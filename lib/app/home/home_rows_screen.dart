// "Home rows" editor (ticket 41 follow-up; restyled in issue #90).
//
// One reorderable list of every rail the Home can show — Cinemeta rows, TMDB
// rows and the Letterboxd catalogs — so the user can drag them into any order
// (Letterboxd first, say) and switch individual rows off. The list is driven by
// `SettingsState.homeRowOrder`; moving or toggling persists through the settings
// controller, and the Home controller refetches on the resulting state change.
//
// Presentation uses the shared row rhythm (`SwitchRow`): accent switches, soft
// hairlines and a >= 48dp target per row. The editor is scroll content, so no
// BackdropFilter (ADR-0010).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../settings/settings_controller.dart';
import '../shell/player_bar.dart';
import '../theme.dart';
import '../ui/rows.dart';
import 'home_rows.dart';

class HomeRowsScreen extends ConsumerWidget {
  const HomeRowsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsControllerProvider);
    final ctrl = ref.read(settingsControllerProvider.notifier);
    final order = settings.homeRowOrder;
    final hasManifest = settings.letterboxdManifestUrl.trim().isNotEmpty;
    final tokens = AppTokens.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Home rows')),
      body: Column(
        children: [
          _Intro(
            onHideBuiltIn: () => ctrl.setAllBuiltInRowsEnabled(false),
            onShowBuiltIn: () => ctrl.setAllBuiltInRowsEnabled(true),
          ),
          Expanded(
            child: ReorderableListView.builder(
              buildDefaultDragHandles: false,
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
              itemCount: order.length,
              onReorderItem: ctrl.moveHomeRow,
              itemBuilder: (context, index) {
                final key = order[index];
                final entry = homeRowEntry(key);
                if (entry == null) return SizedBox.shrink(key: ValueKey(key));
                final catalogId = letterboxdCatalogId(key);
                final letterboxd = entry.isLetterboxd && catalogId != null;
                final enabled = letterboxd
                    ? settings.enabledLetterboxdCatalogs.contains(catalogId)
                    : !settings.disabledBuiltInRowKeys.contains(key);
                final canToggle = !letterboxd || hasManifest;
                return SwitchRow(
                  key: ValueKey(key),
                  leading: ReorderableDragStartListener(
                    index: index,
                    child: Icon(
                      Icons.drag_handle,
                      size: 22,
                      color: tokens.inkFaint,
                    ),
                  ),
                  title: entry.label,
                  subtitle: entry.source,
                  value: enabled,
                  onChanged: canToggle
                      ? (value) {
                          if (letterboxd) {
                            ctrl.setLetterboxdCatalogEnabled(catalogId, value);
                          } else {
                            ctrl.setBuiltInRowEnabled(key, value);
                          }
                        }
                      : null,
                );
              },
            ),
          ),
        ],
      ),
      bottomNavigationBar: const PlayerBar(),
    );
  }
}

class _Intro extends StatelessWidget {
  final VoidCallback onHideBuiltIn;
  final VoidCallback onShowBuiltIn;
  const _Intro({required this.onHideBuiltIn, required this.onShowBuiltIn});

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Drag to reorder. Switch a row off to hide it from Home. The host '
            'uses your Cinemeta rows when it has no TMDB key, or your TMDB rows '
            'when it does.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: tokens.inkMuted,
                  height: 1.6,
                ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            children: [
              OutlinedButton(
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 48),
                ),
                onPressed: onHideBuiltIn,
                child: const Text('Hide built-in rows'),
              ),
              TextButton(
                style: TextButton.styleFrom(minimumSize: const Size(0, 48)),
                onPressed: onShowBuiltIn,
                child: const Text('Show built-in rows'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
