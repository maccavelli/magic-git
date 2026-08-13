import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../storage/repository_ui_identity.dart';
import 'pane_layout.dart';

enum RepositoryNavigatorMode { changes, files }

enum WorkspacePreset { review, commit, investigate, minimal }

enum RepositoryDiffLayout { unified, split }

enum RepositoryChangeGrouping { status, directory, none }

/// Versioned, repository-identity-scoped layout preferences.
///
/// This deliberately contains only durable presentation choices. Selection,
/// filters, output, activity, and commit drafts remain session state owned by
/// their controllers.
class RepositoryWorkspacePrefs {
  static const int currentVersion = 1;
  static const double defaultNavigatorWidth = 320;
  static const double minNavigatorWidth = 240;
  static const double maxNavigatorWidth = 720;
  static const double defaultInspectorWidth = 360;
  static const double minInspectorWidth = 280;
  static const double maxInspectorWidth = 720;
  static const double defaultTaskDockHeight = 220;
  static const double minTaskDockHeight = 120;
  static const double maxTaskDockHeight = 520;
  static const int minDiffContextLines = 0;
  static const int maxDiffContextLines = 50;

  final int version;
  final RepositoryNavigatorMode navigatorMode;
  final WorkspacePreset preset;
  final double navigatorWidth;
  final double inspectorWidth;
  final double taskDockHeight;
  final bool navigatorCollapsed;
  final bool inspectorCollapsed;
  final bool taskDockCollapsed;
  final bool inspectorPinned;
  final bool filesPinned;
  final RepositoryDiffLayout diffLayout;
  final bool ignoreWhitespace;
  final int diffContextLines;
  final RepositoryChangeGrouping grouping;
  final bool showToolbarLabels;

  const RepositoryWorkspacePrefs({
    this.version = currentVersion,
    this.navigatorMode = RepositoryNavigatorMode.changes,
    this.preset = WorkspacePreset.review,
    this.navigatorWidth = defaultNavigatorWidth,
    this.inspectorWidth = defaultInspectorWidth,
    this.taskDockHeight = defaultTaskDockHeight,
    this.navigatorCollapsed = false,
    this.inspectorCollapsed = false,
    this.taskDockCollapsed = false,
    this.inspectorPinned = false,
    this.filesPinned = false,
    this.diffLayout = RepositoryDiffLayout.unified,
    this.ignoreWhitespace = false,
    this.diffContextLines = 3,
    this.grouping = RepositoryChangeGrouping.status,
    this.showToolbarLabels = false,
  });

  RepositoryWorkspacePrefs get normalized => copyWith(
    version: currentVersion,
    navigatorWidth: navigatorWidth
        .clamp(minNavigatorWidth, maxNavigatorWidth)
        .toDouble(),
    inspectorWidth: inspectorWidth
        .clamp(minInspectorWidth, maxInspectorWidth)
        .toDouble(),
    taskDockHeight: taskDockHeight
        .clamp(minTaskDockHeight, maxTaskDockHeight)
        .toDouble(),
    diffContextLines: diffContextLines.clamp(
      minDiffContextLines,
      maxDiffContextLines,
    ),
  );

  RepositoryWorkspacePrefs copyWith({
    int? version,
    RepositoryNavigatorMode? navigatorMode,
    WorkspacePreset? preset,
    double? navigatorWidth,
    double? inspectorWidth,
    double? taskDockHeight,
    bool? navigatorCollapsed,
    bool? inspectorCollapsed,
    bool? taskDockCollapsed,
    bool? inspectorPinned,
    bool? filesPinned,
    RepositoryDiffLayout? diffLayout,
    bool? ignoreWhitespace,
    int? diffContextLines,
    RepositoryChangeGrouping? grouping,
    bool? showToolbarLabels,
  }) => RepositoryWorkspacePrefs(
    version: version ?? this.version,
    navigatorMode: navigatorMode ?? this.navigatorMode,
    preset: preset ?? this.preset,
    navigatorWidth: navigatorWidth ?? this.navigatorWidth,
    inspectorWidth: inspectorWidth ?? this.inspectorWidth,
    taskDockHeight: taskDockHeight ?? this.taskDockHeight,
    navigatorCollapsed: navigatorCollapsed ?? this.navigatorCollapsed,
    inspectorCollapsed: inspectorCollapsed ?? this.inspectorCollapsed,
    taskDockCollapsed: taskDockCollapsed ?? this.taskDockCollapsed,
    inspectorPinned: inspectorPinned ?? this.inspectorPinned,
    filesPinned: filesPinned ?? this.filesPinned,
    diffLayout: diffLayout ?? this.diffLayout,
    ignoreWhitespace: ignoreWhitespace ?? this.ignoreWhitespace,
    diffContextLines: diffContextLines ?? this.diffContextLines,
    grouping: grouping ?? this.grouping,
    showToolbarLabels: showToolbarLabels ?? this.showToolbarLabels,
  );

  Map<String, Object> toJson() {
    final value = normalized;
    return {
      'version': currentVersion,
      'navigatorMode': value.navigatorMode.name,
      'preset': value.preset.name,
      'navigatorWidth': value.navigatorWidth,
      'inspectorWidth': value.inspectorWidth,
      'taskDockHeight': value.taskDockHeight,
      'navigatorCollapsed': value.navigatorCollapsed,
      'inspectorCollapsed': value.inspectorCollapsed,
      'taskDockCollapsed': value.taskDockCollapsed,
      'inspectorPinned': value.inspectorPinned,
      'filesPinned': value.filesPinned,
      'diffLayout': value.diffLayout.name,
      'ignoreWhitespace': value.ignoreWhitespace,
      'diffContextLines': value.diffContextLines,
      'grouping': value.grouping.name,
      'showToolbarLabels': value.showToolbarLabels,
    };
  }

