# Harbor Companion

Native Android companion for [Harbor](https://github.com/harborstremio/harbor) —
browse and control a Harbor instance over the LAN. A pure client of Harbor's
existing beta remote surface (`ws://<ip>:11471/api/remote`, proto 1); zero
changes to Harbor.

Flutter (stable) + Riverpod. Five-tab shell (Remote / Search / Home / My Stuff /
Profile) with a connect-first empty state on first run.

See `docs/agents/` for how the repo is run, and the issue tracker (#1, #13) for
the destination, spec, and decisions.

## How it works

Harbor Companion connects over your home network to a Harbor instance running on
your PC. Once connected, it replaces Harbor's slow browser remote with a native
Flutter app:

- **Home & Search** fetch catalog data directly from public sources (Cinemeta,
  TMDB, Jikan for anime), rendered in a fast, virtualized grid that only builds
  what's on screen.
- **My Stuff** shows your watchlist, history, and favorites straight from the
  host's live snapshot, with toggles that push back to Harbor.
- **Remote** gives you a d-pad and transport controls for whatever is playing on
  the PC, plus a cast/renderer picker.
- **Playback always runs on your computer.** Tapping play sends a `playMeta`
  command over the wire; the PC resolves streams and plays. The phone never
  resolves streams and never holds your Stremio credentials.

## Why use it

- **Fast.** The browser remote serves the entire desktop app to your phone and
  re-renders a full JSON snapshot every 400 ms. Harbor Companion coalesces those
  snapshots and renders native UI, so Home scrolls at 60 fps instead of janking.
- **Zero changes to Harbor.** It only talks to the remote API Harbor already
  ships.
- **Private by design.** No account, no credentials on your phone. The app even
  warns you before the first connect, because Harbor's remote is unauthenticated
  on the LAN.

## Screen captures

| | |
|---|---|
| ![Remote](https://img.menotifilho.dev/i/7d5d0eb0-7cc6-46d7-a770-52f0bcb6b12e.jpg) | ![Search](https://img.menotifilho.dev/i/712dd855-7c88-4dca-a2fa-455ecf2231a3.jpg) |
| ![Home](https://img.menotifilho.dev/i/103cbb1c-fa99-4a39-9b33-86469328c1e4.jpg) | ![My Stuff](https://img.menotifilho.dev/i/1114444b-b35c-4909-be76-b2a355fc169f.jpg) |
