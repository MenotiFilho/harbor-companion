import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../connect/connect_controller.dart';
import '../connect/connect_reducer.dart';
import '../update/update_controller.dart';
import '../update/update_reducer.dart';

/// Connect/settings surface (ticket 03): the saved-host registry, the per-host
/// open-LAN warning gate, the connection lifecycle, and candidate-only LAN
/// scan. Every connect path (add, select, scan-pick, launch auto-connect) is
/// gated by the reducer — this screen only dispatches events and renders state.
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  @override
  Widget build(BuildContext context) {
    final state = ref.watch(connectControllerProvider);
    final ctrl = ref.read(connectControllerProvider.notifier);
    final updateState = ref.watch(selfUpdateControllerProvider);
    final updateCtrl = ref.read(selfUpdateControllerProvider.notifier);

    // Show the warning gate as a blocking dialog whenever the reducer holds it.
    ref.listen(connectControllerProvider, (previous, next) {
      if (next.warningHeld && previous?.warningHeld != true) {
        _showWarningGate(next.selected);
      }
    });

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _StatusCard(state: state, onRetry: ctrl.retry, onConnect: ctrl.connect, onDisconnect: ctrl.disconnect),
          const SizedBox(height: 16),
          _sectionHeader('Saved hosts'),
          if (state.hosts.isEmpty)
            _emptyHint('No hosts yet — add your PC’s LAN address below.')
          else
            for (final host in state.hosts) _HostTile(
              host: host,
              selected: host.id == state.selectedId,
              phase: host.id == state.selectedId ? state.phase : ConnPhase.idle,
              onSelect: () => ctrl.selectHost(host.id),
              onEdit: () => _editHost(ctrl, host),
              onDelete: () => _deleteHost(ctrl, host),
            ),
          const SizedBox(height: 24),
          _sectionHeader('Find hosts'),
          _ScanSection(state: state, onScan: ctrl.startScan, onPick: (c) => _pickCandidate(ctrl, c)),
          const SizedBox(height: 24),
          _sectionHeader('Updates'),
          _UpdatesSection(state: updateState, onCheck: updateCtrl.checkNow),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _addHost(ctrl),
        icon: const Icon(Icons.add),
        label: const Text('Add host'),
      ),
    );
  }

  Widget _sectionHeader(String title) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(title, style: Theme.of(context).textTheme.titleMedium),
      );

  Widget _emptyHint(String text) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(
          text,
          style: Theme.of(context)
              .textTheme
              .bodyMedium
              ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
      );

  // -- dialogs ---------------------------------------------------------------

  Future<void> _showWarningGate(HostEntry? host) {
    final address = host?.address ?? 'this address';
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Control your PC from the LAN'),
        content: Text(
          'Harbor’s remote is unauthenticated: any device on your network that '
          'knows $address can control playback and read the host’s metadata '
          'keys. Only connect to hosts on a network you trust.',
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              ref.read(connectControllerProvider.notifier).dismissWarning();
            },
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(context).pop();
              ref.read(connectControllerProvider.notifier).acknowledgeWarning();
            },
            child: const Text('I understand, connect'),
          ),
        ],
      ),
    );
  }

  Future<void> _addHost(ConnectController ctrl) =>
      _hostDialog(ctrl, title: 'Add host');

  Future<void> _editHost(ConnectController ctrl, HostEntry host) =>
      _hostDialog(ctrl, title: 'Edit host', host: host);

  Future<void> _hostDialog(ConnectController ctrl,
      {required String title, HostEntry? host}) async {
    final name = TextEditingController(text: host?.name ?? '');
    final address = TextEditingController(text: host?.address ?? '');
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: address,
              decoration: const InputDecoration(
                labelText: 'Address',
                hintText: '192.168.1.50 (port 11471 assumed)',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (result != true) return;
    final addr = address.text.trim();
    if (addr.isEmpty) return;
    final nameText = name.text.trim();
    if (host == null) {
      ctrl.addHost(
        'host-${DateTime.now().microsecondsSinceEpoch}',
        nameText.isEmpty ? 'Harbor' : nameText,
        addr,
      );
    } else {
      ctrl.updateHost(
        host.id,
        name: nameText.isEmpty ? host.name : nameText,
        address: addr,
      );
    }
  }

  Future<void> _deleteHost(ConnectController ctrl, HostEntry host) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove ${host.name}?'),
        content: const Text('This host will be removed from the list.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok == true) ctrl.removeHost(host.id);
  }

  Future<void> _pickCandidate(ConnectController ctrl, HostEntry candidate) async {
    final name = await _askName(candidate.name);
    if (name != null) ctrl.addScanCandidate(candidate, name);
  }

  Future<String?> _askName(String initial) async {
    final name = TextEditingController(text: initial);
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Save this host'),
        content: TextField(
          controller: name,
          decoration: const InputDecoration(labelText: 'Name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (result != true) return null;
    final text = name.text.trim();
    return text.isEmpty ? initial : text;
  }
}

// ---------------------------------------------------------------------------
// Status card
// ---------------------------------------------------------------------------

class _StatusCard extends StatelessWidget {
  final ConnectState state;
  final VoidCallback onRetry;
  final VoidCallback onConnect;
  final VoidCallback onDisconnect;
  const _StatusCard({
    required this.state,
    required this.onRetry,
    required this.onConnect,
    required this.onDisconnect,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (label, icon, color) = _phasePresentation(state.phase);
    final host = state.selected;

    final actions = <Widget>[];
    if (state.phase == ConnPhase.failed) {
      actions.add(TextButton(onPressed: onRetry, child: const Text('Retry')));
    } else if (state.phase == ConnPhase.idle) {
      if (state.notice?.contains('reconnect?') == true) {
        actions.add(TextButton(onPressed: onConnect, child: const Text('Reconnect')));
      } else if (host != null && !host.warned) {
        // Dismissed (or not-yet-acknowledged) gate: offer a path back to it.
        actions.add(TextButton(onPressed: onConnect, child: const Text('Connect')));
      }
    } else if (state.phase == ConnPhase.connected) {
      actions.add(TextButton(onPressed: onDisconnect, child: const Text('Disconnect')));
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: color),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    host == null ? label : '$label ${host.name}',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(color: color),
                  ),
                ),
                ...actions,
              ],
            ),
            if (host != null) ...[
              const SizedBox(height: 4),
              Text(
                host.address,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
            if (state.notice != null) ...[
              const SizedBox(height: 8),
              Text(state.notice!, style: Theme.of(context).textTheme.bodyMedium),
            ],
            if (state.lastError != null) ...[
              const SizedBox(height: 4),
              Text(
                state.lastError!,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.error),
              ),
            ],
          ],
        ),
      ),
    );
  }

  static (String, IconData, Color) _phasePresentation(ConnPhase phase) {
    final base = const Color(0xFFB0BEC5);
    return switch (phase) {
      ConnPhase.idle => ('Disconnected', Icons.cloud_off, base),
      ConnPhase.connecting => ('Connecting…', Icons.sync, Colors.amber),
      ConnPhase.connected => ('Connected to', Icons.check_circle, Colors.green),
      ConnPhase.reconnecting => ('Reconnecting…', Icons.sync_problem, Colors.orange),
      ConnPhase.failed => ('Failed', Icons.error_outline, Colors.red),
    };
  }
}

