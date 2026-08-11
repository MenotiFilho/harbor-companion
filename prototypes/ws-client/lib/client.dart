// Throwaway logic prototype — Harbor remote WS client state model.
//
// QUESTION THIS PROTOTYPE ANSWERS:
//   Does the WS-client state model feel right? Connection lifecycle (reconnect
//   with exponential backoff, backgrounding), snapshot coalescing on updatedAt,
//   command dispatch semantics, and the derived now-playing surface (incl.
//   sticky-idle through episode hops). Not the visuals.
//
// This module is PURE and portable: no I/O, no timers, no terminal code. It is a
// reducer `(ClientState, ClientEvent) => ClientState`. The one impurity is the
// `outgoing` effects buffer: the reducer appends wire frames the shell must send,
// and the shell drains it. Lift this file into the real app's WS layer when the
// shape is validated.
//
// Wire contract: docs/wire-contract.md (beta, proto 1).

library;

import 'dart:convert';

const Duration stickyClear = Duration(milliseconds: 1200);
const Duration backoffFloor = Duration(milliseconds: 400);
const Duration backoffCap = Duration(milliseconds: 3000);

enum ConnStatus { disconnected, connecting, connected, reconnecting }

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

class LibrarySummary {
  final int watchlist;
  final int history;
  final int favorites;
  const LibrarySummary(this.watchlist, this.history, this.favorites);
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
  final List<String> castDevices;
  final bool castDiscovering;
  final bool hasPrevEpisode;
  final bool hasNextEpisode;
  final bool subtitlesOn;
  final bool canToggleSubtitles;
  final TextEntry? textEntry;
  final String? hostVersion;
  final String? tmdbKey;
  final LibrarySummary? library;
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
    this.castDevices = const [],
    this.castDiscovering = false,
    this.hasPrevEpisode = false,
    this.hasNextEpisode = false,
    this.subtitlesOn = false,
    this.canToggleSubtitles = false,
    this.textEntry,
    this.hostVersion,
    this.tmdbKey,
    this.library,
    required this.updatedAt,
  });

  factory Snapshot.fromJson(Map<String, dynamic> j) {
    final ep = j['episode'];
    final tgt = j['target'];
    final te = j['textEntry'];
    final lib = j['library'];
    final devices = j['castDevices'];
    return Snapshot(
      proto: (j['proto'] as num?)?.toInt() ?? 1,
      idle: j['idle'] as bool? ?? true,
      mediaId: j['mediaId'] as String?,
      mediaTitle: j['mediaTitle'] as String?,
      posterUrl: j['posterUrl'] as String?,
      episode: ep is Map<String, dynamic>
          ? EpisodeRef((ep['season'] as num?)?.toInt(), (ep['episode'] as num?)?.toInt(), ep['name'] as String?)
          : null,
      positionSec: (j['positionSec'] as num?)?.toDouble() ?? 0,
      durationSec: (j['durationSec'] as num?)?.toDouble() ?? 0,
      playing: j['playing'] as bool? ?? false,
      volume: (j['volume'] as num?)?.toDouble() ?? 1,
      muted: j['muted'] as bool? ?? false,
      target: tgt is Map<String, dynamic>
          ? TargetInfo(tgt['kind'] as String? ?? 'local', tgt['label'] as String? ?? 'This PC')
          : const TargetInfo('local', 'This PC'),
      castDevices: devices is List ? devices.whereType<String>().toList() : const [],
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
      library: lib is Map<String, dynamic>
          ? LibrarySummary(
              (lib['watchlist'] as num?)?.toInt() ?? 0,
              (lib['history'] as num?)?.toInt() ?? 0,
              (lib['favorites'] as num?)?.toInt() ?? 0)
          : null,
      updatedAt: (j['updatedAt'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
        'proto': proto,
        'idle': idle,
        'mediaId': mediaId,
        'mediaTitle': mediaTitle,
        'posterUrl': posterUrl,
        'episode': episode == null
            ? null
            : {'season': episode!.season, 'episode': episode!.episode, 'name': episode!.name},
        'positionSec': positionSec,
        'durationSec': durationSec,
        'playing': playing,
        'volume': volume,
        'muted': muted,
        'target': {'kind': target.kind, 'label': target.label},
        'castDevices': castDevices,
        'castDiscovering': castDiscovering,
        'hasPrevEpisode': hasPrevEpisode,
        'hasNextEpisode': hasNextEpisode,
        'subtitlesOn': subtitlesOn,
        'canToggleSubtitles': canToggleSubtitles,
        'textEntry': textEntry == null ? null : {'value': textEntry!.value, 'placeholder': textEntry!.placeholder},
        'hostVersion': hostVersion,
        'tmdbKey': tmdbKey,
        'library': library == null
            ? null
            : {'watchlist': library!.watchlist, 'history': library!.history, 'favorites': library!.favorites},
        'updatedAt': updatedAt,
      };
}

// ---------------------------------------------------------------------------
// Client state
// ---------------------------------------------------------------------------

class ClientState {
  final ConnStatus status;
  final bool backgrounded;
  final Duration backoff; // current reconnect delay (relevant while reconnecting)
  final Duration? reconnectAt; // virtual time the next attempt fires
  final int reconnectAttempts;
  final Snapshot? last; // coalesced latest snapshot
  final Snapshot? lastActive; // last snapshot with idle == false (for sticky idle)
  final Duration? idleSince; // virtual time idle went true
  final int snapshotsReceived;
  final int snapshotsSkipped; // dropped as stale/duplicate by updatedAt
  final int droppedFrames; // unparseable / unknown frames
  final String? lastError;
  final String? lastPongAt;
  final String? lastCommand; // last encoded command frame sent
  final String? hostVersion;
  final String? tmdbKey;
  final String? notice; // transient message for the shell to show

  // Effects buffer: the reducer appends wire frames here; the shell drains and
  // sends them, then clears. The one mutable field (impure by convention).
  final List<String> outgoing;

  ClientState({
    this.status = ConnStatus.disconnected,
    this.backgrounded = false,
    this.backoff = backoffFloor,
    this.reconnectAt,
    this.reconnectAttempts = 0,
    this.last,
    this.lastActive,
    this.idleSince,
    this.snapshotsReceived = 0,
    this.snapshotsSkipped = 0,
    this.droppedFrames = 0,
    this.lastError,
    this.lastPongAt,
    this.lastCommand,
    this.hostVersion,
    this.tmdbKey,
    this.notice,
    List<String>? outgoing,
  }) : outgoing = outgoing ?? <String>[];

  ClientState copy({
    ConnStatus? status,
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
    int? snapshotsReceived,
    int? snapshotsSkipped,
    int? droppedFrames,
    String? lastError,
    bool clearLastError = false,
    String? lastPongAt,
    String? lastCommand,
    String? hostVersion,
    String? tmdbKey,
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
      snapshotsReceived: snapshotsReceived ?? this.snapshotsReceived,
      snapshotsSkipped: snapshotsSkipped ?? this.snapshotsSkipped,
      droppedFrames: droppedFrames ?? this.droppedFrames,
      lastError: clearLastError ? null : (lastError ?? this.lastError),
      lastPongAt: lastPongAt ?? this.lastPongAt,
      lastCommand: lastCommand ?? this.lastCommand,
      hostVersion: hostVersion ?? this.hostVersion,
      tmdbKey: tmdbKey ?? this.tmdbKey,
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
  const ConnectRequested(Duration now) : super(now);
}

class DisconnectRequested extends ClientEvent {
  const DisconnectRequested(Duration now) : super(now);
}

class SocketOpened extends ClientEvent {
  const SocketOpened(Duration now) : super(now);
}

class SocketClosed extends ClientEvent {
  final String reason;
  const SocketClosed(Duration now, this.reason) : super(now);
}

class Frame extends ClientEvent {
  final String raw;
  const Frame(Duration now, this.raw) : super(now);
}

class Tick extends ClientEvent {
  const Tick(Duration now) : super(now);
}

class SendCommand extends ClientEvent {
  final String action;
  final Map<String, dynamic> payload;
  const SendCommand(Duration now, this.action, [this.payload = const {}]) : super(now);
}

class SetBackgrounded extends ClientEvent {
  final bool value;
  const SetBackgrounded(Duration now, this.value) : super(now);
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
/// Returns a [String] error message wrapped in a list for the shell to show.
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
      command = t == 'local' ? {'action': 'setTarget', 'target': 'local'} : {'action': 'setTarget', 'castDeviceId': t};
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

ClientState reduce(ClientState s, ClientEvent e) {
  switch (e) {
    case ConnectRequested():
      switch (s.status) {
        case ConnStatus.disconnected:
        case ConnStatus.reconnecting:
          return s.copy(
            status: ConnStatus.connecting,
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
      if (s.status != ConnStatus.connecting) {
        return s.copy(notice: 'unexpected socket open while ${s.status.name} (ignored)');
      }
      s.outgoing.add(jsonEncode({'t': 'hello', 'client': 'harbor-remote', 'proto': 1}));
      return s.copy(
        status: ConnStatus.connected,
        backoff: backoffFloor,
        reconnectAttempts: 0,
        notice: 'socket open → hello sent',
      );

    case SocketClosed(reason: final reason):
      if (s.status == ConnStatus.connected) {
        // unexpected drop of an established connection: first retry at the floor
        return s.copy(
          status: ConnStatus.reconnecting,
          backoff: backoffFloor,
          reconnectAt: e.now + backoffFloor,
          reconnectAttempts: s.reconnectAttempts + 1,
          lastError: 'connection lost ($reason)',
          notice: 'socket closed → retry in ${backoffFloor.inMilliseconds}ms',
        );
      }
      if (s.status == ConnStatus.connecting) {
        // a reconnect attempt failed: double the backoff, up to the cap
        final next = _nextBackoff(s.backoff);
        return s.copy(
          status: ConnStatus.reconnecting,
          backoff: next,
          reconnectAt: e.now + next,
          reconnectAttempts: s.reconnectAttempts + 1,
          lastError: 'connection lost ($reason)',
          notice: 'attempt failed → retry in ${next.inMilliseconds}ms',
        );
      }
      return s.copy(notice: 'close ignored (status ${s.status.name})');

    case DisconnectRequested():
      return s.copy(
        status: ConnStatus.disconnected,
        clearReconnectAt: true,
        backoff: backoffFloor,
        reconnectAttempts: 0,
        clearLastError: true,
        notice: 'user disconnect',
      );

    case Frame(now: final now, raw: final raw):
      return _handleFrame(s, now, raw);

    case Tick(now: final now):
      if (s.status == ConnStatus.reconnecting &&
          !s.backgrounded &&
          s.reconnectAt != null &&
          now >= s.reconnectAt!) {
        return s.copy(
          status: ConnStatus.connecting,
          clearReconnectAt: true,
          notice: 'reconnect attempt ${s.reconnectAttempts + 1} (backoff ${s.backoff.inMilliseconds}ms) → connecting',
        );
      }
      return s.copy(clearNotice: true);

    case SendCommand(action: final action, payload: final payload):
      if (s.status != ConnStatus.connected) {
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
    notice: 'snapshot ${snap.updatedAt}${snap.idle ? ' (idle)' : ''}',
  );

  if (!snap.idle) {
    next = next.copy(lastActive: snap, clearIdleSince: true);
  } else if (prev != null && !prev.idle) {
    // just went idle — start the sticky-idle grace window
    next = next.copy(idleSince: now);
  }

  if (snap.tmdbKey != null && snap.tmdbKey != s.tmdbKey) {
    next = next.copy(notice: 'tmdbKey refreshed: ${snap.tmdbKey}');
  }
  return next;
}

Duration _nextBackoff(Duration current) {
  final doubled = current * 2;
  return doubled > backoffCap ? backoffCap : doubled;
}

// ---------------------------------------------------------------------------
// Derived now-playing view (what a widget renders from the client state)
// ---------------------------------------------------------------------------

class NowPlaying {
  final bool active; // false → render the idle/empty state
  final bool sticky; // true while within the sticky-idle grace window
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

NowPlaying nowPlaying(ClientState s, Duration now) {
  final last = s.last;
  if (last == null) return const NowPlaying(active: false);

  // Sticky idle: hold the last active media for the grace window so a brief
  // idle flap (episode hop / autoplay) doesn't blank the screen.
  if (last.idle) {
    final src = s.lastActive;
    final withinGrace = s.idleSince != null && now - s.idleSince! < stickyClear;
    if (src != null && withinGrace) {
      return NowPlaying(
        active: true,
        sticky: true,
        title: src.mediaTitle,
        episode: src.episode?.name,
        positionSec: src.positionSec,
        durationSec: src.durationSec,
        playing: false,
        volume: last.volume,
        muted: last.muted,
        targetLabel: last.target.label,
        hasPrevEpisode: last.hasPrevEpisode,
        hasNextEpisode: last.hasNextEpisode,
        subtitlesOn: last.subtitlesOn,
        textEntry: last.textEntry,
      );
    }
    return const NowPlaying(active: false);
  }

  return NowPlaying(
    active: true,
    title: last.mediaTitle,
    episode: last.episode?.name,
    positionSec: last.positionSec,
    durationSec: last.durationSec,
    playing: last.playing,
    volume: last.volume,
    muted: last.muted,
    targetLabel: last.target.label,
    hasPrevEpisode: last.hasPrevEpisode,
    hasNextEpisode: last.hasNextEpisode,
    subtitlesOn: last.subtitlesOn,
    textEntry: last.textEntry,
  );
}
