// Thin UI wiring test for the connect/settings screen (ticket 03). The
// decisions live in the reducer; this pins that the screen actually renders,
// dispatches events, and that the warning gate + connect flow work end-to-end
// against a fake transport.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

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

ProviderContainer makeContainer({PlayerBarView? playerBar}) => ProviderContainer(
      overrides: [
        wsTransportProvider.overrideWithValue(FakeTransport()),
        wsKeyStoreProvider.overrideWithValue(FakeKeyStore()),
        hostRegistryStoreProvider.overrideWithValue(InMemoryHostRegistryStore()),
        settingsStoreProvider.overrideWithValue(InMemorySettingsStore()),
        subnetScannerProvider.overrideWithValue(const FixedSubnetScanner([])),
        selfUpdateVersionProvider.overrideWithValue(FakeVersionProvider()),
        releasesClientProvider.overrideWithValue(FakeReleasesClient()),
        playerBarViewProvider.overrideWithValue(playerBar),
      ],
    );

Widget app(ProviderContainer container) => UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: SettingsScreen()),
    );

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
    expect(toggle, findsOneWidget);
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);

    await tester.tap(toggle);
    await tester.pumpAndSettle();

    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
  });

  testWidgets('the Letterboxd section shows the URL and catalog toggles',
      (tester) async {
    final container = makeContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(app(container));
    await tester.pumpAndSettle();

    expect(find.text('Letterboxd'), findsOneWidget);
    expect(find.text('Stremboxd manifest URL'), findsOneWidget);

    for (final label in ['Watchlist', 'Recommended', 'Friends Activity', 'Popular This Week', 'Top 250']) {
      expect(find.widgetWithText(SwitchListTile, label), findsOneWidget);
    }

    // Defaults: watchlist/recommended/popular on; friends/top250 off.
    bool on(String label) =>
        tester.widget<SwitchListTile>(find.widgetWithText(SwitchListTile, label)).value;
    expect(on('Watchlist'), isTrue);
    expect(on('Recommended'), isTrue);
    expect(on('Popular This Week'), isTrue);
    expect(on('Friends Activity'), isFalse);
    expect(on('Top 250'), isFalse);
  });

  testWidgets('saving a manifest URL and toggling a catalog persist',
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

    final urlField = find.byType(TextField);
    await tester.ensureVisible(urlField);
    await tester.pumpAndSettle();
    await tester.enterText(
      urlField,
      'https://api.stremboxd.com/stremio/abc/manifest.json',
    );
    final saveUrl = find.byTooltip('Save URL');
    await tester.ensureVisible(saveUrl);
    await tester.pumpAndSettle();
    await tester.tap(saveUrl);
    await tester.pumpAndSettle();
    expect(
      container.read(settingsControllerProvider).letterboxdManifestUrl,
      'https://api.stremboxd.com/stremio/abc/manifest.json',
    );

    final friends = find.widgetWithText(SwitchListTile, 'Friends Activity');
    await tester.ensureVisible(friends);
    await tester.pumpAndSettle();
    await tester.tap(friends);
    await tester.pumpAndSettle();
    expect(
      container.read(settingsControllerProvider).enabledLetterboxdCatalogs,
      contains('letterboxd-friends'),
    );
  });

  testWidgets('an unsaved URL survives an unrelated toggle rebuild',
      (tester) async {
    final container = makeContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(app(container));
    await tester.pumpAndSettle();

    final urlField = find.byType(TextField);
    await tester.ensureVisible(urlField);
    await tester.pumpAndSettle();
    await tester.enterText(urlField, 'https://typed.but/not/saved/manifest.json');

    final watchlist = find.widgetWithText(SwitchListTile, 'Watchlist');
    await tester.ensureVisible(watchlist);
    await tester.pumpAndSettle();
    await tester.tap(watchlist);
    await tester.pumpAndSettle();

    // The rebuild from the toggle must not reset the in-progress text.
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
}
