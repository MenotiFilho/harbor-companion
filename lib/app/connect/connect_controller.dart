// Riverpod controller for connect/settings (ticket 03).
//
// Thin glue between the pure reducer (connect_reducer.dart) and the outside
// world: the WS client (transport), the host registry store (persistence), the
// subnet scanner, and a reconnect timer. It drains the reducer's `effects`
// buffer into those side-channels and folds the WS client's socket open/close
// back in as [SocketOpened]/[SocketClosed] events.
//
// The connect layer owns the connection *schedule* (warning gate, cold-start,
// asymmetric give-up, reconnect backoff); it drives the WS client as a pure
// transport by disabling the client's own auto-reconnect and re-driving
// `connect()` on each retry.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../ws/client_controller.dart';
import '../ws/client_reducer.dart' show WsStatus;
import 'connect_reducer.dart';
import 'host_registry.dart';
import 'lan_scan.dart';

/// Default clock: milliseconds since epoch. Tests override with a manual clock.
final connectClockProvider = Provider<Duration Function()>(
  (ref) => () => Duration(milliseconds: DateTime.now().millisecondsSinceEpoch),
);

/// Host registry persistence seam. Defaults to an in-memory store; the
/// shared_preferences-backed store is wired in main(). Tests override.
final hostRegistryStoreProvider =
    Provider<HostRegistryStore>((ref) => InMemoryHostRegistryStore());

/// Subnet scanner seam. Defaults to the real TCP-probe scanner; tests override.
final subnetScannerProvider =
    Provider<SubnetScanner>((ref) => TcpProbeScanner());

class ConnectController extends Notifier<ConnectState> {
  Timer? _reconnectTimer;
  StreamSubscription<String>? _scanSub;
  List<HostEntry> _lastSaved = const [];
  bool _restored = false;

  @override
  ConnectState build() {
    ref.onDispose(() {
      _reconnectTimer?.cancel();
      _scanSub?.cancel();
    });

    // The connect layer owns the reconnect schedule; the WS client stops
    // self-reconnecting so the two state machines stay in lockstep.
    ref.read(wsClientControllerProvider.notifier).setAutoReconnect(false);

    // Fold the WS client's socket transitions into the reducer.
    ref.listen(wsClientControllerProvider, (previous, next) {
      if (next.status == WsStatus.connected &&
          previous?.status != WsStatus.connected &&
          state.phase == ConnPhase.connecting) {
        _dispatch(SocketOpened(clock()));
      } else if (next.status == WsStatus.reconnecting &&
          (previous?.status == WsStatus.connected ||
              previous?.status == WsStatus.connecting)) {
        _dispatch(SocketClosed(next.lastError ?? 'connection closed'));
      }
    });

    _restore();
    return ConnectState();
  }

  Future<void> _restore() async {
    final hosts = await ref.read(hostRegistryStoreProvider).load();
    if (!ref.mounted) return;
    _lastSaved = hosts;
    _restored = true;
    _dispatch(RestoreHosts(hosts));
    _dispatch(Launch(clock()));
  }

  Duration clock() => ref.read(connectClockProvider)();

  // -- UI entry points -------------------------------------------------------

  void addHost(String id, String name, String address) =>
      _dispatch(AddHost(id, name, address));

  void updateHost(String id, {String? name, String? address}) =>
      _dispatch(UpdateHost(id, name: name, address: address));

  void removeHost(String id) => _dispatch(RemoveHost(id));

  void selectHost(String id) => _dispatch(SelectHost(id));

  void connect() => _dispatch(ConnectRequested());

  void acknowledgeWarning() => _dispatch(AcknowledgeWarning());

  void dismissWarning() => _dispatch(DismissWarning());

  void disconnect() => _dispatch(DisconnectRequested());

  void retry() => _dispatch(RetryNow());

  void setBackgrounded(bool value) => _dispatch(SetBackgrounded(value));

  void startScan() => _dispatch(StartScan());

  /// Saves a scan candidate as a real host (a scan never auto-adds); this is
  /// the same AddHost path, so it hits the warning gate.
  void addScanCandidate(HostEntry candidate, String name) =>
      _dispatch(AddHost(candidate.id, name, candidate.address));

  // -- The one place state mutates -------------------------------------------

  void _dispatch(ConnectEvent event) {
    state = connectReduce(state, event);
    _afterState(state);
  }

  void _afterState(ConnectState next) {
    _drain(next);
    _syncRegistry(next);
  }

  /// Maps the effects buffer onto the side-channels.
  void _drain(ConnectState next) {
    if (next.effects.isEmpty) return;
    final effects = List<String>.from(next.effects);
    next.effects.clear();
    for (final effect in effects) {
      if (effect == 'warn') {
        // No side-channel: the UI reads `warningHeld` and shows the gate.
      } else if (effect.startsWith('connect:')) {
        final addr = effect.substring('connect:'.length);
        ref.read(wsClientControllerProvider.notifier).connect(addr);
      } else if (effect == 'disconnect') {
        ref.read(wsClientControllerProvider.notifier).disconnect();
      } else if (effect.startsWith('reconnectIn:')) {
        final ms = int.tryParse(effect.substring('reconnectIn:'.length)) ?? 0;
        _armReconnect(ms);
      } else if (effect == 'cancelReconnect') {
        _reconnectTimer?.cancel();
        _reconnectTimer = null;
      } else if (effect == 'scan:start') {
        _runScan();
      }
    }
  }

  void _armReconnect(int ms) {
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(milliseconds: ms), () {
      _dispatch(RetryNow());
    });
  }

  void _runScan() {
    _scanSub?.cancel();
    _scanSub = ref.read(subnetScannerProvider).scan().listen(
      (address) => _dispatch(ScanResultFound(address)),
      onDone: () => _dispatch(ScanDone()),
      onError: (Object _) => _dispatch(ScanDone()),
    );
  }

  /// Persists the registry whenever the host list actually changes (including
  /// `warned` and `lastConnectedAt`, which ride the HostEntry).
  void _syncRegistry(ConnectState next) {
    if (!_restored) return;
    final changed = encodeRegistry(next.hosts) != encodeRegistry(_lastSaved);
    if (!changed) return;
    _lastSaved = List<HostEntry>.from(next.hosts);
    ref.read(hostRegistryStoreProvider).save(_lastSaved);
  }
}

final connectControllerProvider =
    NotifierProvider<ConnectController, ConnectState>(ConnectController.new);
