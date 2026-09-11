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
// Tapping a poster opens the detail page via the reducer's `openDetail`, then
// pushes the detail route.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../routes.dart';
import 'home_controller.dart';
import 'home_rail.dart';
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

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(homeControllerProvider);

    if (state.allFailed) {
      return _CatalogError(
        message: state.firstError ?? 'Could not load the catalog.',
        onRetry: _reload,
      );
    }
    if (state.isEmptyHome) {
      return _EmptyCatalog(onRefresh: _reload);
    }
    final keys = state.renderKeys;
    return ListView.builder(
      key: const ValueKey('homeList'),
      itemCount: keys.length,
      itemExtent: kRowExtent,
      itemBuilder: (context, i) {
        final rowKey = keys[i];
        return _RailBlock(
          rail: state.rails[rowKey],
          rowKey: rowKey,
          onRetry: () => _retryRail(rowKey),
        );
      },
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

  const _RailBlock({required this.rail, required this.rowKey, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final current = rail;
    if (current != null && current.hasItems) {
      return HomeRowRail(
        row: HomeRow(rowKey, current.title, current.items),
        fromCache: current.fromCache,
        updatedAt: current.updatedAt,
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

  const HomeRowRail({
    super.key,
    required this.row,
    this.fromCache = false,
    this.updatedAt,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: kRowExtent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
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
          Expanded(
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: row.items.length,
              itemBuilder: (context, j) => PosterCard(meta: row.items[j]),
            ),
          ),
        ],
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
  const PosterCard({super.key, required this.meta});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return GestureDetector(
      onTap: () {
        ref.read(homeControllerProvider.notifier).openDetail(meta);
        Navigator.of(context).pushNamed(AppRoutes.detail);
      },
      child: SizedBox(
        width: 110,
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
