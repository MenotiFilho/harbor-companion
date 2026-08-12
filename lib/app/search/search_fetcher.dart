// Search HTTP seam (ticket 05).
//
// Search fans out to three public sources, never from Harbor:
//   - TMDB `search/multi` (keyed by `snapshot.tmdbKey`) — drives movies/series
//     and the pinned top match (highest popularity with a poster).
//   - Cinemeta `catalog/{type}/top/search=<q>.json` — the keyless fallback.
//   - Jikan `/anime?q=…` — anime, routed through the shared [JikanQueue].
//
// `SearchFetcher` is the seam the controller drains `fetch:<source>` effects
// into; tests inject a fake. The pure JSON→model mappers are top-level so tests
// pin the wire shapes without network.
//
// Wire contract: docs/wire-contract.md §5.1/§5.2/§5.3.

library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../home/catalog_fetcher.dart'
    show cinemetaBase, parseCinemetaCatalog, parseTmdbMeta, tmdbBase;
import '../home/meta.dart';
import 'jikan.dart';
import 'search_reducer.dart';

// ---------------------------------------------------------------------------
// Pure mappers (pinned to the upstream JSON shapes; tested without network)
// ---------------------------------------------------------------------------

/// Parses a TMDB `search/multi` response `{ "results": [...] }` into movies,
/// series, and the derived top match (highest popularity with a poster).
/// `person` entries are skipped (search.ts:126-151).
TmdbSearchPayload parseTmdbSearch(String raw) {
  final decoded = jsonDecode(raw);
  if (decoded is! Map<String, dynamic>) return const TmdbSearchPayload([], []);
  final results = decoded['results'];
  if (results is! List) return const TmdbSearchPayload([], []);

  final movies = <Meta>[];
  final series = <Meta>[];
  Meta? topMeta;
  double topPopularity = -1;
  double? topVoteAverage;

  for (final r in results) {
    if (r is! Map<String, dynamic>) continue;
    final mediaType = r['media_type'] as String?;
    if (mediaType == 'person') continue;
    final type = mediaType == 'tv' ? 'series' : 'movie';
    final meta = parseTmdbMeta(r, type);
    (type == 'series' ? series : movies).add(meta);

    final popularity = (r['popularity'] as num?)?.toDouble() ?? 0;
    if (meta.poster != null && popularity > topPopularity) {
      topPopularity = popularity;
      topMeta = meta;
      topVoteAverage = (r['vote_average'] as num?)?.toDouble();
    }
  }

  final topMatch = topMeta == null
      ? null
      : TopMatch(
          kind: topMeta.type,
          meta: topMeta,
          popularity: topPopularity,
          backdrop: topMeta.background,
          overview: topMeta.description,
          voteAverage: topVoteAverage,
        );
  return TmdbSearchPayload(movies, series, topMatch);
}

// ---------------------------------------------------------------------------
// Fetcher seam + real implementation
// ---------------------------------------------------------------------------

/// Fetches search results from TMDB/Cinemeta/Jikan. Injected into the search
/// controller; tests provide a fake. [searchJikan] is the **raw** unthrottled
/// call — the controller routes it through the shared [JikanQueue].
abstract interface class SearchFetcher {
  Future<TmdbSearchPayload> searchTmdb(String query, String tmdbKey);

  Future<List<Meta>> searchCinemeta(String query);

  Future<List<AnimeHit>> searchJikan(String query);
}

/// Real search fetcher over dart:io HTTP. No `/api-proxy` — the phone hits the
/// upstreams directly (wire-contract §6).
class HttpSearchFetcher implements SearchFetcher {
  final Duration timeout;

  HttpSearchFetcher({this.timeout = const Duration(seconds: 8)});

  @override
  Future<TmdbSearchPayload> searchTmdb(String query, String tmdbKey) async {
    final url = '$tmdbBase/search/multi?query=${Uri.encodeQueryComponent(query)}'
        '&api_key=$tmdbKey';
    return parseTmdbSearch(await _get(Uri.parse(url)));
  }

  @override
  Future<List<Meta>> searchCinemeta(String query) async {
    final q = Uri.encodeQueryComponent(query);
    final results = await Future.wait([
      _get(Uri.parse('$cinemetaBase/catalog/movie/top/search=$q.json')),
      _get(Uri.parse('$cinemetaBase/catalog/series/top/search=$q.json')),
    ]);
    return [
      ...parseCinemetaCatalog(results[0]),
      ...parseCinemetaCatalog(results[1]),
    ];
  }

  @override
  Future<List<AnimeHit>> searchJikan(String query) async {
    final q = Uri.encodeQueryComponent(query);
    final raw = await _get(Uri.parse(
        '$jikanBase/anime?q=$q&limit=12&sfw=true&order_by=popularity&sort=asc'));
    final hits = parseJikanSearch(raw);
    // Best-effort kitsu/anilist resolution; a failure just leaves the id null
    // (metaId falls back to `mal:`).
    return Future.wait([for (final hit in hits) _enrichIds(hit)]);
  }

  Future<AnimeHit> _enrichIds(AnimeHit hit) async {
    final malId = hit.malId;
    if (malId == null) return hit;
    try {
      final raw = await _get(Uri.parse(
              '$relationsBase/api/ids?source=myanimelist&id=$malId'))
          .timeout(timeout);
      final (kitsu, anilist) = parseAnimeIdRelations(raw);
      return AnimeHit(
        malId: hit.malId,
        kitsuId: kitsu,
        anilistId: anilist,
        format: hit.format,
        name: hit.name,
        year: hit.year,
        poster: hit.poster,
        background: hit.background,
        overview: hit.overview,
      );
    } catch (_) {
      return hit;
    }
  }

  Future<String> _get(Uri url) async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final request = await client.getUrl(url);
      final response = await request.close().timeout(timeout);
      if (response.statusCode == HttpStatus.tooManyRequests) {
        throw const JikanRateLimited();
      }
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('HTTP ${response.statusCode} for $url');
      }
      return await response.transform(utf8.decoder).join();
    } finally {
      client.close(force: true);
    }
  }
}
