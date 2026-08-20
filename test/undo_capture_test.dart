// GitService._runCaptured's wire format: undoable mutations run inside a
// capture script whose stdout brackets the mutation's own output with
// sentinel-delimited pre/post state. These tests pin the parse — records built
// from the fields, callers seeing only the mutation's stdout, and graceful
// degradation when output doesn't parse (fake executors, early script death).

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/core/undo/undo_types.dart';

/// The exact on-the-wire separator — deliberately duplicated from
/// GitService's private `_undoSep` so a drift in either side fails here.
const sep = '\u0002RMGUNDO\u0002';

/// Assembles a capture script's stdout the way the remote shell produces it.
String captured({
  required String pre,
  required String preref,
  List<String> extras = const [],
  String mutOut = '',
  required String post,
  required String postref,
}) =>
    '$sep$pre$sep$preref$sep'
    '${extras.map((e) => '$e$sep').join()}'
    '$mutOut$sep$post$sep$postref$sep';

class _FakeExecutor extends SSHCommandExecutor {
  final List<List<String>> calls = [];
  SSHCommandResult next = const SSHCommandResult(
    exitCode: 0,
    stdout: '',
    stderr: '',
  );

  _FakeExecutor() : super(SSHClientManager());

  @override
  Future<SSHCommandResult> execute({
    required String repoPath,
    required List<String> gitArgs,
    Map<String, String>? extraEnv,
    String? stdin,
    Duration timeout = SSHCommandExecutor.defaultTimeout,
    int retries = 0,
    ExecLane lane = ExecLane.exclusive,
    bool compress = false,
    Duration? activityIdle,
    OperationDescriptor? operation,
    OperationEventCallback? onOperationEvent,
  }) async {
    calls.add(gitArgs);
    return next;
  }
}

