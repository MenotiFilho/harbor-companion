// Riverpod controller for Profile / who's-watching (ticket 08).
//
// Thin glue between the pure reducer (profile_reducer.dart) and the outside
// world. Folds the WS client's snapshots / connection status into the reducer
// and drains the reducer's `command` effect onto the WS client (`setProfile`).
//
// `connected` tracks the WS client's raw status (not the shell's sticky
// window), so a switch issued while the socket is down is honestly rejected.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../ws/client_controller.dart';
import '../ws/client_reducer.dart' show ClientState, WsStatus;
import 'profile_reducer.dart';

class ProfileController extends Notifier<ProfileState> {
  @override
  ProfileState build() {
    ref.listen(wsClientControllerProvider, _onClientChanged);

    // Seed from the WS client's current view so opening the Profile tab
    // mid-session renders immediately rather than waiting for the next
    // snapshot.
    final client = ref.read(wsClientControllerProvider);
    var state = ProfileState(connected: client.status == WsStatus.connected);
    final last = client.last;
    if (last != null) {
      state = profileReduce(
        state,
        SnapshotArrived(last.profile, last.profiles),
      );
    }
    return state;
  }

  // -- UI entry points -------------------------------------------------------

  void select(String id) => _dispatch(Select(id));

  // -- The one place state mutates -------------------------------------------

  void _dispatch(ProfileEvent event) {
    state = profileReduce(state, event);
    _drain(state);
  }

  /// Maps the effects buffer onto the side-channels.
  void _drain(ProfileState next) {
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

  // -- WS client → reducer folding -------------------------------------------

  void _onClientChanged(ClientState? previous, ClientState next) {
    final prevConnected = previous?.status == WsStatus.connected;
    final nextConnected = next.status == WsStatus.connected;
    if (nextConnected != prevConnected) {
      _dispatch(nextConnected ? const Connected() : const Disconnected());
    }
    if (next.last != previous?.last && next.last != null) {
      final snap = next.last!;
      _dispatch(SnapshotArrived(snap.profile, snap.profiles));
    }
  }
}

final profileControllerProvider =
    NotifierProvider<ProfileController, ProfileState>(ProfileController.new);
