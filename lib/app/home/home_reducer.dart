// Pure Home/catalog state model (ticket 04; per-rail rewrite in ticket 71).
//
// `(HomeState, HomeEvent) => HomeState` reducer producing an effects buffer the
// controller drains through injected side-channels (the catalog HTTP fetcher
// and the WS client's playMeta command). No I/O, no timers.
//
// The decisions this module owns, and the seam tests pin:
//   - **Per-rail fetch outcomes** (ticket 71, ADR-0004): the fetcher emits one
//     `loaded` / `failed` / `absent` per planned `rowKey`; the reducer commits
//     each atomically. A `loaded` rail (even empty) replaces the previous copy,
//     a `failed` rail keeps it, an `absent` rail is dropped. A round is pinned
//     by a monotonically increasing [HomeState.round] so a rail is never
//     assembled from two rounds.
//   - **Derived global states** (ticket 71): the Home renders one block per
//     planned rail; "empty Home" and "everything failed" are compositions of the
//     per-rail state, never a blocking `HomeStatus`.
//   - **TMDB-if-key-else-Cinemeta** rows, auto-upgrading the moment a `tmdbKey`
//     lands in a snapshot (and downgrading back to Cinemeta if it is removed).
//   - **Catalog sources on/off** (ticket 41): rows carry the [CatalogRequest] in
//     effect; toggling either starts a new round and a late outcome from a
//     superseded round is dropped.
//   - **Detail → playMeta**: the detail page loads seasons/episodes and the
//     play button encodes the host-driven `playMeta` command.
//
// Effects vocabulary (the Notifier → adapter surface):
//   `fetch:rails` → fetch every planned rail, streaming outcomes back per rail
//   `fetch:rail`  → re-fetch the single rail named by [HomeState.retryingRail]
//   `fetch:detail` → fetch the requested meta's detail, then DetailLoaded/Failed
//   `playMeta`     → send the pending playMeta command to the WS client
//
// Wire contract: docs/wire-contract.md §5.1/§5.2 (data), §4 (playMeta).

library;

import '../letterboxd/letterboxd.dart';
import 'catalog_request.dart';
import 'home_rail.dart';
import 'meta.dart';

enum DetailStatus { loading, ready, failed }

/// The structured playMeta command the reducer produces. The controller drains
/// the `playMeta` effect into the WS client's `sendCommand('playMeta', …)`.
class PlayMetaCommand {
  final String metaId;
  final String metaType; // "movie" | "series" (anime coerced upstream)
  final String? name;
  final String? poster;
  final int? season;
  final int? episode;
  final bool resume;

  const PlayMetaCommand({
    required this.metaId,
    required this.metaType,
    this.name,
    this.poster,
    this.season,
    this.episode,
    this.resume = true,
  });

  /// The payload handed to the WS client's `sendCommand('playMeta', payload)`.
  Map<String, dynamic> toPayload() => {
        'metaId': metaId,
        'metaType': metaType,
        if (name != null) 'name': name,
        if (poster != null) 'poster': poster,
        if (season != null) 'season': season,
        if (episode != null) 'episode': episode,
        'resume': resume,
      };
}

class DetailState {
  final DetailStatus status;
  final Meta meta; // the title being detailed
  final DetailMeta? detail; // resolved when ready
  final String? tmdbKey; // the key in effect when detail was requested
  final String? error;

  const DetailState({
    required this.status,
    required this.meta,
    this.detail,
    this.tmdbKey,
    this.error,
  });
}

class HomeState {
  /// The request the current rail round runs for: the TMDB key in effect,
  /// whether built-in rails are shown, and the Letterboxd config.
  final CatalogRequest request;

  /// Per-`rowKey` rail state. Missing means the current round has not settled
  /// that rail (a skeleton). Entries survive a new round so a failed revalidation
  /// can keep the previous copy.
  final Map<String, RailState> rails;

  /// Monotonic round id, bumped whenever a new full-rail round starts. Outcomes
  /// carry the round they belong to; a mismatch is dropped ("never two rounds").
  final int round;

  /// The rail a single-rail retry is currently re-fetching (`fetch:rail`).
  final String? retryingRail;