void main() {
  late _FakeExecutor exec;
  late List<UndoRecord> records;
  late GitService git;

  setUp(() {
    exec = _FakeExecutor();
    records = [];
    git = GitService(exec, onUndoRecord: records.add);
  });

  test('a successful commit records pre/post state', () async {
    exec.next = SSHCommandResult(
      exitCode: 0,
      stdout: captured(
        pre: 'a' * 40,
        preref: 'main',
        mutOut: '[main bbbbbbb] subject\n',
        post: 'b' * 40,
        postref: 'main',
      ),
      stderr: '',
    );
    await git.commit('/repo', message: 'subject');
    final r = records.single;
    expect(r.kind, UndoOpKind.commit);
    expect(r.repoPath, '/repo');
    expect(r.preHead, 'a' * 40);
    expect(r.preRef, 'main');
    expect(r.postHead, 'b' * 40);
    expect(r.postRef, 'main');
  });

  test('an unborn-HEAD first commit records nothing', () async {
    exec.next = SSHCommandResult(
      exitCode: 0,
      stdout: captured(
        pre: '', // rev-parse failed: unborn branch
        preref: 'main',
        post: 'b' * 40,
        postref: 'main',
      ),
      stderr: '',
    );
    await git.commit('/repo', message: 'first');
    expect(records, isEmpty);
  });

  test(
    'a failed mutation records nothing and throws the cleaned result',
    () async {
      exec.next = SSHCommandResult(
        exitCode: 1,
        stdout: captured(
          pre: 'a' * 40,
          preref: 'main',
          mutOut: 'mutation own stdout',
          post: 'a' * 40,
          postref: 'main',
        ),
        stderr: 'nothing to commit',
      );
      await expectLater(
        () => git.commit('/repo', message: 'x'),
        throwsA(
          isA<GitException>().having(
            (e) => e.result.stdout,
            'stdout',
            'mutation own stdout',
          ),
        ),
      );
      expect(records, isEmpty);
    },
  );

  test(
    'unparseable stdout (fake/legacy output) degrades to no record',
    () async {
      exec.next = const SSHCommandResult(
        exitCode: 0,
        stdout: 'no sentinels here',
        stderr: '',
      );
      await git.commit('/repo', message: 'x');
      expect(records, isEmpty);
    },
  );

  test('deleteBranch maps the extra capture to the deleted tip OID', () async {
    exec.next = SSHCommandResult(
      exitCode: 0,
      stdout: captured(
        pre: 'a' * 40,
        preref: 'main',
        extras: ['d' * 40],
        mutOut: 'Deleted branch old.\n',
        post: 'a' * 40,
        postref: 'main',
      ),
      stderr: '',
    );
    await git.deleteBranch('/repo', 'old', force: true);
    final r = records.single;
    expect(r.kind, UndoOpKind.deleteBranch);
    expect(r.refName, 'old');
    expect(r.deletedOid, 'd' * 40);
  });

  test(
    'deleteBranch of a ref that vanished pre-delete records nothing',
    () async {
      exec.next = SSHCommandResult(
        exitCode: 0,
        stdout: captured(
          pre: 'a' * 40,
          preref: 'main',
          extras: [''], // rev-parse found no such branch
          post: 'a' * 40,
          postref: 'main',
        ),
        stderr: '',
      );
      await git.deleteBranch('/repo', 'old');
      expect(records, isEmpty);
    },
  );

  test('stashDrop maps OID and subject extras, and callers still get the '
      "mutation's own stdout", () async {
    exec.next = SSHCommandResult(
      exitCode: 0,
      stdout: captured(
        pre: 'a' * 40,
        preref: 'main',
        extras: ['On main: wip thing'],
        mutOut: 'Dropped stash@{1}\n',
        post: 'a' * 40,
        postref: 'main',
      ),
      stderr: '',
    );
    final result = await git.stashDrop('/repo', 1, expectedOid: 'c' * 40);
    expect(
      result.stdout,
      'Dropped stash@{1}\n',
      reason: 'capture fields must be stripped from the surfaced result',
    );
    final r = records.single;
    expect(r.kind, UndoOpKind.stashDrop);
    expect(r.deletedOid, 'c' * 40);
    expect(r.stashSubject, 'On main: wip thing');
  });

  test('stashPop maps the subject, pre-pop snapshot and post-pop tree', () async {
    exec.next = SSHCommandResult(
      exitCode: 0,
      // pop carries two pre-mutation extras (subject, snapshot S) and one
      // postCapture (the post-pop worktree tree Pt), which lands after postref.
      stdout:
          '${captured(pre: 'a' * 40, preref: 'main', extras: ['On main: wip thing', 's' * 40], mutOut: 'Dropped refs/stash@{0}\n', post: 'a' * 40, postref: 'main')}${'9' * 40}$sep',
      stderr: '',
    );
    final result = await git.stashPop('/repo', 0, expectedOid: 'c' * 40);
    expect(
      result.stdout,
      'Dropped refs/stash@{0}\n',
      reason: 'capture fields must be stripped from the surfaced result',
    );
    final r = records.single;
    expect(r.kind, UndoOpKind.stashPop);
    expect(r.deletedOid, 'c' * 40);
    expect(r.stashSubject, 'On main: wip thing');
    expect(r.snapshotOid, 's' * 40, reason: 'pre-pop snapshot S');
    expect(r.worktreeTree, '9' * 40, reason: 'post-pop worktree tree Pt');
  });

  test('mixed reset maps the write-tree capture; a degraded (empty) capture '
      'still records', () async {
    exec.next = SSHCommandResult(
      exitCode: 0,
      stdout: captured(
        pre: 'a' * 40,
        preref: 'main',
        extras: ['e' * 40],
        post: 'b' * 40,
        postref: 'main',
      ),
      stderr: '',
    );
    await git.reset('/repo', 'abc', mode: ResetMode.mixed);
    expect(records.single.preIndexTree, 'e' * 40);

    records.clear();
    exec.next = SSHCommandResult(
      exitCode: 0,
      stdout: captured(
        pre: 'a' * 40,
        preref: 'main',
        extras: [''], // conflicted index: write-tree failed
        post: 'b' * 40,
        postref: 'main',
      ),
      stderr: '',
    );
    await git.reset('/repo', 'abc', mode: ResetMode.mixed);
    expect(
      records.single.preIndexTree,
      '',
      reason: 'undo degrades to soft-only, but the record still exists',
    );
  });

  test('a detached-HEAD checkout capture keeps preRef empty', () async {
    exec.next = SSHCommandResult(
      exitCode: 0,
      stdout: captured(
        pre: 'a' * 40,
        preref: '', // symbolic-ref failed: detached
        post: 'b' * 40,
        postref: 'feature',
      ),
      stderr: '',
    );
    await git.checkout('/repo', 'feature');
    final r = records.single;
    expect(r.preRef, '');
    expect(r.preHead, 'a' * 40);
  });

  test('no onUndoRecord callback disables recording without changing '
      'behavior', () async {
    final plain = GitService(exec);
    exec.next = SSHCommandResult(
      exitCode: 0,
      stdout: captured(
        pre: 'a' * 40,
        preref: 'main',
        post: 'b' * 40,
        postref: 'main',
      ),
      stderr: '',
    );
    await plain.commit('/repo', message: 'x'); // completes, records nowhere
    expect(records, isEmpty);
  });
}
