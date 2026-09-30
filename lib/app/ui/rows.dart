import 'package:flutter/material.dart';

import '../theme.dart';
import 'hairline.dart';

/// The shared row rhythm (issue #81): a >= 48dp touch target with an optional
/// leading icon, a title/subtitle stack and an optional trailing control,
/// separated from the next row by the soft hairline.
class ListRow extends StatelessWidget {
  const ListRow({
    super.key,
    this.leading,
    required this.title,
    this.titleMaxLines,
    this.subtitle,
    this.subtitleColor,
    this.trailing,
    this.onTap,
    this.divider = true,
  });

  final Widget? leading;
  final String title;

  /// Caps the title to this many lines with an ellipsis; null lets it wrap.
  final int? titleMaxLines;

  final String? subtitle;

  /// Overrides the subtitle ink (e.g. the Accent for an active state).
  final Color? subtitleColor;

  final Widget? trailing;
  final VoidCallback? onTap;

  /// Draws the soft hairline at the bottom of the row.
  final bool divider;

  @override
  Widget build(BuildContext context) {
    return _RowFrame(
      leading: leading,
      title: title,
      titleMaxLines: titleMaxLines,
      subtitle: subtitle,
      subtitleColor: subtitleColor,
      trailing: trailing,
      onTap: onTap,
      divider: divider,
    );
  }
}

/// The new switch line: the same rhythm as [ListRow] with a Material [Switch]
/// styled by the theme. The whole row toggles, so the tap target is the full
/// width, never just the thumb.
class SwitchRow extends StatelessWidget {
  const SwitchRow({
    super.key,
    required this.title,
    this.subtitle,
    required this.value,
    required this.onChanged,
    this.leading,
    this.divider = true,
  });

  final String title;
  final String? subtitle;
  final bool value;

  /// Null renders the row disabled.
  final ValueChanged<bool>? onChanged;

  final Widget? leading;
  final bool divider;

  @override
  Widget build(BuildContext context) {
    return _RowFrame(
      leading: leading,
      title: title,
      subtitle: subtitle,
      onTap: onChanged == null ? null : () => onChanged!(!value),
      divider: divider,
      mergeSemantics: true,
      trailing: Switch(value: value, onChanged: onChanged),
    );
  }
}

/// A key/value line for host facts; the key is quieter than the value.
///
/// Both steps are informative text on a glass surface, so they use the AA
/// ramp (issue #91): the key [AppTokens.inkMuted], the value
/// [AppTokens.ink] — `inkFaint` stays reserved for decoration.
class InfoRow extends StatelessWidget {
  const InfoRow({super.key, required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final text = Theme.of(context).textTheme.bodySmall;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: text?.copyWith(color: tokens.inkMuted)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: text?.copyWith(color: tokens.ink),
            ),
          ),
        ],
      ),
    );
  }
}

/// The row scaffolding both [ListRow] and [SwitchRow] render into.
class _RowFrame extends StatelessWidget {
  const _RowFrame({
    this.leading,
    required this.title,
    this.titleMaxLines,
    this.subtitle,
    this.subtitleColor,
    this.trailing,
    this.onTap,
    required this.divider,
    this.mergeSemantics = false,
  });

  final Widget? leading;
  final String title;
  final int? titleMaxLines;
  final String? subtitle;
  final Color? subtitleColor;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool divider;
  final bool mergeSemantics;

  @override
  Widget build(BuildContext context) {
    final row = InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(
            children: [
              if (leading != null) ...[leading!, const SizedBox(width: 14)],
              Expanded(
                child: _RowText(
                  title: title,
                  titleMaxLines: titleMaxLines,
                  subtitle: subtitle,
                  subtitleColor: subtitleColor,
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: 12),
                trailing!,
              ],
            ],
          ),
        ),
      ),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        mergeSemantics ? MergeSemantics(child: row) : row,
        if (divider) const Hairline(soft: true),
      ],
    );
  }
}

/// Title/subtitle stack shared by [ListRow] and [SwitchRow].
class _RowText extends StatelessWidget {
  const _RowText({
    required this.title,
    this.titleMaxLines,
    this.subtitle,
    this.subtitleColor,
  });

  final String title;
  final int? titleMaxLines;
  final String? subtitle;
  final Color? subtitleColor;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final text = Theme.of(context).textTheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          maxLines: titleMaxLines,
          overflow:
              titleMaxLines == null ? null : TextOverflow.ellipsis,
          style: text.bodyMedium?.copyWith(
            color: tokens.ink,
            fontWeight: FontWeight.w500,
          ),
        ),
        if (subtitle != null)
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Text(
              subtitle!,
              style: text.bodySmall?.copyWith(
                color: subtitleColor ?? tokens.inkMuted,
                height: 1.45,
              ),
            ),
          ),
      ],
    );
  }
}
