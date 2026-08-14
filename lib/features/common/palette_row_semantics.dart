/// Pure VoiceOver / semantics label for a command-palette row.
///
/// Mirrors `branch_row_semantics.dart`: a plain function over plain values, so
/// the spoken contract is unit-testable without pumping the palette. Kept out
/// of `command_palette.dart` because that file owns widgets; the category
/// arrives as its already-resolved chip word rather than the enum, so this
/// stays free of widget imports.
library;

/// Builds the accessible label for one palette row.
///
/// A row renders three visually distinct but semantically unlabelled pieces —
/// the command name, an optional shortcut hint, and a bare category chip that
/// VoiceOver would otherwise read as a stray word like "app". This joins them
/// into one utterance, with the list position last so it does not bury the
/// command name.
String paletteRowSemanticsLabel({
  required String label,
  required String categoryPrefix,
  String? shortcut,
  int? position,
  int? count,
}) {
  final parts = <String>[
    label,
    categoryPrefix,
    if (shortcut != null && shortcut.isNotEmpty) 'shortcut $shortcut',
    if (position != null && count != null) 'item $position of $count',
  ];
  return parts.join(', ');
}
