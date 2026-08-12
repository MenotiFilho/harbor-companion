import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../home/home_screen.dart';
import '../library/library_screen.dart';
import '../remote/remote_screen.dart';
import '../routes.dart';
import '../search/search_screen.dart';
import 'connect_first_view.dart';
import 'shell_controller.dart';
import 'shell_tab.dart';
import 'tab_placeholder.dart';

/// The five-tab shell: Remote / Search / Home / My Stuff / Profile.
///
/// While [ShellState.showConnectFirst] every tab body is the connect-first
/// empty state pointing at settings — no tab can show content without a host.
/// The app bar's settings action stays available in every state, so a host can
/// be reconfigured after the first connect (the connect-first view alone
/// disappears once connected).
class ShellScreen extends ConsumerWidget {
  const ShellScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(shellControllerProvider);
    final tab = state.activeTab;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Harbor Companion'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Settings',
            onPressed: () => Navigator.of(context).pushNamed(AppRoutes.settings),
          ),
        ],
      ),
      body: state.showConnectFirst
          ? const ConnectFirstView()
          : _tabBody(tab),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab.index,
        onDestinationSelected: (index) =>
            ref.read(shellControllerProvider.notifier).selectTab(ShellTab.values[index]),
        destinations: [
          for (final tab in ShellTab.values)
            NavigationDestination(
              icon: Icon(tab.meta.icon),
              selectedIcon: Icon(tab.meta.selectedIcon),
              label: tab.meta.label,
            ),
        ],
      ),
    );
  }

  Widget _tabBody(ShellTab tab) => switch (tab) {
        ShellTab.home => const HomeScreen(),
        ShellTab.remote => const RemoteScreen(),
        ShellTab.search => const SearchScreen(),
        ShellTab.myStuff => const LibraryScreen(),
        _ => TabPlaceholder(title: tab.meta.label, icon: tab.meta.icon),
      };
}
