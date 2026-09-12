// Native battery-settings bridge (#68, ADR-0007).
//
// `flutter_foreground_task` exposes the exemption check, the direct
// `ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` prompt and the
// `ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS` list, but it does not open the
// generic system battery screen. This thin MethodChannel (backed by
// MainActivity.kt) adds that one intent for the OEM tips action. The adapter
// composes it with the plugin helpers; tests never touch it.

import 'package:flutter/services.dart';

abstract interface class BatterySettingsBridge {
  /// Opens the generic system battery-settings screen.
  Future<void> openBatterySettings();
}

class MethodChannelBatterySettings implements BatterySettingsBridge {
  static const _channel =
      MethodChannel('dev.harbor.harbor_companion/battery');

  @override
  Future<void> openBatterySettings() async {
    await _channel.invokeMethod<void>('openBatterySettings');
  }
}
