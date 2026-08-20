import 'package:flutter/widgets.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../core/github/models.dart';

/// Maps a GitHub Actions run/job state to a display color, shared by the
/// workflow-run list and the run-jobs view. Exhaustive over [GhRunState] (no
/// default), so a newly added state is a compile error here rather than a
/// silent mis-color. Mirrors GitLab's `ciStatusColor` palette.
Color ghRunStateColor(GhRunState state) => switch (state) {
  GhRunState.success => MacosColors.systemGreenColor,
  GhRunState.failure => MacosColors.systemRedColor,
  // In-flight states — "working"/"not started", not a problem.
  GhRunState.running || GhRunState.pending => MacosColors.systemBlueColor,
  GhRunState.canceled ||
  GhRunState.skipped ||
  GhRunState.neutral => MacosColors.systemGrayColor,
  // Waiting on a human (a required review / deployment approval), or a state we
  // don't recognize — both worth the attention-grabbing orange.
  GhRunState.actionRequired ||
  GhRunState.unknown => MacosColors.systemOrangeColor,
};

// Label color parsing lives in features/common/label_colors.dart — it was
// byte-identical across both forges.
