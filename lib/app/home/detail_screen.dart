// Detail page (ticket 04; editorial refresh in ticket 84).
//
// Reads the reducer's `detail` state — seasons/episodes come from Cinemeta
// `videos[]` (keyless) or TMDB season episodes (keyed), fetched by the
// controller. The play button (and each episode) sends `playMeta`, so playback
// always runs on the host (wire-contract §4).
//
// The header is the editorial Hero (issue #83's band, reused): a full-bleed
// Backdrop with the bottom-up scrim, the name and ficha over the art, then the
// Poster + synopsis + meta row just below. It renders from the `Meta` the
// moment the page opens — `DetailStatus.loading` carries it — so a slow
// season/episode fetch never blanks the page; only the Episodes section waits.
//
// A series renders its non-empty seasons as a discreet segmented control (a
// translucent fill + hairline, ADR-0010 — never blurred), and each episode as
// a row with still, number, duration (only when the source reports one) and
// overview. The selected season is local UI state — it never travels to the
// host, so it stays out of the reducer.
//
// The Cast (ticket #86) and Similar (ticket #87) sections come from the detail
// extras fetcher on their own providers (ADR-0012): each settles independently —
// a slow or failed extras fetch never delays the header or the episodes — and
// renders only with data. Similar reuses the Home's poster card, so tapping one
// runs the same `openDetail` + Detail route flow the Home uses.
//
// Honesty rule (parent #80): no affordances without data or action — no
// "My list", no "Download", no watched marker.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../shell/player_bar.dart';
import '../theme.dart';
import '../ui/hairline.dart';
import '../ui/hero_band.dart';
import '../ui/press_scale.dart';
import '../ui/section_header.dart';
import 'detail_extras_fetcher.dart';
import 'home_controller.dart';
import 'home_reducer.dart';
import 'home_screen.dart';
import 'meta.dart';
import 'poster_image.dart';

/// The detail Hero band's editorial height (prototype `.band` 306px).
const double kDetailHeroHeight = 306;

/// The poster geometry just below the band (prototype `.poster-sm` 98×147).
const double kDetailPosterWidth = 98;
const double kDetailPosterHeight = 147;

/// The Similar rail's fixed height: exactly one shared [PosterCard] tall — the
/// Home rail's row extent without its header — so the horizontal list keeps a
/// stable extent.
const double kSimilarRailHeight = kRowExtent - kRailHeaderExtent;

class DetailScreen extends ConsumerWidget {
  const DetailScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(homeControllerProvider).detail;

    return Scaffold(
      appBar: AppBar(title: Text(detail?.meta.name ?? 'Detail')),
      body: switch (detail?.status) {
        null => const Center(child: Text('No title selected')),
        DetailStatus.loading => _DetailBody(meta: detail!.meta),
        DetailStatus.failed => _DetailBody(meta: detail!.meta, error: detail.error),
        DetailStatus.ready => _DetailBody(meta: detail!.meta, detail: detail.detail),
      },
      bottomNavigationBar: const PlayerBar(),
    );
  }
}

/// The whole page body: the Hero header (always, from [meta]) followed by the
/// poster/synopsis/CTA block and the Episodes section, which holds a spinner
/// while [detail] is still in flight and the failure line when [error] is set.
class _DetailBody extends ConsumerWidget {
  final Meta meta;

  /// The resolved detail; null while the fetch is in flight (or failed).
  final DetailMeta? detail;

  /// The season/episode fetch failure, rendered in place of the Episodes
  /// section. The header and the play CTA still render.
  final String? error;

  const _DetailBody({required this.meta, this.detail, this.error});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ctrl = ref.read(homeControllerProvider.notifier);
    final first = detail?.firstEpisode;
    final seasons = _seasonsWithEpisodes(detail);

