import 'package:flutter/material.dart';

/// A placeholder body for a tab whose feature is not yet implemented.
///
/// Later tickets mount the real feature views here (search, home rows, remote,
/// library, profile). Until then each tab shows its label + icon so the shell
/// has somewhere to land.
class TabPlaceholder extends StatelessWidget {
  final String title;
  final IconData icon;
  const TabPlaceholder({super.key, required this.title, required this.icon});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 56, color: scheme.onSurfaceVariant),
          const SizedBox(height: 12),
          Text(
            title,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
          ),
          const SizedBox(height: 4),
          Text(
            'coming soon',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: scheme.outline,
                ),
          ),
        ],
      ),
    );
  }
}
