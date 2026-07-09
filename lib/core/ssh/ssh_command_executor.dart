import 'dart:async';
import 'dart:convert';
import 'dart:io' show gzip;
import 'dart:typed_data';
import 'package:dartssh2/dartssh2.dart';
import '../exec/command_lanes.dart';
import 'command_formatter.dart';
import 'ssh_client_manager.dart';

export '../exec/command_lanes.dart' show ExecLane;

class SSHCommandResult {
  final int exitCode;
  final String stdout;
  final String stderr;

  const SSHCommandResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  bool get isSuccess => exitCode == 0;
}

/// Thrown when a request/response command exceeds its timeout. Distinct from a
/// non-zero exit so the UI can surface "timed out" rather than hanging forever.
class SSHCommandTimeout implements Exception {
  final String command;
  const SSHCommandTimeout(this.command);

  @override
  String toString() => 'SSH command timed out: $command';
}

/// Thrown when a queued command's turn arrives after the connection it was
/// issued for has been superseded — a reconnect or a fresh `connect()` to a
/// different host happened while this command was still waiting in the
/// serialized queue. Refusing to run prevents it from silently executing
/// against the wrong host/session. Never retried (see [SSHCommandExecutor.
/// runWithRetries]) — the caller must re-issue the command against the
/// current connection, not blindly retry against a connection that no longer
/// exists.
class SSHCommandSuperseded implements Exception {
  final String command;
  const SSHCommandSuperseded(this.command);

  @override
  String toString() =>
      'SSH command superseded by a new connection before it could run: $command';
}

/// Thrown when a request/response command's stdout (or stderr) grows past
/// [SSHCommandExecutor.maxCommandOutputChars]. A request/response command
/// buffers its whole output in memory as one String; this surfaces a clear
/// failure the callers already handle (like a non-zero exit) instead of letting
/// a pathological huge diff/log/`cat` balloon memory toward an OOM. Never
/// retried (see [SSHCommandExecutor.runWithRetries]) — a retry would just
/// reproduce the same oversized output.
class SSHOutputExceeded implements Exception {
  final String command;
  const SSHOutputExceeded(this.command);

  @override
  String toString() =>
      'SSH command output exceeded the maximum buffer size: $command';
}

/// A mutable byte budget shared across one command's stdout and stderr, so their
/// *combined* buffered output — not each stream independently — is what the cap
/// bounds. [charge] is called per raw byte chunk before decoding; the first
/// charge that pushes the running total over [limit] throws [SSHOutputExceeded].
/// Single-threaded by construction (both streams drain on the same isolate), so
/// the shared counter needs no synchronization.
class OutputByteBudget {
  OutputByteBudget([this.limit = SSHCommandExecutor.maxCommandOutputBytes]);

  final int limit;
  int _used = 0;

  /// Total bytes charged so far — for tests/diagnostics.
  int get used => _used;

  void charge(int bytes, String command) {
    _used += bytes;
    if (_used > limit) throw SSHOutputExceeded(command);
  }
}

/// A live handle to a long-running command (e.g. `fswatch`, a CI job trace,
/// or `git log --follow`) whose output is consumed incrementally.
///
/// Unlike [CommandExecutor.execute], a streaming command is *not* placed on
/// the serialization queue — it never returns, so queuing it would wedge every
/// subsequent command. Abstract so both the SSH backend ([SSHCommandExecutor],
/// via a live [SSHSession]) and the local backend (`LocalCommandExecutor`, via
/// a live `Process`) can hand callers ([GlabService.traceStream],
/// `RemoteWatchService`/`LocalWatchService`) the same shape regardless of
/// transport.
abstract class SSHStreamHandle {
  /// UTF-8 decoded output. `allowMalformed: true` so a non-UTF-8 byte (binary
  /// content, blob output) is replaced rather than throwing and killing the
  /// stream.
  Stream<String> get stdout;
  Stream<String> get stderr;

