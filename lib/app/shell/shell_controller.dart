import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../connect/connect_controller.dart';
import '../update/update_controller.dart';
import 'shell_reducer.dart';
import 'shell_tab.dart';

/// The live connection status of the app.
///
/// This is the seam the WS client (ticket 02) and the connect controller
/// (ticket 03) drive. For the scaffold it starts `disconnected`; later tickets
/// call [ConnectionStatusController.set] as the socket and connect lifecycle
/// move.
class ConnectionStatusController extends Notifier<ConnectionStatus> {
  @override
  ConnectionStatus build() => ConnectionStatus.disconnected;

  void set(ConnectionStatus status) => state = status;
}

final connectionStatusProvider =
    NotifierProvider<ConnectionStatusController, ConnectionStatus>(
  ConnectionStatusController.new,
);

/// Owns [ShellState], folding live connection changes into the pure reducer so
/// the active tab survives a reconnect (only `ConnectionChanged` un-gates).
class ShellController extends Notifier<ShellState> {
  @override
  ShellState build() {
    // Instantiate the connect controller so its `Launch` auto-connect runs at
    // startup; it drives the connection the shell renders. One-time init, not
    // a reactive dependency. Same for the self-update controller, whose
    // `Launch` check runs once at startup (its foreground-return no-op lives in
    // main.dart's lifecycle observer).
    ref.read(connectControllerProvider);
    ref.read(selfUpdateControllerProvider);
    ref.listen(connectionStatusProvider, (previous, next) {
      state = shellReduce(state, ConnectionChanged(next));
    });
    final connection = ref.read(connectionStatusProvider);
    return shellReduce(const ShellState(), ConnectionChanged(connection));
  }

  void selectTab(ShellTab tab) {
    state = shellReduce(state, SelectTab(tab));
  }
}

final shellControllerProvider =
    NotifierProvider<ShellController, ShellState>(ShellController.new);
