import 'dart:async';
import 'dart:math' show min;

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/remote_watch_service.dart';
import 'package:remote_magic_git/core/git/watch/admission/host_watcher_budget.dart';
import 'package:remote_magic_git/core/git/watch/admission/watch_admission.dart';
import 'package:remote_magic_git/core/git/watch_event.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'helpers/conventional_git_dir.dart';
import 'helpers/fake_arm_settle.dart';
import 'helpers/fake_watcher_handle.dart';

class _FakeExecutor extends SSHCommandExecutor {
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
    return const SSHCommandResult(exitCode: 0, stdout: 'none\n', stderr: '');
  }
}

/// Reports fswatch available, but fails every attempt to actually open the
/// streaming channel — exercises the "watcher tool detected but the channel
/// itself never comes up" path without needing a real, unmockable
/// SSHStreamHandle (its constructor is private).
class _ThrowingStreamExecutor extends SSHCommandExecutor {
  _ThrowingStreamExecutor() : super(SSHClientManager());

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
    return const SSHCommandResult(exitCode: 0, stdout: 'fswatch\n', stderr: '');
  }

  @override
  Future<SSHStreamHandle> executeStream({
    required String repoPath,
    required List<String> gitArgs,
    Map<String, String>? extraEnv,
    Duration openTimeout = SSHCommandExecutor.defaultTimeout,
    OperationDescriptor? operation,
    OperationEventCallback? onOperationEvent,
  }) async {
    throw Exception('cannot open watcher channel');
  }
}

/// Reports no watcher tool on the first probe (degrading the service to
/// polling), then fswatch on every later probe with a working channel — the
/// "recovered from polling" path.
class _RecoveringExecutor extends SSHCommandExecutor {
  _RecoveringExecutor() : super(SSHClientManager());

  int probes = 0;

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
    final tool = probes++ == 0 ? 'none' : 'fswatch';
    return SSHCommandResult(exitCode: 0, stdout: '$tool\n', stderr: '');
  }

  @override
  Future<SSHStreamHandle> executeStream({
    required String repoPath,
    required List<String> gitArgs,
    Map<String, String>? extraEnv,
    Duration openTimeout = SSHCommandExecutor.defaultTimeout,
    OperationDescriptor? operation,
    OperationEventCallback? onOperationEvent,
  }) async {
    return FakeWatcherHandle.armed();
  }
}

/// Reports [tool] and hands back a handle the test controls.
class _DrivableExecutor extends SSHCommandExecutor {
  _DrivableExecutor({required this.tool, required this.handle})
    : super(SSHClientManager());

  final String tool;
  final FakeWatcherHandle handle;
  final armed = Completer<void>();
  List<String> lastStreamArgs = const [];

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
  }) async => SSHCommandResult(exitCode: 0, stdout: '$tool\n', stderr: '');

  @override
  Future<SSHStreamHandle> executeStream({
    required String repoPath,
    required List<String> gitArgs,
    Map<String, String>? extraEnv,
    Duration openTimeout = SSHCommandExecutor.defaultTimeout,
    OperationDescriptor? operation,
    OperationEventCallback? onOperationEvent,
  }) async {
    lastStreamArgs = gitArgs;
    if (!armed.isCompleted) armed.complete();
    return handle;
  }
}

/// The watcher probe fails once (a transport blip) and then reports fswatch.
/// Reading that failure as "this host has no watcher" is 0024 M3.
class _ProbeFailsOnceExecutor extends SSHCommandExecutor {
  _ProbeFailsOnceExecutor() : super(SSHClientManager());

