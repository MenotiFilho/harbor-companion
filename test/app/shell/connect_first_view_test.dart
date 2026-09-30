// Widget tests for the connect-first empty state (issue #90 restyle). The view
// is presentation over the connect controller: these pin the actions it offers,
// the cold-start prompt, the >= 48dp targets and the ADR-0010 glass budget.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:harbor_companion/app/connect/connect_controller.dart';
import 'package:harbor_companion/app/connect/connect_reducer.dart';
import 'package:harbor_companion/app/routes.dart';
import 'package:harbor_companion/app/shell/connect_first_view.dart';
import 'package:harbor_companion/app/theme.dart';

/// A connect controller with a fixed state; records the reconnect taps.
class _StubConnectController extends ConnectController {
  _StubConnectController(this.initial);
  final ConnectState initial;
  int connectCalls = 0;

  @override
  ConnectState build() => initial;

  @override
  void connect() => connectCalls++;
}

Widget _app(ConnectState state, {_StubConnectController? controller}) {
  final ctrl = controller ?? _StubConnectController(state);
  return ProviderScope(
    overrides: [connectControllerProvider.overrideWith(() => ctrl)],
    child: MaterialApp(
      theme: AppTheme.dark,
      routes: {
        AppRoutes.settings: (_) => const Scaffold(body: Text('SETTINGS')),
      },
      home: const Scaffold(body: ConnectFirstView()),
    ),
  );
}

void main() {
  testWidgets('shows the sober copy and leads to settings', (tester) async {
    await tester.pumpWidget(_app(ConnectState()));

    expect(find.text('Connect to your Harbor host'), findsOneWidget);
    expect(find.textContaining('Add your PC’s LAN address'), findsOneWidget);
    expect(find.text('Reconnect'), findsNothing);

    await tester.tap(find.text('Open settings'));
    await tester.pumpAndSettle();
    expect(find.text('SETTINGS'), findsOneWidget);
  });

  testWidgets('a cold-start miss offers Reconnect', (tester) async {
    final controller = _StubConnectController(
      ConnectState(notice: 'last host unreachable — reconnect?'),
    );
    await tester.pumpWidget(_app(controller.initial, controller: controller));

    expect(find.text('Your last host couldn’t be reached.'), findsOneWidget);
    await tester.tap(find.text('Reconnect'));
    expect(controller.connectCalls, 1);
  });

  testWidgets('holds the glass budget and >= 48dp actions', (tester) async {
    await tester.pumpWidget(_app(ConnectState()));

    // ADR-0010: the empty state is neither chrome nor an overlay — no blur.
    expect(find.byType(BackdropFilter), findsNothing);
    expect(
      tester.getSize(find.widgetWithText(FilledButton, 'Open settings')).height,
      greaterThanOrEqualTo(48),
    );
  });
}
