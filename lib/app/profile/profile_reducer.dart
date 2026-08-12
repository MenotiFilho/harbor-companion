// Pure Profile / who's-watching state model (ticket 08).
//
// `(ProfileState, ProfileEvent) => ProfileState` reducer producing an effects
// buffer the controller drains onto the WS client. No I/O, no timers: the
// controller folds the WS client's snapshots / connection status back in as
// events. Slim by design — who's-watching only, no account or Stremio linking.
//
// The decisions this module owns, and the seam tests pin:
//
//   - **profiles render from the snapshot**: `id`/`name`/`avatar`/`color`, with
//     the active profile taken from `snapshot.profile` (host-authoritative —
//     the phone never fakes who's watching).
//   - **select sends `setProfile {id}`**: a `Select` emits the command effect,
//     and the *next snapshot* reflects the active profile; nothing optimistic.
//   - **derive-on-change refresh**: the view re-derives only when the profile
//     list or the active id actually changes, never on the 400 ms tick.
//   - **derived empty states**: `needConnect` (disconnected) and `noProfiles`
//     (connected but the host reports none).
//
// Effects vocabulary (the Notifier → adapter surface):
//   `command` → send `pendingCommand` (setProfile) via the WS client.
//
// Wire contract: docs/wire-contract.md §2.1 (profile/profiles), §2.2
// (setProfile).

library;

import '../ws/client_reducer.dart' show Profile;

enum ProfileEmptyKind { none, needConnect, noProfiles }

/// A command the reducer wants the WS client to send (always setProfile).
class ProfileCommand {
  final String action;
  final Map<String, dynamic> payload;
  const ProfileCommand(this.action, this.payload);
}

// ---------------------------------------------------------------------------
// View model — exactly what the tab renders
// ---------------------------------------------------------------------------

class ProfileView {
  final List<Profile> profiles;
  final String? activeId;
  final ProfileEmptyKind emptyKind;

  const ProfileView({
    this.profiles = const [],
    this.activeId,
    this.emptyKind = ProfileEmptyKind.none,
  });
}

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

class ProfileState {
  final bool connected;
  final Profile? active; // active profile from the last snapshot
  final List<Profile> profiles; // last seen profile list
  final int viewRebuilds; // actual re-derivations of the view (not per-frame)
  final String? notice;
  final ProfileCommand? pendingCommand;
  final ProfileView view;
  final bool viewDirty; // internal: set when the view must be re-derived

  /// Effects buffer: the reducer appends effects here; the controller drains
  /// them. The one mutable field (impure by convention).
  final List<String> effects;

  ProfileState({
    this.connected = false,
    this.active,
    this.profiles = const [],
    this.viewRebuilds = 0,
    this.notice,
    this.pendingCommand,
    this.view = const ProfileView(),
    this.viewDirty = false,
    List<String>? effects,
  }) : effects = effects ?? <String>[];

  ProfileState copy({
    bool? connected,
    Profile? active,
    bool clearActive = false,
    List<Profile>? profiles,
    int? viewRebuilds,
    String? notice,
    bool clearNotice = false,
    ProfileCommand? pendingCommand,
    ProfileView? view,
    bool? viewDirty,
    List<String>? effects,
  }) {
    return ProfileState(
      connected: connected ?? this.connected,
      active: clearActive ? null : (active ?? this.active),
      profiles: profiles ?? this.profiles,
      viewRebuilds: viewRebuilds ?? this.viewRebuilds,
      notice: clearNotice ? null : (notice ?? this.notice),
      pendingCommand: pendingCommand ?? this.pendingCommand,
      view: view ?? this.view,
      viewDirty: viewDirty ?? this.viewDirty,
      effects: effects ?? this.effects,
    );
  }
}

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------

sealed class ProfileEvent {
  const ProfileEvent();
}

class Connected extends ProfileEvent {
  const Connected();
}

class Disconnected extends ProfileEvent {
  const Disconnected();
}

/// A fresh snapshot folded in from the WS client. [active] is the host's
/// `profile` field (null when absent); [profiles] the full list.
class SnapshotArrived extends ProfileEvent {
  final Profile? active;
  final List<Profile> profiles;
  const SnapshotArrived(this.active, this.profiles);
}

/// The user tapped a profile to switch who's watching.
class Select extends ProfileEvent {
  final String id;
  const Select(this.id);
}

// ---------------------------------------------------------------------------
// Reducer
// ---------------------------------------------------------------------------

ProfileState profileReduce(ProfileState s, ProfileEvent e) {
  switch (e) {
    case Connected():
      return _maybeDerive(s.copy(connected: true, viewDirty: true));

    case Disconnected():
      // Who's-watching dies with the socket; a reconnect re-emits on the next
      // changed snapshot. No persistence in v1 (slim by design).
      return _maybeDerive(s.copy(
        connected: false,
        clearActive: true,
        profiles: const [],
        viewDirty: true,
      ));

    case SnapshotArrived(active: final active, profiles: final profiles):
      final activeChanged = active?.id != s.active?.id;
      final listChanged = !_sameProfiles(s.profiles, profiles);
      if (!activeChanged && !listChanged) return s;
      return _maybeDerive(s.copy(
        active: active,
        profiles: profiles,
        viewDirty: true,
      ));

    case Select(id: final id):
      return _onSelect(s, id);
  }
}

ProfileState _onSelect(ProfileState s, String id) {
  if (!s.connected) {
    return s.copy(notice: 'Not connected to a computer — switch dropped');
  }
  if (id.isEmpty) {
    return s.copy(notice: 'This profile has no id — switch dropped');
  }
  final current = s.active;
  if (current?.id == id) {
    return s.copy(notice: 'Already watching as ${current!.displayName}');
  }
  final match = s.profiles.where((p) => p.id == id).toList();
  if (match.isEmpty) {
    return s.copy(notice: 'Unknown profile — switch dropped');
  }
  s.effects.add('command');
  return s.copy(
    pendingCommand: ProfileCommand('setProfile', {'id': id}),
    notice: 'Switching to ${match.first.displayName}…',
  );
}

bool _sameProfiles(List<Profile> a, List<Profile> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i].id != b[i].id ||
        a[i].name != b[i].name ||
        a[i].avatar != b[i].avatar ||
        a[i].color != b[i].color) {
      return false;
    }
  }
  return true;
}

// ---------------------------------------------------------------------------
// View derivation — the "refresh model" in concrete form.
//   disconnected        → needConnect empty state
//   connected, no list  → noProfiles empty state
//   connected, any list → the profile list + active id
// ---------------------------------------------------------------------------

ProfileState _maybeDerive(ProfileState s) {
  if (!s.viewDirty) return s;
  return s.copy(
    view: _deriveView(s),
    viewDirty: false,
    viewRebuilds: s.viewRebuilds + 1,
  );
}

ProfileView _deriveView(ProfileState s) {
  if (!s.connected) {
    return const ProfileView(emptyKind: ProfileEmptyKind.needConnect);
  }
  if (s.profiles.isEmpty) {
    return const ProfileView(emptyKind: ProfileEmptyKind.noProfiles);
  }
  return ProfileView(profiles: s.profiles, activeId: s.active?.id);
}
