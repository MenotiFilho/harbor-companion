// Home tab (ticket 04): virtualized poster rails + detail navigation.
//
// A vertical `ListView.builder` of `HomeRowRail`s, each a horizontal
// `ListView.builder` of poster cards — build cost is O(visible), not
// O(catalog). This is the rendering architecture the Home perf spike (#8)
// proved: sustained 60fps via lazy rails + raised `ImageCache` limits (set
// app-wide in main()).
//
// Tapping a poster opens the detail page via the reducer's `openDetail`, then
// pushes the detail route.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../routes.dart';
import 'home_controller.dart';
import 'home_reducer.dart';
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
    // Load rows on first mount — deferred to after the frame so the provider
    // mutation never happens mid-build. Re-entry is a no-op while ready (the
    // reducer guards it), so switching tabs doesn't refetch.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(homeControllerProvider.notifier).load();
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(homeControllerProvider);
    switch (state.status) {
      case HomeStatus.idle:
      case HomeStatus.loading:
        return const Center(child: CircularProgressIndicator());
      case HomeStatus.failed:
        return _CatalogError(
          message: state.lastError ?? 'Could not load the catalog.',
          onRetry: () => ref.read(homeControllerProvider.notifier).load(),
        );
      case HomeStatus.ready:
        if (state.rows.isEmpty) {
          return _EmptyCatalog(
            onRefresh: () => ref.read(homeControllerProvider.notifier).reload(),
          );
        }
        return ListView.builder(
          key: const ValueKey('homeList'),
          itemCount: state.rows.length,
          itemExtent: kRowExtent,
          itemBuilder: (context, i) => HomeRowRail(row: state.rows[i]),
        );
    }
  }
}

/// Shown when the user turned the built-in rails off and has no own source
/// (Letterboxd) rails either — an empty Home by choice, not a failure.
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
  const HomeRowRail({super.key, required this.row});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: kRowExtent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text(
              row.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium,
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
