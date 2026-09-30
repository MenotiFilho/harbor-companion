// Search tab (ticket 05; editorial refresh in ticket 88): a glass query field,
// a sober empty state, a final-shape skeleton while sources are in flight, the
// top match in an unblurred glass card, and the merged results in 3-column
// grids.
//
// Everything derives from the pure reducer's `results`. Tapping any result
// opens the shared Home detail page (ticket 04), which is the single play
// origin — Search never plays directly, so the host always gets episode
// context and can auto-advance. Results appear incrementally as each source
// settles; the top-match card is pinned only when a keyed TMDB search (or an
// anime swap) produced one, and the grid holds everything else in the
// reducer's pinned order.
//
// Glass budget (ADR-0010): the field is fixed chrome above the scroll content,
// so it may use real blur; the top-match card and the grids are scrolling
// content — translucent fill + hairline only.
//
// Honesty rule (parent #80): the loading state is a skeleton in the final
// shape, never a lonely spinner, and the no-results message waits until every
// source has settled.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../home/home_controller.dart';
import '../home/home_screen.dart' show PosterCard;
import '../home/meta.dart';
import '../home/poster_image.dart';
import '../routes.dart';
import '../theme.dart';
import '../ui/glass_surface.dart';
import '../ui/press_scale.dart';
import '../ui/section_header.dart';
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

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
          child: _SearchField(controller: _controller, state: state),
        ),
        Expanded(child: _body(state)),
      ],
    );
  }

  Widget _body(SearchState state) {
    switch (state.status) {
      case SearchStatus.idle:
        return const _SearchMessage(
          'Search across movies, series, and anime at once.\n'
          'Results appear as each source responds.',
        );
      case SearchStatus.typing:
        return const _SearchSkeleton();
      case SearchStatus.loading:
        final results = state.results;
        // A source may settle empty before the others land; keep the skeleton
        // until something exists AND all sources settled, so the screen never
        // claims "no results" while a source is still in flight.
        if (results == null || _isEmptyResults(results)) {
          return const _SearchSkeleton();
        }
        return _Results(results: results);
      case SearchStatus.done:
        final results = state.results;
        if (results == null || _isEmptyResults(results)) {
          return _SearchMessage('No results for "${state.query.trim()}".');
        }
        return _Results(results: results);
    }
  }
}

bool _isEmptyResults(SearchResults r) =>
    r.topMatch == null &&
    r.movies.isEmpty &&
    r.series.isEmpty &&
    r.anime.isEmpty;

/// The results geometry, shared by the real grids and the skeleton so the two
/// can never drift apart: three columns, 10dp gutters, room for the 2:3 art
/// plus the card's two-line name.
const SliverGridDelegateWithFixedCrossAxisCount _resultGridDelegate =
    SliverGridDelegateWithFixedCrossAxisCount(
  crossAxisCount: 3,
  mainAxisSpacing: 10,
  crossAxisSpacing: 10,
  childAspectRatio: 0.52,
);

/// The glass query field (ADR-0010 chrome: fixed, always on screen, above the
/// scroll content — real blur is inside the budget). The eye toggles the
/// parental hide-anime filter.
class _SearchField extends ConsumerWidget {
  final TextEditingController controller;
  final SearchState state;
  const _SearchField({required this.controller, required this.state});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = AppTokens.of(context);
    final ctrl = ref.read(searchControllerProvider.notifier);
    return GlassSurface(
      blurred: true,
      radius: 16,
      child: Padding(
        padding: const EdgeInsets.only(left: 14, right: 4),
        child: Row(
          children: [
            Icon(Icons.search, size: 20, color: tokens.inkFaint),
            const SizedBox(width: 11),
            Expanded(
              child: TextField(
                controller: controller,
                textInputAction: TextInputAction.search,
                style: TextStyle(fontSize: 14, color: tokens.ink),
                decoration: InputDecoration(
                  hintText: 'Search movies, series, anime',
                  // The hint reads over the glass fill; the AA ink step keeps
                  // it legible (issue #91).
                  hintStyle: TextStyle(fontSize: 14, color: tokens.inkMuted),
                  filled: false,
                  isDense: true,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(vertical: 14),
                ),
                onChanged: ctrl.queryChanged,
                onSubmitted: (_) => ctrl.submit(),
              ),
            ),
            IconButton(
              icon: Icon(state.hideAnime
                  ? Icons.visibility_off
                  : Icons.visibility),
              tooltip: state.hideAnime ? 'Show anime' : 'Hide anime',
              iconSize: 20,
              // Interactive: keeps the AA ramp and the full 48dp target.
              color: tokens.inkMuted,
              onPressed: ctrl.toggleHideAnime,
            ),
          ],
        ),
      ),
    );
  }
}

