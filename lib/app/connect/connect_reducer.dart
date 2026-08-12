// Pure connect/settings state model (ticket 03).
//
// `(ConnectState, ConnectEvent) => ConnectState` reducer producing an effects
// buffer the controller drains through injected side-channels (WS client, host
// registry store, subnet scanner, clock/timers). No I/O, no timers.
//
// Lifted verbatim from the validated connect prototype (#12): the saved-host
// registry, the per-host open-LAN warning gate, the connection lifecycle
// (idle → connecting → connected / reconnecting / failed) with asymmetric
// give-up, cold-start auto-connect drop-to-idle, and candidate-only LAN scan.
//
// Effects vocabulary (the Notifier → adapter surface):
//   `warn`              → show the open-LAN auth warning (blocks connect)
//   `connect:<addr>`    → attempt a socket connect to addr
//   `disconnect`        → close the socket
//   `reconnectIn:<ms>`  → arm a reconnect timer (fires RetryNow)
//   `cancelReconnect`   → drop the pending reconnect timer
//   `scan:start`        → probe the local subnet for :11471

library;

const Duration backoffFloor = Duration(milliseconds: 400);
const Duration backoffCap = Duration(milliseconds: 3000);
const int defaultPort = 11471;
/// Give up after this many consecutive failed (re)connect attempts. An
/// established-connection drop never gives up (transient); a host that never
/// answers eventually stops so the user can check the address.
const int maxReconnectAttempts = 8;

enum ConnPhase { idle, connecting, connected, reconnecting, failed }

extension _FirstOrNull<T> on Iterable<T> {
  T? firstOrNull() => isEmpty ? null : first;
}

/// A saved host. `warned` records that the user has acknowledged the open-LAN
/// risk for this host — first connect is gated on it, thereafter it's shown
/// but auto-approved. `lastConnectedAt` distinguishes a never-reached host
/// (first-connect failure stops: bad address) from a host that has connected
/// before (drops auto-reconnect).
class HostEntry {
  final String id;
  final String name;
  final String address; // "192.168.1.50:11471"
  final bool warned;
  final int? lastConnectedAt;
  const HostEntry({
    required this.id,
    required this.name,
    required this.address,
    this.warned = false,
    this.lastConnectedAt,
  });

  HostEntry copyWith({String? name, String? address, bool? warned, int? lastConnectedAt}) {
    return HostEntry(
      id: id,
      name: name ?? this.name,
      address: address ?? this.address,
      warned: warned ?? this.warned,
      lastConnectedAt: lastConnectedAt ?? this.lastConnectedAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'address': address,
        'warned': warned,
        'lastConnectedAt': lastConnectedAt,
      };

  factory HostEntry.fromJson(Map<String, dynamic> j) => HostEntry(
        id: j['id'] as String,
        name: j['name'] as String? ?? 'Host',
        address: j['address'] as String,
        warned: j['warned'] as bool? ?? false,
        lastConnectedAt: (j['lastConnectedAt'] as num?)?.toInt(),
      );
}

class ConnectState {
  final List<HostEntry> hosts;
  final String? selectedId;
  final ConnPhase phase;
  final bool warningHeld; // open-LAN warning is up; connect is blocked
  final int reconnectAttempt;
  final Duration reconnectDelay; // current backoff (relevant while reconnecting)
  final bool backgrounded;
  final bool coldStart; // this connect was initiated by app launch (auto-connect)
  final bool scanning; // LAN scan in flight
  final List<HostEntry> scanResults; // discovered candidates (name may be generic)
  final String? lastError;
  final String? notice; // transient message for the shell to show

  /// Effects buffer: the reducer appends effects here; the controller drains
  /// them. The one mutable field (impure by convention).
  final List<String> effects;

