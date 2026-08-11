// Throwaway logic prototype — Harbor mobile Search state model.
//
// QUESTION THIS PROTOTYPE ANSWERS:
//   Does the Search state model feel right — 180ms debounce with a request
//   guard, parallel source fan-out (TMDB-if-key / Cinemeta-merge / Jikan anime)
//   each with its own timeout, INCREMENTAL publish as sources land, the
//   merge/dedupe/anime-wins semantics, and the results → detail → playMeta
//   flow? Not the visuals.
//
// This module is PURE and portable: no I/O, no timers, no terminal code. It is
// a reducer `(SearchState, SearchEvent) => SearchState`. Impurities are the
// effects buffers the shell must honor:
//   - `effects`: things the shell must do (run a debounce timer, fire a source
//     fetch, send a wire frame). The shell drains it after every reduce.
//   - `metaCache`-free: caches live in the shell/fetch layer, not here.
//
// Semantics mirror the beta reference exactly (src/lib/search-context.tsx,
// src/lib/search.ts, src/views/mobile/mobile-search.tsx), minus out-of-scope
// sources (addons, manga, characters, liveTV). Jikan is modelled as ONE source
// that rides a 400ms-serialized throttle (see wire-contract §5.3; beta's search
// call is unthrottled but our Home catalog uses the throttled jikanQuery and the
// two must share one queue to avoid 429s).

library;

import 'dart:convert';

const Duration debounceDelay = Duration(milliseconds: 180);
const Duration sourceTimeout = Duration(milliseconds: 8000);
const int maxRecent = 8;
const int capPerKind = 12; // cinemeta search caps results to 12/kind
const int mergeCap = 20;

enum SearchStatus { idle, typing, loading, done }

enum Source { tmdb, cinemeta, jikan }

const Set<Source> allSources = {Source.tmdb, Source.cinemeta, Source.jikan};

// ---------------------------------------------------------------------------
// Meta model (a search result / playable title)
// ---------------------------------------------------------------------------

