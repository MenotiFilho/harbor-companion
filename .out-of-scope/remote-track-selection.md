# Remote audio/subtitle track selection

Request (#38): choose audio track and subtitle track from the remote.

## Why this is out of scope

Harbor's remote wire (beta v0.9.120) exposes only a coarse `toggleSubtitles`
(on = first available subtitle track, off = clear) and two derived booleans
`subtitlesOn`/`canToggleSubtitles`. There is no audio-track command, no
subtitle-track selection command, and no track lists in the snapshot (see
`docs/wire-contract-research.md`).

The host player can select specific tracks (`PlayerBridge.setAudioTrack` /
`setSubtitleTrack`), but that capability is not exposed over remote. The
companion is a pure client and cannot add it. Requires an upstream Harbor
(beta) change.

## Prior requests

- #38: "Remote: mudar áudio e legendas"
