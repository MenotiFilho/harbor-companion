// Settings persistence (tickets 40, 41).
//
// `SettingsStore` is the seam; tests provide an in-memory fake. The real store
// is shared_preferences-backed. It holds the Remote's playback-location toggle
// (off by default so a clean install hides it until the user opts in) and the
// Letterboxd/Stremboxd config: the user's manifest URL plus the catalog ids they
// enabled (watchlist/recommended/popular on by default).

import 'package:shared_preferences/shared_preferences.dart';

import '../letterboxd/letterboxd.dart';

abstract interface class SettingsStore {
  /// Whether the Remote should render the playback-location section. Defaults
  /// to `false` (hidden) when nothing is persisted.
  Future<bool> loadShowPlaybackLocation();

  Future<void> saveShowPlaybackLocation(bool show);

  /// The Stremboxd manifest URL (`''` when unset).
  Future<String> loadLetterboxdManifestUrl();

  Future<void> saveLetterboxdManifestUrl(String url);

  /// The enabled Letterboxd catalog ids. Defaults to
  /// [kDefaultLetterboxdCatalogIds] when nothing is persisted; an empty set is
  /// preserved (the user turned every catalog off).
  Future<Set<String>> loadEnabledLetterboxdCatalogs();

  Future<void> saveEnabledLetterboxdCatalogs(Set<String> ids);
}

/// In-memory settings store. Default seam for tests; holds state for the
/// process lifetime only.
class InMemorySettingsStore implements SettingsStore {
  bool _showPlaybackLocation = false;
  String _letterboxdManifestUrl = '';
  Set<String> _letterboxdCatalogIds = {...kDefaultLetterboxdCatalogIds};

  @override
  Future<bool> loadShowPlaybackLocation() async => _showPlaybackLocation;
  @override
  Future<void> saveShowPlaybackLocation(bool show) async {
    _showPlaybackLocation = show;
  }

  @override
  Future<String> loadLetterboxdManifestUrl() async => _letterboxdManifestUrl;
  @override
  Future<void> saveLetterboxdManifestUrl(String url) async {
    _letterboxdManifestUrl = url;
  }

  @override
  Future<Set<String>> loadEnabledLetterboxdCatalogs() async =>
      {..._letterboxdCatalogIds};
  @override
  Future<void> saveEnabledLetterboxdCatalogs(Set<String> ids) async {
    _letterboxdCatalogIds = {...ids};
  }
}

/// SharedPreferences-backed settings store. Survives restarts.
class SharedPrefsSettingsStore implements SettingsStore {
  static const _showPlaybackLocationKey = 'harbor_companion.settings.show_playback_location';
  static const _letterboxdManifestUrlKey = 'harbor_companion.settings.letterboxd_manifest_url';
  static const _letterboxdCatalogIdsKey = 'harbor_companion.settings.letterboxd_catalog_ids';

  @override
  Future<bool> loadShowPlaybackLocation() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_showPlaybackLocationKey) ?? false;
  }

  @override
  Future<void> saveShowPlaybackLocation(bool show) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_showPlaybackLocationKey, show);
  }

  @override
  Future<String> loadLetterboxdManifestUrl() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_letterboxdManifestUrlKey) ?? '';
  }

  @override
  Future<void> saveLetterboxdManifestUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    if (url.isEmpty) {
      await prefs.remove(_letterboxdManifestUrlKey);
    } else {
      await prefs.setString(_letterboxdManifestUrlKey, url);
    }
  }

  @override
  Future<Set<String>> loadEnabledLetterboxdCatalogs() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList(_letterboxdCatalogIdsKey);
    return saved?.toSet() ?? {...kDefaultLetterboxdCatalogIds};
  }

  @override
  Future<void> saveEnabledLetterboxdCatalogs(Set<String> ids) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_letterboxdCatalogIdsKey, ids.toList()..sort());
  }
}
