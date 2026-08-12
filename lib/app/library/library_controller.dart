// Riverpod controller for Library / My Stuff (ticket 06).
//
// Thin glue between the pure reducer (library_reducer.dart) and the outside
// world. Folds the WS client's snapshots / connection status / host-error
// frames into the reducer, drains the reducer's `command` effect onto the WS
// client (`libraryAction`) and its `persist` effect into the library store,
// and restores persisted state on startup.
//
// `connected` tracks the WS client's raw status (not the shell's sticky
// window), so a toggle issued while the socket is down is honestly rejected
// and a drop falls back to the stale / needConnect view immediately.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../ws/client_controller.dart';
import '../ws/client_reducer.dart' show ClientState, LibraryItem, WsStatus;
import 'library_reducer.dart';
import 'library_store.dart';

/// Library persistence seam. Defaults to an in-memory store; the
/// shared_preferences-backed store is wired in main(). Tests override.
final libraryStoreProvider =
    Provider<LibraryStore>((ref) => InMemoryLibraryStore());

class LibraryController extends Notifier<LibraryState> {
  bool _restored = false;
  bool _lastEnabled = false;

  @override
  LibraryState build() {
    ref.listen(wsClientControllerProvider, _onClientChanged);

    // Seed from the WS client's current view so opening My Stuff mid-session
    // renders immediately rather than waiting for the next snapshot.
    final client = ref.read(wsClientControllerProvider);
    var state = LibraryState(connected: client.status == WsStatus.connected);
    final last = client.last;
    if (last != null) {
      state = libraryReduce(
        state,
        SnapshotArrived(last.library, last.trackers, last.updatedAt),
      );
    }

    _restore();
    return state;
  }

  Future<void> _restore() async {
    final store = ref.read(libraryStoreProvider);
    final enabled = await store.loadEnabled();
    final data = await store.loadData();
    if (!ref.mounted) return;
    _lastEnabled = enabled;
    _restored = true;
    _dispatch(PersistLoaded(enabled, decodePersisted(data ?? '')));
  }

  // -- UI entry points -------------------------------------------------------

  void toggle(String kind, LibraryItem item, bool on) =>
      _dispatch(Toggle(kind, item, on));

  void togglePersistence() => _dispatch(const TogglePersistence());

  // -- The one place state mutates -------------------------------------------

  void _dispatch(LibraryEvent event) {
    state = libraryReduce(state, event);
    _afterState(state);
  }

  void _afterState(LibraryState next) {
    _drain(next);
    _syncEnabled(next);
  }

  /// Maps the effects buffer onto the side-channels.
  void _drain(LibraryState next) {
    if (next.effects.isEmpty) return;
    final effects = List<String>.from(next.effects);
    next.effects.clear();
    for (final effect in effects) {
      switch (effect) {
        case 'command':
          final cmd = next.pendingCommand;
          if (cmd != null) {
            ref
                .read(wsClientControllerProvider.notifier)
                .sendCommand(cmd.action, cmd.payload);
          }
        case 'persist':
          final p = next.pendingPersist;
          if (p != null) {
            _persistWrite(p);
          }
      }
    }
  }

  Future<void> _persistWrite(PersistPayload p) async {
    await ref.read(libraryStoreProvider).saveData(p.encoded);
    if (!ref.mounted) return;
    _dispatch(PersistWritten(p.sig));
  }

  /// Persists the enabled flag whenever it actually changes (so the offline
  /// fallback survives a restart), but only after the initial restore.
  void _syncEnabled(LibraryState next) {
    if (!_restored) return;
    if (next.persistEnabled != _lastEnabled) {
      _lastEnabled = next.persistEnabled;
      ref.read(libraryStoreProvider).saveEnabled(next.persistEnabled);
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
      _dispatch(SnapshotArrived(snap.library, snap.trackers, snap.updatedAt));
    }
    if (next.lastHostError != null && next.lastHostError != previous?.lastHostError) {
      _dispatch(ErrorFrame(next.lastHostError!));
    }
  }
}

final libraryControllerProvider =
    NotifierProvider<LibraryController, LibraryState>(LibraryController.new);
