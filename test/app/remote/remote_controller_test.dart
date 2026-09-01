// Thin wiring tests for the Remote controller (ticket 07). The reducer is the
// decision seam; these pin the glue: snapshot/connection/host-error folding from
// the WS client, the `command` effect drained onto the WS client, and the await
// + sticky timers the reducer delegates to the controller.

import 'dart:async';
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:harbor_companion/app/home/home_reducer.dart' show PlayMetaCommand;
import 'package:harbor_companion/app/remote/remote_controller.dart';
import 'package:harbor_companion/app/remote/remote_reducer.dart';
import 'package:harbor_companion/app/ws/client_controller.dart';
import 'package:harbor_companion/app/ws/host_keys.dart';
import 'package:harbor_companion/app/ws/ws_transport.dart';

class FakeConnection implements WsConnection {
  final List<String> sent = [];
  final _frames = StreamController<String>.broadcast();
  bool closed = false;
  @override
  Stream<String> get frames => _frames.stream;
  @override
  void send(String message) => sent.add(message);
  @override
  Future<void> close() async {
    closed = true;
    await _frames.close();
  }

  void emit(String frame) => _frames.add(frame);
}

class FakeTransport implements WsTransport {
  final List<FakeConnection> connections = [];
  @override
  Future<WsConnection> open(String url) async {
    final c = FakeConnection();
    connections.add(c);
    return c;
  }
}

class FakeKeyStore implements HostKeyStore {
  HostKeys keys = const HostKeys();
  @override
  Future<HostKeys> load() async => keys;
  @override
  Future<void> save(HostKeys k) async {
    keys = k;
  }
}

Map<String, dynamic> snapshotFrame({
  int updatedAt = 1000,
  bool idle = true,
  String? mediaTitle = 'Movie',
  bool hasNext = false,
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
      'source': idle ? null : {'label': null, 'resolution': null, 'quality': '1080p', 'releaseGroup': 'WEB-DL'},
      'positionSec': 0,
      'durationSec': 100,
      'playing': true,
      'volume': 1,
      'muted': false,
      'target': {'kind': 'local', 'label': 'This PC'},
      'castDevices': <String>[],
      'castDiscovering': false,
      'hasPrevEpisode': false,
      'hasNextEpisode': hasNext,
      'subtitlesOn': false,
      'canToggleSubtitles': false,
      'textEntry': null,
      'updatedAt': updatedAt,
    },
  };
}

