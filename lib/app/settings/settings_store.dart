// Settings persistence (tickets 40, 41).
//
// `SettingsStore` is the seam; tests provide an in-memory fake. The real store
// is shared_preferences-backed. It holds the Remote's playback-location toggle
// (off by default so a clean install hides it until the user opts in) and the
// Letterboxd/Stremboxd config: the user's manifest URL plus the catalog ids they
// enabled (watchlist/recommended/popular on by default).

import 'package:shared_preferences/shared_preferences.dart';

import '../home/home_rows.dart';
import '../letterboxd/letterboxd.dart';

abstract interface class SettingsStore {
  /// Whether the Remote should render the playback-location section. Defaults
  /// to `false` (hidden) when nothing is persisted.
  Future<bool> loadShowPlaybackLocation();

  Future<void> saveShowPlaybackLocation(bool show);

  /// The Stremboxd manifest URL (`''` when unset).
  Future<String> loadLetterboxdManifestUrl();

  Future<void> saveLetterboxdManifestUrl(String url);

  /// Built-in Home row keys the user switched off.
  Future<Set<String>> loadDisabledBuiltInRowKeys();

  Future<void> saveDisabledBuiltInRowKeys(Set<String> keys);

  /// Every known Home row key in display order.
  Future<List<String>> loadHomeRowOrder();

  Future<void> saveHomeRowOrder(List<String> order);

  /// The enabled Letterboxd catalog ids. Defaults to
  /// [kDefaultLetterboxdCatalogIds] when nothing is persisted; an empty set is
  /// preserved (the user turned every catalog off).
  Future<Set<String>> loadEnabledLetterboxdCatalogs();

  Future<void> saveEnabledLetterboxdCatalogs(Set<String> ids);

  /// Whether to keep the Harbor connection alive in the background via a
  /// foreground service. Defaults to `true` (opted in) when nothing is
  /// persisted.
  Future<bool> loadKeepConnectionInBackground();

  Future<void> saveKeepConnectionInBackground(bool keep);
}

/// In-memory settings store. Default seam for tests; holds state for the
/// process lifetime only.
class InMemorySettingsStore implements SettingsStore {
  bool _showPlaybackLocation = false;
  bool _keepConnectionInBackground = true;
  String _letterboxdManifestUrl = '';
  Set<String> _letterboxdCatalogIds = {...kDefaultLetterboxdCatalogIds};
  Set<String> _disabledBuiltInRowKeys = {};
  List<String> _homeRowOrder = [...kDefaultHomeRowOrder];

  @override
  Future<bool> loadShowPlaybackLocation() async => _showPlaybackLocation;
  @override
  Future<void> saveShowPlaybackLocation(bool show) async {
    _showPlaybackLocation = show;
  }

  @override
  Future<bool> loadKeepConnectionInBackground() async =>
      _keepConnectionInBackground;
  @override
  Future<void> saveKeepConnectionInBackground(bool keep) async {
    _keepConnectionInBackground = keep;
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

  @override
  Future<Set<String>> loadDisabledBuiltInRowKeys() async =>
      {..._disabledBuiltInRowKeys};
  @override
  Future<void> saveDisabledBuiltInRowKeys(Set<String> keys) async {
    _disabledBuiltInRowKeys = {...keys};
  }

  @override
  Future<List<String>> loadHomeRowOrder() async => [..._homeRowOrder];
  @override
  Future<void> saveHomeRowOrder(List<String> order) async {
    _homeRowOrder = [...order];
  }
}

/// SharedPreferences-backed settings store. Survives restarts.
class SharedPrefsSettingsStore implements SettingsStore {
  static const _showPlaybackLocationKey = 'harbor_companion.settings.show_playback_location';
  static const _keepConnectionInBackgroundKey = 'harbor_companion.settings.keep_connection_in_background';
  static const _letterboxdManifestUrlKey = 'harbor_companion.settings.letterboxd_manifest_url';
  static const _letterboxdCatalogIdsKey = 'harbor_companion.settings.letterboxd_catalog_ids';
  static const _disabledBuiltInRowsKey = 'harbor_companion.settings.disabled_built_in_rows';
  static const _homeRowOrderKey = 'harbor_companion.settings.home_row_order';

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
  Future<bool> loadKeepConnectionInBackground() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keepConnectionInBackgroundKey) ?? true;
  }

  @override
  Future<void> saveKeepConnectionInBackground(bool keep) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keepConnectionInBackgroundKey, keep);
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

  @override
  Future<Set<String>> loadDisabledBuiltInRowKeys() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_disabledBuiltInRowsKey)?.toSet() ?? {};
  }

  @override
  Future<void> saveDisabledBuiltInRowKeys(Set<String> keys) async {
    final prefs = await SharedPreferences.getInstance();
    if (keys.isEmpty) {
      await prefs.remove(_disabledBuiltInRowsKey);
    } else {
      await prefs.setStringList(_disabledBuiltInRowsKey, keys.toList()..sort());
    }
  }

  @override
  Future<List<String>> loadHomeRowOrder() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList(_homeRowOrderKey);
    return saved ?? [...kDefaultHomeRowOrder];
  }

  @override
  Future<void> saveHomeRowOrder(List<String> order) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_homeRowOrderKey, order);
  }
}
