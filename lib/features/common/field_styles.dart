import 'package:flutter/widgets.dart';

/// Shared decorations for text fields across the app.
///
/// The macos_ui default border is nearly invisible on the app's dark canvas, so
/// these give every `MacosTextField` a subtly filled box with a clearly — but
/// not brightly — visible outline, and a blue outline on focus. Apply via
/// `decoration:`/`focusedDecoration:`. `LabeledTextField` sets them for every
/// labelled field; raw `MacosTextField`s set them directly.
const kAppTextFieldRadius = BorderRadius.all(Radius.circular(6));

const kAppTextFieldDecoration = BoxDecoration(
  color: Color(0xFF2C2C2E),
  border: Border.fromBorderSide(BorderSide(color: Color(0xFF5A5A5C))),
  borderRadius: kAppTextFieldRadius,
);

const kAppTextFieldFocusedDecoration = BoxDecoration(
  color: Color(0xFF2C2C2E),
  border: Border.fromBorderSide(BorderSide(color: Color(0xFF0A84FF), width: 2)),
  borderRadius: kAppTextFieldRadius,
);
