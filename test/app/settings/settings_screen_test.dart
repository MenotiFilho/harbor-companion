// Thin UI wiring test for the connect/settings screen (ticket 03). The
// decisions live in the reducer; this pins that the screen actually renders,
// dispatches events, and that the warning gate + connect flow work end-to-end
// against a fake transport.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:harbor_companion/app/background/background_controller.dart';
import 'package:harbor_companion/app/background/background_platform.dart';
import 'package:harbor_companion/app/connect/connect_controller.dart';
import 'package:harbor_companion/app/connect/host_registry.dart';
import 'package:harbor_companion/app/connect/lan_scan.dart';
import 'package:harbor_companion/app/settings/settings_controller.dart';
import 'package:harbor_companion/app/settings/settings_screen.dart';
import 'package:harbor_companion/app/settings/settings_store.dart';
import 'package:harbor_companion/app/shell/player_bar.dart';
import 'package:harbor_companion/app/update/github_releases_client.dart';
import 'package:harbor_companion/app/update/update_controller.dart';
import 'package:harbor_companion/app/update/update_reducer.dart';
import 'package:harbor_companion/app/update/version_provider.dart';
import 'package:harbor_companion/app/ws/client_controller.dart';
import 'package:harbor_companion/app/ws/host_keys.dart';
import 'package:harbor_companion/app/ws/ws_transport.dart';

class FakeConnection implements WsConnection {
  final _frames = StreamController<String>.broadcast();
  @override
  Stream<String> get frames => _frames.stream;
  @override
  void send(String message) {}
  @override
  Future<void> close() async => _frames.close();
}

class FakeTransport implements WsTransport {
  @override
  Future<WsConnection> open(String url) async => FakeConnection();
}

class FakeKeyStore implements HostKeyStore {
  @override
  Future<HostKeys> load() async => const HostKeys();
  @override
  Future<void> save(HostKeys keys) async {}
}

class FakeReleasesClient implements ReleasesClient {
  @override
  Future<ReleaseInfo?> fetchLatestRelease() async => null;
}

class FakeVersionProvider implements VersionProvider {
  @override
  Future<LocalVersion> load() async => const LocalVersion(1, '1.0.0');
}

/// Minimal BackgroundPlatform for the Settings permission row: only the
/// permission operations matter here; the service methods are never reached.
class FakeBackgroundPlatform implements BackgroundPlatform {
  FakeBackgroundPlatform(this.permission, {this.batteryExempt = false});

  NotificationPermissionStatus permission;
  int requestCalls = 0;
  int openSettingsCalls = 0;

  /// Battery / OEM (#68).
  bool batteryExempt;
  int batteryRequestCalls = 0;
  int batteryListCalls = 0;
  int batterySettingsCalls = 0;

  @override
  Future<NotificationPermissionStatus> checkNotificationPermission() async =>
      permission;

  @override
  Future<NotificationPermissionStatus> requestNotificationPermission() async {
    requestCalls++;
    return permission;
  }

  @override
  Future<void> openNotificationSettings() async => openSettingsCalls++;

  @override
  Future<bool> isIgnoringBatteryOptimizations() async => batteryExempt;

  @override
  Future<bool> requestIgnoreBatteryOptimizations() async {
    batteryRequestCalls++;
    return true;
  }

  @override
  Future<void> openBatteryOptimizationSettings() async => batteryListCalls++;

  @override
  Future<void> openBatterySettings() async => batterySettingsCalls++;

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

ProviderContainer makeContainer({
  PlayerBarView? playerBar,
  FakeBackgroundPlatform? backgroundPlatform,
}) =>
    ProviderContainer(
      overrides: [
        wsTransportProvider.overrideWithValue(FakeTransport()),
        wsKeyStoreProvider.overrideWithValue(FakeKeyStore()),
        hostRegistryStoreProvider.overrideWithValue(InMemoryHostRegistryStore()),
        settingsStoreProvider.overrideWithValue(InMemorySettingsStore()),
        subnetScannerProvider.overrideWithValue(const FixedSubnetScanner([])),
        selfUpdateVersionProvider.overrideWithValue(FakeVersionProvider()),
        releasesClientProvider.overrideWithValue(FakeReleasesClient()),
        playerBarViewProvider.overrideWithValue(playerBar),
        if (backgroundPlatform != null)
          backgroundPlatformProvider.overrideWithValue(backgroundPlatform),
      ],
    );

Widget app(ProviderContainer container) => UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: SettingsScreen()),
    );

