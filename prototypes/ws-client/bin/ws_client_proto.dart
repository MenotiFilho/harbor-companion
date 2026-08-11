// Throwaway TUI shell for the WS-client logic prototype. The shell owns the
// simulated socket + host; the logic lives in lib/client.dart and lib/host_sim.dart.

import 'dart:io';

import 'package:ws_client_proto/client.dart';
import 'package:ws_client_proto/host_sim.dart';

const _b = '\x1b[1m';
const _d = '\x1b[2m';
const _g = '\x1b[32m';
const _r = '\x1b[31m';
const _y = '\x1b[33m';
const _x = '\x1b[0m';

void main() {
  final host = HostSim();
  var client = ClientState();
  var now = Duration.zero;
  var socketUp = false;
  var notice = 'press a key (shortcuts at bottom), Enter to run';

  void step() {
    // react to connecting → simulate socket open / refused
    if (client.status == ConnStatus.connecting) {
      if (host.online) {
        socketUp = true;
        client = reduce(client, SocketOpened(now));
        host.connect();
      } else {
        socketUp = false;
        client = reduce(client, SocketClosed(now, 'host offline'));
      }
    }
    if (client.status == ConnStatus.reconnecting || client.status == ConnStatus.disconnected) {
      socketUp = false;
    }
    // drain client → host
    final toHost = List<String>.from(client.outgoing);
    client.outgoing.clear();
    for (final f in toHost) {
      host.receive(f);
    }
    // drain host → client
    final toClient = List<String>.from(host.outgoing);
    host.outgoing.clear();
    for (final f in toClient) {
      client = reduce(client, Frame(now, f));
    }
  }

  while (true) {
    stdout.write('\x1b[2J\x1b[H');
    render(client, host, now, socketUp, notice);
    stdout.write('\n> ');

    final line = stdin.readLineSync();
    if (line == null) break;
    final key = line.trim();

    switch (key) {
      case 'q':
        return;

      // --- client connection lifecycle ---
      case 'c':
        client = reduce(client, ConnectRequested(now));
        step();
        break;
      case 'x':
        client = reduce(client, DisconnectRequested(now));
        step();
        break;
      case 'b':
        client = reduce(client, SetBackgrounded(now, !client.backgrounded));
        step();
        break;

      // --- virtual clock ---
      case '+':
        now += const Duration(milliseconds: 400);
        if (socketUp) host.tick400();
        client = reduce(client, Tick(now));
        step();
        break;
      case '=':
        now += const Duration(milliseconds: 100);
        client = reduce(client, Tick(now));
        step();
        break;
      case '[':
        now += const Duration(milliseconds: 1200);
        client = reduce(client, Tick(now));
        step();
        break;

      // --- host simulation ---
      case 'o':
        host.online = !host.online;
        notice = host.online ? 'host ONLINE' : 'host OFFLINE';
        if (socketUp && !host.online) {
          client = reduce(client, SocketClosed(now, 'host went offline'));
          step();
        }
        break;
      case 'K':
        host.revokeKey();
        step();
        break;
      case 'B':
        host.burst();
        step();
        break;
      case 'W':
        host.stale();
        step();
        break;
      case 'J':
        host.garbage();
        step();
        break;
      case 'E':
        host.error('boom: picker rejected');
        step();
        break;
      case 'P':
        host.pong();
        step();
        break;

      // --- commands (only meaningful when connected) ---
      case 'e':
        client = reduce(client, SendCommand(now, 'play'));
        step();
        break;
      case 'p':
        client = reduce(client, SendCommand(now, 'pause'));
        step();
        break;
      case 'k':
        client = reduce(client, SendCommand(now, 'seek', {'positionSec': (client.last?.positionSec ?? 0) + 5}));
        step();
        break;
      case 'v':
        client = reduce(client, SendCommand(now, 'setVolume', {'volume': 0.5}));
        step();
        break;
      case 'm':
        client = reduce(client, SendCommand(now, 'setMuted', {'muted': !(client.last?.muted ?? false)}));
        step();
        break;
      case 'n':
        client = reduce(client, SendCommand(now, 'nav', {'key': 'select'}));
        step();
        break;
      case 'g':
        client = reduce(client, SendCommand(now, 'setText', {'value': 'dune'}));
        step();
        break;
      case 'u':
        client = reduce(client, SendCommand(now, 'submitText'));
        step();
        break;
      case 'S':
        client = reduce(client, SendCommand(now, 'toggleSubtitles'));
        step();
        break;
      case '<':
        client = reduce(client, SendCommand(now, 'prevEpisode'));
        step();
        break;
      case '>':
        client = reduce(client, SendCommand(now, 'nextEpisode'));
        step();
        break;
      case '.':
        client = reduce(client, SendCommand(now, 'ping'));
        step();
        break;
      case 'f':
        client = reduce(client, SendCommand(now, 'playMeta', {'metaId': 'tt1234567', 'metaType': 'movie', 'name': 'Dune: Part Two', 'resume': true}));
        step();
        break;

      default:
        notice = 'unknown key: "$key"';
    }
  }
}

