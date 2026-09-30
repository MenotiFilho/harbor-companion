import 'package:flutter/material.dart';

import '../theme.dart';

/// A segmented-control pill (issue #91): the shared segment used by the
/// Library's section selector and the Detail's season selector.
///
/// The pill is 42dp tall visually, but the whole 48dp cell is the touch
/// target — the 3+3 vertical padding lives *inside* the detector, so the
/// a11y floor (parent #80) holds without enlarging the drawn pill. The
/// selected segment reads in the Accent family; the unselected labels are
/// informative text over the glass fill, so they use the AA ink step rather
/// than the decorative `inkFaint`.
class SegmentPill extends StatelessWidget {
  const SegmentPill({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.labelPadding = 0,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  /// Horizontal inset of the label inside the pill. `0` lets the parent
  /// stretch the pill across its slot (the Library's equal-width selector);
  /// the Detail's intrinsic-width pills use a comfortable inset.
  final double labelPadding;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    return Semantics(
      button: true,
      selected: selected,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox(
          height: 48,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Container(
              alignment: Alignment.center,
              padding: EdgeInsets.symmetric(horizontal: labelPadding),
              decoration: BoxDecoration(
                color: selected ? tokens.accentFill : Colors.transparent,
                borderRadius: BorderRadius.circular(tokens.radiusSmall - 3),
                border: Border.all(
                  color: selected ? tokens.accentLine : Colors.transparent,
                ),
              ),
              child: Text(
                label,
                maxLines: 1,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: selected ? tokens.accentInk : tokens.inkMuted,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