  /// Resolves once the process has actually exited, with its exit code —
  /// distinct from [stdout]/[stderr] closing, which says nothing about
  /// whether the process itself finished cleanly (a long-lived command like
  /// `glab ci trace` can stream real output for a while and then still die
  /// with a non-zero exit). Null if the process never reported a status (e.g.
  /// killed by a signal, or an implementation that doesn't report one).
  Future<int?> get exitCode;

  /// Terminates the process and tears down the channel. Safe to call more
  /// than once.
  Future<void> cancel();
}

/// [SSHStreamHandle] backed by a live [SSHSession]. dartssh2 multiplexes it
/// onto its own channel with an independent flow-control window, so it
/// coexists with request/response commands without blocking them.
class _SshSessionStreamHandle implements SSHStreamHandle {
  final SSHSession _session;

  _SshSessionStreamHandle(this._session);

  /// The stream transform carries decoder state across chunk boundaries, so
  /// multi-byte sequences split across packets decode correctly.
  @override
  late final Stream<String> stdout = _session.stdout
      .cast<List<int>>()
      .transform(const Utf8Decoder(allowMalformed: true));
  @override
  late final Stream<String> stderr = _session.stderr
      .cast<List<int>>()
      .transform(const Utf8Decoder(allowMalformed: true));

  /// Backed by [SSHSession.waitForExit], which is safe to await more than
  /// once.
  @override
  Future<int?> get exitCode => _session.waitForExit();

  @override
  Future<void> cancel() async {
    try {
      _session.kill(SSHSignal.TERM);
    } catch (_) {
      // Session may already be gone; closing below is still correct.
    }
    _session.close();
  }
}

/// Executes git/glab commands against a repo — either over SSH
/// ([SSHCommandExecutor]) or directly on the local filesystem
/// (`LocalCommandExecutor`, in `lib/core/exec/local_command_executor.dart`).
/// `GitService`/`GlabService`/`RemoteWatchService` depend on this interface,
/// not a concrete transport, so they work unchanged against either backend.
abstract class CommandExecutor {
  /// Runs [gitArgs] against [repoPath]. Implementations schedule commands by
  /// [lane] (see [ExecLane]): reads overlap each other and remote-sync
  /// commands, while mutations run strictly alone (protecting
  /// `.git/index.lock`). The default lane is [ExecLane.exclusive] — the safe
  /// choice for any call site that doesn't declare otherwise. See
  /// [SSHCommandExecutor.execute] for the full contract.
  ///
  /// [compress], for a read whose output is large and text-like (diffs, logs,
  /// file contents), asks the transport to compress stdout on the wire. The
  /// SSH backend honors it when the host has `gzip` (see
  /// [CommandFormatter.format]'s `compressOutput`); the local backend ignores
  /// it — there is no wire to save.
  Future<SSHCommandResult> execute({
    required String repoPath,
    required List<String> gitArgs,
    Map<String, String>? extraEnv,
    String? stdin,
    Duration timeout = SSHCommandExecutor.defaultTimeout,
    int retries = 0,
    ExecLane lane = ExecLane.exclusive,
    bool compress = false,
  });

  /// Starts a long-running command and returns a live handle for incremental
  /// consumption. Bypasses the serialization queue — see
  /// [SSHCommandExecutor.executeStream].
  Future<SSHStreamHandle> executeStream({
    required String repoPath,
    required List<String> gitArgs,
    Map<String, String>? extraEnv,
    Duration openTimeout = SSHCommandExecutor.defaultTimeout,
  });

  /// Uploads [bytes] to [remotePath] on the host: the SSH backend streams over
  /// SFTP, the local backend writes to the filesystem. Used by guided install's
  /// file sideload (an air-gapped host that can't download for itself). Throws
  /// on failure.
  Future<void> uploadBytes(String remotePath, Uint8List bytes);

  /// Applies a resolved environment (augmented PATH + resolved binary
  /// locations) so commands find user-installed tools. See
  /// [SSHCommandExecutor.configureEnvironment].
  void configureEnvironment({String? path, Map<String, String> binaries});

  /// Sets the ambient env var names to neutralize before every command (a
  /// forge's token vars — [CommandFormatter.gitlabTokenVars]/[githubTokenVars] —
  /// when this connection supplied that forge's token, so Magic Git's managed
  /// identity wins over any ambient token). Empty leaves the remote's own
  /// `gh`/`glab` auth untouched. Cleared by [resetEnvironment].
  void setForgeTokenNeutralization(Iterable<String> vars);

