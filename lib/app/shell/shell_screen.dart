import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'connect_first_view.dart';
import 'shell_controller.dart';
import 'shell_tab.dart';
import 'tab_placeholder.dart';

/// The five-tab shell: Remote / Search / Home / My Stuff / Profile.
///
/// While [ShellState.showConnectFirst] every tab body is the connect-first
/// empty state pointing at settings — no tab can show content without a host.
class ShellScreen extends ConsumerWidget {
  const ShellScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(shellControllerProvider);
    final tab = state.activeTab;

    return Scaffold(
      body: state.showConnectFirst
          ? const ConnectFirstView()
          : TabPlaceholder(title: tab.meta.label, icon: tab.meta.icon),
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
}
