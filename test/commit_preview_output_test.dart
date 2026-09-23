// MADR 0068, Amendment 0068.2: the commit-message preview streams the
// `prepare-commit-msg` hook's stderr into the Output view as it is written, so
// a slow or stalled hook explains itself instead of leaving a silent spinner.
//
// These pin `previewCommitMessageWithOutput` against a fake GitService that
// emits chunks through the same `onOutput` callback the executor uses: which
// chunks reach the log, that the session opens only when there is something to
// show, and how a failure closes it. The script half — that the hook's stderr
// reaches `onOutput` at all — is pinned against a real `sh` in
// commit_message_preview_test.dart.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/output/output_log.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/features/repository/commit_composer_controller.dart';

/// What the fake emits, in order: `(chunk, isStderr)`.
typedef _Chunk = (String, bool);

class _ScriptedGit extends GitService {
  _ScriptedGit({required this.chunks, this.message, this.failWith})
    : super(SSHCommandExecutor(SSHClientManager()));

  final List<_Chunk> chunks;
  final String? message;
  final GitException? failWith;

  @override
  Future<String?> generateCommitMessage(
    String repoPath, {
    CommandOutputCallback? onOutput,
  }) async {
    for (final (chunk, stderr) in chunks) {
      onOutput?.call(chunk, stderr: stderr);
    }
    if (failWith != null) throw failWith!;
    return message;
  }
}

const _header = r'$ prepare-commit-msg (message preview)';

List<OutputLine> _lines(ProviderContainer c) => c.read(outputLogProvider).lines;

void main() {
  late ProviderContainer container;
  late OutputLogNotifier log;

  setUp(() {
    container = ProviderContainer.test();
    log = container.read(outputLogProvider.notifier);
  });

  test('the hook\'s stderr reaches the Output view; stdout does not', () async {
    final git = _ScriptedGit(
      chunks: const [
        ('generating via stub (model-x)...\n', true),
        ('noise on stdout\n', false),
        ('retry 1 of 3\n', true),
      ],
      message: 'a generated message',
    );

    final message = await previewCommitMessageWithOutput(git, log, '/repo');

    expect(message, 'a generated message', reason: 'the message is unchanged');
    final texts = _lines(container).map((l) => l.text).toList();
    expect(
      texts.where((t) => t == _header),
      hasLength(1),
      reason: 'one stream session for the whole preview',
    );
    expect(
      _lines(
        container,
      ).where((l) => l.kind == OutputLineKind.stderr).map((l) => l.text),
      ['generating via stub (model-x)...', 'retry 1 of 3'],
    );
    expect(
      texts,
      isNot(contains('noise on stdout')),
      reason: 'stdout is the message, shown in the composer, not logged',
    );
    expect(texts.last, '✓ completed');
  });

  test('a preview that says nothing adds nothing to the log', () async {
    final git = _ScriptedGit(chunks: const [], message: 'quiet message');

    await previewCommitMessageWithOutput(git, log, '/repo');

    expect(
      _lines(container),
      isEmpty,
      reason:
          'no hook, or a silent one, must not add a line every time the '
          'composer opens',
    );
  });

  test('stdout alone opens no session either', () async {
    final git = _ScriptedGit(
      chunks: const [('only stdout\n', false)],
      message: 'm',
    );

    await previewCommitMessageWithOutput(git, log, '/repo');

    expect(_lines(container), isEmpty);
  });

  test(
    'a failing hook closes the session with its exit code and rethrows',
    () async {
      final git = _ScriptedGit(
        chunks: const [('generating via stub...\n', true)],
        failWith: const GitException(
          'generating commit message failed',
          SSHCommandResult(exitCode: 7, stdout: '', stderr: 'boom'),
        ),
      );

      await expectLater(
        previewCommitMessageWithOutput(git, log, '/repo'),
        throwsA(isA<GitException>()),
      );

      final texts = _lines(container).map((l) => l.text).toList();
      expect(texts, contains('generating via stub...'));
      expect(texts.last, '✗ exited with code 7');
    },
  );
}
