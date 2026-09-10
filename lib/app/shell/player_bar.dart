// Persistent now-playing bar (issue #42).
//
// A thin dock rendered in the shell between the tab body and the navigation
// bar, on every tab, while the Remote layer holds media (live or sticky-held).
// It reuses the Remote reducer's already-derived `NowPlaying` view model for
// the title/episode/playing fields, so the bar and the Remote tab never
// disagree.
//
// Play/pause taps go through the same host-authoritative transport path as the
// Remote tab (`RemoteController.togglePlay`) — no optimistic state. Tapping the
// rest of the bar selects the Remote tab. The bar is never drawn in the
// connect-first view: without a host there is no media to hold.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../remote/remote_controller.dart';
import 'shell_controller.dart';
import 'shell_tab.dart';

class PlayerBar extends ConsumerWidget {
  const PlayerBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Gate on the shell first: no host → no bar, and the Remote controller is
    // not even instantiated by the bar in the connect-first state.
    final showConnectFirst = ref.watch(
      shellControllerProvider.select((s) => s.showConnectFirst),
    );
    if (showConnectFirst) return const SizedBox.shrink();

    // Select only the fields the bar renders: a record compares structurally,
    // so the per-snapshot `positionSec` tick does not rebuild the bar.
    final view = ref.watch(
      remoteControllerProvider.select(
        (s) => (
          held: s.nowPlaying != null,
          title: s.nowPlaying?.mediaTitle ?? '',
          episode: s.nowPlaying?.episodeLine,
          playing: s.nowPlaying?.playing ?? false,
        ),
      ),
    );
    if (!view.held) return const SizedBox.shrink();

    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return Material(
      color: scheme.surfaceContainerHigh,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Divider(height: 1, thickness: 1, color: scheme.outlineVariant),
          // The whole bar opens the Remote tab; the nested play/pause button
          // wins the tap for itself, so the button never also navigates.
          InkWell(
            onTap: () => ref
                .read(shellControllerProvider.notifier)
                .selectTab(ShellTab.remote),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  Icon(Icons.graphic_eq, color: scheme.primary),
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
                        if (view.episode != null)
                          Text(
                            view.episode!,
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
        ],
      ),
    );
  }
}
