/// Word-level (intra-line) diff between a removed line and the added line that
/// replaced it.
///
/// A unified diff marks a modified line as a whole `-`/`+` pair, but the eye
/// wants to see *what within the line* changed. Given the two line contents
/// (marker already stripped), [computeIntralineDiff] returns the character
/// ranges that actually differ on each side, so a renderer can emphasise just
/// those runs instead of painting the entire line as changed.
///
/// The algorithm is a token-level longest-common-subsequence: both lines are
/// split into tokens (a maximal run of word characters, or a single other
/// character — so whitespace and punctuation align on their own), an LCS is
/// computed over the token texts, and every token *not* on the common
/// subsequence is reported as a changed range (contiguous changed tokens are
/// merged). Word tokens keep the highlight from fragmenting mid-identifier the
/// way a raw character diff does.
library;

/// A half-open `[start, end)` character range within one line's content.
class IntralineRange {
  final int start;
  final int end;

  const IntralineRange(this.start, this.end);

  @override
  bool operator ==(Object other) =>
      other is IntralineRange && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => 'IntralineRange($start, $end)';
}

/// The changed character ranges on each side of a modified line pair.
class IntralineDiff {
  /// Changed runs within the removed line's content.
  final List<IntralineRange> oldRanges;

  /// Changed runs within the added line's content.
  final List<IntralineRange> newRanges;

  const IntralineDiff({required this.oldRanges, required this.newRanges});

  static const IntralineDiff none = IntralineDiff(oldRanges: [], newRanges: []);

  bool get isEmpty => oldRanges.isEmpty && newRanges.isEmpty;
}

/// Above this content length (on either side) the O(n·m) token LCS is skipped
/// in favour of a cheap common-prefix/suffix trim, so a pair of very long lines
/// (a minified bundle, a lockfile row) can't stall the UI thread.
const int _intralineMaxLen = 2000;

/// Computes the intra-line diff between [oldLine] and [newLine] (marker-stripped
/// line contents). Returns [IntralineDiff.none] when the lines are identical.
IntralineDiff computeIntralineDiff(String oldLine, String newLine) {
  if (oldLine == newLine) return IntralineDiff.none;
  if (oldLine.isEmpty) {
    return IntralineDiff(
      oldRanges: const [],
      newRanges: [IntralineRange(0, newLine.length)],
    );
  }
  if (newLine.isEmpty) {
    return IntralineDiff(
      oldRanges: [IntralineRange(0, oldLine.length)],
      newRanges: const [],
    );
  }

  if (oldLine.length > _intralineMaxLen || newLine.length > _intralineMaxLen) {
    return _affixTrimDiff(oldLine, newLine);
  }

  final oldToks = _tokenize(oldLine);
  final newToks = _tokenize(newLine);
  final (oldMatched, newMatched) = _lcsMatches(oldToks, newToks);

  return IntralineDiff(
    oldRanges: _changedRanges(oldToks, oldMatched),
    newRanges: _changedRanges(newToks, newMatched),
  );
}

/// A token: the substring [text] of the line spanning `[start, end)`.
class _Token {
  final String text;
  final int start;
  final int end;
  const _Token(this.text, this.start, this.end);
}

bool _isWordChar(int codeUnit) =>
    (codeUnit >= 0x30 && codeUnit <= 0x39) || // 0-9
    (codeUnit >= 0x41 && codeUnit <= 0x5A) || // A-Z
    (codeUnit >= 0x61 && codeUnit <= 0x7A) || // a-z
    codeUnit == 0x5F || // _
    codeUnit >= 0x80; // keep non-ASCII (identifiers, CJK) out of char-splitting

/// Splits [s] into tokens: maximal runs of word characters, and every other
/// character as its own token (so whitespace/punctuation align independently).
List<_Token> _tokenize(String s) {
  final tokens = <_Token>[];
  var i = 0;
  while (i < s.length) {
    final startCode = s.codeUnitAt(i);
    if (_isWordChar(startCode)) {
      final start = i;
      while (i < s.length && _isWordChar(s.codeUnitAt(i))) {
        i++;
      }
      tokens.add(_Token(s.substring(start, i), start, i));
    } else {
      tokens.add(_Token(s.substring(i, i + 1), i, i + 1));
      i++;
    }
  }
  return tokens;
}

/// Longest-common-subsequence over token texts. Returns two boolean masks:
/// which tokens of [a] / [b] lie on the common subsequence (i.e. are unchanged).
(List<bool>, List<bool>) _lcsMatches(List<_Token> a, List<_Token> b) {
  final n = a.length;
  final m = b.length;
  // dp[i][j] = LCS length of a[i..] and b[j..].
  final dp = List.generate(n + 1, (_) => List<int>.filled(m + 1, 0));
  for (var i = n - 1; i >= 0; i--) {
    for (var j = m - 1; j >= 0; j--) {
      dp[i][j] = a[i].text == b[j].text
          ? dp[i + 1][j + 1] + 1
          : (dp[i + 1][j] >= dp[i][j + 1] ? dp[i + 1][j] : dp[i][j + 1]);
    }
  }
  final aMatched = List<bool>.filled(n, false);
  final bMatched = List<bool>.filled(m, false);
  var i = 0;
  var j = 0;
  while (i < n && j < m) {
    if (a[i].text == b[j].text) {
      aMatched[i] = true;
      bMatched[j] = true;
      i++;
      j++;
    } else if (dp[i + 1][j] >= dp[i][j + 1]) {
      i++;
    } else {
      j++;
    }
  }
  return (aMatched, bMatched);
}

/// Collapses the unmatched (changed) tokens into merged character ranges.
List<IntralineRange> _changedRanges(List<_Token> tokens, List<bool> matched) {
  final ranges = <IntralineRange>[];
  int? runStart;
  int? runEnd;
  for (var k = 0; k < tokens.length; k++) {
    if (matched[k]) {
      if (runStart != null) {
        ranges.add(IntralineRange(runStart, runEnd!));
        runStart = null;
        runEnd = null;
      }
    } else {
      runStart ??= tokens[k].start;
      runEnd = tokens[k].end;
    }
  }
  if (runStart != null) ranges.add(IntralineRange(runStart, runEnd!));
  return ranges;
}

/// Cheap fallback for very long lines: mark the single middle span that isn't a
/// shared prefix or suffix as changed on each side.
IntralineDiff _affixTrimDiff(String oldLine, String newLine) {
  final maxPrefix = oldLine.length < newLine.length
      ? oldLine.length
      : newLine.length;
  var prefix = 0;
  while (prefix < maxPrefix &&
      oldLine.codeUnitAt(prefix) == newLine.codeUnitAt(prefix)) {
    prefix++;
  }
  var suffix = 0;
  while (suffix < maxPrefix - prefix &&
      oldLine.codeUnitAt(oldLine.length - 1 - suffix) ==
          newLine.codeUnitAt(newLine.length - 1 - suffix)) {
    suffix++;
  }
  final oldEnd = oldLine.length - suffix;
  final newEnd = newLine.length - suffix;
  return IntralineDiff(
    oldRanges: prefix < oldEnd ? [IntralineRange(prefix, oldEnd)] : const [],
    newRanges: prefix < newEnd ? [IntralineRange(prefix, newEnd)] : const [],
  );
}
