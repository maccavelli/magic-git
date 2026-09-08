import 'package:flutter/widgets.dart';
import 'package:macos_ui/macos_ui.dart';
import 'field_styles.dart';

/// A caption-labelled [MacosTextField] — the form-row primitive shared by the
/// connection form, the create-MR sheet and the create-repository wizard.
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

  /// Rendered directly below the field, inside the same padded column — the
  /// wizard's explanatory `FieldHint`/`WizardHint` slot. The hint carries its
  /// own top padding, so this composes without extra spacing.
  final Widget? hint;

  /// Swaps the normal/focused decorations for their error variants, so a
  /// field can show inline validation without the caller rebuilding the row.
  final bool showError;

  /// Lets a caller observe or drive focus — a field with an attached dropdown
  /// needs to know when it is being typed in. The field owns no node of its
  /// own when this is null, exactly as before.
  final FocusNode? focusNode;

  /// Rendered inside the field, before the text — a magnifier on a search
  /// input, for instance, so the affordance reads as search rather than as one
  /// more field to fill in.
  final Widget? prefix;

  /// Shows macOS's in-field clear (ⓧ) button once there is something to
  /// clear. Off by default: an ordinary form field has a label telling you
  /// what belongs in it, and a clear button there is noise.
  final OverlayVisibilityMode clearButtonMode;

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
    this.hint,
    this.showError = false,
    this.focusNode,
    this.prefix,
    this.clearButtonMode = OverlayVisibilityMode.never,
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
            focusNode: focusNode,
            prefix: prefix,
            clearButtonMode: clearButtonMode,
            placeholder: placeholder,
            placeholderStyle: kAppPlaceholderStyle,
            obscureText: obscure,
            maxLines: maxLines,
            decoration: showError
                ? kAppTextFieldErrorDecoration
                : kAppTextFieldDecoration,
            focusedDecoration: showError
                ? kAppTextFieldErrorFocusedDecoration
                : kAppTextFieldFocusedDecoration,
            onChanged: onChanged == null ? null : (_) => onChanged!(),
            onSubmitted: maxLines == 1 ? onSubmitted : null,
          ),
          ?hint,
        ],
      ),
    );
  }
}
