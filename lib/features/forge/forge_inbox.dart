import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';

import '../common/async_views.dart';
import '../common/tappable.dart';
import '../common/tool_icon_button.dart';
import 'forge_prefs.dart';

/// The Forge Inbox: one triage list over everything that needs attention —
/// open MRs/PRs, failing or still-running CI, open issues — with pin (float
/// to top) and snooze (sink to a bottom group), GitKraken-Launchpad style but
/// native. The Browse mode's sections remain one segmented-control click
/// away; both render into the same master list column and drive the same
/// selection/detail pane.

enum ForgeInboxKind { changeRequest, ci, issue }

/// One inbox candidate: a stable per-repo [itemKey] (`mr:7`, `ci:100`,
/// `issue:12`) and a row builder taking the pin/snooze trailing buttons the
/// inbox appends.
class ForgeInboxEntry {
  final String itemKey;
  final ForgeInboxKind kind;
  final Widget Function(List<Widget> trailingExtras) build;

  const ForgeInboxEntry({
    required this.itemKey,
    required this.kind,
    required this.build,
  });
}

/// Merges a row's own trailing widget (retry button) with the inbox's
/// appended pin/snooze buttons.
Widget? forgeCombineTrailing(Widget? own, List<Widget> extras) {
  if (extras.isEmpty) return own;
  return Row(
    mainAxisSize: MainAxisSize.min,
    children: [?own, ...extras],
  );
}

/// The Inbox | Browse mode switch: a compact two-segment pill. Hand-built on
/// the widget kit (macos_ui's segmented control needs a tab controller and
/// keeps the arrow cursor; this follows the app's cursor canon).
class ForgeModeSwitch extends StatelessWidget {
  final bool inbox;
  final ValueChanged<bool> onChanged;

  const ForgeModeSwitch({
    super.key,
    required this.inbox,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 8, 2),
      child: Row(
        children: [
          _segment(context, 'Inbox', inbox, () => onChanged(true)),
          const SizedBox(width: 4),
          _segment(context, 'Browse', !inbox, () => onChanged(false)),
        ],
      ),
    );
  }

  Widget _segment(
    BuildContext context,
    String label,
    bool active,
    VoidCallback onTap,
  ) {
    final typography = MacosTheme.of(context).typography;
    return Tappable(
      onTap: active ? null : onTap,
      cursor: active ? SystemMouseCursors.basic : SystemMouseCursors.click,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        decoration: BoxDecoration(
          color: active
              ? MacosColors.systemBlueColor.withValues(alpha: 0.18)
              : const Color(0x00000000),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          label,
          style: typography.caption1.copyWith(
            fontWeight: active ? FontWeight.bold : FontWeight.normal,
            color: active ? MacosColors.systemBlueColor : null,
          ),
        ),
      ),
    );
  }
}

/// The Inbox's type-filter chips (All / MRs|PRs / CI / Issues).
class _TypeChip extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;

  const _TypeChip({
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    return Tappable(
      onTap: active ? null : onTap,
      cursor: active ? SystemMouseCursors.basic : SystemMouseCursors.click,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: active
              ? MacosColors.systemGrayColor.withValues(alpha: 0.25)
              : MacosColors.systemGrayColor.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          label,
          style: typography.caption1.copyWith(
            fontWeight: active ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ),
    );
  }
}

/// The Inbox list, as children for the panel's master ListView: type chips,
/// pinned group, the main list, and a dimmed Snoozed group at the bottom.
/// [entries] arrive pre-filtered by the panel's shared filter field and in
/// the panel's presentation order (change requests, then CI, then issues).
List<Widget> forgeInboxChildren({
  required WidgetRef ref,
  required String repoPath,
  required List<ForgeInboxEntry> entries,
  required ForgeInboxKind? typeFilter,
  required ValueChanged<ForgeInboxKind?> onTypeFilter,
  required String changeRequestLabel,
  required bool listsReady,
}) {
  final marks = ref.watch(forgeInboxMarksProvider(repoPath));
  final marksNotifier = ref.read(forgeInboxMarksProvider(repoPath).notifier);

  final visible = typeFilter == null
      ? entries
      : [
          for (final e in entries)
            if (e.kind == typeFilter) e,
        ];
  final pinned = [
    for (final e in visible)
      if (marks.pinned.contains(e.itemKey)) e,
  ];
  final snoozed = [
    for (final e in visible)
      if (marks.snoozed.contains(e.itemKey)) e,
  ];
  final normal = [
    for (final e in visible)
      if (!marks.pinned.contains(e.itemKey) &&
          !marks.snoozed.contains(e.itemKey))
        e,
  ];

  Widget row(ForgeInboxEntry e) => e.build([
    ToolIconButton(
      icon: marks.pinned.contains(e.itemKey)
          ? CupertinoIcons.pin_fill
          : CupertinoIcons.pin,
      tooltip: marks.pinned.contains(e.itemKey) ? 'Unpin' : 'Pin to top',
      size: 13,
      onPressed: () => marksNotifier.togglePin(e.itemKey),
    ),
    ToolIconButton(
      icon: CupertinoIcons.moon_zzz,
      tooltip: marks.snoozed.contains(e.itemKey) ? 'Unsnooze' : 'Snooze',
      size: 13,
      onPressed: () => marksNotifier.toggleSnooze(e.itemKey),
    ),
  ]);

  Widget groupLabel(String text) => Builder(
    builder: (context) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 2),
      child: Text(
        text,
        style: MacosTheme.of(context).typography.caption1.copyWith(
          fontWeight: FontWeight.bold,
          color: MacosColors.systemGrayColor,
        ),
      ),
    ),
  );

  return [
    Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 8, 6),
      child: Wrap(
        spacing: 5,
        runSpacing: 4,
        children: [
          _TypeChip(
            label: 'All',
            active: typeFilter == null,
            onTap: () => onTypeFilter(null),
          ),
          _TypeChip(
            label: changeRequestLabel,
            active: typeFilter == ForgeInboxKind.changeRequest,
            onTap: () => onTypeFilter(ForgeInboxKind.changeRequest),
          ),
          _TypeChip(
            label: 'CI',
            active: typeFilter == ForgeInboxKind.ci,
            onTap: () => onTypeFilter(ForgeInboxKind.ci),
          ),
          _TypeChip(
            label: 'Issues',
            active: typeFilter == ForgeInboxKind.issue,
            onTap: () => onTypeFilter(ForgeInboxKind.issue),
          ),
        ],
      ),
    ),
    if (!listsReady)
      const SectionLoading()
    else if (visible.isEmpty)
      const SectionEmpty('Inbox zero — nothing needs attention')
    else ...[
      if (pinned.isNotEmpty) ...[
        groupLabel('Pinned'),
        for (final e in pinned) row(e),
      ],
      for (final e in normal) row(e),
      if (snoozed.isNotEmpty) ...[
        groupLabel('Snoozed'),
        for (final e in snoozed) Opacity(opacity: 0.55, child: row(e)),
      ],
    ],
  ];
}
