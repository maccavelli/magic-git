// MADR 0066: a navigator that can be collapsed must be one the user can get
// back, and the reveal rail names it. A page that supplies `navigator:` without
// `navigatorLabel:` therefore ships a pane that hides with no name on the rail
// — the shape of the defect this record fixes.
//
// A scan rather than a behavioural test: the rule is about every call site,
// including ones nobody has written yet, and the debug assert in the scaffold
// only fires for a page a test happens to pump.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The argument list of a `RepositoryWorkspaceScaffold(...)` call, found by
/// walking from the opening parenthesis to its match so nested calls, trailing
/// commas and comments inside the list are all handled.
String? _scaffoldCall(String source, int from) {
  final start = source.indexOf('RepositoryWorkspaceScaffold(', from);
  if (start < 0) return null;
  var depth = 0;
  for (var i = source.indexOf('(', start); i < source.length; i++) {
    final ch = source[i];
    if (ch == '(') depth++;
    if (ch == ')') {
      depth--;
      if (depth == 0) return source.substring(start, i + 1);
    }
  }
  return null;
}

Iterable<String> _scaffoldCalls(String source) sync* {
  var index = 0;
  while (true) {
    final call = _scaffoldCall(source, index);
    if (call == null) return;
    yield call;
    index = source.indexOf(call, index) + call.length;
  }
}

/// The names the call passes ITSELF, ignoring nested calls' arguments.
///
/// A substring search cannot do this: `compactNavigation:
/// CompactWorkspaceNavigation(navigatorLabel: …)` puts the word inside the
/// scaffold's argument list while saying nothing about the scaffold's own
/// `navigatorLabel:` — the scan passed on a page that had lost it.
Set<String> _topLevelArguments(String call) {
  final names = <String>{};
  final body = call.substring(call.indexOf('(') + 1, call.length - 1);
  final word = RegExp(r'[A-Za-z_][A-Za-z0-9_]*');
  var depth = 0;
  var wordStart = -1;
  for (var i = 0; i < body.length; i++) {
    final ch = body[i];
    if (ch == '(' || ch == '[' || ch == '{') depth++;
    if (ch == ')' || ch == ']' || ch == '}') depth--;
    if (depth != 0) continue;
    if (word.hasMatch(ch)) {
      if (wordStart < 0) wordStart = i;
      continue;
    }
    if (ch == ':' && wordStart >= 0) names.add(body.substring(wordStart, i));
    wordStart = -1;
  }
  return names;
}

void main() {
  test('every scaffold with a navigator names it for the reveal rail', () {
    final offenders = <String>[];
    final scanned = <String>[];

    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final source = entity.readAsStringSync();
      if (!source.contains('RepositoryWorkspaceScaffold(')) continue;
      for (final call in _scaffoldCalls(source)) {
        // The declaration itself, not a call site.
        if (call.contains('extends StatelessWidget')) continue;
        final arguments = _topLevelArguments(call);
        if (!arguments.contains('navigator')) continue;
        scanned.add(entity.path);
        if (!arguments.contains('navigatorLabel')) offenders.add(entity.path);
      }
    }

    expect(
      scanned,
      isNotEmpty,
      reason:
          'the scan found no scaffold call with a navigator — the pattern '
          'it matches must have changed, so it is proving nothing',
    );
    expect(
      offenders,
      isEmpty,
      reason:
          'these pass a navigator with no navigatorLabel, so collapsing it '
          'would leave an unnamed rail (MADR 0066): ${offenders.join(', ')}',
    );
  });
}
