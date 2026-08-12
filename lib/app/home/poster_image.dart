// Shared poster image widget (ticket 04).
//
// Renders a poster URL through `Image.network` with a dark fallback for null or
// failed loads. Used by the Home rails and the detail page so the two don't
// duplicate the poster/errorBuilder logic.

import 'package:flutter/material.dart';

/// A poster that fills its parent, falling back to a dark placeholder when the
/// URL is absent or fails to decode.
class PosterImage extends StatelessWidget {
  final String? url;
  final BoxFit fit;
  const PosterImage({super.key, required this.url, this.fit = BoxFit.cover});

  @override
  Widget build(BuildContext context) {
    final poster = url;
    if (poster == null || poster.isEmpty) {
      return const ColoredBox(color: Colors.black26);
    }
    return Image.network(
      poster,
      fit: fit,
      filterQuality: FilterQuality.medium,
      errorBuilder: (_, _, _) => const ColoredBox(color: Colors.black26),
    );
  }
}
