import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/branch_comparison.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/environment_probe.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';

import 'helpers/mock_executor.dart';

const _repo = '/repo';
const _base = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _branch = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _tree = 'cccccccccccccccccccccccccccccccccccccccc';

void main() {
  group('parseMergeTreeOutput', () {
    test('clean exit 0 is tree OID only', () {
      final preview = parseMergeTreeOutput(exitCode: 0, stdout: '$_tree\u0000');
      expect(preview.state, MergePreviewState.clean);
      expect(preview.treeOid, _tree);
      expect(preview.conflictPaths, isEmpty);
    });

    test('conflict exit 1 lists paths after tree OID', () {
      final preview = parseMergeTreeOutput(
        exitCode: 1,
        stdout: '$_tree\u0000lib/a.dart\u0000docs/b.md\u0000',
      );
      expect(preview.state, MergePreviewState.conflicts);
      expect(preview.treeOid, _tree);
      expect(preview.conflictPaths, ['lib/a.dart', 'docs/b.md']);
    });

    test('malformed tree OID throws', () {
      expect(
        () => parseMergeTreeOutput(exitCode: 0, stdout: 'short\u0000'),
        throwsFormatException,
      );
    });

    test('exit >1 is not a prediction', () {
      expect(
        () => parseMergeTreeOutput(exitCode: 128, stdout: '$_tree\u0000'),
        throwsFormatException,
      );
    });
  });

  group('mergePreviewCapabilityForVersion', () {
    test('landed versions map to supported / unsupported', () {
      expect(
        mergePreviewCapabilityForVersion('2.38.0'),
        MergePreviewCapability.supported,
      );
      expect(
        mergePreviewCapabilityForVersion('2.44.0'),
        MergePreviewCapability.supported,
      );
      expect(
        mergePreviewCapabilityForVersion('2.37.9'),
        MergePreviewCapability.unsupported,
      );
      expect(mergePreviewCapabilityForVersion(null), isNull);
      expect(mergePreviewCapabilityForVersion('unparseable'), isNull);
    });
  });

  group('GitService.mergeTreePreview', () {
    test('unrelated histories skip merge-tree', () async {
      final exec = MockExecutor(
        onExecute: (call) {
          final args = call.gitArgs.join(' ');
          if (args.contains('merge-base')) {
            return const SSHCommandResult(exitCode: 1, stdout: '', stderr: '');
          }
          fail('merge-tree must not run for unrelated: $args');
        },
      );
      final preview = await GitService(
        exec,
      ).mergeTreePreview(_repo, baseOid: _base, branchOid: _branch);
      expect(preview.state, MergePreviewState.unrelated);
      expect(exec.calls, hasLength(1));
    });

    test('exit 0 clean and exit 1 conflicts', () async {
      var mode = 'clean';
      final exec = MockExecutor(
        onExecute: (call) {
          final args = call.gitArgs.join(' ');
          if (args.contains('merge-base')) {
            return const SSHCommandResult(
              exitCode: 0,
              stdout: '$_base\n',
              stderr: '',
            );
          }
          if (args.contains('merge-tree')) {
            expect(args, contains('--write-tree'));
            expect(args, contains('--name-only'));
            expect(args, contains('-z'));
            expect(args, contains('--no-messages'));
            expect(call.gitArgs, contains(_base));
            expect(call.gitArgs, contains(_branch));
            if (mode == 'clean') {
              return const SSHCommandResult(
                exitCode: 0,
                stdout: '$_tree\u0000',
                stderr: '',
              );
            }
            return const SSHCommandResult(
              exitCode: 1,
              stdout: '$_tree\u0000path/x.dart\u0000',
              stderr: '',
            );
          }
          fail('unexpected: $args');
        },
      );
      final git = GitService(exec);
      final clean = await git.mergeTreePreview(
        _repo,
        baseOid: _base,
        branchOid: _branch,
      );
      expect(clean.state, MergePreviewState.clean);
      expect(clean.treeOid, _tree);

      mode = 'conflict';
      final conflicted = await git.mergeTreePreview(
        _repo,
        baseOid: _base,
        branchOid: _branch,
      );
      expect(conflicted.state, MergePreviewState.conflicts);
      expect(conflicted.conflictPaths, ['path/x.dart']);
    });

    test('exit >1 is an error', () async {
      final exec = MockExecutor(
        onExecute: (call) {
          final args = call.gitArgs.join(' ');
          if (args.contains('merge-base')) {
            return const SSHCommandResult(
              exitCode: 0,
              stdout: '$_base\n',
              stderr: '',
            );
          }
          return const SSHCommandResult(
            exitCode: 128,
            stdout: '',
            stderr: 'fatal: bad',
          );
        },
      );
      await expectLater(
        GitService(
          exec,
        ).mergeTreePreview(_repo, baseOid: _base, branchOid: _branch),
        throwsA(isA<GitException>()),
      );
    });

    test('concurrency gate serializes per repo', () async {
      var inFlight = 0;
      var maxInFlight = 0;
      final release = <Completer<void>>[];
      final exec = _GatedExecutor(
        onMergeTree: () async {
          inFlight++;
          if (inFlight > maxInFlight) maxInFlight = inFlight;
          final gate = Completer<void>();
          release.add(gate);
          await gate.future;
          inFlight--;
          return const SSHCommandResult(
            exitCode: 0,
            stdout: '$_tree\u0000',
            stderr: '',
          );
        },
      );
      final git = GitService(exec);
      final a = git.mergeTreePreview(_repo, baseOid: _base, branchOid: _branch);
      final b = git.mergeTreePreview(
        _repo,
        baseOid: _base,
        branchOid: 'dddddddddddddddddddddddddddddddddddddddd',
      );
      // First call enters merge-tree and parks; second waits on the gate.
      for (var i = 0; i < 20 && release.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect(release, hasLength(1));
      expect(maxInFlight, 1);
      release.first.complete();
      for (var i = 0; i < 20 && release.length < 2; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect(release, hasLength(2));
      expect(maxInFlight, 1);
      release.last.complete();
      await Future.wait([a, b]);
      expect(maxInFlight, 1);
    });
  });

  group('providers', () {
    test('capability uses landed version without probing', () async {
      final container = ProviderContainer(
        overrides: [
          binaryEnvironmentProvider.overrideWith(
            () => _EnvNotifier(
              const RemoteEnvironment(
                os: 'macos',
                path: '/usr/bin',
                found: {'git': '/usr/bin/git'},
                versions: {'git': '2.39.0'},
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      final cap = await container.read(
        mergePreviewCapabilityProvider((
          repoPath: _repo,
          sessionEpoch: 1,
        )).future,
      );
      expect(cap, MergePreviewCapability.supported);
    });

    test('absent version probes on demand; unparseable is error', () async {
      var probed = false;
      final exec = MockExecutor(
        onExecute: (call) {
          probed = true;
          expect(call.gitArgs.join(' '), contains('--version'));
          return const SSHCommandResult(
            exitCode: 0,
            stdout: 'VER=git=git version 2.30.0\n',
            stderr: '',
          );
        },
      );
      final container = ProviderContainer(
        overrides: [
          activeExecutorProvider.overrideWithValue(exec),
          binaryEnvironmentProvider.overrideWith(
            () => _EnvNotifier(
              const RemoteEnvironment(
                os: 'linux',
                path: '/usr/bin',
                found: {'git': '/usr/bin/git'},
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      final cap = await container.read(
        mergePreviewCapabilityProvider((
          repoPath: _repo,
          sessionEpoch: 2,
        )).future,
      );
      expect(probed, isTrue);
      expect(cap, MergePreviewCapability.unsupported);
    });

    test('unsupported capability short-circuits merge-tree', () async {
      final git = _CountingGit();
      final container = ProviderContainer(
        overrides: [
          gitServiceProvider.overrideWithValue(git),
          binaryEnvironmentProvider.overrideWith(
            () => _EnvNotifier(
              const RemoteEnvironment(
                os: 'macos',
                path: '/usr/bin',
                found: {'git': '/usr/bin/git'},
                versions: {'git': '2.24.0'},
              ),
            ),
          ),
          connectionProvider.overrideWith(() => _Connected(sessionEpoch: 3)),
        ],
      );
      addTearDown(container.dispose);
      final preview = await container.read(
        branchMergePreviewProvider((
          repoPath: _repo,
          baseOid: _base,
          branchOid: _branch,
        )).future,
      );
      expect(preview.state, MergePreviewState.unsupported);
      expect(git.mergeTreeCalls, 0);
    });

    test('OID-keyed preview does not serve a moved tip', () async {
      final git = _CountingGit()
        ..handler = ({required baseOid, required branchOid}) =>
            BranchMergePreview.clean(treeOid: _tree);
      final container = ProviderContainer(
        overrides: [
          gitServiceProvider.overrideWithValue(git),
          binaryEnvironmentProvider.overrideWith(
            () => _EnvNotifier(
              const RemoteEnvironment(
                os: 'macos',
                path: '/usr/bin',
                found: {'git': '/usr/bin/git'},
                versions: {'git': '2.44.0'},
              ),
            ),
          ),
          connectionProvider.overrideWith(() => _Connected(sessionEpoch: 4)),
        ],
      );
      addTearDown(container.dispose);

      const tip1 = _branch;
      const tip2 = 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee';
      await container.read(
        branchMergePreviewProvider((
          repoPath: _repo,
          baseOid: _base,
          branchOid: tip1,
        )).future,
      );
      await container.read(
        branchMergePreviewProvider((
          repoPath: _repo,
          baseOid: _base,
          branchOid: tip2,
        )).future,
      );
      expect(git.mergeTreeCalls, 2);
      expect(git.lastBranchOid, tip2);
    });
  });

  group('ConflictScanController', () {
    test('never records failed scans as clean', () async {
      final git = _CountingGit()
        ..handler = ({required baseOid, required branchOid}) {
          if (branchOid.startsWith('b')) {
            return BranchMergePreview.conflicts(
              treeOid: _tree,
              conflictPaths: const ['f'],
            );
          }
          throw StateError('boom');
        };
      final container = ProviderContainer(
        overrides: [
          gitServiceProvider.overrideWithValue(git),
          binaryEnvironmentProvider.overrideWith(
            () => _EnvNotifier(
              const RemoteEnvironment(
                os: 'macos',
                path: '/usr/bin',
                found: {'git': '/usr/bin/git'},
                versions: {'git': '2.44.0'},
              ),
            ),
          ),
          connectionProvider.overrideWith(() => _Connected(sessionEpoch: 5)),
        ],
      );
      addTearDown(container.dispose);

      final ctl = container.read(
        conflictScanControllerProvider(_repo).notifier,
      );
      await ctl.scan(
        baseOid: _base,
        branches: [
          (refName: 'refs/heads/feature', oid: _branch),
          (
            refName: 'refs/heads/broken',
            oid: 'ffffffffffffffffffffffffffffffffffffffff',
          ),
        ],
      );
      final state = container.read(conflictScanControllerProvider(_repo));
      expect(state.scanning, isFalse);
      expect(state.conflictRefNames, {'refs/heads/feature'});
      expect(state.byRefName.containsKey('refs/heads/broken'), isFalse);
    });
  });
}

class _EnvNotifier extends BinaryEnvironmentNotifier {
  _EnvNotifier(this._env);
  final RemoteEnvironment _env;
  @override
  RemoteEnvironment build() => _env;
}

class _Connected extends ConnectionController {
  _Connected({required this.sessionEpoch});
  final int sessionEpoch;
  @override
  ConnectionState build() => ConnectionState(
    phase: ConnectionPhase.connected,
    repoPath: _repo,
    sessionEpoch: sessionEpoch,
  );
}

class _CountingGit extends GitService {
  _CountingGit() : super(SSHCommandExecutor(SSHClientManager()));

  int mergeTreeCalls = 0;
  String? lastBranchOid;
  BranchMergePreview Function({
    required String baseOid,
    required String branchOid,
  })?
  handler;

  @override
  Future<BranchMergePreview> mergeTreePreview(
    String repoPath, {
    required String baseOid,
    required String branchOid,
  }) async {
    mergeTreeCalls++;
    lastBranchOid = branchOid;
    return handler?.call(baseOid: baseOid, branchOid: branchOid) ??
        BranchMergePreview.clean(treeOid: _tree);
  }
}

/// Executor that can park on merge-tree so concurrency is observable.
class _GatedExecutor extends CommandExecutor {
  _GatedExecutor({required this.onMergeTree});

  final Future<SSHCommandResult> Function() onMergeTree;

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
    OperationDescriptor? operation,
    OperationEventCallback? onOperationEvent,
  }) async {
    final args = gitArgs.join(' ');
    if (args.contains('merge-base')) {
      return const SSHCommandResult(
        exitCode: 0,
        stdout: '$_base\n',
        stderr: '',
      );
    }
    if (args.contains('merge-tree')) {
      return onMergeTree();
    }
    fail('unexpected: $args');
  }

  @override
  Future<SSHStreamHandle> executeStream({
    required String repoPath,
    required List<String> gitArgs,
    Map<String, String>? extraEnv,
    Duration openTimeout = SSHCommandExecutor.defaultTimeout,
    OperationDescriptor? operation,
    OperationEventCallback? onOperationEvent,
  }) => throw UnimplementedError();

  @override
  Future<void> uploadBytes(
    String remotePath,
    Uint8List bytes, {
    String? routingRepo,
  }) async {}

  @override
  void configureEnvironment({
    String? path,
    Map<String, String> binaries = const {},
  }) {}

  @override
  void resetEnvironment() {}

  @override
  void setForgeTokenNeutralization(Iterable<String> vars) {}

  @override
  String? resolvedBinaryPath(String name) => null;
}
