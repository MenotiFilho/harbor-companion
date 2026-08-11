# Harbor Beta Remote — Pinned Wire Contract

Source of truth: Harbor `beta-branch`, **v0.9.117**, commit **c0ebfd1f**
(`harborstremio/harbor`, shallow-cloned at `/tmp/opencode/harbor-beta`).

This document pins the exact wire contract between a **phone/remote client** and a
Harbor **host** (the desktop app). An engineer should be able to build a native
remote client from this document alone. Every shape, constant, and behavior below
is cited to `src/…`/`src-tauri/…` in the beta source so claims can be re-verified.

- Host side of the WS + HTTP server: `src-tauri/src/web_server.rs`
- Shared protocol types + helpers: `src/lib/remote/protocol.ts`
- Host snapshot/command hub: `src/lib/remote/host-mount.tsx`
- Host playback/session state: `src/lib/remote/session.ts`
- Host manga state: `src/lib/remote/manga-session.ts`
- Reference client (browser): `src/lib/remote/use-remote-client.ts`
- Reference mobile web UI: `src/views/mobile/*`, `src/views/remote-app.tsx`

---

## 1. Connection

### 1.1 Endpoint

- WebSocket URL: `ws://<host-ip>:11471/api/remote`
  - `REMOTE_WS_PATH = "/api/remote"` — `protocol.ts:2`
  - `WEB_PORT = 11471` — `protocol.ts:3`, and the Rust `pub const WEB_PORT: u16 = 11471` — `web_server.rs:16`
  - The client builds the URL as `ws` or `wss` depending on the page protocol (`remoteWsUrl`, `protocol.ts:293-296`). For a LAN native client this is always `ws://<ip>:11471/api/remote`.
- The WS is served by the Tauri web server, which binds **`0.0.0.0:11471`** (all interfaces, so the phone reaches it over Wi-Fi): `web_server.rs:307-309`.
- Router: only two real routes exist — `/api/remote` (WS) and `/manga-img` (image proxy); everything else falls back to the SPA handler — `web_server.rs:322-326`.

### 1.2 Handshake

Client → server, **immediately on open** (exact shape):

```json
{ "t": "hello", "client": "harbor-remote", "proto": 1 }
```

- `REMOTE_PROTO = 1` — `protocol.ts:1`
- `RemoteClientMessage` union: `{ t: "cmd"; command } | { t: "hello"; client: "harbor-remote"; proto: number }` — `protocol.ts:250-252`
- Reference client sends it in `ws.onopen` — `use-remote-client.ts:98-104`.

Server → client, in reply (exact shape):

```json
{ "t": "hello", "proto": 1, "server": "harbor-remote" }
```

- `RemoteServerMessage` union: `{ t: "snapshot"; snapshot } | { t: "hello"; proto; server: "harbor-remote" } | { t: "pong"; at: number } | { t: "error"; message: string }` — `protocol.ts:244-248`
- The host replies to the client `hello` with its own `hello` + an immediate snapshot — `host-mount.tsx:298-301`.
- The host also broadcasts a `hello` + snapshot whenever a client **joins** (server-side `remote://client` "join" event) — `host-mount.tsx:341-349`. In practice the phone can rely on snapshots arriving without waiting for `hello`.
- Any unrecognized client frame that still parses to an object with a `t` field but isn't `hello`/`cmd` is answered with `{ "t": "error", "message": "invalid message" }` — `host-mount.tsx:290-297`. Unparseable JSON is silently dropped (`parseClientMessage`, `protocol.ts:283-291`).

### 1.3 No-auth status

- **The WS is completely unauthenticated.** There is no token, no origin check, no TLS, and no authentication handshake anywhere in `handle_remote_socket` (`web_server.rs:247-300`). Any device on the LAN that can reach `:11471` can connect and issue every command below.
- It is gated only by a UI toggle: the server runs when `settings.serveWebUi || settings.remoteControlEnabled` is on — `host-mount.tsx:253-254`, `remotes-panel.tsx:43` (defaults are both `false` — `settings/defaults.ts:91-92`).
- Because of the no-auth design, the server also **ships the host's TMDB/RPDB/TVDB keys inside every snapshot** to the phone (see §2.2). Anyone on the LAN can read them.

---

## 2. Messages

The wire is text frames, one JSON value per frame. Client sends `{ t: "cmd", command }` (`protocol.ts:250-252`). Server sends snapshots, `hello`, `pong`, or `error`.

### 2.1 `RemoteSnapshot` (server → client, the whole state of the host)

Exact type — `protocol.ts:131-168`:

