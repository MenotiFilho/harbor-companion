// Home tab (tickets 04, 71): virtualized poster rails + detail navigation.
//
// A vertical `ListView.builder` of one block per **planned rail** (ticket 71):
// each block is the loaded rail, a skeleton while its outcome is pending, or a
// local retry card when it failed without a previous copy. There is no global
// spinner hiding available content, and the global empty / everything-failed
// screens are derived from the per-rail state, not a blocking status.
//
// Each rail is a horizontal `ListView.builder` of poster cards — build cost is
// O(visible), not O(catalog). This is the rendering architecture the Home perf
// spike (#8) proved: sustained 60fps via lazy rails + raised `ImageCache` limits
// (set app-wide in main()).
//
// Each rail renders at most `kHomeRailCap` (20) items (ticket 75, ADR-0009): a
// render-time slice over the full source page, which stays in state/cache for
// the grid. When the rail was cut or its source reports more, a trailing "See
// more" card appears, and the rail title is always tappable; both open the
// dedicated grid route (#76).
//
// Tapping a poster opens the detail page via the reducer's `openDetail`, then
// pushes the detail route.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../routes.dart';
import 'home_controller.dart';
import 'home_rail.dart';
import 'home_reducer.dart';
import 'home_rows.dart';
import 'meta.dart';
import 'poster_image.dart';

const double kRowExtent = 176;

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  @override
  void initState() {
    super.initState();
    // Load rails on first mount — deferred to after the frame so the provider
    // mutation never happens mid-build. Re-entry is a no-op once a round has
    // started (the reducer guards it), so switching tabs doesn't refetch.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(homeControllerProvider.notifier).load();
    });
  }

  void _reload() => ref.read(homeControllerProvider.notifier).reload();

  void _retryRail(String rowKey) =>
      ref.read(homeControllerProvider.notifier).retryRail(rowKey);

  /// Opens the dedicated rail grid (tickets 75, 76): the reducer snapshots the
  /// rail (items + source + request + cursor) and the widget pushes the route,
  /// like the detail flow.
  void _openRail(String rowKey) {
    ref.read(homeControllerProvider.notifier).openRailGrid(rowKey);
    Navigator.of(context).pushNamed(AppRoutes.railGrid);
  }

  /// The pull gesture (ADR-0008): starts a round or joins the one in flight,
  /// and keeps the indicator up until every planned rail settles. A short
  /// snackbar appears only when a manual round fails entirely — partial
  /// failures and the automatic round stay silent (the age badge covers cache).
  Future<void> _pullRefresh() async {
    await ref.read(homeControllerProvider.notifier).refresh();
    if (!mounted) return;
    final summary = ref.read(homeControllerProvider).roundSummary;
    if (summary?.notifyFailure ?? false) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: const Text("Couldn't refresh the catalog."),
          duration: const Duration(seconds: 2),
        ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(homeControllerProvider);
    return RefreshIndicator(onRefresh: _pullRefresh, child: _body(state));
  }

  Widget _body(HomeState state) {
    if (state.allFailed) {
      return _ScrollableMessage(
        child: _CatalogError(
          message: state.firstError ?? 'Could not load the catalog.',
          onRetry: _reload,
        ),
      );
    }
    if (state.isEmptyHome) {
      return _ScrollableMessage(child: _EmptyCatalog(onRefresh: _reload));
    }
    final keys = state.renderKeys;
    return ListView.builder(
      key: const ValueKey('homeList'),
      // Always accepts overscroll so a short Home still pulls to refresh.
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: keys.length,
      itemExtent: kRowExtent,
      itemBuilder: (context, i) {
        final rowKey = keys[i];
        return _RailBlock(
          rail: state.rails[rowKey],
          rowKey: rowKey,
          onRetry: () => _retryRail(rowKey),
          onOpen: () => _openRail(rowKey),
        );
      },
    );
  }
}

/// Wraps a no-content screen (empty Home / global error) in a scrollable that
/// always accepts overscroll, so pull-to-refresh works even with nothing to
/// scroll. The screen itself keeps its buttons (ADR-0008).
class _ScrollableMessage extends StatelessWidget {
  final Widget child;
  const _ScrollableMessage({required this.child});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: child,
        ),
      ),
    );
  }
}

/// One planned rail's block: content if it has items (loaded, or a failed rail
/// keeping its previous copy), a local retry card if it failed with nothing to
/// show, a skeleton while pending.
class _RailBlock extends StatelessWidget {
  final RailState? rail;
  final String rowKey;
  final VoidCallback onRetry;
  final VoidCallback onOpen;

