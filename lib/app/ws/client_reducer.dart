// Pure WS client state model for the Harbor remote surface (ticket 02).
//
// `(ClientState, ClientEvent) => ClientState` reducer plus an `outgoing`
// effects buffer the controller drains onto the socket. No I/O, no timers:
// the controller injects a clock and a transport and folds real frames back in
// as [Frame] events. Lifted from the validated ws-client prototype (#7).
//
// Wire contract: docs/wire-contract.md (beta, proto 1).

library;

import 'dart:convert';

/// Hold the last active media this long after an idle flap (episode/autoplay
/// hop) or after a socket drop before the UI falls back to idle.
const Duration stickyClear = Duration(milliseconds: 1200);
const Duration backoffFloor = Duration(milliseconds: 400);
const Duration backoffCap = Duration(milliseconds: 3000);

/// The handshake frame sent immediately on socket open.
const String helloFrame = '{"t":"hello","client":"harbor-remote","proto":1}';

enum WsStatus { disconnected, connecting, connected, reconnecting }

// ---------------------------------------------------------------------------
// Snapshot model (subset the remote surface needs)
// ---------------------------------------------------------------------------

class EpisodeRef {
  final int? season;
  final int? episode;
  final String? name;
  const EpisodeRef(this.season, this.episode, this.name);
}

class TargetInfo {
  final String kind; // "local" | "cast"
  final String label;
  const TargetInfo(this.kind, this.label);
}

class TextEntry {
  final String value;
  final String placeholder;
  const TextEntry(this.value, this.placeholder);
}

class Snapshot {
  final int proto;
  final bool idle;
  final String? mediaId;
  final String? mediaTitle;
  final String? posterUrl;
  final EpisodeRef? episode;
  final double positionSec;
  final double durationSec;
  final bool playing;
  final double volume;
  final bool muted;
  final TargetInfo target;
  final bool castDiscovering;
  final bool hasPrevEpisode;
  final bool hasNextEpisode;
  final bool subtitlesOn;
  final bool canToggleSubtitles;
  final TextEntry? textEntry;
  final String? hostVersion;
  final String? tmdbKey;
  final String? rpdbKey;
  final String? tvdbKey;
  final int updatedAt;

  const Snapshot({
    this.proto = 1,
    this.idle = true,
    this.mediaId,
    this.mediaTitle,
    this.posterUrl,
    this.episode,
    this.positionSec = 0,
    this.durationSec = 0,
    this.playing = false,
    this.volume = 1,
    this.muted = false,
    required this.target,
    this.castDiscovering = false,
    this.hasPrevEpisode = false,
    this.hasNextEpisode = false,
    this.subtitlesOn = false,
    this.canToggleSubtitles = false,
    this.textEntry,
    this.hostVersion,
    this.tmdbKey,
    this.rpdbKey,
    this.tvdbKey,
    required this.updatedAt,
  });

  factory Snapshot.fromJson(Map<String, dynamic> j) {
    final ep = j['episode'];
    final tgt = j['target'];
    final te = j['textEntry'];
    return Snapshot(
      proto: (j['proto'] as num?)?.toInt() ?? 1,
      idle: j['idle'] as bool? ?? true,
      mediaId: j['mediaId'] as String?,
      mediaTitle: j['mediaTitle'] as String?,
      posterUrl: j['posterUrl'] as String?,
      episode: ep is Map<String, dynamic>
          ? EpisodeRef(
              (ep['season'] as num?)?.toInt(),
              (ep['episode'] as num?)?.toInt(),
              ep['name'] as String?,
            )
          : null,
      positionSec: (j['positionSec'] as num?)?.toDouble() ?? 0,
      durationSec: (j['durationSec'] as num?)?.toDouble() ?? 0,
      playing: j['playing'] as bool? ?? false,
      volume: (j['volume'] as num?)?.toDouble() ?? 1,
      muted: j['muted'] as bool? ?? false,
      target: tgt is Map<String, dynamic>
          ? TargetInfo(
              tgt['kind'] as String? ?? 'local',
              tgt['label'] as String? ?? 'This PC',
            )
          : const TargetInfo('local', 'This PC'),
      castDiscovering: j['castDiscovering'] as bool? ?? false,
      hasPrevEpisode: j['hasPrevEpisode'] as bool? ?? false,
      hasNextEpisode: j['hasNextEpisode'] as bool? ?? false,
      subtitlesOn: j['subtitlesOn'] as bool? ?? false,
      canToggleSubtitles: j['canToggleSubtitles'] as bool? ?? false,
      textEntry: te is Map<String, dynamic>
          ? TextEntry(te['value'] as String? ?? '', te['placeholder'] as String? ?? '')
          : null,
      hostVersion: j['hostVersion'] as String?,
      tmdbKey: j['tmdbKey'] as String?,
      rpdbKey: j['rpdbKey'] as String?,
      tvdbKey: j['tvdbKey'] as String?,
      updatedAt: (j['updatedAt'] as num?)?.toInt() ?? 0,
    );
  }
}

