# Notification controls are host-authoritative and ride the main isolate's socket

The background notification's media controls (play/pause, previous/next, seek)
are a second front-end onto the **same** host-authoritative transport as the
in-app Remote tab. They keep no playback state of their own: the
`MediaSession`'s `PlaybackState` — playing flag, position, duration, which
actions exist — is derived from the last snapshot, and a tap emits the same
command the app would. There is no optimistic flip and no pending spinner; the
icon and scrubber catch up on the next snapshot.

## Decision

- **Surface**: play/pause always while media is held; previous/next only when the
  snapshot reports `hasPrevEpisode`/`hasNextEpisode`; a seek scrubber; tapping
  the notification body opens the Remote tab. Volume, mute and subtitles stay
  out of the surface (volume would target the phone's stream, not the host's).
- **`prev`** always goes to the previous episode (`prevEpisode`), matching the
  app — no media-standard "restart if mid-episode".
- **Position** is advertised with `speed=1` while playing and `speed=0` while
  paused, anchored to the latest snapshot; the platform extrapolates between
  snapshots and each snapshot re-anchors it. `ACTION_SEEK_TO` sends the host
  `seek`; the position still corrects from the snapshot, never optimistically.
- **Wiring**: the `flutter_foreground_task` service isolate marshals a tapped
  action to the main isolate (`sendDataToMain`), which calls the existing
  `RemoteController` methods. The socket does **not** move into the service
  isolate. Headset/Bluetooth transport buttons arrive through the same
  `MediaSession` callbacks and map to the same commands.
- **Disconnect**: the media surface disappears immediately (the reducer clears
  `nowPlaying` on `Disconnected`); the notification morphs back to the idle
  "Reconnecting…" state rather than showing a stale paused state.

## Consequences

- Moving the socket into the service isolate (robust to Activity destruction) is
  deferred; it would make the main isolate a snapshot mirror and is only needed
  if the main engine does not survive under the service.
- Because the surface is snapshot-driven, a socket blip drops the lock-screen
  controls instead of lying about state.
