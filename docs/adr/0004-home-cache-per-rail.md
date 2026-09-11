# Home cache is per-rail, disk-backed, with per-rail freshness

The Home fetches catalogs from public sources (Cinemeta, TMDB, the user's
Stremboxd addon). A source-wide failure — most visibly the Stremboxd manifest
timing out — used to blank every rail of that source until the next refetch,
because there was no cache at all. We add a cache whose unit is the **rail**:
one entry per row key, with the Stremboxd manifest cached as its own entry,
written to a per-entry JSON file under the app-support directory with an atomic
`temp`+`rename`, and served stale-while-revalidate. A rail is never assembled
from two rounds; different rails may carry different ages. Caching the manifest
means a manifest timeout no longer prevents fetching fresh Letterboxd rails.
There is no TTL: `updatedAt` is data for a future staleness indicator, and the
refresh *trigger* belongs to the Home-refresh decision, not here.

## Considered Options

- **Whole-Home snapshot** — atomic swap only when every source succeeds.
  Strongest consistency, but couples independent sources: an addon timeout would
  block Cinemeta updates and discard content already fetched.
- **Per-source bundle** — treats the manifest as a shared envelope, but a single
  bad rail inside a good envelope still needs a rule, and the observed failure is
  per-rail anyway.
- **Per-rail** (chosen) — the unit matches the entry the UI shows: a `failed`
  rail keeps its last-good copy, a `loaded` rail (even empty) replaces it, an
  `absent` rail is dropped.
- **TTL** — rejected in favour of event-driven revalidation; a clock policy
  would duplicate the refresh trigger and add skew bugs.

## Consequences

- The `CatalogFetcher` seam returns a per-rail outcome — `loaded(items)` /
  `failed` / `absent` — not `List<HomeRow>`. The empty-vs-failed distinction is
  what lets a cleared rail (e.g. an emptied watchlist) commit empty while a
  network failure keeps the cache.
- Cache identity is the row key, plus the Stremboxd `manifestUrl` for Letterboxd
  rails. The *presence* of `tmdbKey` selects the built-in source and is already
  in the row key (`cinemeta:*` vs `tmdb:*`), so its value does not invalidate.
  Order/visibility/enable-disable are composition, not item validity.
- A new `HomeCacheStore` seam (in-memory default, `path_provider` wired in
  `main.dart`) mirrors `SettingsStore`.
- A corrupted or version-mismatched file costs one rail, not the Home; entries
  whose identity no longer matches the config are swept. No explicit eviction:
  the rail set is finite and bounded by each source's page size.
- Detail/season caching is out of scope; the visual staleness indicator and its
  threshold belong to the Home-render decision (`#53`).

## References

- Issue #52 — "Decision: modelo de cache e política de consistência entre fontes".
- Issue #44 — the wayfinder map ("Home confiável, cacheada e navegável").
- `docs/home-sources-pagination-research.md` (`research/home-sources` @
  `44dc64e`) — per-source page sizes and pagination.
