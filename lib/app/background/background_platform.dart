// The one platform seam for the persistent-connection foreground service
// (tickets #64 / #65 / #67).
//
// Everything Android-specific hides behind this interface: start/update/stop
// the foreground service plus its notification, a stream of actions the user
// performs on that notification, and the OS notification-permission operations
// (#67). The default provider value is a safe no-op so unit tests never touch
// the platform; the real flutter_foreground_task-backed adapter is wired only
// in main()'s `ProviderScope(overrides: [...])`, exactly like
// HostRegistryStore / SubnetScanner / SettingsStore.
//
// #64 built the idle surface ("Harbor Companion" / "Connected to <host>").
// #65 makes the one notification morph: while the Remote layer holds media it
// carries a [BackgroundMediaSurface] (title + episode line, plus the poster and
// transport metadata #66 consumes). #66 adds the transport action vocabulary
// (play/pause, previous, next, seek) and the native `MediaSession` re-anchor.

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

/// An action the user performed on the notification (#66). The media controls
/// are host-authoritative: an action is just a request, mapped by the
/// controller onto the existing [RemoteController] methods; the next snapshot
/// re-renders the surface. Volume, mute and subtitles are intentionally absent
/// — volume would target the phone's stream, not the host's (ADR-0005).
///
/// A `sealed` hierarchy (rather than an enum) lets [BackgroundSeek] carry the
/// position it needs. The singleton members keep the call sites from #64/#65
/// (`BackgroundAction.opened`, `.dismissed`) working unchanged.
sealed class BackgroundAction {
  const BackgroundAction();

  /// The body of the notification was tapped. The shell opens the Remote tab.
  static const BackgroundAction opened = BackgroundOpened();

  /// The notification was dismissed. Android 14+ allows this without stopping
  /// the service — never tie service stop to notification dismissal.
  static const BackgroundAction dismissed = BackgroundDismissed();

  /// Play/pause toggle. Always present while media is held.
  static const BackgroundAction togglePlay = BackgroundTogglePlay();

  /// Previous episode. Only offered when the snapshot says it exists.
  static const BackgroundAction previous = BackgroundPrevious();

  /// Next episode. Only offered when the snapshot says it exists.
  static const BackgroundAction next = BackgroundNext();
}

final class BackgroundOpened extends BackgroundAction {
  const BackgroundOpened();
}

final class BackgroundDismissed extends BackgroundAction {
  const BackgroundDismissed();
}

final class BackgroundTogglePlay extends BackgroundAction {
  const BackgroundTogglePlay();
}

final class BackgroundPrevious extends BackgroundAction {
  const BackgroundPrevious();
}

final class BackgroundNext extends BackgroundAction {
  const BackgroundNext();
}

/// A seek request from the scrubber, in seconds.
final class BackgroundSeek extends BackgroundAction {
  final double positionSec;
  const BackgroundSeek(this.positionSec);

  @override
  bool operator ==(Object other) =>
      other is BackgroundSeek && other.positionSec == positionSec;

  @override
  int get hashCode => positionSec.hashCode;

  @override
  String toString() => 'BackgroundSeek($positionSec)';
}

/// The transport actions the notification may offer for [media], in system
/// compact-view order: previous (when it exists), play/pause (always), next
/// (when it exists). Returns empty while no media is held. The gating lives
/// here so both the plugin-button fallback and the native surface agree.
List<BackgroundAction> surfaceActions(BackgroundMediaSurface? media) {
  if (media == null) return const <BackgroundAction>[];
  return <BackgroundAction>[
    if (media.hasPrevEpisode) BackgroundAction.previous,
    BackgroundAction.togglePlay,
    if (media.hasNextEpisode) BackgroundAction.next,
  ];
}

/// The stable id for [action] on the platform wire (the inverse of
/// [backgroundActionFromId]). Seek has no id: the native surface always carries
/// its position, and the plugin-button fallback has no scrubber.
String? backgroundActionId(BackgroundAction action) {
  switch (action) {
    case BackgroundOpened():
      return 'opened';
    case BackgroundDismissed():
      return 'dismissed';
    case BackgroundTogglePlay():
      return 'togglePlay';
    case BackgroundPrevious():
      return 'previous';
    case BackgroundNext():
      return 'next';
    case BackgroundSeek():
      return null;
  }
}

/// Maps a raw action id (from the plugin TaskHandler's `sendDataToMain`, or the
/// native media channel) to a [BackgroundAction], or null when the id is not a
/// known transport action. Unknown ids — including any volume/mute/subtitles
/// command — are dropped, so those can never reach the surface.
BackgroundAction? backgroundActionFromId(String id, {double? positionSec}) {
  switch (id) {
    case 'opened':
      return BackgroundAction.opened;
    case 'dismissed':
      return BackgroundAction.dismissed;
    case 'togglePlay':
      return BackgroundAction.togglePlay;
    case 'previous':
      return BackgroundAction.previous;
    case 'next':
      return BackgroundAction.next;
    case 'seek':
      return positionSec == null ? null : BackgroundSeek(positionSec);
    default:
      return null;
  }
}

/// The OS notification-permission state the app acts on (ADR-0007).
///
/// `denied` is re-askable — Android will still show the prompt. `permanentlyDenied`
/// means the OS will no longer ask, so the Settings row deep-links to the app's
/// notification settings instead. `granted` needs nothing.
enum NotificationPermissionStatus {
  granted,
  denied,
  permanentlyDenied;

  /// Maps the native bridge's wire string. Unknown values fall back to
  /// [denied] — treat it as re-askable rather than silently permanent.
  static NotificationPermissionStatus fromWire(String? raw) => switch (raw) {
        'granted' => granted,
        'permanently_denied' => permanentlyDenied,
        _ => denied,
      };
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

  /// Re-anchor the native media surface from the freshest snapshot. Called on
  /// a position-only tick the plugin notification coalesces away, so the
  /// platform's `PlaybackState` extrapolates from the latest anchor. No-op
  /// when the adapter has no native surface. [media] null clears it.
  Future<void> updateMediaSession(BackgroundMediaSurface? media);

  /// Stop the service and remove its notification. No-op when not running.
  Future<void> stopService();

  /// The current `POST_NOTIFICATIONS` state (ADR-0007). On Android < 13 this is
  /// always [NotificationPermissionStatus.granted].
  Future<NotificationPermissionStatus> checkNotificationPermission();

  /// Fire the native `POST_NOTIFICATIONS` prompt and report the result. The
  /// caller must show the in-app rationale first; this is never called cold.
  Future<NotificationPermissionStatus> requestNotificationPermission();

  /// Open the app's OS notification settings (the deep-link path used when the
  /// permission is permanently denied).
  Future<void> openNotificationSettings();

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
  Future<void> updateMediaSession(BackgroundMediaSurface? media) async {}

  @override
  Future<void> stopService() async {}

  // Report the permission as already granted: the no-op default must never make
  // the app ask for anything.
  @override
  Future<NotificationPermissionStatus> checkNotificationPermission() async =>
      NotificationPermissionStatus.granted;

  @override
  Future<NotificationPermissionStatus> requestNotificationPermission() async =>
      NotificationPermissionStatus.granted;

  @override
  Future<void> openNotificationSettings() async {}

  @override
  Stream<BackgroundAction> get actions => const Stream<BackgroundAction>.empty();
}
