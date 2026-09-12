// Real `BackgroundPlatform` adapter backed by flutter_foreground_task
// (#64 / #65).
//
// Wired only in main(): unit tests use `NoopBackgroundPlatform` or a fake. The
// service hosts the app's process at foreground importance so the WebSocket
// survives backgrounding; the Dart socket itself stays on the main isolate.
//
// The service is type `connectedDevice` (the correct type for a LAN socket, and
// free of the `dataSync` 6h/24h cap) and holds a partial wake lock plus a WiFi
// lock. The single notification morphs: idle it reads "Harbor Companion" /
// "Connected to <host>"; with media it reads the media title + episode line
// (#65).
//
// Notification actions are produced in the service isolate by the TaskHandler
// and forwarded to the main isolate with `sendDataToMain`; the native
// `MediaSession` (see media_surface_channel.dart) routes its callbacks the same
// way. #66 turns them into RemoteController commands; this adapter forwards and
// gates them.
//
// Two surfaces, one interface:
//   - Preferred: the app-owned native `MediaSession` + `MediaStyle`
//     notification, published under the plugin service's own notification id.
//   - Fallback (no native channel, or the native call fails): the plugin's
//     notification buttons, capped at 3 and without a scrubber/artwork/
//     Bluetooth transport. The limitation is documented in
//     docs/android-media-surface.md.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'background_platform.dart';
import 'battery_settings.dart';
import 'media_surface_channel.dart';
import 'notification_permission.dart';

/// The Android notification channel shown for the persistent connection.
const String kBackgroundChannelId = 'harbor_companion.connection';
const String kBackgroundChannelName = 'Persistent connection';
const int kBackgroundServiceId = 4711;

/// TaskHandler entry point. Must be a top-level function (or static) so the
/// plugin can install it in the service isolate.
@pragma('vm:entry-point')
void foregroundTaskEntryPoint() {
  FlutterForegroundTask.setTaskHandler(_HarborTaskHandler());
}

/// The service-isolate handler: it does no work itself, it only forwards
/// notification actions to the main isolate. The main isolate owns the socket
/// and all state.
class _HarborTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}

  @override
  void onNotificationPressed() =>
      FlutterForegroundTask.sendDataToMain(const {'action': 'opened'});

  @override
  void onNotificationButtonPressed(String id) =>
      FlutterForegroundTask.sendDataToMain({'action': id});

  @override
  void onNotificationDismissed() =>
      FlutterForegroundTask.sendDataToMain(const {'action': 'dismissed'});
}

/// Initialize the plugin once in main(), before runApp: the communication port
/// that delivers TaskHandler data to the main isolate, plus the notification
/// and task options. The service holds a partial wake lock and a WiFi lock.
void initializeForegroundTask() {
  FlutterForegroundTask.initCommunicationPort();
  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: kBackgroundChannelId,
      channelName: kBackgroundChannelName,
      channelDescription: 'Keeps the Harbor connection alive.',
      onlyAlertOnce: true,
    ),
    iosNotificationOptions: const IOSNotificationOptions(
      showNotification: false,
      playSound: false,
    ),
    foregroundTaskOptions: ForegroundTaskOptions(
      // No Dart work on a timer: the service only hosts the process.
      eventAction: ForegroundTaskEventAction.nothing(),
      allowWakeLock: true,
      allowWifiLock: true,
      // Surviving a system kill / reboot is out of scope for #64, and an
      // auto-restarted service would outlive the Dart state that owns it.
      allowAutoRestart: false,
    ),
  );
}

class FlutterForegroundTaskBackgroundPlatform implements BackgroundPlatform {
  /// [mediaSurface] is the native MediaStyle surface (#66); when absent the
  /// adapter falls back to the plugin's notification buttons. [notificationPermission]
  /// is the native permission bridge (#67); the real MethodChannel-backed one is
  /// the default.
  FlutterForegroundTaskBackgroundPlatform({
    this.mediaSurface,
    NotificationPermissionBridge? notificationPermission,
    BatterySettingsBridge? batterySettings,
  })  : notificationPermission =
            notificationPermission ?? MethodChannelNotificationPermission(),
        batterySettings = batterySettings ?? MethodChannelBatterySettings() {
    FlutterForegroundTask.addTaskDataCallback(_onTaskData);
    // App-lifetime adapter: the broadcast subscription lives as long as it does.
    mediaSurface?.actions.listen(_actions.add);
  }

  final MediaSurfaceChannel? mediaSurface;
  final NotificationPermissionBridge notificationPermission;
  final BatterySettingsBridge batterySettings;

  final StreamController<BackgroundAction> _actions =
      StreamController<BackgroundAction>.broadcast();

  @override
  Stream<BackgroundAction> get actions => _actions.stream;

  void _onTaskData(Object data) {
    if (data is! Map) return;
    final id = data['action'];
    if (id is! String) return;
    final action = backgroundActionFromId(id);
    if (action != null) _actions.add(action);
  }