```ts
type RemoteSnapshot = {
  proto: number;                 // REMOTE_PROTO (1)
  idle: boolean;                 // true = nothing playing / no player mounted
  mediaId: string | null;
  mediaTitle: string | null;
  posterUrl: string | null;
  episode: RemoteEpisodeRef | null;   // { season, episode, name? } — protocol.ts:5-9
  source: RemoteSourceInfo | null;    // { label, resolution, quality, releaseGroup } — protocol.ts:26-31
  positionSec: number;
  durationSec: number;
  playing: boolean;
  volume: number;                // 0..1
  muted: boolean;
  target: RemoteTarget;          // { kind: "local"; label } | { kind: "cast"; deviceId; label; castKind } — protocol.ts:22-24
  castDevices: RemoteCastDevice[];    // id,name,kind,host,port,model?,controlUrl?,audioOnly? — protocol.ts:11-20
  castDiscovering: boolean;
  hasPrevEpisode: boolean;
  hasNextEpisode: boolean;
  subtitlesOn: boolean;          // a subtitle track is selected on the local player
  canToggleSubtitles: boolean;   // local player has ≥1 subtitle track and isn't casting
  textEntry: RemoteTextEntry | null;  // { value, placeholder } when a host field is focused — protocol.ts:34-37
  profile: RemoteProfile | null;      // active profile { id?, name, avatar, color } — protocol.ts:39-44
  profiles: RemoteProfile[];          // all profiles for who's-watching
  tmdbKey?: string;              // host metadata keys, piped to a keyless phone
  rpdbKey?: string;
  tvdbKey?: string;
  hostVersion?: string;          // APP_VERSION — session.ts:302
  library?: RemoteLibrary;       // { watchlist, history, favorites } — protocol.ts:54-58
  trackers?: RemoteTrackers;     // { trakt, simkl, stremio, anilist, mal } booleans — protocol.ts:60-66
  manga?: RemoteMangaState | null;    // null when no manga reader is open
  updatedAt: number;
};
```

Where `RemoteLibraryItem = { id, type, name?, poster?, background? }` — `protocol.ts:46-52`.

`RemoteMangaState` — `protocol.ts:108-129`:

```ts
type RemoteMangaState = {
  open: boolean;
  seq: number;                  // increments on every registerRemoteManga — manga-session.ts:68
  mangaId: string;
  title: string;
  cover: string | null;
  chapterId: string;
  chapterIndex: number;
  chapterLabel: string;
  pageIndex: number;
  pageCount: number;
  spread?: number[];            // page pairs in book/double mode
  pageUrls?: string[];          // absolute http(s) page image URLs — client proxies them through /manga-img
  zoom: number;
  canZoom: boolean;
  rtl: boolean;
  mode: "long" | "paged" | "double" | "book";
  hasPrev: boolean;
  hasNext: boolean;
  chapters: RemoteMangaChapter[];  // { id, index, label, chapter?, title?, group?, sourceId?, sourceName?, downloaded? } — protocol.ts:86-96
  bookmarks: RemoteMangaBookmark[]; // { id, chapterId, chapterLabel, page, totalPages, name, createdAt } — protocol.ts:98-106
};
```

Notes on snapshot composition:

- `manga` is **not** part of `buildRemoteSnapshot`; the host appends it at broadcast time — `host-mount.tsx:52-57` calling `buildRemoteMangaState()` (`manga-session.ts:76-112`).
- `library` is only present when a library is being served (`...remoteLibrary ? { library } : {}`) — `session.ts:303`. `trackers`, `tmdbKey`, `rpdbKey`, `tvdbKey`, `hostVersion` are always set on a live snapshot — `session.ts:296-306`.
- The idle snapshot that initializes the reference client includes `proto: 1, idle: true, target: { kind: "local", label: "This PC" }, volume: 1` etc. — `idleSnapshot`, `protocol.ts:254-281`. Treat `updatedAt` as the monotonic clock for coalescing.

### 2.2 `RemoteCommand` variants (client → server), every variant and its payload

Exact union — `protocol.ts:173-242`. The phone wraps these as `{ t: "cmd", command }`.

Playback transport:

```ts
{ action: "play" }
{ action: "pause" }
{ action: "seek"; positionSec: number }
{ action: "setVolume"; volume: number }        // clamped 0..1 — session.ts:543
{ action: "setMuted"; muted: boolean }
{ action: "setTarget"; target: "local" | { castDeviceId: string } }
{ action: "castDiscover" }                      // re-scan; host sets castDiscovering true then false — host-mount.tsx:306-317
{ action: "castStop" }                          // stop cast, preferredTarget → local — session.ts:465-470
{ action: "prevEpisode" }
{ action: "nextEpisode" }
{ action: "toggleSubtitles" }                   // local player only — session.ts:451-464
```

