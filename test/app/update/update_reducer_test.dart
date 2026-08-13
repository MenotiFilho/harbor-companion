// Tests for the self-update check state model (lib/app/update/update_reducer.dart).
//
// Pins the ticket 28 acceptance criteria: check-on-launch emits exactly one
// check (foreground return never double-fires), a newer versionCode prompts,
// equal/downgrade are silent, network failure is quiet, manual check reuses the
// same path and re-checks, stale results are ignored, and the tag parsing
// derives versionCode without ever touching versionName for logic.

import 'package:flutter_test/flutter_test.dart';

import 'package:harbor_companion/app/update/update_reducer.dart';

ReleaseInfo release(int code, {String name = '1.0.0', String? notes}) =>
    ReleaseInfo(
      versionCode: code,
      versionName: name,
      tagName: 'v$name+$code',
      notes: notes,
    );

ReleaseInfo installable(int code, {String name = '1.1.0'}) => ReleaseInfo(
      versionCode: code,
      versionName: name,
      tagName: 'v$name+$code',
      downloadUrl: 'https://example.com/harbor-companion.apk',
      sha256: 'd6da28451a1e15cf7a75f2c3f151befad3b80ad0bb232ab15c20897e54f21478',
    );

List<String> drain(SelfUpdateState s) {
  final e = List<String>.from(s.effects);
  s.effects.clear();
  return e;
}

SelfUpdateState launchedAt(int localCode, {String localName = '1.0.0'}) {
  var s = updateReduce(
      SelfUpdateState(), LocalVersionLoaded(localCode, localName));
  s = updateReduce(s, const Launch());
  drain(s); // the controller consumes the check effect immediately
  return s;
}

