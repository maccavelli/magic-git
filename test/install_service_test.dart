// InstallService: capability probing (incl. arch) and the sideload
// orchestration (temp dir → upload → env-driven install script).

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/settings/install_service.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';

/// Records every execute()/uploadBytes() call and returns canned results in
/// order, so the sideload sequence can be asserted without a real transport.
class _RecordingExecutor extends SSHCommandExecutor {
  _RecordingExecutor(this._results) : super(SSHClientManager());
  final List<SSHCommandResult> _results;
  int _i = 0;

  final List<List<String>> calls = [];
  final List<Map<String, String>?> envs = [];
  final List<(String, int)> uploads = []; // (remotePath, byteLength)

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
  }) async {
    calls.add(gitArgs);
    envs.add(extraEnv);
    return _results[_i++];
  }

  @override
  Future<void> uploadBytes(String remotePath, Uint8List bytes) async {
    uploads.add((remotePath, bytes.length));
  }
}

SSHCommandResult _ok(String out) =>
    SSHCommandResult(exitCode: 0, stdout: out, stderr: '');

void main() {
  group('probeCapabilities', () {
    test('parses sudo, package managers, and architecture', () async {
      final exec = _RecordingExecutor([
        _ok('SUDO=1\nARCH=aarch64\nPM=apt-get\nPM=snap\n'),
      ]);
      final caps = await InstallService(exec).probeCapabilities('/repo');
      expect(caps.passwordlessSudo, isTrue);
      expect(caps.hasApt, isTrue);
      expect(caps.hasSnap, isTrue);
      expect(caps.hasDnf, isFalse);
      expect(caps.arch, 'arm64'); // aarch64 → arm64
    });

    test('x86_64 normalizes to amd64; no sudo reads false', () async {
      final exec = _RecordingExecutor([_ok('SUDO=0\nARCH=x86_64\nPM=dnf\n')]);
      final caps = await InstallService(exec).probeCapabilities('/repo');
      expect(caps.passwordlessSudo, isFalse);
      expect(caps.hasDnf, isTrue);
      expect(caps.arch, 'amd64');
    });
  });

  group('sideload', () {
    test('makes a temp dir, uploads into it, then runs the install script '
        'with inputs passed via env', () async {
      final exec = _RecordingExecutor([
        _ok('/tmp/sl.XXidz'), // mktemp -d
        _ok('Installed glab to ~/.local/bin/glab'), // install script
      ]);
      final bytes = Uint8List.fromList(List.filled(2048, 7));

      final result = await InstallService(exec).sideload(
        repoPath: '/repo',
        bin: 'glab',
        bytes: bytes,
        filename: 'glab_1.107.0_linux_arm64.tar.gz',
      );

      expect(result.isSuccess, isTrue);
      // Uploaded to <tmpdir>/<basename>.
      expect(exec.uploads.single.$1,
          '/tmp/sl.XXidz/glab_1.107.0_linux_arm64.tar.gz');
      expect(exec.uploads.single.$2, 2048);
      // Second execute ran the sideload script with the three env inputs.
      final env = exec.envs[1]!;
      expect(env['SL_FILE'], '/tmp/sl.XXidz/glab_1.107.0_linux_arm64.tar.gz');
      expect(env['SL_BIN'], 'glab');
      expect(env['SL_TMP'], '/tmp/sl.XXidz');
    });

    test('a filename with path separators is reduced to its basename', () async {
      final exec = _RecordingExecutor([_ok('/tmp/d'), _ok('done')]);
      await InstallService(exec).sideload(
        repoPath: '/repo',
        bin: 'gh',
        bytes: Uint8List(4),
        filename: 'a/b/../evil name.tar.gz',
      );
      expect(exec.uploads.single.$1, '/tmp/d/evil name.tar.gz');
    });

    test('aborts (no upload) when the temp dir cannot be made', () async {
      final exec = _RecordingExecutor([_ok('')]); // mktemp printed nothing
      final result = await InstallService(exec).sideload(
        repoPath: '/repo',
        bin: 'gh',
        bytes: Uint8List(4),
        filename: 'gh',
      );
      expect(result.isSuccess, isFalse);
      expect(exec.uploads, isEmpty);
    });
  });
}
