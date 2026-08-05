// Preflight + results for base-safe Review bulk delete (Phase 4).

import 'package:flutter/cupertino.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../core/git/branch_comparison.dart';
import '../../core/git/git_service.dart';
import '../common/escape_dismissible.dart';
import '../common/inline_action_button.dart';
import '../common/sized_sheet.dart';

/// One candidate for base-safe bulk delete.
class BulkDeleteCandidate {
  final String branchName;
  final String fullRef;
  final String expectedOid;
  final String? skipReason; // non-null => excluded from execution

  const BulkDeleteCandidate({
    required this.branchName,
    required this.fullRef,
    required this.expectedOid,
    this.skipReason,
  });
}

/// Shows a preflight table, runs [deleteBranchMergedIntoBase] for each
/// executable candidate, and reports every outcome (never swallows exceptions).
Future<List<BaseDeleteResult>?> showBranchBulkDeleteSheet(
  BuildContext context, {
  required GitService git,
  required String repoPath,
  required String baseOid,
  required String baseDisplayName,
  required List<BulkDeleteCandidate> candidates,
}) {
  return showMacosSheet<List<BaseDeleteResult>>(
    context: context,
    builder: (context) => SizedSheet(
      width: 520,
      height: 480,
      child: _BulkDeleteSheet(
        git: git,
        repoPath: repoPath,
        baseOid: baseOid,
        baseDisplayName: baseDisplayName,
        candidates: candidates,
      ),
    ),
  );
}

class _BulkDeleteSheet extends StatefulWidget {
  final GitService git;
  final String repoPath;
  final String baseOid;
  final String baseDisplayName;
  final List<BulkDeleteCandidate> candidates;

  const _BulkDeleteSheet({
    required this.git,
    required this.repoPath,
    required this.baseOid,
    required this.baseDisplayName,
    required this.candidates,
  });

  @override
  State<_BulkDeleteSheet> createState() => _BulkDeleteSheetState();
}

class _BulkDeleteSheetState extends State<_BulkDeleteSheet> {
  bool _running = false;
  List<BaseDeleteResult>? _results;
  final List<String> _failures = [];

  List<BulkDeleteCandidate> get _executable => [
    for (final c in widget.candidates)
      if (c.skipReason == null) c,
  ];

  List<BulkDeleteCandidate> get _skipped => [
    for (final c in widget.candidates)
      if (c.skipReason != null) c,
  ];

  Future<void> _run() async {
    setState(() {
      _running = true;
      _results = null;
      _failures.clear();
    });
    final results = <BaseDeleteResult>[];
    for (final c in _executable) {
      try {
        final r = await widget.git.deleteBranchMergedIntoBase(
          widget.repoPath,
          branchName: c.branchName,
          expectedBranchOid: c.expectedOid,
          baseOid: widget.baseOid,
        );
        results.add(r);
      } catch (e) {
        _failures.add('${c.branchName}: $e');
        results.add(
          BaseDeleteResult(
            branchName: c.branchName,
            status: BaseDeleteStatus.moved, // placeholder group; see failures
          ),
        );
      }
    }
    if (!mounted) return;
    setState(() {
      _running = false;
      _results = results;
    });
  }

  @override
  Widget build(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    return EscapeDismissible(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Delete merged into ${widget.baseDisplayName}',
              style: typography.title2.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Text(
              'Each branch is OID-pinned and only removed when it is still an '
              'ancestor of the comparison base. Non-ancestors and held '
              'worktrees are skipped — never force-deleted in bulk.',
              style: typography.caption1.copyWith(
                color: MacosColors.systemGrayColor,
              ),
            ),
            const SizedBox(height: 14),
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_results == null) ...[
                      Text(
                        'Will delete (${_executable.length})',
                        style: typography.headline,
                      ),
                      for (final c in _executable)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Text(
                            c.branchName,
                            style: typography.caption1,
                          ),
                        ),
                      if (_skipped.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        Text(
                          'Skipped (${_skipped.length})',
                          style: typography.headline,
                        ),
                        for (final c in _skipped)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2),
                            child: Text(
                              '${c.branchName} — ${c.skipReason}',
                              style: typography.caption1.copyWith(
                                color: MacosColors.systemOrangeColor,
                              ),
                            ),
                          ),
                      ],
                    ] else ...[
                      Text('Results', style: typography.headline),
                      for (final r in _results!)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Text(
                            '${r.branchName}: ${r.status.name}',
                            style: typography.caption1.copyWith(
                              color: r.deleted
                                  ? MacosColors.systemGreenColor
                                  : MacosColors.systemOrangeColor,
                            ),
                          ),
                        ),
                      for (final f in _failures)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Text(
                            f,
                            style: typography.caption1.copyWith(
                              color: MacosColors.systemRedColor,
                            ),
                          ),
                        ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                InlineActionButton(
                  label: _results == null ? 'Cancel' : 'Close',
                  icon: CupertinoIcons.xmark,
                  onPressed: _running
                      ? null
                      : () => Navigator.of(context).pop(_results),
                ),
                if (_results == null) ...[
                  const SizedBox(width: 8),
                  InlineActionButton(
                    label: _running
                        ? 'Deleting…'
                        : 'Delete ${_executable.length}',
                    icon: CupertinoIcons.trash,
                    onPressed: _running || _executable.isEmpty ? null : _run,
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}