  const _RailBlock({
    required this.rail,
    required this.rowKey,
    required this.onRetry,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final current = rail;
    if (current != null && current.hasItems) {
      return HomeRowRail(
        row: HomeRow(rowKey, current.title, current.items),
        fromCache: current.fromCache,
        updatedAt: current.updatedAt,
        hasMore: current.hasMore,
        onOpen: onOpen,
      );
    }
    if (current != null && current.status == RailStatus.failed) {
      return _RailErrorCard(
        title: current.title.isEmpty ? homeRowLabel(rowKey) : current.title,
        onRetry: onRetry,
      );
    }
    return HomeRailSkeleton(rowKey: rowKey, title: homeRowLabel(rowKey));
  }
}

/// Shown when the user turned the built-in rails off and has no own source
/// (Letterboxd) rails either, or when a settled round produced nothing — an
/// empty Home by choice or by empty catalogs, not a failure.
class _EmptyCatalog extends StatelessWidget {
  final VoidCallback onRefresh;
  const _EmptyCatalog({required this.onRefresh});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.video_library_outlined, size: 48, color: scheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text('No catalogs to show', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              'Enable some rows under "Home rows", or check your Letterboxd '
              'manifest URL in Settings.',
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              alignment: WrapAlignment.center,
              children: [
                OutlinedButton.icon(
                  onPressed: onRefresh,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Refresh'),
                ),
                FilledButton.tonal(
                  onPressed: () => Navigator.of(context).pushNamed(AppRoutes.settings),
                  child: const Text('Open settings'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _CatalogError extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _CatalogError({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off, size: 48, color: scheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton.tonal(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}

class HomeRowRail extends StatelessWidget {
  final HomeRow row;

  /// Whether this rail is served from the per-rail cache (show the age badge).
  final bool fromCache;

  /// The cache write time (ms since epoch) the badge renders; null for fresh.
  final int? updatedAt;

  /// The source's "there is more than this page" signal (ticket 75). Combined
  /// with the 20-item render cap it decides the "See more" card.
  final bool hasMore;

  /// The tap seam for the title and the "See more" card (ticket 75); #76 opens
  /// the dedicated grid route from it. Required so the title is always tappable.
  final VoidCallback onOpen;

  const HomeRowRail({
    super.key,
    required this.row,
    required this.onOpen,
    this.fromCache = false,
    this.updatedAt,
    this.hasMore = false,
  });

  @override
  Widget build(BuildContext context) {
    // Cap at render time: the full list stays in `row.items` for the grid.
    final visible = homeRailVisibleItems(row.items);
    final showSeeMore =
        homeRailShowsSeeMore(itemCount: row.items.length, hasMore: hasMore);
    return SizedBox(
      height: kRowExtent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: onOpen,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      row.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  if (fromCache) HomeRailAgeBadge(updatedAt: updatedAt),
                ],
              ),
            ),
          ),
          Expanded(
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: visible.length + (showSeeMore ? 1 : 0),
              itemBuilder: (context, j) => j < visible.length
                  ? PosterCard(meta: visible[j])
                  : _SeeMoreCard(onTap: onOpen),
            ),
          ),
        ],
      ),
    );
  }
}

/// The "See more" card at the end of a capped rail (ticket 75, ADR-0009): a
/// poster-shaped affordance that opens the rail's dedicated grid (#76). Shown
/// iff the rail was cut at [kHomeRailCap] or its source reports more.
class _SeeMoreCard extends StatelessWidget {
  final VoidCallback? onTap;
  const _SeeMoreCard({this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: 110,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Container(
                width: double.infinity,
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(Icons.more_horiz, color: scheme.onSurfaceVariant),
              ),
            ),
            const SizedBox(height: 2),
            Text(
              'See more',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

/// The age badge on a rail served from the cache (ticket 72, ADR-0004). It is
/// present while [RailState.fromCache] holds and disappears the moment a fresh
/// `loaded` outcome commits. The label is a coarse relative age so it never
/// needs a ticking clock: "cached" under a minute, then `Nm`/`Nh`/`Nd`.
class HomeRailAgeBadge extends StatelessWidget {
  final int? updatedAt;
  const HomeRailAgeBadge({super.key, this.updatedAt});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(left: 8),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.history, size: 12, color: scheme.onSurfaceVariant),
          const SizedBox(width: 4),
          Text(
            homeRailAgeLabel(updatedAt),
            style: Theme.of(context)
                .textTheme
                .labelSmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

/// A coarse relative age for [updatedAt] (ms since epoch) — pure so widget tests
/// can pin it without a clock. Null means "cached, age unknown".
String homeRailAgeLabel(int? updatedAt, {DateTime? now}) {
  if (updatedAt == null) return 'cached';
  final reference = now ?? DateTime.now();
  final age = reference.difference(DateTime.fromMillisecondsSinceEpoch(updatedAt));
  if (age.inMinutes < 1) return 'cached';
  if (age.inMinutes < 60) return '${age.inMinutes}m';
  if (age.inHours < 24) return '${age.inHours}h';
  return '${age.inDays}d';
}

/// The pending block for a planned rail: its known title plus placeholder
/// posters, so a slow rail holds its place without hiding the others.
class HomeRailSkeleton extends StatelessWidget {
  final String rowKey;
  final String title;
  const HomeRailSkeleton({super.key, required this.rowKey, required this.title});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: kRowExtent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          Expanded(
            child: ListView.builder(
              key: ValueKey('railSkeleton:$rowKey'),
              scrollDirection: Axis.horizontal,
              physics: const NeverScrollableScrollPhysics(),
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: 4,
              itemBuilder: (context, _) => Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Container(
                  width: 110,
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The local retry card replacing a failed rail that has no previous copy; the
/// other rails around it keep rendering.
class _RailErrorCard extends StatelessWidget {
  final String title;
  final VoidCallback onRetry;
  const _RailErrorCard({required this.title, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: kRowExtent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Container(
                width: double.infinity,
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    Icon(Icons.cloud_off, size: 20, color: scheme.onSurfaceVariant),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Couldn\'t load this row.',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ),
                    TextButton(onPressed: onRetry, child: const Text('Retry')),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class PosterCard extends ConsumerWidget {
  final Meta meta;

  /// Fixed card width — the Home rail's 110. Null lets the parent define it:
  /// the rail grid's delegate supplies the tile width, so the card fills it
  /// (ticket 76). One card, no fork.
  final double? width;

  const PosterCard({super.key, required this.meta, this.width = 110});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return GestureDetector(
      onTap: () {
        ref.read(homeControllerProvider.notifier).openDetail(meta);
        Navigator.of(context).pushNamed(AppRoutes.detail);
      },
      child: SizedBox(
        width: width,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: double.infinity,
                  child: PosterImage(url: meta.poster),
                ),
              ),
            ),
            const SizedBox(height: 2),
            Text(
              meta.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
