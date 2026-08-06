import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/forge/auth_probe_service.dart';
import 'package:remote_magic_git/core/forge/auth_status.dart';
import 'package:remote_magic_git/core/forge/forge.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';

class _FakeExecutor extends CommandExecutor {
  final SSHCommandResult Function(List<String> argv)? onExecute;

  _FakeExecutor({this.onExecute});

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
    if (onExecute != null) return onExecute!(gitArgs);
    return const SSHCommandResult(exitCode: 0, stdout: '', stderr: '');
  }

  @override
  Future<SSHStreamHandle> executeStream({
    required String repoPath,
    required List<String> gitArgs,
    Map<String, String>? extraEnv,
    Duration openTimeout = SSHCommandExecutor.defaultTimeout,
  }) =>
      throw UnimplementedError();

  @override
  Future<void> uploadBytes(String remotePath, Uint8List bytes, {String? routingRepo}) async {}

  @override
  void configureEnvironment({
    String? path,
    Map<String, String> binaries = const {},
  }) {}

  @override
  String? resolvedBinaryPath(String name) => null;

  @override
  void setForgeTokenNeutralization(Iterable<String> vars) {}

  @override
  void resetEnvironment() {}
}

void main() {
  group('AuthProbeService.probe', () {
    test('runs all three concurrent probes and assembles TargetAuth', () async {
      final argsSeen = <List<String>>[];
      final executor = _FakeExecutor(
        onExecute: (argv) {
          argsSeen.add(List.of(argv));
          if (argv.last == '--version') {
            return const SSHCommandResult(
              exitCode: 0,
              stdout: 'git version 2.48.1\n',
              stderr: '',
            );
          }
          if (argv.first == 'gh') {
            return const SSHCommandResult(
              exitCode: 0,
              stdout: 'github.com\n  ✓ Logged in to github.com account u (k)'
                  '\n  - Active account: true\n',
              stderr: '',
            );
          }
          return const SSHCommandResult(
            exitCode: 1,
            stdout: '',
            stderr: 'glab: not logged in',
          );
        },
      );
      final service = AuthProbeService(executor);

      final result = await service.probe(label: 'This Mac', isLocal: true);

      expect(result.label, 'This Mac');
      expect(result.isLocal, isTrue);
      expect(result.git.authenticated, isTrue);
      expect(result.git.detail, contains('2.48.1'));
      expect(result.gh.authenticated, isTrue);
      expect(result.gh.host, 'github.com');
      expect(result.glab.authenticated, isFalse);
      expect(
        argsSeen.map((a) => a.join(' ')),
        containsAll(['git --version', 'gh auth status', 'glab auth status']),
      );
    });

    test('missing binary (exit 127) marks tool as not present', () async {
      final executor = _FakeExecutor(
        onExecute: (argv) {
          if (argv.first == 'gh') {
            return const SSHCommandResult(
              exitCode: 127,
              stdout: '',
              stderr: 'gh: not found',
            );
          }
          return const SSHCommandResult(
            exitCode: 0,
            stdout: 'git version 2.48.1\n',
            stderr: '',
          );
        },
      );
      final service = AuthProbeService(executor);
      final result = await service.probe(label: 'x', isLocal: true);

      expect(result.gh.present, isFalse);
      expect(result.gh.level, ToolAuthLevel.bad);
      expect(result.git.present, isTrue);
    });

    test('a probe that throws (timeout) becomes ToolAuth.unknown', () async {
      final executor = _FakeExecutor(
        onExecute: (argv) {
          if (argv.first == 'gh') throw Exception('transport error');
          return const SSHCommandResult(
            exitCode: 0,
            stdout: 'git version 2.48.1\n',
            stderr: '',
          );
        },
      );
      final service = AuthProbeService(executor);
      final result = await service.probe(label: 'x', isLocal: true);

      expect(result.gh.checkFailed, isTrue);
      expect(result.gh.level, ToolAuthLevel.unknown);
      expect(result.git.checkFailed, isFalse);
    });
  });

  group('AuthProbeService.probeForgeCli', () {
    test('Forge.github runs gh auth status', () async {
      var calledWith = <String>[];
      final executor = _FakeExecutor(
        onExecute: (argv) {
          calledWith = List.of(argv);
          return const SSHCommandResult(
            exitCode: 0,
            stdout: 'github.com\n  ✓ Logged in to github.com account u (k)'
                '\n  - Active account: true\n',
            stderr: '',
          );
        },
      );
      final service = AuthProbeService(executor);

      final result = await service.probeForgeCli(Forge.github);

      expect(calledWith, ['gh', 'auth', 'status']);
      expect(result.authenticated, isTrue);
      expect(result.host, 'github.com');
    });

    test('Forge.gitlab runs glab auth status', () async {
      var calledWith = <String>[];
      final executor = _FakeExecutor(
        onExecute: (argv) {
          calledWith = List.of(argv);
          return const SSHCommandResult(
            exitCode: 0,
            stdout:
                'gitlab.com\n  ✓ Logged in to gitlab.com as u (/x/config.yml)\n',
            stderr: '',
          );
        },
      );
      final service = AuthProbeService(executor);

      final result = await service.probeForgeCli(Forge.gitlab);

      expect(calledWith, ['glab', 'auth', 'status']);
      expect(result.authenticated, isTrue);
      expect(result.host, 'gitlab.com');
    });

    test('non-present CLI returns missing', () async {
      final executor = _FakeExecutor(
        onExecute: (_) => const SSHCommandResult(
          exitCode: 127,
          stdout: '',
          stderr: 'gh: not found',
        ),
      );
      final service = AuthProbeService(executor);

      final result = await service.probeForgeCli(Forge.github);

      expect(result.present, isFalse);
      expect(result.level, ToolAuthLevel.bad);
    });

    test('a thrown exception becomes unknown', () async {
      final executor = _FakeExecutor(
        onExecute: (_) => throw Exception('drop'),
      );
      final service = AuthProbeService(executor);

      final result = await service.probeForgeCli(Forge.github);

      expect(result.checkFailed, isTrue);
      expect(result.level, ToolAuthLevel.unknown);
    });
  });
}
