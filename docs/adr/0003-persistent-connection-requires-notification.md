# Persistent connection requires an always-on notification

The companion keeps a `ws://<host>:11471` connection to a LAN Harbor host while
the app is in the background. On Android that is only possible with a
**foreground service**, and a foreground service **must** show an ongoing
notification. There is no way to hold the socket in the background without a
user-visible notification. We therefore run the service whenever a host is
connected — idle or playing — and accept the persistent notification as the
cost of the persistent connection.

The alternative (start the service only while media plays) was considered and
rejected: it cannot be started from the background (Android 12+ forbids it), so
playback started on the host with the phone already backgrounded could never
raise the controls. It would also drop the socket whenever nothing plays,
contradicting the "connection stays alive with the screen off" goal.

## Consequences

- The service is scoped to the **connection**, not to playback: it starts on the
  first connection established while the app is foregrounded and stops on
  explicit disconnect or when the active host is removed.
- The notification is a single one that morphs: idle it shows host status text;
  while media plays it becomes a `MediaStyle` + `MediaSession` control surface.
- Dismissing the notification (allowed on Android 14+) does not stop the
  service; it is re-posted only on the next real state change.
- Playback started on the host cannot wake the phone app by itself; controls are
  available only because the service was already running.
