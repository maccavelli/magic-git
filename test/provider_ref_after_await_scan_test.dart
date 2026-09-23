// Pins MADR 0050: a provider body must not touch `ref` in a statement that
// begins after an earlier `await` inside that same body. Riverpod wants
// dependencies registered synchronously — a `ref.watch` issued after an
// `await` may be silently dropped on a rebuild, and a provider disposed
// while that `await` is still pending throws "Cannot use the Ref ... after
// it has been disposed" the moment any post-`await` statement touches `ref`.
//
// The declaration-boundary scanner below (`_declarationEnd`/
// `_argumentListOpen`/`_skipString`) is copied from
// `provider_retry_policy_test.dart`, which already solved finding where a
// provider's body ends in this codebase (shell heredocs with unbalanced
// parens in string literals, record types opening a paren before the
// argument list does). This file adds the ref-after-await check on top.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('no provider body uses ref in a statement after an earlier await', () {
    // file#provider -> reason. Keyed by the provider's declared name, not its
    // line: a line key went stale whenever anything was added above it in a
    // long file, and the guard then failed on sites it had already reviewed
    // (0070-PLAN D3). A match here has been checked by hand and is not
    // a live defect, for one of three reasons (MADR 0050's Option C):
    //  - a textual false positive: the `ref` use is inside a separate
    //    asynchronous context (a Timer/Stream callback), not the provider's
    //    own build continuation, and that callback already guards with
    //    `ref.mounted`;
    //  - a textual false positive: the `ref` use is in a branch that never
    //    runs alongside the branch containing the flagged `await` (this
    //    scanner is textual, not branch-aware, so an `if`/`else` where only
    //    one side awaits reads as "after" the other side's await even
    //    though they're mutually exclusive);
    //  - a real site the scan is right to flag, resolved with a
    //    `ref.mounted` guard rather than a hoist because the call genuinely
    //    needs the awaited value (so hoisting would mean doing the work, or
    //    picking the branch, before knowing what to do) — the guard turns a
    //    disposed-mid-`await` throw into a quiet early return instead.
    const allowed = <String, String>{
      'lib/core/providers/app_providers.dart#autoFetchProvider': //
          'autoFetchProvider: the flagged ref calls are inside its '
          'Timer.periodic callback, a separate async context from the '
          "provider's own (synchronous) build, and are already guarded "
          'with `if (!ref.mounted) return;` before each one.',
      'lib/core/providers/app_providers.dart#remoteTagsProvider': //
          'remoteTagsProvider: `keepAlive`/`onDispose` only make sense once '
          '`remote` (the awaited value) is known, so they cannot be '
          'hoisted; guarded with `if (!ref.mounted) return null;` instead.',
      'lib/core/providers/app_providers.dart#forgeProvider': //
          'forgeProvider: `keepAlive` depends on the awaited `forge`, so it '
          'cannot be hoisted; guarded with `if (ref.mounted && ...)` '
          'instead.',
      'lib/core/providers/app_providers.dart#forgeRepoListProvider': //
          'forgeRepoListProvider: the flagged read is in the `if (local)` '
          "branch; the scan's first-await search lands on the `else` "
          "branch's await, which never runs in the same call as the "
          'flagged branch.',
      'lib/features/branches/pinned_branches.dart#pinnedBranchesProvider': //
          'pinnedBranchesProvider: the flagged watch is in the `else` path '
          'of an early-return `if`; the scan\'s first-await search lands on '
          "the `if` branch's await (`return await _legacyPins(...)`), which "
          'never runs in the same call as the flagged watch.',
      'lib/core/forge/branch_forge_status.dart#branchForgeProvider': //
          'branchForgeProvider: each switch case watches a different '
          'provider depending on the awaited `forge`, so none can be '
          'hoisted without watching all of them regardless of forge — a '
          'real behaviour change; guarded with `if (!ref.mounted) return '
          'const {};` instead.',
      'lib/core/forge/branch_forge_status.dart#protectedBranchRulesProvider': //
          'protectedBranchRulesProvider: same shape as branchForgeProvider '
          'above — guarded, not hoisted, for the same reason.',
      'lib/core/forge/branch_forge_status.dart#branchForgeKnowledgeProvider': //
          'branchForgeKnowledgeProvider: same shape as branchForgeProvider '
          'above — guarded, not hoisted, for the same reason.',
    };

    final offenders = <String>[];

    for (final file
        in Directory('lib')
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart'))) {
      final source = file.readAsStringSync();
      for (final match in _declaration.allMatches(source)) {
        final start = match.start;
        final int end;
        try {
          end = _declarationEnd(source, start);
        } on StateError {
          continue;
        }
        final body = source.substring(start, end);
        final hit = _refAfterFirstAwait(body);
        if (hit == null) continue;
        final key = '${file.path}#${match[1]}';
        if (allowed.containsKey(key)) continue;
        offenders.add('$key (line ${_lineOf(source, start)}): $hit');
      }
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'A provider must register every `ref.watch`/`ref.read`/`ref.listen`/'
          '`ref.keepAlive`/`ref.invalidate` before its first `await` — '
          'Riverpod may silently drop a watch registered after one, and a '
          'provider disposed while that await is pending throws the moment a '
          'later statement touches `ref`. Hoist the call above the await, or '
          'add it to `allowed` above with a one-line reason if it is a false '
          'positive (a separately-guarded callback, or a branch that never '
          'runs alongside the flagged await).\n'
          'Offenders found:\n${offenders.join('\n')}',
    );
  });
}

