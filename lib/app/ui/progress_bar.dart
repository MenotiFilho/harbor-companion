import 'package:flutter/material.dart';

import '../theme.dart';

/// A thin, rounded progress bar: a translucent track with an Accent fill.
///
/// Chrome for the mini-player's Playback position line (and later card
/// progress). Decorative: it carries no semantics of its own — the surrounding
/// line names the value.
class ProgressBar extends StatelessWidget {
  const ProgressBar({super.key, required this.value});

  /// Fraction filled in `[0, 1]`; values outside are clamped.
  final double value;

  static const double _height = 2;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final filled = value.clamp(0.0, 1.0);
    return ClipRRect(
      borderRadius: BorderRadius.circular(_height / 2),
      child: SizedBox(
        height: _height,
        child: ColoredBox(
          color: tokens.ink.withValues(alpha: 0.20),
          child: Align(
            alignment: Alignment.centerLeft,
            child: FractionallySizedBox(
              widthFactor: filled,
              heightFactor: 1,
              child: ColoredBox(color: tokens.accent),
            ),
          ),
        ),
      ),
    );
  }
}
