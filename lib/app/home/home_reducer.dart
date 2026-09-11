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
//   - **Cache-first** (ticket 72, ADR-0004): `CacheLoaded` seeds pending rails
//     from disk before the network round, marked `fromCache` with the entry's
//     `updatedAt`; a fresh `loaded` outcome replaces the copy and clears the
//     badge. A revalidation never clobbers content already on screen.
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
import 'home_cache_store.dart';
import 'home_rail.dart';
import 'home_rows.dart';
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

/// The outcome of a settled rail round (ticket 74, ADR-0008). The widget shows
/// at most one short snackbar, and only when [notifyFailure] holds: the round
/// was started by a manual pull and the whole round failed. A partial failure,
/// a round that kept content (cache), or the automatic round stay silent.
class RoundSummary {
  final int round;
  final bool manual;
  final bool allFailed;

  const RoundSummary({
    required this.round,
    required this.manual,
    required this.allFailed,
  });

  bool get notifyFailure => manual && allFailed;
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

  /// Process latch (ticket 74, ADR-0008): the automatic once-per-process
  /// revalidation has been triggered. The first [LoadHome] arms it — even when
  /// it joins a round already in flight — and nothing clears it, so tab
  /// re-entry after the Home settled never refetches.
  final bool autoRefreshDone;

  /// Whether the round currently in flight (or just settled) was started by a
  /// manual pull. A pull that joins an in-flight round upgrades it to manual so
  /// the user still gets their failure feedback.
  final bool roundManual;

  /// The planned rails of the current round that still await their network
  /// outcome. Cache seeding fills [rails] without completing the round, so this
  /// — not [hasPending] — is the "round in flight" signal a pull awaits.
  final Set<String> roundPending;

  /// The summary of the last settled round, or null while a round is in flight
  /// or before the first round. Cleared when a new round starts.
  final RoundSummary? roundSummary;

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
    this.autoRefreshDone = false,
    this.roundManual = false,
    this.roundPending = const {},
    this.roundSummary,
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

