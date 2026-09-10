// Widget tests for the detail page (thin coverage: the reducer is the real
// seam). Verifies the header (title + description) renders immediately while
// the detail is still loading instead of a blank spinner, and that a ready
// series detail renders one season tab per non-empty season, defaults to the
// first, and switches episodes on tap.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:harbor_companion/app/home/detail_screen.dart';
import 'package:harbor_companion/app/home/home_controller.dart';
import 'package:harbor_companion/app/home/home_reducer.dart';
import 'package:harbor_companion/app/home/meta.dart';
import 'package:harbor_companion/app/shell/player_bar.dart';

class _StubHomeController extends HomeController {
  @override
  final HomeState state;
  _StubHomeController(this.state);
  @override
  HomeState build() => state;
}

Meta seriesMeta() => Meta(
    id: 'tt1', type: 'series', name: 'Breaking Bad', description: 'A show');

DetailMeta seriesDetail() => DetailMeta(
      meta: seriesMeta(),
      seasons: [
        Season(number: 1, name: 'Season 1', episodes: [
          Episode(season: 1, episode: 1, name: 'Pilot'),
          Episode(season: 1, episode: 2, name: 'Cat'),
        ]),
        Season(number: 2, name: 'Season 2', episodes: [
          Episode(season: 2, episode: 1, name: 'Seven Thirty-Seven'),
        ]),
      ],
    );

HomeState _loading(Meta meta) =>
    HomeState(detail: DetailState(status: DetailStatus.loading, meta: meta));

HomeState _ready(DetailMeta detail) => HomeState(
    detail: DetailState(status: DetailStatus.ready, meta: detail.meta, detail: detail));

Widget _wrap(HomeState state, {PlayerBarView? playerBar}) => ProviderScope(
      overrides: [
        homeControllerProvider.overrideWith(() => _StubHomeController(state)),
        playerBarViewProvider.overrideWithValue(playerBar),
      ],
      child: const MaterialApp(home: DetailScreen()),
    );

void main() {
  testWidgets('shows the title and description immediately while loading',
      (tester) async {
    await tester.pumpWidget(_wrap(_loading(seriesMeta())));

    expect(find.text('A show'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('a ready series renders one tab per season, first selected',
      (tester) async {
    await tester.pumpWidget(_wrap(_ready(seriesDetail())));

    expect(find.text('Season 1'), findsOneWidget);
    expect(find.text('Season 2'), findsOneWidget);
    expect(find.textContaining('Pilot'), findsOneWidget);
    expect(find.textContaining('Seven Thirty-Seven'), findsNothing);
  });

  testWidgets('tapping a season tab switches the episode list', (tester) async {
    await tester.pumpWidget(_wrap(_ready(seriesDetail())));

    await tester.tap(find.text('Season 2'));
    await tester.pump();

    expect(find.textContaining('Seven Thirty-Seven'), findsOneWidget);
    expect(find.textContaining('Pilot'), findsNothing);
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
  });

  testWidgets('a movie detail shows no season tabs', (tester) async {
    final movie = DetailMeta(
        meta: Meta(id: 'tt1', type: 'movie', name: 'The Matrix'));
    await tester.pumpWidget(_wrap(_ready(movie)));

    expect(find.byType(ChoiceChip), findsNothing);
    expect(find.text('Play'), findsOneWidget);
  });

  testWidgets('renders the floating player bar when media is held',
      (tester) async {
    final movie = DetailMeta(
        meta: Meta(id: 'tt1', type: 'movie', name: 'The Matrix'));
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
