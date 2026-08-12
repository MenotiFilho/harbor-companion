// Thin widget test for the Library screen (the reducer is the real seam).
// Verifies the derived empty states (needConnect / emptyLibrary), the offline
// stale banner, and that the three sections render items with their
// host-authoritative toggle chips.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:harbor_companion/app/library/library_controller.dart';
import 'package:harbor_companion/app/library/library_reducer.dart';
import 'package:harbor_companion/app/library/library_screen.dart';
import 'package:harbor_companion/app/ws/client_reducer.dart' show LibraryItem;

class _StubLibraryController extends LibraryController {
  @override
  final LibraryState state;
  final List<(String, String, bool)> toggles = [];
  _StubLibraryController(this.state);
  @override
  LibraryState build() => state;
  @override
  void toggle(String kind, LibraryItem item, bool on) {
    toggles.add((kind, item.id, on));
  }
}

Widget _wrap(LibraryState state) => ProviderScope(
      overrides: [
        libraryControllerProvider
            .overrideWith(() => _StubLibraryController(state)),
      ],
      child: const MaterialApp(home: Scaffold(body: LibraryScreen())),
    );

void main() {
  final matrix = LibraryItem('tt1', 'movie', 'The Matrix', null, null);

  testWidgets('needConnect shows the connect empty state', (tester) async {
    await tester.pumpWidget(_wrap(LibraryState(
      view: const MyStuffView(emptyKind: EmptyKind.needConnect),
    )));
    expect(find.text('Connect to see My Stuff'), findsOneWidget);
  });

  testWidgets('emptyLibrary shows the empty-library state', (tester) async {
    await tester.pumpWidget(_wrap(LibraryState(
      connected: true,
      view: const MyStuffView(emptyKind: EmptyKind.emptyLibrary),
    )));
    expect(find.text('Your library is empty'), findsOneWidget);
  });

  testWidgets('a stale view shows the offline banner and the persisted items',
      (tester) async {
    await tester.pumpWidget(_wrap(LibraryState(
      connected: false,
      view: MyStuffView(
        stale: true,
        watchlist: [matrix],
        watchlistIds: {matrix.id},
      ),
    )));
    expect(find.textContaining('Offline'), findsOneWidget);
    expect(find.text('The Matrix'), findsOneWidget);
  });

  testWidgets('sections render items with toggle chips reflecting membership',
      (tester) async {
    await tester.pumpWidget(_wrap(LibraryState(
      connected: true,
      view: MyStuffView(
        watchlist: [matrix],
        watchlistIds: {matrix.id},
        historyIds: const {},
        favoriteIds: const {},
      ),
    )));
    expect(find.text('Watchlist (1)'), findsOneWidget);
    expect(find.text('History (0)'), findsOneWidget);
    expect(find.text('Favorites (0)'), findsOneWidget);
    expect(find.text('The Matrix'), findsOneWidget);
    // The watchlist chip is active (filled bookmark); watched/favorite are not.
    expect(find.byIcon(Icons.bookmark), findsOneWidget);
    expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);
    expect(find.byIcon(Icons.favorite_border), findsOneWidget);
  });

  testWidgets('each toggle chip routes to its own kind (not the section kind)',
      (tester) async {
    final controller = _StubLibraryController(LibraryState(
      connected: true,
      view: MyStuffView(
        watchlist: [matrix],
        watchlistIds: {matrix.id},
        historyIds: const {},
        favoriteIds: const {},
      ),
    ));
    await tester.pumpWidget(ProviderScope(
      overrides: [
        libraryControllerProvider.overrideWith(() => controller),
      ],
      child: const MaterialApp(home: Scaffold(body: LibraryScreen())),
    ));

    // Tap the "mark watched" chip (outline) and the "favorite" chip.
    await tester.tap(find.byIcon(Icons.check_circle_outline));
    await tester.tap(find.byIcon(Icons.favorite_border));
    expect(controller.toggles, [
      ('watched', 'tt1', true),
      ('favorite', 'tt1', true),
    ]);
  });
}
