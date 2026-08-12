// Pure Search state model (ticket 05).
//
// `(SearchState, SearchEvent) => SearchState` reducer producing an effects
// buffer the controller drains through injected side-channels (the search HTTP
// fetcher and the WS client's playMeta). No I/O, no timers: the controller owns
// the 180ms debounce timer and the 8s per-source guard, and folds the host's
// `tmdbKey` (from snapshots) back in as a [KeyChanged] event.
//
// Lifted from the validated search prototype (prototype/search). The decisions
// this module owns, and the seam tests pin:
//
//   - **180ms debounce + request guard**: typing abandons the prior request;
//     only the current query's results may publish.
//   - **Parallel fan-out** of TMDB `search/multi` (when keyed), Cinemeta
//     `search=` (keyless fallback), and Jikan anime, each with an 8s source
//     guard (a timeout is a fallback to empty, never an error); incremental
//     publish as each source lands; `done` only on full settle.
//   - **Merge order**: TMDB base + cinemeta appended (dedupe by id) → dedupe by
//     normalized title + year (different year = a remake, survives) →
//     anime-wins over colliding film rows → top-match swap (anime id becomes
//     `kitsu:`/`mal:`/`anilist:`).
//   - **Keyless → cinemeta rows only, no top-match card**; the key re-applies
//     from the snapshot and re-runs an active query the moment it changes.
//   - **playMeta encoding**: `anime` coerced to `series`, `resume` always true.
//
// Effects vocabulary (the Notifier → adapter surface):
//   `debounce:<id>`            → arm a 180ms timer, then dispatch DebounceFired
//   `fetch:<tmdb|cinemeta|jikan>:<id>:<query>` → run the source (8s guard)
//   `playMeta`                 → send `pendingPlay` via the WS client
//
// Wire contract: docs/wire-contract.md §5.1/§5.2/§5.3 (data), §4 (playMeta).

library;

import '../home/home_reducer.dart' show PlayMetaCommand, coerceMetaType;
import '../home/meta.dart';

const Duration debounceDelay = Duration(milliseconds: 180);
const Duration sourceTimeout = Duration(milliseconds: 8000);
const int maxRecent = 8;
const int mergeCap = 20;

enum SearchStatus { idle, typing, loading, done }

enum Source { tmdb, cinemeta, jikan }

const Set<Source> allSources = {Source.tmdb, Source.cinemeta, Source.jikan};

// ---------------------------------------------------------------------------
// Anime model (Jikan)
// ---------------------------------------------------------------------------

/// A Jikan anime hit. `metaId` prefers `kitsu:` then `mal:` then `anilist:`
/// (jikan.ts:210-216); `kind` is `movie` only for the `Movie` format.
class AnimeHit {
  final int? malId;
  final int? kitsuId;
  final int? anilistId;
  final String? format; // "TV" | "Movie" | ...
  final String name;
  final String? year;
  final String? poster;
  final String? background;
  final String overview;

  const AnimeHit({
    this.malId,
    this.kitsuId,
    this.anilistId,
    this.format,
    required this.name,
    this.year,
    this.poster,
    this.background,
    this.overview = '',
  });

  String get metaId {
    if (kitsuId != null) return 'kitsu:$kitsuId';
    if (malId != null) return 'mal:$malId';
    return 'anilist:$anilistId';
  }

  String get kind => format?.toUpperCase() == 'MOVIE' ? 'movie' : 'series';

  /// The `Meta` this hit renders as (type `anime`, coerced to `series` on play).
  Meta get meta => Meta(
        id: metaId,
        type: 'anime',
        name: name,
        poster: poster,
        background: background,
        description: overview.isEmpty ? null : overview,
        releaseInfo: year,
      );
}

// ---------------------------------------------------------------------------
// Results model
// ---------------------------------------------------------------------------

/// The pinned top-match card. `meta` is the TMDB top result, or the anime hit
/// that replaced it (same name → anime wins; id becomes `kitsu:`/`mal:`/`anilist:`).
class TopMatch {
  final String kind; // "movie" | "series"
  final Meta meta;
  final double popularity;
  final String? backdrop;
  final String? overview;
  final double? voteAverage;
  const TopMatch({
    required this.kind,
    required this.meta,
    this.popularity = 0,
    this.backdrop,
    this.overview,
    this.voteAverage,
  });
}

