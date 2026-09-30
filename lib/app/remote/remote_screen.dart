// Remote tab (ticket 07; cover-forward header #85, revised in the device
// pass): the now-playing Poster shown sharp, the five-button transport, and
// every secondary control below the fold.
//
// The header shows the cover itself — the snapshot has no Backdrop, and the
// first cut's blurred 2:3 Poster read as a washed-out smear on device. Below
// the poster come the title/ficha and the five-button transport
// `[prev] [-30] [play] [+30] [next]` — the transport is disabled without held
// media and the skip works while paused. Everything else (volume, subtitles,
// destination, Navigate — still collapsed by default — and text entry) lives
// below the first fold.
//
// Renders the pure reducer's view. Everything host-authoritative: the controls
// read their state from the latest snapshot (via `nowPlaying`) and the reducer
// sends host wire commands — the phone never optimistically flips a toggle.
// Progress comes straight from `positionSec` (never interpolated).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../home/poster_image.dart';
import '../settings/settings_controller.dart';
import '../theme.dart';
import '../ui/glass_surface.dart';
import '../ui/playback_position_line.dart' show formatPlaybackTime;
import '../ws/client_reducer.dart' show CastDevice, TextEntry;
import 'remote_controller.dart';
import 'remote_reducer.dart';

/// The now-playing cover width. The poster is 2:3, so the height follows.
const double kRemotePosterWidth = 176;

class RemoteScreen extends ConsumerStatefulWidget {
  const RemoteScreen({super.key});

  @override
  ConsumerState<RemoteScreen> createState() => _RemoteScreenState();
}

class _RemoteScreenState extends ConsumerState<RemoteScreen> {
  double? _seekDrag;
  final TextEditingController _textController = TextEditingController();
  final FocusNode _textFocusNode = FocusNode();
  TextEntry? _lastTextEntry;

  @override
  void dispose() {
    _textController.dispose();
    _textFocusNode.dispose();
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
    final showPlaybackLocation = ref.watch(
        settingsControllerProvider.select((s) => s.showPlaybackLocation));
    final textEntry =
        ref.watch(remoteControllerProvider.select((s) => s.textEntry));
    if (_lastTextEntry == null && textEntry != null) {
      _lastTextEntry = textEntry;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _textFocusNode.requestFocus();
      });
    } else {
      _lastTextEntry = textEntry;
    }

    final awaiting = phase == RemotePhase.awaitingStart;
    return ListView(
      key: const ValueKey('remoteList'),
      // Zero padding: the Cinemascope band bleeds edge to edge; every other
      // block carries its own inset.
      padding: EdgeInsets.zero,
      children: [
        if (!connected)
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: _DisconnectedBanner(),
          ),
        switch (phase) {
          RemotePhase.awaitingStart => Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: _AwaitingCard(title: awaitingTitle),
            ),
          RemotePhase.idle => Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: _IdleCard(error: lastError),
            ),
          RemotePhase.nowPlaying => _NowPlayingHeader(
              nowPlaying: nowPlaying,
              connected: connected,
              seekDrag: _seekDrag,
              onSeekChanged: (v) => setState(() => _seekDrag = v),
              onSeekCommit: (v) {
                ref.read(remoteControllerProvider.notifier).seek(v);
                setState(() => _seekDrag = null);
              },
            ),
        },
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // With held media the transport lives in the band. Without it —
              // or while awaiting a start — the row stays visible but disabled.
              if (nowPlaying == null && !awaiting) ...[
                _TransportRow(nowPlaying: null, enabled: connected),
                const SizedBox(height: 16),
              ],
              if (!awaiting) ...[
                _VolumeRow(nowPlaying: nowPlaying, enabled: connected),
                if (nowPlaying?.canToggleSubtitles == true)
                  Center(
                    child: TextButton.icon(
                      icon: Icon(nowPlaying!.subtitlesOn
                          ? Icons.subtitles
                          : Icons.subtitles_off),
                      label: Text(nowPlaying.subtitlesOn
                          ? 'Subtitles on'
                          : 'Subtitles off'),
                      onPressed: connected
                          ? () => ref
                              .read(remoteControllerProvider.notifier)
                              .toggleSubtitles()
                          : null,
                    ),
                  ),
                if (showPlaybackLocation) ...[
                  const SizedBox(height: 16),
                  _CastSection(enabled: connected),
                ],
              ],
              const SizedBox(height: 16),
              _NavSection(enabled: connected),
              const SizedBox(height: 16),
              _TextSection(
                enabled: connected,
                textController: _textController,
                focusNode: _textFocusNode,
              ),
            ],
          ),
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

