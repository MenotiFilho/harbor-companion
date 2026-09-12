// Pure background / foreground-service state model (tickets #64 / #65).
//
// `(BackgroundState, BackgroundEvent) => BackgroundState` producing an effects
// buffer the controller drains onto the `BackgroundPlatform` seam. No I/O, no
// timers, no platform calls — this is the decision seam the tests pin.
//
// The decision: host the `connectedDevice` foreground service whenever there is
// an active host and the user's "keep connection in background" toggle is on.
// Android forbids starting a foreground service from the background, so a
// desired service whose app is backgrounded waits for the next foreground
// instead of failing. A refused start folds into `degraded` (honest, no crash);
// it is only retried when a fresh trigger arrives (a new connect, a foreground
// return, or the toggle being switched on).
//
// #65: the single notification morphs. [NowPlayingChanged] folds in the derived
// media surface (null when disconnected or nothing is held); the notification
// getter picks idle host status vs. media, and `_reconcile` posts an in-place
// update only when the rendered surface actually changes.
//
// #66: a position-only tick (400 ms while playing) still re-anchors the native
// `MediaSession`'s `PlaybackState` — the plugin notification is not re-posted,
// but the platform must extrapolate from the freshest position, so a
// `updateMediaSession` effect is emitted without an `updateService`.
//
// #67: the `POST_NOTIFICATIONS` request is contextual. The rationale is due
// only when the service is wanted (connected + toggle on) and the permission is
// missing but re-askable, and it is offered at most once per session; accepting
// emits the real OS prompt, declining cancels it. A denial never changes the
// service lifecycle — the notification merely does not appear.
//
// Effects vocabulary:
//   `startService`           → platform.startService(state.notification)
//   `updateService`          → platform.updateService(state.notification)
//   `updateMediaSession`     → platform.updateMediaSession(state.media)
//   `stopService`            → platform.stopService()
//   `requestPermission`      → platform.requestNotificationPermission()
//   `openNotificationSettings` → platform.openNotificationSettings()

import 'background_platform.dart';

enum BackgroundServiceStatus {
  /// No foreground service is running.
  stopped,

  /// A start was requested and is in flight.
  starting,

  /// The foreground service is up and its notification is posted.
  running,

  /// A stop was requested and is in flight.
  stopping,

  /// The platform refused a start (Android background-start restriction or a
  /// missing type permission). The app keeps working without the service.
  degraded,
}

class BackgroundState {
  /// An active host: a live connection, or an established one being retried.
  /// A host that has never connected does not count (no service for a dead
  /// address).
  final bool connected;

  /// The active host's display name, for the idle notification.
  final String? hostName;

  /// The user's "keep connection in background" opt-out (default on).
  final bool keepConnectionInBackground;

  /// The app is in the foreground. Android permits an FGS start only here.
  final bool foregrounded;

  final BackgroundServiceStatus serviceStatus;

  /// The last refused-start reason, kept for an honest status line.
  final String? lastError;

  /// The playing surface the Remote layer currently holds, or null when
  /// nothing is held. Folded in from [NowPlayingChanged]; the notification
  /// getter morphs between it and the idle host status.
  final BackgroundMediaSurface? media;

  /// The notification currently shown by the platform; a host/media change
  /// while running triggers exactly one in-place update. Null when none is
  /// posted (or after a stop).
  final BackgroundNotification? notified;

  /// The last known `POST_NOTIFICATIONS` state (#67). Assumed granted until the
  /// controller's async check lands, so a late first connect can never prompt
  /// cold.
  final NotificationPermissionStatus notificationPermission;

  /// The in-app rationale should be shown. The shell observes this and shows
  /// the dialog; accepting emits `requestPermission`, declining cancels it
  /// without firing the OS prompt.
  final bool rationaleVisible;

  /// The automatic rationale has already been offered this session. It gates
  /// the automatic prompt so a decline (or an answer) never re-nags; the
  /// Settings row requests manually and bypasses this.
  final bool permissionPrompted;

