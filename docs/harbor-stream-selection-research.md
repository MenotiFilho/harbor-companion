# Harbor stream resolution & remote stream/quality selection — primary-source research

Source of truth: the Harbor source code only
(https://github.com/harborstremio/harbor). Read directly from a shallow clone of
**`beta-branch` at commit `74d73858c4292bdd916804d39d0f1dfa74c545a2`**
(`package.json` version **0.9.124**). The companion app's pinned wire doc
(`docs/wire-contract-research.md`) was pinned at 0.9.118/0.9.120; the `proto:1`
contract and the `RemoteCommand` union are unchanged in 0.9.124, so every
conclusion below applies to the host the app targets.

Every claim carries an inline citation to a file path + symbol/line relative to
the Harbor repo. Research date: 2026-09-11.

## Key finding

Choosing playback quality/source from the phone is **not possible client-only**.
Harbor resolves streams and picks one entirely on the host desktop; the remote
wire exposes only a *single, already-chosen* `source` in the snapshot
(`src/lib/remote/protocol.ts:26-31,137-178`) and has **no command to list or
select a stream**. The only wire path that reaches the stream picker is
`playMeta`, and it merely asks the host to open the picker and let the host's
own auto-pick policy choose (`src/lib/remote/remote-open-bridge.tsx:96-97`).
A minimal Harbor change (a new command + a stream list channel) is feasible and
reuses existing host machinery, but it is still an upstream change — consistent
with the app's zero-change decision for issue #36 in
`docs/wire-contract-research.md`.

---

## 1. Where Harbor resolves streams and how it chooses

### 1.1 The addon `stream` resource

Addons declaring the `stream` resource are queried over the Stremio addon
protocol at `${addonBase}/stream/${type}/${id}.json`
(`src/lib/streams/addons.ts:313`; declaration check
`src/lib/streams/addons.ts:252-267,276-289`). `fetchAddonStreams` fans out to all
addons in parallel (`src/lib/streams/addons.ts:47-56,163-166`) and streams
partial results back via `onPartial` as each addon settles
(`src/lib/streams/addons.ts:158-161`). Debrid-library streams are fetched
separately by `fetchLibraryStreams` (`src/lib/streams/library.ts`, called from
`src/lib/streams/pipeline.ts:20,137-155`).

### 1.2 The picker

`openPicker(meta, episode, opts)` pushes a `picker` frame onto the host nav
stack (`src/lib/view.tsx:1134-1177`). `playMeta` is the only remote command that
calls it: `openPicker(meta, episode, { autoPlay: settings.instantPlay, resume })`
(`src/lib/remote/remote-open-bridge.tsx:96-97`). `openMeta`, by contrast, only
opens the detail page (`openMeta(meta)`, `src/lib/remote/remote-open-bridge.tsx:88-90`).

Inside the picker, `usePipelineResult` runs
`runPipeline` (`src/lib/streams/pipeline.ts:103-230`), then
`use-pick-handler.onPlay` resolves and opens the player
(`src/views/play-picker/use-pick-handler.ts:158-441,464-491`).

### 1.3 How the host ranks and picks

Scoring is a pure function, `scoreStream` (`src/lib/streams/scoring/scoring-stream.ts:17-253`).
Dominant signals, with exact weights:

- **Debrid cache / direct → +60** for a cached-on-active-debrid stream (or an
  Easynews direct result), **+25** for a plain direct URL
  (`scoring-stream.ts:25-34`). This is the single biggest term.
- **Resolution**: 4K +25, 1080p +20, 720p +8, 480p +2
  (`src/lib/streams/scoring/scoring-resolution.ts:3-9`).
- HDR +5/+6 (`scoring-stream.ts:42-46`), REMUX +3 (`:123-126`),
  seeders up to +10 (`:67-76`), language match +12 (`:148-174`), and size/trust
  penalties (`:219-250`).

Ranking/selection is `rankAndPick` (`src/lib/streams/scoring/scoring-rank.ts:4-35`):

- `all` is sorted by **score desc**, unless `respectAddonOrder` (the host's
  `streamSort === "addon"`) puts addon priority/native order first
  (`scoring-rank.ts:10-16`).
- **Primary is not simply the top score**: `all.find(isCached(...))` — the
  highest-scoring *cached* stream wins if any exists, else `null`
  (`scoring-rank.ts:28-32`). On the HTML5/web build a cached AAC stream is
  further preferred (`:29-32`, `PREFER_AAC` in `src/lib/streams/pipeline.ts:16`).
- `byTier` exposes the best cached stream per quality tier
  (`scoring-rank.ts:23-26`), which the UI renders as quality tiles
  (`src/views/play-picker.tsx:369-379,445`).

### 1.4 Autoplay policy

`instantPlay` defaults to **true** (`src/lib/settings/defaults.ts:213`, type at
`src/lib/settings/types.ts:261`) and drives `autoPlay`
(`src/lib/remote/remote-open-bridge.tsx:97`). The autoplay state machine
(`src/views/play-picker/use-auto-fire.ts`) picks from
`autoCandidates`, built by `useAutoCandidates` (`src/views/play-picker/use-auto-candidates.ts`):

- Candidate ordering pulls a previously-played/source-lineage match to the front,
  then prefers cached/exact-episode streams, non-packs, language match, and addon
  rank (`use-auto-candidates.ts:179-184,116-160`).
- Autoplay waits **1500 ms** (`AUTO_SETTLE_MS`) or **4000 ms** for packs
  (`AUTO_SETTLE_PACK_MS`), with a **350 ms** high-confidence grace for a cached
  top pick, and a **10000 ms** quorum cap
  (`use-auto-fire.ts:11-17,124-154,156-216,218-270`).
- It fires `onPlay(autoCandidates[0])` with P2P pre-consent when the pick is
  torrent-only and `p2pAutoConsent` is on (`use-auto-fire.ts:239-250`).

### 1.5 Debrid/cache vs P2P

- `isCached` is true when the stream has a URL without an "uncached" marker, or
  is cached on an active debrid (`src/lib/streams/cached.ts:35-48`).
- `isP2pStream` is true for a non-debrid, non-cached infoHash
  (`src/lib/streams/cached.ts:50-62`).
- `streamMode` (`"both" | "addons" | "p2p"`, default `"both"`,
  `src/lib/settings/defaults.ts:240`, type `src/lib/settings/types.ts:288`) is
  applied by `filterStreamsByMode` (`src/lib/streams/mode.ts:80-96`); it
  degrades gracefully so the picker never becomes artificially empty.
- A torrent-only pick triggers a P2P confirmation unless
  `p2pAutoConsent` is set (`src/views/play-picker/use-pick-handler.ts:478-490`).

### 1.6 The in-player stream switcher (host-only capability)

The desktop player already has an in-place source switcher overlay: "Switch
stream" (`src/views/player/hooks/use-stream-switcher.ts:78-80`), which
re-resolves a chosen `ScoredStream` and hot-swaps the player without leaving
playback (`use-stream-switcher.ts:82-198`). It filters by quality
(`src/components/player/stream-switcher/quality.ts:4-57`) and facets
(`src/views/play-picker/stream-facets.ts:40-77`). **None of this is reachable
from the remote wire** — it is local UI state.

---

## 2. Does the remote API expose listing/selection?

### 2.1 Complete command surface — no stream command

`RemoteCommand`, `src/lib/remote/protocol.ts:183-253`: `play`, `pause`,
`togglePlayback`, `seek`, `setVolume`, `setMuted`, `setTarget`, `castDiscover`,
`castStop`, `prevEpisode`, `nextEpisode`, `toggleSubtitles`, `nav`, `setText`,
`submitText`, `blurText`, `openSearch`, `openMeta`, `openService`, `goView`,
`setSpeed`, `setSleep`, `setProfile`, `playMeta`, `libraryAction`, the `manga*`
set, `ping`. There is **no** `selectStream`/`setSource`/`nextStream` and **no**
list-streams request/response (`protocol.ts:183-253`). Command dispatch is
`dispatchRemoteCommand` (`src/lib/remote/session.ts:404-601`); the `default`
branch silently ignores unknown actions (`:599-600`).

### 2.2 What the existing "navigation" commands actually reach

- `openMeta` → `openMeta(meta)` detail page only, never the picker
  (`src/lib/remote/remote-open-bridge.tsx:88-90`).
- `playMeta` → `openPicker(..., { autoPlay: settings.instantPlay })`
  (`remote-open-bridge.tsx:96-97`) — opens the picker, then the **host** picks.
- `openService` → streaming-service catalog (`remote-open-bridge.tsx:72-74`;
  `openService` at `src/lib/view.tsx:825-842`).
- `goView` → `setView(view)` root view (`remote-open-bridge.tsx:68-70`).
- `nav` → `injectHostNav` → `dispatchTvNav` drives host keyboard/TV focus
  (`src/lib/remote/session.ts:415-421`, `src/lib/remote/inject-host-nav.ts:5-8`,
  `src/lib/keyboard-navigation.ts:45-65`). This can *mechanically* move focus and
  press `select` inside whatever host UI is open, but the phone neither receives
  the picker's stream list nor any indication of what is focused/selected — it
  is a blind input channel, not a selection API.

### 2.3 Transport layer adds nothing

The only routes on `:11471` are `/api/remote` (WebSocket) and `/manga-img`
(`src-tauri/src/web_server.rs:325-326`); everything else falls back to the SPA.
The Rust side is a dumb relay: inbound text frames are emitted as
`remote://cmd` with the raw string, outbound broadcasts are forwarded verbatim
(`handle_remote_socket`, `src-tauri/src/web_server.rs:249-293`; `remote://cmd`
relay at `:281`). All command
semantics live in `src/lib/remote/session.ts`.

### 2.4 Harbor's own phone remote can't do it either

Harbor's built-in mobile remote renders the chosen source as a text line only
(`sourceLine`, `src/views/remote-app.tsx:56-71,662-666`) and sends only
transport/nav/cast/text commands (`remote-app.tsx:807-912`). There is no
stream list or quality picker in the reference client — confirming the gap is on
the wire, not just in the companion app.

---

## 3. What the 400 ms snapshot carries

The snapshot is pushed on an interval of **400 ms**
(`src/lib/remote/host-mount.tsx:564-566`; `pushSnapshot` at `:62-67`) and defined
by `RemoteSnapshot` (`src/lib/remote/protocol.ts:137-178`).

- `source: RemoteSourceInfo | null` where `RemoteSourceInfo = { label,
  resolution, quality, releaseGroup }` (`protocol.ts:26-31,144`).
- It is populated from the **player's current `streamRef`** only — never a list:
  `source: b.src.streamRef ? { label: parsedTitle ?? title, resolution, quality,
  releaseGroup } : null` (`src/lib/remote/session.ts:378-385`, and the sticky
  copy at `:139-146`).
- `quality` is `formatStreamQuality(stream)` = resolution + HDR label + audio
  codec (`src/views/play-picker/picker-utils.ts:395-411`).
- There is **no available-streams list**, **no per-stream cache/P2P flag**, and
  **no chosen-stream identity**. Note `PlayerStreamRef` *does* hold
  `cachedSlugs` and `infoHash` (`src/lib/view.tsx:116-131`) but
  `RemoteSourceInfo` deliberately drops them (`session.ts:378-385`).

So the phone can show "what is playing / at what quality / from which release
group", but cannot see alternatives or even whether the current source is cached
vs P2P.

---

## 4. Smallest Harbor change, cost, and upstream reality

There is no client-only path (§2). The minimal viable upstream change:

1. **Expose the alternatives.** Add a stream-list channel. Do **not** bloat the
   400 ms snapshot with 50–200 stream objects — it is already described as heavy
   in `docs/wire-contract-research.md`. Prefer a request/response or a
   picker-open-only event, e.g. a `getStreams` command answered with a
   `{ t: "streams", ... }` server message, sourced from the existing in-memory
   picker cache (`peekPickerCache(meta, episode)`,
   `src/lib/picker-cache.ts:98-115`, populated by `setPickerCache` at
   `:51-69`). Each option needs a stable id, label, resolution, quality, source,
   cached/debrid slugs, seeders, size, and addon name — all already on
   `ScoredStream`/`ParsedStream` (`src/lib/streams/types.ts:45-138`).

2. **Add a `selectStream` command.** Add to `RemoteCommand`
   (`src/lib/remote/protocol.ts:183-253`) and dispatch in
   `dispatchRemoteCommand` (`src/lib/remote/session.ts:404-601`). Resolve the id
   against the current picker cache and reuse the existing swap path: if the
   player is open, the logic is already implemented in
   `onSwitchStream` (`src/views/player/hooks/use-stream-switcher.ts:82-198`); if
   the picker is open, call the picker's `onPlay`
   (`src/views/play-picker/use-pick-handler.ts:464-491`). Because neither hook is
   reachable from `session.ts`, the change needs a shared bridge/registry (the
   same `window` custom-event pattern already used for `openMeta`/`playMeta`,
   `src/lib/remote/remote-open-bridge.tsx:157-158`) plus wiring in
   `player.tsx`/`play-picker.tsx`.

**Cost:** moderate — roughly `protocol.ts`, `session.ts`, `host-mount.tsx`
(snapshot/list plumbing), `remote-open-bridge.tsx`, the player and picker
entry points, plus the companion's Dart client and UI. Not a one-liner, but it
reuses existing resolve/swap machinery rather than reimplementing it.

**Upstream approval reality:** precedent exists — the wire already exposes
`toggleSubtitles` (first-track heuristic, `session.ts:479-492`), `nextEpisode`,
and `setProfile`, so a stream-selection command is in the same spirit and could
plausibly be accepted. Two headwinds: (a) the API is **unauthenticated over the
open LAN** (documented in `docs/wire-contract-research.md` and issue #1), so
maintainers may be cautious about expanding its power; (b) effort is currently
going to open PRs (#1017 bigger companion shell, #1047 pairing token, #950
community Flutter app). Realistically, this is a "propose it upstream and wait"
change, not something the companion can ship by itself.

A smaller but **worse** non-change option is blind `nav`: send `playMeta` to
open the picker, then `nav` up/down/select with no readback. It cannot target a
specific quality and can mis-select anything; it is fragile and
indistinguishable from guessing. Not recommended.

---

## 5. Is there a "preferred quality" concept a client could influence?

There is no global "preferred/max resolution" for addon/torrent streams. The
closest host-side concepts, none of which the remote can read or write:

- **Sort order**: `streamSort: "harbor" | "addon"` default `"addon"`
  (`src/lib/settings/types.ts:567`, `src/lib/settings/defaults.ts:488`;
  UI `src/views/settings/streaming-sources-panel/sorting-tab.tsx:19`), plus
  per-addon `streamPriority` (`types.ts:568`, applied by
  `src/lib/streams/addon-priority.ts:18-27` and
  `src/lib/streams/priority-partition.ts:9-22`).
- **Persistent custom filters**: `customStreamFilters` + `activeStreamFilterId`
  (`types.ts:572-573`, defaults `493-494`) can pin resolution/source/codec/audio/
  HDR/cached-only/min-seeders/max-size
  (`src/lib/streams/custom-filters.ts:36-47,114-142`). These filter the picker.
- **Transport mode**: `streamMode` (`types.ts:288`).
- **Bandwidth budget**: `bandwidthMbps` feeds the bitrate penalty in scoring
  (`types.ts:456`, `src/lib/streams/scoring/scoring-bitrate.ts`).
- **Language**: `preferredLanguages` / `requirePreferredLanguage`
  (`types.ts:106-107`).
- **Media servers only**: `preferredQuality` exists solely on Jellyfin/Emby/Plex
  connections (`src/lib/media-server/types.ts:36`), not on addon streams.
- Addon-owned quality/sort options (e.g. Torrentio) live in each addon's
  config/URL and are invisible to the remote.

One indirect lever: profiles can carry linked settings — `SettingsProfileBridge`
calls `switchProfile(activeProfile.id, settingsLinked)` when the active profile
changes (`src/lib/settings-profile-bridge.tsx:8-12`), and `setProfile` is on the
wire (`protocol.ts`, `session.ts:474-478`). So switching profile can swap a
whole settings bundle (which may include sort/filters) — but that is not a
per-title quality choice and cannot be aimed at a specific stream.

---

## Recommendation

**Do not attempt phone-side stream/quality selection as a client-only feature.**
The remote API (`proto 1`) has no list or select command, the 400 ms snapshot
carries only the single chosen `source` (`protocol.ts:26-31,144`;
`session.ts:378-385`), and the only command that reaches the picker (`playMeta`)
hands the choice back to the host's scoring/autoplay policy
(`remote-open-bridge.tsx:96-97`; `scoring-rank.ts:28-34`;
`use-auto-fire.ts:239-250`).

**Recommended posture:** keep the zero-change stance and scope the current app
to *displaying* the chosen `source` (quality + release group) plus the existing
transport commands. File the upstream proposal — a `getStreams`/`selectStream`
pair answered off the existing picker cache
(`src/lib/picker-cache.ts:51-69,98-115`) and reusing the existing in-player swap
(`use-stream-switcher.ts:82-198`) — as a separate Harbor issue and track it; do
not gate companion work on it. Avoid the blind-`nav` hack; it cannot select a
quality deterministically and has no readback.

If upstream accepts, the companion gains a real quality picker; until then,
"quality selection from the phone" is **infeasible without a Harbor change**.

---

## Source index

- `src/lib/remote/protocol.ts` — `REMOTE_PROTO`, `RemoteSourceInfo`,
  `RemoteSnapshot`, `RemoteCommand` union (no stream command).
- `src/lib/remote/session.ts` — command dispatch; snapshot `source` from
  `streamRef`.
- `src/lib/remote/remote-open-bridge.tsx` — `openMeta`/`playMeta`/`openService`/
  `goView` host bridge; `playMeta` → `openPicker`.
- `src/lib/remote/inject-host-nav.ts`, `src/lib/keyboard-navigation.ts` — `nav`
  is focus injection.
- `src/lib/remote/host-mount.tsx` — 400 ms `pushSnapshot` interval.
- `src-tauri/src/web_server.rs` — `/api/remote` route; raw command relay.
- `src/lib/streams/addons.ts`, `pipeline.ts`, `scoring/*`, `mode.ts`,
  `custom-filters.ts`, `picker-cache.ts` — resolution, scoring, ranking, mode,
  filters.
- `src/views/play-picker/*` — picker, autoplay (`use-auto-fire.ts`,
  `use-auto-candidates.ts`), resolution/p2p handling (`use-pick-handler.ts`).
- `src/views/player/hooks/use-stream-switcher.ts` — host-only in-player source
  switch.
- `src/lib/settings/types.ts`, `defaults.ts`, `settings-profile-bridge.tsx` —
  preference knobs and profile-linked settings.
- `src/lib/media-server/types.ts` — the only `preferredQuality` field
  (media servers).
- `src/views/remote-app.tsx` — Harbor's own mobile remote shows source text
  only.
- Companion `docs/wire-contract-research.md` — prior wire pin (issue #36
  verdict).
