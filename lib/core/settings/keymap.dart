import 'dart:convert';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show SingleActivator, ShortcutActivator;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'settings_bus.dart';

/// A single serializable key combination — the persistable, comparable
/// counterpart to Flutter's [SingleActivator] (which supports neither out of
/// the box).
class KeyBinding {
  final bool meta;
  final bool shift;
  final bool alt;
  final bool control;
  final int keyId;

  const KeyBinding({
    this.meta = false,
    this.shift = false,
    this.alt = false,
    this.control = false,
    required this.keyId,
  });

  factory KeyBinding.fromKey(
    LogicalKeyboardKey key, {
    bool meta = false,
    bool shift = false,
    bool alt = false,
    bool control = false,
  }) => KeyBinding(
    meta: meta,
    shift: shift,
    alt: alt,
    control: control,
    keyId: key.keyId,
  );

  SingleActivator toActivator() => SingleActivator(
    LogicalKeyboardKey(keyId),
    meta: meta,
    shift: shift,
    alt: alt,
    control: control,
  );

  /// Compact persisted form: modifier flags then the key id, e.g. `"1010:70"`.
  String encode() {
    final flags = '${meta ? 1 : 0}${shift ? 1 : 0}${alt ? 1 : 0}${control ? 1 : 0}';
    return '$flags:$keyId';
  }

  static KeyBinding? decode(String s) {
    final parts = s.split(':');
    if (parts.length != 2 || parts[0].length != 4) return null;
    final flags = parts[0];
    final keyId = int.tryParse(parts[1]);
    if (keyId == null) return null;
    return KeyBinding(
      meta: flags[0] == '1',
      shift: flags[1] == '1',
      alt: flags[2] == '1',
      control: flags[3] == '1',
      keyId: keyId,
    );
  }

  /// macOS-style display label, e.g. "⌘⇧P".
  String get label {
    final buffer = StringBuffer();
    if (control) buffer.write('⌃');
    if (alt) buffer.write('⌥');
    if (shift) buffer.write('⇧');
    if (meta) buffer.write('⌘');
    buffer.write(_keyLabel(LogicalKeyboardKey(keyId)));
    return buffer.toString();
  }

  static String _keyLabel(LogicalKeyboardKey key) {
    if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter) {
      return '↩';
    }
    if (key == LogicalKeyboardKey.backspace) return '⌫';
    if (key == LogicalKeyboardKey.space) return 'Space';
    if (key == LogicalKeyboardKey.escape) return '⎋';
    if (key == LogicalKeyboardKey.comma) return ',';
    if (key == LogicalKeyboardKey.arrowUp) return '↑';
    if (key == LogicalKeyboardKey.arrowDown) return '↓';
    if (key == LogicalKeyboardKey.arrowLeft) return '←';
    if (key == LogicalKeyboardKey.arrowRight) return '→';
    final keyLabel = key.keyLabel;
    return keyLabel.isEmpty ? '?' : keyLabel.toUpperCase();
  }

  @override
  bool operator ==(Object other) =>
      other is KeyBinding &&
      other.meta == meta &&
      other.shift == shift &&
      other.alt == alt &&
      other.control == control &&
      other.keyId == keyId;

  @override
  int get hashCode => Object.hash(meta, shift, alt, control, keyId);
}

/// Groups shortcut actions for display and for scoping which are active at
/// once. [global] shortcuts fire regardless of the active panel and conflict
/// with everything; the rest are scoped to one panel/dialog and only conflict
/// within their own category (or with a global one).
enum KeymapCategory {
  global('Global'),
  repository('Repository'),
  branches('Branches'),
  commit('Commit Message'),
  history('History'),
  stashes('Stashes'),
  gitlab('GitLab'),
  github('GitHub'),
  viewer('File Viewer');

  final String label;
  const KeymapCategory(this.label);
}

/// A single remappable action: a stable id (persisted, never shown), a
/// display label, the category it's scoped to, and its factory-default
/// binding(s).
class KeymapAction {
  final String id;
  final String label;
  final KeymapCategory category;
  final List<KeyBinding> defaultBindings;

  const KeymapAction({
    required this.id,
    required this.label,
    required this.category,
    required this.defaultBindings,
  });
}

