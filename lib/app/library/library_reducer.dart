// Pure Library / My Stuff state model (ticket 06).
//
// `(LibraryState, LibraryEvent) => LibraryState` reducer producing an effects
// buffer the controller drains through injected side-channels (the WS client's
// `sendCommand`, the library persistence store). No I/O, no timers.
//
// Lifted from the validated library prototype (#10) with the shell's string
// effects replaced by structured `command`/`persist` payloads. The decisions
// this module owns, and the seam tests pin:
//
//   - **derive-on-change refresh model**: the view is rebuilt only when
//     `snapshot.library` changes (a stable signature of its content), never on
//     the 400 ms tick and never on `updatedAt` — `viewRebuilds << snapshotsSeen`.
//   - **host-authoritative toggles, no optimistic UI**: `Toggle` sends
//     `libraryAction {kind: watchlist|watched|favorite, on}`, marks the op
//     pending, resolves when a snapshot's membership reflects it, and rejects
//     after 3 un-reflected snapshots or on an error frame — the chip honestly
//     reverts (the view derives from the snapshot, so it can never show a
//     membership the host doesn't have).
//   - **cloud-sync honest revert**: `watchlist/watched OFF` on Stremio-cloud
//     items is a silent host no-op (no provenance on the wire), so those
//     toggles are sent and reverted when never reflected — never faked.
//   - **derived empty states**: `needConnect` (disconnected, nothing
//     persisted), `emptyLibrary` (connected, all empty), `stale` (disconnected
//     with persisted data and persistence on).
//   - **trackers display-only** in v1 (the simkl/anilist/mal write ops are
//     deferred).
//
// Effects vocabulary (the Notifier → adapter surface):
//   `command` → send `pendingCommand` (libraryAction) via the WS client
//   `persist` → write `pendingPersist` (encoded library) to the store
//
// Wire contract: docs/wire-contract.md §2.1 (library/trackers), §2.2
// (libraryAction).

library;

import 'dart:convert';

import '../ws/client_reducer.dart' show LibraryItem, SnapshotLibrary;

/// A pending op is rejected if this many snapshots pass without the host
/// reflecting it (a host no-op / drop / silent ignore).
const int rejectAfterSnapshots = 3;

enum EmptyKind { none, needConnect, emptyLibrary }

// ---------------------------------------------------------------------------
// Signature + persistence encoding (pure, deterministic)
// ---------------------------------------------------------------------------

/// Canonical, deterministic signature of the library — stable within and
/// across runs. id/type/name/poster/background are all included so even a
/// poster swap is caught. This is the change-detection key for the
/// derive-on-change refresh model.
String librarySignature(SnapshotLibrary? lib) {
  if (lib == null) return '';
  final sb = StringBuffer();
  for (final section in [lib.watchlist, lib.history, lib.favorites]) {
    for (final it in section) {
      sb.write('${it.id}|${it.type}|${it.name}|${it.poster}|${it.background};');
    }
    sb.write('/');
  }
  return sb.toString();
}

/// Persistence payload: JSON (unlike the signature, this must round-trip — the
/// canonical form's separators collide with poster URLs).
String encodePersisted(SnapshotLibrary lib) => jsonEncode({
      'w': [for (final i in lib.watchlist) _encItem(i)],
      'h': [for (final i in lib.history) _encItem(i)],
      'f': [for (final i in lib.favorites) _encItem(i)],
    });

Map<String, Object?> _encItem(LibraryItem i) => {
      'id': i.id,
      'type': i.type,
      if (i.name != null) 'name': i.name,
      if (i.poster != null) 'poster': i.poster,
      if (i.background != null) 'background': i.background,
    };

