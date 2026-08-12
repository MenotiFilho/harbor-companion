// Remote tab (ticket 07): now-playing + transport + cast picker + d-pad + text.
//
// Renders the pure reducer's view. Everything host-authoritative: the transport
// controls read their state from the latest snapshot (via `nowPlaying`) and the
// reducer sends host wire commands — the phone never optimistically flips a
// toggle. Progress comes straight from `positionSec` (never interpolated).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../home/poster_image.dart';
import '../ws/client_reducer.dart' show CastDevice;
import 'remote_controller.dart';
import 'remote_reducer.dart';

class RemoteScreen extends ConsumerStatefulWidget {
  const RemoteScreen({super.key});

  @override
  ConsumerState<RemoteScreen> createState() => _RemoteScreenState();
}

class _RemoteScreenState extends ConsumerState<RemoteScreen> {
  double? _seekDrag;
  double? _volumeDrag;
  final TextEditingController _textController = TextEditingController();

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final phase = ref.watch(remoteControllerProvider.select((s) => s.phase));
    final nowPlaying =
        ref.watch(remoteControllerProvider.select((s) => s.nowPlaying));
    final connected =
        ref.watch(remoteControllerProvider.select((s) => s.connected));
    final lastError =
        ref.watch(remoteControllerProvider.select((s) => s.lastError));
    final awaitingTitle = ref.watch(remoteControllerProvider
        .select((s) => s.playRequest?.name ?? s.playRequest?.metaId));

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (!connected) const _DisconnectedBanner(),
        switch (phase) {
          RemotePhase.awaitingStart => _AwaitingCard(title: awaitingTitle),
          RemotePhase.idle => _IdleCard(error: lastError),
          RemotePhase.nowPlaying => _NowPlayingCard(
              nowPlaying: nowPlaying,
              seekDrag: _seekDrag,
              onSeekChanged: (v) => setState(() => _seekDrag = v),
              onSeekCommit: (v) {
                ref.read(remoteControllerProvider.notifier).seek(v);
                setState(() => _seekDrag = null);
              },
              volumeDrag: _volumeDrag,
              onVolumeChanged: (v) => setState(() => _volumeDrag = v),
              onVolumeCommit: (v) {
                ref.read(remoteControllerProvider.notifier).setVolume(v);
                setState(() => _volumeDrag = null);
              },
            ),
        },
        if (phase != RemotePhase.awaitingStart) ...[
          const SizedBox(height: 16),
          _TransportBar(nowPlaying: nowPlaying, enabled: connected),
        ],
        const SizedBox(height: 16),
        _CastSection(enabled: connected),
        const SizedBox(height: 16),
        _NavSection(enabled: connected),
        const SizedBox(height: 16),
        _TextSection(
          enabled: connected,
          textController: _textController,
        ),
      ],
    );
  }
}

class _DisconnectedBanner extends StatelessWidget {
  const _DisconnectedBanner();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(Icons.cloud_off, color: scheme.onErrorContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Not connected — commands will be rejected.',
              style: TextStyle(color: scheme.onErrorContainer),
            ),
          ),
        ],
      ),
    );
  }
}

