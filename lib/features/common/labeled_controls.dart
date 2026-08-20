import 'package:flutter/widgets.dart';
import 'package:macos_ui/macos_ui.dart';

import 'tappable.dart';

/// A checkbox with a clickable label.
///
/// On macOS a checkbox is an `NSButton` whose **title is part of the
/// control**, so clicking the text toggles it. `macos_ui` ships only the
/// glyph ([MacosCheckbox]) and leaves the label to the call site, so that
/// behaviour has to be rebuilt — and was, at one call site out of ten, until
/// this widget. Pairs with [LabeledRadio]; same relationship to
/// [MacosCheckbox] that [LabeledTextField] has to `MacosTextField`.
///
/// A null [onChanged] disables both halves: [Tappable] with a null `onTap`
/// keeps the arrow cursor, matching `AppPushButton`'s disabled semantics.
///
/// Deliberately not extended to `MacosSwitch`: `NSSwitch` has no title, and
/// AppKit does not toggle a switch from an adjacent label, so doing it there
/// would invent behaviour rather than restore it.
class LabeledCheckbox extends StatelessWidget {
  final String label;
  final bool value;
  final ValueChanged<bool>? onChanged;

  /// Defaults to the ambient body style.
  final TextStyle? style;

  /// Let the label take the row's remaining width, so a long label wraps
  /// instead of overflowing. Requires a **bounded** parent — true inside a
  /// sheet column, false in a toolbar row that is itself unbounded, where
  /// the label is sized to its content instead.
  final bool expand;

  const LabeledCheckbox({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.style,
    this.expand = false,
  });

  @override
  Widget build(BuildContext context) {
    final callback = onChanged;
    return _controlRow(
      glyph: MacosCheckbox(value: value, onChanged: callback),
      label: label,
      style: style,
      expand: expand,
      onTap: callback == null ? null : () => callback(!value),
    );
  }
}

/// A radio button with a clickable label. See [LabeledCheckbox] for why the
/// label has to be made clickable by hand.
class LabeledRadio<T> extends StatelessWidget {
  final String label;
  final T value;
  final T? groupValue;
  final ValueChanged<T>? onChanged;
  final TextStyle? style;
  final bool expand;

  const LabeledRadio({
    super.key,
    required this.label,
    required this.value,
    required this.groupValue,
    required this.onChanged,
    this.style,
    this.expand = true,
  });

  @override
  Widget build(BuildContext context) {
    final callback = onChanged;
    return _controlRow(
      glyph: MacosRadioButton<T>(
        value: value,
        groupValue: groupValue,
        onChanged: callback == null
            ? null
            : (v) {
                if (v != null) callback(v);
              },
      ),
      label: label,
      style: style,
      expand: expand,
      onTap: callback == null ? null : () => callback(value),
    );
  }
}

/// The glyph, a gap, and the clickable label.
///
/// [expand] picks between the two layouts, and the choice is load-bearing:
/// an `Expanded`/`Flexible` label inside a Row nested in another *unbounded*
/// Row cannot be laid out at all (the toolbar rows in the history and branch
/// panels are exactly that). So the non-expanding form takes no flex and
/// sizes the whole row to its content.
Widget _controlRow({
  required Widget glyph,
  required String label,
  required TextStyle? style,
  required bool expand,
  required VoidCallback? onTap,
}) {
  final text = Tappable(
    onTap: onTap,
    // Opaque so the whole label box is the hit target, not just the glyphs.
    behavior: HitTestBehavior.opaque,
    child: Text(label, style: style),
  );
  return Row(
    mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
    children: [
      glyph,
      const SizedBox(width: 8),
      if (expand) Expanded(child: text) else text,
    ],
  );
}
