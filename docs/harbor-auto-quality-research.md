# Harbor Auto-Pick Quality from the Remote Wire — Primary-Source Research

Source of truth: the Harbor source code only
(https://github.com/harborstremio/harbor), read directly. The **authoritative**
branch for Harbor Companion is **`beta-branch`** at commit
`74d73858c4292bdd916804d39d0f1dfa74c545a2`, `package.json` version **0.9.124**
— that is the host the app actually connects to. `main` (version 0.9.21) and the
open PRs #1017, #1031, #1047 and #950 were also checked. Every factual claim
carries an inline citation (file path + line numbers, relative to the Harbor
repo). Research date: 2026-09-11.

Scope: this ticket (#61) asks whether the companion can drive Harbor's
automatic "pick the stream at the desired quality" system from the remote wire,
instead of selecting an individual stream (which ticket #57 proved is
impossible). The question is **not** whether the host can auto-pick at a quality
(it can) but whether **the phone can direct that from `ws://<ip>:11471/api/remote`**.

Short answer: the phone can only pull two levers — send `playMeta` (the host
auto-picks under whatever settings are already active) or `setProfile` (swap the
whole active profile, and with it the whole settings bundle if that profile is
"Independent"). It cannot create or edit profiles, filters, or any settings over
the wire, and the quality preference is a **soft, self-healing preference**, not
an imposed constraint.

## Key finding

Harbor's stream filters live in the settings bundle
(`src/lib/settings/types.ts:567-573`), and a profile can carry its own copy of
that entire bundle when it is marked **Independent** (`settingsLinked: false`).
The remote wire's only settings-adjacent command is `setProfile {id}` — a
*switch between profiles the user already configured on the desktop*, nothing
more (`src/lib/remote/protocol.ts:217-218`, `src/lib/remote/session.ts:474-478`).

So the indirect path is **partially viable and requires host-side setup**: the
user must pre-create Independent profiles that differ in
`customStreamFilters`/`activeStreamFilterId`/`streamSort`/`streamMode`/
`bandwidthMbps`, and the app can then offer those profiles as "quality options"
before play. It is **not client-only**, and even then the filter is best-effort:
it silently falls back to all streams when nothing matches, and is bypassed
entirely during a host-matched Together session. There is no wire command to
create/edit filters, set `bandwidthMbps`, set `streamMode`, configure addons, or
acknowledge that a profile's settings have been applied.

---

## 1. Can a profile carry the stream-filter settings? What does `settingsLinked` cover?

**Yes — but only for profiles marked Independent, and it is the whole settings
bundle, not a selected subset.**

- A Harbor profile (`Profile`) has an optional `settingsLinked` flag
  (`src/lib/profiles.tsx:122-135`).
- `settingsLinked` is the "Shared vs Independent" scope switch in the profile's
  settings UI: shared = "One set of preferences everyone on this Harbor uses";
  independent = "This profile keeps its own preferences, separate from everyone
  else" (`src/views/settings/account/settings-scope-card.tsx:8-15, 20-44`).
- The settings store keys by profile + link flag: `sourceKeyFor(profileId,
  linked)` returns the shared blob `harbor.settings.shared` when linked, or
  `harbor.settings.<profileId>` when independent
  (`src/lib/settings/profile-store.ts:5-14`). `loadEffective()` reads that key
  and falls back to the shared/legacy blob if the per-profile one does not exist
  yet (`src/lib/settings/profile-store.ts:32-38`). `forkToProfile()` clones the
  shared blob into the per-profile key when a profile is made independent
  (`src/lib/settings/profile-store.ts:81-84`).
- Because the persisted object is the **entire** `Settings` type, an
  independent profile carries *all* settings fields, including the
  quality-affecting ones:
  - `preferredLanguages` (`src/lib/settings/types.ts:106`),
  - `streamMode: "both" | "addons" | "p2p"` (`:288`),
  - `bandwidthMbps` (`:456`),
  - `streamSort: "harbor" | "addon"` (`:567`),
  - `customStreamFilters` and `activeStreamFilterId` (`:572-573`).
  Defaults live in `src/lib/settings/defaults.ts:26, 240, 383, 488, 493-494`;
  the custom-filter array is only overwritten wholesale when the stored value is
  not an array (`src/lib/settings/load.ts:440-442`).
- **Critical default:** newly created profiles are `settingsLinked: true`
  (`src/lib/profiles.tsx:557`), and adopted/synced profiles default to `true`
  when the flag is absent (`src/lib/profiles.tsx:117`,
  `src/lib/profile-sync/types.ts:115`). A profile created the normal way
  therefore **shares** the global settings — it does not get its own filter. The
  user must explicitly flip it to Independent *and then* configure a filter on
  it. The `settingsLinked` flag itself does sync between devices
  (`WireProfile.settingsLinked`, `src/lib/profile-sync/types.ts:106-119`).

So: the profile is the *only* per-media lever in Harbor's settings model, and it
carries filters only when it is Independent.

## 2. Does `setProfile` swap settings immediately? Race? Does the pick really enforce quality?

### 2.1 The swap is asynchronous (React effect), and there is no settings acknowledgement

- Wire: `setProfile {id}` → `dispatchRemoteCommand` dispatches a DOM event and
  returns; it does not touch settings itself
  (`src/lib/remote/session.ts:474-478`).
- `RemoteOpenBridge` listens for `harbor:remote-set-profile` and calls
  `selectProfile(id)` (`src/lib/remote/remote-open-bridge.tsx:56-63`).
- `selectProfile` writes the new `activeId` to `localStorage` synchronously and
  calls `setState` (`src/lib/profiles.tsx:491-517`).
- The actual settings swap happens **later, in a React effect**:
  `SettingsProfileBridge` watches `activeProfile?.id` and calls
  `switchProfile(activeProfile.id, activeProfile.settingsLinked !== false)`
  (`src/lib/settings-profile-bridge.tsx:5-11`). `switchProfile` is what calls
  `loadEffective()` and `setSettings(next)` (`src/lib/settings.tsx:472-509`).
- There is **no wire message that confirms the new settings bundle is loaded**.
  The 400 ms snapshot's `profile` is built by `readActiveProfileIdentity()`,
  which reads `localStorage` directly (`src/lib/remote/session.ts:272, 345, 398`;
  `src/lib/profiles.tsx:295-312`). Because `selectProfile` writes
  `localStorage` synchronously, the *snapshot will already show the new profile
  identity* while the settings bundle may still be the old one for one render.
- Consequence: a `setProfile` followed immediately by `playMeta` is racy. The
  `playMeta` handler reads `settings` from the `RemoteOpenBridge` render closure
  — notably `autoPlay: settings.instantPlay`
  (`src/lib/remote/remote-open-bridge.tsx:96-98`) — and the picker's pipeline is
  started from the settings available at that render
  (`src/views/play-picker/use-pipeline-result.ts:153-171`). The filter itself is
  applied at render time and would catch up, but `instantPlay` and any pipeline
  input absorbed into the scored result would not necessarily. The app cannot
  wait for an "applied" signal; it can only wait for a snapshot whose
  `profile.id` matches the target, which only proves the selection, not the
  settings reload.

### 2.2 Filters are a soft preference with a guaranteed fallback

The custom filter is applied to the picker candidate list, but only as a
preference:

- `activeStreamFilter` = the non-empty filter whose id equals
  `activeStreamFilterId` (`src/views/play-picker.tsx:331-334`).
- In `filteredPicker`, when a filter is active it keeps matching streams; if
  **zero** match, it sets `fellBack = true` and keeps the unfiltered list
  (`src/views/play-picker.tsx:355-364`). The same semantics are extracted as
  `applyActiveStreamFilterPreference()` in the open PR #1031 for `main`
  (`src/lib/streams/filter-preference.ts:9-25`, PR #1031 body: "safe fallback
  when nothing matches").
- The filter is **bypassed entirely** when a Together host stream needs matching
  (`if (activeStreamFilter && !hostMatch)`, `src/views/play-picker.tsx:355`;
  PR #1031 passes `bypass = !!hostMatch`).
- Matching is a hard include/exclude on parsed fields — resolution, source,
  codec, audio, HDR, cached-only, min seeders, max size
  (`src/lib/streams/custom-filters.ts:36-47, 114-142`).

### 2.3 Autoplay obeys the filter — when the filter produced candidates

- Autoplay candidates are derived from `filteredPicker`, so they are the
  filtered set (with the fallback above): `useAutoCandidates({ filteredPicker,
  ... })` (`src/views/play-picker.tsx:479-498`).
- `useAutoCandidates` sorts by cached/instant, missing-name, "your media",
  packs, addon rank, language, etc. **and does not reference `score` at all**
  (`src/views/play-picker/use-auto-candidates.ts:116-160`); it then pushes any
  previously played/source-matched stream first (`:175-192`).
- `useAutoFire` plays `autoCandidates[0]` once the settle quorum/high-confidence
  grace passes and the stream is instant-playable
  (`src/views/play-picker/use-auto-fire.ts:124-154, 156-216, 218-270`).

So an active filter does gate autoplay: **if at least one stream matches, the
auto-pick is drawn only from matches; if none match, the filter is silently
ignored and the best un-filtered stream plays.** The desired quality is
best-effort, never guaranteed.

### 2.4 What the other settings actually do

- `bandwidthMbps` is a **soft score penalty**, not a filter
  (`src/lib/streams/scoring/scoring-bitrate.ts:4-35`). It is passed into the
  pipeline as a score option only when `> 0`
  (`src/lib/streams/episode-pipeline-input.ts:168`). It can be outweighed by
  strong signals (e.g. cached `+60`, `src/lib/streams/scoring/scoring-stream.ts:28-30`).
  Note it is **not** in the `usePipelineResult` effect dependency list
  (`src/views/play-picker/use-pipeline-result.ts:153-171`), so changing a
  profile's bandwidth does not re-score an already-computed picker result.
- `streamSort` only chooses display/addon order
  (`respectAddonOrder: settings.streamSort === "addon"`,
  `src/lib/streams/episode-pipeline-input.ts:173`; display reorder in
  `src/views/play-picker.tsx:396-402`). It is not a resolution preference.
- `streamMode` filters transport (`addons` vs `p2p`) but also falls back to all
  streams when the preferred transport is empty
  (`src/lib/streams/mode.ts:80-95`).
- `preferredLanguages` feeds scoring (`+12` on match, `-14` on mismatch,
  `src/lib/streams/scoring/scoring-stream.ts:148-178`) and, only when strict
  mode plus `requirePreferredLanguage` are on, a trust-stage language filter
  (`src/lib/streams/episode-pipeline-input.ts:155`;
  `requirePreferredLanguage` defaults to `false`,
  `src/lib/settings/defaults.ts:27`).
- The score-based ranking itself is `scoreStream()` / `rankAndPick()`
  (`src/lib/streams/scoring/scoring-stream.ts:17-252`,
  `src/lib/streams/scoring/scoring-rank.ts:4-34`); it is a soft ranking, and
  autoplay re-sorts with its own heuristics anyway (`use-auto-candidates.ts`,
  above).

## 3. Can filters/profiles be created or edited over the wire?

**No. The wire only switches between host-configured profiles.**

- The full `RemoteCommand` union in beta is: `play`, `pause`, `togglePlayback`,
  `seek`, `setVolume`, `setMuted`, `setTarget`, `castDiscover`, `castStop`,
  `prevEpisode`, `nextEpisode`, `toggleSubtitles`, `nav`, `setText`,
  `submitText`, `blurText`, `openSearch`, `openMeta`, `openService`, `goView`,
  `setSpeed`, `setSleep`, `setProfile`, `playMeta`, `libraryAction`, the
  `manga*` commands, and `ping` (`src/lib/remote/protocol.ts:183-253`). There is
  **no `setSetting`, `setStreamFilter`, `createProfile`, `setBandwidth`, or
  `setStreamMode`**.
- The host dispatch switch confirms it: the only settings-adjacent case is
  `setProfile` (`src/lib/remote/session.ts:404-602`, case at `:474-478`).
- A repo-wide grep for settings/filter commands found nothing in
  `src-tauri/` either; the Rust remote server only relays opaque messages and
  broadcasts snapshots (`src-tauri/src/web_server.rs:257-300`).
- **`main` is even smaller**: its `RemoteCommand` union stops at `ping` with no
  `playMeta`/`setProfile` at all (`origin/main:src/lib/remote/protocol.ts`,
  command list at lines 70-92 of that blob). Open PR #1017 ports the beta remote
  (`port/manga`); its `protocol.ts` is the beta union verbatim and adds no
  settings command. Its body only claims profile *switching*, and explicitly
  drops password-protected profiles from the remote list (PR #1017 body,
  "Security differences from beta").
- Open PR #1031 ("persist the selected saved stream filter", base `main`) adds
  `activeStreamFilterId` persistence and a shared
  `applyActiveStreamFilterPreference()` helper
  (`src/lib/streams/filter-preference.ts:9-25`, files list includes
  `src/views/play-picker/use-auto-candidates.ts`,
  `src/views/settings/stream-filters-panel.tsx`) — i.e. it is the port of a
  feature beta 0.9.124 already has. **It adds no wire command.**
- Open PR #1047 is security hardening for the local HTTP/remote surfaces. It
  says the remote socket "has no token and no origin check" and that its `nav`,
  `setText`, `submitText` and `openSearch` commands "amount to full puppeting of
  the interface", then proposes a per-process pairing token plus an Origin check
  (PR #1047 body, §2). It adds no settings command.
- Open PR #950 adds a brand-new native Flutter client under `clients/` with its
  own stream engine and "on-the-fly quality switching" (PR #950 body). It is
  purely additive and does not touch the desktop remote wire — it is a
  different architecture (phone resolves streams itself), not a wire change.

## 4. Does the 400 ms snapshot expose the active profile and/or active filter?

**It exposes the active profile identity and the full profile list, but no
filter or setting at all.**

- `RemoteSnapshot` (`src/lib/remote/protocol.ts:137-178`) carries
  `profile: RemoteProfile | null` and `profiles: RemoteProfile[]`
  (`:161-164`).
- `RemoteProfile` is only `{ id?, name, avatar, color }`
  (`src/lib/remote/protocol.ts:39-44`); the host fills it from
  `readActiveProfileIdentity()` / `readAllProfilesIdentity()`, which return only
  `{ id, name, avatar, color }` (`src/lib/profiles.tsx:295-330`; used at
  `src/lib/remote/session.ts:272-273, 345-346, 398-399`).
- There is **no** field for `activeStreamFilterId`, `streamSort`, `streamMode`,
  `bandwidthMbps`, `preferredLanguages`, or the filter list anywhere in the
  snapshot or in any command. The only stream information is the single chosen
  `source` after playback starts (`src/lib/remote/protocol.ts:144, 26-31`).

Implication for the app: it can display *which profile* is active (and, by
convention, which quality bucket that profile represents), but it cannot read
back what filter is actually in force. The host writes the active profile to
`localStorage` before the settings swap, so the snapshot's `profile` is the
earliest reliable signal that a `setProfile` took effect.

## 5. If it is "switch between pre-configured profiles": viable UX and side effects

**Viable UX (host-assisted):**

1. On Harbor, the user creates N profiles (e.g. "4K", "1080p", "Cached only").
2. For each, they must set the profile scope to **Independent**
   (`settingsLinked: false`) — new profiles default to Shared
   (`src/lib/profiles.tsx:557`) — and configure
   `customStreamFilters` + `activeStreamFilterId` (and optionally `streamSort`,
   `streamMode`, `bandwidthMbps`, `preferredLanguages`).
3. The companion shows `snapshot.profiles` as quality options. Tapping one sends
   `setProfile {id}`; the app then waits for a snapshot whose `profile.id`
   matches before sending `playMeta`.

**Side effects of switching the active profile (all host-global and persistent):**

- The active profile is written to `localStorage` and stays active
  (`src/lib/profiles.tsx:504-513`), so it is not a per-play override; every
  subsequent host action runs as that profile.
- If the profile is Independent, the **entire settings bundle** swaps
  (`src/lib/settings.tsx:472-491`), not just the filter.
- Per-profile data keys change with the profile. `PROFILE_KEY_PREFIXES` includes
  Stremio/Trakt/Simkl/AniList/MAL auth sessions, favorites, watchlist, watched
  flags, playback history and **installed addons**
  (`src/lib/profiles.tsx:48-80`; addon store keys by active profile at
  `src/lib/addon-store.ts:11-17, 21-39, 54-58`). Installed addons are shared
  with the profile named in `shareStremioWith` (normally the primary), so this
  is often invisible, but it is per-profile state.
- Collections, custom lists and ratings are separately keyed for Independent
  profiles (`src/lib/collections.ts:18-34`, `src/lib/custom-lists.ts:10-26`,
  `src/lib/ratings/store.ts:13-29`), and the UI language follows the
  Independent profile's own settings blob (`src/lib/i18n/store.ts:11-30`).
- Switching picks up the new profile's watch history/watched flags, so a "4K"
  profile is effectively a separate person — this is the real cost of the
  approach.
- **PIN-locked profiles cannot be switched remotely.** `selectProfile` fails
  closed for a profile with a password hash unless the caller proves it
  (`src/lib/profile-sync/profile-lock.ts:20-29`,
  `src/lib/profiles.tsx:498-499`). PR #1017 additionally omits
  password-protected profiles from the remote profile list entirely.
- No acknowledgement that the settings reload finished (see §2.1), so the app
  must wait at least one snapshot round-trip, and bandwidth/streamSort baked into
  an already-computed picker result will not necessarily re-score.

## 6. Alternatives outside profiles

There is **no wire command** that influences any of these directly:

- `bandwidthMbps`, `streamMode`, `preferredLanguages`, `instantPlay`, `streamSort`
  — all settings; no setter on the wire (`src/lib/remote/protocol.ts:183-253`).
- Addon URL/config — no command; addons are host-local, per-profile state
  (`src/lib/addon-store.ts`).
- A per-play quality argument on `playMeta` — none; it only carries
  `metaId`/`metaType`/`name`/`poster`/`season`/`episode`/`resume`
  (`src/lib/remote/protocol.ts:220-229`).
- **Passive path:** just sending `playMeta` already triggers the host's entire
  auto-pick machinery under whatever settings/profile are currently active
  (`src/lib/remote/remote-open-bridge.tsx:92-98`, `openPicker(... autoPlay:
  settings.instantPlay ...)`). With `instantPlay` defaulting to `true`
  (`src/lib/settings/defaults.ts:213`), the host auto-picks at its configured
  preference. This is the only "quality control" that needs zero host setup —
  but the phone does not choose the quality; the host's global setting does.
- **UI puppeting path:** `goView`, `nav`, `setText`, `submitText`, `openSearch`
  can drive the host's own UI (including the settings screens and focused text
  fields) (`src/lib/remote/protocol.ts:197-212`;
  `src/lib/remote/session.ts:415-453`). It is not a settings API, it is brittle,
  and PR #1047 explicitly classifies it as "full puppeting of the interface"
  and proposes gating it behind a pairing token and Origin check.

---

## Verdict

| Question | Verdict |
| --- | --- |
| 1. Profile carries filters? | **Yes, only if `settingsLinked: false` (Independent); whole settings bundle.** Default profiles are Shared. |
| 2. `setProfile` immediate? Enforced? | **Async (React effect), no ack, racy with an immediate `playMeta`.** Filters gate autoplay but fall back to all when nothing matches, and are bypassed for host matching. |
| 3. Create/edit over wire? | **No.** Only `setProfile` (switch). Nothing in beta, `main`, #1017, #1031, #1047. |
| 4. Snapshot exposes? | **Active profile identity + full profile list. No filter/settings.** |
| 5. Viable UX? | **Only "profiles as quality presets", with the user pre-creating Independent profiles on Harbor.** Global, persistent, identity-changing side effects. |
| 6. Other settings over wire? | **None** (bandwidth/streamMode/addon/instantPlay). `playMeta` triggers host auto-pick passively; UI puppeting is not an API. |

## Recommendation

**Partially viable — requires host-side setup; infeasible as a client-only
control.**

- **The indirect path is real but not client-only.** The companion cannot create
  or edit filters/profiles/settings (`src/lib/remote/protocol.ts:183-253`), so
  the user must pre-build Independent quality profiles inside Harbor. Only then
  can the app offer them and switch with `setProfile`.
- **It is a preference, not an imposition.** Even with the right profile
  active, Harbor falls back to unfiltered streams when nothing matches
  (`src/views/play-picker.tsx:355-364`) and bypasses the filter during
  host-matched playback. A "4K" profile does not guarantee 4K.
- **Switching a profile is heavyweight.** It is global, persistent, swaps the
  whole settings bundle, and changes watch history/library/language keys
  (`src/lib/settings.tsx:472-491`, `src/lib/profiles.tsx:48-80`). Treating
  profiles as per-play quality buttons is an abuse of their intended meaning.
- **There is a race and no ack.** `setProfile` only swaps settings on a React
  effect; the snapshot's profile identity updates from `localStorage` first
  (`src/lib/settings-profile-bridge.tsx:8-10`, `src/lib/profiles.tsx:491-517`).
  Any UI must wait ≥1 snapshot after switching, and still cannot be sure the
  pipeline re-scored.
- **Low-risk fallback that is worth shipping now:** offer nothing but the
  existing "Play on host" (`playMeta`) and, at most, a read-only display of the
  active quality profile. That already makes Harbor auto-pick at the user's
  desktop-configured preference (`src/lib/remote/remote-open-bridge.tsx:96-98`),
  with zero new failure modes.
- **A true per-play quality control requires an upstream Harbor change** — e.g.
  a `setActiveStreamFilter {id}` / settings command, a richer `playMeta` with a
  filter/quality argument, or the `activeStreamFilterId` added to the 400 ms
  snapshot for read-back. Until then, Harbor Companion should not promise
  per-play quality selection.

## Source index

Beta (`74d73858c4292bdd916804d39d0f1dfa74c545a2`, v0.9.124):

- `src/lib/remote/protocol.ts` — wire types, `RemoteCommand` (`:183-253`),
  `RemoteSnapshot` (`:137-178`), `RemoteProfile` (`:39-44`).
- `src/lib/remote/session.ts` — dispatch and snapshot composition; `setProfile`
  (`:474-478`), `playMeta` (`:454-461`).
- `src/lib/remote/remote-open-bridge.tsx` — `setProfile` → `selectProfile`
  (`:56-63`), `playMeta` → `openPicker` with `autoPlay: settings.instantPlay`
  (`:92-98`).
- `src/lib/settings.tsx` — `switchProfile` bundle swap (`:472-509`),
  `readActiveSource` (`:49-63`).
- `src/lib/settings-profile-bridge.tsx` — active-profile → settings effect
  (`:5-11`).
- `src/lib/settings/profile-store.ts` — per-profile vs shared keys
  (`:5-14, 32-38, 81-84`).
- `src/lib/settings/types.ts` / `defaults.ts` — the quality-affecting fields and
  their defaults.
- `src/lib/profiles.tsx` — `Profile`/`settingsLinked` (`:122-135`),
  `selectProfile` (`:491-517`), profile key prefixes (`:48-80`),
  `createProfile` default Shared (`:543-564`), identity readers (`:295-330`).
- `src/views/settings/account/settings-scope-card.tsx` — Shared vs Independent.
- `src/lib/streams/custom-filters.ts` — filter shape and `matchesCustomFilter`.
- `src/lib/streams/mode.ts` — `filterStreamsByMode` with fallback.
- `src/views/play-picker.tsx` — filter application/fallback (`:331-393`),
  autoplay candidates (`:479-498`).
- `src/views/play-picker/use-auto-candidates.ts` / `use-auto-fire.ts` — autoplay
  ordering and firing.
- `src/lib/streams/scoring/scoring-stream.ts`,
  `scoring-rank.ts`, `scoring-bitrate.ts` — soft scoring.
- `src/lib/streams/episode-pipeline-input.ts` — how settings enter the pipeline.
- `src/lib/profile-sync/types.ts`, `profile-lock.ts` — synced flag + PIN gate.
- `src/lib/addon-store.ts`, `collections.ts`, `custom-lists.ts`,
  `ratings/store.ts`, `i18n/store.ts` — per-profile side-effect keys.

Other branches/PRs:

- `main` (`origin/main`, v0.9.21): smaller wire, no `playMeta`/`setProfile`.
- PR #1017 (`port/manga`, open): ports the beta remote to `main`; adds no
  settings command; omits locked profiles.
- PR #1031 (`feat/persistent-stream-filter`, open, base `main`): port of the
  persistent active-filter feature; adds `src/lib/streams/filter-preference.ts`
  and applies it to auto picks with fallback; no wire command.
- PR #1047 (open): pairing token + Origin check for `/api/remote`; documents
  `nav`/`setText`/`submitText` as full interface puppeting; no settings command.
- PR #950 (open): additive native Flutter client under `clients/`; own stream
  engine; does not change the desktop wire.

Companion (this repo): `lib/app/profile/profile_reducer.dart:10-24` and
`lib/app/ws/client_reducer.dart:99-101` already model `setProfile` and the
`profile`/`profiles` snapshot fields, so the switching half of the UX already
exists client-side.
