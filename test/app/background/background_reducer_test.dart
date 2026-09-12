// Pure reducer tests for the background module (#64 / #65). The reducer is the
// decision seam: these pin the service lifecycle (start/stop for connect,
// disconnect, remove-host and toggle), the "start only while foregrounded"
// rule, start-failure degradation, and the notification content — idle host
// status and the #65 idle ↔ media morph. No platform, no I/O.
//
// The effects buffer is mutable and shared across a reduce chain (the
// controller drains it after every step), so [step] returns the next state plus
// the effects that single step produced, clearing the buffer.

import 'package:flutter_test/flutter_test.dart';

import 'package:harbor_companion/app/background/background_platform.dart';
import 'package:harbor_companion/app/background/background_reducer.dart';

typedef Step = (BackgroundState state, List<String> effects);

Step step(BackgroundState s, BackgroundEvent e) {
  final next = backgroundReduce(s, e);
  final effects = List<String>.from(next.effects);
  next.effects.clear();
  return (next, effects);
}

/// A running service for [host], with an empty effects buffer.
BackgroundState running({String host = 'desk', bool foregrounded = true}) {
  final (connected, _) = step(
    BackgroundState(foregrounded: foregrounded),
    ConnectionChanged(true, host),
  );
  final (started, _) = step(connected, const ServiceStarted());
  return started;
}