  final DetailState? detail;
  final String? notice;
  final PlayMetaCommand? pendingPlay; // the most recent playMeta command

  /// Effects buffer: the reducer appends effects here; the controller drains
  /// them. The one mutable field (impure by convention).
  final List<String> effects;

  HomeState({
    this.request = const CatalogRequest(),
    this.rails = const {},
    this.round = 0,
    this.retryingRail,
    this.detail,
    this.notice,
    this.pendingPlay,
    List<String>? effects,
  }) : effects = effects ?? <String>[];

  String? get tmdbKey => request.tmdbKey;
  LetterboxdConfig get letterboxd => request.letterboxd;
  bool get showBuiltInCatalogs => request.showBuiltInCatalogs;

  /// The rails to render, in the user's chosen order. Pure — the same plan the
  /// fetcher resolves, so a pending rail is known before its outcome arrives.
  List<String> get plannedKeys => planHomeRowKeys(request);

  bool isPending(String rowKey) {
    final rail = rails[rowKey];
    return rail == null || rail.status == RailStatus.pending;
  }

  /// The planned rails that still have a visible block: content or a failed
  /// rail's local retry card (pending rails are visible as skeletons). A
  /// `loaded` empty rail and an `absent` rail render nothing.
  List<String> get renderKeys => [
        for (final key in plannedKeys)
          if (_renders(key)) key,
      ];

  bool _renders(String rowKey) {
    final rail = rails[rowKey];
    if (rail != null && rail.hasItems) return true;
    if (isPending(rowKey)) return true;
    return rail?.status == RailStatus.failed;
  }

  /// Some planned rail still awaits its outcome in the current round.
  bool get hasPending => plannedKeys.any(isPending);

  /// Some planned rail has items on screen (loaded, or a failed rail keeping the
  /// previous copy).
  bool get hasContent => plannedKeys.any((key) => rails[key]?.hasItems ?? false);

  /// Every planned rail failed and nothing is on screen — the global error.
  bool get allFailed {
    if (plannedKeys.isEmpty || hasContent || hasPending) return false;
    return plannedKeys.every((key) => rails[key]?.status == RailStatus.failed);
  }

  /// Nothing planned, or the round settled with nothing to show (all loaded
  /// empty / absent) — the empty Home.
  bool get isEmptyHome {
    if (plannedKeys.isEmpty) return true;
    if (hasContent || hasPending) return false;
    return !allFailed;
  }

  /// The first rail error in plan order, for the global failure screen.
  String? get firstError {
    for (final key in plannedKeys) {
      final error = rails[key]?.error;
      if (error != null) return error;
    }
    return null;
  }

  HomeState copy({
    CatalogRequest? request,
    Map<String, RailState>? rails,
    int? round,
    String? retryingRail,
    bool clearRetryingRail = false,
    DetailState? detail,
    bool clearDetail = false,
    String? notice,
    bool clearNotice = false,
    PlayMetaCommand? pendingPlay,
    List<String>? effects,
  }) {
    return HomeState(
      request: request ?? this.request,
      rails: rails ?? this.rails,
      round: round ?? this.round,
      retryingRail: clearRetryingRail ? null : (retryingRail ?? this.retryingRail),
      detail: clearDetail ? null : (detail ?? this.detail),
      notice: clearNotice ? null : (notice ?? this.notice),
      pendingPlay: pendingPlay ?? this.pendingPlay,
      effects: effects ?? this.effects,
    );
  }
}

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------

sealed class HomeEvent {
  const HomeEvent();
}

/// Load the planned rails on first mount. No-op once a round has started — the
/// Home tab re-entry does not refetch.
class LoadHome extends HomeEvent {
  const LoadHome();
}

/// Force a fresh round regardless of state. The empty/error screens' Refresh
/// action uses it — `LoadHome` would no-op after the first round.
class RefreshHome extends HomeEvent {
  const RefreshHome();
}

/// The host's `tmdbKey` changed in a snapshot: start a keyed (or keyless) round.
class KeyChanged extends HomeEvent {
  final String? tmdbKey;
  const KeyChanged(this.tmdbKey);
}

