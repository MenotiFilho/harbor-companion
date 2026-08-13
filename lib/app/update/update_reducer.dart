// Pure self-update state model (tickets 28 + 30).
//
// `(SelfUpdateState, SelfUpdateEvent) => SelfUpdateState` reducer producing an
// effects buffer the controller drains through injected side-channels (GitHub
// releases client, version provider, ota_update installer, install-permission
// adapter). No I/O, no timers.
//
// Check half (ticket 28): on launch, ask GitHub for the latest non-prerelease,
// non-draft release, compare its versionCode (parsed from the `v<name>+<code>`
// tag) to the local versionCode (`package_info_plus` build number), and prompt
// with the newer version. Same/downgrade are silent; network failure is quiet.
//
// Install half (ticket 30): on the user's tap, gate on the install permission
// (lazy, package-scoped), then hand the APK to ota_update — which downloads,
// verifies the SHA-256, and triggers the system install dialog. A checksum
// mismatch or download failure never installs and surfaces an error; there is
// no auto-retry.
//
// Effects vocabulary (the Notifier → adapter surface):
//   `check:<seq>`            → fetch GET /repos/{owner}/{repo}/releases/latest
//   `prompt`                 → show the update prompt (UI reads `promptVisible`)
//   `install:<seq>`          → controller checks canRequestPackageInstalls()
//   `installApk`             → controller runs ota_update (download + verify
//                              + install in one call; url/sha256 read from
//                              state.update, since the effect carries no payload)
//   `grantInstallPermission` → controller opens the "Install unknown apps" screen
//   `fail:<reason>`          → log the failure quietly (no modal, no retry)

library;

/// Parses the versionCode out of a release tag `v<versionName>+<versionCode>`.
/// Null when the tag has no parseable integer code (e.g. no `+` suffix).
int? parseVersionCodeFromTag(String tag) {
  final plus = tag.lastIndexOf('+');
  if (plus < 0) return null;
  return int.tryParse(tag.substring(plus + 1).trim());
}

/// The display name part of a release tag (`v1.2.3+4` → `1.2.3`).
String parseVersionNameFromTag(String tag) {
  final plus = tag.lastIndexOf('+');
  var name = plus < 0 ? tag : tag.substring(0, plus);
  if (name.startsWith('v')) name = name.substring(1);
  return name;
}

enum UpdateStatus {
  idle,
  checking,
  upToDate,
  hasUpdate,
  failed,

  /// Downloading / verifying / installing the accepted update (inside
  /// ota_update). The user already consented and tapped Update.
  installing,

  /// The install failed (checksum mismatch, download error, or a denied
  /// install-permission grant). Never auto-retries.
  installFailed,
}

/// The latest release as the GitHub client hands it to the reducer.
/// [versionCode] and [versionName] come from the tag; [notes] is the release
/// body (display only); [downloadUrl] + [sha256] are the APK asset's
/// `browser_download_url` and hex digest, needed by the install half.
class ReleaseInfo {
  final int versionCode;
  final String versionName;
  final String tagName;
  final String? notes;
  final String? downloadUrl;
  final String? sha256;
  const ReleaseInfo({
    required this.versionCode,
    required this.versionName,
    required this.tagName,
    this.notes,
    this.downloadUrl,
    this.sha256,
  });
}

class SelfUpdateState {
  final UpdateStatus status;
  final int? localVersionCode;
  final String? localVersionName; // display only, never used for logic
  final int checkSeq; // generation counter (stale-result guard)
  final int installSeq; // generation counter for the install half
  final ReleaseInfo? update; // the newer release, when hasUpdate
  final bool promptVisible;
  final bool manualCheckPending; // a manual check awaits its result

  /// The install is paused waiting for the "Install unknown apps" grant; the
  /// settings screen was opened and the controller re-checks on resume.
  final bool awaitingInstallPermission;
  final String? lastError;
  final String? notice;

  /// Effects buffer: the reducer appends effects here; the controller drains
  /// them. The one mutable field (impure by convention).
  final List<String> effects;

  SelfUpdateState({
    this.status = UpdateStatus.idle,
    this.localVersionCode,
    this.localVersionName,
    this.checkSeq = 0,
    this.installSeq = 0,
    this.update,
    this.promptVisible = false,
    this.manualCheckPending = false,
    this.awaitingInstallPermission = false,
    this.lastError,
    this.notice,
    List<String>? effects,
  }) : effects = effects ?? <String>[];

