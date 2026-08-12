// Pure Remote/playback state model (ticket 07).
//
// `(RemoteState, RemoteEvent) => RemoteState` reducer producing an effects
// buffer the controller drains onto the WS client. No I/O, no timers: the
// controller owns the await + sticky timers (side-channels) and folds the WS
// client's snapshots / connection status / host-error frames back in as events.
//
// Lifted from the validated playback prototype (prototype/playback) with the
// renderer picker, d-pad nav, and text entry added. The decisions this module
// owns, and the seam tests pin:
//
//   - **awaitingStart** between `playMeta` and the first non-idle snapshot; the
//     await window is the phone's only no-stream/host-busy detector, and a
//     thrown handler (`{t:"error"}`) fails it immediately.
//   - **rendered-gate coalescing**: the now-playing view is re-derived only when
//     its rendered fields change (the `NowPlaying ==` gate), never on
//     `updatedAt`; `viewRebuilds` counts actual re-derivations.
//   - **sticky hold** (~1.2s) absorbs episode-hop idle flaps while `nowPlaying`.
//   - **host-authoritative transport**: play/pause/seek/volume/mute/prev/next
//     derive their wire payloads from the last snapshot; rejected with a notice
//     while disconnected; the next snapshot reflects them (no optimistic state).
//   - **manual renderer picker** — `castDiscover` only ever on user action,
//     never on connect/reconnect.
//
// Effects vocabulary (the Notifier → adapter surface):
//   `command` → send `pendingCommand` (action + payload) via the WS client.
//
// Wire contract: docs/wire-contract.md §2.1/§2.2/§4.

library;

import '../home/home_reducer.dart' show PlayMetaCommand;
import '../ws/client_reducer.dart'
    show CastDevice, EpisodeRef, Snapshot, SourceInfo, TargetInfo, TextEntry;

const int stickyIdleMs = 1200;
const Duration awaitingWindow = Duration(seconds: 20);

enum RemotePhase { idle, awaitingStart, nowPlaying }

/// A command the reducer wants the WS client to send. The controller drains the
/// `command` effect by calling `sendCommand(action, payload)`.
class PendingCommand {
  final String action;
  final Map<String, dynamic> payload;
  const PendingCommand(this.action, [this.payload = const {}]);
}

// ---------------------------------------------------------------------------
// Now-playing view model — the rendered gate
// ---------------------------------------------------------------------------

/// The rendered now-playing view. `==`/`hashCode` implement the rendered gate
/// (title/poster/episode/source/position/duration/playing/volume/muted/
/// target/prev-next/subtitles) — the only trigger that re-derives the view.
/// `positionSec` advances every 400 ms while playing (so the bar moves); nothing
/// else changes on a paused frame, so no pointless rebuilds.
class NowPlaying {
  final String? mediaId;
  final String mediaTitle;
  final String? posterUrl;
  final EpisodeRef? episode;
  final SourceInfo? source;
  final double positionSec;
  final double durationSec;
  final bool playing;
  final double volume; // 0..1
  final bool muted;
  final TargetInfo target;
  final bool hasPrevEpisode;
  final bool hasNextEpisode;
  final bool subtitlesOn;
  final bool canToggleSubtitles;

  const NowPlaying({
    this.mediaId,
    required this.mediaTitle,
    this.posterUrl,
    this.episode,
    this.source,
    this.positionSec = 0,
    this.durationSec = 0,
    this.playing = false,
    this.volume = 1,
    this.muted = false,
    this.target = const TargetInfo('local', 'This PC'),
    this.hasPrevEpisode = false,
    this.hasNextEpisode = false,
    this.subtitlesOn = false,
    this.canToggleSubtitles = false,
  });

  factory NowPlaying.fromSnapshot(Snapshot s) => NowPlaying(
        mediaId: s.mediaId,
        mediaTitle: s.mediaTitle ?? s.mediaId ?? '',
        posterUrl: s.posterUrl,
        episode: s.episode,
        source: s.source,
        positionSec: s.positionSec,
        durationSec: s.durationSec,
        playing: s.playing,
        volume: s.volume,
        muted: s.muted,
        target: s.target,
        hasPrevEpisode: s.hasPrevEpisode,
        hasNextEpisode: s.hasNextEpisode,
        subtitlesOn: s.subtitlesOn,
        canToggleSubtitles: s.canToggleSubtitles,
      );

  double get progress =>
      durationSec > 0 ? (positionSec / durationSec).clamp(0.0, 1.0) : 0;

