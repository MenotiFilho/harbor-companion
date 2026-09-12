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
      expect(effects, isEmpty);
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
}
