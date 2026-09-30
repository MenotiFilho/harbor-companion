# Glass surfaces are real only on chrome and overlays

The UI refresh borrows the prototype's "frosted glass" language. In Flutter that
means `BackdropFilter`, which re-blurs its backdrop every frame — the wrong cost
on Home's scrolling rails, where the perf spike (#8) set a sustained-60fps bar.
We decided real blur is reserved for **persistent chrome** (app bar, player bar,
tab bar) and **overlays** (bottom sheets, dialogs); every other "glass" surface —
cards, rails, list rows, segmented controls — is a translucent fill plus a
hairline border.

## Decision

- Real `BackdropFilter` only on: app bar, player bar, tab bar, bottom sheets,
  dialogs.
- Cards, rails, list rows and segmented controls: translucent fill + hairline,
  never blurred.
- The blurred surfaces are a fixed set that is always on screen; there is no
  per-item blur anywhere.
- The prototype's heavier frosting is a deliberate visual delta, not a bug.

## Considered Options

- **Blur everywhere the prototype shows it** — rejected: repaints over scrolling
  content and risks the Home perf target.
- **No real blur at all** — rejected: gives up the glass reading exactly where it
  is cheapest and most visible (the persistent chrome).
- **Blur only on overlays** — rejected: leaves the chrome flat, which is the
  surface the user looks at the most.

## Consequences

- The player bar keeps its blur over scrolling lists; card surfaces read
  "translucent", not "frosted".
- Any new always-on chrome surface must fit the fixed budget; a per-item blur
  needs a new ADR.

## References

- `prototype/ui/app.html` (branch `prototype/ui-refresh`).
- Issue #8 — Home perf spike (lazy rails + raised image cache).