  String? get episodeLine {
    final ep = episode;
    if (ep == null) return null;
    final s = ep.season;
    final e = ep.episode;
    if (s == null || e == null) return ep.name;
    final label = 'S$s · E$e';
    final name = ep.name;
    return (name == null || name.isEmpty) ? label : '$label  $name';
  }

  /// Mirrors the reference `sourceLine` — `quality` already includes
  /// resolution, so don't repeat it; hide a label that just echoes the title.
  String? get sourceLine {
    final src = source;
    if (src == null) return null;
    final bits = <String>[];
    if (src.quality != null && src.quality!.isNotEmpty) {
      bits.add(src.quality!);
    } else if (src.resolution != null && src.resolution!.isNotEmpty) {
      bits.add(src.resolution!);
    }
    if (src.releaseGroup != null && src.releaseGroup!.isNotEmpty) {
      bits.add(src.releaseGroup!);
    }
    if (bits.isNotEmpty) return bits.join(' · ');
    final label = src.label?.trim();
    if (label == null || label.isEmpty) return null;
    final title = mediaTitle.trim();
    if (label.toLowerCase() == title.toLowerCase()) return null;
    String norm(String s) => s.toLowerCase().replaceAll(RegExp('[^a-z0-9]+'), '');
    final nt = norm(title);
    final nl = norm(label);
    if (nt.isNotEmpty && nl.isNotEmpty && (nl.startsWith(nt) || nt.startsWith(nl))) {
      return null;
    }
    return label;
  }

  @override
  bool operator ==(Object other) =>
      other is NowPlaying &&
      mediaId == other.mediaId &&
      mediaTitle == other.mediaTitle &&
      posterUrl == other.posterUrl &&
      _eqEpisode(episode, other.episode) &&
      sourceLine == other.sourceLine &&
      positionSec == other.positionSec &&
      durationSec == other.durationSec &&
      playing == other.playing &&
      volume == other.volume &&
      muted == other.muted &&
      target == other.target &&
      hasPrevEpisode == other.hasPrevEpisode &&
      hasNextEpisode == other.hasNextEpisode &&
      subtitlesOn == other.subtitlesOn &&
      canToggleSubtitles == other.canToggleSubtitles;

  @override
  int get hashCode => Object.hash(mediaId, mediaTitle, posterUrl, episodeLine,
      sourceLine, positionSec, durationSec, playing, volume, muted, target);

  static bool _eqEpisode(EpisodeRef? a, EpisodeRef? b) {
    if (a == null || b == null) return a == b;
    return a.season == b.season && a.episode == b.episode && a.name == b.name;
  }
}

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

class RemoteState {
  final bool connected;
  final RemotePhase phase;
  final PlayMetaCommand? playRequest; // the most recent playMeta (awaiting title)
  final NowPlaying? nowPlaying; // live or sticky-held media (coalesced)
  final bool stickyHeld; // holding media though the last snapshot was idle
  final TargetInfo target;
  final List<CastDevice> castDevices;
  final bool castDiscovering;
  final TextEntry? textEntry;
  final String? notice;
  final String? lastError;
  final PendingCommand? pendingCommand;
  final int snapshotsSeen;
  final int viewRebuilds; // actual now-playing re-derivations (not per-frame)
  final int playMetaSent;
  final int playStarted; // awaiting/idle → nowPlaying transitions
  final int playFailed; // awaiting → timeout/error failures
  final int commandsSent;

  /// Effects buffer: the reducer appends effects here; the controller drains
  /// them. The one mutable field (impure by convention).
  final List<String> effects;

  RemoteState({
    this.connected = false,
    this.phase = RemotePhase.idle,
    this.playRequest,
    this.nowPlaying,
    this.stickyHeld = false,
    this.target = const TargetInfo('local', 'This PC'),
    this.castDevices = const [],
    this.castDiscovering = false,
    this.textEntry,
    this.notice,
    this.lastError,
    this.pendingCommand,
    this.snapshotsSeen = 0,
    this.viewRebuilds = 0,
    this.playMetaSent = 0,
    this.playStarted = 0,
    this.playFailed = 0,
    this.commandsSent = 0,
    List<String>? effects,
  }) : effects = effects ?? <String>[];

