import 'package:flutter/material.dart';
import 'package:macos_ui/macos_ui.dart';

/// Magic Git is a **dark-only** app by deliberate design: the diff, commit-graph,
/// and CI-log surfaces are code/terminal views tuned for a dark canvas (their
/// backgrounds and syntax contrast are baked to it). Rather than ship a
/// half-tuned light theme, we pin dark and keep a single source of truth here.
class AppTheme {
  /// The shared dark "terminal canvas": the app canvas, output/CI log panes,
  /// code and image preview surfaces, and the commit-graph node fill all sit
  /// on this exact color — change it here and they stay in step.
  static const Color terminalBackground = Color(0xFF1E1E1E);

  /// The highlight every selectable list row uses for its selected state
  /// (panels, sheets, job lists) — one value so selection reads identically
  /// across the app.
  static final Color rowSelectionTint =
      MacosColors.systemBlueColor.withValues(alpha: 0.15);

  static MacosThemeData get darkTheme {
    return MacosThemeData.dark().copyWith(
      visualDensity: VisualDensity.adaptivePlatformDensity,
      dividerColor: const Color(0x1FEEF0F5),
      canvasColor: terminalBackground,
    );
  }
}
