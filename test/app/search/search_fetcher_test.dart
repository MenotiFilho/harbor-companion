// Tests for the search JSON mappers and the shared Jikan throttle
// (lib/app/search/search_fetcher.dart, lib/app/search/jikan.dart).
//
// Pins the TMDB search/multi mapping (person skip, top-match by popularity with
// a poster), the Jikan search mapping, the relations id resolution, and the
// JikanQueue's serialization + 429 backoff + fallback-to-empty semantics.

import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:harbor_companion/app/search/jikan.dart';
import 'package:harbor_companion/app/search/search_fetcher.dart';
import 'package:harbor_companion/app/search/search_reducer.dart';

void main() {
  group('tmdb search/multi', () {
    test('maps movies/series, skips persons, derives the top match', () {
      final raw = jsonEncode({
        'results': [
          {
            'media_type': 'movie',
            'id': 603,
            'title': 'The Matrix',
            'poster_path': '/m.jpg',
            'backdrop_path': '/mb.jpg',
            'release_date': '1999-03-30',
            'popularity': 100.0,
            'vote_average': 8.2,
            'overview': 'A hacker…',
          },
          {
            'media_type': 'tv',
            'id': 1396,
            'name': 'Breaking Bad',
            'poster_path': '/b.jpg',
            'first_air_date': '2008-01-20',
            'popularity': 50.0,
          },
          {'media_type': 'person', 'id': 1, 'name': 'Keanu Reeves'},
          {
            'media_type': 'movie',
            'id': 99,
            'title': 'No Poster',
            'popularity': 999.0,
          },
        ],
      });
      final payload = parseTmdbSearch(raw);
      expect(payload.movies.map((m) => m.id), ['tmdb:603', 'tmdb:99']);
      expect(payload.series.map((m) => m.id), ['tmdb:1396']);
      // Highest popularity *with a poster* wins (the posterless 999 is skipped).
      expect(payload.topMatch!.meta.id, 'tmdb:603');
      expect(payload.topMatch!.meta.name, 'The Matrix');
      expect(payload.topMatch!.voteAverage, 8.2);
      expect(payload.topMatch!.meta.releaseInfo, '1999');
    });

    test('a person-only response has no top match', () {
      final payload = parseTmdbSearch(jsonEncode({
        'results': [
          {'media_type': 'person', 'id': 1, 'name': 'Keanu'},
        ],
      }));
      expect(payload.movies, isEmpty);
      expect(payload.series, isEmpty);
      expect(payload.topMatch, isNull);
    });
  });

  group('jikan search', () {
    test('maps Jikan data to anime hits', () {
      final raw = jsonEncode({
        'data': [
          {
            'mal_id': 16498,
            'title': 'Attack on Titan',
            'type': 'TV',
            'year': 2013,
            'images': {
              'jpg': {
                'image_url': 'https://img/at.jpg',
                'large_image_url': 'https://img/atl.jpg',
              },
            },
            'synopsis': 'Humanity fights titans.',
          },
        ],
      });
      final hits = parseJikanSearch(raw);
      expect(hits.single.malId, 16498);
      expect(hits.single.name, 'Attack on Titan');
      expect(hits.single.year, '2013');
      expect(hits.single.poster, 'https://img/atl.jpg');
      expect(hits.single.metaId, 'mal:16498');
      expect(hits.single.kind, 'series');
    });
  });

  group('relations id resolution', () {
    test('parses kitsu + anilist ids', () {
      final (kitsu, anilist) = parseAnimeIdRelations(
          '{"anidb":9541,"anilist":16498,"myanimelist":16498,"kitsu":7442}');
      expect(kitsu, 7442);
      expect(anilist, 16498);
    });

    test('tolerates a malformed response', () {
      expect(parseAnimeIdRelations('not json'), (null, null));
      expect(parseAnimeIdRelations('{"nope":true}'), (null, null));
    });
  });

  group('shared Jikan queue', () {
    test('serializes concurrent searches (never two in flight)', () {
      fakeAsync((async) {
        var inFlight = 0;
        var maxInFlight = 0;
        final fetches = <String>[];
        final queue = JikanQueue(fetch: (q) async {
          inFlight++;
          if (inFlight > maxInFlight) maxInFlight = inFlight;
          fetches.add(q);
          await Future<void>.delayed(const Duration(milliseconds: 50));
          inFlight--;
          return <AnimeHit>[];
        });
        queue.search('a');
        queue.search('b');
        async.elapse(const Duration(seconds: 2));
        async.flushMicrotasks();
        expect(maxInFlight, 1);
        expect(fetches, ['a', 'b']);
      });
    });

    test('a 429 backs off (2s/4s…) and retries to success', () {
      fakeAsync((async) {
        var attempts = 0;
        final queue = JikanQueue(fetch: (q) async {
          attempts++;
          if (attempts <= 2) throw const JikanRateLimited();
          return [AnimeHit(malId: 1, name: 'A')];
        });
        var result = const <AnimeHit>[];
        queue.search('a').then((r) => result = r);

        async.elapse(const Duration(milliseconds: 400));
        async.flushMicrotasks();
        expect(attempts, 1, reason: 'first attempt after the 400ms spacing');

        async.elapse(const Duration(milliseconds: 2000));
        async.flushMicrotasks();
        expect(attempts, 2, reason: '2s backoff then retry');

        async.elapse(const Duration(milliseconds: 4000));
        async.flushMicrotasks();
        expect(attempts, 3, reason: '4s backoff then success');
        expect(result, hasLength(1));
      });
    });

    test('exhausted 429 retries resolve to empty (never an error)', () {
      fakeAsync((async) {
        var attempts = 0;
        final queue = JikanQueue(fetch: (q) async {
          attempts++;
          throw const JikanRateLimited();
        });
        var result = <AnimeHit>[AnimeHit(malId: 9, name: 'x')];
        var threw = false;
        queue.search('a').then((r) => result = r, onError: (_) => threw = true);
        async.elapse(const Duration(seconds: 30));
        async.flushMicrotasks();
        expect(threw, isFalse);
        expect(attempts, 4);
        expect(result, isEmpty);
      });
    });

    test('a non-429 error resolves to empty (never an error)', () {
      fakeAsync((async) {
        final queue = JikanQueue(fetch: (q) async => throw Exception('boom'));
        var result = <AnimeHit>[AnimeHit(malId: 1, name: 'x')];
        var threw = false;
        queue.search('a').then((r) => result = r, onError: (_) => threw = true);
        async.elapse(const Duration(seconds: 1));
        async.flushMicrotasks();
        expect(threw, isFalse);
        expect(result, isEmpty);
      });
    });
  });
}