class _AwaitingCard extends StatelessWidget {
  final String? title;
  const _AwaitingCard({required this.title});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(
              'Starting ${title ?? 'playback'} on your computer…',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'Waiting for the host to resolve streams.',
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

class _IdleCard extends StatelessWidget {
  final String? error;
  const _IdleCard({required this.error});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (error != null) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              Icon(Icons.error_outline, size: 40, color: scheme.error),
              const SizedBox(height: 12),
              Text(
                'Could not start playback',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                error!,
                textAlign: TextAlign.center,
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      );
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Icon(Icons.tv_off, size: 40, color: scheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(
              'Nothing playing',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              'Pick a title from Home or Search to play on your computer.',
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

class _NowPlayingCard extends StatelessWidget {
  final NowPlaying? nowPlaying;
  final double? seekDrag;
  final ValueChanged<double> onSeekChanged;
  final ValueChanged<double> onSeekCommit;
  final double? volumeDrag;
  final ValueChanged<double> onVolumeChanged;
  final ValueChanged<double> onVolumeCommit;

  const _NowPlayingCard({
    required this.nowPlaying,
    required this.seekDrag,
    required this.onSeekChanged,
    required this.onSeekCommit,
    required this.volumeDrag,
    required this.onVolumeChanged,
    required this.onVolumeCommit,
  });

  @override
  Widget build(BuildContext context) {
    final np = nowPlaying;
    if (np == null) return const SizedBox.shrink();
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;

    final duration = np.durationSec;
    final position = (seekDrag ?? np.positionSec).clamp(0.0, duration <= 0 ? double.infinity : duration);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox(
                    width: 88,
                    height: 132,
                    child: PosterImage(url: np.posterUrl),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        np.mediaTitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: text.titleLarge,
                      ),
                      if (np.episodeLine != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          np.episodeLine!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.bodyMedium
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ],
                      if (np.sourceLine != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          np.sourceLine!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.bodySmall?.copyWith(color: scheme.outline),
                        ),
                      ],
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Icon(
                            np.target.isCasting ? Icons.cast : Icons.desktop_windows,
                            size: 16,
                            color: scheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 4),
                          Flexible(
                            child: Text(
                              np.target.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: text.bodySmall
                                  ?.copyWith(color: scheme.onSurfaceVariant),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Slider(
              value: position.toDouble(),
              max: duration <= 0 ? 1 : duration,
              onChanged: duration <= 0 ? null : onSeekChanged,
              onChangeEnd: duration <= 0 ? null : onSeekCommit,
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(_fmt(position), style: text.bodySmall),
                Text(_fmt(duration), style: text.bodySmall),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _fmt(double sec) {
    final s = sec.round();
    final h = s ~/ 3600;
    final m = (s % 3600) ~/ 60;
    final r = s % 60;
    final mm = m.toString().padLeft(2, '0');
    final rr = r.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$rr' : '$mm:$rr';
  }
}

class _TransportBar extends ConsumerWidget {
  final NowPlaying? nowPlaying;
  final bool enabled;
  const _TransportBar({required this.nowPlaying, required this.enabled});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final np = nowPlaying;
    final ctrl = ref.read(remoteControllerProvider.notifier);
    final playing = np?.playing ?? false;
    final muted = np?.muted ?? false;

    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            IconButton(
              iconSize: 32,
              icon: const Icon(Icons.skip_previous),
              tooltip: 'Previous episode',
              onPressed:
                  (enabled && np?.hasPrevEpisode == true) ? ctrl.prevEpisode : null,
            ),
            IconButton.filled(
              iconSize: 48,
              icon: Icon(playing ? Icons.pause : Icons.play_arrow),
              tooltip: playing ? 'Pause' : 'Play',
              onPressed: enabled && np != null ? ctrl.togglePlay : null,
            ),
            IconButton(
              iconSize: 32,
              icon: const Icon(Icons.skip_next),
              tooltip: 'Next episode',
              onPressed:
                  (enabled && np?.hasNextEpisode == true) ? ctrl.nextEpisode : null,
            ),
          ],
        ),
        Row(
          children: [
            Icon(muted ? Icons.volume_off : Icons.volume_up),
            Expanded(
              child: Slider(
                value: (np?.volume ?? 1).clamp(0.0, 1.0),
                onChanged: (enabled && np != null)
                    ? (v) => ctrl.setVolume(v)
                    : null,
              ),
            ),
            IconButton(
              icon: Icon(muted ? Icons.volume_off : Icons.volume_up),
              tooltip: muted ? 'Unmute' : 'Mute',
              onPressed: enabled && np != null ? ctrl.toggleMute : null,
            ),
          ],
        ),
        if (np?.canToggleSubtitles == true)
          TextButton.icon(
            icon: Icon(np!.subtitlesOn ? Icons.subtitles : Icons.subtitles_off),
            label: Text(np.subtitlesOn ? 'Subtitles on' : 'Subtitles off'),
            onPressed: enabled ? ctrl.toggleSubtitles : null,
          ),
      ],
    );
  }
}

class _CastSection extends ConsumerWidget {
  final bool enabled;
  const _CastSection({required this.enabled});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final target = ref.watch(remoteControllerProvider.select((s) => s.target));
    final discovering = ref
        .watch(remoteControllerProvider.select((s) => s.castDiscovering));

    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        target.isCasting ? Icons.cast_connected : Icons.cast,
        color: Theme.of(context).colorScheme.primary,
      ),
      title: Text(target.isCasting ? 'Casting to ${target.label}' : target.label),
      subtitle: Text(
        discovering ? 'Discovering renderers…' : 'Renderer',
        style: Theme.of(context).textTheme.bodySmall,
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: enabled ? () => _showRendererPicker(context, ref) : null,
    );
  }

  void _showRendererPicker(BuildContext context, WidgetRef ref) {
    final ctrl = ref.read(remoteControllerProvider.notifier);
    showModalBottomSheet<void>(
      context: context,
      builder: (context) {
        return Consumer(builder: (context, ref, _) {
          final target =
              ref.watch(remoteControllerProvider.select((s) => s.target));
          final devices =
              ref.watch(remoteControllerProvider.select((s) => s.castDevices));
          final discovering = ref.watch(
              remoteControllerProvider.select((s) => s.castDiscovering));
          return SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const ListTile(
                  title: Text('Play on'),
                  dense: true,
                ),
                ListTile(
                  leading: const Icon(Icons.desktop_windows),
                  title: const Text('This PC'),
                  selected: !target.isCasting,
                  onTap: () {
                    ctrl.setTarget('local');
                    Navigator.of(context).pop();
                  },
                ),
                for (final CastDevice d in devices)
                  ListTile(
                    leading: const Icon(Icons.cast),
                    title: Text(d.name),
                    subtitle: Text(d.kind),
                    selected: target.isCasting && target.deviceId == d.id,
                    onTap: () {
                      ctrl.setTarget(d.id);
                      Navigator.of(context).pop();
                    },
                  ),
                const Divider(),
                ListTile(
                  leading: discovering
                      ? const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh),
                  title: const Text('Discover renderers'),
                  onTap: discovering ? null : ctrl.castDiscover,
                ),
                if (target.isCasting)
                  ListTile(
                    leading: const Icon(Icons.stop),
                    title: const Text('Stop casting'),
                    onTap: () {
                      ctrl.castStop();
                      Navigator.of(context).pop();
                    },
                  ),
              ],
            ),
          );
        });
      },
    );
  }
}

