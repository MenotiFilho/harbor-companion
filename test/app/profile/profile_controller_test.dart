// Thin wiring tests for the Profile controller (ticket 08). The reducer is the
// decision seam; these pin the glue: snapshot folding from the WS client (the
// profile + profiles fields), the `command` effect drained onto the WS client
// as a `setProfile`, and the connection-status folding.

import 'dart:async';
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:harbor_companion/app/profile/profile_controller.dart';
import 'package:harbor_companion/app/profile/profile_reducer.dart';
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
  Map<String, dynamic>? profile,
  List<Map<String, dynamic>>? profiles,
}) {
  return {
    't': 'snapshot',
    'snapshot': {
      'proto': 1,
      'idle': true,
      'target': {'kind': 'local', 'label': 'This PC'},
      'profile': profile,
      'profiles': profiles ?? <Map<String, dynamic>>[],
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

  Future<void> connectAndSeed(
    Map<String, dynamic>? profile,
    List<Map<String, dynamic>> profiles,
  ) async {
    container.read(wsClientControllerProvider.notifier).connect('192.168.1.50');
    await Future<void>.delayed(Duration.zero);
    transport.connections.single
        .emit(jsonEncode(snapshotFrame(profile: profile, profiles: profiles)));
    await Future<void>.delayed(Duration.zero);
  }

  test('snapshot profiles fold into the view with the active id', () async {
    container = makeContainer();
    await connectAndSeed(
      {'id': 'dad', 'name': 'Dad'},
      [
        {'id': 'dad', 'name': 'Dad', 'color': '#ff0000'},
        {'id': 'kid', 'name': 'Kid', 'avatar': 'https://img/k.png'},
      ],
    );
    final s = container.read(profileControllerProvider);
    expect(s.connected, isTrue);
    expect(s.view.profiles, hasLength(2));
    expect(s.view.activeId, 'dad');
    expect(s.view.emptyKind, ProfileEmptyKind.none);
    addTearDown(container.dispose);
  });

  test('select drains a setProfile command onto the WS client', () async {
    container = makeContainer();
    await connectAndSeed(
      {'id': 'dad', 'name': 'Dad'},
      [
        {'id': 'dad', 'name': 'Dad'},
        {'id': 'kid', 'name': 'Kid'},
      ],
    );
    container.read(profileControllerProvider);
    transport.connections.single.sent.clear();

    container.read(profileControllerProvider.notifier).select('kid');

    final sent = transport.connections.single.sent.single;
    final cmd = (jsonDecode(sent) as Map<String, dynamic>)['command'] as Map<String, dynamic>;
    expect(cmd['action'], 'setProfile');
    expect(cmd['id'], 'kid');
    addTearDown(container.dispose);
  });

  test('the next snapshot reflecting the active profile updates the view',
      () async {
    container = makeContainer();
    await connectAndSeed(
      {'id': 'dad', 'name': 'Dad'},
      [
        {'id': 'dad', 'name': 'Dad'},
        {'id': 'kid', 'name': 'Kid'},
      ],
    );
    container.read(profileControllerProvider);
    container.read(profileControllerProvider.notifier).select('kid');
    transport.connections.single.sent.clear();

    // The host reflects the switch in the next snapshot.
    transport.connections.single.emit(jsonEncode(snapshotFrame(
      updatedAt: 1400,
      profile: {'id': 'kid', 'name': 'Kid'},
      profiles: [
        {'id': 'dad', 'name': 'Dad'},
        {'id': 'kid', 'name': 'Kid'},
      ],
    )));
    await Future<void>.delayed(Duration.zero);

    final s = container.read(profileControllerProvider);
    expect(s.view.activeId, 'kid');
    addTearDown(container.dispose);
  });

  test('select while disconnected is honestly rejected (raw status)', () async {
    container = makeContainer();
    container.read(profileControllerProvider);
    container.read(profileControllerProvider.notifier).select('kid');

    final s = container.read(profileControllerProvider);
    expect(s.notice, contains('Not connected'));
    expect(transport.connections, isEmpty);
    addTearDown(container.dispose);
  });
}
