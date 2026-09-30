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
import 'package:harbor_companion/app/ui/rows.dart';

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
      of: find.widgetWithText(SwitchRow, label),
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

  testWidgets('rows use the shared hairline switch row with a 48dp target',
      (tester) async {
    final container = make();
    addTearDown(container.dispose);
    await tester.pumpWidget(app(container));
    await tester.pumpAndSettle();

    expect(find.byType(SwitchRow), findsWidgets);
    expect(find.byType(ListTile), findsNothing);
    expect(
      tester.getSize(find.byType(SwitchRow).first).height,
      greaterThanOrEqualTo(48),
    );
    // ADR-0010: the editor is scroll content — no backdrop blur.
    expect(find.byType(BackdropFilter), findsNothing);
  });

  testWidgets('the drag handle keeps a >= 48dp square touch target (#91)',
      (tester) async {
    final container = make();
    addTearDown(container.dispose);
    await tester.pumpWidget(app(container));
    await tester.pumpAndSettle();

    expect(find.byType(ReorderableDragStartListener), findsWidgets);
    final handle = find.byType(ReorderableDragStartListener).first;
    final size = tester.getSize(handle);
    expect(size.width, greaterThanOrEqualTo(48));
    expect(size.height, greaterThanOrEqualTo(48));

    // The full square is draggable, not just the 22dp glyph centered in it:
    // start the gesture in the handle's top-left corner and reorder.
    final first = container.read(settingsControllerProvider).homeRowOrder.first;
    final gesture = await tester.startGesture(
      tester.getTopLeft(handle) + const Offset(4, 4),
    );
    await tester.pump();
    await gesture.moveBy(const Offset(0, 120));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(
      container.read(settingsControllerProvider).homeRowOrder.indexOf(first),
      isNot(0),
      reason: 'a drag from the expanded handle area must reorder the row',
    );
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
