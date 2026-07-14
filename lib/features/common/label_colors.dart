import 'package:flutter/widgets.dart';
import 'package:macos_ui/macos_ui.dart';

/// Label-color parsing shared by every forge surface. GitHub and GitLab both
/// hand labels over as `#RRGGBB` hex (GhLabel normalizes GitHub's bare hex to
/// the prefixed form on parse), and both feature trees had grown their own
/// byte-identical copies of these — six in total — before they were pulled
/// here.

/// Parses a `#RRGGBB` label color; null when malformed.
///
/// Only a full 6-digit RRGGBB is valid; the parse forces the color opaque
/// (0xFF alpha). Anything else (e.g. a 3-digit `#abc` shorthand) would parse
/// *without* an alpha byte — `Color(0x00000abc)`, fully transparent → an
/// invisible chip — so malformed input is refused instead.
Color? tryParseLabelColor(String hex) {
  var h = hex.trim();
  if (h.startsWith('#')) h = h.substring(1);
  if (h.length != 6) return null;
  final v = int.tryParse(h, radix: 16);
  return v == null ? null : Color(0xFF000000 | v);
}

/// [tryParseLabelColor] with the list panes' gray fallback for malformed
/// input (the create sheets prefer their own accent fallback — they call the
/// nullable form directly).
Color parseLabelColor(String hex) =>
    tryParseLabelColor(hex) ?? MacosColors.systemGrayColor;

/// Chooses readable foreground (black/white) for a label background color.
Color labelTextColor(Color background) => background.computeLuminance() > 0.5
    ? const Color(0xFF000000)
    : const Color(0xFFFFFFFF);
