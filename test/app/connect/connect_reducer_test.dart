// Tests for the connect/settings state model (lib/app/connect/connect_reducer.dart).
//
// Pins the decisions validated by the connect prototype (#12) and the ticket
// 03 acceptance criteria: the warning gate, first-connect give-up vs.
// established-drop retry, backoff doubling to the cap, backgrounding
// pause/resume, launch auto-connect (incl. the cold-start drop-to-idle), scan
// candidacy, and registry teardown. The reducer is pure, so every case is a
// sequence of (event → assert state/effects).

import 'package:flutter_test/flutter_test.dart';

import 'package:harbor_companion/app/connect/connect_reducer.dart';

/// Helper: drain effects so subsequent asserts see a clean slate.
List<String> _drain(ConnectState s) {
  final e = List<String>.from(s.effects);
  s.effects.clear();
  return e;
}

ConnectState _withHost(ConnectState s, String id, String address,
    {String? name, bool warned = false, int? lastConnectedAt}) {
  return s.copy(hosts: [
    ...s.hosts,
    HostEntry(
      id: id,
      name: name ?? 'Host $id',
      address: address,
      warned: warned,
      lastConnectedAt: lastConnectedAt,
    ),
  ]);
}

void main() {
  group('open-LAN warning gate', () {
    test('adding a new host gates the first connect and emits warn', () {
      final s = connectReduce(ConnectState(), const AddHost('h1', 'desk', '192.168.1.10'));
      expect(s.warningHeld, isTrue);
      expect(_drain(s), contains('warn'));
      expect(s.selected?.address, '192.168.1.10:11471');
      expect(s.phase, ConnPhase.idle); // blocked, not connecting
    });

    test('connect while warning is held cannot proceed (no connect effect)', () {
      var s = connectReduce(ConnectState(), const AddHost('h1', 'desk', '192.168.1.10'));
      _drain(s);
      s = connectReduce(s, const ConnectRequested());
      expect(s.phase, ConnPhase.idle);
      expect(s.warningHeld, isTrue);
      expect(_drain(s), isNot(contains(anyOf(contains('connect:')))));
    });

    test('acknowledging the warning proceeds to connecting and marks host warned', () {
      var s = connectReduce(ConnectState(), const AddHost('h1', 'desk', '192.168.1.10'));
      _drain(s);
      s = connectReduce(s, const AcknowledgeWarning());
      expect(s.warningHeld, isFalse);
      expect(s.phase, ConnPhase.connecting);
      expect(s.selected?.warned, isTrue);
      expect(_drain(s), contains('connect:192.168.1.10:11471'));
    });

    test('a warned host is never gated again (reconnect and launch skip it)', () {
      var s = connectReduce(ConnectState(), const AddHost('h1', 'desk', '192.168.1.10'));
      _drain(s);
      s = connectReduce(s, const AcknowledgeWarning());
      _drain(s);
      s = connectReduce(s, const SocketOpened(Duration.zero));
      s = connectReduce(s, const SocketClosed('connection reset by peer'));
      _drain(s);
      // RetryNow (internal reconnect) should not re-gate.
      s = connectReduce(s, const RetryNow());
      expect(s.warningHeld, isFalse);
      expect(s.phase, ConnPhase.connecting);
      expect(s.selected?.warned, isTrue);
    });

    test('adding an already-saved address selects it and does not duplicate', () {
      var s = _withHost(ConnectState(), 'h1', '192.168.1.10:11471',
          name: 'desk', warned: true);
      s = connectReduce(s, const AddHost('h2', 'other', '192.168.1.10'));
      expect(s.hosts.length, 1);
      expect(s.selectedId, 'h1');
      expect(s.warningHeld, isFalse);
      expect(s.phase, ConnPhase.connecting); // warned → straight to connect
    });

    test('dismissing the warning keeps the host unwarned and re-gates', () {
      var s = connectReduce(ConnectState(), const AddHost('h1', 'desk', '192.168.1.10'));
      _drain(s);
      s = connectReduce(s, const DismissWarning());
      expect(s.warningHeld, isFalse);
      expect(s.selected?.warned, isFalse);
      // the next connect attempt re-gates (the gate is re-triggerable)
      s = connectReduce(s, const ConnectRequested());
      expect(s.warningHeld, isTrue);
      expect(_drain(s), contains('warn'));
    });
  });

  group('connection lifecycle', () {
    ConnectState connected() {
      var s = connectReduce(ConnectState(), const AddHost('h1', 'desk', '192.168.1.10'));
      _drain(s);
      s = connectReduce(s, const AcknowledgeWarning());
      _drain(s);
      s = connectReduce(s, const SocketOpened(Duration(seconds: 5)));
      return s;
    }

    test('socket open → connected, records lastConnectedAt, resets backoff', () {
      var s = connectReduce(ConnectState(), const AddHost('h1', 'desk', '192.168.1.10'));
      _drain(s);
      s = connectReduce(s, const AcknowledgeWarning());
      _drain(s);
      s = connectReduce(s, const SocketOpened(Duration(seconds: 5)));
      expect(s.phase, ConnPhase.connected);
      expect(s.selected?.lastConnectedAt, 5000);
      expect(s.reconnectAttempt, 0);
      expect(s.reconnectDelay, backoffFloor);
    });

    test('established-connection drop → reconnecting at floor, attempt 1', () {
      final s = connected();
      final after = connectReduce(s, const SocketClosed('connection reset by peer'));
      expect(after.phase, ConnPhase.reconnecting);
      expect(after.reconnectAttempt, 1);
      expect(after.reconnectDelay, backoffFloor);
      expect(_drain(after), contains('reconnectIn:400'));
    });

    test('reconnect attempt failures double the backoff up to the cap', () {
      var s = connected();
      s = connectReduce(s, const SocketClosed('drop'));
      expect(s.reconnectDelay, backoffFloor); // drop → floor
      _drain(s);
      // Sequence of observed delays after each failed attempt:
      // 800, 1600, 3000(cap), 3000, 3000 … give-up fires at maxReconnectAttempts.
      final expected = <int>[800, 1600, 3000, 3000, 3000, 3000];
      for (final delay in expected) {
        s = connectReduce(s, const RetryNow());
        _drain(s);
        s = connectReduce(s, const SocketClosed('no host'));
        expect(s.reconnectDelay.inMilliseconds, delay,
            reason: 'attempt ${s.reconnectAttempt}');
      }
      expect(s.phase, ConnPhase.reconnecting); // not yet given up
      expect(s.reconnectDelay, backoffCap);
    });

    test('a host that never connected gives up after maxReconnectAttempts', () {
      var s = connectReduce(ConnectState(), const AddHost('h1', 'far', '10.9.9.9'));
      _drain(s);
      s = connectReduce(s, const AcknowledgeWarning());
      _drain(s);
      s = connectReduce(s, const SocketClosed('no host at 10.9.9.9:11471'));
      expect(s.phase, ConnPhase.reconnecting);
      for (var attempt = 1; attempt < maxReconnectAttempts; attempt++) {
        s = connectReduce(s, const RetryNow());
        _drain(s);
        s = connectReduce(s, const SocketClosed('no host'));
      }
      expect(s.phase, ConnPhase.failed);
      expect(s.reconnectAttempt, maxReconnectAttempts);
      expect(_drain(s), contains('cancelReconnect'));
      expect(s.notice, contains('check the address'));
    });

    test('a host that connected before retries past the give-up threshold', () {
      var s = connected();
      for (var i = 0; i < maxReconnectAttempts * 2; i++) {
        s = connectReduce(s, const SocketClosed('drop'));
        _drain(s);
        s = connectReduce(s, const RetryNow());
        _drain(s);
        s = connectReduce(s, const SocketOpened(Duration(seconds: 30)));
      }
      expect(s.phase, ConnPhase.connected);
    });

    test('an established host that keeps failing never gives up', () {
      // Asymmetric give-up: a host we were connected to is a transient blip, so
      // it retries indefinitely — past the give-up threshold that would `failed`
      // a never-connected host.
      var s = connected();
      for (var i = 0; i < maxReconnectAttempts * 3; i++) {
        s = connectReduce(s, const SocketClosed('no host'));
        _drain(s);
        s = connectReduce(s, const RetryNow());
        _drain(s);
      }
      expect(s.phase, isNot(ConnPhase.failed));
      expect(s.notice, isNot(contains('check the address')));
    });

    test('retry from failed starts a fresh attempt counter', () {
      var s = connectReduce(ConnectState(), const AddHost('h1', 'far', '10.9.9.9'));
      _drain(s);
      s = connectReduce(s, const AcknowledgeWarning());
      _drain(s);
      for (var attempt = 0; attempt < maxReconnectAttempts; attempt++) {
        s = connectReduce(s, const SocketClosed('no host'));
        _drain(s);
        if (s.phase == ConnPhase.failed) break;
        s = connectReduce(s, const RetryNow());
        _drain(s);
      }
      expect(s.phase, ConnPhase.failed);
      s = connectReduce(s, const RetryNow());
      expect(s.phase, ConnPhase.connecting);
      expect(s.reconnectAttempt, 0); // fresh counter
      expect(s.reconnectDelay, backoffFloor);
    });

    test('disconnect while connected closes socket and cancels reconnect', () {
      var s = connected();
      final after = connectReduce(s, const DisconnectRequested());
      expect(after.phase, ConnPhase.idle);
      expect(after.reconnectAttempt, 0);
      final fx = _drain(after);
      expect(fx, contains('disconnect'));
      expect(fx, contains('cancelReconnect'));
    });

    test('manual connect to an offline previously-connected host still reconnects', () {
      // coldStart only applies to app-launch; a manual retry keeps the loop.
      var s = connected();
      s = connectReduce(s, const DisconnectRequested());
      _drain(s);
      s = connectReduce(s, const ConnectRequested());
      _drain(s);
      s = connectReduce(s, const SocketClosed('no host'));
      expect(s.phase, ConnPhase.reconnecting);
      expect(s.reconnectDelay, const Duration(milliseconds: 800));
    });
  });

  group('backgrounding', () {
    ConnectState reconnecting() {
      var s = connectReduce(ConnectState(), const AddHost('h1', 'desk', '192.168.1.10'));
      _drain(s);
      s = connectReduce(s, const AcknowledgeWarning());
      _drain(s);
      s = connectReduce(s, const SocketOpened(Duration.zero));
      s = connectReduce(s, const SocketClosed('drop'));
      return s;
    }

    test('background pauses the reconnect timer', () {
      final s = reconnecting();
      final after = connectReduce(s, const SetBackgrounded(true));
      expect(after.backgrounded, isTrue);
      expect(_drain(after), contains('cancelReconnect'));
    });

    test('foreground resumes the reconnect timer with the current backoff', () {
      var s = reconnecting();
      _drain(s);
      s = connectReduce(s, const SetBackgrounded(true));
      _drain(s);
      final after = connectReduce(s, const SetBackgrounded(false));
      expect(after.backgrounded, isFalse);
      expect(_drain(after), contains('reconnectIn:400'));
    });
  });

  group('app launch (auto-connect)', () {
    test('launch with no hosts just informs', () {
      final s = connectReduce(ConnectState(), const Launch(Duration.zero));
      expect(s.phase, ConnPhase.idle);
      expect(s.notice, contains('no saved hosts'));
    });

    test('launch falls back to the most recent host when none has connected', () {
      var s = _withHost(ConnectState(), 'h1', '192.168.1.10:11471',
          name: 'a', warned: true);
      s = _withHost(s, 'h2', '192.168.1.20:11471', name: 'b', warned: true);
      s = connectReduce(s, const Launch(Duration.zero));
      expect(s.selectedId, 'h2');
      expect(s.phase, ConnPhase.connecting);
      expect(_drain(s), contains('connect:192.168.1.20:11471'));
    });

    test('launch auto-connects to the last-used host, skipping the warning if warned', () {
      var s = _withHost(ConnectState(), 'h1', '192.168.1.10:11471',
          name: 'old', warned: true, lastConnectedAt: 100);
      s = _withHost(s, 'h2', '192.168.1.20:11471',
          name: 'new', warned: true, lastConnectedAt: 200);
      s = connectReduce(s, const Launch(Duration.zero));
      expect(s.selectedId, 'h2'); // last-used wins
      expect(s.warningHeld, isFalse);
      expect(s.phase, ConnPhase.connecting);
      expect(_drain(s), contains('connect:192.168.1.20:11471'));
    });

    test('launch to an unwarned last-used host gates on the warning', () {
      var s = _withHost(ConnectState(), 'h1', '192.168.1.10:11471',
          name: 'desk', warned: false, lastConnectedAt:100);
      s = connectReduce(s, const Launch(Duration.zero));
      expect(s.warningHeld, isTrue);
      expect(s.phase, ConnPhase.idle);
      expect(_drain(s), contains('warn'));
    });

    test('launch to an unreachable host drops to idle, not reconnect loop', () {
      var s = _withHost(ConnectState(), 'h1', '192.168.1.10:11471',
          name: 'desk', warned: true, lastConnectedAt: 100);
      s = connectReduce(s, const Launch(Duration.zero));
      _drain(s);
      s = connectReduce(s, const SocketClosed('no host at 192.168.1.10:11471'));
      expect(s.phase, ConnPhase.idle);
      expect(s.notice, contains('last used host unreachable'));
      expect(_drain(s), contains('cancelReconnect'));
    });

    test('a successful launch connect ends the cold-start window', () {
      var s = _withHost(ConnectState(), 'h1', '192.168.1.10:11471',
          name: 'desk', warned: true, lastConnectedAt: 100);
      s = connectReduce(s, const Launch(Duration.zero));
      _drain(s);
      s = connectReduce(s, const SocketOpened(Duration(seconds: 5)));
      expect(s.coldStart, isFalse);
      // a later drop + failed reconnect retries, not a cold-start drop-to-idle
      s = connectReduce(s, const SocketClosed('drop'));
      s = connectReduce(s, const RetryNow());
      s = connectReduce(s, const SocketClosed('no host'));
      expect(s.phase, ConnPhase.reconnecting);
      expect(s.notice, isNot(contains('last used host unreachable')));
    });
  });

  group('LAN scan', () {
    test('start scan marks scanning and emits probe', () {
      final s = connectReduce(ConnectState(), const StartScan());
      expect(s.scanning, isTrue);
      expect(_drain(s), contains('scan:start'));
    });

    test('scan results are candidates; a saved address is skipped', () {
      var s = _withHost(ConnectState(), 'h1', '192.168.1.10:11471',
          name: 'desk');
      s = connectReduce(s, const StartScan());
      _drain(s);
      s = connectReduce(s, const ScanResultFound('192.168.1.10')); // already saved
      expect(s.scanResults, isEmpty);
      s = connectReduce(s, const ScanResultFound('192.168.1.77'));
      expect(s.scanResults.length, 1);
      // duplicates within a scan are dropped
      s = connectReduce(s, const ScanResultFound('192.168.1.77'));
      expect(s.scanResults.length, 1);
    });

    test('scan never auto-connects; picking a result hits the warning gate', () {
      var s = connectReduce(ConnectState(), const StartScan());
      _drain(s);
      s = connectReduce(s, const ScanResultFound('192.168.1.77'));
      s = connectReduce(s, const ScanDone());
      expect(s.scanning, isFalse);
      expect(s.phase, ConnPhase.idle); // nothing auto-connected
      // pick the first result → new host, gated on the warning
      s = connectReduce(s, const AddHost('h9', 'Found host', '192.168.1.77:11471'));
      expect(s.warningHeld, isTrue);
      expect(s.phase, ConnPhase.idle);
    });
  });

  group('host registry', () {
    test('address normalization appends the default port', () {
      var s = connectReduce(ConnectState(), const AddHost('h1', 'desk', '192.168.1.10'));
      expect(s.selected?.address, '192.168.1.10:11471');
    });

    test('editing a host updates name and address', () {
      var s = connectReduce(ConnectState(), const AddHost('h1', 'desk', '192.168.1.10'));
      s = connectReduce(s, const UpdateHost('h1', name: 'living', address: '10.0.0.5'));
      expect(s.selected?.name, 'living');
      expect(s.selected?.address, '10.0.0.5:11471');
    });

    test('deleting the active connected host tears the socket down and falls back', () {
      var s = connectReduce(ConnectState(), const AddHost('h1', 'desk', '192.168.1.10'));
      _drain(s);
      s = connectReduce(s, const AcknowledgeWarning());
      _drain(s);
      s = connectReduce(s, const SocketOpened(Duration.zero));
      s = _withHost(s, 'h2', '192.168.1.20:11471', name: 'backup');
      s = connectReduce(s, const RemoveHost('h1'));
      expect(s.hosts.any((h) => h.id == 'h1'), isFalse);
      expect(s.selectedId, 'h2');
      final fx = _drain(s);
      expect(fx, contains('disconnect'));
      expect(fx, contains('cancelReconnect'));
    });

    test('deleting a non-selected host leaves the selection alone', () {
      var s = _withHost(ConnectState(), 'h1', '192.168.1.10:11471', name: 'a');
      s = _withHost(s, 'h2', '192.168.1.20:11471', name: 'b');
      s = connectReduce(s, const SelectHost('h1'));
      s = connectReduce(s, const RemoveHost('h2'));
      expect(s.selectedId, 'h1');
      expect(s.hosts.length, 1);
    });

    test('selecting another host while connected switches (tears down + connects)', () {
      var s = connectReduce(ConnectState(), const AddHost('h1', 'desk', '192.168.1.10'));
      _drain(s);
      s = connectReduce(s, const AcknowledgeWarning());
      _drain(s);
      s = connectReduce(s, const SocketOpened(Duration.zero)); // connected to h1
      s = _withHost(s, 'h2', '192.168.1.20:11471', name: 'laptop', warned: true);
      final after = connectReduce(s, const SelectHost('h2'));
      final fx = _drain(after);
      expect(fx, contains('disconnect'));
      expect(after.selectedId, 'h2');
      expect(after.phase, ConnPhase.connecting);
      expect(fx, contains('connect:192.168.1.20:11471'));
    });
  });
}