  /// The plugin-button fallback (max 3 buttons, no scrubber), gated by
  /// [surfaceActions] so it agrees with the native surface. A no-op when the
  /// native surface is handling the media, so the two never fight.
  List<NotificationButton>? _buttons(BackgroundNotification notification) {
    if (mediaSurface != null) return null;
    final actions = surfaceActions(notification.media);
    if (actions.isEmpty) return null;
    return [
      for (final action in actions)
        NotificationButton(id: backgroundActionId(action)!, text: _label(action)),
    ];
  }

  String _label(BackgroundAction action) => switch (action) {
        BackgroundPrevious() => 'Previous',
        BackgroundNext() => 'Next',
        _ => 'Play/Pause',
      };

  @override
  Future<void> startService(BackgroundNotification notification) async {
    final result = await FlutterForegroundTask.startService(
      serviceId: kBackgroundServiceId,
      // The one type the platform permits for a LAN connection; never
      // dataSync/mediaPlayback/remoteMessaging.
      serviceTypes: const [ForegroundServiceTypes.connectedDevice],
      // Media title/episode line when media is already held; the native
      // surface replaces this with artwork + controls below.
      notificationTitle: notification.title,
      notificationText: notification.text,
      notificationButtons: _buttons(notification),
      callback: foregroundTaskEntryPoint,
    );
    final alreadyStarted = result is ServiceRequestFailure &&
        result.error is ServiceAlreadyStartedException;
    if (!alreadyStarted) {
      _throwIfFailed(result, 'start');
    }
    // The service is up; publish the media surface in its notification slot.
    if (notification.media != null) {
      await mediaSurface?.show(notification);
    }
  }

  @override
  Future<void> updateService(BackgroundNotification notification) async {
    // With media and a native surface, the media notification IS the update:
    // it carries the poster and controls, under the service's own id.
    final surface = mediaSurface;
    if (notification.media != null && surface != null) {
      await surface.show(notification);
      return;
    }
    // Idle (morph back), or no native surface: the plugin notification, with
    // transport buttons in the fallback case. Deactivate the native session
    // first so the lock-screen/Bluetooth surface drops immediately.
    if (notification.media == null) {
      try {
        await mediaSurface?.clear();
      } catch (_) {
        // Best-effort; the plugin repost below still restores the idle status.
      }
    }
    final result = await FlutterForegroundTask.updateService(
      notificationTitle: notification.title,
      notificationText: notification.text,
      notificationButtons: _buttons(notification),
    );
    _throwIfFailed(result, 'update');
  }

  @override
  Future<void> updateMediaSession(BackgroundMediaSurface? media) async {
    final surface = mediaSurface;
    if (surface == null || media == null) return;
    await surface.anchor(media);
  }

  @override
  Future<void> stopService() async {
    try {
      await mediaSurface?.clear();
    } catch (_) {
      // Best-effort teardown; the plugin stop below removes the notification.
    }
    final result = await FlutterForegroundTask.stopService();
    if (result is ServiceRequestFailure) {
      final error = result.error;
      // Never started / already stopped: a no-op success.
      if (error is ServiceNotStartedException) return;
      throw BackgroundServiceException('stop failed: $error');
    }
  }

  @override
  Future<NotificationPermissionStatus> checkNotificationPermission() =>
      notificationPermission.checkStatus();

  @override
  Future<NotificationPermissionStatus> requestNotificationPermission() async {
    // Record the ask first: even if the OS dialog is interrupted, a later
    // status check must not mistake "never asked" for "permanently denied".
    await notificationPermission.markRequested();
    final result = await FlutterForegroundTask.requestNotificationPermission();
    return switch (result) {
      NotificationPermission.granted => NotificationPermissionStatus.granted,
      NotificationPermission.denied => NotificationPermissionStatus.denied,
      NotificationPermission.permanently_denied =>
        NotificationPermissionStatus.permanentlyDenied,
    };
  }

  @override
  Future<void> openNotificationSettings() =>
      notificationPermission.openNotificationSettings();

  // -- Battery / OEM onboarding (#68) ----------------------------------------

  @override
  Future<bool> isIgnoringBatteryOptimizations() =>
      FlutterForegroundTask.isIgnoringBatteryOptimizations;

  @override
  Future<bool> requestIgnoreBatteryOptimizations() async {
    // The plugin resolves the intent and reports the post-request exemption
    // state. We only care whether the prompt was dispatched: any platform
    // failure (no activity, no handler) means the direct path is unavailable,
    // so the caller falls back to the optimization list.
    try {
      await FlutterForegroundTask.requestIgnoreBatteryOptimization();
      return true;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<void> openBatteryOptimizationSettings() async {
    try {
      await FlutterForegroundTask.openIgnoreBatteryOptimizationSettings();
    } on PlatformException {
      // The list is unavailable; the generic battery screen is the last route.
      await openBatterySettings();
    }
  }

  @override
  Future<void> openBatterySettings() => batterySettings.openBatterySettings();

  void _throwIfFailed(ServiceRequestResult result, String operation) {
    if (result is ServiceRequestFailure) {
      throw BackgroundServiceException('$operation failed: ${result.error}');
    }
  }
}
