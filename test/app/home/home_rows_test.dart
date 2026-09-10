// Tests for the built-in row vocabulary + canonical order
// (lib/app/home/home_rows.dart).

import 'package:flutter_test/flutter_test.dart';

import 'package:harbor_companion/app/home/home_rows.dart';
import 'package:harbor_companion/app/letterboxd/letterboxd.dart';

void main() {
  test('every known row appears exactly once in the default order', () {
    final expected = {
      for (final row in [...kCinemetaRows, ...kTmdbRows]) row.id,
      for (final toggle in kLetterboxdCatalogToggles) letterboxdRowKey(toggle.id),
    };
    expect(kDefaultHomeRowOrder.toSet(), expected);
    expect(kDefaultHomeRowOrder, hasLength(expected.length));
  });

  test('built-in rows are looked up by id', () {
    expect(builtInRowById('cinemeta:top-movies')!.title, 'Top Movies');
    expect(builtInRowById('tmdb:trending-movies')!.source, 'tmdb');
    expect(builtInRowById('nope'), isNull);
  });

  test('letterboxd keys round-trip', () {
    final key = letterboxdRowKey('letterboxd-watchlist');
    expect(isLetterboxdRowKey(key), isTrue);
    expect(letterboxdCatalogId(key), 'letterboxd-watchlist');
    expect(isLetterboxdRowKey('cinemeta:top-movies'), isFalse);
    expect(letterboxdCatalogId('cinemeta:top-movies'), isNull);
  });

  test('normalizeRowOrder keeps saved order, appends missing, drops unknown', () {
    final normalized = normalizeRowOrder([
      'tmdb:upcoming', // moved to front
      'bogus:key', // unknown → dropped
      'tmdb:upcoming', // duplicate → dropped
      'cinemeta:top-movies',
    ]);
    expect(normalized.first, 'tmdb:upcoming');
    expect(normalized[1], 'cinemeta:top-movies');
    expect(normalized, isNot(contains('bogus:key')));
    // An unknown Letterboxd id is dropped too (only the app's toggles count).
    expect(normalizeRowOrder(['letterboxd:letterboxd-search']),
        isNot(contains('letterboxd:letterboxd-search')));
    // Every known key ends up present.
    expect(normalized.toSet(), kDefaultHomeRowOrder.toSet());
    expect(normalized, hasLength(kDefaultHomeRowOrder.length));
  });

  test('normalizeRowOrder fences a completely empty order', () {
    expect(normalizeRowOrder(const []), kDefaultHomeRowOrder);
  });

  test('homeRowEntry labels and sources', () {
    expect(homeRowEntry('cinemeta:top-movies')!.source, 'Cinemeta');
    expect(homeRowEntry('cinemeta:top-movies')!.isLetterboxd, isFalse);
    expect(homeRowEntry('tmdb:upcoming')!.source, 'TMDB');
    final lb = homeRowEntry(letterboxdRowKey('letterboxd-watchlist'))!;
    expect(lb.label, 'Watchlist');
    expect(lb.source, 'Letterboxd');
    expect(lb.isLetterboxd, isTrue);
    expect(homeRowEntry('bogus'), isNull);
  });
}