/// Scrolls the settings list down to the Letterboxd section (it sits below the
/// fold, and the lazy list has not built it yet).
Future<void> scrollToLetterboxd(WidgetTester tester) async {
  await tester.scrollUntilVisible(
    find.text('Letterboxd'),
    200,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
}

Future<void> scrollTo(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(
    finder,
    200,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('an empty registry shows the add-host prompt', (tester) async {
    final container = makeContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(app(container));
    await tester.pumpAndSettle();

    expect(find.text('Saved hosts'), findsOneWidget);
    expect(find.textContaining('No hosts yet'), findsOneWidget);
  });

  testWidgets('adding a host gates on the warning, then connects', (tester) async {
    final container = makeContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(app(container));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Add host'));
    await tester.pumpAndSettle();
    // Scope to the dialog: the screen behind it also has a TextField (the
    // Letterboxd URL field).
    final dialogFields = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    await tester.enterText(dialogFields.first, 'desk');
    await tester.enterText(dialogFields.last, '192.168.1.50');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    // The warning gate blocks the connect until acknowledged.
    expect(find.text('I understand, connect'), findsOneWidget);
    expect(find.text('desk'), findsOneWidget); // saved in the registry

    await tester.tap(find.text('I understand, connect'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Connected'), findsWidgets);
  });

  testWidgets('"Check for updates" runs the check and reports up to date',
      (tester) async {
    final container = makeContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(app(container));
    await tester.pumpAndSettle();

    // The Letterboxd section pushed this button below the fold, and the list
    // builds lazily — scroll it into the tree.
    final checkButton = find.text('Check for updates');
    await tester.scrollUntilVisible(
      checkButton,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(checkButton);
    await tester.pumpAndSettle();

    expect(find.text('No update available'), findsOneWidget);
  });

  testWidgets('the playback-location toggle defaults off and flips on tap',
      (tester) async {
    final container = makeContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(app(container));
    await tester.pumpAndSettle();

    final toggle =
        find.widgetWithText(SwitchListTile, 'Show playback location');
    await scrollTo(tester, toggle);
    expect(toggle, findsOneWidget);
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);

    await tester.tap(toggle);
    await tester.pumpAndSettle();

    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
  });

  testWidgets('the Connection section toggle defaults on and persists',
      (tester) async {
    final store = InMemorySettingsStore();
    final container = ProviderContainer(
      overrides: [
        wsTransportProvider.overrideWithValue(FakeTransport()),
        wsKeyStoreProvider.overrideWithValue(FakeKeyStore()),
        hostRegistryStoreProvider.overrideWithValue(InMemoryHostRegistryStore()),
        settingsStoreProvider.overrideWithValue(store),
        subnetScannerProvider.overrideWithValue(const FixedSubnetScanner([])),
        selfUpdateVersionProvider.overrideWithValue(FakeVersionProvider()),
        releasesClientProvider.overrideWithValue(FakeReleasesClient()),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(app(container));
    await tester.pumpAndSettle();

    final toggle = find.widgetWithText(
      SwitchListTile,
      'Keep connection in background',
    );
    await scrollTo(tester, find.text('Connection'));
    expect(find.text('Connection'), findsOneWidget);
    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);

    await tester.tap(toggle);
    await tester.pumpAndSettle();

    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
    expect(await store.loadKeepConnectionInBackground(), isFalse);
  });

  testWidgets('settings exposes the Home rows editor entry point',
      (tester) async {
    final container = makeContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(app(container));
    await tester.pumpAndSettle();

    await scrollTo(tester, find.text('Home rows'));
    expect(find.text('Home rows'), findsOneWidget);
    expect(find.byIcon(Icons.chevron_right), findsOneWidget);
  });

  testWidgets('the Letterboxd section shows the manifest URL field',
      (tester) async {
    final container = makeContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(app(container));
    await tester.pumpAndSettle();

    await scrollToLetterboxd(tester);
    expect(find.text('Letterboxd'), findsOneWidget);
    expect(find.text('Stremboxd manifest URL'), findsOneWidget);
  });

  testWidgets('saving a manifest URL persists it', (tester) async {
    final store = InMemorySettingsStore();
    final container = ProviderContainer(
      overrides: [
        wsTransportProvider.overrideWithValue(FakeTransport()),
        wsKeyStoreProvider.overrideWithValue(FakeKeyStore()),
        hostRegistryStoreProvider.overrideWithValue(InMemoryHostRegistryStore()),
        settingsStoreProvider.overrideWithValue(store),
        subnetScannerProvider.overrideWithValue(const FixedSubnetScanner([])),
        selfUpdateVersionProvider.overrideWithValue(FakeVersionProvider()),
        releasesClientProvider.overrideWithValue(FakeReleasesClient()),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(app(container));
    await tester.pumpAndSettle();

    final urlField = find.byType(TextField);
    await scrollTo(tester, urlField);
    await tester.enterText(
      urlField,
      'https://api.stremboxd.com/stremio/abc/manifest.json',
    );
    final saveUrl = find.byTooltip('Save URL');
    await scrollTo(tester, saveUrl);
    await tester.tap(saveUrl);
    await tester.pumpAndSettle();
    expect(
      container.read(settingsControllerProvider).letterboxdManifestUrl,
      'https://api.stremboxd.com/stremio/abc/manifest.json',
    );
  });

  testWidgets('an unsaved URL survives an unrelated rebuild', (tester) async {
    final container = makeContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(app(container));
    await tester.pumpAndSettle();

    final urlField = find.byType(TextField);
    await scrollTo(tester, urlField);
    await tester.enterText(urlField, 'https://typed.but/not/saved/manifest.json');

    // Any Settings state change rebuilds the screen; the field must keep the
    // in-progress text.
    container.read(settingsControllerProvider.notifier).setShowPlaybackLocation(true);
    await tester.pumpAndSettle();

    expect(
      tester.widget<TextField>(urlField).controller!.text,
      'https://typed.but/not/saved/manifest.json',
    );
  });

  testWidgets('renders the floating player bar when media is held',
      (tester) async {
    final container = makeContainer(
      playerBar: const PlayerBarView(title: 'Shawshank', playing: true),
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(app(container));
    await tester.pumpAndSettle();

    expect(find.byType(PlayerBar), findsOneWidget);
    expect(find.text('Shawshank'), findsOneWidget);
  });

  testWidgets('the Notification access row re-asks while Android still allows it',
      (tester) async {
    final platform =
        FakeBackgroundPlatform(NotificationPermissionStatus.denied);
    final container = makeContainer(backgroundPlatform: platform);
    addTearDown(container.dispose);
    await tester.pumpWidget(app(container));
    await tester.pumpAndSettle();

    final row = find.text('Notification access');
    await scrollTo(tester, row);
    expect(find.textContaining('Not allowed'), findsOneWidget);

    await tester.tap(row);
    await tester.pumpAndSettle();

    // The in-app rationale precedes the OS prompt.
    expect(find.text('Allow notifications'), findsOneWidget);
    await tester.tap(find.text('Allow'));
    await tester.pumpAndSettle();

    expect(platform.requestCalls, 1);
    expect(platform.openSettingsCalls, 0);
  });

  testWidgets(
      'the Notification access row deep-links when permanently denied',
      (tester) async {
    final platform =
        FakeBackgroundPlatform(NotificationPermissionStatus.permanentlyDenied);
    final container = makeContainer(backgroundPlatform: platform);
    addTearDown(container.dispose);
    await tester.pumpWidget(app(container));
    await tester.pumpAndSettle();

    final row = find.text('Notification access');
    await scrollTo(tester, row);
    expect(find.textContaining('Blocked in Android settings'), findsOneWidget);

    await tester.tap(row);
    await tester.pumpAndSettle();

    // No rationale/OS prompt is possible anymore — only the deep link.
    expect(find.text('Allow notifications'), findsNothing);
    expect(platform.requestCalls, 0);
    expect(platform.openSettingsCalls, 1);
  });

  testWidgets('a granted permission shows Notification access as allowed',
      (tester) async {
    final platform =
        FakeBackgroundPlatform(NotificationPermissionStatus.granted);
    final container = makeContainer(backgroundPlatform: platform);
    addTearDown(container.dispose);
    await tester.pumpWidget(app(container));
    await tester.pumpAndSettle();

    final row = find.text('Notification access');
    await scrollTo(tester, row);
    expect(find.textContaining('Allowed'), findsOneWidget);

    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(platform.requestCalls, 0);
    expect(platform.openSettingsCalls, 0);
  });

  testWidgets('the battery section offers the direct request and the fallback',
      (tester) async {
    final platform = FakeBackgroundPlatform(NotificationPermissionStatus.granted);
    final container = makeContainer(backgroundPlatform: platform);
    addTearDown(container.dispose);
    await tester.pumpWidget(app(container));
    await tester.pumpAndSettle();

    await scrollTo(tester, find.text('Battery optimization'));
    expect(find.textContaining('Not exempt'), findsOneWidget);

    await tester.tap(find.text('Request exemption'));
    await tester.pumpAndSettle();
    expect(platform.batteryRequestCalls, 1);

    await tester.tap(find.text('Open optimization list'));
    await tester.pumpAndSettle();
    expect(platform.batteryListCalls, 1);
  });

  testWidgets('the battery section reflects an exempt app', (tester) async {
    final platform = FakeBackgroundPlatform(
      NotificationPermissionStatus.granted,
      batteryExempt: true,
    );
    final container = makeContainer(backgroundPlatform: platform);
    addTearDown(container.dispose);
    await tester.pumpWidget(app(container));
    await tester.pumpAndSettle();

    await scrollTo(tester, find.text('Battery optimization'));
    expect(find.textContaining('Exempt'), findsOneWidget);
    expect(find.text('Request exemption'), findsNothing);
    expect(find.text('Open optimization list'), findsNothing);
  });

  testWidgets('the OEM tips block shows static guidance and a battery action',
      (tester) async {
    final platform = FakeBackgroundPlatform(NotificationPermissionStatus.granted);
    final container = makeContainer(backgroundPlatform: platform);
    addTearDown(container.dispose);
    await tester.pumpWidget(app(container));
    await tester.pumpAndSettle();

    await scrollTo(tester, find.text('If the connection still drops'));
    expect(find.textContaining('MIUI'), findsOneWidget);
    expect(find.textContaining('Samsung'), findsOneWidget);
    expect(find.textContaining('Xiaomi'), findsOneWidget);

    await tester.tap(find.text('Open battery settings'));
    await tester.pumpAndSettle();
    expect(platform.batterySettingsCalls, 1);
  });
}
