// Library persistence (ticket 06).
//
// My Stuff local persistence is off by default. When enabled, the reducer
// hands the controller a `persist` effect carrying the encoded library; the
// controller writes it through this seam and the enabled flag rides alongside
// so an offline fallback survives restarts.
//
// `LibraryStore` is the seam; tests provide an in-memory fake. The real store
// is shared_preferences-backed (a bool for the flag, a JSON string for the
// library content).

import 'package:shared_preferences/shared_preferences.dart';

abstract interface class LibraryStore {
  Future<bool> loadEnabled();
  Future<String?> loadData();
  Future<void> saveEnabled(bool enabled);
  Future<void> saveData(String encoded);
}

/// In-memory library store. Default seam for tests; holds state for the
/// process lifetime only.
class InMemoryLibraryStore implements LibraryStore {
  bool _enabled = false;
  String? _data;
  @override
  Future<bool> loadEnabled() async => _enabled;
  @override
  Future<String?> loadData() async => _data;
  @override
  Future<void> saveEnabled(bool enabled) async {
    _enabled = enabled;
  }

  @override
  Future<void> saveData(String encoded) async {
    _data = encoded;
  }
}

/// SharedPreferences-backed library store. Survives restarts.
class SharedPrefsLibraryStore implements LibraryStore {
  static const _enabledKey = 'harbor_companion.library.enabled';
  static const _dataKey = 'harbor_companion.library.data';

  @override
  Future<bool> loadEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_enabledKey) ?? false;
  }

  @override
  Future<String?> loadData() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_dataKey);
  }

  @override
  Future<void> saveEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledKey, enabled);
  }

  @override
  Future<void> saveData(String encoded) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_dataKey, encoded);
  }
}
