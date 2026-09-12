// "Open file" opens the user's own default application for the file's type —
// the same thing a double-click in Finder does.
//
// This exists because `5e93607` pinned `-a 'Visual Studio Code'`, and on a Mac
// without VS Code installed that `open` exits non-zero: the action opened
// nothing, reported nothing, and logged nothing, because the ProcessResult was
// discarded. Both halves are guarded here — which command is launched, and what
// happens when it fails.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/utils/file_actions.dart';

/// Records every launch and answers with the scripted exit codes, so nothing is
/// actually opened by the suite.
class _Launcher {
  _Launcher([this.exitCodes = const [0]]);

  final List<int> exitCodes;
  final List<List<String>> calls = [];

  Future<ProcessResult> call(String executable, List<String> arguments) async {
    calls.add([executable, ...arguments]);
    final index = calls.length - 1;
    final code = index < exitCodes.length ? exitCodes[index] : 0;
    return ProcessResult(
      1,
      code,
      '',
      code == 0 ? '' : 'Unable to find application named \'Some Editor\'',
    );
  }
}

void main() {
  test('opens each path with the default application for its type', () async {
    final launcher = _Launcher();
    await FileActions(
      launch: launcher.call,
    ).openFiles(['/repo/a.dart', '/repo/b.md']);

    expect(launcher.calls, [
      ['open', '/repo/a.dart', '/repo/b.md'],
    ]);
  });

  test(
    'pins no editor — the choice is the user\'s, in Launch Services',
    () async {
      final launcher = _Launcher();
      await FileActions(launch: launcher.call).openFiles(['/repo/a.dart']);

      expect(
        launcher.calls.single,
        isNot(contains('-a')),
        reason:
            '`open -a <editor>` imposes one editor and fails when it is absent',
      );
    },
  );

  test(
    'a type with no registered handler falls back to the default text editor',
    () async {
      final launcher = _Launcher([1, 0]);
      await FileActions(launch: launcher.call).openFiles(['/repo/LICENSE']);

      expect(launcher.calls, [
        ['open', '/repo/LICENSE'],
        ['open', '-t', '/repo/LICENSE'],
      ]);
    },
  );

  test('a failure no editor can serve is reported, not swallowed', () async {
    final launcher = _Launcher([1, 1]);

    await expectLater(
      FileActions(launch: launcher.call).openFiles(['/repo/a.dart']),
      throwsA(
        isA<FileOpenException>().having(
          (e) => e.toString(),
          'message',
          allOf(contains('/repo/a.dart'), contains('Unable to find')),
        ),
      ),
    );
    expect(launcher.calls, hasLength(2), reason: 'both routes were tried');
  });

  test('opening nothing launches nothing', () async {
    final launcher = _Launcher();
    await FileActions(launch: launcher.call).openFiles([]);

    expect(launcher.calls, isEmpty);
  });

  test('reveal in Finder selects the file rather than opening it', () async {
    final launcher = _Launcher();
    await FileActions(launch: launcher.call).revealInFinder('/repo/a.dart');

    expect(launcher.calls, [
      ['open', '-R', '/repo/a.dart'],
    ]);
  });
}
