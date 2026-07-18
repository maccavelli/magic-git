import 'package:flutter/cupertino.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../core/forge/forge_dashboard.dart';
import 'label_colors.dart';
import 'tappable.dart';

/// The create-sheet "Labels" field: a caption plus a wrap of toggleable
/// label chips. This widget existed as byte-identical twins in the PR and MR
/// create sheets (modulo the `GhLabel`/`Label` model split the shared
/// [ForgeLabel] absorbed). Selection state stays with the caller: pass the
/// currently selected names and receive taps via [onToggle].
class LabelPickerField extends StatelessWidget {
  final List<ForgeLabel> labels;
  final Set<String> selected;
  final ValueChanged<String> onToggle;

  const LabelPickerField({
    super.key,
    required this.labels,
    required this.selected,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Labels',
            style: typography.caption1.copyWith(
              color: MacosColors.systemGrayColor,
            ),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [for (final l in labels) _chip(l)],
          ),
        ],
      ),
    );
  }

  Widget _chip(ForgeLabel label) {
    final isSelected = selected.contains(label.name);
    final color =
        tryParseLabelColor(label.color) ?? MacosColors.systemBlueColor;
    return Tappable(
      onTap: () => onToggle(label.name),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: isSelected ? 0.28 : 0.10),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isSelected ? color : MacosColors.separatorColor,
          ),
        ),
        child: Text(
          label.name,
          style: TextStyle(
            fontSize: 11,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
            color: color,
          ),
        ),
      ),
    );
  }
}
