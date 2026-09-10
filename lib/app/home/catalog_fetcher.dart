// Catalog HTTP seam (tickets 04, 41).
//
// Home rows and detail come from public sources, never from Harbor:
//   - Cinemeta (`https://v3-cinemeta.strem.io`, keyless) as the fallback.
//   - TMDB (`https://api.themoviedb.org/3`, keyed by `snapshot.tmdbKey`).
//   - Stremboxd (`https://api.stremboxd.com/stremio/<token>/…`), the user's
//     Letterboxd rails, only when a manifest URL is configured (ticket 41).
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

import '../letterboxd/letterboxd.dart';
import 'catalog_request.dart';
import 'home_rows.dart';
import 'meta.dart';

const String cinemetaBase = 'https://v3-cinemeta.strem.io';
const String tmdbBase = 'https://api.themoviedb.org/3';
const String tmdbImageBase = 'https://image.tmdb.org/t/p';

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
    // The host's wire expects the kind segment (`tmdb:tv:…` / `tmdb:movie:…`);
    // its `fetchAdjacentEpisodes` only recognizes `tmdb:tv:` for series, so a
    // bare `tmdb:<id>` would fall through to addon resolution and lose the
    // next/prev episode flags.
    id: isSeries ? 'tmdb:tv:${j['id']}' : 'tmdb:movie:${j['id']}',
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

/// The ordered row keys [request] should attempt: the enabled built-in rows for
/// the source in effect (TMDB when keyed, else Cinemeta), plus the enabled
/// Letterboxd catalogs when a manifest URL is set. Pure so tests pin the
/// filtering + order without network. A Letterboxd key survives planning even
/// when the manifest may not list it — the manifest is consulted at fetch time.
List<String> planHomeRowKeys(CatalogRequest request) {
  final activeSource = request.tmdbKey == null ? 'cinemeta' : 'tmdb';
  final letterboxdActive = request.letterboxd.isActive;
  final keys = <String>[];
  for (final key in request.rowOrder) {
    final builtIn = builtInRowById(key);
    if (builtIn != null) {
      if (builtIn.source != activeSource) continue;
      if (request.disabledBuiltInRowKeys.contains(key)) continue;
      keys.add(key);
      continue;
    }
    final catalogId = letterboxdCatalogId(key);
    if (catalogId == null || !letterboxdActive) continue;
    if (!request.letterboxd.enabledCatalogIds.contains(catalogId)) continue;
    keys.add(key);
  }
  return keys;
}

/// Fetches each planned [key] via [fetch], concurrently, preserving order. A key
/// whose fetch throws is skipped — one flaky rail never takes down the rest; a
/// `null` result means "no row" (empty catalog or skipped).
Future<List<HomeRow>> fetchHomeRowsConcurrently(
  List<String> keys,
  Future<HomeRow?> Function(String key) fetch,
) async {
  Future<HomeRow?> safe(String key) async {
    try {
      return await fetch(key);
    } catch (_) {
      return null;
    }
  }

  final results = await Future.wait([for (final key in keys) safe(key)]);
  return [for (final row in results) ?row];
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

/// Fetches home rows and detail from Cinemeta/TMDB/Stremboxd. Injected into the
/// home controller; tests provide a fake.
abstract interface class CatalogFetcher {
  /// Home rows for [request]: TMDB when a key is set, else Cinemeta (unless the
  /// built-in rails are switched off), plus the enabled Letterboxd rails. A row
  /// whose fetch fails is skipped; the list only carries rows that loaded.
  Future<List<HomeRow>> fetchRows(CatalogRequest request);

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
  Future<List<HomeRow>> fetchRows(CatalogRequest request) async {
    final keys = planHomeRowKeys(request);

    // Resolve the Letterboxd manifest once, up front: catalog names + types come
    // from it, and one bad manifest must only drop the Letterboxd rails.
    var catalogsById = const <String, LetterboxdCatalog>{};
    if (keys.any(isLetterboxdRowKey)) {
      try {
        final raw = await _get(Uri.parse(request.letterboxd.manifestUrl.trim()));
        catalogsById = {
          for (final catalog in parseLetterboxdManifest(raw).catalogs)
            catalog.id: catalog,
        };
      } catch (_) {
        catalogsById = const {};
      }
    }

    final attemptedBuiltIn = keys.any((key) => builtInRowById(key) != null);
    final rows = await fetchHomeRowsConcurrently(
      keys,
      (key) => _fetchRowByKey(key, request, catalogsById),
    );
    // Built-ins were requested but every rail failed (e.g. no network): surface
    // an error so the UI shows the retry state. With them off, an empty Home is
    // the user's choice, not a failure.
    if (rows.isEmpty && attemptedBuiltIn) {
      throw const HttpException('no catalog rows loaded');
    }
    return rows;
  }

  Future<HomeRow?> _fetchRowByKey(
    String key,
    CatalogRequest request,
    Map<String, LetterboxdCatalog> catalogsById,
  ) async {
    final builtIn = builtInRowById(key);
    if (builtIn != null) {
      final metas = await _fetchBuiltInRow(builtIn, request.tmdbKey);
      return metas.isEmpty ? null : HomeRow(builtIn.title, metas);
    }
    final catalogId = letterboxdCatalogId(key);
    final catalog = catalogId == null ? null : catalogsById[catalogId];
    if (catalog == null) return null;
    final url = letterboxdCatalogUrl(request.letterboxd.manifestUrl, catalog);
    if (url == null) return null;
    final metas = parseCinemetaCatalog(await _get(Uri.parse(url)));
    return metas.isEmpty ? null : HomeRow(catalog.name, metas);
  }

  Future<List<Meta>> _fetchBuiltInRow(BuiltInRow row, String? tmdbKey) async {
    try {
      final url = tmdbKey == null
          ? '$cinemetaBase${row.path}'
          : '$tmdbBase${row.path}?api_key=$tmdbKey';
      final raw = await _get(Uri.parse(url));
      return tmdbKey == null
          ? parseCinemetaCatalog(raw)
          : parseTmdbPage(raw, row.type);
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<DetailMeta> fetchDetail(String type, String id, String? tmdbKey) async {
    if (!usesTmdbDetail(tmdbKey, id)) {
      final raw = await _get(Uri.parse('$cinemetaBase/meta/$type/$id.json'));
      return parseCinemetaDetail(raw);
    }
    final key = tmdbKey!;
    // id is `tmdb:movie:<id>` / `tmdb:tv:<id>`; the numeric id is the last segment.
    final idNum = id.substring(id.lastIndexOf(':') + 1);
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
