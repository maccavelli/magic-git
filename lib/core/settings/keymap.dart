import 'dart:convert';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show SingleActivator, ShortcutActivator;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
  commit('Commit Message');

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
    label: 'Switch to GitLab',
    category: KeymapCategory.global,
    defaultBindings: [KeyBinding.fromKey(LogicalKeyboardKey.digit5, meta: true)],
  ),
  KeymapAction(
    id: 'global.panel6',
    label: 'Switch to Project',
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
    id: 'commit.confirm',
    label: 'Confirm commit',
    category: KeymapCategory.commit,
    defaultBindings: [KeyBinding.fromKey(LogicalKeyboardKey.enter, meta: true)],
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

  @override
  Map<String, List<KeyBinding>> build() {
    _load();
    return Map<String, List<KeyBinding>>.from(_defaults);
  }

  Future<void> _load() async {
    final SharedPreferences prefs;
    try {
      prefs = await SharedPreferences.getInstance();
    } catch (_) {
      return; // storage unavailable — keep defaults
    }
    final raw = prefs.getString(_prefsKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      final next = Map<String, List<KeyBinding>>.from(_defaults);
      for (final entry in decoded.entries) {
        if (!_defaults.containsKey('${entry.key}')) {
          continue; // a since-removed action
        }
        try {
          final value = entry.value;
          if (value is! List) continue;
          final decoded = value
              .whereType<String>()
              .map(KeyBinding.decode)
              .whereType<KeyBinding>()
              .toList();
          if (decoded.isEmpty && value.isNotEmpty) {
            // The stored list was non-empty but every element failed to
            // decode (corrupted entry / future format change) — this is not
            // the same as the user deliberately clearing the shortcut (which
            // stores an empty list to begin with). Skip so the action falls
            // back to its default binding, matching the wrong-type branch
            // above.
            continue;
          }
          next['${entry.key}'] = decoded;
        } catch (_) {
          // Skip one malformed action's overrides (keeps its default) rather
          // than discarding *every* customization on a single bad entry.
        }
      }
      // A user edit landed while we were reading from disk — honor it rather
      // than overwriting it with the now-stale stored overrides.
      if (_userEdited) return;
      state = next;
    } catch (_) {
      // Corrupt top-level payload — fall back to defaults rather than crash.
    }
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
