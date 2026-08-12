// Tests for the WS client state model (lib/app/ws/client_reducer.dart).
//
// Pins the wire-contract behaviors validated by the ws-client prototype (#7)
// and the ticket 02 acceptance criteria: connect + hello handshake, frame
// handling, snapshot coalescing on updatedAt, reconnect backoff, command
// dispatch (reject while disconnected, never queue), the ~1.2s sticky window
// after a disconnect, key persistence/re-apply, and the no-castDiscover rule.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:harbor_companion/app/ws/client_reducer.dart';

Duration ms(int m) => Duration(milliseconds: m);

/// Drain the outgoing effects buffer so later asserts see a clean slate.
List<String> drain(ClientState s) {
  final e = List<String>.from(s.outgoing);
  s.outgoing.clear();
  return e;
}

/// Builds a wrapped `{t:"snapshot", snapshot:{...}}` frame — the exact wire
/// envelope the real host sends.
Map<String, dynamic> snapshotFrame({
  int updatedAt = 1000,
  bool idle = true,
  String? mediaTitle = 'Movie',
  String? tmdbKey,
  String? rpdbKey,
  String? tvdbKey,
  String? hostVersion = '0.9.118',
}) {
  return {
    't': 'snapshot',
    'snapshot': {
      'proto': 1,
      'idle': idle,
      'mediaId': idle ? null : 'tt0000001',
      'mediaTitle': idle ? null : mediaTitle,
      'posterUrl': null,
      'episode': null,
      'positionSec': 0,
      'durationSec': 0,
      'playing': false,
      'volume': 1,
      'muted': false,
      'target': {'kind': 'local', 'label': 'This PC'},
      'castDevices': <String>[],
      'castDiscovering': false,
      'hasPrevEpisode': false,
      'hasNextEpisode': false,
      'subtitlesOn': false,
      'canToggleSubtitles': false,
      'textEntry': null,
      'hostVersion': hostVersion,
      'tmdbKey': tmdbKey,
      'rpdbKey': rpdbKey,
      'tvdbKey': tvdbKey,
      'updatedAt': updatedAt,
    },
  };
}

ClientState connected(ClientState s) {
  var next = clientReduce(s, ConnectRequested(ms(0)));
  drain(next);
  next = clientReduce(next, SocketOpened(ms(0)));
  drain(next);
  return next;
}

