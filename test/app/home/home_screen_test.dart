// Widget test for the Home screen (thin coverage: the reducer is the real
// seam). Verifies the Home tab loads rows through the catalog fetcher and
// renders virtualized rails with the row titles and poster labels.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:harbor_companion/app/home/catalog_fetcher.dart';
import 'package:harbor_companion/app/home/catalog_request.dart';
import 'package:harbor_companion/app/home/home_controller.dart';
import 'package:harbor_companion/app/home/home_screen.dart';
import 'package:harbor_companion/app/home/meta.dart';

class _FakeCatalogFetcher implements CatalogFetcher {
  final List<HomeRow> rows;
  int calls = 0;

  _FakeCatalogFetcher([this.rows = const [
    HomeRow('Top Movies', [
      Meta(id: 'tt1', type: 'movie', name: 'The Matrix'),
      Meta(id: 'tt2', type: 'movie', name: 'Inception'),
    ]),
    HomeRow('Top Series', [
      Meta(id: 'tt3', type: 'series', name: 'Breaking Bad'),
    ]),
  ]]);

  @override
  Future<List<HomeRow>> fetchRows(CatalogRequest request) async {
    calls++;
    return rows;
  }

  @override
  Future<DetailMeta> fetchDetail(String type, String id, String? tmdbKey) async =>
      DetailMeta(meta: Meta(id: id, type: type, name: 'Detail'));
}

Widget _app(CatalogFetcher fetcher) => ProviderScope(
      overrides: [catalogFetcherProvider.overrideWithValue(fetcher)],
      child: const MaterialApp(home: Scaffold(body: HomeScreen())),
    );

void main() {
  testWidgets('Home loads rows and renders rail titles + posters', (tester) async {
    await tester.pumpWidget(_app(_FakeCatalogFetcher()));
    await tester.pump(); // load() → fetch resolves
    await tester.pump(); // rows publish + rebuild

    expect(find.text('Top Movies'), findsOneWidget);
    expect(find.text('Top Series'), findsOneWidget);
    expect(find.text('The Matrix'), findsOneWidget);
    expect(find.text('Inception'), findsOneWidget);
    expect(find.text('Breaking Bad'), findsOneWidget);
  });

  testWidgets('an empty catalog shows the empty state, not a blank grid',
      (tester) async {
    final fetcher = _FakeCatalogFetcher(const []);
    await tester.pumpWidget(_app(fetcher));
    await tester.pump();
    await tester.pump();

    expect(find.text('No catalogs to show'), findsOneWidget);
    expect(find.text('Open settings'), findsOneWidget);

    // Refresh forces a refetch even though the terminal state is `ready`.
    await tester.tap(find.text('Refresh'));
    await tester.pump();
    await tester.pump();
    expect(fetcher.calls, 2);
  });
}
