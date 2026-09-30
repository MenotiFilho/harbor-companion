// Detail extras HTTP seam (tickets 86, 87; ADR-0012).
//
// The detail page's extra sections are fetched on their own providers, never
// joined to the detail round: credits come from TMDB
// `/{kind}/{id}/credits` (Cast, #86) and similar titles from
// `/{kind}/{id}/recommendations` (Similar, #87). A Cinemeta `tt…` id first
// resolves through TMDB `/find/{imdb_id}?external_source=imdb_id`. Without a
// TMDB key — or with no match, an empty list or a failure — a section simply
// has no data and does not render (ADR-0012). Results are cached in memory for
// the session only, and both sections share the `/find` resolution.
//
// Wire contract: docs/wire-contract.md §5.2 (TMDB).

import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../ws/client_controller.dart';
import 'catalog_fetcher.dart' show parseTmdbMeta, tmdbBase, tmdbImageBase;
import 'meta.dart';

/// Top-billed cast cap. The detail page's cast row is a rail; twelve fills it
/// without paging (TMDB returns every credit, so an uncapped list would ship a
/// whole film's cast into the section).
const int kCastCap = 12;

/// A TMDB profile image at the rail's avatar size, or null when the source has
/// no path — never a broken URL.
String? tmdbProfile(String? path) =>
    path == null ? null : '$tmdbImageBase/w185$path';

/// One cast member from TMDB credits, top-billed: the actor, the character
/// they play (when the source names one) and an avatar-sized profile image.
class CastMember {
  final String name;
  final String? character;
  final String? profile;

  const CastMember({required this.name, this.character, this.profile});
}

/// A resolved TMDB target: the media kind (`movie`/`tv`) and the numeric id
/// the credits/recommendations endpoints take.
class TmdbTarget {
  final String kind;
  final String id;

  const TmdbTarget(this.kind, this.id);

  @override
  bool operator ==(Object other) =>
      other is TmdbTarget && other.kind == kind && other.id == id;

  @override
  int get hashCode => Object.hash(kind, id);

  @override
  String toString() => 'TmdbTarget($kind, $id)';
}

// ---------------------------------------------------------------------------
// Pure mappers (pinned to the upstream JSON shapes; tested without network)
// ---------------------------------------------------------------------------

/// Parses a TMDB credits response `{ "cast": [...] }` into the [limit]
/// top-billed members. Billing order comes from the `order` field — the array
/// order is the tiebreaker, so an upstream reorder cannot shuffle the rail.
/// Entries without a name are skipped; a missing character or profile stays
/// null, never invented.
List<CastMember> parseTmdbCredits(String raw, {int limit = kCastCap}) {
  final decoded = jsonDecode(raw);
  if (decoded is! Map<String, dynamic>) return const [];
  final cast = decoded['cast'];
  if (cast is! List) return const [];

  final entries = <(int order, int index, CastMember member)>[];
  for (var i = 0; i < cast.length; i++) {
    final c = cast[i];
    if (c is! Map<String, dynamic>) continue;
    final name = c['name'] as String?;
    if (name == null || name.isEmpty) continue;
    entries.add((
      (c['order'] as num?)?.toInt() ?? i,
      i,
      CastMember(
        name: name,
        character: _nonEmpty(c['character'] as String?),
        profile: tmdbProfile(c['profile_path'] as String?),
      ),
    ));
  }
  entries.sort((a, b) {
    final byOrder = a.$1.compareTo(b.$1);
    return byOrder != 0 ? byOrder : a.$2.compareTo(b.$2);
  });
  return [for (final entry in entries.take(limit)) entry.$3];
}

/// Parses a TMDB `/find` response into the numeric target for [type]:
/// `tv_results` for a series, `movie_results` for a movie. Null when that list
/// is absent or empty — a mismatched id never borrows the other list.
TmdbTarget? parseTmdbFind(String raw, String type) {
  final decoded = jsonDecode(raw);
  if (decoded is! Map<String, dynamic>) return null;
  final isSeries = type == 'series';
  final results = decoded[isSeries ? 'tv_results' : 'movie_results'];
  if (results is! List) return null;
  for (final r in results) {
    if (r is! Map<String, dynamic>) continue;
    final id = (r['id'] as num?)?.toInt();
    if (id != null) return TmdbTarget(isSeries ? 'tv' : 'movie', '$id');
  }
  return null;
}

