// Widget tests for the Home-rows editor. The reorder math lives in the settings
// controller (tested there); these pin that the screen renders the rows, toggles
// a rail, and offers the bulk built-in actions.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:harbor_companion/app/home/home_rows.dart';
import 'package:harbor_companion/app/home/home_rows_screen.dart';
import 'package:harbor_companion/app/settings/settings_controller.dart';
import 'package:harbor_companion/app/settings/settings_store.dart';
import 'package:harbor_companion/app/shell/player_bar.dart';

ProviderContainer make() => ProviderContainer(
      overrides: [
        settingsStoreProvider.overrideWithValue(InMemorySettingsStore()),
        playerBarViewProvider.overrideWithValue(null),
      ],
    );

Widget app(ProviderContainer container) => UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: HomeRowsScreen()),
    );

Finder switchOf(String label) => find.descendant(
      of: find.widgetWithText(ListTile, label),
      matching: find.byType(Switch),
    );

void main() {
  testWidgets('renders the built-in and Letterboxd rows', (tester) async {
    final container = make();
    addTearDown(container.dispose);
    await tester.pumpWidget(app(container));
    await tester.pumpAndSettle();

    expect(find.text('Top Movies'), findsOneWidget);
    expect(find.text('Cinemeta'), findsWidgets);

    await tester.scrollUntilVisible(
      find.text('Watchlist'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Watchlist'), findsOneWidget);
    expect(find.text('Letterboxd'), findsWidgets);
  });

  testWidgets('toggling a built-in row off persists', (tester) async {
    final container = make();
    addTearDown(container.dispose);
    await tester.pumpWidget(app(container));
    await tester.pumpAndSettle();

    await tester.tap(switchOf('Top Movies'));
    await tester.pumpAndSettle();

    expect(
      container.read(settingsControllerProvider).disabledBuiltInRowKeys,
      contains('cinemeta:top-movies'),
    );
  });

  testWidgets('"Hide built-in rows" disables every built-in rail',
      (tester) async {
    final container = make();
    addTearDown(container.dispose);
    await tester.pumpWidget(app(container));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Hide built-in rows'));
    await tester.pumpAndSettle();

    expect(
      container.read(settingsControllerProvider).disabledBuiltInRowKeys,
      hasLength(kCinemetaRows.length + kTmdbRows.length),
    );
  });
}
