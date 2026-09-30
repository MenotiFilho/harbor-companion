import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme.dart';

/// A glass surface: translucent fill + hairline border.
///
/// Per ADR-0010, real blur is a fixed budget: pass [blurred] `true` only for
/// persistent chrome (app bar, player bar, tab bar) or overlays (bottom
/// sheets, dialogs). Cards, rails, list rows and anything inside scrollable
/// content use the default unblurred fill, which costs nothing per frame.
class GlassSurface extends StatelessWidget {
  const GlassSurface({
    super.key,
    required this.child,
    this.padding,
    this.radius,
    this.blurred = false,
    this.fill,
    this.hairline,
  });

  final Widget child;

  /// Inset of [child] from the surface edges. The fill still covers the
  /// padding, so the surface reads as one panel.
  final EdgeInsetsGeometry? padding;

  /// Corner radius; defaults to [AppTokens.radius].
  final double? radius;

  /// Whether to actually blur the backdrop (ADR-0010 surfaces only).
  final bool blurred;

  /// Overrides the default translucent glass fill.
  final Color? fill;

  /// Overrides the default glass hairline border.
  final Color? hairline;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final borderRadius = BorderRadius.circular(radius ?? tokens.radius);
    final surface = DecoratedBox(
      decoration: BoxDecoration(
        color: fill ?? tokens.glassFill,
        borderRadius: borderRadius,
        border: Border.all(color: hairline ?? tokens.glassHair),
      ),
      child: padding == null ? child : Padding(padding: padding!, child: child),
    );
    if (!blurred) return surface;
    return ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ImageFilter.blur(
          sigmaX: tokens.glassBlur,
          sigmaY: tokens.glassBlur,
        ),
        child: surface,
      ),
    );
  }
}
