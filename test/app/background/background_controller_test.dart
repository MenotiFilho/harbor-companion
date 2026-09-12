// Wiring tests for the background controller (#64). The reducer is the
// decision seam; these pin the glue: connect/disconnect/toggle effects reach
// the fake platform, the "start only while foregrounded" rule holds through
// the lifecycle event, and a refused start degrades without throwing.

import 'dart:async';

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
  @override
  Stream<String> get frames => _frames.stream;
  @override
  void send(String message) {}
  @override
  Future<void> close() async => _frames.close();
}

class FakeTransport implements WsTransport {
  @override
  Future<WsConnection> open(String url) async => FakeConnection();
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
  late ProviderContainer container;

  Duration now() => Duration(milliseconds: clock.now().millisecondsSinceEpoch);

  ProviderContainer makeContainer() {
    platform = FakeBackgroundPlatform();
    return ProviderContainer(
      overrides: [
        wsTransportProvider.overrideWithValue(FakeTransport()),
        wsKeyStoreProvider.overrideWithValue(FakeKeyStore()),
        wsClockProvider.overrideWithValue(now),
        connectClockProvider.overrideWithValue(now),
        hostRegistryStoreProvider.overrideWithValue(InMemoryHostRegistryStore()),
        subnetScannerProvider.overrideWithValue(const FixedSubnetScanner([])),
        settingsStoreProvider.overrideWithValue(InMemorySettingsStore()),
        backgroundPlatformProvider.overrideWithValue(platform),
      ],
    );
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
}
