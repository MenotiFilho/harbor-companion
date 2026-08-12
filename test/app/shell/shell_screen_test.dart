import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:harbor_companion/app/shell/connect_first_view.dart';
import 'package:harbor_companion/app/shell/shell_controller.dart';
import 'package:harbor_companion/app/shell/shell_reducer.dart';
import 'package:harbor_companion/main.dart';

void main() {
  testWidgets('fresh install shows the connect-first empty state and five tabs',
      (tester) async {
    await tester.pumpWidget(const ProviderScope(child: HarborCompanionApp()));

    expect(find.byType(ConnectFirstView), findsOneWidget);

    for (final label in ['Remote', 'Search', 'Home', 'My Stuff', 'Profile']) {
      expect(find.text(label), findsWidgets);
    }
  });

  testWidgets('the connect-first view leads to settings', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: HarborCompanionApp()));

    await tester.tap(find.text('Open settings'));
    await tester.pumpAndSettle();

    expect(find.text('Settings'), findsOneWidget);
    expect(find.byType(ConnectFirstView), findsNothing);
  });

  testWidgets('a live connection shows the active tab body', (tester) async {
    final container = ProviderContainer(
      overrides: [
        connectionStatusProvider.overrideWith(ConnectionStatusController.new),
      ],
    );
    container.read(connectionStatusProvider.notifier).set(ConnectionStatus.connected);
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const HarborCompanionApp(),
      ),
    );

    expect(find.byType(ConnectFirstView), findsNothing);
    expect(find.text('Home'), findsWidgets);

    await tester.tap(find.text('Search'));
    await tester.pumpAndSettle();
    expect(find.text('Search'), findsWidgets);
  });
}