  /// Effects buffer: the reducer appends effects here; the controller drains
  /// them. The one mutable field (impure by convention).
  final List<String> effects;

  BackgroundState({
    this.connected = false,
    this.hostName,
    this.keepConnectionInBackground = true,
    this.foregrounded = true,
    this.serviceStatus = BackgroundServiceStatus.stopped,
    this.lastError,
    this.media,
    this.notified,
    this.notificationPermission = NotificationPermissionStatus.granted,
    this.rationaleVisible = false,
    this.permissionPrompted = false,
    List<String>? effects,
  }) : effects = effects ?? <String>[];

  /// The service is wanted when a host is active and the user has not opted out.
  bool get desired => connected && keepConnectionInBackground;

  /// The automatic rationale is due: the service is wanted, the permission is
  /// missing but re-askable, and the app has not already offered it this
  /// session. Android never gets asked cold.
  bool get permissionDue =>
      desired &&
      notificationPermission == NotificationPermissionStatus.denied &&
      !permissionPrompted;

  /// The morphing notification: idle → "Harbor Companion" / the
  /// `Connected to <host>` status; with media, the media title + episode line
  /// (playing state and poster ride on [BackgroundNotification.media]). One
  /// notification, never two.
  BackgroundNotification get notification {
    final held = media;
    if (held == null) {
      return BackgroundNotification(
        title: 'Harbor Companion',
        text: (hostName == null || hostName!.isEmpty)
            ? 'Connected'
            : 'Connected to $hostName',
      );
    }
    final episode = held.episodeLine;
    return BackgroundNotification(
      title: held.title,
      text: (episode == null || episode.isEmpty)
          ? (held.playing ? 'Playing' : 'Paused')
          : episode,
      media: held,
    );
  }

  BackgroundState copy({
    bool? connected,
    String? hostName,
    bool clearHostName = false,
    bool? keepConnectionInBackground,
    bool? foregrounded,
    BackgroundServiceStatus? serviceStatus,
    String? lastError,
    bool clearLastError = false,
    BackgroundMediaSurface? media,
    bool clearMedia = false,
    BackgroundNotification? notified,
    bool clearNotified = false,
    NotificationPermissionStatus? notificationPermission,
    bool? rationaleVisible,
    bool? permissionPrompted,
    List<String>? effects,
  }) {
    return BackgroundState(
      connected: connected ?? this.connected,
      hostName: clearHostName ? null : (hostName ?? this.hostName),
      keepConnectionInBackground:
          keepConnectionInBackground ?? this.keepConnectionInBackground,
      foregrounded: foregrounded ?? this.foregrounded,
      serviceStatus: serviceStatus ?? this.serviceStatus,
      lastError: clearLastError ? null : (lastError ?? this.lastError),
      media: clearMedia ? null : (media ?? this.media),
      notified: clearNotified ? null : (notified ?? this.notified),
      notificationPermission:
          notificationPermission ?? this.notificationPermission,
      rationaleVisible: rationaleVisible ?? this.rationaleVisible,
      permissionPrompted: permissionPrompted ?? this.permissionPrompted,
      effects: effects ?? this.effects,
    );
  }
}

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------

sealed class BackgroundEvent {
  const BackgroundEvent();
}

/// The active-host signal folded from the connect layer. [connected] is true
/// for a live connection or an established one being retried; [hostName] is the
/// active host's display name.
class ConnectionChanged extends BackgroundEvent {
  final bool connected;
  final String? hostName;
  const ConnectionChanged(this.connected, this.hostName);
}

/// The "keep connection in background" toggle changed.
class KeepConnectionChanged extends BackgroundEvent {
  final bool enabled;
  const KeepConnectionChanged(this.enabled);
}

/// App lifecycle transition from main.dart's WidgetsBindingObserver.
class ForegroundChanged extends BackgroundEvent {
  final bool foregrounded;
  const ForegroundChanged(this.foregrounded);
}

/// The platform reports the service is up.
class ServiceStarted extends BackgroundEvent {
  const ServiceStarted();
}

