import 'dart:async' show unawaited;

import 'package:flutter/cupertino.dart' hide OverlayVisibilityMode;
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:macos_ui/macos_ui.dart';
import 'package:url_launcher/url_launcher.dart' show launchUrl;

import '../../core/forge/forge_dashboard.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/display_error.dart';
import '../common/buttons.dart';
import '../common/field_styles.dart';
import '../common/label_colors.dart';
import '../common/tappable.dart';
import '../common/tool_icon_button.dart';

/// The Forge workspace's shared widget kit: one row idiom, one detail
/// scaffold, one section-header idiom — used identically by the GitHub and
/// GitLab panels so every forge item (MR/PR, pipeline/run, issue, milestone,
/// release, job) reads as the same family of surfaces.
///
/// Badge palette (semantic, not per-panel): blue = change request, green =
/// issue, grey = draft. CI status dots use the per-forge status colors.

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

/// A list-section header: bold caption title (optionally a disclosure toggle),
/// a grey count caption, then (right-aligned) an optional add button and a
/// refresh button.
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

  /// When non-null the title becomes a disclosure toggle (chevron + click to
  /// collapse/expand); the caller owns the collapsed state and hides the
  /// section body itself.
  final bool? collapsed;
  final VoidCallback? onToggleCollapsed;

  const ForgeSectionHeader(
    this.title, {
    super.key,
    required this.onRefresh,
    this.onAdd,
    this.addTooltip = 'New',
    this.refreshTooltip = 'Refresh',
    this.padding = const EdgeInsets.fromLTRB(16, 8, 8, 4),
    this.count,
    this.collapsed,
    this.onToggleCollapsed,
  });

  @override
  Widget build(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    final titleRow = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (collapsed != null) ...[
          MacosIcon(
            collapsed!
                ? CupertinoIcons.chevron_right
                : CupertinoIcons.chevron_down,
            size: 10,
            color: MacosColors.systemGrayColor,
          ),
          const SizedBox(width: 4),
        ],
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
      ],
    );
    return Padding(
      padding: padding,
      child: Row(
        children: [
          if (onToggleCollapsed != null)
            Tappable(
              onTap: onToggleCollapsed,
              behavior: HitTestBehavior.opaque,
              child: titleRow,
            )
          else
            titleRow,
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

/// A labelled detail row (70px grey label, body value) for the detail
/// scaffold's metadata block.
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
/// its log", "Select an item on the left").
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

/// **The one list-row idiom for every forge item.** Leading badge/dot/icon,
/// a title (1 or 2 lines), an optional grey caption (with an optional CI dot
/// before it), an optional wrap of label chips, and optional trailing widgets
/// (an action button, a grey right-aligned caption). One padding rhythm and
/// one selection tint for every configuration.
class ForgeListRow extends StatelessWidget {
  final Widget? leading;
  final String title;
  final int titleMaxLines;
  final String? caption;

  /// A CI status dot rendered just before [caption].
  final Color? captionDotColor;

  /// Label chips rendered in a wrap under the caption (issues).
  final List<Widget> chips;

  /// Right-aligned grey caption (a milestone's due date, a release's tag).
  final String? trailingCaption;

  /// Trailing action (retry/re-run button).
  final Widget? trailing;

  final bool selected;
  final VoidCallback? onTap;

  /// Opens this item's right-click context menu (PR/MR/issue actions). The
  /// row's inner [Tappable] already carries the hand-cursor + hit-test policy;
  /// this just forwards the secondary-tap through it.
  final GestureTapUpCallback? onSecondaryTapUp;
  final EdgeInsets? padding;

  const ForgeListRow({
    super.key,
    this.leading,
    required this.title,
    this.titleMaxLines = 1,
    this.caption,
    this.captionDotColor,
    this.chips = const [],
    this.trailingCaption,
    this.trailing,
    this.selected = false,
    this.onTap,
    this.onSecondaryTapUp,
    this.padding,
  });

  @override
  Widget build(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    final captionStyle = typography.caption1.copyWith(
      color: MacosColors.systemGrayColor,
    );
    final hasTrailing = trailing != null || trailingCaption != null;
    return Tappable(
      onTap: onTap,
      onSecondaryTapUp: onSecondaryTapUp,
      child: Container(
        color: selected ? AppTheme.rowSelectionTint : const Color(0x00000000),
        // Right inset 8 when a trailing icon must line up flush with the
        // section header's icons; 16 (matching the left) otherwise.
        padding:
            padding ?? EdgeInsets.fromLTRB(16, 7, hasTrailing ? 8 : 16, 7),
        child: Row(
          crossAxisAlignment: titleMaxLines > 1 || chips.isNotEmpty
              ? CrossAxisAlignment.start
              : CrossAxisAlignment.center,
          children: [
            if (leading != null) ...[leading!, const SizedBox(width: 8)],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: typography.body,
                    maxLines: titleMaxLines,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (caption != null) ...[
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        if (captionDotColor != null) ...[
                          MacosIcon(
                            CupertinoIcons.circle_fill,
                            size: 8,
                            color: captionDotColor,
                          ),
                          const SizedBox(width: 5),
                        ],
                        Flexible(
                          child: Text(
                            caption!,
                            style: captionStyle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ],
                  if (chips.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Wrap(spacing: 4, runSpacing: 3, children: chips),
                    ),
                ],
              ),
            ),
            if (trailingCaption != null)
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Text(trailingCaption!, style: captionStyle),
              ),
            ?trailing,
          ],
        ),
      ),
    );
  }
}

/// A CI status dot sized for list-row leading position.
class CiDot extends StatelessWidget {
  final Color color;
  final double size;

  const CiDot(this.color, {super.key, this.size = 10});

  @override
  Widget build(BuildContext context) =>
      MacosIcon(CupertinoIcons.circle_fill, size: size, color: color);
}

/// One row in a jobs column: status dot, job name, grey caption. A
/// [ForgeListRow] configuration with the narrower jobs-column padding.
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
    return ForgeListRow(
      leading: CiDot(dotColor, size: 9),
      title: name,
      caption: caption,
      selected: selected,
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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

/// Opens a forge item's web page in the default browser (fire-and-forget:
/// NSWorkspace either opens it or it doesn't, no recovery worth a dialog).
/// No-op when [url] is null/empty or unparseable. Shared by the context menus
/// and the [OpenInBrowserButton].
void forgeOpenUrl(String? url) {
  if (url == null || url.isEmpty) return;
  final uri = Uri.tryParse(url);
  if (uri != null) unawaited(launchUrl(uri));
}

/// Copies [text] to the clipboard (fire-and-forget) — a forge item's URL or
/// its `#123`/`!45` reference, from the right-click menu.
void forgeCopy(String text) =>
    unawaited(Clipboard.setData(ClipboardData(text: text)));

/// The header icon that opens a forge item's web page in the default browser.
/// Hidden (not disabled) when no URL could be determined.
class OpenInBrowserButton extends StatelessWidget {
  final String? url;

  const OpenInBrowserButton(this.url, {super.key});

  @override
  Widget build(BuildContext context) {
    final url = this.url;
    if (url == null || url.isEmpty) return const SizedBox.shrink();
    return ToolIconButton(
      icon: CupertinoIcons.arrow_up_right_square,
      tooltip: 'Open in browser',
      size: 15,
      onPressed: () {
        final uri = Uri.tryParse(url);
        // Fire-and-forget: NSWorkspace either opens the browser or it
        // doesn't; there's no recovery worth a dialog here.
        if (uri != null) unawaited(launchUrl(uri));
      },
    );
  }
}

/// **The one detail-pane shape for every forge item.** Header band (leading
/// badge/dot/icon + title + trailing header actions), the [DetailLine]
/// metadata block, a separator, the scrollable/filling body — and, when the
/// item has mutations, a pinned action bar along the bottom, so Check out /
/// Approve / Merge live in the same place for every item type.
class ForgeDetailScaffold extends StatelessWidget {
  final Widget? leading;
  final String title;

  /// Header-trailing cluster: open-in-browser, retry — icon-sized actions
  /// that belong to the item as a whole.
  final List<Widget> headerActions;

  /// [DetailLine]s and chip wraps under the title.
  final List<Widget> lines;

  /// Fills the area between header and action bar. Null renders nothing
  /// (an item with no body content).
  final Widget? body;

  /// Pinned bottom action bar (buttons). Empty → no bar.
  final List<Widget> actions;

  const ForgeDetailScaffold({
    super.key,
    this.leading,
    required this.title,
    this.headerActions = const [],
    this.lines = const [],
    this.body,
    this.actions = const [],
  });

  @override
  Widget build(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 12, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (leading != null) ...[leading!, const SizedBox(width: 8)],
                  Expanded(
                    child: Text(
                      title,
                      style: typography.title3,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  ...headerActions,
                ],
              ),
              if (lines.isNotEmpty) ...[
                const SizedBox(height: 10),
                ...lines,
              ],
            ],
          ),
        ),
        Container(height: 1, color: MacosColors.separatorColor),
        Expanded(child: body ?? const SizedBox.shrink()),
        if (actions.isNotEmpty) ...[
          Container(height: 1, color: MacosColors.separatorColor),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: actions,
            ),
          ),
        ],
      ],
    );
  }
}