/// The now-playing header (issue #85, revised): the sharp Poster on an
/// elevated surface, with the kicker, serif title, ficha, seek slider + times
/// and the five-button transport below it. No blur anywhere — the cover is the
/// hero, and the earlier blurred fill was dropped after the device pass.
class _NowPlayingHeader extends StatelessWidget {
  final NowPlaying? nowPlaying;
  final bool connected;
  final double? seekDrag;
  final ValueChanged<double> onSeekChanged;
  final ValueChanged<double> onSeekCommit;

  const _NowPlayingHeader({
    required this.nowPlaying,
    required this.connected,
    required this.seekDrag,
    required this.onSeekChanged,
    required this.onSeekCommit,
  });

  @override
  Widget build(BuildContext context) {
    final np = nowPlaying;
    if (np == null) return const SizedBox.shrink();
    final tokens = AppTokens.of(context);
    final text = Theme.of(context).textTheme;

    final duration = np.durationSec;
    final position = (seekDrag ?? np.positionSec)
        .clamp(0.0, duration <= 0 ? double.infinity : duration);
    final ficha = [np.episodeLine, np.sourceLine]
        .whereType<String>()
        .where((line) => line.isNotEmpty)
        .join('  ·  ');

    return Column(
      key: const ValueKey('remoteBand'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          color: tokens.bgElev,
          padding: const EdgeInsets.fromLTRB(22, 20, 22, 4),
          child: Center(
            child: Container(
              key: const ValueKey('remotePoster'),
              width: kRemotePosterWidth,
              height: kRemotePosterWidth * 3 / 2,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(tokens.radiusSmall),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.45),
                    blurRadius: 24,
                    offset: const Offset(0, 12),
                  ),
                ],
              ),
              foregroundDecoration: BoxDecoration(
                borderRadius: BorderRadius.circular(tokens.radiusSmall),
                border: Border.all(color: tokens.hair),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(tokens.radiusSmall),
                child: PosterImage(url: np.posterUrl),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(22, 18, 22, 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'NOW PLAYING',
                style: tokens.sectionLabel.copyWith(color: tokens.accentInk),
              ),
              const SizedBox(height: 8),
              Text(
                np.mediaTitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: tokens.serifTitle,
              ),
              if (ficha.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  ficha,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodySmall?.copyWith(color: tokens.inkMuted),
                ),
              ],
              const SizedBox(height: 10),
              Row(
                children: [
                  Icon(
                    np.target.isCasting ? Icons.cast : Icons.desktop_windows,
                    size: 16,
                    color: tokens.inkFaint,
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      np.target.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodySmall?.copyWith(color: tokens.inkFaint),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Slider(
                value: position.toDouble(),
                max: duration <= 0 ? 1 : duration,
                onChanged: duration <= 0 ? null : onSeekChanged,
                onChangeEnd: duration <= 0 ? null : onSeekCommit,
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    formatPlaybackTime(position),
                    style: text.bodySmall?.copyWith(color: tokens.inkMuted),
                  ),
                  Text(
                    formatPlaybackTime(duration),
                    style: text.bodySmall?.copyWith(color: tokens.inkMuted),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              _TransportRow(nowPlaying: np, enabled: connected),
            ],
          ),
        ),
      ],
    );
  }
}

/// The five-button transport `[prev] [-30] [play] [+30] [next]` (ADR-0011).
///
/// Every button is disabled without held media. Play follows the snapshot's
/// playing flag; prev/next additionally require the host to report a
/// neighbouring episode (kept from ticket 07), and the ±30 skips only need
/// held media — they work while paused (the reducer clamps the seek).
class _TransportRow extends ConsumerWidget {
  final NowPlaying? nowPlaying;
  final bool enabled;
  const _TransportRow({required this.nowPlaying, required this.enabled});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final np = nowPlaying;
    final ctrl = ref.read(remoteControllerProvider.notifier);
    final tokens = AppTokens.of(context);
    final playing = np?.playing ?? false;
    final mediaHeld = enabled && np != null;

