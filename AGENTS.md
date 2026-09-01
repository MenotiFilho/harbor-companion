# AGENTS.md

## What this is

Flutter/Dart app `harbor_companion`: a native **Android** companion for
[Harbor](https://github.com/harborstremio/harbor). It is a pure client of
Harbor's remote API over `ws://<ip>:11471/api/remote`. Playback always runs on
the host PC — the phone never resolves streams and never holds Stremio
credentials. Sideloaded via GitHub Releases (no Play Store), with in-app
self-update.

## Commands

- `flutter pub get` — install dependencies.
- `flutter analyze` — lint + static analysis (this is also the typecheck step).
- `flutter test` — run all tests.
- `flutter test test/app/ws/client_reducer_test.dart` — run one test file.
- `flutter build apk --release` — needs signing material: env secrets
  (`KEYSTORE_BASE64`, `KEYSTORE_PASSWORD`, `KEY_PASSWORD`, `KEY_ALIAS`) or
  `android/key.properties`. No debug-key fallback: without signing it fails.
- `dart run tool/release/version_gate.dart` — release version gate. Pure Dart,
  no package imports, so it runs with plain `dart run` even before
  `flutter pub get`.
- `dart run bin/live_check.dart [--host HOST] [--port 11471]` — live conformance
  harness against a real Harbor beta host. Read-only (only sends hello / optional ping).

## Architecture

State management is Riverpod (`flutter_riverpod` v3). Every feature under
`lib/app/<feature>/` follows one strict pattern:

- `*_reducer.dart` — pure `(State, Event) => State` reducer plus a mutable
  `effects`/`outgoing` buffer. No I/O, no timers; this is the decision seam.
- `*_controller.dart` — a `Notifier` that drains the buffer into real
  side-channels (socket, HTTP, storage) and folds results back in as events.
- `*_screen.dart`, plus `*_store.dart` / `*_fetcher.dart` seams where needed.

Controllers inject a clock and I/O seams as providers; tests override them via
`ProviderContainer(overrides: [...])`. Seams default to in-memory/real
implementations in the provider, but the disk/network backends are wired only in
`lib/main.dart`'s `ProviderScope(overrides: [...])` (`SharedPrefsHostRegistryStore`,
`TcpProbeScanner`).

Key wiring:

- `lib/app/ws/` — WebSocket client (`ws://<addr>:11471/api/remote`, `hello`
  handshake `proto:1`, ~400ms snapshots, stale-snapshot coalescing, ~1.2s sticky
  window). `connect_controller` owns the reconnect *schedule*; it disables the
  WS client's auto-reconnect and re-drives `connect()` on each retry.
- Catalog (Home/Search) hits public sources directly, never Harbor: Cinemeta
  (keyless fallback), TMDB (keyed by `snapshot.tmdbKey`), Jikan (anime, shared
  400ms throttle). There is no `/api-proxy`.
- `lib/app/update/` — in-app self-update via GitHub Releases (`ota_update`).
  Owner/repo hardcoded in `github_releases_client.dart`
  (`MenotiFilho` / `harbor-companion`).

JSON parsing is all hand-written `fromJson` factories — no build_runner,
freezed, or json_serializable codegen exists in this repo.

## Testing

Tests mirror `lib/app/` under `test/app/`, plus `test/release/` for the version
gate tool. Conventions:

- Time is fake: `wsClockProvider` / `connectClockProvider` inject ms-since-epoch;
  tests use `package:clock` + `fake_async` (`async.elapse(...)`).
- Pure JSON mappers are top-level functions so wire shapes are pinned without
  network.
- `test/app/ws/client_e2e_test.dart` spins up an in-process simulated Harbor host
  over a real socket — no real host needed for CI. `bin/live_check.dart` is the
  live equivalent (needs a real Harbor beta host, v0.9.118).

## Releasing

- Push a tag `v<versionName>+<versionCode>`; `.github/workflows/release.yml`
  runs the version gate (tag must equal pubspec `version:`, versionCode strictly
  greater than the previous release), builds the signed APK, and publishes to
  GitHub Releases with a `SHA256SUMS` sidecar. A bad tag fails before building.
- Signing key never rotates (ADR-0001): key loss means every install must
  uninstall/reinstall.
- Ticket/story numbers in code comments (`ticket 29`, `#15`) refer to GitHub
  issues — resolve them with `gh issue view <n>`.
- Code comments reference `docs/wire-contract.md`, which does not exist in the
  repo — don't go looking for it.

## Agent skills

### Issue tracker

Issues and PRDs for this repo live as GitHub issues, operated via the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Five canonical triage roles, each label string equal to its name: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context — one `CONTEXT.md` plus `docs/adr/` at the repo root. See `docs/agents/domain.md`.