/// Parses a TMDB recommendations response `{ "results": [...] }` for a target
/// of [kind] (`movie`/`tv`) into catalog [Meta]s. The endpoint is kind-specific,
/// so every result carries that kind; the ids and image sizes match the
/// catalog's own TMDB mapping, so a similar title opens its Detail through the
/// normal path. Entries without a numeric id or a name are skipped — a card
/// that cannot open or is labelled nothing would lie; an absent `results` array
/// is no data, never a crash.
List<Meta> parseTmdbRecommendations(String raw, String kind) {
  final decoded = jsonDecode(raw);
  if (decoded is! Map<String, dynamic>) return const [];
  final results = decoded['results'];
  if (results is! List) return const [];

  final type = kind == 'tv' ? 'series' : 'movie';
  final items = <Meta>[];
  for (final r in results) {
    if (r is! Map<String, dynamic>) continue;
    final id = (r['id'] as num?)?.toInt();
    if (id == null) continue;
    final meta = parseTmdbMeta({...r, 'id': id}, type);
    if (meta.name.isEmpty) continue;
    items.add(meta);
  }
  return items;
}

/// The TMDB target a `tmdb:<kind>:<id>` detail id already names, or null for a
/// Cinemeta `tt…` id (which needs `/find`).
TmdbTarget? tmdbTargetFromId(String id) {
  for (final kind in const ['movie', 'tv']) {
    final prefix = 'tmdb:$kind:';
    final numeric = id.startsWith(prefix) ? id.substring(prefix.length) : '';
    if (numeric.isNotEmpty) return TmdbTarget(kind, numeric);
  }
  return null;
}

String? _nonEmpty(String? value) =>
    (value == null || value.isEmpty) ? null : value;

// ---------------------------------------------------------------------------
// Session cache + fetcher seam
// ---------------------------------------------------------------------------

/// Session-only in-memory cache for detail extras (ADR-0012): the `/find`
/// resolution per title identity — including a resolved "no match", so a `tt…`
/// id never asks `/find` twice — and the parsed section results per TMDB
/// target. No disk, no TTL; the whole point is that re-opening a title in the
/// same session is instant.
class DetailExtrasCache {
  final Map<String, TmdbTarget?> _targets = {};
  final Map<String, List<CastMember>> _cast = {};
  final Map<String, List<Meta>> _recommendations = {};

  /// Whether [identity] has already been resolved, so "resolved to no match"
  /// (a null [targetFor]) is distinguishable from "not asked yet".
  bool hasTarget(String identity) => _targets.containsKey(identity);

  /// The target resolved for [identity]; null both when it resolved to no match
  /// and when it was never asked — pair with [hasTarget].
  TmdbTarget? targetFor(String identity) => _targets[identity];

  void saveTarget(String identity, TmdbTarget? target) =>
      _targets[identity] = target;

  List<CastMember>? castFor(String targetKey) => _cast[targetKey];

  void saveCast(String targetKey, List<CastMember> members) =>
      _cast[targetKey] = members;

  List<Meta>? recommendationsFor(String targetKey) =>
      _recommendations[targetKey];

  void saveRecommendations(String targetKey, List<Meta> items) =>
      _recommendations[targetKey] = items;
}

/// Narrow fetcher for the detail page's extra sections (ADR-0012). Injected via
/// [detailExtrasFetcherProvider]; tests provide a fake.
abstract interface class DetailExtrasFetcher {
  /// Top-billed cast for a title. Empty when [tmdbKey] is absent or the id has
  /// no TMDB match; throws on an HTTP/parse failure.
  Future<List<CastMember>> fetchCast(String type, String id, String? tmdbKey);

  /// Similar titles for a title, from TMDB recommendations. Empty when
  /// [tmdbKey] is absent or the id has no TMDB match; throws on an
  /// HTTP/parse failure.
  Future<List<Meta>> fetchRecommendations(
    String type,
    String id,
    String? tmdbKey,
  );
}

/// Real extras fetcher over dart:io HTTP. No `/api-proxy` — the phone hits TMDB
/// directly (wire-contract §6).
class HttpDetailExtrasFetcher implements DetailExtrasFetcher {
  final Duration timeout;

  /// Session cache shared by every section (ADR-0012). Defaults to a fresh
  /// in-memory cache so direct construction in tests needs no wiring.
  final DetailExtrasCache cache;

  /// Test seam: when set, every upstream GET goes through it instead of the
  /// real dart:io client. Null in production.
  final Future<String> Function(Uri url)? _getOverride;

  HttpDetailExtrasFetcher({
    this.timeout = const Duration(seconds: 8),
    DetailExtrasCache? cache,
    Future<String> Function(Uri url)? get,
  })  : cache = cache ?? DetailExtrasCache(),
        _getOverride = get;

  @override
  Future<List<CastMember>> fetchCast(
    String type,
    String id,
    String? tmdbKey,
  ) async {
    final key = _usableKey(tmdbKey);
    if (key == null) return const [];
    final target = await resolveTarget(type, id, key);
    if (target == null) return const [];

    final targetKey = _targetKey(target);
    final cached = cache.castFor(targetKey);
    if (cached != null) return cached;

    final members = parseTmdbCredits(
      await _get(
        Uri.parse('$tmdbBase/${target.kind}/${target.id}/credits?api_key=$key'),
      ),
    );
    cache.saveCast(targetKey, members);
    return members;
  }