void render(ClientState s, HostSim host, Duration now, bool socketUp, String notice) {
  final np = nowPlaying(s, now);

  print('${_b}HARBOR REMOTE — WS CLIENT PROTOTYPE$_x  ${_d}(throwaway)$_x');
  print('${_d}┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈$_x');

  // connection
  final statusColor = switch (s.status) {
    ConnStatus.connected => _g,
    ConnStatus.reconnecting => _y,
    _ => _x,
  };
  print('${_b}connection$_x      ${statusColor}${s.status.name.toUpperCase()}$_x  '
      'socket=${socketUp ? 'up' : 'down'}  '
      'host=${host.online ? 'online' : 'OFFLINE'}  '
      'backgrounded=${s.backgrounded ? 'yes' : 'no'}  '
      '${_d}virtual time ${now.inSeconds}s${_x}');
  if (s.status == ConnStatus.reconnecting) {
    print('${_b}reconnect$_x      backoff=${_y}${s.backoff.inMilliseconds}ms$_x  '
        'attempt ${s.reconnectAttempts}  next at ${s.reconnectAt?.inMilliseconds ?? '?'}ms  '
        '${_d}(advance clock with +/=/[)$_x');
  }

  // now playing
  print('${_b}now playing$_x');
  if (!np.active) {
    print('  ${_d}— nothing playing / idle —$_x');
  } else {
    print('  ${np.sticky ? '${_y}[sticky: idle flap, holding last media]$_x ' : ''}'
        '${_b}${np.title ?? '?'}$_x');
    if (np.episode != null) print('  ${_d}episode $_x${np.episode}');
    final pos = fmtSec(np.positionSec);
    final dur = fmtSec(np.durationSec);
    print('  ${_b}${np.playing ? '▶' : '⏸'}$_x $pos / $dur  '
        '${np.muted ? _y : ''}vol ${(np.volume * 100).round()}%${np.muted ? ' (muted)' : ''}$_x  '
        'subs ${np.subtitlesOn ? 'on' : 'off'}');
    print('  ${_d}target$_x ${np.targetLabel}  '
        '${np.hasPrevEpisode ? '←' : '${_d}←$_x'} ${np.hasNextEpisode ? '→' : '${_d}→$_x'} episode');
    if (np.textEntry != null) {
      print('  ${_y}textEntry active: "${np.textEntry!.value}" (${np.textEntry!.placeholder})$_x');
    }
  }

  // snapshot / coalescing
  print('${_b}snapshot$_x');
  final last = s.last;
  if (last == null) {
    print('  ${_d}no snapshot yet — connect first (c)$_x');
  } else {
    print('  updatedAt=${last.updatedAt}  idle=${last.idle}  '
        'received=${_g}${s.snapshotsReceived}$_x  skipped=${_y}${s.snapshotsSkipped}$_x  '
        'dropped=${_r}${s.droppedFrames}$_x');
    print('  ${_d}keys: tmdbKey=${s.tmdbKey ?? '—'}  hostVersion=${s.hostVersion ?? '—'}$_x');
    print('  ${_d}library watchlist=${last.library?.watchlist ?? '?'} '
        'history=${last.library?.history ?? '?'} favorites=${last.library?.favorites ?? '?'}'
        '  cast devices=${last.castDevices.length} $_x');
  }

  // errors / recent
  if (s.lastError != null) print('${_r}error: ${s.lastError}$_x');
  if (s.lastPongAt != null) print('${_d}last pong at ${s.lastPongAt}$_x');
  if (s.lastCommand != null) print('${_d}last cmd sent: ${s.lastCommand}$_x');

  // host log
  print('${_b}host command log$_x ${_d}(simulated PC)$_x');
  if (host.commandLog.isEmpty) {
    print('  ${_d}no commands received yet$_x');
  } else {
    for (final c in host.commandLog) {
      print('  ${_d}→$_x $c');
    }
  }

  // notice
  if (notice.isNotEmpty) print('${_y}• $_x$notice');

  print('${_d}┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈$_x');
  print('${_b}c$_x connect  ${_b}x$_x disconnect  ${_b}b$_x background  '
      '${_b}o$_x host on/off  ${_b}K$_x revoke key');
  print('${_b}+$_x 400ms tick (host snap)  ${_b}=$_x 100ms  ${_b}[$_x 1200ms  '
      '${_b}B$_x burst  ${_b}W$_x stale  ${_b}J$_x garbage  ${_b}E$_x error  ${_b}P$_x pong');
  print('${_b}e$_x play  ${_b}p$_x pause  ${_b}k$_x seek+5  ${_b}v$_x vol.5  ${_b}m$_x mute  '
      '${_b}n$_x nav  ${_b}g$_x setText  ${_b}u$_x submit  ${_b}S$_x subs  '
      '${_b}<$_x/${_b}>$_x prev/next ep  ${_b}.$_x ping  ${_b}f$_x playMeta  ${_b}q$_x quit');
}

String fmtSec(double s) {
  final total = s.round();
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final sec = total % 60;
  final mm = m.toString().padLeft(2, '0');
  final ss = sec.toString().padLeft(2, '0');
  return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
}
