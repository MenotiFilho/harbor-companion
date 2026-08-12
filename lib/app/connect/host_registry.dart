// Host registry persistence (ticket 03).
//
// The reducer keeps `warned` and `lastConnectedAt` on each HostEntry, so
// persistence is a pure serialization of the registry. The controller saves
// the whole list whenever it changes and restores it on launch (before the
// `Launch` auto-connect).
//
// `HostRegistryStore` is the seam; tests provide an in-memory fake. The real
// store is shared_preferences-backed (JSON array under one key).

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'connect_reducer.dart';

abstract interface class HostRegistryStore {
  Future<List<HostEntry>> load();
  Future<void> save(List<HostEntry> hosts);
}

/// Serializes the registry to a JSON string. Shared by the store and tests.
String encodeRegistry(List<HostEntry> hosts) =>
    jsonEncode([for (final h in hosts) h.toJson()]);

/// Deserializes a JSON string back into a registry. Unknown/corrupt entries
/// are dropped rather than crashing a cold start.
List<HostEntry> decodeRegistry(String raw) {
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! List) return const [];
    return [
      for (final e in decoded)
        if (e is Map<String, dynamic>) HostEntry.fromJson(e),
    ];
  } catch (_) {
    return const [];
  }
}

/// In-memory registry store. Default seam for tests; holds state for the
/// process lifetime only.
class InMemoryHostRegistryStore implements HostRegistryStore {
  List<HostEntry> _hosts = const [];
  @override
  Future<List<HostEntry>> load() async => _hosts;
  @override
  Future<void> save(List<HostEntry> hosts) async {
    _hosts = hosts;
  }
}

/// SharedPreferences-backed registry store. Survives restarts.
class SharedPrefsHostRegistryStore implements HostRegistryStore {
  static const _key = 'harbor_companion.host_registry';

  @override
  Future<List<HostEntry>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    return raw == null ? const [] : decodeRegistry(raw);
  }

  @override
  Future<void> save(List<HostEntry> hosts) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, encodeRegistry(hosts));
  }
}
