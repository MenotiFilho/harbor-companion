// Widget tests for the dedicated rail grid (tickets 76, 77, ADR-0009). The
// presentation tests ride a stub controller over a fixed snapshot; the
// pagination tests mount the real HomeController with a fake CatalogFetcher so
// the on-scroll trigger, the per-source cursor request and the "End"/error
// footers are exercised end to end.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:harbor_companion/app/home/catalog_fetcher.dart';
import 'package:harbor_companion/app/home/catalog_request.dart';
import 'package:harbor_companion/app/home/home_cache_store.dart';
import 'package:harbor_companion/app/home/home_controller.dart';
import 'package:harbor_companion/app/home/home_rail.dart';
import 'package:harbor_companion/app/home/home_reducer.dart';
import 'package:harbor_companion/app/home/home_screen.dart';
import 'package:harbor_companion/app/home/meta.dart';
import 'package:harbor_companion/app/home/rail_grid_screen.dart';
import 'package:harbor_companion/app/routes.dart';
import 'package:harbor_companion/app/settings/settings_controller.dart';
import 'package:harbor_companion/app/settings/settings_store.dart';
import 'package:harbor_companion/app/ws/client_controller.dart';
import 'package:harbor_companion/app/ws/ws_transport.dart';

class _StubHomeController extends HomeController {
  @override
  final HomeState state;
  final List<Meta> openedDetails = [];
  _StubHomeController(this.state);

  @override
  HomeState build() => state;

  @override
  void openDetail(Meta meta) => openedDetails.add(meta);

  // The presentation tests never paginate; keep the fixed state fixed.
  @override
  void loadMoreRailGrid() {}

  @override
  void retryRailGridPage() {}
}

/// A catalog fetcher for the grid tests: every planned rail loads [railItemCount]
/// items with [railHasMore]; grid pages are recorded and answered from [pageFor]
/// or held open by [pageGate] so a test can observe the loading footer.
class _FakeGridFetcher implements CatalogFetcher {
  _FakeGridFetcher({this.railItemCount = 50, this.railHasMore = true});

  final int railItemCount;
  final bool railHasMore;
  final List<(String, int)> pageRequests = [];
  RailPage Function(String rowKey, int cursor)? pageFor;
  Completer<RailPage>? pageGate;

  List<Meta> _metas(String key) => [
        for (var i = 0; i < railItemCount; i++)
          Meta(id: '$key:$i', type: 'movie', name: '$key $i'),
      ];

  @override
  Stream<HomeRailOutcome> fetchRails(CatalogRequest request) => Stream.fromIterable([
        for (final key in planHomeRowKeys(request))
          HomeRailLoaded(key, 'Row $key', _metas(key), hasMore: railHasMore),
      ]);

  @override
  Future<HomeRailOutcome> fetchRail(CatalogRequest request, String rowKey) async =>
      HomeRailLoaded(rowKey, 'Row $rowKey', _metas(rowKey), hasMore: railHasMore);

  @override
  Future<RailPage> fetchRailPage(
    CatalogRequest request,
    String rowKey,
    int cursor,
  ) {
    pageRequests.add((rowKey, cursor));
    final gate = pageGate;
    if (gate != null) return gate.future;
    return Future<RailPage>.value(
      pageFor?.call(rowKey, cursor) ?? const RailPage(items: []),
    );
  }

  @override
  Future<DetailMeta> fetchDetail(String type, String id, String? tmdbKey) async =>
      DetailMeta(meta: Meta(id: id, type: type, name: 'Detail'));
}

Meta movie(int i) => Meta(id: 'tt$i', type: 'movie', name: 'Movie $i');

List<Meta> many(int n, {int start = 0}) =>
    [for (var i = start; i < start + n; i++) movie(i)];

/// A Home state with the one active grid snapshot [items].
HomeState gridState(
  List<Meta> items, {
  bool hasMore = true,
  bool loading = false,
  bool ended = false,
  String? error,
  RailGridSource source = RailGridSource.cinemeta,
  int? cursor,
}) =>
    HomeState(
      railGrids: {
        'cinemeta:top-movies': RailGridSnapshot(
          rowKey: 'cinemeta:top-movies',
          title: 'Top Movies',
          items: items,
          source: source,
          request: const CatalogRequest(),
          cursor: cursor ?? items.length,
          hasMore: hasMore,
          loading: loading,
          error: error,
          ended: ended,
        ),
      },
      activeRailGridKey: 'cinemeta:top-movies',
    );