  /// Forgets any resolved environment. See
  /// [SSHCommandExecutor.resetEnvironment].
  void resetEnvironment();
}

class SSHCommandExecutor implements CommandExecutor {
  final SSHClientManager _clientManager;

  /// Default request/response timeout. Generous, because commit (which invokes a
  /// possibly-slow prepare-commit-msg hook) and remote-sync ops cross a network;
  /// callers can override per command.
  static const Duration defaultTimeout = Duration(seconds: 60);

  /// Post-decode backstop on the number of decoded characters a single
  /// request/response stream may accumulate. The *primary* ceiling is now
  /// [maxCommandOutputBytes], charged on raw bytes before decoding and shared
  /// across stdout+stderr (see [OutputByteBudget]); since UTF-8 bytes ≥ code
  /// units, the byte budget trips first for any content, so this char cap only
  /// backs it up. Such commands buffer their entire output in memory as one
  /// String, so without a bound a huge diff/log/`cat` of a big blob could spike
  /// memory. The streaming path ([executeStream] / [SSHStreamHandle]) is exempt:
  /// it hands callers the raw stream and never materializes it here.
  static const int maxCommandOutputChars = 50 * 1024 * 1024;

  /// Lane-aware scheduler: reads run concurrently (and alongside a fetch/push
  /// on the sync lane), mutations run strictly alone — see [ExecLane] /
  /// [CommandLaneScheduler]. Replaces the old single serialized chain, which
  /// let one slow network op head-of-line-block every read in the app.
  final CommandLaneScheduler _scheduler = CommandLaneScheduler();

  /// Augmented remote `$PATH` (discovered at connect), exported before every
  /// command so user-installed tools resolve on the minimal exec-channel PATH.
  /// Null until [configureEnvironment] is called.
  String? _envPath;

  /// Bare tool name → resolved absolute path; when a command's `argv[0]` matches,
  /// the exact binary is used (see [CommandFormatter.format]).
  Map<String, String> _binaryPaths = const {};

  /// Ambient env vars to `unset` before every command (see
  /// [CommandExecutor.setForgeTokenNeutralization]). Empty by default.
  List<String> _neutralizeTokens = const [];

  SSHCommandExecutor(this._clientManager);

  /// Applies the per-connection resolved environment (see [EnvironmentResolver]):
  /// an augmented [path] and a [binaries] map. Cleared with [resetEnvironment].
  @override
  void configureEnvironment({
    String? path,
    Map<String, String> binaries = const {},
  }) {
    _envPath = (path != null && path.isNotEmpty) ? path : null;
    _binaryPaths = binaries;
  }

  @override
  void setForgeTokenNeutralization(Iterable<String> vars) {
    _neutralizeTokens = List.unmodifiable(vars);
  }

  /// Forgets any resolved environment (on disconnect), reverting to bare-name
  /// invocation against the inherited PATH.
  @override
  void resetEnvironment() {
    _envPath = null;
    _binaryPaths = const {};
    _neutralizeTokens = const [];
  }

  /// Streams [bytes] to [remotePath] over SFTP on the active session. Not on the
  /// serialized command queue — it's a distinct SFTP channel, so it coexists
  /// with in-flight git commands.
  @override
  Future<void> uploadBytes(String remotePath, Uint8List bytes) async {
    final client = _clientManager.client;
    if (client == null) {
      throw StateError('cannot upload: no active SSH connection');
    }
    final sftp = await client.sftp();
    final file = await sftp.open(
      remotePath,
      mode:
          SftpFileOpenMode.create |
          SftpFileOpenMode.write |
          SftpFileOpenMode.truncate,
    );
    try {
      await file.write(Stream<Uint8List>.value(bytes)).done;
    } finally {
      await file.close();
    }
  }

