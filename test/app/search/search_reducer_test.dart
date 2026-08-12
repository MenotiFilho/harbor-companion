// Tests for the Search state model (lib/app/search/search_reducer.dart).
//
// Pins the ticket 05 acceptance criteria: 180ms debounce + request guard
// (stale never overrides), parallel fan-out with incremental publish and `done`
// only on full settle, the merge order (id dedupe → title+year dedupe →
// anime-wins → top-match swap), keyless cinemeta-only fallback with snapshot
// re-apply, and the playMeta encoding (anime coerced to series, resume true).

import 'package:flutter_test/flutter_test.dart';

import 'package:harbor_companion/app/home/meta.dart';
import 'package:harbor_companion/app/search/search_reducer.dart';

Meta movie({
  String id = 'tmdb:movie:603',
  String name = 'The Matrix',
  String? year = '1999',
}) =>
    Meta(id: id, type: 'movie', name: name, releaseInfo: year, poster: 'http://p/$id.jpg');

Meta series({
  String id = 'tmdb:tv:1396',
  String name = 'Breaking Bad',
  String? year = '2008',
}) =>
    Meta(id: id, type: 'series', name: name, releaseInfo: year, poster: 'http://p/$id.jpg');

AnimeHit animeHit({
  int? malId = 16498,
  int? kitsuId = 6922,
  int? anilistId,
  String name = 'Attack on Titan',
  String? year = '2013',
  String format = 'TV',
}) =>
    AnimeHit(
        malId: malId,
        kitsuId: kitsuId,
        anilistId: anilistId,
        format: format,
        name: name,
        year: year);

List<String> drain(SearchState s) {
  final e = List<String>.from(s.effects);
  s.effects.clear();
  return e;
}

SearchState typed(String q, {String? tmdbKey}) {
  final s = searchReduce(
    SearchState(tmdbKey: tmdbKey),
    QueryChanged(q),
  );
  drain(s);
  return s;
}