/// The TMDB source payload: movies, series, and the derived top match.
class TmdbSearchPayload {
  final List<Meta> movies;
  final List<Meta> series;
  final TopMatch? topMatch;
  const TmdbSearchPayload(this.movies, this.series, [this.topMatch]);
}

class SearchResults {
  final String query;
  final TopMatch? topMatch;
  final List<Meta> movies;
  final List<Meta> series;
  final List<AnimeHit> anime;
  const SearchResults({
    required this.query,
    this.topMatch,
    this.movies = const [],
    this.series = const [],
    this.anime = const [],
  });

  /// What the grid renders: top-match pinned first, then movies/series
  /// interleaved (mobile-search.tsx:143-149). Anime rows render separately.
  List<Meta> get grid {
    final out = <Meta>[];
    if (topMatch != null) out.add(topMatch!.meta);
    final seen = <String>{topMatch?.meta.id ?? ''};
    for (final m in interleave(movies, series)) {
      if (seen.add(m.id)) out.add(m);
    }
    return out;
  }
}

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

class SearchState {
  final String query;
  final SearchStatus status;
  final String? tmdbKey; // the key currently in effect (from snapshots)
  final int requestId; // the request guard's "current" id
  final SearchResults? results;
  final List<String> recent;
  final bool hideAnime;

  // Accumulators per request (only valid while a request is in flight).
  final TopMatch? topMatch; // TMDB's top match (the pinned card)
  final List<Meta> tmdbMovies;
  final List<Meta> tmdbSeries;
  final List<Meta> cineMovies;
  final List<Meta> cineSeries;
  final List<AnimeHit> anime;
  final Set<Source> pending; // sources still in flight for the current request

  // Observability counters (for tests / honest notes).
  final int requestsBumped; // stale requests dropped
  final int sourceTimeouts; // sources that hit the 8s guard

  final String? notice;
  final PlayMetaCommand? pendingPlay; // the most recent playMeta command

  /// Effects buffer: the reducer appends effects here; the controller drains
  /// them. The one mutable field (impure by convention).
  final List<String> effects;

  SearchState({
    this.query = '',
    this.status = SearchStatus.idle,
    this.tmdbKey,
    this.requestId = 0,
    this.results,
    this.recent = const [],
    this.hideAnime = false,
    this.topMatch,
    this.tmdbMovies = const [],
    this.tmdbSeries = const [],
    this.cineMovies = const [],
    this.cineSeries = const [],
    this.anime = const [],
    this.pending = const {},
    this.requestsBumped = 0,
    this.sourceTimeouts = 0,
    this.notice,
    this.pendingPlay,
    List<String>? effects,
  }) : effects = effects ?? <String>[];

  SearchState copy({
    String? query,
    SearchStatus? status,
    String? tmdbKey,
    bool clearTmdbKey = false,
    int? requestId,
    SearchResults? results,
    bool clearResults = false,
    List<String>? recent,
    bool? hideAnime,
    TopMatch? topMatch,
    bool clearTopMatch = false,
    List<Meta>? tmdbMovies,
    List<Meta>? tmdbSeries,
    List<Meta>? cineMovies,
    List<Meta>? cineSeries,
    List<AnimeHit>? anime,
    Set<Source>? pending,
    int? requestsBumped,
    int? sourceTimeouts,
    String? notice,
    bool clearNotice = false,
    PlayMetaCommand? pendingPlay,
    List<String>? effects,
  }) {
    return SearchState(
      query: query ?? this.query,
      status: status ?? this.status,
      tmdbKey: clearTmdbKey ? null : (tmdbKey ?? this.tmdbKey),
      requestId: requestId ?? this.requestId,
      results: clearResults ? null : (results ?? this.results),
      recent: recent ?? this.recent,
      hideAnime: hideAnime ?? this.hideAnime,
      topMatch: clearTopMatch ? null : (topMatch ?? this.topMatch),
      tmdbMovies: tmdbMovies ?? this.tmdbMovies,
      tmdbSeries: tmdbSeries ?? this.tmdbSeries,
      cineMovies: cineMovies ?? this.cineMovies,
      cineSeries: cineSeries ?? this.cineSeries,
      anime: anime ?? this.anime,
      pending: pending ?? this.pending,
      requestsBumped: requestsBumped ?? this.requestsBumped,
      sourceTimeouts: sourceTimeouts ?? this.sourceTimeouts,
      notice: clearNotice ? null : (notice ?? this.notice),
      pendingPlay: pendingPlay ?? this.pendingPlay,
      effects: effects ?? this.effects,
    );
  }
}

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------

