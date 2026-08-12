// Tests for the Home/catalog state model (lib/app/home/home_reducer.dart).
//
// Pins the ticket 04 acceptance criteria: TMDB-if-key-else-Cinemeta rows with
// auto-upgrade when a tmdbKey arrives (and downgrade when it leaves), the
// stale-fetch guard, detail loading with the requested-meta guard, and the
// host-driven playMeta encoding (movie / series first episode / specific
// episode, `resume` always true, anime coerced to series).

import 'package:flutter_test/flutter_test.dart';

import 'package:harbor_companion/app/home/home_reducer.dart';
import 'package:harbor_companion/app/home/meta.dart';

Meta movie({String id = 'tt0000001', String name = 'The Matrix'}) =>
    Meta(id: id, type: 'movie', name: name, poster: 'http://p/$id.jpg');

Meta series({String id = 'tt0000002', String name = 'Breaking Bad'}) =>
    Meta(id: id, type: 'series', name: name, poster: 'http://p/$id.jpg');

HomeRow row(String title, [int n = 3]) =>
    HomeRow(title, [for (var i = 0; i < n; i++) movie(id: '$title:$i')]);

List<String> drain(HomeState s) {
  final e = List<String>.from(s.effects);
  s.effects.clear();
  return e;
}

void main() {
  group('rows: load & status', () {
    test('LoadHome from idle fetches and enters loading', () {
      final s = homeReduce(HomeState(), const LoadHome());
      expect(s.status, HomeStatus.loading);
      expect(drain(s), ['fetch:rows']);
    });

    test('LoadHome while ready is a no-op (no refetch on tab re-entry)', () {
      var s = homeReduce(HomeState(), const LoadHome());
      drain(s);
      s = homeReduce(s, RowsLoaded([row('Top Movies')], null));
      drain(s);
      final after = homeReduce(s, const LoadHome());
      expect(after.status, HomeStatus.ready);
      expect(drain(after), isEmpty);
    });

    test('LoadHome while loading is a no-op', () {
      final loading = homeReduce(HomeState(), const LoadHome());
      drain(loading);
      final after = homeReduce(loading, const LoadHome());
      expect(drain(after), isEmpty);
    });

    test('LoadHome after a failure retries', () {
      var s = homeReduce(HomeState(), const LoadHome());
      drain(s);
      s = homeReduce(s, RowsFailed(Exception('boom'), null));
      drain(s);
      expect(s.status, HomeStatus.failed);
      final after = homeReduce(s, const LoadHome());
      expect(after.status, HomeStatus.loading);
      expect(drain(after), ['fetch:rows']);
    });

    test('RowsLoaded with the current key publishes rows', () {
      var s = homeReduce(HomeState(), const LoadHome());
      drain(s);
      s = homeReduce(s, RowsLoaded([row('Top Movies')], null));
      expect(s.status, HomeStatus.ready);
      expect(s.rows.single.title, 'Top Movies');
      expect(drain(s), isEmpty);
    });

    test('RowsFailed with the current key enters failed', () {
      var s = homeReduce(HomeState(), const LoadHome());
      drain(s);
      s = homeReduce(s, RowsFailed(Exception('down'), null));
      expect(s.status, HomeStatus.failed);
      expect(s.rows, isEmpty);
      expect(s.lastError, contains('down'));
    });
  });

  group('rows: TMDB-if-key-else-Cinemeta + auto-upgrade', () {
    test('a keyless host fetches cinemeta (no key in state)', () {
      var s = homeReduce(HomeState(), const LoadHome());
      drain(s);
      s = homeReduce(s, RowsLoaded([row('Action'), row('Drama')], null));
      expect(s.tmdbKey, isNull);
      expect(s.rows, hasLength(2));
    });

    test('a key arriving upgrades the rows (refetch keyed)', () {
      var s = homeReduce(HomeState(), const LoadHome());
      drain(s);
      s = homeReduce(s, RowsLoaded([row('Top Movies')], null)); // cinemeta rows
      drain(s);
      final after = homeReduce(s, KeyChanged('tmdb-key'));
      expect(after.tmdbKey, 'tmdb-key');
      expect(after.status, HomeStatus.loading);
      expect(drain(after), ['fetch:rows']);
    });

    test('a key leaving downgrades back to cinemeta', () {
      var s = homeReduce(HomeState(tmdbKey: 'tmdb-key'), const LoadHome());
      drain(s);
      s = homeReduce(s, RowsLoaded([row('Trending')], 'tmdb-key'));
      drain(s);
      final after = homeReduce(s, KeyChanged(null));
      expect(after.tmdbKey, isNull);
      expect(drain(after), ['fetch:rows']);
    });

    test('an unchanged key is a no-op', () {
      final s = homeReduce(HomeState(tmdbKey: 'k'), KeyChanged('k'));
      expect(drain(s), isEmpty);
    });

    test('a stale keyless result never overwrites keyed rows', () {
      // key arrives mid-flight; the old keyless fetch returns late and is dropped
      var s = homeReduce(HomeState(), const LoadHome()); // keyless fetch
      drain(s);
      s = homeReduce(s, KeyChanged('tmdb-key')); // upgrade
      drain(s);
      final stale = homeReduce(s, RowsLoaded([row('Top Movies')], null));
      expect(stale.status, HomeStatus.loading); // still awaiting the keyed fetch
      expect(drain(stale), isEmpty);
    });

    test('the keyed result then lands and publishes', () {
      var s = homeReduce(HomeState(), const LoadHome());
      drain(s);
      s = homeReduce(s, KeyChanged('tmdb-key'));
      drain(s);
      s = homeReduce(s, RowsLoaded([row('Trending Movies')], 'tmdb-key'));
      expect(s.status, HomeStatus.ready);
      expect(s.rows.single.title, 'Trending Movies');
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
      final s = homeReduce(HomeState(tmdbKey: 'tmdb-key'), OpenDetail(movie()));
      expect(s.detail!.tmdbKey, 'tmdb-key');
      // a keyless request stays keyless even if a key arrives mid-load
      final keyless = homeReduce(HomeState(), OpenDetail(movie()));
      final upgraded = homeReduce(keyless, KeyChanged('tmdb-key'));
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

    test('a series first episode is just a specific season/episode', () {
      final s = homeReduce(HomeState(), PlayMeta(series(), season: 1, episode: 1));
      final payload = s.pendingPlay!.toPayload();
      expect(payload['season'], 1);
      expect(payload['episode'], 1);
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
}
