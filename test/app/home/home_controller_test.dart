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

  /// Grid page requests, in order, as `(rowKey, cursor)`.
  final List<(String, int)> pageRequests = [];

  /// The page [fetchRailPage] returns; default is an empty, ended page.
  RailPage Function(String rowKey, int cursor)? pageFor;

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
  Future<RailPage> fetchRailPage(
    CatalogRequest request,
    String rowKey,
    int cursor,
  ) async {
    pageRequests.add((rowKey, cursor));
    return pageFor?.call(rowKey, cursor) ?? const RailPage(items: []);
  }

  @override
  Future<DetailMeta> fetchDetail(String type, String id, String? tmdbKey) async =>
      DetailMeta(meta: Meta(id: id, type: type, name: 'Detail'));
}

/// Lets the settings restore + the resulting fetch microtasks settle.
Future<void> settle() => Future<void>.delayed(Duration.zero);

/// A fetcher whose rail stream is held open so a test controls exactly when the
/// round settles — used to pin coalescing (a pull joining an in-flight round).
class ControllableCatalogFetcher implements CatalogFetcher {
  final List<CatalogRequest> rowRequests = [];
  StreamController<HomeRailOutcome>? _rails;

  @override
  Stream<HomeRailOutcome> fetchRails(CatalogRequest request) {
    rowRequests.add(request);
    return (_rails = StreamController<HomeRailOutcome>()).stream;
  }

  void emit(HomeRailOutcome outcome) => _rails!.add(outcome);

  void finish() => _rails?.close();

  @override
  Future<HomeRailOutcome> fetchRail(CatalogRequest request, String rowKey) async =>
      HomeRailAbsent(rowKey);

  @override
  Future<RailPage> fetchRailPage(
    CatalogRequest request,
    String rowKey,
    int cursor,
  ) async =>
      const RailPage(items: []);