/// The user changed the catalog sources — Letterboxd config, which built-in
/// rows are off, or their order. Carries the full desired request (with the key
/// in effect), so the reducer just adopts it.
class CatalogSourcesChanged extends HomeEvent {
  final CatalogRequest request;
  const CatalogSourcesChanged(this.request);
}

/// One planned rail resolved. [round] + [request] pin the round that produced
/// it; an outcome from a superseded round is dropped.
class RailOutcomeReceived extends HomeEvent {
  final HomeRailOutcome outcome;
  final CatalogRequest request;
  final int round;
  const RailOutcomeReceived(this.outcome, this.request, this.round);
}

/// The rail stream itself errored (rare — the real fetcher wraps per-rail
/// failures). Every still-pending planned rail fails, keeping any previous copy.
class RailsFetchFailed extends HomeEvent {
  final Object error;
  final CatalogRequest request;
  final int round;
  const RailsFetchFailed(this.error, this.request, this.round);
}

/// Re-fetch a single failed rail from its local retry card.
class RetryRail extends HomeEvent {
  final String rowKey;
  const RetryRail(this.rowKey);
}

class OpenDetail extends HomeEvent {
  final Meta meta;
  const OpenDetail(this.meta);
}

class DetailLoaded extends HomeEvent {
  final Meta meta;
  final DetailMeta detail;
  const DetailLoaded(this.meta, this.detail);
}

class DetailFailed extends HomeEvent {
  final Meta meta;
  final Object error;
  const DetailFailed(this.meta, this.error);
}

class CloseDetail extends HomeEvent {
  const CloseDetail();
}

/// Encode and enqueue a host-driven `playMeta` for the given title (optionally
/// a specific season/episode).
class PlayMeta extends HomeEvent {
  final Meta meta;
  final int? season;
  final int? episode;
  const PlayMeta(this.meta, {this.season, this.episode});
}

// ---------------------------------------------------------------------------
// Reducer
// ---------------------------------------------------------------------------

/// `metaType` is coerced to the host's `movie`/`series` vocabulary (there is no
/// `anime` on the wire, but guard anyway) — matches `toMeta` in
/// `remote-open-bridge.tsx`. Shared with the Search reducer (anime → series).
String coerceMetaType(String type) => type == 'movie' ? 'movie' : 'series';

/// Starts a fresh round for [request]: bump the round id, mark every planned
/// rail pending (keeping any previous copy for a failed revalidation), and emit
/// the fetch effect.
HomeState _startRound(HomeState s, CatalogRequest request, String notice) {
  final rails = Map<String, RailState>.from(s.rails);
  for (final key in planHomeRowKeys(request)) {
    final prev = rails[key];
    rails[key] = prev == null
        ? RailState(rowKey: key)
        : prev.copyWith(status: RailStatus.pending, clearError: true);
  }
  s.effects.add('fetch:rails');
  return s.copy(
    request: request,
    rails: rails,
    round: s.round + 1,
    clearRetryingRail: true,
    notice: notice,
  );
}

