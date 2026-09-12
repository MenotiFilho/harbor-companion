# Home catalog sources: limits & pagination (Cinemeta, TMDB, Stremboxd)

Research for the "rail capped at 20 items + See more grid" work. Question: after a
rail fetch of ~20 items, can the grid fetch **more** from each source, or must it
show only what the first fetch returned?

Method: read each upstream's own docs/source and probed the live endpoints on
**2026-09-11**. Payload sizes are the raw `curl` body bytes (uncompressed); counts
are parsed from the JSON. Every claim below links to the primary source that owns
it. This note does not modify product code.

## Today's behavior in this app

- `HttpCatalogFetcher.fetchRows` fetches each planned row once and returns all
  parsed metas; the UI renders the whole `HomeRow`. It never sends `skip`/`page`.
  ([`catalog_fetcher.dart`](https://github.com/MenotiFilho/harbor-companion/blob/0655f55/lib/app/home/catalog_fetcher.dart))
- Built-in rows are Cinemeta or TMDB paths; Letterboxd rows are fetched from the
  user's Stremboxd manifest via `<base>/catalog/<type>/<id>.json` with no extras.
  ([`home_rows.dart`](https://github.com/MenotiFilho/harbor-companion/blob/0655f55/lib/app/home/home_rows.dart),
  [`letterboxd.dart`](https://github.com/MenotiFilho/harbor-companion/blob/0655f55/lib/app/letterboxd/letterboxd.dart))
- The Letterboxd parser deliberately ignores `extra`/pagination metadata today.

## Shared: what the Stremio addon protocol says

All three sources are Stremio-style catalogs (Cinemeta and Stremboxd literally are
Stremio addons). The protocol is the common contract:

- Requests are `/{resource}/{type}/{id}/{extraArgs}.json`, where `extraArgs` is a
  URL-encoded `&`-joined object, e.g. `"search=game%20of%20thrones&skip=100"`, and
  the catalog response is `{ "metas": [ … MetaPreview … ] }`.
  ([Stremio Addon Protocol](https://github.com/Stremio/stremio-addon-sdk/blob/master/docs/protocol.md))
- Manifest catalogs declare `extra` entries of
  `{ name, isRequired, options, optionsLimit }`.
  ([manifest.md — Catalog format](https://github.com/Stremio/stremio-addon-sdk/blob/master/docs/api/responses/manifest.md))
- `skip` is the pagination extra: *"refers to the number of items skipped from the
  beginning of the catalog; the standard page size in Stremio is 100, so the
  `skip` value will be a multiple of 100; if you return less than 100 items,
  Stremio will consider this to be the end of the catalog."*
  ([defineCatalogHandler.md — Extra Parameters](https://github.com/Stremio/stremio-addon-sdk/blob/master/docs/api/requests/defineCatalogHandler.md))

So a source is paginable **iff** it declares `skip` and honors it; and a source is
"finished" once it returns fewer than 100 items.

## 1. Cinemeta — 50 per request, `skip` honored

Manifest (`https://v3-cinemeta.strem.io/manifest.json`, fetched 2026-09-11):
`id: com.linvo.cinemeta`, `version: 3.0.14`, `types: ["movie","series"]`,
`resources: ["catalog","meta","addon_catalog"]`. The `top` catalog (movie and
series) declares `extra: [genre, search, skip]` and
`extraSupported: ["search","genre","skip"]`.

> Note: `https://v3-cinemeta.strem.io/catalog/...` responds **307** and redirects to
> `https://cinemeta-catalogs.strem.io/top/catalog/...`; the client must follow
> redirects (this app's `dart:io` client does by default).

Live catalog probes (fetched 2026-09-11):

| Endpoint | metas | body |
|---|---|---|
| [`/catalog/movie/top.json`](https://v3-cinemeta.strem.io/catalog/movie/top.json) | 50 | 127,819 B |
| [`/catalog/series/top.json`](https://v3-cinemeta.strem.io/catalog/series/top.json) | 49 | 569,932 B |
| [`/catalog/movie/top/genre=Action.json`](https://v3-cinemeta.strem.io/catalog/movie/top/genre=Action.json) | 50 | 138,515 B |
| [`/catalog/series/top/genre=Drama.json`](https://v3-cinemeta.strem.io/catalog/series/top/genre=Drama.json) | 50 | 584,422 B |

`skip` works and each window is a stable, disjoint batch of ~50:

| Endpoint | metas | body |
|---|---|---|
| [`/catalog/movie/top/skip=50.json`](https://v3-cinemeta.strem.io/catalog/movie/top/skip=50.json) | 50 | 132,840 B |
| [`/catalog/movie/top/skip=100.json`](https://v3-cinemeta.strem.io/catalog/movie/top/skip=100.json) | 49 | 134,780 B |
| [`/catalog/movie/top/skip=200.json`](https://v3-cinemeta.strem.io/catalog/movie/top/skip=200.json) | 48 | 128,964 B |
| [`/catalog/movie/top/skip=500.json`](https://v3-cinemeta.strem.io/catalog/movie/top/skip=500.json) | 49 | 127,506 B |
| [`/catalog/movie/top/skip=2000.json`](https://v3-cinemeta.strem.io/catalog/movie/top/skip=2000.json) | 50 | 128,010 B |
| [`/catalog/movie/top/skip=10000.json`](https://v3-cinemeta.strem.io/catalog/movie/top/skip=10000.json) | 50 | 113,332 B |
| [`/catalog/movie/top/genre=Action&skip=100.json`](https://v3-cinemeta.strem.io/catalog/movie/top/genre=Action&skip=100.json) | 50 | 140,184 B |

Observed properties (repeated probes, 2026-09-11):

- Each page is **deterministic** (two identical requests gave identical order).
- Consecutive pages are **disjoint** (`default ∩ skip=50 = 0`,
  `skip=50 ∩ skip=100 = 0`) — i.e. `skip` genuinely advances the window.
- `skip` goes arbitrarily deep (50 items still returned at `skip=10000`), so
  Cinemeta exposes a very large ranked corpus, not a fixed finished list.
- Multi-extra uses `&`: `/genre=Action&skip=100.json` works; the malformed
  `/genre=Action/skip=100.json` returns 404.
- Quirk: the no-extra page and `skip=0` returned **different** orderings. Both are
  stable across repeats, but a client must not assume `default == skip=0`.

**Consequence.** Cinemeta's own page size is ~50, already **> 20 × 2.5**. A rail
that displays 20 can build a 50-item "See more" grid from the *same* response with
zero extra network. To go past 50, request `skip=50`, `skip=100`, … The network
cost is dominated by series rows (~570 KB / 50 items, because metas carry
`videos[]`); movie rows are ~128 KB / 50. There is no limit/page-size parameter,
so fetching a rail always costs ~50 items worth of payload regardless of the
20-item cap.

## 2. TMDB — 20 per page, `page` documented for lists, *not* for trending

Base: `https://api.themoviedb.org/3`. List responses are
`{ page, results, total_pages, total_results }`.

List/discover endpoints that **officially document a `page` query parameter**
(integer, default 1):

- [`/movie/popular`](https://developer.themoviedb.org/reference/movie-popular-list.md)
- [`/movie/top_rated`](https://developer.themoviedb.org/reference/movie-top-rated-list.md)
- [`/movie/now_playing`](https://developer.themoviedb.org/reference/movie-now-playing-list.md)
- [`/movie/upcoming`](https://developer.themoviedb.org/reference/movie-upcoming-list.md)
- [`/tv/popular`](https://developer.themoviedb.org/reference/tv-series-popular-list.md)
- [`/tv/top_rated`](https://developer.themoviedb.org/reference/tv-series-top-rated-list.md)
- [`/discover/movie`](https://developer.themoviedb.org/reference/discover-movie.md)
- [`/discover/tv`](https://developer.themoviedb.org/reference/discover-tv.md)

**20 per page** is pinned by the official examples: the `/movie/popular` example
returns exactly 20 `results` with `total_pages: 38029` and
`total_results: 760569` (760569 / 20 → 38029). The `/discover/movie` example is
likewise 20 results with `total_pages: 38020`, `total_results: 760385`. (Counted
from the OpenAPI `Result` example string in the linked reference pages.)

**Trending is the exception.** The official reference for
[`/trending/movie/{time_window}`](https://developer.themoviedb.org/reference/trending-movies.md)
documents only `time_window` (path) and `language` (query) — **no `page`**. Its
example nonetheless returns 20 `results` with `page: 1`, `total_pages: 1000`,
`total_results: 20000`, i.e. the response schema is paged even though the request
contract exposes no page knob. The same is true for `/trending/tv/{time_window}`
(reference page has no `page` parameter). Treat trending as **page-1-only unless
empirically verified**; community clients do pass `page` (e.g. the
[`tmdb-ts` docs](https://context7.com/blakejoy/tmdb-ts/llms.txt) and
[`tmdbv3api`](https://github.com/imufly/nt2/blob/master/app/media/tmdbv3api/objs/trending.py)
append `page=`), but that is not an official guarantee.

**Rate limits / cost of page 2+.** TMDB's own docs: the legacy limit
(40 requests / 10 s) was disabled on 2019-12-16; the current ceiling is
"somewhere in the 40 requests per second range", may change at any time, and
clients must "respect the `429`".
([Rate Limiting](https://developer.themoviedb.org/docs/rate-limiting.md)) Fetching
page 2+ is simply **one extra HTTP request per page**, with the same 20-item page
size; no separate pagination charge is documented.

No `page`-cap number (e.g. 500) appears in the primary docs pages checked — FAQ,
Finding Data, Search & Query for Details, Getting Started (probed 2026-09-11).
Community reports of a 500/1000-page ceiling exist but are unverified here and
are irrelevant at page 2.

**Consequence.** A TMDB rail fetch returns exactly 20 — the cap size. A "See more"
grid **needs a real network request** (`?page=2`, then 3, …) for any TMDB row, and
that is documented and cheap for the list/discover rows. For the two `*/trending/*`
built-in rows, the documented contract gives no way past 20.

## 3. Stremboxd / Letterboxd — 100 per request, `skip` declared, fetch-all-then-slice

Source of truth: the Stremboxd backend,
[`esp4ce/stremio-letterboxd-addon`](https://github.com/esp4ce/stremio-letterboxd-addon)
at commit
[`55690af`](https://github.com/esp4ce/stremio-letterboxd-addon/tree/55690af85661cb090ae229672ac6b47c94a1e4a9)
("bump addon manifest version to 2.0.0", 2026-09-09).

Live manifest (`https://api.stremboxd.com/manifest.json`, fetched 2026-09-11):
`id: community.stremboxd`, `version: 2.0.0`, `types: ["movie"]`,
`resources: ["catalog", {meta, types:[movie], idPrefixes:[tt]}]`,
`behaviorHints: {configurable: true, configurationRequired: false}`, and catalogs:

- `letterboxd-popular` ("Popular This Week") —
  `extra: [{name:"genre", options:[sort + genre + decade values], isRequired:false, optionsLimit:1}, {name:"skip", isRequired:false}]`
- `letterboxd-top250` ("Top 250 Narrative Features") — same `[genre, skip]` extras
- `letterboxd-search` — `extra: [{name:"search", isRequired:true}]`

(The manifest is generated in
[`stremio.service.ts`](https://github.com/esp4ce/stremio-letterboxd-addon/blob/55690af85661cb090ae229672ac6b47c94a1e4a9/backend/src/modules/stremio/stremio.service.ts);
every user catalog is built with `{ name: 'skip', isRequired: false }`.) No
`extraSupported` field is emitted.

Response shape is the standard catalog object `{ metas: [...] }`; metas are Meta
Preview entries (`id` = IMDb `tt…`, `type: "movie"`, name, poster, year, genres).
Verified against the live bodies below.

**Page size is 100.** `CATALOG_PAGE_SIZE = 100` in
[`public-catalog-fetcher.service.ts:50`](https://github.com/esp4ce/stremio-letterboxd-addon/blob/55690af85661cb090ae229672ac6b47c94a1e4a9/backend/src/modules/stremio/catalog/public-catalog-fetcher.service.ts#L50)
and
[`catalog-fetcher.service.ts:62`](https://github.com/esp4ce/stremio-letterboxd-addon/blob/55690af85661cb090ae229672ac6b47c94a1e4a9/backend/src/modules/stremio/catalog/catalog-fetcher.service.ts#L62).
Every response slices the cached full list `[skip, skip + 100)`.
`skip` is parsed in
[`parseCombinedFilter`](https://github.com/esp4ce/stremio-letterboxd-addon/blob/55690af85661cb090ae229672ac6b47c94a1e4a9/backend/src/modules/stremio/catalog/catalog-filter.ts#L42)
(`skip=…`, with sort/genre/decade packed into the single `genre` extra). Routes:
token path `/stremio/:userId/catalog/:type/:id/:extra.json` and the public Tier-1
`:extra` routes.

It does **not** stream lazily: for each request it fetches the whole catalog from
Letterboxd into a process cache and then slices. Fetch caps per catalog
(`... so up to …`):

- popular / watchlist / liked-films / lists: `page < 10` × 100 = **≤ 1000** metas
  ([`public-catalog-fetcher.service.ts:97`](https://github.com/esp4ce/stremio-letterboxd-addon/blob/55690af85661cb090ae229672ac6b47c94a1e4a9/backend/src/modules/stremio/catalog/public-catalog-fetcher.service.ts#L97))
- Top 250 / diary: `page < 5` × 100 = **≤ 500**
  ([`:136`](https://github.com/esp4ce/stremio-letterboxd-addon/blob/55690af85661cb090ae229672ac6b47c94a1e4a9/backend/src/modules/stremio/catalog/public-catalog-fetcher.service.ts#L136))
- friends activity: `page < 3` × 100 = **≤ 300**
  ([`catalog-fetcher.service.ts:153`](https://github.com/esp4ce/stremio-letterboxd-addon/blob/55690af85661cb090ae229672ac6b47c94a1e4a9/backend/src/modules/stremio/catalog/catalog-fetcher.service.ts#L153))

Live probes (fetched 2026-09-11):

| Endpoint | metas | body |
|---|---|---|
| [`/catalog/movie/letterboxd-popular.json`](https://api.stremboxd.com/catalog/movie/letterboxd-popular.json) | 100 | 87,284 B |
| [`/catalog/movie/letterboxd-top250.json`](https://api.stremboxd.com/catalog/movie/letterboxd-top250.json) | 100 | 85,214 B |
| [`/catalog/movie/letterboxd-popular/skip=0.json`](https://api.stremboxd.com/catalog/movie/letterboxd-popular/skip=0.json) | 100 | 87,284 B |
| [`/catalog/movie/letterboxd-popular/skip=100.json`](https://api.stremboxd.com/catalog/movie/letterboxd-popular/skip=100.json) | 100 | 87,282 B |
| [`/catalog/movie/letterboxd-popular/skip=900.json`](https://api.stremboxd.com/catalog/movie/letterboxd-popular/skip=900.json) | 100 | 35,569 B |
| [`/catalog/movie/letterboxd-popular/genre=Action&skip=100.json`](https://api.stremboxd.com/catalog/movie/letterboxd-popular/genre=Action&skip=100.json) | 100 | 36,201 B (7.0 s) |
| [`/catalog/movie/letterboxd-top250/skip=200.json`](https://api.stremboxd.com/catalog/movie/letterboxd-top250/skip=200.json) | 100 | 84,251 B |

**Consequence.** A Stremboxd rail fetch already returns **100** items (~85–88 KB).
A 20-item rail cap and a 100-item "See more" grid can both come from the single
existing fetch; `skip=100` unlocks the next 100, up to the per-catalog cap. This is
fully protocol-conformant (page size 100; returning exactly 100 means "not the
end").

## Summary: can the grid go past 20, and at what cost?

| Source | First fetch | Extra request needed for >20? | Pagination mechanism | Grid capacity from one fetch |
|---|---|---|---|---|
| Cinemeta | ~50 metas | No (up to 50) | `skip` (own page = 50) | 50 (+50/fetch, arbitrarily deep) |
| TMDB list/discover rows | 20 metas | **Yes** | `?page=N` (20/page) | 20 (+20/request) |
| TMDB `/trending/*` rows | 20 metas | Not documented | `page` undocumented for `/trending` | 20 (unless verified) |
| Stremboxd / Letterboxd | 100 metas | No (up to 100) | `skip` (page = 100) | 100 (+100/fetch, to per-catalog cap) |

## Recommendation

**Make "See more" source-aware: client-side slice first, network page only for
TMDB.**

1. **Cap the rail at 20 at render time, keep the full fetch.** Today the app
   fetches the whole rail anyway. Slicing the first 20 for the rail and keeping
   the remaining items in state makes "See more" instant for Cinemeta (50
   available) and Stremboxd (100 available), with zero new network calls and zero
   new parsing. This is the cheapest correct implementation and avoids a
   source-specific fetch abstraction for two of the three sources.

2. **Only TMDB needs real pagination.** TMDB returns exactly 20, so its grid must
   request `?page=2` (then 3, …). That is documented for `/movie/*`, `/tv/*`, and
   `/discover/*` and is cheap (one request per page, ~40 req/s ceiling, respect
   `429`). Add page-fetching to the fetcher for TMDB list rows only.

3. **Treat `/trending/*` as 20-only.** The official `/trending` reference exposes
   no `page` parameter. Either accept a 20-item grid for the two trending rows, or
   swap those rows to their documented discover equivalents
   (`/discover/movie?sort_by=popularity.desc`, etc.) so they can paginate on the
   same code path as other TMDB rows. Do not ship a "See more" page-2 call against
   `/trending` without an empirical check against a real API key.

4. **Model the grid as "loaded pages", not "the rail".** Keep a per-row cursor
   (`skip` for Cinemeta/Stremboxd, `page` for TMDB) plus the loaded list, so the
   grid can append:
   - Cinemeta: re-request `skip=<loaded>` (server returns ~50; note page 1 has no
     `skip` and `skip=0` orders differently, so always page from the loaded count).
   - Stremboxd: re-request `skip=<loaded>` (server returns 100; stop when a
     response has <100, per the protocol).
   - TMDB: increment `page` while `page < total_pages`; stop when
     `page >= total_pages`.

5. **Don't expect a payload win from the 20 cap.** Cinemeta has no page-size
   parameter and always returns ~50 items — series rows in particular are ~570 KB
   because each meta carries `videos[]`. Capping the *display* at 20 does not
   shrink that download; it only defers the rendering. If payload becomes a
   concern, that is a separate optimization (e.g. don't prefetch rows the user
   never opens), not something the 20-item cap solves.

6. **Watch the aggregator caps.** Stremboxd builds each catalog from a bounded
   Letterboxd pull (≤1000 metas for popular/watchlist/liked/lists, ≤500 for Top
   250/diary, ≤300 for friends) and silently returns fewer once exhausted; a
   grid should treat a short page (especially <100) as the end. Cinemeta's `skip`
   is not bounded in practice, so the grid needs its own stop condition
   (e.g. a max page count) rather than relying on an empty page.

## Primary sources

- Stremio addon protocol —
  https://github.com/Stremio/stremio-addon-sdk/blob/master/docs/protocol.md
- Stremio catalog `skip` semantics —
  https://github.com/Stremio/stremio-addon-sdk/blob/master/docs/api/requests/defineCatalogHandler.md
- Stremio manifest `extra` format —
  https://github.com/Stremio/stremio-addon-sdk/blob/master/docs/api/responses/manifest.md
- Cinemeta manifest — https://v3-cinemeta.strem.io/manifest.json
- Cinemeta catalogs (live probes) —
  https://v3-cinemeta.strem.io/catalog/movie/top.json,
  https://v3-cinemeta.strem.io/catalog/series/top.json,
  https://v3-cinemeta.strem.io/catalog/movie/top/genre=Action.json,
  https://v3-cinemeta.strem.io/catalog/movie/top/skip=50.json (and `skip=100/200/500/2000/10000`, `genre=Action&skip=100`)
- TMDB rate limiting — https://developer.themoviedb.org/docs/rate-limiting.md
- TMDB reference pages —
  https://developer.themoviedb.org/reference/movie-popular-list.md,
  https://developer.themoviedb.org/reference/movie-top-rated-list.md,
  https://developer.themoviedb.org/reference/movie-now-playing-list.md,
  https://developer.themoviedb.org/reference/movie-upcoming-list.md,
  https://developer.themoviedb.org/reference/tv-series-popular-list.md,
  https://developer.themoviedb.org/reference/tv-series-top-rated-list.md,
  https://developer.themoviedb.org/reference/discover-movie.md,
  https://developer.themoviedb.org/reference/discover-tv.md,
  https://developer.themoviedb.org/reference/trending-movies.md,
  https://developer.themoviedb.org/reference/trending-tv.md
- Stremboxd source —
  https://github.com/esp4ce/stremio-letterboxd-addon
  (commit `55690af85661cb090ae229672ac6b47c94a1e4a9`)
- Stremboxd live manifest & catalogs —
  https://api.stremboxd.com/manifest.json,
  https://api.stremboxd.com/catalog/movie/letterboxd-popular.json,
  https://api.stremboxd.com/catalog/movie/letterboxd-top250.json,
  https://api.stremboxd.com/catalog/movie/letterboxd-popular/skip=100.json
