// Widget tests for the Search screen (tickets 05, 88; the reducer is the real
// seam). Verifies typing debounces and the merged results grid + anime section
// render from the fetcher, that a tap opens the shared detail page, and the
// refresh presentation: a sober idle state, a glass field, the final-shape
// skeleton while loading (never a lonely spinner), and the top match in an
// unblurred glass card over 3-column grids.

import 'dart:async';

// Material also exports a SearchController (SearchAnchor); the search feature's
// own controller is the one this screen test stubs.
import 'package:flutter/material.dart' hide SearchController;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:harbor_companion/app/home/home_controller.dart';
import 'package:harbor_companion/app/home/home_reducer.dart';
import 'package:harbor_companion/app/home/meta.dart';
import 'package:harbor_companion/app/routes.dart';
import 'package:harbor_companion/app/search/jikan.dart';
import 'package:harbor_companion/app/search/search_controller.dart';
import 'package:harbor_companion/app/search/search_fetcher.dart';
import 'package:harbor_companion/app/search/search_reducer.dart';
import 'package:harbor_companion/app/search/search_screen.dart';
import 'package:harbor_companion/app/ui/glass_surface.dart';

class _FakeSearchFetcher implements SearchFetcher {
  @override
  Future<TmdbSearchPayload> searchTmdb(String query, String tmdbKey) async =>
      const TmdbSearchPayload([], []);

  @override
  Future<List<Meta>> searchCinemeta(String query) async => const [
        Meta(id: 'tt0133093', type: 'movie', name: 'The Matrix', releaseInfo: '1999'),
      ];

  @override
  Future<List<AnimeHit>> searchJikan(String query) async =>
      const [AnimeHit(malId: 1, kitsuId: 2, format: 'TV', name: 'Attack on Titan')];
}

class _SeriesFetcher implements SearchFetcher {
  @override
  Future<TmdbSearchPayload> searchTmdb(String query, String tmdbKey) async =>
      const TmdbSearchPayload([], []);

  @override
  Future<List<Meta>> searchCinemeta(String query) async => const [
        Meta(id: 'tt0944947', type: 'series', name: 'Game of Thrones'),
      ];

  @override
  Future<List<AnimeHit>> searchJikan(String query) async => const [];
}

/// A fetcher whose sources stay in flight until the test completes them, so
/// the loading state can be observed in place.
class _PendingSearchFetcher implements SearchFetcher {
  final Completer<List<Meta>> cinemeta = Completer<List<Meta>>();
  final Completer<List<AnimeHit>> jikan = Completer<List<AnimeHit>>();

  @override
  Future<TmdbSearchPayload> searchTmdb(String query, String tmdbKey) async =>
      const TmdbSearchPayload([], []);

  @override
  Future<List<Meta>> searchCinemeta(String query) => cinemeta.future;

  @override
  Future<List<AnimeHit>> searchJikan(String query) => jikan.future;
}

class _StubHomeController extends HomeController {
  final List<Meta> opened = [];
  @override
  HomeState build() => HomeState();
  @override
  void openDetail(Meta meta) => opened.add(meta);
}

/// A controller pinned to one outcome: the presentation tests inject the state
/// the reducer would publish, without driving the debounce/fetch plumbing.
class _StubSearchController extends SearchController {
  final SearchState fixed;
  _StubSearchController(this.fixed);

  @override
  SearchState build() => fixed;
}

