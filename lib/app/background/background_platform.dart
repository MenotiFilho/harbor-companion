// The one platform seam for the persistent-connection foreground service
// (tickets #64 / #65).
//
// Everything Android-specific hides behind this interface: start/update/stop
// the foreground service plus its notification, and a stream of actions the
// user performs on that notification. The default provider value is a safe
// no-op so unit tests never touch the platform; the real
// flutter_foreground_task-backed adapter is wired only in main()'s
// `ProviderScope(overrides: [...])`, exactly like HostRegistryStore /
// SubnetScanner / SettingsStore.
//
// #64 built the idle surface ("Harbor Companion" / "Connected to <host>").
// #65 makes the one notification morph: while the Remote layer holds media it
// carries a [BackgroundMediaSurface] (title + episode line, plus the poster and
// transport metadata #66 consumes). The action model stays intentionally
// minimal until #66 adds the transport controls.

import 'dart:async';

/// The media surface carried by the foreground-service notification while the
/// Remote layer holds something (#65).
///
/// #65 renders [title] + [episodeLine] as the notification title/text through
/// the plugin. [posterUrl] and the transport metadata ([positionSec],
/// [durationSec], [hasPrevEpisode], [hasNextEpisode]) are carried for #66's
/// native `MediaSessionCompat` + `MediaStyle` surface: `flutter_foreground_task`
/// 11.0.3 only exposes a resource `NotificationIcon` and `BigTextStyle`, so it
/// cannot render a network bitmap or a MediaStyle.
class BackgroundMediaSurface {
  final String title;
  final String? episodeLine;
  final String? posterUrl;
  final bool playing;
  final double positionSec;
  final double durationSec;
  final bool hasPrevEpisode;
  final bool hasNextEpisode;

  const BackgroundMediaSurface({
    required this.title,
    this.episodeLine,
    this.posterUrl,
    required this.playing,
    this.positionSec = 0,
    this.durationSec = 0,
    this.hasPrevEpisode = false,
    this.hasNextEpisode = false,
  });

  @override
  bool operator ==(Object other) =>
      other is BackgroundMediaSurface &&
      other.title == title &&
      other.episodeLine == episodeLine &&
      other.posterUrl == posterUrl &&
      other.playing == playing &&
      other.positionSec == positionSec &&
      other.durationSec == durationSec &&
      other.hasPrevEpisode == hasPrevEpisode &&
      other.hasNextEpisode == hasNextEpisode;

  @override
  int get hashCode => Object.hash(title, episodeLine, posterUrl, playing,
      positionSec, durationSec, hasPrevEpisode, hasNextEpisode);

  @override
  String toString() =>
      'BackgroundMediaSurface($title / ${episodeLine ?? '-'} / '
      '${playing ? 'playing' : 'paused'})';
}

/// The content of the foreground-service notification. It morphs between the
/// idle host status ([media] null) and the playing surface (#65); value equality
/// lets the reducer coalesce updates instead of re-posting an identical
/// notification.
class BackgroundNotification {
  final String title;
  final String text;

  /// The playing surface, or null while the notification is the idle host
  /// status. One notification morphed between the two.
  final BackgroundMediaSurface? media;

  const BackgroundNotification({
    required this.title,
    required this.text,
    this.media,
  });

  bool get isIdle => media == null;

  @override
  bool operator ==(Object other) =>
      other is BackgroundNotification &&
      other.title == title &&
      other.text == text &&
      other.media == media;

  @override
  int get hashCode => Object.hash(title, text, media);

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
