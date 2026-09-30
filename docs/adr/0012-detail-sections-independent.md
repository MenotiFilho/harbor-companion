# Detail sections fetch independently

The refresh adds cast and similar titles to the detail screen. Both need TMDB
requests the detail fetch does not make today — credits and recommendations,
plus a `/find` resolution for `tt…` ids when a TMDB key is configured. We
decided each section — seasons/episodes, cast, similar — is fetched and rendered
by its own provider with its own loading and error state, instead of joining one
blocking detail round. A slow or failed section never delays the header or the
episodes, and a section with no data (no key, no match) does not render at all.

## Decision

- One provider per section; the header renders from the already-available
  `Meta` the moment the page opens.
- Cast comes from TMDB credits (top-billed); similar comes from TMDB
  recommendations.
- Cinemeta (`tt…`) ids resolve through `/find` when a key exists; without a key
  or a match those sections are simply absent.
- No placeholder for an empty or failed section — sections appear only with
  content.
- Cache: in memory for the session only.

## Considered Options

- **One combined detail round** — rejected: the slowest request would hold the
  whole screen, against the per-rail philosophy (ADR-0009).
- **Disk cache like the rails** — rejected for now: TTL, invalidation and tests
  for little gain; revisit if re-opening titles hits the network too often.

## Consequences

- More providers and per-section states to test; the detail screen composes
  independently settling sections.
- Extends ADR-0009's per-rail philosophy from Home to the detail route.

## References

- ADR-0009 — rail cap and "See more" grid (per-source outcomes).
- `prototype/ui/app.html` — cast row and "Você também pode gostar".
