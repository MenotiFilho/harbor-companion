// Thin wiring tests for the Home controller (tickets 41, 71). The reducer is
// the decision seam; these pin the glue: the config handed to the fetcher, a
// Settings change starting a new round, the per-rail outcomes being folded in as
// they stream, and the local retry hitting the single-rail fetch seam.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:harbor_companion/app/home/catalog_fetcher.dart';
import 'package:harbor_companion/app/home/catalog_request.dart';
import 'package:harbor_companion/app/home/home_cache_store.dart';
import 'package:harbor_companion/app/home/home_controller.dart';
import 'package:harbor_companion/app/home/home_rail.dart';
import 'package:harbor_companion/app/letterboxd/letterboxd.dart';
import 'package:harbor_companion/app/home/meta.dart';
import 'package:harbor_companion/app/settings/settings_controller.dart';
import 'package:harbor_companion/app/settings/settings_store.dart';
import 'package:harbor_companion/app/ws/client_controller.dart';
import 'package:harbor_companion/app/ws/ws_transport.dart';

class FakeConnection implements WsConnection {
  final _frames = StreamController<String>.broadcast();
  @override
  Stream<String> get frames => _frames.stream;
  @override
  void send(String message) {}
  @override
  Future<void> close() async => _frames.close();
}

class FakeTransport implements WsTransport {
  @override
  Future<WsConnection> open(String url) async => FakeConnection();
}

/// Records the [CatalogRequest] handed to each fetch and lets a test override a
/// rail's outcome (default: a loaded row with one item). Single-rail retries are
/// recorded separately.
class RecordingCatalogFetcher implements CatalogFetcher {
  final List<CatalogRequest> rowRequests = [];
  final List<String> retriedKeys = [];
  final Map<String, HomeRailOutcome Function()> outcomes = {};

  /// Called synchronously when [fetchRails] starts, so a test can interleave a
  /// cache-read log with the network hand-off.
  void Function()? onFetch;

  HomeRailOutcome _outcome(String key) =>
      outcomes[key]?.call() ??
      HomeRailLoaded(key, 'Row $key', [Meta(id: 'tt-$key', type: 'movie', name: key)]);

  @override
  Stream<HomeRailOutcome> fetchRails(CatalogRequest request) {
    onFetch?.call();
    rowRequests.add(request);
    return Stream.fromIterable([
      for (final key in planHomeRowKeys(request)) _outcome(key),
    ]);
  }

  @override
  Future<HomeRailOutcome> fetchRail(CatalogRequest request, String rowKey) async {
    retriedKeys.add(rowKey);
    return _outcome(rowKey);
  }

  @override
  Future<DetailMeta> fetchDetail(String type, String id, String? tmdbKey) async =>
      DetailMeta(meta: Meta(id: id, type: type, name: 'Detail'));
}

/// Lets the settings restore + the resulting fetch microtasks settle.
Future<void> settle() => Future<void>.delayed(Duration.zero);

/// Cache store that records its reads/sweeps so a test can prove the cache is
/// consulted before the network round.
class LoggingCacheStore extends InMemoryHomeCacheStore {
  final List<String> log;
  LoggingCacheStore(this.log);

  @override
  Future<CachedRail?> loadRail(HomeCacheIdentity identity) {
    log.add('load:${identity.rowKey}');
    return super.loadRail(identity);
  }

  @override
  Future<void> sweep(Iterable<HomeCacheIdentity> live) {
    log.add('sweep');
    return super.sweep(live);
  }
}

ProviderContainer make(
  CatalogFetcher fetcher,
  SettingsStore store, {
  HomeCacheStore? cacheStore,
  int Function()? clock,
}) =>
    ProviderContainer(
      overrides: [
        wsTransportProvider.overrideWithValue(FakeTransport()),
        wsKeyStoreProvider.overrideWithValue(InMemoryHostKeyStore()),
        catalogFetcherProvider.overrideWithValue(fetcher),
        settingsStoreProvider.overrideWithValue(store),
        homeCacheStoreProvider
            .overrideWithValue(cacheStore ?? InMemoryHomeCacheStore()),
        if (clock != null) homeCacheClockProvider.overrideWithValue(clock),
      ],
    );