  /// Executes a command over the active SSH session.
  ///
  /// [gitArgs] is the argument vector (e.g. `['git', 'status', '-z']`); every
  /// element is escaped by [CommandFormatter]. [stdin], if given, is written to
  /// the process's standard input and then closed (used to pipe a secret without
  /// it appearing in argv). [timeout] bounds how long the command may run before
  /// it is killed and [SSHCommandTimeout] is thrown — so one stuck command can
  /// never wedge the serialized queue for the app's lifetime.
  ///
  /// Commands are scheduled by [lane] (see [ExecLane]): reads run concurrently
  /// with each other and with a fetch/push, while an exclusive mutation waits
  /// for everything in flight and then runs strictly alone — the same
  /// `.git/index.lock` protection the old fully-serialized queue provided,
  /// without letting one slow network op block every read in the app.
  /// [retries] permits automatic re-execution after a *transient* transport
  /// failure (a dropped/not-yet-reconnected session). It is safe only for
  /// idempotent reads — never pass it for a mutation, which could apply twice.
  /// A [SSHCommandTimeout] is never retried (an ambiguous long-running command
  /// may have had an effect), and a non-zero exit is not a throw so it isn't a
  /// retry trigger either. Each *attempt* is a separate enqueue: the inter-try
  /// backoff wait is taken *between* enqueues (see [runWithRetries]), so a
  /// failed read's retry-wait never head-of-line-blocks other queued commands —
  /// the slot is released during the wait and the retry re-enqueues at the back.
  @override
  Future<SSHCommandResult> execute({
    required String repoPath,
    required List<String> gitArgs,
    Map<String, String>? extraEnv,
    String? stdin,
    Duration timeout = defaultTimeout,
    int retries = 0,
    ExecLane lane = ExecLane.exclusive,
    bool compress = false,
  }) {
    // Pin this command to the connection generation active *right now*, at
    // enqueue time — not whatever generation happens to be active once its
    // turn in the scheduler comes up. A reconnect or a fresh connect()
    // to a different host between now and then bumps the generation; without
    // this, `_run` would fetch `_clientManager.client` fresh at run time and
    // silently execute against the new host/session instead of refusing.
    // Captured synchronously here (before the first enqueue) and held across
    // every retry, so a re-enqueued attempt still refuses to run against a
    // newer generation rather than adopting the current one.
    final gen = _clientManager.generation;
    return runWithRetries(
      () => _run(gen, repoPath, gitArgs, extraEnv, stdin, timeout, compress),
      retries,
      enqueue: (attempt) => _scheduler.run(lane, attempt),
    );
  }

  static const Duration _retryBackoff = Duration(milliseconds: 400);

  /// Runs [attempt], retrying up to [retries] times on a *transient* transport
  /// error with [backoff] between tries. An [SSHCommandTimeout] is never retried
  /// (the command is ambiguous — it may already have taken effect), nor is an
  /// [SSHCommandSuperseded] (retrying would just fail again against the same
  /// stale generation — the caller must re-issue against the current
  /// connection). A non-zero exit is returned normally (not thrown), so it
  /// isn't a retry trigger either. Shared by every [CommandExecutor]
  /// implementation (not just tests) — `LocalCommandExecutor` reuses this
  /// directly rather than duplicating retry logic that has no SSH-specific
  /// behavior in its body.
  ///
  /// [enqueue], if given, wraps each individual attempt — it submits the
  /// attempt to the executor's lane scheduler and returns its result. The point
  /// is that the [backoff] `delay` sits *between* two separate [enqueue] calls,
  /// not inside one, so the scheduler slot is released for the duration of the
  /// wait and the retry re-enqueues at the back: a failed command's retry-wait
  /// can never head-of-line-block other commands already queued behind it. When
  /// omitted (tests, or a caller that doesn't schedule), each attempt runs
  /// directly with identical retry semantics.
  static Future<SSHCommandResult> runWithRetries(
    Future<SSHCommandResult> Function() attempt,
    int retries, {
    Duration backoff = _retryBackoff,
    Future<SSHCommandResult> Function(Future<SSHCommandResult> Function())?
    enqueue,
  }) async {
    final run = enqueue ?? (a) => a();
    var n = 0;
    while (true) {
      try {
        return await run(attempt);
      } on SSHCommandTimeout {
        rethrow;
      } on SSHCommandSuperseded {
        rethrow;
      } on SSHOutputExceeded {
        // An oversized output is deterministic — retrying just reproduces it.
        rethrow;
      } catch (_) {
        if (n++ >= retries) rethrow;
        await Future<void>.delayed(backoff);
      }
    }
  }