  RemoteState copy({
    bool? connected,
    RemotePhase? phase,
    PlayMetaCommand? playRequest,
    bool clearPlayRequest = false,
    NowPlaying? nowPlaying,
    bool clearNowPlaying = false,
    bool? stickyHeld,
    TargetInfo? target,
    List<CastDevice>? castDevices,
    bool? castDiscovering,
    TextEntry? textEntry,
    bool clearTextEntry = false,
    String? notice,
    bool clearNotice = false,
    String? lastError,
    bool clearLastError = false,
    PendingCommand? pendingCommand,
    int? snapshotsSeen,
    int? viewRebuilds,
    int? playMetaSent,
    int? playStarted,
    int? playFailed,
    int? commandsSent,
    List<String>? effects,
  }) {
    return RemoteState(
      connected: connected ?? this.connected,
      phase: phase ?? this.phase,
      playRequest: clearPlayRequest ? null : (playRequest ?? this.playRequest),
      nowPlaying: clearNowPlaying ? null : (nowPlaying ?? this.nowPlaying),
      stickyHeld: stickyHeld ?? this.stickyHeld,
      target: target ?? this.target,
      castDevices: castDevices ?? this.castDevices,
      castDiscovering: castDiscovering ?? this.castDiscovering,
      textEntry: clearTextEntry ? null : (textEntry ?? this.textEntry),
      notice: clearNotice ? null : (notice ?? this.notice),
      lastError: clearLastError ? null : (lastError ?? this.lastError),
      pendingCommand: pendingCommand ?? this.pendingCommand,
      snapshotsSeen: snapshotsSeen ?? this.snapshotsSeen,
      viewRebuilds: viewRebuilds ?? this.viewRebuilds,
      playMetaSent: playMetaSent ?? this.playMetaSent,
      playStarted: playStarted ?? this.playStarted,
      playFailed: playFailed ?? this.playFailed,
      commandsSent: commandsSent ?? this.commandsSent,
      effects: effects ?? this.effects,
    );
  }
}

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------

sealed class RemoteEvent {
  const RemoteEvent();
}

class Connected extends RemoteEvent {
  const Connected();
}

class Disconnected extends RemoteEvent {
  const Disconnected();
}

/// A fresh snapshot folded in from the WS client (already coalesced on
/// `updatedAt` upstream). `snapshot.idle` decides playing vs. idle.
class SnapshotArrived extends RemoteEvent {
  final Snapshot snapshot;
  const SnapshotArrived(this.snapshot);
}

/// The user tapped play on a title (movie, series first-episode, or a
/// deep-linked season/episode with resume).
class PlayMeta extends RemoteEvent {
  final PlayMetaCommand command;
  const PlayMeta(this.command);
}

class TogglePlay extends RemoteEvent {
  const TogglePlay();
}

class Seek extends RemoteEvent {
  final double positionSec;
  const Seek(this.positionSec);
}

class SetVolume extends RemoteEvent {
  final double volume;
  const SetVolume(this.volume);
}

class ToggleMute extends RemoteEvent {
  const ToggleMute();
}

class PrevEpisode extends RemoteEvent {
  const PrevEpisode();
}

class NextEpisode extends RemoteEvent {
  const NextEpisode();
}

class ToggleSubtitles extends RemoteEvent {
  const ToggleSubtitles();
}

/// Manual renderer re-scan. Never auto-issued on connect/reconnect.
class CastDiscover extends RemoteEvent {
  const CastDiscover();
}

/// Pick a renderer: `local` for "This PC", or a cast device id.
class SetTarget extends RemoteEvent {
  final String target;
  const SetTarget(this.target);
}

class CastStop extends RemoteEvent {
  const CastStop();
}

/// D-pad key: up | down | left | right | select | back.
class Nav extends RemoteEvent {
  final String key;
  const Nav(this.key);
}

class SetText extends RemoteEvent {
  final String value;
  const SetText(this.value);
}

class SubmitText extends RemoteEvent {
  final String? value;
  const SubmitText([this.value]);
}

class BlurText extends RemoteEvent {
  const BlurText();
}

class OpenSearch extends RemoteEvent {
  const OpenSearch();
}

/// `{t:"error", message}` — only when a command handler THROWS on the host.
class ErrorFrame extends RemoteEvent {
  final String message;
  const ErrorFrame(this.message);
}

/// The controller's await timer fired: the host never left idle after playMeta.
class AwaitTimeout extends RemoteEvent {
  final Duration window;
  const AwaitTimeout(this.window);
}

/// The controller's sticky timer fired: idle held past the window → drop.
class StickyExpired extends RemoteEvent {
  const StickyExpired();
}

