// CloneJobController: the clone state machine. Covers the success path with
// live progress, early failures (dest exists / missing parent), the mkdir
// toggle, cancellation with SIGTERM + guarded cleanup, the no-delete guarantee
// for pre-existing destinations, and the single-job entry guard.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/forge/forge.dart';
import 'package:remote_magic_git/core/output/output_log.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/core/workspace/clone_controller.dart';

class _FakeHandle implements SSHStreamHandle {
  final _stdout = StreamController<String>.broadcast();
  final _stderr = StreamController<String>.broadcast();
  final exit = Completer<int?>();
  int cancels = 0;

  @override
  Stream<String> get stdout => _stdout.stream;
  @override
  Stream<String> get stderr => _stderr.stream;
  @override
  Future<int?> get exitCode => exit.future;

  void emitErr(String chunk) => _stderr.add(chunk);
  void emitOut(String chunk) => _stdout.add(chunk);

  Future<void> finish(int? code) async {
    if (!exit.isCompleted) exit.complete(code);
    await _stdout.close();
    await _stderr.close();
  }

  @override
  Future<void> cancel() async {
    cancels++;
    await finish(null);
  }
}

/// Scripted one-shot results (for HostFsService probes/mkdir/rm) plus a
/// controllable stream handle for the clone itself.
class _FakeExecutor extends SSHCommandExecutor {
  final List<List<String>> calls = [];
  final List<String> repoPaths = [];
  final List<SSHCommandResult> results = [];
  final List<List<String>> streamCalls = [];
  final List<Map<String, String>?> streamEnvs = [];
  final List<String> streamRepoPaths = [];
  _FakeHandle handle = _FakeHandle();

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
  }) async {
    calls.add(gitArgs);
    repoPaths.add(repoPath);
    if (results.isEmpty) {
      fail('unexpected execute: $gitArgs');
    }
    return results.removeAt(0);
  }

  @override
  Future<SSHStreamHandle> executeStream({
    required String repoPath,
    required List<String> gitArgs,
    Map<String, String>? extraEnv,
    Duration openTimeout = SSHCommandExecutor.defaultTimeout,
  }) async {
    streamCalls.add(gitArgs);
    streamEnvs.add(extraEnv);
    streamRepoPaths.add(repoPath);
    return handle;
  }
}

SSHCommandResult _ok(String stdout) =>
    SSHCommandResult(exitCode: 0, stdout: stdout, stderr: '');

const _req = CloneRequest(
  source: ForgeCloneSource(
    forge: Forge.github,
    host: 'github.com',
    slug: 'mac/magic-git',
  ),
  parentDir: '/srv/code',
  name: 'magic-git',
);

