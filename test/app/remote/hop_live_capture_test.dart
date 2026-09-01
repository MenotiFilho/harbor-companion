// Regression net for ticket 31, pinned against a REAL host timeline.
//
// Captured live on Harbor beta 0.9.120 (2026-09-01, host 127.0.0.1): Seinfeld
// S1E1 was driven near its end via `playMeta` + `seek`, the natural
// end-of-episode auto-advance was recorded frame by frame (400ms snapshots),
// and the host hopped to S1E2 after a 3917ms idle gap. Personal fields
// (library, trackers, profiles, API keys) are stripped; playback fields are
// verbatim.
//
// The replay mirrors the controller's timer contract exactly: the sticky timer
// arms once when `stickyHeld` first turns true with `stickyWindowFor(held
// media)`, idle snapshots must NOT re-arm it, and a non-idle snapshot clears
// the hold before any expiry. With the fix the Remote never leaves nowPlaying;
// under the old fixed 1.2s window the same timeline blinks "Nothing playing"
// for ~2.7s — the reported bug.

import 'package:flutter_test/flutter_test.dart';

import 'package:harbor_companion/app/remote/remote_reducer.dart';
import 'package:harbor_companion/app/ws/client_reducer.dart';

/// `(recvMs, snapshot json)` — verbatim host snapshots across the hop.
const List<(int, Map<String, dynamic>)> realHopFrames = [
    (48172, { "proto": 1, "idle": false, "mediaId": "tt0098904", "mediaTitle": "Seinfeld", "posterUrl": null, "episode": { "season": 1, "episode": 1 }, "source": { "label": "Seinfeld", "resolution": "SD", "quality": "SD · Dolby Vision · DTS", "releaseGroup": null }, "positionSec": 1383.0069999999998, "durationSec": 1385.535, "playing": true, "volume": 1, "muted": false, "target": { "kind": "local", "label": "This PC" }, "castDevices": [], "castDiscovering": false, "hasPrevEpisode": false, "hasNextEpisode": true, "subtitlesOn": true, "canToggleSubtitles": true, "textEntry": null, "updatedAt": 1788284081702 }),
    (48571, { "proto": 1, "idle": false, "mediaId": "tt0098904", "mediaTitle": "Seinfeld", "posterUrl": null, "episode": { "season": 1, "episode": 1 }, "source": { "label": "Seinfeld", "resolution": "SD", "quality": "SD · Dolby Vision · DTS", "releaseGroup": null }, "positionSec": 1383.424, "durationSec": 1385.535, "playing": true, "volume": 1, "muted": false, "target": { "kind": "local", "label": "This PC" }, "castDevices": [], "castDiscovering": false, "hasPrevEpisode": false, "hasNextEpisode": true, "subtitlesOn": true, "canToggleSubtitles": true, "textEntry": null, "updatedAt": 1788284082102 }),
    (48971, { "proto": 1, "idle": false, "mediaId": "tt0098904", "mediaTitle": "Seinfeld", "posterUrl": null, "episode": { "season": 1, "episode": 1 }, "source": { "label": "Seinfeld", "resolution": "SD", "quality": "SD · Dolby Vision · DTS", "releaseGroup": null }, "positionSec": 1383.841, "durationSec": 1385.535, "playing": true, "volume": 1, "muted": false, "target": { "kind": "local", "label": "This PC" }, "castDevices": [], "castDiscovering": false, "hasPrevEpisode": false, "hasNextEpisode": true, "subtitlesOn": true, "canToggleSubtitles": true, "textEntry": null, "updatedAt": 1788284082501 }),
    (49372, { "proto": 1, "idle": false, "mediaId": "tt0098904", "mediaTitle": "Seinfeld", "posterUrl": null, "episode": { "season": 1, "episode": 1 }, "source": { "label": "Seinfeld", "resolution": "SD", "quality": "SD · Dolby Vision · DTS", "releaseGroup": null }, "positionSec": 1384.258, "durationSec": 1385.535, "playing": true, "volume": 1, "muted": false, "target": { "kind": "local", "label": "This PC" }, "castDevices": [], "castDiscovering": false, "hasPrevEpisode": false, "hasNextEpisode": true, "subtitlesOn": true, "canToggleSubtitles": true, "textEntry": null, "updatedAt": 1788284082902 }),
    (49771, { "proto": 1, "idle": false, "mediaId": "tt0098904", "mediaTitle": "Seinfeld", "posterUrl": null, "episode": { "season": 1, "episode": 1 }, "source": { "label": "Seinfeld", "resolution": "SD", "quality": "SD · Dolby Vision · DTS", "releaseGroup": null }, "positionSec": 1384.675, "durationSec": 1385.535, "playing": true, "volume": 1, "muted": false, "target": { "kind": "local", "label": "This PC" }, "castDevices": [], "castDiscovering": false, "hasPrevEpisode": false, "hasNextEpisode": true, "subtitlesOn": true, "canToggleSubtitles": true, "textEntry": null, "updatedAt": 1788284083301 }),
    (50177, { "proto": 1, "idle": false, "mediaId": "tt0098904", "mediaTitle": "Seinfeld", "posterUrl": null, "episode": { "season": 1, "episode": 1 }, "source": { "label": "Seinfeld", "resolution": "SD", "quality": "SD · Dolby Vision · DTS", "releaseGroup": null }, "positionSec": 1385.0919999999999, "durationSec": 1385.535, "playing": true, "volume": 1, "muted": false, "target": { "kind": "local", "label": "This PC" }, "castDevices": [], "castDiscovering": false, "hasPrevEpisode": false, "hasNextEpisode": true, "subtitlesOn": true, "canToggleSubtitles": true, "textEntry": null, "updatedAt": 1788284083707 }),
    (50451, { "proto": 1, "idle": false, "mediaId": "tt0098904", "mediaTitle": "Seinfeld", "posterUrl": null, "episode": { "season": 1, "episode": 1 }, "source": { "label": "Seinfeld", "resolution": "SD", "quality": "SD · Dolby Vision · DTS", "releaseGroup": null }, "positionSec": 1385.301, "durationSec": 1385.535, "playing": false, "volume": 1, "muted": false, "target": { "kind": "local", "label": "This PC" }, "castDevices": [], "castDiscovering": false, "hasPrevEpisode": false, "hasNextEpisode": true, "subtitlesOn": true, "canToggleSubtitles": true, "textEntry": null, "updatedAt": 1788284083981 }),
    (50530, { "proto": 1, "idle": true, "mediaId": null, "mediaTitle": null, "posterUrl": null, "episode": null, "source": null, "positionSec": 0, "durationSec": 0, "playing": false, "volume": 1, "muted": false, "target": { "kind": "local", "label": "This PC" }, "castDevices": [], "castDiscovering": false, "hasPrevEpisode": false, "hasNextEpisode": false, "subtitlesOn": false, "canToggleSubtitles": false, "textEntry": null, "updatedAt": 1788284084059 }),
    (50604, { "proto": 1, "idle": true, "mediaId": null, "mediaTitle": null, "posterUrl": null, "episode": null, "source": null, "positionSec": 0, "durationSec": 0, "playing": false, "volume": 1, "muted": false, "target": { "kind": "local", "label": "This PC" }, "castDevices": [], "castDiscovering": false, "hasPrevEpisode": false, "hasNextEpisode": false, "subtitlesOn": false, "canToggleSubtitles": false, "textEntry": null, "updatedAt": 1788284084133 }),
    (50972, { "proto": 1, "idle": true, "mediaId": null, "mediaTitle": null, "posterUrl": null, "episode": null, "source": null, "positionSec": 0, "durationSec": 0, "playing": false, "volume": 1, "muted": false, "target": { "kind": "local", "label": "This PC" }, "castDevices": [], "castDiscovering": false, "hasPrevEpisode": false, "hasNextEpisode": false, "subtitlesOn": false, "canToggleSubtitles": false, "textEntry": null, "updatedAt": 1788284084502 }),
    (51371, { "proto": 1, "idle": true, "mediaId": null, "mediaTitle": null, "posterUrl": null, "episode": null, "source": null, "positionSec": 0, "durationSec": 0, "playing": false, "volume": 1, "muted": false, "target": { "kind": "local", "label": "This PC" }, "castDevices": [], "castDiscovering": false, "hasPrevEpisode": false, "hasNextEpisode": false, "subtitlesOn": false, "canToggleSubtitles": false, "textEntry": null, "updatedAt": 1788284084901 }),
    (51772, { "proto": 1, "idle": true, "mediaId": null, "mediaTitle": null, "posterUrl": null, "episode": null, "source": null, "positionSec": 0, "durationSec": 0, "playing": false, "volume": 1, "muted": false, "target": { "kind": "local", "label": "This PC" }, "castDevices": [], "castDiscovering": false, "hasPrevEpisode": false, "hasNextEpisode": false, "subtitlesOn": false, "canToggleSubtitles": false, "textEntry": null, "updatedAt": 1788284085303 }),
    (52171, { "proto": 1, "idle": true, "mediaId": null, "mediaTitle": null, "posterUrl": null, "episode": null, "source": null, "positionSec": 0, "durationSec": 0, "playing": false, "volume": 1, "muted": false, "target": { "kind": "local", "label": "This PC" }, "castDevices": [], "castDiscovering": false, "hasPrevEpisode": false, "hasNextEpisode": false, "subtitlesOn": false, "canToggleSubtitles": false, "textEntry": null, "updatedAt": 1788284085702 }),
    (52571, { "proto": 1, "idle": true, "mediaId": null, "mediaTitle": null, "posterUrl": null, "episode": null, "source": null, "positionSec": 0, "durationSec": 0, "playing": false, "volume": 1, "muted": false, "target": { "kind": "local", "label": "This PC" }, "castDevices": [], "castDiscovering": false, "hasPrevEpisode": false, "hasNextEpisode": false, "subtitlesOn": false, "canToggleSubtitles": false, "textEntry": null, "updatedAt": 1788284086101 }),
    (52971, { "proto": 1, "idle": true, "mediaId": null, "mediaTitle": null, "posterUrl": null, "episode": null, "source": null, "positionSec": 0, "durationSec": 0, "playing": false, "volume": 1, "muted": false, "target": { "kind": "local", "label": "This PC" }, "castDevices": [], "castDiscovering": false, "hasPrevEpisode": false, "hasNextEpisode": false, "subtitlesOn": false, "canToggleSubtitles": false, "textEntry": null, "updatedAt": 1788284086502 }),
    (53371, { "proto": 1, "idle": true, "mediaId": null, "mediaTitle": null, "posterUrl": null, "episode": null, "source": null, "positionSec": 0, "durationSec": 0, "playing": false, "volume": 1, "muted": false, "target": { "kind": "local", "label": "This PC" }, "castDevices": [], "castDiscovering": false, "hasPrevEpisode": false, "hasNextEpisode": false, "subtitlesOn": false, "canToggleSubtitles": false, "textEntry": null, "updatedAt": 1788284086901 }),
    (53771, { "proto": 1, "idle": true, "mediaId": null, "mediaTitle": null, "posterUrl": null, "episode": null, "source": null, "positionSec": 0, "durationSec": 0, "playing": false, "volume": 1, "muted": false, "target": { "kind": "local", "label": "This PC" }, "castDevices": [], "castDiscovering": false, "hasPrevEpisode": false, "hasNextEpisode": false, "subtitlesOn": false, "canToggleSubtitles": false, "textEntry": null, "updatedAt": 1788284087301 }),
    (54171, { "proto": 1, "idle": true, "mediaId": null, "mediaTitle": null, "posterUrl": null, "episode": null, "source": null, "positionSec": 0, "durationSec": 0, "playing": false, "volume": 1, "muted": false, "target": { "kind": "local", "label": "This PC" }, "castDevices": [], "castDiscovering": false, "hasPrevEpisode": false, "hasNextEpisode": false, "subtitlesOn": false, "canToggleSubtitles": false, "textEntry": null, "updatedAt": 1788284087701 }),
    (54447, { "proto": 1, "idle": false, "mediaId": "tt0098904", "mediaTitle": "Seinfeld", "posterUrl": null, "episode": { "season": 1, "episode": 2, "name": "The Stake Out" }, "source": { "label": "Seinfeld", "resolution": "SD", "quality": "SD · Dolby Vision · DTS", "releaseGroup": null }, "positionSec": 0, "durationSec": 0, "playing": false, "volume": 1, "muted": false, "target": { "kind": "local", "label": "This PC" }, "castDevices": [], "castDiscovering": false, "hasPrevEpisode": false, "hasNextEpisode": false, "subtitlesOn": false, "canToggleSubtitles": false, "textEntry": null, "updatedAt": 1788284087978 }),
    (54488, { "proto": 1, "idle": false, "mediaId": "tt0098904", "mediaTitle": "Seinfeld", "posterUrl": null, "episode": { "season": 1, "episode": 2, "name": "The Stake Out" }, "source": { "label": "Seinfeld", "resolution": "SD", "quality": "SD · Dolby Vision · DTS", "releaseGroup": null }, "positionSec": 0, "durationSec": 0, "playing": false, "volume": 1, "muted": false, "target": { "kind": "local", "label": "This PC" }, "castDevices": [], "castDiscovering": false, "hasPrevEpisode": true, "hasNextEpisode": true, "subtitlesOn": false, "canToggleSubtitles": false, "textEntry": null, "updatedAt": 1788284088017 }),
    (54492, { "proto": 1, "idle": false, "mediaId": "tt0098904", "mediaTitle": "Seinfeld", "posterUrl": null, "episode": { "season": 1, "episode": 2, "name": "The Stake Out" }, "source": { "label": "Seinfeld", "resolution": "SD", "quality": "SD · Dolby Vision · DTS", "releaseGroup": null }, "positionSec": 0, "durationSec": 0, "playing": true, "volume": 1, "muted": false, "target": { "kind": "local", "label": "This PC" }, "castDevices": [], "castDiscovering": false, "hasPrevEpisode": true, "hasNextEpisode": true, "subtitlesOn": false, "canToggleSubtitles": false, "textEntry": null, "updatedAt": 1788284088019 }),
    (54571, { "proto": 1, "idle": false, "mediaId": "tt0098904", "mediaTitle": "Seinfeld", "posterUrl": null, "episode": { "season": 1, "episode": 2, "name": "The Stake Out" }, "source": { "label": "Seinfeld", "resolution": "SD", "quality": "SD · Dolby Vision · DTS", "releaseGroup": null }, "positionSec": 0, "durationSec": 0, "playing": true, "volume": 1, "muted": false, "target": { "kind": "local", "label": "This PC" }, "castDevices": [], "castDiscovering": false, "hasPrevEpisode": true, "hasNextEpisode": true, "subtitlesOn": false, "canToggleSubtitles": false, "textEntry": null, "updatedAt": 1788284088102 }),
    (54971, { "proto": 1, "idle": false, "mediaId": "tt0098904", "mediaTitle": "Seinfeld", "posterUrl": null, "episode": { "season": 1, "episode": 2, "name": "The Stake Out" }, "source": { "label": "Seinfeld", "resolution": "SD", "quality": "SD · Dolby Vision · DTS", "releaseGroup": null }, "positionSec": 0, "durationSec": 0, "playing": true, "volume": 1, "muted": false, "target": { "kind": "local", "label": "This PC" }, "castDevices": [], "castDiscovering": false, "hasPrevEpisode": true, "hasNextEpisode": true, "subtitlesOn": false, "canToggleSubtitles": false, "textEntry": null, "updatedAt": 1788284088501 }),
    (55371, { "proto": 1, "idle": false, "mediaId": "tt0098904", "mediaTitle": "Seinfeld", "posterUrl": null, "episode": { "season": 1, "episode": 2, "name": "The Stake Out" }, "source": { "label": "Seinfeld", "resolution": "SD", "quality": "SD · Dolby Vision · DTS", "releaseGroup": null }, "positionSec": 0, "durationSec": 0, "playing": true, "volume": 1, "muted": false, "target": { "kind": "local", "label": "This PC" }, "castDevices": [], "castDiscovering": false, "hasPrevEpisode": true, "hasNextEpisode": true, "subtitlesOn": false, "canToggleSubtitles": false, "textEntry": null, "updatedAt": 1788284088902 }),
    (55771, { "proto": 1, "idle": false, "mediaId": "tt0098904", "mediaTitle": "Seinfeld", "posterUrl": null, "episode": { "season": 1, "episode": 2, "name": "The Stake Out" }, "source": { "label": "Seinfeld", "resolution": "SD", "quality": "SD · Dolby Vision · DTS", "releaseGroup": null }, "positionSec": 0, "durationSec": 0, "playing": true, "volume": 1, "muted": false, "target": { "kind": "local", "label": "This PC" }, "castDevices": [], "castDiscovering": false, "hasPrevEpisode": true, "hasNextEpisode": true, "subtitlesOn": false, "canToggleSubtitles": false, "textEntry": null, "updatedAt": 1788284089302 }),
    (56171, { "proto": 1, "idle": false, "mediaId": "tt0098904", "mediaTitle": "Seinfeld", "posterUrl": null, "episode": { "season": 1, "episode": 2, "name": "The Stake Out" }, "source": { "label": "Seinfeld", "resolution": "SD", "quality": "SD · Dolby Vision · DTS", "releaseGroup": null }, "positionSec": 0, "durationSec": 0, "playing": true, "volume": 1, "muted": false, "target": { "kind": "local", "label": "This PC" }, "castDevices": [], "castDiscovering": false, "hasPrevEpisode": true, "hasNextEpisode": true, "subtitlesOn": false, "canToggleSubtitles": false, "textEntry": null, "updatedAt": 1788284089702 }),
    (56572, { "proto": 1, "idle": false, "mediaId": "tt0098904", "mediaTitle": "Seinfeld", "posterUrl": null, "episode": { "season": 1, "episode": 2, "name": "The Stake Out" }, "source": { "label": "Seinfeld", "resolution": "SD", "quality": "SD · Dolby Vision · DTS", "releaseGroup": null }, "positionSec": 0, "durationSec": 0, "playing": true, "volume": 1, "muted": false, "target": { "kind": "local", "label": "This PC" }, "castDevices": [], "castDiscovering": false, "hasPrevEpisode": true, "hasNextEpisode": true, "subtitlesOn": false, "canToggleSubtitles": false, "textEntry": null, "updatedAt": 1788284090101 }),
    (56970, { "proto": 1, "idle": false, "mediaId": "tt0098904", "mediaTitle": "Seinfeld", "posterUrl": null, "episode": { "season": 1, "episode": 2, "name": "The Stake Out" }, "source": { "label": "Seinfeld", "resolution": "SD", "quality": "SD · Dolby Vision · DTS", "releaseGroup": null }, "positionSec": 0, "durationSec": 0, "playing": true, "volume": 1, "muted": false, "target": { "kind": "local", "label": "This PC" }, "castDevices": [], "castDiscovering": false, "hasPrevEpisode": true, "hasNextEpisode": true, "subtitlesOn": false, "canToggleSubtitles": false, "textEntry": null, "updatedAt": 1788284090501 }),
];

