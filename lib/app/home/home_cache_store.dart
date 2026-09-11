// Per-rail Home cache seam (ticket 72, ADR-0004).
//
// The cache unit is the **rail**: one entry per `rowKey` (plus the Stremboxd
// `manifestUrl` for Letterboxd rails), served stale-while-revalidate. The Home
// reads it before any network fetch so a cold open shows content immediately,
// and replaces each rail in place when the fresh copy arrives (the age badge
// disappears). There is no TTL: `updatedAt` is data for the badge, and the
// refresh trigger belongs to the Home-refresh decision.
//
// This file holds the value shapes + the seam + the in-memory default. The
// disk adapter (`path_provider` + `dart:io`) lives in `home_cache_disk_store.dart`
// and is wired only in `main.dart`, mirroring `SettingsStore`.

import 'dart:convert';

import 'catalog_request.dart';
import 'home_rows.dart';
import 'meta.dart';

/// The version tag written into every cache file. A file with any other `v`
/// costs exactly one rail, never the Home.
const int kHomeCacheVersion = 1;

/// One cached rail: the last good `items` + `hasMore` and the ms-since-epoch
/// `updatedAt` the age badge renders. Order/visibility/`tmdbKey` are composition
/// and never appear here.
class CachedRail {
  final List<Meta> items;
  final bool hasMore;
  final int updatedAt;

  const CachedRail({
    required this.items,
    this.hasMore = false,
    required this.updatedAt,
  });
}

/// A cached Stremboxd manifest. The `manifestUrl` is part of the identity so a
/// different account's cached manifest is never served as a fallback; a fresh
/// manifest failure only falls back to the manifest for the *same* URL.
class CachedManifest {
  final String manifestUrl;
  final String body; // the raw manifest body, re-parsed on load
  final int updatedAt;

  const CachedManifest({
    required this.manifestUrl,
    required this.body,
    required this.updatedAt,
  });
}

/// The identity of a cached rail: its `rowKey`, plus the Stremboxd
/// `manifestUrl` for Letterboxd rails (changing accounts invalidates those).
/// Two identities are equal iff both parts match.
class HomeCacheIdentity {
  final String rowKey;
  final String? manifestUrl;

  const HomeCacheIdentity(this.rowKey, {this.manifestUrl});

  /// A filesystem-safe, deterministic token for this identity, used as the
  /// in-memory key and the disk file's stem. base64url never emits path
  /// separators, so a URL-bearing Letterboxd identity is safe to name a file.
  String get token => base64Url
      .encode(utf8.encode('$rowKey\u0000${manifestUrl ?? ''}'))
      .replaceAll('=', '');

  @override
  bool operator ==(Object other) =>
      other is HomeCacheIdentity &&
      other.rowKey == rowKey &&
      other.manifestUrl == manifestUrl;

  @override
  int get hashCode => Object.hash(rowKey, manifestUrl);
}

/// Persistence seam for the per-rail cache. Defaults to an in-memory store; the
/// disk-backed implementation is wired only in the app bootstrap. Tests override.
abstract interface class HomeCacheStore {
  /// The cached rail for [identity], or null when absent/corrupt/version-
  /// mismatched — a bad entry costs one rail, never the Home.
  Future<CachedRail?> loadRail(HomeCacheIdentity identity);

  Future<void> saveRail(HomeCacheIdentity identity, CachedRail rail);

  /// The cached manifest for [manifestUrl], or null when absent, corrupt,
  /// version-mismatched, or belonging to a different URL.
  Future<CachedManifest?> loadManifest(String manifestUrl);

  Future<void> saveManifest(CachedManifest manifest);

  /// Removes rail entries whose identity is not in [live]. The manifest entry
  /// is left alone; order/visibility/`tmdbKey` never make a rail an orphan.
  Future<void> sweep(Iterable<HomeCacheIdentity> live);
}

/// In-memory cache store. Default seam for tests; holds state for the process
/// lifetime only.
class InMemoryHomeCacheStore implements HomeCacheStore {
  final Map<String, CachedRail> _rails = {};
  CachedManifest? _manifest;