sealed class SearchEvent {
  const SearchEvent();
}

/// The user changed the text. Debounce begins.
class QueryChanged extends SearchEvent {
  final String query;
  const QueryChanged(this.query);
}

/// The host's `tmdbKey` changed in a snapshot: upgrade (or downgrade) an active
/// query. A keyless phone → cinemeta rows only; a key arriving re-runs TMDB.
class KeyChanged extends SearchEvent {
  final String? tmdbKey;
  const KeyChanged(this.tmdbKey);
}

/// The 180ms debounce timer fired for [requestId] (controller dispatches this).
class DebounceFired extends SearchEvent {
  final int requestId;
  const DebounceFired(this.requestId);
}

/// A source settled for [requestId] with [payload] (controller dispatches this).
class SourceResult extends SearchEvent {
  final int requestId;
  final Source source;
  final Object payload; // TmdbSearchPayload | List<Meta> | List<AnimeHit>
  const SourceResult(this.requestId, this.source, this.payload);
}

/// A source hit the 8s guard for [requestId].
class SourceTimedOut extends SearchEvent {
  final int requestId;
  final Source source;
  const SourceTimedOut(this.requestId, this.source);
}

/// Record the current query in `recent` (capped at [maxRecent]).
class Submit extends SearchEvent {
  const Submit();
}

/// Clear the query and drop the results.
class Clear extends SearchEvent {
  const Clear();
}

/// Parental toggle: hide anime results (and stop anime-wins from firing).
class ToggleHideAnime extends SearchEvent {
  const ToggleHideAnime();
}

/// The user tapped a result / pressed play: encode the playMeta command.
class PlayMeta extends SearchEvent {
  final Meta meta;
  final int? season;
  final int? episode;
  const PlayMeta(this.meta, {this.season, this.episode});
}

// ---------------------------------------------------------------------------
// Helpers (ported from beta)
// ---------------------------------------------------------------------------

String normalizeKey(String s) =>
    s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();

String normShow(String s) => normalizeKey(s);

/// mergeMetas: dedupe by id, primary wins, cap. (search-addons.ts:73-82)
List<Meta> mergeMetas(List<Meta> primary, List<Meta> extra, [int cap = mergeCap]) {
  final seen = <String>{};
  final out = <Meta>[];
  for (final m in primary) {
    if (m.id.isEmpty || seen.add(m.id)) out.add(m);
  }
  for (final m in extra) {
    if (m.id.isNotEmpty && !seen.add(m.id)) continue;
    out.add(m);
  }
  return out.take(cap).toList();
}

/// dedupeByTitle: same normalized title only survives when the two entries have
/// DIFFERENT years (a remake). (search-context.tsx:72-98)
List<Meta> dedupeByTitle(List<Meta> list) {
  final seen = <String, List<Meta>>{};
  final out = <Meta>[];
  for (final m in list) {
    final key = normalizeKey(m.name);
    if (key.isEmpty) {
      out.add(m);
      continue;
    }
    final bucket = seen[key];
    if (bucket == null) {
      seen[key] = [m];
      out.add(m);
      continue;
    }
    final year = (m.releaseInfo ?? '').sliceYear();
    final clashes = bucket.any((prev) {
      final prevYear = (prev.releaseInfo ?? '').sliceYear();
      return year.isEmpty || prevYear.isEmpty || year == prevYear;
    });
    if (clashes) continue; // drop the duplicate title
    bucket.add(m);
    out.add(m);
  }
  return out;
}

extension on String {
  String sliceYear() => length >= 4 ? substring(0, 4) : this;
}

/// interleave: zip two lists, dedupe by id. (mobile-search.tsx:63-76)
List<Meta> interleave(List<Meta> a, List<Meta> b) {
  final out = <Meta>[];
  final seen = <String>{};
  final n = a.length > b.length ? a.length : b.length;
  for (var i = 0; i < n; i++) {
    for (final m in [i < a.length ? a[i] : null, i < b.length ? b[i] : null]) {
      if (m != null && seen.add(m.id)) out.add(m);
    }
  }
  return out;
}