  ConnectState({
    this.hosts = const [],
    this.selectedId,
    this.phase = ConnPhase.idle,
    this.warningHeld = false,
    this.reconnectAttempt = 0,
    this.reconnectDelay = backoffFloor,
    this.backgrounded = false,
    this.coldStart = false,
    this.scanning = false,
    this.scanResults = const [],
    this.lastError,
    this.notice,
    List<String>? effects,
  }) : effects = effects ?? <String>[];

  ConnectState copy({
    List<HostEntry>? hosts,
    String? selectedId,
    bool clearSelected = false,
    ConnPhase? phase,
    bool? warningHeld,
    int? reconnectAttempt,
    Duration? reconnectDelay,
    bool? backgrounded,
    bool? coldStart,
    bool? scanning,
    List<HostEntry>? scanResults,
    String? lastError,
    bool clearLastError = false,
    String? notice,
    bool clearNotice = false,
    List<String>? effects,
  }) {
    return ConnectState(
      hosts: hosts ?? this.hosts,
      selectedId: clearSelected ? null : (selectedId ?? this.selectedId),
      phase: phase ?? this.phase,
      warningHeld: warningHeld ?? this.warningHeld,
      reconnectAttempt: reconnectAttempt ?? this.reconnectAttempt,
      reconnectDelay: reconnectDelay ?? this.reconnectDelay,
      backgrounded: backgrounded ?? this.backgrounded,
      coldStart: coldStart ?? this.coldStart,
      scanning: scanning ?? this.scanning,
      scanResults: scanResults ?? this.scanResults,
      lastError: clearLastError ? null : (lastError ?? this.lastError),
      notice: clearNotice ? null : (notice ?? this.notice),
      effects: effects ?? this.effects,
    );
  }

