import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';
import '../../core/git/git_service.dart';
import '../../core/output/output_log.dart';
import '../../core/providers/app_providers.dart';
import '../../core/utils/display_error.dart';
import '../common/actions.dart';
import '../common/sized_sheet.dart';
import '../common/tool_icon_button.dart';

/// Visual interactive-rebase editor: reorder commits, and set each to pick,
/// squash (fold into the previous, keeping both messages), fixup (fold and drop
/// its message), or drop. Runs headlessly via [GitService.rebaseInteractive].
/// [commits] are oldest→newest; [onto] is the parent the oldest is rebased onto.
class RebaseSheet extends ConsumerStatefulWidget {
  final String repoPath;
  final String onto;
  final List<GitCommit> commits;
  const RebaseSheet({
    super.key,
    required this.repoPath,
    required this.onto,
    required this.commits,
  });

  @override
  ConsumerState<RebaseSheet> createState() => _RebaseSheetState();
}

class _Row {
  RebaseAction action;
  final GitCommit commit;
  _Row(this.action, this.commit);
}

class _RebaseSheetState extends ConsumerState<RebaseSheet> {
  late final List<_Row> _rows = [
    for (final c in widget.commits) _Row(RebaseAction.pick, c),
  ];
  bool _busy = false;

  static const _actions = [
    RebaseAction.pick,
    RebaseAction.squash,
    RebaseAction.fixup,
    RebaseAction.drop,
  ];

  static String _label(RebaseAction a) => switch (a) {
    RebaseAction.pick => 'Pick',
    RebaseAction.squash => 'Squash',
    RebaseAction.fixup => 'Fixup',
    RebaseAction.drop => 'Drop',
  };

  /// A squash/fixup folds into the nearest NON-DROPPED commit above it — so the
  /// first *kept* row (not merely the first row) has nothing to fold into. The
  /// generated todo omits drop lines entirely, and git rejects a todo that
  /// starts with `squash`/`fixup` ("cannot 'squash' without a previous commit"),
  /// so any edit that leaves the first kept row folding is normalized to pick.
  /// Runs after every mutation: moves, drops onto rows, and action changes.
  void _normalizeRows() {
    for (final r in _rows) {
      if (r.action == RebaseAction.drop) continue;
      if (r.action == RebaseAction.squash || r.action == RebaseAction.fixup) {
        r.action = RebaseAction.pick;
      }
      break; // only the first kept row is constrained
    }
  }

  /// Whether row [i] has any kept (non-dropped) commit above it to fold into —
  /// gates the Squash/Fixup menu entries and the squash drop target.
  bool _canFoldAt(int i) =>
      _rows.take(i).any((r) => r.action != RebaseAction.drop);

  void _move(int i, int delta) {
    final j = i + delta;
    if (j < 0 || j >= _rows.length) return;
    setState(() {
      final r = _rows.removeAt(i);
      _rows.insert(j, r);
      _normalizeRows();
    });
  }

  /// Dropping a commit into the gap [slot] (0..n) reorders it there. Slots
  /// [from] and [from]+1 straddle the commit's own position, so they're no-ops.
  bool _isReorderNoop(int from, int slot) => slot == from || slot == from + 1;

  void _reorderTo(int from, int slot) {
    if (_busy || _isReorderNoop(from, slot)) return;
    setState(() {
      final r = _rows.removeAt(from);
      // Removing shifts everything after `from` down one, so a slot past it
      // lands one index earlier than its raw value.
      _rows.insert(slot > from ? slot - 1 : slot, r);
      _normalizeRows();
    });
  }

  /// Dropping commit [dragged] onto commit [target] folds it in: it moves to sit
  /// immediately below [target] and is marked squash (keep both messages). The
  /// user can switch it to fixup via the row's action menu. The drop target
  /// rejects dropped rows — folding "into" a dropped commit would actually fold
  /// into whatever kept commit sits above it, which is not what the drop said.
  void _squashInto(int dragged, int target) {
    if (_busy || dragged == target) return;
    setState(() {
      final r = _rows.removeAt(dragged);
      // `target`'s index after the removal, then insert just below it.
      final t = dragged < target ? target - 1 : target;
      _rows.insert(t + 1, r);
      r.action = RebaseAction.squash;
      _normalizeRows();
    });
  }

