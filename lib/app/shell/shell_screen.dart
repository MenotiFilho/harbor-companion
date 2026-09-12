import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../background/background_controller.dart';
import '../background/notification_permission_dialog.dart';
import '../background/open_remote_request.dart';
import '../home/home_screen.dart';
import '../library/library_screen.dart';
import '../profile/profile_screen.dart';
import '../remote/remote_screen.dart';
import '../routes.dart';
import '../search/search_screen.dart';
import '../update/update_controller.dart';
import '../update/update_reducer.dart';
import 'connect_first_view.dart';
import 'player_bar.dart';
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
    // version (launch or manual). Tapping Update begins the install half;
    // install failures and the lazy install-permission grant surface as
    // snackbars here in the shell.
    ref.listen(selfUpdateControllerProvider, (previous, next) {
      if (next.promptVisible && previous?.promptVisible != true) {
        _showUpdatePrompt(next.update);
      }
      if (next.status == UpdateStatus.installFailed &&
          previous?.status != UpdateStatus.installFailed) {
        _showSnack(next.notice ?? next.lastError ?? 'Update failed');
      }
      if (next.awaitingInstallPermission &&
          !(previous?.awaitingInstallPermission ?? false)) {
        _showSnack('Allow "Install unknown apps" to update Harbor Companion');
      }
    });

    // A notification body tap (background module) requests the Remote tab; do
    // the same pop-to-root + select the mini-player does. A monotonically
    // increasing counter means every request is observed, and the first build
    // (0) never fires.
    ref.listen(openRemoteRequestProvider, (previous, next) {
      if (next > (previous ?? 0)) _openRemote();
    });

    // The background module decides when the notification rationale is due
    // (#67): the first successful connect with the toggle on, behind this
    // in-app dialog. The reducer never fires the OS prompt cold.
    ref.listen(backgroundControllerProvider, (previous, next) {
      if (next.rationaleVisible && previous?.rationaleVisible != true) {
        _showNotificationRationale();
      }
      // The reactive battery nudge (#68) is a dismissible shell notice shown
      // over the current screen. It is never a banner on the Remote: the
      // decision lives in the background reducer, the shell only presents it.
      if (next.batteryNudgeVisible && previous?.batteryNudgeVisible != true) {
        _showBatteryNudge();
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
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // The floating mini-player rides above the nav bar on every tab
          // except Remote (where the full transport already lives).
          if (tab != ShellTab.remote) const PlayerBar(safeArea: false),
          NavigationBar(
            selectedIndex: tab.index,
            onDestinationSelected: (index) => ref
                .read(shellControllerProvider.notifier)
                .selectTab(ShellTab.values[index]),
            destinations: [
              for (final tab in ShellTab.values)
                NavigationDestination(
                  icon: Icon(tab.meta.icon),
                  selectedIcon: Icon(tab.meta.selectedIcon),
                  label: tab.meta.label,
                ),
            ],
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
          FilledButton(
            onPressed: () {
              Navigator.of(context).pop();
              ref.read(selfUpdateControllerProvider.notifier).acceptUpdate();
            },
            child: const Text('Update'),
          ),
        ],
      ),
    );
  }

  /// Shows the in-app rationale and folds the user's answer back in: accepting
  /// emits the real OS prompt, declining cancels it without one.
  Future<void> _showNotificationRationale() async {
    final accepted = await showNotificationPermissionRationale(context);
    if (!mounted) return;
    final background = ref.read(backgroundControllerProvider.notifier);
    if (accepted) {
      background.acceptNotificationRationale();
    } else {
      background.declineNotificationRationale();
    }
  }

  /// Presents the reactive battery nudge (ADR-0007) and folds its dismissal
  /// back in. Dismissal (the action, a swipe, or the timeout) clears the flag
  /// and feeds the throttle, so the notice cannot spam.
  void _showBatteryNudge() {
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    final controller = messenger.showSnackBar(
      SnackBar(
        content: const Text(
          'Android may have paused the connection while Harbor Companion was in '
          'the background. Exempt it from battery optimization to keep it alive '
          'with the screen off.',
        ),
        action: SnackBarAction(
          label: 'Settings',
          onPressed: () {
            ref
                .read(backgroundControllerProvider.notifier)
                .dismissBatteryNudge();
            Navigator.of(context).pushNamed(AppRoutes.settings);
          },
        ),
      ),
    );
    controller.closed.then((_) {
      if (mounted) {
        ref.read(backgroundControllerProvider.notifier).dismissBatteryNudge();
      }
    });
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// Opens the Remote tab, popping any pushed route (settings/detail) first so
  /// the tab is actually visible. Mirrors [PlayerBar]'s open-Remote.
  void _openRemote() {
    Navigator.of(context).popUntil((route) => route.isFirst);
    ref.read(shellControllerProvider.notifier).selectTab(ShellTab.remote);
  }

  Widget _tabBody(ShellTab tab) => switch (tab) {
        ShellTab.home => const HomeScreen(),
        ShellTab.remote => const RemoteScreen(),
        ShellTab.search => const SearchScreen(),
        ShellTab.myStuff => const LibraryScreen(),
        ShellTab.profile => const ProfileScreen(),
      };
}
