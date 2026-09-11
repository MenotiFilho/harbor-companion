# Notification permission and battery onboarding are contextual, and denying notifications degrades instead of blocking

The persistent connection needs a foreground service, and a foreground service
needs an ongoing notification (ADR-0003, ADR-0006). On Android 13+ that
notification sits behind the `POST_NOTIFICATIONS` runtime permission, so the app
must decide when to ask, what a denial means, and how to get the user to exempt
it from battery optimization on OEMs that kill background processes. We ask at
the **first successful connect, as the foreground service would start** — never
on launch and never before the user has connected anything — and always behind a
short in-app rationale dialog, because a LAN companion asking for a persistent
notification is not self-explanatory.

A denial is a **degradation, not a block**: a foreground service does not require
the permission, so the service keeps running (ADR-0006) but its controls are
invisible. The app does not nag with a Remote banner; it keeps one permanent
Settings row, `Notification access`, that re-requests (rationale + native
prompt) when Android still allows it and otherwise deep-links to the app's
notification settings. Battery optimization is handled from Settings only: a
direct `ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` with a fallback to the
optimization list, plus a reactive nudge when the app resumes with the socket
dropped after a background stretch. A `keep connection in background` toggle
(default on, in a "Connection" section) is the user's opt-out: with it off, no
foreground service is started and no permission is requested, and — consistent
with ADR-0006 — no background reconnect pause is reintroduced.

## Considered Options

- **Warn in Settings only vs. also a Remote banner.** A banner would sit exactly
  where the hidden controls are, but it nags for a degradation the in-app Remote
  fully covers. One honest Settings row, no banner.
- **Battery: instruct vs. request direct vs. both.** The direct request is the
  only lever that reliably works on MIUI; the optimization list stays as
  fallback rather than the only path. Being sideloaded, Play's restriction on
  `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` does not bind us.
- **A dedicated onboarding wizard vs. contextual prompts.** Rejected: the
  permission has context only at connect time, so a wizard asks before the user
  knows they want the feature.
- **Toggle off = no service vs. toggle off = pause the socket.** The background
  pause was removed in ADR-0006 precisely because the service is the gate;
  bringing it back behind the toggle would resurrect lifecycle-dependent
  scheduling for a user who has already opted out. Letting the OS reap the
  unprotected process is the simpler, honest model.

## Consequences

- The permission rationale dialog and the Settings row are the only places the
  permission is ever requested; the OS prompt is never fired cold.
- If the toggle is off at the first connect, the permission is not requested at
  all — it is requested when the toggle is turned on, or on the next connect
  with it on.
- The `Notification access` row must distinguish "re-askable" from "permanently
  denied" and, in the latter case, open the OS notification settings.
- The reactive battery nudge only fires while the toggle is on (a user who opted
  out of background connection should not be nudged about background survival),
  is dismissible, and is throttled.
- The OEM guidance is a static tips block plus a generic battery-settings
  action; no runtime `Build.MANUFACTURER` detection.
- Enabling the toggle while connected and foregrounded starts the service
  immediately; while backgrounded Android forbids starting a foreground service,
  so it waits for the next foreground.
- `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` is the one new manifest permission this
  decision requires (plus `POST_NOTIFICATIONS`), in addition to the
  `connectedDevice` foreground-service permissions from ADR-0003.

## References

- Issue #49 — "Decision: permissão de notificação e onboarding de bateria/OEM".
- Issue #43 — the wayfinder map ("Conexão persistente em background").
- ADR-0003 — persistent connection requires an always-on notification.
- ADR-0006 — background reconnect has no pause.
