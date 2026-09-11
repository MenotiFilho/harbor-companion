// Tests for the Home/catalog state model (lib/app/home/home_reducer.dart).
//
// Pins the ticket 71 per-rail acceptance criteria: the fetcher emits one
// loaded/failed/absent per planned `rowKey`, each committed atomically (loaded
// even-empty replaces, failed keeps the previous copy, absent drops), a rail is
// never assembled from two rounds (the round id guards), and the global empty /
// everything-failed states are derived from the per-rail state. Plus the ticket
// 04 detail + playMeta behavior, unchanged.

import 'package:flutter_test/flutter_test.dart';

import 'package:harbor_companion/app/home/catalog_request.dart';
import 'package:harbor_companion/app/home/home_cache_store.dart';
import 'package:harbor_companion/app/home/home_rail.dart';
import 'package:harbor_companion/app/home/home_reducer.dart';
import 'package:harbor_companion/app/home/home_rows.dart';
import 'package:harbor_companion/app/letterboxd/letterboxd.dart';
import 'package:harbor_companion/app/home/meta.dart';

Meta movie({String id = 'tt0000001', String name = 'The Matrix'}) =>
    Meta(id: id, type: 'movie', name: name, poster: 'http://p/$id.jpg');

Meta series({String id = 'tt0000002', String name = 'Breaking Bad'}) =>
    Meta(id: id, type: 'series', name: name, poster: 'http://p/$id.jpg');

List<Meta> items(String prefix, [int n = 3]) =>
    [for (var i = 0; i < n; i++) movie(id: '$prefix:$i')];

CatalogRequest req({
  String? key,
  LetterboxdConfig letterboxd = const LetterboxdConfig(),
  Set<String> disabledBuiltIn = const {},
  List<String> order = kDefaultHomeRowOrder,
}) =>
    CatalogRequest(
      tmdbKey: key,
      letterboxd: letterboxd,
      disabledBuiltInRowKeys: disabledBuiltIn,
      rowOrder: order,
    );

List<String> drain(HomeState s) {
  final e = List<String>.from(s.effects);
  s.effects.clear();
  return e;
}

/// Starts the first round and returns the state with the effect drained.
HomeState started([CatalogRequest? request]) {
  final s = homeReduce(HomeState(request: request ?? req()), const LoadHome());
  drain(s);
  return s;
}

/// Folds [outcome] into [s] for the round/request [s] is currently on.
HomeState fold(HomeState s, HomeRailOutcome outcome) =>
    homeReduce(s, RailOutcomeReceived(outcome, s.request, s.round));

