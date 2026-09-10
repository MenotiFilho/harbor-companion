// Persistent now-playing bar (issue #42).
//
// A floating mini-player rendered on every screen except the Remote tab:
// the shell tabs (Home / Search / My Stuff / Profile) and the pushed detail
// and settings routes. It reuses the Remote reducer's already-derived
// `NowPlaying` view model for the poster, title, episode line and playing
// state, so the bar and the Remote tab never disagree.
//
// Play/pause taps go through the same host-authoritative transport path as the
// Remote tab (`RemoteController.togglePlay`) — no optimistic state. Tapping the
// rest of the bar opens the Remote tab (popping any pushed route first). The
// bar never renders without a host or without held media.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../home/poster_image.dart';
import '../remote/remote_controller.dart';
import 'shell_controller.dart';
import 'shell_reducer.dart';
import 'shell_tab.dart';

/// The rendered content of the player bar. Composed by [playerBarViewProvider]
/// from the shell connection gate plus the Remote view model, so [PlayerBar]
/// itself stays free of wiring and tests can stub this one seam.
class PlayerBarView {
  final String title;
  final String? episodeLine;
  final String? posterUrl;
  final bool playing;

  const PlayerBarView({
    required this.title,
    this.episodeLine,
    this.posterUrl,
    required this.playing,
  });
}

/// Null while disconnected (connect-first) or when nothing is held, so the bar
/// disappears the moment the Remote layer drops the media (sticky expiry).
final playerBarViewProvider = Provider<PlayerBarView?>((ref) {
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
      ),
    ),
  );
  if (!data.held) return null;
  return PlayerBarView(
    title: data.title,
    episodeLine: data.episodeLine,
    posterUrl: data.posterUrl,
    playing: data.playing,
  );
});

class PlayerBar extends ConsumerWidget {
  /// Whether to inset the bar for the system navigation area. False in the
  /// shell, where the navigation bar below already consumes that inset.
  final bool safeArea;

  const PlayerBar({super.key, this.safeArea = true});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final view = ref.watch(playerBarViewProvider);
    if (view == null) return const SizedBox.shrink();

    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    Widget bar = Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: Material(
        color: scheme.surfaceContainerHigh,
        elevation: 6,
        shadowColor: Colors.black,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        // The whole card opens Remote; the nested play/pause button wins the
        // tap for itself, so the button never also navigates.
        child: InkWell(
          onTap: () => _openRemote(context, ref),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: SizedBox(
                    width: 40,
                    height: 56,
                    child: PosterImage(url: view.posterUrl),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        view.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.titleSmall,
                      ),
                      if (view.episodeLine != null)
                        Text(
                          view.episodeLine!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                    ],
                  ),
                ),
                IconButton(
                  icon: Icon(view.playing ? Icons.pause : Icons.play_arrow),
                  tooltip: view.playing ? 'Pause' : 'Play',
                  onPressed: () =>
                      ref.read(remoteControllerProvider.notifier).togglePlay(),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    if (safeArea) bar = SafeArea(top: false, child: bar);
    return bar;
  }

  /// Opens the Remote tab, popping any pushed route (detail/settings) first so
  /// the tab is actually visible.
  void _openRemote(BuildContext context, WidgetRef ref) {
    Navigator.of(context).popUntil((route) => route.isFirst);
    ref.read(shellControllerProvider.notifier).selectTab(ShellTab.remote);
  }
}
