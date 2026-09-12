import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import 'package:harbor_companion/app/background/background_controller.dart';
import 'package:harbor_companion/app/background/background_platform.dart';
import 'package:harbor_companion/app/background/background_reducer.dart';
import 'package:harbor_companion/app/background/open_remote_request.dart';
import 'package:harbor_companion/app/connect/connect_controller.dart';
import 'package:harbor_companion/app/connect/connect_reducer.dart';
import 'package:harbor_companion/app/home/catalog_fetcher.dart';
import 'package:harbor_companion/app/home/catalog_request.dart';
import 'package:harbor_companion/app/home/home_controller.dart';
import 'package:harbor_companion/app/home/home_rail.dart';
import 'package:harbor_companion/app/home/meta.dart';
import 'package:harbor_companion/app/shell/connect_first_view.dart';
import 'package:harbor_companion/app/remote/remote_controller.dart';
import 'package:harbor_companion/app/remote/remote_reducer.dart';
import 'package:harbor_companion/app/shell/player_bar.dart';
import 'package:harbor_companion/app/shell/shell_controller.dart';
import 'package:harbor_companion/app/shell/shell_reducer.dart';
import 'package:harbor_companion/app/shell/shell_tab.dart';
import 'package:harbor_companion/app/update/github_releases_client.dart';
import 'package:harbor_companion/app/update/update_controller.dart';
import 'package:harbor_companion/app/update/update_reducer.dart';
import 'package:harbor_companion/app/update/version_provider.dart';
import 'package:harbor_companion/main.dart';

class _FakeReleasesClient implements ReleasesClient {
  ReleaseInfo? result;
  _FakeReleasesClient({this.result});
  @override
  Future<ReleaseInfo?> fetchLatestRelease() async => result;
}

class _FakeVersionProvider implements VersionProvider {
  @override
  Future<LocalVersion> load() async => const LocalVersion(1, '1.0.0');
}

/// The Home catalog stub: shell tests are not about catalog loading. The real
/// fetcher would hit the network and, because of the ticket-73 retry backoff,
/// leave a timer pending past teardown. Every planned rail settles absent, so
/// the Home stays quiet and no timer is scheduled.
class _StubCatalogFetcher implements CatalogFetcher {
  @override
  Stream<HomeRailOutcome> fetchRails(CatalogRequest request) =>
      Stream.fromIterable([
        for (final key in planHomeRowKeys(request)) HomeRailAbsent(key),
      ]);

  @override
  Future<HomeRailOutcome> fetchRail(CatalogRequest request, String rowKey) async =>
      HomeRailAbsent(rowKey);

  @override
  Future<RailPage> fetchRailPage(
    CatalogRequest request,
    String rowKey,
    int cursor,
  ) async =>
      const RailPage(items: []);

  @override
  Future<DetailMeta> fetchDetail(String type, String id, String? tmdbKey) async =>
      DetailMeta(meta: Meta(id: id, type: type, name: ''));
}

/// Remote seam stub: the player bar reads `nowPlaying` from the Remote
/// controller, so the shell tests inject a fixed view without a live socket.
class _StubRemoteController extends RemoteController {
  final RemoteState initialState;
  _StubRemoteController(this.initialState);
  @override
  RemoteState build() => initialState;
}

/// Minimal BackgroundPlatform for the shell rationale test; reports the fixed
/// permission and records the OS prompt.
class _StubBackgroundPlatform implements BackgroundPlatform {
  _StubBackgroundPlatform(this.permission);

  NotificationPermissionStatus permission;
  int requestCalls = 0;

  @override
  Future<NotificationPermissionStatus> checkNotificationPermission() async =>
      permission;

  @override
  Future<NotificationPermissionStatus> requestNotificationPermission() async {
    requestCalls++;
    return permission;
  }

  @override
  Future<void> openNotificationSettings() async {}

  @override
  Future<bool> isIgnoringBatteryOptimizations() async => false;

  @override
  Future<bool> requestIgnoreBatteryOptimizations() async => true;

  @override
  Future<void> openBatteryOptimizationSettings() async {}

  @override
  Future<void> openBatterySettings() async {}

  @override
  Future<LocalNetworkPermissionStatus> checkLocalNetworkPermission() async =>
      LocalNetworkPermissionStatus.granted;

  @override
  Future<LocalNetworkPermissionStatus> requestLocalNetworkPermission() async =>
      LocalNetworkPermissionStatus.granted;

  @override
  Future<void> startService(BackgroundNotification notification) async {}

