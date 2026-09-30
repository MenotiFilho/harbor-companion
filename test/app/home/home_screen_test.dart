// Widget tests for the Home screen's Hero + per-rail render (tickets 71, 83).
// Thin coverage over a stub controller: the reducer is the real seam. Verifies
// the hero source (first rail in order, no resume semantics), the artwork
// fallbacks, skeleton for a pending rail, the user's order preserved, a
// loaded-empty rail removed, a local retry card that leaves the other rails on
// screen, the derived empty / everything-failed screens, and that no
// Watch-progress bar exists anywhere (the data does not).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:harbor_companion/app/home/catalog_request.dart';
import 'package:harbor_companion/app/home/home_controller.dart';
import 'package:harbor_companion/app/home/home_rail.dart';
import 'package:harbor_companion/app/home/home_reducer.dart';
import 'package:harbor_companion/app/home/home_rows.dart';
import 'package:harbor_companion/app/home/home_screen.dart';
import 'package:harbor_companion/app/home/meta.dart';
import 'package:harbor_companion/app/routes.dart';
import 'package:harbor_companion/app/ui/hero_band.dart';
import 'package:harbor_companion/app/ui/progress_bar.dart';

class _StubHomeController extends HomeController {
  @override
  final HomeState state;
  int reloads = 0;
  int refreshes = 0;

  /// When set, [refresh] waits on it so a test can hold the round in flight.
  Completer<void>? refreshGate;
  final List<String> retried = [];

  /// Rail keys whose title / "See more" card was tapped (ticket 75 seam).
  final List<String> openedRails = [];

  /// Titles opened through the detail seam (hero / poster cards).
  final List<Meta> openedDetails = [];
  _StubHomeController(this.state);

  @override
  HomeState build() => state;

  @override
  void load() {}

  @override
  void reload() => reloads++;

  @override
  Future<void> refresh() {
    refreshes++;
    return refreshGate?.future ?? Future<void>.value();
  }

  @override
  void retryRail(String rowKey) => retried.add(rowKey);

  @override
  void openRailGrid(String rowKey) => openedRails.add(rowKey);

  @override
  void openDetail(Meta meta) => openedDetails.add(meta);
}

const twoRows = CatalogRequest(
  rowOrder: ['cinemeta:top-movies', 'cinemeta:top-series'],
);
const seriesFirst = CatalogRequest(
  rowOrder: ['cinemeta:top-series', 'cinemeta:top-movies'],
);

Meta movie({
  String id = 'tt1',
  String name = 'The Matrix',
  String? poster,
  String? background,
  String? releaseInfo,
}) =>
    Meta(
      id: id,
      type: 'movie',
      name: name,
      poster: poster,
      background: background,
      releaseInfo: releaseInfo,
    );

RailState loaded(String rowKey, String title, List<Meta> items) =>
    RailState(rowKey: rowKey, title: title, items: items, status: RailStatus.loaded);

RailState failed(String rowKey, {String title = ''}) => RailState(
    rowKey: rowKey,
    title: title,
    status: RailStatus.failed,
    error: 'boom',
  );

/// The rail header title, scoped to the loaded rail so the hero's kicker (the
/// same words, at the top of the screen) never matches. [skipOffstage] is for
/// rails inside the viewport's cache area, which the bigger hero + cards pushed
/// below the test surface's fold.
Finder railTitle(String title, {bool skipOffstage = true}) => find.descendant(
      of: find.byType(HomeRowRail, skipOffstage: skipOffstage),
      matching: find.text(title.toUpperCase(), skipOffstage: skipOffstage),
      skipOffstage: skipOffstage,
    );

Widget _app(HomeState state, {_StubHomeController? controller}) {
  controller ??= _StubHomeController(state);
  return ProviderScope(
    overrides: [homeControllerProvider.overrideWith(() => controller!)],
    child: MaterialApp(
      routes: {
        AppRoutes.railGrid: (_) => const Scaffold(body: Text('RAIL GRID')),
        AppRoutes.detail: (_) => const Scaffold(body: Text('DETAIL')),
      },
      home: const Scaffold(body: HomeScreen()),
    ),
  );
}