  SelfUpdateState copy({
    UpdateStatus? status,
    int? localVersionCode,
    String? localVersionName,
    int? checkSeq,
    int? installSeq,
    ReleaseInfo? update,
    bool clearUpdate = false,
    bool? promptVisible,
    bool? manualCheckPending,
    bool? awaitingInstallPermission,
    String? lastError,
    bool clearLastError = false,
    String? notice,
    bool clearNotice = false,
    List<String>? effects,
  }) {
    return SelfUpdateState(
      status: status ?? this.status,
      localVersionCode: localVersionCode ?? this.localVersionCode,
      localVersionName: localVersionName ?? this.localVersionName,
      checkSeq: checkSeq ?? this.checkSeq,
      installSeq: installSeq ?? this.installSeq,
      update: clearUpdate ? null : (update ?? this.update),
      promptVisible: promptVisible ?? this.promptVisible,
      manualCheckPending: manualCheckPending ?? this.manualCheckPending,
      awaitingInstallPermission:
          awaitingInstallPermission ?? this.awaitingInstallPermission,
      lastError: clearLastError ? null : (lastError ?? this.lastError),
      notice: clearNotice ? null : (notice ?? this.notice),
      effects: effects ?? this.effects,
    );
  }
}

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------

sealed class SelfUpdateEvent {
  const SelfUpdateEvent();
}

/// App cold start: run the launch check (once per launch — the controller only
/// dispatches this once, and a foreground return is [SetForegrounded], never a
/// second [Launch]).
class Launch extends SelfUpdateEvent {
  const Launch();
}

/// App lifecycle transition. Returning to the foreground never re-checks; only
/// [Launch] and [CheckRequested] do. This is a deliberate no-op — the launch
/// check fires once, and a foreground return is ignored (no double-fire).
class SetForegrounded extends SelfUpdateEvent {
  final bool value;
  const SetForegrounded(this.value);
}

/// Manual "Check for updates" from Settings. Always re-checks, and surfaces a
/// quiet notice when there is nothing new.
class CheckRequested extends SelfUpdateEvent {
  const CheckRequested();
}

/// The version provider reported the local build (before the launch check).
class LocalVersionLoaded extends SelfUpdateEvent {
  final int versionCode;
  final String versionName;
  const LocalVersionLoaded(this.versionCode, this.versionName);
}

/// The releases client returned the latest release.
class RemoteResult extends SelfUpdateEvent {
  final int seq;
  final ReleaseInfo info;
  const RemoteResult(this.seq, this.info);
}

/// The releases client found no published release (a 404, not an error).
class NoRelease extends SelfUpdateEvent {
  final int seq;
  const NoRelease(this.seq);
}

/// The releases client failed (network/HTTP). Quiet: log, no modal, no retry.
class CheckFailed extends SelfUpdateEvent {
  final int seq;
  final String reason;
  const CheckFailed(this.seq, this.reason);
}

/// The user closed the update prompt.
class DismissPrompt extends SelfUpdateEvent {
  const DismissPrompt();
}

/// The user tapped Update in the prompt. Begins the install half: the reducer
/// emits `install:<seq>` and the controller checks the install permission.
class UpdateRequested extends SelfUpdateEvent {
  const UpdateRequested();
}

/// The result of `canRequestPackageInstalls()`. Granted → proceed to
/// `download`; denied → open the "Install unknown apps" screen (or, if we were
/// already waiting and came back still-denied, fail).
class InstallPermission extends SelfUpdateEvent {
  final int seq;
  final bool granted;
  const InstallPermission(this.seq, this.granted);
}

/// ota_update reached the install step (the system dialog appeared). Success.
class InstallTriggered extends SelfUpdateEvent {
  const InstallTriggered();
}

/// ota_update reported a SHA-256 mismatch: never install, surface the failure.
class ChecksumMismatch extends SelfUpdateEvent {
  const ChecksumMismatch();
}

/// The download/install failed (network, internal, or permission error).
class InstallFailed extends SelfUpdateEvent {
  final String reason;
  const InstallFailed(this.reason);
}

// ---------------------------------------------------------------------------
// Reducer
// ---------------------------------------------------------------------------

SelfUpdateState updateReduce(SelfUpdateState s, SelfUpdateEvent e) {
  switch (e) {
    case Launch():
      return _beginCheck(s, manual: false);
    case CheckRequested():
      return _beginCheck(s, manual: true);
    case SetForegrounded():
      // A foreground/background transition never triggers a check — only
      // Launch and CheckRequested do. Deliberate no-op (no double-fire).
      return s;
    case LocalVersionLoaded(versionCode: final code, versionName: final name):
      return s.copy(localVersionCode: code, localVersionName: name);
    case RemoteResult(seq: final seq, info: final info):
      return _onRemoteResult(s, seq, info);
    case NoRelease(seq: final seq):
      return _onNoUpdate(s, seq, null);
    case CheckFailed(seq: final seq, reason: final reason):
      return _onCheckFailed(s, seq, reason);
    case DismissPrompt():
      return s.copy(promptVisible: false);
    case UpdateRequested():
      return _beginInstall(s);
    case InstallPermission(seq: final seq, granted: final granted):
      return _onInstallPermission(s, seq, granted);
    case InstallTriggered():
      return _onInstallTriggered(s);
    case ChecksumMismatch():
      return _failInstall(
          s, 'Verification failed: the downloaded APK did not match its checksum');
    case InstallFailed(reason: final reason):
      return _failInstall(s, reason);
  }
}

