import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../core/settings/keymap.dart';
import '../common/actions.dart';
import '../common/buttons.dart';
import '../common/escape_dismissible.dart';
import '../common/field_styles.dart';
import '../common/sized_sheet.dart';
import '../common/tappable.dart';
import '../common/tool_icon_button.dart';

/// Modifier-only keys — pressing one alone while recording a shortcut isn't a
/// complete combination yet, so it's ignored rather than accepted as-is.
final _modifierKeys = {
  LogicalKeyboardKey.metaLeft,
  LogicalKeyboardKey.metaRight,
  LogicalKeyboardKey.shiftLeft,
  LogicalKeyboardKey.shiftRight,
  LogicalKeyboardKey.altLeft,
  LogicalKeyboardKey.altRight,
  LogicalKeyboardKey.controlLeft,
  LogicalKeyboardKey.controlRight,
  LogicalKeyboardKey.capsLock,
  LogicalKeyboardKey.fn,
};

/// Lets the user rebind every shortcut in [kKeymapActions]: click a binding
/// chip to replace it, click "+ Add" to bind a second trigger to the same
/// action, or reset one action (or all of them) back to its default. Opened
/// from Settings via the customize (slider) [ToolIconButton].
class KeyboardMappingsSheet extends ConsumerStatefulWidget {
  const KeyboardMappingsSheet({super.key});

  @override
  ConsumerState<KeyboardMappingsSheet> createState() =>
      _KeyboardMappingsSheetState();
}

class _KeyboardMappingsSheetState extends ConsumerState<KeyboardMappingsSheet> {
  final _search = TextEditingController();
  final _captureFocus = FocusNode(debugLabel: 'shortcut-capture');

  // The action/slot currently being recorded. A null slot means "recording a
  // new, additional binding" rather than replacing an existing one.
  String? _recordingActionId;
  int? _recordingSlot;

