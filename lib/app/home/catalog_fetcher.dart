// Catalog HTTP seam (tickets 04, 41).
//
// Home rows and detail come from public sources, never from Harbor:
//   - Cinemeta (`https://v3-cinemeta.strem.io`, keyless) as the fallback.
//   - TMDB (`https://api.themoviedb.org/3`, keyed by `snapshot.tmdbKey`).
//   - Stremboxd (`https://api.stremboxd.com/stremio/<token>/…`), the user's
//     Letterboxd rails, only when a manifest URL is configured (ticket 41).
//
// `CatalogFetcher` is the seam the controller drains `fetch:rails` /
// `fetch:rail` / `fetch:detail` effects into; tests inject a fake. The real
// implementation (dart:io) hits the upstreams directly — there is no
// `/api-proxy` on the LAN (wire-contract §5, §6) — and emits one per-rail
// outcome as each resolves (ticket 71), never a single blocking list. The pure
// JSON→model mappers are top-level so tests pin the wire shapes without network.
//
// Wire contract: docs/wire-contract.md §5.1 (Cinemeta), §5.2 (TMDB).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../letterboxd/letterboxd.dart';
import 'catalog_request.dart';
import 'home_cache_store.dart';
import 'home_rail.dart';
import 'home_rows.dart';
import 'meta.dart';

const String cinemetaBase = 'https://v3-cinemeta.strem.io';
const String tmdbBase = 'https://api.themoviedb.org/3';
const String tmdbImageBase = 'https://image.tmdb.org/t/p';

/// The Stremio addon protocol's standard catalog page size. Stremboxd (and
/// Cinemeta, though it is unbounded) slices catalogs in windows of this size: a
/// full page means there is more, a shorter one is the end of the catalog
/// (ticket 75, ADR-0009).
const int kStremboxdPageSize = 100;

/// Whether a Stremboxd/Stremio catalog page has a continuation: a full
/// [kStremboxdPageSize] page means more may exist, a short page is the end.
bool stremboxdHasMore(int itemCount) => itemCount >= kStremboxdPageSize;

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

/// A parsed TMDB paged response: the page's items plus the cursor fields the
/// `hasMore` rule reads (`page < total_pages`, ticket 75, ADR-0009). A response
/// without the fields is treated as page 1 of 1 — no continuation.
class TmdbPage {
  final List<Meta> items;
  final int page;
  final int totalPages;

  const TmdbPage({
    required this.items,
    required this.page,
    required this.totalPages,
  });

  bool get hasMore => page < totalPages;
}

/// Parses a TMDB paged response `{ page, total_pages, results: [...] }`.
TmdbPage parseTmdbPageResponse(String raw, String type) {
  final decoded = jsonDecode(raw);
  if (decoded is! Map<String, dynamic>) {
    return const TmdbPage(items: [], page: 1, totalPages: 1);
  }
  final results = decoded['results'];
  final items = results is List
      ? [
          for (final r in results)
            if (r is Map<String, dynamic>) parseTmdbMeta(r, type),
        ]
      : <Meta>[];
  final page = (decoded['page'] as num?)?.toInt() ?? 1;
  final totalPages = (decoded['total_pages'] as num?)?.toInt() ?? page;
  return TmdbPage(items: items, page: page, totalPages: totalPages);
}

/// Parses a TMDB paged response's `results` array.
List<Meta> parseTmdbPage(String raw, String type) =>
    parseTmdbPageResponse(raw, type).items;

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