/// The full set of shortcuts Remote Magic Git ships with. Every action here
/// must have a real, already-implemented handler to wire up to — this list is
/// deliberately scoped to actions that exist today.
final List<KeymapAction> kKeymapActions = [
  KeymapAction(
    id: 'global.refresh',
    label: 'Refresh',
    category: KeymapCategory.global,
    defaultBindings: [KeyBinding.fromKey(LogicalKeyboardKey.keyR, meta: true)],
  ),
  KeymapAction(
    id: 'global.openSettings',
    label: 'Open Settings',
    category: KeymapCategory.global,
    defaultBindings: [KeyBinding.fromKey(LogicalKeyboardKey.comma, meta: true)],
  ),
  KeymapAction(
    id: 'global.showShortcuts',
    label: 'Show Keyboard Shortcuts',
    category: KeymapCategory.global,
    defaultBindings: [KeyBinding.fromKey(LogicalKeyboardKey.slash, meta: true)],
  ),
  KeymapAction(
    id: 'global.commandPalette',
    label: 'Command Palette',
    category: KeymapCategory.global,
    defaultBindings: [KeyBinding.fromKey(LogicalKeyboardKey.keyK, meta: true)],
  ),
  KeymapAction(
    id: 'global.undo',
    label: 'Undo Git Operation',
    category: KeymapCategory.global,
    defaultBindings: [KeyBinding.fromKey(LogicalKeyboardKey.keyZ, meta: true)],
  ),
  KeymapAction(
    id: 'global.panel1',
    label: 'Switch to Repository',
    category: KeymapCategory.global,
    defaultBindings: [KeyBinding.fromKey(LogicalKeyboardKey.digit1, meta: true)],
  ),
  KeymapAction(
    id: 'global.panel2',
    label: 'Switch to History',
    category: KeymapCategory.global,
    defaultBindings: [KeyBinding.fromKey(LogicalKeyboardKey.digit2, meta: true)],
  ),
  KeymapAction(
    id: 'global.panel3',
    label: 'Switch to Branches',
    category: KeymapCategory.global,
    defaultBindings: [KeyBinding.fromKey(LogicalKeyboardKey.digit3, meta: true)],
  ),
  KeymapAction(
    id: 'global.panel4',
    label: 'Switch to Stashes',
    category: KeymapCategory.global,
    defaultBindings: [KeyBinding.fromKey(LogicalKeyboardKey.digit4, meta: true)],
  ),
  KeymapAction(
    id: 'global.panel5',
    label: 'Switch to Forge',
    category: KeymapCategory.global,
    defaultBindings: [KeyBinding.fromKey(LogicalKeyboardKey.digit5, meta: true)],
  ),
  KeymapAction(
    id: 'global.panel6',
    label: 'Switch to Worktrees',
    category: KeymapCategory.global,
    defaultBindings: [KeyBinding.fromKey(LogicalKeyboardKey.digit6, meta: true)],
  ),
  KeymapAction(
    id: 'repository.fetch',
    label: 'Fetch',
    category: KeymapCategory.repository,
    defaultBindings: [
      KeyBinding.fromKey(LogicalKeyboardKey.keyF, meta: true, shift: true),
    ],
  ),
  KeymapAction(
    id: 'repository.push',
    label: 'Push',
    category: KeymapCategory.repository,
    defaultBindings: [
      KeyBinding.fromKey(LogicalKeyboardKey.keyP, meta: true, shift: true),
    ],
  ),
  KeymapAction(
    id: 'repository.pull',
    label: 'Pull',
    category: KeymapCategory.repository,
    defaultBindings: [
      KeyBinding.fromKey(LogicalKeyboardKey.keyL, meta: true, shift: true),
    ],
  ),
  KeymapAction(
    id: 'repository.stash',
    label: 'Stash changes',
    category: KeymapCategory.repository,
    defaultBindings: [
      KeyBinding.fromKey(LogicalKeyboardKey.keyS, meta: true, shift: true),
    ],
  ),
  KeymapAction(
    id: 'repository.sync',
    label: 'Sync (pull, then push)',
    category: KeymapCategory.repository,
    defaultBindings: [
      KeyBinding.fromKey(LogicalKeyboardKey.keyY, meta: true, shift: true),
    ],
  ),
  KeymapAction(
    id: 'repository.stageAll',
    label: 'Stage all changes',
    category: KeymapCategory.repository,
    defaultBindings: [
      KeyBinding.fromKey(LogicalKeyboardKey.keyA, meta: true, shift: true),
    ],
  ),
  KeymapAction(
    id: 'repository.forcePush',
    label: 'Force push (with lease)',
    category: KeymapCategory.repository,
    defaultBindings: [
      KeyBinding.fromKey(LogicalKeyboardKey.keyU, meta: true, control: true),
    ],
  ),
  KeymapAction(
    id: 'repository.toggleSplitDiff',
    label: 'Toggle side-by-side diff',
    category: KeymapCategory.repository,
    defaultBindings: [
      KeyBinding.fromKey(LogicalKeyboardKey.keyS, meta: true, alt: true),
    ],
  ),
  KeymapAction(
    id: 'repository.toggleIgnoreWhitespace',
    label: 'Toggle ignore whitespace in diff',
    category: KeymapCategory.repository,
    defaultBindings: [
      KeyBinding.fromKey(LogicalKeyboardKey.keyW, meta: true, alt: true),
    ],
  ),
  KeymapAction(
    id: 'repository.toggleExpandContext',
    label: 'Toggle expanded diff context',
    category: KeymapCategory.repository,
    defaultBindings: [
      KeyBinding.fromKey(LogicalKeyboardKey.keyX, meta: true, alt: true),
    ],
  ),
  KeymapAction(
    id: 'repository.toggleStage',
    label: 'Toggle stage for selected file',
    category: KeymapCategory.repository,
    defaultBindings: [KeyBinding.fromKey(LogicalKeyboardKey.space)],
  ),
  KeymapAction(
    id: 'repository.discard',
    label: 'Discard changes to selected file',
    category: KeymapCategory.repository,
    defaultBindings: [
      KeyBinding.fromKey(LogicalKeyboardKey.backspace, meta: true, shift: true),
    ],
  ),
  KeymapAction(
    id: 'repository.focusCommit',
    label: 'Open commit dialog',
    category: KeymapCategory.repository,
    defaultBindings: [KeyBinding.fromKey(LogicalKeyboardKey.keyG, meta: true)],
  ),
  KeymapAction(
    id: 'branches.newBranch',
    label: 'Focus new branch field',
    category: KeymapCategory.branches,
    defaultBindings: [KeyBinding.fromKey(LogicalKeyboardKey.keyB, meta: true)],
  ),
  KeymapAction(
    id: 'branches.createTag',
    label: 'Create tag…',
    category: KeymapCategory.branches,
    defaultBindings: [
      KeyBinding.fromKey(LogicalKeyboardKey.keyT, meta: true, shift: true),
    ],
  ),
  KeymapAction(
    id: 'branches.merge',
    label: 'Merge selected branch into current',
    category: KeymapCategory.branches,
    defaultBindings: [
      KeyBinding.fromKey(LogicalKeyboardKey.keyM, meta: true, shift: true),
    ],
  ),
  KeymapAction(
    id: 'branches.delete',
    label: 'Delete selected branch',
    category: KeymapCategory.branches,
    defaultBindings: [
      KeyBinding.fromKey(LogicalKeyboardKey.backspace, meta: true),
    ],
  ),
  KeymapAction(
    id: 'commit.confirm',
    label: 'Confirm commit',
    category: KeymapCategory.commit,
    defaultBindings: [KeyBinding.fromKey(LogicalKeyboardKey.enter, meta: true)],
  ),
  KeymapAction(
    id: 'commit.confirmAndPush',
    label: 'Commit and push',
    category: KeymapCategory.commit,
    defaultBindings: [
      KeyBinding.fromKey(LogicalKeyboardKey.enter, meta: true, shift: true),
    ],
  ),
  // History — scoped to the History panel; most require a selected commit.
  KeymapAction(
    id: 'history.copySha',
    label: 'Copy commit SHA',
    category: KeymapCategory.history,
    defaultBindings: [KeyBinding.fromKey(LogicalKeyboardKey.keyC, meta: true)],
  ),
  KeymapAction(
    id: 'history.checkout',
    label: 'Checkout selected commit',
    category: KeymapCategory.history,
    defaultBindings: [
      KeyBinding.fromKey(LogicalKeyboardKey.keyB, meta: true, shift: true),
    ],
  ),
  KeymapAction(
    id: 'history.branchFrom',
    label: 'Branch from selected commit',
    category: KeymapCategory.history,
    defaultBindings: [
      KeyBinding.fromKey(LogicalKeyboardKey.keyN, meta: true, shift: true),
    ],
  ),
  KeymapAction(
    id: 'history.cherryPick',
    label: 'Cherry-pick selected commit',
    category: KeymapCategory.history,
    defaultBindings: [
      KeyBinding.fromKey(LogicalKeyboardKey.keyC, meta: true, alt: true),
    ],
  ),
  KeymapAction(
    id: 'history.rebaseFrom',
    label: 'Interactive rebase from selected commit',
    category: KeymapCategory.history,
    defaultBindings: [
      KeyBinding.fromKey(LogicalKeyboardKey.keyR, meta: true, shift: true),
    ],
  ),
  KeymapAction(
    id: 'history.amend',
    label: 'Amend last commit',
    category: KeymapCategory.history,
    defaultBindings: [
      KeyBinding.fromKey(LogicalKeyboardKey.enter, meta: true, shift: true),
    ],
  ),
  KeymapAction(
    id: 'history.filter',
    label: 'Filter commits',
    category: KeymapCategory.history,
    defaultBindings: [KeyBinding.fromKey(LogicalKeyboardKey.keyF, meta: true)],
  ),
  // The zoom trio mirrors the ecosystem convention (GitKraken, browsers):
  // ⌘= / ⌘− / ⌘0. ⌘-scroll-wheel and trackpad pinch also zoom, unremappable.
  KeymapAction(
    id: 'history.zoomIn',
    label: 'Zoom commit list in',
    category: KeymapCategory.history,
    defaultBindings: [
      KeyBinding.fromKey(LogicalKeyboardKey.equal, meta: true),
    ],
  ),
  KeymapAction(
    id: 'history.zoomOut',
    label: 'Zoom commit list out',
    category: KeymapCategory.history,
    defaultBindings: [
      KeyBinding.fromKey(LogicalKeyboardKey.minus, meta: true),
    ],
  ),
  KeymapAction(
    id: 'history.zoomReset',
    label: 'Reset commit list zoom',
    category: KeymapCategory.history,
    defaultBindings: [
      KeyBinding.fromKey(LogicalKeyboardKey.digit0, meta: true),
    ],
  ),
  // Stashes — scoped to the Stashes panel; require a selected stash.
  KeymapAction(
    id: 'stashes.apply',
    label: 'Apply selected stash',
    category: KeymapCategory.stashes,
    defaultBindings: [
      KeyBinding.fromKey(LogicalKeyboardKey.keyA, meta: true, alt: true),
    ],
  ),
  KeymapAction(
    id: 'stashes.pop',
    label: 'Pop selected stash',
    category: KeymapCategory.stashes,
    defaultBindings: [
      KeyBinding.fromKey(LogicalKeyboardKey.keyP, meta: true, alt: true),
    ],
  ),
  KeymapAction(
    id: 'stashes.drop',
    label: 'Drop selected stash',
    category: KeymapCategory.stashes,
    defaultBindings: [
      KeyBinding.fromKey(LogicalKeyboardKey.backspace, meta: true),
    ],
  ),
  // GitLab — scoped to the GitLab panel; approve/merge require a selected MR,
  // retry a selected pipeline.
  KeymapAction(
    id: 'gitlab.newMr',
    label: 'New merge request',
    category: KeymapCategory.gitlab,
    defaultBindings: [KeyBinding.fromKey(LogicalKeyboardKey.keyN, meta: true)],
  ),
  KeymapAction(
    id: 'gitlab.approve',
    label: 'Approve selected merge request',
    category: KeymapCategory.gitlab,
    defaultBindings: [
      KeyBinding.fromKey(LogicalKeyboardKey.keyA, meta: true, alt: true),
    ],
  ),
  KeymapAction(
    id: 'gitlab.merge',
    label: 'Merge selected merge request',
    category: KeymapCategory.gitlab,
    defaultBindings: [
      KeyBinding.fromKey(LogicalKeyboardKey.keyM, meta: true, shift: true),
    ],
  ),
  KeymapAction(
    id: 'gitlab.retry',
    label: 'Retry selected pipeline',
    category: KeymapCategory.gitlab,
    defaultBindings: [
      KeyBinding.fromKey(LogicalKeyboardKey.keyR, meta: true, alt: true),
    ],
  ),
  // GitHub — scoped to the GitHub (Forge) panel; approve/merge require a
  // selected pull request, re-run a selected workflow run. Shares default
  // bindings with the GitLab actions above, which is safe: they're in separate
  // (non-global) categories, so only one forge panel is ever active per repo.
  KeymapAction(
    id: 'github.newPr',
    label: 'New pull request',
    category: KeymapCategory.github,
    defaultBindings: [KeyBinding.fromKey(LogicalKeyboardKey.keyN, meta: true)],
  ),
  KeymapAction(
    id: 'github.approve',
    label: 'Approve selected pull request',
    category: KeymapCategory.github,
    defaultBindings: [
      KeyBinding.fromKey(LogicalKeyboardKey.keyA, meta: true, alt: true),
    ],
  ),
  KeymapAction(
    id: 'github.merge',
    label: 'Merge selected pull request',
    category: KeymapCategory.github,
    defaultBindings: [
      KeyBinding.fromKey(LogicalKeyboardKey.keyM, meta: true, shift: true),
    ],
  ),
  KeymapAction(
    id: 'github.rerun',
    label: 'Re-run selected workflow run',
    category: KeymapCategory.github,
    defaultBindings: [
      KeyBinding.fromKey(LogicalKeyboardKey.keyR, meta: true, alt: true),
    ],
  ),
  // File Viewer — scoped to the front-most viewer window.
  KeymapAction(
    id: 'viewer.close',
    label: 'Close viewer window',
    category: KeymapCategory.viewer,
    defaultBindings: [KeyBinding.fromKey(LogicalKeyboardKey.keyW, meta: true)],
  ),
  KeymapAction(
    id: 'viewer.copyContents',
    label: 'Copy file contents',
    category: KeymapCategory.viewer,
    defaultBindings: [
      KeyBinding.fromKey(LogicalKeyboardKey.keyC, meta: true, shift: true),
    ],
  ),
  KeymapAction(
    id: 'viewer.wordWrap',
    label: 'Toggle word wrap',
    category: KeymapCategory.viewer,
    defaultBindings: [KeyBinding.fromKey(LogicalKeyboardKey.keyZ, alt: true)],
  ),
  KeymapAction(
    id: 'viewer.find',
    label: 'Find in file',
    category: KeymapCategory.viewer,
    defaultBindings: [KeyBinding.fromKey(LogicalKeyboardKey.keyF, meta: true)],
  ),
];

