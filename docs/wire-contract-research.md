# Harbor Remote-Control Wire Protocol — Primary-Source Research

Source of truth: the Harbor source code only
(https://github.com/harborstremio/harbor), read directly. The **authoritative**
branch for Harbor Companion is **`beta-branch` (v0.9.120)** — that is the host
the app actually connects to. `main` (v0.9.21) was also checked for comparison
(see "Version note"). Every factual claim carries an inline citation (file path
+ line numbers, relative to the Harbor repo). Research date: 2026-09-01.

Scope: answer eight questions that gate whether eight GitHub issues in Harbor
Companion are implementable in the companion app alone, or need upstream Harbor
changes. The app is a pure client of Harbor's remote WebSocket
(`ws://<ip>:11471/api/remote`), so "supported" means "the host wire already
carries it".

## Key finding

Harbor Companion is a **faithful client of `beta-branch`**: the snapshot fields
and commands it models (`library`, `trackers`, `profile`, `profiles`,
`hostVersion`, `tmdbKey`/`rpdbKey`/`tvdbKey`, `textEntry`, `playMeta`, `openMeta`,
`goView`, `setSpeed`, `setSleep`, `setProfile`, `libraryAction`) all exist on the
beta wire (`src/lib/remote/protocol.ts:137-178`, `:183-253`). The earlier reading
against `main` (which lacks all of these) is **not** the app's target.

However, five of the eight requests are **not on the beta wire either** — they
are player/UI capabilities the Harbor desktop app has, but which the remote
protocol does not expose. Those need upstream Harbor changes.

## Command inventory (beta)

Complete `RemoteCommand` union, `src/lib/remote/protocol.ts:183-253`:

`play`, `pause`, `togglePlayback`, `seek`, `setVolume`, `setMuted`, `setTarget`,
`castDiscover`, `castStop`, `prevEpisode`, `nextEpisode`, `toggleSubtitles`,
`nav`, `setText`, `submitText`, `blurText`, `openSearch`, `openMeta`,
`openService`, `goView`, `setSpeed`, `setSleep`, `setProfile`, `playMeta`,
`libraryAction`, `mangaTurnPage` / `mangaSetPage` / `mangaJumpChapter` /
`mangaZoomIn` / `mangaZoomOut` / `mangaSetZoom` / `mangaPan` / `mangaFlipProgress`
/ `mangaFlipEnd` / `mangaSetRtl` / `mangaBookmark` / `mangaJumpBookmark` /
`mangaBookmarkRemove` / `mangaCloseReader`, `ping`.

- **No stream/source-switch command** (no `nextStream`/`setSource`/`setStream`).
- **No audio-track command** and **no subtitle-track selection command** — only
  the coarse `toggleSubtitles` (on = first available track, off = clear;
  `src/lib/remote/session.ts:479-492`).
- `libraryAction` supports `watchlist`/`watched`/`favorite`/`simkl`/`anilist`/`mal`
  ops (`src/lib/remote/library-commands.ts:23-72`).

## Snapshot inventory (beta)

Complete `RemoteSnapshot`, `src/lib/remote/protocol.ts:137-178`: `proto`, `idle`,
`mediaId`, `mediaTitle`, `posterUrl`, `episode` (single `{season,episode,name?}`),
`source` (single `{label,resolution,quality,releaseGroup}`), `positionSec`,
`durationSec`, `playing`, `volume`, `muted`, `target`, `castDevices`,
`castDiscovering`, `hasPrevEpisode`, `hasNextEpisode`, `subtitlesOn`,
`canToggleSubtitles`, `textEntry`, `profile`, `profiles`, `tmdbKey`, `rpdbKey`,
`tvdbKey`, `tmdbLanguage`, `tmdbImageLangs`, `translateTitles`,
`translateDescriptions`, `hostVersion`, `library`, `trackers`, `manga`,
`updatedAt`.

- `library` = `{ watchlist, history, favorites, local, mediaServers }`, each a
  list of `RemoteLibraryItem` = `{ id, type, tmdbId?, imdbId?, name?, poster?,
  background?, local?, mediaServerProviders? }` (`protocol.ts:46-64`). **No
  episode/season fields on a library item** — history is media/series-level, not
  episode-granular.
- `trackers` = `{ trakt, simkl, stremio, anilist, mal }` booleans
  (`protocol.ts:66-72`). No Letterboxd / catalog data.
- **No list of streams**, **no list of episodes/seasons**, **no audio/subtitle
  track lists** — only the single current `episode`, the single `source`, and the
  two derived subtitle booleans.

## Issue verdicts (beta)

| Issue | Verdict | Evidence |
| --- | --- | --- |
| #31 autoplay / next episode | **(a) wire supports it** — `nextEpisode` command + `hasNextEpisode` flag (`protocol.ts:194-195,154`). Autoplay is host-player behavior, not a wire concern. | — |
| #32 history episode granularity | **(b) needs upstream** — `RemoteLibraryItem` has no episode/season fields; history is media-level (`protocol.ts:46-56`). | — |
| #34 openSearch | **(a) wire supports it** — `openSearch` opens host search **and focuses its field** (`session.ts:437-453`), which pushes `textEntry`. The app already sends `openSearch`; the gap is that the app's text field doesn't auto-focus (keyboard doesn't open). | — |
| #35 volume semantics | **(a) wire supports it** — snapshot carries the host's actual `volume` (`session.ts:389`); `setVolume` clamps 0..1 (`session.ts:583-592`). No reset in the remote layer. | — |
| #36 stream/source switching | **(b) needs upstream** — no such command (`protocol.ts:183-253`), no streams list (`protocol.ts:137-178`). | — |
| #37 episode/season list | **(b) needs upstream** — snapshot has only the single current `episode` (`protocol.ts:143`). | — |
| #38 audio/subtitle track selection | **(b) needs upstream** — only `toggleSubtitles` (`session.ts:479-492`); track selection exists in the player bridge but is not on the wire. | — |
| #41 Letterboxd / catalogs | **(b) needs upstream** — remote exposes no catalogs; `library`/`trackers` have no Letterboxd (`protocol.ts:58-72`). | — |

Overall: **3 of 8** (#31, #34, #35) are already on the beta wire (two are bugs to
reproduce, one is a client auto-focus gap); **5 of 8** (#32, #36, #37, #38, #41)
need upstream Harbor (beta) changes.

## App vs. beta gaps (not part of the 8 issues)

The app models an earlier beta and is missing newer beta surface: `manga*`
commands + `manga` snapshot, `openService`, `togglePlayback`, the
`library.local`/`library.mediaServers` sections, `RemoteLibraryItem.tmdbId`/
`imdbId`/`local`/`mediaServerProviders`, `tmdbLanguage`/`tmdbImageLangs`/
`translateTitles`/`translateDescriptions`, the extra `RemoteCastDevice` fields
(`host`/`port`/`model`/`controlUrl`/`audioOnly`), and the `simkl`/`anilist`/`mal`
`libraryAction` ops.

## Version note

- `beta-branch` (`package.json` version `0.9.120`) is the authoritative wire and
  matches the app's model. Files: `src/lib/remote/protocol.ts`,
  `src/lib/remote/session.ts`, `src/lib/remote/library-commands.ts`.
- `main` (`0.9.21`) has a *smaller* wire — no `library`/`trackers`/`profile`/
  `hostVersion`/keys and no `playMeta`/`libraryAction`/`setSpeed`/etc. The app
  must be used with `beta-branch`, not `main`.

## Source index

- `src/lib/remote/protocol.ts` — wire types, `RemoteCommand` union, `RemoteSnapshot`, defaults (beta).
- `src/lib/remote/session.ts` — command dispatch + snapshot composition (beta).
- `src/lib/remote/library-commands.ts` — `libraryAction` handlers (beta).
- Harbor Companion `lib/app/ws/client_reducer.dart` — the app's wire model, for contrast.
