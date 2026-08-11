// Minimal catalog model, mirroring the beta Meta shape (cinemeta/TMDB both map
// to this): id, name, poster, type.

class Meta {
  final String id;
  final String name;
  final String? poster;
  final String type; // "movie" | "series"
  const Meta({required this.id, required this.name, this.poster, required this.type});
}

class HomeRow {
  final String title;
  final List<Meta> items;
  const HomeRow(this.title, this.items);
}
