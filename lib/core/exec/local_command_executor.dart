import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import '../ssh/command_formatter.dart';
import '../ssh/ssh_command_executor.dart';
import 'activity_deadline.dart';
import 'command_lanes.dart';
import 'command_telemetry.dart';
import 'operation_activity.dart';

/// [CommandExecutor] backed directly by [Process.start] instead of an SSH
/// channel — for a repo living on this machine's own filesystem. No shell
/// string is ever built: `Process.start` takes argv/cwd/env natively, so
/// [CommandFormatter]/`ShellEscaper` (which exist purely to serialize a
/// command safely into a remote shell string) are entirely unused here. There
/// is also no reconnect/generation concept: a locally-spawned process has no
/// persistent session to go stale, so (unlike [SSHCommandExecutor]) this class
/// never throws [SSHCommandSuperseded].
class LocalCommandExecutor implements CommandExecutor {
  /// Lane-aware scheduler — mirrors [SSHCommandExecutor]'s: reads overlap,
  /// mutations run strictly alone, protecting `.git/index.lock` regardless of
  /// transport. See [ExecLane] / [CommandLaneScheduler].
  final CommandLaneScheduler _scheduler = CommandLaneScheduler();

  /// Augmented local `$PATH` (from [EnvironmentResolver], reused as-is for the
  /// local backend since a Finder-launched GUI app's inherited PATH is often
  /// as bare as an SSH exec channel's — e.g. missing a Homebrew `/opt/homebrew/
  /// bin`). Null until [configureEnvironment] is called.
  String? _envPath;

  /// Bare tool name → resolved absolute path; when a command's `argv[0]`
  /// matches, the exact binary is used — same idea as
  /// [CommandFormatter]'s rewrite, just applied directly to argv with no
  /// shell-string involved.
  Map<String, String> _binaryPaths = const {};

  /// Ambient forge-token env vars to neutralize (see
  /// [CommandExecutor.setForgeTokenNeutralization]). Empty by default.
  List<String> _neutralizeTokens = const [];

  /// Whether an environment probe has configured this executor (augmented
  /// PATH and/or binary rewrites). False after [resetEnvironment] — used to
  /// decide whether an on-demand probe is needed before This-Mac work that
  /// runs outside any local session.
  bool get isConfigured => _envPath != null || _binaryPaths.isNotEmpty;

  @override
  void configureEnvironment({
    String? path,
    Map<String, String> binaries = const {},
  }) {
    _envPath = (path != null && path.isNotEmpty) ? path : null;
    _binaryPaths = binaries;
  }

  @override
  String? resolvedBinaryPath(String name) => _binaryPaths[name];

  @override
  void setForgeTokenNeutralization(Iterable<String> vars) {
    _neutralizeTokens = List.unmodifiable(vars);
  }

  @override
  void resetEnvironment() {
    _envPath = null;
    _binaryPaths = const {};
    _neutralizeTokens = const [];
  }

  /// Writes [bytes] to [remotePath] on this machine's own filesystem — the
  /// local-backend equivalent of the SSH SFTP upload.
  @override
  Future<void> uploadBytes(
    String remotePath,
    Uint8List bytes, {
    String? routingRepo,
  }) async {
    await File(remotePath).writeAsBytes(bytes);
  }

  Map<String, String> _mergedEnv(Map<String, String>? extraEnv) => {
    ...CommandFormatter.defaultEnv,
    // Neutralize the ambient forge-auth env vars this connection opted into
    // (empty values — both CLIs treat that as unset) — the local equivalent of
    // the SSH path's `unset` prelude. Only the forges whose token this
    // connection supplied are here (see setForgeTokenNeutralization); placed
    // before extraEnv so a caller that legitimately supplies a token overrides.
    for (final v in _neutralizeTokens) v: '',
    'PATH': ?_envPath,
    ...?extraEnv,
  };

  List<String> _rewriteArgv(List<String> gitArgs) {
    if (gitArgs.isEmpty) return gitArgs;
    final override = _binaryPaths[gitArgs.first];
    if (override == null) return gitArgs;
    return [override, ...gitArgs.skip(1)];
  }