void main() {
  test('connect while foregrounded + toggle on requests the service', () {
    final (s, effects) = step(BackgroundState(), const ConnectionChanged(true, 'desk'));
    expect(s.desired, isTrue);
    expect(s.serviceStatus, BackgroundServiceStatus.starting);
    expect(effects, ['startService']);
    expect(s.notification,
        const BackgroundNotification(title: 'Harbor Companion', text: 'Connected to desk'));
  });

  test('connect while backgrounded waits for the next foreground', () {
    final (backgrounded, effects) = step(
      BackgroundState(foregrounded: false),
      const ConnectionChanged(true, 'desk'),
    );
    expect(backgrounded.serviceStatus, BackgroundServiceStatus.stopped);
    expect(effects, isEmpty);

    final (foregrounded, effects2) =
        step(backgrounded, const ForegroundChanged(true));
    expect(foregrounded.serviceStatus, BackgroundServiceStatus.starting);
    expect(effects2, ['startService']);
  });

  test('toggle off keeps the service down', () {
    final (off, _) = step(BackgroundState(), const KeepConnectionChanged(false));
    final (s, effects) = step(off, const ConnectionChanged(true, 'desk'));
    expect(s.desired, isFalse);
    expect(s.serviceStatus, BackgroundServiceStatus.stopped);
    expect(effects, isEmpty);
  });

  test('toggle off while running stops the service', () {
    final (s, effects) = step(running(), const KeepConnectionChanged(false));
    expect(s.serviceStatus, BackgroundServiceStatus.stopping);
    expect(effects, ['stopService']);
  });

  test('toggle on while connected + foregrounded starts immediately', () {
    final (off, _) = step(BackgroundState(), const KeepConnectionChanged(false));
    final (connected, _) = step(off, const ConnectionChanged(true, 'desk'));
    final (s, effects) = step(connected, const KeepConnectionChanged(true));
    expect(s.serviceStatus, BackgroundServiceStatus.starting);
    expect(effects, ['startService']);
  });

  test('toggle on while backgrounded waits for the next foreground', () {
    final (off, _) = step(
      BackgroundState(foregrounded: false),
      const KeepConnectionChanged(false),
    );
    final (connected, _) = step(off, const ConnectionChanged(true, 'desk'));
    final (s, effects) = step(connected, const KeepConnectionChanged(true));
    expect(s.serviceStatus, BackgroundServiceStatus.stopped);
    expect(effects, isEmpty);

    final (foregrounded, effects2) = step(s, const ForegroundChanged(true));
    expect(foregrounded.serviceStatus, BackgroundServiceStatus.starting);
    expect(effects2, ['startService']);
  });

  test('disconnect while running stops the service', () {
    final (s, effects) = step(running(), const ConnectionChanged(false, null));
    expect(s.desired, isFalse);
    expect(s.serviceStatus, BackgroundServiceStatus.stopping);
    expect(effects, ['stopService']);
  });

  test('removing the active host (connection false) stops the service', () {
    // The connect layer reports the active host gone; from the background
    // module's point of view that is the same signal as a disconnect.
    final (s, effects) = step(running(), const ConnectionChanged(false, 'desk'));
    expect(s.serviceStatus, BackgroundServiceStatus.stopping);
    expect(effects, ['stopService']);
  });

  test('a reconnect (active stays true) never stops the service', () {
    final (s, effects) = step(running(), const ConnectionChanged(true, 'desk'));
    expect(s.serviceStatus, BackgroundServiceStatus.running);
    expect(effects, isEmpty);
  });

  test('a refused start degrades instead of crashing, and does not spin', () {
    final (connected, _) = step(BackgroundState(), const ConnectionChanged(true, 'desk'));
    final (degraded, effects) =
        step(connected, const ServiceStartFailed('SecurityException'));
    expect(degraded.serviceStatus, BackgroundServiceStatus.degraded);
    expect(degraded.lastError, contains('SecurityException'));
    expect(effects, isEmpty);

    // An unrelated event (same connect signal) must not retry in a loop.
    final (s, effects2) = step(degraded, const ConnectionChanged(true, 'desk'));
    expect(s.serviceStatus, BackgroundServiceStatus.degraded);
    expect(effects2, isEmpty);
  });

  test('a fresh trigger lifts the degraded state', () {
    final (connected, _) = step(BackgroundState(), const ConnectionChanged(true, 'desk'));
    final (degraded, _) =
        step(connected, const ServiceStartFailed('start-not-allowed'));

    // Background → foreground is a fresh start opportunity.
    final (backgrounded, _) = step(degraded, const ForegroundChanged(false));
    final (s, effects) = step(backgrounded, const ForegroundChanged(true));
    expect(s.serviceStatus, BackgroundServiceStatus.starting);
    expect(effects, ['startService']);
  });

  test('a re-connect lifts the degraded state', () {
    final (connected, _) = step(BackgroundState(), const ConnectionChanged(true, 'desk'));
    final (degraded, _) =
        step(connected, const ServiceStartFailed('start-not-allowed'));

    final (down, _) = step(degraded, const ConnectionChanged(false, null));
    final (s, effects) = step(down, const ConnectionChanged(true, 'desk'));
    expect(s.serviceStatus, BackgroundServiceStatus.starting);
    expect(effects, ['startService']);
  });

  test('host change while running updates the notification once', () {
    final (s, effects) = step(running(), const ConnectionChanged(true, 'living room'));
    expect(s.serviceStatus, BackgroundServiceStatus.running);
    expect(effects, ['updateService']);
    expect(
      s.notified,
      const BackgroundNotification(
        title: 'Harbor Companion',
        text: 'Connected to living room',
      ),
    );

    // No change → no extra update.
    final (_, effects2) = step(s, const ConnectionChanged(true, 'living room'));
    expect(effects2, isEmpty);
  });

  group('the notification morphs (#65)', () {
    const surface = BackgroundMediaSurface(
      title: 'Breaking Bad',
      episodeLine: 'S2 · E5  Breakage',
      posterUrl: 'http://desk:11471/poster.jpg',
      playing: true,
      positionSec: 120,
      durationSec: 2700,
      hasPrevEpisode: true,
      hasNextEpisode: true,
    );

    test('media raises the playing surface with the media title + episode line',
        () {
      final (s, effects) = step(running(), const NowPlayingChanged(surface));
      expect(s.serviceStatus, BackgroundServiceStatus.running);
      expect(effects, ['updateService']);
      expect(s.notification.title, 'Breaking Bad');
      expect(s.notification.text, 'S2 · E5  Breakage');
      expect(s.notification.media, surface);
      expect(s.notification.isIdle, isFalse);
    });

    test('a movie (no episode line) falls back to a playing/paused label', () {
      final (playing, _) = step(
        running(),
        const NowPlayingChanged(
          BackgroundMediaSurface(title: 'Shawshank', playing: true),
        ),
      );
      expect(playing.notification.text, 'Playing');

      final (paused, _) = step(
        playing,
        const NowPlayingChanged(
          BackgroundMediaSurface(title: 'Shawshank', playing: false),
        ),
      );
      expect(paused.notification.text, 'Paused');
    });

    test('clearing the media returns to the idle host status', () {
      final (withMedia, _) = step(running(), const NowPlayingChanged(surface));
      final (s, effects) = step(withMedia, const NowPlayingChanged(null));

      expect(s.serviceStatus, BackgroundServiceStatus.running);
      expect(effects, ['updateService']);
      expect(s.media, isNull);
      expect(s.notification.isIdle, isTrue);
      expect(s.notification.text, 'Connected to desk');
    });

    test('a socket drop (media cleared) never leaves a stale surface behind',
        () {
      final (withMedia, _) = step(running(), const NowPlayingChanged(surface));
      // The derived view nulls the surface the moment the Remote drops; the
      // notification morphs to the idle/reconnecting status and the service
      // stays up (a reconnect is not an explicit disconnect).
      final (s, effects) = step(withMedia, const NowPlayingChanged(null));
      expect(s.notification.media, isNull);
      expect(effects, ['updateService']);
      expect(s.serviceStatus, isNot(BackgroundServiceStatus.stopping));
    });

    test('a position-only tick does not re-post the notification', () {
      final (withMedia, _) = step(running(), const NowPlayingChanged(surface));
      final (s, effects) = step(
        withMedia,
        const NowPlayingChanged(BackgroundMediaSurface(
          title: 'Breaking Bad',
          episodeLine: 'S2 · E5  Breakage',
          posterUrl: 'http://desk:11471/poster.jpg',
          playing: true,
          positionSec: 125, // 400 ms later
          durationSec: 2700,
          hasPrevEpisode: true,
          hasNextEpisode: true,
        )),
      );
      expect(effects, ['updateMediaSession']);
      // The fresher transport metadata is still held for #66.
      expect(s.media?.positionSec, 125);
      expect(s.notification.media?.positionSec, 125);
    });

    test('a real change (pause) re-posts the notification', () {
      final (withMedia, _) = step(running(), const NowPlayingChanged(surface));
      final (s, effects) = step(
        withMedia,
        const NowPlayingChanged(BackgroundMediaSurface(
          title: 'Breaking Bad',
          episodeLine: 'S2 · E5  Breakage',
          posterUrl: 'http://desk:11471/poster.jpg',
          playing: false,
          positionSec: 120,
          durationSec: 2700,
          hasPrevEpisode: true,
          hasNextEpisode: true,
        )),
      );
      expect(effects, ['updateService']);
      expect(s.notification.media?.playing, isFalse);
    });

    test('media raised before the service starts rides the start notification',
        () {
      final (withMedia, _) =
          step(BackgroundState(), const NowPlayingChanged(surface));
      final (s, effects) =
          step(withMedia, const ConnectionChanged(true, 'desk'));
      expect(effects, ['startService']);
      expect(s.notification.title, 'Breaking Bad');
    });

    test('a host change while playing keeps the media surface', () {
      final (withMedia, _) = step(running(), const NowPlayingChanged(surface));
      final (s, effects) =
          step(withMedia, const ConnectionChanged(true, 'living room'));
      expect(effects, isEmpty);
      expect(s.notification.title, 'Breaking Bad');
      expect(s.notification.media, surface);
    });

    test('an established host being retried shows Reconnecting… while idle', () {
      final (s, effects) = step(
        running(),
        const ConnectionChanged(true, 'desk', reconnecting: true),
      );
      expect(s.serviceStatus, BackgroundServiceStatus.running);
      expect(s.hostReconnecting, isTrue);
      expect(effects, ['updateService']);
      expect(s.notification.isIdle, isTrue);
      expect(s.notification.text, 'Reconnecting…');

      // The connection returning morphs the idle status back and re-posts once.
      final (back, effects2) =
          step(s, const ConnectionChanged(true, 'desk'));
      expect(back.hostReconnecting, isFalse);
      expect(effects2, ['updateService']);
      expect(back.notification.text, 'Connected to desk');
    });

    test('a socket drop clears the media and morphs to Reconnecting…', () {
      final (withMedia, _) = step(running(), const NowPlayingChanged(surface));
      final (cleared, _) = step(withMedia, const NowPlayingChanged(null));
      final (s, effects) = step(
        cleared,
        const ConnectionChanged(true, 'desk', reconnecting: true),
      );
      expect(s.media, isNull);
      expect(s.notification.media, isNull);
      expect(s.notification.text, 'Reconnecting…');
      expect(effects, ['updateService']);
      expect(s.serviceStatus, BackgroundServiceStatus.running);
    });

    test('media still wins while the host is reconnecting', () {
      final (withMedia, _) = step(running(), const NowPlayingChanged(surface));
      final (s, effects) = step(
        withMedia,
        const ConnectionChanged(true, 'desk', reconnecting: true),
      );
      // The rendered media surface is unchanged, so no re-post is needed.
      expect(effects, isEmpty);
      expect(s.notification.title, 'Breaking Bad');
      expect(s.notification.media, surface);
    });

    test('a cleared host is never reconnecting', () {
      final (s, _) = step(
        running(),
        const ConnectionChanged(false, null, reconnecting: true),
      );
      expect(s.hostReconnecting, isFalse);
    });
  });

  test('a notification dismissal never stops the service', () {
    final (s, effects) = step(
      running(),
      const NotificationActionReceived(BackgroundAction.dismissed),
    );
    expect(s.serviceStatus, BackgroundServiceStatus.running);
    expect(effects, isEmpty);
  });

  test('stopping then a new connect restarts the service', () {
    final (stopping, _) = step(running(), const ConnectionChanged(false, null));
    final (stopped, _) = step(stopping, const ServiceStopped());
    expect(stopped.serviceStatus, BackgroundServiceStatus.stopped);

    final (s, effects) = step(stopped, const ConnectionChanged(true, 'desk'));
    expect(s.serviceStatus, BackgroundServiceStatus.starting);
    expect(effects, ['startService']);
  });

  group('notification permission timing (#67)', () {
    BackgroundState notGranted() => BackgroundState(
          notificationPermission: NotificationPermissionStatus.denied,
        );

    test('the first connect with the toggle on offers the rationale', () {
      final (s, effects) = step(notGranted(), const ConnectionChanged(true, 'desk'));
      expect(s.desired, isTrue);
      expect(s.rationaleVisible, isTrue);
      expect(s.permissionPrompted, isTrue);
      // The decision seam never fires the OS prompt: accepting does.
      expect(effects, ['startService']);
    });

    test('no connection means no rationale', () {
      final (s, effects) = step(notGranted(), const KeepConnectionChanged(true));
      expect(s.rationaleVisible, isFalse);
      expect(effects, isEmpty);
    });

    test('the toggle off means no rationale (and no service)', () {
      final (off, _) = step(notGranted(), const KeepConnectionChanged(false));
      final (s, effects) = step(off, const ConnectionChanged(true, 'desk'));
      expect(s.rationaleVisible, isFalse);
      expect(effects, isEmpty);
    });

    test('a granted permission never offers the rationale', () {
      final (s, _) = step(BackgroundState(), const ConnectionChanged(true, 'desk'));
      expect(s.rationaleVisible, isFalse);
    });

    test('a permanently denied permission never offers the rationale', () {
      final (s, _) = step(
        BackgroundState(
          notificationPermission: NotificationPermissionStatus.permanentlyDenied,
        ),
        const ConnectionChanged(true, 'desk'),
      );
      expect(s.rationaleVisible, isFalse);
    });

    test('a late permission denial while the service is wanted still offers it',
        () {
      // The connect landed before the async status check; the denial arriving
      // afterwards must still produce the rationale.
      final (connected, _) =
          step(BackgroundState(), const ConnectionChanged(true, 'desk'));
      final (s, _) = step(
        connected,
        const NotificationPermissionChanged(NotificationPermissionStatus.denied),
      );
      expect(s.rationaleVisible, isTrue);
    });

    test('accepting the rationale emits requestPermission and closes it', () {
      final (pending, _) = step(notGranted(), const ConnectionChanged(true, 'desk'));
      final (s, effects) = step(pending, const NotificationRationaleAccepted());
      expect(s.rationaleVisible, isFalse);
      expect(effects, ['requestPermission']);
    });

    test('declining cancels without the OS prompt and never re-prompts', () {
      final (pending, _) = step(notGranted(), const ConnectionChanged(true, 'desk'));
      final (declined, effects) = step(pending, const NotificationRationaleDeclined());
      expect(declined.rationaleVisible, isFalse);
      expect(effects, isEmpty);

      // A later connect signal must not offer it again automatically.
      final (s, effects2) = step(declined, const ConnectionChanged(true, 'desk'));
      expect(s.rationaleVisible, isFalse);
      expect(effects2, isEmpty);
    });

    test('a denial folds without touching the service lifecycle', () {
      final (s, effects) = step(
        running(),
        const NotificationPermissionChanged(NotificationPermissionStatus.denied),
      );
      expect(s.serviceStatus, BackgroundServiceStatus.running);
      expect(effects, isEmpty);
    });

    test('a manual re-ask emits requestPermission', () {
      final (s, effects) = step(notGranted(), const NotificationPermissionRequested());
      expect(effects, ['requestPermission']);
      expect(s.rationaleVisible, isFalse);
      expect(s.permissionPrompted, isTrue);
    });

    test('a manual settings request emits openNotificationSettings', () {
      final (s, effects) = step(
        BackgroundState(
          notificationPermission: NotificationPermissionStatus.permanentlyDenied,
        ),
        const NotificationSettingsRequested(),
      );
      expect(effects, ['openNotificationSettings']);
      expect(s.rationaleVisible, isFalse);
    });

    test('a granted answer retires the automatic rationale for good', () {
      final (pending, _) = step(notGranted(), const ConnectionChanged(true, 'desk'));
      final (granted, _) = step(
        pending,
        const NotificationPermissionChanged(NotificationPermissionStatus.granted),
      );
      expect(granted.rationaleVisible, isFalse);
      expect(granted.permissionPrompted, isTrue);

      final (s, _) = step(granted, const ConnectionChanged(true, 'desk'));
      expect(s.rationaleVisible, isFalse);
    });
  });

  group('battery / OEM onboarding (#68)', () {
    test('the direct request emits requestBatteryExemption', () {
      final (_, effects) =
          step(BackgroundState(), const BatteryExemptionRequested());
      expect(effects, ['requestBatteryExemption']);
    });

    test('an unavailable direct request falls back to the optimization list',
        () {
      final (_, effects) =
          step(BackgroundState(), const BatteryExemptionUnavailable());
      expect(effects, ['openBatteryOptimizationSettings']);
    });

    test('the list and generic battery-settings requests emit their effects',
        () {
      final (_, listEffects) =
          step(BackgroundState(), const BatteryOptimizationListRequested());
      expect(listEffects, ['openBatteryOptimizationSettings']);

      final (_, settingsEffects) =
          step(BackgroundState(), const BatterySettingsRequested());
      expect(settingsEffects, ['openBatterySettings']);
    });

    test('the exemption check folds into the state', () {
      final (exempt, _) =
          step(BackgroundState(), const BatteryExemptionChanged(true));
      expect(exempt.batteryExempt, isTrue);
      final (notExempt, _) =
          step(exempt, const BatteryExemptionChanged(false));
      expect(notExempt.batteryExempt, isFalse);
    });

    group('the reactive nudge', () {
      BackgroundState backgrounded({
        bool keep = true,
        bool socketDown = false,
      }) {
        final (s, _) = step(
          BackgroundState(
            keepConnectionInBackground: keep,
            socketConnected: !socketDown,
          ),
          const ForegroundChanged(false, atMs: 1000),
        );
        return s;
      }

      test('fires on resume with the socket down after a long background stretch',
          () {
        final (s, effects) = step(
          backgrounded(socketDown: true),
          const ForegroundChanged(
            true,
            atMs: 1000 + kBatteryNudgeBackgroundThresholdMs,
          ),
        );
        expect(s.batteryNudgeVisible, isTrue);
        expect(s.lastBatteryNudgeMs, 1000 + kBatteryNudgeBackgroundThresholdMs);
      });

      test('does not fire when the socket is up', () {
        final (s, _) = step(
          backgrounded(socketDown: false),
          const ForegroundChanged(
            true,
            atMs: 1000 + kBatteryNudgeBackgroundThresholdMs,
          ),
        );
        expect(s.batteryNudgeVisible, isFalse);
      });

      test('does not fire with the toggle off', () {
        final (s, _) = step(
          backgrounded(keep: false, socketDown: true),
          const ForegroundChanged(
            true,
            atMs: 1000 + kBatteryNudgeBackgroundThresholdMs,
          ),
        );
        expect(s.batteryNudgeVisible, isFalse);
      });

      test('does not fire after a short background stretch', () {
        final (s, _) = step(
          backgrounded(socketDown: true),
          const ForegroundChanged(
            true,
            atMs: 1000 + kBatteryNudgeBackgroundThresholdMs - 1,
          ),
        );
        expect(s.batteryNudgeVisible, isFalse);
      });

      test('is throttled after a dismissal', () {
        final (shown, _) = step(
          backgrounded(socketDown: true),
          const ForegroundChanged(
            true,
            atMs: 1000 + kBatteryNudgeBackgroundThresholdMs,
          ),
        );
        expect(shown.batteryNudgeVisible, isTrue);

        final (dismissed, _) = step(
          shown,
          BatteryNudgeDismissed(atMs: shown.lastBatteryNudgeMs),
        );
        expect(dismissed.batteryNudgeVisible, isFalse);

        // A second long background/resume inside the throttle stays quiet.
        final last = dismissed.lastBatteryNudgeMs!;
        final (againBackgrounded, _) =
            step(dismissed, ForegroundChanged(false, atMs: last + 1));
        final (s, _) = step(
          againBackgrounded,
          ForegroundChanged(
            true,
            atMs: last + 1 + kBatteryNudgeBackgroundThresholdMs,
          ),
        );
        expect(s.batteryNudgeVisible, isFalse);
      });

      test('fires again once the throttle window has elapsed', () {
        final (shown, _) = step(
          backgrounded(socketDown: true),
          const ForegroundChanged(
            true,
            atMs: 1000 + kBatteryNudgeBackgroundThresholdMs,
          ),
        );
        final (dismissed, _) =
            step(shown, const BatteryNudgeDismissed());
        final last = dismissed.lastBatteryNudgeMs!;

        final (againBackgrounded, _) = step(
          dismissed,
          ForegroundChanged(false, atMs: last + kBatteryNudgeThrottleMs),
        );
        final (s, _) = step(
          againBackgrounded,
          ForegroundChanged(
            true,
            atMs: last + kBatteryNudgeThrottleMs + kBatteryNudgeBackgroundThresholdMs,
          ),
        );
        expect(s.batteryNudgeVisible, isTrue);
      });

      test('turning the toggle off drops a visible nudge', () {
        final (shown, _) = step(
          backgrounded(socketDown: true),
          const ForegroundChanged(
            true,
            atMs: 1000 + kBatteryNudgeBackgroundThresholdMs,
          ),
        );
        final (s, _) = step(shown, const KeepConnectionChanged(false));
        expect(s.batteryNudgeVisible, isFalse);
      });

      test('a resume with no recorded background time stays quiet', () {
        final (s, _) = step(
          BackgroundState(socketConnected: false),
          const ForegroundChanged(true, atMs: 99),
        );
        expect(s.batteryNudgeVisible, isFalse);
      });

      test('a persisted background stretch is replayed on cold start', () {
        // The process was killed and relaunched: there is no in-memory entry,
        // only the timestamp restored from disk.
        final (s, _) = step(
          BackgroundState(socketConnected: false),
          const BackgroundedAtRestored(
            1000,
            1000 + kBatteryNudgeBackgroundThresholdMs,
          ),
        );
        expect(s.batteryNudgeVisible, isTrue);
        expect(s.lastBatteryNudgeMs, 1000 + kBatteryNudgeBackgroundThresholdMs);
        // The stretch was consumed, so a later resume cannot replay it.
        expect(s.backgroundedAtMs, isNull);
      });

      test('a restored stretch stays quiet when the socket is up', () {
        final (s, _) = step(
          BackgroundState(socketConnected: true),
          const BackgroundedAtRestored(
            1000,
            1000 + kBatteryNudgeBackgroundThresholdMs,
          ),
        );
        expect(s.batteryNudgeVisible, isFalse);
      });

      test('a restored stretch stays quiet with the toggle off', () {
        final (s, _) = step(
          BackgroundState(
            keepConnectionInBackground: false,
            socketConnected: false,
          ),
          const BackgroundedAtRestored(
            1000,
            1000 + kBatteryNudgeBackgroundThresholdMs,
          ),
        );
        expect(s.batteryNudgeVisible, isFalse);
      });

      test('a restored stretch inside the threshold stays quiet', () {
        final (s, _) = step(
          BackgroundState(socketConnected: false),
          const BackgroundedAtRestored(
            1000,
            1000 + kBatteryNudgeBackgroundThresholdMs - 1,
          ),
        );
        expect(s.batteryNudgeVisible, isFalse);
      });

      test('a restored stretch honours an existing throttle', () {
        final (s, _) = step(
          BackgroundState(
            socketConnected: false,
            lastBatteryNudgeMs: 1000,
          ),
          const BackgroundedAtRestored(
            1000,
            1000 + kBatteryNudgeBackgroundThresholdMs,
          ),
        );
        expect(s.batteryNudgeVisible, isFalse);
      });
    });
  });
}