/// Inverse of [encodePersisted]. Null on empty/garbage input.
SnapshotLibrary? decodePersisted(String json) {
  if (json.isEmpty) return null;
  try {
    final m = jsonDecode(json) as Map<String, dynamic>;
    List<LibraryItem> sec(String k) => [
          for (final e in (m[k] as List? ?? const []))
            LibraryItem(
              (e as Map)['id'] as String,
              e['type'] as String,
              e['name'] as String?,
              e['poster'] as String?,
              e['background'] as String?,
            ),
        ];
    return SnapshotLibrary(
      watchlist: sec('w'),
      history: sec('h'),
      favorites: sec('f'),
    );
  } catch (_) {
    return null;
  }
}

bool _inSection(SnapshotLibrary lib, String kind, String id) {
  final list = switch (kind) {
    'watchlist' => lib.watchlist,
    'watched' => lib.history, // "watched" maps onto history membership
    'favorite' => lib.favorites,
    _ => const <LibraryItem>[],
  };
  return list.any((i) => i.id == id);
}

// ---------------------------------------------------------------------------
// Wire encoding (client → host) — libraryAction only (tracker ops deferred)
// ---------------------------------------------------------------------------

/// The `command` payload for a libraryAction, without the `action` key (the WS
/// client's `sendCommand` adds it). Mirrors library-commands.ts:23-71.
Map<String, dynamic> encodeLibraryAction(String kind, LibraryItem item, bool on) => {
      'metaId': item.id,
      'metaType': item.type,
      if (item.name != null) 'name': item.name,
      if (item.poster != null) 'poster': item.poster,
      'op': {'kind': kind, 'on': on},
    };

// ---------------------------------------------------------------------------
// View model — exactly what the tab renders
// ---------------------------------------------------------------------------

class MyStuffView {
  final List<LibraryItem> watchlist;
  final List<LibraryItem> history;
  final List<LibraryItem> favorites;
  final bool stale; // true = showing persisted data because the WS is down
  final EmptyKind emptyKind;
  final List<String> trackers; // linked trackers, display-only in v1
  final Set<String> watchlistIds;
  final Set<String> historyIds;
  final Set<String> favoriteIds;

  const MyStuffView({
    this.watchlist = const [],
    this.history = const [],
    this.favorites = const [],
    this.stale = false,
    this.emptyKind = EmptyKind.none,
    this.trackers = const [],
    this.watchlistIds = const {},
    this.historyIds = const {},
    this.favoriteIds = const {},
  });

  /// Membership flag for a toggle chip (w / h / f) on a row.
  bool inSection(String kind, String id) => switch (kind) {
        'watchlist' => watchlistIds.contains(id),
        'watched' => historyIds.contains(id),
        'favorite' => favoriteIds.contains(id),
        _ => false,
      };
}

// ---------------------------------------------------------------------------
// Pending op (a libraryAction in flight awaiting host reflection)
// ---------------------------------------------------------------------------

class PendingOp {
  final String kind; // watchlist | watched | favorite
  final LibraryItem item;
  final bool on;
  final int sentAtSnapshot;
  const PendingOp({
    required this.kind,
    required this.item,
    required this.on,
    required this.sentAtSnapshot,
  });
}

/// A command the reducer wants the WS client to send (always libraryAction).
class LibraryCommand {
  final String action;
  final Map<String, dynamic> payload;
  const LibraryCommand(this.action, this.payload);
}

/// The persistence write the reducer wants the store to commit.
class PersistPayload {
  final String sig;
  final String encoded;
  const PersistPayload(this.sig, this.encoded);
}

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

class LibraryState {
  final bool connected;
  final SnapshotLibrary? live; // last live library from a snapshot
  final String liveSig; // signature of `live`
  final List<String> trackers; // last seen linked trackers
  final int liveUpdatedAt;
  final int snapshotsSeen;
  final int viewRebuilds; // actual re-derivations of the view (NOT per-frame)

  // Persistence.
  final bool persistEnabled;
  final SnapshotLibrary? persisted; // last content handed to the store
  final String persistedSig;
  final bool persistDirty; // a write is pending (live differs from the store)
  final int persistWrites;

  // Toggle ops in flight (host-authoritative; nothing optimistic).
  final Map<String, PendingOp> pending;
  final int opsResolved;
  final int opsRejected;