  @override
  Future<DetailMeta> fetchDetail(String type, String id, String? tmdbKey) async =>
      DetailMeta(meta: Meta(id: id, type: type, name: 'Detail'));
}

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
  Future<void> saveRail(HomeCacheIdentity identity, CachedRail rail) {
    log.add('save:${identity.rowKey}');
    return super.saveRail(identity, rail);
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

    test('a fresh loaded outcome persists the source hasMore (ticket 75)',
        () async {
      final cache = InMemoryHomeCacheStore();
      final fetcher = RecordingCatalogFetcher();
      fetcher.outcomes[firstKey] = () => HomeRailLoaded(
            firstKey,
            'Top Movies',
            [Meta(id: 'tt1', type: 'movie', name: 'A')],
            hasMore: true,
          );
      final container = make(fetcher, InMemorySettingsStore(), cacheStore: cache);
      addTearDown(container.dispose);

      container.read(homeControllerProvider.notifier).load();
      await settle();

      final saved = await cache.loadRail(const HomeCacheIdentity(firstKey));
      expect(saved, isNotNull);
      expect(saved!.hasMore, isTrue);
    });

    test('a successful local retry writes the loaded rail to the cache', () async {
      final cache = InMemoryHomeCacheStore();
      final fetcher = RecordingCatalogFetcher();
      fetcher.outcomes[firstKey] = () =>
          HomeRailFailed(firstKey, Exception('down'));
      final container = make(
        fetcher,
        InMemorySettingsStore(),
        cacheStore: cache,
        clock: () => 4242,
      );
      addTearDown(container.dispose);
      final notifier = container.read(homeControllerProvider.notifier);

      notifier.load();
      await settle();
      expect(await cache.loadRail(const HomeCacheIdentity(firstKey)), isNull,
          reason: 'a failed rail is never cached');

      fetcher.outcomes[firstKey] = () => HomeRailLoaded(
            firstKey,
            'Top Movies',
            [Meta(id: 'tt1', type: 'movie', name: 'The Matrix')],
            hasMore: true,
          );
      notifier.retryRail(firstKey);
      await pumpEventQueue();

      final saved = await cache.loadRail(const HomeCacheIdentity(firstKey));
      expect(saved, isNotNull,
          reason: 'the retry outcome follows the same cache-write path');
      expect(saved!.items.single.name, 'The Matrix');
      expect(saved.hasMore, isTrue);
      expect(saved.updatedAt, 4242);
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

  group('refresh triggers (ticket 74)', () {
    test('load is a no-op after the first process round', () async {
      final fetcher = RecordingCatalogFetcher();
      final container = make(fetcher, InMemorySettingsStore());
      addTearDown(container.dispose);
      final notifier = container.read(homeControllerProvider.notifier);

      notifier.load();
      await settle();
      notifier.load();
      await settle();

      expect(fetcher.rowRequests, hasLength(1));
    });

    test('a pull during an in-flight round joins it and resolves with it',
        () async {
      final fetcher = ControllableCatalogFetcher();
      final container = make(fetcher, InMemorySettingsStore());
      addTearDown(container.dispose);
      final notifier = container.read(homeControllerProvider.notifier);

      notifier.load();
      await settle();
      expect(fetcher.rowRequests, hasLength(1));

      var refreshed = false;
      final pull = notifier.refresh().whenComplete(() => refreshed = true);
      await settle();
      expect(fetcher.rowRequests, hasLength(1), reason: 'joined, not restarted');
      expect(refreshed, isFalse, reason: 'round still in flight');

      final keys = planHomeRowKeys(fetcher.rowRequests.single);
      fetcher.emit(HomeRailLoaded(keys.first, 'Top Movies', [
        Meta(id: 'tt1', type: 'movie', name: 'The Matrix'),
      ]));
      await settle();
      expect(refreshed, isFalse, reason: 'more rails still pending');

      for (final key in keys.skip(1)) {
        fetcher.emit(HomeRailAbsent(key));
      }
      await pull;
      expect(refreshed, isTrue);
      final state = container.read(homeControllerProvider);
      expect(state.roundInFlight, isFalse);
      expect(state.roundSummary, isNotNull);
    });

    test('a stream ending early settles the round instead of hanging it',
        () async {
      final fetcher = ControllableCatalogFetcher();
      final container = make(fetcher, InMemorySettingsStore());
      addTearDown(container.dispose);
      final notifier = container.read(homeControllerProvider.notifier);

      notifier.load();
      await settle();
      final keys = planHomeRowKeys(fetcher.rowRequests.single);
      fetcher.emit(HomeRailLoaded(keys.first, 'Top Movies', [
        Meta(id: 'tt1', type: 'movie', name: 'The Matrix'),
      ]));
      await settle();

      fetcher.finish();
      await settle();

      final state = container.read(homeControllerProvider);
      expect(state.roundInFlight, isFalse);
      expect(state.roundSummary, isNotNull);
      expect(state.hasPending, isFalse);
    });

    test('a pull after settle starts a new round and resolves at its end',
        () async {
      final fetcher = RecordingCatalogFetcher();
      final container = make(fetcher, InMemorySettingsStore());
      addTearDown(container.dispose);
      final notifier = container.read(homeControllerProvider.notifier);

      notifier.load();
      await settle();
      expect(fetcher.rowRequests, hasLength(1));

      await notifier.refresh();
      expect(fetcher.rowRequests, hasLength(2));
      final state = container.read(homeControllerProvider);
      expect(state.roundInFlight, isFalse);
      expect(state.roundSummary, isNotNull);
    });

    test('a fully-failed manual round reports a notify summary', () async {
      final fetcher = RecordingCatalogFetcher();
      final container = make(fetcher, InMemorySettingsStore());
      addTearDown(container.dispose);
      final notifier = container.read(homeControllerProvider.notifier);

      final keys =
          planHomeRowKeys(container.read(homeControllerProvider).request);
      for (final key in keys) {
        fetcher.outcomes[key] = () => HomeRailAbsent(key);
      }
      notifier.load();
      await settle();

      for (final key in keys) {
        fetcher.outcomes[key] = () => HomeRailFailed(key, Exception('down'));
      }
      await notifier.refresh();
      final summary = container.read(homeControllerProvider).roundSummary!;
      expect(summary.manual, isTrue);
      expect(summary.allFailed, isTrue);
      expect(summary.notifyFailure, isTrue);
    });
  });

  group('rail grid (ticket 76)', () {
    const firstKey = 'cinemeta:top-movies';

    test('opening a grid snapshots the rail without fetching or caching',
        () async {
      final log = <String>[];
      final cache = LoggingCacheStore(log);
      final fetcher = RecordingCatalogFetcher();
      final container =
          make(fetcher, InMemorySettingsStore(), cacheStore: cache);
      addTearDown(container.dispose);
      final notifier = container.read(homeControllerProvider.notifier);

      notifier.load();
      await settle();
      await settle();
      final fetchesAfterLoad = fetcher.rowRequests.length;
      log.clear();

      notifier.openRailGrid(firstKey);
      await settle();

      final state = container.read(homeControllerProvider);
      expect(state.activeRailGrid!.rowKey, firstKey);
      expect(state.activeRailGrid!.items, isNotEmpty);
      expect(fetcher.rowRequests.length, fetchesAfterLoad,
          reason: 'the grid opens on what was already downloaded');
      expect(log.where((entry) => entry.startsWith('save:')), isEmpty,
          reason: 'nothing is written to the rail cache by opening the grid');
      expect(log, isEmpty, reason: 'no cache read either');
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

  group('rail grid pagination (ticket 77)', () {
    const firstKey = 'cinemeta:top-movies';

    /// Loads the Home and opens [firstKey]'s grid, leaving the state ready to
    /// page. The rail has exactly one item and reports a continuation, so the
    /// open cursor is 1 and the grid is not already ended.
    Future<HomeController> openGrid(
      RecordingCatalogFetcher fetcher,
      ProviderContainer container,
    ) async {
      fetcher.outcomes[firstKey] = () => HomeRailLoaded(
            firstKey,
            'Top Movies',
            [Meta(id: 'tt-1', type: 'movie', name: 'One')],
            hasMore: true,
          );
      final notifier = container.read(homeControllerProvider.notifier);
      notifier.load();
      await pumpEventQueue();
      notifier.openRailGrid(firstKey);
      await settle();
      return notifier;
    }

    test('loading more fetches the snapshot cursor and appends the page',
        () async {
      final fetcher = RecordingCatalogFetcher();
      final container = make(fetcher, InMemorySettingsStore());
      addTearDown(container.dispose);
      final notifier = await openGrid(fetcher, container);
      expect(container.read(homeControllerProvider).activeRailGrid!.items,
          hasLength(1));

      fetcher.pageFor = (key, cursor) => RailPage(
            items: [Meta(id: 'next', type: 'movie', name: 'Next')],
            hasMore: false,
          );
      notifier.loadMoreRailGrid();
      await pumpEventQueue();

      expect(fetcher.pageRequests, [(firstKey, 1)]);
      final grid = container.read(homeControllerProvider).activeRailGrid!;
      expect(grid.items.last.id, 'next');
      expect(grid.ended, isTrue);
    });

    test('a duplicate page is deduped and ends instead of looping', () async {
      final fetcher = RecordingCatalogFetcher();
      final container = make(fetcher, InMemorySettingsStore());
      addTearDown(container.dispose);
      final notifier = await openGrid(fetcher, container);
      final loadedId =
          container.read(homeControllerProvider).activeRailGrid!.items.single.id;

      fetcher.pageFor = (key, cursor) => RailPage(
            items: [Meta(id: loadedId, type: 'movie', name: 'Same')],
            hasMore: true,
          );
      notifier.loadMoreRailGrid();
      await pumpEventQueue();

      final grid = container.read(homeControllerProvider).activeRailGrid!;
      expect(grid.items, hasLength(1), reason: 'the repeated id is dropped');
      expect(grid.ended, isTrue,
          reason: 'no new ids can never advance the cursor');
    });

    test('a page failure keeps the loaded items and a retry re-fetches',
        () async {
      final fetcher = RecordingCatalogFetcher();
      final container = make(fetcher, InMemorySettingsStore());
      addTearDown(container.dispose);
      final notifier = await openGrid(fetcher, container);

      fetcher.pageFor = (key, cursor) => throw Exception('boom');
      notifier.loadMoreRailGrid();
      await pumpEventQueue();
      var grid = container.read(homeControllerProvider).activeRailGrid!;
      expect(grid.items, hasLength(1));
      expect(grid.error, contains('boom'));

      fetcher.pageFor = (key, cursor) => RailPage(
            items: [Meta(id: 'next', type: 'movie', name: 'Next')],
            hasMore: false,
          );
      notifier.retryRailGridPage();
      await pumpEventQueue();

      grid = container.read(homeControllerProvider).activeRailGrid!;
      expect(grid.error, isNull);
      expect(grid.items.any((m) => m.id == 'next'), isTrue);
      expect(fetcher.pageRequests, [(firstKey, 1), (firstKey, 1)]);
    });

    test('a second scroll while a page is in flight is ignored', () async {
      final fetcher = RecordingCatalogFetcher();
      final container = make(fetcher, InMemorySettingsStore());
      addTearDown(container.dispose);
      final notifier = await openGrid(fetcher, container);

      fetcher.pageFor = (key, cursor) => const RailPage(items: []);
      notifier.loadMoreRailGrid();
      notifier.loadMoreRailGrid();
      await pumpEventQueue();
      expect(fetcher.pageRequests, hasLength(1));
    });
  });
}
