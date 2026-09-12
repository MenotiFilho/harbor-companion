// Riverpod controller for Home/catalog (tickets 04, 71).
//
// Thin glue between the pure reducer (home_reducer.dart) and the outside
// world. Drains the reducer's `effects` buffer into the catalog HTTP fetcher
// (`fetch:rails`/`fetch:rail`/`fetch:railPage`/`fetch:detail`) and the WS client
// (`playMeta`), and folds the host's `tmdbKey` into the reducer so rails
// auto-upgrade the moment a key arrives in a snapshot. The per-rail outcome
// stream is folded back in as `RailOutcomeReceived`, tagged with the round it
// belongs to.
//
// The playMeta command goes through the WS client's own `sendCommand`, so it is
// rejected with a notice while disconnected (ticket 02) — the phone never
// resolves streams and never holds credentials (wire-contract §4).

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../letterboxd/letterboxd.dart';
import '../remote/remote_controller.dart';
import '../settings/settings_controller.dart';
import '../ws/client_controller.dart';
import 'catalog_fetcher.dart';
import 'catalog_request.dart';
import 'home_cache_store.dart';
import 'home_rail.dart';
import 'home_reducer.dart';
import 'home_rows.dart';
import 'meta.dart';

/// Catalog fetch seam. Defaults to the real dart:io HTTP fetcher (with the
/// manifest cache wired in); tests override with a fake.
final catalogFetcherProvider = Provider<CatalogFetcher>((ref) => HttpCatalogFetcher(
      cache: ref.read(homeCacheStoreProvider),
      nowMs: ref.read(homeCacheClockProvider),
    ));

/// Per-rail cache seam. Defaults to an in-memory store; the disk-backed store is
/// wired only in the app bootstrap. Tests override.
final homeCacheStoreProvider =
    Provider<HomeCacheStore>((ref) => InMemoryHomeCacheStore());

/// Clock for cache entry `updatedAt` (ms since epoch). Tests pin it.
final homeCacheClockProvider = Provider<int Function()>(
  (ref) => () => DateTime.now().millisecondsSinceEpoch,
);

class HomeController extends Notifier<HomeState> {
  StreamSubscription<HomeRailOutcome>? _railsSub;

  /// Completes when the in-flight round settles (all planned network outcomes
  /// resolved). Created when a round starts; a pull that joins a round awaits
  /// this same future, so the pull indicator clears exactly on settle.
  Completer<void>? _roundSettled;

  @override
  HomeState build() {
    ref.onDispose(() {
      _railsSub?.cancel();
      final settled = _roundSettled;
      if (settled != null && !settled.isCompleted) settled.complete();
    });
    // Seed the current key + Letterboxd config, then upgrade/refetch the rows
    // whenever either changes: the host's `tmdbKey` arrives in a snapshot (the
    // WS client persists + re-applies it), and the Letterboxd manifest URL /
    // enabled catalogs change in Settings.
    final currentKey = ref.read(wsClientControllerProvider).tmdbKey;
    ref.listen(wsClientControllerProvider, (previous, next) {
      if (next.tmdbKey != previous?.tmdbKey) {
        _dispatch(KeyChanged(next.tmdbKey));
      }
    });
    ref.listen(settingsControllerProvider, (previous, next) {
      if (_requestOf(previous) != _requestOf(next)) {
        _dispatch(CatalogSourcesChanged(
          // Keep the key already in effect — the sources change only.
          _requestOf(next, tmdbKey: state.tmdbKey),
        ));
      }
    });
    return HomeState(
      request: _requestOf(
        ref.read(settingsControllerProvider),
        tmdbKey: currentKey,
      ),
    );
  }

  /// The row request implied by [settings], with [tmdbKey] (null for the
  /// equality check that decides whether a Settings change needs a refetch).
  CatalogRequest _requestOf(SettingsState? settings, {String? tmdbKey}) =>
      CatalogRequest(
        tmdbKey: tmdbKey,
        letterboxd: _letterboxdOf(settings),
        disabledBuiltInRowKeys: settings?.disabledBuiltInRowKeys ?? const {},
        rowOrder: settings?.homeRowOrder ?? kDefaultHomeRowOrder,
      );

  LetterboxdConfig _letterboxdOf(SettingsState? settings) => LetterboxdConfig(
        manifestUrl: settings?.letterboxdManifestUrl ?? '',
        enabledCatalogIds:
            settings?.enabledLetterboxdCatalogs ?? kDefaultLetterboxdCatalogIds,
      );

  /// The automatic once-per-process trigger, dispatched when the Home first
  /// becomes available after connect (ADR-0008). A second call is a no-op.
  void load() => _dispatch(const LoadHome());

  /// Force a fresh round (the empty/error screens' Refresh/Retry action).
  void reload() => _dispatch(const RefreshHome());