  final MyStuffView view;
  final bool viewDirty; // internal: set when the view must be re-derived
  final String? notice;
  final LibraryCommand? pendingCommand;
  final PersistPayload? pendingPersist;

  /// Effects buffer: the reducer appends effects here; the controller drains
  /// them. The one mutable field (impure by convention).
  final List<String> effects;

  LibraryState({
    this.connected = false,
    this.live,
    this.liveSig = '',
    this.trackers = const [],
    this.liveUpdatedAt = 0,
    this.snapshotsSeen = 0,
    this.viewRebuilds = 0,
    this.persistEnabled = false,
    this.persisted,
    this.persistedSig = '',
    this.persistDirty = false,
    this.persistWrites = 0,
    this.pending = const {},
    this.opsResolved = 0,
    this.opsRejected = 0,
    this.view = const MyStuffView(),
    this.viewDirty = false,
    this.notice,
    this.pendingCommand,
    this.pendingPersist,
    List<String>? effects,
  }) : effects = effects ?? <String>[];

  LibraryState copy({
    bool? connected,
    SnapshotLibrary? live,
    String? liveSig,
    List<String>? trackers,
    int? liveUpdatedAt,
    int? snapshotsSeen,
    int? viewRebuilds,
    bool? persistEnabled,
    SnapshotLibrary? persisted,
    String? persistedSig,
    bool? persistDirty,
    int? persistWrites,
    Map<String, PendingOp>? pending,
    int? opsResolved,
    int? opsRejected,
    MyStuffView? view,
    bool? viewDirty,
    String? notice,
    bool clearNotice = false,
    LibraryCommand? pendingCommand,
    PersistPayload? pendingPersist,
    List<String>? effects,
  }) {
    return LibraryState(
      connected: connected ?? this.connected,
      live: live ?? this.live,
      liveSig: liveSig ?? this.liveSig,
      trackers: trackers ?? this.trackers,
      liveUpdatedAt: liveUpdatedAt ?? this.liveUpdatedAt,
      snapshotsSeen: snapshotsSeen ?? this.snapshotsSeen,
      viewRebuilds: viewRebuilds ?? this.viewRebuilds,
      persistEnabled: persistEnabled ?? this.persistEnabled,
      persisted: persisted ?? this.persisted,
      persistedSig: persistedSig ?? this.persistedSig,
      persistDirty: persistDirty ?? this.persistDirty,
      persistWrites: persistWrites ?? this.persistWrites,
      pending: pending ?? this.pending,
      opsResolved: opsResolved ?? this.opsResolved,
      opsRejected: opsRejected ?? this.opsRejected,
      view: view ?? this.view,
      viewDirty: viewDirty ?? this.viewDirty,
      notice: clearNotice ? null : (notice ?? this.notice),
      pendingCommand: pendingCommand ?? this.pendingCommand,
      pendingPersist: pendingPersist ?? this.pendingPersist,
      effects: effects ?? this.effects,
    );
  }
}

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------

sealed class LibraryEvent {
  const LibraryEvent();
}

class Connected extends LibraryEvent {
  const Connected();
}

/// The WS client dropped. The ~1.2s sticky window is the WS client's own
/// concern; this model reacts to the reported connection state.
class Disconnected extends LibraryEvent {
  const Disconnected();
}

/// A snapshot frame arrived. [library] is null when the field is absent on the
/// wire (treat as an empty library, not an error).
class SnapshotArrived extends LibraryEvent {
  final SnapshotLibrary? library;
  final List<String> trackers;
  final int updatedAt;
  const SnapshotArrived(this.library, this.trackers, this.updatedAt);
}

/// The user tapped a toggle chip on an item.
class Toggle extends LibraryEvent {
  final String kind; // watchlist | watched | favorite
  final LibraryItem item;
  final bool on;
  const Toggle(this.kind, this.item, this.on);
}

/// Host answered a command with `{ t: "error", message }`.
class ErrorFrame extends LibraryEvent {
  final String message;
  const ErrorFrame(this.message);
}