  @override
  Future<List<Meta>> fetchRecommendations(
    String type,
    String id,
    String? tmdbKey,
  ) async {
    final key = _usableKey(tmdbKey);
    if (key == null) return const [];
    final target = await resolveTarget(type, id, key);
    if (target == null) return const [];

    final targetKey = _targetKey(target);
    final cached = cache.recommendationsFor(targetKey);
    if (cached != null) return cached;

    final items = parseTmdbRecommendations(
      await _get(
        Uri.parse(
          '$tmdbBase/${target.kind}/${target.id}/recommendations?api_key=$key',
        ),
      ),
      target.kind,
    );
    cache.saveRecommendations(targetKey, items);
    return items;
  }

  /// Resolves a detail id to the numeric TMDB target the section endpoints
  /// take: a `tmdb:<kind>:<id>` id maps directly, a Cinemeta `tt…` id resolves
  /// through `/find`. The resolution is cached per identity, including the
  /// "no match" outcome. Null means no match — the section stays absent.
  Future<TmdbTarget?> resolveTarget(String type, String id, String key) async {
    final identity = '$type:$id';
    if (cache.hasTarget(identity)) return cache.targetFor(identity);

    final direct = tmdbTargetFromId(id);
    if (direct != null) {
      cache.saveTarget(identity, direct);
      return direct;
    }
    final target = parseTmdbFind(
      await _get(
        Uri.parse('$tmdbBase/find/$id?external_source=imdb_id&api_key=$key'),
      ),
      type,
    );
    cache.saveTarget(identity, target);
    return target;
  }

  String _targetKey(TmdbTarget target) => '${target.kind}:${target.id}';

  Future<String> _get(Uri url) {
    final override = _getOverride;
    if (override != null) return override(url).timeout(timeout);
    return _getReal(url);
  }

  Future<String> _getReal(Uri url) async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final request = await client.getUrl(url).timeout(timeout);
      final response = await request.close().timeout(timeout);
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('HTTP ${response.statusCode} for $url');
      }
      return await response.transform(utf8.decoder).join().timeout(timeout);
    } finally {
      client.close(force: true);
    }
  }
}

String? _usableKey(String? key) => (key == null || key.isEmpty) ? null : key;

// ---------------------------------------------------------------------------
// Providers
// ---------------------------------------------------------------------------

/// Session-only extras cache (ADR-0012). One instance per provider scope; the
/// disk-backed store ADR-0012 explicitly rejected.
final detailExtrasCacheProvider =
    Provider<DetailExtrasCache>((ref) => DetailExtrasCache());

/// Detail extras fetch seam. Defaults to the real dart:io HTTP fetcher on the
/// session cache; tests override with a fake.
final detailExtrasFetcherProvider = Provider<DetailExtrasFetcher>(
  (ref) => HttpDetailExtrasFetcher(cache: ref.read(detailExtrasCacheProvider)),
);

/// The family key of a detail section: the title identity the route carries.
/// Both section providers ([castProvider], [similarProvider]) take it.
typedef DetailTitle = ({String type, String id});

/// The Cast section's own provider (ADR-0012): it fetches and settles
/// independently of the header and the episodes, and re-runs if the host's
/// TMDB key changes — a keyless session simply resolves to no data. Whether
/// "no data" renders is the widget's call (it renders nothing).
///
/// The framework's automatic error retry is disabled: a failed extras fetch is
/// decoration, and retrying it silently would hammer TMDB with no UI signal.
final castProvider = FutureProvider.family<List<CastMember>, DetailTitle>(
  (ref, title) async {
    final key = ref.watch(wsClientControllerProvider.select((s) => s.tmdbKey));
    return ref
        .read(detailExtrasFetcherProvider)
        .fetchCast(title.type, title.id, key);
  },
  retry: (_, _) => null,
);

/// The Similar section's own provider (ticket #87, ADR-0012): the same
/// independent settling as [castProvider] — the `/find` resolution and the
/// parsed results are already session-cached, but a pending or failed
/// recommendations request never touches the header, cast or episodes, and a
/// keyless/no-match/failed result is simply absent from the page.
final similarProvider = FutureProvider.family<List<Meta>, DetailTitle>(
  (ref, title) async {
    final key = ref.watch(wsClientControllerProvider.select((s) => s.tmdbKey));
    return ref
        .read(detailExtrasFetcherProvider)
        .fetchRecommendations(title.type, title.id, key);
  },
  retry: (_, _) => null,
);
