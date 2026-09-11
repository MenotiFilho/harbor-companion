# Background reconnect has no pause

Story #15 paused the reconnect schedule whenever the app left the foreground, to
save battery. The persistent-connection effort (ADR-0003) runs a foreground
service whenever a host is connected, precisely so the process and socket can
stay alive with the screen off — and the background pause defeats that by
stopping retries in the one situation the service exists for. We therefore
remove the pause entirely: the reconnect schedule runs regardless of app
lifecycle. A host that has connected before retries **indefinitely** at the
existing `400 → 800 → 1600 → 3000 ms` cap; a host that has never connected still
gives up after 8 attempts; an explicit disconnect never reconnects. The
`SetBackgrounded` event and the `backgrounded` fields on `ClientState` and
`ConnectState` are deleted; `main.dart` keeps its lifecycle observer only for
the self-updater. This **supersedes the gate from #46** ("pause only while no
foreground service is running") — with the pause gone the gate is moot, and the
service keeps running through an outage (ADR-0003).

## Considered Options

- **Adaptive or background-specific backoff** — grow the cap to 30–60 s after a
  sustained outage, or cap higher in background. Rejected: the 3 s cap is what
  makes recovery feel instant when the host comes back, and Doze already
  restricts network with the screen off, so the real battery cost is bounded.
  A slower cap would also need a foreground-return retry trigger to avoid
  feeling stuck.
- **Keep the pause when no foreground service is running** — the conservative
  #46 default. Rejected: once a host is connected the service is the design, so
  the "no service" case is not a mode we ship.

## Consequences

- During an outage the service and its notification stay up and show the
  reconnecting state until the connection returns or the user disconnects. That
  persistence is the point of the map, not a leak.
- Removing the fields also removes the background guard on the reconnect timer
  in `client_controller.dart` and the `Tick` guard in `client_reducer.dart` and
  `connect_reducer.dart`. `WsClient.setBackgrounded` was already unreferenced
  (the connect layer disables the client's auto-reconnect), so nothing consumes
  the old signal.

## References

- Issue #48 — "Decision: política de reconexão em background".
- Issue #46 — service lifecycle and notification content.
- Issue #43 — the wayfinder map ("Conexão persistente em background").
- ADR-0003 — persistent connection requires an always-on notification.
- ADR-0005 — notification controls are host-authoritative.
