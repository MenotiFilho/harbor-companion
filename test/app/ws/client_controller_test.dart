// Thin wiring tests for the WS client controller (ticket 02). The reducer is
// the decision seam; these pin the glue: URL building, hello-on-open, frame
// folding, key persistence, reconnect timer ownership, backgrounding pause,
// and the shell connection-status mirror.

import 'dart:async';

import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

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
  int saves = 0;
  @override
  Future<HostKeys> load() async => keys;
  @override
  Future<void> save(HostKeys k) async {
    keys = k;
    saves++;
  }
}

void main() {
  late FakeTransport transport;
  late FakeKeyStore keyStore;
  late ProviderContainer container;

  /// The ws clock is zone-scoped: real time in plain tests, fake time inside
  /// `fakeAsync` (advances with `async.elapse`).
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

  WsClientController controller() => container.read(wsClientControllerProvider.notifier);

  test('remoteWsUrl builds the api/remote URL and assumes port 11471', () {
    expect(remoteWsUrl('192.168.1.50'), 'ws://192.168.1.50:11471/api/remote');
    expect(remoteWsUrl('192.168.1.50:9000'), 'ws://192.168.1.50:9000/api/remote');
    expect(remoteWsUrl(' http://10.0.0.5 '), 'ws://10.0.0.5:11471/api/remote');
  });

  test('connect opens the socket and sends hello on open', () async {
    container = makeContainer();
    final c = controller();
    c.connect('192.168.1.50');
    await Future<void>.delayed(Duration.zero);
    expect(transport.openedUrls, ['ws://192.168.1.50:11471/api/remote']);
    final conn = transport.connections.single;
    expect(conn.sent, ['{"t":"hello","client":"harbor-remote","proto":1}']);
    expect(container.read(wsClientControllerProvider).status, WsStatus.connected);
    addTearDown(container.dispose);
  });

  test('inbound frames fold into the reducer state', () async {
    container = makeContainer();
    controller().connect('192.168.1.50');
    await Future<void>.delayed(Duration.zero);
    final conn = transport.connections.single;
    conn.emit('{"t":"snapshot","snapshot":{"proto":1,"idle":true,"updatedAt":1000}}');
    await Future<void>.delayed(Duration.zero);
    final s = container.read(wsClientControllerProvider);
    expect(s.last, isNotNull);
    expect(s.last!.updatedAt, 1000);
    addTearDown(container.dispose);
  });

  test('keys from snapshots are persisted to the key store', () async {
    container = makeContainer();
    controller().connect('192.168.1.50');
    await Future<void>.delayed(Duration.zero);
    transport.connections.single.emit(
      '{"t":"snapshot","snapshot":{"proto":1,"idle":true,"updatedAt":1000,"tmdbKey":"tmdb-x"}}',
    );
    await Future<void>.delayed(Duration.zero);
    expect(keyStore.keys.tmdbKey, 'tmdb-x');
    expect(container.read(wsClientControllerProvider).tmdbKey, 'tmdb-x');
    addTearDown(container.dispose);
  });

  test('restored persisted keys seed the state on build', () async {
    keyStore = FakeKeyStore()..keys = const HostKeys(tmdbKey: 'tmdb-restored');
    transport = FakeTransport();
    container = ProviderContainer(
      overrides: [
        wsTransportProvider.overrideWithValue(transport),
        wsKeyStoreProvider.overrideWithValue(keyStore),
        wsClockProvider.overrideWithValue(wsNow),
      ],
    );
    // Reading the provider triggers build(), which kicks off the async restore.
    container.read(wsClientControllerProvider);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(container.read(wsClientControllerProvider).tmdbKey, 'tmdb-restored');
    addTearDown(container.dispose);
  });

  test('a socket close arms the reconnect timer, which reopens the socket', () {
    fakeAsync((async) {
      container = makeContainer();
      controller().connect('192.168.1.50');
      async.flushMicrotasks();
      final conn = transport.connections.single;
      conn.emit('{"t":"snapshot","snapshot":{"proto":1,"idle":true,"updatedAt":1000}}');
      async.flushMicrotasks();
      conn.close();
      async.flushMicrotasks();
      var s = container.read(wsClientControllerProvider);
      expect(s.status, WsStatus.reconnecting);
      // backoff floor is 400ms: nothing before, reopen after.
      async.elapse(const Duration(milliseconds: 399));
      expect(transport.openedUrls, hasLength(1));
      async.elapse(const Duration(milliseconds: 1));
      async.flushMicrotasks();
      expect(transport.openedUrls, hasLength(2));
      s = container.read(wsClientControllerProvider);
      expect(s.status, WsStatus.connected); // the reopen succeeded
    });
  });

  test('reconnect timer is cancelled while backgrounded', () {
    fakeAsync((async) {
      container = makeContainer();
      controller().connect('192.168.1.50');
      async.flushMicrotasks();
      transport.connections.single.close();
      async.flushMicrotasks();
      controller().setBackgrounded(true);
      async.elapse(const Duration(seconds: 30));
      expect(transport.openedUrls, hasLength(1));
    });
  });

  test('foregrounding resumes the reconnect timer', () {
    fakeAsync((async) {
      container = makeContainer();
      controller().connect('192.168.1.50');
      async.flushMicrotasks();
      transport.connections.single.close();
      async.flushMicrotasks();
      controller().setBackgrounded(true);
      async.elapse(const Duration(seconds: 5));
      controller().setBackgrounded(false);
      async.flushMicrotasks();
      async.elapse(const Duration(milliseconds: 400));
      async.flushMicrotasks();
      expect(transport.openedUrls, hasLength(2));
    });
  });

  test('commands while connected are sent; while disconnected are not', () async {
    container = makeContainer();
    controller().connect('192.168.1.50');
    await Future<void>.delayed(Duration.zero);
    final conn = transport.connections.single;
    conn.sent.clear();
    controller().sendCommand('play');
    expect(conn.sent, ['{"t":"cmd","command":{"action":"play"}}']);

    controller().disconnect();
    await Future<void>.delayed(Duration.zero);
    controller().sendCommand('pause');
    expect(conn.sent, hasLength(1), reason: 'never queued while disconnected');
    expect(container.read(wsClientControllerProvider).lastError, contains('cannot send'));
  });

  test('the shell connection-status seam mirrors the effective status', () {
    fakeAsync((async) {
      container = makeContainer();
      expect(container.read(connectionStatusProvider), ConnectionStatus.disconnected);
      controller().connect('192.168.1.50');
      async.flushMicrotasks();
      expect(container.read(connectionStatusProvider), ConnectionStatus.connected);

      // Host goes away: the reopen attempt must fail so we stay reconnecting.
      transport.failOpen = true;
      transport.connections.single.close();
      async.flushMicrotasks();
      // Within the sticky window the seam still reports connected.
      expect(container.read(connectionStatusProvider), ConnectionStatus.connected);
      // Past the sticky window it reports connecting (reconnecting).
      async.elapse(const Duration(seconds: 2));
      expect(container.read(connectionStatusProvider), ConnectionStatus.connecting);
    });
  });
}