// ---------------------------------------------------------------------------
// Client state
// ---------------------------------------------------------------------------

class ClientState {
  final WsStatus status;
  final bool backgrounded;
  final Duration backoff;
  final Duration? reconnectAt;
  final int reconnectAttempts;
  final Snapshot? last;
  final Snapshot? lastActive;
  final Duration? idleSince;
  final Duration? disconnectedAt;
  final int snapshotsReceived;
  final int snapshotsSkipped;
  final int droppedFrames;
  final String? lastError;
  final String? lastPongAt;
  final String? lastCommand;
  final String? hostVersion;
  final String? tmdbKey;
  final String? rpdbKey;
  final String? tvdbKey;
  final String? notice;

  /// Effects buffer: the reducer appends wire frames here; the controller
  /// drains and sends them, then clears. The one mutable field (impure by
  /// convention).
  final List<String> outgoing;

  ClientState({
    this.status = WsStatus.disconnected,
    this.backgrounded = false,
    this.backoff = backoffFloor,
    this.reconnectAt,
    this.reconnectAttempts = 0,
    this.last,
    this.lastActive,
    this.idleSince,
    this.disconnectedAt,
    this.snapshotsReceived = 0,
    this.snapshotsSkipped = 0,
    this.droppedFrames = 0,
    this.lastError,
    this.lastPongAt,
    this.lastCommand,
    this.hostVersion,
    this.tmdbKey,
    this.rpdbKey,
    this.tvdbKey,
    this.notice,
    List<String>? outgoing,
  }) : outgoing = outgoing ?? <String>[];

  ClientState copy({
    WsStatus? status,
    bool? backgrounded,
    Duration? backoff,
    Duration? reconnectAt,
    bool clearReconnectAt = false,
    int? reconnectAttempts,
    Snapshot? last,
    bool keepLast = true,
    Snapshot? lastActive,
    bool keepLastActive = true,
    Duration? idleSince,
    bool clearIdleSince = false,
    Duration? disconnectedAt,
    bool clearDisconnectedAt = false,
    int? snapshotsReceived,
    int? snapshotsSkipped,
    int? droppedFrames,
    String? lastError,
    bool clearLastError = false,
    String? lastPongAt,
    String? lastCommand,
    String? hostVersion,
    String? tmdbKey,
    String? rpdbKey,
    String? tvdbKey,
    String? notice,
    bool clearNotice = false,
    List<String>? outgoing,
  }) {
    return ClientState(
      status: status ?? this.status,
      backgrounded: backgrounded ?? this.backgrounded,
      backoff: backoff ?? this.backoff,
      reconnectAt: clearReconnectAt ? null : (reconnectAt ?? this.reconnectAt),
      reconnectAttempts: reconnectAttempts ?? this.reconnectAttempts,
      last: keepLast ? (last ?? this.last) : last,
      lastActive: keepLastActive ? (lastActive ?? this.lastActive) : lastActive,
      idleSince: clearIdleSince ? null : (idleSince ?? this.idleSince),
      disconnectedAt: clearDisconnectedAt
          ? null
          : (disconnectedAt ?? this.disconnectedAt),
      snapshotsReceived: snapshotsReceived ?? this.snapshotsReceived,
      snapshotsSkipped: snapshotsSkipped ?? this.snapshotsSkipped,
      droppedFrames: droppedFrames ?? this.droppedFrames,
      lastError: clearLastError ? null : (lastError ?? this.lastError),
      lastPongAt: lastPongAt ?? this.lastPongAt,
      lastCommand: lastCommand ?? this.lastCommand,
      hostVersion: hostVersion ?? this.hostVersion,
      tmdbKey: tmdbKey ?? this.tmdbKey,
      rpdbKey: rpdbKey ?? this.rpdbKey,
      tvdbKey: tvdbKey ?? this.tvdbKey,
      notice: clearNotice ? null : (notice ?? this.notice),
      outgoing: outgoing ?? this.outgoing,
    );
  }
}

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------