  @override
  Future<CachedRail?> loadRail(HomeCacheIdentity identity) async =>
      _rails[identity.token];

  @override
  Future<void> saveRail(HomeCacheIdentity identity, CachedRail rail) async {
    _rails[identity.token] = rail;
  }

  @override
  Future<CachedManifest?> loadManifest(String manifestUrl) async {
    final manifest = _manifest;
    return manifest != null && manifest.manifestUrl == manifestUrl
        ? manifest
        : null;
  }

  @override
  Future<void> saveManifest(CachedManifest manifest) async {
    _manifest = manifest;
  }

  @override
  Future<void> sweep(Iterable<HomeCacheIdentity> live) async {
    final keep = {for (final identity in live) identity.token};
    _rails.removeWhere((token, _) => !keep.contains(token));
  }
}

/// The identities the cache may legitimately hold for [request]: every known
/// built-in rail, plus every known Letterboxd rail for the configured manifest
/// URL. Deliberately independent of order, visibility, enable/disable and
/// `tmdbKey` — hiding or reordering a rail must never sweep its copy. A changed
/// `manifestUrl` orphans the previous account's Letterboxd entries, which is the
/// one identity change that should.
List<HomeCacheIdentity> cacheIdentitiesFor(CatalogRequest request) {
  final manifestUrl = request.letterboxd.manifestUrl.trim();
  return [
    for (final row in kAllBuiltInRows) HomeCacheIdentity(row.id),
    if (manifestUrl.isNotEmpty)
      for (final key in kLetterboxdRowKeys)
        HomeCacheIdentity(key, manifestUrl: manifestUrl),
  ];
}

/// Serializes a rail entry to the versioned on-disk shape. Pure so tests can pin
/// the wire shape without touching the filesystem.
String encodeCachedRail(CachedRail rail) => jsonEncode({
      'v': kHomeCacheVersion,
      'updatedAt': rail.updatedAt,
      'items': [for (final item in rail.items) item.toJson()],
      'hasMore': rail.hasMore,
    });

/// Parses a rail entry. Null on corruption, a non-map body, a missing
/// `updatedAt`, or any version other than [kHomeCacheVersion].
CachedRail? decodeCachedRail(String raw) {
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) return null;
    if ((decoded['v'] as num?)?.toInt() != kHomeCacheVersion) return null;
    final updatedAt = (decoded['updatedAt'] as num?)?.toInt();
    if (updatedAt == null) return null;
    final rawItems = decoded['items'];
    if (rawItems is! List) return null;
    final items = <Meta>[];
    for (final item in rawItems) {
      if (item is! Map<String, dynamic>) return null;
      items.add(Meta.fromJson(item));
    }
    return CachedRail(
      items: items,
      hasMore: decoded['hasMore'] as bool? ?? false,
      updatedAt: updatedAt,
    );
  } catch (_) {
    return null;
  }
}

/// Serializes the manifest entry to its versioned shape.
String encodeCachedManifest(CachedManifest manifest) => jsonEncode({
      'v': kHomeCacheVersion,
      'updatedAt': manifest.updatedAt,
      'manifestUrl': manifest.manifestUrl,
      'body': manifest.body,
    });

/// Parses the manifest entry. Null on corruption, version mismatch, or a
/// missing URL/body.
CachedManifest? decodeCachedManifest(String raw) {
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) return null;
    if ((decoded['v'] as num?)?.toInt() != kHomeCacheVersion) return null;
    final updatedAt = (decoded['updatedAt'] as num?)?.toInt();
    final manifestUrl = decoded['manifestUrl'] as String?;
    final body = decoded['body'] as String?;
    if (updatedAt == null || manifestUrl == null || body == null) return null;
    return CachedManifest(
      manifestUrl: manifestUrl,
      body: body,
      updatedAt: updatedAt,
    );
  } catch (_) {
    return null;
  }
}