/// The filter field at the top of the Forge list column: one query scoping
/// every section at once (titles, branches, refs, labels).
class ForgeFilterField extends StatelessWidget {
  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  const ForgeFilterField({
    super.key,
    required this.controller,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
      child: MacosTextField(
        controller: controller,
        placeholder: 'Filter',
        clearButtonMode: OverlayVisibilityMode.editing,
        decoration: kAppTextFieldDecoration,
        focusedDecoration: kAppTextFieldFocusedDecoration,
        onChanged: onChanged,
      ),
    );
  }
}

/// A full-size label chip (the Labels section), colored from the forge's
/// palette, with the label description as a tooltip.
class ForgeLabelChip extends StatelessWidget {
  final ForgeLabel label;

  const ForgeLabelChip(this.label, {super.key});

  @override
  Widget build(BuildContext context) {
    final bg = parseLabelColor(label.color);
    final chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        label.name,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: labelTextColor(bg),
        ),
      ),
    );
    final description = label.description;
    if (description == null || description.isEmpty) return chip;
    return MacosTooltip(message: description, child: chip);
  }
}

/// A compact chip for a label attached to an issue row/detail, colored from
/// the project palette when the label is among the fetched ones (else neutral
/// gray).
class MiniLabelChip extends StatelessWidget {
  final String name;
  final ForgeLabel? label;

  const MiniLabelChip(this.name, this.label, {super.key});

  @override
  Widget build(BuildContext context) {
    final bg = label == null
        ? const Color(0xFF888888)
        : parseLabelColor(label!.color);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        name,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: labelTextColor(bg),
        ),
      ),
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