  @override
  Future<SSHCommandResult> execute({
    required String repoPath,
    required List<String> gitArgs,
    Map<String, String>? extraEnv,
    String? stdin,
    Duration timeout = SSHCommandExecutor.defaultTimeout,
    int retries = 0,
    ExecLane lane = ExecLane.exclusive,
    // Ignored: compression exists to save SSH wire bytes; a local pipe has no
    // wire, so spending CPU gzipping/gunzipping it would be pure loss.
    bool compress = false,
    Duration? activityIdle,
    OperationDescriptor? operation,
    OperationEventCallback? onOperationEvent,
  }) async {
    final lifecycle = OperationLifecycleEmitter.begin(
      operation,
      onOperationEvent,
    );
    // Each attempt is enqueued separately so the inter-retry backoff wait
    // (taken inside runWithRetries, between enqueues) doesn't head-of-line-block
    // other queued commands — mirrors SSHCommandExecutor.execute.
    try {
      final result = await SSHCommandExecutor.runWithRetries(
        () => _run(
          repoPath,
          gitArgs,
          extraEnv,
          stdin,
          timeout,
          lane,
          activityIdle,
        ),
        retries,
        // See SSHCommandExecutor.execute: the deadline is the attempt's own
        // timeout plus a margin, a backstop against a body that never settles and
        // so never gives its lane slot back.
        enqueue: (attempt) => _scheduler.run(
          lane,
          attempt,
          deadline: timeout + CommandLaneScheduler.watchdogMargin,
          onStarted: lifecycle?.started,
        ),
      );
      if (result.isSuccess) {
        lifecycle?.succeeded();
      } else {
        lifecycle?.failed('Exited with code ${result.exitCode}');
      }
      return result.withOperationId(lifecycle?.id);
    } catch (_) {
      lifecycle?.failed();
      rethrow;
    }
  }