HomeState homeReduce(HomeState s, HomeEvent e) {
  switch (e) {
    case LoadHome():
      if (s.round > 0) {
        return s.copy(notice: 'home already loaded — skipped');
      }
      return _startRound(
        s,
        s.request,
        'loading home rails (${s.tmdbKey == null ? 'cinemeta' : 'tmdb'})…',
      );

    case RefreshHome():
      return _startRound(s, s.request, 'refreshing home rails…');

    case KeyChanged(tmdbKey: final key):
      if (key == s.tmdbKey) return s.copy(notice: 'tmdbKey unchanged');
      return _startRound(
        s,
        s.request.copyWith(tmdbKey: key),
        'tmdbKey ${key == null ? 'removed' : 'arrived'} → refetching rails',
      );

    case CatalogSourcesChanged(request: final request):
      if (request == s.request) return s.copy(notice: 'catalog sources unchanged');
      return _startRound(s, request, 'catalog sources changed → refetching rails');

    case RailOutcomeReceived(
        outcome: final outcome,
        request: final request,
        round: final round
      ):
      if (round != s.round || request != s.request) {
        return s.copy(notice: 'stale rail ${outcome.rowKey} — dropped');
      }
      final rails = Map<String, RailState>.from(s.rails);
      final prev = rails[outcome.rowKey];
      switch (outcome) {
        case HomeRailLoaded(title: final title, items: final items):
          rails[outcome.rowKey] = RailState(
            rowKey: outcome.rowKey,
            title: title,
            items: items,
            status: RailStatus.loaded,
          );
        case HomeRailFailed(error: final error):
          rails[outcome.rowKey] = RailState(
            rowKey: outcome.rowKey,
            title: prev?.title ?? '',
            // Keep the previous copy: a failure never blanks a loaded rail.
            items: prev?.items ?? const [],
            status: RailStatus.failed,
            error: '$error',
          );
        case HomeRailAbsent():
          rails[outcome.rowKey] = RailState(
            rowKey: outcome.rowKey,
            title: prev?.title ?? '',
            status: RailStatus.absent,
          );
      }
      return s.copy(
        rails: rails,
        clearRetryingRail: s.retryingRail == outcome.rowKey,
      );

    case RailsFetchFailed(
        error: final error,
        request: final request,
        round: final round
      ):
      if (round != s.round || request != s.request) {
        return s.copy(notice: 'stale rail failure — dropped');
      }
      final rails = Map<String, RailState>.from(s.rails);
      for (final key in s.plannedKeys) {
        if (!s.isPending(key)) continue;
        final prev = rails[key];
        rails[key] = RailState(
          rowKey: key,
          title: prev?.title ?? '',
          items: prev?.items ?? const [],
          status: RailStatus.failed,
          error: '$error',
        );
      }
      return s.copy(rails: rails, notice: 'rail stream failed');

    case RetryRail(rowKey: final key):
      if (!s.plannedKeys.contains(key)) {
        return s.copy(notice: 'retry for unplanned rail $key ignored');
      }
      final rails = Map<String, RailState>.from(s.rails);
      final prev = rails[key];
      rails[key] = prev == null
          ? RailState(rowKey: key)
          : prev.copyWith(status: RailStatus.pending, clearError: true);
      s.effects.add('fetch:rail');
      return s.copy(
        rails: rails,
        retryingRail: key,
        notice: 'retrying rail $key…',
      );

    case OpenDetail(meta: final meta):
      s.effects.add('fetch:detail');
      return s.copy(
        // Pin the key in effect now: a Cinemeta (imdb) meta stays on the
        // Cinemeta path even if a tmdbKey arrives while the detail is loading.
        detail: DetailState(status: DetailStatus.loading, meta: meta, tmdbKey: s.tmdbKey),
        clearNotice: true,
      );

    case DetailLoaded(meta: final meta, detail: final detail):
      if (s.detail?.meta.id != meta.id) {
        return s.copy(notice: 'stale detail (${meta.id}) — dropped');
      }
      return s.copy(
        detail: DetailState(
          status: DetailStatus.ready,
          meta: meta,
          detail: detail,
          tmdbKey: s.detail?.tmdbKey,
        ),
        clearNotice: true,
      );

    case DetailFailed(meta: final meta, error: final error):
      if (s.detail?.meta.id != meta.id) {
        return s.copy(notice: 'stale detail failure (${meta.id}) — dropped');
      }
      return s.copy(
        detail: DetailState(
          status: DetailStatus.failed,
          meta: meta,
          error: '$error',
          tmdbKey: s.detail?.tmdbKey,
        ),
        clearNotice: true,
      );

    case CloseDetail():
      return s.copy(clearDetail: true, clearNotice: true);

    case PlayMeta(meta: final meta, season: final season, episode: final episode):
      final command = PlayMetaCommand(
        metaId: meta.id,
        metaType: coerceMetaType(meta.type),
        name: meta.name,
        poster: meta.poster,
        season: season,
        episode: episode,
      );
      s.effects.add('playMeta');
      return s.copy(
        pendingPlay: command,
        notice: 'playMeta enqueued → ${meta.name}',
      );
  }
}
