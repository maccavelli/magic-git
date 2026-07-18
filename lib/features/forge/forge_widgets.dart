import 'package:flutter/cupertino.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/display_error.dart';
import '../common/buttons.dart';
import '../common/tool_icon_button.dart';

/// Small widgets shared by the GitHub and GitLab panels and their jobs views.
/// These were byte-identical private copies in the two forge features (the
/// panels are deliberately parallel); one definition here keeps them that way.

/// The colored pill badge (`#123`, `!45`, `DRAFT`): [color] at a 15% fill with
/// the same color as bold caption text.
class StatusBadge extends StatelessWidget {
  final String text;
  final Color color;

  const StatusBadge(this.text, this.color, {super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: color),
      ),
    );
  }
}

/// A list-section header: bold caption title, then (right-aligned) an optional
/// add button and a refresh button. The panels use the default padding; the
/// narrower jobs columns pass their own.
class ForgeSectionHeader extends StatelessWidget {
  final String title;
  final VoidCallback onRefresh;
  final VoidCallback? onAdd;
  final String addTooltip;
  final String refreshTooltip;
  final EdgeInsets padding;

  /// Optional grey count caption after the title (`"30 of 974"`), so a section
  /// whose fetch is capped says so instead of silently truncating.
  final String? count;

  const ForgeSectionHeader(
    this.title, {
    super.key,
    required this.onRefresh,
    this.onAdd,
    this.addTooltip = 'New',
    this.refreshTooltip = 'Refresh',
    this.padding = const EdgeInsets.fromLTRB(16, 8, 8, 4),
    this.count,
  });

  @override
  Widget build(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    return Padding(
      padding: padding,
      child: Row(
        children: [
          Text(
            title,
            style: typography.caption1.copyWith(fontWeight: FontWeight.bold),
          ),
          if (count != null)
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: Text(
                count!,
                style: typography.caption1.copyWith(
                  color: MacosColors.systemGrayColor,
                ),
              ),
            ),
          const Spacer(),
          if (onAdd != null)
            ToolIconButton(
              icon: CupertinoIcons.add,
              tooltip: addTooltip,
              size: 15,
              onPressed: onAdd,
            ),
          ToolIconButton(
            icon: CupertinoIcons.refresh,
            tooltip: refreshTooltip,
            size: 15,
            onPressed: onRefresh,
          ),
        ],
      ),
    );
  }
}

/// A labelled detail row (70px grey label, body value) for the PR/MR detail
/// header.
class DetailLine extends StatelessWidget {
  final String label;
  final String value;

  const DetailLine(this.label, this.value, {super.key});

  @override
  Widget build(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 70,
            child: Text(
              label,
              style: typography.caption1.copyWith(
                color: MacosColors.systemGrayColor,
              ),
            ),
          ),
          Expanded(child: Text(value, style: typography.body)),
        ],
      ),
    );
  }
}

/// Centered red error text for a failed pane load, humanized via
/// [displayError].
class PaneError extends StatelessWidget {
  final Object error;

  const PaneError(this.error, {super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          displayError(error),
          style: MacosTheme.of(
            context,
          ).typography.body.copyWith(color: MacosColors.systemRedColor),
        ),
      ),
    );
  }
}

/// Centered grey hint for a pane with nothing selected ("Select a job to view
/// its log", "Select a pull request or workflow run").
class CenteredHint extends StatelessWidget {
  final String text;

  const CenteredHint(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        text,
        style: MacosTheme.of(
          context,
        ).typography.body.copyWith(color: MacosColors.systemGrayColor),
      ),
    );
  }
}

/// One row in a jobs column: status dot, job name, grey caption; highlighted
/// when selected.
class JobRow extends StatelessWidget {
  final String name;
  final String caption;
  final Color dotColor;
  final bool selected;
  final VoidCallback onTap;

