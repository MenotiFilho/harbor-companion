import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

/// Explicit design tokens for the Editorial Cinema language (issues #80/#81).
///
/// Values mirror the approved prototype (`prototype/ui/app.html`, branch
/// `prototype/ui-refresh`). The [accent] is fixed brand identity — swappable by
/// editing this one constant; it is **not** a user setting. Sans stays the
/// platform default; only the hero serif ships bundled (ADR-0013), consumed
/// through [serifTitle] so its use stays scoped to titles.
///
/// Glass is a fill + hairline here; real blur is opt-in per surface and
/// restricted to persistent chrome and overlays (ADR-0010) — see
/// `GlassSurface` in `lib/app/ui/`.
@immutable
class AppTokens extends ThemeExtension<AppTokens> {
  const AppTokens({
    this.accent = const Color(0xFF8F97FF),
    this.onAccent = const Color(0xFF0A0A0F),
    this.bg = const Color(0xFF08080B),
    this.bgElev = const Color(0xFF0E0E13),
    this.solid = const Color(0xFF13131A),
    this.solidHigh = const Color(0xFF1A1A23),
    this.ink = const Color(0xFFF2F2F4),
    this.inkMuted = const Color(0xFFB6B6C0),
    this.inkFaint = const Color(0xFF787884),
    this.hair = const Color(0x17FFFFFF),
    this.hairSoft = const Color(0x0EFFFFFF),
    this.glassFill = const Color(0x0CFFFFFF),
    this.glassFillStrong = const Color(0x13FFFFFF),
    this.glassHair = const Color(0x1CFFFFFF),
    this.glassBlur = 18,
    this.radius = 20,
    this.radiusSmall = 14,
  });

  /// The single brand color that marks interactive and active states.
  final Color accent;
  final Color onAccent;

  /// Dark surfaces, darkest to lightest.
  final Color bg;
  final Color bgElev;
  final Color solid;
  final Color solidHigh;

  /// Text ramp: primary, secondary, decorative labels only.
  final Color ink;
  final Color inkMuted;
  final Color inkFaint;

  /// Hairlines: the standard `--hair`, and the softer row separator.
  final Color hair;
  final Color hairSoft;

  /// Translucent (unblurred) glass fills and the glass hairline.
  final Color glassFill;
  final Color glassFillStrong;
  final Color glassHair;

  /// Blur sigma for a real glass surface (ADR-0010 surfaces only).
  final double glassBlur;

  /// Corner radii: [radius] for cards/surfaces, [radiusSmall] for controls.
  final double radius;
  final double radiusSmall;

  /// Accent variants (prototype `--accent-2/ink/dim/line`).
  Color get accentBright => Color.lerp(accent, Colors.white, 0.38)!;
  Color get accentInk => Color.lerp(accent, Colors.white, 0.30)!;
  Color get accentFill => accent.withValues(alpha: 0.16);
  Color get accentLine => accent.withValues(alpha: 0.40);

  /// Bottom-up scrim for artwork bands (Hero/Cinemascope), fading to [bg].
  LinearGradient get heroScrim => LinearGradient(
        begin: Alignment.bottomCenter,
        end: Alignment.topCenter,
        colors: [
          bg,
          bg,
          bg.withValues(alpha: 0.74),
          bg.withValues(alpha: 0.24),
          bg.withValues(alpha: 0.42),
        ],
        stops: const [0, 0.01, 0.30, 0.62, 1],
      );

