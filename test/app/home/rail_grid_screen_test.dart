// Widget tests for the dedicated rail grid (ticket 76, ADR-0009). The reducer
// is the real decision seam; these pin the presentation the snapshot feeds:
// every captured item in a responsive, width-driven grid that reuses the rail's
// poster card, with no age badge. On-scroll pagination is #77.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:harbor_companion/app/home/catalog_request.dart';
import 'package:harbor_companion/app/home/home_controller.dart';
import 'package:harbor_companion/app/home/home_reducer.dart';
import 'package:harbor_companion/app/home/home_screen.dart';
import 'package:harbor_companion/app/home/meta.dart';
import 'package:harbor_companion/app/home/rail_grid_screen.dart';
import 'package:harbor_companion/app/routes.dart';

class _StubHomeController extends HomeController {
  @override
  final HomeState state;
  final List<Meta> openedDetails = [];
  _StubHomeController(this.state);

  @override
  HomeState build() => state;

  @override
  void openDetail(Meta meta) => openedDetails.add(meta);
}

Meta movie(int i) => Meta(id: 'tt$i', type: 'movie', name: 'Movie $i');

List<Meta> many(int n) => [for (var i = 0; i < n; i++) movie(i)];

/// A Home state with the one active grid snapshot [items].
HomeState gridState(List<Meta> items) => HomeState(
      railGrids: {
        'cinemeta:top-movies': RailGridSnapshot(
          rowKey: 'cinemeta:top-movies',
          title: 'Top Movies',
          items: items,
          source: RailGridSource.cinemeta,
          request: const CatalogRequest(),
          cursor: items.length,
          hasMore: true,
        ),
      },
      activeRailGridKey: 'cinemeta:top-movies',
    );

Widget _app(HomeState state, {_StubHomeController? controller}) {
  controller ??= _StubHomeController(state);
  return ProviderScope(
    overrides: [homeControllerProvider.overrideWith(() => controller!)],
    child: MaterialApp(
      routes: {
        AppRoutes.detail: (_) => const Scaffold(body: Text('DETAIL')),
      },
      home: const RailGridScreen(),
    ),
  );
}

void main() {
  testWidgets('renders every captured item in a responsive grid',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(_app(gridState(many(50))));

    expect(find.byType(GridView), findsOneWidget);
    final grid = tester.widget<GridView>(find.byType(GridView));
    expect(grid.gridDelegate, isA<SliverGridDelegateWithMaxCrossAxisExtent>());

    // At this width the first two cards share a row (multiple columns).
    final first = tester.getTopLeft(find.byType(PosterCard).at(0));
    final second = tester.getTopLeft(find.byType(PosterCard).at(1));
    expect(second.dy, first.dy);
    expect(second.dx, greaterThan(first.dx));

    // The whole downloaded page is reachable, not just the rail's 20.
    await tester.scrollUntilVisible(find.text('Movie 49'), 300);
    expect(find.text('Movie 49'), findsOneWidget);
  });

  testWidgets('at a narrow width the grid falls back to one column',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(140, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(_app(gridState(many(4))));

    final first = tester.getTopLeft(find.byType(PosterCard).at(0));
    final second = tester.getTopLeft(find.byType(PosterCard).at(1));
    expect(second.dx, first.dx);
    expect(second.dy, greaterThan(first.dy));
  });

  testWidgets('a 20-only rail opens with exactly its 20 items', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(_app(gridState(many(20))));

    expect(find.byType(PosterCard), findsNWidgets(20));
  });

  testWidgets('shows no age badge', (tester) async {
    await tester.pumpWidget(_app(gridState(many(3))));

    expect(find.byType(PosterCard), findsNWidgets(3));
    expect(find.byType(HomeRailAgeBadge), findsNothing);
  });

  testWidgets('reuses the poster card and opens detail on tap', (tester) async {
    final controller = _StubHomeController(gridState(many(3)));
    await tester.pumpWidget(_app(controller.state, controller: controller));

    await tester.tap(find.byType(PosterCard).first);
    await tester.pumpAndSettle();

    expect(controller.openedDetails, hasLength(1));
    expect(find.text('DETAIL'), findsOneWidget);
  });

  testWidgets('with no snapshot it shows a placeholder', (tester) async {
    await tester.pumpWidget(_app(HomeState()));

    expect(find.text('No rail selected'), findsOneWidget);
    expect(find.byType(PosterCard), findsNothing);
  });
}