void main() {
  group('hero (issue #83)', () {
    testWidgets('takes the first item of the first rail with content, in order',
        (tester) async {
      final state = HomeState(
        request: seriesFirst,
        rails: {
          'cinemeta:top-movies': loaded('cinemeta:top-movies', 'Top Movies', [movie()]),
          'cinemeta:top-series': loaded('cinemeta:top-series', 'Top Series',
              [movie(id: 'tt2', name: 'Breaking Bad')]),
        },
      );
      await tester.pumpWidget(_app(state));

      final hero = tester.widget<HeroBand>(find.byType(HeroBand));
      expect(hero.title, 'Breaking Bad',
          reason: 'the first planned rail wins, not arrival or progress');
      expect(hero.kicker, 'Top Series');
      expect(hero.height, kHomeHeroHeight);
    });

    testWidgets('is absent while no rail has content', (tester) async {
      await tester.pumpWidget(_app(HomeState(request: twoRows)));

      expect(find.byType(HeroBand), findsNothing);
      expect(find.byType(HomeRailSkeleton), findsNWidgets(2));
    });

    testWidgets('carries the item backdrop, poster and release info',
        (tester) async {
      final item = movie(
        poster: 'https://img/poster.jpg',
        background: 'https://img/backdrop.jpg',
        releaseInfo: '1999',
      );
      await tester.pumpWidget(_app(HomeState(
        request: twoRows,
        rails: {
          'cinemeta:top-movies':
              loaded('cinemeta:top-movies', 'Top Movies', [item]),
        },
      )));

      final hero = tester.widget<HeroBand>(find.byKey(const ValueKey('homeHero')));
      expect(hero.backdropUrl, 'https://img/backdrop.jpg');
      expect(hero.posterUrl, 'https://img/poster.jpg');
      expect(hero.meta, '1999');
    });

    testWidgets('tapping the hero opens the Detail route', (tester) async {
      final controller = _StubHomeController(HomeState(
        request: twoRows,
        rails: {
          'cinemeta:top-movies':
              loaded('cinemeta:top-movies', 'Top Movies', [movie()]),
        },
      ));
      await tester.pumpWidget(_app(controller.state, controller: controller));

      await tester.tap(find.byType(HeroBand));
      await tester.pumpAndSettle();

      expect(controller.openedDetails, hasLength(1));
      expect(controller.openedDetails.single.id, 'tt1');
      expect(find.text('DETAIL'), findsOneWidget);
    });

    testWidgets('a failed rail with no copy never becomes the hero',
        (tester) async {
      final state = HomeState(
        request: twoRows,
        rails: {
          'cinemeta:top-movies': failed('cinemeta:top-movies', title: 'Top Movies'),
          'cinemeta:top-series': loaded('cinemeta:top-series', 'Top Series',
              [movie(id: 'tt2', name: 'Breaking Bad')]),
        },
      );
      await tester.pumpWidget(_app(state));

      final hero = tester.widget<HeroBand>(find.byType(HeroBand));
      expect(hero.title, 'Breaking Bad');
      expect(hero.kicker, 'Top Series');
    });
  });

  testWidgets('a pending rail renders its title + a skeleton, no global spinner',
      (tester) async {
    await tester.pumpWidget(_app(HomeState(request: twoRows)));

    expect(find.byType(HomeRailSkeleton), findsNWidgets(2));
    expect(find.text('TOP MOVIES'), findsOneWidget);
    expect(find.text('TOP SERIES'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('rails render in the user order despite arrival order',
      (tester) async {
    final state = HomeState(
      request: seriesFirst,
      rails: {
        'cinemeta:top-movies': loaded('cinemeta:top-movies', 'Top Movies', [movie()]),
        'cinemeta:top-series':
            loaded('cinemeta:top-series', 'Top Series', [movie(id: 'tt2', name: 'Breaking Bad')]),
      },
    );
    await tester.pumpWidget(_app(state));

    final moviesY = tester.getTopLeft(railTitle('Top Movies', skipOffstage: false)).dy;
    final seriesY = tester.getTopLeft(railTitle('Top Series', skipOffstage: false)).dy;
    expect(seriesY, lessThan(moviesY));
    expect(find.byType(HomeRailSkeleton), findsNothing);
  });

  testWidgets('a loaded-empty rail is removed, not left as a gap', (tester) async {
    final state = HomeState(
      request: twoRows,
      rails: {
        'cinemeta:top-movies': loaded('cinemeta:top-movies', 'Top Movies', [movie()]),
        'cinemeta:top-series':
            loaded('cinemeta:top-series', 'Top Series', const []),
      },
    );
    await tester.pumpWidget(_app(state));

    expect(railTitle('Top Movies'), findsOneWidget);
    expect(find.text('The Matrix'), findsWidgets,
        reason: 'the hero and the poster card both show the title');
    expect(railTitle('Top Series'), findsNothing);
  });

  testWidgets('a failed rail without a copy shows a local retry card; others stay',
      (tester) async {
    // Taller than the fold: the hero + the first rail push the failed rail into
    // the cache area, and the retry card must still be reachable by scrolling.
    await tester.binding.setSurfaceSize(const Size(800, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = _StubHomeController(
      HomeState(
        request: twoRows,
        rails: {
          'cinemeta:top-movies': loaded('cinemeta:top-movies', 'Top Movies', [movie()]),
          'cinemeta:top-series': failed('cinemeta:top-series'),
        },
      ),
    );
    await tester.pumpWidget(_app(controller.state, controller: controller));

    expect(railTitle('Top Movies'), findsOneWidget);
    expect(find.text('The Matrix'), findsWidgets);
    expect(find.text('TOP SERIES'), findsOneWidget);
    expect(find.textContaining("Couldn't load"), findsOneWidget);

    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(controller.retried, ['cinemeta:top-series']);
  });

  testWidgets('a failed rail with a previous copy keeps its content', (tester) async {
    final state = HomeState(
      request: twoRows,
      rails: {
        'cinemeta:top-movies': loaded('cinemeta:top-movies', 'Top Movies', [movie()]),
        'cinemeta:top-series': failed(
          'cinemeta:top-series',
          title: 'Top Series',
        ).copyWith(items: [movie(id: 'tt2', name: 'Breaking Bad')]),
      },
    );
    await tester.pumpWidget(_app(state));

    expect(find.text('Breaking Bad', skipOffstage: false), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
  });

  testWidgets('a settled plan with no content shows the derived empty Home',
      (tester) async {
    final state = HomeState(
      request: twoRows,
      rails: {
        'cinemeta:top-movies':
            const RailState(rowKey: 'cinemeta:top-movies', status: RailStatus.absent),
        'cinemeta:top-series':
            loaded('cinemeta:top-series', 'Top Series', const []),
      },
    );
    await tester.pumpWidget(_app(state));

    expect(find.text('No catalogs to show'), findsOneWidget);
    expect(find.byType(HomeRailSkeleton), findsNothing);
    expect(find.byType(HeroBand), findsNothing);
  });

  testWidgets(
      'an all-empty cache round in flight shows skeletons, not the empty screen',
      (tester) async {
    final state = HomeState(
      request: twoRows,
      roundPending: const {'cinemeta:top-movies', 'cinemeta:top-series'},
      rails: {
        'cinemeta:top-movies': const RailState(
          rowKey: 'cinemeta:top-movies',
          title: 'Top Movies',
          status: RailStatus.loaded,
          fromCache: true,
          updatedAt: 1,
        ),
        'cinemeta:top-series': const RailState(
          rowKey: 'cinemeta:top-series',
          title: 'Top Series',
          status: RailStatus.loaded,
          fromCache: true,
          updatedAt: 1,
        ),
      },
    );
    await tester.pumpWidget(_app(state));

    expect(find.byType(HomeRailSkeleton), findsNWidgets(2));
    expect(find.text('No catalogs to show'), findsNothing);
  });

  testWidgets('all rails failed shows the derived global error screen',
      (tester) async {
    final state = HomeState(
      request: twoRows,
      rails: {
        'cinemeta:top-movies': failed('cinemeta:top-movies'),
        'cinemeta:top-series': failed('cinemeta:top-series'),
      },
    );
    await tester.pumpWidget(_app(state));

    expect(find.textContaining('boom'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('the empty screen Refresh starts a new round', (tester) async {
    final controller = _StubHomeController(
      HomeState(request: const CatalogRequest(rowOrder: [])),
    );
    await tester.pumpWidget(_app(controller.state, controller: controller));

    expect(find.text('No catalogs to show'), findsOneWidget);
    await tester.tap(find.text('Refresh'));
    await tester.pump();
    expect(controller.reloads, 1);
  });

  testWidgets('a cached rail shows the age badge', (tester) async {
    final twoDaysAgo =
        DateTime.now().subtract(const Duration(days: 2)).millisecondsSinceEpoch;
    final cached = HomeState(
      request: twoRows,
      rails: {
        'cinemeta:top-movies': RailState(
          rowKey: 'cinemeta:top-movies',
          title: 'Top Movies',
          items: [movie()],
          status: RailStatus.loaded,
          fromCache: true,
          updatedAt: twoDaysAgo,
        ),
        'cinemeta:top-series':
            loaded('cinemeta:top-series', 'Top Series', [movie(id: 'tt2')]),
      },
    );
    await tester.pumpWidget(_app(cached));

    expect(find.byType(HomeRailAgeBadge), findsOneWidget);
    expect(find.text('2d'), findsOneWidget);
  });

  testWidgets('a fresh rail shows no age badge', (tester) async {
    final fresh = HomeState(
      request: twoRows,
      rails: {
        'cinemeta:top-movies': loaded('cinemeta:top-movies', 'Top Movies', [movie()]),
        'cinemeta:top-series':
            loaded('cinemeta:top-series', 'Top Series', [movie(id: 'tt2')]),
      },
    );
    await tester.pumpWidget(_app(fresh));

    expect(find.byType(HomeRailAgeBadge), findsNothing);
  });

  testWidgets('no Watch-progress bar renders anywhere (the data does not exist)',
      (tester) async {
    final state = HomeState(
      request: twoRows,
      rails: {
        'cinemeta:top-movies': loaded('cinemeta:top-movies', 'Top Movies', [movie()]),
        'cinemeta:top-series':
            loaded('cinemeta:top-series', 'Top Series', [movie(id: 'tt2')]),
      },
    );
    await tester.pumpWidget(_app(state));

    expect(find.byType(ProgressBar), findsNothing);
  });

  group('pull-to-refresh (ticket 74)', () {
    Widget app(_StubHomeController controller) =>
        _app(controller.state, controller: controller);

    testWidgets('pulling the rail list starts a manual refresh', (tester) async {
      final controller = _StubHomeController(HomeState(
        request: twoRows,
        rails: {
          'cinemeta:top-movies':
              loaded('cinemeta:top-movies', 'Top Movies', [movie()]),
          'cinemeta:top-series':
              loaded('cinemeta:top-series', 'Top Series', [movie(id: 'tt2')]),
        },
      ));
      await tester.pumpWidget(app(controller));

      await tester.fling(
        find.byKey(const ValueKey('homeList')),
        const Offset(0, 300),
        1000,
      );
      await tester.pumpAndSettle();

      expect(controller.refreshes, 1);
      expect(controller.reloads, 0);
    });

    testWidgets(
        'the empty Home is scrollable, accepts the pull, and keeps its buttons',
        (tester) async {
      final controller = _StubHomeController(
        HomeState(request: const CatalogRequest(rowOrder: [])),
      );
      await tester.pumpWidget(app(controller));

      expect(find.text('No catalogs to show'), findsOneWidget);
      expect(find.text('Refresh'), findsOneWidget);
      expect(find.text('Open settings'), findsOneWidget);
      expect(find.byType(SingleChildScrollView), findsOneWidget);

      await tester.fling(
        find.byType(SingleChildScrollView),
        const Offset(0, 300),
        1000,
      );
      await tester.pumpAndSettle();

      expect(controller.refreshes, 1);
    });

    testWidgets(
        'the global error screen is scrollable, accepts the pull, keeps Retry',
        (tester) async {
      final controller = _StubHomeController(HomeState(
        request: twoRows,
        rails: {
          'cinemeta:top-movies': failed('cinemeta:top-movies'),
          'cinemeta:top-series': failed('cinemeta:top-series'),
        },
      ));
      await tester.pumpWidget(app(controller));

      expect(find.text('Retry'), findsOneWidget);
      await tester.fling(
        find.byType(SingleChildScrollView),
        const Offset(0, 300),
        1000,
      );
      await tester.pumpAndSettle();

      expect(controller.refreshes, 1);
    });

    testWidgets('a fully-failed manual round shows one short snackbar',
        (tester) async {
      final controller = _StubHomeController(HomeState(
        request: twoRows,
        rails: {
          'cinemeta:top-movies': failed('cinemeta:top-movies'),
          'cinemeta:top-series': failed('cinemeta:top-series'),
        },
        roundSummary:
            const RoundSummary(round: 1, manual: true, allFailed: true),
      ));
      await tester.pumpWidget(app(controller));

      await tester.fling(
        find.byType(SingleChildScrollView),
        const Offset(0, 300),
        1000,
      );
      await tester.pumpAndSettle();

      expect(find.textContaining("Couldn't refresh"), findsOneWidget);
    });

    testWidgets('a partial round shows no snackbar', (tester) async {
      final controller = _StubHomeController(HomeState(
        request: twoRows,
        rails: {
          'cinemeta:top-movies':
              loaded('cinemeta:top-movies', 'Top Movies', [movie()]),
          'cinemeta:top-series':
              loaded('cinemeta:top-series', 'Top Series', [movie(id: 'tt2')]),
        },
        roundSummary:
            const RoundSummary(round: 1, manual: true, allFailed: false),
      ));
      await tester.pumpWidget(app(controller));

      await tester.fling(
        find.byKey(const ValueKey('homeList')),
        const Offset(0, 300),
        1000,
      );
      await tester.pumpAndSettle();

      expect(find.byType(SnackBar), findsNothing);
    });
  });

  group('rail cap + see-more card (ticket 75)', () {
    List<Meta> many(int n) =>
        [for (var i = 0; i < n; i++) movie(id: 'tt$i', name: 'Movie $i')];

    HomeState oneRail(List<Meta> items, {bool hasMore = false}) => HomeState(
          request: const CatalogRequest(rowOrder: ['cinemeta:top-movies']),
          rails: {
            'cinemeta:top-movies': RailState(
              rowKey: 'cinemeta:top-movies',
              title: 'Top Movies',
              items: items,
              status: RailStatus.loaded,
              hasMore: hasMore,
            ),
          },
        );

    testWidgets('renders at most 20 items and shows the card when cut',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(2600, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(_app(oneRail(many(25))));

      expect(find.byType(PosterCard, skipOffstage: false), findsNWidgets(20));
      expect(find.text('See more', skipOffstage: false), findsOneWidget);
      expect(find.text('Movie 24'), findsNothing, reason: 'capped out of the rail');
      expect(find.text('Movie 19', skipOffstage: false), findsOneWidget);
    });

    testWidgets('a short rail with no source continuation hides the card',
        (tester) async {
      await tester.pumpWidget(_app(oneRail(many(5))));
      expect(find.byType(PosterCard), findsNWidgets(5));
      expect(find.text('See more'), findsNothing);
    });

    testWidgets('exactly 20 items with no continuation hides the card',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(2600, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(_app(oneRail(many(20))));
      expect(find.byType(PosterCard, skipOffstage: false), findsNWidgets(20));
      expect(find.text('See more', skipOffstage: false), findsNothing);
    });

    testWidgets('exactly 20 items with a source continuation shows the card',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(2600, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(_app(oneRail(many(20), hasMore: true)));
      expect(find.byType(PosterCard, skipOffstage: false), findsNWidgets(20));
      expect(find.text('See more', skipOffstage: false), findsOneWidget);
    });

    testWidgets('the rail title is always tappable, even without the card',
        (tester) async {
      final controller = _StubHomeController(oneRail(many(3)));
      await tester.pumpWidget(_app(controller.state, controller: controller));

      expect(find.text('See more'), findsNothing);
      await tester.tap(railTitle('Top Movies'));
      await tester.pumpAndSettle();

      expect(controller.openedRails, ['cinemeta:top-movies']);
      expect(find.text('RAIL GRID'), findsOneWidget,
          reason: 'the title pushes the dedicated grid route');
    });

    testWidgets('tapping the See more card opens the rail', (tester) async {
      final controller = _StubHomeController(oneRail(many(3), hasMore: true));
      await tester.pumpWidget(_app(controller.state, controller: controller));

      await tester.tap(find.text('See more'));
      await tester.pumpAndSettle();

      expect(controller.openedRails, ['cinemeta:top-movies']);
      expect(find.text('RAIL GRID'), findsOneWidget,
          reason: 'the See more card pushes the dedicated grid route');
    });
  });

  group('accessibility + perf guards (#91)', () {
    List<Meta> many(int n) =>
        [for (var i = 0; i < n; i++) movie(id: 'tt$i', name: 'Movie $i')];

    testWidgets('the rail title is a >= 48dp tap target', (tester) async {
      final state = HomeState(
        request: const CatalogRequest(rowOrder: ['cinemeta:top-movies']),
        rails: {
          'cinemeta:top-movies':
              loaded('cinemeta:top-movies', 'Top Movies', many(3)),
        },
      );
      await tester.pumpWidget(_app(state));

      final header = find.ancestor(
        of: railTitle('Top Movies'),
        matching: find.byType(InkWell),
      );
      expect(
        tester.getSize(header).height,
        greaterThanOrEqualTo(48),
        reason: 'the tappable rail header must carry the 48dp floor',
      );
    });

    testWidgets('no BackdropFilter anywhere in the Home scroll content',
        (tester) async {
      final state = HomeState(
        request: twoRows,
        rails: {
          'cinemeta:top-movies':
              loaded('cinemeta:top-movies', 'Top Movies', many(30)),
          'cinemeta:top-series': loaded(
              'cinemeta:top-series', 'Top Series', [movie(id: 'tt2')]),
        },
      );
      await tester.pumpWidget(_app(state));

      // ADR-0010: rails and cards are translucent fill + hairline only.
      expect(find.byType(BackdropFilter), findsNothing);
    });

    testWidgets('rails stay lazy: a large Home builds only its visible window',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final state = HomeState(
        request: const CatalogRequest(
          rowOrder: ['cinemeta:top-movies'],
        ),
        rails: {
          // A source page much larger than any screen: if the rail built its
          // whole catalog the perf spike (#8) would regress.
          'cinemeta:top-movies':
              loaded('cinemeta:top-movies', 'Top Movies', many(200)),
        },
      );
      await tester.pumpWidget(_app(state));

      final horizontal = tester
          .widgetList(find.byType(PosterCard, skipOffstage: false))
          .length;
      expect(horizontal, greaterThan(0));
      expect(
        horizontal,
        lessThan(50),
        reason: 'the rail ListView.builder must build O(visible), not O(catalog)',
      );
    });

    testWidgets('a long Home list builds only the visible rails', (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final state = HomeState(
        request: CatalogRequest(
          rowOrder: [for (final row in kCinemetaRows) row.id],
        ),
        rails: {
          for (final row in kCinemetaRows)
            row.id: loaded(row.id, row.title, [movie(id: row.id)]),
        },
      );
      await tester.pumpWidget(_app(state));

      final built = tester
          .widgetList(find.byType(HomeRowRail, skipOffstage: false))
          .length;
      expect(built, greaterThan(0));
      expect(
        built,
        lessThan(6),
        reason: 'SliverFixedExtentList must build only the viewport window',
      );
    });
  });

  test('homeRailAgeLabel is a coarse relative age', () {
    final now = DateTime(2026, 1, 1, 12);
    expect(homeRailAgeLabel(null, now: now), 'cached');
    expect(
      homeRailAgeLabel(now.subtract(const Duration(seconds: 10)).millisecondsSinceEpoch,
          now: now),
      'cached',
    );
    expect(
      homeRailAgeLabel(now.subtract(const Duration(minutes: 5)).millisecondsSinceEpoch,
          now: now),
      '5m',
    );
    expect(
      homeRailAgeLabel(now.subtract(const Duration(hours: 3)).millisecondsSinceEpoch,
          now: now),
      '3h',
    );
    expect(
      homeRailAgeLabel(now.subtract(const Duration(days: 4)).millisecondsSinceEpoch,
          now: now),
      '4d',
    );
  });

  test('homeHeroPick takes the first rail with items, in order', () {
    final first = movie(id: 'a', name: 'A');
    final second = movie(id: 'b', name: 'B');
    final state = HomeState(
      request: seriesFirst,
      rails: {
        'cinemeta:top-movies': loaded('cinemeta:top-movies', 'Top Movies', [
          first,
        ]),
        'cinemeta:top-series':
            loaded('cinemeta:top-series', 'Top Series', [second]),
      },
    );
    expect(homeHeroPick(state), (second, 'Top Series'));

    expect(homeHeroPick(HomeState(request: seriesFirst)), isNull);
  });
}
