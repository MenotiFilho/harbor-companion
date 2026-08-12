// Tests for the Remote/playback state model (lib/app/remote/remote_reducer.dart).
//
// Pins the ticket 07 acceptance criteria: now-playing from snapshots with
// rendered-gate coalescing (never `updatedAt`), host-authoritative transport
// (rejected while disconnected), the awaitingStart window (first non-idle
// snapshot / timeout / error frame), the sticky hold through episode-hop idle
// flaps, the manual renderer picker, and d-pad nav + text entry.

import 'package:flutter_test/flutter_test.dart';

import 'package:harbor_companion/app/home/home_reducer.dart' show PlayMetaCommand;
import 'package:harbor_companion/app/remote/remote_reducer.dart';
import 'package:harbor_companion/app/ws/client_reducer.dart'
    show CastDevice, EpisodeRef, Snapshot, SourceInfo, TargetInfo, TextEntry;

List<String> drain(RemoteState s) {
  final e = List<String>.from(s.effects);
  s.effects.clear();
  return e;
}

RemoteState connected() => remoteReduce(RemoteState(), const Connected());

Snapshot snap({
  bool idle = true,
  String? mediaId = 'tt0000001',
  String? mediaTitle = 'Movie',
  String? posterUrl,
  int? season,
  int? episode,
  String? epName,
  double positionSec = 0,
  double durationSec = 1000,
  bool playing = false,
  double volume = 1,
  bool muted = false,
  TargetInfo? target,
  List<CastDevice> castDevices = const [],
  bool castDiscovering = false,
  bool hasPrev = false,
  bool hasNext = false,
  bool subtitlesOn = false,
  bool canToggleSubtitles = false,
  TextEntry? textEntry,
  int updatedAt = 1000,
}) {
  return Snapshot(
    idle: idle,
    mediaId: idle ? null : mediaId,
    mediaTitle: idle ? null : mediaTitle,
    posterUrl: idle ? null : posterUrl,
    episode: (!idle && season != null && episode != null)
        ? EpisodeRef(season, episode, epName)
        : null,
    source: idle ? null : const SourceInfo(null, null, '1080p', 'WEB-DL'),
    positionSec: positionSec,
    durationSec: durationSec,
    playing: playing,
    volume: volume,
    muted: muted,
    target: target ?? const TargetInfo('local', 'This PC'),
    castDevices: castDevices,
    castDiscovering: castDiscovering,
    hasPrevEpisode: hasPrev,
    hasNextEpisode: hasNext,
    subtitlesOn: subtitlesOn,
    canToggleSubtitles: canToggleSubtitles,
    textEntry: textEntry,
    updatedAt: updatedAt,
  );
}

PlayMetaCommand play(String metaId, {String? name, int? season, int? episode}) =>
    PlayMetaCommand(
      metaId: metaId,
      metaType: season != null ? 'series' : 'movie',
      name: name,
      season: season,
      episode: episode,
    );

