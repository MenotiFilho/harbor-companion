// Thin wiring tests for the connect controller (ticket 03). The reducer is the
// decision seam; these pin the glue: effect → WS client calls, registry
// persistence, launch auto-connect (cold-start drop-to-idle), asymmetric give-up
// teardown, candidate-only scan, and the shell connection-status mirror.

import 'dart:async';

import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:harbor_companion/app/connect/connect_controller.dart';
import 'package:harbor_companion/app/connect/connect_reducer.dart';
import 'package:harbor_companion/app/connect/host_registry.dart';
import 'package:harbor_companion/app/connect/lan_scan.dart';
import 'package:harbor_companion/app/shell/shell_controller.dart';
import 'package:harbor_companion/app/shell/shell_reducer.dart';
import 'package:harbor_companion/app/ws/client_controller.dart';
import 'package:harbor_companion/app/ws/client_reducer.dart';
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
  final List<String> openedUrls = [];
  final List<FakeConnection> connections = [];
  bool failOpen = false;
  @override
  Future<WsConnection> open(String url) async {
    openedUrls.add(url);
    if (failOpen) throw Exception('connection refused');
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

class FakeRegistryStore implements HostRegistryStore {
  List<HostEntry> hosts;
  int saves = 0;
  FakeRegistryStore([this.hosts = const []]);
  @override
  Future<List<HostEntry>> load() async => hosts;
  @override
  Future<void> save(List<HostEntry> h) async {
    hosts = h;
    saves++;
  }
}

void main() {
  late FakeTransport transport;
  late FakeRegistryStore registry;
  late ProviderContainer container;

  Duration now() => Duration(milliseconds: clock.now().millisecondsSinceEpoch);

  ProviderContainer makeContainer({
    FakeRegistryStore? store,
    bool failOpen = false,
    List<String> scanResults = const [],
  }) {
    transport = FakeTransport()..failOpen = failOpen;
    registry = store ?? FakeRegistryStore();
    return ProviderContainer(
      overrides: [
        wsTransportProvider.overrideWithValue(transport),
        wsKeyStoreProvider.overrideWithValue(FakeKeyStore()),
        wsClockProvider.overrideWithValue(now),
        connectClockProvider.overrideWithValue(now),
        hostRegistryStoreProvider.overrideWithValue(registry),
        subnetScannerProvider.overrideWithValue(FixedSubnetScanner(scanResults)),
      ],
    );
  }

  ConnectController ctrl() => container.read(connectControllerProvider.notifier);

  HostEntry host(String id,
      {String address = '192.168.1.50:11471', bool warned = false, int? lastConnectedAt}) {
    return HostEntry(id: id, name: 'Host $id', address: address, warned: warned, lastConnectedAt: lastConnectedAt);
  }

  test('add host + acknowledge warning drives the WS client to connect', () {
    fakeAsync((async) {
      container = makeContainer();
      ctrl();
      async.flushMicrotasks(); // restore
      ctrl().addHost('h1', 'desk', '192.168.1.50');
      expect(container.read(connectControllerProvider).warningHeld, isTrue);
      expect(transport.openedUrls, isEmpty, reason: 'no connect before acknowledge');
      ctrl().acknowledgeWarning();
      async.flushMicrotasks();
      expect(transport.openedUrls, ['ws://192.168.1.50:11471/api/remote']);
      expect(container.read(connectControllerProvider).phase, ConnPhase.connected);
    });
  });

  test('a socket open folds back into the reducer (lastConnectedAt recorded)', () {
    fakeAsync((async) {
      container = makeContainer();
      ctrl();
      async.flushMicrotasks();
      ctrl().addHost('h1', 'desk', '192.168.1.50');
      ctrl().acknowledgeWarning();
      async.flushMicrotasks();
      final s = container.read(connectControllerProvider);
      expect(s.phase, ConnPhase.connected);
      expect(s.selected?.lastConnectedAt, isNotNull);
    });
  });

  test('adding a host persists the registry (warned + lastConnectedAt ride along)', () {
    fakeAsync((async) {
      container = makeContainer();
      ctrl();
      async.flushMicrotasks();
      ctrl().addHost('h1', 'desk', '192.168.1.50');
      ctrl().acknowledgeWarning();
      async.flushMicrotasks();
      final saved = registry.hosts;
      expect(saved.map((h) => h.address), ['192.168.1.50:11471']);
      expect(saved.single.warned, isTrue);
      expect(saved.single.lastConnectedAt, isNotNull);
    });
  });

  test('launch auto-connects to a persisted warned host (cold start succeeds)', () {
    fakeAsync((async) {
      container = makeContainer(
        store: FakeRegistryStore([host('h1', warned: true, lastConnectedAt: 5000)]),
      );
      ctrl();
      async.flushMicrotasks();
      expect(container.read(connectControllerProvider).phase, ConnPhase.connected);
      expect(transport.openedUrls, ['ws://192.168.1.50:11471/api/remote']);
      expect(container.read(connectionStatusProvider), ConnectionStatus.connected);
    });
  });

  test('a launch connect that fails drops to idle (cold start, no spinner)', () {
    fakeAsync((async) {
      container = makeContainer(
        store: FakeRegistryStore([host('h1', warned: true, lastConnectedAt: 5000)]),
        failOpen: true,
      );
      ctrl();
      async.flushMicrotasks();
      final s = container.read(connectControllerProvider);
      expect(s.phase, ConnPhase.idle);
      expect(s.notice, contains('last used host unreachable'));
      // The WS client is torn down, not left reconnecting.
      expect(container.read(wsClientControllerProvider).status, WsStatus.disconnected);
      expect(container.read(connectionStatusProvider), ConnectionStatus.disconnected);
    });
  });

  test('a never-connected host gives up after maxReconnectAttempts and tears down', () {
    fakeAsync((async) {
      container = makeContainer(failOpen: true);
      ctrl();
      async.flushMicrotasks();
      ctrl().addHost('h1', 'far', '10.9.9.9');
      ctrl().acknowledgeWarning();
      async.flushMicrotasks();
      // First attempt fails → reconnecting.
      expect(container.read(connectControllerProvider).phase, ConnPhase.reconnecting);

      // Drive the remaining attempts through the backoff timer until give-up.
      for (var i = 0; i < maxReconnectAttempts * 2; i++) {
        async.elapse(const Duration(seconds: 4)); // past any backoff (≤3000ms)
        async.flushMicrotasks();
        final s = container.read(connectControllerProvider);
        if (s.phase == ConnPhase.failed) break;
      }
      final s = container.read(connectControllerProvider);
      expect(s.phase, ConnPhase.failed);
      expect(s.notice, contains('check the address'));
      expect(container.read(wsClientControllerProvider).status, WsStatus.disconnected);
    });
  });

  test('scan surfaces candidates and never auto-connects', () {
    fakeAsync((async) {
      container = makeContainer(scanResults: ['192.168.1.77']);
      ctrl();
      async.flushMicrotasks();
      ctrl().startScan();
      async.flushMicrotasks();
      final s = container.read(connectControllerProvider);
      expect(s.scanning, isFalse);
      expect(s.scanResults.map((h) => h.address), ['192.168.1.77:11471']);
      expect(transport.openedUrls, isEmpty);
    });
  });

  test('deleting the active connected host tears the socket down', () {
    fakeAsync((async) {
      container = makeContainer();
      ctrl();
      async.flushMicrotasks();
      ctrl().addHost('h1', 'desk', '192.168.1.50');
      ctrl().acknowledgeWarning();
      async.flushMicrotasks();
      expect(container.read(connectControllerProvider).phase, ConnPhase.connected);
      ctrl().removeHost('h1');
      async.flushMicrotasks();
      expect(container.read(wsClientControllerProvider).status, WsStatus.disconnected);
      expect(container.read(connectControllerProvider).hosts, isEmpty);
    });
  });
}