  @override
  Future<void> updateService(BackgroundNotification notification) async {}

  @override
  Future<void> updateMediaSession(BackgroundMediaSurface? media) async {}

  @override
  Future<void> stopService() async {}

  @override
  Stream<BackgroundAction> get actions =>
      const Stream<BackgroundAction>.empty();
}

/// A connect controller already in the connected phase, so the background module
/// sees a successful connect without a real socket.
class _StubConnectController extends ConnectController {
  @override
  ConnectState build() => ConnectState(
        hosts: const [
          HostEntry(id: 'h1', name: 'desk', address: '192.168.1.50'),
        ],
        selectedId: 'h1',
        phase: ConnPhase.connected,
      );
}

RemoteState _holding(String title) => RemoteState(
      connected: true,
      phase: RemotePhase.nowPlaying,
      nowPlaying: NowPlaying(mediaId: 'tt1', mediaTitle: title, playing: true),
    );

/// Stubs the outbound seams the shell touches on launch: the self-update check
/// (no package_info_plus channel or network) and the Home catalog fetch (no
/// network, and no retry-backoff timer left pending past teardown).
List<Override> shellOverrides() => [
      selfUpdateVersionProvider.overrideWithValue(_FakeVersionProvider()),
      releasesClientProvider.overrideWithValue(_FakeReleasesClient()),
      catalogFetcherProvider.overrideWithValue(_StubCatalogFetcher()),
    ];

/// A container that reports connected and holds `title` in the Remote layer,
/// so the shell renders the player bar over its tab bodies.
ProviderContainer _connectedContainer({required String title}) {
  final container = ProviderContainer(
    overrides: [
      connectionStatusProvider.overrideWith(ConnectionStatusController.new),
      remoteControllerProvider
          .overrideWith(() => _StubRemoteController(_holding(title))),
      ...shellOverrides(),
    ],
  );
  container
      .read(connectionStatusProvider.notifier)
      .set(ConnectionStatus.connected);
  addTearDown(container.dispose);
  return container;
}

