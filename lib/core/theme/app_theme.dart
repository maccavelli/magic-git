import 'package:flutter/material.dart';
import 'package:macos_ui/macos_ui.dart';

import '../settings/app_settings.dart';

enum WorkspaceSurfaceRole {
  sidebar,
  navigator,
  canvas,
  inspector,
  taskDock,
  overlay,
  code,
}

enum WorkspaceTypeRole { title, heading, body, metadata, code, status }

enum WorkspaceCiState { idle, queued, running, passed, failed, canceled }

class WorkspaceSpacing {
  static const double xxs = 4;
  static const double xs = 8;
  static const double sm = 12;
  static const double md = 16;
  static const double lg = 24;
  static const double xl = 32;
}

class WorkspaceRadii {
  static const double small = 4;
  static const double medium = 8;
  static const double large = 12;
  static const double pill = 999;
}

@immutable
class WorkspaceMetrics {
  final double rowHeight;
  final double denseRowHeight;
  final double minimumTargetSize;
  final double paneHeaderHeight;

  const WorkspaceMetrics({
    required this.rowHeight,
    required this.denseRowHeight,
    required this.minimumTargetSize,
    required this.paneHeaderHeight,
  });

  static WorkspaceMetrics resolve(WorkspaceDensity density) =>
      switch (density) {
        WorkspaceDensity.compact => const WorkspaceMetrics(
          rowHeight: 28,
          denseRowHeight: 24,
          minimumTargetSize: 28,
          paneHeaderHeight: 36,
        ),
        WorkspaceDensity.comfortable => const WorkspaceMetrics(
          rowHeight: 34,
          denseRowHeight: 28,
          minimumTargetSize: 32,
          paneHeaderHeight: 42,
        ),
      };
}

@immutable
class WorkspacePalette {
  final Color sidebar;
  final Color navigator;
  final Color canvas;
  final Color inspector;
  final Color taskDock;
  final Color overlay;
  final Color focus;
  final Color hover;
  final Color selection;
  final Color dropTarget;
  final Color success;
  final Color warning;
  final Color danger;
  final Color conflict;
  final Color border;

  const WorkspacePalette({
    required this.sidebar,
    required this.navigator,
    required this.canvas,
    required this.inspector,
    required this.taskDock,
    required this.overlay,
    required this.focus,
    required this.hover,
    required this.selection,
    required this.dropTarget,
    required this.success,
    required this.warning,
    required this.danger,
    required this.conflict,
    required this.border,
  });

  Color surface(WorkspaceSurfaceRole role) => switch (role) {
    WorkspaceSurfaceRole.sidebar => sidebar,
    WorkspaceSurfaceRole.navigator => navigator,
    WorkspaceSurfaceRole.canvas => canvas,
    WorkspaceSurfaceRole.inspector => inspector,
    WorkspaceSurfaceRole.taskDock => taskDock,
    WorkspaceSurfaceRole.overlay => overlay,
    WorkspaceSurfaceRole.code => AppTheme.terminalBackground,
  };
}

@immutable
class WorkspaceThemeTokens {
  final WorkspaceMetrics metrics;
  final WorkspacePalette palette;

  const WorkspaceThemeTokens({required this.metrics, required this.palette});
}

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
  static final Color rowSelectionTint = MacosColors.systemBlueColor.withValues(
    alpha: 0.15,
  );

  static WorkspaceThemeTokens workspaceTokens(
    WorkspaceDensity density, {
    bool highContrast = false,
  }) {
    final border = highContrast
        ? const Color(0x99EEF0F5)
        : MacosColors.separatorColor;
    return WorkspaceThemeTokens(
      metrics: WorkspaceMetrics.resolve(density),
      palette: WorkspacePalette(
        sidebar: const Color(0xFF25262B),
        navigator: const Color(0xFF222328),
        canvas: terminalBackground,
        inspector: const Color(0xFF24252A),
        taskDock: const Color(0xFF202126),
        overlay: const Color(0xFF2B2C32),
        focus: highContrast
            ? const Color(0xFF7BB7FF)
            : MacosColors.systemBlueColor,
        hover: const Color(0x1FFFFFFF),
        selection: highContrast ? const Color(0x665AA9FF) : rowSelectionTint,
        dropTarget: const Color(0x665AC8FA),
        success: MacosColors.systemGreenColor,
        warning: MacosColors.systemYellowColor,
        danger: MacosColors.systemRedColor,
        conflict: const Color(0xFFFF8A3D),
        border: border,
      ),
    );
  }

  static Color ciColor(WorkspaceCiState state) => switch (state) {
    WorkspaceCiState.idle => MacosColors.systemGrayColor,
    WorkspaceCiState.queued => MacosColors.systemYellowColor,
    WorkspaceCiState.running => MacosColors.systemBlueColor,
    WorkspaceCiState.passed => MacosColors.systemGreenColor,
    WorkspaceCiState.failed => MacosColors.systemRedColor,
    WorkspaceCiState.canceled => MacosColors.systemGrayColor,
  };

  static MacosThemeData get darkTheme {
    return MacosThemeData.dark().copyWith(
      visualDensity: VisualDensity.adaptivePlatformDensity,
      dividerColor: const Color(0x1FEEF0F5),
      canvasColor: terminalBackground,
    );
  }
}
