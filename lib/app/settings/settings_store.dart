// Settings persistence (ticket 40).
//
// `SettingsStore` is the seam; tests provide an in-memory fake. The real store
// is shared_preferences-backed. Currently it holds a single preference: whether
// the Remote shows the playback-location ("This PC" / cast) section — off by
// default so a clean install hides it until the user opts in.

import 'package:shared_preferences/shared_preferences.dart';

abstract interface class SettingsStore {
  /// Whether the Remote should render the playback-location section. Defaults
  /// to `false` (hidden) when nothing is persisted.
  Future<bool> loadShowPlaybackLocation();

  Future<void> saveShowPlaybackLocation(bool show);
}

/// In-memory settings store. Default seam for tests; holds state for the
/// process lifetime only.
class InMemorySettingsStore implements SettingsStore {
  bool _showPlaybackLocation = false;
  @override
  Future<bool> loadShowPlaybackLocation() async => _showPlaybackLocation;
  @override
  Future<void> saveShowPlaybackLocation(bool show) async {
    _showPlaybackLocation = show;
  }
}

/// SharedPreferences-backed settings store. Survives restarts.
class SharedPrefsSettingsStore implements SettingsStore {
  static const _showPlaybackLocationKey = 'harbor_companion.settings.show_playback_location';

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
}