    return CustomScrollView(
      key: const ValueKey('detailList'),
      slivers: [
        SliverToBoxAdapter(
          child: HeroBand(
            key: const ValueKey('detailHero'),
            height: kDetailHeroHeight,
            backdropUrl: meta.background,
            posterUrl: meta.poster,
            kicker: meta.isSeries ? 'Series' : 'Film',
            title: meta.name,
            meta: meta.releaseInfo,
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(22, 18, 22, 30),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (seasons.isNotEmpty) _SeasonsLine(seasons: seasons),
                _PosterSynopsis(meta: meta),
                const SizedBox(height: 18),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    // Full-width and a >= 48dp target (parent #80 a11y).
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                    ),
                    icon: const Icon(Icons.play_arrow),
                    label: Text(meta.isSeries ? 'Play first episode' : 'Play'),
                    // A series whose seasons are still empty (episodes failed
                    // to load) has no playable first episode — keep the button
                    // honest.
                    onPressed: meta.isSeries && first == null
                        ? null
                        : () {
                            final firstEpisode = first;
                            if (meta.isSeries && firstEpisode != null) {
                              ctrl.playMeta(
                                meta,
                                season: firstEpisode.$1,
                                episode: firstEpisode.$2,
                              );
                            } else {
                              ctrl.playMeta(meta);
                            }
                          },
                  ),
                ),
                // The Cast and Similar sections load on their own providers
                // and render only when they have data, so neither ever delays
                // or hides the rest of the page (ADR-0012).
                CastSection(meta: meta),
                SimilarSection(meta: meta),
                if (error != null) ...[
                  const SizedBox(height: 24),
                  _DetailError(message: error!),
                ] else if (meta.isSeries) ...[
                  if (detail == null) ...[
                    const SectionHeader('Episodes'),
                    const Center(
                      child: Padding(
                        padding: EdgeInsets.symmetric(vertical: 28),
                        child: CircularProgressIndicator(),
                      ),
                    ),
                  ] else if (seasons.isNotEmpty) ...[
                    const SectionHeader('Episodes'),
                    _SeasonSection(detail: detail!, meta: meta),
                  ],
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// The seasons that have episodes — the only ones the selector and the count
/// line show. A season whose fetch failed stays invisible rather than opening
/// to "nothing here".
List<Season> _seasonsWithEpisodes(DetailMeta? detail) => [
      for (final season in detail?.seasons ?? const <Season>[])
        if (season.episodes.isNotEmpty) season,
    ];

/// The meta row just below the band: the honest facts the detail fetch adds —
/// season and episode counts. Empty (and omitted) while the detail is loading
/// or when there is nothing to count.
class _SeasonsLine extends StatelessWidget {
  final List<Season> seasons;
  const _SeasonsLine({required this.seasons});

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final episodes =
        seasons.fold<int>(0, (count, season) => count + season.episodes.length);
    final seasonLabel = seasons.length == 1 ? 'season' : 'seasons';
    final episodeLabel = episodes == 1 ? 'episode' : 'episodes';
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Text(
        '${seasons.length} $seasonLabel · $episodes $episodeLabel',
        style: Theme.of(context)
            .textTheme
            .bodySmall
            ?.copyWith(color: tokens.inkMuted, letterSpacing: 0.2),
      ),
    );
  }
}

/// The Poster and the synopsis, side by side just below the band. Renders
/// whichever half has data; renders nothing when both are absent.
class _PosterSynopsis extends StatelessWidget {
  final Meta meta;
  const _PosterSynopsis({required this.meta});

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final poster = meta.poster;
    final hasPoster = poster != null && poster.isNotEmpty;
    final synopsis = meta.description;
    final hasSynopsis = synopsis != null && synopsis.isNotEmpty;
    if (!hasPoster && !hasSynopsis) return const SizedBox.shrink();

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (hasPoster) ...[
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: SizedBox(
              width: kDetailPosterWidth,
              height: kDetailPosterHeight,
              child: PosterImage(url: poster),
            ),
          ),
          const SizedBox(width: 16),
        ],
        if (hasSynopsis)
          Expanded(
            child: Text(
              synopsis,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: tokens.inkMuted, height: 1.6),
            ),
          ),
      ],
    );
  }
}

