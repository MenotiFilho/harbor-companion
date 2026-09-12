// Wiring tests for the background controller (#64 / #65). The reducer is the
// decision seam; these pin the glue: connect/disconnect/toggle effects reach
// the fake platform, the "start only while foregrounded" rule holds through
// the lifecycle event, a refused start degrades without throwing, and the
// notification morphs idle ↔ media (and clears on a socket drop) off the
// derived now-playing view.

import 'dart:async';
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:harbor_companion/app/background/background_controller.dart';
import 'package:harbor_companion/app/background/background_platform.dart';
import 'package:harbor_companion/app/background/background_reducer.dart';
import 'package:harbor_companion/app/connect/connect_controller.dart';
import 'package:harbor_companion/app/connect/host_registry.dart';
import 'package:harbor_companion/app/connect/lan_scan.dart';
import 'package:harbor_companion/app/settings/settings_controller.dart';
import 'package:harbor_companion/app/settings/settings_store.dart';
import 'package:harbor_companion/app/ws/client_controller.dart';
import 'package:harbor_companion/app/ws/host_keys.dart';
import 'package:harbor_companion/app/ws/ws_transport.dart';

class FakeConnection implements WsConnection {
  final _frames = StreamController<String>.broadcast();
  bool closed = false;
  @override
  Stream<String> get frames => _frames.stream;
  @override
  void send(String message) {}
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
    final connection = FakeConnection();
    connections.add(connection);
    return connection;
  }
}

/// A snapshot frame the WS client will fold into the Remote state. `updatedAt`
/// must strictly increase between frames (the client coalesces on it).
Map<String, dynamic> snapshotFrame({
  required int updatedAt,
  bool idle = false,
  String mediaTitle = 'Breaking Bad',
  String? posterUrl,
  Map<String, dynamic>? episode,
  bool playing = true,
  double positionSec = 0,
  double durationSec = 2700,
  bool hasPrev = false,
  bool hasNext = false,
}) {
  return {
    't': 'snapshot',
    'snapshot': {
      'proto': 1,
      'idle': idle,
      'mediaId': idle ? null : 'tt0903747',
      'mediaTitle': idle ? null : mediaTitle,
      'posterUrl': idle ? null : posterUrl,
      'episode': idle ? null : episode,
      'source': idle ? null : {'quality': '1080p'},
      'positionSec': idle ? 0 : positionSec,
      'durationSec': idle ? 0 : durationSec,
      'playing': idle ? false : playing,
      'volume': 1,
      'muted': false,
      'target': {'kind': 'local', 'label': 'This PC'},
      'castDevices': <String>[],
      'castDiscovering': false,
      'hasPrevEpisode': idle ? false : hasPrev,
      'hasNextEpisode': idle ? false : hasNext,
      'subtitlesOn': false,
      'canToggleSubtitles': false,
      'textEntry': null,
      'updatedAt': updatedAt,
    },
  };
}

class FakeKeyStore implements HostKeyStore {
  @override
  Future<HostKeys> load() async => const HostKeys();
  @override
  Future<void> save(HostKeys keys) async {}
}

class FakeBackgroundPlatform implements BackgroundPlatform {
  final List<BackgroundNotification> startCalls = [];
  final List<BackgroundNotification> updateCalls = [];
  int stopCalls = 0;
  bool failStart = false;

  final StreamController<BackgroundAction> _actions =
      StreamController<BackgroundAction>.broadcast();

  @override
  Future<void> startService(BackgroundNotification notification) async {
    startCalls.add(notification);
    if (failStart) {
      throw const BackgroundServiceException('SecurityException: missing type');
    }
  }

  @override
  Future<void> updateService(BackgroundNotification notification) async {
    updateCalls.add(notification);
  }

  @override
  Future<void> stopService() async => stopCalls++;

  @override
  Stream<BackgroundAction> get actions => _actions.stream;

  void emit(BackgroundAction action) => _actions.add(action);
}