Widget _app(HomeState state, {HomeController? controller}) {
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

/// Mounts the real HomeController (fake fetcher + in-memory seams) with
/// `cinemeta:top-movies`'s grid already open, and returns its container.
Future<ProviderContainer> _mountOpenGrid(
  WidgetTester tester,
  _FakeGridFetcher fetcher,
) async {
  final container = ProviderContainer(
    overrides: [
      catalogFetcherProvider.overrideWithValue(fetcher),
      settingsStoreProvider.overrideWithValue(InMemorySettingsStore()),
      homeCacheStoreProvider.overrideWithValue(InMemoryHomeCacheStore()),
      wsTransportProvider.overrideWithValue(_FakeTransport()),
      wsKeyStoreProvider.overrideWithValue(InMemoryHostKeyStore()),
    ],
  );
  addTearDown(container.dispose);

  // Mount first: in a widget test the event loop only advances through pump.
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      routes: {
        AppRoutes.detail: (_) => const Scaffold(body: Text('DETAIL')),
      },
      home: const RailGridScreen(),
    ),
  ));
  final notifier = container.read(homeControllerProvider.notifier);
  notifier.load();
  for (var i = 0; i < 6; i++) {
    await tester.pump();
  }
  notifier.openRailGrid('cinemeta:top-movies');
  await tester.pump();
  return container;
}

class _FakeConnection implements WsConnection {
  final _frames = StreamController<String>.broadcast();
  @override
  Stream<String> get frames => _frames.stream;
  @override
  void send(String message) {}
  @override
  Future<void> close() async => _frames.close();
}

class _FakeTransport implements WsTransport {
  @override
  Future<WsConnection> open(String url) async => _FakeConnection();
}

void main() {
  testWidgets('renders every captured item in a responsive grid',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(_app(gridState(many(50))));

    expect(find.byType(CustomScrollView), findsOneWidget);
    final grid = tester.widget<SliverGrid>(find.byType(SliverGrid));
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

  group('pagination (ticket 77)', () {
    testWidgets('scrolling near the end requests the next page, then appends it',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final fetcher = _FakeGridFetcher(railItemCount: 50)..pageGate = Completer();
      final container = await _mountOpenGrid(tester, fetcher);

      expect(container.read(homeControllerProvider).activeRailGrid!.cursor, 50);

      await tester.drag(find.byType(CustomScrollView), const Offset(0, -4000));
      await tester.pump();

      expect(fetcher.pageRequests, [('cinemeta:top-movies', 50)],
          reason: 'the cursor is the loaded count, never skip=0');
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      fetcher.pageGate!.complete(
        RailPage(items: many(10, start: 50), hasMore: true),
      );
      await tester.pump();
      await tester.pump();

      final grid = container.read(homeControllerProvider).activeRailGrid!;
      expect(grid.items, hasLength(60));
      expect(grid.loading, isFalse);
      expect(grid.cursor, 60);
    });

    testWidgets('an ended grid shows the End footer', (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final fetcher = _FakeGridFetcher(railItemCount: 20, railHasMore: false);
      final container = await _mountOpenGrid(tester, fetcher);

      final grid = container.read(homeControllerProvider).activeRailGrid!;
      expect(grid.items, hasLength(20));
      expect(grid.ended, isTrue);
      expect(find.text('End'), findsOneWidget);
    });

    testWidgets('a failed page keeps the items and offers Try again',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final fetcher = _FakeGridFetcher(railItemCount: 50)
        ..pageFor = ((key, cursor) => throw Exception('boom'));
      final container = await _mountOpenGrid(tester, fetcher);

      await tester.drag(find.byType(CustomScrollView), const Offset(0, -4000));
      await tester.pump();
      await tester.pump();

      expect(find.byType(PosterCard), findsWidgets,
          reason: 'the loaded items stay through the failure');
      expect(find.textContaining("Couldn't load more"), findsOneWidget);

      fetcher.pageFor = (key, cursor) =>
          RailPage(items: many(10, start: 50), hasMore: true);
      final retry = find.widgetWithText(FilledButton, 'Try again');
      await tester.ensureVisible(retry);
      await tester.pumpAndSettle();
      await tester.tap(retry);
      await tester.pump();
      await tester.pump();

      final grid = container.read(homeControllerProvider).activeRailGrid!;
      expect(grid.error, isNull);
      expect(grid.items, hasLength(60));
      expect(fetcher.pageRequests, [
        ('cinemeta:top-movies', 50),
        ('cinemeta:top-movies', 50),
      ]);
    });

    testWidgets('a /trending-style ended grid never requests a page',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final fetcher = _FakeGridFetcher(railItemCount: 20, railHasMore: false);
      await _mountOpenGrid(tester, fetcher);

      await tester.drag(find.byType(CustomScrollView), const Offset(0, -4000));
      await tester.pump();

      expect(fetcher.pageRequests, isEmpty);
      expect(find.text('End'), findsOneWidget);
    });
  });
}
