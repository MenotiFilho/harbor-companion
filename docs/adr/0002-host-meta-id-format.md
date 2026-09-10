# Playback meta ids must match the host's canonical form

The companion is a pure client: it never resolves streams or episodes, it hands
the host a `metaId` and the host does the rest. The host's
`fetchAdjacentEpisodes` (`src/lib/series-episodes.ts` on Harbor's `beta-branch`)
recognizes exactly two id shapes — `tt…` (Cinemeta/imdb) and `tmdb:tv:<id>`
(TMDB series) — and falls through to addon resolution for anything else. The
TMDB mapper used to emit a bare `tmdb:<id>`, which hits that fallback: the host
cannot compute the adjacent episode, so the snapshot reports
`hasNextEpisode: false` / `hasPrevEpisode: false`. The stream still plays, but
the next/previous buttons stay disabled and the host never auto-advances.

We therefore emit ids in the host's canonical form: `tt…` from Cinemeta and
`tmdb:movie:<id>` / `tmdb:tv:<id>` from TMDB. Playback is driven only from the
shared detail page — Home, Search, My Stuff and History all open it — so a
series always carries `season`/`episode`. A direct `playMeta` without episode
context loses auto-advance for the same reason, which is why Search has no play
path of its own.

## Consequences

- The TMDB mapper keeps the kind segment (`tmdb:movie:` / `tmdb:tv:`);
  `fetchDetail` parses the numeric id back out (`tmdb:tv:1396` → `1396`) for the
  TMDB API calls.
- Companion-side id parsing must treat the numeric id as the *last* `:`-segment,
  never as `substring('tmdb:'.length)`.
- The failure mode is silent: playback succeeds, only the next/prev flags and
  auto-advance disappear. Tests pin the `tmdb:<kind>:<id>` shape
  (`catalog_fetcher_test`, `search_fetcher_test`), and `search_screen_test` pins
  that a tap opens the detail page rather than playing directly.
- Imdb (`tt…`) ids were already correct and are unaffected.

## References

- Harbor beta `src/lib/series-episodes.ts` — `fetchAdjacentEpisodes`,
  `fetchSeasonList`, `fetchSeasonEpisodes`.
- Harbor beta `src/lib/remote/remote-open-bridge.tsx` — the `tmdb:` regex and
  the `openPicker(meta, episode, …)` call.
- `docs/wire-contract-research.md` — the broader beta wire inventory.
