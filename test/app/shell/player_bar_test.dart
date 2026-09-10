// Widget tests for the persistent player bar (issue #42).
//
// The bar is a floating mini-player shown on every screen except the Remote
// tab. These tests pin the content (poster / title / episode / play state), the
// host-authoritative play/pause tap, and tap-to-open-Remote. They stub
// [playerBarViewProvider], the single seam the bar renders from.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:harbor_companion/app/home/poster_image.dart';
import 'package:harbor_companion/app/remote/remote_controller.dart';
import 'package:harbor_companion/app/remote/remote_reducer.dart';
import 'package:harbor_companion/app/shell/player_bar.dart';
import 'package:harbor_companion/app/shell/shell_controller.dart';
import 'package:harbor_companion/app/shell/shell_reducer.dart';
import 'package:harbor_companion/app/shell/shell_tab.dart';

class _StubRemoteController extends RemoteController {
  final RemoteState? initial;
  int toggles = 0;

  _StubRemoteController([this.initial]);

  @override
  RemoteState build() => initial ?? RemoteState(connected: true);

  @override
  void togglePlay() => toggles++;
}

class _StubShellController extends ShellController {
  final ShellState initialState;

  _StubShellController(this.initialState);

  @override
  ShellState build() => initialState;
}

const _view = PlayerBarView(title: 'Shawshank', playing: true);

ProviderContainer _container({
  PlayerBarView? view = _view,
  ShellState shell = const ShellState(
    connection: ConnectionStatus.connected,
    activeTab: ShellTab.home,
  ),
}) {
  final container = ProviderContainer(
    overrides: [
      playerBarViewProvider.overrideWithValue(view),
      remoteControllerProvider.overrideWith(() => _StubRemoteController()),
      shellControllerProvider.overrideWith(() => _StubShellController(shell)),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Widget _app() => const MaterialApp(home: Scaffold(body: PlayerBar()));

Future<void> _pump(WidgetTester tester, ProviderContainer container) =>
    tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: _app()),
    );

void main() {
  testWidgets('hidden when there is no view', (tester) async {
    await _pump(tester, _container(view: null));
    expect(find.byType(IconButton), findsNothing);
    expect(find.byType(PosterImage), findsNothing);
  });

  testWidgets('renders the poster, title and a pause control while playing',
      (tester) async {
    await _pump(
      tester,
      _container(
        view: const PlayerBarView(
          title: 'Shawshank',
          posterUrl: 'http://host/poster.jpg',
          playing: true,
        ),
      ),
    );
    expect(find.byType(PosterImage), findsOneWidget);
    expect(find.text('Shawshank'), findsOneWidget);
    expect(find.byIcon(Icons.pause), findsOneWidget);
    expect(find.byIcon(Icons.play_arrow), findsNothing);
  });

  testWidgets('shows the episode line for a series', (tester) async {
    await _pump(
      tester,
      _container(
        view: const PlayerBarView(
          title: 'Breaking Bad',
          episodeLine: 'S2 · E5  Breakage',
          playing: true,
        ),
      ),
    );
    expect(find.textContaining('S2 · E5'), findsOneWidget);
    expect(find.textContaining('Breakage'), findsOneWidget);
  });

  testWidgets('shows a play control when the media is paused', (tester) async {
    await _pump(
      tester,
      _container(view: const PlayerBarView(title: 'Shawshank', playing: false)),
    );
    expect(find.byIcon(Icons.play_arrow), findsOneWidget);
    expect(find.byIcon(Icons.pause), findsNothing);
  });

  testWidgets('tapping play/pause drives the remote transport', (tester) async {
    final container = _container();
    await _pump(tester, container);

    await tester.tap(find.byIcon(Icons.pause));
    await tester.pump();

    final remote = container.read(remoteControllerProvider.notifier)
        as _StubRemoteController;
    expect(remote.toggles, 1);
  });

  testWidgets('tapping the bar body opens the Remote tab', (tester) async {
    final container = _container();
    await _pump(tester, container);

    await tester.tap(find.text('Shawshank'));
    await tester.pump();

    expect(container.read(shellControllerProvider).activeTab, ShellTab.remote);
  });

  testWidgets('tapping play/pause does not also open Remote', (tester) async {
    final container = _container();
    await _pump(tester, container);

    await tester.tap(find.byIcon(Icons.pause));
    await tester.pump();

    expect(container.read(shellControllerProvider).activeTab, ShellTab.home);
  });

  group('playerBarViewProvider', () {
    RemoteState held() => RemoteState(
          connected: true,
          phase: RemotePhase.nowPlaying,
          nowPlaying: const NowPlaying(
            mediaId: 'tt1',
            mediaTitle: 'Shawshank',
            playing: true,
          ),
        );

    ProviderContainer real(RemoteState remote) {
      final container = ProviderContainer(
        overrides: [
          connectionStatusProvider.overrideWith(ConnectionStatusController.new),
          remoteControllerProvider
              .overrideWith(() => _StubRemoteController(remote)),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('null while disconnected, even with held media', () {
      expect(real(held()).read(playerBarViewProvider), isNull);
    });

    test('null when connected but nothing is held', () {
      final container = real(RemoteState(connected: true));
      container
          .read(connectionStatusProvider.notifier)
          .set(ConnectionStatus.connected);
      expect(container.read(playerBarViewProvider), isNull);
    });

    test('the view when connected and media is held', () {
      final container = real(held());
      container
          .read(connectionStatusProvider.notifier)
          .set(ConnectionStatus.connected);

      final view = container.read(playerBarViewProvider);
      expect(view?.title, 'Shawshank');
      expect(view?.playing, isTrue);
    });
  });
}