  int probes = 0;

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
    // Exit 255 with empty stdout: what a dropped channel looks like. Today the
    // empty stdout falls through the switch to `none` and is cached.
    if (probes++ == 0) {
      return const SSHCommandResult(exitCode: 255, stdout: '', stderr: 'boom');
    }
    return const SSHCommandResult(exitCode: 0, stdout: 'fswatch\n', stderr: '');
  }

  @override
  Future<SSHStreamHandle> executeStream({
    required String repoPath,
    required List<String> gitArgs,
    Map<String, String>? extraEnv,
    Duration openTimeout = SSHCommandExecutor.defaultTimeout,
    OperationDescriptor? operation,
    OperationEventCallback? onOperationEvent,
  }) async => FakeWatcherHandle.armed();
}

/// Hands out a FRESH handle per arm — the single-handle fake above cannot be
/// listened to twice, which would fail an arm for the wrong reason.
class _MultiArmExecutor extends SSHCommandExecutor {
  _MultiArmExecutor() : super(SSHClientManager());

  final handles = <FakeWatcherHandle>[];

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
  }) async {
    final h = FakeWatcherHandle.armed();
    handles.add(h);
    return h;
  }
}

List<String> _chunk(String blob, int bytes) {
  final out = <String>[];
  for (var i = 0; i < blob.length; i += bytes) {
    out.add(blob.substring(i, min(i + bytes, blob.length)));
  }
  return out;
}

/// Runs fake time until [executor] has opened its watcher stream — what
/// awaiting `armed.future` did in real time. Bounded, so an arm that never
/// opens falls through to the assertions that say so instead of spinning.
void _untilStreamOpened(FakeAsync async, _DrivableExecutor executor) {
  final start = async.elapsed;
  async.flushMicrotasks();
  while (!executor.armed.isCompleted &&
      async.elapsed - start < const Duration(seconds: 10)) {
    async.elapse(const Duration(milliseconds: 5));
  }
}

