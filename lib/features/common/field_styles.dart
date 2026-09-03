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

/// Outline for a field that is required right now and not yet valid.
/// Same fill as [kAppTextFieldDecoration]; macOS dark-mode system red
/// (`#FF453A`) so it reads as the same danger as `MacosColors.systemRedColor`
/// without importing macos_ui into this file.
const kAppTextFieldErrorDecoration = BoxDecoration(
  color: Color(0xFF2C2C2E),
  border: Border.fromBorderSide(BorderSide(color: Color(0xFFFF453A))),
  borderRadius: kAppTextFieldRadius,
);

const kAppTextFieldErrorFocusedDecoration = BoxDecoration(
  color: Color(0xFF2C2C2E),
  border: Border.fromBorderSide(BorderSide(color: Color(0xFFFF453A), width: 2)),
  borderRadius: kAppTextFieldRadius,
);

/// Placeholder (hint) text style for `MacosTextField`s. macos_ui's default is a
/// `CupertinoDynamicColor` (`CupertinoColors.placeholderText`) that resolves
/// against the *system* brightness — so on this dark-only app running under a
/// light-mode system it comes out dark-on-dark and is invisible against the
/// field fill. This is a fixed, clearly-visible muted gray tuned for the dark
/// canvas. Pass via `placeholderStyle:` on any field with a `placeholder:`.
const kAppPlaceholderStyle = TextStyle(color: Color(0xFF8E8E93));

/// Debounce for text-input-driven refetches (the history search filter and
/// the PR/MR preview diff) — long enough to let typing settle, short enough
/// to feel live. One value so every "type, then fetch" field feels the same.
const kInputDebounce = Duration(milliseconds: 350);
