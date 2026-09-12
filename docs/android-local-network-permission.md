# Android 17 local network permission readiness

Ticket #69. The companion is a pure LAN client: it holds a `ws://<host>:11471`
socket and fetches catalogs over the local network. Android 17 (API 37)
introduces **Local Network Protection**, which gates LAN sockets behind the
runtime `ACCESS_LOCAL_NETWORK` permission (the "Nearby devices" group) once an
app targets API 37. This note records the readiness work and what remains a
device-only check.

## What is in place

- **Declaration.** `android/app/src/main/AndroidManifest.xml` declares
  `android.permission.ACCESS_LOCAL_NETWORK`. The declaration is inert on every
  version below 37, where LAN sockets are ungated.
- **Seam.** `BackgroundPlatform` gained
  `checkLocalNetworkPermission()` and `requestLocalNetworkPermission()`
  (`lib/app/background/background_platform.dart`), returning a
  `LocalNetworkPermissionStatus`. Both stay behind the same seam as the
  notification and battery operations, so wiring the runtime gate when the
  target SDK reaches 37 needs no re-plumbing.
- **No-op below 37.** The real adapter
  (`FlutterForegroundTaskBackgroundPlatform` + `MethodChannelLocalNetworkPermission`
  → `MainActivity.kt`, channel
  `dev.harbor.harbor_companion/local_network`) reports `granted` and the request
  is a no-op below API 37. `NoopBackgroundPlatform` does the same, so tests and
  other platforms never gate on it.
- **No behavior change now.** `targetSdk` is untouched and nothing in the
  connect path calls the local-network operations. On current versions the LAN
  connection works exactly as before.

## Device-only checks (not covered by unit tests)

The Dart seam is pinned by tests (the granted/no-op path and that a connect
issues no local-network check/request). The native bridge and the OS prompt
cannot be exercised in a unit test. On a real Android 17+ device, in a release
build that targets API 37:

- [ ] First LAN connect prompts for "Nearby devices" access after the in-app
      rationale; granting it lets the socket connect.
- [ ] Denying keeps the prompt re-askable; denying permanently is reported as
      `permanentlyDenied`.
- [ ] With the permission revoked in system settings, `checkStatus` reports the
      truth and the request can restore it.
- [ ] On Android 16 and below, `checkStatus` is `granted` and the request never
      shows a prompt (the connection is never gated).
