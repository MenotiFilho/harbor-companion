# Episode-granular history on remote

The companion's My Stuff → History shows one entry per media (series/movie).
The request (#32) was to show each watched episode of a series as its own entry,
with its name.

## Why this is out of scope

Harbor's remote snapshot (beta v0.9.120) sends `library.history` as a list of
`RemoteLibraryItem` — `{ id, type, name, poster, background, ... }` with **no
season/episode/name fields** (see `docs/wire-contract-research.md`). History is
media-level: watching three episodes of a series produces one history entry.

The companion is a pure client of Harbor's remote wire — it can only render what
the snapshot carries. Showing per-episode history would require Harbor to change
the wire (add season/episode/name to history items, or emit one entry per
episode), which is an upstream change outside this repo.

## Prior requests

- #32: "Histórico não lista episódios individuais de séries"
