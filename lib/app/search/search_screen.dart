// Search tab (ticket 05): debounced query field, pinned top-match card, and the
// merged results grid (movies/series interleaved + anime).
//
// Everything derives from the pure reducer's `results`. Tapping a movie/series
// opens the detail page (the Home detail screen, ticket 04); tapping an anime
// hit plays directly (there is no anime detail page); the play button on any
// tile plays on the host via `playMeta`. Results appear incrementally as each
// source settles; the top-match card is pinned only when a keyed TMDB search
// (or an anime swap) produced one.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../home/home_controller.dart';
import '../home/meta.dart';
import '../home/poster_image.dart';
import '../routes.dart';
import 'search_controller.dart';
import 'search_reducer.dart';

class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(searchControllerProvider);
    final results = state.results;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: TextField(
            controller: _controller,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: 'Search movies, series, anime',
              prefixIcon: const Icon(Icons.search),
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: Icon(state.hideAnime
                    ? Icons.visibility_off
                    : Icons.visibility),
                tooltip: state.hideAnime ? 'Show anime' : 'Hide anime',
                onPressed: () =>
                    ref.read(searchControllerProvider.notifier).toggleHideAnime(),
              ),
            ),
            onChanged: (v) =>
                ref.read(searchControllerProvider.notifier).queryChanged(v),
            onSubmitted: (_) =>
                ref.read(searchControllerProvider.notifier).submit(),
          ),
        ),
        Expanded(child: _body(state, results)),
      ],
    );
  }

  Widget _body(SearchState state, SearchResults? results) {
    switch (state.status) {
      case SearchStatus.idle:
        return const _Hint(
          icon: Icons.search,
          message: 'Search across movies, series, and anime at once.',
        );
      case SearchStatus.typing:
        return const Center(child: Text('…'));
      case SearchStatus.loading:
      case SearchStatus.done:
        if (results == null) {
          return const Center(child: CircularProgressIndicator());
        }
        final empty = results.topMatch == null &&
            results.movies.isEmpty &&
            results.series.isEmpty &&
            results.anime.isEmpty;
        if (empty) {
          return _Hint(
            icon: Icons.search_off,
            message: 'No results for "${results.query}".',
          );
        }
        return _Results(results: results);
    }
  }
}

class _Hint extends StatelessWidget {
  final IconData icon;
  final String message;
  const _Hint({required this.icon, required this.message});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 56, color: scheme.onSurfaceVariant),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodyLarge
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

class _Results extends ConsumerWidget {
  final SearchResults results;
  const _Results({required this.results});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final moviesAndSeries = results.grid;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        if (results.topMatch != null) ...[
          _TopMatchCard(topMatch: results.topMatch!),
          const SizedBox(height: 16),
        ],
        if (moviesAndSeries.isNotEmpty) ...[
          Text('Results', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              childAspectRatio: 0.52,
            ),
            itemCount: moviesAndSeries.length,
            itemBuilder: (context, i) =>
                _ResultTile(meta: moviesAndSeries[i]),
          ),
        ],
        if (results.anime.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text('Anime', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              childAspectRatio: 0.52,
            ),
            itemCount: results.anime.length,
            itemBuilder: (context, i) =>
                _ResultTile(meta: results.anime[i].meta),
          ),
        ],
      ],
    );
  }
}

/// A result tile: tap opens detail (movie/series) or plays (anime); the play
/// button always plays on the host.
class _ResultTile extends ConsumerWidget {
  final Meta meta;
  const _ResultTile({required this.meta});

  bool get _isAnime => meta.type == 'anime';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final search = ref.read(searchControllerProvider.notifier);

    void play() => search.playMeta(meta);
    void open() {
      if (_isAnime) {
        play();
        return;
      }
      ref.read(homeControllerProvider.notifier).openDetail(meta);
      Navigator.of(context).pushNamed(AppRoutes.detail);
    }

    return GestureDetector(
      onTap: open,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: PosterImage(url: meta.poster),
                ),
                Positioned(
                  right: 4,
                  bottom: 4,
                  child: IconButton.filledTonal(
                    iconSize: 20,
                    icon: const Icon(Icons.play_arrow),
                    tooltip: 'Play',
                    onPressed: play,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Text(
            meta.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _TopMatchCard extends ConsumerWidget {
  final TopMatch topMatch;
  const _TopMatchCard({required this.topMatch});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final meta = topMatch.meta;
    final isAnime = meta.type == 'anime';

    void play() =>
        ref.read(searchControllerProvider.notifier).playMeta(meta);
    void openDetail() {
      ref.read(homeControllerProvider.notifier).openDetail(meta);
      Navigator.of(context).pushNamed(AppRoutes.detail);
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.star, size: 18, color: scheme.primary),
                const SizedBox(width: 6),
                Text('Top match', style: text.titleSmall),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox(
                    width: 96,
                    height: 144,
                    child: PosterImage(url: meta.poster),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(meta.name, style: text.titleMedium),
                      if (meta.releaseInfo != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          meta.releaseInfo!,
                          style: text.bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ],
                      if (topMatch.overview != null &&
                          topMatch.overview!.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(
                          topMatch.overview!,
                          maxLines: 4,
                          overflow: TextOverflow.ellipsis,
                          style: text.bodySmall,
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                FilledButton.icon(
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Play'),
                  onPressed: play,
                ),
                if (!isAnime) ...[
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: openDetail,
                    child: const Text('Details'),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}
