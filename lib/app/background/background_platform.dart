// The one platform seam for the persistent-connection foreground service
// (ticket #64).
//
// Everything Android-specific hides behind this interface: start/update/stop
// the foreground service plus its notification, and a stream of actions the
// user performs on that notification. The default provider value is a safe
// no-op so unit tests never touch the platform; the real
// flutter_foreground_task-backed adapter is wired only in main()'s
// `ProviderScope(overrides: [...])`, exactly like HostRegistryStore /
// SubnetScanner / SettingsStore.
//
// This ticket builds the idle surface only ("Harbor Companion" / "Connected to
// <host>"). #65 adds the media surface and #66 the notification buttons; the
// action model stays intentionally minimal for now.

import 'dart:async';

/// The content of the idle foreground-service notification.
class BackgroundNotification {
  final String title;
  final String text;
  const BackgroundNotification({required this.title, required this.text});

  @override
  bool operator ==(Object other) =>
      other is BackgroundNotification &&
      other.title == title &&
      other.text == text;

  @override
  int get hashCode => Object.hash(title, text);

  @override
  String toString() => 'BackgroundNotification($title / $text)';
}

/// An action the user performed on the notification. Minimal for #64: #66 adds
/// the transport controls (play/pause, prev/next, seek).
enum BackgroundAction {
  /// The body of the notification was tapped. The shell opens the Remote tab
  /// (ticket #66); the background module only carries the signal.
  opened,

  /// The notification was dismissed. Android 14+ allows this without stopping
  /// the service — never tie service stop to notification dismissal.
  dismissed,
}

/// Raised by an adapter when the platform refuses to start/update/stop the
/// service: Android 12+ forbids a background foreground-service start, Android
/// 14+ throws when the service type's permission is missing, and the plugin can
/// also fail to bring up its engine. The controller catches it and folds a
/// degraded state, so a refused start never crashes the app.
class BackgroundServiceException implements Exception {
  final String message;
  const BackgroundServiceException(this.message);

  @override
  String toString() => 'BackgroundServiceException: $message';
}

/// The platform seam. A stop of an already-stopped service is a no-op success.
abstract interface class BackgroundPlatform {
  /// Start the foreground service and post [notification]. Throws
  /// [BackgroundServiceException] when Android refuses the start.
  Future<void> startService(BackgroundNotification notification);

  /// Update the running service's notification in place.
  Future<void> updateService(BackgroundNotification notification);

  /// Stop the service and remove its notification. No-op when not running.
  Future<void> stopService();

  /// Actions the user performs on the notification.
  Stream<BackgroundAction> get actions;
}

/// Safe default: does nothing and never emits. Keeps unit tests off the
/// platform; main() overrides it with the real adapter.
class NoopBackgroundPlatform implements BackgroundPlatform {
  const NoopBackgroundPlatform();

  @override
  Future<void> startService(BackgroundNotification notification) async {}

  @override
  Future<void> updateService(BackgroundNotification notification) async {}

  @override
  Future<void> stopService() async {}

  @override
  Stream<BackgroundAction> get actions => const Stream<BackgroundAction>.empty();
}
