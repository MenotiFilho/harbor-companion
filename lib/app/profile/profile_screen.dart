// Profile / who's-watching tab (ticket 08).
//
// Renders the pure reducer's view: the host's profile list with the active
// profile highlighted, derived empty states (needConnect / noProfiles), and
// tap-to-switch. Everything derives from the snapshot — the phone never
// optimistically flips who's watching, and there is no account/Stremio linking
// surface.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 12),
      itemCount: profiles.length,
      separatorBuilder: (_, _) => const Divider(height: 1, indent: 72),
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
    final scheme = Theme.of(context).colorScheme;
    final name = profile.displayName;
    return ListTile(
      onTap: onTap,
      leading: _ProfileAvatar(profile: profile),
      title: Text(name),
      subtitle: active
          ? Text(
              'Watching',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.primary),
            )
          : null,
      trailing: active
          ? Icon(Icons.check_circle, color: scheme.primary)
          : const Icon(Icons.person_outline, color: Colors.transparent),
    );
  }
}

class _ProfileAvatar extends StatelessWidget {
  final Profile profile;
  const _ProfileAvatar({required this.profile});

  @override
  Widget build(BuildContext context) {
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
        backgroundImage: NetworkImage(avatar),
        onBackgroundImageError: (_, _) {},
        child: Text(initial),
      );
    }
    return CircleAvatar(backgroundColor: color, child: Text(initial));
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
