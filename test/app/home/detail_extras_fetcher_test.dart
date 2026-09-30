// Tests for the detail extras fetcher
// (lib/app/home/detail_extras_fetcher.dart).
//
// Pins the TMDB credits and `/find` wire shapes as top-level mappers and the
// narrow fetcher's keyless/no-match/cache behavior, all without network.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:harbor_companion/app/home/detail_extras_fetcher.dart';

String credits(List<Map<String, Object?>> cast) => jsonEncode({'cast': cast});

void main() {
  group('parseTmdbCredits', () {
    test('maps name, character and the avatar-sized profile URL', () {
      final cast = parseTmdbCredits(credits([
        {
          'name': 'Keanu Reeves',
          'character': 'Neo',
          'profile_path': '/keanu.jpg',
          'order': 0,
        },
      ]));

      expect(cast.single.name, 'Keanu Reeves');
      expect(cast.single.character, 'Neo');
      expect(cast.single.profile, 'https://image.tmdb.org/t/p/w185/keanu.jpg');
    });

    test('billing order decides, not the array order', () {
      final cast = parseTmdbCredits(credits([
        {'name': 'Second', 'order': 1},
        {'name': 'First', 'order': 0},
      ]));

      expect(cast.map((m) => m.name), ['First', 'Second']);
    });

    test('caps the rail at the top-billed kCastCap', () {
      final cast = parseTmdbCredits(credits([
        for (var i = 0; i < kCastCap + 3; i++) {'name': 'Actor $i', 'order': i},
      ]));

      expect(cast, hasLength(kCastCap));
      expect(cast.first.name, 'Actor 0');
    });

    test('a missing character or profile stays null; nameless entries skip',
        () {
      final cast = parseTmdbCredits(credits([
        {'name': 'Uncredited', 'order': 0},
        {'character': 'No Name', 'order': 1},
        {'name': 'Named', 'character': '', 'profile_path': null, 'order': 2},
      ]));

      expect(cast.map((m) => m.name), ['Uncredited', 'Named']);
      expect(cast.first.character, isNull);
      expect(cast.first.profile, isNull);
      expect(cast.last.character, isNull, reason: 'empty string is no credit');
      expect(cast.last.profile, isNull);
    });

    test('a body without a cast array is empty, not a crash', () {
      expect(parseTmdbCredits('{}'), isEmpty);
      expect(parseTmdbCredits(jsonEncode({'cast': 'nope'})), isEmpty);
    });
  });

  group('parseTmdbFind', () {
    test('a series resolves from tv_results', () {
      final target = parseTmdbFind(
        jsonEncode({'tv_results': [{'id': 1396}]}),
        'series',
      );
      expect(target, const TmdbTarget('tv', '1396'));
    });

    test('a movie resolves from movie_results', () {
      final target = parseTmdbFind(
        jsonEncode({'movie_results': [{'id': 603}]}),
        'movie',
      );
      expect(target, const TmdbTarget('movie', '603'));
    });

    test('a mismatched id never borrows the other list', () {
      final raw = jsonEncode({'movie_results': [{'id': 603}]});
      expect(parseTmdbFind(raw, 'series'), isNull);
    });

    test('an empty or absent result list is no match', () {
      expect(parseTmdbFind(jsonEncode({'tv_results': []}), 'series'), isNull);
      expect(parseTmdbFind('{}', 'movie'), isNull);
    });
  });

  group('tmdbTargetFromId', () {
    test('tmdb:movie: and tmdb:tv: ids map directly', () {
      expect(tmdbTargetFromId('tmdb:movie:603'), const TmdbTarget('movie', '603'));
      expect(tmdbTargetFromId('tmdb:tv:1396'), const TmdbTarget('tv', '1396'));
    });

    test('a tt id and an unknown kind need /find', () {
      expect(tmdbTargetFromId('tt0903747'), isNull);
      expect(tmdbTargetFromId('tmdb:person:5'), isNull);
      expect(tmdbTargetFromId('tmdb:movie:'), isNull);
    });
  });

  group('fetchCast', () {
    test('without a key nothing is requested and nothing is returned', () async {
      var gets = 0;
      final fetcher = HttpDetailExtrasFetcher(get: (url) async {
        gets++;
        return credits([]);
      });

      expect(await fetcher.fetchCast('movie', 'tmdb:movie:603', null), isEmpty);
      expect(await fetcher.fetchCast('series', 'tt0903747', ''), isEmpty);
      expect(gets, 0);
    });

    test('a tmdb: id fetches its credits endpoint', () async {
      final urls = <String>[];
      final fetcher = HttpDetailExtrasFetcher(get: (url) async {
        urls.add(url.toString());
        return credits([
          {'name': 'Keanu Reeves', 'character': 'Neo', 'order': 0},
        ]);
      });

      final cast = await fetcher.fetchCast('movie', 'tmdb:movie:603', 'key');

      expect(cast.single.name, 'Keanu Reeves');
      expect(
        urls.single,
        'https://api.themoviedb.org/3/movie/603/credits?api_key=key',
      );
    });

    test('a tt id resolves through /find, then fetches that target', () async {
      final urls = <String>[];
      final fetcher = HttpDetailExtrasFetcher(get: (url) async {
        urls.add(url.toString());
        if (url.path.contains('/find/')) {
          return jsonEncode({'tv_results': [{'id': 1396}]});
        }
        return credits([
          {'name': 'Bryan Cranston', 'order': 0},
        ]);
      });

      final cast = await fetcher.fetchCast('series', 'tt0903747', 'key');

      expect(cast.single.name, 'Bryan Cranston');
      expect(urls[0], contains('/find/tt0903747'));
      expect(urls[0], contains('external_source=imdb_id'));
      expect(
        urls[1],
        'https://api.themoviedb.org/3/tv/1396/credits?api_key=key',
      );
    });

    test('no match yields nothing and the negative is cached', () async {
      var finds = 0;
      final fetcher = HttpDetailExtrasFetcher(get: (url) async {
        finds++;
        return jsonEncode({'movie_results': [], 'tv_results': []});
      });

      expect(await fetcher.fetchCast('series', 'tt0000', 'key'), isEmpty);
      expect(await fetcher.fetchCast('series', 'tt0000', 'key'), isEmpty);
      expect(finds, 1, reason: 'the resolved no-match is cached for the session');
    });

    test('a second fetch is served by the session cache', () async {
      var gets = 0;
      final fetcher = HttpDetailExtrasFetcher(get: (url) async {
        gets++;
        return credits([
          {'name': 'A', 'order': 0},
        ]);
      });

      await fetcher.fetchCast('movie', 'tmdb:movie:603', 'key');
      await fetcher.fetchCast('movie', 'tmdb:movie:603', 'key');

      expect(gets, 1);
    });

    test('an empty cast is a legitimate empty result', () async {
      final fetcher = HttpDetailExtrasFetcher(get: (url) async => credits([]));
      expect(await fetcher.fetchCast('movie', 'tmdb:movie:1', 'key'), isEmpty);
    });

    test('an HTTP failure propagates to the section provider', () async {
      final fetcher = HttpDetailExtrasFetcher(
        get: (url) async => throw Exception('down'),
      );

      await expectLater(
        fetcher.fetchCast('movie', 'tmdb:movie:603', 'key'),
        throwsA(isA<Exception>()),
      );
    });
  });
}
