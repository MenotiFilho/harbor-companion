import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../connect/connect_controller.dart';
import '../routes.dart';

/// First-run / disconnected body: points the user at settings to add a host,
/// and surfaces the cold-start "last used host unreachable — reconnect?" prompt
/// (a launch-time auto-connect that failed drops to idle, never a spinner).
class ConnectFirstView extends ConsumerWidget {
  const ConnectFirstView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final connect = ref.watch(connectControllerProvider);
    final coldStartMiss = connect.notice?.contains('reconnect?') == true;

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
              coldStartMiss
                  ? 'Your last host couldn’t be reached.'
                  : 'Add your PC’s LAN address in Settings to browse and control '
                      'it from your phone.',
              textAlign: TextAlign.center,
              style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 24),
            if (coldStartMiss) ...[
              FilledButton.icon(
                onPressed: () =>
                    ref.read(connectControllerProvider.notifier).connect(),
                icon: const Icon(Icons.refresh),
                label: const Text('Reconnect'),
              ),
              const SizedBox(height: 8),
            ],
            FilledButton.tonalIcon(
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