/// The sober empty / no-results copy: centered, muted, no artwork.
class _SearchMessage extends StatelessWidget {
  final String message;
  const _SearchMessage(this.message);

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(40, 64, 40, 0),
      child: Text(
        message,
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: tokens.inkFaint,
              fontSize: 12.5,
              height: 1.7,
            ),
      ),
    );
  }
}

class _Results extends StatelessWidget {
  final SearchResults results;
  const _Results({required this.results});

  @override
  Widget build(BuildContext context) {
    // The top match rides in its own card; the grid carries the rest in the
    // reducer's pinned order (its id is skipped so it never renders twice).
    final topId = results.topMatch?.meta.id;
    final films = [
      for (final m in results.grid)
        if (m.id != topId) m,
    ];

    return ListView(
      key: const ValueKey('searchResults'),
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
      children: [
        if (results.topMatch != null) _TopMatchCard(topMatch: results.topMatch!),
        if (films.isNotEmpty) ...[
          const SectionHeader('Results'),
          _PosterGrid(items: films),
        ],
        if (results.anime.isNotEmpty) ...[
          const SectionHeader('Anime'),
          _PosterGrid(items: [for (final a in results.anime) a.meta]),
        ],
      ],
    );
  }
}

/// The shared Home [PosterCard] (press-scale, shadow, hairline) laid out in the
/// three columns the refresh's search grid calls for.
class _PosterGrid extends StatelessWidget {
  final List<Meta> items;
  const _PosterGrid({required this.items});

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: _resultGridDelegate,
      itemCount: items.length,
      // Width null: the delegate defines the cell, the card fills it.
      itemBuilder: (context, i) => PosterCard(meta: items[i], width: null),
    );
  }
}

/// The pinned top match (prototype `.topmatch`): a glass card — fill + hairline,
/// never blurred (ADR-0010) — with the accent kicker, the poster, the honest
/// facts line and the Details affordance. The artwork row and the button both
/// open the shared Detail page.
class _TopMatchCard extends ConsumerWidget {
  final TopMatch topMatch;
  const _TopMatchCard({required this.topMatch});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = AppTokens.of(context);
    final text = Theme.of(context).textTheme;
    final meta = topMatch.meta;

    void openDetail() {
      ref.read(homeControllerProvider.notifier).openDetail(meta);
      Navigator.of(context).pushNamed(AppRoutes.detail);
    }

    // Only the facts that exist render (parent #80 honesty rule).
    final facts = [
      if (meta.releaseInfo != null && meta.releaseInfo!.isNotEmpty)
        meta.releaseInfo!,
      topMatch.kind == 'series' ? 'Series' : 'Film',
      if (topMatch.voteAverage != null)
        '★ ${topMatch.voteAverage!.toStringAsFixed(1)}',
    ].join(' · ');

