// Thin wiring tests for the self-update controller (ticket 28). The reducer is
// the decision seam; these pin the glue: the launch check drains into the
// releases client exactly once, the local version is loaded before the check,
// a newer release folds back into a prompt, network failure folds into a quiet
// fail (no modal, no retry), manual check reuses the same path, and a
// foreground return never hits the client again.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:harbor_companion/app/update/github_releases_client.dart';
import 'package:harbor_companion/app/update/update_controller.dart';
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

void main() {
  late FakeReleasesClient client;
  late ProviderContainer container;

  ProviderContainer makeContainer({
    int localCode = 1,
    ReleaseInfo? release,
    Object? error,
  }) {
    client = FakeReleasesClient()
      ..result = release
      ..error = error;
    return ProviderContainer(
      overrides: [
        selfUpdateVersionProvider
            .overrideWithValue(FakeVersionProvider(LocalVersion(localCode, '1.0.0'))),
        releasesClientProvider.overrideWithValue(client),
      ],
    );
  }

  ReleaseInfo release(int code, {String name = '1.0.0'}) =>
      ReleaseInfo(versionCode: code, versionName: name, tagName: 'v$name+$code');

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
}
