// First-run / disconnected body: points the user at settings to add a host,
// and surfaces the cold-start "last used host unreachable — reconnect?" prompt
// (a launch-time auto-connect that failed drops to idle, never a spinner).
//
// Restyled for the Editorial Cinema language (issue #90): one centered column,
// an accent-tinted seal, the serif brand title and sober ghost/accent buttons.
// No behavior changes — the same reconnect and settings actions as before.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../connect/connect_controller.dart';
import '../routes.dart';
import '../theme.dart';

class ConnectFirstView extends ConsumerWidget {
  const ConnectFirstView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = AppTokens.of(context);
    final text = Theme.of(context).textTheme;
    final connect = ref.watch(connectControllerProvider);
    final coldStartMiss = connect.notice?.contains('reconnect?') == true;

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: tokens.accentFill,
                border: Border.all(color: tokens.accentLine),
              ),
              child: Icon(Icons.cast_connected, size: 28, color: tokens.accentInk),
            ),
            const SizedBox(height: 20),
            Text(
              'Connect to your Harbor host',
              textAlign: TextAlign.center,
              style: tokens.serifTitle.copyWith(fontSize: 28, height: 1.12),
            ),
            const SizedBox(height: 10),
            Text(
              coldStartMiss
                  ? 'Your last host couldn’t be reached.'
                  : 'Add your PC’s LAN address in Settings to browse and control '
                      'it from your phone.',
              textAlign: TextAlign.center,
              style: text.bodyMedium?.copyWith(
                color: tokens.inkMuted,
                height: 1.6,
              ),
            ),
            const SizedBox(height: 26),
            if (coldStartMiss) ...[
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 48),
                ),
                onPressed: () =>
                    ref.read(connectControllerProvider.notifier).connect(),
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Reconnect'),
              ),
              const SizedBox(height: 10),
            ],
            FilledButton.icon(
              style: FilledButton.styleFrom(
                minimumSize: const Size(0, 48),
              ),
              onPressed: () => Navigator.of(context).pushNamed(AppRoutes.settings),
              icon: const Icon(Icons.tune, size: 18),
              label: const Text('Open settings'),
            ),
          ],
        ),
      ),
    );
  }
}
