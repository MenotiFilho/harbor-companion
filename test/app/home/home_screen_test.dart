// Widget test for the Home screen (thin coverage: the reducer is the real
// seam). Verifies the Home tab loads rows through the catalog fetcher and
// renders virtualized rails with the row titles and poster labels.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:harbor_companion/app/home/catalog_fetcher.dart';
import 'package:harbor_companion/app/home/home_controller.dart';
import 'package:harbor_companion/app/home/home_screen.dart';
import 'package:harbor_companion/app/home/meta.dart';

class _FakeCatalogFetcher implements CatalogFetcher {
  @override
  Future<List<HomeRow>> fetchRows(String? tmdbKey) async => [
        HomeRow('Top Movies', [
          Meta(id: 'tt1', type: 'movie', name: 'The Matrix'),
          Meta(id: 'tt2', type: 'movie', name: 'Inception'),
        ]),
        HomeRow('Top Series', [
          Meta(id: 'tt3', type: 'series', name: 'Breaking Bad'),
        ]),
      ];

  @override
  Future<DetailMeta> fetchDetail(String type, String id, String? tmdbKey) async =>
      DetailMeta(meta: Meta(id: id, type: type, name: 'Detail'));
}

void main() {
  testWidgets('Home loads rows and renders rail titles + posters', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [catalogFetcherProvider.overrideWithValue(_FakeCatalogFetcher())],
        child: const MaterialApp(home: Scaffold(body: HomeScreen())),
      ),
    );
    await tester.pump(); // load() → fetch resolves
    await tester.pump(); // rows publish + rebuild

    expect(find.text('Top Movies'), findsOneWidget);
    expect(find.text('Top Series'), findsOneWidget);
    expect(find.text('The Matrix'), findsOneWidget);
    expect(find.text('Inception'), findsOneWidget);
    expect(find.text('Breaking Bad'), findsOneWidget);
  });
}