SelfUpdateState _beginCheck(SelfUpdateState s, {required bool manual}) {
  final seq = s.checkSeq + 1;
  var next = s.copy(
    status: UpdateStatus.checking,
    checkSeq: seq,
    clearUpdate: true,
    promptVisible: false,
    manualCheckPending: manual,
    clearLastError: true,
    clearNotice: true,
  );
  next.effects.add('check:$seq');
  return next;
}

SelfUpdateState _onRemoteResult(SelfUpdateState s, int seq, ReleaseInfo info) {
  if (!_isCurrent(s, seq)) return s.copy(notice: 'stale check result ignored');
  final local = s.localVersionCode;
  if (local != null && info.versionCode > local) {
    var next = s.copy(
      status: UpdateStatus.hasUpdate,
      update: info,
      promptVisible: true,
      manualCheckPending: false,
      clearNotice: true,
    );
    next.effects.add('prompt');
    return next;
  }
  // Equal or downgrade: ignored. A manual check still gets a quiet notice.
  return _onNoUpdate(s, seq, info);
}

SelfUpdateState _onNoUpdate(SelfUpdateState s, int seq, ReleaseInfo? info) {
  if (!_isCurrent(s, seq)) return s.copy(notice: 'stale check result ignored');
  final manual = s.manualCheckPending;
  return s.copy(
    status: UpdateStatus.upToDate,
    clearUpdate: true,
    promptVisible: false,
    manualCheckPending: false,
    notice: manual ? 'No update available' : null,
    clearNotice: !manual,
  );
}

SelfUpdateState _onCheckFailed(SelfUpdateState s, int seq, String reason) {
  if (!_isCurrent(s, seq)) return s.copy(notice: 'stale check failure ignored');
  final manual = s.manualCheckPending;
  var next = s.copy(
    status: UpdateStatus.failed,
    clearUpdate: true,
    promptVisible: false,
    manualCheckPending: false,
    lastError: reason,
    notice: manual ? 'Could not check for updates' : null,
    clearNotice: !manual,
  );
  next.effects.add('fail:$reason');
  return next;
}

bool _isCurrent(SelfUpdateState s, int seq) =>
    seq == s.checkSeq && s.status == UpdateStatus.checking;

// ---------------------------------------------------------------------------
// Install half (download → verify → install, ticket 30)
// ---------------------------------------------------------------------------

SelfUpdateState _beginInstall(SelfUpdateState s) {
  final update = s.update;
  if (update == null || update.downloadUrl == null || update.sha256 == null) {
    return _failInstall(s, 'No downloadable APK for this release');
  }
  final seq = s.installSeq + 1;
  var next = s.copy(
    status: UpdateStatus.installing,
    installSeq: seq,
    promptVisible: false,
    awaitingInstallPermission: false,
    clearLastError: true,
    clearNotice: true,
  );
  next.effects.add('install:$seq');
  return next;
}

bool _isCurrentInstall(SelfUpdateState s, int seq) =>
    seq == s.installSeq && s.status == UpdateStatus.installing;

SelfUpdateState _onInstallPermission(SelfUpdateState s, int seq, bool granted) {
  if (!_isCurrentInstall(s, seq)) return s;
  if (granted) {
    var next = s.copy(awaitingInstallPermission: false);
    next.effects.add('installApk');
    return next;
  }
  if (s.awaitingInstallPermission) {
    // Came back from the settings screen still without the grant: stop instead
    // of re-opening it in a loop.
    return _failInstall(s, 'Install permission not granted');
  }
  var next = s.copy(awaitingInstallPermission: true);
  next.effects.add('grantInstallPermission');
  return next;
}

SelfUpdateState _onInstallTriggered(SelfUpdateState s) {
  // The system install dialog has appeared; the OS takes over from here (and
  // may restart the app). Treat the app as up to date.
  return s.copy(
    status: UpdateStatus.upToDate,
    clearUpdate: true,
    promptVisible: false,
    awaitingInstallPermission: false,
    clearLastError: true,
    clearNotice: true,
  );
}

SelfUpdateState _failInstall(SelfUpdateState s, String reason) {
  return s.copy(
    status: UpdateStatus.installFailed,
    clearUpdate: true,
    promptVisible: false,
    awaitingInstallPermission: false,
    lastError: reason,
    notice: reason,
  );
}
