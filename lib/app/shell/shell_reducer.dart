import 'shell_tab.dart';

/// The connection status the shell renders against. This is the seam the WS
/// layer (ticket 02) and the connect controller (ticket 03) feed into; for the
/// scaffold it starts disconnected and is driven by tests and the wiring seam.
enum ConnectionStatus { disconnected, connecting, connected }

/// Shell state: which tab is active, and whether the app has a live
/// connection. `showConnectFirst` gates every tab body while disconnected, so
/// no tab can show content without a host — the connect-first empty state
/// (pointing at settings) is the whole first-run experience.
class ShellState {
  final ShellTab activeTab;
  final ConnectionStatus connection;

  const ShellState({
    this.activeTab = ShellTab.home,
    this.connection = ConnectionStatus.disconnected,
  });

  bool get showConnectFirst => connection != ConnectionStatus.connected;
}

sealed class ShellEvent {
  const ShellEvent();
}

class SelectTab extends ShellEvent {
  final ShellTab tab;
  const SelectTab(this.tab);
}

class ConnectionChanged extends ShellEvent {
  final ConnectionStatus status;
  const ConnectionChanged(this.status);
}

/// Pure reducer: `(ShellState, ShellEvent) => ShellState`.
///
/// Navigation always works — switching tabs never connects or disconnects, and
/// a tab change alone can't un-gate the connect-first body. Only a
/// `ConnectionChanged` to connected does.
ShellState shellReduce(ShellState s, ShellEvent e) {
  switch (e) {
    case SelectTab(:final tab):
      return ShellState(activeTab: tab, connection: s.connection);
    case ConnectionChanged(:final status):
      return ShellState(activeTab: s.activeTab, connection: status);
  }
}
