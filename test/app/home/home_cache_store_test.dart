// Tests for the per-rail Home cache seam (ticket 72, ADR-0004).
//
// Pins the versioned entry shape, corruption/version-mismatch costing one rail,
// identity (`rowKey` + `manifestUrl`), the manifest entry's URL scoping, and the
// orphan sweep. The disk adapter is exercised against a real temp directory
// (atomic temp+rename, corrupted file, version bump, sweep); the real
// `path_provider` app-support resolution is left to the device.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:harbor_companion/app/home/catalog_request.dart';
import 'package:harbor_companion/app/home/home_cache_disk_store.dart';
import 'package:harbor_companion/app/home/home_cache_store.dart';
import 'package:harbor_companion/app/home/home_rows.dart';
import 'package:harbor_companion/app/letterboxd/letterboxd.dart';
import 'package:harbor_companion/app/home/meta.dart';

Meta movie(String id) => Meta(id: id, type: 'movie', name: 'Title $id');

CachedRail rail({String id = 'tt1', int updatedAt = 100, bool hasMore = false}) =>
    CachedRail(items: [movie(id)], hasMore: hasMore, updatedAt: updatedAt);

const watchlist = HomeCacheIdentity(
  'letterboxd:letterboxd-watchlist',
  manifestUrl: 'https://a/manifest.json',
);

