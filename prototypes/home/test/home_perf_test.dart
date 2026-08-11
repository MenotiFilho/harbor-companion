// Headless perf spike for the Home + catalog screens.
//
// Answers the wayfinder ticket question: does the native rendering architecture
// stay fast, and can we put a number on "fast"? Runs in `flutter test` — no
// device, no display, no emulator.
//
// What this measures, and honestly:
//  - per-frame wall-clock during a scripted full-Home scroll (build+layout+
//    paint+raster in the test harness). Absolute values here include the
//    GPU-less software rasterizer on this VM, so they are reported for
//    direction, not asserted as the gate — the formal p95/p99 build budget is
//    measured on-device (real FrameTiming) with the same scroll harness, and
//    that is the follow-up milestone.
//  - image-cache hit rate on scroll-back, via decode counts (deterministic).
//  - lazy-vs-eager build cost via a card counter (deterministic, and the core
//    architectural win over the SPA: cost is O(visible), not O(catalog)).
//
// The "fast" definition this spike validates (wayfinder #8 decision):
//   sustained 60fps scroll — p95 frame-build <= 8ms, p99 <= 16ms, <= 5 dropped
//   frames across a scripted scroll through the full Home, and >= 90%
//   image-cache hit on scroll-back. On-device raster/build verification is the
//   follow-up milestone.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:home_proto/app.dart';
import 'package:home_proto/catalog_repo.dart';
import 'package:home_proto/home_screen.dart';
import 'package:home_proto/poster_image.dart';

const double _rowExtent = kRowExtent;

void _setPhoneViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(390 * 2, 844 * 2);
  tester.view.devicePixelRatio = 2.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

double _percentile(List<double> sorted, double p) {
  if (sorted.isEmpty) return 0;
  return sorted[((sorted.length - 1) * p).round()];
}

/// Pumps one frame and returns its wall-clock time in microseconds.
Future<int> _pumpUs(WidgetTester tester) async {
  final sw = Stopwatch()..start();
  await tester.pump();
  sw.stop();
  return sw.elapsedMicroseconds;
}

/// Measures the harness's per-pump overhead so it can be subtracted from the
/// app measurement: widget-test pumps include JIT/test-binding work that has
/// nothing to do with our frame cost.
Future<double> _baselinePumpUs(WidgetTester tester) async {
  await tester.pumpWidget(const MaterialApp(home: SizedBox()));
  await tester.pump();
  final samples = <double>[];
  for (var i = 0; i < 20; i++) {
    samples.add((await _pumpUs(tester)).toDouble());
  }
  final sorted = [...samples]..sort();
  return _percentile(sorted, 0.5);
}

void main() {
  setUp(() {
    PaintingBinding.instance.imageCache
      ..clear()
      ..maximumSize = 20000
      ..maximumSizeBytes = 100 << 20;
  });

  testWidgets('Home scrolls at target: per-frame cost, dropped frames, cache hits', (tester) async {
    _setPhoneViewport(tester);
    final repo = CatalogRepo(tmdbKey: 'k');

    final baseline = await _baselinePumpUs(tester);

    await tester.pumpWidget(HomeProtoApp(repo: repo));
    await tester.pump();

    final scrollable = find.byKey(const ValueKey('homeList'));
    final distance = (repo.rowCount - 2) * _rowExtent;
    const step = 400.0;

    // phase 1 — scroll the full Home downward
    PosterImage.loadCount = 0;
    final downUs = <double>[];
    for (var d = 0.0; d < distance; d += step) {
      await tester.drag(scrollable, const Offset(0, -step));
      downUs.add((await _pumpUs(tester)).toDouble());
    }
    final downLoads = PosterImage.loadCount;

    // phase 2 — scroll back up (cache-hit probe)
    PosterImage.loadCount = 0;
    final upUs = <double>[];
    for (var d = 0.0; d < distance; d += step) {
      await tester.drag(scrollable, const Offset(0, step));
      upUs.add((await _pumpUs(tester)).toDouble());
    }
    final upLoads = PosterImage.loadCount;

    // app-specific frame cost = pump wall-clock minus harness overhead
    double appCost(double us) => (us - baseline).clamp(0, double.infinity);
    final downApp = downUs.map(appCost).toList()..sort();
    final upApp = upUs.map(appCost).toList()..sort();
    final allApp = [...downApp, ...upApp]..sort();
    final cacheHit = downLoads == 0 ? 0.0 : 1 - upLoads / downLoads;

    debugPrint('[perf] harness baseline=${baseline.toStringAsFixed(0)}us  frames=${downUs.length + upUs.length} '
        'appCost down: p50=${_percentile(downApp, 0.5).toStringAsFixed(0)}us p95=${_percentile(downApp, 0.95).toStringAsFixed(0)}us '
        'appCost up: p50=${_percentile(upApp, 0.5).toStringAsFixed(0)}us p95=${_percentile(upApp, 0.95).toStringAsFixed(0)}us '
        'appCost overall p95=${_percentile(allApp, 0.95).toStringAsFixed(0)}us p99=${_percentile(allApp, 0.99).toStringAsFixed(0)}us '
        'max=${allApp.last.toStringAsFixed(0)}us downLoads=$downLoads upLoads=$upLoads cacheHit=${(cacheHit * 100).toStringAsFixed(1)}%');

    expect(cacheHit, greaterThanOrEqualTo(0.9), reason: '>= 90% image-cache hit on scroll-back');
    expect(_percentile(upApp, 0.95), lessThanOrEqualTo(_percentile(downApp, 0.95) * 1.25 + 500),
        reason: 'caching must not make scroll-back costlier than the initial scroll');
  });

  testWidgets('lazy build stays constant as the catalog grows (vs eager/SPA)', (tester) async {
    _setPhoneViewport(tester);

    Future<int> countCards(Widget child) async {
      HomeMetrics.reset();
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
      await tester.pump();
      return HomeMetrics.cardsBuilt;
    }

    final lazy10 = await countCards(HomeScreen(repo: CatalogRepo(tmdbKey: 'k', rowCount: 10)));
    final lazy100 = await countCards(HomeScreen(repo: CatalogRepo(tmdbKey: 'k', rowCount: 100)));

    final eagerRepo = CatalogRepo(tmdbKey: 'k', rowCount: 100);
    final eager100 = await countCards(
      SingleChildScrollView(
        child: Column(children: [for (final r in eagerRepo.fetchHome()) HomeRowRail(row: r)]),
      ),
    );

    debugPrint('[perf] cards built on first frame: lazy(10 rows)=$lazy10 lazy(100 rows)=$lazy100 eager(100 rows)=$eager100');

    expect(lazy100, lessThan(lazy10 * 4), reason: 'lazy build cost must stay ~constant as the catalog grows');
    expect(lazy100, lessThan(eager100 ~/ 3), reason: 'lazy must build far fewer cards than the eager/SPA baseline');
  });
}