/// The Cast rail (ticket #86): profile circles with the actor and the character.
/// Watches its own provider (ADR-0012), so it appears whenever its fetch
/// resolves — a slow cast never blocks the header or the episodes — and renders
/// nothing while loading, on failure, without a TMDB key or without a match:
/// no section without data, never a placeholder.
class CastSection extends ConsumerWidget {
  final Meta meta;
  const CastSection({super.key, required this.meta});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final members =
        ref.watch(castProvider((type: meta.type, id: meta.id))).value ??
            const <CastMember>[];
    if (members.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader('Cast'),
        SizedBox(
          height: 116,
          child: ListView.separated(
            key: const ValueKey('castRail'),
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.zero,
            itemCount: members.length,
            separatorBuilder: (_, _) => const SizedBox(width: 14),
            itemBuilder: (context, index) => _CastCircle(member: members[index]),
          ),
        ),
      ],
    );
  }
}

/// One cast circle: the avatar, the actor's name and the character. The avatar
/// falls back to a static gradient when the source has no profile image or the
/// image fails — the same honest fallback the posters use.
class _CastCircle extends StatelessWidget {
  final CastMember member;
  const _CastCircle({required this.member});

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final profile = member.profile;
    final character = member.character;
    return SizedBox(
      width: 64,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 56,
            height: 56,
            padding: const EdgeInsets.all(1),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: tokens.hair),
            ),
            child: ClipOval(
              child: profile == null || profile.isEmpty
                  ? const _CastFallback()
                  : Image.network(
                      profile,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => const _CastFallback(),
                    ),
            ),
          ),
          const SizedBox(height: 7),
          Text(
            member.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 10.5,
              height: 1.3,
              color: tokens.inkMuted,
            ),
          ),
          if (character != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                character,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 9.5,
                  height: 1.3,
                  color: tokens.inkFaint,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The avatar's no-image fallback: the prototype's static dark gradient.
class _CastFallback extends StatelessWidget {
  const _CastFallback();

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [tokens.solidHigh, tokens.bg],
        ),
      ),
    );
  }
}

/// The Similar rail (ticket #87): TMDB recommendations as the shared Home
/// poster cards. Watches its own provider (ADR-0012), like the cast — a slow or
/// failed recommendations request never delays the header, cast or episodes —
/// and renders nothing while loading, on failure, without a TMDB key or
/// without a match: no section without data, never a placeholder. Tapping a
/// card opens the recommended title's Detail through the same `openDetail` +
/// route flow the Home's cards use ([PosterCard]).
class SimilarSection extends ConsumerWidget {
  final Meta meta;
  const SimilarSection({super.key, required this.meta});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref
            .watch(similarProvider((type: meta.type, id: meta.id)))
            .value ??
        const <Meta>[];
    if (items.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader('Similar'),
        SizedBox(
          height: kSimilarRailHeight,
          child: ListView.separated(
            key: const ValueKey('similarRail'),
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.zero,
            itemCount: items.length,
            separatorBuilder: (_, _) => const SizedBox(width: kPosterGap),
            itemBuilder: (context, index) => PosterCard(meta: items[index]),
          ),
        ),
      ],
    );
  }
}

/// The season/episode fetch failure. No retry affordance: the reducer has no
/// detail retry today, and inventing one here would be a new action.
class _DetailError extends StatelessWidget {
  final String message;
  const _DetailError({required this.message});

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: tokens.glassFill,
        borderRadius: BorderRadius.circular(tokens.radiusSmall),
        border: Border.all(color: tokens.hair),
      ),
      child: Text(
        message,
        style: Theme.of(context)
            .textTheme
            .bodySmall
            ?.copyWith(color: tokens.inkMuted, height: 1.5),
      ),
    );
  }
}

/// The discreet season segmented control plus the selected season's episodes.
/// Holds the selected season as local UI state.
class _SeasonSection extends ConsumerStatefulWidget {
  final DetailMeta detail;
  final Meta meta;
  const _SeasonSection({required this.detail, required this.meta});

  @override
  ConsumerState<_SeasonSection> createState() => _SeasonSectionState();
}

class _SeasonSectionState extends ConsumerState<_SeasonSection> {
  int _index = 0;

  /// Non-empty seasons only — a segment that opens to "nothing here" is noise.
  List<Season> get _seasons => _seasonsWithEpisodes(widget.detail);

  @override
  void didUpdateWidget(covariant _SeasonSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A different title reuses this state — reset to the first season.
    if (widget.detail.meta.id != oldWidget.detail.meta.id) _index = 0;
  }

