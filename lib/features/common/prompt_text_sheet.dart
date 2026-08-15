import 'package:flutter/cupertino.dart';
import 'package:macos_ui/macos_ui.dart';
import 'buttons.dart';

import 'escape_dismissible.dart';
import 'field_styles.dart';
import 'sized_sheet.dart';

/// A single-field text prompt (a branch name, a mainline number) — THE shared
/// name-a-thing sheet. Returns the trimmed value, or null if cancelled or
/// left empty. Extracted from the History panel, which grew it first; every
/// panel that needs to ask for one string uses this rather than growing its
/// own subtly-different sheet.
///
/// [validate] (optional) maps the trimmed draft to a problem message, shown
/// inline under the field; while non-null the confirm button is disabled and
/// Enter is inert — so a caller like rename-branch can reject an invalid ref
/// name with a specific message before any round trip.
///
/// [allowEmpty] lets a caller treat a confirmed empty field as a value in its
/// own right (returned as `''` — e.g. "clear this alias") instead of folding
/// it into the cancelled `null`.
Future<String?> promptText(
  BuildContext context,
  String title, {
  required String placeholder,
  String initial = '',
  String? description,
  String confirmLabel = 'OK',
  String? Function(String value)? validate,
  bool allowEmpty = false,
}) async {
  final value = await showMacosSheet<String>(
    context: context,
    builder: (_) => _PromptTextSheet(
      title: title,
      placeholder: placeholder,
      initial: initial,
      description: description,
      confirmLabel: confirmLabel,
      validate: validate,
      allowEmpty: allowEmpty,
    ),
  );
  final trimmed = value?.trim();
  if (allowEmpty) return trimmed;
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
  final String? Function(String value)? validate;
  final bool allowEmpty;

  const _PromptTextSheet({
    required this.title,
    required this.placeholder,
    required this.initial,
    this.description,
    this.confirmLabel = 'OK',
    this.validate,
    this.allowEmpty = false,
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

  String? get _problem => widget.validate?.call(_controller.text.trim());

  void _submit() {
    if (_problem != null) return;
    final text = _controller.text;
    // With allowEmpty a confirmed blank pops '' so the caller can tell
    // "cleared" from a cancel (which pops null).
    Navigator.of(
      context,
    ).pop(text.trim().isEmpty ? (widget.allowEmpty ? '' : null) : text);
  }

  @override
  Widget build(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    return EscapeDismissible(
      child: SizedSheet(
        width: kSheetWidth,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(widget.title, style: typography.title3),
              if (widget.description != null)
                SheetDescription(widget.description!),
              const SizedBox(height: 14),
              // The listener scope covers the field, the inline error, and
              // the confirm button — all three react per keystroke without a
              // whole-sheet setState.
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: _controller,
                builder: (context, value, _) {
                  final problem = _problem;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      MacosTextField(
                        controller: _controller,
                        placeholder: widget.placeholder,
                        placeholderStyle: kAppPlaceholderStyle,
                        autofocus: true,
                        decoration: kAppTextFieldDecoration,
                        focusedDecoration: kAppTextFieldFocusedDecoration,
                        onSubmitted: (_) => _submit(),
                      ),
                      if (problem != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            problem,
                            style: typography.caption1.copyWith(
                              color: MacosColors.systemRedColor,
                            ),
                          ),
                        ),
                      const SizedBox(height: 16),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          AppPushButton(
                            controlSize: ControlSize.large,
                            secondary: true,
                            onPressed: () => Navigator.of(context).pop(),
                            child: const Text('Cancel'),
                          ),
                          const SizedBox(width: 10),
                          AppPushButton(
                            controlSize: ControlSize.large,
                            onPressed: problem != null ? null : _submit,
                            child: Text(widget.confirmLabel),
                          ),
                        ],
                      ),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}