final Map<String, KeymapAction> kKeymapActionsById = {
  for (final action in kKeymapActions) action.id: action,
};

/// Loads/persists keybinding overrides and resolves conflicts. Follows the
/// same "defaults immediately, load async, diff-only persistence" shape as
/// [AppSettingsNotifier] — only entries that differ from default are ever
/// written to disk, so a future addition to [kKeymapActions] with no override
/// on record silently gets its new default (nothing to migrate).
class KeymapNotifier extends Notifier<Map<String, List<KeyBinding>>> {
  static const _prefsKey = 'keymapOverrides';
  final Map<String, List<KeyBinding>> _defaults = {
    for (final action in kKeymapActions) action.id: action.defaultBindings,
  };

  /// Set true the moment the user explicitly changes a binding. [build] kicks
  /// [_load] fire-and-forget and returns defaults immediately, so a user edit
  /// (setBindings/resetAction/resetAll) can land before the async on-disk read
  /// resolves; when that happens [_load] must not clobber the just-made edit
  /// with the stale stored overrides. Checked right before [_load]'s assignment.
  bool _userEdited = false;

  /// Count of setter disk writes in flight — mirrors [AppSettingsNotifier]'s
  /// guard so a cross-tab [reloadFromDisk] defers to an unflushed local write.
  int _pendingWrites = 0;

