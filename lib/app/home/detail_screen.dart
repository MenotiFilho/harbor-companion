// Detail page (ticket 04): meta with seasons/episodes and a play button.
//
// Reads the reducer's `detail` state — seasons/episodes come from Cinemeta
// `videos[]` (keyless) or TMDB season episodes (keyed), fetched by the
// controller. The play button (and each episode) sends `playMeta`, so playback
// always runs on the host (wire-contract §4).

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
        DetailStatus.loading => const Center(child: CircularProgressIndicator()),
        DetailStatus.failed => Center(child: Text(detail!.error ?? 'Could not load detail')),
        DetailStatus.ready => _DetailBody(detail: detail!.detail!, meta: detail.meta),
      },
    );
  }
}

class _DetailBody extends ConsumerWidget {
  final DetailMeta detail;
  final Meta meta;
  const _DetailBody({required this.detail, required this.meta});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final ctrl = ref.read(homeControllerProvider.notifier);

    final first = detail.firstEpisode;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _poster(),
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
        ),
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
          Text('Episodes', style: text.titleMedium),
          for (final season in detail.seasons) _SeasonSection(season: season, meta: meta),
        ],
      ],
    );
  }

  Widget _poster() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: 110,
        height: 164,
        child: PosterImage(url: meta.poster),
      ),
    );
  }
}

class _SeasonSection extends ConsumerWidget {
  final Season season;
  final Meta meta;
  const _SeasonSection({required this.season, required this.meta});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final ctrl = ref.read(homeControllerProvider.notifier);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 12, bottom: 4),
          child: Text(season.name, style: text.titleSmall?.copyWith(color: scheme.primary)),
        ),
        for (final episode in season.episodes)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.play_circle_outline),
            title: Text(
              '${episode.episode}. ${episode.name}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: () =>
                ctrl.playMeta(meta, season: episode.season, episode: episode.episode),
          ),
      ],
    );
  }
}
