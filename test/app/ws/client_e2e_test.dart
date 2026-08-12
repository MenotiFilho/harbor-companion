// End-to-end wiring check: the real dart:io transport + controller against an
// in-process simulated Harbor host (the 400ms snapshot tick, hello handshake,
// and a command echo). This is the headless stand-in for the live conformance
// harness (bin/live_check.dart); it proves the glue works over an actual socket
// without needing a beta host on the LAN.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:harbor_companion/app/ws/client_controller.dart';
import 'package:harbor_companion/app/ws/client_reducer.dart';
import 'package:harbor_companion/app/ws/ws_transport.dart';

/// Minimal host simulator over a real WebSocket: replies to hello, pushes a
/// snapshot every 400ms, and echoes `play` by flipping the snapshot's playing
/// flag in the next push.
class SimulatedHost {
  final HttpServer _server;
  final List<WebSocket> _clients = [];
  Timer? _ticker;
  int _updatedAt = 1000;
  bool _playing = false;
  String? _title;

  SimulatedHost._(this._server);

  static Future<SimulatedHost> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final host = SimulatedHost._(server);
    server.listen((req) async {
      if (req.uri.path == '/api/remote' && WebSocketTransformer.isUpgradeRequest(req)) {
        final ws = await WebSocketTransformer.upgrade(req);
        host._clients.add(ws);
        ws.listen((data) => host._onMessage(ws, data as String));
      } else {
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
      }
    });
    return host;
  }

  int get port => _server.port;

  void _onMessage(WebSocket ws, String raw) {
    final m = jsonDecode(raw) as Map<String, dynamic>;
    if (m['t'] == 'hello') {
      ws.add(jsonEncode({'t': 'hello', 'proto': 1, 'server': 'harbor-remote'}));
      _push();
      _ticker ??= Timer.periodic(const Duration(milliseconds: 400), (_) => _push());
    } else if (m['t'] == 'cmd') {
      final cmd = m['command'] as Map<String, dynamic>;
      if (cmd['action'] == 'play') _playing = true;
      if (cmd['action'] == 'pause') _playing = false;
      if (cmd['action'] == 'playMeta') {
        _playing = true;
        _title = cmd['name'] as String? ?? 'Meta';
      }
      _push();
    }
  }

  void _push() {
    _updatedAt += 400;
    final frame = jsonEncode({
      't': 'snapshot',
      'snapshot': {
        'proto': 1,
        'idle': !_playing,
        'mediaId': _playing ? 'tt0000001' : null,
        'mediaTitle': _playing ? _title : null,
        'positionSec': _playing ? 12.0 : 0,
        'durationSec': 5400,
        'playing': _playing,
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
        'hostVersion': '0.9.118',
        'tmdbKey': 'tmdb-e2e',
        'updatedAt': _updatedAt,
      },
    });
    for (final c in _clients) {
      c.add(frame);
    }
  }

  Future<void> stop() async {
    _ticker?.cancel();
    for (final c in _clients) {
      await c.close();
    }
    await _server.close(force: true);
  }
}

void main() {
  test('controller talks to a simulated host over a real socket', () async {
    final host = await SimulatedHost.start();
    addTearDown(host.stop);

    final container = ProviderContainer(
      overrides: [
        wsTransportProvider.overrideWithValue(IoWsTransport()),
      ],
    );
    addTearDown(container.dispose);

    final notifier = container.read(wsClientControllerProvider.notifier);
    notifier.connect('127.0.0.1:${host.port}');

    // Wait for the first snapshot on the 400ms tick.
    var state = container.read(wsClientControllerProvider);
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while ((state.last == null) && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      state = container.read(wsClientControllerProvider);
    }

    expect(state.status, WsStatus.connected, reason: 'handshake completed');
    expect(state.last, isNotNull, reason: 'first snapshot arrived');
    expect(state.last!.hostVersion, '0.9.118');
    expect(state.tmdbKey, 'tmdb-e2e', reason: 'key piped and applied');
    expect(state.snapshotsSkipped, 0, reason: 'no stale frames in a single-client session');

    // A command round-trips and the next snapshot reflects it.
    notifier.sendCommand('play');
    final t1 = DateTime.now();
    while (!(container.read(wsClientControllerProvider).last?.playing ?? false) &&
        DateTime.now().difference(t1) < const Duration(seconds: 5)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(container.read(wsClientControllerProvider).last!.playing, isTrue,
        reason: 'host echoed the play command into a snapshot');

    // Coalescing: the ticker is still pushing, but each frame is newer so the
    // client stays on the latest one without error.
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final s = container.read(wsClientControllerProvider);
    expect(s.status, WsStatus.connected);
    expect(s.snapshotsReceived, greaterThanOrEqualTo(2));
    expect(s.lastError, isNull);
  });
}
