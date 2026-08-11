# Prototype: WS client + remote control surface

**Throwaway.** Answers the question from wayfinder ticket
[WS client + remote control surface (prototype)].

**Question:** Does the WS-client state model feel right — connection lifecycle
(reconnect with exponential backoff, backgrounding), snapshot coalescing on
`updatedAt`, command dispatch semantics, and the derived now-playing surface
(including sticky-idle through episode hops)? This is a logic/state-model
prototype, not a UI one. The stack is Flutter + Riverpod, so it's written in
plain Dart with no deps — the validated module in `lib/client.dart` lifts into
the real app's WS layer.

## Run

```sh
./run.sh
```

or, with a `dart` SDK on your PATH:

```sh
dart run bin/ws_client_proto.dart
```

The shell simulates a Harbor host on your LAN. You drive both sides: connect,
advance the clock, inject frames, send commands.

## Controls

Connect / lifecycle:

| key | action |
| --- | --- |
| `c` | connect (socket open → `hello` handshake → host replies hello + snapshot) |
| `x` | user disconnect (aborts any backoff) |
| `b` | toggle backgrounded (pauses reconnect retries) |
| `o` | toggle host online/offline (offline = reconnect fails, backoff doubles) |

Clock (the host pushes a snapshot every 400 ms while connected):

| key | action |
| --- | --- |
| `+` | advance 400 ms (host tick → snapshot) |
| `=` | advance 100 ms (client clock only — sticky-idle, backoff timing) |
| `[` | advance 1200 ms (blow through the sticky-idle window) |

Host frame injection:

| key | action |
| --- | --- |
| `B` | burst — 3 snapshots back-to-back (coalescing) |
| `W` | stale snapshot (older `updatedAt` — should be skipped) |
| `J` | garbage frame (should be dropped) |
| `E` | host `error` frame |
| `P` | `pong` (no snapshot follows) |
| `K` | revoke/refresh `tmdbKey` (persist + re-apply) |

Commands (sent only when connected; rejected otherwise):

| key | action |
| --- | --- |
| `e` / `p` | play / pause |
| `k` | seek +5s |
| `v` / `m` | volume 0.5 / toggle mute |
| `n` | nav select |
| `g` / `u` | setText / submitText |
| `S` | toggleSubtitles |
| `<` / `>` | prev / next episode |
| `.` | ping |
| `f` | playMeta (movie, resume) |
| `q` | quit |

## Cases worth pushing

1. Connect, then `o` (host offline) — watch the socket drop and the backoff
   400 → 800 → 1600 → 3000 ms climb as you press `+`.
2. Turn the host back online mid-backoff; next `+` reconnects and re-syncs.
3. Press `b` while reconnecting — retries pause; press again and they resume.
4. `f` to play, then `p` to pause — host replies with an immediate snapshot on
   top of the 400 ms tick. Send a few commands fast and watch `skipped` climb
   as `updatedAt` coalescing drops the duplicates.
5. While paused, press `W` (stale snapshot) — skipped, counter increments.
6. `S` after a few ticks — note the command echo snapshot.
7. Host sends `B` burst — only the last frame survives coalescing.
8. `P` ping — no snapshot after, just `pong`.

The logic module (`lib/client.dart`) is pure and portable; the TUI and host
simulator (`bin/`, `lib/host_sim.dart`) are throwaway scaffolding.
