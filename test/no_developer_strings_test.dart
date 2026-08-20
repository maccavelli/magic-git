// A condition a user can reach needs a type and a humanized message.
//
// `Exception('SSH connection not established.')` had neither: it matched no
// branch in humanizeSshError, so displayError stripped the prefix and handed
// the raw developer string to the Repository panel — which is exactly what a
// cold connect showed for a split second (MADR 0018). Typing it was the fix;
// this is what stops the next one.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Developer text that must never reach a user-facing surface, with what to do
/// instead. Add an entry when a raw string escapes into the UI again.
const _banned = <String, String>{
  'SSH connection not established':
      'throw SSHTransportNotReady and let humanizeSshError word it '
      '(lib/core/ssh/ssh_error_messages.dart)',
};

void main() {
  test('no user-facing path can render a developer error string', () {
    final offenders = <String>[];

    for (final file
        in Directory('lib')
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart'))) {
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        // Comments may name the string — that is how the fix documents itself.
        if (line.trimLeft().startsWith('//')) continue;
        for (final entry in _banned.entries) {
          if (line.contains(entry.key)) {
            offenders.add('${file.path}:${i + 1} — ${entry.value}');
          }
        }
      }
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'A developer string reached a user-facing path:\n'
          '${offenders.join('\n')}',
    );
  });
}
