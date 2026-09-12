// Derived notification view for the persistent-connection service (#65).
//
// Mirrors `playerBarViewProvider` (lib/app/shell/player_bar.dart): it composes
// the playing surface from the shell connection gate plus the Remote reducer's
// already-derived `NowPlaying` (title, episode line, poster, playing,
// position/duration, prev/next). It is null — the idle host status — while
// disconnected or when nothing is held.
//
// The Remote reducer clears `nowPlaying` on its `Disconnected` event, so a
// socket drop nulls the surface at once and the notification morphs back to the
// idle/reconnecting status; it never shows a stale paused surface.
//
// The background reducer decides idle vs. playing from this view; the widget /
// platform layer never has to know the wire.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../remote/remote_controller.dart';
import '../shell/shell_controller.dart';
import '../shell/shell_reducer.dart';
import 'background_platform.dart';

/// The playing notification surface, or null when the notification is idle
/// (disconnected or nothing held). The reducer consumes it via
/// `NowPlayingChanged`.
final backgroundNotificationViewProvider =
    Provider<BackgroundMediaSurface?>((ref) {
  final connected =
      ref.watch(connectionStatusProvider) == ConnectionStatus.connected;
  if (!connected) return null;

  final data = ref.watch(
    remoteControllerProvider.select(
      (s) => (
        held: s.nowPlaying != null,
        title: s.nowPlaying?.mediaTitle ?? '',
        episodeLine: s.nowPlaying?.episodeLine,
        posterUrl: s.nowPlaying?.posterUrl,
        playing: s.nowPlaying?.playing ?? false,
        positionSec: s.nowPlaying?.positionSec ?? 0.0,
        durationSec: s.nowPlaying?.durationSec ?? 0.0,
        hasPrevEpisode: s.nowPlaying?.hasPrevEpisode ?? false,
        hasNextEpisode: s.nowPlaying?.hasNextEpisode ?? false,
      ),
    ),
  );
  if (!data.held) return null;
  return BackgroundMediaSurface(
    title: data.title,
    episodeLine: data.episodeLine,
    posterUrl: data.posterUrl,
    playing: data.playing,
    positionSec: data.positionSec,
    durationSec: data.durationSec,
    hasPrevEpisode: data.hasPrevEpisode,
    hasNextEpisode: data.hasNextEpisode,
  );
});
