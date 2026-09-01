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
import 'package:harbor_companion/app/settings/settings_controller.dart';
import 'package:harbor_companion/app/ws/client_reducer.dart' show TextEntry;

class _StubRemoteController extends RemoteController {
  @override
  final RemoteState state;
  _StubRemoteController(this.state);
  @override
  RemoteState build() => state;
}

class _StubSettingsController extends SettingsController {
  @override
  final SettingsState state;
  _StubSettingsController(this.state);
  @override
  SettingsState build() => state;
}

Widget _wrap(RemoteState state,
        {SettingsState settings = const SettingsState()}) =>
    ProviderScope(
      overrides: [
        remoteControllerProvider
            .overrideWith(() => _StubRemoteController(state)),
        settingsControllerProvider
            .overrideWith(() => _StubSettingsController(settings)),
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

  testWidgets('Navigate is collapsed by default', (tester) async {
    await tester.pumpWidget(_wrap(RemoteState(connected: true)));
    expect(find.text('Navigate'), findsOneWidget);
    // The d-pad + Open search + Back are hidden until expanded.
    expect(find.text('Open search'), findsNothing);
    expect(find.text('Back'), findsNothing);
    expect(find.byIcon(Icons.keyboard_arrow_up), findsNothing);
    expect(find.byIcon(Icons.check), findsNothing);
  });

  testWidgets('tapping the Navigate header expands the d-pad', (tester) async {
    await tester.pumpWidget(_wrap(RemoteState(connected: true)));
    await tester.tap(find.text('Navigate'));
    await tester.pumpAndSettle();
    expect(find.text('Open search'), findsOneWidget);
    expect(find.text('Back'), findsOneWidget);
    expect(find.byIcon(Icons.keyboard_arrow_up), findsOneWidget);
    expect(find.byIcon(Icons.check), findsOneWidget);
  });

  testWidgets('tapping the Navigate header again collapses the d-pad', (tester) async {
    await tester.pumpWidget(_wrap(RemoteState(connected: true)));
    await tester.tap(find.text('Navigate'));
    await tester.pumpAndSettle();
    expect(find.text('Open search'), findsOneWidget);
    await tester.tap(find.text('Navigate'));
    await tester.pumpAndSettle();
    expect(find.text('Open search'), findsNothing);
    expect(find.byIcon(Icons.check), findsNothing);
  });

  testWidgets('the d-pad buttons stay disabled while disconnected', (tester) async {
    await tester.pumpWidget(_wrap(RemoteState()));
    await tester.tap(find.text('Navigate'));
    await tester.pumpAndSettle();
    final select = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.check),
    );
    final search =
        tester.widget<TextButton>(find.widgetWithText(TextButton, 'Open search'));
    final back =
        tester.widget<TextButton>(find.widgetWithText(TextButton, 'Back'));
    expect(select.onPressed, isNull);
    expect(search.onPressed, isNull);
    expect(back.onPressed, isNull);
  });

  testWidgets('the playback-location section is hidden by default', (tester) async {
    await tester.pumpWidget(_wrap(RemoteState(connected: true)));
    expect(find.byIcon(Icons.cast), findsNothing);
    expect(find.text('This PC'), findsNothing);
  });

  testWidgets('the playback-location section shows when the setting is on',
      (tester) async {
    await tester.pumpWidget(_wrap(
      RemoteState(connected: true),
      settings: const SettingsState(showPlaybackLocation: true),
    ));
    expect(find.byIcon(Icons.cast), findsOneWidget);
    expect(find.text('This PC'), findsOneWidget);
  });

  testWidgets('text entry receives focus when it appears', (tester) async {
    await tester.pumpWidget(_wrap(RemoteState(
      connected: true,
      textEntry: const TextEntry('typed', 'Search'),
    )));
    await tester.pump();

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.focusNode?.hasFocus, isTrue);
  });
}
