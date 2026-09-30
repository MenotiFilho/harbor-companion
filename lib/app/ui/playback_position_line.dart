import 'package:flutter/material.dart';

import '../theme.dart';
import 'progress_bar.dart';

/// The mini-player's Playback position line: a thin [ProgressBar] with the
/// elapsed / total time. Renders nothing without position data (the honesty
/// rule) — a 0s position with an unknown duration is not a progress state.
///
/// The fill and the text both come straight from the snapshot's Playback
/// position; nothing is interpolated locally.
class PlaybackPositionLine extends StatelessWidget {
  const PlaybackPositionLine({
    super.key,
    required this.positionSec,
    required this.durationSec,
  });

  final double positionSec;

  /// Total media duration; `<= 0` means unknown — no bar is shown.
  final double durationSec;

  @override
  Widget build(BuildContext context) {
    final hasDuration = durationSec > 0;
    if (!hasDuration && positionSec <= 0) return const SizedBox.shrink();

    final tokens = AppTokens.of(context);
    final style = Theme.of(context).textTheme.labelSmall?.copyWith(
      color: tokens.inkMuted,
      letterSpacing: 0.4,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final label = hasDuration
        ? '${formatPlaybackTime(positionSec)} / ${formatPlaybackTime(durationSec)}'
        : formatPlaybackTime(positionSec);

    return Padding(
      padding: const EdgeInsets.only(top: 5),
      child: Row(
        children: [
          if (hasDuration) ...[
            Expanded(child: ProgressBar(value: positionSec / durationSec)),
            const SizedBox(width: 10),
          ],
          Text(label, maxLines: 1, style: style),
        ],
      ),
    );
  }
}

/// `mm:ss`, or `h:mm:ss` past an hour, with tabular-friendly zero padding.
/// Shared by the mini-player and the Remote screen's playback-location row.
String formatPlaybackTime(double sec) {
  final s = sec.round();
  final h = s ~/ 3600;
  final m = (s % 3600) ~/ 60;
  final r = s % 60;
  final mm = m.toString().padLeft(2, '0');
  final rr = r.toString().padLeft(2, '0');
  return h > 0 ? '$h:$mm:$rr' : '$mm:$rr';
}