  /// Manual pull-to-refresh. Starts a round when none is in flight; a pull
  /// during an in-flight round joins it (ADR-0008 coalescing) instead of
  /// starting a second. The returned future completes when the round settles,
  /// so the pull indicator stays up until every planned rail resolves.
  Future<void> refresh() {
    _dispatch(const RefreshHome());
    return _roundSettled?.future ?? Future<void>.value();
  }

  /// Re-fetch one failed rail from its local retry card.
  void retryRail(String rowKey) => _dispatch(RetryRail(rowKey));

  /// The tap seam for a rail's title / "See more" card (ticket 75). The reducer
  /// snapshots the rail and the widget pushes the grid route (#76).
  void openRailGrid(String rowKey) => _dispatch(OpenRailGrid(rowKey));

  /// The grid's on-scroll trigger (ticket 77): ask the reducer for the next
  /// page. Idempotent — it is ignored while a page is in flight, after the end,
  /// or while the footer error is showing.
  void loadMoreRailGrid() => _dispatch(const RailGridScrolledToEnd());

  /// The grid footer's retry (ticket 77): clear the failure and request the
  /// same page again.
  void retryRailGridPage() => _dispatch(const RetryRailGridPage());

  void openDetail(Meta meta) => _dispatch(OpenDetail(meta));

  void closeDetail() => _dispatch(const CloseDetail());

  void playMeta(Meta meta, {int? season, int? episode}) =>
      _dispatch(PlayMeta(meta, season: season, episode: episode));

  // -- The one place state mutates -------------------------------------------

  void _dispatch(HomeEvent event) {
    state = homeReduce(state, event);
    _syncRoundCompleter();
    _drain(state);
  }

  /// Keeps [_roundSettled] in step with the reducer's explicit in-flight signal:
  /// a round start creates the completer, the moment the plan stops pending it
  /// completes (and is cleared for the next round). Cache seeding never trips
  /// this — only a network outcome (or the stream failing) does.
  void _syncRoundCompleter() {
    if (state.roundInFlight) {
      _roundSettled ??= Completer<void>();
      return;
    }
    final settled = _roundSettled;
    if (settled == null) return;
    _roundSettled = null;
    if (!settled.isCompleted) settled.complete();
  }

  void _drain(HomeState next) {
    if (next.effects.isEmpty) return;
    final effects = List<String>.from(next.effects);
    next.effects.clear();
    for (final effect in effects) {
      switch (effect) {
        case 'fetch:rails':
          _fetchRails();
        case 'fetch:rail':
          _fetchRail();
        case 'fetch:railPage':
          _fetchRailGridPage();
        case 'fetch:detail':
          _fetchDetail();
        case 'playMeta':
          _sendPlayMeta();
      }
    }
  }

  /// Starts the round's stream: one [HomeRailOutcome] per planned rail, folded
  /// in as each arrives. The per-rail cache is read *before* the network round
  /// so cached rails render immediately (badged); each fresh `loaded` outcome is
  /// committed and written back to the cache. Captures the round id so a late
  /// outcome from a superseded round is dropped by the reducer. A previous
  /// subscription is cancelled first so a new round never receives the old
  /// round's tail.
  Future<void> _fetchRails() async {
    final request = state.request;
    await _seedFromCache(request);
    if (!ref.mounted || state.request != request) return;
    final round = state.round;
    await _railsSub?.cancel();
    if (!ref.mounted) return;
    _railsSub = ref.read(catalogFetcherProvider).fetchRails(request).listen(
      (outcome) {
        if (!ref.mounted) return;
        _commitRailOutcome(outcome, request, round);
      },
      onError: (Object error) {
        if (!ref.mounted) return;
        _dispatch(RailsFetchFailed(error, request, round));
      },
      // Safety net: a stream that ends before emitting every planned rail would
      // otherwise leave the round (and the pull indicator) hanging. Fail the
      // still-pending rails of this round; a normal stream has none left.
      onDone: () {
        if (!ref.mounted) return;
        if (state.round == round &&
            state.request == request &&
            state.roundInFlight) {
          _dispatch(RailsFetchFailed(
            StateError('rail stream closed before every rail resolved'),
            request,
            round,
          ));
        }
      },
    );
  }

  /// Reads the per-rail cache for [request] and folds it in as [CacheLoaded]
  /// before any network rail starts. Also sweeps entries whose identity no
  /// longer matches the config (never order/visibility/tmdbKey).
  Future<void> _seedFromCache(CatalogRequest request) async {
    final store = ref.read(homeCacheStoreProvider);
    try {
      await store.sweep(cacheIdentitiesFor(request));
    } catch (_) {
      // A failed sweep must never block the Home.
    }
    if (!ref.mounted) return;
    // Read every planned rail in parallel so a cold open is one disk round, not
    // one per rail; the badge appears as soon as they all land.
    final loaded = await Future.wait([
      for (final key in planHomeRowKeys(request))
        _loadCachedRail(store, key, request),
    ]);
    final cached = <String, CachedRail>{
      for (final entry in loaded)
        if (entry.value != null) entry.key: entry.value!,
    };
    if (!ref.mounted || cached.isEmpty) return;
    _dispatch(CacheLoaded(request, cached));
  }

