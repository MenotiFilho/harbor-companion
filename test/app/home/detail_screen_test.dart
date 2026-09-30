// Widget tests for the detail page (thin coverage: the reducer is the real
// seam). Pins the editorial refresh (ticket 84): the header renders from the
// Meta the moment the page opens — band with the artwork fallback, ficha,
// poster, synopsis and CTA — while the episodes are still loading; the season
// segmented control and episode rows (still, duration, overview); the play
// seams (play / play first episode / episode tap → playMeta); the Cast section
// (#86) settling on its own provider; and the honesty rule: no My List/Download,
// no watched marker, no duration line without a runtime.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import 'package:harbor_companion/app/home/detail_extras_fetcher.dart';
import 'package:harbor_companion/app/home/detail_screen.dart';
import 'package:harbor_companion/app/home/home_controller.dart';
import 'package:harbor_companion/app/home/home_reducer.dart';
import 'package:harbor_companion/app/home/meta.dart';
import 'package:harbor_companion/app/remote/remote_controller.dart';
import 'package:harbor_companion/app/remote/remote_reducer.dart';
import 'package:harbor_companion/app/shell/player_bar.dart';

/// A HomeController pinned to [initial]. Unlike a field override, the base
/// state still folds `_dispatch`ed events, so a play tap reaches the recording
/// Remote below.
class _StubHomeController extends HomeController {
  _StubHomeController(this.initial);
  final HomeState initial;
  @override
  HomeState build() => initial;
}

/// Records `playMeta` commands instead of driving the WS client.
class _RecordingRemoteController extends RemoteController {
  final played = <PlayMetaCommand>[];
  @override
  RemoteState build() => RemoteState();
  @override
  void playMeta(PlayMetaCommand command) => played.add(command);
}

Meta seriesMeta() => Meta(
      id: 'tt1',
      type: 'series',
      name: 'Breaking Bad',
      poster: 'https://img/poster.jpg',
      background: 'https://img/backdrop.jpg',
      description: 'A chemistry teacher turns to crime.',
      releaseInfo: '2008',
    );

DetailMeta seriesDetail() => DetailMeta(
      meta: seriesMeta(),
      seasons: [
        Season(number: 1, name: 'Season 1', episodes: [
          Episode(
            season: 1,
            episode: 1,
            name: 'Pilot',
            overview: 'The pilot episode.',
            still: 'https://img/s1e1.jpg',
            duration: const Duration(minutes: 48),
          ),
          Episode(season: 1, episode: 2, name: 'Cat', overview: 'A cat.'),
        ]),
        Season(number: 2, name: 'Season 2', episodes: [
          Episode(season: 2, episode: 1, name: 'Seven Thirty-Seven'),
        ]),
      ],
    );

HomeState _loading(Meta meta) =>
    HomeState(detail: DetailState(status: DetailStatus.loading, meta: meta));

HomeState _ready(DetailMeta detail) => HomeState(
    detail:
        DetailState(status: DetailStatus.ready, meta: detail.meta, detail: detail));

HomeState _failed(Meta meta, String error) => HomeState(
    detail:
        DetailState(status: DetailStatus.failed, meta: meta, error: error));

Widget _wrap(
  HomeState state, {
  PlayerBarView? playerBar,
  _RecordingRemoteController? remote,
  List<Override> overrides = const [],
}) =>
    ProviderScope(
      overrides: [
        homeControllerProvider.overrideWith(() => _StubHomeController(state)),
        playerBarViewProvider.overrideWithValue(playerBar),
        remoteControllerProvider
            .overrideWith(() => remote ?? _RecordingRemoteController()),
        ...overrides,
      ],
      child: const MaterialApp(home: DetailScreen()),
    );

Finder _inHero(Finder matching) => find.descendant(
      of: find.byKey(const ValueKey('detailHero')),
      matching: matching,
    );

