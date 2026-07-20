import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/utils/file_actions.dart';
import 'package:remote_magic_git/features/viewer/remote_edit_service.dart';
import 'package:remote_magic_git/core/exec/scoped_command_executor.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';

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
  Future<void> uploadBytes(String destinationPath, List<int> bytes) async {
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

void main() {
  test('RemoteEditManager downloads file, saves to temp, and opens it', () async {
    final mockFileActions = MockFileActions();
    final fakeExecutor = FakeExecutor({'file.txt': 'hash1'});
    final fakeGit = FakeGitService({'file.txt': 'hello world'});
    
    final container = ProviderContainer(
      overrides: [
        fileActionsProvider.overrideWithValue(mockFileActions),
        activeExecutorProvider.overrideWithValue(fakeExecutor),
        gitServiceProvider.overrideWithValue(fakeGit),
      ]
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
    final session = container.read(remoteEditServiceProvider)['repo1/file.txt'];
    expect(session, isNotNull);
    expect(session!.lastKnownHash, 'hash1');
  });
}
