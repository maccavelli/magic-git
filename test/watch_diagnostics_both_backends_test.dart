// 0026 deviation (c). The transition log must be fed by BOTH watch services.
//
// It was wired into RemoteWatchService only, so repos on this Mac produced no
// watcher lines and no transition records — while driving the same lifecycle
// engine, with the same restart budget and the same degrade-to-polling. The
// diagnostic that exposed the lease-ordering bug on the remote host would not
// have appeared for a local repo at all.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/local_watch_service.dart';
import 'package:remote_magic_git/core/git/remote_watch_service.dart';
import 'package:remote_magic_git/core/git/watch_diagnostics.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';

class _Handle implements SSHStreamHandle {
  final _out = StreamController<String>.broadcast();
  final _err = StreamController<String>.broadcast();
  @override
  Stream<String> get stdout => _out.stream;
  @override
  Stream<String> get stderr => _err.stream;
  @override
  Future<int?> get exitCode => Completer<int?>().future;
  @override
  Future<void> cancel() async {
    await _out.close();
    await _err.close();
  }
}

class _ArmsAlways extends SSHCommandExecutor {
  _ArmsAlways() : super(SSHClientManager());
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
  }) async =>
      const SSHCommandResult(exitCode: 0, stdout: 'inotifywait\n', stderr: '');

  @override
  Future<SSHStreamHandle> executeStream({
    required String repoPath,
    required List<String> gitArgs,
    Map<String, String>? extraEnv,
    Duration openTimeout = SSHCommandExecutor.defaultTimeout,
    OperationDescriptor? operation,
    OperationEventCallback? onOperationEvent,
  }) async => _Handle();
}

void main() {
  setUp(() {
    watchDiagnostics.clear();
    RemoteWatchService.resetWatcherCount();
  });
  tearDown(() {
    watchDiagnostics.clear();
    RemoteWatchService.resetWatcherCount();
  });

  test('the SSH backend records its watch transitions', () async {
    final sub = RemoteWatchService(
      _ArmsAlways(),
    ).watch('/srv/repo').listen((_) {});
    await pumpEventQueue();
    expect(
      watchDiagnostics.forRepo('/srv/repo').records,
      isNotEmpty,
      reason: 'the remote service feeds the transition log',
    );
    await sub.cancel();
  });

  test('the LOCAL backend records its watch transitions too', () async {
    // The half that was missing. A real directory, because LocalWatchService
    // arms `Directory.watch` for real — no shim, no fake.
    final dir = await Directory.systemTemp.createTemp('mg-localwatch-');
    Directory('${dir.path}/.git').createSync();
    addTearDown(() => dir.deleteSync(recursive: true));

    final sub = LocalWatchService().watch(dir.path).listen((_) {});
    await pumpEventQueue();

    final records = watchDiagnostics.forRepo(dir.path).records;
    expect(
      records,
      isNotEmpty,
      reason:
          'a local repo drives the same lifecycle engine and can degrade to '
          'polling the same way; if it records nothing, "why is this repo '
          'polling" is unanswerable for this backend',
    );
    expect(
      records.map((r) => r.kind),
      contains(WatchTransition.armed),
      reason: 'and a healthy local arm is recorded as armed',
    );
    await sub.cancel();
  });

  test(
    'a local watch on a missing path arms and then says nothing, forever',
    () async {
      // CHARACTERISATION, and a hazard worth naming. On macOS
      // `Directory.watch()` over a path that does not exist neither throws, nor
      // errors the stream, nor completes it — measured directly:
      //
      //     PROBE threwSync=false streamError=false done=false
      //
      // So the engine records `armed`, the UI shows a healthy watch, and no
      // event can ever arrive. Nothing in the app can tell this apart from a
      // quiet repository.
      //
      // This pins the behaviour, it does not bless it. If a future Dart or macOS
      // starts reporting the failure this goes red, and the right response is to
      // route it to onDiagnostic and rewrite this test — not to relax it.
      final lines = <String>[];
      final missing =
          '${Directory.systemTemp.path}/mg-missing-'
          '${DateTime.now().microsecondsSinceEpoch}';
      final sub = LocalWatchService(
        onDiagnostic: lines.add,
      ).watch(missing).listen((_) {}, onError: (Object _) {});
      await pumpEventQueue();

      expect(
        watchDiagnostics.forRepo(missing).records.map((r) => r.kind),
        contains(WatchTransition.armed),
        reason: 'it believes it armed',
      );
      expect(
        lines,
        isEmpty,
        reason:
            'and reports nothing, because the platform gives it nothing to '
            'report. The onDiagnostic wiring on the local failure paths is '
            'therefore present but UNTESTED on macOS — 0026 deviation (c).',
      );
      await sub.cancel();
    },
  );
}