sealed class ClientEvent {
  final Duration now;
  const ClientEvent(this.now);
}

class ConnectRequested extends ClientEvent {
  const ConnectRequested(super.now);
}

class DisconnectRequested extends ClientEvent {
  const DisconnectRequested(super.now);
}

class SocketOpened extends ClientEvent {
  const SocketOpened(super.now);
}

class SocketClosed extends ClientEvent {
  final String reason;
  const SocketClosed(super.now, this.reason);
}

class Frame extends ClientEvent {
  final String raw;
  const Frame(super.now, this.raw);
}

class Tick extends ClientEvent {
  const Tick(super.now);
}

class SendCommand extends ClientEvent {
  final String action;
  final Map<String, dynamic> payload;
  const SendCommand(super.now, this.action, [this.payload = const {}]);
}

class SetBackgrounded extends ClientEvent {
  final bool value;
  const SetBackgrounded(super.now, this.value);
}

/// Re-applies host metadata keys persisted by a previous session.
class RestoreKeys extends ClientEvent {
  final String? tmdbKey;
  final String? rpdbKey;
  final String? tvdbKey;
  const RestoreKeys(super.now, this.tmdbKey, this.rpdbKey, this.tvdbKey);
}

// ---------------------------------------------------------------------------
// Command encoding (client → host, wrapped as {t:"cmd", command})
// ---------------------------------------------------------------------------

const Set<String> _known = {
  'play', 'pause', 'seek', 'setVolume', 'setMuted', 'setTarget', 'castDiscover',
  'castStop', 'prevEpisode', 'nextEpisode', 'toggleSubtitles', 'nav', 'setText',
  'submitText', 'blurText', 'openSearch', 'openMeta', 'goView', 'playMeta',
  'setSpeed', 'setSleep', 'setProfile', 'ping',
};

/// Encodes a command into a wire frame, or returns null for an unknown action.
String? encodeCommand(String action, Map<String, dynamic> payload) {
  if (!_known.contains(action)) return null;
  Map<String, dynamic> command;
  switch (action) {
    case 'seek':
      final pos = (payload['positionSec'] as num?)?.toDouble() ?? 0;
      command = {'action': 'seek', 'positionSec': pos < 0 ? 0 : pos};
    case 'setVolume':
      final v = (payload['volume'] as num?)?.toDouble() ?? 0;
      command = {'action': 'setVolume', 'volume': v.clamp(0.0, 1.0)};
    case 'setTarget':
      final t = payload['target'];
      command =
          t == 'local' ? {'action': 'setTarget', 'target': 'local'} : {'action': 'setTarget', 'castDeviceId': t};
    case 'playMeta':
      final p = Map<String, dynamic>.from(payload);
      p['resume'] = payload['resume'] ?? true;
      command = {'action': 'playMeta', ...p};
    default:
      command = {'action': action, ...payload};
  }
  return jsonEncode({'t': 'cmd', 'command': command});
}

// ---------------------------------------------------------------------------
// Reducer
// ---------------------------------------------------------------------------

Duration _nextBackoff(Duration d) {
  final doubled = d * 2;
  return doubled > backoffCap ? backoffCap : doubled;
}

