import 'package:flutter/widgets.dart';
import 'package:macos_ui/macos_ui.dart';
import 'field_styles.dart';

/// A caption-labelled [MacosTextField] — the form-row primitive shared by the
/// connection form and the create-MR sheet.
class LabeledTextField extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final String? placeholder;
  final bool obscure;
  final int maxLines;

  /// Called after each edit so a parent StatefulWidget can re-evaluate its
  /// submit-enabled state. The raw text is read from [controller].
  final VoidCallback? onChanged;

  /// Enter on a single-line field. Multi-line fields leave this null so
  /// Return inserts a newline (same convention as [promptForm]).
  final ValueChanged<String>? onSubmitted;
  final EdgeInsets padding;

  const LabeledTextField({
    super.key,
    required this.label,
    required this.controller,
    this.placeholder,
    this.obscure = false,
    this.maxLines = 1,
    this.onChanged,
    this.onSubmitted,
    this.padding = const EdgeInsets.only(bottom: 12),
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: MacosTheme.of(context).typography.caption1),
          const SizedBox(height: 4),
          MacosTextField(
            controller: controller,
            placeholder: placeholder,
            placeholderStyle: kAppPlaceholderStyle,
            obscureText: obscure,
            maxLines: maxLines,
            decoration: kAppTextFieldDecoration,
            focusedDecoration: kAppTextFieldFocusedDecoration,
            onChanged: onChanged == null ? null : (_) => onChanged!(),
            onSubmitted: maxLines == 1 ? onSubmitted : null,
          ),
        ],
      ),
    );
  }
}