class Meta {
  final String id;
  final String type; // "movie" | "series" | "anime"
  final String name;
  final String? poster;
  final String? background;
  final String? releaseInfo; // year-ish string, for title-dedupe
  final String? description;
  const Meta({
    required this.id,
    required this.type,
    required this.name,
    this.poster,
    this.background,
    this.releaseInfo,
    this.description,
  });
}

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
}

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

  /// What the mobile grid renders: topMatch pinned first, then movies/series
  /// interleaved (mobile-search.tsx:143-149).
  List<Meta> get grid {
    final out = <Meta>[];
    if (topMatch != null) out.add(topMatch!.meta);
    final seen = <String>{};
    final inter = interleave(movies, series);
    for (final m in inter) {
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
  final bool tmdbSettled;

  // Observability counters (for the shell / honest notes).
  final int requestsBumped; // stale requests dropped
  final int sourceTimeouts; // sources that hit the 8s guard

  final String? notice;
  final String? lastPlayMeta; // last encoded playMeta wire frame

  // Effects buffer: the shell drains after every reduce. Entries are strings:
  //   "debounce:<id>"            → start a 180ms timer, then dispatch DebounceFired
  //   "fetch:<tmdb|cinemeta|jikan>:<id>:<query>" → run the source, dispatch SourceResult
  //   "send:<json frame>"        → send a wire frame to the WS host
  final List<String> effects;

  SearchState({
    this.query = '',
    this.status = SearchStatus.idle,
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
    this.tmdbSettled = false,
    this.requestsBumped = 0,
    this.sourceTimeouts = 0,
    this.notice,
    this.lastPlayMeta,
    List<String>? effects,
  }) : effects = effects ?? <String>[];

  SearchState copy({
    String? query,
    SearchStatus? status,
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
    bool? tmdbSettled,
    int? requestsBumped,
    int? sourceTimeouts,
    String? notice,
    bool clearNotice = false,
    String? lastPlayMeta,
    bool clearLastPlayMeta = false,
    List<String>? effects,
  }) {
    return SearchState(
      query: query ?? this.query,
      status: status ?? this.status,
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
      tmdbSettled: tmdbSettled ?? this.tmdbSettled,
      requestsBumped: requestsBumped ?? this.requestsBumped,
      sourceTimeouts: sourceTimeouts ?? this.sourceTimeouts,
      notice: clearNotice ? null : (notice ?? this.notice),
      lastPlayMeta: clearLastPlayMeta ? null : (lastPlayMeta ?? this.lastPlayMeta),
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

/// The 180ms debounce timer fired for [requestId] (shell dispatches this).
class DebounceFired extends SearchEvent {
  final int requestId;
  const DebounceFired(this.requestId);
}

/// A source settled for [requestId] with [payload] (shell dispatches this).
class SourceResult extends SearchEvent {
  final int requestId;
  final Source source;
  final Object payload; // List<Meta> (tmdb/cinemeta) or List<AnimeHit> (jikan)
  const SourceResult(this.requestId, this.source, this.payload);
}

/// A source hit the 8s guard for [requestId].
class SourceTimedOut extends SearchEvent {
  final int requestId;
  final Source source;
  const SourceTimedOut(this.requestId, this.source);
}

class Submit extends SearchEvent {
  const Submit();
}

class Clear extends SearchEvent {
  const Clear();
}

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
/// match replaces the TMDB meta (search-context.tsx:304-330).
TopMatch? mergeTopMatch(TopMatch? base, List<AnimeHit> anime) {
  if (base == null || anime.isEmpty) return base;
  final top = anime.first;
  if (normShow(base.meta.name) != normShow(top.name)) return base;
  return TopMatch(
    kind: top.kind,
    meta: Meta(
      id: top.metaId,
      type: top.kind,
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

SearchState reduce(SearchState s, SearchEvent e) {
  switch (e) {
    case QueryChanged(query: final q):
      return _onQueryChanged(s, q);
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
      final next = s.copy(hideAnime: !s.hideAnime, notice: 'hide anime: ${!s.hideAnime}');
      return s.results == null ? next : _publish(next);
    case PlayMeta(meta: final m, season: final season, episode: final episode):
      final frame = encodePlayMeta(m, season: season, episode: episode);
      s.effects.add('send:$frame');
      return s.copy(
        notice: 'playMeta enqueued → ${m.name}',
        lastPlayMeta: frame,
      );
  }
}

SearchState _onQueryChanged(SearchState s, String q) {
  final trimmed = q.trim();
  final id = s.requestId + 1;
  s.effects.add('debounce:$id');
  if (trimmed.isEmpty) {
    return s.copy(
      query: q,
      status: SearchStatus.idle,
      requestId: id,
      clearResults: true,
      clearTopMatch: true,
      tmdbMovies: const [],
      tmdbSeries: const [],
      cineMovies: const [],
      cineSeries: const [],
      anime: const [],
      pending: const {},
      tmdbSettled: false,
      notice: 'idle — no query',
    );
  }
  return s.copy(
    query: q,
    status: SearchStatus.typing,
    requestId: id,
    clearResults: true,
    clearTopMatch: true,
    tmdbMovies: const [],
    tmdbSeries: const [],
    cineMovies: const [],
    cineSeries: const [],
    anime: const [],
    pending: const {},
    tmdbSettled: false,
    notice: 'typing → debounce 180ms',
  );
}

SearchState _onDebounceFired(SearchState s, int id) {
  if (id != s.requestId) {
    return s.copy(requestsBumped: s.requestsBumped + 1, notice: 'debounce stale (req $id) — dropped');
  }
  // Fan out to all three sources in parallel; each fetch is an effect.
  for (final src in allSources) {
    s.effects.add('fetch:${src.name}:$id:${s.query.trim()}');
  }
  return s.copy(
    status: SearchStatus.loading,
    pending: {...allSources},
    notice: 'loading — ${allSources.length} sources fired',
  );
}

SearchState _onSourceResult(SearchState s, int id, Source src, Object payload) {
  if (id != s.requestId) {
    return s.copy(requestsBumped: s.requestsBumped + 1, notice: 'stale ${src.name} result (req $id) — dropped');
  }
  var next = s.copy(
    pending: {...s.pending}..remove(src),
    notice: '${src.name} landed',
  );
  switch (src) {
    case Source.tmdb:
      final metas = (payload as List).whereType<Meta>().toList();
      final isMovie = (m) => m.type == 'movie';
      next = next.copy(
        tmdbMovies: metas.where(isMovie).toList(),
        tmdbSeries: metas.where((m) => !isMovie(m)).toList(),
        tmdbSettled: true,
      );
      if (metas.isNotEmpty) {
        // TMDB drives the top match: highest popularity with a poster. The sim
        // returns the top match first (index 0) — the shell model keeps it
        // simple; the real app derives it from search/multi popularity.
        next = next.copy(topMatch: TopMatch(kind: metas.first.type, meta: metas.first));
      }
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
    return s.copy(requestsBumped: s.requestsBumped + 1, notice: 'stale ${src.name} timeout (req $id)');
  }
  final next = s.copy(
    pending: {...s.pending}..remove(src),
    sourceTimeouts: s.sourceTimeouts + 1,
    tmdbSettled: src == Source.tmdb ? true : s.tmdbSettled,
    notice: '${src.name} timed out (8s guard) — empty',
  );
  return _publish(next);
}

SearchState _publish(SearchState s) {
  // Merge: TMDB base, then cinemeta appended (dedupe by id), then title-dedupe,
  // then drop titles that collide with an anime hit.
  final animeTitles = {for (final a in s.anime) normShow(a.name)};
  final movies = dedupeByTitle(
    mergeMetas(s.tmdbMovies, s.cineMovies).where((m) => notAnimeDupe(m, animeTitles)).toList(),
  );
  final series = dedupeByTitle(
    mergeMetas(s.tmdbSeries, s.cineSeries).where((m) => notAnimeDupe(m, animeTitles)).toList(),
  );
  final top = mergeTopMatch(s.topMatch, s.anime);

  final done = s.pending.isEmpty;
  return s.copy(
    status: done ? SearchStatus.done : SearchStatus.loading,
    results: SearchResults(
      query: s.query.trim(),
      topMatch: top,
      movies: movies,
      series: series,
      anime: s.anime,
    ),
    clearNotice: true,
  );
}

SearchState _onSubmit(SearchState s) {
  final q = s.query.trim();
  if (q.isEmpty) return s.copy(notice: 'nothing to record');
  final next = [q, ...s.recent.where((r) => r.toLowerCase() != q.toLowerCase())].take(maxRecent).toList();
  return s.copy(recent: next, notice: 'recent recorded');
}

SearchState _onClear(SearchState s) {
  final id = s.requestId + 1;
  return s.copy(
    query: '',
    status: SearchStatus.idle,
    requestId: id,
    clearResults: true,
    clearTopMatch: true,
    tmdbMovies: const [],
    tmdbSeries: const [],
    cineMovies: const [],
    cineSeries: const [],
    anime: const [],
    pending: const {},
    tmdbSettled: false,
    notice: 'cleared',
  );
}

// ---------------------------------------------------------------------------
// Wire encoding (client → host)
// ---------------------------------------------------------------------------

/// Encodes playMeta exactly as the beta reference (mobile-remote.tsx:53-68,
/// protocol.ts:177-180): resume defaults true.
String encodePlayMeta(Meta m, {int? season, int? episode}) {
  final cmd = <String, dynamic>{
    'action': 'playMeta',
    'metaId': m.id,
    'metaType': m.type == 'anime' ? 'series' : m.type,
    'name': m.name,
    'resume': true,
    if (m.poster != null) 'poster': m.poster,
    if (season != null) 'season': season,
    if (episode != null) 'episode': episode,
  };
  return jsonEncode({'t': 'cmd', 'command': cmd});
}
