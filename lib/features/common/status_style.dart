import 'package:flutter/widgets.dart';
import 'package:macos_ui/macos_ui.dart';
import '../../core/utils/git_porcelain_parser.dart';

/// The one-letter code and accent color for a file's git status — the single
/// source of truth shared by the working-tree list (rendered as a [GitStatusBadge])
/// and the file-tree pane (rendered as colored text), so both follow the same
/// convention:
///
///   U untracked (green) · A added (green) · M/T modified (yellow) ·
///   D deleted (red) · R/C renamed/copied (teal) · ! conflict (red)
///
/// [staged] disambiguates a file that is both staged and modified: pass true in
/// the staged section (index code), false in the changes section (worktree
/// code), or null to prefer the worktree code then the index code.
(String letter, Color color) gitStatusLetter(GitFileStatus s, {bool? staged}) {
  if (s.isUntracked) return ('U', MacosColors.systemGreenColor);
  if (s.isUnmerged) return ('!', MacosColors.systemRedColor);

  final String? code;
  if (staged == true) {
    code = _code(s.statusX);
  } else if (staged == false) {
    code = _code(s.statusY);
  } else {
    code = _code(s.statusY) ?? _code(s.statusX);
  }

  final c = code ?? 'M';
  final color = switch (c) {
    'A' => MacosColors.systemGreenColor,
    'M' || 'T' => MacosColors.systemYellowColor,
    'D' => MacosColors.systemRedColor,
    'R' || 'C' => MacosColors.systemTealColor,
    _ => MacosColors.systemGrayColor,
  };
  return (c, color);
}

// The meaningful one-letter git code, or null for "unchanged here" ('.', ' ').
String? _code(String raw) {
  final t = raw.trim().toUpperCase();
  if (t.isEmpty || t == '.') return null;
  return t;
}

/// A polished circular status badge: the status letter tinted by change kind on
/// a matching translucent fill + ring. Used in the working-tree status list.
class GitStatusBadge extends StatelessWidget {
  final GitFileStatus status;
  final bool? staged;

  const GitStatusBadge(this.status, {super.key, this.staged});

  @override
  Widget build(BuildContext context) {
    final (letter, color) = gitStatusLetter(status, staged: staged);
    return Container(
      width: 18,
      height: 18,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.20),
        shape: BoxShape.circle,
        border: Border.all(color: color.withValues(alpha: 0.55)),
      ),
      child: Text(
        letter,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          height: 1,
        ),
      ),
    );
  }
}
