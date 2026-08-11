# Prototype: Search (state model)

**Throwaway.** Answers wayfinder ticket
[Search (prototype)].

**Question:** Does the Search state model feel right — 180ms debounce with a
request guard, parallel source fan-out (TMDB `search/multi` when keyed /
Cinemeta `search=` merge / Jikan anime), **incremental publish** as each source
lands, the merge/dedupe/anime-wins semantics, and the results → detail →
`playMeta` flow? This is a logic/state-model prototype, not a UI one. The stack
is Flutter + Riverpod, so it's written in plain Dart with no deps — the
validated module in `lib/search_controller.dart` lifts into the real app's
search layer.

**Branch choice:** logic branch (single take). The rendering architecture is
already proven by the Home prototype (#8); the question here is "does the
behaviour match beta and feel right", so there is one idiomatic reducer plus a
driveable TUI, not several aesthetic variations.

## Run

```sh
./run.sh
```

or, with a `dart` SDK on your PATH:

```sh
dart run bin/search_proto.dart
```

The shell simulates the three internet data sources and drives the pure reducer
with your keystrokes.

## Controls

| key | action |
| --- | --- |
| `type` | type a query, Enter ends it (the only way to search) |
| `s` | submit — record the query in `recent` (capped at 8) |
| `x` | clear — back to idle, results dropped |
| `k` | toggle `tmdbKey` (keyless phone → cinemeta rows only) |
| `d` | toggle duplicate-title mode (a same-title-same-year cinemeta dup + an anime hit that collides with the film title) |
| `j` | toggle Jikan 429 mode (exercises the 400ms-serialized queue + backoff) |
| `l` | cycle slow-source: none → cinemeta → jikan → tmdb (each sleeps past the 8s source guard) |
| `h` | toggle hide-anime (parental) |
| `p` | playMeta the pinned top result |
| `play <i>` | playMeta the i-th grid result |
| `<enter>` | reprint state |
| `q` | quit |

## Cases worth pushing

1. **Type → debounce → fan-out.** Type `matrix`, watch `typing` → `loading`,
   then the grid populate **incrementally** as tmdb (fastest), cinemeta, then
   jikan (slowest, 400ms-throttled) land. `done` only after all settle.
2. **Request guard.** Type `mat`, then within 180ms type `matrix` — the first
   request is abandoned (`stale` counter climbs, `req#` bumps); stale results
   can never overwrite the newer query's.
3. **Keyless fallback.** `k` (tmdbKey off) → TMDB returns nothing, so the grid
   is cinemeta rows only and **no top-match card**. Re-`k` to see the upgrade.
4. **Dedupe + anime-wins.** `d` then search `matrix`:
   - the same-title-same-year cinemeta "The Matrix" is dropped by
     `dedupeByTitle` (a remake with a different year would survive);
   - the Jikan hit named "The Matrix" replaces the **top-match card** and
     removes both "The Matrix" *film* rows (`notAnimeDupe`) — anime wins.
5. **Jikan 429.** `j` then search: Jikan rides the shared 400ms serialized queue
   (see the `jikan reqs` counter stay at 1 while cinemeta lands), 429s back off
   (2s/4s/6s), and because the retries exceed the 8s source guard the search
   still completes `done` on the film sources — Jikan just contributes nothing.
6. **Slow source.** `l` (cinemeta) then search — cinemeta times out at the 8s
   guard (`timeouts` counter), search still finishes `done`.
7. **Results → playMeta.** `p` encodes the exact beta wire frame
   (`{"t":"cmd","command":{"action":"playMeta",...,"resume":true}}`) — the
   phone never resolves streams; the host does.

## Validated decisions

- **Debounce 180ms + request guard.** Type-ahead cancels prior requests; only
  the current query's results may publish. Ported verbatim from
  `search-context.tsx:186-202` + `search-request-guard.ts`.
- **Fan out three sources in parallel**, each with an 8s guard
  (`SOURCE_TIMEOUT_MS`, `search-context.tsx:41`); a timeout is a *fallback to
  empty*, never an error. TMDB `search/multi` when keyed (drives movies/series/
  top-match), Cinemeta `search=` merged in as a fallback, Jikan anime.
- **Incremental publish.** Each settled source republishes the merged grid, so
  results appear as they arrive; `status: done` only when the last source
  settles. This is the beta `publish()` on each `.then()`.
- **Merge order matters:** `mergeMetas` (TMDB base, cinemeta appended, dedupe by
  id) → `dedupeByTitle` (same normalized title + same year drops; different year
  = a remake, survives) → `notAnimeDupe` (anime title collision removes the film
  rows) → top-match merge (anime hit with the same name replaces the pinned
  TMDB card, id becomes `kitsu:`/`mal:`/`anilist:`).
- **Jikan is one throttled queue.** Beta's search call itself is unthrottled
  (`search.ts:126-151`), but our Home catalog rows use the throttled
  `jikanQuery` (`jikan.ts:290-312`), and Jikan 429s hard. **The app must route
  BOTH search and catalog Jikan fetches through one shared 400ms-serialized
  queue** so they can't hammer the API concurrently. The sim models that shared
  queue (`lib/source_sim.dart` `_jikanChain`).
- **`playMeta` encodes exactly like beta:** `metaType` coerced `movie`/`series`
  (`anime` → `series`, `remote-open-bridge.tsx:23-30`), `resume: true` default.
  Grid ordering is top-match pinned, then movies/series interleaved
  (`mobile-search.tsx:143-149`).

## Honest scope note

`status` transitions to `done` only on full settle; while a slow source is still
in flight the grid shows partial results at `loading`. That's a deliberate match
to beta (the browser shows the loader only while *empty*). Whether the real app
wants a "still searching" affordance is a UI call, not a logic one.

The real TMDB `search/multi` drives the top-match from response `popularity`
with a poster requirement (`search.ts:298-316`); the sim just returns the top
match first for brevity. The reducer already carries the `TopMatch` shape the
real mapper will fill.

## What lifts into the real app

- `lib/search_controller.dart` — the pure reducer + `SearchResults.grid` +
  `encodePlayMeta` drop into a Riverpod `Notifier` as-is. The shell's
  `debounce`/`fetch`/`send` effects become the Notifier's side-channel to the
  WS client and the fetch layer.
- One **shared Jikan throttle** for both Home and Search (see above).
- `mergeMetas`/`dedupeByTitle`/`notAnimeDupe`/`mergeTopMatch` as pure functions.