void main() {
  late FakeTransport transport;
  late FakeKeyStore keyStore;
  late ProviderContainer container;

  Duration wsNow() => Duration(milliseconds: clock.now().millisecondsSinceEpoch);

  ProviderContainer makeContainer() {
    transport = FakeTransport();
    keyStore = FakeKeyStore();
    return ProviderContainer(
      overrides: [
        wsTransportProvider.overrideWithValue(transport),
        wsKeyStoreProvider.overrideWithValue(keyStore),
        wsClockProvider.overrideWithValue(wsNow),
      ],
    );
  }

  test('a snapshot from the WS client folds into the remote state', () async {
    container = makeContainer();
    container.read(wsClientControllerProvider.notifier).connect('192.168.1.50');
    await Future<void>.delayed(Duration.zero);
    transport.connections.single.emit(jsonEncode(snapshotFrame(idle: false)));
    await Future<void>.delayed(Duration.zero);
    final s = container.read(remoteControllerProvider);
    expect(s.nowPlaying, isNotNull);
    expect(s.nowPlaying!.mediaTitle, 'Movie');
    expect(s.phase, RemotePhase.nowPlaying);
    addTearDown(container.dispose);
  });

  test('playMeta sends the command through the WS client and enters awaitingStart',
      () async {
    container = makeContainer();
    container.read(wsClientControllerProvider.notifier).connect('192.168.1.50');
    await Future<void>.delayed(Duration.zero);
    transport.connections.single.sent.clear();

    container.read(remoteControllerProvider.notifier).playMeta(
          const PlayMetaCommand(metaId: 'tt1', metaType: 'movie', name: 'Shawshank'),
        );

    final sent = transport.connections.single.sent.single;
    expect(sent, contains('playMeta'));
    expect(sent, contains('"metaId":"tt1"'));
    final s = container.read(remoteControllerProvider);
    expect(s.phase, RemotePhase.awaitingStart);
    addTearDown(container.dispose);
  });

  test('a host error frame fails an awaiting start immediately', () async {
    container = makeContainer();
    container.read(wsClientControllerProvider.notifier).connect('192.168.1.50');
    await Future<void>.delayed(Duration.zero);
    container.read(remoteControllerProvider.notifier).playMeta(
          const PlayMetaCommand(metaId: 'tt1', metaType: 'movie'),
        );
    transport.connections.single.emit(jsonEncode({'t': 'error', 'message': 'No stream'}));
    await Future<void>.delayed(Duration.zero);
    final s = container.read(remoteControllerProvider);
    expect(s.phase, RemotePhase.idle);
    expect(s.playFailed, 1);
    expect(s.lastError, 'No stream');
    addTearDown(container.dispose);
  });

  test('the await timer fires AwaitTimeout after the window', () {
    fakeAsync((async) {
      container = ProviderContainer(
        overrides: [
          wsTransportProvider.overrideWithValue(transport = FakeTransport()),
          wsKeyStoreProvider.overrideWithValue(keyStore = FakeKeyStore()),
          wsClockProvider.overrideWithValue(wsNow),
          remoteAwaitWindowProvider.overrideWithValue(const Duration(seconds: 5)),
        ],
      );
      container.read(wsClientControllerProvider.notifier).connect('192.168.1.50');
      async.flushMicrotasks();
      container.read(remoteControllerProvider);
      container.read(remoteControllerProvider.notifier).playMeta(
            const PlayMetaCommand(metaId: 'tt1', metaType: 'movie'),
          );
      async.flushMicrotasks();
      expect(container.read(remoteControllerProvider).phase, RemotePhase.awaitingStart);

      // The host stays idle and keeps pushing idle snapshots every 400ms — the
      // stream must NOT reset the countdown.
      for (var i = 1; i <= 10; i++) {
        async.elapse(const Duration(milliseconds: 400));
        transport.connections.single
            .emit(jsonEncode(snapshotFrame(idle: true, updatedAt: 1000 + i * 400)));
        async.flushMicrotasks();
      }
      async.elapse(const Duration(milliseconds: 1000)); // cross the 5s mark
      async.flushMicrotasks();
      final s = container.read(remoteControllerProvider);
      expect(s.phase, RemotePhase.idle);
      expect(s.playFailed, 1);
    });
  });

  test('the sticky timer fires StickyExpired after the hold', () {
    fakeAsync((async) {
      container = ProviderContainer(
        overrides: [
          wsTransportProvider.overrideWithValue(transport = FakeTransport()),
          wsKeyStoreProvider.overrideWithValue(keyStore = FakeKeyStore()),
          wsClockProvider.overrideWithValue(wsNow),
        ],
      );
      container.read(wsClientControllerProvider.notifier).connect('192.168.1.50');
      async.flushMicrotasks();
      // Instantiate the remote controller before the snapshots so its listen
      // folds the non-idle → idle transition (rather than seeding from the end).
      container.read(remoteControllerProvider);
      transport.connections.single
          .emit(jsonEncode(snapshotFrame(updatedAt: 1000, idle: false)));
      async.flushMicrotasks();
      transport.connections.single
          .emit(jsonEncode(snapshotFrame(updatedAt: 1400, idle: true)));
      async.flushMicrotasks();
      expect(container.read(remoteControllerProvider).stickyHeld, isTrue);

      // Idle snapshots keep arriving during the hold — the stream must NOT keep
      // resetting the 1200ms timer.
      for (var i = 1; i <= 4; i++) {
        async.elapse(const Duration(milliseconds: 300));
        transport.connections.single
            .emit(jsonEncode(snapshotFrame(idle: true, updatedAt: 1400 + i * 300)));
        async.flushMicrotasks();
      }
      async.elapse(const Duration(milliseconds: 300));
      async.flushMicrotasks();
      final s = container.read(remoteControllerProvider);
      expect(s.phase, RemotePhase.idle);
      expect(s.nowPlaying, isNull);
    });
  });

  test('a hop hold bridges the host\'s ~4s auto-advance gap', () {
    fakeAsync((async) {
      container = ProviderContainer(
        overrides: [
          wsTransportProvider.overrideWithValue(transport = FakeTransport()),
          wsKeyStoreProvider.overrideWithValue(keyStore = FakeKeyStore()),
          wsClockProvider.overrideWithValue(wsNow),
        ],
      );
      container.read(wsClientControllerProvider.notifier).connect('192.168.1.50');
      async.flushMicrotasks();
      container.read(remoteControllerProvider);
      // A series episode with a next episode armed.
      transport.connections.single
          .emit(jsonEncode(snapshotFrame(updatedAt: 1000, idle: false, hasNext: true)));
      async.flushMicrotasks();
      // The episode ends: the host goes idle and stays idle ~4s (the measured
      // auto-advance gap on beta 0.9.120, ticket 31).
      transport.connections.single
          .emit(jsonEncode(snapshotFrame(updatedAt: 1400, idle: true)));
      async.flushMicrotasks();
      expect(container.read(remoteControllerProvider).stickyHeld, isTrue);

      // Idle snapshots stream through the whole gap — the hold must NOT blink
      // to "Nothing playing" while the host is between episodes.
      for (var i = 1; i <= 11; i++) {
        async.elapse(const Duration(milliseconds: 400));
        transport.connections.single
            .emit(jsonEncode(snapshotFrame(idle: true, updatedAt: 1400 + i * 400)));
        async.flushMicrotasks();
      }
      final midGap = container.read(remoteControllerProvider);
      expect(midGap.phase, RemotePhase.nowPlaying,
          reason: 'still holding through the ~4s host gap');
      expect(midGap.stickyHeld, isTrue);
      expect(midGap.nowPlaying!.hasNextEpisode, isTrue);

      // The next episode starts inside the hold — no flash, and the sticky
      // timer is cancelled so no late drop can fire.
      transport.connections.single.emit(jsonEncode(snapshotFrame(
        idle: false,
        updatedAt: 1400 + 12 * 400,
        mediaTitle: 'Fetal Position',
        hasNext: true,
      )));
      async.flushMicrotasks();
      final resumed = container.read(remoteControllerProvider);
      expect(resumed.phase, RemotePhase.nowPlaying);
      expect(resumed.stickyHeld, isFalse);
      expect(resumed.nowPlaying!.mediaTitle, 'Fetal Position');

      // Settling: no late StickyExpired after the hold was cleared.
      async.elapse(const Duration(seconds: 6));
      async.flushMicrotasks();
      final settled = container.read(remoteControllerProvider);
      expect(settled.phase, RemotePhase.nowPlaying);
      expect(settled.nowPlaying!.mediaTitle, 'Fetal Position');
    });
  });

  test('a real stop with hasNext armed falls back to idle at ~5s', () {
    fakeAsync((async) {
      container = ProviderContainer(
        overrides: [
          wsTransportProvider.overrideWithValue(transport = FakeTransport()),
          wsKeyStoreProvider.overrideWithValue(keyStore = FakeKeyStore()),
          wsClockProvider.overrideWithValue(wsNow),
        ],
      );
      container.read(wsClientControllerProvider.notifier).connect('192.168.1.50');
      async.flushMicrotasks();
      container.read(remoteControllerProvider);
      transport.connections.single
          .emit(jsonEncode(snapshotFrame(updatedAt: 1000, idle: false, hasNext: true)));
      async.flushMicrotasks();
      transport.connections.single
          .emit(jsonEncode(snapshotFrame(updatedAt: 1400, idle: true)));
      async.flushMicrotasks();
      expect(container.read(remoteControllerProvider).stickyHeld, isTrue);

      // The host never resumes (user stopped, or auto-play is off) — idle
      // snapshots stream on, the hold must survive past the hop gap but drop
      // at the ~5s window, never staying stuck in stale now-playing.
      for (var i = 1; i <= 9; i++) {
        async.elapse(const Duration(milliseconds: 400));
        transport.connections.single
            .emit(jsonEncode(snapshotFrame(idle: true, updatedAt: 1400 + i * 400)));
        async.flushMicrotasks();
      }
      expect(container.read(remoteControllerProvider).phase, RemotePhase.nowPlaying,
          reason: '3.6s in — still within the hop window');
      async.elapse(const Duration(milliseconds: 1600)); // cross the 5s mark
      async.flushMicrotasks();
      final s = container.read(remoteControllerProvider);
      expect(s.phase, RemotePhase.idle);
      expect(s.nowPlaying, isNull);
      expect(s.notice, 'Playback ended');
    });
  });

  test('a transport command is drained onto the WS client', () async {
    container = makeContainer();
    container.read(wsClientControllerProvider.notifier).connect('192.168.1.50');
    await Future<void>.delayed(Duration.zero);
    container.read(remoteControllerProvider);
    transport.connections.single
        .emit(jsonEncode(snapshotFrame(idle: false, updatedAt: 1000)));
    await Future<void>.delayed(Duration.zero);
    transport.connections.single.sent.clear();

    container.read(remoteControllerProvider.notifier).togglePlay();

    final sent = transport.connections.single.sent.single;
    expect(sent, contains('pause')); // snapshot reported playing
    addTearDown(container.dispose);
  });
}
