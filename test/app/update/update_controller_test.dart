// Thin wiring tests for the self-update controller (ticket 28). The reducer is
// the decision seam; these pin the glue: the launch check drains into the
// releases client exactly once, the local version is loaded before the check,
// a newer release folds back into a prompt, network failure folds into a quiet
// fail (no modal, no retry), manual check reuses the same path, and a
// foreground return never hits the client again.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:harbor_companion/app/update/github_releases_client.dart';
import 'package:harbor_companion/app/update/install_permission.dart';
import 'package:harbor_companion/app/update/update_controller.dart';
import 'package:harbor_companion/app/update/update_installer.dart';
import 'package:harbor_companion/app/update/update_reducer.dart';
import 'package:harbor_companion/app/update/version_provider.dart';

class FakeReleasesClient implements ReleasesClient {
  ReleaseInfo? result;
  Object? error;
  int calls = 0;

  @override
  Future<ReleaseInfo?> fetchLatestRelease() async {
    calls++;
    if (error != null) throw error!;
    return result;
  }
}

class FakeVersionProvider implements VersionProvider {
  final LocalVersion version;
  FakeVersionProvider(this.version);
  @override
  Future<LocalVersion> load() async => version;
}

class FakeInstaller implements UpdateInstaller {
  final controller = StreamController<InstallStatus>.broadcast();
  String? lastUrl;
  String? lastSha256;

  @override
  Stream<InstallStatus> install({required String url, required String sha256}) {
    lastUrl = url;
    lastSha256 = sha256;
    return controller.stream;
  }
}

class FakeInstallPermission implements InstallPermissionAdapter {
  bool granted = true;
  int checkCalls = 0;
  int openCalls = 0;

  @override
  Future<bool> canRequestPackageInstalls() async {
    checkCalls++;
    return granted;
  }

  @override
  Future<void> openInstallPermissionSettings() async {
    openCalls++;
  }
}

