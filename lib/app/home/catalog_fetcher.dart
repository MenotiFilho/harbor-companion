// Catalog HTTP seam (ticket 04).
//
// Home rows and detail come from two public sources, never from Harbor:
//   - Cinemeta (`https://v3-cinemeta.strem.io`, keyless) as the fallback.
//   - TMDB (`https://api.themoviedb.org/3`, keyed by `snapshot.tmdbKey`).
//
// `CatalogFetcher` is the seam the controller drains `fetch:rows` /
// `fetch:detail` effects into; tests inject a fake. The real implementation
// (dart:io) hits the upstreams directly — there is no `/api-proxy` on the LAN
// (wire-contract §5, §6). The pure JSON→model mappers are top-level so tests
// pin the wire shapes without network.
//
// Wire contract: docs/wire-contract.md §5.1 (Cinemeta), §5.2 (TMDB).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'meta.dart';

const String cinemetaBase = 'https://v3-cinemeta.strem.io';
const String tmdbBase = 'https://api.themoviedb.org/3';
const String tmdbImageBase = 'https://image.tmdb.org/t/p';

/// A single-row spec: endpoint path, result type, and display title.
class _RowSpec {
  final String path;
  final String type;
  final String title;
  const _RowSpec(this.path, this.type, this.title);
}

/// Cinemeta rows: top movie/series plus genre rails. The genre rails mirror the
/// beta mobile home's fallback (wire-contract §5.1 known genres).
const List<_RowSpec> _cinemetaRows = [
  _RowSpec('/catalog/movie/top.json', 'movie', 'Top Movies'),
  _RowSpec('/catalog/series/top.json', 'series', 'Top Series'),
  _RowSpec('/catalog/movie/top/genre=Action.json', 'movie', 'Action'),
  _RowSpec('/catalog/movie/top/genre=Drama.json', 'movie', 'Drama'),
  _RowSpec('/catalog/movie/top/genre=Comedy.json', 'movie', 'Comedy'),
  _RowSpec('/catalog/movie/top/genre=Sci-Fi.json', 'movie', 'Sci-Fi'),
  _RowSpec('/catalog/movie/top/genre=Animation.json', 'movie', 'Animation'),
  _RowSpec('/catalog/movie/top/genre=Thriller.json', 'movie', 'Thriller'),
  _RowSpec('/catalog/series/top/genre=Drama.json', 'series', 'Series Drama'),
  _RowSpec('/catalog/series/top/genre=Comedy.json', 'series', 'Series Comedy'),
];

/// TMDB rows (keyed): trending, movie/tv catalog rows, discover. Mirrors the
/// beta mobile home (`tmdb-catalogs.ts`) — wire-contract §5.2.
const List<_RowSpec> _tmdbRows = [
  _RowSpec('/trending/movie/week', 'movie', 'Trending Movies'),
  _RowSpec('/trending/tv/week', 'series', 'Trending Series'),
  _RowSpec('/movie/popular', 'movie', 'Popular Movies'),
  _RowSpec('/movie/top_rated', 'movie', 'Top Rated Movies'),
  _RowSpec('/movie/now_playing', 'movie', 'Now Playing'),
  _RowSpec('/movie/upcoming', 'movie', 'Upcoming'),
  _RowSpec('/tv/popular', 'series', 'Popular Series'),
  _RowSpec('/tv/top_rated', 'series', 'Top Rated Series'),
  _RowSpec('/tv/on_the_air', 'series', 'On The Air'),
  _RowSpec('/discover/movie', 'movie', 'Discover Movies'),
  _RowSpec('/discover/tv', 'series', 'Discover Series'),
];

// ---------------------------------------------------------------------------
// Pure mappers (pinned to the upstream JSON shapes; tested without network)
// ---------------------------------------------------------------------------

Meta _parseCinemetaMeta(Map<String, dynamic> j) {
  final type = j['type'] == 'series' ? 'series' : 'movie';
  return Meta(
    id: j['id'] as String? ?? '',
    type: type,
    name: j['name'] as String? ?? '',
    poster: j['poster'] as String?,
    background: j['background'] as String?,
    description: j['description'] as String?,
    releaseInfo: j['releaseInfo'] as String?,
  );
}

/// Parses a Cinemeta catalog response `{ "metas": [...] }`.
List<Meta> parseCinemetaCatalog(String raw) {
  final decoded = jsonDecode(raw);
  if (decoded is! Map<String, dynamic>) return const [];
  final metas = decoded['metas'];
  if (metas is! List) return const [];
  return [
    for (final m in metas)
      if (m is Map<String, dynamic>) _parseCinemetaMeta(m),
  ];
}

String? tmdbPoster(String? path) => path == null ? null : '$tmdbImageBase/w342$path';
String? tmdbBackdrop(String? path) => path == null ? null : '$tmdbImageBase/w780$path';

