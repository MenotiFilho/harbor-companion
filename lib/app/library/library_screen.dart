// Library / My Stuff tab (ticket 06; editorial refresh ticket 89).
//
// Renders the pure reducer's view: a glass section selector (Watchlist /
// History / Favorites), each section a virtualized + incrementally-paged list
// of hairline rows so build cost is O(visible), the derived empty states
// (needConnect / emptyLibrary), display-only trackers. Rows carry
// host-authoritative toggle chips — lit in the Accent only when the host says
// the membership is on — and open the shared detail page on tap. Everything
// derives from the snapshot; the phone never optimistically flips a toggle.
//
// Honesty rule (parent #80): the wire has no Watch progress for library items,
// so no row renders a progress bar (the prototype's bars are a deliberate,
// documented delta).
//
// Glass budget (ADR-0010): the segmented control and the rows are scroll
// content — translucent fill + hairline, never BackdropFilter.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../home/home_controller.dart';
import '../home/meta.dart';
import '../home/poster_image.dart';
import '../routes.dart';
import '../theme.dart';
import '../ui/glass_surface.dart';
import '../ui/rows.dart';
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
        if (view.trackers.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
            child: _TrackersRow(trackers: view.trackers),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
          child: _SectionSegmented(
            selected: _section,
            onSelected: _selectSection,
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
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
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

/// The section selector (prototype `.seg`): one pill of equal segments, the
/// selected one lit in the Accent family. Translucent fill + hairline, never
/// blurred (ADR-0010).
class _SectionSegmented extends StatelessWidget {
  final _Section selected;
  final ValueChanged<_Section> onSelected;
  const _SectionSegmented({required this.selected, required this.onSelected});

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    return GlassSurface(
      radius: tokens.radiusSmall,
      padding: const EdgeInsets.all(3),
      child: Row(
        children: [
          for (var i = 0; i < _Section.values.length; i++) ...[
            if (i > 0) const SizedBox(width: 2),
            Expanded(
              child: _Segment(
                label: _Section.values[i].label,
                selected: _Section.values[i] == selected,
                onTap: () => onSelected(_Section.values[i]),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// One segment: the selected pill reads in the Accent, the rest stay quiet.
/// 42dp tall plus the pill's 3+3 padding keeps a 48dp target (parent #80).
class _Segment extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _Segment({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    return Semantics(
      button: true,
      selected: selected,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 42),
          child: Container(
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: selected ? tokens.accentFill : Colors.transparent,
              borderRadius: BorderRadius.circular(tokens.radiusSmall - 3),
              border: Border.all(
                color: selected ? tokens.accentLine : Colors.transparent,
              ),
            ),
            child: Text(
              label,
              maxLines: 1,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: selected ? tokens.accentInk : tokens.inkFaint,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TrackersRow extends StatelessWidget {
  final List<String> trackers;
  const _TrackersRow({required this.trackers});

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    return Row(
      children: [
        Text(
          'Linked:',
          style: Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(color: tokens.inkFaint),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [for (final t in trackers) _TrackerChip(label: t)],
          ),
        ),
      ],
    );
  }
}

/// A linked tracker (prototype `.tagchip`): a hairline pill in the secondary
/// ink. Display-only — v1 has no tracker action to offer.
class _TrackerChip extends StatelessWidget {
  final String label;
  const _TrackerChip({required this.label});

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: tokens.hair),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.4,
          color: tokens.inkMuted,
        ),
      ),
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
    final tokens = AppTokens.of(context);
    return ListRow(
      leading: Container(
        width: 44,
        height: 66,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: tokens.hairSoft),
        ),
        child: PosterImage(url: item.poster),
      ),
      title: item.name ?? item.id,
      titleMaxLines: 2,
      subtitle: item.type,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
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
      onTap: onOpen,
    );
  }
}

/// The host-authoritative toggle chip: lit in the Accent only when the
/// membership is on, quiet ink when off, disabled while disconnected. Keeps a
/// 48dp target (parent #80) even with the small glyph.
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
    final tokens = AppTokens.of(context);
    return IconButton(
      tooltip: tooltip,
      iconSize: 20,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
      icon: Icon(icon, color: active ? tokens.accent : tokens.inkFaint),
      onPressed: enabled ? onPressed : null,
    );
  }
}