  String encode() => jsonEncode(toJson());

  static RepositoryWorkspacePrefs decode(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const RepositoryWorkspacePrefs();
      final json = Map<String, Object?>.from(decoded);
      if (json['version'] != currentVersion) {
        return const RepositoryWorkspacePrefs();
      }
      T enumValue<T extends Enum>(List<T> values, Object? raw, T fallback) {
        if (raw is! String) return fallback;
        return values.where((value) => value.name == raw).firstOrNull ??
            fallback;
      }

      double number(Object? raw, double fallback) =>
          raw is num ? raw.toDouble() : fallback;

      return RepositoryWorkspacePrefs(
        navigatorMode: enumValue(
          RepositoryNavigatorMode.values,
          json['navigatorMode'],
          RepositoryNavigatorMode.changes,
        ),
        preset: enumValue(
          WorkspacePreset.values,
          json['preset'],
          WorkspacePreset.review,
        ),
        navigatorWidth: number(json['navigatorWidth'], defaultNavigatorWidth),
        inspectorWidth: number(json['inspectorWidth'], defaultInspectorWidth),
        taskDockHeight: number(json['taskDockHeight'], defaultTaskDockHeight),
        navigatorCollapsed: json['navigatorCollapsed'] as bool? ?? false,
        inspectorCollapsed: json['inspectorCollapsed'] as bool? ?? false,
        taskDockCollapsed: json['taskDockCollapsed'] as bool? ?? false,
        inspectorPinned: json['inspectorPinned'] as bool? ?? false,
        filesPinned: json['filesPinned'] as bool? ?? false,
        diffLayout: enumValue(
          RepositoryDiffLayout.values,
          json['diffLayout'],
          RepositoryDiffLayout.unified,
        ),
        ignoreWhitespace: json['ignoreWhitespace'] as bool? ?? false,
        diffContextLines: json['diffContextLines'] as int? ?? 3,
        grouping: enumValue(
          RepositoryChangeGrouping.values,
          json['grouping'],
          RepositoryChangeGrouping.status,
        ),
        showToolbarLabels: json['showToolbarLabels'] as bool? ?? false,
      ).normalized;
    } on FormatException {
      return const RepositoryWorkspacePrefs();
    } on TypeError {
      return const RepositoryWorkspacePrefs();
    }
  }

  static String storageKeyFor(RepositoryUiIdentity identity) =>
      'repositoryWorkspacePrefs_v1_${identity.preferenceKey}';
}

final Map<String, RepositoryWorkspacePrefs> _sessionPrefs = {};
final Map<String, Future<void>> _writeChains = {};

void clearSessionRepositoryWorkspacePrefs() => _sessionPrefs.clear();

RepositoryWorkspacePrefs _seeded(Map<PaneId, double> legacyPaneWidths) {
  final width = legacyWorkspaceWidthSeed(
    WorkspaceLegacyWidth.navigator,
    legacyPaneWidths,
  );
  return RepositoryWorkspacePrefs(
    navigatorWidth: width ?? RepositoryWorkspacePrefs.defaultNavigatorWidth,
  ).normalized;
}

Future<RepositoryWorkspacePrefs> loadRepositoryWorkspacePrefs({
  required RepositoryUiIdentity identity,
  Map<PaneId, double> legacyPaneWidths = const {},
}) async {
  if (!identity.durable) {
    return _sessionPrefs.putIfAbsent(
      identity.memoryKey,
      () => _seeded(legacyPaneWidths),
    );
  }

  final prefs = await SharedPreferences.getInstance();
  final key = RepositoryWorkspacePrefs.storageKeyFor(identity);
  final raw = prefs.getString(key);
  if (raw != null && raw.isNotEmpty) {
    return RepositoryWorkspacePrefs.decode(raw);
  }

  final seeded = _seeded(legacyPaneWidths);
  await prefs.setString(key, seeded.encode());
  return seeded;
}

Future<void> saveRepositoryWorkspacePrefs({
  required RepositoryUiIdentity identity,
  required RepositoryWorkspacePrefs next,
}) async {
  final normalized = next.normalized;
  if (!identity.durable) {
    _sessionPrefs[identity.memoryKey] = normalized;
    return;
  }
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(
    RepositoryWorkspacePrefs.storageKeyFor(identity),
    normalized.encode(),
  );
}

String _lockKey(RepositoryUiIdentity identity) =>
    identity.durable ? identity.preferenceKey : identity.memoryKey;

Future<T> _serialized<T>(String key, Future<T> Function() body) async {
  final previous = _writeChains[key] ?? Future<void>.value();
  final gate = Completer<void>();
  _writeChains[key] = gate.future;
  try {
    await previous;
    return await body();
  } finally {
    gate.complete();
    if (identical(_writeChains[key], gate.future)) {
      unawaited(_writeChains.remove(key));
    }
  }
}

Future<RepositoryWorkspacePrefs> updateRepositoryWorkspacePrefs({
  required RepositoryUiIdentity identity,
  required RepositoryWorkspacePrefs Function(RepositoryWorkspacePrefs) update,
  Map<PaneId, double> legacyPaneWidths = const {},
}) => _serialized(_lockKey(identity), () async {
  final current = await loadRepositoryWorkspacePrefs(
    identity: identity,
    legacyPaneWidths: legacyPaneWidths,
  );
  final next = update(current).normalized;
  await saveRepositoryWorkspacePrefs(identity: identity, next: next);
  return next;
});
