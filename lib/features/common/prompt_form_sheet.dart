import 'package:flutter/cupertino.dart';
import 'package:macos_ui/macos_ui.dart';

import 'buttons.dart';
import 'escape_dismissible.dart';
import 'field_styles.dart';
import 'sized_sheet.dart';

/// One field in a [promptForm]: a labelled text input, optionally multi-line.
class PromptField {
  final String key;
  final String label;
  final String placeholder;
  final String initial;

  /// Multi-line grows to [maxLines] as text is entered (a description/body);
  /// single-line (the default) submits on Enter.
  final bool multiline;
  final int maxLines;

  /// Optional validator: maps the trimmed value to a problem message (shown
  /// under the field) or null when valid. While ANY field reports a problem the
  /// confirm button is disabled.
  final String? Function(String value)? validate;

  const PromptField({
    required this.key,
    required this.label,
    this.placeholder = '',
    this.initial = '',
    this.multiline = false,
    this.maxLines = 10,
    this.validate,
  });
}

/// A multi-field sheet — the multi-line sibling of `promptText`. Presents a
/// titled form of [fields] (any of which may be multi-line) and returns the
/// trimmed values keyed by [PromptField.key], or null if cancelled. The confirm
/// button stays disabled while any field's validator reports a problem. THE
/// shared "edit these fields" sheet — reuse it rather than growing a bespoke
/// one per caller.
Future<Map<String, String>?> promptForm(
  BuildContext context,
  String title, {
  required List<PromptField> fields,
  String? description,
  String confirmLabel = 'Save',
}) {
  return showMacosSheet<Map<String, String>>(
    context: context,
    builder: (_) => _PromptFormSheet(
      title: title,
      fields: fields,
      description: description,
      confirmLabel: confirmLabel,
    ),
  );
}

/// Owns the per-field controllers so their disposal happens with the sheet's
/// own State (disposing them the moment the sheet popped would race the
/// dismiss animation still rebuilding the fields against them).
class _PromptFormSheet extends StatefulWidget {
  final String title;
  final List<PromptField> fields;
  final String? description;
  final String confirmLabel;

  const _PromptFormSheet({
    required this.title,
    required this.fields,
    required this.description,
    required this.confirmLabel,
  });

  @override
  State<_PromptFormSheet> createState() => _PromptFormSheetState();
}

class _PromptFormSheetState extends State<_PromptFormSheet> {
  late final List<TextEditingController> _controllers = [
    for (final f in widget.fields) TextEditingController(text: f.initial),
  ];

  // Focus the first field once, post-frame, instead of `autofocus: true` —
  // the live-validation rebuilds recreate the field widgets on every keystroke,
  // and an autofocus that re-fired on rebuild would keep yanking the caret back
  // to the first field while you type in a later one.
  final FocusNode _firstFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _firstFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    for (final c in _controllers) {
      c.dispose();
    }
    _firstFocus.dispose();
    super.dispose();
  }

  String? _problemFor(int i) =>
      widget.fields[i].validate?.call(_controllers[i].text.trim());

  bool get _valid {
    for (var i = 0; i < widget.fields.length; i++) {
      if (_problemFor(i) != null) return false;
    }
    return true;
  }

  void _submit() {
    if (!_valid) return;
    Navigator.of(context).pop(<String, String>{
      for (var i = 0; i < widget.fields.length; i++)
        widget.fields[i].key: _controllers[i].text.trim(),
    });
  }

  @override
  Widget build(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    return EscapeDismissible(
      child: SizedSheet(
        width: kSheetWidth,
        child: Padding(
          padding: const EdgeInsets.all(20),
          // The whole form rebuilds per keystroke so each field's inline error
          // and the confirm button react live; the controllers + focus node are
          // State fields, so nothing is lost across the rebuild.
          child: AnimatedBuilder(
            animation: Listenable.merge(_controllers),
            builder: (context, _) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(widget.title, style: typography.title3),
                if (widget.description != null)
                  SheetDescription(widget.description!),
                const SizedBox(height: 14),
                for (var i = 0; i < widget.fields.length; i++)
                  ..._fieldWidgets(i, typography),
                const SizedBox(height: 4),
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
                      onPressed: _valid ? _submit : null,
                      child: Text(widget.confirmLabel),
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

  List<Widget> _fieldWidgets(int i, MacosTypography typography) {
    final field = widget.fields[i];
    final problem = _problemFor(i);
    return [
      Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Text(
          field.label,
          style: typography.caption1.copyWith(
            color: MacosColors.systemGrayColor,
          ),
        ),
      ),
      MacosTextField(
        controller: _controllers[i],
        focusNode: i == 0 ? _firstFocus : null,
        placeholder: field.placeholder,
        placeholderStyle: kAppPlaceholderStyle,
        maxLines: field.multiline ? field.maxLines : 1,
        decoration: kAppTextFieldDecoration,
        focusedDecoration: kAppTextFieldFocusedDecoration,
        // Enter submits a single-line field; in a multi-line field it inserts
        // a newline (so no onSubmitted there).
        onSubmitted: field.multiline ? null : (_) => _submit(),
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
      const SizedBox(height: 12),
    ];
  }
}
