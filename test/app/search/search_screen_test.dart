// Widget test for the Search screen (thin coverage: the reducer is the real
// seam). Verifies typing debounces and the merged results grid + anime section
// render from the fetcher.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:harbor_companion/app/home/meta.dart';
import 'package:harbor_companion/app/search/jikan.dart';
import 'package:harbor_companion/app/search/search_controller.dart';
import 'package:harbor_companion/app/search/search_fetcher.dart';
import 'package:harbor_companion/app/search/search_reducer.dart';
import 'package:harbor_companion/app/search/search_screen.dart';

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
    expect(find.text('Anime'), findsWidgets);
  });
}