  // Deregisters this sheet's Escape interceptor (see [_interceptEscape]).
  VoidCallback? _escInterceptorDisposer;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // While recording, Escape must cancel recording — not dismiss the whole
    // sheet. Claim it at the registry level so the (focus-independent) Escape
    // dismiss defers to us; registered once, kept for the sheet's lifetime.
    _escInterceptorDisposer ??= EscapeInterceptor.of(context, _interceptEscape);
  }

  bool _interceptEscape() {
    if (_recordingActionId == null) return false;
    _cancelRecording();
    return true;
  }

  @override
  void dispose() {
    _escInterceptorDisposer?.call();
    _search.dispose();
    _captureFocus.dispose();
    super.dispose();
  }

  void _startRecording(String actionId, int? slot) {
    setState(() {
      _recordingActionId = actionId;
      _recordingSlot = slot;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _captureFocus.requestFocus();
    });
  }

  void _cancelRecording() {
    setState(() {
      _recordingActionId = null;
      _recordingSlot = null;
    });
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final actionId = _recordingActionId;
    if (actionId == null) return KeyEventResult.ignored;
    if (event is! KeyDownEvent) return KeyEventResult.handled;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      _cancelRecording();
      return KeyEventResult.handled;
    }
    if (_modifierKeys.contains(event.logicalKey)) return KeyEventResult.handled;
    final binding = KeyBinding(
      meta: HardwareKeyboard.instance.isMetaPressed,
      shift: HardwareKeyboard.instance.isShiftPressed,
      alt: HardwareKeyboard.instance.isAltPressed,
      control: HardwareKeyboard.instance.isControlPressed,
      keyId: event.logicalKey.keyId,
    );
    unawaited(_apply(actionId, _recordingSlot, binding));
    return KeyEventResult.handled;
  }

  Future<void> _apply(String actionId, int? slot, KeyBinding binding) async {
    final notifier = ref.read(keymapProvider.notifier);
    // conflictsFor only looks at OTHER actions in an overlapping scope — it
    // never checks this same action's own other slots, so without this an
    // "Add" (or replacing a different slot) could land an exact duplicate of
    // a binding this action already has, producing two identical chips.
    final ownBindings =
        ref.read(keymapProvider)[actionId] ?? const <KeyBinding>[];
    final ownDuplicateSlot = ownBindings.indexOf(binding);
    final conflicts = notifier.conflictsFor(actionId, binding);
    _cancelRecording();
    if (ownDuplicateSlot != -1 && ownDuplicateSlot != slot) {
      // Already bound to this same action elsewhere — no-op rather than
      // adding a redundant duplicate.
      return;
    }
    if (conflicts.isNotEmpty) {
      final names = conflicts.map((a) => a.label).join(', ');
      final proceed = await confirmAction(
        context,
        title: 'Shortcut already in use',
        message:
            '${binding.label} is already assigned to $names. '
            'Reassign it here?',
        confirmLabel: 'Reassign',
      );
      if (!proceed || !mounted) return;
      for (final other in conflicts) {
        final current =
            ref.read(keymapProvider)[other.id] ?? const <KeyBinding>[];
        await notifier.setBindings(
          other.id,
          current.where((b) => b != binding).toList(),
        );
      }
    }
    final current = ref.read(keymapProvider)[actionId] ?? const <KeyBinding>[];
    final next = [...current];
    if (slot == null) {
      next.add(binding);
    } else if (slot < next.length) {
      next[slot] = binding;
    } else {
      next.add(binding);
    }
    await notifier.setBindings(actionId, next);
  }

  Future<void> _removeBinding(String actionId, int slot) async {
    final current = ref.read(keymapProvider)[actionId] ?? const <KeyBinding>[];
    if (slot >= current.length) return;
    final next = [...current]..removeAt(slot);
    await ref.read(keymapProvider.notifier).setBindings(actionId, next);
  }

  @override
  Widget build(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    final keymap = ref.watch(keymapProvider);
    final query = _search.text.trim().toLowerCase();

    final byCategory = <KeymapCategory, List<KeymapAction>>{};
    for (final action in kKeymapActions) {
      final bindings = keymap[action.id] ?? const <KeyBinding>[];
      final matches =
          query.isEmpty ||
          action.label.toLowerCase().contains(query) ||
          bindings.any((b) => b.label.toLowerCase().contains(query));
      if (!matches) continue;
      byCategory.putIfAbsent(action.category, () => []).add(action);
    }

    return Focus(
      focusNode: _captureFocus,
      onKeyEvent: _onKey,
      child: SizedSheet(
        width: kSheetWidth,
        // Preferred height, capped to the viewport so the bottom controls
        // stay reachable at the app's minimum window size (the inner list
        // scrolls); floored so a degenerate viewport can't go negative.
        height: (MediaQuery.sizeOf(context).height - 80).clamp(320.0, 560.0),
        child: SizedBox(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const MacosIcon(CupertinoIcons.command, size: 18),
                    const SizedBox(width: 8),
                    Text('Keyboard Mappings', style: typography.title2),
                    const Spacer(),
                    ToolIconButton(
                      icon: CupertinoIcons.xmark,
                      tooltip: 'Close',
                      size: 15,
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  'Click a shortcut to replace it, or Add to bind a second '
                  'one. Press Esc to cancel while recording.',
                  style: typography.caption1.copyWith(
                    color: MacosColors.systemGrayColor,
                  ),
                ),
                const SizedBox(height: 12),
                MacosTextField(
                  controller: _search,
                  placeholder: 'Filter shortcuts',
                  placeholderStyle: kAppPlaceholderStyle,
                  decoration: kAppTextFieldDecoration,
                  focusedDecoration: kAppTextFieldFocusedDecoration,
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: ListView(
                    children: [
                      for (final category in KeymapCategory.values)
                        if (byCategory[category]?.isNotEmpty ?? false) ...[
                          Padding(
                            padding: const EdgeInsets.only(top: 12, bottom: 4),
                            child: Text(
                              category.label,
                              style: typography.headline,
                            ),
                          ),
                          for (final action in byCategory[category]!)
                            _actionRow(
                              context,
                              action,
                              keymap[action.id] ?? const <KeyBinding>[],
                            ),
                        ],
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    AppPushButton(
                      controlSize: ControlSize.large,
                      secondary: true,
                      onPressed: () async {
                        final ok = await confirmAction(
                          context,
                          title: 'Reset all shortcuts',
                          message:
                              'Restore every shortcut to its default binding?',
                          confirmLabel: 'Reset All',
                        );
                        if (ok) {
                          await ref.read(keymapProvider.notifier).resetAll();
                        }
                      },
                      child: const Text('Reset All'),
                    ),
                    const Spacer(),
                    AppPushButton(
                      controlSize: ControlSize.large,
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Done'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _actionRow(
    BuildContext context,
    KeymapAction action,
    List<KeyBinding> bindings,
  ) {
    final isCustom = !listEquals(bindings, action.defaultBindings);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Expanded(
            child: Text(
              action.label,
              style: MacosTheme.of(context).typography.body,
            ),
          ),
          for (var i = 0; i < bindings.length; i++) ...[
            _bindingChip(action.id, i, bindings[i]),
            const SizedBox(width: 6),
          ],
          _addChip(action.id),
          const SizedBox(width: 8),
          SizedBox(
            width: 22,
            child: isCustom
                ? ToolIconButton(
                    icon: CupertinoIcons.arrow_counterclockwise,
                    tooltip: 'Reset to default',
                    size: 14,
                    onPressed: () => ref
                        .read(keymapProvider.notifier)
                        .resetAction(action.id),
                  )
                : null,
          ),
        ],
      ),
    );
  }

  Widget _bindingChip(String actionId, int slot, KeyBinding binding) {
    final recording = _recordingActionId == actionId && _recordingSlot == slot;
    return Tappable(
      onTap: () => _startRecording(actionId, slot),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          border: Border.all(
            color: recording
                ? MacosColors.systemBlueColor
                : MacosColors.separatorColor,
          ),
          borderRadius: BorderRadius.circular(5),
          color: recording
              ? MacosColors.systemBlueColor.withValues(alpha: 0.12)
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              recording ? 'Press keys…' : binding.label,
              style: const TextStyle(fontSize: 12),
            ),
            if (!recording) ...[
              const SizedBox(width: 5),
              Tappable(
                onTap: () => _removeBinding(actionId, slot),
                child: const MacosIcon(
                  CupertinoIcons.xmark,
                  size: 10,
                  color: MacosColors.systemGrayColor,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _addChip(String actionId) {
    final recording = _recordingActionId == actionId && _recordingSlot == null;
    return Tappable(
      onTap: () => _startRecording(actionId, null),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          border: Border.all(
            color: recording
                ? MacosColors.systemBlueColor
                : MacosColors.separatorColor,
          ),
          borderRadius: BorderRadius.circular(5),
        ),
        child: Text(
          recording ? 'Press keys…' : '+ Add',
          style: const TextStyle(
            fontSize: 12,
            color: MacosColors.systemGrayColor,
          ),
        ),
      ),
    );
  }
}