// ---------------------------------------------------------------------------
// Host list tile
// ---------------------------------------------------------------------------

class _HostTile extends StatelessWidget {
  final HostEntry host;
  final bool selected;
  final ConnPhase phase;
  final VoidCallback onSelect;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  const _HostTile({
    required this.host,
    required this.selected,
    required this.phase,
    required this.onSelect,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final icon = switch (phase) {
      ConnPhase.connected => Icons.check_circle,
      ConnPhase.connecting => Icons.sync,
      ConnPhase.reconnecting => Icons.sync_problem,
      ConnPhase.failed => Icons.error_outline,
      ConnPhase.idle => Icons.computer,
    };
    return ListTile(
      leading: Icon(icon, color: selected ? scheme.primary : scheme.onSurfaceVariant),
      title: Text(host.name),
      subtitle: Text(host.address),
      selected: selected,
      onTap: onSelect,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(icon: const Icon(Icons.edit_outlined), onPressed: onEdit),
          IconButton(icon: const Icon(Icons.delete_outline), onPressed: onDelete),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Scan section
// ---------------------------------------------------------------------------

class _ScanSection extends StatelessWidget {
  final ConnectState state;
  final VoidCallback onScan;
  final void Function(HostEntry) onPick;
  const _ScanSection({required this.state, required this.onScan, required this.onPick});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        OutlinedButton.icon(
          onPressed: state.scanning ? null : onScan,
          icon: state.scanning
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.radar),
          label: Text(state.scanning ? 'Scanning…' : 'Scan local network'),
        ),
        if (state.scanning)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'Probing your subnet for :11471…',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
        if (state.scanResults.isNotEmpty) ...[
          const SizedBox(height: 8),
          for (final candidate in state.scanResults)
            ListTile(
              leading: const Icon(Icons.wifi_tethering),
              title: Text(candidate.name),
              subtitle: Text(candidate.address),
              trailing: FilledButton.tonal(
                onPressed: () => onPick(candidate),
                child: const Text('Add'),
              ),
            ),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Updates section (self-update check half, ticket 28)
// ---------------------------------------------------------------------------

class _UpdatesSection extends StatelessWidget {
  final SelfUpdateState state;
  final VoidCallback onCheck;
  const _UpdatesSection({required this.state, required this.onCheck});

  @override
  Widget build(BuildContext context) {
    final (label, color) = _statusPresentation(state);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        OutlinedButton.icon(
          onPressed: state.status == UpdateStatus.checking ? null : onCheck,
          icon: state.status == UpdateStatus.checking
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.system_update),
          label: const Text('Check for updates'),
        ),
        if (label != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: color),
            ),
          ),
      ],
    );
  }

  (String?, Color?) _statusPresentation(SelfUpdateState state) {
    final scheme = const Color(0xFFB0BEC5);
    switch (state.status) {
      case UpdateStatus.idle:
        final name = state.localVersionName;
        return (name == null ? null : 'Version $name', scheme);
      case UpdateStatus.checking:
        return ('Checking for updates…', scheme);
      case UpdateStatus.upToDate:
        return (state.notice ?? 'You’re up to date', scheme);
      case UpdateStatus.hasUpdate:
        final update = state.update;
        return (update == null ? null : 'Update available: ${update.versionName}', Colors.green);
      case UpdateStatus.failed:
        return (state.notice ?? 'Could not check for updates', Colors.orange);
      case UpdateStatus.installing:
        return ('Downloading update…', scheme);
      case UpdateStatus.installFailed:
        return (state.notice ?? 'Update failed', Colors.orange);
    }
  }
}
