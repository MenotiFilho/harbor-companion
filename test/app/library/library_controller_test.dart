// Thin wiring tests for the Library controller (ticket 06). The reducer is the
// decision seam; these pin the glue: snapshot/connection/host-error folding from
// the WS client, the `command` effect drained onto the WS client as a
// `libraryAction`.

import 'dart:async';
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:harbor_companion/app/library/library_controller.dart';
import 'package:harbor_companion/app/library/library_reducer.dart';
import 'package:harbor_companion/app/ws/client_controller.dart';
import 'package:harbor_companion/app/ws/client_reducer.dart' show LibraryItem;
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

Map<String, dynamic> wireItem(String id, {String type = 'movie', String? name}) =>
    {'id': id, 'type': type, 'name': ?name};

Map<String, dynamic> snapshotFrame({
  int updatedAt = 1000,
  Map<String, dynamic>? library,
  Map<String, dynamic>? trackers,
}) {
  return {
    't': 'snapshot',
    'snapshot': {
      'proto': 1,
      'idle': true,
      'target': {'kind': 'local', 'label': 'This PC'},
      'updatedAt': updatedAt,
      'library': library,
      'trackers': trackers,
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

  Future<void> connectAndSeed(Map<String, dynamic>? library) async {
    container.read(wsClientControllerProvider.notifier).connect('192.168.1.50');
    await Future<void>.delayed(Duration.zero);
    transport.connections.single
        .emit(jsonEncode(snapshotFrame(library: library)));
    await Future<void>.delayed(Duration.zero);
  }

  test('a snapshot library folds into the view', () async {
    container = makeContainer();
    await connectAndSeed({
      'watchlist': [wireItem('tt1', name: 'Matrix')],
      'history': <Object>[],
      'favorites': <Object>[],
    });
    final s = container.read(libraryControllerProvider);
    expect(s.connected, isTrue);
    expect(s.view.watchlist.single.id, 'tt1');
    expect(s.view.emptyKind, EmptyKind.none);
    addTearDown(container.dispose);
  });

  test('a toggle drains a libraryAction command onto the WS client', () async {
    container = makeContainer();
    await connectAndSeed({
      'watchlist': [wireItem('tt1', name: 'Matrix')],
      'history': <Object>[],
      'favorites': <Object>[],
    });
    container.read(libraryControllerProvider);
    transport.connections.single.sent.clear();

    container
        .read(libraryControllerProvider.notifier)
        .toggle('watchlist', const LibraryItem('tt1', 'movie', 'Matrix', null, null), false);

    final sent = transport.connections.single.sent.single;
    final cmd = (jsonDecode(sent) as Map<String, dynamic>)['command'] as Map<String, dynamic>;
    expect(cmd['action'], 'libraryAction');
    expect(cmd['metaId'], 'tt1');
    expect(cmd['op'], {'kind': 'watchlist', 'on': false});
    addTearDown(container.dispose);
  });

  test('a host error frame rejects a pending toggle', () async {
    container = makeContainer();
    await connectAndSeed({
      'watchlist': [wireItem('tt1', name: 'Matrix')],
      'history': <Object>[],
      'favorites': <Object>[],
    });
    container.read(libraryControllerProvider);
    container
        .read(libraryControllerProvider.notifier)
        .toggle('watchlist', const LibraryItem('tt1', 'movie', 'Matrix', null, null), false);
    transport.connections.single
        .emit(jsonEncode({'t': 'error', 'message': 'invalid message'}));
    await Future<void>.delayed(Duration.zero);

    final s = container.read(libraryControllerProvider);
    expect(s.opsRejected, 1);
    expect(s.pending, isEmpty);
    addTearDown(container.dispose);
  });
}
