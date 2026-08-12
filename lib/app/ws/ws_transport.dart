// Socket seam for the WS client (ticket 02). The reducer never touches I/O;
// the controller drives this interface. dart:io's WebSocket is the real
// implementation; tests inject a fake.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A live socket. `frames` emits inbound text frames until the socket drops.
abstract interface class WsConnection {
  Stream<String> get frames;
  void send(String message);
  Future<void> close();
}

/// Opens sockets to a URL. Injected into the WS client controller.
abstract interface class WsTransport {
  Future<WsConnection> open(String url);
}

class IoWsConnection implements WsConnection {
  final WebSocket _socket;
  IoWsConnection(this._socket);

  @override
  Stream<String> get frames => _socket
      .map((data) => data is String ? data : utf8.decode(data as List<int>))
      .asBroadcastStream();

  @override
  void send(String message) => _socket.add(message);

  @override
  Future<void> close() async {
    await _socket.close();
  }
}

class IoWsTransport implements WsTransport {
  @override
  Future<WsConnection> open(String url) async {
    final socket = await WebSocket.connect(url);
    return IoWsConnection(socket);
  }
}
