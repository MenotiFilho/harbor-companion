// Riverpod controller for Home/catalog (tickets 04, 71).
//
// Thin glue between the pure reducer (home_reducer.dart) and the outside
// world. Drains the reducer's `effects` buffer into the catalog HTTP fetcher
// (`fetch:rails`/`fetch:rail`/`fetch:detail`) and the WS client (`playMeta`),
// and folds the host's `tmdbKey` into the reducer so rails auto-upgrade the
// moment a key arrives in a snapshot. The per-rail outcome stream is folded
// back in as `RailOutcomeReceived`, tagged with the round it belongs to.
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
import 'home_rail.dart';
import 'home_reducer.dart';
import 'home_rows.dart';
import 'meta.dart';

/// Catalog fetch seam. Defaults to the real dart:io HTTP fetcher; tests
/// override with a fake.
final catalogFetcherProvider =
    Provider<CatalogFetcher>((ref) => HttpCatalogFetcher());

class HomeController extends Notifier<HomeState> {
  StreamSubscription<HomeRailOutcome>? _railsSub;

  @override
  HomeState build() {
    ref.onDispose(() => _railsSub?.cancel());
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

  void load() => _dispatch(const LoadHome());

  /// Force a fresh round (the empty/error screens' Refresh action).
  void reload() => _dispatch(const RefreshHome());

  /// Re-fetch one failed rail from its local retry card.
  void retryRail(String rowKey) => _dispatch(RetryRail(rowKey));

  void openDetail(Meta meta) => _dispatch(OpenDetail(meta));

  void closeDetail() => _dispatch(const CloseDetail());

  void playMeta(Meta meta, {int? season, int? episode}) =>
      _dispatch(PlayMeta(meta, season: season, episode: episode));

  // -- The one place state mutates -------------------------------------------

  void _dispatch(HomeEvent event) {
    state = homeReduce(state, event);
    _drain(state);
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
        case 'fetch:detail':
          _fetchDetail();
        case 'playMeta':
          _sendPlayMeta();
      }
    }
  }

  /// Starts the round's stream: one [HomeRailOutcome] per planned rail, folded
  /// in as each arrives. Captures the round id so a late outcome from a
  /// superseded round is dropped by the reducer. A previous subscription is
  /// cancelled first so a new round never receives the old round's tail.
  Future<void> _fetchRails() async {
    final request = state.request;
    final round = state.round;
    await _railsSub?.cancel();
    if (!ref.mounted) return;
    _railsSub = ref.read(catalogFetcherProvider).fetchRails(request).listen(
      (outcome) {
        if (!ref.mounted) return;
        _dispatch(RailOutcomeReceived(outcome, request, round));
      },
      onError: (Object error) {
        if (!ref.mounted) return;
        _dispatch(RailsFetchFailed(error, request, round));
      },
    );
  }

  /// Re-fetches the single rail named by the retry card.
  Future<void> _fetchRail() async {
    final key = state.retryingRail;
    if (key == null) return;
    final request = state.request;
    final round = state.round;
    try {
      final outcome =
          await ref.read(catalogFetcherProvider).fetchRail(request, key);
      if (!ref.mounted) return;
      _dispatch(RailOutcomeReceived(outcome, request, round));
    } catch (error) {
      if (!ref.mounted) return;
      _dispatch(RailOutcomeReceived(HomeRailFailed(key, error), request, round));
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