Meta parseTmdbMeta(Map<String, dynamic> j, String type) {
  final isSeries = type == 'series';
  final name = (isSeries ? j['name'] : j['title']) as String? ?? '';
  final date = (isSeries ? j['first_air_date'] : j['release_date']) as String?;
  return Meta(
    id: 'tmdb:${j['id']}',
    type: type,
    name: name,
    poster: tmdbPoster(j['poster_path'] as String?),
    background: tmdbBackdrop(j['backdrop_path'] as String?),
    description: j['overview'] as String?,
    releaseInfo: (date is String && date.length >= 4) ? date.substring(0, 4) : null,
  );
}

/// Parses a TMDB paged response `{ "results": [...] }`.
List<Meta> parseTmdbPage(String raw, String type) {
  final decoded = jsonDecode(raw);
  if (decoded is! Map<String, dynamic>) return const [];
  final results = decoded['results'];
  if (results is! List) return const [];
  return [
    for (final r in results)
      if (r is Map<String, dynamic>) parseTmdbMeta(r, type),
  ];
}

/// Parses a Cinemeta detail response `{ "meta": {...} }`, deriving seasons from
/// the `videos[]` array (each video carries season/episode) — the keyless path.
DetailMeta parseCinemetaDetail(String raw) {
  final decoded = jsonDecode(raw);
  if (decoded is! Map<String, dynamic>) return DetailMeta(meta: const Meta(id: '', type: 'movie', name: ''));
  final metaJ = decoded['meta'];
  final meta = metaJ is Map<String, dynamic>
      ? _parseCinemetaMeta(metaJ)
      : const Meta(id: '', type: 'movie', name: '');
  final videos = metaJ is Map<String, dynamic> ? metaJ['videos'] : null;
  return DetailMeta(meta: meta, seasons: _seasonsFromVideos(videos));
}

List<Season> _seasonsFromVideos(Object? videos) {
  if (videos is! List) return const [];
  final bySeason = <int, List<Episode>>{};
  for (final v in videos) {
    if (v is! Map<String, dynamic>) continue;
    final season = (v['season'] as num?)?.toInt();
    final episode = (v['episode'] as num?)?.toInt();
    if (season == null || episode == null) continue;
    bySeason.putIfAbsent(season, () => []).add(Episode(
          season: season,
          episode: episode,
          name: v['name'] as String? ?? 'Episode $episode',
          overview: v['overview'] as String?,
          still: v['thumbnail'] as String?,
        ));
  }
  final seasons = <Season>[
    for (final entry in bySeason.entries)
      Season(
        number: entry.key,
        name: 'Season ${entry.key}',
        episodes: entry.value..sort((a, b) => a.episode.compareTo(b.episode)),
      ),
  ]..sort((a, b) => a.number.compareTo(b.number));
  return seasons;
}

/// Parses a TMDB detail response into a [Meta] (no seasons — the episode list
/// is fetched per-season). `type` is "movie" or "series".
Meta parseTmdbDetail(String raw, String type) {
  final decoded = jsonDecode(raw);
  if (decoded is! Map<String, dynamic>) return const Meta(id: '', type: 'movie', name: '');
  return parseTmdbMeta(decoded, type);
}

/// Parses a TMDB `tv/{id}/season/{n}` response `{ "episodes": [...] }`.
List<Episode> parseTmdbSeasonEpisodes(String raw, int seasonNumber) {
  final decoded = jsonDecode(raw);
  if (decoded is! Map<String, dynamic>) return const [];
  final episodes = decoded['episodes'];
  if (episodes is! List) return const [];
  return [
    for (final e in episodes)
      if (e is Map<String, dynamic>)
        Episode(
          season: (e['season_number'] as num?)?.toInt() ?? seasonNumber,
          episode: (e['episode_number'] as num?)?.toInt() ?? 0,
          name: e['name'] as String? ?? 'Episode ${e['episode_number']}',
          overview: e['overview'] as String?,
          still: tmdbPoster(e['still_path'] as String?),
        ),
  ]..sort((a, b) => a.episode.compareTo(b.episode));
}

/// Loads episodes for each season shell concurrently and returns the seasons
/// with episodes filled, in shell order. `fetchEpisodes` never throws (a
/// failed season yields `[]`), so a season can resolve empty — the UI skips
/// empty seasons. Concurrent so a many-season series resolves in roughly one
/// round-trip instead of one per season.
Future<List<Season>> loadTmdbSeasonEpisodes(
  List<Season> shells,
  Future<List<Episode>> Function(int season) fetchEpisodes,
) async {
  final episodes = await Future.wait([
    for (final season in shells) fetchEpisodes(season.number),
  ]);
  return [
    for (var i = 0; i < shells.length; i++)
      Season(
        number: shells[i].number,
        name: shells[i].name,
        poster: shells[i].poster,
        episodes: episodes[i],
      ),
  ];
}

