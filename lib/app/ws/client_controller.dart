// Riverpod controller for the WS client (ticket 02).
//
// Thin glue between the pure reducer (client_reducer.dart) and the outside
// world. Drains the reducer's `outgoing` buffer onto a [WsTransport], folds
// inbound frames back in as [Frame] events, owns the reconnect timer (armed on
// `reconnectAt`, paused while backgrounded), persists host keys through a
// [HostKeyStore], and mirrors the effective connection status into the shell
// seam so the UI can un-gate.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../shell/shell_controller.dart';
import '../shell/shell_reducer.dart';
import 'client_reducer.dart';
import 'host_keys.dart';
import 'ws_transport.dart';

/// Default clock: milliseconds since epoch, matching the reducer's virtual
/// time. Tests override this provider with a manual clock.
final wsClockProvider = Provider<Duration Function()>(
  (ref) => () => Duration(milliseconds: DateTime.now().millisecondsSinceEpoch),
);

/// Socket seam. Defaults to the real dart:io transport; tests override.
final wsTransportProvider = Provider<WsTransport>((ref) => IoWsTransport());

/// Key store seam. Defaults to an in-memory store; the persistence-backed store
/// lands with the connect ticket. Tests override.
final wsKeyStoreProvider = Provider<HostKeyStore>((ref) => InMemoryHostKeyStore());

/// Persists host keys in memory (no disk). The real disk-backed store is a
/// later ticket's concern; this keeps the seam honest and injectable.
class InMemoryHostKeyStore implements HostKeyStore {
  HostKeys _keys = const HostKeys();
  @override
  Future<HostKeys> load() async => _keys;
  @override
  Future<void> save(HostKeys keys) async {
    _keys = keys;
  }
}

/// Builds `ws://<address>/api/remote` from a host address.
String remoteWsUrl(String address) {
  var a = address.trim();
  if (a.contains('://')) a = a.split('://').last.split('/').first;
  if (!a.contains(':')) a = '$a:11471';
  return 'ws://$a/api/remote';
}

class WsClientController extends Notifier<ClientState> {
  String? _address;
  WsConnection? _connection;
  StreamSubscription<String>? _framesSub;
  Timer? _reconnectTimer;
  bool _opening = false;
  HostKeys _lastKeys = const HostKeys();

  @override
  ClientState build() {
    ref.onDispose(() {
      _reconnectTimer?.cancel();
      _framesSub?.cancel();
      _connection?.close();
    });
    _restoreKeys();
    return ClientState();
  }

  void connect(String address) {
    _address = address;
    _dispatch(ConnectRequested(clock()));
    // The reducer rejects a connect while already connected/connecting; only
    // open a socket when it actually accepted the request.
    if (state.status == WsStatus.connecting) {
      _open();
    }
  }

  void disconnect() {
    _reconnectTimer?.cancel();
    _framesSub?.cancel();
    _connection?.close();
    _dispatch(DisconnectRequested(clock()));
  }

  /// Sends a command; rejected by the reducer (never queued) while disconnected.
  void sendCommand(String action, [Map<String, dynamic> payload = const {}]) {
    _dispatch(SendCommand(clock(), action, payload));
  }

  void setBackgrounded(bool value) {
    _dispatch(SetBackgrounded(clock(), value));
  }

  Duration clock() => ref.read(wsClockProvider)();

  /// The one place state mutates: reduce, publish, then run the side effects
  /// (drain outgoing, reconnect timer, key persistence, shell status).
  void _dispatch(ClientEvent event) {
    state = clientReduce(state, event);
    _afterState(state);
  }

  Future<void> _restoreKeys() async {
    final keys = await ref.read(wsKeyStoreProvider).load();
    if (!ref.mounted) return;
    _lastKeys = keys;
    if (keys.isEmpty) return;
    _dispatch(RestoreKeys(clock(), keys.tmdbKey, keys.rpdbKey, keys.tvdbKey));
  }

  Future<void> _open() async {
    final address = _address;
    if (address == null || _opening) return;
    _opening = true;
    try {
      final transport = ref.read(wsTransportProvider);
      final conn = await transport.open(remoteWsUrl(address));
      if (!ref.mounted) {
        await conn.close();
        return;
      }
      if (state.status != WsStatus.connecting) {
        await conn.close();
        return;
      }
      _connection = conn;
      _framesSub = conn.frames.listen(_onFrame, onError: (Object e) {
        _onClosed('$e');
      }, onDone: () => _onClosed('closed'));
      _dispatch(SocketOpened(clock()));
    } catch (e) {
      _onClosed('$e');
    } finally {
      _opening = false;
    }
  }

  void _onFrame(String raw) {
    _dispatch(Frame(clock(), raw));
  }

  void _onClosed(String reason) {
    _dispatch(SocketClosed(clock(), reason));
  }

  /// Reacts to a state change: drain outgoing, arm/cancel the reconnect timer,
  /// persist changed keys, mirror the connection status to the shell seam.
  void _afterState(ClientState next) {
    _drain();
    _syncReconnectTimer(next);
    _syncKeys(next);
    _syncShellStatus(next);
  }

  void _drain() {
    if (state.outgoing.isEmpty) return;
    final frames = List<String>.from(state.outgoing);
    state.outgoing.clear();
    for (final f in frames) {
      _connection?.send(f);
    }
  }

  void _syncReconnectTimer(ClientState s) {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    if (s.status != WsStatus.reconnecting || s.backgrounded) return;
    final at = s.reconnectAt;
    if (at == null) return;
    final delay = at - clock();
    _reconnectTimer = Timer(delay.isNegative ? Duration.zero : delay, () {
      _dispatch(Tick(clock()));
      if (state.status == WsStatus.connecting) {
        _open();
      }
    });
  }

  void _syncKeys(ClientState s) {
    final keys = HostKeys(tmdbKey: s.tmdbKey, rpdbKey: s.rpdbKey, tvdbKey: s.tvdbKey);
    if (keys.sameAs(_lastKeys)) return;
    _lastKeys = keys;
    ref.read(wsKeyStoreProvider).save(keys);
  }

  void _syncShellStatus(ClientState s) {
    final status = switch (effectiveStatus(s, clock())) {
      WsStatus.connected => ConnectionStatus.connected,
      WsStatus.connecting || WsStatus.reconnecting => ConnectionStatus.connecting,
      WsStatus.disconnected => ConnectionStatus.disconnected,
    };
    ref.read(connectionStatusProvider.notifier).set(status);
  }
}

final wsClientControllerProvider =
    NotifierProvider<WsClientController, ClientState>(WsClientController.new);