  Future<SSHCommandResult> _run(
    String repoPath,
    List<String> gitArgs,
    Map<String, String>? extraEnv,
    String? stdin,
    Duration timeout,
    ExecLane lane,
    Duration? activityIdle,
  ) async {
    final sw = Stopwatch()..start();
    final argv = _rewriteArgv(gitArgs);

    // Assigned as soon as the process spawns, so a timeout firing during
    // drain can still reach it for cleanup below.
    Process? process;
    // Hoisted out of spawnAndDrain so the failure paths below can record what
    // the command consumed before it died — mirrors SSHCommandExecutor._run.
    final budget = OutputByteBudget();
    void recordFailureSample() {
      CommandTelemetry.instance.record(
        CommandSample(
          lane: lane,
          duration: sw.elapsed,
          bytes: budget.used,
          // No wire on a local pipe — buffered and "wire" size coincide.
          wireBytes: budget.used,
          compressed: false,
          success: false,
        ),
      );
    }

    // Set when the timeout fires. Checked right after the spawn resolves: a
    // timeout that fired while `Process.start` was still pending found a null
    // process with nothing to kill, and the command would otherwise run on
    // unattended — for one that never exits, forever. Mirrors
    // SSHCommandExecutor._run's flag.
    var timedOut = false;
    final deadline = activityIdle == null
        ? null
        : ActivityDeadline(idle: activityIdle, ceiling: timeout);

    Future<SSHCommandResult> spawnAndDrain() async {
      try {
        process = await Process.start(
          argv.first,
          argv.skip(1).toList(),
          workingDirectory: repoPath,
          environment: _mergedEnv(extraEnv),
        );
      } on ProcessException catch (e) {
        // The binary isn't on PATH, or `repoPath` doesn't exist / isn't
        // accessible. Over SSH the same failure comes back as a non-zero exit
        // (a missing binary is 127, a missing dir is `cd` failing), so map it
        // to the same shape here: a clean result callers convert to a
        // `GitException`, rather than a raw `ProcessException` that no caller
        // catches — and that `runWithRetries` would otherwise pointlessly retry
        // (the failure is deterministic).
        //
        // The two causes are indistinguishable from the exception alone (both
        // surface as ENOENT), but 127 specifically means "command not found" —
        // GitService turns it into "install git / set its path in Settings",
        // which is actively misleading when the real problem is that the
        // repository folder was moved, deleted, or made unreadable. Check the
        // working directory to pick the honest exit shape, mirroring SSH's
        // `cd` failure (non-127, "not a git repository").
        if (!Directory(repoPath).existsSync()) {
          return SSHCommandResult(
            exitCode: 1,
            stdout: '',
            stderr:
                'cannot access repository folder: $repoPath — it may have '
                'been moved, deleted, or had its permissions changed. '
                '(${e.message})',
          );
        }
        return SSHCommandResult(exitCode: 127, stdout: '', stderr: e.message);
      }
      final p = process!;
      if (timedOut) {
        _killEscalate(p);
        throw SSHCommandTimeout(gitArgs.join(' '));
      }

      // Always close stdin (whether or not anything was written) rather than
      // only when [stdin] is non-null: a local pipe left open indefinitely
      // can make a command that unexpectedly reads stdin (or a future call
      // site that forgets `GIT_TERMINAL_PROMPT=0` covers every case) hang
      // forever rather than surfacing a fast, clear failure.
      // Pipe errors are swallowed deliberately: a child that exits before
      // consuming stdin (a fast-failing `--stdin` command) surfaces EPIPE as
      // a SocketException from close() — which would replace the process's
      // real exit code + stderr with a thrown error that retry classification
      // even treats as transient. The exit code is the story; let it speak.
      try {
        if (stdin != null) {
          p.stdin.write(stdin);
        }
        await p.stdin.close();
      } catch (_) {}

      // `allowMalformed: true` so non-UTF-8 bytes (binary content, non-UTF-8
      // filenames/authors) are replaced rather than throwing. A single
      // [OutputByteBudget] charges the raw bytes of stdout+stderr *before*
      // decoding, so an unexpectedly enormous output aborts with
      // [SSHOutputExceeded] — bounded by real byte size (combined across both
      // streams) instead of buffering unbounded toward an OOM. The same
      // reasoning applies locally as over SSH: a huge diff/log/`cat` is just as
      // capable of ballooning memory regardless of transport.
      final label = gitArgs.join(' ');
      final stdoutFuture = collectBounded(
        boundedBytes(
          p.stdout.map((chunk) {
            deadline?.pulse();
            return chunk;
          }),
          budget,
          label,
        ).transform(const Utf8Decoder(allowMalformed: true)),
        label,
      );
      final stderrFuture = collectBounded(
        boundedBytes(
          p.stderr.map((chunk) {
            deadline?.pulse();
            return chunk;
          }),
          budget,
          label,
        ).transform(const Utf8Decoder(allowMalformed: true)),
        label,
      );

      // eagerError: mirrors SSHCommandExecutor's reasoning — fail promptly the
      // moment either stream crosses the cap rather than waiting on the other
      // one too.
      final drained = await Future.wait([
        stdoutFuture,
        stderrFuture,
      ], eagerError: true);
      final exitCode = await p.exitCode;
      CommandTelemetry.instance.record(
        CommandSample(
          lane: lane,
          duration: sw.elapsed,
          bytes: budget.used,
          // No wire on a local pipe — buffered and "wire" size coincide.
          wireBytes: budget.used,
          compressed: false,
          success: exitCode == 0,
        ),
      );
      return SSHCommandResult(
        exitCode: exitCode,
        stdout: drained[0],
        stderr: drained[1],
      );
    }

    final attempt = spawnAndDrain();
    try {
      if (deadline != null) return await deadline.wait(attempt);
      return await attempt.timeout(timeout);
    } on TimeoutException {
      // If the spawn itself was the slow part, `process` is still null here —
      // the flag makes spawnAndDrain kill it the moment the spawn resolves.
      // (A cleanup keyed on `attempt` settling would not do: a never-exiting
      // command never settles it.) Mirrors SSHCommandExecutor._run.
      timedOut = true;
      _killEscalate(process);
      recordFailureSample();
      throw SSHCommandTimeout(gitArgs.join(' '));
    } catch (_) {
      // Any other drain failure — canonically SSHOutputExceeded from the
      // byte budget. Record what it consumed; the dashboard must see failed
      // commands, not just successes. (The `finally` below still kills.)
      recordFailureSample();
      rethrow;
    } finally {
      // Harmless no-op on the success path (the process has already exited
      // by the time `exitCode` resolves) — guards the case where draining
      // itself threw for some other reason, leaving the process running.
      // Use plain kill here (not escalate): the process has usually already
      // exited; escalate is reserved for the timeout path above.
      process?.kill();
    }
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
    final lifecycle = OperationLifecycleEmitter.begin(
      operation,
      onOperationEvent,
    );
    lifecycle?.started();
    final argv = _rewriteArgv(gitArgs);
    final attempt = Process.start(
      argv.first,
      argv.skip(1).toList(),
      workingDirectory: repoPath,
      environment: _mergedEnv(extraEnv),
    );
    try {
      final process = await attempt.timeout(openTimeout);
      return _LocalActivityStreamHandle(
        _ProcessStreamHandle(process),
        lifecycle,
      );
    } on TimeoutException {
      unawaited(
        attempt.then((p) {
          _killEscalate(p);
        }, onError: (_) {}),
      );
      throw SSHCommandTimeout(gitArgs.join(' '));
    } catch (_) {
      lifecycle?.failed();
      rethrow;
    }
  }
}

