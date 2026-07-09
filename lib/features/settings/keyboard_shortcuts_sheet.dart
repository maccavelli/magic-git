import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';
import '../../core/settings/keymap.dart';
import '../common/tool_icon_button.dart';

/// A read-only cheat sheet of every shortcut, grouped by category and reflecting
/// the user's current (possibly customized) bindings — generated straight from
/// [kKeymapActions] + [keymapProvider], so it never drifts from what's actually
/// bound. Opened by the `global.showShortcuts` action (⌘/). Editing lives in the
/// separate Keyboard Mappings sheet; this one is purely for looking things up.
class KeyboardShortcutsSheet extends ConsumerWidget {
  const KeyboardShortcutsSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final typography = MacosTheme.of(context).typography;
    final keymap = ref.watch(keymapProvider);

    final byCategory = <KeymapCategory, List<KeymapAction>>{};
    for (final action in kKeymapActions) {
      byCategory.putIfAbsent(action.category, () => []).add(action);
    }

    return MacosSheet(
      // Escape closes the sheet, matching the standard dismiss affordance.
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): () =>
              Navigator.of(context).pop(),
        },
        child: Focus(
          autofocus: true,
          child: SizedBox(
            width: 560,
            // Capped to the viewport so the Close row stays reachable at the
            // minimum window size — the category list scrolls instead.
            height: (MediaQuery.sizeOf(context).height - 80).clamp(
              320.0,
              560.0,
            ),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const MacosIcon(CupertinoIcons.command, size: 18),
                      const SizedBox(width: 8),
                      Text('Keyboard Shortcuts', style: typography.title2),
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
                    'Customize these in Settings → Keyboard Mappings. '
                    'Panel shortcuts apply while that panel is active.',
                    style: typography.caption1.copyWith(
                      color: MacosColors.systemGrayColor,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: ListView(
                      children: [
                        for (final category in KeymapCategory.values)
                          if (byCategory[category]?.isNotEmpty ?? false) ...[
                            Padding(
                              padding: const EdgeInsets.only(top: 14, bottom: 4),
                              child: Text(
                                category.label,
                                style: typography.headline,
                              ),
                            ),
                            for (final action in byCategory[category]!)
                              _row(
                                context,
                                action,
                                keymap[action.id] ?? const <KeyBinding>[],
                              ),
                          ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _row(
    BuildContext context,
    KeymapAction action,
    List<KeyBinding> bindings,
  ) {
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
          if (bindings.isEmpty)
            Text(
              'Unassigned',
              style: MacosTheme.of(context).typography.caption1.copyWith(
                color: MacosColors.systemGrayColor,
              ),
            )
          else
            for (final b in bindings) ...[
              _keyChip(b.label),
              const SizedBox(width: 6),
            ],
        ],
      ),
    );
  }

  Widget _keyChip(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        border: Border.all(color: MacosColors.separatorColor),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(label, style: const TextStyle(fontSize: 12)),
    );
  }
}