  @override
  Map<String, List<KeyBinding>> build() {
    _load();
    // Cross-tab sync: a rebind in another tab reloads this notifier from disk.
    final sub = SettingsBus.instance.onKeymapWritten.listen(
      (_) => reloadFromDisk(),
    );
    ref.onDispose(sub.cancel);
    return Map<String, List<KeyBinding>>.from(_defaults);
  }

  Future<void> _load() async {
    final SharedPreferences prefs;
    try {
      prefs = await SharedPreferences.getInstance();
    } catch (_) {
      return; // storage unavailable — keep defaults
    }
    final next = _decodeOverrides(prefs);
    // A user edit landed while we were reading disk — honor it over the stale
    // stored overrides; also bail if disposed across the async gap.
    if (next == null || _userEdited || !ref.mounted) return;
    state = next;
  }

  /// Re-reads keymap overrides another tab persisted (each tab is its own
  /// container). Defers while a local write is unflushed, and only assigns when
  /// the result actually differs, so a value-equal reload is a no-op.
  Future<void> reloadFromDisk() async {
    if (_pendingWrites > 0) return;
    final SharedPreferences prefs;
    try {
      prefs = await SharedPreferences.getInstance();
      await prefs.reload();
    } catch (_) {
      return; // storage unavailable — keep what we have
    }
    final next = _decodeOverrides(prefs);
    if (next == null || !ref.mounted || _keymapEquals(next, state)) return;
    state = next;
  }