// ---------------------------------------------------------------------------
// Reducer
// ---------------------------------------------------------------------------

const Set<String> _navKeys = {'up', 'down', 'left', 'right', 'select', 'back'};

RemoteState remoteReduce(RemoteState s, RemoteEvent e) {
  switch (e) {
    case Connected():
      return s.copy(connected: true, clearLastError: true);

    case Disconnected():
      // Playback dies with the socket; the WS layer's own sticky window keeps
      // the shell showing the tab for ~1.2s. Transport + playMeta are rejected
      // while disconnected.
      final changed = s.nowPlaying != null || s.stickyHeld || s.phase != RemotePhase.idle;
      return s.copy(
        connected: false,
        phase: RemotePhase.idle,
        clearPlayRequest: true,
        clearNowPlaying: true,
        stickyHeld: false,
        notice: 'Not connected to a computer',
        viewRebuilds: changed ? s.viewRebuilds + 1 : s.viewRebuilds,
      );

    case SnapshotArrived(snapshot: final snap):
      return _onSnapshot(s, snap);

    case PlayMeta(command: final command):
      return _onPlayMeta(s, command);

    case TogglePlay():
      final np = s.nowPlaying;
      if (!s.connected) return _rejectDisconnected(s);
      if (np == null) return _rejectNothingPlaying(s);
      return _emit(s, np.playing ? 'pause' : 'play');

    case Seek(positionSec: final pos):
      return _transport(s, 'seek', {'positionSec': pos < 0 ? 0 : pos});

    case SetVolume(volume: final v):
      return _transport(s, 'setVolume', {'volume': v.clamp(0.0, 1.0)});

    case ToggleMute():
      final np = s.nowPlaying;
      if (!s.connected) return _rejectDisconnected(s);
      if (np == null) return _rejectNothingPlaying(s);
      return _emit(s, 'setMuted', {'muted': !np.muted});

    case PrevEpisode():
      return _transport(s, 'prevEpisode');

    case NextEpisode():
      return _transport(s, 'nextEpisode');

    case ToggleSubtitles():
      return _transport(s, 'toggleSubtitles');

    case CastDiscover():
      return _command(s, 'castDiscover');

    case SetTarget(target: final t):
      return _command(s, 'setTarget', {'target': t});

    case CastStop():
      return _command(s, 'castStop');

    case Nav(key: final key):
      if (!_navKeys.contains(key)) return s.copy(notice: "unknown nav key '$key'");
      return _command(s, 'nav', {'key': key});

    case SetText(value: final v):
      return _command(s, 'setText', {'value': v});

    case SubmitText(value: final v):
      return _command(s, 'submitText', v == null ? const {} : {'value': v});

    case BlurText():
      return _command(s, 'blurText');

    case OpenSearch():
      return _command(s, 'openSearch');

    case ErrorFrame(message: final message):
      return _onErrorFrame(s, message);

    case AwaitTimeout(window: final w):
      return _onAwaitTimeout(s, w);

    case StickyExpired():
      return _onStickyExpired(s);
  }
}

// -- helpers ----------------------------------------------------------------

RemoteState _rejectDisconnected(RemoteState s) =>
    s.copy(notice: 'Not connected to a computer', clearLastError: true);

RemoteState _rejectNothingPlaying(RemoteState s) =>
    s.copy(notice: 'Nothing playing on your computer', clearLastError: true);

/// Emit a command (already connected + media guards passed).
RemoteState _emit(RemoteState s, String action, [Map<String, dynamic> payload = const {}]) {
  s.effects.add('command');
  return s.copy(
    pendingCommand: PendingCommand(action, payload),
    commandsSent: s.commandsSent + 1,
    clearLastError: true,
    notice: 'sent $action',
  );
}

/// Transport command: requires a live connection and playing media.
RemoteState _transport(RemoteState s, String action,
    [Map<String, dynamic> payload = const {}]) {
  if (!s.connected) return _rejectDisconnected(s);
  if (s.nowPlaying == null) return _rejectNothingPlaying(s);
  return _emit(s, action, payload);
}

/// Any command that only needs a connection (nav, text, cast, playMeta).
RemoteState _command(RemoteState s, String action,
    [Map<String, dynamic> payload = const {}]) {
  if (!s.connected) return _rejectDisconnected(s);
  return _emit(s, action, payload);
}

