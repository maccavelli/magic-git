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

  void _move(int i, int delta) {
    final j = i + delta;
    if (j < 0 || j >= _rows.length) return;
    setState(() {
      final r = _rows.removeAt(i);
      _rows.insert(j, r);
      // The first commit has nothing to fold into, so it can't squash/fixup.
      if (_rows.first.action == RebaseAction.squash ||
          _rows.first.action == RebaseAction.fixup) {
        _rows.first.action = RebaseAction.pick;
      }
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
                'Reorder and choose an action for each commit (top = oldest). '
                'Squash/Fixup fold a commit into the one above it.',
                style: typography.caption1.copyWith(
                  color: MacosColors.systemGrayColor,
                ),
              ),
            ),
            Container(height: 1, color: MacosColors.separatorColor),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(vertical: 6),
                itemCount: _rows.length,
                itemBuilder: (context, i) => _row(context, i),
              ),
            ),
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

  Widget _row(BuildContext context, int i) {
    final typography = MacosTheme.of(context).typography;
    final r = _rows[i];
    final dropped = r.action == RebaseAction.drop;
    final canFold = i > 0; // the first row has nothing above to fold into
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
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
                    onTap: () => setState(() => r.action = a),
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
