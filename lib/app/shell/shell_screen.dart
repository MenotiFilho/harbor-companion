import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../home/home_screen.dart';
import '../library/library_screen.dart';
import '../profile/profile_screen.dart';
import '../remote/remote_screen.dart';
import '../routes.dart';
import '../search/search_screen.dart';
import '../update/update_controller.dart';
import '../update/update_reducer.dart';
import 'connect_first_view.dart';
import 'shell_controller.dart';
import 'shell_tab.dart';

/// The five-tab shell: Remote / Search / Home / My Stuff / Profile.
///
/// While [ShellState.showConnectFirst] every tab body is the connect-first
/// empty state pointing at settings — no tab can show content without a host.
/// The app bar's settings action stays available in every state, so a host can
/// be reconfigured after the first connect (the connect-first view alone
/// disappears once connected).
///
/// The shell also hosts the app-wide self-update prompt: it listens for
/// `promptVisible` and shows the "update available" dialog whenever the launch
/// (or a manual) check finds a newer release.
class ShellScreen extends ConsumerStatefulWidget {
  const ShellScreen({super.key});

  @override
  ConsumerState<ShellScreen> createState() => _ShellScreenState();
}

class _ShellScreenState extends ConsumerState<ShellScreen> {
  @override
  Widget build(BuildContext context) {
    final state = ref.watch(shellControllerProvider);
    final tab = state.activeTab;

    // Show the update prompt whenever the self-update check finds a newer
    // version (launch or manual). The dialog is the only "download consent"
    // surface for now — the download/install half is a later ticket.
    ref.listen(selfUpdateControllerProvider, (previous, next) {
      if (next.promptVisible && previous?.promptVisible != true) {
        _showUpdatePrompt(next.update);
      }
    });

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

  Future<void> _showUpdatePrompt(ReleaseInfo? update) {
    if (update == null) return Future.value();
    return showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Update available'),
        content: Text(
          'Harbor Companion ${update.versionName} is available.'
          '${update.notes == null ? '' : '\n\n${update.notes}'}',
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              ref.read(selfUpdateControllerProvider.notifier).dismissPrompt();
            },
            child: const Text('Later'),
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
        ShellTab.profile => const ProfileScreen(),
      };
}