  Future<MapEntry<String, CachedRail?>> _loadCachedRail(
    HomeCacheStore store,
    String key,
    CatalogRequest request,
  ) async {
    try {
      final rail = await store.loadRail(cacheIdentityFor(key, request));
      return MapEntry(key, rail);
    } catch (_) {
      // A bad entry costs one rail.
      return MapEntry(key, null);
    }
  }

  /// Folds one rail outcome into the reducer and, when it is a fresh `loaded`,
  /// writes it back to the cache. The single commit path for both the full
  /// round's stream and a lone [RetryRail], so a retry persists exactly like a
  /// round outcome (same identity, same `updatedAt` clock).
  void _commitRailOutcome(
    HomeRailOutcome outcome,
    CatalogRequest request,
    int round,
  ) {
    _dispatch(RailOutcomeReceived(outcome, request, round));
    _writeCache(outcome, request);
  }

  /// Writes a fresh `loaded` rail back to the cache (fire-and-forget — a cache
  /// write never blocks or fails the UI). Failed/absent outcomes leave the
  /// previous entry untouched.
  void _writeCache(HomeRailOutcome outcome, CatalogRequest request) {
    if (outcome is! HomeRailLoaded) return;
    final identity = cacheIdentityFor(outcome.rowKey, request);
    final entry = CachedRail(
      items: outcome.items,
      hasMore: outcome.hasMore,
      updatedAt: ref.read(homeCacheClockProvider)(),
    );
    ref
        .read(homeCacheStoreProvider)
        .saveRail(identity, entry)
        .catchError((_) {});
  }

  /// Re-fetches the single rail named by the retry card. The outcome takes the
  /// same commit path as a round outcome, so a successful retry is persisted to
  /// the cache too.
  Future<void> _fetchRail() async {
    final key = state.retryingRail;
    if (key == null) return;
    final request = state.request;
    final round = state.round;
    try {
      final outcome =
          await ref.read(catalogFetcherProvider).fetchRail(request, key);
      if (!ref.mounted) return;
      _commitRailOutcome(outcome, request, round);
    } catch (error) {
      if (!ref.mounted) return;
      _commitRailOutcome(HomeRailFailed(key, error), request, round);
    }
  }

  /// Fetches the active grid's next page (ticket 77). The reducer marked it
  /// loading before emitting `fetch:railPage`, so this reads the cursor and
  /// request to resume from. A success appends (deduped) and advances the
  /// cursor; a failure keeps the loaded items and exposes the footer retry. The
  /// event carries the rowKey, so a page that lands after another grid opened is
  /// dropped by the reducer instead of corrupting the new grid.
  Future<void> _fetchRailGridPage() async {
    final grid = state.activeRailGrid;
    if (grid == null || !grid.loading) return;
    final key = grid.rowKey;
    final cursor = grid.cursor;
    final request = grid.request;
    try {
      final page = await ref
          .read(catalogFetcherProvider)
          .fetchRailPage(request, key, cursor);
      if (!ref.mounted) return;
      _dispatch(RailGridPageReceived(key, page.items, hasMore: page.hasMore));
    } catch (error) {
      if (!ref.mounted) return;
      _dispatch(RailGridPageFailed(key, error));
    }
  }

  Future<void> _fetchDetail() async {
    final pending = state.detail;
    if (pending == null || pending.status != DetailStatus.loading) return;
    final meta = pending.meta;
    try {
      // Use the key pinned at request time, not the current one — the id's
      // source (imdb vs tmdb:) must match the source that listed it.
      final detail = await ref
          .read(catalogFetcherProvider)
          .fetchDetail(meta.type, meta.id, pending.tmdbKey);
      if (!ref.mounted) return;
      _dispatch(DetailLoaded(meta, detail));
    } catch (error) {
      if (!ref.mounted) return;
      _dispatch(DetailFailed(meta, error));
    }
  }

  void _sendPlayMeta() {
    final command = state.pendingPlay;
    if (command == null) return;
    // The Remote layer owns the awaiting-start window: it records the request,
    // sends the command, and tracks the first non-idle snapshot / timeout.
    ref.read(remoteControllerProvider.notifier).playMeta(command);
  }
}

final homeControllerProvider =
    NotifierProvider<HomeController, HomeState>(HomeController.new);