  /// Accumulates a decoded [chunks] stream into a single String, aborting with
  /// [SSHOutputExceeded] once more than [maxChars] characters have arrived. This
  /// is what bounds a request/response command's in-memory output: the stream
  /// subscription is cancelled the moment the ceiling is crossed (the `await
  /// for` exits on throw), so a runaway command stops being drained promptly
  /// rather than buffering to exhaustion. Shared by every [CommandExecutor]
  /// implementation (not just tests) — this has no SSH-specific behavior,
  /// just `Stream<String> → String` bounding, so `LocalCommandExecutor` reuses
  /// it directly.
  static Future<String> collectBounded(
    Stream<String> chunks,
    String command, {
    int maxChars = maxCommandOutputChars,
  }) async {
    final buffer = StringBuffer();
    var total = 0;
    await for (final chunk in chunks) {
      total += chunk.length;
      if (total > maxChars) {
        throw SSHOutputExceeded(command);
      }
      buffer.write(chunk);
    }
    return buffer.toString();
  }

  /// Primary in-memory output ceiling, counted in **raw bytes** (pre-decode) so
  /// it maps to real wire/disk/memory size regardless of encoding — unlike
  /// [maxCommandOutputChars] (UTF-16 code units), under which CJK-heavy output
  /// could be ~3× this many bytes on the wire yet count as far fewer "chars",
  /// and any non-Latin1 content doubles the resident `String` size. A single
  /// budget is shared across a command's stdout+stderr (see [OutputByteBudget]),
  /// bounding their *combined* size. 50 MiB is far above any status/log/diff this
  /// UI issues; [collectBounded]'s char cap remains as a post-decode backstop.
  static const int maxCommandOutputBytes = 50 * 1024 * 1024;

  /// Passes a raw byte stream through unchanged while charging each chunk's
  /// length against [budget] *before* UTF-8 decoding, aborting with
  /// [SSHOutputExceeded] the moment the budget is exceeded. Inserted ahead of the
  /// decoder in both executors' drain paths so the ceiling is byte-based and a
  /// single [budget] shared between stdout and stderr bounds their combined size.
  static Stream<List<int>> boundedBytes(
    Stream<List<int>> bytes,
    OutputByteBudget budget,
    String command,
  ) async* {
    await for (final chunk in bytes) {
      budget.charge(chunk.length, command);
      yield chunk;
    }
  }

  /// Merges the resolved PATH and [extraEnv] over the formatter's default
  /// prelude (later entries win).
  Map<String, String> _mergedEnv(Map<String, String>? extraEnv) => {
    ...CommandFormatter.defaultEnv,
    'PATH': ?_envPath,
    ...?extraEnv,
  };

  /// Marks the in-band exit trailer a compressed read appends to its stdout —
  /// see [CommandFormatter.format]'s `compressOutput` and [splitExitTrailer].
  static const String _exitMarker = '\u0001EXIT=';

  /// Splits `<stdout><\x01EXIT=<n>\x01>` into `(exitCode, stdout)`. Returns a
  /// null code (and the input unchanged) when no well-formed trailer terminates
  /// [out] — a killed/truncated stream — so the caller can substitute a failure
  /// code rather than trusting a partial read. A stray 0x01 inside real output
  /// can't false-match: the trailer must sit at the very end, digits only.
  static (int?, String) splitExitTrailer(String out) {
    if (!out.endsWith('\u0001')) return (null, out);
    final idx = out.lastIndexOf(_exitMarker);
    if (idx < 0) return (null, out);
    final digits = out.substring(idx + _exitMarker.length, out.length - 1);
    final code = digits.isEmpty ? null : int.tryParse(digits);
    if (code == null || code < 0) return (null, out);
    return (code, out.substring(0, idx));
  }