void main() {
  testWidgets('typing a query debounces and renders results', (tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final fetcher = _FakeSearchFetcher();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          searchFetcherProvider.overrideWithValue(fetcher),
          jikanQueueProvider.overrideWithValue(
            JikanQueue(fetch: fetcher.searchJikan, spacing: Duration.zero),
          ),
        ],
        child: const MaterialApp(home: Scaffold(body: SearchScreen())),
      ),
    );

    await tester.enterText(find.byType(TextField), 'matrix');
    await tester.pump(const Duration(milliseconds: 180)); // debounce fires
    await tester.pumpAndSettle(); // sources resolve + republish

    expect(find.text('The Matrix'), findsWidgets);
    expect(find.text('Attack on Titan'), findsWidgets);
    expect(find.text('ANIME'), findsWidgets);
  });

  testWidgets('tapping a series result opens the shared detail page',
      (tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final fetcher = _SeriesFetcher();
    final home = _StubHomeController();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          searchFetcherProvider.overrideWithValue(fetcher),
          jikanQueueProvider.overrideWithValue(
            JikanQueue(fetch: fetcher.searchJikan, spacing: Duration.zero),
          ),
          homeControllerProvider.overrideWith(() => home),
        ],
        child: MaterialApp(
          routes: {AppRoutes.detail: (_) => const Scaffold(body: Text('DETAIL'))},
          home: const Scaffold(body: SearchScreen()),
        ),
      ),
    );

    await tester.enterText(find.byType(TextField), 'got');
    await tester.pump(const Duration(milliseconds: 180)); // debounce fires
    await tester.pumpAndSettle(); // sources resolve + republish

    expect(find.text('Game of Thrones'), findsWidgets);

    // Search never plays directly: a tap opens the shared detail page, the
    // single play origin (so the host gets episode context and auto-advances).
    await tester.tap(find.text('Game of Thrones'));
    await tester.pumpAndSettle();

    expect(home.opened.single.id, 'tt0944947');
    expect(find.text('DETAIL'), findsOneWidget);
  });

  testWidgets('idle is a sober invite under the one real-glass field',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          searchControllerProvider
              .overrideWith(() => _StubSearchController(SearchState())),
        ],
        child: const MaterialApp(home: Scaffold(body: SearchScreen())),
      ),
    );

    expect(
      find.text('Search across movies, series, and anime at once.\n'
          'Results appear as each source responds.'),
      findsOneWidget,
    );
    expect(find.byType(TextField), findsOneWidget);
    expect(find.byType(GridView), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    // The field is the only real blur on the screen (ADR-0010 chrome budget).
    expect(find.byType(BackdropFilter), findsOneWidget);
  });

  testWidgets('loading shows the final-shape skeleton, never a lonely spinner',
      (tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final fetcher = _PendingSearchFetcher();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          searchFetcherProvider.overrideWithValue(fetcher),
          jikanQueueProvider.overrideWithValue(
            JikanQueue(fetch: fetcher.searchJikan, spacing: Duration.zero),
          ),
        ],
        child: const MaterialApp(home: Scaffold(body: SearchScreen())),
      ),
    );

    await tester.enterText(find.byType(TextField), 'matrix');
    await tester.pump(const Duration(milliseconds: 180)); // debounce fires

    expect(find.byKey(const ValueKey('searchSkeleton')), findsOneWidget);
    expect(find.byKey(const ValueKey('topMatchSkeleton')), findsOneWidget);
    expect(find.byKey(const ValueKey('resultsSkeleton')), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    // The no-results claim waits for every source to settle.
    expect(find.text('No results for "matrix".'), findsNothing);

    fetcher.cinemeta.complete(const []);
    fetcher.jikan.complete(const []);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('searchSkeleton')), findsNothing);
    expect(find.text('No results for "matrix".'), findsOneWidget);
  });

  testWidgets(
      'top match is an unblurred glass card over 3-column grids, and opens Detail',
      (tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    const top = Meta(
      id: 'tmdb:movie:1',
      type: 'movie',
      name: 'The Matrix',
      releaseInfo: '1999',
    );
    final state = SearchState(
      query: 'matrix',
      status: SearchStatus.done,
      results: const SearchResults(
        query: 'matrix',
        topMatch: TopMatch(
          kind: 'movie',
          meta: top,
          overview: 'A hacker learns the truth about his reality.',
          voteAverage: 8.2,
        ),
        // The real TMDB payload keeps the top match in its type list; the
        // screen must not render it twice.
        movies: [top, Meta(id: 'tmdb:movie:2', type: 'movie', name: 'Reloaded')],
        series: [Meta(id: 'tmdb:tv:3', type: 'series', name: 'Matrix Animated')],
        anime: [AnimeHit(malId: 1, format: 'TV', name: 'Attack on Titan')],
      ),
    );
    final home = _StubHomeController();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          searchControllerProvider
              .overrideWith(() => _StubSearchController(state)),
          homeControllerProvider.overrideWith(() => home),
        ],
        child: MaterialApp(
          routes: {AppRoutes.detail: (_) => const Scaffold(body: Text('DETAIL'))},
          home: const Scaffold(body: SearchScreen()),
        ),
      ),
    );

    expect(find.text('TOP MATCH'), findsOneWidget);
    expect(find.text('The Matrix'), findsOneWidget,
        reason: 'the top match is pinned in its card, not repeated in the grid');
    expect(find.text('1999 · Film · ★ 8.2'), findsOneWidget);
    expect(find.text('Reloaded'), findsOneWidget);
    expect(find.text('Matrix Animated'), findsOneWidget);
    expect(find.text('Attack on Titan'), findsOneWidget);

    // Three columns in every results grid — films/series and anime (ticket 88).
    final grids = tester.widgetList<GridView>(find.byType(GridView));
    expect(grids, hasLength(2));
    for (final grid in grids) {
      expect(
        (grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount)
            .crossAxisCount,
        3,
      );
    }

    // ADR-0010: the card is fill + hairline; nothing inside the scrolling
    // results blurs (only the field above does).
    final card = tester.widget<GlassSurface>(find.ancestor(
      of: find.text('TOP MATCH'),
      matching: find.byType(GlassSurface),
    ));
    expect(card.blurred, isFalse);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('searchResults')),
        matching: find.byType(BackdropFilter),
      ),
      findsNothing,
    );

    await tester.tap(find.text('The Matrix'));
    await tester.pumpAndSettle();

    expect(home.opened.single.id, 'tmdb:movie:1');
    expect(find.text('DETAIL'), findsOneWidget);
  });
}
