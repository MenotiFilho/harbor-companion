// Profile / who's-watching tab (ticket 08; editorial refresh ticket 89).
//
// Renders the pure reducer's view: the host's profiles as hairline rows with
// the active one marked in the Accent, derived empty states (needConnect /
// noProfiles), and tap-to-switch. Everything derives from the snapshot — the
// phone never optimistically flips who's watching, and there is no account or
// Stremio linking surface. There is also no add/edit-profile affordance: the
// Host API has no such action, so the UI does not pretend it has one.
//
// Glass budget (ADR-0010): the list rows are translucent fill + hairline,
// never BackdropFilter.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../theme.dart';
import '../ui/rows.dart';
import '../ws/client_reducer.dart' show Profile;
import 'profile_controller.dart';
import 'profile_reducer.dart';

class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(profileControllerProvider);
    final view = state.view;

    return switch (view.emptyKind) {
      ProfileEmptyKind.needConnect =>
        const _EmptyState(kind: ProfileEmptyKind.needConnect),
      ProfileEmptyKind.noProfiles =>
        const _EmptyState(kind: ProfileEmptyKind.noProfiles),
      ProfileEmptyKind.none => _ProfileList(
          profiles: view.profiles,
          activeId: view.activeId,
          onSelect: (id) =>
              ref.read(profileControllerProvider.notifier).select(id),
        ),
    };
  }
}

class _ProfileList extends StatelessWidget {
  final List<Profile> profiles;
  final String? activeId;
  final ValueChanged<String> onSelect;
  const _ProfileList({
    required this.profiles,
    required this.activeId,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
      itemCount: profiles.length,
      itemBuilder: (context, i) {
        final profile = profiles[i];
        return _ProfileTile(
          profile: profile,
          active: profile.id == activeId,
          onTap: () => onSelect(profile.id),
        );
      },
    );
  }
}

/// One profile row. The active profile is marked twice in the same family —
/// the 'Watching' subtitle and the trailing check, both in the Accent — while
/// the rest of the list stays quiet. The whole row is the switch affordance;
/// there is deliberately no add/edit button.
class _ProfileTile extends StatelessWidget {
  final Profile profile;
  final bool active;
  final VoidCallback onTap;
  const _ProfileTile({
    required this.profile,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    return ListRow(
      leading: _ProfileAvatar(profile: profile),
      title: profile.displayName,
      subtitle: active ? 'Watching' : null,
      subtitleColor: active ? tokens.accentInk : null,
      trailing: active ? Icon(Icons.check_circle, color: tokens.accent) : null,
      onTap: onTap,
    );
  }
}

class _ProfileAvatar extends StatelessWidget {
  final Profile profile;
  const _ProfileAvatar({required this.profile});

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    final color = _parseHexColor(profile.color) ?? scheme.primaryContainer;
    final display = profile.displayName;
    final initial = display.isEmpty
        ? '?'
        : display.characters.first.toUpperCase();
    final avatar = profile.avatar;

    if (avatar != null && avatar.isNotEmpty) {
      return CircleAvatar(
        backgroundColor: color,
        // The initial sits on a saturated profile color: dark ink holds AA.
        foregroundColor: tokens.onAccent,
        backgroundImage: NetworkImage(avatar),
        onBackgroundImageError: (_, _) {},
        child: Text(initial),
      );
    }
    return CircleAvatar(
      backgroundColor: color,
      foregroundColor: tokens.onAccent,
      child: Text(initial),
    );
  }
}

/// Parses a hex color string (`#RRGGBB`, `RRGGBB`, or `AARRGGBB`) into a
/// [Color]; null when absent or not a valid hex.
Color? _parseHexColor(String? s) {
  if (s == null) return null;
  var hex = s.trim();
  if (hex.startsWith('#')) hex = hex.substring(1);
  if (hex.length == 6) hex = 'FF$hex';
  if (hex.length != 8) return null;
  final v = int.tryParse(hex, radix: 16);
  return v == null ? null : Color(v);
}

class _EmptyState extends StatelessWidget {
  final ProfileEmptyKind kind;
  const _EmptyState({required this.kind});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final needConnect = kind == ProfileEmptyKind.needConnect;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              needConnect ? Icons.cast_connected : Icons.people_outline,
              size: 48,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text(
              needConnect ? 'Connect to switch profiles' : 'No profiles',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              needConnect
                  ? 'Add or select a host in Settings to pick who’s watching.'
                  : 'This computer hasn’t set up any profiles yet.',
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
