// Install-permission seam for the self-update install half (ticket 30).
//
// The reducer gates the install on `canRequestPackageInstalls()` and, when the
// grant is missing, opens the package-scoped "Install unknown apps" screen so
// the user can enable it lazily (no first-run nag). The real implementation is
// a MethodChannel backed by MainActivity.kt; tests inject a fake.

import 'package:flutter/services.dart';

abstract interface class InstallPermissionAdapter {
  Future<bool> canRequestPackageInstalls();
  Future<void> openInstallPermissionSettings();
}

class MethodChannelInstallPermission implements InstallPermissionAdapter {
  static const _channel =
      MethodChannel('dev.harbor.harbor_companion/install_permission');

  @override
  Future<bool> canRequestPackageInstalls() async =>
      await _channel.invokeMethod<bool>('canRequestPackageInstalls') ?? false;

  @override
  Future<void> openInstallPermissionSettings() async {
    await _channel.invokeMethod<void>('openInstallPermissionSettings');
  }
}
