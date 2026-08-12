// Catalog model for Home (ticket 04).
//
// Mirrors the beta `Meta` shape that both Cinemeta and TMDB map to: id, name,
// poster, and a `movie`/`series` type. `HomeRow` is a titled horizontal rail of
// `Meta`; `DetailMeta` carries the season/episode structure the detail page
// renders (Cinemeta `videos[]` or TMDB season episodes) plus the play target.

/// A catalog entry: a title the user can open or play on the host.
class Meta {
  final String id; // imdb id "tt…" (cinemeta) or "tmdb:<id>"
  final String type; // "movie" | "series"
  final String name;
  final String? poster;
  final String? background;
  final String? description;
  final String? releaseInfo; // year-ish string

  const Meta({
    required this.id,
    required this.type,
    required this.name,
    this.poster,
    this.background,
    this.description,
    this.releaseInfo,
  });

  bool get isSeries => type == 'series';
}

/// A titled row of posters, rendered as a horizontal rail.
class HomeRow {
  final String title;
  final List<Meta> items;
  const HomeRow(this.title, this.items);
}

/// A single episode within a season.
class Episode {
  final int season;
  final int episode;
  final String name;
  final String? overview;
  final String? still;
  const Episode({
    required this.season,
    required this.episode,
    required this.name,
    this.overview,
    this.still,
  });
}

/// A season of a series, with its episodes in order.
class Season {
  final int number;
  final String name;
  final String? poster;
  final List<Episode> episodes;
  const Season({
    required this.number,
    required this.name,
    this.poster,
    this.episodes = const [],
  });

  Episode? get firstEpisode => episodes.isEmpty ? null : episodes.first;
}

/// The detail view for a title: the base [Meta] plus season/episode structure
/// (empty for movies).
class DetailMeta {
  final Meta meta;
  final List<Season> seasons;
  const DetailMeta({required this.meta, this.seasons = const []});

  /// The first playable episode across all seasons (series only); null for a
  /// movie. The detail page's primary play button uses this.
  (int season, int episode)? get firstEpisode {
    for (final season in seasons) {
      final ep = season.firstEpisode;
      if (ep != null) return (ep.season, ep.episode);
    }
    return null;
  }
}
