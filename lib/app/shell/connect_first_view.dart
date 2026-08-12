import 'package:flutter/material.dart';

import '../routes.dart';

/// First-run / disconnected body: points the user at settings to add a host.
///
/// Rendered in place of every tab body while [ShellState.showConnectFirst] is
/// true. The settings surface itself is owned by the connect ticket (03); this
/// view only needs to lead there.
class ConnectFirstView extends StatelessWidget {
  const ConnectFirstView({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.settings_remote, size: 64, color: scheme.primary),
            const SizedBox(height: 16),
            Text(
              'Connect to your Harbor host',
              textAlign: TextAlign.center,
              style: text.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              'Add your PC’s LAN address in Settings to browse and control '
              'it from your phone.',
              textAlign: TextAlign.center,
              style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: () => Navigator.of(context).pushNamed(AppRoutes.settings),
              icon: const Icon(Icons.tune),
              label: const Text('Open settings'),
            ),
          ],
        ),
      ),
    );
  }
}
