# Android Self-Update via GitHub Releases — Primary-Source Research

Source of truth: first-party documentation only — Android developer docs,
Google support docs, GitHub REST docs, and pub.dev/package-source READMEs. Every
factual claim carries an inline citation (URL + doc name) so it can be
re-verified. No blog write-ups are treated as authoritative. Research date:
2026-08-12.

Scope: can Harbor Companion (a Flutter, sideloaded Android app) update itself by
"check on launch → download APK from GitHub Releases → verify checksum → trigger
the system installer", and what are the hard platform limits?

---

## 1. Package-installer path on Android

Three mechanisms exist for an app to get an APK installed. They are all gated by
user consent or device-management privileges; **none of them offers a fully
silent install to a normal sideloaded app.**

### 1.1 `REQUEST_INSTALL_PACKAGES` (the "install unknown apps" permission)

`android.permission.REQUEST_INSTALL_PACKAGES` — *"Allows an application to
request installing packages. Apps targeting APIs greater than 25 must hold this
permission in order to use `Intent.ACTION_INSTALL_PACKAGE`."* It is listed with
protection level `signature`, added in API 23
(https://developer.android.com/reference/android/Manifest.permission#REQUEST_INSTALL_PACKAGES —
"Manifest.permission, REQUEST_INSTALL_PACKAGES").

It is **not** a runtime permission in the usual sense: it is granted per-app via
the Settings screen *"Install unknown apps"*, not via a runtime `request()` call.
The screen is reached with `Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES`
(constant `"android.settings.MANAGE_UNKNOWN_APP_SOURCES"`, added in API 26) —
*"Activity Action: Show settings to allow configuration of trusted external
sources. Input: Optionally, the Intent's data URI can specify the application
package name to directly invoke the management GUI specific to the package
name."* (https://developer.android.com/reference/android/provider/Settings#ACTION_MANAGE_UNKNOWN_APP_SOURCES —
"Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES").

The programmatic check is `PackageManager.canRequestPackageInstalls()` (added in
API 26): *"Checks whether the calling package is allowed to request package
installs through package installer. Apps are encouraged to call this API before
launching the package installer via intent `Intent.ACTION_INSTALL_PACKAGE`.
Starting from Android O, the user can explicitly choose what external sources
they trust to install apps on the device. If this API returns `false`, the
install request will be blocked by the package installer and a dialog will be
shown to the user with an option to launch settings to change their preference."*
(https://developer.android.com/reference/android/content/pm/PackageManager#canRequestPackageInstalls() —
"PackageManager.canRequestPackageInstalls").

### 1.2 `ACTION_INSTALL_PACKAGE` intent

`android.intent.action.INSTALL_PACKAGE` (constant
`ACTION_INSTALL_PACKAGE`) — *"Activity Action: Launch application installer.
Input: The data must be a `content:` URI at which the application can be
retrieved… Output: If `EXTRA_RETURN_RESULT`, returns whether the install
succeeded. Note: If your app is targeting API level higher than 25 you need to
hold `Manifest.permission.REQUEST_INSTALL_PACKAGES` in order to launch the
application installer."* It is **deprecated in API 29** with the note *"use
`PackageInstaller` instead"*
(https://developer.android.com/reference/android/content/Intent#ACTION_INSTALL_PACKAGE —
"Intent.ACTION_INSTALL_PACKAGE").

This launches the system install UI and **always requires a user tap** (or at
minimum a user-visible confirmation). It is the mechanism behind
`ACTION_VIEW`-on-an-APK and `FileProvider` + `application/vnd.android.package-archive`
installs.

### 1.3 `PackageInstaller` API

`PackageInstaller` — *"Offers the ability to install, upgrade, and remove
applications on the device… An app is delivered for installation through a
`PackageInstaller.Session`, which any app can create. Once the session is
created, the installer can stream one or more APKs into place until it decides
to either commit or destroy the session. **Committing may require user
intervention to complete the installation, unless the caller falls into one of
the following categories, in which case the installation will complete
automatically: the device owner, the affiliated profile owner.**"*
(https://developer.android.com/reference/android/content/pm/PackageInstaller —
"PackageInstaller").

