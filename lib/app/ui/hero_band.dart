import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme.dart';

/// The editorial Hero band (issue #83): a full-width artwork strip with the
/// bottom-up [AppTokens.heroScrim], a kicker, the serif title and one meta
/// line over the art. Reusable by Home now and Detail later (#84).
///
/// The artwork itself is [HeroArtwork]; the tap seam is a plain [onTap], so
/// the band stays free of controller dependencies.
class HeroBand extends StatelessWidget {
  const HeroBand({
    super.key,
    required this.height,
    this.backdropUrl,
    this.posterUrl,
    this.kicker,
    this.title,
    this.meta,
    this.onTap,
    this.padding = const EdgeInsets.fromLTRB(22, 0, 22, 18),
  });

  /// Band height; the Home uses [kHomeHeroHeight]-ish editorial strips.
  final double height;

  /// The wide Backdrop URL (`Meta.background`), preferred when present.
  final String? backdropUrl;

  /// The Poster URL, used as a blurred fill when there is no Backdrop.
  final String? posterUrl;

  /// Small uppercase wayfinding label above the title (e.g. the rail name).
  final String? kicker;

  /// The serif title.
  final String? title;

  /// One secondary line (release info, credits); hidden when absent.
  final String? meta;

  /// Makes the whole band one tap target.
  final VoidCallback? onTap;

  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final text = Theme.of(context).textTheme;
    final kickerText = kicker;
    final titleText = title;
    final metaText = meta;

    final band = SizedBox(
      height: height,
      width: double.infinity,
      child: Stack(
        fit: StackFit.expand,
        children: [
          HeroArtwork(backdropUrl: backdropUrl, posterUrl: posterUrl),
          DecoratedBox(decoration: BoxDecoration(gradient: tokens.heroScrim)),
          Align(
            alignment: Alignment.bottomLeft,
            child: Padding(
              padding: padding,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (kickerText != null && kickerText.isNotEmpty)
                    Text(kickerText.toUpperCase(), style: tokens.sectionLabel),
                  if (titleText != null && titleText.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      titleText,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: tokens.serifTitle,
                    ),
                  ],
                  if (metaText != null && metaText.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      metaText,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodySmall?.copyWith(color: tokens.inkMuted),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );

    if (onTap == null) return band;
    final label = [kickerText, titleText, metaText]
        .whereType<String>()
        .where((line) => line.isNotEmpty)
        .join(', ');
    return Semantics(
      button: true,
      label: label.isEmpty ? 'Open details' : label,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: band,
      ),
    );
  }
}

/// The Hero's artwork with the honest fallback chain (parent #80): the Backdrop
/// when present and decodable, else a blurred fill of the Poster, else a static
/// gradient. Never a [BackdropFilter] — the blur is a child filter, so it never
/// reads the scrolling backdrop (ADR-0010).
class HeroArtwork extends StatelessWidget {
  const HeroArtwork({super.key, this.backdropUrl, this.posterUrl});

  final String? backdropUrl;
  final String? posterUrl;

  @override
  Widget build(BuildContext context) {
    final backdrop = _nonEmpty(backdropUrl);
    if (backdrop != null) {
      return Image.network(
        backdrop,
        key: const ValueKey('heroBackdrop'),
        fit: BoxFit.cover,
        filterQuality: FilterQuality.medium,
        // A failed decode falls back exactly like an absent URL.
        errorBuilder: (_, _, _) => _fallback(context),
      );
    }
    return _fallback(context);
  }

  Widget _fallback(BuildContext context) {
    final poster = _nonEmpty(posterUrl);
    if (poster == null) return const _StaticGradient();
    return ImageFiltered(
      key: const ValueKey('heroPosterBlur'),
      imageFilter: ImageFilter.blur(sigmaX: 32, sigmaY: 32),
      child: Image.network(
        poster,
        fit: BoxFit.cover,
        filterQuality: FilterQuality.low,
        errorBuilder: (_, _, _) => const _StaticGradient(),
      ),
    );
  }
}

String? _nonEmpty(String? value) =>
    value == null || value.isEmpty ? null : value;

/// The last-resort artwork: the prototype's `150deg` dark gradient.
class _StaticGradient extends StatelessWidget {
  const _StaticGradient();

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    return DecoratedBox(
      key: const ValueKey('heroGradient'),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [tokens.solidHigh, tokens.bg],
        ),
      ),
    );
  }
}