void main() {
  late FakeReleasesClient client;
  late FakeInstaller installer;
  late FakeInstallPermission permission;
  late ProviderContainer container;

  ProviderContainer makeContainer({
    int localCode = 1,
    ReleaseInfo? release,
    Object? error,
  }) {
    client = FakeReleasesClient()
      ..result = release
      ..error = error;
    installer = FakeInstaller();
    permission = FakeInstallPermission();
    return ProviderContainer(
      overrides: [
        selfUpdateVersionProvider
            .overrideWithValue(FakeVersionProvider(LocalVersion(localCode, '1.0.0'))),
        releasesClientProvider.overrideWithValue(client),
        updateInstallerProvider.overrideWithValue(installer),
        installPermissionProvider.overrideWithValue(permission),
      ],
    );
  }

  ReleaseInfo release(int code, {String name = '1.0.0'}) =>
      ReleaseInfo(versionCode: code, versionName: name, tagName: 'v$name+$code');

  ReleaseInfo installable(int code, {String name = '1.1.0'}) => ReleaseInfo(
        versionCode: code,
        versionName: name,
        tagName: 'v$name+$code',
        downloadUrl: 'https://example.com/harbor-companion.apk',
        sha256: 'd6da28451a1e15cf7a75f2c3f151befad3b80ad0bb232ab15c20897e54f21478',
      );

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  test('launch loads the local version, then checks the client once', () async {
    container = makeContainer(release: release(1));
    addTearDown(container.dispose);
    container.read(selfUpdateControllerProvider);
    await settle();

    final s = container.read(selfUpdateControllerProvider);
    expect(s.localVersionCode, 1);
    expect(s.status, UpdateStatus.upToDate); // equal → silent
    expect(s.promptVisible, isFalse);
    expect(client.calls, 1);
  });

  test('a newer release folds back into a prompt', () async {
    container = makeContainer(localCode: 1, release: release(2, name: '1.1.0'));
    addTearDown(container.dispose);
    container.read(selfUpdateControllerProvider);
    await settle();

    final s = container.read(selfUpdateControllerProvider);
    expect(s.status, UpdateStatus.hasUpdate);
    expect(s.promptVisible, isTrue);
    expect(s.update!.versionName, '1.1.0');
  });

  test('a network failure folds into a quiet failed state, no retry', () async {
    container = makeContainer(error: Exception('connection refused'));
    addTearDown(container.dispose);
    container.read(selfUpdateControllerProvider);
    await settle();

    final s = container.read(selfUpdateControllerProvider);
    expect(s.status, UpdateStatus.failed);
    expect(s.promptVisible, isFalse);
    expect(s.lastError, contains('connection refused'));
    expect(s.notice, isNull, reason: 'launch failure is silent');
    expect(client.calls, 1, reason: 'no auto-retry');
  });

  test('a manual check reuses the same path and re-hits the client', () async {
    container = makeContainer(localCode: 1, release: release(1));
    addTearDown(container.dispose);
    final ctrl = container.read(selfUpdateControllerProvider.notifier);
    await settle();
    expect(client.calls, 1);

    client.result = release(2, name: '1.1.0');
    ctrl.checkNow();
    await settle();

    expect(client.calls, 2);
    final s = container.read(selfUpdateControllerProvider);
    expect(s.status, UpdateStatus.hasUpdate);
    expect(s.promptVisible, isTrue);
  });

  test('a foreground return never re-checks (no second client call)', () async {
    container = makeContainer(localCode: 1, release: release(1));
    addTearDown(container.dispose);
    final ctrl = container.read(selfUpdateControllerProvider.notifier);
    await settle();
    expect(client.calls, 1);

    ctrl.setForegrounded(false);
    await settle();
    expect(client.calls, 1, reason: 'foreground return must not double-fire');
  });

  test('dismissing the prompt clears promptVisible', () async {
    container = makeContainer(localCode: 1, release: release(2));
    addTearDown(container.dispose);
    final ctrl = container.read(selfUpdateControllerProvider.notifier);
    await settle();
    expect(container.read(selfUpdateControllerProvider).promptVisible, isTrue);

    ctrl.dismissPrompt();
    expect(container.read(selfUpdateControllerProvider).promptVisible, isFalse);
  });

  group('install half', () {
    Future<void> prompt() async {
      container.read(selfUpdateControllerProvider); // trigger build + launch
      await settle(); // the launch check folds into hasUpdate + prompt
    }

    test('a granted permission downloads via the installer with url + sha256',
        () async {
      container = makeContainer(localCode: 1, release: installable(2));
      addTearDown(container.dispose);
      await prompt();

      container.read(selfUpdateControllerProvider.notifier).acceptUpdate();
      await settle();

      expect(permission.checkCalls, 1);
      expect(installer.lastUrl, 'https://example.com/harbor-companion.apk');
      expect(installer.lastSha256,
          'd6da28451a1e15cf7a75f2c3f151befad3b80ad0bb232ab15c20897e54f21478');
      expect(container.read(selfUpdateControllerProvider).status,
          UpdateStatus.installing);
    });

    test('a denied permission opens the settings screen and awaits the grant',
        () async {
      container = makeContainer(localCode: 1, release: installable(2));
      addTearDown(container.dispose);
      permission.granted = false;
      await prompt();

      container.read(selfUpdateControllerProvider.notifier).acceptUpdate();
      await settle();

      expect(permission.openCalls, 1);
      expect(installer.lastUrl, isNull, reason: 'no download before the grant');
      expect(container.read(selfUpdateControllerProvider).awaitingInstallPermission,
          isTrue);
    });

    test('returning to the foreground re-checks a parked permission grant',
        () async {
      container = makeContainer(localCode: 1, release: installable(2));
      addTearDown(container.dispose);
      permission.granted = false;
      await prompt();

      final ctrl = container.read(selfUpdateControllerProvider.notifier);
      ctrl.acceptUpdate();
      await settle();
      expect(container.read(selfUpdateControllerProvider).awaitingInstallPermission,
          isTrue);

      permission.granted = true;
      ctrl.setForegrounded(false); // resumed
      await settle();

      expect(permission.checkCalls, 2);
      expect(installer.lastUrl, 'https://example.com/harbor-companion.apk');
      expect(container.read(selfUpdateControllerProvider).awaitingInstallPermission,
          isFalse);
    });

    test('a checksum mismatch folds into installFailed', () async {
      container = makeContainer(localCode: 1, release: installable(2));
      addTearDown(container.dispose);
      await prompt();

      container.read(selfUpdateControllerProvider.notifier).acceptUpdate();
      await settle();
      installer.controller.add(InstallStatus.checksumMismatch);
      await settle();

      final s = container.read(selfUpdateControllerProvider);
      expect(s.status, UpdateStatus.installFailed);
      expect(s.notice, contains('Verification failed'));
    });

    test('a failed download folds into installFailed with no retry', () async {
      container = makeContainer(localCode: 1, release: installable(2));
      addTearDown(container.dispose);
      await prompt();

      container.read(selfUpdateControllerProvider.notifier).acceptUpdate();
      await settle();
      installer.controller.add(InstallStatus.failed);
      await settle();

      expect(container.read(selfUpdateControllerProvider).status,
          UpdateStatus.installFailed);
      expect(installer.lastUrl, isNotNull);
      expect(permission.checkCalls, 1, reason: 'no re-check, no auto-retry');
    });

    test('a triggered install lands on upToDate', () async {
      container = makeContainer(localCode: 1, release: installable(2));
      addTearDown(container.dispose);
      await prompt();

      container.read(selfUpdateControllerProvider.notifier).acceptUpdate();
      await settle();
      installer.controller.add(InstallStatus.triggered);
      await settle();

      expect(container.read(selfUpdateControllerProvider).status,
          UpdateStatus.upToDate);
    });
  });
}
