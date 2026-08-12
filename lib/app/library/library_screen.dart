// Library / My Stuff tab (ticket 06).
//
// Renders the pure reducer's view: a section selector (Watchlist / History /
// Favorites), each section a virtualized + incrementally-paged list so build
// cost is O(visible), the derived empty states (needConnect / emptyLibrary),
// the offline stale banner, display-only trackers, and the local-persistence
// switch. Rows carry host-authoritative toggle chips and open the shared detail
// page on tap. Everything derives from the snapshot — the phone never
// optimistically flips a toggle.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../home/home_controller.dart';
import '../home/meta.dart';
import '../home/poster_image.dart';
import '../routes.dart';
import '../ws/client_reducer.dart' show LibraryItem;
import 'library_controller.dart';
import 'library_reducer.dart';

/// Rows rendered per "page" before the list grows on scroll.
const int _pageSize = 20;

enum _Section { watchlist, history, favorites }

extension on _Section {
  String get label => switch (this) {
        _Section.watchlist => 'Watchlist',
        _Section.history => 'History',
        _Section.favorites => 'Favorites',
      };
}

List<LibraryItem> _itemsFor(_Section s, MyStuffView v) => switch (s) {
      _Section.watchlist => v.watchlist,
      _Section.history => v.history,
      _Section.favorites => v.favorites,
    };

class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key});

  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen> {
  _Section _section = _Section.watchlist;
  int _visible = _pageSize;
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    if (_scroll.position.extentAfter > 400) return;
    final total = _itemsFor(_section, ref.read(libraryControllerProvider).view).length;
    if (_visible >= total) return;
    setState(() => _visible = (_visible + _pageSize).clamp(0, total));
  }

  void _selectSection(_Section section) {
    if (section == _section) return;
    setState(() {
      _section = section;
      _visible = _pageSize;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  void _openDetail(LibraryItem item) {
    final meta = Meta(
      id: item.id,
      type: item.type == 'movie' ? 'movie' : 'series',
      name: item.name ?? item.id,
      poster: item.poster,
      background: item.background,
    );
    ref.read(homeControllerProvider.notifier).openDetail(meta);
    Navigator.of(context).pushNamed(AppRoutes.detail);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(libraryControllerProvider);
    final view = state.view;
    final ctrl = ref.read(libraryControllerProvider.notifier);
    final togglesEnabled = state.connected;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: _PersistenceToggle(
            enabled: state.persistEnabled,
            onChanged: ctrl.togglePersistence,
          ),
        ),
        if (view.stale)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: const _StaleBanner(),
          ),
        if (view.trackers.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: _TrackersRow(trackers: view.trackers),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: SegmentedButton<_Section>(
            segments: [
              for (final s in _Section.values)
                ButtonSegment(value: s, label: Text(s.label)),
            ],
            selected: {_section},
            onSelectionChanged: (selection) => _selectSection(selection.single),
          ),
        ),
        Expanded(
          child: switch (view.emptyKind) {
            EmptyKind.needConnect => const _EmptyState(kind: EmptyKind.needConnect),
            EmptyKind.emptyLibrary => const _EmptyState(kind: EmptyKind.emptyLibrary),
            EmptyKind.none => _buildList(view, togglesEnabled, ctrl),
          },
        ),
      ],
    );
  }

  Widget _buildList(MyStuffView view, bool enabled, LibraryController ctrl) {
    final items = _itemsFor(_section, view);
    if (items.isEmpty) {
      return const _EmptySection();
    }
    final shown = _visible > items.length ? items.length : _visible;
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      itemCount: shown,
      itemBuilder: (context, i) {
        final item = items[i];
        return _ItemRow(
          item: item,
          inWatchlist: view.inSection('watchlist', item.id),
          inHistory: view.inSection('watched', item.id),
          inFavorites: view.inSection('favorite', item.id),
          enabled: enabled,
          onToggle: (kind, on) => ctrl.toggle(kind, item, on),
          onOpen: () => _openDetail(item),
        );
      },
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
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
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
      ),
    );
  }
}

class _EmptySection extends StatelessWidget {
  const _EmptySection();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Text(
        'Nothing here yet',
        style: Theme.of(context)
            .textTheme
            .bodyMedium
            ?.copyWith(color: scheme.onSurfaceVariant),
      ),
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
  final VoidCallback onOpen;

  const _ItemRow({
    required this.item,
    required this.inWatchlist,
    required this.inHistory,
    required this.inFavorites,
    required this.enabled,
    required this.onToggle,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onOpen,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
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
            const SizedBox(width: 4),
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