/// The platform refused the start.
class ServiceStartFailed extends BackgroundEvent {
  final String reason;
  const ServiceStartFailed(this.reason);
}

/// The platform reports the service is down.
class ServiceStopped extends BackgroundEvent {
  const ServiceStopped();
}

/// The derived media surface changed (#65): the Remote layer holds media
/// ([media] non-null), holds nothing, or the socket dropped (both null). The
/// notification morphs between the media surface and the idle host status.
class NowPlayingChanged extends BackgroundEvent {
  final BackgroundMediaSurface? media;
  const NowPlayingChanged(this.media);
}

/// A notification action arrived on the platform stream. #66 maps these to
/// RemoteController commands; the decision seam carries them without letting
/// them affect the service lifecycle (dismissal must not stop the service).
class NotificationActionReceived extends BackgroundEvent {
  final BackgroundAction action;
  const NotificationActionReceived(this.action);
}

/// The platform reported the `POST_NOTIFICATIONS` state (#67), either from the
/// startup check or as the result of a request. A denial never touches the
/// service lifecycle (an FGS does not require the permission).
class NotificationPermissionChanged extends BackgroundEvent {
  final NotificationPermissionStatus status;
  const NotificationPermissionChanged(this.status);
}

/// The user accepted the in-app rationale: emit the real OS prompt.
class NotificationRationaleAccepted extends BackgroundEvent {
  const NotificationRationaleAccepted();
}

/// The user declined the in-app rationale: cancel without firing the OS prompt.
class NotificationRationaleDeclined extends BackgroundEvent {
  const NotificationRationaleDeclined();
}

/// A manual re-ask from Settings (rationale already shown): emit the OS prompt
/// even though the automatic one was already offered or declined.
class NotificationPermissionRequested extends BackgroundEvent {
  const NotificationPermissionRequested();
}

/// A manual deep-link to the app's OS notification settings (#67), used when
/// Android will no longer show the prompt.
class NotificationSettingsRequested extends BackgroundEvent {
  const NotificationSettingsRequested();
}

// ---------------------------------------------------------------------------
// Reducer
// ---------------------------------------------------------------------------

BackgroundState backgroundReduce(BackgroundState s, BackgroundEvent e) {
  switch (e) {
    case ConnectionChanged(:final connected, :final hostName):
      return _ensureRationale(_reconcile(
        s.copy(connected: connected, hostName: hostName),
        // A fresh connect is a new chance to start after a failure.
        allowRetry: !s.connected && connected,
      ));

    case KeepConnectionChanged(:final enabled):
      return _ensureRationale(_reconcile(
        s.copy(keepConnectionInBackground: enabled),
        allowRetry: !s.keepConnectionInBackground && enabled,
      ));

    case ForegroundChanged(:final foregrounded):
      return _ensureRationale(_reconcile(
        s.copy(foregrounded: foregrounded),
        allowRetry: !s.foregrounded && foregrounded,
      ));

    case NowPlayingChanged(:final media):
      // The view nulls the surface on disconnect or when nothing is held, so
      // this both raises the media notification and clears it at once.
      final next = _reconcile(
        media == null ? s.copy(clearMedia: true) : s.copy(media: media),
      );
      // The plugin notification coalesces a position-only tick away (see
      // `_sameRenderedSurface`), but the native MediaSession still needs the
      // freshest position to extrapolate from. Re-anchor it when this dispatch
      // did not already repost/start the surface.
      if (next.serviceStatus == BackgroundServiceStatus.running &&
          !next.effects.contains('updateService')) {
        next.effects.add('updateMediaSession');
      }
      return _ensureRationale(next);

    case ServiceStarted():
      return _reconcile(s.copy(
        serviceStatus: BackgroundServiceStatus.running,
        clearLastError: true,
      ));

    case ServiceStartFailed(:final reason):
      return _reconcile(s.copy(
        serviceStatus: BackgroundServiceStatus.degraded,
        lastError: reason,
      ));

    case ServiceStopped():
      return _reconcile(s.copy(
        serviceStatus: BackgroundServiceStatus.stopped,
        clearNotified: true,
      ));

    case NotificationActionReceived():
      // The service lifecycle ignores notification actions: dismissing the
      // notification (Android 14+) must not stop the service.
      return s;

    case NotificationPermissionChanged(:final status):
      // A denial changes nothing about the service (an FGS does not need the
      // permission); it only means the notification will not appear. Answering
      // with anything other than a re-askable denial retires the automatic
      // rationale for good.
      return _ensureRationale(s.copy(
        notificationPermission: status,
        rationaleVisible: false,
        permissionPrompted: status == NotificationPermissionStatus.denied
            ? s.permissionPrompted
            : true,
      ));

    case NotificationRationaleAccepted():
      return s.copy(rationaleVisible: false, permissionPrompted: true)
        ..effects.add('requestPermission');

    case NotificationRationaleDeclined():
      return s.copy(rationaleVisible: false, permissionPrompted: true);

    case NotificationPermissionRequested():
      return s.copy(rationaleVisible: false, permissionPrompted: true)
        ..effects.add('requestPermission');

    case NotificationSettingsRequested():
      return s.copy(rationaleVisible: false, permissionPrompted: true)
        ..effects.add('openNotificationSettings');
  }
}

