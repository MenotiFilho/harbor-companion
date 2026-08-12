import 'package:flutter/material.dart';

/// Material 3 theme for the companion. Dark-first — Harbor's remote surface is
/// a dark, TV-adjacent UI — with a seed color that reads as a media app.
abstract final class AppTheme {
  static const _seed = Color(0xFF5B6CF0);

  static ThemeData get dark => ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: _seed,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      );
}