  /// Interactive rebase is the highest-risk action reachable from this sheet
  /// — it can squash or drop several commits in one shot — so, like the
  /// Repository panel's Reset/Amend/Revert, it confirms before running.
  Future<void> _apply() async {
    final dropped = _rows.where((r) => r.action == RebaseAction.drop).length;
    final folded = _rows
        .where(
          (r) =>
              r.action == RebaseAction.squash || r.action == RebaseAction.fixup,
        )
        .length;
    final effects = <String>[
      if (dropped > 0) 'drop $dropped commit${dropped == 1 ? '' : 's'}',
      if (folded > 0) 'fold $folded commit${folded == 1 ? '' : 's'}',
    ];
    final onto = widget.onto.length > 10
        ? widget.onto.substring(0, 10)
        : widget.onto;
    final ok = await confirmAction(
      context,
      title: 'Rebase',
      message: effects.isEmpty
          ? 'Reorder ${_rows.length} commit${_rows.length == 1 ? '' : 's'} '
                'onto $onto? This rewrites history — avoid it if these '
                'commits are already pushed.'
          : 'This will ${effects.join(' and ')}, rewriting history onto '
                '$onto. Avoid this if these commits are already pushed.',
      confirmLabel: 'Rebase',
    );
    if (!ok || !mounted) return;

    setState(() => _busy = true);
    final steps = [for (final r in _rows) RebaseStep(r.action, r.commit.hash)];
    final label = 'git rebase -i $onto';
    final log = ref.read(outputLogProvider.notifier);
    try {
      log.logResult(
        label,
        await ref
            .read(gitServiceProvider)
            .rebaseInteractive(widget.repoPath, widget.onto, steps),
      );
    } on GitException catch (e) {
      // A conflict leaves the rebase in progress; close so the user can resolve
      // it via the Repository panel's rebase banner, but surface the message.
      log.logResult(label, e.result);
      if (mounted) await showErrorDialog(context, displayError(e));
    } catch (e) {
      log.logError(label, e.toString());
      if (mounted) await showErrorDialog(context, displayError(e));
    } finally {
      // Whatever happened, refresh the repo-scoped views — guarded as one
      // unit: the sheet can be gone (repo switch, disconnect) by the time
      // this rebase resolves, and `ref` throws if touched after disposal.
      if (mounted) {
        for (final p in repoMutationFamilies(widget.repoPath)) {
          ref.invalidate(p);
        }
        Navigator.of(context).pop();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    final screen = MediaQuery.sizeOf(context);
    final keepCount = _rows.where((r) => r.action != RebaseAction.drop).length;
    return SizedSheet(
      width: kSheetWidth,
      height: (screen.height * 0.72).clamp(400.0, 820.0).toDouble(),
      child: SizedBox(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 14, 6),
              child: Row(
                children: [
                  const MacosIcon(CupertinoIcons.wand_stars, size: 16),
                  const SizedBox(width: 8),
                  Text('Interactive rebase', style: typography.title3),
                  const Spacer(),
                  ToolIconButton(
                    icon: CupertinoIcons.xmark,
                    tooltip: 'Cancel',
                    size: 16,
                    onPressed: _busy ? null : () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 8),
              child: Text(
                'Drag a commit to reorder it, or drop it onto another to squash '
                'them together (top = oldest). Squash/Fixup fold a commit into '
                'the one above it.',
                style: typography.caption1.copyWith(
                  color: MacosColors.systemGrayColor,
                ),
              ),
            ),
            Container(height: 1, color: MacosColors.separatorColor),
            Expanded(child: _list(context)),
            Container(height: 1, color: MacosColors.separatorColor),
            Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      keepCount == 0
                          ? 'All commits dropped'
                          : '$keepCount commit${keepCount == 1 ? '' : 's'} after rebase',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: typography.caption1.copyWith(
                        color: MacosColors.systemGrayColor,
                      ),
                    ),
                  ),
                  PushButton(
                    controlSize: ControlSize.large,
                    secondary: true,
                    onPressed: _busy ? null : () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 10),
                  PushButton(
                    controlSize: ControlSize.large,
                    onPressed: (_busy || keepCount == 0) ? null : _apply,
                    child: _busy
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: ProgressCircle(radius: 8),
                          )
                        : const Text('Rebase'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The commit list, interleaving reorder gaps and draggable rows:
  /// gap 0, row 0, gap 1, row 1, …, row n-1, gap n. Each gap is a reorder drop
  /// target (insertion line); each row is both draggable and a squash target.
  Widget _list(BuildContext context) {
    final children = <Widget>[];
    for (var i = 0; i < _rows.length; i++) {
      children.add(_gap(i));
      children.add(_row(context, i));
    }
    children.add(_gap(_rows.length));
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 2),
      children: children,
    );
  }

  /// A reorder drop target between rows. Idle it's just spacing; while a commit
  /// hovers it shows a blue insertion line. Rejects the two slots that straddle
  /// the dragged commit's own position (dropping there wouldn't move it).
  Widget _gap(int slot) {
    return DragTarget<int>(
      onWillAcceptWithDetails: (d) => !_busy && !_isReorderNoop(d.data, slot),
      onAcceptWithDetails: (d) => _reorderTo(d.data, slot),
      builder: (context, candidate, rejected) {
        final active = candidate.isNotEmpty;
        return KeyedSubtree(
          key: ValueKey('rebase-gap-$slot'),
          child: SizedBox(
            height: 12,
            child: Center(
              child: Container(
                height: active ? 3 : 0,
                margin: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: MacosColors.systemBlueColor,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// A draggable commit row that is also a squash drop target: dropping another
  /// commit onto it folds that commit in (green highlight while hovering).
  Widget _row(BuildContext context, int i) {
    final content = _rowContent(context, i);
    return Draggable<int>(
      // Immediate (mouse-first) drag: on macOS list scrolling is wheel/trackpad
      // events, so click-drag steals nothing; disabled while a rebase runs.
      data: i,
      maxSimultaneousDrags: _busy ? 0 : 1,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: _ghost(context, i),
      childWhenDragging: Opacity(opacity: 0.35, child: content),
      child: DragTarget<int>(
        // A dropped (struck-through) row can't be a squash target — the fold
        // would really land on the kept commit above it, not this one.
        onWillAcceptWithDetails: (d) =>
            !_busy && d.data != i && _rows[i].action != RebaseAction.drop,
        onAcceptWithDetails: (d) => _squashInto(d.data, i),
        builder: (context, candidate, rejected) {
          final active = candidate.isNotEmpty;
          return KeyedSubtree(
            key: ValueKey('rebase-row-$i'),
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                color: active
                    ? MacosColors.systemGreenColor.withValues(alpha: 0.16)
                    : null,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: active
                      ? MacosColors.systemGreenColor.withValues(alpha: 0.6)
                      : const Color(0x00000000),
                ),
              ),
              child: content,
            ),
          );
        },
      ),
    );
  }

  /// The pointer-anchored drag ghost — the commit being moved.
  Widget _ghost(BuildContext context, int i) {
    final c = _rows[i].commit;
    final typography = MacosTheme.of(context).typography;
    return Transform.translate(
      offset: const Offset(8, 8),
      child: Opacity(
        opacity: 0.92,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: const Color(0xFF2C2C2E),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: MacosColors.separatorColor),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const MacosIcon(
                    CupertinoIcons.arrow_up_arrow_down,
                    size: 13,
                    color: MacosColors.systemGrayColor,
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      '${c.shortHash}  ${c.subject}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: typography.caption1,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _rowContent(BuildContext context, int i) {
    final typography = MacosTheme.of(context).typography;
    final r = _rows[i];
    final dropped = r.action == RebaseAction.drop;
    // Fold needs a kept commit above — "row 0" isn't enough once rows above
    // can be dropped ([drop, squash] generates a todo starting with squash,
    // which git rejects).
    final canFold = _canFoldAt(i);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
      child: Row(
        children: [
          Column(
            children: [
              _MiniButton(
                icon: CupertinoIcons.chevron_up,
                onPressed: (i == 0 || _busy) ? null : () => _move(i, -1),
              ),
              _MiniButton(
                icon: CupertinoIcons.chevron_down,
                onPressed: (i == _rows.length - 1 || _busy)
                    ? null
                    : () => _move(i, 1),
              ),
            ],
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 120,
            child: MacosPulldownButton(
              title: _label(r.action),
              items: [
                for (final a in _actions)
                  MacosPulldownMenuItem(
                    enabled:
                        canFold ||
                        (a != RebaseAction.squash && a != RebaseAction.fixup),
                    title: Text(_label(a)),
                    // Normalize after ANY action change: dropping a row can
                    // orphan a squash below it as the new first kept row.
                    onTap: () => setState(() {
                      r.action = a;
                      _normalizeRows();
                    }),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  r.commit.subject,
                  style: typography.body.copyWith(
                    color: dropped ? MacosColors.systemGrayColor : null,
                    decoration: dropped ? TextDecoration.lineThrough : null,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  r.commit.shortHash,
                  style: typography.caption1.copyWith(
                    color: MacosColors.systemGrayColor,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MiniButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onPressed;
  const _MiniButton({required this.icon, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return MacosIconButton(
      icon: MacosIcon(
        icon,
        size: 12,
        color: onPressed == null ? MacosColors.systemGrayColor : null,
      ),
      padding: const EdgeInsets.all(2),
      boxConstraints: const BoxConstraints(minWidth: 20, minHeight: 16),
      onPressed: onPressed,
    );
  }
}
