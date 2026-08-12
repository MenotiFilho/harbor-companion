// Thin widget test for the Remote screen (the reducer is the real seam).
// Verifies the three phases render: idle, awaitingStart, and now-playing
// (title + transport). Cast/nav/text wiring is exercised through the reducer
// and controller tests.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:harbor_companion/app/home/home_reducer.dart' show PlayMetaCommand;
import 'package:harbor_companion/app/remote/remote_controller.dart';
import 'package:harbor_companion/app/remote/remote_reducer.dart';
import 'package:harbor_companion/app/remote/remote_screen.dart';

class _StubRemoteController extends RemoteController {
  @override
  final RemoteState state;
  _StubRemoteController(this.state);
  @override
  RemoteState build() => state;
}

Widget _wrap(RemoteState state) => ProviderScope(
      overrides: [
        remoteControllerProvider
            .overrideWith(() => _StubRemoteController(state)),
      ],
      child: const MaterialApp(home: Scaffold(body: RemoteScreen())),
    );

void main() {
  testWidgets('idle shows the nothing-playing empty state', (tester) async {
    await tester.pumpWidget(_wrap(RemoteState(connected: true)));
    expect(find.text('Nothing playing'), findsOneWidget);
  });

  testWidgets('awaitingStart shows the starting card', (tester) async {
    await tester.pumpWidget(_wrap(RemoteState(
      connected: true,
      phase: RemotePhase.awaitingStart,
      playRequest: const PlayMetaCommand(
        metaId: 'tt1',
        metaType: 'movie',
        name: 'Shawshank',
      ),
    )));
    expect(find.textContaining('Starting Shawshank'), findsOneWidget);
  });

  testWidgets('now-playing shows the title and transport', (tester) async {
    await tester.pumpWidget(_wrap(RemoteState(
      connected: true,
      phase: RemotePhase.nowPlaying,
      nowPlaying: const NowPlaying(
        mediaId: 'tt1',
        mediaTitle: 'Shawshank',
        playing: true,
        hasPrevEpisode: true,
        hasNextEpisode: true,
      ),
    )));
    expect(find.text('Shawshank'), findsOneWidget);
    expect(find.byIcon(Icons.pause), findsOneWidget);
    expect(find.byIcon(Icons.skip_previous), findsOneWidget);
    expect(find.byIcon(Icons.skip_next), findsOneWidget);
  });

  testWidgets('a disconnected banner renders while not connected', (tester) async {
    await tester.pumpWidget(_wrap(RemoteState()));
    expect(find.textContaining('Not connected'), findsOneWidget);
  });
}
