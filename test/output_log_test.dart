// Unit test for OutputLogNotifier: visibility, command logging, stream
// sessions with CR progress frames, and file-change formatting.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/output/output_log.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';

void main() {
  group('OutputLogState', () {
    test('default-constructed state has visible=false, no lines, revision 0', () {
      const state = OutputLogState();
      expect(state.visible, isFalse);
      expect(state.lines, isEmpty);
      expect(state.revision, 0);
    });

    test('copyWith overrides selected fields', () {
      const state = OutputLogState();
      expect(state.copyWith(visible: false).visible, isFalse);
      expect(state.copyWith(lines: [const OutputLine('hi', OutputLineKind.info)])
          .lines, hasLength(1));
    });

    test('withLines advances revision', () {
      const state = OutputLogState();
      final updated = state.withLines([const OutputLine('x', OutputLineKind.info)]);
      expect(updated.lines, hasLength(1));
      expect(updated.revision, 1);
      expect(updated.visible, state.visible);
    });
  });

  group('OutputLogNotifier', () {
  test('logFiles formats a header and color-coded file lines', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final log = container.read(outputLogProvider.notifier);

    log.logFiles('Pushed', const [
      'A\tlib/a.dart',
      'M\tlib/b.dart',
      'D\told.dart',
      'R100\tfrom.dart\tto.dart',
      '', // blank lines are ignored
    ]);

    final lines = container.read(outputLogProvider).lines;
    final texts = lines.map((l) => l.text).toList();

    expect(texts.first, 'Pushed — 4 files');
    expect(texts.any((t) => t.contains('lib/a.dart')), isTrue);
    expect(texts.any((t) => t.contains('from.dart → to.dart')), isTrue);

    OutputLineKind kindOf(String needle) =>
        lines.firstWhere((l) => l.text.contains(needle)).kind;
    expect(kindOf('lib/a.dart'), OutputLineKind.success); // A → green
    expect(kindOf('lib/b.dart'), OutputLineKind.stderr); // M → yellow
    expect(kindOf('old.dart'), OutputLineKind.error); // D → red
  });

  test('logFiles is a no-op for an all-empty list', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final log = container.read(outputLogProvider.notifier);
    log.logFiles('Pulled', const ['', '   ']);
    expect(container.read(outputLogProvider).lines, isEmpty);
  });

  test('appending still signals a change once the scrollback is full', () {
    // The output view follows the tail by listening for a change to this signal.
    // It used to listen on `lines.length` — which stops changing the moment the
    // buffer caps, because every append then also drops a line. So after 2000
    // lines (one long clone, or a busy session) the view silently stopped
    // scrolling to new output: it was still arriving, just never followed.
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final log = container.read(outputLogProvider.notifier);

    var notified = 0;
    final sub = container.listen(
      outputLogProvider.select((s) => s.revision),
      (_, _) => notified++,
    );
    addTearDown(sub.close);

    for (var i = 0; i < OutputLogNotifier.maxLines; i++) {
      log.logInfo('line $i');
    }
    expect(
      container.read(outputLogProvider).lines,
      hasLength(OutputLogNotifier.maxLines),
      reason: 'the buffer is now full — the line count can no longer grow',
    );
    final whenFull = notified;

    for (var i = 0; i < 20; i++) {
      log.logInfo('overflow $i');
    }
    expect(
      notified - whenFull,
      20,
      reason: 'every appended line must still notify the tail-follower',
    );
    expect(container.read(outputLogProvider).lines.last.text, 'overflow 19');
  });

    test('setVisible and toggle control visibility', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final log = container.read(outputLogProvider.notifier);

      expect(container.read(outputLogProvider).visible, isTrue);
      log.setVisible(false);
      expect(container.read(outputLogProvider).visible, isFalse);
      log.toggle();
      expect(container.read(outputLogProvider).visible, isTrue);
    });

    test('clear removes all lines', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final log = container.read(outputLogProvider.notifier);

      log.logInfo('hello');
      expect(container.read(outputLogProvider).lines, isNotEmpty);
      log.clear();
      expect(container.read(outputLogProvider).lines, isEmpty);
    });

    test('logResult formats a command with stdout, stderr, and success line', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final log = container.read(outputLogProvider.notifier);

      log.logResult('git status', const SSHCommandResult(
        exitCode: 0,
        stdout: 'clean\n',
        stderr: '',
      ));

      final lines = container.read(outputLogProvider).lines;
      expect(lines, hasLength(3));
      expect(lines[0].text, '\$ git status');
      expect(lines[0].kind, OutputLineKind.command);
      expect(lines[1].text, 'clean');
      expect(lines[1].kind, OutputLineKind.stdout);
      expect(lines[2].text, '✓ completed');
      expect(lines[2].kind, OutputLineKind.success);
    });

    test('logResult failure shows exit code', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final log = container.read(outputLogProvider.notifier);

      log.logResult('git push', const SSHCommandResult(
        exitCode: 128,
        stdout: '',
        stderr: 'fatal: not a git repository\n',
      ));

      final lines = container.read(outputLogProvider).lines;
      expect(lines.last.text, '✗ exited with code 128');
      expect(lines.last.kind, OutputLineKind.error);
      expect(lines.any((l) => l.text.contains('not a git repository')), isTrue);
    });

    test('logError formats command + error message', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final log = container.read(outputLogProvider.notifier);

      log.logError('gh pr view', 'timeout after 30s');

      final lines = container.read(outputLogProvider).lines;
      expect(lines, hasLength(2));
      expect(lines[0].text, '\$ gh pr view');
      expect(lines[0].kind, OutputLineKind.command);
      expect(lines[1].text, 'timeout after 30s');
      expect(lines[1].kind, OutputLineKind.error);
    });

    test('logInfo splits newlines into separate lines', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final log = container.read(outputLogProvider.notifier);

      log.logInfo('connected\ntiming: 42ms');

      final lines = container.read(outputLogProvider).lines;
      expect(lines, hasLength(2));
      expect(lines[0].text, 'connected');
      expect(lines[0].kind, OutputLineKind.info);
      expect(lines[1].text, 'timing: 42ms');
    });

    test('CRLF is normalized to LF', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final log = container.read(outputLogProvider.notifier);

      log.logInfo('line1\r\nline2');

      final lines = container.read(outputLogProvider).lines;
      expect(lines, hasLength(2));
      expect(lines[0].text, 'line1');
      expect(lines[1].text, 'line2');
    });

    test('multi-line stdout is split correctly', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final log = container.read(outputLogProvider.notifier);

      log.logResult('git log', const SSHCommandResult(
        exitCode: 0,
        stdout: 'commit aaa\ncommit bbb\n',
        stderr: '',
      ));

      final lines = container.read(outputLogProvider).lines;
      expect(lines.any((l) => l.text == 'commit aaa'), isTrue);
      expect(lines.any((l) => l.text == 'commit bbb'), isTrue);
    });
  });

  group('OutputStreamSession', () {
    test('append with plain text emits command header and finalized lines', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final log = container.read(outputLogProvider.notifier);

      final session = log.startStream('git clone --progress');
      session.append('Receiving objects:  10%\n', OutputLineKind.stdout);
      session.append('Receiving objects:  20%\n', OutputLineKind.stdout);

      final lines = container.read(outputLogProvider).lines;
      expect(lines, hasLength(3)); // command + 2 finalized (no trailing partial)
      expect(lines[0].text, '\$ git clone --progress');
      expect(lines[1].text, 'Receiving objects:  10%');
      expect(lines[1].kind, OutputLineKind.stdout);
      expect(lines[2].text, 'Receiving objects:  20%');
    });

    test('CR progress frames are collapsed to the last frame', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final log = container.read(outputLogProvider.notifier);

      final session = log.startStream('git clone');
      // Git's progress frames use \r to overwrite the same line.
      session.append('Receiving objects:  10%\r', OutputLineKind.stdout);
      session.append('Receiving objects:  42%\r', OutputLineKind.stdout);
      session.append('Receiving objects: 100%\r', OutputLineKind.stdout);
      session.append('Resolving deltas: 100%\n', OutputLineKind.stdout);

      final lines = container.read(outputLogProvider).lines;
      expect(lines, hasLength(2)); // command + 1 finalized (no trailing partial)
      // The finalized line has the last frame after the \r collapse.
      expect(lines[1].text, 'Resolving deltas: 100%');
    });

    test('close with exit 0 appends completed line', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final log = container.read(outputLogProvider.notifier);

      final session = log.startStream('git pull');
      session.append('Already up to date.\n', OutputLineKind.stdout);
      session.close(exitCode: 0);

      final lines = container.read(outputLogProvider).lines;
      expect(lines.last.text, '✓ completed');
      expect(lines.last.kind, OutputLineKind.success);
    });

    test('close with non-zero exit appends error line', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final log = container.read(outputLogProvider.notifier);

      final session = log.startStream('git pull');
      session.append('error: failed\n', OutputLineKind.stderr);
      session.close(exitCode: 1);

      final lines = container.read(outputLogProvider).lines;
      expect(lines.last.text, '✗ exited with code 1');
      expect(lines.last.kind, OutputLineKind.error);
    });

    test('close with null exitCode appends terminated line', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final log = container.read(outputLogProvider.notifier);

      final session = log.startStream('git clone');
      session.close(exitCode: null);

      final lines = container.read(outputLogProvider).lines;
      expect(lines.last.text, '✗ terminated');
      expect(lines.last.kind, OutputLineKind.error);
    });

    test('fail appends error message and partials', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final log = container.read(outputLogProvider.notifier);

      final session = log.startStream('ssh git clone');
      session.append('Cloning into...\n', OutputLineKind.stdout);
      session.append('partial data', OutputLineKind.stdout);
      session.fail('channel closed unexpectedly');

      final lines = container.read(outputLogProvider).lines;
      expect(lines.any((l) => l.text == 'Cloning into...'), isTrue);
      expect(lines.any((l) => l.text == 'partial data'), isTrue);
      expect(lines.any((l) => l.text == 'channel closed unexpectedly'), isTrue);
    });

    test('append after close is silently ignored', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final log = container.read(outputLogProvider.notifier);

      final session = log.startStream('git clone');
      session.close(exitCode: 0);

      final before = container.read(outputLogProvider).lines.length;
      session.append('should be ignored\n', OutputLineKind.stdout);
      expect(container.read(outputLogProvider).lines, hasLength(before));
    });

    test('stderr and stdout streams interleave correctly', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final log = container.read(outputLogProvider.notifier);

      final session = log.startStream('git push');
      session.append('stdout line 1\n', OutputLineKind.stdout);
      session.append('stderr warning\n', OutputLineKind.stderr);
      session.append('stdout line 2\n', OutputLineKind.stdout);

      final lines = container.read(outputLogProvider).lines;
      expect(lines.any((l) => l.text == 'stdout line 1'), isTrue);
      expect(lines.any((l) => l.text == 'stderr warning'), isTrue);
      expect(lines.any((l) => l.text == 'stdout line 2'), isTrue);
    });
  });
}
