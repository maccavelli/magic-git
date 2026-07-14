import 'package:flutter/widgets.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../core/gitlab/models.dart';

/// Maps a GitLab CI status to a display color, shared by the pipeline list and
/// the job/trace views. Exhaustive over [CiStatus] (no default), so a newly
/// added status is a compile error here rather than a silent mis-color.
Color ciStatusColor(CiStatus status) => switch (status) {
  CiStatus.success => MacosColors.systemGreenColor,
  CiStatus.failed => MacosColors.systemRedColor,
  // Pre-run/in-progress states GitLab reports before or while a pipeline/job
  // runs — "not started yet"/"working", not a problem. Grouping them keeps a
  // retry (which lands in 'created' first) from flashing the orange used for a
  // genuinely unknown status.
  CiStatus.running ||
  CiStatus.pending ||
  CiStatus.created ||
  CiStatus.waitingForResource ||
  CiStatus.preparing ||
  CiStatus.scheduled => MacosColors.systemBlueColor,
  CiStatus.canceled ||
  CiStatus.skipped ||
  CiStatus.manual => MacosColors.systemGrayColor,
  CiStatus.unknown => MacosColors.systemOrangeColor,
};

// Label color parsing lives in features/common/label_colors.dart — it was
// byte-identical across both forges.