class _LocalActivityStreamHandle implements CommandStreamHandle {
  _LocalActivityStreamHandle(this._inner, this._lifecycle) {
    unawaited(
      _inner.exitCode.then((code) {
        if (code == 0) {
          _lifecycle?.succeeded();
        } else {
          _lifecycle?.failed(
            code == null ? 'Stream ended' : 'Exited with code $code',
          );
        }
      }, onError: (_) => _lifecycle?.failed()),
    );
  }

  final CommandStreamHandle _inner;
  final OperationLifecycleEmitter? _lifecycle;

  @override
  Stream<String> get stdout => _inner.stdout;

  @override
  Stream<String> get stderr => _inner.stderr;

  @override
  Future<int?> get exitCode => _inner.exitCode;

  @override
  Future<void> cancel() async {
    _lifecycle?.canceled();
    await _inner.cancel();
  }
}

/// [CommandStreamHandle] backed by a live local [Process].
class _ProcessStreamHandle implements SSHStreamHandle {
  final Process _process;
  late final int _telemetryEpoch;
  bool _closed = false;

  _ProcessStreamHandle(this._process) {
    // Mirror _SshSessionStreamHandle: the dashboard's open/peak-stream
    // counters describe streams on *any* transport, so a local session's
    // watcher must count too. Natural process exit closes the same as cancel.
    _telemetryEpoch = CommandTelemetry.instance.streamOpened();
    unawaited(
      _process.exitCode.then((_) {}, onError: (_) {}).whenComplete(_noteClosed),
    );
  }

  void _noteClosed() {
    if (_closed) return;
    _closed = true;
    CommandTelemetry.instance.streamClosed(_telemetryEpoch);
  }

  @override
  late final Stream<String> stdout = _process.stdout.transform(
    const Utf8Decoder(allowMalformed: true),
  );
  @override
  late final Stream<String> stderr = _process.stderr.transform(
    const Utf8Decoder(allowMalformed: true),
  );

  @override
  Future<int?> get exitCode => _process.exitCode;

  @override
  Future<void> cancel() async {
    _killEscalate(_process);
    _noteClosed();
  }
}

/// TERM immediately, then KILL after [SSHCommandExecutor.killGrace] so a
/// process that ignores TERM cannot run unattended after the client has
/// given up. Mirrors the SSH path's escalation.
void _killEscalate(Process? process) {
  if (process == null) return;
  try {
    process.kill(ProcessSignal.sigterm);
  } catch (_) {}
  unawaited(
    Future<void>.delayed(SSHCommandExecutor.killGrace, () {
      try {
        process.kill(ProcessSignal.sigkill);
      } catch (_) {}
    }),
  );
}
