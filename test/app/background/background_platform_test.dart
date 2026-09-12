// Pure tests for the notification action vocabulary (#66).
//
// The surface is host-authoritative and deliberately narrow: play/pause,
// previous, next and seek only. These pin the gating (prev/next only when the
// snapshot says they exist), the raw-id mapping, and that volume/mute/subtitles
// can never appear on the surface.

import 'package:flutter_test/flutter_test.dart';

import 'package:harbor_companion/app/background/background_platform.dart';

const _noNext = BackgroundMediaSurface(title: 'Shawshank', playing: false);
const _both = BackgroundMediaSurface(
  title: 'Breaking Bad',
  playing: true,
  hasPrevEpisode: true,
  hasNextEpisode: true,
);

void main() {
  group('surfaceActions', () {
    test('empty while nothing is held', () {
      expect(surfaceActions(null), isEmpty);
    });

    test('play/pause only when there is no previous/next episode', () {
      expect(surfaceActions(_noNext), [BackgroundAction.togglePlay]);
    });

    test('previous and next appear only when the snapshot reports them', () {
      expect(surfaceActions(_both), [
        BackgroundAction.previous,
        BackgroundAction.togglePlay,
        BackgroundAction.next,
      ]);
    });

    test('only the allowed transport actions ever appear', () {
      for (final action in surfaceActions(_both)) {
        expect(
          action is BackgroundPrevious ||
              action is BackgroundTogglePlay ||
              action is BackgroundNext,
          isTrue,
        );
      }
    });
  });

  group('backgroundActionFromId', () {
    test('maps the known ids', () {
      expect(backgroundActionFromId('opened'), BackgroundAction.opened);
      expect(backgroundActionFromId('dismissed'), BackgroundAction.dismissed);
      expect(backgroundActionFromId('togglePlay'), BackgroundAction.togglePlay);
      expect(backgroundActionFromId('previous'), BackgroundAction.previous);
      expect(backgroundActionFromId('next'), BackgroundAction.next);
      expect(backgroundActionFromId('seek', positionSec: 42),
          const BackgroundSeek(42));
    });

    test('seek without a position is dropped', () {
      expect(backgroundActionFromId('seek'), isNull);
    });

    test('volume, mute and subtitles can never reach the surface', () {
      for (final id in const [
        'setVolume',
        'volume',
        'setMuted',
        'mute',
        'toggleMute',
        'toggleSubtitles',
        'subtitles',
        'subtitle',
      ]) {
        expect(backgroundActionFromId(id), isNull, reason: id);
      }
    });

    test('unknown ids are dropped rather than guessed', () {
      expect(backgroundActionFromId('restart'), isNull);
      expect(backgroundActionFromId(''), isNull);
    });

    test('id round-trips for the transport actions the fallback offers', () {
      for (final action in surfaceActions(_both)) {
        final id = backgroundActionId(action);
        expect(id, isNotNull);
        expect(backgroundActionFromId(id!), action);
      }
    });
  });

  group('NotificationPermissionStatus.fromWire (#67)', () {
    test('maps the native strings', () {
      expect(NotificationPermissionStatus.fromWire('granted'),
          NotificationPermissionStatus.granted);
      expect(NotificationPermissionStatus.fromWire('denied'),
          NotificationPermissionStatus.denied);
      expect(NotificationPermissionStatus.fromWire('permanently_denied'),
          NotificationPermissionStatus.permanentlyDenied);
    });

    test('an unknown value is treated as re-askable, never permanent', () {
      expect(NotificationPermissionStatus.fromWire(null),
          NotificationPermissionStatus.denied);
      expect(NotificationPermissionStatus.fromWire('weird'),
          NotificationPermissionStatus.denied);
    });
  });

  test('the no-op platform reports granted so nothing is ever requested', () async {
    const platform = NoopBackgroundPlatform();
    expect(await platform.checkNotificationPermission(),
        NotificationPermissionStatus.granted);
    expect(await platform.requestNotificationPermission(),
        NotificationPermissionStatus.granted);
    await platform.openNotificationSettings();
  });
}
