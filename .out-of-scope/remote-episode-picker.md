# Remote episode/season picker

Request (#37): a Netflix-style dropdown of seasons and episodes on the remote.

## Why this is out of scope

Harbor's remote snapshot (beta v0.9.120) carries only the single current
`episode { season, episode, name? }` — there is no list of seasons or episodes
for the series on the wire (see `docs/wire-contract-research.md`).

The companion is a pure client: it can only show episodes if the host sends
them. Exposing the season/episode list requires an upstream Harbor (beta)
change.

## Prior requests

- #37: "Remote: seletor de episódios e temporadas (estilo Netflix)"
