// Tests for the Letterboxd/Stremboxd vocabulary and pure mappers
// (lib/app/letterboxd/letterboxd.dart): manifest parsing, catalog URL
// derivation, the toggle defaults, and config inactivity. `loadLetterboxdRows`
// orchestration is tested alongside its module in catalog_fetcher_test.dart.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:harbor_companion/app/letterboxd/letterboxd.dart';

void main() {
  group('manifest parsing', () {
    test('parses catalog ids, types and names', () {
      final manifest = parseLetterboxdManifest(jsonEncode({
        'catalogs': [
          {'type': 'movie', 'id': 'letterboxd-watchlist', 'name': "me's Watchlist"},
          {'type': 'movie', 'id': 'letterboxd-top250', 'name': 'Top 250'},
        ],
      }));
      expect(manifest.catalogs, hasLength(2));
      expect(manifest.catalogs[0].id, 'letterboxd-watchlist');
      expect(manifest.catalogs[0].type, 'movie');
      expect(manifest.catalogs[0].name, "me's Watchlist");
    });

    test('a nameless catalog falls back to its id; type defaults to movie', () {
      final manifest = parseLetterboxdManifest(jsonEncode({
        'catalogs': [
          {'id': 'letterboxd-liked-films'},
        ],
      }));
      expect(manifest.catalogs.single.name, 'letterboxd-liked-films');
      expect(manifest.catalogs.single.type, 'movie');
    });

    test('non-string id/type/name values are tolerated, not fatal', () {
      final manifest = parseLetterboxdManifest(jsonEncode({
        'catalogs': [
          {'id': 42},
          {'id': 'letterboxd-watchlist', 'type': 7, 'name': false},
        ],
      }));
      // The non-string id is dropped; the other keeps its id and falls back.
      expect(manifest.catalogs, hasLength(1));
      expect(manifest.catalogs.single.id, 'letterboxd-watchlist');
      expect(manifest.catalogs.single.type, 'movie');
      expect(manifest.catalogs.single.name, 'letterboxd-watchlist');
    });

    test('a malformed manifest yields no catalogs instead of throwing', () {
      expect(parseLetterboxdManifest('not json').catalogs, isEmpty);
      expect(parseLetterboxdManifest(jsonEncode({'nope': 1})).catalogs, isEmpty);
      expect(
        parseLetterboxdManifest(jsonEncode({'catalogs': ['nope', 42]})).catalogs,
        isEmpty,
      );
    });
  });

  group('catalog URL', () {
    const url = 'https://api.stremboxd.com/stremio/abc123/manifest.json';
    const catalog = LetterboxdCatalog(
      id: 'letterboxd-watchlist',
      type: 'movie',
      name: 'Watchlist',
    );

    test('derives the base by dropping /manifest.json, then /catalog/<type>/<id>', () {
      expect(letterboxdBase(url), 'https://api.stremboxd.com/stremio/abc123');
      expect(
        letterboxdCatalogUrl(url, catalog),
        'https://api.stremboxd.com/stremio/abc123/catalog/movie/letterboxd-watchlist.json',
      );
    });

    test('a trailing slash on the manifest URL is tolerated', () {
      expect(letterboxdBase('$url/'), 'https://api.stremboxd.com/stremio/abc123');
    });

    test('empty, non-absolute, or non-manifest URLs derive nothing', () {
      expect(letterboxdBase(''), isNull);
      expect(letterboxdBase('not a url'), isNull);
      // Without the /manifest.json suffix there is no base to derive.
      expect(letterboxdBase('https://api.stremboxd.com/stremio/abc123/'), isNull);
      expect(letterboxdCatalogUrl('', catalog), isNull);
    });
  });

  group('config', () {
    test('defaults: watchlist + recommended + popular on, friends + top250 off', () {
      expect(kDefaultLetterboxdCatalogIds, {
        'letterboxd-watchlist',
        'letterboxd-recommended',
        'letterboxd-popular',
      });
      // Every default id is one of the toggles the screen exposes.
      final toggleIds = kLetterboxdCatalogToggles.map((t) => t.id).toSet();
      expect(toggleIds.containsAll(kDefaultLetterboxdCatalogIds), isTrue);
    });

    test('isActive requires both a URL and at least one enabled catalog', () {
      expect(const LetterboxdConfig().isActive, isFalse);
      expect(
        const LetterboxdConfig(manifestUrl: 'https://x/manifest.json').isActive,
        isFalse,
      );
      expect(
        const LetterboxdConfig(enabledCatalogIds: {'letterboxd-watchlist'}).isActive,
        isFalse,
      );
      expect(
        const LetterboxdConfig(
          manifestUrl: 'https://x/manifest.json',
          enabledCatalogIds: {'letterboxd-watchlist'},
        ).isActive,
        isTrue,
      );
    });
  });
}
