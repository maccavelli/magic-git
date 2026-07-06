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

/// Parses a GitLab label color (`#RRGGBB`) into a [Color], defaulting to gray.
Color parseLabelColor(String hex) {
  final h = hex.replaceFirst('#', '').trim();
  // Only a full 6-digit RRGGBB is a valid GitLab label color; force it opaque
  // (0xFF alpha). Anything else (e.g. a 3-digit `#abc` shorthand) would parse
  // *without* an alpha byte — `Color(0x00000abc)`, fully transparent → an
  // invisible chip — so fall back to gray instead. Mirrors the correct
  // length==6 gate in create_mr_sheet.dart's `_hexColor`.
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