/// The shell loaded persisted state at startup: whether persistence is enabled
/// and the last persisted library (if any).
class PersistLoaded extends LibraryEvent {
  final bool enabled;
  final SnapshotLibrary? persisted;
  const PersistLoaded(this.enabled, this.persisted);
}

/// The store finished writing the most recent persist payload.
class PersistWritten extends LibraryEvent {
  final String sig;
  const PersistWritten(this.sig);
}

/// Flip local persistence on/off.
class TogglePersistence extends LibraryEvent {
  const TogglePersistence();
}

// ---------------------------------------------------------------------------
// Reducer
// ---------------------------------------------------------------------------

LibraryState libraryReduce(LibraryState s, LibraryEvent e) {
  switch (e) {
    case Connected():
      return _maybeDerive(s.copy(connected: true, viewDirty: true));
    case Disconnected():
      // Nothing to write while offline; a reconnect re-emits on the next
      // changed snapshot if needed.
      return _maybeDerive(s.copy(
        connected: false,
        persistDirty: false,
        viewDirty: true,
      ));
    case SnapshotArrived(library: final lib, trackers: final trackers, updatedAt: final updatedAt):
      return _onSnapshot(s, lib, trackers, updatedAt);
    case Toggle(kind: final kind, item: final item, on: final on):
      return _onToggle(s, kind, item, on);
    case ErrorFrame(message: final message):
      return _onErrorFrame(s, message);
    case PersistLoaded(enabled: final enabled, persisted: final p):
      return _maybeDerive(s.copy(
        persistEnabled: enabled,
        persisted: p,
        persistedSig: librarySignature(p),
        viewDirty: true,
      ));
    case PersistWritten(sig: final sig):
      final clean = sig == s.liveSig ? false : s.persistDirty;
      return s.copy(persistDirty: clean, persistWrites: s.persistWrites + 1);
    case TogglePersistence():
      return _onTogglePersistence(s);
  }
}

LibraryState _onSnapshot(
  LibraryState s,
  SnapshotLibrary? library,
  List<String> trackers,
  int updatedAt,
) {
  final sig = librarySignature(library);
  final changed = sig != s.liveSig;
  var next = s.copy(
    snapshotsSeen: s.snapshotsSeen + 1,
    liveUpdatedAt: updatedAt,
  );
  if (changed) {
    // The one case that genuinely rebuilds the Library view: the host's
    // library content changed. Pure 400 ms ticks do NOT reach here.
    next = next.copy(live: library, liveSig: sig, viewDirty: true);
    if (next.persistEnabled && library != null) {
      // `persisted` mirrors the most recent queued write, so an offline
      // fallback always has the latest content we asked the store to hold.
      next = next.copy(
        persistDirty: true,
        persisted: library,
        persistedSig: sig,
        pendingPersist: PersistPayload(sig, encodePersisted(library)),
      );
      next.effects.add('persist');
    }
  } else {
    next = next.copy(live: library, liveSig: sig);
  }
  next = _resolvePending(next); // runs on EVERY snapshot (the host's reply)
  if (!sameList(next.trackers, trackers)) {
    next = next.copy(trackers: List.of(trackers), viewDirty: true);
  }
  return _maybeDerive(next);
}

LibraryState _onToggle(LibraryState s, String kind, LibraryItem item, bool on) {
  final lib = s.live;
  if (!s.connected || lib == null) {
    return s.copy(notice: 'Not connected to a computer — toggle dropped');
  }
  final current = _inSection(lib, kind, item.id);
  if (current == on) {
    return s.copy(notice: 'already $kind ${on ? 'on' : 'off'} — nothing sent');
  }
  final key = '$kind:${item.id}';
  if (s.pending.containsKey(key)) {
    return s.copy(notice: 'op already in flight ($key)');
  }
  final payload = encodeLibraryAction(kind, item, on);
  s.effects.add('command');
  return s.copy(
    pending: {
      ...s.pending,
      key: PendingOp(
        kind: kind,
        item: item,
        on: on,
        sentAtSnapshot: s.snapshotsSeen,
      ),
    },
    pendingCommand: LibraryCommand('libraryAction', payload),
    notice: 'sent $kind ${on ? 'on' : 'off'} ${item.name ?? item.id} → awaiting host reflection',
  );
}

