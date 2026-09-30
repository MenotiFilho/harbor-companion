import 'package:flutter/material.dart';

import '../theme.dart';

/// Uppercase, letter-spaced label that opens a group of rows.
class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key, this.topPadding = 24});

  final String title;

  /// Space above the label; the label itself keeps a fixed 6dp below.
  final double topPadding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(top: topPadding, bottom: 6),
      child: Text(
        title.toUpperCase(),
        // Header labels are decorative wayfinding; the body ramp stays AA.
        style: AppTokens.of(context).sectionLabel,
      ),
    );
  }
}
