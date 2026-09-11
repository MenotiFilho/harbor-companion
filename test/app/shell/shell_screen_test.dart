import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

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
}