/// Matches this codebase's provider-declaration convention, the same one
/// `provider_retry_policy_test.dart` scans for annotation coverage.
final _declaration = RegExp(
  r'^final ([A-Za-z0-9_]+Provider) = '
  r'(FutureProvider|StreamProvider|Provider|NotifierProvider|'
  r'AsyncNotifierProvider|StateNotifierProvider)',
  multiLine: true,
);

/// `ref` followed by `.watch`/`.read`/`.listen`/`.keepAlive`/`.invalidate`,
/// tolerating whitespace (including a line break) between `ref` and the
/// `.` — this codebase's formatter regularly breaks a long `ref` chain
/// across lines (`ref\n    .read(...)`), and a check that requires `ref.` on
/// one line silently misses those sites.
final _refCall = RegExp(
  r'\bref\s*\.\s*(watch|read|listen|keepAlive|invalidate)\b',
);

final _await = RegExp(r'\bawait\b');

int _lineOf(String source, int offset) =>
    '\n'.allMatches(source.substring(0, offset)).length + 1;

/// Strips `//` line comments (good enough here: this codebase's provider
/// bodies don't carry `//` inside a string literal on the same line as code
/// that also has a real trailing comment).
String _stripLineComments(String body) => body
    .split('\n')
    .map((line) {
      final i = line.indexOf('//');
      return i == -1 ? line : line.substring(0, i);
    })
    .join('\n');

/// Null if the body has no `await`, or no `ref` call in a statement
/// *beginning after* the statement containing the first `await` ends —
/// i.e. not a `ref.watch` that is itself part of the very expression being
/// awaited (`await ref.watch(x).future`), which is the normal, correct
/// shape and must not be flagged.
String? _refAfterFirstAwait(String body) {
  final clean = _stripLineComments(body);
  final firstAwait = _await.firstMatch(clean);
  if (firstAwait == null) return null;
  final stmtEnd = _statementEnd(clean, firstAwait.start);
  final tail = clean.substring(stmtEnd);
  final hit = _refCall.firstMatch(tail);
  if (hit == null) return null;
  final start = (hit.start - 30).clamp(0, tail.length);
  final stop = (hit.end + 30).clamp(0, tail.length);
  return '...${tail.substring(start, stop).replaceAll('\n', ' ').trim()}...';
}

/// End offset (exclusive) of the statement/expression starting at [start]:
/// the next `;` at the same bracket depth `start` itself sits at (depth 0
/// relative to `start`, not to the top of `body` — a statement inside an
/// `if`/`try` block still ends at its own `;`, before that block's `}`).
int _statementEnd(String body, int start) {
  var depth = 0;
  var i = start;
  while (i < body.length) {
    final c = body[i];
    if (c == "'" || c == '"') {
      i = _skipString(body, i);
      continue;
    }
    if (c == '(' || c == '[' || c == '{') {
      depth++;
    } else if (c == ')' || c == ']' || c == '}') {
      depth--;
    } else if (c == ';' && depth <= 0) {
      return i + 1;
    }
    i++;
  }
  return body.length;
}

/// Offset just past a provider declaration's closing `)` — copied from
/// `provider_retry_policy_test.dart`'s `_declarationEnd`.
int _declarationEnd(String source, int start) {
  var i = _argumentListOpen(source, start);
  var depth = 0;
  while (i < source.length) {
    final c = source[i];
    if (_startsLineComment(source, i)) {
      final nl = source.indexOf('\n', i);
      i = nl < 0 ? source.length : nl + 1;
      continue;
    }
    if (c == "'" || c == '"') {
      i = _skipString(source, i);
      continue;
    }
    if (c == 'r' &&
        i + 1 < source.length &&
        (source[i + 1] == "'" || source[i + 1] == '"')) {
      i = _skipString(source, i + 1);
      continue;
    }
    if (c == '(') {
      depth++;
    } else if (c == ')') {
      depth--;
      if (depth == 0) return i + 1;
    }
    i++;
  }
  throw StateError('unterminated provider declaration at offset $start');
}

int _argumentListOpen(String source, int start) {
  var i = start;
  var angle = 0;
  while (i < source.length) {
    final c = source[i];
    if (c == "'" || c == '"') {
      i = _skipString(source, i);
      continue;
    }
    if (c == '<') {
      angle++;
    } else if (c == '>') {
      if (angle > 0) angle--;
    } else if (c == '(' && angle == 0) {
      return i;
    }
    i++;
  }
  throw StateError('no argument list at offset $start');
}

bool _startsLineComment(String source, int i) =>
    source[i] == '/' && i + 1 < source.length && source[i + 1] == '/';

int _skipString(String source, int i) {
  final quote = source[i];
  final triple = source.startsWith(quote * 3, i);
  final terminator = triple ? quote * 3 : quote;
  i += terminator.length;
  while (i < source.length) {
    if (source[i] == r'\') {
      i += 2;
      continue;
    }
    if (!triple && source[i] == '\n') return i;
    if (source.startsWith(terminator, i)) return i + terminator.length;
    i++;
  }
  return source.length;
}
