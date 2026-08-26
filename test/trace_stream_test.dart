// Service-level coverage for `GlabService.traceStream` — the live `glab ci
// trace` channel. Pins the error/completion contract the UI depends on:
//   * a fully delivered log is a success even when the trace *process* exits
//     non-zero (#13, defensive — a failed-job trace must not paint a spurious
//     error over its complete log);
//   * a job that produced no output at all still terminates cleanly with one
//     empty tick (#3, so the view leaves its spinner);
//   * a genuine failure (no stdout + stderr) still surfaces as a stream error;
//   * an error arriving on the *stderr* substream is routed to the stream, not
//     leaked to the Zone (#1).

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/gitlab/glab_service.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';

/// A hand-driven [CommandStreamHandle]: the test pushes stdout/stderr and
/// completes the exit code to reproduce each trace shape.
class _FakeHandle implements CommandStreamHandle {
  final out = StreamController<String>();
  final err = StreamController<String>();
  final exit = Completer<int?>();
  var cancelled = false;

  @override
  Stream<String> get stdout => out.stream;
  @override
  Stream<String> get stderr => err.stream;
  @override
  Future<int?> get exitCode => exit.future;
  @override
  Future<void> cancel() async {
    cancelled = true;
    if (!out.isClosed) await out.close();
    if (!err.isClosed) await err.close();
  }
}

class _StreamExecutor extends SSHCommandExecutor {
  _StreamExecutor() : super(SSHClientManager());
  _FakeHandle? handle;
  List<String>? lastArgs;

  @override
  Future<SSHStreamHandle> executeStream({
    required String repoPath,
    required List<String> gitArgs,
    Map<String, String>? extraEnv,
    Duration openTimeout = SSHCommandExecutor.defaultTimeout,
    OperationDescriptor? operation,
    OperationEventCallback? onOperationEvent,
  }) async {
    lastArgs = gitArgs;
    return handle = _FakeHandle();
  }
}

/// Subscribes to a fresh trace stream and returns the collector plus the fake
/// handle (available only after the onListen `executeStream` resolves).
class _Trace {
  final List<String> events = [];
  Object? error;
  final done = Completer<void>();
}

void main() {
  late _StreamExecutor exec;
  late GlabService glab;

  setUp(() {
    exec = _StreamExecutor();
    glab = GlabService(exec)..debugOriginHostOverride = 'gitlab.com';
  });

  Future<(_Trace, _FakeHandle)> subscribe() async {
    final t = _Trace();
    glab
        .traceStream('/repo', 900)
        .listen(
          t.events.add,
          onError: (Object e) => t.error = e,
          onDone: () {
            if (!t.done.isCompleted) t.done.complete();
          },
        );
    // Let onListen → start()'s executeStream resolve and attach the listeners.
    await pumpEventQueue();
    final h = exec.handle!;
    addTearDown(h.cancel);
    return (t, h);
  }

  test(
    '#13: a delivered log with a non-zero trace exit is NOT an error',
    () async {
      final (t, h) = await subscribe();
      h.out.add('build step 1\n');
      h.out.add('build step 2\n');
      await pumpEventQueue();
      await h.out.close();
      await h.err.close();
      h.exit.complete(1); // a failed-job trace exits non-zero
      await t.done.future;

      expect(
        t.error,
        isNull,
        reason: 'a fully delivered log must not error on a non-zero exit',
      );
      expect(t.events.join(), contains('build step 1'));
      expect(t.events.join(), contains('build step 2'));
    },
  );

  test(
    '#3: a zero-output clean close emits one empty terminal tick, no error',
    () async {
      final (t, h) = await subscribe();
      await h.out.close(); // no stdout at all
      await h.err.close(); // no stderr
      h.exit.complete(0);
      await t.done.future;

      expect(t.error, isNull);
      expect(
        t.events,
        [''],
        reason: 'exactly one terminal tick so the view can leave its spinner',
      );
    },
  );

  test(
    'a trace that produced no stdout but wrote stderr surfaces an error',
    () async {
      final (t, h) = await subscribe();
      h.err.add('job not found\n');
      await pumpEventQueue();
      await h.err.close();
      await h.out.close();
      h.exit.complete(1);
      await t.done.future;

      expect(t.error, isA<GlabException>());
    },
  );

  test(
    '#1: an error on the stderr substream surfaces as a stream error',
    () async {
      final (t, h) = await subscribe();
      h.out.add('some output\n'); // sawStdout → #13 path won't also fire
      await pumpEventQueue();
      await h.out.close();
      h.err.addError(Exception('trace channel dropped'));
      await t.done.future;

      expect(
        t.error,
        isNotNull,
        reason: 'a stderr channel error must reach the stream, not the Zone',
      );
    },
  );

  test('the trace targets the job id via `glab ci trace`', () async {
    final (_, _) = await subscribe();
    expect(exec.lastArgs, ['glab', 'ci', 'trace', '900']);
  });
}
