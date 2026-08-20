/// Pure VoiceOver / semantics labels for Branches list rows (Phase 6).
library;

import '../../core/forge/branch_forge_status.dart';
import '../../core/git/git_service.dart';

/// Builds a single accessible label for a local branch row.
String branchRowSemanticsLabel({
  required GitRef branch,
  required bool selected,
  required bool multiSelected,
  required int? position,
  required int? count,
  BranchForge? forge,
  bool merged = false,
  String? baseDisplayName,
}) {
  final parts = <String>[
    branch.shortName,
    'local branch',
    if (branch.isHead) 'current',
    if (selected || multiSelected) 'selected',
    if (branch.elsewhereWorktreePath != null) 'checked out in another worktree',
    if (merged)
      baseDisplayName != null ? 'merged into $baseDisplayName' : 'merged',
    if (forge != null && forge.hasRequest)
      '${forge.requestDraft ? 'draft ' : ''}'
          '${forge.isMr ? 'merge' : 'pull'} request ${forge.requestLabel}',
    if (forge?.ci != null) 'CI ${_ciSpoken(forge!.ci!)}',
    if (position != null && count != null) 'item $position of $count',
  ];
  return parts.join(', ');
}

String remoteBranchSemanticsLabel({
  required GitRef branch,
  required bool selected,
  required int? position,
  required int? count,
}) {
  final parts = <String>[
    branch.shortName,
    'remote branch',
    if (selected) 'selected',
    if (position != null && count != null) 'item $position of $count',
  ];
  return parts.join(', ');
}

String tagSemanticsLabel({
  required GitRef tag,
  required bool selected,
  required int? position,
  required int? count,
}) {
  final parts = <String>[
    tag.shortName,
    'tag',
    if (selected) 'selected',
    if (position != null && count != null) 'item $position of $count',
  ];
  return parts.join(', ');
}

String _ciSpoken(ForgeCi c) => switch (c) {
  ForgeCi.success => 'passing',
  ForgeCi.failure => 'failing',
  ForgeCi.running => 'running',
  ForgeCi.canceled => 'canceled',
  ForgeCi.skipped => 'skipped',
  ForgeCi.unknown => 'unknown',
};

/// Stable non-color-only glyph for CI (used with color + tooltip text).
String forgeCiGlyph(ForgeCi c) => switch (c) {
  ForgeCi.success => '✓',
  ForgeCi.failure => '✕',
  ForgeCi.running => '…',
  ForgeCi.canceled => '⊘',
  ForgeCi.skipped => '–',
  ForgeCi.unknown => '?',
};