  HostEntry? get selected =>
      selectedId == null ? null : hosts.where((h) => h.id == selectedId).firstOrNull();
}

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------

sealed class ConnectEvent {
  const ConnectEvent();
}

class Launch extends ConnectEvent {
  final Duration now;
  const Launch(this.now);
}

/// Seeds the persisted host registry into state on app start, before [Launch]
/// auto-connects. The prototype kept hosts in memory only; the app persists.
class RestoreHosts extends ConnectEvent {
  final List<HostEntry> hosts;
  const RestoreHosts(this.hosts);
}

class AddHost extends ConnectEvent {
  final String id;
  final String name;
  final String address;
  const AddHost(this.id, this.name, this.address);
}

class UpdateHost extends ConnectEvent {
  final String id;
  final String? name;
  final String? address;
  const UpdateHost(this.id, {this.name, this.address});
}

class RemoveHost extends ConnectEvent {
  final String id;
  const RemoveHost(this.id);
}

class SelectHost extends ConnectEvent {
  final String id;
  const SelectHost(this.id);
}

class ConnectRequested extends ConnectEvent {
  const ConnectRequested();
}

class AcknowledgeWarning extends ConnectEvent {
  const AcknowledgeWarning();
}

/// Dismisses the warning gate without connecting; the host stays unwarned so
/// the next connect attempt re-gates (the gate is re-triggerable).
class DismissWarning extends ConnectEvent {
  const DismissWarning();
}

class SocketOpened extends ConnectEvent {
  final Duration now;
  const SocketOpened(this.now);
}

class SocketClosed extends ConnectEvent {
  final String reason;
  const SocketClosed(this.reason);
}

class RetryNow extends ConnectEvent {
  const RetryNow();
}

class DisconnectRequested extends ConnectEvent {
  const DisconnectRequested();
}

class SetBackgrounded extends ConnectEvent {
  final bool value;
  const SetBackgrounded(this.value);
}

class StartScan extends ConnectEvent {
  const StartScan();
}

class ScanResultFound extends ConnectEvent {
  final String address;
  const ScanResultFound(this.address);
}

class ScanDone extends ConnectEvent {
  const ScanDone();
}

// ---------------------------------------------------------------------------
// Reducer
// ---------------------------------------------------------------------------

Duration _nextBackoff(Duration d) {
  final doubled = d * 2;
  return doubled > backoffCap ? backoffCap : doubled;
}

String normalizeAddress(String a) {
  var s = a.trim();
  if (s.isEmpty) return s;
  if (s.contains('://')) s = s.split('://').last.split('/').first;
  if (!s.contains(':')) s = '$s:$defaultPort';
  return s;
}

ConnectState connectReduce(ConnectState s, ConnectEvent e) {
  switch (e) {
    case RestoreHosts(:final hosts):
      return s.copy(hosts: hosts);

    case Launch():
      // Auto-connect to the last-used host (warned hosts skip the gate).
      // Fall back to the most recently added host if none has ever connected.
      final connected = s.hosts.where((h) => h.lastConnectedAt != null).toList()
        ..sort((a, b) => (b.lastConnectedAt!).compareTo(a.lastConnectedAt!));
      final target = connected.isNotEmpty
          ? connected.first
          : (s.hosts.isEmpty ? null : s.hosts.last);
      if (target == null) {
        return s.copy(notice: 'no saved hosts — add one to connect');
      }
      // Mark coldStart: a launch-time connect that fails drops to idle with a
      // "last used host unreachable — reconnect?" notice instead of entering
      // the reconnect loop (no spinner on app open for a dead host).
      var next = s.copy(
        selectedId: target.id,
        coldStart: true,
        notice: 'auto-connect → ${target.name}',
      );
      if (target.warned) {
        next = _beginConnect(next);
      } else {
        next = next.copy(warningHeld: true);
        next.effects.add('warn');
      }
      return next;

    case AddHost(id: final id, name: final name, address: final address):
      final addr = normalizeAddress(address);
      final existing = s.hosts.where((h) => h.address == addr).firstOrNull();
      if (existing != null) {
        var next = s.copy(selectedId: existing.id, notice: '${existing.name} already saved — selected');
        if (existing.warned) {
          next = _beginConnect(next);
        } else {
          next = next.copy(warningHeld: true);
          next.effects.add('warn');
        }
        return next;
      }
      final host = HostEntry(id: id, name: name, address: addr);
      var next = s.copy(
        hosts: [...s.hosts, host],
        selectedId: id,
        notice: 'saved ${host.name} (${host.address})',
      );
      // First connect to a brand-new host: gate on the open-LAN warning.
      next = next.copy(warningHeld: true);
      next.effects.add('warn');
      return next;

    case UpdateHost(id: final id, name: final name, address: final address):
      final host = s.hosts.where((h) => h.id == id).firstOrNull();
      if (host == null) return s.copy(notice: 'host not found');
      final addr = address == null ? null : normalizeAddress(address);
      final hosts = [
        for (final h in s.hosts)
          if (h.id == id) h.copyWith(name: name, address: addr) else h,
      ];
      return s.copy(hosts: hosts, notice: 'updated ${name ?? host.name}');

    case RemoveHost(id: final id):
      final wasSelected = s.selectedId == id;
      final hosts = s.hosts.where((h) => h.id != id).toList();
      var next = s.copy(hosts: hosts, notice: 'removed host');
      if (wasSelected) {
        // Tearing down the active host: disconnect whatever we had.
        if (next.phase == ConnPhase.connected || next.phase == ConnPhase.reconnecting) {
          next = next.copy(phase: ConnPhase.idle, clearSelected: true);
          next.effects.add('disconnect');
          next.effects.add('cancelReconnect');
        } else {
          next = next.copy(phase: ConnPhase.idle, clearSelected: true);
        }
        if (next.hosts.isNotEmpty) {
          next = next.copy(selectedId: next.hosts.first.id);
        }
      }
      return next;

    case SelectHost(id: final id):
      final host = s.hosts.where((h) => h.id == id).firstOrNull();
      if (host == null) return s.copy(notice: 'host not found');
      var next = s.copy(selectedId: id, notice: 'selected ${host.name}');
      // Switching away from the active host tears the old socket down first, so
      // the user can actually move which PC they're controlling.
      if (s.selectedId != id &&
          (s.phase == ConnPhase.connected || s.phase == ConnPhase.reconnecting)) {
        next = next.copy(phase: ConnPhase.idle);
        next.effects.add('disconnect');
        next.effects.add('cancelReconnect');
      }
      if (host.warned) {
        next = _beginConnect(next);
      } else {
        next = next.copy(warningHeld: true);
        next.effects.add('warn');
      }
      return next;

    case ConnectRequested():
      return _beginConnect(s);

    case AcknowledgeWarning():
      // Mark the pending host warned, then proceed with the connect.
      final id = s.selectedId;
      if (id == null) return s.copy(notice: 'no host selected', warningHeld: false);
      final hosts = [
        for (final h in s.hosts)
          if (h.id == id) h.copyWith(warned: true) else h,
      ];
      var next = s.copy(hosts: hosts, warningHeld: false, clearLastError: true);
      return _beginConnect(next);

    case DismissWarning():
      return s.copy(
        warningHeld: false,
        notice: 'not connected — acknowledge the warning to continue',
      );

    case SocketOpened(now: final now):
      if (s.phase != ConnPhase.connecting) {
        return s.copy(notice: 'unexpected socket open while ${s.phase.name} (ignored)');
      }
      final id = s.selectedId;
      final hosts = [
        for (final h in s.hosts)
          if (h.id == id) h.copyWith(lastConnectedAt: now.inMilliseconds) else h,
      ];
      return s.copy(
        hosts: hosts,
        phase: ConnPhase.connected,
        reconnectAttempt: 0,
        reconnectDelay: backoffFloor,
        coldStart: false, // a successful connect ends the cold-start window
        clearLastError: true,
        notice: 'connected to ${s.selected?.name}',
      );

    case SocketClosed(reason: final reason):
      if (s.phase == ConnPhase.connected) {
        // Unexpected drop of an established connection: first retry at floor.
        return s.copy(
          phase: ConnPhase.reconnecting,
          reconnectAttempt: 1,
          reconnectDelay: backoffFloor,
          lastError: 'connection lost ($reason)',
          notice: 'reconnecting in ${backoffFloor.inMilliseconds}ms…',
        )..effects.add('reconnectIn:${backoffFloor.inMilliseconds}');
      }
      if (s.phase == ConnPhase.connecting) {
        // A reconnect attempt failed: double the backoff, up to the cap.
        final next = _nextBackoff(s.reconnectDelay);
        final attempt = s.reconnectAttempt + 1;
        // A launch-time auto-connect that fails drops to idle with a
        // "last used host unreachable — reconnect?" notice. No reconnect loop
        // on app open for a host that's simply not there right now.
        if (s.coldStart) {
          return s.copy(
            phase: ConnPhase.idle,
            coldStart: false,
            lastError: 'could not reach ${s.selected?.address}',
            notice: 'last used host unreachable — reconnect?',
          )..effects.add('disconnect')
           ..effects.add('cancelReconnect');
        }
        // Asymmetric give-up: only a host that has never connected stops after
        // maxReconnectAttempts (a mistyped address shouldn't spin forever). A
        // host that connected before retries indefinitely (transient blip).
        final neverConnected = s.selected?.lastConnectedAt == null;
        if (neverConnected && attempt >= maxReconnectAttempts) {
          return s.copy(
            phase: ConnPhase.failed,
            reconnectAttempt: attempt,
            reconnectDelay: next,
            lastError: 'gave up after $attempt attempts (${s.selected?.address})',
            notice: 'could not reach ${s.selected?.name} — check the address',
          )..effects.add('disconnect')
           ..effects.add('cancelReconnect');
        }
        return s.copy(
          phase: ConnPhase.reconnecting,
          reconnectAttempt: attempt,
          reconnectDelay: next,
          lastError: 'connection failed ($reason)',
          notice: 'attempt $attempt failed → retry in ${next.inMilliseconds}ms',
        )..effects.add('reconnectIn:${next.inMilliseconds}');
      }
      return s.copy(notice: 'socket close ignored (status ${s.phase.name})');

    case RetryNow():
      if (s.phase == ConnPhase.reconnecting || s.phase == ConnPhase.failed) {
        // From `failed` this is a fresh manual retry: reset the attempt counter
        // and backoff so the user gets a full budget again. From `reconnecting`
        // (armed timer) it's an internal retry: preserve the counter so the
        // give-up path can still fire. Explicit fresh connects go through
        // ConnectRequested / _beginConnect instead.
        final fresh = s.phase == ConnPhase.failed;
        var next = s.copy(
          phase: ConnPhase.connecting,
          reconnectAttempt: fresh ? 0 : s.reconnectAttempt,
          reconnectDelay: fresh ? backoffFloor : s.reconnectDelay,
          clearLastError: true,
          notice: 'retrying ${s.selected?.name}…',
        );
        next.effects.add('connect:${s.selected?.address}');
        return next;
      }
      return s.copy(notice: 'retry ignored (status ${s.phase.name})');

    case DisconnectRequested():
      if (s.phase == ConnPhase.idle) return s.copy(notice: 'already disconnected');
      var next = s.copy(phase: ConnPhase.idle, reconnectAttempt: 0, reconnectDelay: backoffFloor);
      if (s.phase == ConnPhase.connected) {
        next.effects.add('disconnect');
      }
      next.effects.add('cancelReconnect');
      next = next.copy(notice: 'disconnected');
      return next;

    case SetBackgrounded(value: final value):
      var next = s.copy(backgrounded: value);
      if (s.phase == ConnPhase.reconnecting) {
        if (value) {
          next.effects.add('cancelReconnect');
          next = next.copy(notice: 'backgrounded — reconnect paused');
        } else {
          next = next.copy(notice: 'foregrounded — reconnect resumes');
          next.effects.add('reconnectIn:${s.reconnectDelay.inMilliseconds}');
        }
      }
      return next;

    case StartScan():
      if (s.scanning) return s.copy(notice: 'scan already in progress');
      var next = s.copy(scanning: true, scanResults: const [], notice: 'scanning the subnet…');
      next.effects.add('scan:start');
      return next;

    case ScanResultFound(address: final address):
      if (!s.scanning) return s.copy(notice: 'scan result outside a scan (ignored)');
      final addr = normalizeAddress(address);
      final known = s.hosts.any((h) => h.address == addr);
      if (known) return s.copy(notice: 'scan hit $addr — already saved');
      if (s.scanResults.any((h) => h.address == addr)) return s;
      return s.copy(scanResults: [
        ...s.scanResults,
        HostEntry(id: 'scan-${s.scanResults.length}-${addr.hashCode}', name: 'Found host', address: addr),
      ]);

    case ScanDone():
      if (!s.scanning) return s.copy(notice: 'scan-done outside a scan (ignored)');
      return s.copy(
        scanning: false,
        notice: s.scanResults.isEmpty ? 'scan finished — no new hosts' : 'scan finished — ${s.scanResults.length} new',
      );
  }
}

/// Begin (or re-begin) a connect to the selected host. If it has never been
/// warned, hold on the open-LAN warning instead and block.
ConnectState _beginConnect(ConnectState s) {
  final host = s.selected;
  if (host == null) return s.copy(notice: 'no host selected');
  if (s.phase == ConnPhase.connected) return s.copy(notice: 'already connected to ${host.name}');
  if (!host.warned) {
    return s.copy(warningHeld: true)..effects.add('warn');
  }
  var next = s.copy(
    phase: ConnPhase.connecting,
    reconnectAttempt: 0,
    reconnectDelay: backoffFloor,
    clearLastError: true,
    notice: 'connecting to ${host.name}…',
  );
  next.effects.add('connect:${host.address}');
  return next;
}