/// The host's real idle gap: first idle snapshot after the run of active ones
/// (50530) to the first snapshot of the next episode (54447).
final int realHopGapMs = 54447 - 50530;

class ReplayResult {
  final bool everIdleAfterPlaying;
  final int? blinkMs;
  final int? armedWindowMs;
  final RemoteState finalState;
  const ReplayResult({
    required this.everIdleAfterPlaying,
    required this.blinkMs,
    required this.armedWindowMs,
    required this.finalState,
  });
}

/// Feeds the real timeline through the pure reducer while mirroring the
/// controller's timer contract: the sticky timer arms ONCE when `stickyHeld`
/// first turns true with [windowFor]'s verdict for the held state, fires
/// `StickyExpired` if it elapses, and is cancelled by any non-idle snapshot.
ReplayResult replay(
  List<(int, Map<String, dynamic>)> frames,
  Duration Function(RemoteState) windowFor,
) {
  var s = remoteReduce(RemoteState(), const Connected());
  int? armedAt;
  Duration? window;
  var started = false;
  var everIdle = false;
  int? idleFrom;
  int? blinkMs;
  int? armedWindowMs;
  for (final (recv, json) in frames) {
    final before = s;
    s = remoteReduce(s, SnapshotArrived(Snapshot.fromJson(json)));
    if (!snapIdle(json)) started = true;
    if (started && s.phase == RemotePhase.idle) everIdle = true;

    if (s.stickyHeld && !before.stickyHeld) {
      armedAt = recv;
      window = windowFor(s);
      armedWindowMs = window.inMilliseconds;
    }
    if (!s.stickyHeld && before.stickyHeld) {
      armedAt = null;
      window = null;
    }
    if (armedAt != null && recv - armedAt >= window!.inMilliseconds) {
      s = remoteReduce(s, const StickyExpired());
      idleFrom = recv;
      armedAt = null;
      window = null;
    }
    if (idleFrom != null && !snapIdle(json)) {
      blinkMs = recv - idleFrom;
      idleFrom = null;
    }
  }
  return ReplayResult(
    everIdleAfterPlaying: everIdle,
    blinkMs: blinkMs,
    armedWindowMs: armedWindowMs,
    finalState: s,
  );
}