void main() {
  group('entry serialization', () {
    test('writes and reads the versioned shape', () {
      final raw = encodeCachedRail(rail(id: 'tt9', updatedAt: 42, hasMore: true));
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      expect(decoded['v'], kHomeCacheVersion);
      expect(decoded['updatedAt'], 42);
      expect(decoded['hasMore'], true);
      expect((decoded['items'] as List).single['id'], 'tt9');

      final back = decodeCachedRail(raw)!;
      expect(back.items.single.name, 'Title tt9');
      expect(back.updatedAt, 42);
      expect(back.hasMore, isTrue);
    });

    test('corruption returns null, never throws', () {
      expect(decodeCachedRail('{not json'), isNull);
      expect(decodeCachedRail('[]'), isNull);
      expect(decodeCachedRail('{"v":1,"items":[]}'), isNull); // no updatedAt
      expect(decodeCachedRail('{"v":1,"updatedAt":1,"items":"x"}'), isNull);
      expect(decodeCachedRail('{"v":1,"updatedAt":1,"items":[1]}'), isNull);
    });

    test('a version bump costs the rail', () {
      expect(
        decodeCachedRail('{"v":2,"updatedAt":1,"items":[],"hasMore":false}'),
        isNull,
      );
    });

    test('the manifest entry is versioned and scoped to its URL', () {
      final raw = encodeCachedManifest(const CachedManifest(
        manifestUrl: 'https://a/manifest.json',
        body: '{"catalogs":[]}',
        updatedAt: 7,
      ));
      final back = decodeCachedManifest(raw)!;
      expect(back.manifestUrl, 'https://a/manifest.json');
      expect(back.updatedAt, 7);
      expect(decodeCachedManifest('{"v":2,"updatedAt":1,"manifestUrl":"x","body":"y"}'),
          isNull);
    });
  });

  group('identity', () {
    test('built-in identity ignores a manifest URL; Letterboxd identity needs it',
        () {
      expect(
        const HomeCacheIdentity('cinemeta:top-movies'),
        const HomeCacheIdentity('cinemeta:top-movies'),
      );
      expect(
        const HomeCacheIdentity('letterboxd:letterboxd-watchlist',
            manifestUrl: 'https://a/manifest.json'),
        isNot(const HomeCacheIdentity('letterboxd:letterboxd-watchlist',
            manifestUrl: 'https://b/manifest.json')),
      );
    });

    test('cacheIdentitiesFor is order/visibility/tmdbKey independent', () {
      const order = ['cinemeta:top-movies', 'letterboxd:letterboxd-watchlist'];
      final base = cacheIdentitiesFor(CatalogRequest(
        letterboxd: const LetterboxdConfig(
          manifestUrl: 'https://a/manifest.json',
          enabledCatalogIds: {'letterboxd-watchlist'},
        ),
        rowOrder: order,
      ));
      final hidden = cacheIdentitiesFor(CatalogRequest(
        tmdbKey: 'key',
        letterboxd: const LetterboxdConfig(
          manifestUrl: 'https://a/manifest.json',
          enabledCatalogIds: {'letterboxd-watchlist'},
        ),
        disabledBuiltInRowKeys: {for (final r in kCinemetaRows) r.id},
        rowOrder: order.reversed.toList(),
      ));
      expect(base.toSet(), hidden.toSet());
      // Every built-in and the active manifest's Letterboxd rail are live.
      expect(base, contains(const HomeCacheIdentity('cinemeta:top-movies')));
      expect(base, contains(watchlist));
      expect(
        base,
        isNot(contains(const HomeCacheIdentity(
          'letterboxd:letterboxd-watchlist',
          manifestUrl: 'https://other/manifest.json',
        ))),
      );
    });
  });

  group('in-memory store', () {
    test('round-trips rails and manifests, and scopes the manifest URL', () async {
      final store = InMemoryHomeCacheStore();
      await store.saveRail(watchlist, rail(id: 'w1'));
      await store.saveManifest(const CachedManifest(
        manifestUrl: 'https://a/manifest.json',
        body: 'body',
        updatedAt: 1,
      ));

      expect((await store.loadRail(watchlist))!.items.single.id, 'w1');
      expect(await store.loadRail(const HomeCacheIdentity(
        'letterboxd:letterboxd-watchlist',
        manifestUrl: 'https://b/manifest.json',
      )), isNull);
      expect((await store.loadManifest('https://a/manifest.json'))!.body, 'body');
      expect(await store.loadManifest('https://b/manifest.json'), isNull);
    });

    test('sweep drops orphans and keeps the manifest', () async {
      final store = InMemoryHomeCacheStore();
      await store.saveRail(const HomeCacheIdentity('cinemeta:top-movies'), rail());
      await store.saveRail(watchlist, rail());
      await store.saveManifest(const CachedManifest(
        manifestUrl: 'https://a/manifest.json',
        body: 'b',
        updatedAt: 1,
      ));

      await store.sweep([const HomeCacheIdentity('cinemeta:top-movies')]);

      expect(await store.loadRail(const HomeCacheIdentity('cinemeta:top-movies')),
          isNotNull);
      expect(await store.loadRail(watchlist), isNull);
      expect(await store.loadManifest('https://a/manifest.json'), isNotNull);
    });
  });

  group('disk store', () {
    late Directory base;
    late HomeCacheDiskStore store;

    setUp(() async {
      base = await Directory.systemTemp.createTemp('home-cache-test');
      store = HomeCacheDiskStore(directory: base);
    });

    tearDown(() async {
      if (await base.exists()) await base.delete(recursive: true);
    });

    Future<File> firstRailFile() async {
      final files = await base
          .list(recursive: true)
          .where((e) => e is File && e.path.contains('rail_'))
          .cast<File>()
          .toList();
      return files.single;
    }

    test('round-trips a rail with no temp file left behind', () async {
      await store.saveRail(const HomeCacheIdentity('cinemeta:top-movies'), rail(id: 'tt5'));
      final loaded = await store.loadRail(const HomeCacheIdentity('cinemeta:top-movies'));
      expect(loaded!.items.single.id, 'tt5');

      final tempFiles = await base
          .list(recursive: true)
          .where((e) => e is File && e.path.endsWith('.tmp'))
          .toList();
      expect(tempFiles, isEmpty, reason: 'atomic write renames the temp away');
    });

    test('distinguishes identities by manifest URL', () async {
      await store.saveRail(watchlist, rail(id: 'a'));
      await store.saveRail(
        const HomeCacheIdentity('letterboxd:letterboxd-watchlist',
            manifestUrl: 'https://b/manifest.json'),
        rail(id: 'b'),
      );

      expect(
        (await store.loadRail(watchlist))!.items.single.id,
        'a',
      );
      expect(
        (await store.loadRail(const HomeCacheIdentity(
          'letterboxd:letterboxd-watchlist',
          manifestUrl: 'https://b/manifest.json',
        )))!
            .items
            .single
            .id,
        'b',
      );
    });

    test('a corrupted file costs one rail, not the store', () async {
      await store.saveRail(const HomeCacheIdentity('cinemeta:top-movies'), rail());
      final file = await firstRailFile();
      await file.writeAsString('{ this is not json');
      expect(await store.loadRail(const HomeCacheIdentity('cinemeta:top-movies')),
          isNull);
    });

    test('a version-mismatched file costs one rail', () async {
      await store.saveRail(const HomeCacheIdentity('cinemeta:top-movies'), rail());
      final file = await firstRailFile();
      await file.writeAsString(
          '{"v":99,"updatedAt":1,"items":[],"hasMore":false}');
      expect(await store.loadRail(const HomeCacheIdentity('cinemeta:top-movies')),
          isNull);
    });

    test('sweep removes orphan rail files and keeps live ones + the manifest',
        () async {
      await store.saveRail(const HomeCacheIdentity('cinemeta:top-movies'), rail());
      await store.saveRail(watchlist, rail());
      await store.saveManifest(const CachedManifest(
        manifestUrl: 'https://a/manifest.json',
        body: 'body',
        updatedAt: 1,
      ));

      await store.sweep([const HomeCacheIdentity('cinemeta:top-movies')]);

      expect(await store.loadRail(const HomeCacheIdentity('cinemeta:top-movies')),
          isNotNull);
      expect(await store.loadRail(watchlist), isNull);
      expect(await store.loadManifest('https://a/manifest.json'), isNotNull);
    });

    test('a saved manifest is only loadable for its own URL', () async {
      await store.saveManifest(const CachedManifest(
        manifestUrl: 'https://a/manifest.json',
        body: '{"catalogs":[]}',
        updatedAt: 3,
      ));
      expect(
        (await store.loadManifest('https://a/manifest.json'))!.updatedAt,
        3,
      );
      expect(await store.loadManifest('https://b/manifest.json'), isNull);
    });
  });
}
