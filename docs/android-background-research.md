# Android background execution for a LAN WebSocket remote control

Context: Android-only Flutter client, no local audio, persistent `ws://<host>:11471` to a Harbor instance on the LAN, plus a persistent control notification. Distributed by sideload (GitHub Releases), not Play Store — so Play *policy* is informational, while *platform* behavior is binding.

## 1. Foreground service types (API 34/35/36/37)

Since Android 14 (API 34) every FGS must declare a type in the manifest and hold `FOREGROUND_SERVICE` plus the type-specific permission; missing it throws `MissingForegroundServiceTypeException`/`SecurityException` ([FGS types](https://developer.android.com/develop/background-work/services/fgs/service-types), [FGS changes](https://developer.android.com/develop/background-work/services/fgs/changes)).

| Type | Permission | Runtime prerequisite | Fit for an always-on LAN socket |
|---|---|---|---|
| `connectedDevice` | `FOREGROUND_SERVICE_CONNECTED_DEVICE` | Declare **one** of `CHANGE_NETWORK_STATE`, `CHANGE_WIFI_STATE`, `CHANGE_WIFI_MULTICAST_STATE`, `NFC`, `TRANSMIT_IR` (normal/install-time permissions — **no runtime dialog**); or a BT/USB runtime grant | **Best fit.** "Interactions with external devices that require a Bluetooth, NFC, IR, USB, or network connection." No time limit. |
| `dataSync` | `FOREGROUND_SERVICE_DATA_SYNC` | None | Poor: Android 15+ caps all `dataSync` services at **6 h / 24 h**, then `Service.onTimeout()` → must `stopSelf()` or ANR ([timeout](https://developer.android.com/develop/background-work/services/fgs/timeout)). |
| `mediaPlayback` | `FOREGROUND_SERVICE_MEDIA_PLAYBACK` | None | Wrong semantics: "Continue audio or video playback from the background." The phone plays nothing. |
| `remoteMessaging` | `FOREGROUND_SERVICE_REMOTE_MESSAGING` | None | Wrong: "Transfer text messages from one device to another… continuity of a user's messaging tasks." |
| `specialUse` | `FOREGROUND_SERVICE_SPECIAL_USE` | None | Explicit fallback for uncovered cases; needs a `<property>` justification and Play review. Use only if `connectedDevice` is challenged. |

- Android's own background-data guide says to use `connectedDevice` for "Transferring data to a locally connected device … a local internet connection" ([data transfer options](https://developer.android.com/develop/background-work/background-tasks/data-transfer-options)). That is the legitimate type for "keep a network socket alive to a device on my LAN".
- **No** type exists for "keep a socket alive for remote control" specifically; `connectedDevice` is the closest correct one, `specialUse` the last resort.
- `dataSync`/`mediaPlayback`/camera/microphone/phoneCall can no longer be launched from `BOOT_COMPLETED` on Android 15+ ([Android 15 FGS changes](https://developer.android.com/about/versions/15/changes/foreground-service-types)).
- Apps targeting Android 12+ generally cannot start an FGS from the background (throws `ForegroundServiceStartNotAllowedException`); allowed triggers include a visible activity, a notification action, or a user action ([restrictions](https://developer.android.com/develop/background-work/services/fgs/restrictions-bg-start)). **Start the service from a foreground UI action or notification button, never from the socket's reconnect loop.**
- Android 16 (API 36) adds no new FGS-type rule relevant here, but adds **Local Network Protection** (see §5) ([Android 16 behavior changes](https://developer.android.com/about/versions/16/behavior-changes-16)).

## 2. MediaStyle vs a plain notification

**MediaStyle + `MediaSession` token is what produces system media controls** — lock screen, headset/Bluetooth media buttons, Android Auto/Wear ([MediaStyle](https://developer.android.com/reference/android/app/Notification.MediaStyle), [background playback](https://developer.android.com/media/media3/session/background-playback)).

Remote-control-only is explicitly contemplated by the platform:
- The media carousel lists "**Remote streams, such as those detected on external devices or cast sessions**" ([media controls](https://developer.android.com/media/implement/surfaces/mobile)).
- `Notification.MediaStyle.setRemotePlaybackInfo(deviceName, icon, chipIntent)` exists precisely "for media notifications associated with playback on a **remote device**" ([MediaStyle ref](https://developer.android.com/reference/androidx/media3/session/MediaStyleNotificationHelper.MediaStyle)).
- A session is not required to own a decoder; `audio_service` states it is "media agnostic… It does not care what audio your app plays" ([audio_service](https://pub.dev/packages/audio_service)).

Caveats:
- `androidx.media3`'s `MediaSessionService` **must** declare `foregroundServiceType="mediaPlayback"` ([MediaSessionService ref](https://developer.android.com/reference/androidx/media3/session/MediaSessionService)) and it **self-demotes out of the foreground 10 minutes after pause/stop/failure**, after which the system may destroy it ([background playback](https://developer.android.com/media/media3/session/background-playback)). That is hostile to a control surface that sits idle/paused.
- A plain ongoing notification with action buttons (`NotificationCompat` with `setOngoing(true)` / `flutter_local_notifications`) needs no media type, is simpler, and is robust — but gives **no** media carousel, lock-screen artwork, headset/Bluetooth transport buttons, or Android Auto.
- **Hybrid (recommended if media buttons matter):** create a `MediaSessionCompat` (or platform `MediaSession`) and post a `NotificationCompat.MediaStyle` notification **inside the `connectedDevice` FGS**. FGS type and notification style are independent; you get always-on socket survival *and* media controls without claiming `mediaPlayback`. From Android V, valid MediaStyle notifications get `FLAG_NO_CLEAR`.
- `setRemotePlaybackInfo` is annotated `MEDIA_CONTENT_CONTROL` (system/cast) — treat it as an optional polish, not a dependency.

## 3. Flutter packages

- **`flutter_foreground_task`** — mature (11.x, verified publisher, ~581 likes); hosts Dart logic in a dedicated FGS isolate with two-way comms; `startService(serviceTypes: [ForegroundServiceTypes.connectedDevice, …])`; up to 3 notification buttons with `onNotificationButtonPressed`/`onNotificationPressed`/`onNotificationDismissed`; `allowWakeLock`/`allowWifiLock`; battery-optimization request helper ([pub](https://pub.dev/packages/flutter_foreground_task), [API](https://pub.dev/documentation/flutter_foreground_task/latest/flutter_foreground_task/FlutterForegroundTask-class.html)). **Best off-the-shelf host.** No MediaSession/MediaStyle (buttons are plain actions).
- **`audio_service`** — mature (0.18.x, ~1.3k likes); hosts Dart in a background isolate; full MediaStyle/lockscreen/headset/Auto. But it declares `mediaPlayback` and is playback-shaped; `androidStopForegroundOnPause: true` (default) drops the FGS on pause, which would let the socket die — set `false` to keep it alive ([pub](https://pub.dev/packages/audio_service)). Use only if Auto/Wear/headset integration is a hard requirement.
- **`flutter_local_notifications`** — mature, verified publisher; notification display + actions. Its action callback runs in a short-lived background isolate and it does **not** host a long-lived socket loop; use it as the notification layer on top of an FGS host (or just use `flutter_foreground_task`). MediaStyle with a `MediaSession.Token` is explicitly **not supported** ([pub](https://pub.dev/packages/flutter_local_notifications)).
- **`media_kit`** — a player (libmpv), not a service/notification layer. Irrelevant for a control-only client; adds native weight ([pub](https://pub.dev/packages/media_kit)).
- **`wakelock_plus`** — screen wakelock only; its docs state it does **not** take partial CPU wake locks and does not keep the app alive in the background ([pub](https://pub.dev/packages/wakelock_plus)). Not a solution here.
- **`flutter_background_service`** — ~1.5k likes but last release Dec 2024 (5.1.0); FGS + battery-optimization disable, socket.io example. Older FGS-type ergonomics and stale maintenance vs `flutter_foreground_task` ([pub](https://pub.dev/packages/flutter_background_service)).
- **Custom Kotlin `MethodChannel` + `Service`** — most control: exact FGS type, a `MediaSession`/MediaStyle you fully own, a cached `FlutterEngine` you manage. Cost: native lifecycle code you must maintain. This is the right call if you want the hybrid in §2 without fighting a plugin.

Tradeoff summary: `flutter_foreground_task` covers (a) survival + (b) plain buttons with least effort; a thin custom native service is the only clean way to get (a) + persistent MediaSession controls under a `connectedDevice` type.

## 4. Dart isolates and `dart:io` sockets when backgrounded

- Backgrounding alone does not suspend the Dart VM, but the Android process importance drops; the OS may kill it or cut network. Users report `SocketException`/connection drops roughly 20 s–3 min after backgrounding on Android 13–15, and as little as 3–5 s with target SDK 35 ([flutter#164368](https://github.com/flutter/flutter/issues/164368), [dart-lang/http#877](https://github.com/dart-lang/http/issues/877)). Issue #164368 was **closed as invalid** — this is Android platform behavior, not a Flutter engine bug.
- Dart isolates are threads inside **one** process/FlutterEngine. There is no per-isolate OS scheduling: if the process survives, every isolate survives; if the process is killed, all die. So an isolate does **not** itself protect a socket — the **foreground service** (holding the process at foreground importance with an ongoing notification) is what keeps it alive. `flutter_foreground_task`/`flutter_background_service` host that isolate inside their FGS's engine.
- A running FGS also keeps the app out of **App Standby** ("app has a process currently in the foreground, either as an activity or foreground service") ([Doze](https://developer.android.com/training/monitoring-device-state/doze-standby)). Doze still "suspends network access" and "ignores wake locks", so a persistent socket is most reliable with a **partial wake lock + Wi-Fi lock + battery-optimization exemption**.
- Plugin/Dart gotchas:
  - Background entry points need `@pragma('vm:entry-point')` and often `DartPluginRegistrant.ensureInitialized()`.
  - Some plugins require an `Activity` context and cannot run from an FGS isolate.
  - Android 14+ allows the FGS notification to be dismissed — don't assume the service dies with the notification.
  - Debug-vs-release differences exist ([flutter#170904](https://github.com/flutter/flutter/issues/170904)); validate in release on a physical device.
  - Treat the socket as reconnectable regardless: keep the existing backoff/ping logic; listen for connectivity changes. FGS raises the odds, it is not a guarantee.

## 5. Doze, battery optimization, and OEM killers

- **Doze/App Standby:** official levers are a running FGS + ongoing notification, plus user-granted battery-optimization exemption (`isIgnoringBatteryOptimizations()`, `ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`) ([Doze](https://developer.android.com/training/monitoring-device-state/doze-standby)). The acceptable-use table lists "**Peripheral device companion app** … maintaining a persistent connection with the peripheral device" — closely analogous to holding a connection to the Harbor host, so requesting exemption is defensible. (Play prohibits direct exemption requests unless core function is affected — moot for sideload, relevant if ever distributed.)
- **OEM killers are real and FGS alone is not enough.** dontkillmyapp ranks Huawei #1, Xiaomi #2, OnePlus #3, Samsung #4 ([dontkillmyapp](https://dontkillmyapp.com/)); MIUI kills the FGS the moment the app is swiped from recents even with the notification showing ([flutter_foreground_task#343](https://github.com/Dev-hwang/flutter_foreground_task/issues/343)); `flutter_local_notifications` and `flutter_background_service` document the same and point to per-OEM settings ([fln caveats](https://pub.dev/packages/flutter_local_notifications), [fbs FAQ](https://pub.dev/packages/flutter_background_service)).
- Practical mitigations: an onboarding screen detecting the OEM and linking the right settings (Xiaomi *Autostart* + no battery restriction + lock in recents; Huawei *Protected apps*/launch manager; Samsung *Background usage limits* / remove from *Sleeping apps*), requesting notification permission on 13+, and requesting the battery-optimization exemption. Never promise uninterrupted operation.
- **Forward-looking blocker:** Android 17 (API 37) makes **Local Network Protection mandatory** — LAN sockets require the new `ACCESS_LOCAL_NETWORK` runtime permission (Nearby devices group), blocked by default when targeting 37. Android 16 is opt-in via `NEARBY_WIFI_DEVICES` ([local network permission](https://developer.android.com/privacy-and-security/local-network-permission), [Flutter guidance](https://docs.flutter.dev/platform-integration/android/local-network-permission), [flutter#184859](https://github.com/flutter/flutter/issues/184859)). A LAN remote-control app must plan for this; verify what the current Flutter stable's `flutter.targetSdkVersion` resolves to before bumping.

## Recommendation

- **Use a `connectedDevice` foreground service** as the survival mechanism: `FOREGROUND_SERVICE` + `FOREGROUND_SERVICE_CONNECTED_DEVICE`, and declare `CHANGE_WIFI_STATE` (install-time) to satisfy the runtime prerequisite. Do **not** use `dataSync` (6 h/24 h cap), `mediaPlayback`, or `remoteMessaging`.
- **Start it only from a visible user action**, and handle `ForegroundServiceStartNotAllowedException` (Android 12+) and `SecurityException` (Android 14+ missing permission) by falling back to a foreground prompt.
- **Host the socket in `flutter_foreground_task`** (`serviceTypes: [connectedDevice]`, `allowWakeLock`, `allowWifiLock`) and drive the notification from its `updateService`/buttons API. Avoid `flutter_background_service` (stale) and `media_kit`/`wakelock_plus` (not applicable).
- **If headset/Bluetooth/lock-screen/Auto controls are required**, add a `MediaSessionCompat` + `NotificationCompat.MediaStyle` **inside the same `connectedDevice` service** rather than adopting media3 `MediaSessionService` (it forces `mediaPlayback` and demotes 10 min after pause) or `audio_service` (playback-shaped; would need `androidStopForegroundOnPause: false`). If those controls are optional, a plain ongoing notification with buttons is simpler and equally robust.
- **Keep the app's reconnect schedule as the source of truth.** The FGS prevents process death and App Standby, but the platform can still cut network under Doze and kill the process under memory pressure; heartbeats + connectivity-triggered reconnect must remain.
- **Ask the user to exempt the app from battery optimization** (defensible companion-device use case) and ship per-OEM enablement guidance for Xiaomi/Huawei/Samsung; request `POST_NOTIFICATIONS` on 13+.
- **Add Android 17 readiness for LAN access** (`ACCESS_LOCAL_NETWORK` + runtime request) before ever targeting API 37; track flutter/flutter#184859.
- **Verify on real, aggressive OEM hardware** with screen-off and `adb shell dumpsys deviceidle force-idle`, in release builds, before declaring it solved.