  /// Top-down veil for the Remote wash band.
  LinearGradient get veilScrim => LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          bg.withValues(alpha: 0.25),
          bg.withValues(alpha: 0.62),
          bg,
        ],
        stops: const [0, 0.52, 0.86],
      );

  /// The bundled serif family (ADR-0013).
  static const String serifFamily = 'Cormorant Garamond';

  /// Title style for hero/title surfaces; copyWith(size) per surface.
  TextStyle get serifTitle => TextStyle(
        fontFamily: serifFamily,
        fontSize: 34,
        fontWeight: FontWeight.w600,
        height: 1.05,
        letterSpacing: 0.1,
        color: ink,
      );

  /// Uppercase section label above grouped rows.
  TextStyle get sectionLabel => TextStyle(
        fontSize: 10.5,
        fontWeight: FontWeight.w600,
        letterSpacing: 2.3,
        height: 1.2,
        color: inkFaint,
      );

  /// Tokens for [context], falling back to the defaults when the app theme is
  /// not installed (widget tests pumping a bare `MaterialApp`).
  static AppTokens of(BuildContext context) =>
      Theme.of(context).extension<AppTokens>() ?? const AppTokens();

  @override
  AppTokens copyWith({
    Color? accent,
    Color? onAccent,
    Color? bg,
    Color? bgElev,
    Color? solid,
    Color? solidHigh,
    Color? ink,
    Color? inkMuted,
    Color? inkFaint,
    Color? hair,
    Color? hairSoft,
    Color? glassFill,
    Color? glassFillStrong,
    Color? glassHair,
    double? glassBlur,
    double? radius,
    double? radiusSmall,
  }) {
    return AppTokens(
      accent: accent ?? this.accent,
      onAccent: onAccent ?? this.onAccent,
      bg: bg ?? this.bg,
      bgElev: bgElev ?? this.bgElev,
      solid: solid ?? this.solid,
      solidHigh: solidHigh ?? this.solidHigh,
      ink: ink ?? this.ink,
      inkMuted: inkMuted ?? this.inkMuted,
      inkFaint: inkFaint ?? this.inkFaint,
      hair: hair ?? this.hair,
      hairSoft: hairSoft ?? this.hairSoft,
      glassFill: glassFill ?? this.glassFill,
      glassFillStrong: glassFillStrong ?? this.glassFillStrong,
      glassHair: glassHair ?? this.glassHair,
      glassBlur: glassBlur ?? this.glassBlur,
      radius: radius ?? this.radius,
      radiusSmall: radiusSmall ?? this.radiusSmall,
    );
  }

  @override
  AppTokens lerp(AppTokens? other, double t) {
    if (other is! AppTokens) return this;
    return AppTokens(
      accent: Color.lerp(accent, other.accent, t)!,
      onAccent: Color.lerp(onAccent, other.onAccent, t)!,
      bg: Color.lerp(bg, other.bg, t)!,
      bgElev: Color.lerp(bgElev, other.bgElev, t)!,
      solid: Color.lerp(solid, other.solid, t)!,
      solidHigh: Color.lerp(solidHigh, other.solidHigh, t)!,
      ink: Color.lerp(ink, other.ink, t)!,
      inkMuted: Color.lerp(inkMuted, other.inkMuted, t)!,
      inkFaint: Color.lerp(inkFaint, other.inkFaint, t)!,
      hair: Color.lerp(hair, other.hair, t)!,
      hairSoft: Color.lerp(hairSoft, other.hairSoft, t)!,
      glassFill: Color.lerp(glassFill, other.glassFill, t)!,
      glassFillStrong: Color.lerp(glassFillStrong, other.glassFillStrong, t)!,
      glassHair: Color.lerp(glassHair, other.glassHair, t)!,
      glassBlur: lerpDouble(glassBlur, other.glassBlur, t)!,
      radius: lerpDouble(radius, other.radius, t)!,
      radiusSmall: lerpDouble(radiusSmall, other.radiusSmall, t)!,
    );
  }
}

/// Material 3 theme wired to [AppTokens]. Dark-first — Harbor's remote surface
/// is a dark, TV-adjacent UI.
abstract final class AppTheme {
  /// Token defaults. The Accent is swapped here (one line) to re-skin the app.
  static const tokens = AppTokens();

  static ThemeData get dark {
    final t = tokens;
    final scheme = ColorScheme(
      brightness: Brightness.dark,
      primary: t.accent,
      onPrimary: t.onAccent,
      primaryContainer: t.accentFill,
      onPrimaryContainer: t.accentInk,
      secondary: t.inkMuted,
      onSecondary: t.onAccent,
      secondaryContainer: t.glassFillStrong,
      onSecondaryContainer: t.ink,
      error: const Color(0xFFFF7A85),
      onError: const Color(0xFF26060A),
      surface: t.bg,
      onSurface: t.ink,
      surfaceContainerLowest: t.bg,
      surfaceContainerLow: t.bgElev,
      surfaceContainer: t.solid,
      surfaceContainerHigh: t.solid,
      surfaceContainerHighest: t.solidHigh,
      onSurfaceVariant: t.inkMuted,
      outline: t.inkFaint,
      outlineVariant: t.hair,
      surfaceTint: Colors.transparent,
      scrim: Colors.black,
    );

    final base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: t.bg,
      extensions: [t],
      appBarTheme: AppBarTheme(
        backgroundColor: t.bg,
        foregroundColor: t.ink,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w600,
          color: t.ink,
        ),
        iconTheme: IconThemeData(color: t.ink),
        shape: Border(bottom: BorderSide(color: t.hairSoft)),
      ),
      dividerTheme: DividerThemeData(color: t.hairSoft, thickness: 1, space: 1),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? t.accentInk
              : const Color(0xFFE8E8EE),
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? t.accentFill
              : const Color(0x29FFFFFF),
        ),
        trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: t.accent,
          foregroundColor: t.onAccent,
          disabledBackgroundColor: t.glassFill,
          disabledForegroundColor: t.inkFaint,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(t.radiusSmall),
          ),
          textStyle: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: t.ink,
          side: BorderSide(color: t.hair),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(t.radiusSmall),
          ),
          textStyle: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: t.accentInk,
          textStyle: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: t.accent,
        foregroundColor: t.onAccent,
        elevation: 2,
      ),
      inputDecorationTheme: InputDecorationThemeData(
        filled: true,
        fillColor: t.glassFill,
        // Labels and hints read over the field's translucent fill, so they use
        // the AA step (issue #91); inkFaint stays reserved for decoration.
        labelStyle: TextStyle(color: t.inkMuted),
        hintStyle: TextStyle(color: t.inkMuted),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(t.radiusSmall),
          borderSide: BorderSide(color: t.hair),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(t.radiusSmall),
          borderSide: BorderSide(color: t.hair),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(t.radiusSmall),
          borderSide: BorderSide(color: t.accentLine),
        ),
      ),
    );

    return base.copyWith(
      textTheme: base.textTheme
          .apply(bodyColor: t.ink, displayColor: t.ink)
          .copyWith(
            titleLarge: base.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w600,
              color: t.ink,
            ),
            titleMedium: base.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
              color: t.ink,
            ),
          ),
    );
  }
}