/// Runs [fetch] for each planned [key] concurrently and emits one outcome per
/// key as it completes (completion order, not key order — the Home renders in
/// plan order regardless). A key whose fetch throws becomes a [HomeRailFailed]
/// for that key alone, so one flaky rail never takes down the rest. This is the
/// progressive replacement for the old `Future.wait`-then-`List<HomeRow>`.
Stream<HomeRailOutcome> fetchRailOutcomesConcurrently(
  List<String> keys,
  Future<HomeRailOutcome> Function(String key) fetch,
) {
  Future<HomeRailOutcome> safe(String key) async {
    try {
      return await fetch(key);
    } catch (error) {
      return HomeRailFailed(key, error);
    }
  }

  return Stream.fromFutures([for (final key in keys) safe(key)]);
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

/// Fetches home rails and detail from Cinemeta/TMDB/Stremboxd. Injected into the
/// home controller; tests provide a fake.
///
/// [fetchRails] emits exactly one [HomeRailOutcome] per planned rail, as each
/// resolves — never a single blocking list. [fetchRail] re-fetches one rail for
/// the Home's local retry card.
abstract interface class CatalogFetcher {
  /// Progressive outcomes for [request]: TMDB when a key is set, else Cinemeta
  /// (unless the built-in rails are switched off), plus the enabled Letterboxd
  /// rails. A rail whose fetch fails is a [HomeRailFailed] for that rail alone.
  Stream<HomeRailOutcome> fetchRails(CatalogRequest request);

  /// Re-fetch a single planned [rowKey] (the local retry card).
  Future<HomeRailOutcome> fetchRail(CatalogRequest request, String rowKey);

  /// Detail for a title: Cinemeta `meta/{type}/{id}` when keyless, TMDB detail
  /// + per-season episodes when keyed.
  Future<DetailMeta> fetchDetail(String type, String id, String? tmdbKey);
}

/// Adaptive per-rail timeout + retry policy (ticket 73).
///
/// Calibrated on the field measurement from #51: a warm Stremboxd rail answers
/// in ~0.4s, while a cold one can take 9–33s. A rail that already has a cached
/// copy can therefore fail fast ([warm], 8s) — the cached copy stays on screen
/// and is badged; a rail with no fallback is given the long [cold] timeout (45s)
/// before it is marked failed. A failed rail is retried exactly once after
/// [retryBackoff] (~1s), so a transient blip does not drop it until the next
/// round.
class HomeRailTimeouts {
  final Duration cold;
  final Duration warm;
  final Duration retryBackoff;

  const HomeRailTimeouts({
    this.cold = const Duration(seconds: 45),
    this.warm = const Duration(seconds: 8),
    this.retryBackoff = const Duration(seconds: 1),
  });

  /// The timeout for a rail that does/does not have a cached copy to fall back
  /// to. Warm is short because the cache already covers the screen; cold is long
  /// because the source may legitimately be slow and there is nothing to show.
  Duration forCache({required bool hasCache}) => hasCache ? warm : cold;
}

/// Real catalog fetcher over dart:io HTTP. No `/api-proxy` — the phone hits the
/// upstreams directly (wire-contract §6).
class HttpCatalogFetcher implements CatalogFetcher {
  /// Short HTTP timeout for the non-rail requests that do not use the adaptive
  /// policy: the Stremboxd manifest and detail. Per-rail timeouts come from
  /// [timeouts].
  final Duration timeout;

  /// Adaptive per-rail timeout + retry policy (ticket 73).
  final HomeRailTimeouts timeouts;

  /// Optional manifest cache (ticket 72). When set, a successful manifest fetch
  /// is written as its own entry, and a failed fresh fetch falls back to the
  /// cached manifest for the same URL — so a manifest timeout no longer fails
  /// every Letterboxd rail. Its presence also marks a rail "warm" for the
  /// adaptive timeout. Null in the pure wire-shape tests.
  final HomeCacheStore? cache;

  /// Clock for the manifest entry's `updatedAt` (ms since epoch). Tests pin it.
  final int Function() nowMs;

  /// Test seam: when set, every upstream GET goes through it instead of the
  /// real dart:io client, so the per-rail outcome mapping is pinned without
  /// network. Null in production.
  final Future<String> Function(Uri url)? _getOverride;

  HttpCatalogFetcher({
    this.timeout = const Duration(seconds: 8),
    this.timeouts = const HomeRailTimeouts(),
    this.cache,
    int Function()? nowMs,
    Future<String> Function(Uri url)? get,
  })  : nowMs = nowMs ?? _systemNow,
        _getOverride = get;

  static int _systemNow() => DateTime.now().millisecondsSinceEpoch;

  @override
  Stream<HomeRailOutcome> fetchRails(CatalogRequest request) {
    final keys = planHomeRowKeys(request);
    if (keys.isEmpty) return Stream<HomeRailOutcome>.empty();
    final builtInKeys = keys.where((key) => builtInRowById(key) != null).toList();
    final letterboxdKeys = keys.where(isLetterboxdRowKey).toList();

    final controller = StreamController<HomeRailOutcome>();
    var remaining = keys.length;
    void forward(HomeRailOutcome outcome) {
      controller.add(outcome);
      if (--remaining == 0) controller.close();
    }

    // Built-ins start immediately; the Letterboxd rails start once their
    // manifest resolves, in parallel. A slow/broken manifest must never hold
    // the built-in rails (ADR-0004: one bad manifest only fails Letterboxd).
    if (builtInKeys.isNotEmpty) {
      fetchRailOutcomesConcurrently(
        builtInKeys,
        (key) => _fetchOutcomeWithRetry(key, request, null, null),
      ).listen(forward);
    }
    if (letterboxdKeys.isNotEmpty) {
      _resolveManifest(request, letterboxdKeys).then((resolved) {
        final (catalogsById, manifestError) = resolved;
        fetchRailOutcomesConcurrently(
          letterboxdKeys,
          (key) => _fetchOutcomeWithRetry(key, request, catalogsById, manifestError),
        ).listen(forward);
      });
    }
    return controller.stream;
  }

  @override
  Future<HomeRailOutcome> fetchRail(
    CatalogRequest request,
    String rowKey,
  ) async {
    final (catalogsById, manifestError) =
        await _resolveManifest(request, [rowKey]);
    return _fetchOutcomeWithRetry(rowKey, request, catalogsById, manifestError);
  }

  /// Fetches one rail with the cache-aware timeout, retrying exactly once when
  /// it fails. The timeout comes from the rail's cache presence: a rail with a
  /// cached copy gets the short [HomeRailTimeouts.warm] (fail fast; the cache
  /// stays on screen), a cold one the long [HomeRailTimeouts.cold] (the source
  /// may legitimately take 30s+). Never throws — a second failure is the rail's
  /// final [HomeRailFailed], and it fails only this rail.
  Future<HomeRailOutcome> _fetchOutcomeWithRetry(
    String key,
    CatalogRequest request,
    Map<String, LetterboxdCatalog>? catalogsById,
    Object? manifestError,
  ) async {
    final hasCache = await _hasCachedRail(key, request);
    final railTimeout = timeouts.forCache(hasCache: hasCache);
    var outcome = await _fetchOutcome(
      key,
      request,
      catalogsById,
      manifestError,
      railTimeout,
    );
    if (outcome is HomeRailFailed) {
      await Future<void>.delayed(timeouts.retryBackoff);
      outcome = await _fetchOutcome(
        key,
        request,
        catalogsById,
        manifestError,
        railTimeout,
      );
    }
    return outcome;
  }

  /// Whether [key] has a cache entry to fall back to, which selects the short
  /// warm timeout. A cache read failure is treated as "no cache" (the long
  /// timeout), never as a rail failure.
  Future<bool> _hasCachedRail(String key, CatalogRequest request) async {
    final store = cache;
    if (store == null) return false;
    try {
      return await store.loadRail(cacheIdentityFor(key, request)) != null;
    } catch (_) {
      return false;
    }
  }

  /// Fetches the Stremboxd manifest when any planned key is a Letterboxd rail.
  /// Returns the catalogs on success, or `(null, error)` on failure — a bad
  /// manifest fails only the Letterboxd rails, never the built-ins. A valid
  /// manifest for the same URL is cached; a fresh failure falls back to it
  /// (ticket 72, ADR-0004).
  Future<(Map<String, LetterboxdCatalog>?, Object?)> _resolveManifest(
    CatalogRequest request,
    List<String> keys,
  ) async {
    if (!keys.any(isLetterboxdRowKey)) return (null, null);
    final url = request.letterboxd.manifestUrl.trim();
    try {
      final raw = await _get(Uri.parse(url), timeout);
      final manifest = parseLetterboxdManifest(raw);
      // A body that yields no catalogs (e.g. an HTML error page served 200) is
      // treated as a failure so the cached manifest can still serve.
      if (manifest.catalogs.isEmpty) {
        throw const FormatException('manifest lists no catalogs');
      }
      await cache?.saveManifest(CachedManifest(
        manifestUrl: url,
        body: raw,
        updatedAt: nowMs(),
      ));
      return ({
        for (final catalog in manifest.catalogs) catalog.id: catalog,
      }, null);
    } catch (error) {
      final cached = await cache?.loadManifest(url);
      if (cached != null) {
        final manifest = parseLetterboxdManifest(cached.body);
        if (manifest.catalogs.isNotEmpty) {
          return ({
            for (final catalog in manifest.catalogs) catalog.id: catalog,
          }, null);
        }
      }
      return (null, error);
    }
  }

  /// Resolves one planned rail to its outcome. Never throws: a fetch error is a
  /// [HomeRailFailed], an unlisted/unusable Letterboxd catalog is
  /// [HomeRailAbsent], and an empty catalog is a valid empty [HomeRailLoaded].
  Future<HomeRailOutcome> _fetchOutcome(
    String key,
    CatalogRequest request,
    Map<String, LetterboxdCatalog>? catalogsById,
    Object? manifestError,
    Duration railTimeout,
  ) async {
    try {
      final builtIn = builtInRowById(key);
      if (builtIn != null) {
        final (metas, hasMore) =
            await _fetchBuiltInRow(builtIn, request.tmdbKey, railTimeout);
        return HomeRailLoaded(key, builtIn.title, metas, hasMore: hasMore);
      }
      final catalogId = letterboxdCatalogId(key);
      if (catalogId == null) return HomeRailAbsent(key);
      if (catalogsById == null) {
        return HomeRailFailed(key, manifestError ?? 'manifest unavailable');
      }
      final catalog = catalogsById[catalogId];
      if (catalog == null) return HomeRailAbsent(key);
      final url = letterboxdCatalogUrl(request.letterboxd.manifestUrl, catalog);
      if (url == null) return HomeRailAbsent(key);
      final metas = parseCinemetaCatalog(await _get(Uri.parse(url), railTimeout));
      // Stremboxd pages at 100: a full page has more, a short one is the end.
      return HomeRailLoaded(key, catalog.name, metas,
          hasMore: stremboxdHasMore(metas.length));
    } catch (error) {
      return HomeRailFailed(key, error);
    }
  }

  /// Fetches a built-in rail, returning its items plus the source's `hasMore`
  /// signal (ticket 75, ADR-0009). Throws on an HTTP/parse failure (so the rail
  /// becomes [HomeRailFailed]); an empty catalog is a legitimate empty result.
  ///
  /// `hasMore` is per source: Cinemeta's `skip` is unbounded (always more),
  /// TMDB follows `page < total_pages`, and the `/trending/*` rows expose no
  /// page cursor so they are always `false`.
  Future<(List<Meta>, bool)> _fetchBuiltInRow(
    BuiltInRow row,
    String? tmdbKey,
    Duration railTimeout,
  ) async {
    final url = tmdbKey == null
        ? '$cinemetaBase${row.path}'
        : '$tmdbBase${row.path}?api_key=$tmdbKey';
    final raw = await _get(Uri.parse(url), railTimeout);
    if (tmdbKey == null) {
      return (parseCinemetaCatalog(raw), row.paginatable);
    }
    final page = parseTmdbPageResponse(raw, row.type);
    return (page.items, row.paginatable && page.hasMore);
  }

  @override
  Future<DetailMeta> fetchDetail(String type, String id, String? tmdbKey) async {
    if (!usesTmdbDetail(tmdbKey, id)) {
      final raw = await _get(Uri.parse('$cinemetaBase/meta/$type/$id.json'), timeout);
      return parseCinemetaDetail(raw);
    }
    final key = tmdbKey!;
    // id is `tmdb:movie:<id>` / `tmdb:tv:<id>`; the numeric id is the last segment.
    final idNum = id.substring(id.lastIndexOf(':') + 1);
    if (type == 'movie') {
      final raw = await _get(Uri.parse('$tmdbBase/movie/$idNum?api_key=$key'), timeout);
      return DetailMeta(meta: parseTmdbDetail(raw, 'movie'));
    }
    final raw = await _get(Uri.parse('$tmdbBase/tv/$idNum?api_key=$key'), timeout);
    final meta = parseTmdbDetail(raw, 'series');
    final seasons = await loadTmdbSeasonEpisodes(
      parseTmdbSeasons(raw),
      (season) => _tmdbEpisodes(idNum, season, key),
    );
    return DetailMeta(meta: meta, seasons: seasons);
  }

  Future<List<Episode>> _tmdbEpisodes(String id, int season, String key) async {
    try {
      final raw = await _get(
        Uri.parse('$tmdbBase/tv/$id/season/$season?api_key=$key'),
        timeout,
      );
      return parseTmdbSeasonEpisodes(raw, season);
    } catch (_) {
      return const [];
    }
  }

  Future<String> _get(Uri url, Duration requestTimeout) {
    final override = _getOverride;
    // The timeout is applied here (not just in the real client) so a hanging
    // upstream — including the test override — is bounded by the rail's
    // cache-aware timeout.
    return override != null
        ? override(url).timeout(requestTimeout)
        : _getReal(url, requestTimeout);
  }

  Future<String> _getReal(Uri url, Duration requestTimeout) async {
    final client = HttpClient()..connectionTimeout = requestTimeout;
    try {
      final request = await client.getUrl(url).timeout(requestTimeout);
      final response = await request.close().timeout(requestTimeout);
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('HTTP ${response.statusCode} for $url');
      }
      return await response.transform(utf8.decoder).join().timeout(requestTimeout);
    } finally {
      client.close(force: true);
    }
  }
}