/// Offers the in-app rationale when it is due, at most once per session. The OS
/// prompt stays behind it: the rationale is UI, the request is an effect the
/// controller drains only after the user accepts.
BackgroundState _ensureRationale(BackgroundState s) {
  if (s.rationaleVisible || !s.permissionDue) return s;
  return s.copy(rationaleVisible: true, permissionPrompted: true);
}

/// Brings the service lifecycle in line with the current desire. [allowRetry]
/// lets a fresh trigger lift a degraded state; without it a degraded service is
/// left alone so a refused start cannot spin in a loop.
BackgroundState _reconcile(BackgroundState s, {bool allowRetry = false}) {
  switch (s.serviceStatus) {
    case BackgroundServiceStatus.stopped:
      if (s.desired && s.foregrounded) return _emitStart(s);
      return s;

    case BackgroundServiceStatus.degraded:
      if (!s.desired) {
        return s.copy(
          serviceStatus: BackgroundServiceStatus.stopped,
          clearLastError: true,
        );
      }
      if (allowRetry && s.foregrounded) return _emitStart(s);
      return s;

    case BackgroundServiceStatus.running:
      if (!s.desired) {
        return s.copy(serviceStatus: BackgroundServiceStatus.stopping)
          ..effects.add('stopService');
      }
      if (!_sameRenderedSurface(s.notified, s.notification)) {
        return s.copy(notified: s.notification)
          ..effects.add('updateService');
      }
      return s;

    case BackgroundServiceStatus.starting:
      // Start in flight. If the desire was revoked, [ServiceStarted] will stop
      // it immediately; nothing to emit now.
      return s;

    case BackgroundServiceStatus.stopping:
      // Stop in flight. If the desire came back, [ServiceStopped] will restart.
      return s;
  }
}

BackgroundState _emitStart(BackgroundState s) {
  final next = s.copy(
    serviceStatus: BackgroundServiceStatus.starting,
    clearLastError: true,
    notified: s.notification,
  );
  next.effects.add('startService');
  return next;
}

/// Whether re-posting [next] would change what the platform renders. Only the
/// rendered fields count: the transport-only metadata (position/duration) is
/// carried for #66's native `MediaSession`, which extrapolates position from the
/// snapshot, so a 400 ms position tick must NOT re-post the plugin notification.
bool _sameRenderedSurface(
    BackgroundNotification? posted, BackgroundNotification next) {
  if (posted == null) return false;
  if (posted.title != next.title || posted.text != next.text) return false;
  final a = posted.media;
  final b = next.media;
  if (a == null || b == null) return a == b;
  return a.title == b.title &&
      a.episodeLine == b.episodeLine &&
      a.posterUrl == b.posterUrl &&
      a.playing == b.playing &&
      a.hasPrevEpisode == b.hasPrevEpisode &&
      a.hasNextEpisode == b.hasNextEpisode;
}
