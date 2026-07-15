import 'package:flutter/cupertino.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../core/git/git_service.dart';
import '../worktrees/worktree_tabs.dart';

/// Prepare refs for display on a history (or reflog) row.
///
/// Drops noise that Tower / Fork / GitHub Desktop also suppress:
///  * remote-tracking refs that only echo a local branch already on this
///    commit (`origin/main` when `main` is present),
///  * `*/HEAD` remote symrefs (not a real branch tip the user cares about).
///
/// Reorders to HEAD → local branches → tags → remotes so the most actionable
/// labels win the limited chip slots.
List<GitRef> filterHistoryRefDecorations(List<GitRef> refs) {
  if (refs.isEmpty) return const [];

  final localNames = <String>{
    for (final r in refs)
      if (r.isLocalBranch) r.shortName,
  };

  final filtered = <GitRef>[];
  for (final r in refs) {
    if (r.isRemote) {
      final short = r.shortName;
      // origin/HEAD, upstream/HEAD — symbolic defaults, not useful chips.
      if (short.endsWith('/HEAD') || short == 'HEAD') continue;
      final slash = short.indexOf('/');
      if (slash > 0) {
        final branch = short.substring(slash + 1);
        // Local already names this tip — remote is redundant chrome.
        if (localNames.contains(branch)) continue;
      }
    }
    filtered.add(r);
  }

  int rank(GitRef r) {
    if (r.isHead) return 0;
    if (r.isLocalBranch) return 1;
    if (r.isTag) return 2;
    return 3; // remote
  }

  filtered.sort((a, b) {
    final byRank = rank(a).compareTo(rank(b));
    if (byRank != 0) return byRank;
    return a.shortName.compareTo(b.shortName);
  });
  return filtered;
}

/// Human-readable tooltip for a ref decoration chip.
String refDecorationTooltip(GitRef ref) {
  if (ref.isTag) return 'Tag ${ref.shortName}';
  if (ref.isRemote) return 'Remote branch ${ref.shortName}';
  if (ref.isCheckedOutElsewhere) {
    final wt = ref.worktreePath!;
    return 'Branch ${ref.shortName}\n${checkedOutElsewhereMessage(wt)}';
  }
  if (ref.isHead && ref.isLocalBranch) {
    return 'HEAD → ${ref.shortName} (checked out here)';
  }
  if (ref.isLocalBranch) return 'Local branch ${ref.shortName}';
  return ref.shortName;
}

/// Label text painted on the chip. Always a real name — never icon-only.
///
/// HEAD is a green branch chip that keeps the branch name (Tower / Fork style:
/// you always see *which* branch is checked out). Detached HEAD is rare in
/// for-each-ref output; if it appears, [shortName] still identifies it.
String refDecorationLabel(GitRef ref) {
  if (ref.isHead && ref.isLocalBranch) return ref.shortName;
  return ref.shortName;
}

/// The chips decorating one commit, laid out so they can never overflow the
/// commit list's right edge.
///
/// The commit list has a FIXED row height (`itemExtent`) — the graph painter
/// draws lane edges that must line up between adjacent rows, and the minimap
/// maps commits to y-positions assuming uniform rows. So chips cannot wrap onto
/// a second line; they have to fit on one.
///
/// Chips sit after the subject (see [HistoryView]) with intrinsic width and a
/// per-chip max so long names ellipsize *with a tooltip*, never collapse to an
/// icon alone. Past [maxVisible] the rest collapse into a `+N` chip that lists
/// every hidden ref on hover.
class RefChipStrip extends StatelessWidget {
  final List<GitRef> refs;

  /// Beyond this, chips collapse into a `+N`. Two full-name chips leave room
  /// for the subject in the 420px commit pane; a third crowded out labels into
  /// icon-only ellipses (the complaint that motivated the redesign).
  static const int maxVisible = 2;

  /// Soft cap on a single chip's width so one long name cannot dominate the row.
  static const double maxChipWidth = 132;

  const RefChipStrip({super.key, required this.refs});

  @override
  Widget build(BuildContext context) {
    final visible = filterHistoryRefDecorations(refs);
    if (visible.isEmpty) return const SizedBox.shrink();

    final shown = visible.take(maxVisible).toList();
    final hidden = visible.sublist(shown.length);

    // Flexible chips share the strip's max width so two long names ellipsize
    // instead of overflowing the history row (the strip itself sits in a
    // Flexible in HistoryView). +N stays intrinsic — it's always short.
    return Row(
      children: [
        for (final r in shown)
          Flexible(
            child: Align(
              alignment: Alignment.centerRight,
              child: RefChip(gitRef: r),
            ),
          ),
        if (hidden.isNotEmpty)
          MacosTooltip(
            message: hidden
                .map((r) => refDecorationTooltip(r))
                .join('\n'),
            child: _RefChipChrome(
              color: MacosColors.systemGrayColor,
              child: Text(
                '+${hidden.length}',
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: MacosColors.systemGrayColor,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// A colored label for a branch / remote / tag decorating a commit.
///
/// Always shows the ref's short name (not an icon alone), always has a
/// tooltip summarizing kind + name, and only uses the worktree purple style
/// when the branch is checked out elsewhere.
class RefChip extends StatelessWidget {
  final GitRef gitRef;

  const RefChip({super.key, required this.gitRef});

  @override
  Widget build(BuildContext context) {
    final (color, icon) = _style(gitRef);
    final label = refDecorationLabel(gitRef);
    // Width is capped both by [RefChipStrip.maxChipWidth] and by any Flex
    // ancestor; the label ellipsizes rather than vanishing into an icon-only
    // badge. Full name always lives on the tooltip.
    final chip = _RefChipChrome(
      color: color,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          MacosIcon(icon, size: 11, color: color),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: color,
                letterSpacing: -0.1,
              ),
            ),
          ),
        ],
      ),
    );

    return MacosTooltip(
      message: refDecorationTooltip(gitRef),
      child: chip,
    );
  }

  (Color, IconData) _style(GitRef ref) {
    if (ref.isTag) {
      return (MacosColors.systemOrangeColor, CupertinoIcons.tag_fill);
    }
    if (ref.isRemote) {
      return (MacosColors.systemGrayColor, CupertinoIcons.cloud);
    }
    // Checked out in another worktree — purple + worktree glyph, matching
    // the Branches panel badge.
    if (ref.isCheckedOutElsewhere) {
      return (MacosColors.systemPurpleColor, kWorktreeIcon);
    }
    // Local branch; HEAD is green so the current tip is glanceable.
    return (
      ref.isHead ? MacosColors.systemGreenColor : MacosColors.systemBlueColor,
      CupertinoIcons.arrow_branch,
    );
  }
}

/// Shared pill chrome for named ref chips and the `+N` overflow chip.
class _RefChipChrome extends StatelessWidget {
  final Color color;
  final Widget child;

  const _RefChipChrome({required this.color, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(left: 4),
      constraints: const BoxConstraints(
        maxWidth: RefChipStrip.maxChipWidth,
        // Keep a readable floor so a squeezed Flexible still shows more than
        // an icon (tooltip carries the full name either way).
        minWidth: 36,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: color.withValues(alpha: 0.42),
          width: 0.6,
        ),
      ),
      child: child,
    );
  }
}
