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
      'hasNextEpisode': false,
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