    return GlassSurface(
      radius: tokens.radius,
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.info_outline, size: 15, color: tokens.accent),
              const SizedBox(width: 6),
              Text(
                'TOP MATCH',
                style: tokens.sectionLabel.copyWith(color: tokens.accent),
              ),
            ],
          ),
          const SizedBox(height: 14),
          PressScale(
            onTap: openDetail,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(tokens.radiusSmall),
                  child: Container(
                    // The hairline rides above the art, not behind it.
                    foregroundDecoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(tokens.radiusSmall),
                      border: Border.all(color: tokens.hair),
                    ),
                    child: SizedBox(
                      width: 96,
                      height: 144,
                      child: PosterImage(url: meta.poster),
                    ),
                  ),
                ),
                const SizedBox(width: 15),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        meta.name,
                        style: text.titleMedium?.copyWith(
                          fontSize: 15,
                          height: 1.25,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        facts,
                        style: text.bodySmall?.copyWith(
                          // The facts line reads over the card's glass fill;
                          // the AA ink step keeps it legible (issue #91).
                          color: tokens.inkMuted,
                          letterSpacing: 0.2,
                        ),
                      ),
                      if (topMatch.overview != null &&
                          topMatch.overview!.isNotEmpty) ...[
                        const SizedBox(height: 9),
                        Text(
                          topMatch.overview!,
                          maxLines: 4,
                          overflow: TextOverflow.ellipsis,
                          style: text.bodySmall?.copyWith(
                            color: tokens.inkMuted,
                            height: 1.65,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
            icon: const Icon(Icons.info_outline, size: 18),
            label: const Text('Details'),
            onPressed: openDetail,
          ),
        ],
      ),
    );
  }
}

/// The loading state (ticket 88): placeholders in the final shape — the
/// top-match card and the Results grid — so the layout never jumps when data
/// lands. Static by design: the refresh adds no animation beyond the shared
/// card press-scale.
class _SearchSkeleton extends StatelessWidget {
  const _SearchSkeleton();

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    return ListView(
      key: const ValueKey('searchSkeleton'),
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
      children: [
        GlassSurface(
          key: const ValueKey('topMatchSkeleton'),
          radius: tokens.radius,
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _SkeletonBox(width: 104, height: 16),
              const SizedBox(height: 14),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const _SkeletonBox(width: 96, height: 144),
                  const SizedBox(width: 15),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: const [
                        _SkeletonBox(height: 16, widthFactor: 0.7),
                        SizedBox(height: 9),
                        _SkeletonBox(height: 11, widthFactor: 0.4),
                        SizedBox(height: 14),
                        _SkeletonBox(height: 11, widthFactor: 1),
                        SizedBox(height: 6),
                        _SkeletonBox(height: 11, widthFactor: 0.92),
                        SizedBox(height: 6),
                        _SkeletonBox(height: 11, widthFactor: 0.6),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              const _SkeletonBox(width: 104, height: 38),
            ],
          ),
        ),
        const SectionHeader('Results'),
        GridView.builder(
          key: const ValueKey('resultsSkeleton'),
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: _resultGridDelegate,
          itemCount: 6,
          itemBuilder: (context, _) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: const [
              AspectRatio(aspectRatio: 2 / 3, child: _SkeletonBox()),
              SizedBox(height: 7),
              _SkeletonBox(height: 10, widthFactor: 0.8),
            ],
          ),
        ),
      ],
    );
  }
}

/// A translucent placeholder block — fill + hairline, the same vocabulary as
/// the Home rail skeletons.
class _SkeletonBox extends StatelessWidget {
  final double? width;
  final double? height;
  final double? widthFactor;

  const _SkeletonBox({this.width, this.height, this.widthFactor});

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    Widget box = DecoratedBox(
      decoration: BoxDecoration(
        color: tokens.glassFill,
        borderRadius: BorderRadius.circular(tokens.radiusSmall),
        border: Border.all(color: tokens.hair),
      ),
    );
    if (width != null || height != null) {
      box = SizedBox(width: width, height: height, child: box);
    }
    if (widthFactor != null) {
      box = FractionallySizedBox(widthFactor: widthFactor!, child: box);
    }
    return box;
  }
}
