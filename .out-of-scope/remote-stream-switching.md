# Remote stream switching

Request (#36): change the stream / go to the next stream from the remote.

## Why this is out of scope

Harbor's remote command union (beta v0.9.120) has no stream/source-switch
command (`nextStream`/`setSource`/`setStream`), and the snapshot carries only a
single read-only `source` describing the current stream — no list of candidate
streams (see `docs/wire-contract-research.md`).

The companion is a pure client: it cannot switch streams without the host
exposing it. "Next stream" exists only in Harbor's desktop UI. Adding it is an
upstream Harbor (beta) change.

## Prior requests

- #36: "Remote: mudar de stream / ir para a próxima stream"