Navigation & text (drive the host's TV focus / search field):

```ts
{ action: "nav"; key: RemoteNavKey }            // "up"|"down"|"left"|"right"|"select"|"back" — protocol.ts:171
{ action: "setText"; value: string }            // replace focused host text field — session.ts:399-402
{ action: "submitText"; value?: string }        // optional flush + Enter — session.ts:403-407
{ action: "blurText" }                          // disarm typing without host Back — session.ts:408-412
{ action: "openSearch" }                        // dispatch harbor:open-search + focus field — session.ts:413-429
```

Title / navigation (dispatched as `harbor:remote-open` CustomEvent → `RemoteOpenBridge`) — `session.ts:430-437`, `remote-open-bridge.tsx:48-76`:

```ts
{ action: "openMeta"; metaId: string; metaType: string; name?: string; poster?: string }
{ action: "openService"; service: string }              // e.g. streaming service id
{ action: "goView"; view: string }                      // root view name
{ action: "playMeta"; metaId: string; metaType: string;
  name?: string; poster?: string;
  season?: number; episode?: number; resume?: boolean }
```

Player misc:

```ts
{ action: "setSpeed"; speed: number }
{ action: "setSleep"; minutes: number }         // 0 clears — session.ts:442-445
{ action: "setProfile"; id: string }            // who's-watching — session.ts:446-450
{ action: "ping" }                              // host replies { t: "pong", at: Date.now() } — host-mount.tsx:318-321
```

Library actions — handled by `runLibraryAction` (`library-commands.ts:23-71`):

```ts
{ action: "libraryAction";
  metaId: string; metaType: string; name?: string; poster?: string; imdbId?: string | null;
  op: RemoteLibraryAction }
```

`RemoteLibraryAction` — `protocol.ts:78-84`:

```ts
{ kind: "watchlist"; on: boolean }
{ kind: "watched"; on: boolean }
{ kind: "favorite"; on: boolean }
{ kind: "simkl"; status: SimklWatchStatus | null }   // "watching"|"plantowatch"|"hold"|"completed"|"dropped" — protocol.ts:68
{ kind: "anilist"; status: AnilistWatchStatus | null } // "CURRENT"|"PLANNING"|"COMPLETED"|"REPEATING"|"PAUSED"|"DROPPED" — protocol.ts:69-75
{ kind: "mal"; status: MalWatchStatus | null }        // "watching"|"plan_to_watch"|"completed"|"on_hold"|"dropped" — protocol.ts:76
```

Manga commands — routed to `dispatchMangaCommand` when `action.startsWith("manga")` (`host-mount.tsx:322-325`, `manga-session.ts:72-74`):

```ts
{ action: "mangaTurnPage"; dir: "next" | "prev" }
{ action: "mangaSetPage"; page: number }
{ action: "mangaJumpChapter"; index: number }        // bounds-checked — manga-session.ts:125
{ action: "mangaZoomIn" }                            // +0.1
{ action: "mangaZoomOut" }                           // -0.1
{ action: "mangaSetZoom"; zoom: number }             // clamped 0.5..3 — manga-session.ts:46-49
{ action: "mangaPan"; dx: number; dy: number }
{ action: "mangaFlipProgress"; p: number }
{ action: "mangaFlipEnd"; commit: boolean; dir: "next" | "prev" }
{ action: "mangaSetRtl"; rtl: boolean }
{ action: "mangaBookmark"; page?: number }
{ action: "mangaJumpBookmark"; id: string }
{ action: "mangaBookmarkRemove"; id: string }
{ action: "mangaCloseReader" }
```

### 2.3 Command dispatch rules (host)

- `ping` and `castDiscover` return without a follow-up snapshot — `session.ts:384-386`, `host-mount.tsx:306-317` (castDiscover pushes its own snapshot after the scan).
- After every **other** command, the host pushes a fresh snapshot — except `nav`, `setText`, and `ping`, which are in `SKIP_SNAPSHOT` (their effects are covered by focus events + the 400ms tick) — `host-mount.tsx:59`, `host-mount.tsx:326-328`.
- Manga commands never trigger an immediate snapshot; the host's manga/bookmark subscriptions coalesce pushes to one snapshot per animation frame — `host-mount.tsx:322-325`, `host-mount.tsx:352-361`.
- A thrown command handler produces `{ t: "error", message }` plus a snapshot — `host-mount.tsx:329-333`.
- `setVolume` clamps to `[0,1]` and auto-unmutes when raising from muted — `session.ts:541-550`. `seek` clamps at 0 — `session.ts:534-540`.

---

## 3. Snapshot cadence & size

### 3.1 Cadence

- The host pushes a snapshot on a hard **400ms `setInterval`** while the remote plane is enabled — `host-mount.tsx:389-393`.
- **Immediate pushes** also happen on: client join/hello (`host-mount.tsx:298-301`, `host-mount.tsx:341-349`), after any non-SKIP command (`host-mount.tsx:328`), on `castDiscover` completion (`host-mount.tsx:315`), on any remote-session subscription change (`host-mount.tsx:351`), on `focusin`/`focusout` (text entry), on text-entry listener events (`host-mount.tsx:371-378`), on library/trackers/key changes (`host-mount.tsx:265-282`), and on manga state/bookmark changes (coalesced to one per rAF — `host-mount.tsx:352-361`).
- **`positionSec` during playback is supplied by the playback clock at push time** (`pushSnapshot` passes `getPlaybackPosition()`) so the 400ms tick is enough for a smooth progress bar — `host-mount.tsx:52-56`. When casting, position comes from the cast session — `session.ts:331-333`.

### 3.2 The heavy payload gotcha

Every snapshot is the **entire host state, re-sent up to 2.5×/second to every connected client**, and snapshots are broadcast to **all** clients on one shared channel (`broadcast::channel`, `web_server.rs:313`; the per-command immediate push goes to every socket too). It routinely contains:

- **Library**: up to `LIBRARY_CAP = 60` items **per section** (`host-mount.tsx:61`, applied in `capped`, `host-mount.tsx:91-96`) → **up to 180 items** across `watchlist` + `history` + `favorites`, each with `id/type/name/poster/background`. On a big Stremio watchlist this snapshot can be tens to hundreds of KB.
- **Profiles**: every profile's `{id, name, avatar, color}` is included — `session.ts:375`.
- **Manga**: if the reader is open, the snapshot includes `chapters`, `bookmarks`, and `pageUrls` arrays — `manga-session.ts:90-111`.
- Plus cast devices, keys, tracker flags, text-entry, and host version.

**On-device implication:** a native client **must throttle/coalesce** — do not re-render or re-encode on every frame. The reference browser client keeps the last snapshot in state (`use-remote-client.ts:109`) and the UI already tolerates drops; a native client should do the same and diff on `updatedAt`/`seq`. Also note each **command reply** triggers an extra full snapshot, so bursts are normal after any interaction.

---

## 4. Playback initiation — the `playMeta` flow

The phone **never resolves streams** and **never fetches stream/player URLs**. All playback is initiated on the host.

1. Phone sends `{ t: "cmd", command: { action: "playMeta", metaId, metaType, name?, poster?, season?, episode?, resume? } }` — the reference app always sends `resume: true` unless a caller overrides it — `mobile-remote.tsx:53-68` (`playOnHost`).
2. The host's `dispatchRemoteCommand` dispatches `harbor:remote-open` with the command — `session.ts:430-437`.
3. `RemoteOpenBridge` (host-side, mounted in the desktop shell) listens and calls `openPicker(meta, episode, { autoPlay: true, resume: d.resume ?? true })` — `remote-open-bridge.tsx:70-72`.
   - `metaId`/`metaType` are mapped to a lightweight `Meta`; `metaType` is coerced to `"movie" | "series" | "anime"` (`toMeta`, `remote-open-bridge.tsx:23-30`). For `openMeta`, `person:<id>` ids open the person page instead (`remote-open-bridge.tsx:60-64`).
4. `openPicker` pushes a `picker` frame onto the host nav stack with `autoPlay`, `resume`, and optional `episode` (`season`/`episode`) — `view.tsx:1055-1100`. With `autoPlay`, the picker auto-selects and the `resume` flag is threaded into the pick pipeline (`use-pick-handler.ts:33,62,310`) so the host resumes from the stored position.
5. Season/episode deep-linking: the phone computes the episode ref itself — the detail view plays the first episode via `firstEpisode` (`mobile-detail/data.ts:99-112`, `mobile-detail/detail.tsx:159-162`), and tapping a specific episode sends `season` + `episode` (`mobile-detail/episodes.tsx:204`).
6. Once playing, the phone just renders snapshots (Now Playing) — `remote-app.tsx:421-754` (the `useRemoteSurfaceMode` idle/browse toggle, `remote-app.tsx:136-149`).

**Contract consequences:** the phone only needs to know `metaId` (imdb id `tt…`, or `kitsu:`/`mal:`/`tmdb:` prefixed), `metaType`, an optional `name`/`poster`, and for series a `season`+`episode`. It never needs streams, addon stream endpoints, or the host's stream resolution.

---

## 5. Data endpoints for catalog / meta / search

The beta mobile web fetches catalog/meta/search **directly from the internet from the phone's browser**. On the LAN build there is **no proxy**: `safeFetch` only rewrites to `/api-proxy/...` when the page is served from `*.harbor.site` and the target host is proxiable (`safe-fetch.ts:62-85`, `safe-fetch.ts:71-74`); on `http://<ip>:11471` the hostname check fails and requests go straight to the upstream (final `fetch(r.url, r.init)`, `safe-fetch.ts:198-201`). All the endpoints below are public/CORS-open and work from a native client.

### 5.1 Cinemeta (no key required)

Base: `https://v3-cinemeta.strem.io` — `cinemeta.ts:3`.

Catalog (top/trending, optional genre and skip):

```
GET https://v3-cinemeta.strem.io/catalog/{movie|series}/top.json
GET https://v3-cinemeta.strem.io/catalog/{movie|series}/top/genre=<Genre>.json
GET https://v3-cinemeta.strem.io/catalog/{movie|series}/top/genre=<Genre>/skip=<N>.json
```

- Path construction — `cinemetaTopPath`, `cinemeta.ts:71-76`; genre is URL-encoded (`encodeURIComponent`).
- Response: `{ "metas": Meta[] }` — `catalog()`, `cinemeta.ts:64-69`.
- Known genres used by the app: `Action, Drama, Comedy, Sci-Fi, Thriller, Horror, Romance, Animation, Adventure, Crime, Mystery, Fantasy, Documentary, Family, War, Western` (`mobile-search.tsx:38-55`), and for series `Drama, Comedy, Crime` (`home-rows.ts:93-95`).

Meta (detail, includes `videos[]` with season/episode info):

```
GET https://v3-cinemeta.strem.io/meta/{movie|series}/{id}.json
```

- `meta()`, `cinemeta.ts:93-103`. Response: `{ "meta": Meta | null }`.

Search (cinemeta fallback when no TMDB key):

```
GET https://v3-cinemeta.strem.io/catalog/{movie|series}/top/search=<encoded query>.json
```

- `searchCinemeta`, `search.ts:236-248`; results capped to 12 per kind.

### 5.2 TMDB (needs the host's `tmdbKey`)

The phone's TMDB browsing requires a key. The host pipes its own key into every snapshot (`tmdbKey`, `session.ts:296-306`), and the reference phone **writes that key into its own per-origin settings** the moment it receives a snapshot — `mobile-remote.tsx:26-43`. A native client should do the same (persist `snapshot.tmdbKey` and use it for all TMDB calls).

Base & image host:

```
https://api.themoviedb.org/3     // TMDB — tmdb-client.ts:4
https://image.tmdb.org/t/p       // IMG — tmdb-client.ts:5
```

Auth: `api_key` is sent as a query param on every request — `get()`, `tmdb-client.ts:96-107`. Optional `language` param is added when set. All responses are read as `{ results: [...] }` pages (`Page<T>`).

Endpoints used by the mobile web (all `tmdb-catalogs.ts`, `search.ts`):

- `movie/{popular|top_rated|now_playing|upcoming}` — `tmdbMovieRow`, `tmdb-catalogs.ts:11-23` (adds `region`).
- `tv/{popular|top_rated|airing_today|on_the_air}` — `tmdbSeriesRow`, `tmdb-catalogs.ts:40-47`.
- `trending/{movie|tv}/{day|week}` — `tmdbTrending`, `tmdb-catalogs.ts:49-62`.
- `discover/movie` and `discover/tv` — `tmdbDiscover`, `tmdb-catalogs.ts:64-75`. Used heavily: in-theaters window (`tmdb-catalogs.ts:25-38`), "now on a service" (with `with_watch_providers`, `watch_region`, `with_watch_monetization_types`, `sort_by`, `include_adult` — `mobile-service-page.tsx:47-56`), and explore rows (`mobile-search.tsx:123-132`).
- `search/multi` — primary search — `searchAll`, `search.ts:263-266`; plus `search/movie` / `search/tv` (title resolution, `tmdb-catalogs.ts:77-109`) and `search/person` fallback (`search.ts:407-411`).
- `tv/{id}/season/{n}` — `tmdbSeasonEpisodes` (used to build the mobile episode list — `mobile-detail/episodes.tsx:119`).
- Full detail (`tmdbDetails`, `tmdb-details.ts`), collections (`tmdbCollection`, `tmdb-collections`), and watch-provider data are also used on the phone; all follow the same `api_key` pattern.

### 5.3 Jikan (anime)

Base: `https://api.jikan.moe/v4` — `jikan.ts:5`.

```
GET /seasons/now?page=N          // jikanAiringNow — jikan.ts:358
GET /seasons/upcoming?page=N     // jikanUpcoming — jikan.ts:359
GET /top/anime?page=N            // jikanTopAnime — jikan.ts:360
GET /top/anime?filter=airing     // jikanTopAiring — jikan.ts:361
GET /top/anime?filter=bypopularity // jikanTopPopular — jikan.ts:362
GET /top/anime?type=movie        // jikanTopMovies — jikan.ts:363
GET /top/anime?type=tv           // jikanTopTv — jikan.ts:364
GET /anime?order_by=start_date&sort=desc&status=airing&min_score=6&page=N   // jikanNewReleases — jikan.ts:365-372
GET /anime?genres=<id>&order_by=score&sort=desc&min_score=7&sfw=true&page=N // jikanByGenre — jikan.ts:393-401
GET /anime?q=<title>&limit=1&sfw=true               // jikanResolveMalId — jikan.ts:410-425
GET /anime?q=<title>&limit=N&sfw=true&order_by=popularity&sort=asc  // jikanAnimeSearch — search.ts:126-151
GET /anime/{malId}/recommendations                    // jikan.ts:427-448
```

- Responses: `{ data: JikanAnime[] }` — `jikan.ts:335-336`; Jikan anime maps to a `Meta` (anime ids become `kitsu:<id>` when a Kitsu id is resolvable via `https://relations.yuna.moe/api/ids`, else `mal:<id>` — `jikan.ts:210-216`).
- **Jikan is rate-limited (HTTP 429).** The reference client serializes requests (≥400ms apart) with exponential backoff and a 4-attempt cap — `jikan.ts:285-348`. A native client must implement equivalent throttling or it will get hammered.

### 5.4 Addon catalogs (user-installed content)

The phone gets the user's addon list from the Stremio API:

```
POST https://api.strem.io/api/addonCollectionGet
     { "authKey": "<stremio auth key>", "type": "user", "update": false }
```

- `userAddons`, `addons.ts:128-135` (`STREMIO_API = "https://api.strem.io/api"` — `addons.ts:5`). Response: `{ "result": { "addons": Addon[] } }` — `call()`, `addons.ts:113-126`.

Each addon has a `transportUrl` (its `manifest.json` URL). Catalog content is fetched straight from the addon:

```
GET <base>/catalog/{type}/{id}.json
GET <base>/catalog/{type}/{id}/{extra=value&...}.json        // required extras — addons.ts:333-339
GET <base>/catalog/{type}/{id}/{extra=value&...}/{skip=N}.json  // paging — fetchAddonCatalogPage, addons.ts:421-440
GET <base>/meta/{type}/{id}.json                              // fetchAddonMeta, addons.ts:410-419
```

where `<base>` = `transportUrl` with the trailing `/manifest.json` stripped — `addons.ts:357`. Response is `{ "metas": Meta[] }` (or `{ "meta": Meta }`). Paging is by `skip`, not page number — the fetcher computes `skip = loaded` or `(page-1)*step` — `addons.ts:444-456`.

**The Stremio `authKey` is NOT piped through the wire.** The snapshot carries only `tmdbKey/rpdbKey/tvdbKey` (`protocol.ts:160-162`); the host never sends its Stremio auth key. So a native phone client must obtain its own `authKey` (the mobile web signs the user into Stremio on its own origin and persists per-origin in `localStorage`, `harbor.auth.<profile>` — `auth.tsx:22,32,44`). Without a key, `addonCollectionGet` returns nothing and the phone falls back to Cinemeta/TMDB rows (exactly what `mobile-home.tsx:41-50` does).

### 5.5 CORS openness

All of the above are called **directly from the phone's origin** in the beta mobile web and succeed in browsers, i.e. Cinemeta, TMDB (with `api_key`), Jikan, and addon endpoints serve permissive CORS headers. The app's `safeFetch` falls through to plain `fetch` on the LAN host (no `isTauri`, no `harbor.site`) — `safe-fetch.ts:62-85`, `safe-fetch.ts:198-201`. A native client has no CORS constraint at all.

---

## 6. Gotchas

- **No `/api-proxy` on the LAN server.** The Tauri web server has exactly two real routes (`/api/remote`, `/manga-img`) and a catch-all `serve_http` fallback that serves the SPA `index.html` for **every** unmatched path (`web_server.rs:44-51`, `web_server.rs:322-326`, `web_server.rs:226-238`). If a native client (or a browser tab) calls anything like `/api-proxy/…` or any other "API-looking" path against `:11471`, it gets back HTML, not a proxy response. The `/api-proxy` rewrite only exists when the app is hosted at `*.harbor.site` (`safe-fetch.ts:52-85`). On the LAN you must hit upstream services directly.
- **`/manga-img` proxy blocks private hosts.** `GET /manga-img?u=<url>` proxies the image and returns `Access-Control-Allow-Origin: *` with a 1-day cache — `web_server.rs:169-224`. But `blocked_host` refuses URLs whose host is `localhost`, `127.*`, `0.*`, `10.*`, `192.168.*`, `169.254.*`, `[::1]`, or `172.16-31.*` — `web_server.rs:149-167`. Manga sources on private IPs (e.g. a Suwayomi server on your LAN) will be rejected with HTTP 400 from this endpoint. The phone renders manga images by proxying `pageUrls` through `/manga-img?u=…` (`manga-read/local-reader-types.ts:9-11`, `proxied-img.tsx:37`).
- **Unauthenticated WS exposes keys.** Any LAN peer can connect to the WS and receive the host's TMDB/RPDB/TVDB keys inside snapshots (`protocol.ts:160-162`, `web_server.rs:247-300`). Treat this contract as LAN-trust-only. The phone should also expect the host to change keys and re-apply them from every snapshot (`mobile-remote.tsx:26-43`).
- **Per-origin localStorage on the web UI.** The phone's web UI stores settings, auth (`harbor.auth.<profile>` — `auth.tsx:22`), and caches (Jikan catalog `harbor.jikancatalog2` — `jikan.ts:234`) in `localStorage` **scoped to the `http://<ip>:11471` origin**. On a native client there is no origin: you own the key lifecycle yourself and must NOT assume a key the host once sent stays valid.
- **Mobile browsers freeze timers / kill sockets in background.** The reference client tears down and re-opens the WS on visibility/freeze events and never retries while hidden — `use-remote-client.ts:23-27`, `use-remote-client.ts:145-217`. Reconnect uses exponential backoff 400ms → 3000ms (`use-remote-client.ts:14-15`, `use-remote-client.ts:131-137`).
- **Do not spam `castDiscover`.** The reference client explicitly does NOT cast-discover on connect or reconnect — concurrent discovery storms have hard-crashed hosts (heap corruption) — `use-remote-client.ts:102-104`.
- **Snapshot flood after commands.** Every command (except `nav`/`setText`/`ping`) triggers an immediate full snapshot on top of the 400ms tick (`host-mount.tsx:326-328`). A client that round-trips commands rapidly will receive a wall of multi-KB frames; coalesce.
- **Sticky "now playing" through episode hops.** The host holds the last media for up to `STICKY_CLEAR_MS = 1200ms` during episode/autoplay hops so the remote doesn't flash idle (`session.ts:91-92`, `session.ts:119-179`). A client should not thrash its UI when `idle` flaps briefly during a hop.
- **Idle target/label:** when idle, `target` stays as the last preferred target and label is `"This PC"` for local (`protocol.ts:268`, `session.ts:81`).

---

## 7. V1 implementation checklist

Derived from the pinned contract. Implement bottom-up; each group is independently testable against a live host.

### WS client
- [ ] Connect to `ws://<ip>:11471/api/remote` (allow user-configured host; default port `11471`).
- [ ] On open, send `{ t: "hello", client: "harbor-remote", proto: 1 }`.
- [ ] Read frames; handle `snapshot`, `hello`, `pong`, `error` (`protocol.ts:244-248`).
- [ ] JSON-parse tolerant: drop unparseable frames; reply to `{ t: "error", message: "invalid message" }` only as server→client.
- [ ] Exponential backoff reconnect (400ms→3000ms); skip retries while app is backgrounded.
- [ ] Coalesce snapshot updates on `updatedAt`/`seq`; never re-render on every frame.
- [ ] Persist `snapshot.tmdbKey/rpdbKey/tvdbKey` into your client's key store; re-apply on every snapshot.
- [ ] No `castDiscover` on connect/reconnect.

### Home / catalog
- [ ] Cinemeta top rows + genres (`/catalog/{movie|series}/top[/genre=X[/skip=N]].json`).
- [ ] If a TMDB key is available, TMDB rows: `trending/{movie|tv}/{week|day}`, `movie/{popular|top_rated|now_playing|upcoming}`, `tv/{popular|top_rated|on_the_air}`, `discover/*`.
- [ ] Fall back to Cinemeta when the key is absent (`mobile-home.tsx:41-50`).
- [ ] Detail page: Cinemeta `meta/{type}/{id}.json` (+ `videos[]` for seasons/episodes) and TMDB detail/season episodes when keyed.

### Search
- [ ] Primary: TMDB `search/multi` (+ `search/movie`, `search/tv`, `search/person` fallback) when keyed.
- [ ] Fallback: Cinemeta `catalog/{type}/top/search=<q>.json` per type.
- [ ] Anime: Jikan `/anime?q=…` with serialized requests + 429 backoff (≥400ms spacing).
- [ ] Show results as `Meta` rows; tapping opens detail or plays via `playMeta`.

### Library
- [ ] Render `snapshot.library.watchlist|history|favorites` directly from snapshots (no fetch).
- [ ] Show a "not connected" empty state when the WS is down.
- [ ] Send `libraryAction` with the right `op` for watchlist/watched/favorite toggles (`library-commands.ts:27-45`).
- [ ] Prefer `openMeta`/`playMeta` over re-fetching detail; the phone never fetches streams.

### Playback
- [ ] Now Playing from snapshots: idle↔playing, progress from `positionSec/durationSec`, volume/mute, episode nav from `hasPrevEpisode/hasNextEpisode`, renderer picker from `target`/`castDevices`/`castDiscovering`.
- [ ] Commands: `play/pause/seek/setVolume/setMuted/setTarget/setSpeed/setSleep/toggleSubtitles/prevEpisode/nextEpisode/castDiscover/castStop`.
- [ ] `playMeta` for playback initiation: include `metaId`, `metaType`, optional `name`/`poster`, `season`+`episode` for series, `resume: true` default.
- [ ] Nav/text: `nav` keys, `setText/submitText/blurText`, `openSearch`; react to `textEntry` by showing a typing UI.
- [ ] Manga (optional): render `manga.*`; send `manga*` commands; proxy page images through `/manga-img?u=…` (mind the private-host block).

### Connect
- [ ] Connection screen: host IP entry; status `idle|connecting|connected|error` (`use-remote-client.ts:12`).
- [ ] After connect, first snapshot arrives automatically (hello → hello+snapshot, join → hello+snapshot).
- [ ] Show the host-version (`hostVersion`) and renderer (`target.label`) in the header.
- [ ] On disconnect, keep last snapshot visible for ~1.2s before dropping to idle UI (sticky behavior).

---

## Wire contract vs. what's easy to get wrong

| Contract | Common mistake |
| --- | --- |
| Snapshots are the **entire host state**, pushed up to 2.5×/s + once per command. | Treating each frame as a light delta; rendering 400ms bursts of 100KB+ frames directly. **Coalesce.** |
| WS is at `/api/remote` **only**, port `11471`, bound to `0.0.0.0`. | Guessing an HTTP/REST API exists on the same port, or assuming TLS/auth. There is none. |
| Playback is **host-driven**: phone sends `playMeta`, host resolves streams in its picker. | A phone that tries to resolve streams/addon streams itself, or that re-requests a stream URL. |
| The LAN server has **no `/api-proxy`**; unmatched paths return `index.html`. | Hitting `/api-proxy/…` or any API-ish path against `:11471` and parsing HTML as JSON. |
| Cinemeta paging is `/genre=X/skip=N.json`; addon paging is a `skip=` extra on `/catalog/{type}/{id}/…`. | Using Stremio's page-number convention or TMDB-style `page` params on addons. |
| The phone must have its **own** Stremio `authKey` for addons; only `tmdb/rpdb/tvdb` keys ride the wire. | Expecting `snapshot.authKey` to exist and sending it in `addonCollectionGet`. |
| `setVolume` clamps to `[0,1]`; `seek` clamps to `≥0`; volume 0 unmutes on raise. | Sending out-of-range values or a `seek` for an episode-bound position without the host's clamp. |
| `ping` is answered with `{ t: "pong", at }` and **no snapshot**; `nav`/`setText` also skip snapshots. | Waiting for a snapshot after a ping/nav as confirmation. |
| `libraryAction` `metaType` for simkl/anilist/mal is normalized to `movie` vs everything-else-as-`series`. | Passing raw addon types into tracker ops. |
| Manga images must go through `/manga-img` (CORS) but **private hosts are blocked**. | Pointing the phone at `http://192.168.x.x/…` manga pages directly — blocked and/or CORS-failing. |
