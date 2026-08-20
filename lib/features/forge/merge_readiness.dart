import 'package:flutter/cupertino.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../core/forge/merge_plan.dart';
import '../common/inline_action_button.dart';

/// Compact readiness strip for PR/MR detail: ready / blocked reasons / checking.
class MergeReadinessStrip extends StatelessWidget {
  final MergePlan plan;
  final bool detailLoading;
  final VoidCallback? onRetry;

  const MergeReadinessStrip({
    super.key,
    required this.plan,
    this.detailLoading = false,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final secondary =
        MacosTheme.of(context).typography.body.color?.withValues(alpha: 0.7) ??
        MacosColors.systemGrayColor;
    // While detail is in flight, Checking wins over ANY list-tier verdict:
    // list JSON has no mergeable/mergeStateStatus, so a list-tier plan's
    // canMergeNow is "not hard-blocked", never "Ready" (0009 H10).
    if (detailLoading) {
      return _row(
        icon: CupertinoIcons.clock,
        color: secondary,
        text: 'Checking mergeability…',
        trailing: null,
      );
    }

    if (plan.autoMergeAlreadyEnabled) {
      return _row(
        icon: CupertinoIcons.timer,
        color: MacosColors.systemOrangeColor,
        text: 'Auto-merge is enabled — will merge when requirements are met.',
        trailing: null,
      );
    }

    if (plan.canMergeNow) {
      return _row(
        icon: CupertinoIcons.checkmark_circle_fill,
        color: MacosColors.systemGreenColor,
        text: 'Ready to merge',
        trailing: null,
      );
    }

    if (plan.blockedReasons.isEmpty) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final r in plan.blockedReasons)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: _row(
              icon: CupertinoIcons.exclamationmark_triangle_fill,
              color: MacosColors.systemOrangeColor,
              text: r.message,
              trailing: r.code == 'mergeability_unknown' && onRetry != null
                  ? InlineActionButton(
                      label: 'Retry',
                      icon: CupertinoIcons.arrow_clockwise,
                      onPressed: onRetry,
                    )
                  : null,
            ),
          ),
        if (plan.canEnableAutoMerge)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              'You can enable auto-merge to land this when checks finish.',
              style: TextStyle(fontSize: 12, color: secondary),
            ),
          ),
      ],
    );
  }

  Widget _row({
    required IconData icon,
    required Color color,
    required String text,
    required Widget? trailing,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 6),
        Expanded(
          child: Text(text, style: TextStyle(fontSize: 12, color: color)),
        ),
        ?trailing,
      ],
    );
  }
}