void main() {
  const firstKey = 'cinemeta:top-movies';

  group('round start', () {
    test('LoadHome plans every rail pending and emits fetch:rails', () {
      final s = homeReduce(HomeState(), const LoadHome());
      expect(s.round, 1);
      expect(drain(s), ['fetch:rails']);
      expect(s.plannedKeys, isNotEmpty);
      expect(s.rails.keys, containsAll(s.plannedKeys));
      expect(s.hasPending, isTrue);
      expect(s.renderKeys, s.plannedKeys);
    });

    test('a second LoadHome is a no-op (no refetch on tab re-entry)', () {
      final after = homeReduce(started(), const LoadHome());
      expect(after.round, 1);
      expect(drain(after), isEmpty);
    });

    test('RefreshHome starts a new round even after the first settled', () {
      var s = started();
      for (final key in s.plannedKeys) {
        s = fold(s, HomeRailAbsent(key));
      }
      final after = homeReduce(s, const RefreshHome());
      expect(after.round, 2);
      expect(drain(after), ['fetch:rails']);
      expect(after.isPending(firstKey), isTrue);
    });

    test('KeyChanged starts a keyed round; a stale keyless outcome is dropped',
        () {
      var s = started();
      final keyed = homeReduce(s, const KeyChanged('tmdb-key'));
      drain(keyed);
      expect(keyed.tmdbKey, 'tmdb-key');
      expect(keyed.round, 2);
      // The keyless result now returns for round 1 — dropped.
      final stale = homeReduce(
        keyed,
        RailOutcomeReceived(HomeRailLoaded('cinemeta:top-movies', 'Top Movies', items('old')), req(), 1),
      );
      expect(stale.rails['cinemeta:top-movies']?.hasItems ?? false, isFalse);
      // A keyed result for round 2 applies.
      final fresh = homeReduce(
        keyed,
        RailOutcomeReceived(HomeRailLoaded('tmdb:trending-movies', 'Trending', items('new')), keyed.request, 2),
      );
      expect(fresh.rails['tmdb:trending-movies']!.items, isNotEmpty);
    });

    test('an unchanged key is a no-op; changed sources start a round', () {
      final same = homeReduce(HomeState(request: req(key: 'k')), const KeyChanged('k'));
      expect(drain(same), isEmpty);
      final changed = homeReduce(
        HomeState(),
        CatalogSourcesChanged(req(letterboxd: const LetterboxdConfig(
          manifestUrl: 'https://x/manifest.json',
          enabledCatalogIds: {'letterboxd-watchlist'},
        ))),
      );
      expect(drain(changed), ['fetch:rails']);
    });
  });

  group('per-rail commit', () {
    test('loaded with items publishes the rail under its rowKey', () {
      final s = fold(started(), HomeRailLoaded(firstKey, 'Top Movies', items('a')));
      final rail = s.rails[firstKey]!;
      expect(rail.status, RailStatus.loaded);
      expect(rail.title, 'Top Movies');
      expect(rail.items, hasLength(3));
      expect(s.isPending(firstKey), isFalse);
    });

    test('loaded with zero items removes the rail', () {
      final s = fold(started(), HomeRailLoaded(firstKey, 'Top Movies', const []));
      expect(s.rails[firstKey]!.status, RailStatus.loaded);
      expect(s.rails[firstKey]!.hasItems, isFalse);
      expect(s.renderKeys, isNot(contains(firstKey)));
    });

    test('loaded empty replaces a previous copy', () {
      var s = fold(started(), HomeRailLoaded(firstKey, 'Top Movies', items('a')));
      s = homeReduce(s, const RefreshHome());
      s = fold(s, HomeRailLoaded(firstKey, 'Top Movies', const []));
      expect(s.rails[firstKey]!.hasItems, isFalse);
      expect(s.renderKeys, isNot(contains(firstKey)));
    });

    test('failed without a previous copy keeps no items (local retry card)', () {
      final s = fold(started(), HomeRailFailed(firstKey, Exception('down')));
      final rail = s.rails[firstKey]!;
      expect(rail.status, RailStatus.failed);
      expect(rail.hasItems, isFalse);
      expect(rail.error, contains('down'));
      expect(s.renderKeys, contains(firstKey));
    });

    test('failed keeps the previous copy and its title', () {
      var s = fold(started(), HomeRailLoaded(firstKey, 'Top Movies', items('a')));
      s = homeReduce(s, const RefreshHome());
      s = fold(s, HomeRailFailed(firstKey, Exception('down')));
      final rail = s.rails[firstKey]!;
      expect(rail.status, RailStatus.failed);
      expect(rail.title, 'Top Movies');
      expect(rail.items, hasLength(3));
      expect(s.hasContent, isTrue);
      expect(s.renderKeys, contains(firstKey));
    });

    test('absent drops the rail and its previous copy', () {
      var s = fold(started(), HomeRailLoaded(firstKey, 'Top Movies', items('a')));
      s = homeReduce(s, const RefreshHome());
      s = fold(s, HomeRailAbsent(firstKey));
      expect(s.rails[firstKey]!.status, RailStatus.absent);
      expect(s.rails[firstKey]!.hasItems, isFalse);
      expect(s.renderKeys, isNot(contains(firstKey)));
    });
  });

  group('never two rounds', () {
    test('an outcome from a superseded round is dropped', () {
      var s = started(); // round 1
      for (final key in s.plannedKeys) {
        s = fold(s, HomeRailAbsent(key));
      }
      s = homeReduce(s, const RefreshHome()); // round 2
      final stale = homeReduce(
        s,
        RailOutcomeReceived(HomeRailLoaded(firstKey, 'Old', items('old')), s.request, 1),
      );
      expect(stale.rails[firstKey]!.hasItems, isFalse);
      final fresh = homeReduce(
        s,
        RailOutcomeReceived(HomeRailLoaded(firstKey, 'Fresh', items('fresh')), s.request, 2),
      );
      expect(fresh.rails[firstKey]!.title, 'Fresh');
    });

    test('an outcome for a superseded request is dropped', () {
      final s = homeReduce(started(), const KeyChanged('tmdb-key'));
      final stale = homeReduce(
        s,
        RailOutcomeReceived(HomeRailLoaded('cinemeta:top-movies', 'Old', items('old')), req(), s.round),
      );
      expect(stale.rails['cinemeta:top-movies']?.hasItems ?? false, isFalse);
    });

    test('a stream failure fails every still-pending planned rail', () {
      final s = homeReduce(
        started(),
        RailsFetchFailed(Exception('offline'), req(), 1),
      );
      expect(s.hasPending, isFalse);
      expect(s.allFailed, isTrue);
      expect(s.plannedKeys.every((k) => s.rails[k]!.status == RailStatus.failed), isTrue);
    });
  });

  group('derived global states', () {
    test('a fresh, unsettled plan is pending — not empty, not failed', () {
      final s = started();
      expect(s.isEmptyHome, isFalse);
      expect(s.allFailed, isFalse);
    });

    test('everything failed with nothing on screen is the global failure', () {
      var s = started();
      for (final key in s.plannedKeys) {
        s = fold(s, HomeRailFailed(key, Exception('x')));
      }
      expect(s.allFailed, isTrue);
      expect(s.isEmptyHome, isFalse);
      expect(s.firstError, isNotNull);
    });

    test('a settled plan with no content is the empty Home', () {
      var s = started();
      for (final key in s.plannedKeys) {
        s = fold(s, HomeRailAbsent(key));
      }
      expect(s.isEmptyHome, isTrue);
      expect(s.allFailed, isFalse);
      expect(s.renderKeys, isEmpty);
    });

    test('an empty plan is the empty Home', () {
      final s = homeReduce(
        HomeState(request: req(disabledBuiltIn: {for (final r in kCinemetaRows) r.id})),
        const LoadHome(),
      );
      expect(s.plannedKeys, isEmpty);
      expect(s.isEmptyHome, isTrue);
      expect(s.allFailed, isFalse);
    });

    test('one loaded rail keeps the Home out of empty and failed', () {
      var s = started();
      s = fold(s, HomeRailLoaded(firstKey, 'Top Movies', items('a')));
      for (final key in s.plannedKeys.where((k) => k != firstKey)) {
        s = fold(s, HomeRailFailed(key, Exception('x')));
      }
      expect(s.hasContent, isTrue);
      expect(s.allFailed, isFalse);
      expect(s.isEmptyHome, isFalse);
    });

    test('failed-with-previous-copy counts as content, not all-failed', () {
      var s = fold(started(), HomeRailLoaded(firstKey, 'Top Movies', items('a')));
      s = homeReduce(s, const RefreshHome());
      for (final key in s.plannedKeys) {
        s = fold(s, HomeRailFailed(key, Exception('x')));
      }
      expect(s.allFailed, isFalse);
      expect(s.hasContent, isTrue);
    });
  });

  group('local retry', () {
    test('RetryRail re-pends the rail and emits fetch:rail, keeping items', () {
      var s = fold(started(), HomeRailFailed(firstKey, Exception('down')));
      final after = homeReduce(s, const RetryRail(firstKey));
      expect(drain(after), ['fetch:rail']);
      expect(after.retryingRail, firstKey);
      expect(after.isPending(firstKey), isTrue);
      expect(after.renderKeys, contains(firstKey));
    });

    test('the retry outcome applies and clears retryingRail', () {
      var s = homeReduce(
        fold(started(), HomeRailFailed(firstKey, Exception('down'))),
        const RetryRail(firstKey),
      );
      drain(s);
      s = fold(s, HomeRailLoaded(firstKey, 'Top Movies', items('a')));
      expect(s.rails[firstKey]!.status, RailStatus.loaded);
      expect(s.retryingRail, isNull);
    });

    test('RetryRail for an unplanned key is a no-op', () {
      final s = homeReduce(started(), const RetryRail('bogus:key'));
      expect(drain(s), isEmpty);
    });
  });

  group('cache-first (ticket 72)', () {
    CachedRail cached(String prefix, {int updatedAt = 5000, bool hasMore = false}) =>
        CachedRail(items: items(prefix), updatedAt: updatedAt, hasMore: hasMore);

    test('CacheLoaded seeds a pending rail as fromCache with its age', () {
      final start = started();
      final s = homeReduce(
        start,
        CacheLoaded(start.request, {firstKey: cached('c', updatedAt: 7000)}),
      );
      final rail = s.rails[firstKey]!;
      expect(rail.status, RailStatus.loaded);
      expect(rail.items, hasLength(3));
      expect(rail.title, 'Top Movies');
      expect(rail.fromCache, isTrue);
      expect(rail.updatedAt, 7000);
      expect(s.renderKeys, contains(firstKey));
    });

    test('a fresh loaded outcome clears fromCache and the age (badge gone)', () {
      var s = started();
      s = homeReduce(s, CacheLoaded(s.request, {firstKey: cached('c')}));
      s = fold(s, HomeRailLoaded(firstKey, 'Top Movies', items('fresh')));
      expect(s.rails[firstKey]!.status, RailStatus.loaded);
      expect(s.rails[firstKey]!.fromCache, isFalse);
      expect(s.rails[firstKey]!.updatedAt, isNull);
    });

    test('cache does not clobber a rail that already has content', () {
      var s = fold(started(), HomeRailLoaded(firstKey, 'Top Movies', items('fresh')));
      s = homeReduce(s, const RefreshHome()); // pending, keeps the fresh copy
      s = homeReduce(s, CacheLoaded(s.request, {firstKey: cached('old')}));
      expect(s.rails[firstKey]!.items.first.id, 'fresh:0');
      expect(s.rails[firstKey]!.fromCache, isFalse);
    });

    test('a failed revalidation keeps the cached copy and its badge', () {
      var s = started();
      s = homeReduce(s, CacheLoaded(s.request, {firstKey: cached('c', updatedAt: 900)}));
      s = fold(s, HomeRailFailed(firstKey, Exception('down')));
      final rail = s.rails[firstKey]!;
      expect(rail.status, RailStatus.failed);
      expect(rail.items, hasLength(3));
      expect(rail.fromCache, isTrue);
      expect(rail.updatedAt, 900);
    });

    test('a stale CacheLoaded for a superseded request is dropped', () {
      var s = started();
      s = homeReduce(s, const KeyChanged('tmdb-key'));
      s = homeReduce(s, CacheLoaded(req(), {firstKey: cached('c')}));
      expect(s.rails[firstKey]?.hasItems ?? false, isFalse);
    });

    test('hasMore rides through the loaded commit', () {
      var s = fold(
        started(),
        const HomeRailLoaded('cinemeta:top-movies', 'Top Movies', [], hasMore: true),
      );
      expect(s.rails[firstKey]!.hasMore, isTrue);
    });
  });

  group('refresh triggers (ticket 74)', () {
    /// Settles the round [s] is on by dropping every planned rail absent.
    HomeState settle(HomeState s) {
      for (final key in s.plannedKeys) {
        s = fold(s, HomeRailAbsent(key));
      }
      return s;
    }

    test('the automatic round fires once and arms the process latch', () {
      final s = homeReduce(HomeState(request: req()), const LoadHome());
      expect(s.round, 1);
      expect(s.autoRefreshDone, isTrue);
      expect(s.roundManual, isFalse);
      drain(s);

      final again = homeReduce(s, const LoadHome());
      expect(again.round, 1);
      expect(drain(again), isEmpty);
    });

    test('settling the automatic round does not clear the latch', () {
      final s = settle(started());
      final again = homeReduce(s, const LoadHome());
      expect(again.round, s.round);
      expect(drain(again), isEmpty);
    });

    test('the latch arms even when the first availability joins a round', () {
      // A source-change round is already in flight before the Home opens.
      var s = homeReduce(
        HomeState(),
        CatalogSourcesChanged(req(order: [firstKey])),
      );
      drain(s);
      expect(s.roundInFlight, isTrue);
      expect(s.autoRefreshDone, isFalse);

      final joined = homeReduce(s, const LoadHome());
      expect(joined.round, s.round);
      expect(joined.autoRefreshDone, isTrue);
      expect(drain(joined), isEmpty);
    });

    test('a manual pull during an in-flight round joins and marks it manual',
        () {
      final s = started();
      expect(s.roundInFlight, isTrue);

      final joined = homeReduce(s, const RefreshHome());
      expect(joined.round, s.round);
      expect(drain(joined), isEmpty);
      expect(joined.roundManual, isTrue);
      expect(joined.roundInFlight, isTrue);
    });

    test('a manual pull after settle starts a new manual round', () {
      final done = settle(started());
      expect(done.roundInFlight, isFalse);

      final next = homeReduce(done, const RefreshHome());
      expect(next.round, done.round + 1);
      expect(drain(next), ['fetch:rails']);
      expect(next.roundManual, isTrue);
      expect(next.roundInFlight, isTrue);
      expect(next.roundSummary, isNull, reason: 'the previous summary cleared');
    });

    test('cache seeding does not settle the round (network still in flight)',
        () {
      var s = started();
      final cached = {
        for (final key in s.plannedKeys)
          key: CachedRail(items: items(key), updatedAt: 1000),
      };
      s = homeReduce(s, CacheLoaded(s.request, cached));

      // Cached rails render (no skeletons) but the round is not done.
      expect(s.hasPending, isFalse);
      expect(s.roundInFlight, isTrue);
      expect(s.roundSummary, isNull);
    });

    test('the summary reports a fully-failed manual round for feedback', () {
      var s = settle(started());

      // An all-failed automatic round is quiet.
      var auto = started();
      for (final key in auto.plannedKeys) {
        auto = fold(auto, HomeRailFailed(key, Exception('x')));
      }
      expect(auto.roundSummary!.manual, isFalse);
      expect(auto.roundSummary!.allFailed, isTrue);
      expect(auto.roundSummary!.notifyFailure, isFalse);

      s = homeReduce(s, const RefreshHome());
      for (final key in s.plannedKeys) {
        s = fold(s, HomeRailFailed(key, Exception('x')));
      }
      expect(s.roundSummary!.round, s.round);
      expect(s.roundSummary!.manual, isTrue);
      expect(s.roundSummary!.allFailed, isTrue);
      expect(s.roundSummary!.notifyFailure, isTrue);
    });

    test('a partial failure never notifies', () {
      var s = homeReduce(settle(started()), const RefreshHome());
      for (final key in s.plannedKeys) {
        s = fold(
          s,
          key == firstKey
              ? HomeRailLoaded(key, 'Top Movies', items('a'))
              : HomeRailFailed(key, Exception('x')),
        );
      }
      expect(s.roundSummary!.allFailed, isFalse);
      expect(s.roundSummary!.notifyFailure, isFalse);
    });

    test('a failed manual round with cache stays silent', () {
      var s = started();
      for (final key in s.plannedKeys) {
        s = fold(
          s,
          key == firstKey
              ? HomeRailLoaded(key, 'Top Movies', items('a'))
              : HomeRailAbsent(key),
        );
      }
      s = homeReduce(s, const RefreshHome());
      for (final key in s.plannedKeys) {
        s = fold(s, HomeRailFailed(key, Exception('x')));
      }
      expect(s.hasContent, isTrue);
      expect(s.roundSummary!.manual, isTrue);
      expect(s.roundSummary!.allFailed, isFalse);
      expect(s.roundSummary!.notifyFailure, isFalse);
    });
  });

  group('detail', () {
    test('OpenDetail requests a fetch and marks loading', () {
      final s = homeReduce(HomeState(), OpenDetail(movie()));
      expect(s.detail!.status, DetailStatus.loading);
      expect(s.detail!.meta.id, 'tt0000001');
      expect(drain(s), ['fetch:detail']);
    });

    test('OpenDetail pins the key in effect at request time', () {
      final s = homeReduce(HomeState(request: req(key: 'tmdb-key')), OpenDetail(movie()));
      expect(s.detail!.tmdbKey, 'tmdb-key');
      // a keyless request stays keyless even if a key arrives mid-load
      final keyless = homeReduce(HomeState(), OpenDetail(movie()));
      final upgraded = homeReduce(keyless, const KeyChanged('tmdb-key'));
      expect(upgraded.detail!.tmdbKey, isNull);
    });

    test('DetailLoaded for the requested meta resolves', () {
      var s = homeReduce(HomeState(), OpenDetail(movie()));
      drain(s);
      final detail = DetailMeta(meta: movie(), seasons: const []);
      s = homeReduce(s, DetailLoaded(movie(), detail));
      expect(s.detail!.status, DetailStatus.ready);
      expect(s.detail!.detail, same(detail));
    });

    test('a stale DetailLoaded for another meta is dropped', () {
      var s = homeReduce(HomeState(), OpenDetail(movie()));
      drain(s);
      final other = movie(id: 'tt9999999', name: 'Other');
      s = homeReduce(s, DetailLoaded(other, DetailMeta(meta: other)));
      expect(s.detail!.status, DetailStatus.loading);
    });

    test('DetailFailed marks failed; CloseDetail clears', () {
      var s = homeReduce(HomeState(), OpenDetail(movie()));
      drain(s);
      s = homeReduce(s, DetailFailed(movie(), Exception('404')));
      expect(s.detail!.status, DetailStatus.failed);
      expect(s.detail!.error, contains('404'));
      final cleared = homeReduce(s, const CloseDetail());
      expect(cleared.detail, isNull);
    });
  });

  group('playMeta encoding', () {
    test('a movie encodes metaType movie with resume, no season/episode', () {
      final s = homeReduce(HomeState(), PlayMeta(movie()));
      expect(drain(s), ['playMeta']);
      expect(s.pendingPlay!.toPayload(), {
        'metaId': 'tt0000001',
        'metaType': 'movie',
        'name': 'The Matrix',
        'poster': 'http://p/tt0000001.jpg',
        'resume': true,
      });
    });

    test('a series with a specific season/episode carries them', () {
      final s = homeReduce(HomeState(), PlayMeta(series(), season: 3, episode: 5));
      final payload = s.pendingPlay!.toPayload();
      expect(payload['metaType'], 'series');
      expect(payload['season'], 3);
      expect(payload['episode'], 5);
      expect(payload['resume'], true);
    });

    test('an anime metaType is coerced to series', () {
      final anime = Meta(id: 'kitsu:1', type: 'anime', name: 'Frieren');
      final s = homeReduce(HomeState(), PlayMeta(anime));
      expect(s.pendingPlay!.toPayload()['metaType'], 'series');
    });
  });

  group('detail first episode', () {
    test('a series detail surfaces the first playable episode', () {
      final detail = DetailMeta(
        meta: series(),
        seasons: [
          Season(number: 1, name: 'Season 1', episodes: [
            Episode(season: 1, episode: 1, name: 'Pilot'),
            Episode(season: 1, episode: 2, name: 'Cat'),
          ]),
          Season(number: 2, name: 'Season 2', episodes: [
            Episode(season: 2, episode: 1, name: 'Seven Thirty-Seven'),
          ]),
        ],
      );
      expect(detail.firstEpisode, (1, 1));
    });

    test('a movie detail has no first episode', () {
      expect(DetailMeta(meta: movie()).firstEpisode, isNull);
    });
  });

  group('plan order', () {
    test('a reorder preserves the planned rail order', () {
      final reordered = [
        'cinemeta:top-series',
        'cinemeta:top-movies',
        ...kDefaultHomeRowOrder.where(
          (k) => k != 'cinemeta:top-series' && k != 'cinemeta:top-movies',
        ),
      ];
      var s = homeReduce(HomeState(), CatalogSourcesChanged(req(order: reordered)));
      drain(s);
      expect(s.plannedKeys.first, 'cinemeta:top-series');
      expect(s.plannedKeys[1], 'cinemeta:top-movies');
      // Outcomes arriving out of order still render in the user's order.
      s = fold(s, HomeRailLoaded('cinemeta:top-movies', 'Top Movies', items('m')));
      s = fold(s, HomeRailLoaded('cinemeta:top-series', 'Top Series', items('s')));
      expect(s.renderKeys.first, 'cinemeta:top-series');
      expect(s.renderKeys[1], 'cinemeta:top-movies');
    });
  });
}