void main() {
  test('falls back to polling when no watcher tool is available', () {
    fakeAsync((async) {
      final service = RemoteWatchService(
        _FakeExecutor(),
        gitDirOf: conventionalGitDir,
      );
      final events = <RepoWatchEvent>[];
      final sub = service
          .watch('/repo', pollInterval: const Duration(seconds: 5))
          .listen(events.add);

      async.elapse(Duration.zero);
      expect(events, isNotEmpty);
      expect(events.last.mode, WatchMode.polling);

      async.elapse(const Duration(seconds: 5));
      expect(events.length, greaterThanOrEqualTo(2));

      sub.cancel();
    });
  });

  test('recovering from polling back to event-driven stops the poll ticks '
      '(regression: the poll timer used to leak and fire forever)', () {
    fakeAsync((async) {
      final service = RemoteWatchService(
        _RecoveringExecutor(),
        gitDirOf: conventionalGitDir,
      );
      final events = <RepoWatchEvent>[];
      final sub = service
          .watch(
            '/repo',
            pollInterval: const Duration(seconds: 5),
            recoveryInterval: const Duration(seconds: 30),
          )
          .listen(events.add);

      // First probe finds no tool → polling mode, ticking every 5s.
      async.elapse(Duration.zero);
      expect(events.last.mode, WatchMode.polling);
      async.elapse(const Duration(seconds: 29));
      expect(events.length, greaterThanOrEqualTo(5));

      // Recovery probe finds fswatch and the channel opens → event-driven.
      async.elapse(const Duration(seconds: 2));
      expect(events.last.mode, WatchMode.eventDriven);
      final atRecovery = events.length;

      // No file changes arrive; a leaked poll timer would keep emitting a
      // tick (each one a status round trip) every 5s regardless.
      async.elapse(const Duration(seconds: 60));
      expect(
        events.length,
        atRecovery,
        reason: 'poll timer must be cancelled once event-driven recovers',
      );

      sub.cancel();
    });
  });

  test('a failed watcher start surfaces `stopped` immediately, not silently '
      'through the whole restart backoff window', () {
    fakeAsync((async) {
      final service = RemoteWatchService(
        _ThrowingStreamExecutor(),
        gitDirOf: conventionalGitDir,
      );
      final events = <RepoWatchEvent>[];
      final sub = service.watch('/repo').listen(events.add);

      // The channel-open fails right away; before the fix, nothing was ever
      // emitted here — subscribers would see no event at all through the
      // entire restart backoff, previously indistinguishable from "still
      // fine" (whatever mode a consumer's UI last rendered).
      async.elapse(Duration.zero);
      expect(events, isNotEmpty);
      expect(events.last.mode, WatchMode.stopped);

      sub.cancel();
    });
  });

  test('inotifywait argv carries one --exclude and three @-paths', () {
    // Was: assert all four `--exclude` flags are present. They were — on both
    // arms of the stdbuf fork — and three of them did nothing, because
    // inotifywait honours only the LAST one and warns about it on the very
    // stderr this app reads (MADR 0041 F8). A `contains` sees presence, never
    // effect; a COUNT is what would have caught it, so that is what this
    // asserts now.
    final args = remoteWatcherArgs(RemoteWatcherTool.inotifywait, null);
    expect(args.take(2), ['sh', '-c']);
    final script = args.last;

    expect(
      '--exclude '.allMatches(script),
      hasLength(2),
      reason: 'exactly one per fork arm — more means the earlier ones are dead',
    );
    expect(
      r"--exclude '\.lock$'".allMatches(script),
      hasLength(2),
      reason: 'lock files stay a filter: they live in .git/, which is watched',
    );

    // The three subtrees are not watched at all rather than filtered after the
    // fact — 259 of the largest repo's 701 watch descriptors sat under
    // .git/objects (0041 F9). The `./` prefix is the only spelling that works
    // when the watch root is `.`; the bare and absolute forms match nothing.
    for (final p in const [
      '@./.git/objects',
      '@./.git/logs',
      '@./.git/fsmonitor--daemon',
    ]) {
      expect(p.allMatches(script), hasLength(2), reason: '$p on both arms');
    }
    expect(script, isNot(contains('@.git/')));
    expect(
      script.indexOf('@./.git/objects'),
      greaterThan(script.indexOf('--format %w%f .')),
      reason: 'after the watch root, which is the form verified on a host',
    );
  });

  test('the LEASED recursive argv carries the same surface', () {
    // The assertion above reaches the un-leased legacy branch, which no live
    // arm takes: production always passes a heartbeat, so it always builds the
    // leased script. A sabotage run caught this — dropping the @-paths from the
    // leased branch alone left every assertion above green (MADR 0041 phase 5,
    // one survivor).
    final args = remoteWatcherArgs(
      RemoteWatcherTool.inotifywait,
      null,
      pidFile: '/r/.git/mg-watch.t.pid',
      heartbeat: '/r/.git/mg-watch.t.hb',
      lock: (gitDir: '/r/.git', token: 't'),
    );
    final script = args.last;

    expect(script, contains('mg-watch.t.hb'), reason: 'it is the leased form');
    expect('--exclude '.allMatches(script), hasLength(2));
    for (final p in const [
      '@./.git/objects',
      '@./.git/logs',
      '@./.git/fsmonitor--daemon',
    ]) {
      expect(p.allMatches(script), hasLength(2), reason: '$p on both arms');
    }
  });

  // ---- 0024 A1: the record split ----------------------------------------
  //
  // dartssh2 negotiates a 32 KiB maximum packet size (ssh_client.dart:57), so
  // that is the arrival shape these drive.
  group('record splitting', () {
    test('records straddling chunk boundaries survive intact', () {
      fakeAsync((async) {
        // Well under 512 (the engine's maxPathsPerTick) so the burst stays
        // path-scoped instead of overflowing to an unscoped tick.
        final paths = [for (var i = 0; i < 60; i++) 'src/m$i/f$i.dart'];
        final handle = FakeWatcherHandle.armed();
        final executor = _DrivableExecutor(tool: 'inotifywait', handle: handle);
        final service = RemoteWatchService(
          executor,
          gitDirOf: conventionalGitDir,
        );

        final seen = <String>{};
        final sub = service.watch('/repo').listen((e) => seen.addAll(e.paths));
        _untilStreamOpened(async, executor);
        async.letArmsSettle();

        // Deliberately awkward: 37 bytes cuts records mid-path constantly.
        for (final c in _chunk('${paths.join('\n')}\n', 37)) {
          handle.emitStdout(c);
        }
        // Longer than the coalescer's 1s minInterval/maxWait, so the burst has
        // actually been emitted rather than still being batched.
        async.elapse(const Duration(milliseconds: 1500));

        // First, last, and a middle one — cheap assertions. `containsAll` over
        // a large set builds a pathological mismatch description when it fails.
        expect(seen, contains(paths.first));
        expect(seen, contains(paths[30]));
        expect(seen, contains(paths.last));
        expect(seen, hasLength(paths.length));
        sub.cancel();
        async.flushMicrotasks();
      });
    });

    test('a large burst costs linear time, not a copy per record', () {
      fakeAsync((async) {
        const records = 20000;
        final blob = [
          for (var i = 0; i < records; i++) 'src/m$i/f$i.dart',
        ].join('\n');
        final chunks = _chunk('$blob\n', 32 * 1024);

        final handle = FakeWatcherHandle.armed();
        final executor = _DrivableExecutor(tool: 'inotifywait', handle: handle);
        final service = RemoteWatchService(
          executor,
          gitDirOf: conventionalGitDir,
        );
        final sub = service.watch('/repo').listen((_) {});
        _untilStreamOpened(async, executor);
        async.letArmsSettle();

        // The stopwatch runs on REAL time, which fake time does not drive: the
        // split happens inside the flushes below, so it times that work alone,
        // without the event-loop turns the real-time version also counted.
        final sw = Stopwatch()..start();
        for (final c in chunks) {
          handle.emitStdout(c);
        }
        for (
          var i = 0;
          i < chunks.length && handle.delivered < chunks.length;
          i++
        ) {
          async.flushMicrotasks();
        }
        sw.stop();

        // Measured: re-slicing the buffer per record costs ~134 ms here; a
        // cursor costs ~1 ms. 50 ms sits ~2.7x under the quadratic cost and
        // ~50x over the linear one, so it cannot flake on a slow machine and
        // cannot pass on the old implementation.
        expect(
          sw.elapsedMilliseconds,
          lessThan(50),
          reason: 'splitting must not copy the remaining buffer per record',
        );
        sub.cancel();
        async.flushMicrotasks();
      });
    });
  });

  // ---- 0024 H3: the watcher's stderr -------------------------------------
  group('watcher diagnostics', () {
    test('a diagnostic on stderr is surfaced, not discarded', () {
      fakeAsync((async) {
        final handle = FakeWatcherHandle.armed();
        final executor = _DrivableExecutor(tool: 'inotifywait', handle: handle);
        final diagnostics = <String>[];
        final service = RemoteWatchService(
          executor,
          onDiagnostic: diagnostics.add,
          gitDirOf: conventionalGitDir,
        );

        final sub = service.watch('/repo').listen((_) {});
        _untilStreamOpened(async, executor);
        async.letArmsSettle();

        // The one message that says WHY the watcher died, and names the knob.
        handle.emitStderr(
          'Failed to watch /home/u/src; upper limit on inotify watches reached\n',
        );
        async.elapse(Duration.zero);

        expect(diagnostics, hasLength(1));
        expect(diagnostics.single, contains('upper limit on inotify watches'));
        sub.cancel();
        async.flushMicrotasks();
      });
    });

    test('startup chatter is dropped, so it cannot crowd out a real one', () {
      fakeAsync((async) {
        // `inotifywait` prints these on every arm. They spent two of the twenty
        // lines each time, right where a real message lands — and next to them,
        // for months, sat `--exclude: only the last option will be taken into
        // consideration`, which nobody read (MADR 0041 F8).
        final handle = FakeWatcherHandle.armed();
        final executor = _DrivableExecutor(tool: 'inotifywait', handle: handle);
        final diagnostics = <String>[];
        final service = RemoteWatchService(
          executor,
          onDiagnostic: diagnostics.add,
          gitDirOf: conventionalGitDir,
        );

        final sub = service.watch('/repo').listen((_) {});
        _untilStreamOpened(async, executor);
        async.letArmsSettle();

        handle.emitStderr(
          'Setting up watches.  Beware: since -r was given, this may take a '
          'while!\n'
          'Watches established.\n'
          '--exclude: only the last option will be taken into consideration.\n',
        );
        async.elapse(Duration.zero);

        expect(
          diagnostics.where((d) => d.startsWith('Setting up watches')),
          isEmpty,
        );
        expect(
          diagnostics.where((d) => d.startsWith('Watches established')),
          isEmpty,
        );
        expect(
          diagnostics.where((d) => d.contains('only the last option')),
          isNotEmpty,
          reason:
              'the filter is an enumerated list of noise, not a pattern — it '
              'must not swallow a message nobody has seen yet',
        );
        sub.cancel();
        async.flushMicrotasks();
      });
    });

    test('a flooding watcher cannot fill the log', () {
      fakeAsync((async) {
        // inotifywait prints one failure line per directory it cannot watch, so
        // a host at its watch limit emits one per entry in the surface.
        final handle = FakeWatcherHandle.armed();
        final executor = _DrivableExecutor(tool: 'inotifywait', handle: handle);
        final diagnostics = <String>[];
        final service = RemoteWatchService(
          executor,
          onDiagnostic: diagnostics.add,
          gitDirOf: conventionalGitDir,
        );

        final sub = service.watch('/repo').listen((_) {});
        _untilStreamOpened(async, executor);
        async.letArmsSettle();

        for (var i = 0; i < 500; i++) {
          handle.emitStderr('Failed to watch /d$i\n');
        }
        async.elapse(const Duration(milliseconds: 50));

        expect(diagnostics, hasLength(RemoteWatchService.maxDiagnosticLines));
        sub.cancel();
        async.flushMicrotasks();
      });
    });
  });

  // ---- 0024 M3: a failed probe is not "no watcher" ------------------------
  test('a failed watcher probe retries instead of caching "none"', () {
    fakeAsync((async) {
      final service = RemoteWatchService(
        _ProbeFailsOnceExecutor(),
        gitDirOf: conventionalGitDir,
      );
      final events = <RepoWatchEvent>[];
      final sub = service
          .watch(
            '/repo',
            pollInterval: const Duration(seconds: 5),
            recoveryInterval: const Duration(minutes: 3),
          )
          .listen(events.add);

      async.elapse(Duration.zero);
      // Well inside the restart budget (2s, 4s, 6s) and far short of the
      // three-minute recovery probe that is the only other way back.
      async.elapse(const Duration(seconds: 10));

      expect(
        events.last.mode,
        WatchMode.eventDriven,
        reason: 'a transport blip must not cost three minutes of polling',
      );

      sub.cancel();
    });
  });

  group('watcher ceiling', () {
    test('the ceiling is derived from the transport budget', () {
      // Was `expect(maxConcurrentWatchers, 2)` — a constant that stood in front
      // of an 8-stream budget and never referred to it (MADR 0041 F7). It is
      // now that budget minus the two channels reserved for the CI trace and
      // clone progress, floored at 1.
      expect(
        RemoteWatchService(
          _FakeExecutor(),
          streamBudget: () => 8,
          gitDirOf: conventionalGitDir,
        ).maxConcurrentWatchers,
        8 - RemoteWatchService.reservedStreams,
      );
      expect(
        RemoteWatchService(
          _FakeExecutor(),
          streamBudget: () => 2,
          gitDirOf: conventionalGitDir,
        ).maxConcurrentWatchers,
        1,
        reason: 'a degraded session still watches the repo in front of you',
      );
    });

    test('arms past the ceiling degrade to polling with a diagnostic', () {
      fakeAsync((async) {
        final exec = _MultiArmExecutor();
        final diagnostics = <String>[];
        final service = RemoteWatchService(
          exec,
          onDiagnostic: diagnostics.add,
          admission: WatchAdmission(budget: HostWatcherBudget()),
          gitDirOf: conventionalGitDir,
        );
        // The cap is derived per service since MADR 0041 phase 4, so read it
        // from the service under test rather than from a static.
        final cap = service.maxConcurrentWatchers;

        final subs = <StreamSubscription<RepoWatchEvent>>[];
        final modes = <int, List<WatchMode>>{};
        for (var i = 0; i <= cap; i++) {
          modes[i] = [];
          subs.add(
            service
                .watch('/r$i', pollInterval: const Duration(milliseconds: 50))
                .listen((e) => modes[i]!.add(e.mode)),
          );
        }
        async.elapse(const Duration(milliseconds: 900));

        // The arms within the ceiling are live; the one past it polls, and says
        // why — the failure mode that produced 19 orphans was accumulating in
        // silence instead.
        expect(
          modes[cap],
          contains(WatchMode.polling),
          reason: 'the arm past the ceiling must degrade, not accumulate',
        );
        expect(diagnostics.join(' '), contains('ceiling reached'));
        expect(exec.handles.length, cap);

        for (final sub in subs) {
          sub.cancel();
        }
        async.flushMicrotasks();
      });
    });
  });

  test('the arm actually uses a leased, self-terminating script (0025 C1)', () {
    fakeAsync((async) {
      // Pins the WIRING, not the builder. The builder supported a lease for a
      // while before the arm passed one — a silent no-op that every script-level
      // test still passed. This is the assertion that would have caught it.
      final handle = FakeWatcherHandle.armed();
      final executor = _DrivableExecutor(tool: 'inotifywait', handle: handle);
      final service = RemoteWatchService(
        executor,
        admission: WatchAdmission(budget: HostWatcherBudget()),
        gitDirOf: conventionalGitDir,
      );

      final sub = service.watch('/repo').listen((_) {});
      _untilStreamOpened(async, executor);
      async.letArmsSettle();

      final script = executor.lastStreamArgs.last;
      // Tokenised per watcher instance since 0027 — the invariant is that the
      // arm records a pid and checks a heartbeat, not that they sit at a fixed
      // per-repo path. A shared path is what let a live successor hold a dead
      // predecessor's lease open.
      expect(
        script,
        matches(RegExp(r'mg-watch\.[\w]+\.pid')),
        reason: 'records its pid, under this instance token',
      );
      expect(
        script,
        matches(RegExp(r'mg-watch\.[\w]+\.hb')),
        reason: 'checks its own heartbeat, not the repo-wide one',
      );
      // Was `contains('-t ')` — "bounded wait, not blocking". MADR 0041
      // removed that lever: `-t` bounded the residue at ~6 minutes and paid a
      // full recursive re-walk per wake, and the loop it woke signalled the
      // wrong pid. What bounds the watcher now is the client's own stdin, read
      // from a SAVED descriptor because POSIX hands an asynchronous list
      // /dev/null (0041 F11).
      expect(
        script,
        isNot(contains('-t ')),
        reason: 'the watch is kept, not re-walked',
      );
      expect(
        script,
        contains('exec 3<&0'),
        reason: 'the channel stdin is saved',
      );
      expect(script, contains('cat <&3'), reason: 'and the watchdog reads it');
      expect(script, contains('trap'), reason: 'owns its child on signal');
      sub.cancel();
      async.flushMicrotasks();
    });
  });
}
