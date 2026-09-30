// Pure-Dart WCAG contrast guard for the Editorial Cinema tokens (issue #91).
//
// Body text must clear WCAG AA (4.5:1) on every dark token surface and — since
// the refresh's "glass" is a translucent fill + hairline — on those fills
// composited over each surface. `inkFaint` is the decorative-label step and is
// deliberately exempt: it is only used for decoration and for AA-checked
// labels on the plain background (where it clears 4.5:1).
//
// This is a token-level guard, not a pixel test: it pins the ramp so a token
// edit that breaks body-text legibility fails here, in milliseconds.

import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';

import 'package:harbor_companion/app/theme.dart';

/// WCAG relative luminance of one sRGB channel (0..1).
double _linearize(double channel) => channel <= 0.04045
    ? channel / 12.92
    : math.pow((channel + 0.055) / 1.055, 2.4).toDouble();

/// WCAG relative luminance of a color.
double relativeLuminance(Color color) =>
    0.2126 * _linearize(color.r) +
    0.7152 * _linearize(color.g) +
    0.0722 * _linearize(color.b);

/// WCAG contrast ratio between two opaque colors; 1 (identical) to 21.
double contrastRatio(Color a, Color b) {
  final la = relativeLuminance(a);
  final lb = relativeLuminance(b);
  final hi = math.max(la, lb);
  final lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

/// [fill] composited over [backdrop] — what the eye sees through a glass fill.
Color over(Color fill, Color backdrop) => Color.alphaBlend(fill, backdrop);

void main() {
  const tokens = AppTokens();
  const aa = 4.5;

  final surfaces = {
    'bg': tokens.bg,
    'bgElev': tokens.bgElev,
    'solid': tokens.solid,
    'solidHigh': tokens.solidHigh,
  };

  group('body ink clears WCAG AA over every token surface (#91)', () {
    for (final surface in surfaces.entries) {
      final glass = over(tokens.glassFill, surface.value);
      final glassStrong = over(tokens.glassFillStrong, surface.value);

      test('ink and inkMuted on ${surface.key} and its glass fills', () {
        for (final ink in {
          'ink': tokens.ink,
          'inkMuted': tokens.inkMuted,
        }.entries) {
          for (final backdrop in {
            surface.key: surface.value,
            'glassFill over ${surface.key}': glass,
            'glassFillStrong over ${surface.key}': glassStrong,
          }.entries) {
            final ratio = contrastRatio(ink.value, backdrop.value);
            expect(
              ratio,
              greaterThanOrEqualTo(aa),
              reason:
                  '${ink.key} on ${backdrop.key} is ${ratio.toStringAsFixed(2)}:1',
            );
          }
        }
      });

      test('accent text on ${surface.key} and its glass fills', () {
        for (final ink in {
          'accent': tokens.accent,
          'accentInk': tokens.accentInk,
        }.entries) {
          for (final backdrop in {
            surface.key: surface.value,
            'glassFill over ${surface.key}': glass,
            'glassFillStrong over ${surface.key}': glassStrong,
          }.entries) {
            final ratio = contrastRatio(ink.value, backdrop.value);
            expect(
              ratio,
              greaterThanOrEqualTo(aa),
              reason: '${ink.key} on ${backdrop.key} is '
                  '${ratio.toStringAsFixed(2)}:1',
            );
          }
        }
      });
    }

    test('button text clears AA on the accent and its fill', () {
      expect(contrastRatio(tokens.onAccent, tokens.accent),
          greaterThanOrEqualTo(aa));
      expect(
        contrastRatio(tokens.accentInk, over(tokens.accentFill, tokens.solid)),
        greaterThanOrEqualTo(aa),
        reason: 'the selected-segment label reads over the accent fill',
      );
    });
  });

  test('the ink ramp stays ordered brightest to faintest', () {
    expect(relativeLuminance(tokens.ink),
        greaterThan(relativeLuminance(tokens.inkMuted)));
    expect(relativeLuminance(tokens.inkMuted),
        greaterThan(relativeLuminance(tokens.inkFaint)));
  });

  test('the glass fills are brighter than what they cover', () {
    for (final surface in surfaces.values) {
      expect(relativeLuminance(over(tokens.glassFill, surface)),
          greaterThan(relativeLuminance(surface)));
      expect(relativeLuminance(over(tokens.glassFillStrong, surface)),
          greaterThan(relativeLuminance(surface)));
    }
  });
}
