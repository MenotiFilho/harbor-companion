import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import 'package:harbor_companion/app/shell/connect_first_view.dart';
import 'package:harbor_companion/app/shell/shell_controller.dart';
import 'package:harbor_companion/app/shell/shell_reducer.dart';
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

/// The shell's self-update seam (launch check fires on app start); tests stub
/// it so no package_info_plus channel or network is touched.
List<Override> selfUpdateOverrides() => [
      selfUpdateVersionProvider.overrideWithValue(_FakeVersionProvider()),
      releasesClientProvider.overrideWithValue(_FakeReleasesClient()),
    ];

void main() {
  testWidgets('fresh install shows the connect-first empty state and five tabs',
      (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: selfUpdateOverrides(),
      child: const HarborCompanionApp(),
    ));

    expect(find.byType(ConnectFirstView), findsOneWidget);

    for (final label in ['Remote', 'Search', 'Home', 'My Stuff', 'Profile']) {
      expect(find.text(label), findsWidgets);
    }
  });

  testWidgets('the connect-first view leads to settings', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: selfUpdateOverrides(),
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
        ...selfUpdateOverrides(),
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
}
