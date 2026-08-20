import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:remote_magic_git/core/exec/scoped_command_executor.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/core/utils/file_actions.dart';
import 'package:remote_magic_git/features/viewer/remote_edit_service.dart';

class MockFileActions extends FileActions {
  final List<String> openedPaths = [];

  @override
  Future<void> openFiles(List<String> absolutePaths) async {
    openedPaths.addAll(absolutePaths);
  }
}

class FakeExecutor implements ScopedCommandExecutor {
  final Map<String, String> remoteHashes;
  final Map<String, List<int>> uploads = {};

  FakeExecutor(this.remoteHashes);

  @override
  Future<CommandResult> execute({
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
    if (gitArgs.first == 'hash-object') {
      final path = gitArgs.last;
      return CommandResult(
        exitCode: 0,
        stdout: remoteHashes[path] ?? '',
        stderr: '',
      );
    }
    return const CommandResult(exitCode: 1, stdout: '', stderr: '');
  }

  @override
  Future<void> uploadBytes(
    String destinationPath,
    List<int> bytes, {
    String? routingRepo,
  }) async {
    uploads[destinationPath] = bytes;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeGitService implements GitService {
  final Map<String, String> remoteFiles;

  FakeGitService(this.remoteFiles);

  @override
  Future<String> readFileBase64(String repoPath, String path) async {
    final content = remoteFiles[path] ?? '';
    return base64.encode(utf8.encode(content));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class ThrowingGitService implements GitService {
  @override
  Future<String> readFileBase64(String repoPath, String path) async =>
      throw const GitException(
        'read failed over SSH',
        CommandResult(exitCode: 1, stdout: '', stderr: 'boom'),
      );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'RemoteEditManager downloads file, saves to temp, and opens it',
    () async {
      final mockFileActions = MockFileActions();
      final fakeExecutor = FakeExecutor({'file.txt': 'hash1'});
      final fakeGit = FakeGitService({'file.txt': 'hello world'});

      final container = ProviderContainer(
        overrides: [
          fileActionsProvider.overrideWithValue(mockFileActions),
          activeExecutorProvider.overrideWithValue(fakeExecutor),
          gitServiceProvider.overrideWithValue(fakeGit),
        ],
      );

      final manager = container.read(remoteEditServiceProvider.notifier);
      await manager.openRemoteFile('repo1', 'file.txt');

      expect(mockFileActions.openedPaths, isNotEmpty);
      final openedPath = mockFileActions.openedPaths.first;
      expect(openedPath, endsWith('file.txt'));

      final tempFile = File(openedPath);
      expect(tempFile.existsSync(), isTrue);
      expect(tempFile.readAsStringSync(), 'hello world');

      // Test that the session was saved correctly
      final session = container.read(
        remoteEditServiceProvider,
      )['repo1/file.txt'];
      expect(session, isNotNull);
      expect(session!.lastKnownHash, 'hash1');
    },
  );

  // 0009 H15: an open that fails (download, decode, temp IO) must land on
  // the notice provider like every sync failure — callers fire-and-forget,
  // so a thrown error would be silent.
  test('a failed open surfaces a notice instead of throwing', () async {
    final container = ProviderContainer(
      overrides: [
        fileActionsProvider.overrideWithValue(MockFileActions()),
        activeExecutorProvider.overrideWithValue(FakeExecutor({})),
        gitServiceProvider.overrideWithValue(ThrowingGitService()),
      ],
    );
    addTearDown(container.dispose);

    final manager = container.read(remoteEditServiceProvider.notifier);
    await manager.openRemoteFile('repo1', 'file.txt'); // must not throw

    final notice = container.read(remoteEditNoticeProvider);
    expect(notice, isNotNull);
    expect(notice!.title, 'Remote Edit Open Failed');
    expect(notice.message, contains('file.txt'));
    expect(container.read(remoteEditServiceProvider), isEmpty);
  });

  // 0009 M24: atomic saves (temp + rename) must still sync — the watch is on
  // the scratch directory, not the original inode — and a conflict the user
  // declined must not re-open the dialog for the same bytes.
  test('atomic saves sync; a declined conflict stays quiet for the same '
      'bytes', () async {
    final mockFileActions = MockFileActions();
    final fakeExecutor = FakeExecutor({'file.txt': 'hash1'});
    final fakeGit = FakeGitService({'file.txt': 'hello world'});
    final container = ProviderContainer(
      overrides: [
        fileActionsProvider.overrideWithValue(mockFileActions),
        activeExecutorProvider.overrideWithValue(fakeExecutor),
        gitServiceProvider.overrideWithValue(fakeGit),
      ],
    );
    addTearDown(container.dispose);

    final manager = container.read(remoteEditServiceProvider.notifier);
    await manager.openRemoteFile('repo1', 'file.txt');
    final session = container.read(
      remoteEditServiceProvider,
    )['repo1/file.txt']!;

    // The remote moved on — the next local save conflicts.
    fakeExecutor.remoteHashes['file.txt'] = 'hash2';

    // An editor-style atomic save: sibling temp file renamed over the real
    // one. A modify-only watch on the original inode would never see this.
    File('${session.tempDir.path}/file.txt.tmp')
      ..writeAsStringSync('local edit')
      ..renameSync(session.tempFile.path);
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    expect(container.read(remoteEditNoticeProvider)?.isConflict, isTrue);

    // Decline: the watcher re-reporting the SAME bytes must stay quiet.
    manager.declineConflict('repo1/file.txt');
    container.read(remoteEditNoticeProvider.notifier).clear();
    session.tempFile.writeAsStringSync('local edit');
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    expect(container.read(remoteEditNoticeProvider), isNull);

    // A genuinely new save conflicts again.
    session.tempFile.writeAsStringSync('local edit, take two');
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    expect(container.read(remoteEditNoticeProvider)?.isConflict, isTrue);
  });
}
