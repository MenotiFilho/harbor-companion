// Built-in Home rails and the canonical row order (ticket 41 follow-up).
//
// Every rail the Home can render has a stable string key so the user's
// visibility + order choices survive restarts and can interleave the two built-in
// sources (Cinemeta / TMDB) with the Letterboxd catalogs:
//   - built-in: the [BuiltInRow.id], e.g. `cinemeta:top-movies`, `tmdb:upcoming`
//   - Letterboxd: `letterboxd:<catalogId>`, e.g. `letterboxd:letterboxd-watchlist`
//
// The Home only ever shows one built-in source at a time (TMDB when the host has
// a key, else Cinemeta); the other group's rows are simply skipped.

import '../letterboxd/letterboxd.dart';

/// A built-in rail: a stable id, the source that serves it, and its request
/// shape + display title.
class BuiltInRow {
  final String id;
  final String source; // 'cinemeta' | 'tmdb'
  final String path;
  final String type; // 'movie' | 'series'
  final String title;
  const BuiltInRow({
    required this.id,
    required this.source,
    required this.path,
    required this.type,
    required this.title,
  });
}

/// Cinemeta rails (keyless fallback), mirroring the beta mobile home.
const List<BuiltInRow> kCinemetaRows = [
  BuiltInRow(id: 'cinemeta:top-movies', source: 'cinemeta', path: '/catalog/movie/top.json', type: 'movie', title: 'Top Movies'),
  BuiltInRow(id: 'cinemeta:top-series', source: 'cinemeta', path: '/catalog/series/top.json', type: 'series', title: 'Top Series'),
  BuiltInRow(id: 'cinemeta:action', source: 'cinemeta', path: '/catalog/movie/top/genre=Action.json', type: 'movie', title: 'Action'),
  BuiltInRow(id: 'cinemeta:drama', source: 'cinemeta', path: '/catalog/movie/top/genre=Drama.json', type: 'movie', title: 'Drama'),
  BuiltInRow(id: 'cinemeta:comedy', source: 'cinemeta', path: '/catalog/movie/top/genre=Comedy.json', type: 'movie', title: 'Comedy'),
  BuiltInRow(id: 'cinemeta:sci-fi', source: 'cinemeta', path: '/catalog/movie/top/genre=Sci-Fi.json', type: 'movie', title: 'Sci-Fi'),
  BuiltInRow(id: 'cinemeta:animation', source: 'cinemeta', path: '/catalog/movie/top/genre=Animation.json', type: 'movie', title: 'Animation'),
  BuiltInRow(id: 'cinemeta:thriller', source: 'cinemeta', path: '/catalog/movie/top/genre=Thriller.json', type: 'movie', title: 'Thriller'),
  BuiltInRow(id: 'cinemeta:series-drama', source: 'cinemeta', path: '/catalog/series/top/genre=Drama.json', type: 'series', title: 'Series Drama'),
  BuiltInRow(id: 'cinemeta:series-comedy', source: 'cinemeta', path: '/catalog/series/top/genre=Comedy.json', type: 'series', title: 'Series Comedy'),
];

/// TMDB rails (keyed), mirroring the beta mobile home.
const List<BuiltInRow> kTmdbRows = [
  BuiltInRow(id: 'tmdb:trending-movies', source: 'tmdb', path: '/trending/movie/week', type: 'movie', title: 'Trending Movies'),
  BuiltInRow(id: 'tmdb:trending-series', source: 'tmdb', path: '/trending/tv/week', type: 'series', title: 'Trending Series'),
  BuiltInRow(id: 'tmdb:popular-movies', source: 'tmdb', path: '/movie/popular', type: 'movie', title: 'Popular Movies'),
  BuiltInRow(id: 'tmdb:top-rated-movies', source: 'tmdb', path: '/movie/top_rated', type: 'movie', title: 'Top Rated Movies'),
  BuiltInRow(id: 'tmdb:now-playing', source: 'tmdb', path: '/movie/now_playing', type: 'movie', title: 'Now Playing'),
  BuiltInRow(id: 'tmdb:upcoming', source: 'tmdb', path: '/movie/upcoming', type: 'movie', title: 'Upcoming'),
  BuiltInRow(id: 'tmdb:popular-series', source: 'tmdb', path: '/tv/popular', type: 'series', title: 'Popular Series'),
  BuiltInRow(id: 'tmdb:top-rated-series', source: 'tmdb', path: '/tv/top_rated', type: 'series', title: 'Top Rated Series'),
  BuiltInRow(id: 'tmdb:on-the-air', source: 'tmdb', path: '/tv/on_the_air', type: 'series', title: 'On The Air'),
  BuiltInRow(id: 'tmdb:discover-movies', source: 'tmdb', path: '/discover/movie', type: 'movie', title: 'Discover Movies'),
  BuiltInRow(id: 'tmdb:discover-series', source: 'tmdb', path: '/discover/tv', type: 'series', title: 'Discover Series'),
];

