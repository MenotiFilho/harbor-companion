// Pure self-update check state model (ticket 28).
//
// `(SelfUpdateState, SelfUpdateEvent) => SelfUpdateState` reducer producing an
// effects buffer the controller drains through injected side-channels (GitHub
// releases client, version provider). No I/O, no timers.
//
// The check half only: on launch, ask GitHub for the latest non-prerelease,
// non-draft release, compare its versionCode (parsed from the `v<name>+<code>`
// tag) to the local versionCode (`package_info_plus` build number), and prompt
// with the newer version. Same/downgrade are silent; network failure is quiet.
//
// Effects vocabulary (the Notifier → adapter surface):
//   `check:<seq>`   → fetch GET /repos/{owner}/{repo}/releases/latest
//   `prompt`        → show the update prompt (UI reads `promptVisible`)
//   `fail:<reason>` → log the failure quietly (no modal, no retry)

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

enum UpdateStatus { idle, checking, upToDate, hasUpdate, failed }

/// The latest release as the GitHub client hands it to the reducer.
/// [versionCode] and [versionName] come from the tag; [notes] is the release
/// body (display only).
class ReleaseInfo {
  final int versionCode;
  final String versionName;
  final String tagName;
  final String? notes;
  const ReleaseInfo({
    required this.versionCode,
    required this.versionName,
    required this.tagName,
    this.notes,
  });
}

class SelfUpdateState {
  final UpdateStatus status;
  final int? localVersionCode;
  final String? localVersionName; // display only, never used for logic
  final int checkSeq; // generation counter (stale-result guard)
  final ReleaseInfo? update; // the newer release, when hasUpdate
  final bool promptVisible;
  final bool manualCheckPending; // a manual check awaits its result
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
    this.update,
    this.promptVisible = false,
    this.manualCheckPending = false,
    this.lastError,
    this.notice,
    List<String>? effects,
  }) : effects = effects ?? <String>[];

  SelfUpdateState copy({
    UpdateStatus? status,
    int? localVersionCode,
    String? localVersionName,
    int? checkSeq,
    ReleaseInfo? update,
    bool clearUpdate = false,
    bool? promptVisible,
    bool? manualCheckPending,
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
      update: clearUpdate ? null : (update ?? this.update),
      promptVisible: promptVisible ?? this.promptVisible,
      manualCheckPending: manualCheckPending ?? this.manualCheckPending,
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