  @override
  Widget build(BuildContext context) {
    final seasons = _seasons;
    if (seasons.isEmpty) return const SizedBox.shrink();

    final selected = seasons[_index.clamp(0, seasons.length - 1)];
    final ctrl = ref.read(homeControllerProvider.notifier);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SeasonSegmented(
          labels: [for (final season in seasons) season.name],
          selected: _index.clamp(0, seasons.length - 1),
          onSelected: (i) => setState(() => _index = i),
        ),
        const SizedBox(height: 6),
        for (final episode in selected.episodes)
          _EpisodeRow(
            episode: episode,
            onTap: () => ctrl.playMeta(
              widget.meta,
              season: episode.season,
              episode: episode.episode,
            ),
          ),
      ],
    );
  }
}

/// The season selector: one pill of segments, selected in the Accent. A
/// translucent fill + hairline, never blurred (ADR-0010).
class _SeasonSegmented extends StatelessWidget {
  final List<String> labels;
  final int selected;
  final ValueChanged<int> onSelected;

  const _SeasonSegmented({
    required this.labels,
    required this.selected,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    return Container(
      decoration: BoxDecoration(
        color: tokens.glassFill,
        borderRadius: BorderRadius.circular(tokens.radiusSmall),
        border: Border.all(color: tokens.hair),
      ),
      padding: const EdgeInsets.all(3),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < labels.length; i++)
              Padding(
                padding: EdgeInsets.only(left: i == 0 ? 0 : 2),
                child: Semantics(
                  button: true,
                  selected: i == selected,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => onSelected(i),
                    child: ConstrainedBox(
                      // 42 + the pill's 3+3 padding keeps the segment a 48dp
                      // touch target (parent #80 accessibility).
                      constraints: const BoxConstraints(minHeight: 42),
                      child: Container(
                        alignment: Alignment.center,
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        decoration: BoxDecoration(
                          color: i == selected
                              ? tokens.accentFill
                              : Colors.transparent,
                          borderRadius:
                              BorderRadius.circular(tokens.radiusSmall - 3),
                          border: Border.all(
                            color: i == selected
                                ? tokens.accentLine
                                : Colors.transparent,
                          ),
                        ),
                        child: Text(
                          labels[i],
                          maxLines: 1,
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: i == selected
                                ? tokens.accentInk
                                : tokens.inkFaint,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// One episode row: still thumbnail, number, name, duration (only when the
/// source reports one) and overview. The whole row plays the episode.
class _EpisodeRow extends StatelessWidget {
  final Episode episode;
  final VoidCallback onTap;
  const _EpisodeRow({required this.episode, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final text = Theme.of(context).textTheme;
    final duration = episode.duration;
    final overview = episode.overview;
    // The duration leads the secondary line when present; the overview follows
    // when present. Neither is invented.
    final secondary = [
      if (duration != null) _durationLabel(duration),
      if (overview != null && overview.isNotEmpty) overview,
    ].join(' · ');

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        PressScale(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Row(
              children: [
                ClipRRect(
                  key: ValueKey('episodeStill-${episode.season}-${episode.episode}'),
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox(
                    width: 104,
                    height: 59,
                    child: PosterImage(url: episode.still),
                  ),
                ),
                const SizedBox(width: 13),
                Text(
                  episode.episode.toString().padLeft(2, '0'),
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: tokens.accent,
                    letterSpacing: 0.6,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        episode.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodyMedium?.copyWith(
                          color: tokens.ink,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (secondary.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 3),
                          child: Text(
                            secondary,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: text.bodySmall?.copyWith(
                              color: tokens.inkMuted,
                              height: 1.45,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(Icons.play_arrow, size: 20, color: tokens.inkFaint),
              ],
            ),
          ),
        ),
        const Hairline(soft: true),
      ],
    );
  }
}

/// "48 min" under an hour, "2 h 5 min" above — only rendered when the source
/// reported a duration.
String _durationLabel(Duration duration) {
  final minutes = duration.inMinutes;
  if (minutes < 60) return '$minutes min';
  final hours = minutes ~/ 60;
  final rest = minutes % 60;
  return rest == 0 ? '$hours h' : '$hours h $rest min';
}
