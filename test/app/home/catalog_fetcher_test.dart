// Tests for the catalog JSON mappers (lib/app/home/catalog_fetcher.dart).
//
// Pins the Cinemeta/TMDB wire shapes against representative payloads so the
// Home/catalog mapping (id prefixing, poster URL building, season/episode
// derivation) is exercised without network.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:harbor_companion/app/home/catalog_fetcher.dart';

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
      expect(metas.single.id, 'tmdb:603');
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
      expect(meta.id, 'tmdb:603');
      expect(meta.type, 'movie');
    });
  });
}
