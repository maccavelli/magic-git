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
  GhRunState.actionRequired || GhRunState.unknown =>
    MacosColors.systemOrangeColor,
};

/// Parses a GitHub label color (`#RRGGBB`; GhLabel already prefixes the `#`)
/// into a [Color], defaulting to gray. See GitLab's `parseLabelColor`.
Color parseLabelColor(String hex) {
  final h = hex.replaceFirst('#', '').trim();
  if (h.length != 6) return MacosColors.systemGrayColor;
  final value = int.tryParse(h, radix: 16);
  return value == null
      ? MacosColors.systemGrayColor
      : Color(0xFF000000 | value);
}

/// Chooses readable foreground (black/white) for a label background color.
Color labelTextColor(Color background) => background.computeLuminance() > 0.5
    ? const Color(0xFF000000)
    : const Color(0xFFFFFFFF);