LibraryState _onErrorFrame(LibraryState s, String message) {
  if (s.pending.isEmpty) {
    return s.copy(notice: 'error frame: $message');
  }
  final rejected = s.pending.length;
  return s.copy(
    pending: const {},
    opsRejected: s.opsRejected + rejected,
    notice: 'error frame — $rejected op(s) rejected: $message',
  );
}

LibraryState _onTogglePersistence(LibraryState s) {
  final enabled = !s.persistEnabled;
  var next = s.copy(persistEnabled: enabled, viewDirty: true);
  if (enabled && s.live != null && !s.persistDirty) {
    final encoded = encodePersisted(s.live!);
    next = next.copy(
      persistDirty: true,
      persisted: s.live,
      persistedSig: s.liveSig,
      pendingPersist: PersistPayload(s.liveSig, encoded),
    );
    next.effects.add('persist');
  }
  return _maybeDerive(next);
}

// ---------------------------------------------------------------------------
// Pending-op resolution: the host is the only writer. An op is resolved when
// the next snapshot's membership reflects it; rejected when a few snapshots
// pass without reflection (host ignored it, or an error frame arrived).
// ---------------------------------------------------------------------------

LibraryState _resolvePending(LibraryState s) {
  if (s.pending.isEmpty || s.live == null) return s;
  final lib = s.live!;
  var kept = <String, PendingOp>{};
  var resolved = 0;
  var rejected = 0;
  s.pending.forEach((key, op) {
    final reflected = _inSection(lib, op.kind, op.item.id) == op.on;
    if (reflected) {
      resolved++;
    } else {
      final seen = s.snapshotsSeen - op.sentAtSnapshot;
      if (seen >= rejectAfterSnapshots) {
        rejected++;
      } else {
        kept[key] = op;
      }
    }
  });
  if (resolved == 0 && rejected == 0) return s;
  return s.copy(
    pending: kept,
    opsResolved: s.opsResolved + resolved,
    opsRejected: s.opsRejected + rejected,
    notice: '$resolved op(s) reflected · $rejected op(s) rejected',
  );
}

// ---------------------------------------------------------------------------
// View derivation — the "refresh model" in concrete form.
//   disconnected + persisted data → show persisted, stale banner
//   disconnected + nothing       → needConnect empty state
//   connected + all empty        → emptyLibrary empty state
//   connected + any content      → live view
// ---------------------------------------------------------------------------

LibraryState _maybeDerive(LibraryState s) {
  if (!s.viewDirty) return s;
  return s.copy(
    view: _deriveView(s),
    viewDirty: false,
    viewRebuilds: s.viewRebuilds + 1,
  );
}

MyStuffView _deriveView(LibraryState s) {
  if (!s.connected) {
    if (s.persistEnabled && s.persisted != null && s.persisted!.hasItems) {
      return _buildView(s.persisted!, stale: true, trackers: const []);
    }
    return const MyStuffView(emptyKind: EmptyKind.needConnect);
  }
  final lib = s.live ?? const SnapshotLibrary();
  return _buildView(lib, stale: false, trackers: s.trackers);
}

MyStuffView _buildView(
  SnapshotLibrary lib, {
  required bool stale,
  required List<String> trackers,
}) {
  return MyStuffView(
    watchlist: lib.watchlist,
    history: lib.history,
    favorites: lib.favorites,
    stale: stale,
    trackers: trackers,
    emptyKind: lib.hasItems ? EmptyKind.none : EmptyKind.emptyLibrary,
    watchlistIds: {for (final i in lib.watchlist) i.id},
    historyIds: {for (final i in lib.history) i.id},
    favoriteIds: {for (final i in lib.favorites) i.id},
  );
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

bool sameList(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
