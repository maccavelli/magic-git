// HostFsService: the filesystem primitives behind clone/create — home-dir
// resolution, the remote directory browser's listing, destination probing,
// mkdir -p, and (most importantly) the refusal matrix of the single guarded
// delete used to clean up a failed clone.

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/host_fs_service.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';

class _FakeExecutor extends SSHCommandExecutor {
  final List<List<String>> calls = [];
  final List<String> repoPaths = [];
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
    CommandOutputCallback? onOutput,
  }) async {
    calls.add(gitArgs);
    repoPaths.add(repoPath);
    return next;
  }
}

SSHCommandResult _ok(String stdout) =>
    SSHCommandResult(exitCode: 0, stdout: stdout, stderr: '');

void main() {
  late _FakeExecutor exec;
  late HostFsService fs;

  setUp(() {
    exec = _FakeExecutor();
    fs = HostFsService(exec);
  });

  group('homeDir', () {
    test('runs pwd from "." and trims the result', () async {
      exec.next = _ok('/home/mac\n');
      expect(await fs.homeDir(), '/home/mac');
      expect(exec.calls.single, ['pwd']);
      expect(exec.repoPaths.single, '.');
    });

    test('throws on failure', () async {
      exec.next = const SSHCommandResult(exitCode: 1, stdout: '', stderr: 'no');
      await expectLater(fs.homeDir(), throwsA(isA<HostFsException>()));
    });
  });

  group('listDirectories', () {
    test(
      'keeps only directory entries, stripping the trailing slash',
      () async {
        exec.next = _ok('code/\nnotes.txt\n.config/\nlink-to-dir/\nfile\n');
        expect(await fs.listDirectories('/home/mac'), [
          'code',
          '.config',
          'link-to-dir',
        ]);
        expect(exec.repoPaths.single, '/home/mac');
        expect(exec.calls.single, ['sh', '-c', 'LC_ALL=C ls -1ALp .']);
      },
    );

    test('permission denied (no output) throws with stderr', () async {
      exec.next = const SSHCommandResult(
        exitCode: 1,
        stdout: '',
        stderr: 'ls: cannot open directory: Permission denied',
      );
      await expectLater(
        fs.listDirectories('/root/secret'),
        throwsA(
          isA<HostFsException>().having(
            (e) => e.message,
            'message',
            contains('Permission denied'),
          ),
        ),
      );
    });

    test('a partial listing (broken symlink stat error) is returned', () async {
      exec.next = const SSHCommandResult(
        exitCode: 1,
        stdout: 'good/\n',
        stderr: 'ls: bad: No such file or directory',
      );
      expect(await fs.listDirectories('/x'), ['good']);
    });
  });

  group('probePath', () {
    test(
      'script embeds the path exactly once, single-escaped, run from "."',
      () async {
        exec.next = _ok('absent\n');
        expect(await fs.probePath("/srv/it's here"), PathProbe.absent);
        expect(exec.repoPaths.single, '.');
        final script = exec.calls.single[2];
        expect(exec.calls.single.take(2), ['sh', '-c']);
        expect(script, contains("p='/srv/it'\\''s here'"));
        expect(script, contains('test -e "\$p"'));
        expect(script, contains('dirname'));
      },
    );

    test('maps all three outcomes', () async {
      exec.next = _ok('exists');
      expect(await fs.probePath('/a'), PathProbe.exists);
      exec.next = _ok('absent');
      expect(await fs.probePath('/a'), PathProbe.absent);
      exec.next = _ok('noparent');
      expect(await fs.probePath('/a'), PathProbe.noParent);
      exec.next = const SSHCommandResult(exitCode: 1, stdout: '', stderr: '');
      await expectLater(fs.probePath('/a'), throwsA(isA<HostFsException>()));
    });
  });

  test('makeDirs issues mkdir -p -- with the escaped path', () async {
    await fs.makeDirs('/srv/new parent');
    expect(exec.calls.single, ['sh', '-c', "mkdir -p -- '/srv/new parent'"]);
  });

  group('removeDirGuarded', () {
    test('deletes exactly parent/name with rm -rf --', () async {
      await fs.removeDirGuarded(
        path: '/srv/code/myrepo',
        expectedParent: '/srv/code',
        expectedName: 'myrepo',
      );
      expect(exec.calls.single, ['sh', '-c', "rm -rf -- '/srv/code/myrepo'"]);
    });

    test('tolerates a trailing slash on the parent', () async {
      await fs.removeDirGuarded(
        path: '/srv/code/myrepo',
        expectedParent: '/srv/code/',
        expectedName: 'myrepo',
      );
      expect(exec.calls, hasLength(1));
    });

    test('refusal matrix — never reaches the executor', () async {
      Future<void> refuses({
        required String path,
        required String parent,
        required String name,
      }) {
        return expectLater(
          fs.removeDirGuarded(
            path: path,
            expectedParent: parent,
            expectedName: name,
          ),
          throwsArgumentError,
        );
      }

      // Relative parent.
      await refuses(path: 'code/x', parent: 'code', name: 'x');
      // Root parent.
      await refuses(path: '/x', parent: '/', name: 'x');
      // Path/name mismatch.
      await refuses(path: '/srv/other', parent: '/srv', name: 'x');
      // Traversal as the name.
      await refuses(path: '/srv/..', parent: '/srv', name: '..');
      // Option-looking name.
      await refuses(path: '/srv/-rf', parent: '/srv', name: '-rf');
      // Name containing a separator.
      await refuses(path: '/srv/a/b', parent: '/srv', name: 'a/b');
      // Empty name.
      await refuses(path: '/srv/', parent: '/srv', name: '');

      expect(exec.calls, isEmpty, reason: 'no refusal may reach rm');
    });
  });

  group('helpers', () {
    test('joinPath', () {
      expect(HostFsService.joinPath('/srv/code', 'x'), '/srv/code/x');
      expect(HostFsService.joinPath('/srv/code/', 'x'), '/srv/code/x');
      expect(HostFsService.joinPath('/', 'x'), '/x');
    });

    test('isValidRepoDirName', () {
      expect(HostFsService.isValidRepoDirName('my-repo'), isTrue);
      expect(HostFsService.isValidRepoDirName('.dotfiles'), isTrue);
      expect(HostFsService.isValidRepoDirName(''), isFalse);
      expect(HostFsService.isValidRepoDirName(' pad '), isFalse);
      expect(HostFsService.isValidRepoDirName('.'), isFalse);
      expect(HostFsService.isValidRepoDirName('..'), isFalse);
      expect(HostFsService.isValidRepoDirName('a/b'), isFalse);
      expect(HostFsService.isValidRepoDirName('-rf'), isFalse);
    });
  });
}
