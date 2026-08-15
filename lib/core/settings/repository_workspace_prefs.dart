import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../storage/repository_ui_identity.dart';
import 'pane_layout.dart';

enum WorkspacePreset { review, commit, investigate, minimal }

/// Context-bar items the user may hide.
///
/// Deliberately excluded, and therefore always present: the repository
/// identity block and the emphasized primary action. Apple's guidance is that
/// "items on the toolbar's leading edge aren't customizable" and to "only
/// specify one primary action" — a bar you can strip to nothing tells you
/// nothing about which repository you are looking at.
///
/// Hiding is only safe because every one of these also exists as a menu
/// command (MADR 0008, Phase 1): a toolbar item "can't be the only place that
/// presents a command", or turning it off would delete the command.
enum WorkspaceToolbarSlot {
  back,
  forward,
  syncGroup,
  stash,
  refresh,
  activity,
  viewOptions,
  statusSummary,
  linkStatus,
}

extension WorkspaceToolbarSlotPresentation on WorkspaceToolbarSlot {
  String get label => switch (this) {
    WorkspaceToolbarSlot.back => 'Back',
    WorkspaceToolbarSlot.forward => 'Forward',
    WorkspaceToolbarSlot.syncGroup => 'Sync actions',
    WorkspaceToolbarSlot.stash => 'Stash',
    WorkspaceToolbarSlot.refresh => 'Refresh',
    WorkspaceToolbarSlot.activity => 'Activity',
    WorkspaceToolbarSlot.viewOptions => 'View options',
    WorkspaceToolbarSlot.statusSummary => 'Status summary',
    WorkspaceToolbarSlot.linkStatus => 'Connection status',
  };

  /// Where the slot sits, so the menu can group leading and trailing items the
  /// way they appear on the bar.
  bool get isLeading =>
      this == WorkspaceToolbarSlot.back || this == WorkspaceToolbarSlot.forward;
}

extension WorkspacePresetPresentation on WorkspacePreset {
  String get label => switch (this) {
    WorkspacePreset.review => 'Review',
    WorkspacePreset.commit => 'Commit',
    WorkspacePreset.investigate => 'Investigate',
    WorkspacePreset.minimal => 'Minimal',
  };
}

/// Applies a built-in pane arrangement without touching Git-facing view state.
/// Navigator mode, filters/grouping, diff options, and toolbar presentation
/// remain exactly as the user configured them.
RepositoryWorkspacePrefs applyWorkspacePreset(
  RepositoryWorkspacePrefs current,
  WorkspacePreset preset,
) => switch (preset) {
  WorkspacePreset.review => current.copyWith(
    preset: preset,
    navigatorCollapsed: false,
    inspectorCollapsed: false,
    inspectorPinned: false,
    taskDockCollapsed: true,
  ),
  WorkspacePreset.commit => current.copyWith(
    preset: preset,
    navigatorCollapsed: false,
    inspectorCollapsed: true,
    inspectorPinned: false,
    taskDockCollapsed: false,
  ),
  WorkspacePreset.investigate => current.copyWith(
    preset: preset,
    navigatorCollapsed: false,
    inspectorCollapsed: false,
    inspectorPinned: true,
    taskDockCollapsed: true,
  ),
  WorkspacePreset.minimal => current.copyWith(
    preset: preset,
    navigatorCollapsed: true,
    inspectorCollapsed: true,
    inspectorPinned: false,
    taskDockCollapsed: true,
  ),
};

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
  final WorkspacePreset preset;
  final double navigatorWidth;
  final double inspectorWidth;
  final double taskDockHeight;
  final bool navigatorCollapsed;
  final bool inspectorCollapsed;
  final bool taskDockCollapsed;
  final bool inspectorPinned;
  final bool filesPinned;
  // NOTE: `inspectorWidth`, `inspectorPinned` and `inspectorCollapsed` — and
  // therefore the Investigate preset — are currently INERT. No screen passes
  // an `inspector:` to `RepositoryWorkspaceScaffold`, so nothing consumes
  // them. They round-trip correctly and are kept deliberately: populating an
  // inspector is product work (see MADR 0008 §out of scope), not a bug to fix
  // here. Do not "clean them up" without first checking whether an inspector
  // has since been built.
  final RepositoryDiffLayout diffLayout;
  final bool ignoreWhitespace;
  final int diffContextLines;
  final RepositoryChangeGrouping grouping;
  final bool showToolbarLabels;
  final Set<WorkspaceToolbarSlot> visibleToolbarSlots;

  const RepositoryWorkspacePrefs({
    this.version = currentVersion,
    this.preset = WorkspacePreset.review,
    this.navigatorWidth = defaultNavigatorWidth,
    this.inspectorWidth = defaultInspectorWidth,
    this.taskDockHeight = defaultTaskDockHeight,
    this.navigatorCollapsed = false,
    this.inspectorCollapsed = false,
    // Matches `applyWorkspacePreset(review)`, which is the default [preset].
    // These disagreed: the record claimed the Review preset while carrying
    // Commit's dock state, so a fresh workspace matched no preset at all.
    // The docked commit bar is unaffected — it renders whenever the tree is
    // dirty, independent of the task dock — and ⌘G now un-collapses the dock.
    this.taskDockCollapsed = true,
    this.inspectorPinned = false,
    this.filesPinned = false,
    this.diffLayout = RepositoryDiffLayout.unified,
    this.ignoreWhitespace = false,
    this.diffContextLines = 3,
    this.grouping = RepositoryChangeGrouping.status,
    this.showToolbarLabels = false,
    // Everything on by default: a fresh workspace shows the full bar, and
    // hiding is an explicit choice rather than something to discover.
    this.visibleToolbarSlots = const {
      WorkspaceToolbarSlot.back,
      WorkspaceToolbarSlot.forward,
      WorkspaceToolbarSlot.syncGroup,
      WorkspaceToolbarSlot.stash,
      WorkspaceToolbarSlot.refresh,
      WorkspaceToolbarSlot.activity,
      WorkspaceToolbarSlot.viewOptions,
      WorkspaceToolbarSlot.statusSummary,
      WorkspaceToolbarSlot.linkStatus,
    },
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
    Set<WorkspaceToolbarSlot>? visibleToolbarSlots,
  }) => RepositoryWorkspacePrefs(
    version: version ?? this.version,
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
    visibleToolbarSlots: visibleToolbarSlots ?? this.visibleToolbarSlots,
  );

  Map<String, Object> toJson() {
    final value = normalized;
    return {
      'version': currentVersion,
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
      'visibleToolbarSlots': [
        for (final slot in WorkspaceToolbarSlot.values)
          if (value.visibleToolbarSlots.contains(slot)) slot.name,
      ],
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
        visibleToolbarSlots: _decodeToolbarSlots(json['visibleToolbarSlots']),
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

Set<WorkspaceToolbarSlot> _decodeToolbarSlots(Object? raw) {
  if (raw == null) {
    return const {WorkspaceToolbarSlot.back, WorkspaceToolbarSlot.forward};
  }
  if (raw is! List) {
    return const {WorkspaceToolbarSlot.back, WorkspaceToolbarSlot.forward};
  }
  return {
    for (final item in raw)
      if (item is String)
        ...WorkspaceToolbarSlot.values.where((slot) => slot.name == item),
  };
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