  const JobRow({
    super.key,
    required this.name,
    required this.caption,
    required this.dotColor,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        color: selected ? AppTheme.rowSelectionTint : const Color(0x00000000),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            MacosIcon(CupertinoIcons.circle_fill, size: 9, color: dotColor),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    style: typography.body,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    caption,
                    style: typography.caption1.copyWith(
                      color: MacosColors.systemGrayColor,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Spinner-or-icon-button: the row/header affordance for a mutation that may
/// be in flight (retry pipeline, re-run failed jobs).
class InFlightIconButton extends StatelessWidget {
  final bool busy;
  final IconData icon;
  final String tooltip;
  final double size;
  final Color color;
  final VoidCallback onPressed;

  const InFlightIconButton({
    super.key,
    required this.busy,
    required this.icon,
    required this.tooltip,
    required this.size,
    required this.color,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    if (busy) {
      return SizedBox(width: size, height: size, child: const ProgressCircle());
    }
    return ToolIconButton(
      icon: icon,
      tooltip: tooltip,
      size: size,
      color: color,
      onPressed: onPressed,
    );
  }
}

/// Spinner-or-push-button for the detail pane's mutation actions
/// (Check out / Approve / Merge).
class InFlightPushButton extends StatelessWidget {
  final bool busy;
  final String label;
  final bool secondary;
  final VoidCallback onPressed;

  const InFlightPushButton({
    super.key,
    required this.busy,
    required this.label,
    required this.onPressed,
    this.secondary = false,
  });

  @override
  Widget build(BuildContext context) {
    if (busy) return const ProgressCircle();
    return AppPushButton(
      controlSize: ControlSize.large,
      secondary: secondary,
      onPressed: onPressed,
      child: Text(label),
    );
  }
}

/// A left-pane PR/MR row: badge, two-line title, then an optional CI dot
/// beside the `source → target` caption.
class ChangeRequestRow extends StatelessWidget {
  final Widget badge;
  final String title;
  final String branches;
  final Color? ciDotColor;
  final bool selected;
  final VoidCallback onTap;

  const ChangeRequestRow({
    super.key,
    required this.badge,
    required this.title,
    required this.branches,
    required this.selected,
    required this.onTap,
    this.ciDotColor,
  });

  @override
  Widget build(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        color: selected ? AppTheme.rowSelectionTint : const Color(0x00000000),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            badge,
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: typography.body,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      if (ciDotColor != null) ...[
                        MacosIcon(
                          CupertinoIcons.circle_fill,
                          size: 8,
                          color: ciDotColor,
                        ),
                        const SizedBox(width: 5),
                      ],
                      Flexible(
                        child: Text(
                          branches,
                          style: typography.caption1.copyWith(
                            color: MacosColors.systemGrayColor,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A left-pane CI run/pipeline row: status dot, title (with an optional grey
/// caption line beneath), and an optional trailing affordance (retry).
///
/// The right inset matches the section headers so every trailing icon lines
/// up flush against the same right margin.
class CiRunRow extends StatelessWidget {
  final Color dotColor;
  final String title;
  final String? caption;
  final bool selected;
  final VoidCallback onTap;
  final Widget? trailing;

  const CiRunRow({
    super.key,
    required this.dotColor,
    required this.title,
    required this.selected,
    required this.onTap,
    this.caption,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        color: selected ? AppTheme.rowSelectionTint : const Color(0x00000000),
        padding: const EdgeInsets.fromLTRB(16, 7, 8, 7),
        child: Row(
          children: [
            MacosIcon(CupertinoIcons.circle_fill, size: 10, color: dotColor),
            const SizedBox(width: 8),
            Expanded(
              child: caption == null
                  ? Text(
                      title,
                      style: typography.body,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: typography.body,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          caption!,
                          style: typography.caption1.copyWith(
                            color: MacosColors.systemGrayColor,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
            ),
            ?trailing,
          ],
        ),
      ),
    );
  }
}

/// The main pane's CI detail header: status dot, title, an optional trailing
/// action, then a separator line. The body (jobs view) is the caller's.
class CiDetailHeader extends StatelessWidget {
  final Color dotColor;
  final String title;
  final Widget? trailing;

  const CiDetailHeader({
    super.key,
    required this.dotColor,
    required this.title,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
          child: Row(
            children: [
              MacosIcon(CupertinoIcons.circle_fill, size: 11, color: dotColor),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: typography.title3,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              ?trailing,
            ],
          ),
        ),
        Container(height: 1, color: MacosColors.separatorColor),
      ],
    );
  }
}

/// The main pane's PR/MR detail: badge + title, the [DetailLine]s, the action
/// buttons row, then a separator line.
class ChangeRequestDetail extends StatelessWidget {
  final Widget badge;
  final String title;
  final List<Widget> lines;
  final List<Widget> actions;

  const ChangeRequestDetail({
    super.key,
    required this.badge,
    required this.title,
    required this.lines,
    required this.actions,
  });

  @override
  Widget build(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  badge,
                  const SizedBox(width: 8),
                  Expanded(child: Text(title, style: typography.title3)),
                ],
              ),
              const SizedBox(height: 10),
              ...lines,
              const SizedBox(height: 16),
              // Wrap, not Row: the detail pane's width is user-controlled now
              // (the panel divider drags), so the action buttons must flow to
              // a second line in a narrow pane instead of overflowing.
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: actions,
              ),
            ],
          ),
        ),
        Container(height: 1, color: MacosColors.separatorColor),
      ],
    );
  }
}

/// The monospace style CI log panes render with, on [AppTheme.terminalBackground].
const kJobLogStyle = TextStyle(
  fontFamily: 'Menlo',
  fontFamilyFallback: ['SF Mono', 'Consolas', 'monospace'],
  fontSize: 12,
  height: 1.35,
  color: Color(0xFFE0E0E0),
);

/// Muted grey used inside the dark log panes (placeholders, "No log output.").
const kLogMutedColor = Color(0xFF9E9E9E);
