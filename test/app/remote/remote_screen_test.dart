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
import 'package:harbor_companion/app/ws/client_reducer.dart'
    show EpisodeRef, SourceInfo, TextEntry;

class _StubRemoteController extends RemoteController {
  @override
  final RemoteState state;
  final List<double> skips = [];
  _StubRemoteController(this.state);
  @override
  RemoteState build() => state;
  @override
  void skipBy(double seconds) => skips.add(seconds);
}

class _StubSettingsController extends SettingsController {
  @override
  final SettingsState state;
  _StubSettingsController(this.state);
  @override
  SettingsState build() => state;
}

Widget _wrap(RemoteState state,
        {SettingsState settings = const SettingsState(),
        _StubRemoteController? controller}) =>
    ProviderScope(
      overrides: [
        remoteControllerProvider.overrideWith(
            () => controller ?? _StubRemoteController(state)),
        settingsControllerProvider
            .overrideWith(() => _StubSettingsController(settings)),
      ],
      child: const MaterialApp(home: Scaffold(body: RemoteScreen())),
    );

/// A now-playing state with held media, the shape every transport assertion
/// starts from.
RemoteState _playing({
  bool playing = true,
  double positionSec = 100,
  double durationSec = 1000,
  bool hasPrev = true,
  bool hasNext = true,
}) =>
    RemoteState(
      connected: true,
      phase: RemotePhase.nowPlaying,
      nowPlaying: NowPlaying(
        mediaId: 'tt1',
        mediaTitle: 'Shawshank',
        positionSec: positionSec,
        durationSec: durationSec,
        playing: playing,
        hasPrevEpisode: hasPrev,
        hasNextEpisode: hasNext,
      ),
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

  testWidgets('now-playing shows the Cinemascope band and transport',
      (tester) async {
    await tester.pumpWidget(_wrap(_playing()));
    expect(find.byKey(const ValueKey('remoteBand')), findsOneWidget);
    expect(find.text('Shawshank'), findsOneWidget);
    expect(find.byIcon(Icons.pause), findsOneWidget);
    for (final icon in const [
      Icons.skip_previous,
      Icons.replay_30,
      Icons.pause,
      Icons.forward_30,
      Icons.skip_next,
    ]) {
      expect(find.byIcon(icon), findsOneWidget, reason: '$icon');
    }
  });

  testWidgets('the band shows the episode/source ficha over the scrim',
      (tester) async {
    await tester.pumpWidget(_wrap(RemoteState(
      connected: true,
      phase: RemotePhase.nowPlaying,
      nowPlaying: const NowPlaying(
        mediaId: 'tt1',
        mediaTitle: 'Shawshank',
        episode: EpisodeRef(1, 2, 'Winterfell'),
        source: SourceInfo(null, null, '1080p', 'WEB-DL'),
        positionSec: 100,
        durationSec: 1000,
        playing: true,
      ),
    )));
    expect(find.text('S1 · E2  Winterfell  ·  1080p · WEB-DL'), findsOneWidget);
  });

  testWidgets('the transport is disabled without held media', (tester) async {
    await tester.pumpWidget(_wrap(RemoteState(connected: true)));
    for (final icon in const [
      Icons.skip_previous,
      Icons.replay_30,
      Icons.play_arrow,
      Icons.forward_30,
      Icons.skip_next,
    ]) {
      final button =
          tester.widget<IconButton>(find.widgetWithIcon(IconButton, icon));
      expect(button.onPressed, isNull, reason: '$icon stays disabled');
    }
  });

  testWidgets('the five transport buttons are enabled with held media',
      (tester) async {
    await tester.pumpWidget(_wrap(_playing()));
    for (final icon in const [
      Icons.skip_previous,
      Icons.replay_30,
      Icons.pause,
      Icons.forward_30,
      Icons.skip_next,
    ]) {
      final button =
          tester.widget<IconButton>(find.widgetWithIcon(IconButton, icon));
      expect(button.onPressed, isNotNull, reason: '$icon is enabled');
    }
  });

  testWidgets('tapping ±30 calls the reducer skip path', (tester) async {
    final ctrl = _StubRemoteController(_playing());
    await tester.pumpWidget(_wrap(ctrl.state, controller: ctrl));
    await tester.tap(find.widgetWithIcon(IconButton, Icons.forward_30));
    await tester.tap(find.widgetWithIcon(IconButton, Icons.replay_30));
    expect(ctrl.skips, [30, -30]);
  });

  testWidgets('skip stays enabled while paused', (tester) async {
    final ctrl = _StubRemoteController(_playing(playing: false));
    await tester.pumpWidget(_wrap(ctrl.state, controller: ctrl));
    expect(find.byIcon(Icons.play_arrow), findsOneWidget);
    final forward =
        tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.forward_30));
    expect(forward.onPressed, isNotNull);
    await tester.tap(find.widgetWithIcon(IconButton, Icons.forward_30));
    expect(ctrl.skips, [30]);
  });

  testWidgets('volume and Navigate live below the band', (tester) async {
    await tester.pumpWidget(_wrap(_playing()));
    final band = find.byKey(const ValueKey('remoteBand'));
    expect(tester.getBottomLeft(band).dy, kRemoteBandHeight);
    // The seek slider is the band's; the volume slider is the other one and
    // starts below the fold.
    expect(
      find.descendant(of: band, matching: find.byType(Slider)),
      findsOneWidget,
    );
    expect(find.byType(Slider), findsNWidgets(2));
    expect(
      tester.getTopLeft(find.text('Navigate')).dy,
      greaterThanOrEqualTo(kRemoteBandHeight),
    );
  });

  testWidgets('a disconnected banner renders while not connected',
      (tester) async {
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
