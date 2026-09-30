// Dedicated rail grid (tickets 76, 77, ADR-0009; restyled in issue #90).
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
//
// Glass budget (ADR-0010): the grid is long scrolling content, so the cards and
// the footer are translucent fill + hairline — never a BackdropFilter.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../theme.dart';
import 'home_controller.dart';
import 'home_reducer.dart';
import 'home_screen.dart' show PosterCard;

/// The "See more" grid geometry (issue #90): responsive columns per ADR-0009,
/// restyled to the editorial rhythm — 10dp gutters and `childAspectRatio`
/// leaving room for the card's 2:3 art plus the two-line type block
/// ([PosterCard]). On a phone this lands on the same three columns as Search.
const SliverGridDelegateWithMaxCrossAxisExtent _gridDelegate =
    SliverGridDelegateWithMaxCrossAxisExtent(
  maxCrossAxisExtent: 150,
  mainAxisSpacing: 10,
  crossAxisSpacing: 10,
  childAspectRatio: 0.52,
);

class RailGridScreen extends ConsumerWidget {
  const RailGridScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final grid = ref.watch(homeControllerProvider).activeRailGrid;
    final controller = ref.read(homeControllerProvider.notifier);

    return Scaffold(
      appBar: AppBar(title: Text(grid?.title ?? 'Grid')),
      body: grid == null
          ? const _GridMessage('No rail selected')
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
      return const _GridMessage('Nothing to show');
    }
    return CustomScrollView(
      key: const ValueKey('railGrid'),
      controller: _controller,
      // Always scrollable so a short page keeps a live position for the
      // post-frame check and still accepts a manual pull.
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          sliver: SliverGrid(
            gridDelegate: _gridDelegate,
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

/// Sober centered copy for the grid's empty and placeholder states.
class _GridMessage extends StatelessWidget {
  final String message;
  const _GridMessage(this.message);

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        message,
        textAlign: TextAlign.center,
        style: Theme.of(context)
            .textTheme
            .bodyMedium
            ?.copyWith(color: AppTokens.of(context).inkFaint),
      ),
    );
  }
}

/// The grid's bottom edge (ticket 77): a spinner while a page is in flight, the
/// retry affordance when the last page failed, "End" when the source is
/// exhausted, and a small spacer while more may be requested. Restyled for the
/// Editorial Cinema language (issue #90) — quiet ink, hairline vocabulary.
class _GridFooter extends StatelessWidget {
  final RailGridSnapshot grid;
  final VoidCallback onRetry;

  const _GridFooter({required this.grid, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final text = Theme.of(context).textTheme;
    if (grid.loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 28),
        child: Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (grid.error != null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
        child: Column(
          children: [
            Text(
              "Couldn't load more.",
              textAlign: TextAlign.center,
              style: text.bodySmall?.copyWith(color: tokens.inkMuted),
            ),
            const SizedBox(height: 12),
            FilledButton.tonal(
              onPressed: onRetry,
              style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
              child: const Text('Try again'),
            ),
          ],
        ),
      );
    }
    if (grid.ended) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 28),
        child: Center(
          child: Text(
            'End',
            style: text.bodySmall?.copyWith(
              color: tokens.inkFaint,
              letterSpacing: 1.4,
            ),
          ),
        ),
      );
    }
    return const SizedBox(height: 24);
  }
}