void main() {
  group('now-playing from snapshots', () {
    test('a non-idle snapshot renders now-playing with the snapshot fields', () {
      final s = remoteReduce(
        connected(),
        SnapshotArrived(snap(
          idle: false,
          mediaTitle: 'Shawshank',
          positionSec: 42,
          durationSec: 100,
          playing: true,
        )),
      );
      expect(s.phase, RemotePhase.nowPlaying);
      expect(s.nowPlaying, isNotNull);
      expect(s.nowPlaying!.mediaTitle, 'Shawshank');
      expect(s.nowPlaying!.positionSec, 42);
      expect(s.nowPlaying!.playing, isTrue);
      expect(s.playStarted, 1);
    });

    test('progress uses the latest snapshot positionSec (never interpolated)', () {
      var s = connected();
      s = remoteReduce(s, SnapshotArrived(snap(idle: false, positionSec: 100)));
      s = remoteReduce(s, SnapshotArrived(snap(idle: false, positionSec: 140)));
      expect(s.nowPlaying!.positionSec, 140);
    });

    test('source/episode lines derive from the snapshot', () {
      final s = remoteReduce(
        connected(),
        SnapshotArrived(snap(
          idle: false,
          season: 1,
          episode: 2,
          epName: 'Winterfell',
        )),
      );
      expect(s.nowPlaying!.episodeLine, 'S1 · E2  Winterfell');
      expect(s.nowPlaying!.sourceLine, '1080p · WEB-DL');
    });
  });

  group('rendered-gate coalescing (never updatedAt)', () {
    test('an unchanged frame does not re-derive the view', () {
      var s = remoteReduce(
        connected(),
        SnapshotArrived(snap(idle: false, positionSec: 100, updatedAt: 1000)),
      );
      final before = s.nowPlaying;
      s = remoteReduce(
        s,
        SnapshotArrived(snap(idle: false, positionSec: 100, updatedAt: 1400)),
      );
      expect(identical(s.nowPlaying, before), isTrue,
          reason: 'the rendered view is the same object when nothing changed');
      expect(s.viewRebuilds, 1);
    });

    test('advancing position re-derives the view', () {
      var s = remoteReduce(
        connected(),
        SnapshotArrived(snap(idle: false, positionSec: 100)),
      );
      s = remoteReduce(s, SnapshotArrived(snap(idle: false, positionSec: 100.4)));
      expect(s.viewRebuilds, 2);
    });

    test('a title change re-derives the view', () {
      var s = remoteReduce(
        connected(),
        SnapshotArrived(snap(idle: false, mediaTitle: 'A', mediaId: 'tt1')),
      );
      s = remoteReduce(
        s,
        SnapshotArrived(snap(idle: false, mediaTitle: 'B', mediaId: 'tt2')),
      );
      expect(s.viewRebuilds, 2);
    });
  });

  group('awaitingStart', () {
    test('playMeta enters awaitingStart and emits the playMeta command', () {
      final s = remoteReduce(connected(), PlayMeta(play('tt1', name: 'Movie')));
      expect(s.phase, RemotePhase.awaitingStart);
      expect(s.playMetaSent, 1);
      expect(s.playRequest, isNotNull);
      expect(s.notice, contains('Starting Movie'));
      final cmd = s.pendingCommand!;
      expect(cmd.action, 'playMeta');
      expect(cmd.payload['metaId'], 'tt1');
      expect(cmd.payload['resume'], isTrue);
      expect(drain(s), ['command']);
    });

    test('playMeta while disconnected is rejected', () {
      final s = remoteReduce(RemoteState(), PlayMeta(play('tt1')));
      expect(s.phase, RemotePhase.idle);
      expect(s.notice, contains('Not connected'));
      expect(drain(s), isEmpty);
    });

    test('idle snapshots during the window are ignored', () {
      var s = remoteReduce(connected(), PlayMeta(play('tt1')));
      s = remoteReduce(s, SnapshotArrived(snap(idle: true, updatedAt: 1100)));
      expect(s.phase, RemotePhase.awaitingStart);
    });

    test('the first non-idle snapshot leaves awaitingStart', () {
      var s = remoteReduce(connected(), PlayMeta(play('tt1')));
      s = remoteReduce(s, SnapshotArrived(snap(idle: true, updatedAt: 1100)));
      s = remoteReduce(s, SnapshotArrived(snap(idle: false, updatedAt: 1400)));
      expect(s.phase, RemotePhase.nowPlaying);
      expect(s.playStarted, 1);
      expect(s.playRequest, isNull);
    });

    test('AwaitTimeout fails with a message pointing at the picker', () {
      var s = remoteReduce(connected(), PlayMeta(play('tt1')));
      s = remoteReduce(s, const AwaitTimeout(awaitingWindow));
      expect(s.phase, RemotePhase.idle);
      expect(s.playFailed, 1);
      expect(s.lastError, contains('Check the picker'));
    });

    test('AwaitTimeout outside awaitingStart is a no-op', () {
      final s = remoteReduce(connected(), const AwaitTimeout(awaitingWindow));
      expect(s.playFailed, 0);
    });

    test('an error frame fails the await immediately with the host message', () {
      var s = remoteReduce(connected(), PlayMeta(play('tt1')));
      s = remoteReduce(s, const ErrorFrame('No stream found'));
      expect(s.phase, RemotePhase.idle);
      expect(s.playFailed, 1);
      expect(s.lastError, 'No stream found');
      expect(s.notice, contains('Could not start playback'));
    });

    test('an error frame while playing keeps the media up', () {
      var s = remoteReduce(connected(), SnapshotArrived(snap(idle: false)));
      s = remoteReduce(s, const ErrorFrame('transport boom'));
      expect(s.phase, RemotePhase.nowPlaying);
      expect(s.nowPlaying, isNotNull);
      expect(s.lastError, 'transport boom');
    });
  });

  group('sticky hold through episode hops', () {
    test('an idle flap holds the last media and marks sticky', () {
      var s = remoteReduce(connected(), SnapshotArrived(snap(idle: false)));
      final held = s.nowPlaying;
      s = remoteReduce(s, SnapshotArrived(snap(idle: true, updatedAt: 1400)));
      expect(s.phase, RemotePhase.nowPlaying);
      expect(s.stickyHeld, isTrue);
      expect(s.nowPlaying, same(held));
    });

    test('a fresh non-idle snapshot clears the sticky hold', () {
      var s = remoteReduce(connected(), SnapshotArrived(snap(idle: false)));
      s = remoteReduce(s, SnapshotArrived(snap(idle: true, updatedAt: 1400)));
      s = remoteReduce(
        s,
        SnapshotArrived(snap(idle: false, positionSec: 0, updatedAt: 1800)),
      );
      expect(s.stickyHeld, isFalse);
      expect(s.phase, RemotePhase.nowPlaying);
    });

    test('StickyExpired drops to idle', () {
      var s = remoteReduce(connected(), SnapshotArrived(snap(idle: false)));
      s = remoteReduce(s, SnapshotArrived(snap(idle: true, updatedAt: 1400)));
      s = remoteReduce(s, const StickyExpired());
      expect(s.phase, RemotePhase.idle);
      expect(s.nowPlaying, isNull);
      expect(s.notice, 'Playback ended');
    });

    test('StickyExpired when not sticky is a no-op', () {
      final s = remoteReduce(connected(), const StickyExpired());
      expect(s.phase, RemotePhase.idle);
    });
  });

  group('host-authoritative transport', () {
    test('togglePlay sends pause while playing, play while paused', () {
      var s = remoteReduce(
        connected(),
        SnapshotArrived(snap(idle: false, playing: true)),
      );
      s = remoteReduce(s, const TogglePlay());
      expect(s.pendingCommand!.action, 'pause');

      s = remoteReduce(
        connected(),
        SnapshotArrived(snap(idle: false, playing: false)),
      );
      s = remoteReduce(s, const TogglePlay());
      expect(s.pendingCommand!.action, 'play');
    });

    test('toggleMute derives muted from the last snapshot', () {
      var s = remoteReduce(
        connected(),
        SnapshotArrived(snap(idle: false, muted: false)),
      );
      s = remoteReduce(s, const ToggleMute());
      expect(s.pendingCommand!.action, 'setMuted');
      expect(s.pendingCommand!.payload['muted'], isTrue);
    });

    test('seek clamps negative positions and sends the value', () {
      final s = remoteReduce(connected(), SnapshotArrived(snap(idle: false)));
      final after = remoteReduce(s, const Seek(-5));
      expect(after.pendingCommand!.payload['positionSec'], 0);
      final after2 = remoteReduce(s, const Seek(120));
      expect(after2.pendingCommand!.payload['positionSec'], 120);
    });

    test('setVolume clamps to [0,1]', () {
      final s = remoteReduce(connected(), SnapshotArrived(snap(idle: false)));
      expect(remoteReduce(s, const SetVolume(2)).pendingCommand!.payload['volume'], 1.0);
      expect(remoteReduce(s, const SetVolume(-1)).pendingCommand!.payload['volume'], 0.0);
    });

    test('prev/next/subtitles encode their commands', () {
      final s = remoteReduce(connected(), SnapshotArrived(snap(idle: false)));
      expect(remoteReduce(s, const PrevEpisode()).pendingCommand!.action, 'prevEpisode');
      expect(remoteReduce(s, const NextEpisode()).pendingCommand!.action, 'nextEpisode');
      expect(remoteReduce(s, const ToggleSubtitles()).pendingCommand!.action, 'toggleSubtitles');
    });

    test('transport is rejected with a notice while disconnected', () {
      final base = RemoteState();
      for (final event in [
        const TogglePlay(),
        const Seek(10),
        const SetVolume(0.5),
        const ToggleMute(),
        const PrevEpisode(),
        const NextEpisode(),
        const ToggleSubtitles(),
      ]) {
        final s = remoteReduce(base, event);
        expect(s.notice, contains('Not connected'), reason: '${event.runtimeType}');
        expect(drain(s), isEmpty, reason: '${event.runtimeType} — never queued');
      }
    });

    test('transport is rejected while connected but nothing playing', () {
      final s = remoteReduce(connected(), const TogglePlay());
      expect(s.notice, contains('Nothing playing'));
      expect(drain(s), isEmpty);
    });
  });

  group('manual renderer picker', () {
    test('snapshots and connect never emit castDiscover', () {
      var s = remoteReduce(RemoteState(), const Connected());
      s = remoteReduce(s, SnapshotArrived(snap(idle: true)));
      s = remoteReduce(s, SnapshotArrived(snap(idle: false)));
      s = remoteReduce(s, const Disconnected());
      s = remoteReduce(s, const Connected());
      expect(drain(s), isEmpty, reason: 'no castDiscover on connect/reconnect/snapshot');
    });

    test('castDiscover is only sent on the explicit event', () {
      final s = remoteReduce(connected(), const CastDiscover());
      expect(s.pendingCommand!.action, 'castDiscover');
      expect(drain(s), ['command']);
    });

    test('setTarget local vs device id', () {
      final local = remoteReduce(connected(), const SetTarget('local'));
      expect(local.pendingCommand!.payload['target'], 'local');

      final cast = remoteReduce(connected(), const SetTarget('abc123'));
      expect(cast.pendingCommand!.payload['target'], 'abc123');
    });

    test('castStop encodes castStop', () {
      final s = remoteReduce(connected(), const CastStop());
      expect(s.pendingCommand!.action, 'castStop');
    });

    test('snapshot renders target / castDevices / castDiscovering', () {
      final devices = const [CastDevice('d1', 'Living Room TV', 'chromecast')];
      final s = remoteReduce(
        connected(),
        SnapshotArrived(snap(
          idle: false,
          target: const TargetInfo('cast', 'Living Room TV',
              deviceId: 'd1', castKind: 'chromecast'),
          castDevices: devices,
          castDiscovering: true,
        )),
      );
      expect(s.target.isCasting, isTrue);
      expect(s.target.deviceId, 'd1');
      expect(s.castDevices, devices);
      expect(s.castDiscovering, isTrue);
    });
  });

  group('nav + text entry', () {
    test('nav keys encode nav commands', () {
      final s = remoteReduce(connected(), const Nav('up'));
      expect(s.pendingCommand!.action, 'nav');
      expect(s.pendingCommand!.payload['key'], 'up');
    });

    test('an unknown nav key is rejected', () {
      final s = remoteReduce(connected(), const Nav('diagonal'));
      expect(s.notice, contains('unknown nav key'));
      expect(drain(s), isEmpty);
    });

    test('setText / submitText / blurText / openSearch encode commands', () {
      expect(remoteReduce(connected(), const SetText('hi')).pendingCommand!.payload['value'], 'hi');
      expect(remoteReduce(connected(), const SubmitText()).pendingCommand!.action, 'submitText');
      expect(remoteReduce(connected(), const SubmitText('x')).pendingCommand!.payload['value'], 'x');
      expect(remoteReduce(connected(), const BlurText()).pendingCommand!.action, 'blurText');
      expect(remoteReduce(connected(), const OpenSearch()).pendingCommand!.action, 'openSearch');
    });

    test('nav and text commands are rejected while disconnected', () {
      final base = RemoteState();
      for (final event in [
        const Nav('up'),
        const SetText('x'),
        const SubmitText(),
        const BlurText(),
        const OpenSearch(),
        const CastDiscover(),
        const CastStop(),
      ]) {
        final s = remoteReduce(base, event);
        expect(s.notice, contains('Not connected'), reason: '${event.runtimeType}');
        expect(drain(s), isEmpty, reason: '${event.runtimeType} — never queued');
      }
    });

    test('the snapshot textEntry is reflected in state', () {
      final te = const TextEntry('typed', 'Search');
      final s = remoteReduce(connected(), SnapshotArrived(snap(idle: true, textEntry: te)));
      expect(s.textEntry, te);
    });
  });

  group('disconnect', () {
    test('disconnect drops to idle and clears the media', () {
      var s = remoteReduce(connected(), SnapshotArrived(snap(idle: false)));
      s = remoteReduce(s, const Disconnected());
      expect(s.connected, isFalse);
      expect(s.phase, RemotePhase.idle);
      expect(s.nowPlaying, isNull);
      expect(s.notice, contains('Not connected'));
    });
  });
}