void main() {
  const firstKey = 'cinemeta:top-movies';

  test('load passes the seeded Letterboxd config (URL empty, defaults on)', () async {
    final fetcher = RecordingCatalogFetcher();
    final container = make(fetcher, InMemorySettingsStore());
    addTearDown(container.dispose);

    container.read(homeControllerProvider.notifier).load();
    await settle();

    expect(fetcher.rowRequests, hasLength(1));
    expect(fetcher.rowRequests.single.letterboxd.manifestUrl, '');
    expect(
      fetcher.rowRequests.single.letterboxd.enabledCatalogIds,
      kDefaultLetterboxdCatalogIds,
    );
    expect(fetcher.rowRequests.single.showBuiltInCatalogs, isTrue);
  });

  test('folds one outcome per planned rail as it streams', () async {
    final fetcher = RecordingCatalogFetcher();
    fetcher.outcomes['cinemeta:top-series'] = () =>
        HomeRailFailed('cinemeta:top-series', Exception('down'));
    final container = make(fetcher, InMemorySettingsStore());
    addTearDown(container.dispose);

    container.read(homeControllerProvider.notifier).load();
    await settle();

    final state = container.read(homeControllerProvider);
    expect(state.rails[firstKey]!.status, RailStatus.loaded);
    expect(state.rails[firstKey]!.items, isNotEmpty);
    expect(state.rails['cinemeta:top-series']!.status, RailStatus.failed);
    expect(state.hasContent, isTrue);
  });

  test('a failed rail with no prior copy can be retried per rail', () async {
    final fetcher = RecordingCatalogFetcher();
    fetcher.outcomes[firstKey] = () =>
        HomeRailFailed(firstKey, Exception('down'));
    final container = make(fetcher, InMemorySettingsStore());
    addTearDown(container.dispose);

    container.read(homeControllerProvider.notifier).load();
    await settle();
    expect(container.read(homeControllerProvider).rails[firstKey]!.status,
        RailStatus.failed);

    // The retry card replaces the outcome with a loaded one.
    fetcher.outcomes[firstKey] = () =>
        HomeRailLoaded(firstKey, 'Top Movies', [Meta(id: 'tt1', type: 'movie', name: 'The Matrix')]);
    container.read(homeControllerProvider.notifier).retryRail(firstKey);
    await settle();

    expect(fetcher.retriedKeys, [firstKey]);
    final state = container.read(homeControllerProvider);
    expect(state.rails[firstKey]!.status, RailStatus.loaded);
    expect(state.rails[firstKey]!.items.single.name, 'The Matrix');
  });

  test('setting the manifest URL starts a round with the active config', () async {
    final fetcher = RecordingCatalogFetcher();
    final container = make(fetcher, InMemorySettingsStore());
    addTearDown(container.dispose);
    container.read(homeControllerProvider); // build + register the listener
    await settle();

    container
        .read(settingsControllerProvider.notifier)
        .setLetterboxdManifestUrl('https://api.stremboxd.com/stremio/abc/manifest.json');
    await settle();

    expect(fetcher.rowRequests, isNotEmpty);
    expect(
      fetcher.rowRequests.last.letterboxd.manifestUrl,
      'https://api.stremboxd.com/stremio/abc/manifest.json',
    );
  });

  test('toggling a catalog refetches with the updated enabled set', () async {
    final fetcher = RecordingCatalogFetcher();
    final container = make(fetcher, InMemorySettingsStore());
    addTearDown(container.dispose);
    container.read(homeControllerProvider);
    await settle();

    container
        .read(settingsControllerProvider.notifier)
        .setLetterboxdCatalogEnabled('letterboxd-friends', true);
    await settle();

    expect(
      fetcher.rowRequests.last.letterboxd.enabledCatalogIds,
      contains('letterboxd-friends'),
    );
  });

  test('toggling a built-in row off refetches with it disabled', () async {
    final fetcher = RecordingCatalogFetcher();
    final container = make(fetcher, InMemorySettingsStore());
    addTearDown(container.dispose);
    container.read(homeControllerProvider);
    await settle();

    container
        .read(settingsControllerProvider.notifier)
        .setBuiltInRowEnabled('cinemeta:top-movies', false);
    await settle();

    expect(
      fetcher.rowRequests.last.disabledBuiltInRowKeys,
      contains('cinemeta:top-movies'),
    );
  });

  test('reordering rows refetches with the new order', () async {
    final fetcher = RecordingCatalogFetcher();
    final container = make(fetcher, InMemorySettingsStore());
    addTearDown(container.dispose);
    container.read(homeControllerProvider);
    await settle();

    container.read(settingsControllerProvider.notifier).moveHomeRow(0, 2);
    await settle();

    expect(fetcher.rowRequests.last.rowOrder[2], 'cinemeta:top-movies');
  });

  test('an unrelated setting change does not refetch the catalog', () async {
    final fetcher = RecordingCatalogFetcher();
    final container = make(fetcher, InMemorySettingsStore());
    addTearDown(container.dispose);
    container.read(homeControllerProvider.notifier).load();
    await settle();
    final calls = fetcher.rowRequests.length;

    container
        .read(settingsControllerProvider.notifier)
        .setShowPlaybackLocation(true);
    await settle();

    expect(fetcher.rowRequests.length, calls);
  });

  test('a persisted URL restored at startup refetches with it', () async {
    final fetcher = RecordingCatalogFetcher();
    final store = InMemorySettingsStore();
    await store.saveLetterboxdManifestUrl('https://api.stremboxd.com/stremio/abc/manifest.json');
    final container = make(fetcher, store);
    addTearDown(container.dispose);

    container.read(homeControllerProvider); // seeds '' before the async restore
    await settle();

    expect(
      fetcher.rowRequests.last.letterboxd.manifestUrl,
      'https://api.stremboxd.com/stremio/abc/manifest.json',
    );
  });

  group('per-rail cache (ticket 72)', () {
    const firstKey = 'cinemeta:top-movies';

    test('reads the cache (and sweeps) before starting the network round',
        () async {
      final log = <String>[];
      final cache = LoggingCacheStore(log);
      final fetcher = RecordingCatalogFetcher()..onFetch = () => log.add('fetch');
      final container = make(fetcher, InMemorySettingsStore(), cacheStore: cache);
      addTearDown(container.dispose);

      container.read(homeControllerProvider.notifier).load();
      await settle();

      final fetchAt = log.indexOf('fetch');
      expect(fetchAt, greaterThan(0));
      expect(log.sublist(0, fetchAt), contains('sweep'));
      expect(
        log.sublist(0, fetchAt).any((e) => e.startsWith('load:')),
        isTrue,
      );
    });

    test('a cached rail renders badged while its fresh fetch fails', () async {
      final cache = InMemoryHomeCacheStore();
      await cache.saveRail(
        const HomeCacheIdentity(firstKey),
        CachedRail(
          items: [Meta(id: 'cached', type: 'movie', name: 'Cached')],
          updatedAt: 1000,
        ),
      );
      final fetcher = RecordingCatalogFetcher();
      fetcher.outcomes[firstKey] = () => HomeRailFailed(firstKey, Exception('down'));
      final container = make(fetcher, InMemorySettingsStore(), cacheStore: cache);
      addTearDown(container.dispose);

      container.read(homeControllerProvider.notifier).load();
      await settle();

      final rail = container.read(homeControllerProvider).rails[firstKey]!;
      expect(rail.items.single.name, 'Cached');
      expect(rail.fromCache, isTrue);
      expect(rail.updatedAt, 1000);
    });

    test('a fresh loaded outcome clears the badge and writes the entry', () async {
      final cache = InMemoryHomeCacheStore();
      final fetcher = RecordingCatalogFetcher();
      final container = make(
        fetcher,
        InMemorySettingsStore(),
        cacheStore: cache,
        clock: () => 7777,
      );
      addTearDown(container.dispose);

      container.read(homeControllerProvider.notifier).load();
      await settle();

      final rail = container.read(homeControllerProvider).rails[firstKey]!;
      expect(rail.fromCache, isFalse);
      expect(rail.updatedAt, isNull);

      final saved = await cache.loadRail(const HomeCacheIdentity(firstKey));
      expect(saved, isNotNull);
      expect(saved!.updatedAt, 7777);
      expect(saved.items, hasLength(1));
    });

    test('a Letterboxd rail caches under rowKey + manifestUrl', () async {
      final cache = InMemoryHomeCacheStore();
      final settings = InMemorySettingsStore();
      await settings
          .saveLetterboxdManifestUrl('https://api.stremboxd.com/stremio/tok/manifest.json');
      final fetcher = RecordingCatalogFetcher();
      final container = make(fetcher, settings, cacheStore: cache);
      addTearDown(container.dispose);

      container.read(homeControllerProvider.notifier).load();
      await settle();

      final manifestUrl = 'https://api.stremboxd.com/stremio/tok/manifest.json';
      final watchlist = HomeCacheIdentity(
        'letterboxd:letterboxd-watchlist',
        manifestUrl: manifestUrl,
      );
      expect(await cache.loadRail(watchlist), isNotNull);
      // A different account's manifest URL does not see the entry.
      expect(
        await cache.loadRail(const HomeCacheIdentity(
          'letterboxd:letterboxd-watchlist',
          manifestUrl: 'https://other/manifest.json',
        )),
        isNull,
      );
    });
  });

  group('adaptive timeout + retry (ticket 73)', () {
    const firstKey = 'cinemeta:top-movies';

    test('a rail that fails after one retry keeps its cached copy; others load',
        () async {
      final cache = InMemoryHomeCacheStore();
      await cache.saveRail(
        const HomeCacheIdentity(firstKey),
        CachedRail(
          items: [Meta(id: 'cached', type: 'movie', name: 'Cached')],
          updatedAt: 1000,
        ),
      );
      var movieGets = 0;
      var seriesGets = 0;
      final fetcher = HttpCatalogFetcher(
        cache: cache,
        timeouts: const HomeRailTimeouts(retryBackoff: Duration.zero),
        get: (url) async {
          if (url.path == '/catalog/movie/top.json') {
            movieGets++;
            throw Exception('down');
          }
          if (url.path == '/catalog/series/top.json') seriesGets++;
          return jsonEncode({'metas': []});
        },
      );
      final container =
          make(fetcher, InMemorySettingsStore(), cacheStore: cache);
      addTearDown(container.dispose);

      container.read(homeControllerProvider.notifier).load();
      await pumpEventQueue();

      expect(movieGets, 2, reason: 'the failed rail is retried exactly once');
      expect(seriesGets, 1, reason: 'a loaded rail is not retried');

      final state = container.read(homeControllerProvider);
      final rail = state.rails[firstKey]!;
      expect(rail.status, RailStatus.failed);
      // The previous copy survives the final failure, still badged from cache.
      expect(rail.items.single.name, 'Cached');
      expect(rail.fromCache, isTrue);
      expect(rail.updatedAt, 1000);
      // The other rails still settle.
      expect(state.hasPending, isFalse);
    });
  });
}