  Future<SSHCommandResult> _run(
    int gen,
    String repoPath,
    List<String> gitArgs,
    Map<String, String>? extraEnv,
    String? stdin,
    Duration timeout,
    bool compress,
  ) async {
    if (_clientManager.generation != gen) {
      // A reconnect or a fresh connect() to a different host happened while
      // this command was waiting in the scheduler. Refuse to run
      // rather than fetching whatever client is current now.
      throw SSHCommandSuperseded(gitArgs.join(' '));
    }
    final client = _clientManager.client;
    if (client == null) {
      throw Exception('SSH connection not established.');
    }
    if (_clientManager.clientGeneration != gen) {
      // The generation matches but the *attached client* belongs to an older
      // one: a new connect() is mid-handshake (it bumps the generation at its
      // start but swaps the client in only on success). Running now would
      // silently execute against the previous host's still-open session —
      // exactly what generation pinning exists to prevent.
      throw SSHCommandSuperseded(gitArgs.join(' '));
    }

    // Compression is honored only when the probe actually found gzip on the
    // host (configureEnvironment's binaries map) — otherwise the command runs
    // uncompressed exactly as before, so a minimal host degrades gracefully.
    final compressed = compress && _binaryPaths.containsKey('gzip');
    final command = CommandFormatter.format(
      repoPath: repoPath,
      gitArgs: gitArgs,
      env: _mergedEnv(extraEnv),
      binaryPaths: _binaryPaths,
      neutralizeEnv: _neutralizeTokens,
      compressOutput: compressed,
    );

    // The session is assigned as soon as the channel opens, so a timeout that
    // fires later (during drain) can still reach it for cleanup below. A
    // local (not instance) variable — concurrent commands each get their own.
    SSHSession? session;

    Future<SSHCommandResult> openAndDrain() async {
      session = await client.execute(command);
      final s = session!;

      if (stdin != null) {
        s.write(Uint8List.fromList(utf8.encode(stdin)));
        await s.stdin.close();
      }

      // Drain both streams; they close when the process exits.
      // `allowMalformed: true` so non-UTF-8 bytes (binary content, non-UTF-8
      // filenames/authors) are replaced rather than throwing and leaking the
      // session past this function's own error handling. A single
      // [OutputByteBudget] charges the raw bytes of stdout+stderr *before*
      // decoding, so an unexpectedly enormous output aborts with
      // [SSHOutputExceeded] — bounded by real byte size (combined across both
      // streams) instead of buffering unbounded toward an OOM. For a
      // compressed read, stdout is gunzipped *before* the budget so the cap
      // bounds what this process actually buffers (the decompressed size) —
      // the wire saving is the point, but a gzip bomb must not be.
      final label = gitArgs.join(' ');
      final budget = OutputByteBudget();
      final rawStdout = s.stdout.cast<List<int>>();
      final stdoutFuture = collectBounded(
        boundedBytes(
          compressed ? rawStdout.transform(gzip.decoder) : rawStdout,
          budget,
          label,
        ).transform(const Utf8Decoder(allowMalformed: true)),
        label,
      );
      final stderrFuture = collectBounded(
        boundedBytes(
          s.stderr.cast<List<int>>(),
          budget,
          label,
        ).transform(const Utf8Decoder(allowMalformed: true)),
        label,
      );

      // eagerError: as soon as either stream crosses the byte budget,
      // fail this call immediately rather than blocking on the *other*
      // stream too — which, for a remote process whose stdout we just
      // stopped draining, may never close on its own (the process can be
      // stuck blocked on a full SSH flow-control window, so it never exits
      // and its stderr channel never closes either). The outer `finally`
      // below still closes the session either way, unblocking/killing the
      // remote process.
      final drained = await Future.wait([
        stdoutFuture,
        stderrFuture,
      ], eagerError: true);
      final exitCode = await s.waitForExit() ?? -1;
      if (!compressed) {
        return SSHCommandResult(
          exitCode: exitCode,
          stdout: drained[0],
          stderr: drained[1],
        );
      }
      // A compressed read's channel exit code is gzip's, not the command's —
      // the real one rides an in-band trailer at the end of stdout. A missing
      // trailer means the stream was killed/truncated mid-flight: surface the
      // channel's own failure code if it has one, else -1 — never 0, which
      // would present a partial read as a success.
      final (realExit, body) = splitExitTrailer(drained[0]);
      return SSHCommandResult(
        exitCode: realExit ?? (exitCode != 0 ? exitCode : -1),
        stdout: body,
        stderr: drained[1],
      );
    }

    // One timeout budget for the *entire* lifecycle — channel open through
    // exit — not just the drain phase. A stalled channel-open (a dead NAT
    // session with no RST) used to hang forever here, wedging every
    // subsequent command behind it on the serialized queue for the app's
    // lifetime; now it surfaces as SSHCommandTimeout like any other stuck
    // command.
    final attempt = openAndDrain();
    try {
      return await attempt.timeout(timeout);
    } on TimeoutException {
      _killAndClose(session);
      // If the open itself was the slow part, `session` may still be null
      // here. Once `attempt` eventually settles in the background (the
      // channel finally opens, or the command finally exits), make sure
      // whatever session it produced gets terminated too, instead of running
      // on unattended forever.
      unawaited(
        attempt.then((_) {}, onError: (_) {}).whenComplete(() {
          _killAndClose(session);
        }),
      );
      throw SSHCommandTimeout(gitArgs.join(' '));
    } finally {
      // Covers the success path and any non-timeout exception: close the
      // channel promptly rather than relying on it being collected once the
      // process exits.
      session?.close();
    }
  }

