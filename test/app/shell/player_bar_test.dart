// Widget tests for the shell's persistent player bar (issue #42).
//
// The bar is a thin dock above the navigation bar, visible on every tab while
// the Remote layer holds media (live or sticky-held). These tests pin the
// visibility gate, the title/episode content, the host-authoritative
// play/pause tap, and tap-to-open-Remote.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:harbor_companion/app/remote/remote_controller.dart';
import 'package:harbor_companion/app/remote/remote_reducer.dart';
import 'package:harbor_companion/app/shell/player_bar.dart';
import 'package:harbor_companion/app/shell/shell_controller.dart';
import 'package:harbor_companion/app/shell/shell_reducer.dart';
import 'package:harbor_companion/app/shell/shell_tab.dart';
import 'package:harbor_companion/app/ws/client_reducer.dart' show EpisodeRef;

class _StubRemoteController extends RemoteController {
  final RemoteState initialState;
  int toggles = 0;

  _StubRemoteController(this.initialState);

  @override
  RemoteState build() => initialState;

  @override
  void togglePlay() => toggles++;
}

class _StubShellController extends ShellController {
  final ShellState initialState;

  _StubShellController(this.initialState);

  @override
  ShellState build() => initialState;
}

const _connectedShell = ShellState(connection: ConnectionStatus.connected);

NowPlaying _playing({bool playing = true, EpisodeRef? episode}) => NowPlaying(
      mediaId: 'tt1',
      mediaTitle: 'Shawshank',
      episode: episode,
      playing: playing,
    );

ProviderContainer _container({
  required RemoteState remote,
  ShellState shell = _connectedShell,
}) {
  final container = ProviderContainer(
    overrides: [
      remoteControllerProvider
          .overrideWith(() => _StubRemoteController(remote)),
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
  testWidgets('hidden when nothing is held', (tester) async {
    await _pump(tester, _container(remote: RemoteState(connected: true)));
    expect(find.text('Shawshank'), findsNothing);
    expect(find.byType(IconButton), findsNothing);
  });

  testWidgets('stays visible while media is held even without a title',
      (tester) async {
    await _pump(
      tester,
      _container(
        remote: RemoteState(
          connected: true,
          phase: RemotePhase.nowPlaying,
          nowPlaying: const NowPlaying(mediaTitle: ''),
        ),
      ),
    );
    expect(find.byType(IconButton), findsOneWidget);
  });

  testWidgets('shows the title and a pause control while playing',
      (tester) async {
    await _pump(
      tester,
      _container(
        remote: RemoteState(
          connected: true,
          phase: RemotePhase.nowPlaying,
          nowPlaying: _playing(),
        ),
      ),
    );
    expect(find.text('Shawshank'), findsOneWidget);
    expect(find.byIcon(Icons.pause), findsOneWidget);
    expect(find.byIcon(Icons.play_arrow), findsNothing);
  });

  testWidgets('shows the episode line for a series', (tester) async {
    await _pump(
      tester,
      _container(
        remote: RemoteState(
          connected: true,
          phase: RemotePhase.nowPlaying,
          nowPlaying: _playing(episode: const EpisodeRef(2, 5, 'Breakage')),
        ),
      ),
    );
    expect(find.textContaining('S2 · E5'), findsOneWidget);
    expect(find.textContaining('Breakage'), findsOneWidget);
  });

  testWidgets('shows a play control when the media is paused', (tester) async {
    await _pump(
      tester,
      _container(
        remote: RemoteState(
          connected: true,
          phase: RemotePhase.nowPlaying,
          nowPlaying: _playing(playing: false),
        ),
      ),
    );
    expect(find.byIcon(Icons.play_arrow), findsOneWidget);
    expect(find.byIcon(Icons.pause), findsNothing);
  });

  testWidgets('tapping play/pause drives the remote transport', (tester) async {
    final container = _container(
      remote: RemoteState(
        connected: true,
        phase: RemotePhase.nowPlaying,
        nowPlaying: _playing(),
      ),
    );
    await _pump(tester, container);

    await tester.tap(find.byIcon(Icons.pause));
    await tester.pump();

    final remote =
        container.read(remoteControllerProvider.notifier) as _StubRemoteController;
    expect(remote.toggles, 1);
  });

  testWidgets('tapping the bar body opens the Remote tab', (tester) async {
    final container = _container(
      remote: RemoteState(
        connected: true,
        phase: RemotePhase.nowPlaying,
        nowPlaying: _playing(),
      ),
      shell: const ShellState(
        connection: ConnectionStatus.connected,
        activeTab: ShellTab.home,
      ),
    );
    await _pump(tester, container);

    await tester.tap(find.text('Shawshank'));
    await tester.pump();

    expect(container.read(shellControllerProvider).activeTab, ShellTab.remote);
  });

  testWidgets('tapping play/pause does not also open Remote', (tester) async {
    final container = _container(
      remote: RemoteState(
        connected: true,
        phase: RemotePhase.nowPlaying,
        nowPlaying: _playing(),
      ),
      shell: const ShellState(
        connection: ConnectionStatus.connected,
        activeTab: ShellTab.home,
      ),
    );
    await _pump(tester, container);

    await tester.tap(find.byIcon(Icons.pause));
    await tester.pump();

    expect(container.read(shellControllerProvider).activeTab, ShellTab.home);
  });

  testWidgets('never shows in the connect-first view', (tester) async {
    await _pump(
      tester,
      _container(
        remote: RemoteState(
          connected: true,
          phase: RemotePhase.nowPlaying,
          nowPlaying: _playing(),
        ),
        shell: const ShellState(connection: ConnectionStatus.disconnected),
      ),
    );
    expect(find.text('Shawshank'), findsNothing);
    expect(find.byType(IconButton), findsNothing);
  });
}
