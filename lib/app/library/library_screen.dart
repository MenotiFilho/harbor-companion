// Library / My Stuff tab (ticket 06).
//
// Renders the pure reducer's view: three sections (Watchlist / History /
// Favorites) with host-authoritative toggle chips, the derived empty states
// (needConnect / emptyLibrary), the offline stale banner, display-only
// trackers, and the local-persistence switch. Everything derives from the
// snapshot — the phone never optimistically flips a toggle.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../home/poster_image.dart';
import '../ws/client_reducer.dart' show LibraryItem;
import 'library_controller.dart';
import 'library_reducer.dart';

class LibraryScreen extends ConsumerWidget {
  const LibraryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(libraryControllerProvider);
    final view = state.view;
    final ctrl = ref.read(libraryControllerProvider.notifier);
    final togglesEnabled = state.connected;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _PersistenceToggle(
          enabled: state.persistEnabled,
          onChanged: ctrl.togglePersistence,
        ),
        if (view.stale) ...[
          const SizedBox(height: 12),
          const _StaleBanner(),
        ],
        if (view.trackers.isNotEmpty) ...[
          const SizedBox(height: 12),
          _TrackersRow(trackers: view.trackers),
        ],
        const SizedBox(height: 16),
        ...switch (view.emptyKind) {
          EmptyKind.needConnect => const [_EmptyState(kind: EmptyKind.needConnect)],
          EmptyKind.emptyLibrary => const [_EmptyState(kind: EmptyKind.emptyLibrary)],
          EmptyKind.none => [
              _Section(
                title: 'Watchlist',
                items: view.watchlist,
                view: view,
                enabled: togglesEnabled,
                onToggle: (item, kind, on) => ctrl.toggle(kind, item, on),
              ),
              const SizedBox(height: 16),
              _Section(
                title: 'History',
                items: view.history,
                view: view,
                enabled: togglesEnabled,
                onToggle: (item, kind, on) => ctrl.toggle(kind, item, on),
              ),
              const SizedBox(height: 16),
              _Section(
                title: 'Favorites',
                items: view.favorites,
                view: view,
                enabled: togglesEnabled,
                onToggle: (item, kind, on) => ctrl.toggle(kind, item, on),
              ),
            ],
        },
      ],
    );
  }
}

class _PersistenceToggle extends StatelessWidget {
  final bool enabled;
  final VoidCallback onChanged;
  const _PersistenceToggle({required this.enabled, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: SwitchListTile(
        secondary: const Icon(Icons.cloud_download_outlined),
        title: const Text('Keep a local copy'),
        subtitle: const Text('Browse your last-synced library offline'),
        value: enabled,
        onChanged: (_) => onChanged(),
      ),
    );
  }
}

class _StaleBanner extends StatelessWidget {
  const _StaleBanner();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(Icons.cloud_off, color: scheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Offline — showing your last-synced library.',
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

class _TrackersRow extends StatelessWidget {
  final List<String> trackers;
  const _TrackersRow({required this.trackers});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Text(
          'Linked:',
          style: Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              for (final t in trackers)
                Chip(
                  label: Text(t),
                  labelStyle: Theme.of(context).textTheme.labelSmall,
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  final EmptyKind kind;
  const _EmptyState({required this.kind});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final needConnect = kind == EmptyKind.needConnect;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Column(
        children: [
          Icon(
            needConnect ? Icons.cast_connected : Icons.bookmark_outline,
            size: 48,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(height: 12),
          Text(
            needConnect ? 'Connect to see My Stuff' : 'Your library is empty',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          Text(
            needConnect
                ? 'Add or select a host in Settings to browse your watchlist, history, and favorites.'
                : 'Add titles from Home or Search and they’ll show up here.',
            textAlign: TextAlign.center,
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final List<LibraryItem> items;
  final MyStuffView view;
  final bool enabled;
  final void Function(LibraryItem item, String kind, bool on) onToggle;

  const _Section({
    required this.title,
    required this.items,
    required this.view,
    required this.enabled,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$title (${items.length})',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        if (items.isEmpty)
          Text(
            'Nothing here yet',
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(color: scheme.onSurfaceVariant),
          )
        else
          Card(
            child: Column(
              children: [
                for (var i = 0; i < items.length; i++) ...[
                  if (i > 0) const Divider(height: 1),
                  _ItemRow(
                    item: items[i],
                    inWatchlist: view.inSection('watchlist', items[i].id),
                    inHistory: view.inSection('watched', items[i].id),
                    inFavorites: view.inSection('favorite', items[i].id),
                    enabled: enabled,
                    onToggle: (kind, on) => onToggle(items[i], kind, on),
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

class _ItemRow extends StatelessWidget {
  final LibraryItem item;
  final bool inWatchlist;
  final bool inHistory;
  final bool inFavorites;
  final bool enabled;
  final void Function(String kind, bool on) onToggle;

  const _ItemRow({
    required this.item,
    required this.inWatchlist,
    required this.inHistory,
    required this.inFavorites,
    required this.enabled,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: SizedBox(
              width: 44,
              height: 66,
              child: PosterImage(url: item.poster),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.name ?? item.id,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
                const SizedBox(height: 2),
                Text(
                  item.type,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          _ToggleButton(
            tooltip: inWatchlist ? 'Remove from watchlist' : 'Add to watchlist',
            icon: inWatchlist ? Icons.bookmark : Icons.bookmark_outline,
            active: inWatchlist,
            enabled: enabled,
            onPressed: () => onToggle('watchlist', !inWatchlist),
          ),
          _ToggleButton(
            tooltip: inHistory ? 'Unmark watched' : 'Mark watched',
            icon: inHistory ? Icons.check_circle : Icons.check_circle_outline,
            active: inHistory,
            enabled: enabled,
            onPressed: () => onToggle('watched', !inHistory),
          ),
          _ToggleButton(
            tooltip: inFavorites ? 'Remove from favorites' : 'Add to favorites',
            icon: inFavorites ? Icons.favorite : Icons.favorite_border,
            active: inFavorites,
            enabled: enabled,
            onPressed: () => onToggle('favorite', !inFavorites),
          ),
        ],
      ),
    );
  }
}

class _ToggleButton extends StatelessWidget {
  final String tooltip;
  final IconData icon;
  final bool active;
  final bool enabled;
  final VoidCallback onPressed;

  const _ToggleButton({
    required this.tooltip,
    required this.icon,
    required this.active,
    required this.enabled,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IconButton(
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      icon: Icon(icon, size: 20, color: active ? scheme.primary : scheme.onSurfaceVariant),
      onPressed: enabled ? onPressed : null,
    );
  }
}
