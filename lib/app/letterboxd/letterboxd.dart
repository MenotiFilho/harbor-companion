// Letterboxd catalogs via the Stremboxd addon (ticket 41).
//
// The Home can show the user's Letterboxd rails by consuming a Stremboxd addon
// manifest directly — the same "public source, never Harbor" pattern as
// Cinemeta/TMDB (wire-contract-research §41: the Harbor beta remote exposes no
// catalogs, so this is a client-side source). The user brings their own manifest
// URL.
//
// This module is the shared vocabulary between the Home (which fetches the
// rails) and Settings (which owns the knobs): the catalog toggles, the config in
// effect, the manifest model + pure parser, and URL derivation. A catalog
// response reuses `parseCinemetaCatalog` (same `{ "metas": [...] }` shape), so no
// item mapper lives here.

import 'dart:convert';

/// A catalog the Settings screen offers as a toggle. The id is Stremboxd's
/// stable catalog id; [label] is the fallback shown in Settings (the Home rail
/// uses the manifest's own `name`).
class LetterboxdCatalogToggle {
  final String id;
  final String label;
  const LetterboxdCatalogToggle(this.id, this.label);
}

/// The five Letterboxd catalogs the app exposes. `letterboxd-search` and the
/// other Stremboxd catalogs (diary, liked films) are intentionally out of scope;
/// a toggle enabled here only renders if the user's manifest lists that id.
const List<LetterboxdCatalogToggle> kLetterboxdCatalogToggles = [
  LetterboxdCatalogToggle('letterboxd-watchlist', 'Watchlist'),
  LetterboxdCatalogToggle('letterboxd-recommended', 'Recommended'),
  LetterboxdCatalogToggle('letterboxd-friends', 'Friends Activity'),
  LetterboxdCatalogToggle('letterboxd-popular', 'Popular This Week'),
  LetterboxdCatalogToggle('letterboxd-top250', 'Top 250'),
];

/// Catalogs enabled before the user chooses. Watchlist + Recommended +
/// Popular are on; Friends Activity + Top 250 are opt-in.
const Set<String> kDefaultLetterboxdCatalogIds = {
  'letterboxd-watchlist',
  'letterboxd-recommended',
  'letterboxd-popular',
};

/// The Letterboxd/Stremboxd configuration in effect: the user's manifest URL
/// plus the catalog ids they enabled. An empty URL (or no enabled ids) means the
/// Home never talks to Stremboxd.
class LetterboxdConfig {
  final String manifestUrl;
  final Set<String> enabledCatalogIds;
  const LetterboxdConfig({
    this.manifestUrl = '',
    this.enabledCatalogIds = const {},
  });

  bool get isActive =>
      manifestUrl.trim().isNotEmpty && enabledCatalogIds.isNotEmpty;

  @override
  bool operator ==(Object other) =>
      other is LetterboxdConfig &&
      other.manifestUrl == manifestUrl &&
      _sameSet(other.enabledCatalogIds, enabledCatalogIds);

  @override
  int get hashCode =>
      Object.hash(manifestUrl, Object.hashAllUnordered(enabledCatalogIds));
}

bool _sameSet(Set<String> a, Set<String> b) =>
    a.length == b.length && a.containsAll(b);

/// A catalog entry from the manifest: the id used in the `/catalog/<type>/<id>`
/// path, the media type, and the display name for the rail.
class LetterboxdCatalog {
  final String id;
  final String type;
  final String name;
  const LetterboxdCatalog({
    required this.id,
    required this.type,
    required this.name,
  });
}

class LetterboxdManifest {
  final List<LetterboxdCatalog> catalogs;
  const LetterboxdManifest(this.catalogs);
}

/// Parses a Stremboxd manifest's `catalogs` array. `extra`, `resources` and the
/// behavior hints are ignored — only the url path + display name matter here.
/// A non-JSON body (e.g. an HTML error page) or a malformed entry yields no
/// catalog, never a throw.
LetterboxdManifest parseLetterboxdManifest(String raw) {
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } catch (_) {
    return const LetterboxdManifest([]);
  }
  if (decoded is! Map<String, dynamic>) return const LetterboxdManifest([]);
  final catalogs = decoded['catalogs'];
  if (catalogs is! List) return const LetterboxdManifest([]);

  final parsed = <LetterboxdCatalog>[];
  for (final c in catalogs) {
    if (c is! Map<String, dynamic>) continue;
    final catalog = _parseCatalog(c);
    if (catalog != null) parsed.add(catalog);
  }
  return LetterboxdManifest(parsed);
}

LetterboxdCatalog? _parseCatalog(Map<String, dynamic> c) {
  final id = c['id'];
  if (id is! String || id.isEmpty) return null;
  final type = c['type'];
  final name = c['name'];
  return LetterboxdCatalog(
    id: id,
    // Fall back to the id so a nameless catalog still gets a rail title.
    name: name is String && name.isNotEmpty ? name : id,
    type: type is String && type.isNotEmpty ? type : 'movie',
  );
}

/// The addon base URL behind [manifestUrl]: the manifest URL minus its trailing
/// `/manifest.json` (a trailing slash is tolerated). Null when the URL is not an
/// absolute URL ending in `/manifest.json`.
String? letterboxdBase(String manifestUrl) {
  var trimmed = manifestUrl.trim();
  while (trimmed.endsWith('/')) {
    trimmed = trimmed.substring(0, trimmed.length - 1);
  }
  if (trimmed.isEmpty) return null;
  final uri = Uri.tryParse(trimmed);
  if (uri == null || !uri.hasScheme || !uri.hasAuthority) return null;
  const suffix = '/manifest.json';
  final path = uri.path;
  if (!path.toLowerCase().endsWith(suffix)) return null;
  final basePath = path.substring(0, path.length - suffix.length);
  return '${uri.scheme}://${uri.authority}$basePath';
}

/// The catalog endpoint for [catalog] on the account behind [manifestUrl]:
/// `<base>/catalog/<type>/<id>.json`. Null when the manifest URL is unusable.
String? letterboxdCatalogUrl(String manifestUrl, LetterboxdCatalog catalog) {
  final base = letterboxdBase(manifestUrl);
  return base == null ? null : '$base/catalog/${catalog.type}/${catalog.id}.json';
}