  /// A full round is in flight while any planned rail still awaits its network
  /// outcome. Cache seeding (which marks rails `loaded` from disk) does not
  /// settle the round, so a pull keeps its indicator until the network resolves.
  bool get roundInFlight => roundPending.isNotEmpty;

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
    bool? autoRefreshDone,
    bool? roundManual,
    Set<String>? roundPending,
    RoundSummary? roundSummary,
    bool clearRoundSummary = false,
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
      autoRefreshDone: autoRefreshDone ?? this.autoRefreshDone,
      roundManual: roundManual ?? this.roundManual,
      roundPending: roundPending ?? this.roundPending,
      roundSummary:
          clearRoundSummary ? null : (roundSummary ?? this.roundSummary),
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

/// The automatic once-per-process trigger (ADR-0008), dispatched when the Home
/// first becomes available after connect. Arms the process latch; a second
/// `LoadHome` (tab re-entry) is a no-op. If a round is already in flight (e.g.
/// a source-change refetch) it joins it instead of starting a duplicate.
class LoadHome extends HomeEvent {
  const LoadHome();
}

/// Force a fresh round regardless of state (pull-to-refresh and the empty/error
/// screens' Refresh action). A `RefreshHome` during an in-flight round joins
/// that round rather than starting another (ADR-0008 coalescing).
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

/// Seeds the planned rails from the disk cache before the network round. Each
/// cached rail renders immediately as `fromCache` with its age; a fresh outcome
/// replaces it in place. Only rails still pending with nothing on screen are
/// seeded, so a revalidation never clobbers content already shown.
class CacheLoaded extends HomeEvent {
  final CatalogRequest request;
  final Map<String, CachedRail> rails; // by rowKey
  const CacheLoaded(this.request, this.rails);
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

/// A rail's title or its "See more" card was tapped (ticket 75). The dedicated
/// grid route and its snapshot state arrive in #76; this event is the seam they
/// hook into, so the rail is tappable (and testable) before the grid exists.
class OpenRailGrid extends HomeEvent {
  final String rowKey;
  const OpenRailGrid(this.rowKey);
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
/// rail pending (keeping any previous copy for a failed revalidation), pin
/// which of them still await a network outcome, and emit the fetch effect.
/// [manual] marks a pull-started round for the failure summary; [armAutoRefresh]
/// sets the process latch when the round is the automatic first one.
HomeState _startRound(
  HomeState s,
  CatalogRequest request,
  String notice, {
  required bool manual,
  bool armAutoRefresh = false,
}) {
  final planned = planHomeRowKeys(request);
  final rails = Map<String, RailState>.from(s.rails);
  for (final key in planned) {
    final prev = rails[key];
    rails[key] = prev == null
        ? RailState(rowKey: key)
        : prev.copyWith(status: RailStatus.pending, clearError: true);
  }
  // An empty plan has no pending outcome: [roundPending] is empty and the
  // round is considered settled the moment it starts (the empty Home).
  s.effects.add('fetch:rails');
  return s.copy(
    request: request,
    rails: rails,
    round: s.round + 1,
    clearRetryingRail: true,
    notice: notice,
    roundManual: manual,
    roundPending: planned.toSet(),
    clearRoundSummary: true,
    autoRefreshDone: armAutoRefresh ? true : null,
  );
}

HomeState homeReduce(HomeState s, HomeEvent e) {
  switch (e) {
    case LoadHome():
      // The automatic once-per-process trigger: arm the latch and start a
      // round, or join one already in flight (e.g. a source-change refetch
      // that began before the Home opened) rather than duplicating it.
      if (s.autoRefreshDone) {
        return s.copy(notice: 'home already loaded — skipped');
      }
      if (s.roundInFlight) {
        return s.copy(
          autoRefreshDone: true,
          notice: 'home load joined in-flight round',
        );
      }
      return _startRound(
        s,
        s.request,
        'loading home rails (${s.tmdbKey == null ? 'cinemeta' : 'tmdb'})…',
        manual: false,
        armAutoRefresh: true,
      );

    case RefreshHome():
      // Manual pull. A pull during an in-flight round joins it (ADR-0008);
      // marking it manual keeps the pull's failure feedback. Otherwise start a
      // fresh manual round.
      if (s.roundInFlight) {
        return s.copy(
          roundManual: true,
          notice: 'refresh joined in-flight round',
        );
      }
      return _startRound(s, s.request, 'refreshing home rails…', manual: true);

    case KeyChanged(tmdbKey: final key):
      if (key == s.tmdbKey) return s.copy(notice: 'tmdbKey unchanged');
      return _startRound(
        s,
        s.request.copyWith(tmdbKey: key),
        'tmdbKey ${key == null ? 'removed' : 'arrived'} → refetching rails',
        manual: false,
      );

    case CatalogSourcesChanged(request: final request):
      if (request == s.request) return s.copy(notice: 'catalog sources unchanged');
      return _startRound(
        s,
        request,
        'catalog sources changed → refetching rails',
        manual: false,
      );

    case CacheLoaded(request: final request, rails: final cached):
      if (request != s.request) {
        return s.copy(notice: 'stale cache — dropped');
      }
      final rails = Map<String, RailState>.from(s.rails);
      for (final entry in cached.entries) {
        final key = entry.key;
        if (!s.plannedKeys.contains(key)) continue;
        final prev = rails[key];
        // Never clobber a rail that already has content or has settled this
        // round: cache-first only fills a pending empty rail.
        if (prev != null && (prev.hasItems || prev.status != RailStatus.pending)) {
          continue;
        }
        rails[key] = RailState(
          rowKey: key,
          title: homeRowLabel(key),
          items: entry.value.items,
          status: RailStatus.loaded,
          fromCache: true,
          updatedAt: entry.value.updatedAt,
          hasMore: entry.value.hasMore,
        );
      }
      return s.copy(rails: rails, notice: '${cached.length} cached rails seeded');

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
        case HomeRailLoaded(title: final title, items: final items, hasMore: final hasMore):
          rails[outcome.rowKey] = RailState(
            rowKey: outcome.rowKey,
            title: title,
            items: items,
            status: RailStatus.loaded,
            hasMore: hasMore,
          );
        case HomeRailFailed(error: final error):
          rails[outcome.rowKey] = RailState(
            rowKey: outcome.rowKey,
            title: prev?.title ?? '',
            // Keep the previous copy: a failure never blanks a loaded rail.
            items: prev?.items ?? const [],
            status: RailStatus.failed,
            error: '$error',
            // A cached copy stays badged through a failed revalidation.
            fromCache: prev?.fromCache ?? false,
            updatedAt: prev?.updatedAt,
            hasMore: prev?.hasMore ?? false,
          );
        case HomeRailAbsent():
          rails[outcome.rowKey] = RailState(
            rowKey: outcome.rowKey,
            title: prev?.title ?? '',
            status: RailStatus.absent,
          );
      }
      final pending = Set<String>.from(s.roundPending)..remove(outcome.rowKey);
      final next = s.copy(
        rails: rails,
        roundPending: pending,
        clearRetryingRail: s.retryingRail == outcome.rowKey,
      );
      // The round settles when the last planned outcome lands; the summary is
      // read by the widget to decide the single manual-failure snackbar.
      if (s.roundInFlight && pending.isEmpty) {
        return next.copy(
          roundSummary: RoundSummary(
            round: s.round,
            manual: s.roundManual,
            allFailed: next.allFailed,
          ),
        );
      }
      return next;

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
          fromCache: prev?.fromCache ?? false,
          updatedAt: prev?.updatedAt,
          hasMore: prev?.hasMore ?? false,
        );
      }
      final next = s.copy(
        rails: rails,
        roundPending: const {},
        notice: 'rail stream failed',
      );
      if (s.roundInFlight) {
        return next.copy(
          roundSummary: RoundSummary(
            round: s.round,
            manual: s.roundManual,
            allFailed: next.allFailed,
          ),
        );
      }
      return next;

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

    case OpenRailGrid(rowKey: final key):
      // Ticket 75 seam: the grid state + route land in #76. No fetch effect —
      // the grid opens on what the rail already holds.
      return s.copy(notice: 'open rail grid $key (#76)');

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
