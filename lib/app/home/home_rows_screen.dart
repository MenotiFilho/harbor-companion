// "Home rows" editor (ticket 41 follow-up).
//
// One reorderable list of every rail the Home can show — Cinemeta rows, TMDB
// rows and the Letterboxd catalogs — so the user can drag them into any order
// (Letterboxd first, say) and switch individual rows off. The list is driven by
// `SettingsState.homeRowOrder`; moving or toggling persists through the settings
// controller, and the Home controller refetches on the resulting state change.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../settings/settings_controller.dart';
import '../shell/player_bar.dart';
import 'home_rows.dart';

class HomeRowsScreen extends ConsumerWidget {
  const HomeRowsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsControllerProvider);
    final ctrl = ref.read(settingsControllerProvider.notifier);
    final order = settings.homeRowOrder;
    final hasManifest = settings.letterboxdManifestUrl.trim().isNotEmpty;

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
                return ListTile(
                  key: ValueKey(key),
                  leading: ReorderableDragStartListener(
                    index: index,
                    child: const Icon(Icons.drag_handle),
                  ),
                  title: Text(entry.label),
                  subtitle: Text(entry.source),
                  trailing: Switch(
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
                  ),
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
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Drag to reorder. Switch a row off to hide it from Home. The host '
            'uses your Cinemeta rows when it has no TMDB key, or your TMDB rows '
            'when it does.',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            children: [
              OutlinedButton(
                onPressed: onHideBuiltIn,
                child: const Text('Hide built-in rows'),
              ),
              TextButton(
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