/// The pinned top-match merge: an anime hit whose name matches the TMDB top
/// match replaces the TMDB meta (search-context.tsx:304-330). The match can be
/// anywhere in the anime list, not just first.
TopMatch? mergeTopMatch(TopMatch? base, List<AnimeHit> anime) {
  if (base == null || anime.isEmpty) return base;
  AnimeHit? top;
  for (final a in anime) {
    if (normShow(a.name) == normShow(base.meta.name)) {
      top = a;
      break;
    }
  }
  if (top == null) return base;
  return TopMatch(
    kind: top.kind,
    meta: Meta(
      id: top.metaId,
      type: 'anime',
      name: top.name,
      poster: top.poster ?? base.meta.poster,
      background: top.background ?? base.meta.background,
      description: top.overview.isNotEmpty ? top.overview : base.meta.description,
      releaseInfo: top.year,
    ),
    popularity: base.popularity,
    backdrop: top.background ?? base.backdrop,
    overview: top.overview.isNotEmpty ? top.overview : base.overview,
    voteAverage: base.voteAverage,
  );
}

/// notAnimeDupe: a movie/series whose title exactly matches an anime hit is
/// dropped from the film lists (anime wins). (search-context.tsx:289-291)
bool notAnimeDupe(Meta m, Set<String> animeTitles) {
  if (animeTitles.isEmpty) return true;
  return !animeTitles.contains(normShow(m.name));
}

// ---------------------------------------------------------------------------
// Reducer
// ---------------------------------------------------------------------------

SearchState searchReduce(SearchState s, SearchEvent e) {
  switch (e) {
    case QueryChanged(query: final q):
      return _onQueryChanged(s, q);
    case KeyChanged(tmdbKey: final key):
      return _onKeyChanged(s, key);
    case DebounceFired(requestId: final id):
      return _onDebounceFired(s, id);
    case SourceResult(requestId: final id, source: final src, payload: final p):
      return _onSourceResult(s, id, src, p);
    case SourceTimedOut(requestId: final id, source: final src):
      return _onSourceTimeout(s, id, src);
    case Submit():
      return _onSubmit(s);
    case Clear():
      return _onClear(s);
    case ToggleHideAnime():
      final next =
          s.copy(hideAnime: !s.hideAnime, notice: 'hide anime: ${!s.hideAnime}');
      return s.results == null ? next : _publish(next);
    case PlayMeta(meta: final m, season: final season, episode: final episode):
      final command = PlayMetaCommand(
        metaId: m.id,
        metaType: coerceMetaType(m.type),
        name: m.name,
        poster: m.poster,
        season: season,
        episode: episode,
      );
      s.effects.add('playMeta');
      return s.copy(
        pendingPlay: command,
        notice: 'playMeta enqueued → ${m.name}',
      );
  }
}

/// Resets the per-request accumulators for a fresh request, returning the new
/// base state (the caller sets query/status/requestId/notice on top).
SearchState _clearAccumulators(SearchState s) => s.copy(
      clearResults: true,
      clearTopMatch: true,
      tmdbMovies: const [],
      tmdbSeries: const [],
      cineMovies: const [],
      cineSeries: const [],
      anime: const [],
      pending: const {},
    );

SearchState _onQueryChanged(SearchState s, String q) {
  final trimmed = q.trim();
  final id = s.requestId + 1;
  final base = _clearAccumulators(s).copy(requestId: id, query: q);
  if (trimmed.isEmpty) {
    return base.copy(
      status: SearchStatus.idle,
      notice: 'idle — no query',
    );
  }
  s.effects.add('debounce:$id');
  return base.copy(
    status: SearchStatus.typing,
    notice: 'typing → debounce ${debounceDelay.inMilliseconds}ms',
  );
}

SearchState _onKeyChanged(SearchState s, String? key) {
  if (key == s.tmdbKey) return s.copy(notice: 'tmdbKey unchanged');
  final applied = s.copy(
    tmdbKey: key,
    clearTmdbKey: key == null,
    notice: 'tmdbKey ${key == null ? 'removed' : 'arrived'}',
  );
  if (s.query.trim().isEmpty) return applied;
  // Re-run the active query under the new key (keyless → cinemeta only; a key
  // arriving → TMDB joins the fan-out).
  final id = s.requestId + 1;
  s.effects.add('debounce:$id');
  return _clearAccumulators(applied).copy(
    requestId: id,
    status: SearchStatus.typing,
    notice: 'tmdbKey ${key == null ? 'removed' : 'arrived'} → re-running query',
  );
}

