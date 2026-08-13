// Detail page (ticket 04): meta with seasons/episodes and a play button.
//
// Reads the reducer's `detail` state — seasons/episodes come from Cinemeta
// `videos[]` (keyless) or TMDB season episodes (keyed), fetched by the
// controller. The play button (and each episode) sends `playMeta`, so playback
// always runs on the host (wire-contract §4).
//
// The header (poster + name + description) renders from the already-available
// `meta` the moment the page opens, so a slow season/episode fetch no longer
// blanks the page — a spinner holds only the episode area while `loading`.
// Series render their non-empty seasons as a scrollable season selector (one
// tab per season, first selected), not a flat list of every episode.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'home_controller.dart';
import 'home_reducer.dart';
import 'meta.dart';
import 'poster_image.dart';

class DetailScreen extends ConsumerWidget {
  const DetailScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(homeControllerProvider).detail;

    return Scaffold(
      appBar: AppBar(title: Text(detail?.meta.name ?? 'Detail')),
      body: switch (detail?.status) {
        null => const Center(child: Text('No title selected')),
        DetailStatus.loading => _DetailLoading(meta: detail!.meta),
        DetailStatus.failed => Center(child: Text(detail!.error ?? 'Could not load detail')),
        DetailStatus.ready => _DetailBody(detail: detail!.detail!, meta: detail.meta),
      },
    );
  }
}

/// Header + a spinner where the episodes will land, shown while the season/
/// episode fetch is still in flight.
class _DetailLoading extends StatelessWidget {
  final Meta meta;
  const _DetailLoading({required this.meta});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _DetailHeader(meta: meta),
        if (meta.isSeries) ...[
          const SizedBox(height: 32),
          const Center(child: CircularProgressIndicator()),
        ],
      ],
    );
  }
}

class _DetailBody extends ConsumerWidget {
  final DetailMeta detail;
  final Meta meta;
  const _DetailBody({required this.detail, required this.meta});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ctrl = ref.read(homeControllerProvider.notifier);
    final first = detail.firstEpisode;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _DetailHeader(meta: meta),
        const SizedBox(height: 16),
        FilledButton.icon(
          icon: const Icon(Icons.play_arrow),
          label: Text(meta.isSeries ? 'Play first episode' : 'Play'),
          // A series whose seasons are still empty (episodes failed to load)
          // has no playable first episode — keep the button honest.
          onPressed: meta.isSeries && first == null
              ? null
              : () {
                  final firstEpisode = first;
                  if (meta.isSeries && firstEpisode != null) {
                    ctrl.playMeta(meta, season: firstEpisode.$1, episode: firstEpisode.$2);
                  } else {
                    ctrl.playMeta(meta);
                  }
                },
        ),
        if (meta.isSeries) ...[
          const SizedBox(height: 24),
          _SeasonTabs(detail: detail, meta: meta),
        ],
      ],
    );
  }
}

/// The poster + title + release/description block, shared by the loading and
/// ready states so it appears immediately.
class _DetailHeader extends StatelessWidget {
  final Meta meta;
  const _DetailHeader({required this.meta});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(
            width: 110,
            height: 164,
            child: PosterImage(url: meta.poster),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(meta.name, style: text.headlineSmall),
              if (meta.releaseInfo != null) ...[
                const SizedBox(height: 4),
                Text(meta.releaseInfo!, style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
              ],
              if (meta.description != null && meta.description!.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(meta.description!, maxLines: 6, overflow: TextOverflow.ellipsis),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// A scrollable season selector plus the selected season's episode list. Holds
/// the selected season as local UI state — it never travels to the host, so it
/// stays out of the reducer.
class _SeasonTabs extends ConsumerStatefulWidget {
  final DetailMeta detail;
  final Meta meta;
  const _SeasonTabs({required this.detail, required this.meta});

  @override
  ConsumerState<_SeasonTabs> createState() => _SeasonTabsState();
}

class _SeasonTabsState extends ConsumerState<_SeasonTabs> {
  int _index = 0;

  /// Non-empty seasons only — a tab that opens to "nothing here" is noise.
  List<Season> get _seasons => [
        for (final season in widget.detail.seasons)
          if (season.episodes.isNotEmpty) season,
      ];

  @override
  void didUpdateWidget(covariant _SeasonTabs oldWidget) {
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
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (var i = 0; i < seasons.length; i++)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(seasons[i].name),
                    selected: i == _index,
                    onSelected: (_) => setState(() => _index = i),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        for (final episode in selected.episodes)
          _EpisodeTile(
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

class _EpisodeTile extends StatelessWidget {
  final Episode episode;
  final VoidCallback onTap;
  const _EpisodeTile({required this.episode, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.play_circle_outline),
      title: Text(
        '${episode.episode}. ${episode.name}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      onTap: onTap,
    );
  }
}