class _NavSection extends ConsumerWidget {
  final bool enabled;
  const _NavSection({required this.enabled});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ctrl = ref.read(remoteControllerProvider.notifier);
    Widget key(String k, IconData icon) => IconButton.filledTonal(
          icon: Icon(icon),
          onPressed: enabled ? () => ctrl.nav(k) : null,
        );

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Text('Navigate', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [key('up', Icons.keyboard_arrow_up)],
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                key('left', Icons.keyboard_arrow_left),
                const SizedBox(width: 8),
                key('select', Icons.check),
                const SizedBox(width: 8),
                key('right', Icons.keyboard_arrow_right),
              ],
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [key('down', Icons.keyboard_arrow_down)],
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                TextButton.icon(
                  icon: const Icon(Icons.search),
                  label: const Text('Open search'),
                  onPressed: enabled ? ctrl.openSearch : null,
                ),
                const SizedBox(width: 8),
                TextButton.icon(
                  icon: const Icon(Icons.arrow_back),
                  label: const Text('Back'),
                  onPressed: enabled ? () => ctrl.nav('back') : null,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _TextSection extends ConsumerWidget {
  final bool enabled;
  final TextEditingController textController;
  const _TextSection({required this.enabled, required this.textController});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final textEntry =
        ref.watch(remoteControllerProvider.select((s) => s.textEntry));
    final ctrl = ref.read(remoteControllerProvider.notifier);
    if (textEntry == null) return const SizedBox.shrink();

    // Keep the field in sync with the host's live value unless the user is
    // editing (we only overwrite when the host text changes).
    if (textController.text != textEntry.value) {
      textController.text = textEntry.value;
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            TextField(
              controller: textController,
              enabled: enabled,
              decoration: InputDecoration(
                labelText: textEntry.placeholder.isEmpty
                    ? 'Type here'
                    : textEntry.placeholder,
                border: const OutlineInputBorder(),
              ),
              onChanged: enabled ? ctrl.setText : null,
              onSubmitted: enabled ? (_) => ctrl.submitText() : null,
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: enabled ? ctrl.blurText : null,
                  child: const Text('Done'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed:
                      enabled ? () => ctrl.submitText(textController.text) : null,
                  child: const Text('Submit'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
