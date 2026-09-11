// Widget tests for the Home screen's per-rail render (ticket 71). Thin coverage
// over a stub controller: the reducer is the real seam. Verifies skeleton for a
// pending rail, the user's order preserved, a loaded-empty rail removed, a local
// retry card that leaves the other rails on screen, and the derived empty /
// everything-failed screens.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:harbor_companion/app/home/catalog_request.dart';
import 'package:harbor_companion/app/home/home_controller.dart';
import 'package:harbor_companion/app/home/home_rail.dart';
import 'package:harbor_companion/app/home/home_reducer.dart';
import 'package:harbor_companion/app/home/home_screen.dart';
import 'package:harbor_companion/app/home/meta.dart';

class _StubHomeController extends HomeController {
  @override
  final HomeState state;
  int reloads = 0;
  int refreshes = 0;

  /// When set, [refresh] waits on it so a test can hold the round in flight.
  Completer<void>? refreshGate;
  final List<String> retried = [];
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
}

const twoRows = CatalogRequest(
  rowOrder: ['cinemeta:top-movies', 'cinemeta:top-series'],
);
const seriesFirst = CatalogRequest(
  rowOrder: ['cinemeta:top-series', 'cinemeta:top-movies'],
);

Meta movie({String id = 'tt1', String name = 'The Matrix'}) =>
    Meta(id: id, type: 'movie', name: name);

RailState loaded(String rowKey, String title, List<Meta> items) =>
    RailState(rowKey: rowKey, title: title, items: items, status: RailStatus.loaded);

RailState failed(String rowKey, {String title = ''}) => RailState(
    rowKey: rowKey,
    title: title,
    status: RailStatus.failed,
    error: 'boom',
  );

Widget _app(HomeState state, {_StubHomeController? controller}) {
  controller ??= _StubHomeController(state);
  return ProviderScope(
    overrides: [homeControllerProvider.overrideWith(() => controller!)],
    child: const MaterialApp(home: Scaffold(body: HomeScreen())),
  );
}

void main() {
  testWidgets('a pending rail renders its title + a skeleton, no global spinner',
      (tester) async {
    await tester.pumpWidget(_app(HomeState(request: twoRows)));

    expect(find.byType(HomeRailSkeleton), findsNWidgets(2));
    expect(find.text('Top Movies'), findsOneWidget);
    expect(find.text('Top Series'), findsOneWidget);
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

    final moviesY = tester.getTopLeft(find.text('Top Movies')).dy;
    final seriesY = tester.getTopLeft(find.text('Top Series')).dy;
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

    expect(find.text('Top Movies'), findsOneWidget);
    expect(find.text('The Matrix'), findsOneWidget);
    expect(find.text('Top Series'), findsNothing);
  });

  testWidgets('a failed rail without a copy shows a local retry card; others stay',
      (tester) async {
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

    expect(find.text('Top Movies'), findsOneWidget);
    expect(find.text('The Matrix'), findsOneWidget);
    expect(find.text('Top Series'), findsOneWidget);
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

    expect(find.text('Breaking Bad'), findsOneWidget);
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
}
