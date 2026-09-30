// Widget tests for the shared Hero band (issue #83). These pin the honest
// artwork fallback chain (Backdrop → blurred Poster → static gradient), the
// ADR-0010 guard (no BackdropFilter anywhere near it) and the tap seam — not
// pixels.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:harbor_companion/app/theme.dart';
import 'package:harbor_companion/app/ui/hero_band.dart';

Widget host(Widget child) => MaterialApp(
      theme: AppTheme.dark,
      home: Scaffold(body: child),
    );

const _backdrop = ValueKey('heroBackdrop');
const _posterBlur = ValueKey('heroPosterBlur');
const _gradient = ValueKey('heroGradient');

void main() {
  group('HeroArtwork fallback chain', () {
    testWidgets('a Backdrop fills the band when present', (tester) async {
      await tester.pumpWidget(host(const HeroArtwork(
        backdropUrl: 'https://img/back.jpg',
        posterUrl: 'https://img/poster.jpg',
      )));

      expect(find.byKey(_backdrop), findsOneWidget);
      expect(find.byKey(_posterBlur), findsNothing,
          reason: 'the poster is only the fallback');
    });

    testWidgets('without a Backdrop it fills with the blurred Poster',
        (tester) async {
      await tester.pumpWidget(host(const HeroArtwork(
        posterUrl: 'https://img/poster.jpg',
      )));

      expect(find.byKey(_posterBlur), findsOneWidget);
      expect(find.byType(ImageFiltered), findsOneWidget);
      expect(find.byType(BackdropFilter), findsNothing,
          reason: 'ADR-0010: the hero blurs its own child, never the backdrop');
      expect(find.byKey(_gradient), findsNothing);
    });

    testWidgets('with no Poster either it falls back to a static gradient',
        (tester) async {
      await tester.pumpWidget(host(const HeroArtwork()));

      expect(find.byKey(_gradient), findsOneWidget);
      expect(find.byType(ImageFiltered), findsNothing);
      expect(find.byType(BackdropFilter), findsNothing);
    });

    testWidgets('blank URLs count as absent artwork', (tester) async {
      await tester.pumpWidget(host(const HeroArtwork(
        backdropUrl: '',
        posterUrl: '',
      )));

      expect(find.byKey(_gradient), findsOneWidget);
      expect(find.byType(ImageFiltered), findsNothing);
    });

    testWidgets('a Backdrop that fails to decode falls back to the Poster',
        (tester) async {
      await tester.pumpWidget(host(const HeroArtwork(
        backdropUrl: 'https://img/broken-backdrop.jpg',
        posterUrl: 'https://img/poster.jpg',
      )));
      // The test HttpClient answers every request with 400, so the backdrop's
      // errorBuilder runs on the next frame.
      await tester.pumpAndSettle();

      expect(find.byKey(_posterBlur), findsOneWidget);
    });

    testWidgets('a Poster that fails to decode leaves the static gradient',
        (tester) async {
      await tester.pumpWidget(host(const HeroArtwork(
        posterUrl: 'https://img/broken-poster.jpg',
      )));
      await tester.pumpAndSettle();

      expect(find.byKey(_gradient), findsOneWidget);
      expect(find.byKey(_posterBlur), findsOneWidget,
          reason: 'the blurred fill stays; the gradient shows through it');
    });
  });

  group('HeroBand', () {
    testWidgets('renders the scrim, kicker, serif title and meta',
        (tester) async {
      await tester.pumpWidget(host(const HeroBand(
        height: 300,
        title: 'The Matrix',
        kicker: 'Top Movies',
        meta: '1999',
      )));

      expect(tester.getSize(find.byType(HeroBand)).height, 300);
      expect(find.text('THE MATRIX'), findsNothing);
      expect(find.text('The Matrix'), findsOneWidget);
      expect(find.text('TOP MOVIES'), findsOneWidget);
      expect(find.text('1999'), findsOneWidget);

      final title = tester.widget<Text>(find.text('The Matrix'));
      expect(title.style?.fontFamily, AppTokens.serifFamily,
          reason: 'hero titles use the bundled serif (ADR-0013)');
    });

    testWidgets('omits lines with no data', (tester) async {
      await tester.pumpWidget(host(const HeroBand(height: 300, title: 'X')));

      expect(find.text('X'), findsOneWidget);
    });

    testWidgets('tapping the band fires onTap once', (tester) async {
      var taps = 0;
      await tester.pumpWidget(host(HeroBand(
        height: 300,
        title: 'The Matrix',
        onTap: () => taps++,
      )));

      await tester.tap(find.byType(HeroBand));
      await tester.pump();

      expect(taps, 1);
    });

    testWidgets('is inert without onTap', (tester) async {
      await tester.pumpWidget(host(const HeroBand(
        height: 300,
        title: 'The Matrix',
        posterUrl: 'https://img/poster.jpg',
      )));

      await tester.tap(find.byType(HeroBand), warnIfMissed: false);
      expect(find.byType(HeroBand), findsOneWidget);
    });
  });
}
