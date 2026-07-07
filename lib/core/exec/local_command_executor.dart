import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../ssh/command_formatter.dart';
import '../ssh/ssh_command_executor.dart';

/// [CommandExecutor] backed directly by [Process.start] instead of an SSH
/// channel — for a repo living on this machine's own filesystem. No shell
/// string is ever built: `Process.start` takes argv/cwd/env natively, so
/// [CommandFormatter]/`ShellEscaper` (which exist purely to serialize a
/// command safely into a remote shell string) are entirely unused here. There
/// is also no reconnect/generation concept: a locally-spawned process has no
/// persistent session to go stale, so (unlike [SSHCommandExecutor]) this class
/// never throws [SSHCommandSuperseded].
class LocalCommandExecutor implements CommandExecutor {
  /// Tail of the serialization chain — mirrors [SSHCommandExecutor]'s: no two
  /// commands against the same repo ever overlap, protecting `.git/index.lock`
  /// regardless of transport.
  Future<void> _tail = Future.value();

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

  @override
  void configureEnvironment({
    String? path,
    Map<String, String> binaries = const {},
  }) {
    _envPath = (path != null && path.isNotEmpty) ? path : null;
    _binaryPaths = binaries;
  }

  @override
  void resetEnvironment() {
    _envPath = null;
    _binaryPaths = const {};
  }

  Map<String, String> _mergedEnv(Map<String, String>? extraEnv) => {
    ...CommandFormatter.defaultEnv,
    // Neutralize ambient glab-auth env vars inherited from the launching shell
    // (Process.start defaults includeParentEnvironment: true) — the local
    // equivalent of the SSH path's `unset` prelude. Placed before extraEnv so a
    // caller that legitimately supplies a token still overrides.
    ...CommandFormatter.neutralizedGlabTokens,
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
  }) {
    // Each attempt is enqueued separately so the inter-retry backoff wait
    // (taken inside runWithRetries, between enqueues) doesn't head-of-line-block
    // other queued commands — mirrors SSHCommandExecutor.execute.
    return SSHCommandExecutor.runWithRetries(
      () => _run(repoPath, gitArgs, extraEnv, stdin, timeout),
      retries,
      enqueue: _enqueue,
    );
  }

  /// Links [attempt] onto the tail of the serialization chain and advances the
  /// tail, swallowing errors on the tail so one failure never wedges the queue —
  /// mirrors [SSHCommandExecutor]'s `_enqueue`.
  Future<SSHCommandResult> _enqueue(
    Future<SSHCommandResult> Function() attempt,
  ) {
    final result = _tail.then((_) => attempt());
    _tail = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<SSHCommandResult> _run(
    String repoPath,
    List<String> gitArgs,
    Map<String, String>? extraEnv,
    String? stdin,
    Duration timeout,
  ) async {
    final argv = _rewriteArgv(gitArgs);

    // Assigned as soon as the process spawns, so a timeout firing during
    // drain can still reach it for cleanup below.
    Process? process;

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
        return SSHCommandResult(exitCode: 127, stdout: '', stderr: e.message);
      }
      final p = process!;

      // Always close stdin (whether or not anything was written) rather than
      // only when [stdin] is non-null: unlike an SSH channel, a local pipe
      // left open indefinitely can make a command that unexpectedly reads
      // stdin (or a future call site that forgets `GIT_TERMINAL_PROMPT=0`
      // covers every case) hang forever rather than surfacing a fast, clear
      // failure.
      if (stdin != null) {
        p.stdin.write(stdin);
      }
      await p.stdin.close();

      // `allowMalformed: true` so non-UTF-8 bytes (binary content, non-UTF-8
      // filenames/authors) are replaced rather than throwing. Each stream is
      // bounded by [SSHCommandExecutor.collectBounded] so an unexpectedly
      // enormous output aborts with [SSHOutputExceeded] instead of buffering
      // unbounded toward an OOM — the same reasoning applies locally as over
      // SSH, since a huge diff/log/`cat` is just as capable of ballooning
      // memory regardless of transport.
      final label = gitArgs.join(' ');
      final stdoutFuture = SSHCommandExecutor.collectBounded(
        p.stdout.transform(const Utf8Decoder(allowMalformed: true)),
        label,
      );
      final stderrFuture = SSHCommandExecutor.collectBounded(
        p.stderr.transform(const Utf8Decoder(allowMalformed: true)),
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
      return SSHCommandResult(
        exitCode: exitCode,
        stdout: drained[0],
        stderr: drained[1],
      );
    }

    final attempt = spawnAndDrain();
    try {
      return await attempt.timeout(timeout);
    } on TimeoutException {
      process?.kill();
      // If spawn/drain eventually does settle in the background, make sure
      // whatever process it produced gets terminated too, instead of leaving
      // it running unattended — mirrors SSHCommandExecutor's post-timeout
      // cleanup.
      unawaited(
        attempt.then((_) {}, onError: (_) {}).whenComplete(() {
          process?.kill();
        }),
      );
      throw SSHCommandTimeout(gitArgs.join(' '));
    } finally {
      // Harmless no-op on the success path (the process has already exited
      // by the time `exitCode` resolves) — guards the case where draining
      // itself threw for some other reason, leaving the process running.
      process?.kill();
    }
  }

  @override
  Future<SSHStreamHandle> executeStream({
    required String repoPath,
    required List<String> gitArgs,
    Map<String, String>? extraEnv,
    Duration openTimeout = SSHCommandExecutor.defaultTimeout,
  }) async {
    final argv = _rewriteArgv(gitArgs);
    final attempt = Process.start(
      argv.first,
      argv.skip(1).toList(),
      workingDirectory: repoPath,
      environment: _mergedEnv(extraEnv),
    );
    try {
      final process = await attempt.timeout(openTimeout);
      return _ProcessStreamHandle(process);
    } on TimeoutException {
      unawaited(attempt.then((p) => p.kill(), onError: (_) {}));
      throw SSHCommandTimeout(gitArgs.join(' '));
    }
  }
}

/// [SSHStreamHandle] backed by a live local [Process].
class _ProcessStreamHandle implements SSHStreamHandle {
  final Process _process;

  _ProcessStreamHandle(this._process);

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
    _process.kill(ProcessSignal.sigterm);
  }
}