/// Parses a TMDB `tv/{id}` response's `seasons` array into [Season] shells
/// (episodes filled separately). Season 0 (specials) is dropped.
List<Season> parseTmdbSeasons(String raw) {
  final decoded = jsonDecode(raw);
  if (decoded is! Map<String, dynamic>) return const [];
  final seasons = decoded['seasons'];
  if (seasons is! List) return const [];
  return [
    for (final s in seasons)
      if (s is Map<String, dynamic> && (s['season_number'] as num?)?.toInt() != 0)
        Season(
          number: (s['season_number'] as num?)?.toInt() ?? 0,
          name: s['name'] as String? ?? 'Season ${s['season_number']}',
          poster: tmdbPoster(s['poster_path'] as String?),
        ),
  ]..sort((a, b) => a.number.compareTo(b.number));
}

// ---------------------------------------------------------------------------
// Fetcher seam + real implementation
// ---------------------------------------------------------------------------

/// True when a title's detail should come from TMDB: a key is present AND the
/// id is `tmdb:`-prefixed. An imdb id (Cinemeta rows, library items) routes to
/// Cinemeta even when keyed — TMDB's detail endpoints only accept numeric ids,
/// so an imdb id there would 404 (e.g. a series opened from My Stuff).
bool usesTmdbDetail(String? tmdbKey, String id) =>
    tmdbKey != null && id.startsWith('tmdb:');

/// Fetches home rows and detail from Cinemeta/TMDB. Injected into the home
/// controller; tests provide a fake.
abstract interface class CatalogFetcher {
  /// Home rows: TMDB when [tmdbKey] is set, else Cinemeta. A row whose fetch
  /// fails is skipped; the list only carries rows that loaded.
  Future<List<HomeRow>> fetchRows(String? tmdbKey);

  /// Detail for a title: Cinemeta `meta/{type}/{id}` when keyless, TMDB detail
  /// + per-season episodes when keyed.
  Future<DetailMeta> fetchDetail(String type, String id, String? tmdbKey);
}

/// Real catalog fetcher over dart:io HTTP. No `/api-proxy` — the phone hits the
/// upstreams directly (wire-contract §6).
class HttpCatalogFetcher implements CatalogFetcher {
  final Duration timeout;

  HttpCatalogFetcher({this.timeout = const Duration(seconds: 8)});

  @override
  Future<List<HomeRow>> fetchRows(String? tmdbKey) async {
    final specs = tmdbKey == null ? _cinemetaRows : _tmdbRows;
    final results = await Future.wait([
      for (final spec in specs) _fetchRow(spec, tmdbKey),
    ]);
    final rows = [
      for (final (spec, metas) in results)
        if (metas.isNotEmpty) HomeRow(spec.title, metas),
    ];
    // Every row failed (e.g. no network): surface an error so the UI shows the
    // retry state rather than a blank "ready" grid.
    if (rows.isEmpty) {
      throw const HttpException('no catalog rows loaded');
    }
    return rows;
  }

  Future<(_RowSpec, List<Meta>)> _fetchRow(_RowSpec spec, String? tmdbKey) async {
    try {
      final url = tmdbKey == null
          ? '$cinemetaBase${spec.path}'
          : '$tmdbBase${spec.path}?api_key=$tmdbKey';
      final raw = await _get(Uri.parse(url));
      final metas =
          tmdbKey == null ? parseCinemetaCatalog(raw) : parseTmdbPage(raw, spec.type);
      return (spec, metas);
    } catch (_) {
      return (spec, const <Meta>[]);
    }
  }

  @override
  Future<DetailMeta> fetchDetail(String type, String id, String? tmdbKey) async {
    if (!usesTmdbDetail(tmdbKey, id)) {
      final raw = await _get(Uri.parse('$cinemetaBase/meta/$type/$id.json'));
      return parseCinemetaDetail(raw);
    }
    final key = tmdbKey!;
    final idNum = id.substring('tmdb:'.length);
    if (type == 'movie') {
      final raw = await _get(Uri.parse('$tmdbBase/movie/$idNum?api_key=$key'));
      return DetailMeta(meta: parseTmdbDetail(raw, 'movie'));
    }
    final raw = await _get(Uri.parse('$tmdbBase/tv/$idNum?api_key=$key'));
    final meta = parseTmdbDetail(raw, 'series');
    final seasons = await loadTmdbSeasonEpisodes(
      parseTmdbSeasons(raw),
      (season) => _tmdbEpisodes(idNum, season, key),
    );
    return DetailMeta(meta: meta, seasons: seasons);
  }

  Future<List<Episode>> _tmdbEpisodes(String id, int season, String key) async {
    try {
      final raw = await _get(Uri.parse('$tmdbBase/tv/$id/season/$season?api_key=$key'));
      return parseTmdbSeasonEpisodes(raw, season);
    } catch (_) {
      return const [];
    }
  }

  Future<String> _get(Uri url) async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final request = await client.getUrl(url);
      final response = await request.close().timeout(timeout);
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('HTTP ${response.statusCode} for $url');
      }
      return await response.transform(utf8.decoder).join();
    } finally {
      client.close(force: true);
    }
  }
}
