import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show SelectableText;
import 'package:flutter/services.dart';
import 'package:macos_ui/macos_ui.dart';

import 'tool_icon_button.dart';

/// A labelled command for the user to run by hand: a Copy button that puts the
/// exact text on the clipboard, and the text itself, selectable, in monospace.
///
/// Shared by the environment health sheet's install hints and the Windows
/// shell prompt (MADR 0070), so every command the app hands to a user looks,
/// selects and copies the same way — byte-for-byte, because a pasted command
/// that differs from the one shown is a command the user did not agree to.
class CopyableCommandBlock extends StatelessWidget {
  const CopyableCommandBlock({
    super.key,
    required this.label,
    required this.command,
  });

  final String label;
  final String command;

  @override
  Widget build(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: typography.caption1.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            ToolIconButton(
              icon: CupertinoIcons.doc_on_clipboard,
              tooltip: 'Copy command',
              onPressed: () => Clipboard.setData(ClipboardData(text: command)),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: MacosColors.black.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(4),
          ),
          child: SelectableText(
            command,
            style: const TextStyle(
              fontFamily: 'Menlo',
              fontSize: 11.5,
              height: 1.4,
            ),
          ),
        ),
      ],
    );
  }
}
