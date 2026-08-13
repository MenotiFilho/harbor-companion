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
import 'package:harbor_companion/app/settings/settings_screen.dart';
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

ProviderContainer makeContainer() => ProviderContainer(
      overrides: [
        wsTransportProvider.overrideWithValue(FakeTransport()),
        wsKeyStoreProvider.overrideWithValue(FakeKeyStore()),
        hostRegistryStoreProvider.overrideWithValue(InMemoryHostRegistryStore()),
        subnetScannerProvider.overrideWithValue(const FixedSubnetScanner([])),
        selfUpdateVersionProvider.overrideWithValue(FakeVersionProvider()),
        releasesClientProvider.overrideWithValue(FakeReleasesClient()),
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
    await tester.enterText(find.byType(TextField).first, 'desk');
    await tester.enterText(find.byType(TextField).last, '192.168.1.50');
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

    expect(find.text('Check for updates'), findsOneWidget);

    await tester.tap(find.text('Check for updates'));
    await tester.pumpAndSettle();

    expect(find.text('No update available'), findsOneWidget);
  });
}
