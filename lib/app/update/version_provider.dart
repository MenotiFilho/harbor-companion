// Local version seam (ticket 28).
//
// The reducer needs the local `versionCode` (the Android build number) to
// compare against a release's. `VersionProvider` is the seam the controller
// reads at startup; tests inject a fake. `name` rides along for display only —
// it is never used for comparison logic.
//
// The real provider reads `package_info_plus`.

import 'package:package_info_plus/package_info_plus.dart';

/// The local app version read at startup. [code] is the comparison key;
/// [name] is display-only.
class LocalVersion {
  final int code;
  final String name;
  const LocalVersion(this.code, this.name);
}

abstract interface class VersionProvider {
  Future<LocalVersion> load();
}

/// package_info_plus-backed version provider. `buildNumber` is the Android
/// `versionCode`; `version` is the `versionName` (display only).
class PackageInfoVersionProvider implements VersionProvider {
  @override
  Future<LocalVersion> load() async {
    final info = await PackageInfo.fromPlatform();
    return LocalVersion(int.tryParse(info.buildNumber) ?? 0, info.version);
  }
}