void main() {
  group('debounce + request guard', () {
    test('QueryChanged with text enters typing and arms the debounce', () {
      final s = searchReduce(SearchState(tmdbKey: 'k'), QueryChanged('matrix'));
      expect(s.status, SearchStatus.typing);
      expect(s.requestId, 1);
      expect(drain(s), ['debounce:1']);
    });

    test('an empty query goes idle with no debounce', () {
      final s = searchReduce(SearchState(), QueryChanged('   '));
      expect(s.status, SearchStatus.idle);
      expect(drain(s), isEmpty);
    });

    test('typing again bumps the request id (prior request abandoned)', () {
      var s = typed('mat', tmdbKey: 'k');
      s = searchReduce(s, QueryChanged('matrix'));
      expect(s.requestId, 2);
      expect(drain(s), ['debounce:2']);
    });

    test('DebounceFired fires the fan-out for the current request', () {
      final s = searchReduce(typed('matrix', tmdbKey: 'k'), const DebounceFired(1));
      expect(s.status, SearchStatus.loading);
      expect(s.pending, allSources);
      expect(drain(s), [
        'fetch:tmdb:1:matrix',
        'fetch:cinemeta:1:matrix',
        'fetch:jikan:1:matrix',
      ]);
    });

    test('a stale DebounceFired is dropped', () {
      var s = typed('mat', tmdbKey: 'k');
      drain(s);
      s = searchReduce(s, QueryChanged('matrix'));
      drain(s);
      final after = searchReduce(s, const DebounceFired(1)); // old id
      expect(after.requestsBumped, 1);
      expect(drain(after), isEmpty);
    });

    test('a stale source result never overrides the newer query', () {
      var s = typed('mat', tmdbKey: 'k');
      s = searchReduce(s, const DebounceFired(1));
      drain(s);
      s = searchReduce(s, QueryChanged('matrix')); // newer query
      drain(s);
      final after = searchReduce(
        s,
        SourceResult(1, Source.tmdb, TmdbSearchPayload([movie()], [])),
      );
      expect(after.requestsBumped, 1);
      expect(after.tmdbMovies, isEmpty);
    });
  });

  group('fan-out + incremental publish + settle', () {
    test('a keyless fan-out skips TMDB', () {
      final s = searchReduce(typed('matrix'), const DebounceFired(1));
      expect(s.pending, {Source.cinemeta, Source.jikan});
      expect(drain(s), [
        'fetch:cinemeta:1:matrix',
        'fetch:jikan:1:matrix',
      ]);
    });

    test('each landed source republishes; done only on full settle', () {
      var s = searchReduce(typed('matrix', tmdbKey: 'k'), const DebounceFired(1));
      drain(s);

      s = searchReduce(
        s,
        SourceResult(1, Source.tmdb, TmdbSearchPayload([movie()], [series()])),
      );
      expect(s.status, SearchStatus.loading); // still awaiting cinemeta + jikan
      expect(s.results, isNotNull);

      s = searchReduce(s, SourceResult(1, Source.cinemeta, const <Meta>[]));
      expect(s.status, SearchStatus.loading); // still awaiting jikan

      s = searchReduce(s, SourceResult(1, Source.jikan, const <AnimeHit>[]));
      expect(s.status, SearchStatus.done);
      expect(s.results!.query, 'matrix');
    });

    test('a late result after its source settled is dropped', () {
      var s = searchReduce(typed('matrix', tmdbKey: 'k'), const DebounceFired(1));
      drain(s);
      s = searchReduce(s, SourceTimedOut(1, Source.jikan));
      drain(s);
      final late = searchReduce(s, SourceResult(1, Source.jikan, const <AnimeHit>[]));
      expect(late.requestsBumped, 1);
      expect(late.anime, isEmpty);
    });

    test('a source timeout is a fallback to empty, never an error', () {
      var s = searchReduce(typed('matrix', tmdbKey: 'k'), const DebounceFired(1));
      drain(s);
      s = searchReduce(s, SourceTimedOut(1, Source.cinemeta));
      expect(s.sourceTimeouts, 1);
      expect(s.cineMovies, isEmpty);
      expect(s.cineSeries, isEmpty);
      expect(s.pending, isNot(contains(Source.cinemeta)));
      // the other two sources still settling → loading, not failed
      expect(s.status, SearchStatus.loading);
    });
  });

  group('merge order', () {
    test('cinemeta duplicates by id are dropped from the TMDB base', () {
      final tmdb = movie(id: 'tmdb:movie:603');
      final cineDup = movie(id: 'tmdb:movie:603', name: 'The Matrix (dup)');
      final merged = mergeMetas([tmdb], [cineDup, movie(id: 'tt0133093')]);
      expect(merged.map((m) => m.id), ['tmdb:movie:603', 'tt0133093']);
    });

    test('same title + same year is deduped; a remake (different year) survives', () {
      final a = movie(id: 'tmdb:movie:603', name: 'The Matrix', year: '1999');
      final dup = movie(id: 'tt9999999', name: 'The Matrix', year: '1999');
      final remake = movie(id: 'tt2222222', name: 'The Matrix', year: '2003');
      final out = dedupeByTitle([a, dup, remake]);
      expect(out.map((m) => m.id), ['tmdb:movie:603', 'tt2222222']);
    });

    test('anime wins over a colliding film row', () {
      final films = [movie(id: 'tt0133093', name: 'The Matrix')];
      final kept = notAnimeDupe(films[0], {'the matrix'});
      expect(kept, isFalse);
      final other = movie(id: 'tt0111161', name: 'The Shawshank Redemption');
      expect(notAnimeDupe(other, {'the matrix'}), isTrue);
    });

    test('a colliding anime replaces the top-match card with a kitsu: id', () {
      final base = TopMatch(kind: 'movie', meta: movie(name: 'The Matrix'));
      final anime = animeHit(kitsuId: 2222, malId: 1111, name: 'The Matrix', format: 'TV');
      final merged = mergeTopMatch(base, [anime]);
      expect(merged!.kind, 'series');
      expect(merged.meta.id, 'kitsu:2222');
      expect(merged.meta.type, 'anime');
      expect(merged.meta.name, 'The Matrix');
    });

    test('a non-colliding anime leaves the top match alone', () {
      final base = TopMatch(kind: 'movie', meta: movie(name: 'The Matrix'));
      final anime = animeHit(name: 'Attack on Titan');
      expect(mergeTopMatch(base, [anime])!.meta.id, base.meta.id);
    });

    test('the matching anime swaps the top match even when not first', () {
      final base = TopMatch(kind: 'movie', meta: movie(name: 'The Matrix'));
      final anime = [
        animeHit(name: 'Attack on Titan'),
        animeHit(kitsuId: 2222, malId: 1111, name: 'The Matrix', format: 'TV'),
      ];
      expect(mergeTopMatch(base, anime)!.meta.id, 'kitsu:2222');
    });

    test('the grid pins the top match first, then interleaves movies/series', () {
      final results = SearchResults(
        query: 'q',
        topMatch: TopMatch(kind: 'movie', meta: movie(id: 'tmdb:movie:1')),
        movies: [movie(id: 'tmdb:movie:2'), movie(id: 'tmdb:movie:3')],
        series: [series(id: 'tmdb:tv:4')],
      );
      expect(results.grid.map((m) => m.id), [
        'tmdb:movie:1',
        'tmdb:movie:2',
        'tmdb:tv:4',
        'tmdb:movie:3',
      ]);
    });
  });

  group('keyless fallback + snapshot re-apply', () {
    test('a keyless search has no top-match card and cinemeta-only rows', () {
      var s = searchReduce(typed('matrix'), const DebounceFired(1));
      drain(s);
      s = searchReduce(
        s,
        SourceResult(1, Source.cinemeta, [movie(id: 'tt0133093'), series(id: 'tt0903747')]),
      );
      s = searchReduce(s, SourceResult(1, Source.jikan, const <AnimeHit>[]));
      expect(s.status, SearchStatus.done);
      expect(s.results!.topMatch, isNull);
      expect(s.results!.movies.map((m) => m.id), ['tt0133093']);
      expect(s.results!.series.map((m) => m.id), ['tt0903747']);
    });

    test('a tmdbKey arriving re-runs the active query', () {
      var s = searchReduce(typed('matrix'), const DebounceFired(1));
      drain(s);
      s = searchReduce(s, SourceResult(1, Source.cinemeta, [movie(id: 'tt0133093')]));
      s = searchReduce(s, SourceResult(1, Source.jikan, const <AnimeHit>[]));
      drain(s);
      expect(s.status, SearchStatus.done);

      final after = searchReduce(s, KeyChanged('tmdb-key'));
      expect(after.tmdbKey, 'tmdb-key');
      expect(after.status, SearchStatus.typing);
      expect(after.requestId, 2);
      expect(drain(after), ['debounce:2']);
    });

    test('a key leaving downgrades a keyed search back to cinemeta', () {
      final after = searchReduce(typed('matrix', tmdbKey: 'k'), KeyChanged(null));
      expect(after.tmdbKey, isNull);
      expect(drain(after), ['debounce:2']);
    });

    test('an unchanged key is a no-op', () {
      final s = searchReduce(SearchState(tmdbKey: 'k'), KeyChanged('k'));
      expect(drain(s), isEmpty);
    });

    test('a key change with an empty query does not re-run anything', () {
      final s = searchReduce(SearchState(query: ''), KeyChanged('k'));
      expect(drain(s), isEmpty);
    });
  });

  group('playMeta encoding', () {
    test('a movie encodes metaType movie with resume', () {
      final s = searchReduce(SearchState(), PlayMeta(movie()));
      expect(drain(s), ['playMeta']);
      expect(s.pendingPlay!.toPayload(), {
        'metaId': 'tmdb:movie:603',
        'metaType': 'movie',
        'name': 'The Matrix',
        'poster': 'http://p/tmdb:movie:603.jpg',
        'resume': true,
      });
    });

    test('an anime hit is coerced to series', () {
      final s = searchReduce(SearchState(), PlayMeta(animeHit().meta));
      expect(s.pendingPlay!.toPayload()['metaType'], 'series');
      expect(s.pendingPlay!.toPayload()['metaId'], 'kitsu:6922');
    });

    test('a series with season/episode carries them', () {
      final s = searchReduce(
        SearchState(),
        PlayMeta(series(), season: 2, episode: 3),
      );
      expect(s.pendingPlay!.toPayload()['season'], 2);
      expect(s.pendingPlay!.toPayload()['episode'], 3);
    });
  });

  group('anime id derivation', () {
    test('prefers kitsu, then mal, then anilist', () {
      expect(animeHit(kitsuId: 1, malId: 2, anilistId: 3).metaId, 'kitsu:1');
      expect(animeHit(kitsuId: null, malId: 2, anilistId: 3).metaId, 'mal:2');
      expect(animeHit(kitsuId: null, malId: null, anilistId: 3).metaId, 'anilist:3');
    });

    test('kind is movie only for the Movie format', () {
      expect(animeHit(format: 'Movie').kind, 'movie');
      expect(animeHit(format: 'TV').kind, 'series');
    });
  });

  group('clear / recent / hide-anime', () {
    test('Clear drops everything and bumps the request id', () {
      var s = typed('matrix', tmdbKey: 'k');
      s = searchReduce(s, const DebounceFired(1));
      drain(s);
      final cleared = searchReduce(s, const Clear());
      expect(cleared.query, '');
      expect(cleared.status, SearchStatus.idle);
      expect(cleared.results, isNull);
      expect(cleared.requestId, 2);
    });

    test('Submit records the query once, capped at 8', () {
      var s = SearchState();
      for (var i = 1; i <= 10; i++) {
        s = searchReduce(s, QueryChanged('q$i'));
        s = searchReduce(s, const Submit());
      }
      expect(s.recent, hasLength(maxRecent));
      expect(s.recent.first, 'q10');
    });

    test('ToggleHideAnime flips the flag and republishes', () {
      var s = typed('matrix', tmdbKey: 'k');
      s = searchReduce(s, const DebounceFired(1));
      drain(s);
      s = searchReduce(s, SourceResult(1, Source.tmdb, TmdbSearchPayload([movie()], [])));
      s = searchReduce(s, SourceResult(1, Source.cinemeta, const <Meta>[]));
      s = searchReduce(s, SourceResult(1, Source.jikan, [animeHit()]));
      final hidden = searchReduce(s, const ToggleHideAnime());
      expect(hidden.hideAnime, isTrue);
      expect(hidden.results!.anime, isEmpty);
      final shown = searchReduce(hidden, const ToggleHideAnime());
      expect(shown.results!.anime, hasLength(1));
    });
  });
}