The two exceptions listed are the *only* automatic/silent paths. This is the
canonical statement of the rule.

### 1.4 What a sideloaded app can and cannot do

- **Can:** request the *Install unknown apps* grant (`REQUEST_INSTALL_PACKAGES`),
  check it via `canRequestPackageInstalls()`, then invoke either the
  `ACTION_INSTALL_PACKAGE` intent or a `PackageInstaller.Session` to start an
  install — both of which surface the system install UI.
- **Cannot:** install silently. A normal sideloaded app is neither the device
  owner nor an affiliated profile owner, so a `PackageInstaller.Session` commit
  *"may require user intervention"* (i.e. a user tap on the confirmation
  dialog). This is corroborated independently by the `ota_update` package's own
  README, which states silent install is for *system apps* only and that
  *"regular apps (Play Store, sideloaded) show the standard installation prompt"*
  (https://github.com/4Q-s-r-o/ota_update — "ota_update README, Silent
  Installation (System Apps Only)").

**Conclusion for topic 1: there is no fully-silent install path for a normal
sideloaded app.** The best achievable is one user tap on the system install
dialog, after the user has already granted *Install unknown apps* once.

---

## 2. Android 13+ "restricted settings"

### 2.1 The behavior

Android 13 introduced *"restricted settings"*: certain sensitive settings
toggles can be blocked for an app until the user opts in.

The first-party description (Google Help) states: *"To protect you from harmful
apps, some device settings may be restricted when you install an app. These
restricted settings can't be changed unless you allow restricted settings."* The
flow to opt in is *Settings → Apps → <app> → More → Allow restricted settings*,
and it is explicitly *"Android 13 and up"*. Accessibility services are the named
example — *"an app that's designed to support people with disabilities might ask
you to turn on accessibility settings. With access to accessibility settings,
the app can read content on your screen and interact with apps on your behalf"*
(https://support.google.com/android/answer/12623953 — "Learn about restricted
settings", Google Help).

The affected toggle types are the "special access" settings, chiefly
**AccessibilityService** and **NotificationListenerService** (the same class of
toggles an app reaches via `Settings.ACTION_ACCESSIBILITY_SETTINGS` /
`ACTION_NOTIFICATION_LISTENER_SETTINGS`). The trigger for the restriction is
that the app was installed outside an app store (i.e. sideloaded via *unknown
sources*), so the restriction is specific to sideloaded apps — not apps from
Play. Note that this behavior is *not* given a dedicated developer "behavior
change" entry on developer.android.com: the authoritative first-party source for
it is the Google Help page above, and the developer-facing reference is thin.

### 2.2 Interaction with self-update

Restricted settings and the *install unknown apps* permission are **orthogonal**:

- *Install unknown apps* (`REQUEST_INSTALL_PACKAGES`) governs whether the app
  may hand a new APK to the system installer. It is required for the self-update
  flow itself.
- *Restricted settings* governs whether the app may toggle sensitive
  accessibility/notification-listener services. It is only relevant to an app
  that actually ships such a service.

For Harbor Companion the practical consequences are:

1. The self-update install flow needs only the *Install unknown apps* grant.
2. The grant is scoped per package (see §1.1 — the settings intent accepts a
   `package:` data URI), so it survives an **upgrade** of the same app but is
   lost on a full **uninstall/reinstall**.
3. A freshly sideloaded or freshly updated (still-sideloaded) Harbor Companion
   remains a sideloaded app for the purposes of restricted settings: if a future
   version adds an accessibility or notification-listener service, its toggle
   would be gated behind *Allow restricted settings* until the user opts in.

---

## 3. GitHub Releases API

### 3.1 "Latest release" endpoint

`GET /repos/{owner}/{repo}/releases/latest` — *"View the latest published full
release for the repository. The latest release is the most recent
non-prerelease, non-draft release, sorted by the `created_at` attribute."*
(https://docs.github.com/en/rest/releases/releases#get-the-latest-release —
"REST API endpoints for releases, Get the latest release"). Returns `404` if
the repo has no releases.

The response is a `Release` object whose relevant fields are `tag_name` and
`assets[]`; each asset carries `name`, `size`, `content_type`, `digest`, and
`browser_download_url` — the example shows
`"tag_name": "v1.0.0"`, `"draft": false`, `"prerelease": false`, and
`"assets": [ { "name": "example.zip", "size": 1024, "digest": "sha256:2151…", "browser_download_url": "https://github.com/octocat/Hello-World/releases/download/v1.0.0/example.zip" } ]`
(https://docs.github.com/en/rest/releases/releases#get-the-latest-release —
response schema). Note the `digest` field (an `sha256:`-prefixed value) is the
only checksum GitHub itself exposes on an asset.

### 3.2 Downloading an asset

`GET /repos/{owner}/{repo}/releases/assets/{asset_id}` — *"To download the
asset's binary content: if within a browser, fetch the location specified in the
`browser_download_url` key… Alternatively, set the `Accept` header to
`application/octet-stream`. The API will either redirect the client to the
location, or stream it directly if possible. API clients should handle both a
`200` or `302` response."*
(https://docs.github.com/en/rest/releases/assets#get-a-release-asset — "REST API
endpoints for release assets, Get a release asset").

For a public repo, **no authentication is required** to read releases or download
assets. Both endpoints state: *"This endpoint can be used without authentication
or the aforementioned permissions if only public resources are requested."*
(https://docs.github.com/en/rest/releases/releases#get-the-latest-release and
https://docs.github.com/en/rest/releases/assets#get-a-release-asset).

### 3.3 Rate limits (anonymous/unauthenticated)

*"The primary rate limit for unauthenticated requests is **60 requests per
hour**. Unauthenticated requests are associated with the originating IP address,
not with the user or application that made the request."* Authenticated requests
(e.g. a PAT) get **5,000/hour**. Rate-limit state is reported via the
`x-ratelimit-limit` / `x-ratelimit-remaining` / `x-ratelimit-reset` response
headers; exceeding the limit returns `403` or `429`
(https://docs.github.com/en/rest/using-the-rest-api/rate-limits-for-the-rest-api —
"Rate limits for the REST API").

Practical note: the 60/hr cap applies to `api.github.com` REST calls (the
`/releases/latest` lookup). The binary asset fetch via `browser_download_url`
(`github.com/.../releases/download/...`) is **not** an `api.github.com` REST
call — it is a redirect to object storage — so the check-on-launch flow makes at
most one or two counted API requests per launch.

---

## 4. Flutter packages for download + install

Checked against the pub.dev API (version, publish date, SDK constraint) and each
package's GitHub repo (last push, maintenance). "Fits" = covers
*check-on-launch → download APK → verify checksum → trigger system installer*
without inventing the downloader/installer ourselves.

| Package | Latest | Published (last update) | SDK constraint | Dart 3 / null-safe | What it does | Fits? |
| --- | --- | --- | --- | --- | --- | --- |
| **ota_update** | 7.1.0 | 2025-12-03 | `>=3.7.0 <4.0.0` | Dart 3 only | Download APK w/ progress + **sha256 checksum verify** + install via intent or `PackageInstaller` | **Yes** |
| upgrader | 13.6.0 | 2026-07-23 | `>=3.5.0 <4.0.0` | Dart 3 only | Prompts upgrade vs. **app-store** version (Play/App Store); does not download/install an APK | No |
| flutter_app_installer | 2.0.0 | 2026-03-19 | `>=3.0.0 <4.0.0` | Dart 3 only | `installApk(filePath, silently:)` via intent; silent = system/root only | Partial (install only) |
| app_installer | 1.3.1 | 2024-12-03 | `>=2.12.0 <4.0.0` | null-safe, Dart 3 compatible | Open store / review / install APK (Android+iOS+macOS) | Partial (install only) |
| sodium_updater | — | — | — | — | **Does not exist on pub.dev** (API returns `NoSuchKey`) | — |

Sources: pub.dev package pages — https://pub.dev/packages/ota_update,
https://pub.dev/packages/upgrader, https://pub.dev/packages/flutter_app_installer,
https://pub.dev/packages/app_installer (metadata via `https://pub.dev/api/packages/<name>`);
repos — https://github.com/4Q-s-r-o/ota_update, https://github.com/larryaasen/upgrader,
https://github.com/irvine1231/flutter_app_installer, https://github.com/BytesZero/app_installer.

Notes per package:

- **ota_update** — `OtaUpdate().execute(url, destinationFilename:, sha256checksum:)`
  downloads, optionally validates an SHA-256 checksum, and triggers install;
  since 7.1.0 it can use `PackageInstaller` (`usePackageInstaller: true`). Its
  README is explicit that regular (sideloaded) apps still get the standard
  install prompt, and that silent install is system-app-only. Requires
  `REQUEST_INSTALL_PACKAGES` and (for progress) a manifest receiver, plus
  desugaring on Android. Active (repo pushed 2026-02-25, 191 stars).
  (https://github.com/4Q-s-r-o/ota_update — README).
- **upgrader** — store-comparison only ("prompting users to upgrade when there
  is a newer version of the app in the store"). Does not do APK download or
  install, so it does not fit the GitHub-Releases sideload flow. It is the most
  starred/maintained (640 stars, pushed 2026-07-23) but the wrong tool here.
  (https://github.com/larryaasen/upgrader — README).
- **flutter_app_installer** — install-only helper; `installApk(filePath:)` via
  `FileProvider` + intent, or `silently: true` which the README says requires a
  system app or root. No download, no checksum. Low traction (4 stars).
  (https://github.com/irvine1231/flutter_app_installer — README).
- **app_installer** — install + store/review helper across platforms; the
  Android install step is an APK install only (no download/checksum). Requires
  read-storage on Android.
  (https://github.com/BytesZero/app_installer — README).

**Recommendation: `ota_update`.** It is the only one that covers download +
checksum verification + install in a single call, it is actively maintained, and
its install path correctly maps to the platform reality established in §1 (user
tap required for a sideloaded app). The "check on launch" half (GitHub `/releases/latest`
+ `versionCode` comparison from §3/§5) is thin app logic and belongs in our own
code, not in any of these packages.

---

## 5. APK versioning: `versionCode` vs `versionName`

From the Android "Version your app" doc
(https://developer.android.com/studio/publish/versioning — "Version your app"):

- **`versionCode`** — *"A positive integer used as an internal version number.
  This number helps determine whether one version is more recent than another,
  with higher numbers indicating more recent versions… The Android system uses
  the `versionCode` value to protect against downgrades by preventing users from
  installing an APK with a lower `versionCode` than the version currently
  installed… The value is a positive integer so that other apps can
  programmatically evaluate it—to check an upgrade or downgrade relationship."*
- **`versionName`** — *"A string used as the version number shown to users…
  The `versionName` is the only value displayed to users."*

For a *"is there a newer version"* comparison, **`versionCode` (the integer) is
the correct field** — it is the monotonic, machine-comparable value the OS
itself uses, and `versionName` is a display-only, non-normative string. A
comparison should therefore be `remote.versionCode > local.versionCode`.
Practical bounds: `versionCode` must be a positive integer and *"the greatest
value Google Play allows for `versionCode` is `2100000000`"* (same doc). In the
Flutter/Gradle build, `versionCode` maps to `--build-number` and `versionName`
to `--build-name` (https://developer.android.com/studio/publish/versioning).

---

## 6. Gotchas / verdict

### Verdict

Android self-update via GitHub Releases **is feasible** for a sideloaded Flutter
app, with one hard limit: **the install always ends in a user tap** (no silent
path for non-device-owner apps — §1.4). The shape is: on launch, `GET /releases/latest`
(60/hr anonymous, per IP — §3.3), compare `versionCode` (§5), download the asset
via `browser_download_url`, verify the `sha256` digest (§3.1), and hand the APK
to the installer (`ota_update` recommended — §4). The user grants *Install
unknown apps* once, then taps through the system install dialog on each update.

### Gotchas

- **No silent install, ever.** `PackageInstaller.Session` commit completes
  automatically only for *device owner / affiliated profile owner* (§1.3). Any
  package advertising silent install (e.g. `flutter_app_installer`'s
  `silently: true`, `ota_update`'s system-app mode) works only on system/rooted
  devices.
- **`ACTION_INSTALL_PACKAGE` is deprecated** (API 29) in favor of
  `PackageInstaller`, but both still need `REQUEST_INSTALL_PACKAGES` for apps
  targeting >25 (§1.2).
- **"Install unknown apps" is per-package** and survives upgrades but not
  uninstall/reinstall (§1.1, §2.2). A user who clears the app data or
  reinstalls must re-grant it; check `canRequestPackageInstalls()` before
  invoking the installer and route to `ACTION_MANAGE_UNKNOWN_APP_SOURCES` if
  false.
- **Anonymous rate limit is 60/hr per IP** on `api.github.com`; the `/releases/latest`
  check should be infrequent and cached (only on launch), and the binary download
  should use `browser_download_url` rather than the `api.github.com` asset
  endpoint (§3.3).
- **`/releases/latest` skips prereleases and drafts** and sorts by `created_at`
  of the commit, not publish date (§3.1) — don't use it if you want to offer
  pre-release channel builds; use `GET /releases/{owner}/{repo}/releases` +
  filter in that case.
- **Checksum source**: GitHub's asset `digest` field (`sha256:…`) is the only
  checksum GitHub exposes (§3.1); if you want a stronger/signed guarantee, sign
  the APK and rely on Android's signature verification rather than a bare hash
  over HTTP.
- **Restricted settings (Android 13+)** does not block the *install* flow, but a
  future accessibility/notification-listener feature in a sideloaded Harbor
  Companion would be gated behind *Allow restricted settings* (§2).
- **`versionCode` must be a positive, strictly-increasing integer** and is capped
  at `2100000000` (§5). Compare on `versionCode`, never `versionName`.

---

## Source index

- Android — `REQUEST_INSTALL_PACKAGES`: https://developer.android.com/reference/android/Manifest.permission#REQUEST_INSTALL_PACKAGES
- Android — `ACTION_INSTALL_PACKAGE`: https://developer.android.com/reference/android/content/Intent#ACTION_INSTALL_PACKAGE
- Android — `PackageInstaller`: https://developer.android.com/reference/android/content/pm/PackageInstaller
- Android — `canRequestPackageInstalls()`: https://developer.android.com/reference/android/content/pm/PackageManager#canRequestPackageInstalls()
- Android — `ACTION_MANAGE_UNKNOWN_APP_SOURCES`: https://developer.android.com/reference/android/provider/Settings#ACTION_MANAGE_UNKNOWN_APP_SOURCES
- Android — versioning (`versionCode`/`versionName`): https://developer.android.com/studio/publish/versioning
- Google Help — "Learn about restricted settings": https://support.google.com/android/answer/12623953
- GitHub — "Get the latest release": https://docs.github.com/en/rest/releases/releases#get-the-latest-release
- GitHub — "Get a release asset": https://docs.github.com/en/rest/releases/assets#get-a-release-asset
- GitHub — "Rate limits for the REST API": https://docs.github.com/en/rest/using-the-rest-api/rate-limits-for-the-rest-api
- pub.dev — ota_update / upgrader / flutter_app_installer / app_installer: https://pub.dev/packages/{name}
- GitHub — ota_update: https://github.com/4Q-s-r-o/ota_update · upgrader: https://github.com/larryaasen/upgrader · flutter_app_installer: https://github.com/irvine1231/flutter_app_installer · app_installer: https://github.com/BytesZero/app_installer