bool snapIdle(Map<String, dynamic> json) => json['idle'] == true;

void main() {
  test('the real hop timeline stays in nowPlaying start to finish (fixed client)', () {
    final r = replay(realHopFrames, (s) => stickyWindowFor(s.nowPlaying));

    // The held media (S1E1, end of file) reported a next episode, so the hold
    // must arm with the ~5s hop window.
    expect(r.armedWindowMs, hopStickyIdleMs);
    // The host's real gap is 3917ms — inside the 5s window, outside the old
    // 1.2s one (this pair of facts is exactly ticket 31).
    expect(realHopGapMs, lessThan(hopStickyIdleMs));
    expect(realHopGapMs, greaterThan(stickyIdleMs));
    // Not a single idle frame reached the UI: the hold bridged the whole gap.
    expect(r.everIdleAfterPlaying, isFalse, reason: 'phase must never drop to idle during the hop');
    expect(r.blinkMs, isNull);
    // And the view lands on the next episode.
    expect(r.finalState.phase, RemotePhase.nowPlaying);
    expect(r.finalState.nowPlaying!.episode!.season, 1);
    expect(r.finalState.nowPlaying!.episode!.episode, 2);
    expect(r.finalState.stickyHeld, isFalse);
  });

  test('the same timeline under the old fixed 1.2s window blinks ~2.7s', () {
    final r = replay(realHopFrames, (_) => const Duration(milliseconds: stickyIdleMs));

    expect(r.armedWindowMs, stickyIdleMs);
    expect(r.everIdleAfterPlaying, isTrue, reason: 'the old window expires 1.2s into the 3.9s gap');
    // The expiry lands on a 400ms frame boundary, so allow one tick of skew.
    expect(r.blinkMs, closeTo(realHopGapMs - stickyIdleMs, 400),
        reason: 'the reported "Nothing playing" flash');
  });
}