RemoteState _onSnapshot(RemoteState s, Snapshot snap) {
  final target = _sameTarget(s.target, snap.target) ? s.target : snap.target;
  final castDevices = _sameCastDevices(s.castDevices, snap.castDevices)
      ? s.castDevices
      : snap.castDevices;
  final textEntry = _sameTextEntry(s.textEntry, snap.textEntry)
      ? s.textEntry
      : snap.textEntry;
  var next = s.copy(
    snapshotsSeen: s.snapshotsSeen + 1,
    target: target,
    castDevices: castDevices,
    castDiscovering: snap.castDiscovering,
    textEntry: textEntry,
  );

  if (!snap.idle) {
    final np = NowPlaying.fromSnapshot(snap);
    final started = next.phase != RemotePhase.nowPlaying;
    final mediaChanged = started || np != next.nowPlaying; // the rendered gate
    final held = (next.nowPlaying != null && next.nowPlaying == np)
        ? next.nowPlaying
        : np;
    next = next.copy(
      phase: RemotePhase.nowPlaying,
      clearPlayRequest: true,
      nowPlaying: held,
      stickyHeld: false,
      clearLastError: true,
      playStarted: next.playStarted + (started ? 1 : 0),
      viewRebuilds: next.viewRebuilds + (mediaChanged ? 1 : 0),
      notice: started ? 'Playing on your computer' : null,
    );
  } else if (next.phase == RemotePhase.nowPlaying) {
    // Idle flap while playing: hold the media through the sticky window so a
    // brief episode/autoplay hop doesn't yank the transport.
    next = next.copy(
      stickyHeld: true,
      viewRebuilds: next.viewRebuilds + (next.stickyHeld ? 0 : 1),
    );
  }
  // awaitingStart / idle phases ignore the idle snapshot.

  return next;
}

bool _sameTarget(TargetInfo a, TargetInfo b) => a == b;

bool _sameCastDevices(List<CastDevice> a, List<CastDevice> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i].id != b[i].id || a[i].name != b[i].name || a[i].kind != b[i].kind) {
      return false;
    }
  }
  return true;
}

bool _sameTextEntry(TextEntry? a, TextEntry? b) {
  if (a == null || b == null) return a == b;
  return a.value == b.value && a.placeholder == b.placeholder;
}

RemoteState _onPlayMeta(RemoteState s, PlayMetaCommand command) {
  if (!s.connected) return _rejectDisconnected(s);
  s.effects.add('command');
  return s.copy(
    phase: RemotePhase.awaitingStart,
    playRequest: command,
    clearNowPlaying: true,
    stickyHeld: false,
    pendingCommand: PendingCommand('playMeta', command.toPayload()),
    playMetaSent: s.playMetaSent + 1,
    commandsSent: s.commandsSent + 1,
    clearLastError: true,
    notice: 'Starting ${command.name ?? command.metaId} on your computer…',
  );
}

RemoteState _onErrorFrame(RemoteState s, String message) {
  // An error frame while awaiting start means the host THREW handling our
  // playMeta — treat it as the failure signal (no stream / host busy).
  if (s.phase == RemotePhase.awaitingStart) {
    return s.copy(
      phase: RemotePhase.idle,
      clearPlayRequest: true,
      clearNowPlaying: true,
      playFailed: s.playFailed + 1,
      lastError: message,
      notice: 'Could not start playback: $message',
      viewRebuilds: s.viewRebuilds + 1,
    );
  }
  // Otherwise a transport command failed on the host; keep the media up.
  return s.copy(lastError: message, notice: 'Error: $message');
}

RemoteState _onAwaitTimeout(RemoteState s, Duration window) {
  if (s.phase != RemotePhase.awaitingStart) return s;
  final secs = (window.inMilliseconds / 1000).round();
  return s.copy(
    phase: RemotePhase.idle,
    clearPlayRequest: true,
    clearNowPlaying: true,
    stickyHeld: false,
    playFailed: s.playFailed + 1,
    lastError: 'The host did not start playing within ${secs}s — no stream '
        'found or the host is busy. Check the picker on your computer.',
    notice: 'Could not start playback on your computer',
    viewRebuilds: s.viewRebuilds + 1,
  );
}

RemoteState _onStickyExpired(RemoteState s) {
  if (s.phase != RemotePhase.nowPlaying || !s.stickyHeld) return s;
  return s.copy(
    phase: RemotePhase.idle,
    clearNowPlaying: true,
    stickyHeld: false,
    notice: 'Playback ended',
    viewRebuilds: s.viewRebuilds + 1,
  );
}
