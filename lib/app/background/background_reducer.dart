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
// Effects vocabulary:
//   `startService`  → platform.startService(state.notification)
//   `updateService` → platform.updateService(state.notification)
//   `stopService`   → platform.stopService()

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
    List<String>? effects,
  }) : effects = effects ?? <String>[];

  /// The service is wanted when a host is active and the user has not opted out.
  bool get desired => connected && keepConnectionInBackground;

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

// ---------------------------------------------------------------------------
// Reducer
// ---------------------------------------------------------------------------

BackgroundState backgroundReduce(BackgroundState s, BackgroundEvent e) {
  switch (e) {
    case ConnectionChanged(:final connected, :final hostName):
      return _reconcile(
        s.copy(connected: connected, hostName: hostName),
        // A fresh connect is a new chance to start after a failure.
        allowRetry: !s.connected && connected,
      );

    case KeepConnectionChanged(:final enabled):
      return _reconcile(
        s.copy(keepConnectionInBackground: enabled),
        allowRetry: !s.keepConnectionInBackground && enabled,
      );

    case ForegroundChanged(:final foregrounded):
      return _reconcile(
        s.copy(foregrounded: foregrounded),
        allowRetry: !s.foregrounded && foregrounded,
      );

    case NowPlayingChanged(:final media):
      // The view nulls the surface on disconnect or when nothing is held, so
      // this both raises the media notification and clears it at once.
      return _reconcile(
        media == null ? s.copy(clearMedia: true) : s.copy(media: media),
      );

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
  }
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
