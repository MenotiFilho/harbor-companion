// LAN scan seam (ticket 03).
//
// The scan is candidate-only: it never connects, it only probes the local
// subnet for an open :11471 and surfaces the address as a candidate. The
// reducer owns `scan:start` / `ScanResultFound` / `ScanDone`; the controller
// drains `scan:start` into this seam and folds the results back.
//
// The real scanner derives each /24 that the device sits on and concurrently
// TCP-probes `:11471` (Harbor's remote port). It's a best-effort probe — a
// host behind a firewall or asleep simply won't answer, same as the reference.

import 'dart:async';
import 'dart:io';

import 'connect_reducer.dart';

/// Emits discovered `"ip:11471"` addresses, then closes when the scan settles.
abstract interface class SubnetScanner {
  Stream<String> scan();
}

/// A fake scanner for tests: pushes the given addresses then closes.
class FixedSubnetScanner implements SubnetScanner {
  final List<String> results;
  const FixedSubnetScanner(this.results);

  @override
  Stream<String> scan() async* {
    for (final r in results) {
      yield r;
    }
  }
}

/// Probes the device's /24 subnets for `:11471`.
class TcpProbeScanner implements SubnetScanner {
  /// Per-host connect timeout. A real Harbor answers fast; this bounds the
  /// worst-case full sweep.
  final Duration timeout;

  /// Bounded concurrency so a /24 probe never opens hundreds of sockets at once.
  final int concurrency;

  TcpProbeScanner({this.timeout = const Duration(milliseconds: 250), this.concurrency = 64});

  @override
  Stream<String> scan() {
    final controller = StreamController<String>();
    _run(controller);
    return controller.stream;
  }

  Future<void> _run(StreamController<String> controller) async {
    try {
      final prefixes = await _localPrefixes();
      final localIps = await _localIps();
      final candidates = <String>[];
      for (final prefix in prefixes) {
        for (var host = 1; host <= 254; host++) {
          final ip = '$prefix.$host';
          if (!localIps.contains(ip)) candidates.add(ip);
        }
      }

      final queue = candidates.toList();
      final workers = <Future<void>>[
        for (var i = 0; i < concurrency && queue.isNotEmpty; i++)
          _worker(queue, controller),
      ];
      await Future.wait(workers);
    } finally {
      await controller.close();
    }
  }

  Future<void> _worker(List<String> queue, StreamController<String> controller) async {
    while (queue.isNotEmpty) {
      final ip = queue.removeLast();
      if (await _probe(ip)) {
        controller.add('$ip:$defaultPort');
      }
    }
  }

  Future<bool> _probe(String ip) async {
    try {
      final socket = await Socket.connect(ip, defaultPort, timeout: timeout);
      socket.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<Set<String>> _localIps() async {
    final ips = <String>{};
    for (final i in await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLinkLocal: false,
      includeLoopback: false,
    )) {
      for (final a in i.addresses) {
        ips.add(a.address);
      }
    }
    return ips;
  }

  Future<Set<String>> _localPrefixes() async {
    final prefixes = <String>{};
    for (final i in await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLinkLocal: false,
      includeLoopback: false,
    )) {
      for (final a in i.addresses) {
        final octets = a.address.split('.');
        if (octets.length == 4) {
          prefixes.add('${octets[0]}.${octets[1]}.${octets[2]}');
        }
      }
    }
    return prefixes;
  }
}
