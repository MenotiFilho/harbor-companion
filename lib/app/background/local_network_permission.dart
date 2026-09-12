// Native local-network-permission bridge (#69, Android 17 LAN readiness).
//
// Android 17 (API 37) gates LAN sockets behind the runtime
// `ACCESS_LOCAL_NETWORK` permission (the "Nearby devices" group). The app
// declares it in the manifest now — inert on every earlier version — and exposes
// the check/request operations behind this bridge so the runtime gate can be
// wired when the target SDK reaches 37 without re-plumbing the adapter.
//
// Below API 37 the MainActivity side reports `granted` and the request is a
// no-op (it never calls the OS prompt), so the LAN connection keeps working
// untouched. Tests never touch this channel; they use the fake seam instead.

import 'package:flutter/services.dart';

import 'background_platform.dart';

abstract interface class LocalNetworkPermissionBridge {
  /// The current `ACCESS_LOCAL_NETWORK` state. Always
  /// [LocalNetworkPermissionStatus.granted] below Android 17.
  Future<LocalNetworkPermissionStatus> checkStatus();

  /// Fire the OS prompt (Android 17+ only) and report the result. A no-op
  /// returning [LocalNetworkPermissionStatus.granted] below Android 17.
  Future<LocalNetworkPermissionStatus> request();
}

class MethodChannelLocalNetworkPermission
    implements LocalNetworkPermissionBridge {
  static const _channel =
      MethodChannel('dev.harbor.harbor_companion/local_network');

  @override
  Future<LocalNetworkPermissionStatus> checkStatus() async {
    final raw = await _channel.invokeMethod<String>('checkStatus');
    return LocalNetworkPermissionStatus.fromWire(raw);
  }

  @override
  Future<LocalNetworkPermissionStatus> request() async {
    final raw = await _channel.invokeMethod<String>('request');
    return LocalNetworkPermissionStatus.fromWire(raw);
  }
}
