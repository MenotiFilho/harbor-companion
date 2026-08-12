// Live conformance harness for the WS client (ticket 02).
//
// Connects to a REAL Harbor beta host (v0.9.118) and verifies the facts the
// reducer's tests pin, against the actual wire — the same pattern as the
// library prototype's live_check.dart:
//
//   1. Handshake — ws://<ip>:11471/api/remote, hello {client:"harbor-remote",
//      proto:1}, host replies hello + snapshot.
//   2. Snapshot shape — proto==1, keys present when configured, `updatedAt`
//      monotonic, `hostVersion`.
//   3. Cadence — snapshots really do arrive on ~400ms.
//   4. Coalescing — feeding the raw frames through `clientReduce()` skips stale
//      frames and never sends a second hello or any castDiscover.
//
// READ-ONLY. It only sends hello and (optionally) a ping; it never issues
// playback or library commands.
//
// Usage:
//   dart run bin/live_check.dart [--host localhost] [--port 11471]
//                                 [--snapshots 6] [--timeout 10] [--ping]

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:harbor_companion/app/ws/client_reducer.dart';

String _arg(List<String> args, String name, {required String def}) {
  final i = args.indexOf(name);
  if (i == -1 || i + 1 >= args.length) return def;
  return args[i + 1];
}

Future<void> main(List<String> args) async {
  final host = _arg(args, '--host', def: 'localhost');
  final port = int.parse(_arg(args, '--port', def: '11471'));
  final wantSnapshots = int.parse(_arg(args, '--snapshots', def: '6'));
  final timeout = int.parse(_arg(args, '--timeout', def: '10'));
  final doPing = args.contains('--ping');

  final url = 'ws://$host:$port/api/remote';
  stdout.writeln('live-check: connecting $url');
  final WebSocket ws;
  try {
    ws = await WebSocket.connect(url).timeout(const Duration(seconds: 8));
  } catch (e) {
    stdout.writeln('  FAIL  could not connect — is a beta host (v0.9.118) running at $url?');
    stdout.writeln('  $e');
    exit(1);
  }
  final it = StreamIterator(ws);

  Future<Map<String, dynamic>?> nextFrame() async {
    if (await it.moveNext()) {
      final raw = it.current as String;
      try {
        return jsonDecode(raw) as Map<String, dynamic>;
      } catch (_) {
        stdout.writeln(
            '  (unparseable frame: ${raw.length > 80 ? '${raw.substring(0, 80)}…' : raw})');
        return nextFrame();
      }
    }
    return null;
  }

  final pass = <String>[];
  final fail = <String>[];
  void check(String name, bool ok, [String? detail]) {
    (ok ? pass : fail).add(name);
    stdout.writeln('  ${ok ? 'PASS' : 'FAIL'}  $name${detail != null ? ' — $detail' : ''}');
  }

  Map<String, dynamic> snapOf(Map<String, dynamic> f) =>
      (f['snapshot'] ?? f) as Map<String, dynamic>;

  stdout.writeln('sending hello {t:"hello", client:"harbor-remote", proto:1}');
  ws.add(jsonEncode({'t': 'hello', 'client': 'harbor-remote', 'proto': 1}));

  final firstFrame = await nextFrame();
  check('host replies within timeout', firstFrame != null,
      firstFrame == null ? 'no frame received' : 'first frame t=${firstFrame['t']}');

  final snapshots = <Map<String, dynamic>>[];
  final deadline = DateTime.now().add(Duration(seconds: timeout));
  stdout.writeln('collecting $wantSnapshots snapshot(s) on the 400ms tick…');
  while (snapshots.length < wantSnapshots && DateTime.now().isBefore(deadline)) {
    final f = await nextFrame();
    if (f == null) break;
    if (f['t'] == 'snapshot') snapshots.add(f);
  }
  check('got $wantSnapshots snapshot(s)', snapshots.length == wantSnapshots,
      'saw ${snapshots.length} within ${timeout}s');

  if (snapshots.isNotEmpty) {
    final s = snapOf(snapshots.last);
    check('proto == 1', s['proto'] == 1, 'proto=${s['proto']}');
    check('hostVersion present', s['hostVersion'] is String,
        'hostVersion=${s['hostVersion']}');
    check('updatedAt monotonic', () {
      if (snapshots.length < 2) return false;
      for (var i = 1; i < snapshots.length; i++) {
        final a = snapOf(snapshots[i - 1])['updatedAt'];
        final b = snapOf(snapshots[i])['updatedAt'];
        if (a is! num || b is! num || b <= a) return false;
      }
      return true;
    }());
    final keys = <String>[
      for (final k in ['tmdbKey', 'rpdbKey', 'tvdbKey'])
        if (s[k] is String && (s[k] as String).isNotEmpty) k
    ];
    check('host keys piped (present when configured)', keys.isNotEmpty,
        keys.isEmpty ? 'none present' : 'present: ${keys.join(', ')}');

    // Cadence: time a few ticks.
    final t0 = DateTime.now();
    var ticks = 0;
    while (ticks < 3 && DateTime.now().isBefore(deadline)) {
      final f = await nextFrame();
      if (f != null && f['t'] == 'snapshot') ticks++;
    }
    final dt = DateTime.now().difference(t0).inMilliseconds / ticks;
    check('snapshot cadence ≈400ms', dt < 700, 'avg ${dt.toStringAsFixed(0)}ms across $ticks ticks');
  }

  // Reduce every frame through the pure client model: coalescing must keep the
  // newest snapshot, hello must be the only auto-sent frame, and no
  // castDiscover may ever be issued.
  var now = Duration.zero;
  // Replay the frames we captured (hello reply + snapshots).
  final allFrames = [
    firstFrame,
    ...snapshots,
  ].whereType<Map<String, dynamic>>().toList();
  final reduced = _driveFrames(allFrames, now);
  check('reducer applied ${reduced.snapshotsReceived} snapshot(s)',
      reduced.snapshotsReceived >= wantSnapshots,
      'received ${reduced.snapshotsReceived} skipped ${reduced.snapshotsSkipped}');
  check('no stale frames skipped on a healthy single client', reduced.snapshotsSkipped == 0,
      'skipped ${reduced.snapshotsSkipped}');
  final framesSent = _drainSent(reduced);
  check('never auto-sends castDiscover', framesSent.every((f) => !f.contains('castDiscover')));
  check('no duplicate hello in the reducer output',
      framesSent.where((f) => f.contains('"t":"hello"')).length <= 1);

  if (doPing) {
    ws.add(jsonEncode({'t': 'cmd', 'command': {'action': 'ping'}}));
    final pong = await nextFrame();
    check('ping answered with pong', pong?['t'] == 'pong',
        pong == null ? 'no frame' : 'frame t=${pong['t']}');
  }

  await ws.close();
  stdout.writeln('''
  ── summary ─────────────────────────────────
  PASS ${pass.length}   FAIL ${fail.length}
  ${fail.isEmpty ? 'all wire facts hold — the WS client model matches the real host' : 'FAILED: ${fail.join(' · ')}'}
  ''');
  exit(fail.isEmpty ? 0 : 1);
}

/// Feeds frames through `clientReduce()` with a virtual clock, returning the final
/// state.
ClientState _driveFrames(List<Map<String, dynamic>> frames, Duration start) {
  var s = ClientState();
  // connect + open so the client is ready to accept frames
  s = clientReduce(s, ConnectRequested(start));
  s = clientReduce(s, SocketOpened(start));
  _drainSent(s);
  var now = start;
  for (final f in frames) {
    now += const Duration(milliseconds: 100);
    s = clientReduce(s, Frame(now, jsonEncode(f)));
  }
  return s;
}

List<String> _drainSent(ClientState s) {
  final sent = List<String>.from(s.outgoing);
  s.outgoing.clear();
  return sent;
}