SearchState _onDebounceFired(SearchState s, int id) {
  if (id != s.requestId) {
    return s.copy(
      requestsBumped: s.requestsBumped + 1,
      notice: 'debounce stale (req $id) — dropped',
    );
  }
  final query = s.query.trim();
  final fired = <Source>{};
  if (s.tmdbKey != null) {
    s.effects.add('fetch:tmdb:$id:$query');
    fired.add(Source.tmdb);
  }
  s.effects.add('fetch:cinemeta:$id:$query');
  fired.add(Source.cinemeta);
  s.effects.add('fetch:jikan:$id:$query');
  fired.add(Source.jikan);
  return s.copy(
    status: SearchStatus.loading,
    pending: fired,
    notice: 'loading — ${fired.length} sources fired',
  );
}

SearchState _onSourceResult(SearchState s, int id, Source src, Object payload) {
  if (id != s.requestId) {
    return s.copy(
      requestsBumped: s.requestsBumped + 1,
      notice: 'stale ${src.name} result (req $id) — dropped',
    );
  }
  if (!s.pending.contains(src)) {
    return s.copy(
      requestsBumped: s.requestsBumped + 1,
      notice: 'late ${src.name} result (already settled) — dropped',
    );
  }
  var next = s.copy(
    pending: {...s.pending}..remove(src),
    notice: '${src.name} landed',
  );
  switch (src) {
    case Source.tmdb:
      final tmdb = payload as TmdbSearchPayload;
      next = next.copy(
        tmdbMovies: tmdb.movies,
        tmdbSeries: tmdb.series,
        topMatch: tmdb.topMatch,
      );
      break;
    case Source.cinemeta:
      final cine = (payload as List).whereType<Meta>().toList();
      next = next.copy(
        cineMovies: cine.where((m) => m.type == 'movie').toList(),
        cineSeries: cine.where((m) => m.type == 'series').toList(),
      );
      break;
    case Source.jikan:
      next = next.copy(anime: (payload as List).whereType<AnimeHit>().toList());
      break;
  }
  return _publish(next);
}

SearchState _onSourceTimeout(SearchState s, int id, Source src) {
  if (id != s.requestId) {
    return s.copy(
      requestsBumped: s.requestsBumped + 1,
      notice: 'stale ${src.name} timeout (req $id)',
    );
  }
  if (!s.pending.contains(src)) {
    return s.copy(notice: 'late ${src.name} timeout — dropped');
  }
  final next = s.copy(
    pending: {...s.pending}..remove(src),
    sourceTimeouts: s.sourceTimeouts + 1,
    notice: '${src.name} timed out (${sourceTimeout.inMilliseconds}ms guard) — empty',
  );
  return _publish(next);
}

SearchState _publish(SearchState s) {
  final anime = s.hideAnime ? const <AnimeHit>[] : s.anime;
  final animeTitles = {for (final a in anime) normShow(a.name)};
  // Merge order (spec): TMDB base + cinemeta appended (dedupe by id) →
  // dedupe by normalized title + year → anime-wins over colliding film rows.
  final movies = dedupeByTitle(mergeMetas(s.tmdbMovies, s.cineMovies))
      .where((m) => notAnimeDupe(m, animeTitles))
      .toList();
  final series = dedupeByTitle(mergeMetas(s.tmdbSeries, s.cineSeries))
      .where((m) => notAnimeDupe(m, animeTitles))
      .toList();
  final top = s.hideAnime ? s.topMatch : mergeTopMatch(s.topMatch, s.anime);

  final done = s.pending.isEmpty;
  return s.copy(
    status: done ? SearchStatus.done : SearchStatus.loading,
    results: SearchResults(
      query: s.query.trim(),
      topMatch: top,
      movies: movies,
      series: series,
      anime: anime,
    ),
    clearNotice: true,
  );
}

SearchState _onSubmit(SearchState s) {
  final q = s.query.trim();
  if (q.isEmpty) return s.copy(notice: 'nothing to record');
  final next = [
    q,
    ...s.recent.where((r) => r.toLowerCase() != q.toLowerCase()),
  ].take(maxRecent).toList();
  return s.copy(recent: next, notice: 'recent recorded');
}

SearchState _onClear(SearchState s) {
  final id = s.requestId + 1;
  return _clearAccumulators(s).copy(
    query: '',
    status: SearchStatus.idle,
    requestId: id,
    clearNotice: true,
    notice: 'cleared',
  );
}
