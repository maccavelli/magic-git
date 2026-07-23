import 'package:flutter/cupertino.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../core/git/git_service.dart';
import '../dnd/drag_item.dart';
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
      // parseRefs now drops symrefs at the source (via %(symref)); this stays
      // as belt-and-braces for refs that arrive from any other path.
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

  /// When true, branch chips can be dragged onto a commit (or another branch)
  /// to merge/rebase — the History view opts in; the reflog and other read-only
  /// surfaces leave it off.
  final bool enableDrag;

  /// Beyond this, chips collapse into a `+N`. Two full-name chips leave room
  /// for the subject in the 420px commit pane; a third would overflow the row.
  static const int maxVisible = 2;

  final int? _maxVisibleOverride;
  int get effectiveMaxVisible => _maxVisibleOverride ?? maxVisible;

  /// Soft cap on a single chip's width so one long name cannot dominate the row.
  static const double maxChipWidth = 132;

  const RefChipStrip({
    super.key,
    required this.refs,
    this.enableDrag = false,
    int? maxVisible,
  }) : _maxVisibleOverride = maxVisible;

  @override
  Widget build(BuildContext context) {
    final visible = filterHistoryRefDecorations(refs);
    if (visible.isEmpty) return const SizedBox.shrink();

    final shown = visible.take(effectiveMaxVisible).toList();
    final hidden = visible.sublist(shown.length);

    // Intrinsic row: each chip caps its own width ([maxChipWidth]) and long
    // names ellipsize inside. Do NOT wrap chips in Flexible here — a flex
    // child of a min-sized / right-aligned strip can collapse to zero width
    // (the history pop-out showed subjects with no badges at all).
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final r in shown) RefChip(gitRef: r, enableDrag: enableDrag),
        if (hidden.isNotEmpty)
          MacosTooltip(
            message: hidden.map((r) => refDecorationTooltip(r)).join('\n'),
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

  /// When true and this chip is a branch (local or remote), it becomes a
  /// [Draggable] carrying its [GitRef] so it can be dropped on a commit to
  /// merge/rebase. Tags and worktree-pinned branches are never draggable.
  final bool enableDrag;

  const RefChip({super.key, required this.gitRef, this.enableDrag = false});

  @override
  Widget build(BuildContext context) {
    final (color, icon) = _style(gitRef);
    final label = refDecorationLabel(gitRef);

    final tooltipped = MacosTooltip(
      message: refDecorationTooltip(gitRef),
      child: _chip(color, icon, label),
    );

    // Only real branches are integration operands.
    final draggable = enableDrag && (gitRef.isLocalBranch || gitRef.isRemote);
    if (!draggable) return tooltipped;

    // Immediate (mouse-first) drag. The ghost is the engine's canonical lift
    // cell — a snapshot of this chip in the rounded elevated cell, consistent
    // with every other drag surface.
    return DragItemDraggable(
      item: DragRef(gitRef),
      immediate: true,
      child: tooltipped,
    );
  }

  // Width is hard-capped by [RefChipStrip.maxChipWidth]; the label ellipsizes
  // rather than vanishing into an icon-only badge. Full name always lives on the
  // tooltip. Built on demand so the same chrome can back both the resting chip
  // and the drag feedback (one widget can't appear in the tree twice).
  Widget _chip(Color color, IconData icon, String label) => _RefChipChrome(
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
    // Bounded max width is what lets the inner Row's Flexible text ellipsize
    // without a flex ancestor on the strip itself.
    return Container(
      margin: const EdgeInsets.only(left: 4),
      constraints: const BoxConstraints(maxWidth: RefChipStrip.maxChipWidth),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.42), width: 0.6),
      ),
      child: child,
    );
  }
}