ClientState clientReduce(ClientState s, ClientEvent e) {
  switch (e) {
    case ConnectRequested():
      switch (s.status) {
        case WsStatus.disconnected:
        case WsStatus.reconnecting:
          return s.copy(
            status: WsStatus.connecting,
            backoff: backoffFloor,
            clearReconnectAt: true,
            reconnectAttempts: 0,
            clearLastError: true,
            notice: 'connect requested → connecting',
          );
        default:
          return s.copy(notice: 'already ${s.status.name}');
      }

    case SocketOpened():
      if (s.status != WsStatus.connecting) {
        return s.copy(notice: 'unexpected socket open while ${s.status.name} (ignored)');
      }
      s.outgoing.add(helloFrame);
      return s.copy(
        status: WsStatus.connected,
        backoff: backoffFloor,
        reconnectAttempts: 0,
        clearDisconnectedAt: true,
        notice: 'socket open → hello sent',
      );

    case SocketClosed(reason: final reason):
      if (s.status == WsStatus.connected) {
        return s.copy(
          status: WsStatus.reconnecting,
          backoff: backoffFloor,
          reconnectAt: e.now + backoffFloor,
          reconnectAttempts: s.reconnectAttempts + 1,
          disconnectedAt: e.now,
          lastError: 'connection lost ($reason)',
          notice: 'socket closed → retry in ${backoffFloor.inMilliseconds}ms',
        );
      }
      if (s.status == WsStatus.connecting) {
        final next = _nextBackoff(s.backoff);
        return s.copy(
          status: WsStatus.reconnecting,
          backoff: next,
          reconnectAt: e.now + next,
          reconnectAttempts: s.reconnectAttempts + 1,
          disconnectedAt: s.disconnectedAt ?? e.now,
          lastError: 'connection lost ($reason)',
          notice: 'attempt failed → retry in ${next.inMilliseconds}ms',
        );
      }
      return s.copy(notice: 'close ignored (status ${s.status.name})');

    case DisconnectRequested():
      return s.copy(
        status: WsStatus.disconnected,
        clearReconnectAt: true,
        backoff: backoffFloor,
        reconnectAttempts: 0,
        clearDisconnectedAt: true,
        clearLastError: true,
        notice: 'user disconnect',
      );

    case Frame(now: final now, raw: final raw):
      return _handleFrame(s, now, raw);

    case Tick(now: final now):
      if (s.status == WsStatus.reconnecting &&
          !s.backgrounded &&
          s.reconnectAt != null &&
          now >= s.reconnectAt!) {
        return s.copy(
          status: WsStatus.connecting,
          clearReconnectAt: true,
          notice: 'reconnect attempt ${s.reconnectAttempts + 1} (backoff ${s.backoff.inMilliseconds}ms) → connecting',
        );
      }
      return s.copy(clearNotice: true);

    case SendCommand(action: final action, payload: final payload):
      if (s.status != WsStatus.connected) {
        return s.copy(
          lastError: "cannot send '$action' while ${s.status.name}",
          notice: 'command rejected',
        );
      }
      final frame = encodeCommand(action, payload);
      if (frame == null) return s.copy(lastError: "unknown command '$action'", notice: 'command rejected');
      s.outgoing.add(frame);
      return s.copy(lastCommand: frame, clearLastError: true, notice: 'sent $action');

    case SetBackgrounded(value: final value):
      return s.copy(
        backgrounded: value,
        notice: value ? 'backgrounded — retries paused' : 'foregrounded — retries resume on next tick',
      );

    case RestoreKeys(:final tmdbKey, :final rpdbKey, :final tvdbKey):
      return s.copy(
        tmdbKey: tmdbKey,
        rpdbKey: rpdbKey,
        tvdbKey: tvdbKey,
        notice: 'restored persisted host keys',
      );
  }
}

ClientState _handleFrame(ClientState s, Duration now, String raw) {
  Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } catch (_) {
    return s.copy(droppedFrames: s.droppedFrames + 1, notice: 'dropped unparseable frame');
  }
  if (decoded is! Map<String, dynamic>) {
    return s.copy(droppedFrames: s.droppedFrames + 1, notice: 'dropped non-object frame');
  }

  switch (decoded['t']) {
    case 'snapshot':
      final payload = decoded['snapshot'];
      if (payload is! Map<String, dynamic>) {
        return s.copy(droppedFrames: s.droppedFrames + 1, notice: 'snapshot frame with bad payload — dropped');
      }
      return _applySnapshot(s, now, Snapshot.fromJson(payload));

    case 'hello':
      return s.copy(notice: 'host hello: proto ${decoded['proto']} server ${decoded['server']}');

    case 'pong':
      return s.copy(lastPongAt: '${decoded['at']}', notice: 'pong received');

    case 'error':
      return s.copy(lastError: 'host error: ${decoded['message']}', notice: 'host error frame');

    default:
      return s.copy(droppedFrames: s.droppedFrames + 1, notice: 'dropped unknown frame type "${decoded['t']}"');
  }
}

ClientState _applySnapshot(ClientState s, Duration now, Snapshot snap) {
  final prev = s.last;
  if (prev != null && snap.updatedAt <= prev.updatedAt) {
    return s.copy(snapshotsSkipped: s.snapshotsSkipped + 1, notice: 'snapshot stale (updatedAt ${snap.updatedAt} ≤ ${prev.updatedAt}) — skipped');
  }

  var next = s.copy(
    last: snap,
    snapshotsReceived: s.snapshotsReceived + 1,
    clearLastError: true,
    hostVersion: snap.hostVersion ?? s.hostVersion,
    tmdbKey: snap.tmdbKey ?? s.tmdbKey,
    rpdbKey: snap.rpdbKey ?? s.rpdbKey,
    tvdbKey: snap.tvdbKey ?? s.tvdbKey,
    notice: 'snapshot ${snap.updatedAt}${snap.idle ? ' (idle)' : ''}',
  );

  if (!snap.idle) {
    next = next.copy(lastActive: snap, clearIdleSince: true);
  } else if (prev != null && !prev.idle) {
    next = next.copy(idleSince: now);
  }

  return next;
}