void main() {
  testWidgets('fresh install shows the connect-first empty state and five tabs',
      (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: shellOverrides(),
      child: const HarborCompanionApp(),
    ));

    expect(find.byType(ConnectFirstView), findsOneWidget);

    for (final label in ['Remote', 'Search', 'Home', 'My Stuff', 'Profile']) {
      expect(find.text(label), findsWidgets);
    }
  });

  testWidgets('the connect-first view leads to settings', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: shellOverrides(),
      child: const HarborCompanionApp(),
    ));

    await tester.tap(find.text('Open settings'));
    await tester.pumpAndSettle();

    expect(find.text('Settings'), findsOneWidget);
    expect(find.byType(ConnectFirstView), findsNothing);
  });

  testWidgets('a live connection shows the active tab body', (tester) async {
    final container = ProviderContainer(
      overrides: [
        connectionStatusProvider.overrideWith(ConnectionStatusController.new),
        ...shellOverrides(),
      ],
    );
    container.read(connectionStatusProvider.notifier).set(ConnectionStatus.connected);
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const HarborCompanionApp(),
      ),
    );

    expect(find.byType(ConnectFirstView), findsNothing);
    expect(find.text('Home'), findsWidgets);

    await tester.tap(find.text('Search'));
    await tester.pumpAndSettle();
    expect(find.text('Search'), findsWidgets);
  });

  testWidgets('the player bar shows on every tab except Remote',
      (tester) async {
    final container = _connectedContainer(title: 'Shawshank');
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const HarborCompanionApp(),
      ),
    );
    await tester.pumpAndSettle();

    final barTitle = find.descendant(
      of: find.byType(PlayerBar),
      matching: find.text('Shawshank'),
    );

    for (final label in ['Search', 'Home', 'My Stuff', 'Profile']) {
      await tester.tap(find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text(label),
      ));
      await tester.pumpAndSettle();
      expect(barTitle, findsOneWidget, reason: 'bar missing on $label');
    }

    await tester.tap(find.descendant(
      of: find.byType(NavigationBar),
      matching: find.text('Remote'),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(PlayerBar), findsNothing);
  });

  testWidgets('tapping the player bar opens the Remote tab', (tester) async {
    final container = _connectedContainer(title: 'Shawshank');
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const HarborCompanionApp(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.descendant(
      of: find.byType(PlayerBar),
      matching: find.text('Shawshank'),
    ));
    await tester.pumpAndSettle();

    expect(container.read(shellControllerProvider).activeTab, ShellTab.remote);
  });

  testWidgets('the player bar is absent in the connect-first view',
      (tester) async {
    final container = ProviderContainer(
      overrides: [
        remoteControllerProvider
            .overrideWith(() => _StubRemoteController(_holding('Shawshank'))),
        ...shellOverrides(),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const HarborCompanionApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(ConnectFirstView), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(PlayerBar),
        matching: find.text('Shawshank'),
      ),
      findsNothing,
    );
  });

  testWidgets('a newer release shows the update prompt on launch',
      (tester) async {
    final container = ProviderContainer(
      overrides: [
        selfUpdateVersionProvider.overrideWithValue(_FakeVersionProvider()),
        releasesClientProvider.overrideWithValue(_FakeReleasesClient(
          result: ReleaseInfo(
            versionCode: 2,
            versionName: '1.1.0',
            tagName: 'v1.1.0+2',
            notes: 'Fixes the thing',
          ),
        )),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const HarborCompanionApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Update available'), findsOneWidget);
    expect(find.textContaining('1.1.0'), findsWidgets);

    await tester.tap(find.text('Later'));
    await tester.pumpAndSettle();
    expect(find.text('Update available'), findsNothing);
  });

  testWidgets('a notification body tap opens Remote and pops pushed routes',
      (tester) async {
    final container = _connectedContainer(title: 'Shawshank');
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const HarborCompanionApp(),
      ),
    );
    await tester.pumpAndSettle();

    // Push a route so the pop-to-root is observable.
    await tester.tap(find.byIcon(Icons.settings));
    await tester.pumpAndSettle();
    expect(find.text('Settings'), findsOneWidget);

    // The background module signals the request (a notification body tap).
    container.read(openRemoteRequestProvider.notifier).request();
    await tester.pumpAndSettle();

    expect(container.read(shellControllerProvider).activeTab, ShellTab.remote);
    expect(find.text('Settings'), findsNothing);
  });

  testWidgets('the first connect offers the rationale before the OS prompt',
      (tester) async {
    final platform =
        _StubBackgroundPlatform(NotificationPermissionStatus.denied);
    final container = ProviderContainer(
      overrides: [
        connectionStatusProvider.overrideWith(ConnectionStatusController.new),
        connectControllerProvider.overrideWith(_StubConnectController.new),
        remoteControllerProvider
            .overrideWith(() => _StubRemoteController(_holding('Shawshank'))),
        backgroundPlatformProvider.overrideWithValue(platform),
        ...shellOverrides(),
      ],
    );
    addTearDown(container.dispose);
    container
        .read(connectionStatusProvider.notifier)
        .set(ConnectionStatus.connected);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const HarborCompanionApp(),
      ),
    );
    await tester.pumpAndSettle();

    // The in-app rationale is up; Android has not been asked yet.
    expect(find.text('Allow notifications'), findsOneWidget);
    expect(platform.requestCalls, 0);

    await tester.tap(find.text('Allow'));
    await tester.pumpAndSettle();
    expect(platform.requestCalls, 1);
  });

  testWidgets('resuming with the socket down shows a dismissible battery nudge',
      (tester) async {
    var nowMs = 0;
    final platform =
        _StubBackgroundPlatform(NotificationPermissionStatus.granted);
    final container = ProviderContainer(
      overrides: [
        connectionStatusProvider.overrideWith(ConnectionStatusController.new),
        connectControllerProvider.overrideWith(_StubConnectController.new),
        remoteControllerProvider
            .overrideWith(() => _StubRemoteController(_holding('Shawshank'))),
        backgroundPlatformProvider.overrideWithValue(platform),
        backgroundClockProvider.overrideWithValue(() => nowMs),
        ...shellOverrides(),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const HarborCompanionApp(),
      ),
    );
    await tester.pumpAndSettle();

    // Background → resume after a long stretch, with the socket down.
    final background = container.read(backgroundControllerProvider.notifier);
    nowMs = 1000;
    background.setForegrounded(false);
    await tester.pump();
    nowMs = 1000 + kBatteryNudgeBackgroundThresholdMs;
    background.setForegrounded(true);
    await tester.pumpAndSettle();

    expect(find.textContaining('battery optimization'), findsOneWidget);

    // The action dismisses the notice and leads to Settings, where the
    // battery/OEM guidance lives.
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    expect(container.read(backgroundControllerProvider).batteryNudgeVisible,
        isFalse);
    expect(find.widgetWithText(AppBar, 'Settings'), findsOneWidget);
  });
}
