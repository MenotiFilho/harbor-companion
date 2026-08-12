// Riverpod controller for the Remote/playback tab (ticket 07).
//
// Thin glue between the pure reducer (remote_reducer.dart) and the outside
// world. Folds the WS client's snapshots / connection status / host-error
// frames into the reducer, drains the reducer's `command` effect onto the WS
// client, and owns the two timers the reducer delegates to the outside world:
// the await window (awaitingStart → AwaitTimeout) and the sticky hold
// (stickyHeld → StickyExpired).
//
// `connected` tracks the WS client's raw status, so a command issued while the
// socket is down (even inside the shell's sticky window) is honestly rejected.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../home/home_reducer.dart' show PlayMetaCommand;
import '../ws/client_controller.dart';
import '../ws/client_reducer.dart' show ClientState, WsStatus;
import 'remote_reducer.dart';

/// The await window the controller arms while `awaitingStart`. Defaults to the
/// reducer's 20 s; tests override it.
final remoteAwaitWindowProvider = Provider<Duration>((ref) => awaitingWindow);

class RemoteController extends Notifier<RemoteState> {
  Timer? _awaitTimer;
  Timer? _stickyTimer;

  @override
  RemoteState build() {
    ref.onDispose(() {
      _awaitTimer?.cancel();
      _stickyTimer?.cancel();
    });

    final client = ref.read(wsClientControllerProvider);
    ref.listen(wsClientControllerProvider, _onClientChanged);

    // Seed from the WS client's current view so opening the Remote tab mid-
    // playback renders immediately rather than waiting for the next snapshot.
    var state = RemoteState(connected: client.status == WsStatus.connected);
    final last = client.last;
    if (last != null) state = remoteReduce(state, SnapshotArrived(last));
    return state;
  }

  // -- UI entry points -------------------------------------------------------

  void playMeta(PlayMetaCommand command) => _dispatch(PlayMeta(command));

  void togglePlay() => _dispatch(const TogglePlay());

  void seek(double positionSec) => _dispatch(Seek(positionSec));

  void setVolume(double volume) => _dispatch(SetVolume(volume));

  void toggleMute() => _dispatch(const ToggleMute());

  void prevEpisode() => _dispatch(const PrevEpisode());

  void nextEpisode() => _dispatch(const NextEpisode());

  void toggleSubtitles() => _dispatch(const ToggleSubtitles());

  void castDiscover() => _dispatch(const CastDiscover());

  void setTarget(String target) => _dispatch(SetTarget(target));

  void castStop() => _dispatch(const CastStop());

  void nav(String key) => _dispatch(Nav(key));

  void setText(String value) => _dispatch(SetText(value));

  void submitText([String? value]) => _dispatch(SubmitText(value));

  void blurText() => _dispatch(const BlurText());

  void openSearch() => _dispatch(const OpenSearch());

  // -- The one place state mutates -------------------------------------------

  void _dispatch(RemoteEvent event) {
    state = remoteReduce(state, event);
    _afterState(state);
  }

  void _afterState(RemoteState next) {
    _drain(next);
    _syncTimers(next);
  }

  void _drain(RemoteState next) {
    if (next.effects.isEmpty) return;
    final effects = List<String>.from(next.effects);
    next.effects.clear();
    for (final effect in effects) {
      if (effect == 'command') {
        final cmd = next.pendingCommand;
        if (cmd != null) {
          ref
              .read(wsClientControllerProvider.notifier)
              .sendCommand(cmd.action, cmd.payload);
        }
      }
    }
  }

  /// Arms/cancels the await + sticky timers to match the current phase. Timers
  /// are armed once at the transition (entering `awaitingStart`, or `stickyHeld`
  /// first becoming true) and only cancelled on the transition out — a 400 ms
  /// snapshot stream must NOT keep resetting the countdown.
  void _syncTimers(RemoteState s) {
    final awaiting = s.phase == RemotePhase.awaitingStart;
    if (awaiting && _awaitTimer == null) {
      final window = ref.read(remoteAwaitWindowProvider);
      _awaitTimer = Timer(window, () => _dispatch(AwaitTimeout(window)));
    } else if (!awaiting && _awaitTimer != null) {
      _awaitTimer!.cancel();
      _awaitTimer = null;
    }

    if (s.stickyHeld && _stickyTimer == null) {
      _stickyTimer = Timer(
        const Duration(milliseconds: stickyIdleMs),
        () => _dispatch(const StickyExpired()),
      );
    } else if (!s.stickyHeld && _stickyTimer != null) {
      _stickyTimer!.cancel();
      _stickyTimer = null;
    }
  }

  // -- WS client → reducer folding -------------------------------------------

  void _onClientChanged(ClientState? previous, ClientState next) {
    final prevConnected = previous?.status == WsStatus.connected;
    final nextConnected = next.status == WsStatus.connected;
    if (nextConnected != prevConnected) {
      _dispatch(nextConnected ? const Connected() : const Disconnected());
    }
    if (next.last != previous?.last && next.last != null) {
      _dispatch(SnapshotArrived(next.last!));
    }
    if (next.lastHostError != null && next.lastHostError != previous?.lastHostError) {
      _dispatch(ErrorFrame(next.lastHostError!));
    }
  }
}

final remoteControllerProvider =
    NotifierProvider<RemoteController, RemoteState>(RemoteController.new);