void main() {
  group('check-on-launch', () {
    test('Launch emits exactly one check effect and marks checking', () {
      var s = updateReduce(SelfUpdateState(), const LocalVersionLoaded(1, '1.0.0'));
      s = updateReduce(s, const Launch());
      expect(s.status, UpdateStatus.checking);
      expect(drain(s), ['check:1']);
    });

    test('a foreground return never re-checks (no double-fire)', () {
      var s = launchedAt(1);
      drain(s);
      final after = updateReduce(s, const SetForegrounded(true));
      expect(drain(after), isEmpty, reason: 'backgrounding never checks');
      final back = updateReduce(after, const SetForegrounded(false));
      expect(drain(back), isEmpty, reason: 'foreground return never re-checks');
      expect(back.status, UpdateStatus.checking);
    });
  });

  group('comparison on versionCode only', () {
    test('a newer remote versionCode prompts with the new version', () {
      final s = launchedAt(1);
      final after = updateReduce(s, RemoteResult(1, release(2, name: '1.1.0')));
      expect(after.status, UpdateStatus.hasUpdate);
      expect(after.promptVisible, isTrue);
      expect(after.update!.versionCode, 2);
      expect(drain(after), ['prompt']);
    });

    test('an equal versionCode is a silent no-op', () {
      final s = launchedAt(1);
      final after = updateReduce(s, RemoteResult(1, release(1)));
      expect(after.status, UpdateStatus.upToDate);
      expect(after.promptVisible, isFalse);
      expect(after.update, isNull);
      expect(drain(after), isEmpty);
      expect(after.notice, isNull, reason: 'launch check is silent when equal');
    });

    test('a downgrade (remote < local) is ignored', () {
      final s = launchedAt(5);
      final after = updateReduce(s, RemoteResult(1, release(4)));
      expect(after.status, UpdateStatus.upToDate);
      expect(after.promptVisible, isFalse);
      expect(drain(after), isEmpty);
    });

    test('a larger versionName with a lower versionCode does NOT prompt', () {
      // versionName is never used for logic: `v99.0.0+1` must not beat local
      // `v1.0.0+2` just because 99 > 1.
      final s = launchedAt(2, localName: '1.0.0');
      final after = updateReduce(s, RemoteResult(1, release(1, name: '99.0.0')));
      expect(after.status, UpdateStatus.upToDate);
      expect(after.promptVisible, isFalse);
      expect(drain(after), isEmpty);
    });
  });

  group('no release / failure', () {
    test('no published release is "no update", not an error', () {
      final s = launchedAt(1);
      final after = updateReduce(s, const NoRelease(1));
      expect(after.status, UpdateStatus.upToDate);
      expect(after.promptVisible, isFalse);
      expect(drain(after), isEmpty);
    });

    test('a network failure is quiet: fail effect, no prompt, no retry', () {
      final s = launchedAt(1);
      final after = updateReduce(s, const CheckFailed(1, 'connection refused'));
      expect(after.status, UpdateStatus.failed);
      expect(after.promptVisible, isFalse);
      expect(after.lastError, 'connection refused');
      expect(drain(after), ['fail:connection refused']);
      expect(after.notice, isNull, reason: 'launch failure is silent');
    });
  });

  group('manual "Check for updates"', () {
    test('a manual check re-checks after a completed launch check', () {
      var s = launchedAt(1);
      drain(s);
      s = updateReduce(s, RemoteResult(1, release(1)));
      drain(s);
      final after = updateReduce(s, const CheckRequested());
      expect(after.status, UpdateStatus.checking);
      expect(after.checkSeq, 2);
      expect(drain(after), ['check:2']);
    });

    test('a manual check that finds nothing newer surfaces a quiet notice', () {
      var s = launchedAt(1);
      drain(s);
      s = updateReduce(s, const CheckRequested());
      drain(s);
      final after = updateReduce(s, RemoteResult(2, release(1)));
      expect(after.status, UpdateStatus.upToDate);
      expect(after.notice, 'No update available');
      expect(drain(after), isEmpty);
    });

    test('a manual check failure surfaces a quiet notice, no modal', () {
      var s = launchedAt(1);
      drain(s);
      s = updateReduce(s, const CheckRequested());
      drain(s);
      final after = updateReduce(s, const CheckFailed(2, 'timeout'));
      expect(after.status, UpdateStatus.failed);
      expect(after.notice, 'Could not check for updates');
      expect(drain(after), ['fail:timeout']);
    });
  });

  group('staleness + dismissal', () {
    test('a stale check result never publishes over a newer manual check', () {
      var s = launchedAt(1); // seq 1 in flight
      s = updateReduce(s, const CheckRequested()); // seq 2 supersedes
      drain(s);
      final after = updateReduce(s, RemoteResult(1, release(99)));
      expect(after.status, UpdateStatus.checking, reason: 'stale result ignored');
      expect(after.promptVisible, isFalse);
      expect(drain(after), isEmpty);
    });

    test('a stale check failure is ignored too', () {
      var s = launchedAt(1);
      s = updateReduce(s, const CheckRequested());
      drain(s);
      final after = updateReduce(s, const CheckFailed(1, 'stale'));
      expect(after.status, UpdateStatus.checking);
      expect(drain(after), isEmpty);
    });

    test('DismissPrompt clears promptVisible and keeps the update', () {
      final s = updateReduce(launchedAt(1), RemoteResult(1, release(2)));
      drain(s);
      final after = updateReduce(s, const DismissPrompt());
      expect(after.promptVisible, isFalse);
      expect(after.update!.versionCode, 2);
      expect(drain(after), isEmpty);
    });

    test('a fresh check clears a previously prompted update', () {
      var s = updateReduce(launchedAt(1), RemoteResult(1, release(2)));
      drain(s);
      expect(s.update, isNotNull);
      s = updateReduce(s, const CheckRequested());
      expect(s.update, isNull);
      expect(s.promptVisible, isFalse);
    });
  });

  group('tag parsing', () {
    test('parseVersionCodeFromTag reads the code after the last +', () {
      expect(parseVersionCodeFromTag('v1.0.0+1'), 1);
      expect(parseVersionCodeFromTag('v1.2.3+45'), 45);
      expect(parseVersionCodeFromTag('1.0.0+7'), 7);
      expect(parseVersionCodeFromTag('v1.0.0+1+2'), 2);
    });

    test('parseVersionCodeFromTag returns null when there is no usable code', () {
      expect(parseVersionCodeFromTag('v1.0.0'), isNull);
      expect(parseVersionCodeFromTag('v1.0.0+abc'), isNull);
      expect(parseVersionCodeFromTag(''), isNull);
    });

    test('parseVersionNameFromTag strips the v prefix and code', () {
      expect(parseVersionNameFromTag('v1.2.3+4'), '1.2.3');
      expect(parseVersionNameFromTag('1.2.3+4'), '1.2.3');
    });
  });

  group('install half', () {
    SelfUpdateState prompted({int localCode = 1}) {
      var s = launchedAt(localCode);
      s = updateReduce(s, RemoteResult(1, installable(2)));
      drain(s); // consume the prompt effect
      return s;
    }

    test('UpdateRequested closes the prompt, marks installing, emits install:1',
        () {
      final s = updateReduce(prompted(), const UpdateRequested());
      expect(s.status, UpdateStatus.installing);
      expect(s.promptVisible, isFalse);
      expect(s.installSeq, 1);
      expect(s.update!.versionCode, 2, reason: 'update kept for the install');
      expect(drain(s), ['install:1']);
    });

    test('UpdateRequested with no downloadable APK fails immediately', () {
      var s = launchedAt(1);
      s = updateReduce(s, RemoteResult(1, release(2))); // no url/sha256
      drain(s);
      s = updateReduce(s, const UpdateRequested());
      expect(s.status, UpdateStatus.installFailed);
      expect(s.lastError, 'No downloadable APK for this release');
      expect(drain(s), isEmpty, reason: 'nothing to download, no install');
    });

    test('a granted permission proceeds to download', () {
      var s = updateReduce(prompted(), const UpdateRequested());
      drain(s);
      s = updateReduce(s, const InstallPermission(1, true));
      expect(s.status, UpdateStatus.installing);
      expect(drain(s), ['installApk']);
    });

    test('a denied permission opens the settings screen and awaits the grant',
        () {
      var s = updateReduce(prompted(), const UpdateRequested());
      drain(s);
      s = updateReduce(s, const InstallPermission(1, false));
      expect(s.status, UpdateStatus.installing);
      expect(s.awaitingInstallPermission, isTrue);
      expect(drain(s), ['grantInstallPermission']);
    });

    test('a grant after awaiting resumes straight to download', () {
      var s = updateReduce(prompted(), const UpdateRequested());
      drain(s);
      s = updateReduce(s, const InstallPermission(1, false));
      drain(s);
      s = updateReduce(s, const InstallPermission(1, true));
      expect(s.awaitingInstallPermission, isFalse);
      expect(drain(s), ['installApk']);
    });

    test('a resume still denied fails instead of re-opening settings', () {
      var s = updateReduce(prompted(), const UpdateRequested());
      drain(s);
      s = updateReduce(s, const InstallPermission(1, false));
      drain(s);
      s = updateReduce(s, const InstallPermission(1, false));
      expect(s.status, UpdateStatus.installFailed);
      expect(s.lastError, 'Install permission not granted');
      expect(drain(s), isEmpty, reason: 'no re-open, no retry');
    });

    test('InstallTriggered lands on upToDate and clears the update', () {
      var s = updateReduce(prompted(), const UpdateRequested());
      drain(s);
      s = updateReduce(s, const InstallPermission(1, true));
      drain(s);
      s = updateReduce(s, const InstallTriggered());
      expect(s.status, UpdateStatus.upToDate);
      expect(s.update, isNull);
      expect(s.promptVisible, isFalse);
      expect(drain(s), isEmpty);
    });

    test('ChecksumMismatch never installs and surfaces verification failed', () {
      var s = updateReduce(prompted(), const UpdateRequested());
      drain(s);
      s = updateReduce(s, const InstallPermission(1, true));
      drain(s);
      s = updateReduce(s, const ChecksumMismatch());
      expect(s.status, UpdateStatus.installFailed);
      expect(s.notice, contains('Verification failed'));
      expect(s.update, isNull);
      expect(drain(s), isEmpty, reason: 'no install effect, no retry');
    });

    test('InstallFailed surfaces the reason and does not auto-retry', () {
      var s = updateReduce(prompted(), const UpdateRequested());
      drain(s);
      s = updateReduce(s, const InstallPermission(1, true));
      drain(s);
      s = updateReduce(s, const InstallFailed('download timed out'));
      expect(s.status, UpdateStatus.installFailed);
      expect(s.lastError, 'download timed out');
      expect(drain(s), isEmpty, reason: 'no auto-retry');
    });

    test('a stale InstallPermission result is ignored', () {
      // seq 2 supersedes seq 1; a late seq-1 permission result must not act.
      var s = updateReduce(prompted(), const UpdateRequested()); // seq 1
      s = updateReduce(s, const UpdateRequested()); // seq 2 supersedes
      drain(s);
      s = updateReduce(s, const InstallPermission(1, true));
      expect(s.status, UpdateStatus.installing);
      expect(drain(s), isEmpty, reason: 'stale permission result ignored');
    });
  });
}
