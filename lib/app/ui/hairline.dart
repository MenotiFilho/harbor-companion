import 'package:flutter/material.dart';

import '../theme.dart';

/// A 1 logical-pixel separator line.
///
/// [soft] picks the quieter row hairline (`--hair-2`); the default is the
/// standard hairline. Purely decorative — no semantics.
class Hairline extends StatelessWidget {
  const Hairline({
    super.key,
    this.soft = false,
    this.indent = 0,
    this.endIndent = 0,
  });

  final bool soft;
  final double indent;
  final double endIndent;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    return Container(
      height: 1,
      margin: EdgeInsetsDirectional.only(start: indent, end: endIndent),
      color: soft ? tokens.hairSoft : tokens.hair,
    );
  }
}
