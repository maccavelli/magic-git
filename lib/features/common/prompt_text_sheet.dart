import 'package:flutter/cupertino.dart';
import 'package:macos_ui/macos_ui.dart';

import 'escape_dismissible.dart';
import 'field_styles.dart';
import 'sized_sheet.dart';

/// A single-field text prompt (a branch name, a mainline number) — THE shared
/// name-a-thing sheet. Returns the trimmed value, or null if cancelled or
/// left empty. Extracted from the History panel, which grew it first; every
/// panel that needs to ask for one string uses this rather than growing its
/// own subtly-different sheet.
Future<String?> promptText(
  BuildContext context,
  String title, {
  required String placeholder,
  String initial = '',
  String? description,
  String confirmLabel = 'OK',
}) async {
  final value = await showMacosSheet<String>(
    context: context,
    builder: (_) => _PromptTextSheet(
      title: title,
      placeholder: placeholder,
      initial: initial,
      description: description,
      confirmLabel: confirmLabel,
    ),
  );
  final trimmed = value?.trim();
  return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
}

/// Owns its [TextEditingController] so disposal happens with the sheet's own
/// State — the original hand-rolled version disposed the controller the
/// moment the sheet POPPED, while the dismiss animation was still rebuilding
/// the text field against it ("used after being disposed").
class _PromptTextSheet extends StatefulWidget {
  final String title;
  final String placeholder;
  final String initial;
  final String? description;
  final String confirmLabel;

  const _PromptTextSheet({
    required this.title,
    required this.placeholder,
    required this.initial,
    this.description,
    this.confirmLabel = 'OK',
  });

  @override
  State<_PromptTextSheet> createState() => _PromptTextSheetState();
}

class _PromptTextSheetState extends State<_PromptTextSheet> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return EscapeDismissible(
      child: SizedSheet(
        width: kSheetWidth,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.title,
                style: MacosTheme.of(context).typography.title3,
              ),
              if (widget.description != null)
                SheetDescription(widget.description!),
              const SizedBox(height: 14),
              MacosTextField(
                controller: _controller,
                placeholder: widget.placeholder,
                placeholderStyle: kAppPlaceholderStyle,
                autofocus: true,
                decoration: kAppTextFieldDecoration,
                focusedDecoration: kAppTextFieldFocusedDecoration,
                onSubmitted: (v) =>
                    Navigator.of(context).pop(v.trim().isEmpty ? null : v),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  PushButton(
                    controlSize: ControlSize.large,
                    secondary: true,
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 10),
                  PushButton(
                    controlSize: ControlSize.large,
                    onPressed: () => Navigator.of(context).pop(
                      _controller.text.trim().isEmpty
                          ? null
                          : _controller.text,
                    ),
                    child: Text(widget.confirmLabel),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
