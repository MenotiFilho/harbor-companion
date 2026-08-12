import 'package:flutter/material.dart';

/// The five tabs of the companion shell, in the reference's order.
///
/// Order matches Harbor's `MobileShell`: Remote / Search / Home / My Stuff /
/// Profile.
enum ShellTab {
  remote,
  search,
  home,
  myStuff,
  profile;

  /// Display metadata for each tab. Single source of truth for the label and
  /// icons the shell renders — the navigation bar and the placeholder bodies
  /// both read from here, so a new tab is one entry, not three.
  ShellTabMeta get meta => switch (this) {
        ShellTab.remote => const ShellTabMeta(
            label: 'Remote',
            icon: Icons.settings_remote_outlined,
            selectedIcon: Icons.settings_remote,
          ),
        ShellTab.search => const ShellTabMeta(
            label: 'Search',
            icon: Icons.search,
            selectedIcon: Icons.search,
          ),
        ShellTab.home => const ShellTabMeta(
            label: 'Home',
            icon: Icons.home_outlined,
            selectedIcon: Icons.home,
          ),
        ShellTab.myStuff => const ShellTabMeta(
            label: 'My Stuff',
            icon: Icons.bookmark_outline,
            selectedIcon: Icons.bookmark,
          ),
        ShellTab.profile => const ShellTabMeta(
            label: 'Profile',
            icon: Icons.person_outline,
            selectedIcon: Icons.person,
          ),
      };
}

class ShellTabMeta {
  final String label;
  final IconData icon;
  final IconData selectedIcon;

  const ShellTabMeta({
    required this.label,
    required this.icon,
    required this.selectedIcon,
  });
}