  /// Decodes the persisted overrides folded onto [_defaults]. Returns a fresh
  /// full map (defaults when nothing is stored), or null on a corrupt top-level
  /// payload (caller keeps current state). Shared by [_load]/[reloadFromDisk].
  Map<String, List<KeyBinding>>? _decodeOverrides(SharedPreferences prefs) {
    final next = Map<String, List<KeyBinding>>.from(_defaults);
    final raw = prefs.getString(_prefsKey);
    if (raw == null || raw.isEmpty) return next;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      for (final entry in decoded.entries) {
        if (!_defaults.containsKey('${entry.key}')) {
          continue; // a since-removed action
        }
        try {
          final value = entry.value;
          if (value is! List) continue;
          final list = value
              .whereType<String>()
              .map(KeyBinding.decode)
              .whereType<KeyBinding>()
              .toList();
          if (list.isEmpty && value.isNotEmpty) {
            // Stored list non-empty but every element failed to decode
            // (corrupted / future format) — fall back to the default binding,
            // distinct from a deliberately-cleared (stored-empty) shortcut.
            continue;
          }
          next['${entry.key}'] = list;
        } catch (_) {
          // Skip one malformed action's overrides (keeps its default).
        }
      }
      return next;
    } catch (_) {
      return null; // corrupt top-level payload — keep current state
    }
  }

  static bool _keymapEquals(
    Map<String, List<KeyBinding>> a,
    Map<String, List<KeyBinding>> b,
  ) {
    if (a.length != b.length) return false;
    for (final e in a.entries) {
      final other = b[e.key];
      if (other == null || !listEquals(e.value, other)) return false;
    }
    return true;
  }

  /// Replaces every binding for [actionId] and persists.
  Future<void> setBindings(String actionId, List<KeyBinding> bindings) async {
    _userEdited = true;
    state = {...state, actionId: bindings};
    await _persist();
  }

  Future<void> resetAction(String actionId) async {
    _userEdited = true;
    state = {...state, actionId: _defaults[actionId] ?? const <KeyBinding>[]};
    await _persist();
  }

  Future<void> resetAll() async {
    _userEdited = true;
    state = Map<String, List<KeyBinding>>.from(_defaults);
    await _persist();
  }

  Future<void> _persist() async {
    _pendingWrites++;
    try {
      final prefs = await SharedPreferences.getInstance();
      final overrides = <String, dynamic>{};
      for (final entry in state.entries) {
        final defaults = _defaults[entry.key] ?? const <KeyBinding>[];
        if (!listEquals(entry.value, defaults)) {
          overrides[entry.key] = entry.value.map((b) => b.encode()).toList();
        }
      }
      if (overrides.isEmpty) {
        await prefs.remove(_prefsKey);
      } else {
        await prefs.setString(_prefsKey, jsonEncode(overrides));
      }
    } finally {
      _pendingWrites--;
    }
    SettingsBus.instance.notifyKeymapWritten();
  }

  /// Every other action — in [actionId]'s own category, or global — currently
  /// bound to [binding]. Shown to the user before they overwrite it.
  List<KeymapAction> conflictsFor(String actionId, KeyBinding binding) {
    final ownCategory = kKeymapActionsById[actionId]?.category;
    return [
      for (final action in kKeymapActions)
        if (action.id != actionId &&
            _scopesOverlap(action.category, ownCategory ?? action.category) &&
            (state[action.id] ?? const <KeyBinding>[]).contains(binding))
          action,
    ];
  }

  bool _scopesOverlap(KeymapCategory a, KeymapCategory b) =>
      a == b || a == KeymapCategory.global || b == KeymapCategory.global;
}

final keymapProvider =
    NotifierProvider<KeymapNotifier, Map<String, List<KeyBinding>>>(
      KeymapNotifier.new,
    );

/// Builds a [CallbackShortcuts] bindings map from the current keymap. A null
/// handler — an action whose precondition (e.g. "a file is selected") isn't
/// currently met — contributes no binding, so the key event falls through
/// instead of silently no-op'ing.
Map<ShortcutActivator, VoidCallback> resolveShortcuts(
  Map<String, List<KeyBinding>> keymap,
  Map<String, VoidCallback?> handlers,
) {
  final map = <ShortcutActivator, VoidCallback>{};
  for (final entry in handlers.entries) {
    final callback = entry.value;
    if (callback == null) continue;
    for (final binding in keymap[entry.key] ?? const <KeyBinding>[]) {
      map[binding.toActivator()] = callback;
    }
  }
  return map;
}
