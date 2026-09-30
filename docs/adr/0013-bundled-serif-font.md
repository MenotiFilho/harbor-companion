# The hero serif ships bundled as an asset

The refresh uses a serif face for hero titles, matching the prototype. We
decided to bundle the font file as an app asset rather than depend on
`google_fonts`: the app is sideloaded and must open on a LAN with no internet,
so a runtime font download would make the first paint depend on the network. The
face is used only on hero and title surfaces; the rest of the UI keeps the
system sans.

## Decision

- Bundle the serif (Cormorant Garamond, as prototyped) as an app asset.
- Scope: hero and title surfaces only (Cinemascope title, detail hero, Home
  hero).
- No runtime font fetching.

## Considered Options

- **`google_fonts`** — rejected: first paint depends on the network, which is
  wrong for an offline-capable LAN remote.
- **No serif (system sans with tight tracking)** — rejected: drops the editorial
  identity the refresh is built on; documented fallback if APK size ever
  matters.

## Consequences

- Roughly 200–300 KB added to the APK.
- Deterministic first paint; no font-fetch failure mode to handle.

## References

- `prototype/ui/app.html` — serif hero titles.
