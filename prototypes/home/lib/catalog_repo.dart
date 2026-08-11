// Catalog data strategy (#5): Home rows come from TMDB when a key is available
// (auto-upgrades when snapshot.tmdbKey arrives), else Cinemeta. Fetches are
// stubbed — this spike measures *rendering* cost, not network. The real HTTP
// layer per row type lives behind this same interface in the real app.

import 'meta.dart';

class CatalogRepo {
  final String? tmdbKey;
  final int rowCount;
  CatalogRepo({this.tmdbKey, this.rowCount = 52});

  List<HomeRow> fetchHome() {
    final names = tmdbKey != null
        ? ['Trending', 'Popular', 'Top Rated', 'Now Playing', 'Upcoming', 'Airing Today', 'On The Air']
        : ['Action', 'Drama', 'Comedy', 'Sci-Fi', 'Thriller', 'Horror', 'Romance', 'Animation', 'Adventure', 'Crime', 'Mystery', 'Fantasy'];
    final tag = tmdbKey != null ? 'tmdb' : 'cine';
    return List.generate(rowCount, (i) {
      final base = names[i % names.length];
      return HomeRow('$base ${i ~/ names.length + 1}', _items('$tag:$base:$i', 7));
    });
  }

  List<Meta> _items(String prefix, int count) => [
        for (var i = 0; i < count; i++)
          Meta(
            id: '$prefix:$i',
            name: 'Title ${i + 1}',
            poster: 'https://img.test/p/$prefix/$i.jpg',
            type: i.isEven ? 'movie' : 'series',
          ),
      ];
}
