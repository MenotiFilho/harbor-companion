// Pins the design-system tokens and the bundled serif asset (#81, ADR-0013).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';

import 'package:harbor_companion/app/theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the Accent is the fixed brand color', () {
    expect(AppTheme.tokens.accent, const Color(0xFF8F97FF));
    expect(AppTheme.tokens.bg, const Color(0xFF08080B));
  });

  testWidgets('AppTokens.of falls back when the extension is absent',
      (tester) async {
    AppTokens? tokens;
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (context) {
        tokens = AppTokens.of(context);
        return const SizedBox.shrink();
      }),
    ));

    expect(tokens, isNotNull);
    expect(tokens!.accent, AppTheme.tokens.accent);
  });

  testWidgets('the app theme carries the tokens extension', (tester) async {
    late AppTokens tokens;
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.dark,
      home: Builder(builder: (context) {
        tokens = AppTokens.of(context);
        return const SizedBox.shrink();
      }),
    ));

    expect(tokens.radius, 20);
    expect(tokens.glassHair, isNot(Colors.transparent));
  });

  test('the serif title style uses the bundled family', () {
    expect(AppTheme.tokens.serifTitle.fontFamily, AppTokens.serifFamily);
    expect(AppTheme.tokens.serifTitle.fontWeight, FontWeight.w600);
  });

  testWidgets('the serif faces are bundled as assets (ADR-0013)',
      (tester) async {
    for (final weight in ['Medium', 'SemiBold', 'Bold']) {
      final data = await rootBundle
          .load('assets/fonts/CormorantGaramond-$weight.ttf');
      expect(data.lengthInBytes, greaterThan(0),
          reason: 'CormorantGaramond-$weight.ttf must ship in the bundle');
    }
  });
}