void main() {
  group('header', () {
    testWidgets('renders the Meta immediately while the episodes load',
        (tester) async {
      await tester.pumpWidget(_wrap(_loading(seriesMeta())));

      // The band, with the Backdrop as artwork and the name/ficha over it.
      expect(find.byKey(const ValueKey('detailHero')), findsOneWidget);
      expect(find.byKey(const ValueKey('heroBackdrop')), findsOneWidget);
      expect(_inHero(find.text('Breaking Bad')), findsOneWidget);
      expect(_inHero(find.text('2008')), findsOneWidget);
      expect(_inHero(find.text('SERIES')), findsOneWidget);
      // Poster + synopsis just below, and the honest disabled CTA (a series
      // has no first episode yet).
      expect(find.text('A chemistry teacher turns to crime.'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      final cta = tester.widget<FilledButton>(
          find.widgetWithText(FilledButton, 'Play first episode'));
      expect(cta.onPressed, isNull);
    });

    testWidgets('without a Backdrop the hero blurs the Poster',
        (tester) async {
      final meta = Meta(
        id: 'tt1',
        type: 'movie',
        name: 'The Matrix',
        poster: 'https://img/poster.jpg',
      );
      await tester.pumpWidget(_wrap(_ready(DetailMeta(meta: meta))));

      expect(find.byKey(const ValueKey('heroPosterBlur')), findsOneWidget);
      expect(find.byKey(const ValueKey('heroBackdrop')), findsNothing);
    });

    testWidgets('with no artwork at all the hero is a static gradient',
        (tester) async {
      final meta = Meta(id: 'tt1', type: 'movie', name: 'The Matrix');
      await tester.pumpWidget(_wrap(_ready(DetailMeta(meta: meta))));

      expect(find.byKey(const ValueKey('heroGradient')), findsOneWidget);
      expect(find.byKey(const ValueKey('heroPosterBlur')), findsNothing);
      expect(find.text('FILM'), findsOneWidget);
    });

    testWidgets('a failed episode fetch keeps the header and shows the error',
        (tester) async {
      await tester.pumpWidget(_wrap(_failed(seriesMeta(), 'boom')));

      expect(_inHero(find.text('Breaking Bad')), findsOneWidget);
      expect(find.text('boom'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('a movie shows no Episodes section', (tester) async {
      final meta = Meta(id: 'tt1', type: 'movie', name: 'The Matrix');
      await tester.pumpWidget(_wrap(_ready(DetailMeta(meta: meta))));

      expect(find.text('EPISODES'), findsNothing);
      expect(find.text('Season 1'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });
  });

  group('seasons and episodes', () {
    testWidgets('renders a discreet segmented control, first season selected',
        (tester) async {
      await tester.pumpWidget(_wrap(_ready(seriesDetail())));

      expect(find.text('EPISODES'), findsOneWidget);
      expect(find.byType(ChoiceChip), findsNothing,
          reason: 'seasons are a segmented control, not loud chips');
      expect(find.text('Season 1'), findsOneWidget);
      expect(find.text('Season 2'), findsOneWidget);
      expect(find.textContaining('Pilot'), findsOneWidget);
      expect(find.textContaining('Seven Thirty-Seven'), findsNothing);
    });

    testWidgets('tapping a season segment switches the episode list',
        (tester) async {
      await tester.pumpWidget(_wrap(_ready(seriesDetail())));

      await tester.ensureVisible(find.text('Season 2'));
      await tester.pump();
      await tester.tap(find.text('Season 2'));
      await tester.pump();

      expect(find.textContaining('Seven Thirty-Seven'), findsOneWidget);
      expect(find.textContaining('Pilot'), findsNothing);
    });

    testWidgets('episode rows carry a still, duration and overview',
        (tester) async {
      await tester.pumpWidget(_wrap(_ready(seriesDetail())));

      expect(find.byKey(const ValueKey('episodeStill-1-1')), findsOneWidget);
      expect(find.textContaining('48 min'), findsOneWidget);
      expect(find.textContaining('The pilot episode.'), findsOneWidget);
    });

    testWidgets('an episode without a runtime renders no duration',
        (tester) async {
      await tester.pumpWidget(_wrap(_ready(seriesDetail())));

      // Season 2's only episode has neither runtime nor overview — never
      // invented.
      await tester.ensureVisible(find.text('Season 2'));
      await tester.pump();
      await tester.tap(find.text('Season 2'));
      await tester.pump();

      expect(find.text('Seven Thirty-Seven'), findsOneWidget);
      expect(find.textContaining('min'), findsNothing);
    });

    testWidgets('skips seasons with no episodes', (tester) async {
      final detail = DetailMeta(
        meta: seriesMeta(),
        seasons: [
          Season(number: 1, name: 'Season 1', episodes: [
            Episode(season: 1, episode: 1, name: 'Pilot'),
          ]),
          const Season(number: 2, name: 'Season 2'),
        ],
      );
      await tester.pumpWidget(_wrap(_ready(detail)));

      expect(find.text('Season 1'), findsOneWidget);
      expect(find.text('Season 2'), findsNothing);
      // The meta row counts only what is actually shown.
      expect(find.text('1 season · 1 episode'), findsOneWidget);
    });

    testWidgets('no My List, Download or watched marker exists',
        (tester) async {
      await tester.pumpWidget(_wrap(_ready(seriesDetail())));

      expect(find.text('My List'), findsNothing);
      expect(find.textContaining('Download'), findsNothing);
      expect(find.textContaining('Watched'), findsNothing);
      expect(find.byIcon(Icons.check), findsNothing);
    });
  });

  group('cast', () {
    const members = [
      CastMember(
        name: 'Bryan Cranston',
        character: 'Walter White',
        profile: 'https://img/cranston.jpg',
      ),
      CastMember(name: 'Aaron Paul', character: 'Jesse Pinkman'),
    ];

    testWidgets('renders the rail with names and characters when there is data',
        (tester) async {
      await tester.pumpWidget(_wrap(
        _ready(seriesDetail()),
        overrides: [
          castProvider.overrideWith((ref, title) async => members),
        ],
      ));
      await tester.pump();

      expect(find.text('CAST'), findsOneWidget);
      expect(find.byKey(const ValueKey('castRail')), findsOneWidget);
      expect(find.text('Bryan Cranston'), findsOneWidget);
      expect(find.text('Walter White'), findsOneWidget);
      expect(find.text('Aaron Paul'), findsOneWidget);
      expect(find.text('Jesse Pinkman'), findsOneWidget);
    });

    testWidgets('a pending cast never delays the header or the episodes',
        (tester) async {
      final pending = Completer<List<CastMember>>();
      await tester.pumpWidget(_wrap(
        _ready(seriesDetail()),
        overrides: [castProvider.overrideWith((ref, title) => pending.future)],
      ));

      expect(_inHero(find.text('Breaking Bad')), findsOneWidget);
      expect(find.text('Pilot'), findsOneWidget);
      expect(find.text('CAST'), findsNothing);
      expect(find.byKey(const ValueKey('castRail')), findsNothing);
      // The section's own loading never adds a spinner to the page.
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('an empty cast renders nothing', (tester) async {
      await tester.pumpWidget(_wrap(
        _ready(seriesDetail()),
        overrides: [
          castProvider.overrideWith((ref, title) async => const <CastMember>[]),
        ],
      ));
      await tester.pump();

      expect(find.text('CAST'), findsNothing);
      expect(find.byKey(const ValueKey('castRail')), findsNothing);
      expect(find.text('Pilot'), findsOneWidget);
    });

    testWidgets('a failed cast renders nothing and keeps the page honest',
        (tester) async {
      await tester.pumpWidget(_wrap(
        _ready(seriesDetail()),
        overrides: [
          castProvider.overrideWith((ref, title) async => throw Exception('boom')),
        ],
      ));
      await tester.pump();

      expect(find.text('CAST'), findsNothing);
      expect(find.byKey(const ValueKey('castRail')), findsNothing);
      expect(_inHero(find.text('Breaking Bad')), findsOneWidget);
      expect(find.text('Pilot'), findsOneWidget);
    });

    testWidgets('a movie renders the same rail when there is data',
        (tester) async {
      final meta = Meta(id: 'tt1', type: 'movie', name: 'The Matrix');
      await tester.pumpWidget(_wrap(
        _ready(DetailMeta(meta: meta)),
        overrides: [
          castProvider.overrideWith((ref, title) async => members),
        ],
      ));
      await tester.pump();

      // The rail is not series-only: it renders wherever there is data.
      expect(find.text('CAST'), findsOneWidget);
      expect(find.text('Bryan Cranston'), findsOneWidget);
    });
  });

  group('play seams', () {
    testWidgets('a movie Play sends playMeta for the movie', (tester) async {
      final remote = _RecordingRemoteController();
      final meta = Meta(id: 'tt1', type: 'movie', name: 'The Matrix');
      await tester.pumpWidget(
          _wrap(_ready(DetailMeta(meta: meta)), remote: remote));

      await tester.tap(find.text('Play'));
      await tester.pump();

      expect(remote.played.single.metaId, 'tt1');
      expect(remote.played.single.season, isNull);
      expect(remote.played.single.episode, isNull);
    });

    testWidgets('a series Play first episode sends playMeta for the first one',
        (tester) async {
      final remote = _RecordingRemoteController();
      await tester.pumpWidget(_wrap(_ready(seriesDetail()), remote: remote));

      await tester.tap(find.text('Play first episode'));
      await tester.pump();

      expect(remote.played.single.metaId, 'tt1');
      expect(remote.played.single.season, 1);
      expect(remote.played.single.episode, 1);
    });

    testWidgets('tapping an episode row sends playMeta for that episode',
        (tester) async {
      final remote = _RecordingRemoteController();
      await tester.pumpWidget(_wrap(_ready(seriesDetail()), remote: remote));

      await tester.ensureVisible(find.textContaining('Cat'));
      await tester.pump();
      await tester.tap(find.textContaining('Cat'));
      await tester.pump();

      expect(remote.played.single.season, 1);
      expect(remote.played.single.episode, 2);
    });

    testWidgets('a series with no episodes keeps Play first episode disabled',
        (tester) async {
      final remote = _RecordingRemoteController();
      await tester.pumpWidget(_wrap(
        _ready(DetailMeta(meta: seriesMeta())),
        remote: remote,
      ));

      final cta = tester.widget<FilledButton>(
          find.widgetWithText(FilledButton, 'Play first episode'));
      expect(cta.onPressed, isNull);
      expect(remote.played, isEmpty);
    });
  });

  testWidgets('renders the floating player bar when media is held',
      (tester) async {
    final movie =
        DetailMeta(meta: Meta(id: 'tt1', type: 'movie', name: 'The Matrix'));
    await tester.pumpWidget(_wrap(
      _ready(movie),
      playerBar: const PlayerBarView(
        title: 'The Matrix',
        episodeLine: 'S1 · E1  Pilot',
        playing: true,
      ),
    ));

    expect(find.byType(PlayerBar), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(PlayerBar),
        matching: find.text('The Matrix'),
      ),
      findsOneWidget,
    );
    expect(find.textContaining('S1 · E1'), findsOneWidget);
  });
}
