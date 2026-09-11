// Disk-backed per-rail Home cache (ticket 72, ADR-0004).
//
// One versioned JSON file per entry under the app-support directory, written
// atomically (`temp` + `rename`) so a crash mid-write never leaves a half-file.
// Wired only in `main.dart`'s bootstrap, mirroring `SharedPrefsSettingsStore`.
//
// A corrupted or version-mismatched file costs one rail, never the Home: every
// read is guarded and returns null on any parse/version failure. A sweep removes
// rail files whose identity no longer matches the config; the manifest entry is
// kept separate and never swept.

import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'home_cache_store.dart';

/// Disk-backed cache. The directory is injectable for tests; production resolves
/// `<app-support>/home_cache` lazily on first use.
class HomeCacheDiskStore implements HomeCacheStore {
  static const _dirName = 'home_cache';
  static const _railPrefix = 'rail_';
  static const _fileSuffix = '.json';
  static const _manifestFile = 'manifest.json';
  static const _tempSuffix = '.tmp';

  final Directory? _baseOverride;
  Directory? _resolved;

  HomeCacheDiskStore({Directory? directory}) : _baseOverride = directory;

  Future<Directory> _dir() async {
    final existing = _resolved;
    if (existing != null) return existing;
    final base = _baseOverride ?? await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/$_dirName');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _resolved = dir;
    return dir;
  }

  String _railFileName(HomeCacheIdentity identity) =>
      '$_railPrefix${identity.token}$_fileSuffix';

  @override
  Future<CachedRail?> loadRail(HomeCacheIdentity identity) async {
    final file = File('${(await _dir()).path}/${_railFileName(identity)}');
    if (!await file.exists()) return null;
    try {
      return decodeCachedRail(await file.readAsString());
    } catch (_) {
      // An unreadable file costs one rail; the Home keeps rendering.
      return null;
    }
  }

  @override
  Future<void> saveRail(HomeCacheIdentity identity, CachedRail rail) async {
    final file = File('${(await _dir()).path}/${_railFileName(identity)}');
    await _atomicWrite(file, encodeCachedRail(rail));
  }

  @override
  Future<CachedManifest?> loadManifest(String manifestUrl) async {
    final file = File('${(await _dir()).path}/$_manifestFile');
    if (!await file.exists()) return null;
    try {
      final manifest = decodeCachedManifest(await file.readAsString());
      return manifest != null && manifest.manifestUrl == manifestUrl
          ? manifest
          : null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> saveManifest(CachedManifest manifest) async {
    final file = File('${(await _dir()).path}/$_manifestFile');
    await _atomicWrite(file, encodeCachedManifest(manifest));
  }

  @override
  Future<void> sweep(Iterable<HomeCacheIdentity> live) async {
    final keep = {for (final identity in live) _railFileName(identity)};
    final dir = await _dir();
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      if (!name.startsWith(_railPrefix) || !name.endsWith(_fileSuffix)) {
        continue;
      }
      if (keep.contains(name)) continue;
      try {
        await entity.delete();
      } catch (_) {
        // A file that can't be deleted is retried on the next sweep.
      }
    }
  }

  /// Writes [contents] to a sibling temp file, then renames it over [target] —
  /// atomic on the same filesystem, so readers never see a partial file.
  Future<void> _atomicWrite(File target, String contents) async {
    final temp = File('${target.path}$_tempSuffix');
    await temp.writeAsString(contents, flush: true);
    await temp.rename(target.path);
  }
}
