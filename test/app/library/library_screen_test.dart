// Thin widget test for the Library screen (the reducer is the real seam).
// Verifies the derived empty states (needConnect / emptyLibrary), the section
// selector switching between Watchlist / History /
// Favorites, the host-authoritative toggle chips routing to their own kind,
// row tap opening the shared detail page, and the editorial restyle pins
// (#89): the Accent-lit segmented control and toggles, hairline rows, and no
// watch-progress bar (the wire has none).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:harbor_companion/app/home/home_controller.dart';
import 'package:harbor_companion/app/home/home_reducer.dart';
import 'package:harbor_companion/app/home/meta.dart';
import 'package:harbor_companion/app/library/library_controller.dart';
import 'package:harbor_companion/app/library/library_reducer.dart';
import 'package:harbor_companion/app/library/library_screen.dart';
import 'package:harbor_companion/app/routes.dart';
import 'package:harbor_companion/app/theme.dart';
import 'package:harbor_companion/app/ui/hairline.dart';
import 'package:harbor_companion/app/ui/progress_bar.dart';
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

class _StubHomeController extends HomeController {
  final List<Meta> opened = [];
  @override
  HomeState build() => HomeState();
  @override
  void openDetail(Meta meta) => opened.add(meta);
}

Widget _wrap(LibraryState state, {_StubHomeController? home}) => ProviderScope(
      overrides: [
        libraryControllerProvider
            .overrideWith(() => _StubLibraryController(state)),
        if (home != null) homeControllerProvider.overrideWith(() => home),
      ],
      child: MaterialApp(
        routes: {AppRoutes.detail: (_) => const Scaffold(body: Text('DETAIL'))},
        home: const Scaffold(body: LibraryScreen()),
      ),
    );

void main() {
  final matrix = LibraryItem('tt1', 'movie', 'The Matrix', null, null);
  final got =
      LibraryItem('tt2', 'series', 'Game of Thrones', null, null);

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

  testWidgets('disconnected view shows the connect empty state', (tester) async {
    await tester.pumpWidget(_wrap(LibraryState(
      connected: false,
      view: const MyStuffView(emptyKind: EmptyKind.needConnect),
    )));
    expect(find.text('Connect to see My Stuff'), findsOneWidget);
    expect(find.text('Keep a local copy'), findsNothing);
  });

  testWidgets('the default section renders watchlist items with toggle chips',
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
    expect(find.text('The Matrix'), findsOneWidget);
    // The watchlist chip is active (filled bookmark); watched/favorite are not.
    expect(find.byIcon(Icons.bookmark), findsOneWidget);
    expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);
    expect(find.byIcon(Icons.favorite_border), findsOneWidget);
  });

  testWidgets('switching sections shows that section’s items', (tester) async {
    await tester.pumpWidget(_wrap(LibraryState(
      connected: true,
      view: MyStuffView(
        watchlist: [matrix],
        watchlistIds: {matrix.id},
        favorites: [got],
        favoriteIds: {got.id},
      ),
    )));
    expect(find.text('The Matrix'), findsOneWidget);
    expect(find.text('Game of Thrones'), findsNothing);

    await tester.tap(find.text('Favorites'));
    await tester.pumpAndSettle();

    expect(find.text('Game of Thrones'), findsOneWidget);
    expect(find.text('The Matrix'), findsNothing);
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

  testWidgets('tapping a row opens the shared detail page', (tester) async {
    final home = _StubHomeController();
    await tester.pumpWidget(_wrap(
      LibraryState(
        connected: true,
        view: MyStuffView(
          watchlist: [matrix],
          watchlistIds: {matrix.id},
        ),
      ),
      home: home,
    ));

    await tester.tap(find.text('The Matrix'));
    await tester.pumpAndSettle();

    expect(home.opened.single.id, 'tt1');
    expect(home.opened.single.type, 'movie');
    expect(find.text('DETAIL'), findsOneWidget);
  });

  testWidgets('the segmented control is unblurred with the selected section lit',
      (tester) async {
    await tester.pumpWidget(_wrap(LibraryState(
      connected: true,
      view: MyStuffView(
        watchlist: [matrix],
        watchlistIds: {matrix.id},
      ),
    )));

    const tokens = AppTokens();
    // ADR-0010: the segmented control and the rows are fill + hairline only.
    expect(find.byType(BackdropFilter), findsNothing);
    expect(
      tester.widget<Text>(find.text('Watchlist')).style?.color,
      tokens.accentInk,
      reason: 'the selected segment reads in the Accent family',
    );
    expect(
      tester.widget<Text>(find.text('History')).style?.color,
      // Unselected labels are informative text over the glass fill, so they
      // use the AA ink step (#91) — not the decorative inkFaint.
      tokens.inkMuted,
    );
  });

  testWidgets('every section segment is a >= 48dp touch target (#91)',
      (tester) async {
    await tester.pumpWidget(_wrap(LibraryState(
      connected: true,
      view: MyStuffView(watchlist: [matrix], watchlistIds: {matrix.id}),
    )));

    for (final label in ['Watchlist', 'History', 'Favorites']) {
      final target = find.ancestor(
        of: find.text(label),
        matching: find.byType(GestureDetector),
      );
      expect(
        tester.getSize(target).height,
        greaterThanOrEqualTo(48),
        reason: '$label must keep a 48dp touch target',
      );
    }

    // The target is real: a tap on the unselected pill still switches.
    await tester.tap(find.text('History'));
    await tester.pumpAndSettle();
    expect(find.text('Nothing here yet'), findsOneWidget);
  });

  testWidgets('toggle chips light up in the Accent only when on', (tester) async {
    await tester.pumpWidget(_wrap(LibraryState(
      connected: true,
      view: MyStuffView(
        watchlist: [matrix],
        watchlistIds: {matrix.id},
        historyIds: const {},
        favoriteIds: const {},
      ),
    )));

    const tokens = AppTokens();
    expect(
      tester.widget<Icon>(find.byIcon(Icons.bookmark)).color,
      tokens.accent,
    );
    expect(
      tester.widget<Icon>(find.byIcon(Icons.check_circle_outline)).color,
      tokens.inkFaint,
    );
    expect(
      tester.widget<Icon>(find.byIcon(Icons.favorite_border)).color,
      tokens.inkFaint,
    );
  });

  testWidgets('rows are hairline-separated and carry no watch-progress bar',
      (tester) async {
    await tester.pumpWidget(_wrap(LibraryState(
      connected: true,
      view: MyStuffView(
        watchlist: [matrix, got],
        watchlistIds: {matrix.id, got.id},
      ),
    )));

    // Honesty rule (#80): LibraryItem has no Watch progress, so no bar renders.
    expect(find.byType(ProgressBar), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.byType(Hairline), findsNWidgets(2));
  });
}
