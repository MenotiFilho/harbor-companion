# Android media surface for the persistent-connection notification

Ticket #66. The one background notification (ADR-0003) morphs into a
host-authoritative media control surface (ADR-0005) while the Remote layer holds
media. This note records how the surface is built and what remains a
device-only check.

## Why an app-owned native channel

`flutter_foreground_task` 11.0.3 hosts the `connectedDevice` foreground service
and posts a plain notification, but exposes no `MediaStyle`/bitmap API. A
`MediaSession` is what produces the lock-screen carousel, the headset/Bluetooth
transport buttons and the seek scrubber, so the app owns a thin channel:

- Dart: `lib/app/background/media_surface_channel.dart`
  (`dev.harbor.harbor_companion/media_surface`).
- Android: `android/app/src/main/kotlin/.../MediaSurfaceController.kt`
  (platform `android.media.session.MediaSession` +
  `android.app.Notification.MediaStyle`, no new dependency; API 21+,
  minSdk 24).

The native controller republishes the notification under the plugin service's
own id/channel (`4711` / `harbor_companion.connection`), so the service stays
foreground and there is still exactly one notification. When media clears it
deactivates the session immediately and the adapter asks the plugin to repost
its idle status, so the surface never shows a stale paused state.

## Host-authoritative, no optimism

Dart pushes the last snapshot with `show` (title/text/artwork/transport) or
`anchor` (transport only, for a 400 ms position tick the plugin notification
coalesces away). The native side only stores `PlaybackState`/`MediaMetadata`; a
button or Bluetooth callback reports the action back and the main isolate calls
the existing `RemoteController` method. The next snapshot corrects the surface.

## Fallback

If the native channel is absent (other platforms, or the native call fails),
the same `BackgroundPlatform` adapter uses the plugin's notification buttons:
`flutter_foreground_task` is capped at three actions, so the fallback offers
previous / play-pause / next. It has **no seek scrubber, no artwork/MediaStyle
metadata and no headset/Bluetooth transport integration** — those require the
native `MediaSession`. The action vocabulary (`surfaceActions`,
`backgroundActionFromId`) is identical either way, and volume/mute/subtitles are
excluded from both.

## Device-only checks (not covered by unit tests)

The Dart seam is pinned by tests; the native surface cannot be exercised in a
unit test. On a real device, in a release build:

- [ ] Play/pause from the notification and from a headset/Bluetooth control.
- [ ] The transport icons are distinct and the toggle morphs play ⇄ pause as the
      snapshot flips `playing` (regression: all three actions once shared the
      play-mark small icon, so prev/next/toggle all looked like "play").
- [ ] Previous/next appear only for a series episode that has them.
- [ ] The scrubber seeks; the bar re-anchors on the next snapshot (no optimism).
- [ ] Tapping the body opens the Remote tab, popping any pushed route.
- [ ] Artwork appears once the poster download completes.
- [ ] A socket drop removes the surface and the idle/reconnecting text returns.
- [ ] The notification survives backgrounding with the screen off, and the
      service stays foreground (single notification).