void main() {
  group('connect + hello handshake', () {
    test('ConnectRequested moves disconnected → connecting at the floor', () {
      final s = clientReduce(ClientState(), ConnectRequested(ms(100)));
      expect(s.status, WsStatus.connecting);
      expect(s.backoff, backoffFloor);
      expect(s.reconnectAttempts, 0);
      expect(s.reconnectAt, isNull);
    });

    test('SocketOpened moves to connected, resets backoff, sends hello', () {
      var s = clientReduce(ClientState(), ConnectRequested(ms(0)));
      drain(s);
      s = clientReduce(s, SocketOpened(ms(10)));
      expect(s.status, WsStatus.connected);
      expect(s.backoff, backoffFloor);
      expect(s.reconnectAttempts, 0);
      final hello = drain(s);
      expect(hello, hasLength(1));
      final frame = jsonDecode(hello.single) as Map<String, dynamic>;
      expect(frame, {'t': 'hello', 'client': 'harbor-remote', 'proto': 1});
    });

    test('the hello frame is the ONLY thing auto-sent on open', () {
      var s = clientReduce(ClientState(), ConnectRequested(ms(0)));
      drain(s);
      s = clientReduce(s, SocketOpened(ms(0)));
      final sent = drain(s);
      expect(sent, hasLength(1));
      final frame = jsonDecode(sent.single) as Map<String, dynamic>;
      expect(frame['t'], 'hello');
    });

    test('SocketOpened while not connecting is ignored', () {
      final s = clientReduce(ClientState(), SocketOpened(ms(0)));
      expect(s.status, WsStatus.disconnected);
      expect(drain(s), isEmpty);
      expect(s.notice, contains('ignored'));
    });

    test('ConnectRequested while already connected is ignored', () {
      final s = connected(ClientState());
      final after = clientReduce(s, ConnectRequested(ms(100)));
      expect(after.status, WsStatus.connected);
      expect(after.notice, contains('already connected'));
      expect(drain(after), isEmpty);
    });
  });

  group('frame handling', () {
    test('a wrapped snapshot frame is unwrapped and applied', () {
      var s = connected(ClientState());
      drain(s);
      s = clientReduce(s, Frame(ms(10), jsonEncode(snapshotFrame(updatedAt: 2000))));
      expect(s.last, isNotNull);
      expect(s.last!.updatedAt, 2000);
      expect(s.snapshotsReceived, 1);
      expect(s.snapshotsSkipped, 0);
      expect(drain(s), isEmpty);
    });

    test('host hello frame is accepted, not dropped', () {
      final s = clientReduce(connected(ClientState()),
          Frame(ms(0), jsonEncode({'t': 'hello', 'proto': 1, 'server': 'harbor-remote'})));
      expect(s.droppedFrames, 0);
      expect(s.notice, contains('host hello'));
    });

    test('pong frame records lastPongAt', () {
      final s = clientReduce(connected(ClientState()),
          Frame(ms(0), jsonEncode({'t': 'pong', 'at': 1234567890})));
      expect(s.lastPongAt, '1234567890');
      expect(s.droppedFrames, 0);
    });

    test('error frame records the host message', () {
      final s = clientReduce(connected(ClientState()),
          Frame(ms(0), jsonEncode({'t': 'error', 'message': 'bad command'})));
      expect(s.lastError, contains('bad command'));
    });

    test('unparseable frames are dropped and counted', () {
      final s = clientReduce(connected(ClientState()), Frame(ms(0), 'this is not json{{{'));
      expect(s.droppedFrames, 1);
      expect(s.notice, contains('unparseable'));
    });

    test('non-object JSON frames are dropped', () {
      final s = clientReduce(connected(ClientState()), Frame(ms(0), jsonEncode([1, 2, 3])));
      expect(s.droppedFrames, 1);
      expect(s.notice, contains('non-object'));
    });

    test('snapshot frames with a malformed payload are dropped', () {
      final s = clientReduce(connected(ClientState()),
          Frame(ms(0), jsonEncode({'t': 'snapshot', 'snapshot': 'not-a-map'})));
      expect(s.droppedFrames, 1);
      expect(s.last, isNull);
    });

    test('unknown frame types are dropped', () {
      final s = clientReduce(connected(ClientState()),
          Frame(ms(0), jsonEncode({'t': 'whatever', 'x': 1})));
      expect(s.droppedFrames, 1);
    });
  });

  group('snapshot coalescing on updatedAt', () {
    test('a newer snapshot replaces the previous one', () {
      var s = connected(ClientState());
      drain(s);
      s = clientReduce(s, Frame(ms(0), jsonEncode(snapshotFrame(updatedAt: 1000))));
      s = clientReduce(s, Frame(ms(1), jsonEncode(snapshotFrame(updatedAt: 1400))));
      expect(s.snapshotsReceived, 2);
      expect(s.snapshotsSkipped, 0);
      expect(s.last!.updatedAt, 1400);
    });

    test('an equal-updatedAt snapshot is dropped as stale', () {
      var s = connected(ClientState());
      drain(s);
      s = clientReduce(s, Frame(ms(0), jsonEncode(snapshotFrame(updatedAt: 1000))));
      s = clientReduce(s, Frame(ms(1), jsonEncode(snapshotFrame(updatedAt: 1000))));
      expect(s.snapshotsReceived, 1);
      expect(s.snapshotsSkipped, 1);
    });

    test('an older-updatedAt snapshot is dropped as stale', () {
      var s = connected(ClientState());
      drain(s);
      s = clientReduce(s, Frame(ms(0), jsonEncode(snapshotFrame(updatedAt: 1000))));
      s = clientReduce(s, Frame(ms(1), jsonEncode(snapshotFrame(updatedAt: 999))));
      expect(s.snapshotsReceived, 1);
      expect(s.snapshotsSkipped, 1);
      expect(s.last!.updatedAt, 1000);
    });

    test('a 3-frame burst coalesces to the single newest snapshot', () {
      var s = connected(ClientState());
      drain(s);
      s = clientReduce(s, Frame(ms(0), jsonEncode(snapshotFrame(updatedAt: 1000))));
      s = clientReduce(s, Frame(ms(1), jsonEncode(snapshotFrame(updatedAt: 1200))));
      s = clientReduce(s, Frame(ms(2), jsonEncode(snapshotFrame(updatedAt: 1400))));
      s = clientReduce(s, Frame(ms(3), jsonEncode(snapshotFrame(updatedAt: 1200)))); // post-command echo
      expect(s.snapshotsReceived, 3);
      expect(s.snapshotsSkipped, 1);
      expect(s.last!.updatedAt, 1400);
    });
  });

  group('reconnect backoff', () {
    test('an established-connection drop retries at the floor', () {
      final s = clientReduce(connected(ClientState()), SocketClosed(ms(1000), 'connection reset'));
      expect(s.status, WsStatus.reconnecting);
      expect(s.backoff, backoffFloor);
      expect(s.reconnectAttempts, 1);
      expect(s.reconnectAt, ms(1400));
      expect(s.lastError, contains('connection reset'));
    });

    test('a failed retry doubles the backoff', () {
      var s = clientReduce(connected(ClientState()), SocketClosed(ms(0), 'drop'));
      s = clientReduce(s, Tick(ms(500))); // attempt 1 fires
      drain(s);
      s = clientReduce(s, SocketClosed(ms(500), 'no host'));
      expect(s.status, WsStatus.reconnecting);
      expect(s.backoff, const Duration(milliseconds: 800));
      expect(s.reconnectAttempts, 2);
      expect(s.reconnectAt, ms(1300));
    });

    test('backoff doubles to the 3000ms cap and stays there', () {
      final expected = <int>[800, 1600, 3000, 3000, 3000];
      var s = clientReduce(connected(ClientState()), SocketClosed(ms(0), 'drop'));
      for (final delay in expected) {
        final at = s.reconnectAt!;
        s = clientReduce(s, Tick(at));
        drain(s);
        s = clientReduce(s, SocketClosed(at, 'no host'));
        expect(s.backoff.inMilliseconds, delay, reason: 'attempt ${s.reconnectAttempts}');
      }
    });

    test('backoff resets to the floor on a successful open', () {
      var s = clientReduce(connected(ClientState()), SocketClosed(ms(0), 'drop'));
      s = clientReduce(s, Tick(s.reconnectAt!));
      drain(s);
      s = clientReduce(s, SocketOpened(ms(500)));
      expect(s.status, WsStatus.connected);
      expect(s.backoff, backoffFloor);
      expect(s.reconnectAttempts, 0);
    });

    test('Tick before reconnectAt does not retry', () {
      final s = clientReduce(connected(ClientState()), SocketClosed(ms(0), 'drop'));
      final after = clientReduce(s, Tick(ms(100)));
      expect(after.status, WsStatus.reconnecting);
    });

    test('Tick at reconnectAt fires the retry (connecting)', () {
      var s = clientReduce(connected(ClientState()), SocketClosed(ms(0), 'drop'));
      s = clientReduce(s, Tick(ms(400)));
      expect(s.status, WsStatus.connecting);
      expect(s.reconnectAt, isNull);
    });

    test('a reconnect attempt that gives up (user disconnect) is clean', () {
      var s = clientReduce(connected(ClientState()), SocketClosed(ms(0), 'drop'));
      s = clientReduce(s, DisconnectRequested(ms(100)));
      expect(s.status, WsStatus.disconnected);
      expect(s.reconnectAt, isNull);
      expect(s.backoff, backoffFloor);
      expect(s.reconnectAttempts, 0);
    });
  });

  group('backgrounding', () {
    test('Tick is suppressed while backgrounded', () {
      var s = clientReduce(connected(ClientState()), SocketClosed(ms(0), 'drop'));
      s = clientReduce(s, SetBackgrounded(ms(0), true));
      final after = clientReduce(s, Tick(ms(4000))); // long past reconnectAt
      expect(after.status, WsStatus.reconnecting);
      expect(after.backgrounded, isTrue);
    });

    test('foregrounding resumes retries from the existing backoff', () {
      var s = clientReduce(connected(ClientState()), SocketClosed(ms(0), 'drop'));
      s = clientReduce(s, SetBackgrounded(ms(0), true));
      s = clientReduce(s, SetBackgrounded(ms(4000), false));
      final after = clientReduce(s, Tick(ms(4000)));
      expect(after.backgrounded, isFalse);
      expect(after.status, WsStatus.connecting);
    });

    test('backgrounding does not change an established connection', () {
      final s = clientReduce(connected(ClientState()), SetBackgrounded(ms(0), true));
      expect(s.status, WsStatus.connected);
      expect(s.backgrounded, isTrue);
    });
  });

  group('command dispatch', () {
    test('a command while connected is encoded and sent', () {
      var s = connected(ClientState());
      drain(s);
      s = clientReduce(s, SendCommand(ms(0), 'play'));
      final frames = drain(s);
      expect(frames, hasLength(1));
      final cmd = jsonDecode(frames.single) as Map<String, dynamic>;
      expect(cmd, {
        't': 'cmd',
        'command': {'action': 'play'},
      });
      expect(s.lastCommand, isNotNull);
    });

    test('commands while disconnected are rejected and never queued', () {
      final states = [WsStatus.disconnected, WsStatus.connecting, WsStatus.reconnecting];
      for (final status in states) {
        final base = status == WsStatus.disconnected
            ? ClientState()
            : status == WsStatus.connecting
                ? clientReduce(ClientState(), ConnectRequested(ms(0)))
                : clientReduce(connected(ClientState()), SocketClosed(ms(0), 'drop'));
        final s = clientReduce(base, SendCommand(ms(0), 'pause'));
        expect(s.lastError, contains('cannot send'), reason: 'status $status');
        expect(s.notice, contains('rejected'), reason: 'status $status');
        expect(drain(s), isEmpty, reason: 'status $status — never queued');
      }
    });

    test('a rejected command is not replayed after a reconnect', () {
      var s = connected(ClientState());
      drain(s);
      s = clientReduce(s, SendCommand(ms(0), 'pause'));
      drain(s); // rejected, nothing queued
      s = clientReduce(s, SocketClosed(ms(0), 'drop'));
      drain(s);
      s = clientReduce(s, Tick(s.reconnectAt!));
      drain(s);
      s = clientReduce(s, SocketOpened(ms(500)));
      final frames = drain(s);
      expect(frames, hasLength(1)); // only hello — pause never came back
    });

    test('unknown commands are rejected with an error', () {
      final s = clientReduce(connected(ClientState()), SendCommand(ms(0), 'frobnicate'));
      expect(s.lastError, contains('unknown command'));
      expect(drain(s), isEmpty);
    });

    test('no castDiscover is ever auto-sent across a connect/reconnect cycle', () {
      var s = connected(ClientState());
      drain(s);
      expect(drain(s).where((f) => f.contains('castDiscover')), isEmpty);
      s = clientReduce(s, SocketClosed(ms(0), 'drop'));
      s = clientReduce(s, Tick(s.reconnectAt!));
      drain(s);
      s = clientReduce(s, SocketOpened(ms(500)));
      final frames = drain(s);
      expect(frames.where((f) => f.contains('castDiscover')), isEmpty);
      expect(frames.map((f) => (jsonDecode(f) as Map)['t']), everyElement('hello'));
    });

    test('setTarget encodes the wire shape: local vs castDeviceId object', () {
      var s = connected(ClientState());
      drain(s);
      s = clientReduce(s, SendCommand(ms(0), 'setTarget', {'target': 'local'}));
      final local = jsonDecode(drain(s).single) as Map<String, dynamic>;
      expect((local['command'] as Map)['target'], 'local');

      s = clientReduce(s, SendCommand(ms(0), 'setTarget', {'target': 'abc123'}));
      final cast = jsonDecode(drain(s).single) as Map<String, dynamic>;
      expect((cast['command'] as Map)['target'], {'castDeviceId': 'abc123'});
    });
  });

  group('snapshot extras (source + castDevices)', () {
    test('source and castDevices parse from a snapshot', () {
      final frame = snapshotFrame(updatedAt: 1000, idle: false);
      final inner = (frame['snapshot'] as Map<String, dynamic>);
      inner['source'] = {'label': null, 'resolution': '1080p', 'quality': null, 'releaseGroup': 'WEB-DL'};
      inner['castDevices'] = [
        {'id': 'd1', 'name': 'Living Room TV', 'kind': 'chromecast'},
      ];
      inner['target'] = {'kind': 'cast', 'label': 'Living Room TV', 'deviceId': 'd1', 'castKind': 'chromecast'};
      final s = clientReduce(connected(ClientState()), Frame(ms(0), jsonEncode(frame)));
      expect(s.last!.source!.resolution, '1080p');
      expect(s.last!.castDevices, hasLength(1));
      expect(s.last!.castDevices.single.name, 'Living Room TV');
      expect(s.last!.target.deviceId, 'd1');
      expect(s.last!.target.isCasting, isTrue);
    });
  });

  group('host error frames', () {
    test('an error frame records the host message separately', () {
      final s = clientReduce(connected(ClientState()),
          Frame(ms(0), jsonEncode({'t': 'error', 'message': 'No stream found'})));
      expect(s.lastHostError, 'No stream found');
      expect(s.lastError, contains('No stream found'));
    });
  });

  group('sticky window after disconnect', () {
    test('the last snapshot stays visible within the ~1.2s sticky window', () {
      var s = connected(ClientState());
      drain(s);
      s = clientReduce(s, Frame(ms(0), jsonEncode(snapshotFrame(updatedAt: 1000, idle: false))));
      s = clientReduce(s, SocketClosed(ms(1000), 'drop'));
      expect(s.status, WsStatus.reconnecting);
      expect(s.disconnectedAt, ms(1000));
      final held = nowPlaying(s, ms(1500));
      expect(held.active, isTrue);
      expect(held.sticky, isTrue);
      expect(held.title, 'Movie');
    });

    test('after the sticky window the UI drops to idle', () {
      var s = connected(ClientState());
      drain(s);
      s = clientReduce(s, Frame(ms(0), jsonEncode(snapshotFrame(updatedAt: 1000, idle: false))));
      s = clientReduce(s, SocketClosed(ms(1000), 'drop'));
      final after = nowPlaying(s, ms(2201));
      expect(after.active, isFalse);
    });

    test('a deliberate user disconnect drops to idle immediately', () {
      var s = connected(ClientState());
      drain(s);
      s = clientReduce(s, Frame(ms(0), jsonEncode(snapshotFrame(updatedAt: 1000, idle: false))));
      s = clientReduce(s, DisconnectRequested(ms(1000)));
      expect(nowPlaying(s, ms(1050)).active, isFalse);
    });

    test('a reconnect that lands inside the window restores the view', () {
      var s = connected(ClientState());
      drain(s);
      s = clientReduce(s, Frame(ms(0), jsonEncode(snapshotFrame(updatedAt: 1000, idle: false))));
      s = clientReduce(s, SocketClosed(ms(1000), 'drop'));
      s = clientReduce(s, Tick(s.reconnectAt!));
      drain(s);
      s = clientReduce(s, SocketOpened(ms(1400)));
      s = clientReduce(s, Frame(ms(1400), jsonEncode(snapshotFrame(updatedAt: 1800, idle: false))));
      expect(nowPlaying(s, ms(1450)).active, isTrue);
    });
  });

  group('sticky idle through episode hops', () {
    test('a brief idle flap holds the last active media, then drops', () {
      var s = connected(ClientState());
      drain(s);
      s = clientReduce(s, Frame(ms(0), jsonEncode(snapshotFrame(updatedAt: 1000, idle: false))));
      s = clientReduce(s, Frame(ms(400), jsonEncode(snapshotFrame(updatedAt: 1400, idle: true))));
      final held = nowPlaying(s, ms(600));
      expect(held.active, isTrue);
      expect(held.sticky, isTrue);
      expect(held.title, 'Movie');
      final dropped = nowPlaying(s, ms(1601));
      expect(dropped.active, isFalse);
    });

    test('a fresh non-idle snapshot clears the idle window', () {
      var s = connected(ClientState());
      drain(s);
      s = clientReduce(s, Frame(ms(0), jsonEncode(snapshotFrame(updatedAt: 1000, idle: false))));
      s = clientReduce(s, Frame(ms(400), jsonEncode(snapshotFrame(updatedAt: 1400, idle: true))));
      s = clientReduce(s, Frame(ms(800), jsonEncode(snapshotFrame(updatedAt: 1800, idle: false))));
      expect(nowPlaying(s, ms(900)).active, isTrue);
      expect(nowPlaying(s, ms(900)).sticky, isFalse);
    });
  });

  group('host metadata keys', () {
    test('keys from a snapshot land in state and are retained when absent', () {
      var s = connected(ClientState());
      drain(s);
      s = clientReduce(s, Frame(ms(0), jsonEncode(snapshotFrame(
            updatedAt: 1000,
            tmdbKey: 'tmdb-1',
            rpdbKey: 'rpdb-1',
            tvdbKey: 'tvdb-1',
          ))));
      expect(s.tmdbKey, 'tmdb-1');
      expect(s.rpdbKey, 'rpdb-1');
      expect(s.tvdbKey, 'tvdb-1');
      // next snapshot omits the keys (stock host) — the last known keys hold
      s = clientReduce(s, Frame(ms(1), jsonEncode(snapshotFrame(updatedAt: 1400))));
      expect(s.tmdbKey, 'tmdb-1');
      expect(s.rpdbKey, 'rpdb-1');
      expect(s.tvdbKey, 'tvdb-1');
    });

    test('a changed key overwrites the previous value', () {
      var s = connected(ClientState());
      drain(s);
      s = clientReduce(s, Frame(ms(0), jsonEncode(snapshotFrame(updatedAt: 1000, tmdbKey: 'old'))));
      s = clientReduce(s, Frame(ms(1), jsonEncode(snapshotFrame(updatedAt: 1400, tmdbKey: 'new'))));
      expect(s.tmdbKey, 'new');
    });

    test('persisted keys are restored into the model', () {
      var s = connected(ClientState());
      drain(s);
      s = clientReduce(s, RestoreKeys(ms(0), 'tmdb-restored', 'rpdb-restored', null));
      expect(s.tmdbKey, 'tmdb-restored');
      expect(s.rpdbKey, 'rpdb-restored');
      expect(s.tvdbKey, isNull);
    });

    test('hostVersion rides the snapshot and sticks', () {
      var s = connected(ClientState());
      drain(s);
      s = clientReduce(s, Frame(ms(0), jsonEncode(snapshotFrame(updatedAt: 1000))));
      expect(s.hostVersion, '0.9.118');
    });
  });

  group('effective status (the shell seam)', () {
    test('reconnecting reports connected within the sticky window', () {
      var s = clientReduce(connected(ClientState()), SocketClosed(ms(1000), 'drop'));
      expect(effectiveStatus(s, ms(1200)), WsStatus.connected);
    });

    test('connecting mid-retry still holds connected inside the window', () {
      var s = clientReduce(connected(ClientState()), SocketClosed(ms(1000), 'drop'));
      s = clientReduce(s, Tick(s.reconnectAt!)); // backoff fires → connecting
      expect(s.status, WsStatus.connecting);
      expect(effectiveStatus(s, ms(1200)), WsStatus.connected);
      expect(effectiveStatus(s, ms(2201)), WsStatus.connecting);
    });

    test('a fresh connect in progress is not mistaken for a drop', () {
      final c = clientReduce(ClientState(), ConnectRequested(ms(0)));
      expect(effectiveStatus(c, ms(0)), WsStatus.connecting);
    });

    test('reconnecting reports reconnecting after the sticky window', () {
      var s = clientReduce(connected(ClientState()), SocketClosed(ms(1000), 'drop'));
      expect(effectiveStatus(s, ms(2201)), WsStatus.reconnecting);
    });

    test('connected/connecting pass through unchanged', () {
      expect(effectiveStatus(connected(ClientState()), ms(0)), WsStatus.connected);
      final c = clientReduce(ClientState(), ConnectRequested(ms(0)));
      expect(effectiveStatus(c, ms(0)), WsStatus.connecting);
    });
  });
}
