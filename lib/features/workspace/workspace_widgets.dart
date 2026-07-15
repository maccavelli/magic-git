import 'package:flutter/cupertino.dart';
import 'package:macos_ui/macos_ui.dart';
import '../common/tool_icon_button.dart';

/// Inline error/warning banner shared by the clone/create sheets.
class WorkspaceBanner extends StatelessWidget {
  final String message;
  final bool error;
  const WorkspaceBanner(this.message, {super.key, this.error = false});

  @override
  Widget build(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    final color = error
        ? MacosColors.systemRedColor
        : MacosColors.systemOrangeColor;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            MacosIcon(
              CupertinoIcons.exclamationmark_triangle,
              size: 14,
              color: color,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message,
                style: typography.caption1,
                // Multi-paragraph create-repo warnings; wrap rather than
                // force a fixed-height overflow in the wizard footer.
                softWrap: true,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Icon-toggle + caption row (fsmonitor / create-parents / save toggles),
/// matching the Add Repository sheet's affordance.
class WorkspaceToggleRow extends StatelessWidget {
  final bool on;
  final VoidCallback onTap;
  final IconData onIcon;
  final IconData offIcon;
  final String label;

  const WorkspaceToggleRow({
    super.key,
    required this.on,
    required this.onTap,
    required this.onIcon,
    required this.offIcon,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    return Row(
      children: [
        ToolIconButton(
          icon: on ? onIcon : offIcon,
          tooltip: on ? '$label (on)' : '$label (off)',
          size: 15,
          color: on ? MacosColors.systemBlueColor : MacosColors.systemGrayColor,
          onPressed: onTap,
        ),
        const SizedBox(width: 8),
        Expanded(child: Text(label, style: typography.caption1)),
      ],
    );
  }
}
