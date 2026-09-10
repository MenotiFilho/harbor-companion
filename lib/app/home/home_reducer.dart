// Pure Home/catalog state model (ticket 04).
//
// `(HomeState, HomeEvent) => HomeState` reducer producing an effects buffer the
// controller drains through injected side-channels (the catalog HTTP fetcher
// and the WS client's playMeta command). No I/O, no timers.
//
// The three decisions this module owns, and the seam tests pin:
//   - **TMDB-if-key-else-Cinemeta** rows, auto-upgrading the moment a `tmdbKey`
//     lands in a snapshot (and downgrading back to Cinemeta if it is removed).
//   - **Letterboxd rail on/off** (ticket 41): rows carry the Stremboxd config in
//     effect, so a manifest-URL or catalog-toggle change refetches and a late
//     fetch from the old config is dropped.
//   - **Detail → playMeta**: the detail page loads seasons/episodes and the
//     play button encodes the host-driven `playMeta` command (movie, series
//     first episode, or a specific episode — `resume` always true).
//
// Effects vocabulary (the Notifier → adapter surface):
//   `fetch:rows`   → fetch home rows with the current key + config, then RowsLoaded/Failed
//   `fetch:detail` → fetch the requested meta's detail, then DetailLoaded/Failed
//   `playMeta`     → send the pending playMeta command to the WS client
//
// Wire contract: docs/wire-contract.md §5.1/§5.2 (data), §4 (playMeta).

library;

import '../letterboxd/letterboxd.dart';
import 'meta.dart';

enum HomeStatus { idle, loading, ready, failed }

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
  final HomeStatus status;
  final String? tmdbKey; // the key currently in effect for rows
  final LetterboxdConfig letterboxd; // the Stremboxd config in effect for rows
  final List<HomeRow> rows;
  final DetailState? detail;
  final String? lastError;
  final String? notice;
  final PlayMetaCommand? pendingPlay; // the most recent playMeta command

  /// Effects buffer: the reducer appends effects here; the controller drains
  /// them. The one mutable field (impure by convention).
  final List<String> effects;

  HomeState({
    this.status = HomeStatus.idle,
    this.tmdbKey,
    this.letterboxd = const LetterboxdConfig(),
    this.rows = const [],
    this.detail,
    this.lastError,
    this.notice,
    this.pendingPlay,
    List<String>? effects,
  }) : effects = effects ?? <String>[];

  HomeState copy({
    HomeStatus? status,
    String? tmdbKey,
    bool clearTmdbKey = false,
    LetterboxdConfig? letterboxd,
    List<HomeRow>? rows,
    DetailState? detail,
    bool clearDetail = false,
    String? lastError,
    bool clearLastError = false,
    String? notice,
    bool clearNotice = false,
    PlayMetaCommand? pendingPlay,
    List<String>? effects,
  }) {
    return HomeState(
      status: status ?? this.status,
      tmdbKey: clearTmdbKey ? null : (tmdbKey ?? this.tmdbKey),
      letterboxd: letterboxd ?? this.letterboxd,
      rows: rows ?? this.rows,
      detail: clearDetail ? null : (detail ?? this.detail),
      lastError: clearLastError ? null : (lastError ?? this.lastError),
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

/// Load (or retry after a failure) the home rows. No-op while already loading
/// or ready — the Home tab re-entry does not refetch.
class LoadHome extends HomeEvent {
  const LoadHome();
}

/// The host's `tmdbKey` changed in a snapshot: upgrade (or downgrade) the rows.
class KeyChanged extends HomeEvent {
  final String? tmdbKey;
  const KeyChanged(this.tmdbKey);
}

/// The user changed the Letterboxd/Stremboxd configuration (manifest URL or the
/// enabled catalog set): refetch the rows so the rails track the choice.
class LetterboxdChanged extends HomeEvent {
  final LetterboxdConfig config;
  const LetterboxdChanged(this.config);
}

class RowsLoaded extends HomeEvent {
  final List<HomeRow> rows;
  final String? tmdbKey;
  final LetterboxdConfig letterboxd;
  const RowsLoaded(this.rows, this.tmdbKey, {required this.letterboxd});
}

class RowsFailed extends HomeEvent {
  final Object error;
  final String? tmdbKey;
  final LetterboxdConfig letterboxd;
  const RowsFailed(this.error, this.tmdbKey, {required this.letterboxd});
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

/// A rows result is stale when the key or Letterboxd config that produced it no
/// longer matches the state — a late fetch must not overwrite fresher intent.
bool _rowsAreStale(HomeState s, String? key, LetterboxdConfig config) =>
    key != s.tmdbKey || config != s.letterboxd;

HomeState homeReduce(HomeState s, HomeEvent e) {
  switch (e) {
    case LoadHome():
      if (s.status == HomeStatus.loading || s.status == HomeStatus.ready) {
        return s.copy(notice: 'rows already ${s.status.name} — skipped');
      }
      s.effects.add('fetch:rows');
      return s.copy(
        status: HomeStatus.loading,
        clearLastError: true,
        notice: 'loading home rows (${s.tmdbKey == null ? 'cinemeta' : 'tmdb'})…',
      );

    case KeyChanged(tmdbKey: final key):
      if (key == s.tmdbKey) return s.copy(notice: 'tmdbKey unchanged');
      s.effects.add('fetch:rows');
      return s.copy(
        tmdbKey: key,
        clearTmdbKey: key == null,
        status: HomeStatus.loading,
        clearLastError: true,
        notice: 'tmdbKey ${key == null ? 'removed' : 'arrived'} → refetching rows',
      );

    case LetterboxdChanged(config: final config):
      if (config == s.letterboxd) {
        return s.copy(notice: 'letterboxd config unchanged');
      }
      s.effects.add('fetch:rows');
      return s.copy(
        letterboxd: config,
        status: HomeStatus.loading,
        clearLastError: true,
        notice: 'letterboxd config changed → refetching rows',
      );

    case RowsLoaded(rows: final rows, tmdbKey: final key, letterboxd: final config):
      if (_rowsAreStale(s, key, config)) {
        return s.copy(notice: 'stale rows — dropped');
      }
      return s.copy(
        status: HomeStatus.ready,
        rows: rows,
        clearLastError: true,
        notice: '${rows.length} rows loaded',
      );

    case RowsFailed(error: final error, tmdbKey: final key, letterboxd: final config):
      if (_rowsAreStale(s, key, config)) {
        return s.copy(notice: 'stale rows failure — dropped');
      }
      return s.copy(
        status: HomeStatus.failed,
        rows: const [],
        lastError: 'catalog fetch failed: $error',
        notice: 'home rows failed — retry?',
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
