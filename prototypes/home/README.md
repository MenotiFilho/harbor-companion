# Prototype: Native Home + catalog screens (perf spike)

**Throwaway.** Answers wayfinder ticket
[Native Home + catalog screens (prototype)].

**Question:** Does the native Flutter rendering architecture for Home/catalog
stay fast, and what is a defensible, measurable definition of "fast"? The stack
(Flutter + Riverpod), wire contract, and catalog data strategy are already
decided; this spike builds the real Home/grid widgets and proves the rendering
architecture with a headless benchmark.

**Branch choice:** this is a perf spike, not a visual-variation prototype — the
question is "does the architecture stay fast", so there is one idiomatic
implementation plus a benchmark, not several aesthetic takes. (Prototype skill,
UI branch, single take.)

## Run

```sh
flutter pub get
flutter test          # the benchmark, headless (no device/display/emulator)
```

Uses a phone-sized viewport (390x844 @2x). Real poster images are simulated by
a tiny `PosterImage` provider riding Flutter's real `ImageCache`, so cache-hit
behaviour is measured exactly as it will work in the app.

## What "fast" means (the decision this ticket resolves)

Sustained 60fps scroll through the full Home (50+ poster rows):

| metric | target |
| --- | --- |
| p95 frame-build | <= 8ms |
| p99 frame-build | <= 16ms |
| dropped frames over a scripted full-Home scroll | <= 5 |
| image-cache hit on scroll-back | >= 90% |

The p95/p99/dropped-frame gate is verified **on-device** (real engine
`FrameTiming` via the same scroll harness in an `integration_test`); the
headless spike proves the architecture that makes it reachable.

## What the headless spike proves (deterministic)

Ran on this WSL VM, `flutter test`:

```
[perf] cards built on first frame: lazy(10 rows)=42 lazy(100 rows)=42 eager(100 rows)=600
[perf] harness baseline=83us frames=44
       appCost down: p50=22.9ms p95=31.0ms   appCost up: p50=15.6ms p95=23.0ms
       downLoads=270 upLoads=0 cacheHit=100.0%
```

1. **O(visible) build cost, not O(catalog).** Building 10 rows or 100 rows costs
   the same 42 cards — `ListView.builder` only ever builds the sliding window.
   Forcing all rows to build costs 600 cards (14x). This is the exact SPA
   problem (full re-render of the whole catalog per snapshot) avoided
   structurally.
2. **100% image-cache hit on scroll-back.** Zero re-decodes (270 loads down,
   0 up) — browsing back and forth costs nothing once posters are in cache.
   Requires raising Flutter's default `ImageCache` limits (done in the harness;
   the app must do the same — see below).
3. **Caching measurably cuts frame cost** even under software raster (scroll-back
   ~30% cheaper than the initial scroll).

The absolute per-frame times (20-40ms) are **not** the app's build cost — they
include the GPU-less software rasterizer this VM uses, which is why the numeric
gate is measured on-device rather than asserted here.

## Bugs the spike caught

- The first draft of `PosterCard` had a fixed 150px image; on a phone-sized
  rail it overflowed by 28px (RenderFlex overflow). Fixed by sizing the poster
  to its rail (`Expanded` image).
- Widget-test frames do not emit `FrameTiming` (`addTimingsCallback` never
  fires under `flutter test`), so absolute build timings must come from
  on-device `integration_test`, not widget tests.

## What lifts into the real app

- `HomeScreen` (vertical `ListView.builder` of `HomeRowRail` × horizontal
  `ListView.builder` of `PosterCard`, `itemExtent` for exact scroll math) and
  `CatalogScreen` (`GridView.builder`).
- `CatalogRepo` shape: TMDB-if-key-else-cinemeta branching; the real HTTP layer
  slots behind the same interface.
- **Raise `ImageCache.maximumSize`/`maximumSizeBytes`** in the app for
  poster-heavy screens (default 1000 entries is too small for a long catalog).
- The scroll harness becomes an on-device `integration_test` that asserts the
  p95/p99/dropped-frame gate with real `FrameTiming`.
