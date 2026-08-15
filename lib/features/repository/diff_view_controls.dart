import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../core/settings/keymap.dart';
import '../common/tool_icon_button.dart';

class DiffViewControls extends ConsumerWidget {
  final bool split;
  final bool ignoreWhitespace;
  final bool expandedContext;
  final bool blame;
  final VoidCallback onToggleSplit;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final VoidCallback onToggleWhitespace;
  final VoidCallback onToggleContext;
  final VoidCallback onToggleBlame;
  final VoidCallback onPopOut;
  final VoidCallback onClose;

  const DiffViewControls({
    super.key,
    required this.split,
    required this.ignoreWhitespace,
    required this.expandedContext,
    required this.blame,
    required this.onToggleSplit,
    required this.onPrevious,
    required this.onNext,
    required this.onToggleWhitespace,
    required this.onToggleContext,
    required this.onToggleBlame,
    required this.onPopOut,
    required this.onClose,
  });

  Color _color(bool active) =>
      active ? MacosColors.systemBlueColor : MacosColors.systemGrayColor;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Live-keymap suffix for the split toggle's tooltip (0009 L10) — the
    // chord exists (⌘⌥S by default) but the tooltip never taught it.
    final splitBindings = ref.watch(
      keymapProvider,
    )['repository.toggleSplitDiff'];
    final splitSuffix = (splitBindings == null || splitBindings.isEmpty)
        ? ''
        : ' (${splitBindings.first.label})';
    final hunkReason = split
        ? 'Hunk actions are unavailable in split view'
        : ignoreWhitespace
        ? 'Hunk actions are unavailable while whitespace is ignored'
        : 'Unified diff supports hunk actions';
    return Semantics(
      container: true,
      label: 'Diff view controls. $hunkReason',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ToolIconButton(
            icon: CupertinoIcons.chevron_up,
            tooltip: 'Previous changed file',
            size: 14,
            onPressed: onPrevious,
          ),
          ToolIconButton(
            icon: CupertinoIcons.chevron_down,
            tooltip: 'Next changed file',
            size: 14,
            onPressed: onNext,
          ),
          ToolIconButton(
            icon: CupertinoIcons.square_split_2x1,
            tooltip:
                '${split ? 'Use unified diff' : 'Use split diff'}$splitSuffix',
            size: 15,
            color: _color(split),
            onPressed: onToggleSplit,
          ),
          MacosPulldownButton(
            icon: CupertinoIcons.ellipsis_circle,
            items: [
              MacosPulldownMenuItem(
                title: Text(
                  ignoreWhitespace
                      ? 'Show whitespace changes'
                      : 'Ignore whitespace',
                ),
                onTap: onToggleWhitespace,
              ),
              MacosPulldownMenuItem(
                title: Text(
                  expandedContext ? 'Use normal context' : 'Expand context',
                ),
                onTap: onToggleContext,
              ),
              MacosPulldownMenuItem(
                title: Text(blame ? 'Hide blame' : 'Show blame'),
                onTap: onToggleBlame,
              ),
              const MacosPulldownMenuDivider(),
              MacosPulldownMenuItem(
                title: const Text('Open diff in larger window'),
                onTap: onPopOut,
              ),
            ],
          ),
          ToolIconButton(
            icon: CupertinoIcons.xmark,
            tooltip: 'Close diff',
            size: 15,
            color: MacosColors.systemGrayColor,
            onPressed: onClose,
          ),
        ],
      ),
    );
  }
}
