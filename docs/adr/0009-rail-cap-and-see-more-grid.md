# Rail cap is 20 items, and "See more" is a snapshot grid with its own state

The Home shows at most **20 items per rail** and opens a dedicated, responsive
grid of the whole rail via "See more". The cap is a **render-time slice** over
the full list the source already returned — Cinemeta ~50, Stremboxd 100, TMDB 20
— not a smaller fetch, so the grid opens instantly on the in-memory remainder.
Because TMDB returns *exactly* 20, the trigger cannot follow the raw count:
the rail carries a persisted **`hasMore`** boolean and the trigger is
`items > 20 || hasMore`. The grid keeps its **own ephemeral state per row key**,
**snapshots the round when it opens**, paginates on scroll (`skip` / `page`),
and **never writes back into the rail cache** — the rail's round stays intact and
the grid's extra pages are session-only.

## Decision

- **Cap — 20, fixed, render-time.** The rail keeps and caches the full source
  page; the UI shows the first 20. Not user-configurable.
- **Trigger — `items > 20 || hasMore`.** The card "Ver mais" sits at the end of
  the rail (a ~110-wide poster-shaped affordance). The rail title is *always*
  tappable and opens the grid with whatever is loaded, even without a
  continuation.
- **`hasMore` — persisted on the rail.** The rail / ADR-0004 cache entry becomes
  `{v, updatedAt, items, hasMore}`. The per-source rule: Stremboxd page of 100 =
  more, short page = end; TMDB `page < total_pages`; Cinemeta always (unbounded
  `skip`); `/trending` always `false`.
- **Grid — a route, not an in-place expansion.** New `AppRoutes.railGrid`
  (opened like `detail`: controller state then `pushNamed`), a responsive
  `GridView` (`SliverGridDelegateWithMaxCrossAxisExtent`) reusing a
  **`PosterCard` generalized to take an optional width**.
- **Grid data — ephemeral, snapshot, in-memory per row key.** No disk, no cache
  merge, no effect on the rail's age. It captures items + source + request +
  cursor at open and ignores Home refreshes while open.
- **Pagination — on scroll.** Cinemeta/Stremboxd `skip=<loaded>` (never `skip=0`,
  whose order differs from the default), TMDB `?page=N+1`; dedupe by `Meta.id`.
  End conditions: Stremboxd short page, TMDB `page >= total_pages`, a safety cap
  on Cinemeta (the only unbounded source), empty page. Error at the bottom keeps
  loaded items and offers "Tentar de novo".

## Considered Options

- **Configurable limit (10/20/30)** — rejected: extra UI and test surface for a
  preference the research did not ask for.
- **Cut at fetch (request only 20)** — rejected: the sources return ~50/100
  anyway, so it buys no payload and forces the grid to re-request what was
  already downloaded.
- **Raw-count trigger (`items > 20`)** — rejected: TMDB rails are exactly 20, so
  they would never show the trigger, contradicting their documented `page` API.
- **Merge grid pages into the rail cache** — rejected: it mixes rounds and
  muddles freshness (an old page 1 plus fresh later pages), against ADR-0004's
  "a rail is never assembled from two rounds"; a Home refresh would also discard
  the extra pages.
- **Grid follows the live Home / re-fetches page 1 on open** — rejected:
  following live loses scroll and loaded pages mid-pagination; re-fetching page 1
  contradicts the cache-first instant open.
- **Swap `/trending` rows for paginable `discover` equivalents** — rejected: it
  changes the content meaning and duplicates the existing discover rows, for a
  grid nobody asked for on those two rails.

## Consequences

- ADR-0004's cache entry gains `hasMore`; issue #53's per-rail fetch outcome
  (`loaded`/`failed`/`absent`) also carries it.
- A rail served from cache still shows the trigger; opening the grid offline
  lands on the retry footer once pagination is attempted.
- New route + a generalized `PosterCard`; this also enables unifying the
  Search `_ResultTile` later.
- TMDB's two `/trending` rails are 20-only: no end-of-list pagination, and the
  card hides unless more than 20 are loaded; the always-tappable title can still
  open their 20-item grid.
- Search / My Stuff "see more" is out of scope for this map and untouched.

## References

- Issue #55 — "Decision: limite de 20 itens por rail e a grid de 'ver mais'".
- Issue #50 — per-source limits and pagination
  (`docs/home-sources-pagination-research.md`).
- Issue #52 / ADR-0004 — per-rail cache and consistency; the `hasMore` extension.
- Issue #53 — per-rail loading/render semantics and the age badge.
- Issue #44 — the wayfinder map ("Home confiável, cacheada e navegável").
