import 'package:flutter/material.dart';
import 'package:macos_ui/macos_ui.dart';

/// Magic Git is a **dark-only** app by deliberate design: the diff, commit-graph,
/// and CI-log surfaces are code/terminal views tuned for a dark canvas (their
/// backgrounds and syntax contrast are baked to it). Rather than ship a
/// half-tuned light theme, we pin dark and keep a single source of truth here.
class AppTheme {
  static MacosThemeData get darkTheme {
    return MacosThemeData.dark().copyWith(
      visualDensity: VisualDensity.adaptivePlatformDensity,
      dividerColor: const Color(0x1FEEF0F5),
      canvasColor: const Color(0xFF1E1E1E),
    );
  }
}
