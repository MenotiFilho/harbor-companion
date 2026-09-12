// Native notification-permission bridge (#67, ADR-0007).
//
// `flutter_foreground_task` owns the actual `POST_NOTIFICATIONS` prompt, but it
// does not expose `shouldShowRequestPermissionRationale`-style permanent-denial
// detection across a "never asked" state, nor a deep link to the app's
// notification settings. This MethodChannel (backed by MainActivity.kt) adds
// both; the adapter composes it with the plugin's request helper. Tests inject
// a fake through the adapter.

import 'package:flutter/services.dart';

import 'background_platform.dart';

abstract interface class NotificationPermissionBridge {
  /// The current OS permission state. A never-asked app reports [denied]
  /// (re-askable); only an actual refusal with no rationale left reports
  /// [permanentlyDenied].
  Future<NotificationPermissionStatus> checkStatus();

  /// Records that the app has asked, so a later [checkStatus] can tell
  /// "never asked" from "permanently denied".
  Future<void> markRequested();

  /// Opens the app's OS notification settings.
  Future<void> openNotificationSettings();
}

class MethodChannelNotificationPermission
    implements NotificationPermissionBridge {
  static const _channel =
      MethodChannel('dev.harbor.harbor_companion/notification_permission');

  @override
  Future<NotificationPermissionStatus> checkStatus() async {
    final raw = await _channel.invokeMethod<String>('checkStatus');
    return NotificationPermissionStatus.fromWire(raw);
  }

  @override
  Future<void> markRequested() async {
    await _channel.invokeMethod<void>('markRequested');
  }

  @override
  Future<void> openNotificationSettings() async {
    await _channel.invokeMethod<void>('openNotificationSettings');
  }
}
