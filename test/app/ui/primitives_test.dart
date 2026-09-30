// Widget tests for the shared UI primitives (#81). These pin the behavior the
// rows carry — tap targets, disabled state, divider — not pixels.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:harbor_companion/app/theme.dart';
import 'package:harbor_companion/app/ui/glass_surface.dart';
import 'package:harbor_companion/app/ui/hairline.dart';
import 'package:harbor_companion/app/ui/press_scale.dart';
import 'package:harbor_companion/app/ui/rows.dart';
import 'package:harbor_companion/app/ui/section_header.dart';

Widget host(Widget child) => MaterialApp(
      theme: AppTheme.dark,
      home: Scaffold(body: child),
    );

void main() {
  group('GlassSurface', () {
    testWidgets('renders its child without blurring by default (ADR-0010)',
        (tester) async {
      await tester.pumpWidget(host(const GlassSurface(child: Text('panel'))));

      expect(find.text('panel'), findsOneWidget);
      expect(find.byType(BackdropFilter), findsNothing);
    });

    testWidgets('blurs only when explicitly asked', (tester) async {
      await tester.pumpWidget(
        host(const GlassSurface(blurred: true, child: Text('chrome'))),
      );

      expect(find.text('chrome'), findsOneWidget);
      expect(find.byType(BackdropFilter), findsOneWidget);
    });
  });

  group('SectionHeader', () {
    testWidgets('renders the label uppercased', (tester) async {
      await tester.pumpWidget(host(const SectionHeader('Saved hosts')));

      expect(find.text('SAVED HOSTS'), findsOneWidget);
      expect(find.text('Saved hosts'), findsNothing);
    });
  });

  group('Hairline', () {
    testWidgets('is one logical pixel tall', (tester) async {
      await tester.pumpWidget(host(const Hairline()));

      expect(tester.getSize(find.byType(Hairline)).height, 1);
    });
  });

  group('SwitchRow', () {
    testWidgets('tapping the whole row toggles the value', (tester) async {
      bool? changed;
      var calls = 0;
      await tester.pumpWidget(host(SwitchRow(
        title: 'Keep connection',
        subtitle: 'Stays alive with the screen off.',
        value: false,
        onChanged: (v) {
          changed = v;
          calls++;
        },
      )));

      expect(find.text('Keep connection'), findsOneWidget);
      expect(find.text('Stays alive with the screen off.'), findsOneWidget);

      await tester.tap(find.text('Keep connection'));
      expect(changed, isTrue);
      expect(calls, 1, reason: 'row tap must fire onChanged exactly once');

      changed = null;
      await tester.tap(find.byType(Switch));
      expect(changed, isTrue);
      expect(calls, 2, reason: 'switch tap must fire onChanged exactly once');
    });

    testWidgets('carries a >= 48dp touch target', (tester) async {
      await tester.pumpWidget(host(SwitchRow(
        title: 'Toggle',
        value: true,
        onChanged: (_) {},
      )));

      expect(tester.getSize(find.byType(SwitchRow)).height, greaterThanOrEqualTo(48));
    });

    testWidgets('renders disabled without an onChanged', (tester) async {
      await tester.pumpWidget(host(const SwitchRow(
        title: 'Locked',
        value: false,
        onChanged: null,
      )));

      expect(tester.widget<Switch>(find.byType(Switch)).onChanged, isNull);
      await tester.tap(find.text('Locked'));
      // No exception, no state change: the row is inert.
      expect(find.text('Locked'), findsOneWidget);
    });
  });

  group('ListRow', () {
    testWidgets('taps and shows title, subtitle and trailing', (tester) async {
      var taps = 0;
      await tester.pumpWidget(host(ListRow(
        leading: const Icon(Icons.computer),
        title: 'menoti pc',
        subtitle: '192.168.1.50:11471',
        trailing: const Icon(Icons.chevron_right),
        onTap: () => taps++,
      )));

      expect(find.text('menoti pc'), findsOneWidget);
      expect(find.text('192.168.1.50:11471'), findsOneWidget);
      expect(find.byIcon(Icons.computer), findsOneWidget);

      await tester.tap(find.text('menoti pc'));
      expect(taps, 1);
    });

    testWidgets('carries a >= 48dp touch target and a soft divider',
        (tester) async {
      await tester.pumpWidget(host(ListRow(title: 'Row', onTap: () {})));

      expect(tester.getSize(find.byType(ListRow)).height, greaterThanOrEqualTo(48));
      expect(find.byType(Hairline), findsOneWidget);
    });

    testWidgets('can drop the divider', (tester) async {
      await tester.pumpWidget(host(const ListRow(title: 'Last', divider: false)));

      expect(find.byType(Hairline), findsNothing);
    });

    testWidgets('caps the title when asked', (tester) async {
      await tester.pumpWidget(host(const SizedBox(
        width: 120,
        child: ListRow(title: 'A very long row title', titleMaxLines: 1),
      )));

      final title = tester.widget<Text>(find.text('A very long row title'));
      expect(title.maxLines, 1);
      expect(title.overflow, TextOverflow.ellipsis);
    });
  });

  group('InfoRow', () {
    testWidgets('shows a quiet key and a value', (tester) async {
      await tester.pumpWidget(host(const InfoRow(
        label: 'Host version',
        value: 'v0.9.118',
      )));

      expect(find.text('Host version'), findsOneWidget);
      expect(find.text('v0.9.118'), findsOneWidget);
    });
  });

  group('PressScale', () {
    testWidgets('scales down while pressed and back on release, tapping once',
        (tester) async {
      var taps = 0;
      await tester.pumpWidget(host(PressScale(
        onTap: () => taps++,
        child: const SizedBox(width: 60, height: 60),
      )));

      AnimatedScale scale() =>
          tester.widget<AnimatedScale>(find.byType(AnimatedScale));
      expect(scale().scale, 1.0);

      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(PressScale)),
      );
      await tester.pump();
      expect(scale().scale, lessThan(1.0),
          reason: 'the card acknowledges the touch');

      await gesture.up();
      await tester.pumpAndSettle();
      expect(scale().scale, 1.0);
      expect(taps, 1);
    });

    testWidgets('is inert without onTap', (tester) async {
      await tester.pumpWidget(host(const PressScale(
        child: SizedBox(width: 60, height: 60),
      )));

      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(PressScale)),
      );
      await tester.pump();
      expect(
        tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale,
        1.0,
      );
      await gesture.up();
      await tester.pumpAndSettle();
    });
  });
}