void main() {
  late _FakeExecutor exec;
  late ProviderContainer container;
  late CloneJobController job;

  setUp(() {
    exec = _FakeExecutor();
    container = ProviderContainer(
      overrides: [activeExecutorProvider.overrideWithValue(exec)],
    );
    addTearDown(container.dispose);
    job = container.read(cloneJobProvider.notifier);
  });

  CloneJobState jobState() => container.read(cloneJobProvider);
  List<String> logLines() => [
    for (final l in container.read(outputLogProvider).lines) l.text,
  ];

  test('success: probe → stream with progress → succeeded, no cleanup',
      () async {
    exec.results.add(_ok('absent'));
    final fut = job.run(_req);
    await pumpEventQueue();

    expect(exec.streamCalls.single, [
      'gh', 'repo', 'clone', 'mac/magic-git', 'magic-git', '--', '--progress',
    ]);
    expect(exec.streamRepoPaths.single, '/srv/code');
    expect(exec.streamEnvs.single, isNull, reason: 'github.com needs no GH_HOST');
    expect(jobState().phase, CloneJobPhase.cloning);
    expect(jobState().destPath, '/srv/code/magic-git');

    exec.handle.emitErr('Receiving objects:  10%\rReceiving objects:  60%');
    await pumpEventQueue();
    expect(jobState().progressLine, 'Receiving objects:  60%');

    exec.handle.emitErr('\rReceiving objects: 100%, done.\n');
    await exec.handle.finish(0);
    expect(await fut, isTrue);
    expect(jobState().phase, CloneJobPhase.succeeded);
    expect(logLines().last, '✓ completed');
    expect(exec.calls, hasLength(1), reason: 'only the probe — never rm');
  });

  test('an existing destination fails before any stream or delete', () async {
    exec.results.add(_ok('exists'));
    expect(await job.run(_req), isFalse);
    expect(jobState().phase, CloneJobPhase.failed);
    expect(jobState().error, contains('already exists'));
    expect(exec.streamCalls, isEmpty);
    expect(exec.calls, hasLength(1));
  });

  test('missing parent without the toggle fails; with it, mkdir -p runs',
      () async {
    exec.results.add(_ok('noparent'));
    expect(await job.run(_req), isFalse);
    expect(jobState().error, contains("parent folder doesn't exist"));
    expect(exec.calls, hasLength(1), reason: 'no mkdir without the toggle');

    exec.results.add(_ok('noparent'));
    exec.results.add(_ok('')); // mkdir
    exec.handle = _FakeHandle();
    const withParents = CloneRequest(
      source: UrlCloneSource('https://example.com/r.git'),
      parentDir: '/srv/new',
      name: 'r',
      createParents: true,
    );
    final fut = job.run(withParents);
    await pumpEventQueue();
    expect(exec.calls[2], ['sh', '-c', "mkdir -p -- '/srv/new'"]);
    expect(exec.streamCalls.single, [
      'git', 'clone', '--progress', '--', 'https://example.com/r.git', 'r',
    ]);
    await exec.handle.finish(0);
    expect(await fut, isTrue);
  });

  test('cancel: SIGTERM, then guarded rm of the partial dir, phase cancelled',
      () async {
    exec.results.add(_ok('absent')); // pre-check
    final fut = job.run(_req);
    await pumpEventQueue();
    expect(jobState().phase, CloneJobPhase.cloning);

    exec.results.add(_ok('exists')); // cleanup probe: partial dir landed
    exec.results.add(_ok('')); // rm
    await job.cancel();
    expect(await fut, isFalse);

    expect(exec.handle.cancels, 1);
    expect(jobState().phase, CloneJobPhase.cancelled);
    expect(
      exec.calls.last,
      ['sh', '-c', "rm -rf -- '/srv/code/magic-git'"],
      reason: 'partial destination cleaned up',
    );
    expect(logLines().last, '✗ terminated');
  });

  test('failure: exit 128 cleans up and carries the stderr tail', () async {
    exec.results.add(_ok('absent'));
    final fut = job.run(_req);
    await pumpEventQueue();

    exec.handle.emitErr('fatal: repository not found\n');
    exec.results.add(_ok('exists')); // cleanup probe
    exec.results.add(_ok('')); // rm
    await exec.handle.finish(128);
    expect(await fut, isFalse);
    expect(jobState().phase, CloneJobPhase.failed);
    expect(jobState().error, contains('repository not found'));
    expect(logLines(), contains('✗ exited with code 128'));
  });

  test('failure with no partial dir skips the delete entirely', () async {
    exec.results.add(_ok('absent'));
    final fut = job.run(_req);
    await pumpEventQueue();

    exec.results.add(_ok('absent')); // cleanup probe: git left nothing
    await exec.handle.finish(1);
    expect(await fut, isFalse);
    expect(
      exec.calls.every((c) => !c.join(' ').contains('rm -rf')),
      isTrue,
      reason: 'nothing to delete → rm never issued',
    );
  });

  test('a GHE source rides GH_HOST on the stream', () async {
    exec.results.add(_ok('absent'));
    const ghe = CloneRequest(
      source: ForgeCloneSource(
        forge: Forge.github,
        host: 'ghe.corp.example',
        slug: 'team/x',
      ),
      parentDir: '/srv/code',
      name: 'x',
    );
    final fut = job.run(ghe);
    await pumpEventQueue();
    expect(exec.streamEnvs.single, {'GH_HOST': 'ghe.corp.example'});
    await exec.handle.finish(0);
    await fut;
  });

  test('only one job at a time; terminal states allow a re-run', () async {
    exec.results.add(_ok('absent'));
    final fut = job.run(_req);
    await pumpEventQueue();

    expect(await job.run(_req), isFalse, reason: 'second run refused');
    expect(exec.streamCalls, hasLength(1));

    await exec.handle.finish(0);
    expect(await fut, isTrue);

    exec.handle = _FakeHandle();
    exec.results.add(_ok('absent'));
    final again = job.run(_req);
    await pumpEventQueue();
    await exec.handle.finish(0);
    expect(await again, isTrue, reason: 'succeeded → re-run allowed');
  });

  test('an invalid name fails before touching the executor', () async {
    const bad = CloneRequest(
      source: UrlCloneSource('https://x/r.git'),
      parentDir: '/srv',
      name: '../evil',
    );
    expect(await job.run(bad), isFalse);
    expect(exec.calls, isEmpty);
    expect(exec.streamCalls, isEmpty);
  });
}
