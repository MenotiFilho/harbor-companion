import 'package:flutter_test/flutter_test.dart';

import 'package:harbor_companion/app/shell/shell_reducer.dart';
import 'package:harbor_companion/app/shell/shell_tab.dart';

void main() {
  group('ShellState defaults', () {
    test('fresh install opens on the Home tab, disconnected', () {
      final s = const ShellState();
      expect(s.activeTab, ShellTab.home);
      expect(s.connection, ConnectionStatus.disconnected);
    });

    test('showConnectFirst is true while disconnected', () {
      expect(const ShellState().showConnectFirst, isTrue);
    });

    test('showConnectFirst is true while connecting', () {
      const s = ShellState(connection: ConnectionStatus.connecting);
      expect(s.showConnectFirst, isTrue);
    });

    test('showConnectFirst is false once connected', () {
      const s = ShellState(connection: ConnectionStatus.connected);
      expect(s.showConnectFirst, isFalse);
    });
  });

  group('SelectTab', () {
    test('switches the active tab', () {
      final s = shellReduce(const ShellState(), const SelectTab(ShellTab.search));
      expect(s.activeTab, ShellTab.search);
      expect(s.connection, ConnectionStatus.disconnected);
    });

    test('every tab is reachable while disconnected (nav always works)', () {
      for (final tab in ShellTab.values) {
        final s = shellReduce(const ShellState(), SelectTab(tab));
        expect(s.activeTab, tab);
        expect(s.showConnectFirst, isTrue, reason: '$tab must stay gated offline');
      }
    });

    test('selecting a tab while connected shows that tab', () {
      const connected = ShellState(connection: ConnectionStatus.connected);
      final s = shellReduce(connected, const SelectTab(ShellTab.profile));
      expect(s.activeTab, ShellTab.profile);
      expect(s.showConnectFirst, isFalse);
    });
  });

  group('ConnectionChanged', () {
    test('moving to connected un-gates the body but keeps the active tab', () {
      final s = shellReduce(
        const ShellState(),
        const ConnectionChanged(ConnectionStatus.connected),
      );
      expect(s.connection, ConnectionStatus.connected);
      expect(s.showConnectFirst, isFalse);
      expect(s.activeTab, ShellTab.home);
    });

    test('dropping back to disconnected re-gates the body', () {
      final s = shellReduce(
        const ShellState(connection: ConnectionStatus.connected),
        const ConnectionChanged(ConnectionStatus.disconnected),
      );
      expect(s.connection, ConnectionStatus.disconnected);
      expect(s.showConnectFirst, isTrue);
    });
  });
}
