// Tests for the catalog JSON mappers (lib/app/home/catalog_fetcher.dart).
//
// Pins the Cinemeta/TMDB wire shapes against representative payloads so the
// Home/catalog mapping (id prefixing, poster URL building, season/episode
// derivation) is exercised without network.

import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:harbor_companion/app/home/catalog_fetcher.dart';
import 'package:harbor_companion/app/home/catalog_request.dart';
import 'package:harbor_companion/app/home/home_cache_store.dart';
import 'package:harbor_companion/app/home/home_rail.dart';
import 'package:harbor_companion/app/home/home_rows.dart';
import 'package:harbor_companion/app/letterboxd/letterboxd.dart';
import 'package:harbor_companion/app/home/meta.dart';

void main() {
  group('cinemeta catalog', () {
    test('maps metas from { "metas": [...] }', () {
      final raw = jsonEncode({
        'metas': [
          {
            'id': 'tt0133093',
            'type': 'movie',
            'name': 'The Matrix',
            'poster': 'https://img/cinema/the-matrix.jpg',
            'releaseInfo': '1999',
          },
          {
            'id': 'tt0903747',
            'type': 'series',
            'name': 'Breaking Bad',
            'poster': 'https://img/cinema/breaking-bad.jpg',
          },
        ],
      });
      final metas = parseCinemetaCatalog(raw);
      expect(metas, hasLength(2));
      expect(metas[0].id, 'tt0133093');
      expect(metas[0].type, 'movie');
      expect(metas[0].poster, 'https://img/cinema/the-matrix.jpg');
      expect(metas[0].releaseInfo, '1999');
      expect(metas[1].type, 'series');
    });

    test('an unknown type falls back to movie', () {
      final metas = parseCinemetaCatalog(jsonEncode({
        'metas': [
          {'id': 'x', 'type': 'whatever', 'name': 'N'},
        ],
      }));
      expect(metas.single.type, 'movie');
    });
  });

  group('tmdb page', () {
    test('maps movie results with tmdb: ids and image URLs', () {
      final raw = jsonEncode({
        'results': [
          {
            'id': 603,
            'title': 'The Matrix',
            'poster_path': '/abc.jpg',
            'backdrop_path': '/def.jpg',
            'overview': 'A hacker…',
            'release_date': '1999-03-30',
          },
        ],
      });
      final metas = parseTmdbPage(raw, 'movie');
      expect(metas.single.id, 'tmdb:movie:603');
      expect(metas.single.name, 'The Matrix');
      expect(metas.single.poster, 'https://image.tmdb.org/t/p/w342/abc.jpg');
      expect(metas.single.background, 'https://image.tmdb.org/t/p/w780/def.jpg');
      expect(metas.single.releaseInfo, '1999');
    });

    test('maps tv results using name + first_air_date', () {
      final raw = jsonEncode({
        'results': [
          {'id': 1396, 'name': 'Breaking Bad', 'first_air_date': '2008-01-20'},
        ],
      });
      final metas = parseTmdbPage(raw, 'series');
      expect(metas.single.name, 'Breaking Bad');
      expect(metas.single.releaseInfo, '2008');
    });

    test('a missing poster path is null, not a broken URL', () {
      final metas = parseTmdbPage(jsonEncode({
        'results': [
          {'id': 1, 'title': 'No Poster'},
        ],
      }), 'movie');
      expect(metas.single.poster, isNull);
    });
  });

  group('cinemeta detail', () {
    test('derives seasons/episodes from videos[]', () {
      final raw = jsonEncode({
        'meta': {
          'id': 'tt0903747',
          'type': 'series',
          'name': 'Breaking Bad',
          'videos': [
            {'name': 'Pilot', 'season': 1, 'episode': 1},
            {'name': 'Cat', 'season': 1, 'episode': 2},
            {'name': 'Seven Thirty-Seven', 'season': 2, 'episode': 1},
          ],
        },
      });
      final detail = parseCinemetaDetail(raw);
      expect(detail.meta.name, 'Breaking Bad');
      expect(detail.seasons, hasLength(2));
      expect(detail.seasons[0].number, 1);
      expect(detail.seasons[0].episodes, hasLength(2));
      expect(detail.seasons[0].firstEpisode!.name, 'Pilot');
      expect(detail.seasons[1].episodes.single.name, 'Seven Thirty-Seven');
    });

    test('a movie detail has no seasons', () {
      final raw = jsonEncode({
        'meta': {'id': 'tt0133093', 'type': 'movie', 'name': 'The Matrix'},
      });
      expect(parseCinemetaDetail(raw).seasons, isEmpty);
    });
  });

  group('detail source routing', () {
    test('a keyed tmdb: id routes to TMDB', () {
      expect(usesTmdbDetail('key', 'tmdb:movie:603'), isTrue);
    });

    test('an imdb id routes to Cinemeta even when a key is present', () {
      expect(usesTmdbDetail('key', 'tt0944947'), isFalse);
    });

    test('a keyless request always routes to Cinemeta', () {
      expect(usesTmdbDetail(null, 'tmdb:movie:603'), isFalse);
      expect(usesTmdbDetail(null, 'tt0944947'), isFalse);
    });
  });

  group('tmdb detail + seasons', () {
    test('tv detail parses seasons and drops season 0 specials', () {
      final raw = jsonEncode({
        'id': 1396,
        'name': 'Breaking Bad',
        'seasons': [
          {'season_number': 0, 'name': 'Specials'},
          {'season_number': 1, 'name': 'Season 1'},
          {'season_number': 2, 'name': 'Season 2'},
        ],
      });
      final seasons = parseTmdbSeasons(raw);
      expect(seasons, hasLength(2));
      expect(seasons.first.number, 1);
    });

    test('season episodes map episode/season numbers and stills', () {
      final raw = jsonEncode({
        'episodes': [
          {'episode_number': 1, 'season_number': 1, 'name': 'Pilot', 'still_path': '/s.jpg'},
          {'episode_number': 2, 'season_number': 1, 'name': 'Cat'},
        ],
      });
      final episodes = parseTmdbSeasonEpisodes(raw, 1);
      expect(episodes, hasLength(2));
      expect(episodes.first.episode, 1);
      expect(episodes.first.still, 'https://image.tmdb.org/t/p/w342/s.jpg');
    });

    test('movie detail parses as a movie meta', () {
      final meta = parseTmdbDetail(jsonEncode({'id': 603, 'title': 'The Matrix'}), 'movie');
      expect(meta.id, 'tmdb:movie:603');
      expect(meta.type, 'movie');
    });
  });

  group('tmdb season episode loading', () {
    test('fills episodes in season order, preserving names and posters', () async {
      Future<List<Episode>> fetch(int season) async => [
            Episode(season: season, episode: 1, name: 'S${season}E1'),
          ];
      final shells = [
        const Season(number: 2, name: 'Season 2', poster: '/p2.jpg'),
        const Season(number: 1, name: 'Season 1', poster: '/p1.jpg'),
      ];
      final seasons = await loadTmdbSeasonEpisodes(shells, fetch);
      expect(seasons.map((s) => s.number), [2, 1]);
      expect(seasons[0].name, 'Season 2');
      expect(seasons[0].poster, '/p2.jpg');
      expect(seasons[0].episodes.single.name, 'S2E1');
    });

    test('kicks off every season fetch before any completes (parallel, not serial)',
        () async {
      final started = <int>[];
      final completers = <int, Completer<List<Episode>>>{};
      Future<List<Episode>> fetch(int season) {
        started.add(season);
        final c = Completer<List<Episode>>();
        completers[season] = c;
        return c.future;
      }

      final shells = [
        const Season(number: 1, name: 'Season 1'),
        const Season(number: 2, name: 'Season 2'),
        const Season(number: 3, name: 'Season 3'),
      ];
      final pending = loadTmdbSeasonEpisodes(shells, fetch);

      // All three fetches started before any completes — a serial await loop
      // would have started only season 1 here.
      expect(started, [1, 2, 3]);

      completers[1]!.complete([Episode(season: 1, episode: 1, name: 'A')]);
      completers[2]!.complete([Episode(season: 2, episode: 1, name: 'B')]);
      completers[3]!.complete(const []);

      final seasons = await pending;
      expect(seasons.map((s) => s.episodes.length), [1, 1, 0]);
    });
  });

  group('row plan', () {
    const active = LetterboxdConfig(
      manifestUrl: 'https://x/manifest.json',
      enabledCatalogIds: {'letterboxd-watchlist'},
    );

    CatalogRequest request({
      String? key,
      LetterboxdConfig letterboxd = const LetterboxdConfig(),
      Set<String> disabled = const {},
      List<String> order = kDefaultHomeRowOrder,
    }) =>
        CatalogRequest(
          tmdbKey: key,
          letterboxd: letterboxd,
          disabledBuiltInRowKeys: disabled,
          rowOrder: order,
        );

    test('keyless plans the Cinemeta rows, not the TMDB ones', () {
      final keys = planHomeRowKeys(request());
      expect(keys, contains('cinemeta:top-movies'));
      expect(keys.any((k) => k.startsWith('tmdb:')), isFalse);
    });

    test('keyed plans the TMDB rows, not the Cinemeta ones', () {
      final keys = planHomeRowKeys(request(key: 'tmdb-key'));
      expect(keys, contains('tmdb:trending-movies'));
      expect(keys.any((k) => k.startsWith('cinemeta:')), isFalse);
    });

    test('disabled built-in rows are dropped', () {
      final keys = planHomeRowKeys(
        request(disabled: {'cinemeta:top-movies'}),
      );
      expect(keys, isNot(contains('cinemeta:top-movies')));
      expect(keys, contains('cinemeta:top-series'));
    });

    test('planning preserves the configured order (Letterboxd first)', () {
      final order = [
        'letterboxd:letterboxd-watchlist',
        'cinemeta:top-series',
        'cinemeta:top-movies',
      ];
      final keys = planHomeRowKeys(request(letterboxd: active, order: order));
      expect(keys, [
        'letterboxd:letterboxd-watchlist',
        'cinemeta:top-series',
        'cinemeta:top-movies',
      ]);
    });

    test('Letterboxd rows need an active config and an enabled catalog', () {
      expect(
        planHomeRowKeys(request(order: ['letterboxd:letterboxd-watchlist'])),
        isEmpty,
      );
      expect(
        planHomeRowKeys(request(
          letterboxd: const LetterboxdConfig(manifestUrl: 'https://x/manifest.json'),
          order: ['letterboxd:letterboxd-watchlist'],
        )),
        isEmpty,
      );
      expect(
        planHomeRowKeys(request(
          letterboxd: active,
          order: ['letterboxd:letterboxd-watchlist'],
        )),
        ['letterboxd:letterboxd-watchlist'],
      );
    });
  });

  group('catalog request', () {
    test('showBuiltInCatalogs tracks the source in effect', () {
      // Keyless → Cinemeta is the active source.
      expect(const CatalogRequest().showBuiltInCatalogs, isTrue);
      // Disabling only TMDB rows leaves the keyless Cinemeta rows showing.
      expect(
        const CatalogRequest(
          disabledBuiltInRowKeys: {'tmdb:upcoming'},
        ).showBuiltInCatalogs,
        isTrue,
      );
      // Disabling every Cinemeta row turns built-ins off for a keyless host.
      expect(
        CatalogRequest(
          disabledBuiltInRowKeys: {for (final r in kCinemetaRows) r.id},
        ).showBuiltInCatalogs,
        isFalse,
      );
      // A keyed host ignores the Cinemeta toggles.
      expect(
        CatalogRequest(
          tmdbKey: 'key',
          disabledBuiltInRowKeys: {for (final r in kCinemetaRows) r.id},
        ).showBuiltInCatalogs,
        isTrue,
      );
    });

    test('copyWith can clear the tmdbKey back to null', () {
      const request = CatalogRequest(tmdbKey: 'key');
      expect(request.copyWith().tmdbKey, 'key');
      expect(request.copyWith(tmdbKey: null).tmdbKey, isNull);
    });
  });

  group('concurrent rail outcomes', () {
    Meta meta(String id) => Meta(id: id, type: 'movie', name: id);

    test('emits one outcome per key; a throwing fetch fails only that rail',
        () async {
      final outcomes = await fetchRailOutcomesConcurrently(['a', 'b', 'c'], (key) async {
        if (key == 'b') throw Exception('boom');
        return HomeRailLoaded(key, key, [meta('tt-$key')]);
      }).toList();

      expect(outcomes.map((o) => o.rowKey).toSet(), {'a', 'b', 'c'});
      expect(outcomes.whereType<HomeRailFailed>().single.rowKey, 'b');
      expect(
        outcomes.whereType<HomeRailLoaded>().map((o) => o.rowKey).toSet(),
        {'a', 'c'},
      );
    });

    test('emits each rail as it completes, not in key order', () async {
      final slow = Completer<HomeRailOutcome>();
      final fast = Completer<HomeRailOutcome>();
      final stream = fetchRailOutcomesConcurrently(
        ['slow', 'fast'],
        (key) => key == 'slow' ? slow.future : fast.future,
      );
      final seen = <String>[];
      final done = stream.listen((o) => seen.add(o.rowKey)).asFuture<void>();

      fast.complete(HomeRailLoaded('fast', 'Fast', [meta('tt-fast')]));
      await Future<void>.delayed(Duration.zero);
      expect(seen, ['fast']);

      slow.complete(HomeRailLoaded('slow', 'Slow', [meta('tt-slow')]));
      await done;
      expect(seen, ['fast', 'slow']);
    });
  });

  group('fetchRails per-rail outcomes', () {
    String cinemeta(List<String> ids) => jsonEncode({
          'metas': [
            for (final id in ids) {'id': id, 'type': 'movie', 'name': id},
          ],
        });

    CatalogRequest keyless({
      List<String> order = const ['cinemeta:top-movies', 'cinemeta:top-series'],
      LetterboxdConfig letterboxd = const LetterboxdConfig(),
    }) =>
        CatalogRequest(rowOrder: order, letterboxd: letterboxd);

    const active = LetterboxdConfig(
      manifestUrl: 'https://api.stremboxd.com/stremio/tok/manifest.json',
      enabledCatalogIds: {'letterboxd-watchlist'},
    );

    test('loaded carries the rail title and its items', () async {
      final fetcher = HttpCatalogFetcher(
        get: (url) async => cinemeta(['tt1', 'tt2']),
      );
      final outcomes = await fetcher.fetchRails(keyless()).toList();

      expect(outcomes, hasLength(2));
      final top = outcomes.whereType<HomeRailLoaded>().first;
      expect(top.rowKey, 'cinemeta:top-movies');
      expect(top.title, 'Top Movies');
      expect(top.items, hasLength(2));
    });

    test('an empty catalog is loaded-empty, not failed or absent', () async {
      final fetcher = HttpCatalogFetcher(
        get: (url) async => cinemeta(const []),
      );
      final outcomes = await fetcher.fetchRails(keyless()).toList();

      final loaded = outcomes.whereType<HomeRailLoaded>();
      expect(loaded, hasLength(2));
      expect(loaded.every((o) => o.items.isEmpty), isTrue);
    });

    test('an HTTP failure fails one rail; the others still load', () async {
      final fetcher = HttpCatalogFetcher(
        get: (url) async {
          if (url.path.contains('/series/')) throw Exception('500');
          return cinemeta(['tt1']);
        },
      );
      final outcomes = await fetcher.fetchRails(keyless()).toList();

      expect(outcomes.whereType<HomeRailFailed>().single.rowKey,
          'cinemeta:top-series');
      expect(outcomes.whereType<HomeRailLoaded>().single.rowKey,
          'cinemeta:top-movies');
    });

    test('a Letterboxd catalog the manifest does not list is absent', () async {
      final fetcher = HttpCatalogFetcher(get: (url) async {
        if (url.path.endsWith('/manifest.json')) {
          return jsonEncode({
            'catalogs': [
              {'id': 'letterboxd-friends', 'type': 'movie', 'name': 'Friends'},
            ],
          });
        }
        return cinemeta(['tt1']);
      });
      final outcomes = await fetcher
          .fetchRails(keyless(
            order: const ['cinemeta:top-movies', 'letterboxd:letterboxd-watchlist'],
            letterboxd: active,
          ))
          .toList();

      expect(
        outcomes.whereType<HomeRailAbsent>().single.rowKey,
        'letterboxd:letterboxd-watchlist',
      );
      expect(outcomes.whereType<HomeRailLoaded>().single.rowKey,
          'cinemeta:top-movies');
    });

    test('a Letterboxd rail not in the manifest loads from the catalog', () async {
      final fetcher = HttpCatalogFetcher(get: (url) async {
        if (url.path.endsWith('/manifest.json')) {
          return jsonEncode({
            'catalogs': [
              {'id': 'letterboxd-watchlist', 'type': 'movie', 'name': 'Watchlist'},
            ],
          });
        }
        return cinemeta(['tt9']);
      });
      final outcomes = await fetcher
          .fetchRails(keyless(
            order: const ['letterboxd:letterboxd-watchlist'],
            letterboxd: active,
          ))
          .toList();

      final loaded = outcomes.single as HomeRailLoaded;
      expect(loaded.title, 'Watchlist');
      expect(loaded.items.single.id, 'tt9');
    });

    test('a manifest failure fails only the Letterboxd rails', () async {
      final fetcher = HttpCatalogFetcher(get: (url) async {
        if (url.path.endsWith('/manifest.json')) throw Exception('timeout');
        return cinemeta(['tt1']);
      });
      final outcomes = await fetcher
          .fetchRails(keyless(
            order: const ['cinemeta:top-movies', 'letterboxd:letterboxd-watchlist'],
            letterboxd: active,
          ))
          .toList();

      expect(
        outcomes.whereType<HomeRailFailed>().single.rowKey,
        'letterboxd:letterboxd-watchlist',
      );
      expect(outcomes.whereType<HomeRailLoaded>().single.rowKey,
          'cinemeta:top-movies');
    });

    test('built-in rails are not gated on a slow Letterboxd manifest', () async {
      final manifest = Completer<String>();
      final fetcher = HttpCatalogFetcher(get: (url) {
        if (url.path.endsWith('/manifest.json')) return manifest.future;
        return Future.value(cinemeta(['tt1']));
      });
      final seen = <String>[];
      final done = fetcher
          .fetchRails(keyless(
            order: const ['cinemeta:top-movies', 'letterboxd:letterboxd-watchlist'],
            letterboxd: active,
          ))
          .listen((o) => seen.add(o.rowKey))
          .asFuture<void>();

      await Future<void>.delayed(Duration.zero);
      expect(seen, ['cinemeta:top-movies']); // manifest still pending

      manifest.complete(jsonEncode({
        'catalogs': [
          {'id': 'letterboxd-watchlist', 'type': 'movie', 'name': 'Watchlist'},
        ],
      }));
      await done;
      expect(seen, contains('letterboxd:letterboxd-watchlist'));
    });

    test('fetchRail re-fetches a single rail', () async {
      final fetcher = HttpCatalogFetcher(get: (url) async => cinemeta(['tt7']));
      final outcome =
          await fetcher.fetchRail(keyless(), 'cinemeta:top-series');

      expect(outcome, isA<HomeRailLoaded>());
      expect(outcome.rowKey, 'cinemeta:top-series');
      expect((outcome as HomeRailLoaded).items.single.id, 'tt7');
    });

    test('a successful manifest is cached for later fallback', () async {
      final cache = InMemoryHomeCacheStore();
      final fetcher = HttpCatalogFetcher(
        cache: cache,
        nowMs: () => 1234,
        get: (url) async {
          if (url.path.endsWith('/manifest.json')) {
            return jsonEncode({
              'catalogs': [
                {'id': 'letterboxd-watchlist', 'type': 'movie', 'name': 'Watchlist'},
              ],
            });
          }
          return cinemeta(['tt1']);
        },
      );
      await fetcher
          .fetchRails(keyless(
            order: const ['letterboxd:letterboxd-watchlist'],
            letterboxd: active,
          ))
          .toList();

      final cached = await cache.loadManifest(active.manifestUrl);
      expect(cached, isNotNull);
      expect(cached!.updatedAt, 1234);
    });

    test('a failed fresh manifest falls back to the cached manifest', () async {
      final cache = InMemoryHomeCacheStore();
      await cache.saveManifest(CachedManifest(
        manifestUrl: active.manifestUrl,
        body: jsonEncode({
          'catalogs': [
            {'id': 'letterboxd-watchlist', 'type': 'movie', 'name': 'Watchlist'},
          ],
        }),
        updatedAt: 1,
      ));
      final fetcher = HttpCatalogFetcher(
        cache: cache,
        get: (url) async {
          if (url.path.endsWith('/manifest.json')) throw Exception('timeout');
          return cinemeta(['tt9']);
        },
      );

      final outcomes = await fetcher
          .fetchRails(keyless(
            order: const ['letterboxd:letterboxd-watchlist'],
            letterboxd: active,
          ))
          .toList();

      final loaded = outcomes.single as HomeRailLoaded;
      expect(loaded.title, 'Watchlist');
      expect(loaded.items.single.id, 'tt9');
    });

    test('a cached manifest for another URL does not rescue the rail', () async {
      final cache = InMemoryHomeCacheStore();
      await cache.saveManifest(CachedManifest(
        manifestUrl: 'https://api.stremboxd.com/stremio/other/manifest.json',
        body: jsonEncode({
          'catalogs': [
            {'id': 'letterboxd-watchlist', 'type': 'movie', 'name': 'Watchlist'},
          ],
        }),
        updatedAt: 1,
      ));
      final fetcher = HttpCatalogFetcher(
        cache: cache,
        get: (url) async => throw Exception('timeout'),
      );

      final outcomes = await fetcher
          .fetchRails(keyless(
            order: const ['letterboxd:letterboxd-watchlist'],
            letterboxd: active,
          ))
          .toList();

      expect(outcomes.single, isA<HomeRailFailed>());
    });
  });

  group('adaptive timeout + retry (ticket 73)', () {
    String cinemeta(List<String> ids) => jsonEncode({
          'metas': [
            for (final id in ids) {'id': id, 'type': 'movie', 'name': id},
          ],
        });

    CatalogRequest keyless({
      List<String> order = const ['cinemeta:top-movies'],
    }) =>
        CatalogRequest(rowOrder: order);

    Meta cached(String id) => Meta(id: id, type: 'movie', name: id);

    test('policy: cold is 45s, warm is 8s, retry backoff is ~1s', () {
      const policy = HomeRailTimeouts();
      expect(policy.forCache(hasCache: false), const Duration(seconds: 45));
      expect(policy.forCache(hasCache: true), const Duration(seconds: 8));
      expect(policy.retryBackoff, const Duration(seconds: 1));
    });

    test('a warm rail uses the 8s timeout and a cold rail the 45s one',
        () async {
      final warmCache = InMemoryHomeCacheStore();
      await warmCache.saveRail(
        const HomeCacheIdentity('cinemeta:top-movies'),
        CachedRail(items: [cached('cached')], updatedAt: 1),
      );

      var warmGets = 0;
      final warmFetcher = HttpCatalogFetcher(
        cache: warmCache,
        timeouts: const HomeRailTimeouts(retryBackoff: Duration.zero),
        get: (url) {
          warmGets++;
          return Completer<String>().future; // never answers
        },
      );
      var coldGets = 0;
      final coldFetcher = HttpCatalogFetcher(
        cache: InMemoryHomeCacheStore(), // no entry → cold
        timeouts: const HomeRailTimeouts(retryBackoff: Duration.zero),
        get: (url) {
          coldGets++;
          return Completer<String>().future; // never answers
        },
      );

      fakeAsync((async) {
        HomeRailOutcome? warmOutcome;
        HomeRailOutcome? coldOutcome;
        warmFetcher
            .fetchRail(keyless(), 'cinemeta:top-movies')
            .then((o) => warmOutcome = o);
        coldFetcher
            .fetchRail(keyless(), 'cinemeta:top-movies')
            .then((o) => coldOutcome = o);
        async.flushMicrotasks();

        // At 8s the warm rail has timed out and retried; the cold one is still
        // on its first (45s) attempt.
        async.elapse(const Duration(seconds: 8));
        async.flushMicrotasks();
        expect(warmGets, 2, reason: 'warm rail (8s) timed out and retried');
        expect(coldGets, 1, reason: 'cold rail (45s) is still fetching at 8s');

        // A further 8s settles the warm rail after exactly one retry.
        async.elapse(const Duration(seconds: 8));
        async.flushMicrotasks();
        expect(warmOutcome, isA<HomeRailFailed>());
        expect(warmGets, 2, reason: 'exactly one retry');
        expect(coldOutcome, isNull);

        // Past 45s the cold rail finally times out and retries too.
        async.elapse(const Duration(seconds: 30));
        async.flushMicrotasks();
        expect(coldGets, 2, reason: 'cold rail timed out only after 45s');
      });
    });

    test('a failing rail is retried exactly once before HomeRailFailed',
        () async {
      var gets = 0;
      final fetcher = HttpCatalogFetcher(
        timeouts: const HomeRailTimeouts(retryBackoff: Duration.zero),
        get: (url) async {
          gets++;
          throw Exception('down');
        },
      );

      final outcome =
          await fetcher.fetchRail(keyless(), 'cinemeta:top-movies');

      expect(outcome, isA<HomeRailFailed>());
      expect(gets, 2, reason: 'the initial attempt + exactly one retry');
    });

    test('a transient failure recovers on the single retry', () async {
      var gets = 0;
      final fetcher = HttpCatalogFetcher(
        timeouts: const HomeRailTimeouts(retryBackoff: Duration.zero),
        get: (url) async {
          gets++;
          if (gets == 1) throw Exception('blip');
          return cinemeta(['tt1']);
        },
      );

      final outcome =
          await fetcher.fetchRail(keyless(), 'cinemeta:top-movies');

      expect(outcome, isA<HomeRailLoaded>());
      expect(gets, 2);
    });

    test('a rail that loads on the first try is not retried', () async {
      var gets = 0;
      final fetcher = HttpCatalogFetcher(
        get: (url) async {
          gets++;
          return cinemeta(['tt1']);
        },
      );

      final outcome =
          await fetcher.fetchRail(keyless(), 'cinemeta:top-movies');

      expect(outcome, isA<HomeRailLoaded>());
      expect(gets, 1);
    });

    test('fetchRails retries the failed rail only; the others still load',
        () async {
      var movieGets = 0;
      var seriesGets = 0;
      final fetcher = HttpCatalogFetcher(
        timeouts: const HomeRailTimeouts(retryBackoff: Duration.zero),
        get: (url) async {
          if (url.path.contains('/series/')) {
            seriesGets++;
            throw Exception('500');
          }
          movieGets++;
          return cinemeta(['tt1']);
        },
      );

      final outcomes = await fetcher
          .fetchRails(keyless(order: const [
            'cinemeta:top-movies',
            'cinemeta:top-series',
          ]))
          .toList();

      expect(outcomes, hasLength(2));
      expect(outcomes.whereType<HomeRailFailed>().single.rowKey,
          'cinemeta:top-series');
      expect(outcomes.whereType<HomeRailLoaded>().single.rowKey,
          'cinemeta:top-movies');
      expect(movieGets, 1, reason: 'a loaded rail is not retried');
      expect(seriesGets, 2, reason: 'a failed rail gets exactly one retry');
    });
  });

  group('per-source hasMore (ticket 75)', () {
    String cinemeta(List<String> ids) => jsonEncode({
          'metas': [
            for (final id in ids) {'id': id, 'type': 'movie', 'name': id},
          ],
        });

    String tmdbPage({
      required int page,
      required int totalPages,
      int count = 20,
    }) =>
        jsonEncode({
          'page': page,
          'total_pages': totalPages,
          'results': [
            for (var i = 0; i < count; i++) {'id': i, 'title': 'T$i'},
          ],
        });

    test('parseTmdbPageResponse reads the page cursor', () {
      final parsed = parseTmdbPageResponse(
        tmdbPage(page: 2, totalPages: 5, count: 3),
        'movie',
      );
      expect(parsed.items, hasLength(3));
      expect(parsed.page, 2);
      expect(parsed.totalPages, 5);
      expect(parsed.hasMore, isTrue);
      expect(
        parseTmdbPageResponse(tmdbPage(page: 5, totalPages: 5), 'movie').hasMore,
        isFalse,
      );
    });

    test('a response without page/total_pages is treated as the end', () {
      final parsed = parseTmdbPageResponse(jsonEncode({'results': []}), 'movie');
      expect(parsed.hasMore, isFalse);
    });

    test('stremboxdHasMore: a full 100 page has more, a short page ends', () {
      expect(stremboxdHasMore(100), isTrue);
      expect(stremboxdHasMore(101), isTrue);
      expect(stremboxdHasMore(99), isFalse);
      expect(stremboxdHasMore(0), isFalse);
    });

    test('Cinemeta rows always report hasMore (skip is unbounded)', () async {
      final fetcher = HttpCatalogFetcher(get: (url) async => cinemeta(['tt1']));
      final outcomes = await fetcher
          .fetchRails(const CatalogRequest(rowOrder: ['cinemeta:top-movies']))
          .toList();
      expect((outcomes.single as HomeRailLoaded).hasMore, isTrue);
    });

    test('a TMDB list row reports hasMore from page < total_pages', () async {
      Future<bool> hasMore(int page, int totalPages) async {
        final fetcher = HttpCatalogFetcher(
          get: (url) async =>
              tmdbPage(page: page, totalPages: totalPages, count: 3),
        );
        final outcomes = await fetcher
            .fetchRails(const CatalogRequest(
              tmdbKey: 'key',
              rowOrder: ['tmdb:popular-movies'],
            ))
            .toList();
        return (outcomes.single as HomeRailLoaded).hasMore;
      }

      expect(await hasMore(1, 3), isTrue);
      expect(await hasMore(3, 3), isFalse);
    });

    test('a /trending row never reports hasMore, even as page 1 of 1000',
        () async {
      final fetcher = HttpCatalogFetcher(
        get: (url) async => tmdbPage(page: 1, totalPages: 1000),
      );
      final outcomes = await fetcher
          .fetchRails(const CatalogRequest(
            tmdbKey: 'key',
            rowOrder: ['tmdb:trending-movies'],
          ))
          .toList();
      expect((outcomes.single as HomeRailLoaded).hasMore, isFalse);
    });

    test('a Stremboxd page of 100 has more; a short page is the end', () async {
      const active = LetterboxdConfig(
        manifestUrl: 'https://api.stremboxd.com/stremio/tok/manifest.json',
        enabledCatalogIds: {'letterboxd-watchlist'},
      );
      Future<bool> hasMore(int count) async {
        final fetcher = HttpCatalogFetcher(get: (url) async {
          if (url.path.endsWith('/manifest.json')) {
            return jsonEncode({
              'catalogs': [
                {'id': 'letterboxd-watchlist', 'type': 'movie', 'name': 'Watchlist'},
              ],
            });
          }
          return cinemeta([for (var i = 0; i < count; i++) 'tt$i']);
        });
        final outcomes = await fetcher
            .fetchRails(const CatalogRequest(
              letterboxd: active,
              rowOrder: ['letterboxd:letterboxd-watchlist'],
            ))
            .toList();
        return (outcomes.single as HomeRailLoaded).hasMore;
      }

      expect(await hasMore(100), isTrue);
      expect(await hasMore(42), isFalse);
    });
  });
}
