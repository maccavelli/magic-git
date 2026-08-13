import 'package:flutter/material.dart' show VisualDensity;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../core/settings/app_settings.dart';
import '../../core/theme/app_theme.dart';

@immutable
class WorkspaceAppearanceData {
  final WorkspaceDensity density;
  final bool highContrast;
  final bool reduceMotion;
  final WorkspaceThemeTokens tokens;

  const WorkspaceAppearanceData({
    required this.density,
    required this.highContrast,
    required this.reduceMotion,
    required this.tokens,
  });
}

class WorkspaceAppearanceScope extends InheritedWidget {
  final WorkspaceAppearanceData data;

  const WorkspaceAppearanceScope({
    super.key,
    required this.data,
    required super.child,
  });

  static WorkspaceAppearanceData? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<WorkspaceAppearanceScope>()
      ?.data;

  @override
  bool updateShouldNotify(WorkspaceAppearanceScope oldWidget) =>
      data.density != oldWidget.data.density ||
      data.highContrast != oldWidget.data.highContrast ||
      data.reduceMotion != oldWidget.data.reduceMotion;
}

/// Resolves the global appearance settings once at the shared workspace root.
/// Every migrated screen renders below this boundary.
class WorkspaceAppearanceBoundary extends StatelessWidget {
  final Widget child;

  const WorkspaceAppearanceBoundary({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    try {
      ProviderScope.containerOf(context, listen: false);
    } on StateError {
      return _ResolvedWorkspaceAppearance(
        density: WorkspaceDensity.comfortable,
        highContrast: false,
        child: child,
      );
    }
    return Consumer(
      builder: (context, ref, _) {
        final (density, highContrast) = ref.watch(
          appSettingsProvider.select(
            (settings) =>
                (settings.workspaceDensity, settings.workspaceHighContrast),
          ),
        );
        return _ResolvedWorkspaceAppearance(
          density: density,
          highContrast: highContrast,
          child: child,
        );
      },
    );
  }
}

class _ResolvedWorkspaceAppearance extends StatelessWidget {
  final WorkspaceDensity density;
  final bool highContrast;
  final Widget child;

  const _ResolvedWorkspaceAppearance({
    required this.density,
    required this.highContrast,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final tokens = AppTheme.workspaceTokens(
      density,
      highContrast: highContrast,
    );
    final visualDensity = density == WorkspaceDensity.compact
        ? VisualDensity.compact
        : VisualDensity.standard;
    return WorkspaceAppearanceScope(
      data: WorkspaceAppearanceData(
        density: density,
        highContrast: highContrast,
        reduceMotion: reduceMotion,
        tokens: tokens,
      ),
      child: MacosTheme(
        data: MacosTheme.of(context).copyWith(visualDensity: visualDensity),
        child: child,
      ),
    );
  }
}
