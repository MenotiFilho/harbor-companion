// Dedicated rail grid (tickets 76, 77, ADR-0009).
//
// A rail's title or its "See more" card pushes this route with the rail already
// snapshotted in the controller (`HomeState.activeRailGrid`): the full
// downloaded page (Cinemeta ~50, Stremboxd 100, TMDB 20), its source, request
// and cursor. The grid renders every captured item in a responsive,
// width-driven grid that reuses the rail's `PosterCard` — instant, with no
// fetch, no cache write and no age badge. A Home round while the grid is open
// never changes this snapshot.
//
// On-scroll pagination (#77): scrolling near the bottom asks the controller for
// the next page (`skip=<loaded>` for Cinemeta/Stremboxd, `?page=N+1` for TMDB),
// which appends deduped by id. The footer is honest per source: a spinner while
// a page loads, "End" when the source is exhausted (or the Cinemeta cap is hit),
// and an error + "Try again" when a page fails — the already-loaded items stay
// on screen. A `/trending/*` rail opens already ended (20-only).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'home_controller.dart';
import 'home_reducer.dart';
import 'home_screen.dart' show PosterCard;

class RailGridScreen extends ConsumerWidget {
  const RailGridScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final grid = ref.watch(homeControllerProvider).activeRailGrid;
    final controller = ref.read(homeControllerProvider.notifier);

    return Scaffold(
      appBar: AppBar(title: Text(grid?.title ?? 'Grid')),
      body: grid == null
          ? const Center(child: Text('No rail selected'))
          : _RailGrid(
              grid: grid,
              onLoadMore: controller.loadMoreRailGrid,
              onRetry: controller.retryRailGridPage,
            ),
    );
  }
}

/// The responsive grid itself: columns are chosen by the available width via
/// [SliverGridDelegateWithMaxCrossAxisExtent], each cell is the rail's own
/// [PosterCard] (its width left null so the delegate defines it), and a
/// full-width footer sliver carries the "End"/spinner/retry state.
class _RailGrid extends StatefulWidget {
  final RailGridSnapshot grid;
  final VoidCallback onLoadMore;
  final VoidCallback onRetry;

  const _RailGrid({
    required this.grid,
    required this.onLoadMore,
    required this.onRetry,
  });

  @override
  State<_RailGrid> createState() => _RailGridState();
}

class _RailGridState extends State<_RailGrid> {
  final ScrollController _controller = ScrollController();

  /// How close (px) to the bottom the scroll must get before the next page is
  /// requested — roughly two rows of posters, so the page is usually ready
  /// before the user reaches the footer.
  static const double _loadThreshold = 400;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onScroll);
    // A first page that does not fill the viewport never emits a scroll
    // notification, so the on-scroll trigger alone would never fire. Check once
    // the first frame has laid the slivers out.
    _scheduleLoadCheck();
  }

  @override
  void didUpdateWidget(_RailGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A page landing (or ending/failing) can still leave room: re-check after
    // the new content lays out so a short page keeps paginating on its own.
    if (!identical(oldWidget.grid, widget.grid)) {
      _scheduleLoadCheck();
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onScroll);
    _controller.dispose();
    super.dispose();
  }

  /// Defers [_maybeLoadMore] to after the frame that just built this widget, so
  /// the sliver geometry is current. Cheap and idempotent: it only dispatches
  /// when there is room, and the reducer owns the in-flight/ended/error guard.
  void _scheduleLoadCheck() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _maybeLoadMore();
    });
  }

  void _onScroll() => _maybeLoadMore();

  /// Requests the next page when the viewport has room for it and the source is
  /// not done. A no-scroll short page therefore pages itself. Idempotent — the
  /// guards here plus the reducer's own loading/ended/error checks mean a
  /// duplicate call cannot stack requests.
  void _maybeLoadMore() {
    if (!mounted || !_controller.hasClients) return;
    final grid = widget.grid;
    // Nothing to request while loading, ended, or showing the error footer
    // (the retry button owns that case). The reducer also guards, but skipping
    // the dispatch keeps a fast scroll cheap.
    if (grid.ended || grid.loading || grid.error != null) return;
    final position = _controller.position;
    if (position.maxScrollExtent - position.pixels <= _loadThreshold) {
      widget.onLoadMore();
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = widget.grid.items;
    if (items.isEmpty) {
      return const Center(child: Text('Nothing to show'));
    }
    return CustomScrollView(
      key: const ValueKey('railGrid'),
      controller: _controller,
      // Always scrollable so a short page keeps a live position for the
      // post-frame check and still accepts a manual pull.
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.all(16),
          sliver: SliverGrid(
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 150,
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
              childAspectRatio: 0.58,
            ),
            delegate: SliverChildBuilderDelegate(
              (context, i) => PosterCard(meta: items[i], width: null),
              childCount: items.length,
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: _GridFooter(grid: widget.grid, onRetry: widget.onRetry),
        ),
      ],
    );
  }
}

/// The grid's bottom edge (ticket 77): a spinner while a page is in flight, the
/// retry affordance when the last page failed, "End" when the source is
/// exhausted, and a small spacer while more may be requested.
class _GridFooter extends StatelessWidget {
  final RailGridSnapshot grid;
  final VoidCallback onRetry;

  const _GridFooter({required this.grid, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (grid.loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (grid.error != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
        child: Column(
          children: [
            Text(
              "Couldn't load more.",
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 8),
            FilledButton.tonal(
              onPressed: onRetry,
              child: const Text('Try again'),
            ),
          ],
        ),
      );
    }
    if (grid.ended) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: Text(
            'End',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
      );
    }
    return const SizedBox(height: 24);
  }
}