// ---------------------------------------------------------------------------
// Derived views
// ---------------------------------------------------------------------------

/// Status the shell/UI should report, folding the ~1.2s sticky window into
/// the raw [ClientState.status]: a connection that just dropped (whether
/// [WsStatus.reconnecting] or [WsStatus.connecting] mid-retry) still reports
/// connected until the window expires, so the last snapshot doesn't blink out.
WsStatus effectiveStatus(ClientState s, Duration now) {
  final dropped = s.status == WsStatus.reconnecting || s.status == WsStatus.connecting;
  if (dropped && s.disconnectedAt != null && now - s.disconnectedAt! < stickyClear) {
    return WsStatus.connected;
  }
  return s.status;
}

class NowPlaying {
  final bool active;
  final bool sticky;
  final String? title;
  final String? episode;
  final double positionSec;
  final double durationSec;
  final bool playing;
  final double volume;
  final bool muted;
  final String targetLabel;
  final bool hasPrevEpisode;
  final bool hasNextEpisode;
  final bool subtitlesOn;
  final TextEntry? textEntry;
  const NowPlaying({
    required this.active,
    this.sticky = false,
    this.title,
    this.episode,
    this.positionSec = 0,
    this.durationSec = 0,
    this.playing = false,
    this.volume = 1,
    this.muted = false,
    this.targetLabel = 'This PC',
    this.hasPrevEpisode = false,
    this.hasNextEpisode = false,
    this.subtitlesOn = false,
    this.textEntry,
  });
}

NowPlaying _sticky(Snapshot src) {
  return NowPlaying(
    active: true,
    sticky: true,
    title: src.mediaTitle,
    episode: src.episode?.name,
    positionSec: src.positionSec,
    durationSec: src.durationSec,
    playing: false,
    volume: src.volume,
    muted: src.muted,
    targetLabel: src.target.label,
    hasPrevEpisode: src.hasPrevEpisode,
    hasNextEpisode: src.hasNextEpisode,
    subtitlesOn: src.subtitlesOn,
    textEntry: src.textEntry,
  );
}

NowPlaying _playing(Snapshot s) {
  return NowPlaying(
    active: true,
    title: s.mediaTitle,
    episode: s.episode?.name,
    positionSec: s.positionSec,
    durationSec: s.durationSec,
    playing: s.playing,
    volume: s.volume,
    muted: s.muted,
    targetLabel: s.target.label,
    hasPrevEpisode: s.hasPrevEpisode,
    hasNextEpisode: s.hasNextEpisode,
    subtitlesOn: s.subtitlesOn,
    textEntry: s.textEntry,
  );
}

/// Derived now-playing view: what a widget renders from the client state.
///
/// - connected + non-idle → the live snapshot.
/// - connected + brief idle flap → hold [ClientState.lastActive] for the
///   sticky window (episode/autoplay hop).
/// - disconnected → hold the last snapshot for the sticky window, then idle.
/// - deliberate user disconnect → idle immediately.
NowPlaying nowPlaying(ClientState s, Duration now) {
  final last = s.last;
  if (last == null) return const NowPlaying(active: false);

  // A deliberate user disconnect drops to idle immediately.
  if (s.status == WsStatus.disconnected) return const NowPlaying(active: false);

  if (s.status == WsStatus.reconnecting || s.status == WsStatus.connecting) {
    // Dropped: hold the last snapshot for the sticky window, then drop to idle.
    final withinSticky = s.disconnectedAt != null && now - s.disconnectedAt! < stickyClear;
    return withinSticky ? _sticky(s.lastActive ?? last) : const NowPlaying(active: false);
  }

  if (last.idle) {
    // Connected but idle: hold the last active media for the sticky window.
    final src = s.lastActive;
    final withinGrace = s.idleSince != null && now - s.idleSince! < stickyClear;
    return (src != null && withinGrace) ? _sticky(src) : const NowPlaying(active: false);
  }

  return _playing(last);
}
