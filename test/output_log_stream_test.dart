// OutputStreamSession: the incremental transcript API used by streamed
// long-running commands (git clone --progress). Covers chunk reassembly across
// boundaries, \r progress-frame collapsing into one transient line, safety
// under interleaved batch logging, close/fail finalization, and the cap.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/output/output_log.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';

void main() {
  late ProviderContainer container;
  late OutputLogNotifier log;

  setUp(() {
    container = ProviderContainer();
    addTearDown(container.dispose);
    log = container.read(outputLogProvider.notifier);
  });

  List<String> lines() => [
    for (final l in container.read(outputLogProvider).lines) l.text,
  ];

  test('logs the command header immediately', () {
    log.startStream('git clone --progress url dest');
    expect(lines(), ['\$ git clone --progress url dest']);
  });

  test('reassembles lines split across chunk boundaries', () {
    final s = log.startStream('cmd');
    s.append('Cloning into', OutputLineKind.stderr);
    expect(lines(), ['\$ cmd', 'Cloning into'], reason: 'partial is visible');

    s.append(" 'dest'...\nremote: Enumerating\n", OutputLineKind.stderr);
    expect(lines(), ['\$ cmd', "Cloning into 'dest'...", 'remote: Enumerating']);

    s.close(exitCode: 0);
    expect(lines().last, '✓ completed');
  });

  test(r'\r progress frames collapse to one transient line, updated in place', () {
    final s = log.startStream('cmd');
    s.append('Receiving objects:  10%\rReceiving objects:  55%',
        OutputLineKind.stderr);
    expect(lines(), ['\$ cmd', 'Receiving objects:  55%']);

    s.append('\rReceiving objects: 100%, done.\n', OutputLineKind.stderr);
    expect(lines(), ['\$ cmd', 'Receiving objects: 100%, done.'],
        reason: 'frames never accumulate as separate lines');
  });

  test(r'a chunk ENDING in \r shows the frame text, not a blank line', () {
    // git's progress.c writes each frame as `...:  42%\r` — the \r AFTER the
    // counters — so real streamed chunks routinely end with \r. Collapsing to
    // "text after the last \r" rendered the entire transfer blank.
    final s = log.startStream('cmd');
    s.append('Receiving objects:  42%\r', OutputLineKind.stderr);
    expect(lines(), ['\$ cmd', 'Receiving objects:  42%']);

    s.append('Receiving objects:  77%\r', OutputLineKind.stderr);
    expect(lines(), ['\$ cmd', 'Receiving objects:  77%'],
        reason: 'later frames replace the transient in place');

    s.close(exitCode: 0);
    expect(lines(), ['\$ cmd', 'Receiving objects:  77%', '✓ completed'],
        reason: 'the final frame is flushed into the transcript');
  });

  test(r'a \r\n terminator split across two chunks keeps the line text', () {
    final s = log.startStream('cmd');
    s.append('remote: Compressing done.\r', OutputLineKind.stderr);
    s.append('\nnext line\n', OutputLineKind.stderr);
    expect(
      lines(),
      ['\$ cmd', 'remote: Compressing done.', 'next line'],
      reason: r'the split \r\n must collapse to one newline — the stray \r '
          'must not erase the finalized line',
    );
  });

  test('stdout and stderr keep separate partial buffers', () {
    final s = log.startStream('cmd');
    s.append('out-part', OutputLineKind.stdout);
    s.append('err-part', OutputLineKind.stderr);
    s.append('-done\n', OutputLineKind.stderr);
    s.append('-ok\n', OutputLineKind.stdout);
    s.close(exitCode: 0);

    expect(lines(), containsAll(['err-part-done', 'out-part-ok']),
        reason: 'interleaved chunks must not merge across streams');
  });

  test('an interleaved batch log leaves the transient as history', () {
    final s = log.startStream('cmd');
    s.append('progress 10%', OutputLineKind.stderr);
    // Another command finishes and logs while the stream is live.
    log.logResult(
      'git fetch',
      const SSHCommandResult(exitCode: 0, stdout: '', stderr: ''),
    );
    s.append('\rprogress 90%', OutputLineKind.stderr);
    // The old transient is no longer last, so it stays; the fresh frame lands
    // at the tail. No crash, no lost batch lines.
    expect(lines(), containsAllInOrder(['\$ git fetch', '✓ completed']));
    expect(lines().last, 'progress 90%');
  });

  test('close variants: exit code, non-zero, terminated', () {
    final a = log.startStream('a');
    a.close(exitCode: 0);
    expect(lines().last, '✓ completed');

    final b = log.startStream('b');
    b.append('fatal: repository not found', OutputLineKind.stderr);
    b.close(exitCode: 128);
    expect(lines(), containsAllInOrder([
      'fatal: repository not found',
      '✗ exited with code 128',
    ]), reason: 'partial flushed before the status line');

    final c = log.startStream('c');
    c.close();
    expect(lines().last, '✗ terminated');

    // Sessions are inert after close.
    c.append('late', OutputLineKind.stdout);
    c.close(exitCode: 0);
    expect(lines().last, '✗ terminated');
  });

  test('fail() flushes partials and logs the error message', () {
    final s = log.startStream('cmd');
    s.append('half a line', OutputLineKind.stderr);
    s.fail('SSH channel closed');
    expect(lines(), containsAllInOrder(['half a line', 'SSH channel closed']));
  });

  test('respects the scrollback cap', () {
    final s = log.startStream('cmd');
    final chunk = StringBuffer();
    for (var i = 0; i < OutputLogNotifier.maxLines + 100; i++) {
      chunk.writeln('line $i');
    }
    s.append(chunk.toString(), OutputLineKind.stdout);
    s.close(exitCode: 0);
    expect(
      container.read(outputLogProvider).lines.length,
      lessThanOrEqualTo(OutputLogNotifier.maxLines),
    );
    expect(lines().last, '✓ completed');
  });
}