/// Every built-in rail, both sources.
const List<BuiltInRow> kAllBuiltInRows = [...kCinemetaRows, ...kTmdbRows];

final Map<String, BuiltInRow> _builtInById = {
  for (final row in kAllBuiltInRows) row.id: row,
};

BuiltInRow? builtInRowById(String id) => _builtInById[id];

const String _letterboxdPrefix = 'letterboxd:';

String letterboxdRowKey(String catalogId) => '$_letterboxdPrefix$catalogId';
bool isLetterboxdRowKey(String key) => key.startsWith(_letterboxdPrefix);
String? letterboxdCatalogId(String key) =>
    isLetterboxdRowKey(key) ? key.substring(_letterboxdPrefix.length) : null;

/// The Letterboxd row keys the app knows (the toggles it exposes).
final Set<String> kLetterboxdRowKeys = {
  for (final toggle in kLetterboxdCatalogToggles) letterboxdRowKey(toggle.id),
};

/// The canonical order: Cinemeta rails, then TMDB rails, then the Letterboxd
/// catalogs. The user can move any of these (e.g. Letterboxd first).
const List<String> kDefaultHomeRowOrder = [
  'cinemeta:top-movies',
  'cinemeta:top-series',
  'cinemeta:action',
  'cinemeta:drama',
  'cinemeta:comedy',
  'cinemeta:sci-fi',
  'cinemeta:animation',
  'cinemeta:thriller',
  'cinemeta:series-drama',
  'cinemeta:series-comedy',
  'tmdb:trending-movies',
  'tmdb:trending-series',
  'tmdb:popular-movies',
  'tmdb:top-rated-movies',
  'tmdb:now-playing',
  'tmdb:upcoming',
  'tmdb:popular-series',
  'tmdb:top-rated-series',
  'tmdb:on-the-air',
  'tmdb:discover-movies',
  'tmdb:discover-series',
  'letterboxd:letterboxd-watchlist',
  'letterboxd:letterboxd-recommended',
  'letterboxd:letterboxd-friends',
  'letterboxd:letterboxd-popular',
  'letterboxd:letterboxd-top250',
];

/// Fills in any known key the saved [order] is missing (a new app version's
/// rails) and drops unknown keys, so stored order never loses rows.
List<String> normalizeRowOrder(Iterable<String> order) {
  final seen = <String>{};
  final result = <String>[];
  for (final key in order) {
    if (_builtInById.containsKey(key) || kLetterboxdRowKeys.contains(key)) {
      if (seen.add(key)) result.add(key);
    }
  }
  for (final key in kDefaultHomeRowOrder) {
    if (seen.add(key)) result.add(key);
  }
  return result;
}

/// How a row key is presented in the Home-rows editor.
class HomeRowEntry {
  final String key;
  final String label;
  final String source; // 'Cinemeta' | 'TMDB' | 'Letterboxd'
  final bool isLetterboxd;
  const HomeRowEntry({
    required this.key,
    required this.label,
    required this.source,
    required this.isLetterboxd,
  });
}

HomeRowEntry? homeRowEntry(String key) {
  final builtIn = builtInRowById(key);
  if (builtIn != null) {
    return HomeRowEntry(
      key: key,
      label: builtIn.title,
      source: builtIn.source == 'cinemeta' ? 'Cinemeta' : 'TMDB',
      isLetterboxd: false,
    );
  }
  final catalogId = letterboxdCatalogId(key);
  if (catalogId == null) return null;
  for (final toggle in kLetterboxdCatalogToggles) {
    if (toggle.id == catalogId) {
      return HomeRowEntry(
        key: key,
        label: toggle.label,
        source: 'Letterboxd',
        isLetterboxd: true,
      );
    }
  }
  return null;
}
