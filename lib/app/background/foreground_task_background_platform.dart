// Real `BackgroundPlatform` adapter backed by flutter_foreground_task (#64).
//
// Wired only in main(): unit tests use `NoopBackgroundPlatform` or a fake. The
// service hosts the app's process at foreground importance so the WebSocket
// survives backgrounding; the Dart socket itself stays on the main isolate.
//
// The service is type `connectedDevice` (the correct type for a LAN socket, and
// free of the `dataSync` 6h/24h cap) and holds a partial wake lock plus a WiFi
// lock. The idle notification reads "Harbor Companion" / "Connected to <host>".
//
// Notification actions are produced in the service isolate by the TaskHandler
// and forwarded to the main isolate with `sendDataToMain`. #66 turns them into
// RemoteController commands; this adapter only forwards them.

import 'dart:async';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'background_platform.dart';

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
  FlutterForegroundTaskBackgroundPlatform() {
    FlutterForegroundTask.addTaskDataCallback(_onTaskData);
  }

  final StreamController<BackgroundAction> _actions =
      StreamController<BackgroundAction>.broadcast();

  @override
  Stream<BackgroundAction> get actions => _actions.stream;

  void _onTaskData(Object data) {
    if (data is! Map) return;
    switch (data['action']) {
      case 'opened':
        _actions.add(BackgroundAction.opened);
      case 'dismissed':
        _actions.add(BackgroundAction.dismissed);
    }
  }

  @override
  Future<void> startService(BackgroundNotification notification) async {
    final result = await FlutterForegroundTask.startService(
      serviceId: kBackgroundServiceId,
      // The one type the platform permits for a LAN connection; never
      // dataSync/mediaPlayback/remoteMessaging.
      serviceTypes: const [ForegroundServiceTypes.connectedDevice],
      notificationTitle: notification.title,
      notificationText: notification.text,
      callback: foregroundTaskEntryPoint,
    );
    if (result is ServiceRequestFailure &&
        result.error is ServiceAlreadyStartedException) {
      // The service outlived our state (process restart); it is up.
      return;
    }
    _throwIfFailed(result, 'start');
  }

  @override
  Future<void> updateService(BackgroundNotification notification) async {
    final result = await FlutterForegroundTask.updateService(
      notificationTitle: notification.title,
      notificationText: notification.text,
    );
    _throwIfFailed(result, 'update');
  }

  @override
  Future<void> stopService() async {
    final result = await FlutterForegroundTask.stopService();
    if (result is ServiceRequestFailure) {
      final error = result.error;
      // Never started / already stopped: a no-op success.
      if (error is ServiceNotStartedException) return;
      throw BackgroundServiceException('stop failed: $error');
    }
  }

  void _throwIfFailed(ServiceRequestResult result, String operation) {
    if (result is ServiceRequestFailure) {
      throw BackgroundServiceException('$operation failed: ${result.error}');
    }
  }
}