    Widget side(IconData icon, String tooltip, VoidCallback? onPressed) {
      return IconButton(
        iconSize: 26,
        icon: Icon(icon),
        tooltip: tooltip,
        onPressed: onPressed,
        style: IconButton.styleFrom(
          foregroundColor: tokens.inkMuted,
          disabledForegroundColor: tokens.inkFaint,
          side: BorderSide(color: tokens.hair),
          shape: const CircleBorder(),
          fixedSize: const Size(48, 48),
        ),
      );
    }

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        side(
          Icons.skip_previous,
          'Previous episode',
          (mediaHeld && np.hasPrevEpisode) ? ctrl.prevEpisode : null,
        ),
        side(
          Icons.replay_30,
          'Back 30 seconds',
          mediaHeld ? () => ctrl.skipBy(-30) : null,
        ),
        IconButton.filled(
          iconSize: 34,
          icon: Icon(playing ? Icons.pause : Icons.play_arrow),
          tooltip: playing ? 'Pause' : 'Play',
          onPressed: mediaHeld ? ctrl.togglePlay : null,
          style: IconButton.styleFrom(
            fixedSize: const Size(70, 70),
            backgroundColor: tokens.accent,
            foregroundColor: tokens.onAccent,
            disabledBackgroundColor: tokens.glassFill,
            disabledForegroundColor: tokens.inkFaint,
          ),
        ),
        side(
          Icons.forward_30,
          'Forward 30 seconds',
          mediaHeld ? () => ctrl.skipBy(30) : null,
        ),
        side(
          Icons.skip_next,
          'Next episode',
          (mediaHeld && np.hasNextEpisode) ? ctrl.nextEpisode : null,
        ),
      ],
    );
  }
}

/// Volume slider + mute, below the fold (issue #85). The slider keeps sending
/// the host-authoritative `setVolume` on every drag tick, as before.
class _VolumeRow extends ConsumerWidget {
  final NowPlaying? nowPlaying;
  final bool enabled;
  const _VolumeRow({required this.nowPlaying, required this.enabled});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final np = nowPlaying;
    final ctrl = ref.read(remoteControllerProvider.notifier);
    final tokens = AppTokens.of(context);
    final muted = np?.muted ?? false;

    return Row(
      children: [
        Icon(
          muted ? Icons.volume_off : Icons.volume_up,
          color: tokens.inkFaint,
        ),
        Expanded(
          child: Slider(
            value: (np?.volume ?? 1).clamp(0.0, 1.0),
            onChanged:
                (enabled && np != null) ? (v) => ctrl.setVolume(v) : null,
          ),
        ),
        IconButton(
          icon: Icon(muted ? Icons.volume_off : Icons.volume_up),
          tooltip: muted ? 'Unmute' : 'Mute',
          onPressed: enabled && np != null ? ctrl.toggleMute : null,
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

    return GlassSurface(
      // A translucent fill + hairline (ADR-0010 — cards never blur); clipped
      // so the ExpansionTile's ink stays inside the rounded corners.
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppTokens.of(context).radius),
        child: ExpansionTile(
          // Local view state only (ticket 39): collapsed by default, header
          // always toggles so the d-pad is reachable even while disconnected.
          initiallyExpanded: false,
          shape: const Border(),
          collapsedShape: const Border(),
          title:
              Text('Navigate', style: Theme.of(context).textTheme.titleSmall),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                children: [
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
          ],
        ),
      ),
    );
  }
}

class _TextSection extends ConsumerWidget {
  final bool enabled;
  final TextEditingController textController;
  final FocusNode focusNode;
  const _TextSection({
    required this.enabled,
    required this.textController,
    required this.focusNode,
  });

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

    return GlassSurface(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          TextField(
            controller: textController,
            focusNode: focusNode,
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
    );
  }
}