void main() {
  late FakeBackgroundPlatform platform;
  late FakeTransport transport;
  late ProviderContainer container;

  Duration now() => Duration(milliseconds: clock.now().millisecondsSinceEpoch);

  ProviderContainer makeContainer() {
    platform = FakeBackgroundPlatform();
    transport = FakeTransport();
    final c = ProviderContainer(
      overrides: [
        wsTransportProvider.overrideWithValue(transport),
        wsKeyStoreProvider.overrideWithValue(FakeKeyStore()),
        wsClockProvider.overrideWithValue(now),
        connectClockProvider.overrideWithValue(now),
        hostRegistryStoreProvider.overrideWithValue(InMemoryHostRegistryStore()),
        subnetScannerProvider.overrideWithValue(const FixedSubnetScanner([])),
        settingsStoreProvider.overrideWithValue(InMemorySettingsStore()),
        backgroundPlatformProvider.overrideWithValue(platform),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  ConnectController connect() => container.read(connectControllerProvider.notifier);

  void connectTo(String name) {
    connect().addHost('h1', name, '192.168.1.50');
    connect().acknowledgeWarning();
  }

  test('a successful connect starts the service with the idle notification',
      () {
    fakeAsync((async) {
      container = makeContainer();
      container.read(backgroundControllerProvider.notifier);
      connect();
      async.flushMicrotasks();

      connectTo('desk');
      async.flushMicrotasks();

      expect(platform.startCalls, hasLength(1));
      expect(platform.startCalls.single.title, 'Harbor Companion');
      expect(platform.startCalls.single.text, 'Connected to desk');
      expect(
        container.read(backgroundControllerProvider).serviceStatus,
        BackgroundServiceStatus.running,
      );
    });
  });

  test('an explicit disconnect stops the service', () {
    fakeAsync((async) {
      container = makeContainer();
      container.read(backgroundControllerProvider.notifier);
      connect();
      async.flushMicrotasks();
      connectTo('desk');
      async.flushMicrotasks();

      connect().disconnect();
      async.flushMicrotasks();

      expect(platform.stopCalls, 1);
      expect(
        container.read(backgroundControllerProvider).serviceStatus,
        BackgroundServiceStatus.stopped,
      );
    });
  });

  test('removing the active host stops the service', () {
    fakeAsync((async) {
      container = makeContainer();
      container.read(backgroundControllerProvider.notifier);
      connect();
      async.flushMicrotasks();
      connectTo('desk');
      async.flushMicrotasks();

      connect().removeHost('h1');
      async.flushMicrotasks();

      expect(platform.stopCalls, 1);
    });
  });

  test('turning the toggle off while running stops the service', () {
    fakeAsync((async) {
      container = makeContainer();
      container.read(backgroundControllerProvider.notifier);
      connect();
      async.flushMicrotasks();
      connectTo('desk');
      async.flushMicrotasks();

      container
          .read(settingsControllerProvider.notifier)
          .setKeepConnectionInBackground(false);
      async.flushMicrotasks();

      expect(platform.stopCalls, 1);
    });
  });

  test('with the toggle off no service ever starts', () {
    fakeAsync((async) {
      container = makeContainer();
      container.read(backgroundControllerProvider.notifier);
      connect();
      async.flushMicrotasks();

      container
          .read(settingsControllerProvider.notifier)
          .setKeepConnectionInBackground(false);
      async.flushMicrotasks();

      connectTo('desk');
      async.flushMicrotasks();

      expect(platform.startCalls, isEmpty);
    });
  });

  test('a refused start degrades without throwing', () {
    fakeAsync((async) {
      container = makeContainer();
      platform.failStart = true;
      container.read(backgroundControllerProvider.notifier);
      connect();
      async.flushMicrotasks();

      connectTo('desk');
      async.flushMicrotasks();

      final state = container.read(backgroundControllerProvider);
      expect(state.serviceStatus, BackgroundServiceStatus.degraded);
      expect(state.lastError, contains('missing type'));
    });
  });

  test('a connect while backgrounded waits for the next foreground', () {
    fakeAsync((async) {
      container = makeContainer();
      final background = container.read(backgroundControllerProvider.notifier);
      background.setForegrounded(false);
      connect();
      async.flushMicrotasks();

      connectTo('desk');
      async.flushMicrotasks();
      expect(platform.startCalls, isEmpty);

      background.setForegrounded(true);
      async.flushMicrotasks();
      expect(platform.startCalls, hasLength(1));
    });
  });

  test('a notification action is folded without changing the service', () {
    fakeAsync((async) {
      container = makeContainer();
      container.read(backgroundControllerProvider.notifier);
      connect();
      async.flushMicrotasks();
      connectTo('desk');
      async.flushMicrotasks();

      platform.emit(BackgroundAction.dismissed);
      async.flushMicrotasks();

      expect(
        container.read(backgroundControllerProvider).serviceStatus,
        BackgroundServiceStatus.running,
      );
      expect(platform.stopCalls, 0);
    });
  });

  // Frame-driven tests: the WS fake is a real broadcast stream, so drive the
  // event loop with a few zero-delay turns (the pattern in
  // remote_controller_test) rather than fake_async's microtask flush.
  Future<void> settle() async {
    for (var i = 0; i < 4; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  test('playing media morphs the idle notification into the media surface',
      () async {
    container = makeContainer();
    container.read(backgroundControllerProvider.notifier);
    connect();
    await settle();
    connectTo('desk');
    await settle();
    expect(platform.startCalls.single.text, 'Connected to desk');

    transport.connections.single.emit(jsonEncode(snapshotFrame(
      updatedAt: 1000,
      mediaTitle: 'Breaking Bad',
      posterUrl: 'http://desk:11471/poster.jpg',
      episode: const {'season': 2, 'episode': 5, 'name': 'Breakage'},
      playing: true,
      positionSec: 120,
      durationSec: 2700,
      hasPrev: true,
      hasNext: true,
    )));
    await settle();

    final posted = platform.updateCalls.single;
    expect(posted.title, 'Breaking Bad');
    expect(posted.text, 'S2 · E5  Breakage');
    expect(posted.media?.posterUrl, 'http://desk:11471/poster.jpg');
    expect(posted.media?.playing, isTrue);
    expect(posted.media?.hasPrevEpisode, isTrue);
    expect(posted.media?.hasNextEpisode, isTrue);
    expect(posted.media?.positionSec, 120);
    expect(posted.media?.durationSec, 2700);
    expect(platform.stopCalls, 0);
  });

  test('a socket drop clears the media surface and keeps the service running',
      () async {
    container = makeContainer();
    container.read(backgroundControllerProvider.notifier);
    connect();
    await settle();
    connectTo('desk');
    await settle();

    transport.connections.single.emit(jsonEncode(snapshotFrame(
      updatedAt: 1000,
      mediaTitle: 'Breaking Bad',
      episode: const {'season': 2, 'episode': 5, 'name': 'Breakage'},
    )));
    await settle();
    expect(platform.updateCalls.last.title, 'Breaking Bad');

    // The socket drops: the Remote reducer clears `nowPlaying` at once, so the
    // notification morphs back to the idle/reconnecting status. The service
    // stays up because the connect layer is reconnecting, not disconnected.
    await transport.connections.single.close();
    await settle();

    final posted = platform.updateCalls.last;
    expect(posted.media, isNull);
    expect(posted.text, 'Connected to desk');
    expect(platform.stopCalls, 0);
    expect(
      container.read(backgroundControllerProvider).serviceStatus,
      BackgroundServiceStatus.running,
    );
  });
}
