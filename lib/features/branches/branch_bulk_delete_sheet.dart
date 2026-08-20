// Preflight + results for base-safe Review bulk delete (Phase 4).

import 'package:flutter/cupertino.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../core/git/branch_comparison.dart';
import '../../core/git/branch_review_query.dart';
import '../../core/git/git_service.dart';
import '../common/escape_dismissible.dart';
import '../common/inline_action_button.dart';
import '../common/labeled_controls.dart';
import '../common/sized_sheet.dart';

/// One candidate for base-safe bulk delete.
class BulkDeleteCandidate {
  final String branchName;
  final String fullRef;
  final String expectedOid;
  final String? skipReason; // non-null => excluded from execution

  /// Ahead/behind against the comparison base, when a summary was available.
  final int? aheadOfBase;

  /// Forge protection. Deliberately tri-state: "we could not find out" must
  /// not read as "safe to delete".
  final ProtectionKnowledge protection;

  /// An open request's label (`#42` / `!42`), when the forge said so.
  final String? requestLabel;

  const BulkDeleteCandidate({
    required this.branchName,
    required this.fullRef,
    required this.expectedOid,
    this.skipReason,
    this.aheadOfBase,
    this.protection = const ProtectionKnowledge.unknown(),
    this.requestLabel,
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
      width: 640,
      height: 520,
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

  /// Rows the user has explicitly unchecked. Eligible-but-unchecked is a
  /// third state: the preflight used to partition only on skipReason, so a
  /// user who wanted to drop one branch from a batch had to cancel and redo
  /// the whole selection.
  final Set<String> _unchecked = {};

  /// Eligible AND still checked — what Delete will actually run on.
  List<BulkDeleteCandidate> get _executable => [
    for (final c in widget.candidates)
      if (c.skipReason == null && !_unchecked.contains(c.fullRef)) c,
  ];

  /// Eligible, regardless of the checkbox.
  List<BulkDeleteCandidate> get _eligible => [
    for (final c in widget.candidates)
      if (c.skipReason == null) c,
  ];

  /// Eligible rows whose forge protection could not be determined. Their
  /// delete may still be refused by the server; say so rather than implying
  /// the preflight cleared them.
  List<BulkDeleteCandidate> get _unknownProtection => [
    for (final c in _executable)
      if (c.protection.isUnknown) c,
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
                      if (_unknownProtection.isNotEmpty) ...[
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: MacosColors.systemOrangeColor.withValues(
                              alpha: 0.12,
                            ),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            'Forge protection could not be verified for '
                            '${_unknownProtection.length} of these branches. '
                            'A protected branch will be refused by the server '
                            'even though it passed this preflight.',
                            style: typography.caption1,
                          ),
                        ),
                        const SizedBox(height: 12),
                      ],
                      Text(
                        'Will delete (${_executable.length})',
                        style: typography.headline,
                      ),
                      const SizedBox(height: 4),
                      for (final c in _eligible)
                        _PreflightRow(
                          candidate: c,
                          checked: !_unchecked.contains(c.fullRef),
                          onChanged: (v) => setState(() {
                            v
                                ? _unchecked.remove(c.fullRef)
                                : _unchecked.add(c.fullRef);
                          }),
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

/// One preflight row: the checkbox plus the facts that decide whether this
/// delete will succeed — tip, distance from base, forge protection, and any
/// open request that would be orphaned.
class _PreflightRow extends StatelessWidget {
  final BulkDeleteCandidate candidate;
  final bool checked;
  final ValueChanged<bool> onChanged;

  const _PreflightRow({
    required this.candidate,
    required this.checked,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    final caption = typography.caption1.copyWith(
      color: MacosColors.systemGrayColor,
    );
    final facts = <String>[
      candidate.expectedOid.substring(0, 7),
      if (candidate.aheadOfBase != null) '↑${candidate.aheadOfBase}',
      switch (candidate.protection) {
        ProtectionProtected() => 'protected',
        ProtectionUnprotected() => 'unprotected',
        ProtectionUnknown() => 'protection unknown',
      },
      if (candidate.requestLabel != null) candidate.requestLabel!,
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(
            child: LabeledCheckbox(
              label: candidate.branchName,
              value: checked,
              onChanged: onChanged,
              style: typography.caption1,
              expand: true,
            ),
          ),
          Text(facts.join('  ·  '), style: caption),
        ],
      ),
    );
  }
}