  /// Best-effort remote termination + channel close for a timed-out command.
  /// Safe to call with a null [session] (nothing to do yet) and safe to call
  /// more than once (dartssh2 sessions tolerate repeated `close()`). See
  /// [command_formatter.dart]'s `exec`-based invocation for why the signal is
  /// actually delivered to the real process rather than a shell wrapper.
  void _killAndClose(SSHSession? session) {
    if (session == null) return;
    try {
      session.kill(SSHSignal.TERM);
    } catch (_) {}
    session.close();
  }

  /// Starts a long-running remote command and returns a live [SSHStreamHandle]
  /// for incremental consumption. See [SSHStreamHandle] for why this bypasses
  /// the serialization queue. Once the returned handle is live, there is no
  /// further timeout — streaming commands never exit — but the channel-open
  /// itself is bounded by [openTimeout]: a dead/NAT-dropped session with no
  /// RST can otherwise hang here forever, wedging the file watcher or a
  /// GitLab CI trace with no user-visible recourse short of disconnecting.
  ///
  /// [extraEnv] is merged over the formatter's default prelude (which disables
  /// optional locks and interactive prompts).
  @override
  Future<SSHStreamHandle> executeStream({
    required String repoPath,
    required List<String> gitArgs,
    Map<String, String>? extraEnv,
    Duration openTimeout = defaultTimeout,
  }) async {
    final client = _clientManager.client;
    if (client == null) {
      throw Exception('SSH connection not established.');
    }
    if (_clientManager.clientGeneration != _clientManager.generation) {
      // A new connect() is mid-handshake: the attached client belongs to a
      // superseded attempt. Refuse to bind a long-lived stream (a watcher, a
      // CI trace) to a session that's about to be retired — the caller's
      // restart/backoff logic re-opens it against the new session instead.
      throw SSHCommandSuperseded(gitArgs.join(' '));
    }

    final command = CommandFormatter.format(
      repoPath: repoPath,
      gitArgs: gitArgs,
      env: _mergedEnv(extraEnv),
      binaryPaths: _binaryPaths,
      neutralizeEnv: _neutralizeTokens,
    );

    final attempt = client.execute(command);
    try {
      final session = await attempt.timeout(openTimeout);
      return _SshSessionStreamHandle(session);
    } on TimeoutException {
      // If the open eventually does resolve in the background, don't leak the
      // session it produces — terminate and close it, mirroring `_run`'s
      // post-timeout cleanup above.
      unawaited(attempt.then(_killAndClose, onError: (_) {}));
      throw SSHCommandTimeout(gitArgs.join(' '));
    }
  }
}
