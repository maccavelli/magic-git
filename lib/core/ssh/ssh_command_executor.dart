import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException, gzip;
import 'dart:typed_data';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import '../exec/command_drain.dart';
import '../exec/command_lanes.dart';
import '../exec/command_telemetry.dart';
import '../exec/operation_activity.dart';
import 'adaptive_read_concurrency.dart';
import 'command_formatter.dart';
import 'shell_escaper.dart';
import 'ssh_client_manager.dart';

// Re-export drain types so existing imports of this library keep working.
export '../exec/command_drain.dart'
    show
        SSHOutputExceeded,
        OutputByteBudget,
        collectBounded,
        boundedBytes,
        maxCommandOutputChars,
        maxCommandOutputBytes;
export '../exec/command_lanes.dart' show ExecLane;
export '../exec/operation_activity.dart'
    show OperationDescriptor, OperationEventCallback, OperationId;

/// Transport-agnostic command result. [SSHCommandResult] remains as a
/// compatibility typedef — both the SSH and local executors return this shape.
class CommandResult {
  final int exitCode;
  final String stdout;
  final String stderr;
  final OperationId? operationId;

  const CommandResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    this.operationId,
  });

  bool get isSuccess => exitCode == 0;

  CommandResult withOperationId(OperationId? id) => CommandResult(
    exitCode: exitCode,
    stdout: stdout,
    stderr: stderr,
    operationId: id,
  );
}

/// Compatibility alias — prefer [CommandResult] in new code.
typedef SSHCommandResult = CommandResult;

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
abstract class CommandStreamHandle {
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

/// Compatibility alias — prefer [CommandStreamHandle] in new code.
typedef SSHStreamHandle = CommandStreamHandle;

/// [CommandStreamHandle] backed by a live [SSHSession]. dartssh2 multiplexes it
/// onto its own channel with an independent flow-control window, so it
/// coexists with request/response commands without blocking them.
class _SshSessionStreamHandle implements CommandStreamHandle {
  final SSHSession _session;
  final void Function() onByte;
  final void Function() onClosed;
  late final int _telemetryEpoch;
  bool _closed = false;

  _SshSessionStreamHandle(
    this._session, {
    required this.onByte,
    required this.onClosed,
  }) {
    _telemetryEpoch = CommandTelemetry.instance.streamOpened();
    // Count natural channel death the same as cancel (watcher restart path).
    unawaited(
      _session.done.then((_) {}, onError: (_) {}).whenComplete(_noteClosed),
    );
  }

  void _noteClosed() {
    if (_closed) return;
    _closed = true;
    CommandTelemetry.instance.streamClosed(_telemetryEpoch);
    onClosed();
  }

  Stream<String> _decode(Stream<List<int>> raw) => raw
      .map((chunk) {
        onByte();
        return chunk;
      })
      .transform(const Utf8Decoder(allowMalformed: true));

  /// The stream transform carries decoder state across chunk boundaries, so
  /// multi-byte sequences split across packets decode correctly.
  @override
  late final Stream<String> stdout = _decode(_session.stdout.cast<List<int>>());
  @override
  late final Stream<String> stderr = _decode(_session.stderr.cast<List<int>>());

  /// Backed by [SSHSession.waitForExit], which is safe to await more than
  /// once.
  @override
  Future<int?> get exitCode => _session.waitForExit();

  @override
  Future<void> cancel() async {
    await SSHCommandExecutor.killAndCloseSession(_session);
    _noteClosed();
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
    OperationDescriptor? operation,
    OperationEventCallback? onOperationEvent,
  });

  /// Starts a long-running command and returns a live handle for incremental
  /// consumption. Bypasses the serialization queue — see
  /// [SSHCommandExecutor.executeStream].
  Future<SSHStreamHandle> executeStream({
    required String repoPath,
    required List<String> gitArgs,
    Map<String, String>? extraEnv,
    Duration openTimeout = SSHCommandExecutor.defaultTimeout,
    OperationDescriptor? operation,
    OperationEventCallback? onOperationEvent,
  });

  /// Uploads [bytes] to [remotePath] on the host: the SSH backend streams over
  /// SFTP, the local backend writes to the filesystem. Used by guided install's
  /// file sideload (an air-gapped host that can't download for itself) and
  /// remote-edit sync. Throws on failure.
  ///
  /// [routingRepo] is ignored by real executors; the secondary-window proxy
  /// uses it to pick the main-isolate session that owns the file (same role
  /// as `execute`'s `repoPath`).
  Future<void> uploadBytes(
    String remotePath,
    Uint8List bytes, {
    String? routingRepo,
  });

  /// Applies a resolved environment (augmented PATH + resolved binary
  /// locations) so commands find user-installed tools. See
  /// [SSHCommandExecutor.configureEnvironment].
  void configureEnvironment({String? path, Map<String, String> binaries});

  /// The connect-time-resolved absolute path for a bare tool name (e.g.
  /// `glab`), or null when unknown — an unconfigured executor, or a relay
  /// proxy that holds no environment of its own. Unlike `argv[0]` (rewritten
  /// by [CommandFormatter.format]), a tool name embedded inside an argument —
  /// notably the `!glab auth git-credential` in a `git -c credential.helper=…`
  /// override — is opaque to that rewrite, so callers pin it explicitly via
  /// this. See [forgeGitAuthConfigArgs].
  String? resolvedBinaryPath(String name);

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

  /// Lane-aware scheduler: reads run concurrently (and alongside a fetch/push
  /// on the sync lane), mutations run strictly alone — see [ExecLane] /
  /// [CommandLaneScheduler]. Replaces the old single serialized chain, which
  /// let one slow network op head-of-line-block every read in the app.
  final CommandLaneScheduler _scheduler = CommandLaneScheduler();

  /// Soft-throttles [_scheduler]'s read ceiling from keepalive RTT samples.
  late final AdaptiveReadConcurrency _adaptiveReads = AdaptiveReadConcurrency(
    onCapChanged: _scheduler.setMaxConcurrentReads,
  );

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

  int _activeCommands = 0;
  int _activeStreams = 0;
  DateTime? _lastStreamByteAt;
  DateTime? _lastStreamNoteAt;

  static const Duration streamBusyWindow = Duration(seconds: 30);

  bool get transportBusy => _activeCommands > 0;

  /// Stream client is busy only while bytes have flowed recently.
  bool get streamBusy =>
      _activeStreams > 0 &&
      _lastStreamByteAt != null &&
      DateTime.now().difference(_lastStreamByteAt!) < streamBusyWindow;

  SSHCommandExecutor(this._clientManager) {
    _clientManager.registerBusyProbes(
      command: () => transportBusy,
      stream: () => streamBusy,
    );
    // Start at the adaptive no-sample cap (3) until RTT samples arrive.
    _scheduler.setMaxConcurrentReads(_adaptiveReads.effectiveCap);
  }

  void _noteStreamByte() {
    final now = DateTime.now();
    _lastStreamByteAt = now;
    if (_lastStreamNoteAt != null &&
        now.difference(_lastStreamNoteAt!) < const Duration(seconds: 1)) {
      return;
    }
    _lastStreamNoteAt = now;
    _clientManager.noteStreamActivity();
  }

  void _noteStreamClosed() {
    if (_activeStreams > 0) _activeStreams--;
  }

  /// Current adaptive read ceiling (for tests / diagnostics).
  int get adaptiveReadCap => _adaptiveReads.effectiveCap;

  /// Feed a keepalive RTT sample so the read lane can soft-throttle under
  /// high latency. Wired from [ConnectionHealthMonitor.onPingSample].
  void noteLinkRtt(Duration rtt) => _adaptiveReads.onRtt(rtt);

  /// Reset adaptive concurrency to the no-sample cap (on connect/disconnect).
  void resetAdaptiveReads() {
    _adaptiveReads.reset();
    _scheduler.setMaxConcurrentReads(_adaptiveReads.effectiveCap);
  }

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
  String? resolvedBinaryPath(String name) => _binaryPaths[name];

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
    resetAdaptiveReads();
  }

  /// Writes [bytes] to [remotePath] as an ordinary exec-channel command
  /// (`cat > path`, the raw bytes on stdin) — NOT over SFTP. dartssh2's
  /// `SftpClient.close()` ends the SFTP protocol session but never closes the
  /// channel underneath it (verified against the library source; channels die
  /// only with the whole client), so the previous SFTP implementation leaked
  /// one of the host's `MaxSessions` slots per sideload until disconnect. The
  /// exec channel gets the full command lifecycle for free: lane scheduling,
  /// generation pinning, the timeout's TERM→KILL cleanup, and guaranteed
  /// channel close. [ExecLane.isolated] because a sideload touches neither
  /// the repo nor the resources the sync lane serializes.
  /// Timeout for a sideload of [byteCount] bytes: the flat request/response
  /// default plus transfer time at a conservative 64 KiB/s floor. A flat
  /// [defaultTimeout] guaranteed failure for any payload bigger than a slow
  /// link can move in 60s — and the sideload's whole audience is air-gapped
  /// hosts behind exactly such links. The timeout stays a safety net against
  /// a wedged transfer, not a clock a slow-but-progressing one can lose to.
  @visibleForTesting
  static Duration uploadTimeoutFor(int byteCount) =>
      defaultTimeout + Duration(seconds: byteCount ~/ (64 * 1024));

  @override
  Future<void> uploadBytes(
    String remotePath,
    Uint8List bytes, {
    String? routingRepo,
  }) async {
    final gen = _clientManager.generation;
    final gitArgs = ['sh', '-c', 'cat > ${ShellEscaper.escape(remotePath)}'];
    final timeout = uploadTimeoutFor(bytes.length);
    final result = await runWithRetries(
      () => _run(
        gen,
        '/',
        gitArgs,
        null,
        bytes,
        timeout,
        false,
        ExecLane.isolated,
      ),
      0,
      enqueue: (attempt) => _scheduler.run(
        ExecLane.isolated,
        attempt,
        deadline: timeout + CommandLaneScheduler.watchdogMargin,
      ),
    );
    if (!result.isSuccess) {
      throw Exception(
        'upload to $remotePath failed (exit ${result.exitCode}): '
        '${result.stderr.trim()}',
      );
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
    OperationDescriptor? operation,
    OperationEventCallback? onOperationEvent,
  }) async {
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
    final stdinBytes = stdin == null
        ? null
        : Uint8List.fromList(utf8.encode(stdin));
    final lifecycle = OperationLifecycleEmitter.begin(
      operation,
      onOperationEvent,
    );
    try {
      final result = await runWithRetries(
        () => _run(
          gen,
          repoPath,
          gitArgs,
          extraEnv,
          stdinBytes,
          timeout,
          compress,
          lane,
        ),
        retries,
        // One enqueued job per *attempt*, and an attempt is bounded by `timeout`
        // (which also kills the channel/process). The scheduler's deadline is that
        // plus a margin — a pure backstop against a body that never settles at
        // all, which would otherwise hold its lane slot for the life of the app.
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

  static const Duration _retryBackoff = Duration(milliseconds: 400);

  /// Runs [attempt], retrying up to [retries] times on a *transient* transport
  /// error with [backoff] between tries. Only errors that [isTransientTransportError]
  /// accepts are retried — deterministic failures (timeouts, supersession,
  /// oversized output, auth, argument errors, gzip format errors) rethrow
  /// immediately. A non-zero exit is returned normally (not thrown), so it
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
      } catch (e) {
        // Observe MaxSessions / channel-open pressure once per failure, even
        // when we will not retry (retries == 0 or non-transient).
        if (e is SSHChannelOpenError) {
          CommandTelemetry.instance.recordChannelOpenError();
        }
        if (!isTransientTransportError(e) || n++ >= retries) rethrow;
        await Future<void>.delayed(backoff);
      }
    }
  }

  /// Whether [e] is a blip worth re-issuing an *idempotent* read for.
  /// Allowlist, not denylist: auth failures, timeouts, supersession, parse
  /// errors, and argument errors must never be retried.
  static bool isTransientTransportError(Object e) {
    // Deterministic / ambiguous — never retry.
    if (e is SSHCommandTimeout ||
        e is SSHCommandSuperseded ||
        e is SSHOutputExceeded ||
        e is ArgumentError ||
        e is FormatException ||
        e is StateError ||
        e is TimeoutException) {
      return false;
    }
    // dartssh2 auth / host-key / key-decode are deterministic for this attempt.
    // Peer disconnect, handshake timeout, and malformed packets are protocol
    // failures, not blips — 3.3.0 types them as SSHError so handlers can
    // refuse to retry the same peer.
    if (e is SSHAuthError ||
        e is SSHHostkeyError ||
        e is SSHKeyDecodeError ||
        e is SSHDisconnectError ||
        e is SSHHandshakeError ||
        e is SSHPacketError) {
      return false;
    }
    // Capacity blip or mid-flight channel drop — worth one retry after backoff.
    if (e is SSHChannelOpenError ||
        e is SSHChannelRequestError ||
        e is SSHSocketError ||
        e is SSHStateError ||
        e is SocketException) {
      return true;
    }
    // String fallback for transport wraps that don't surface typed errors.
    final s = e.toString().toLowerCase();
    if (s.contains('connection closed') ||
        s.contains('connection reset') ||
        s.contains('broken pipe') ||
        (s.contains('socket') &&
            (s.contains('closed') || s.contains('error'))) ||
        (s.contains('channel') && s.contains('closed'))) {
      return true;
    }
    return false;
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
    // Raw bytes, not a String: execute() UTF-8-encodes its text stdin, while
    // uploadBytes feeds file content through unmangled.
    Uint8List? stdin,
    Duration timeout,
    bool compress,
    ExecLane lane,
  ) async {
    // Started before the channel open so the sample's duration reflects the
    // full user-perceived cost of the command, not just the drain.
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

    _activeCommands++;
    try {
      return await _runBody(
        client,
        gitArgs,
        extraEnv,
        stdin,
        timeout,
        compress,
        lane,
        repoPath,
      );
    } finally {
      _activeCommands--;
      _clientManager.noteCommandSettled();
    }
  }

  Future<SSHCommandResult> _runBody(
    SSHClient client,
    List<String> gitArgs,
    Map<String, String>? extraEnv,
    Uint8List? stdin,
    Duration timeout,
    bool compress,
    ExecLane lane,
    String repoPath,
  ) async {
    final sw = Stopwatch()..start();
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
    // Hoisted out of openAndDrain so the failure paths below can record what
    // the command consumed before it died — a dashboard that only sees
    // successes reports a healthy session while every read is timing out.
    final budget = OutputByteBudget();
    // Counts stdout's on-the-wire size *before* any decompression — with the
    // budget's (post-decompression) total this is what lets the dashboard
    // report real gzip savings per session.
    var stdoutWireBytes = 0;
    void recordFailureSample() {
      CommandTelemetry.instance.record(
        CommandSample(
          lane: lane,
          duration: sw.elapsed,
          bytes: budget.used,
          wireBytes: stdoutWireBytes,
          compressed: compressed,
          success: false,
        ),
      );
    }

    // Set when the client-side timeout fires. Checked immediately after the
    // channel opens: a timeout that fired *while the open was still pending*
    // found a null session with nothing to kill, and the command it launched
    // would otherwise run on unattended — for a command that never exits (and
    // so never settles this attempt), forever, until disconnect.
    var timedOut = false;

    Future<SSHCommandResult> openAndDrain() async {
      session = await client.execute(command);
      final s = session!;
      if (timedOut) {
        await killAndCloseSession(s);
        throw SSHCommandTimeout(gitArgs.join(' '));
      }

      if (stdin != null) {
        s.write(stdin);
      }
      // Always close stdin — with or without data — mirroring
      // LocalCommandExecutor's contract. dartssh2 turns this into a channel
      // EOF only (output keeps flowing), and without it a remote command that
      // unexpectedly reads stdin blocks on it forever: it never exits, its
      // streams never close, and this attempt never settles.
      await s.stdin.close();

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
      final rawStdout = s.stdout.cast<List<int>>().map((chunk) {
        stdoutWireBytes += chunk.length;
        return chunk;
      });
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
      // and its stderr channel never closes either). The catch below then
      // TERM-kills the remote process — a bare close() would not (see there).
      final drained = await Future.wait([
        stdoutFuture,
        stderrFuture,
      ], eagerError: true);
      final exitCode = await s.waitForExit() ?? -1;
      void recordSample(int effectiveExit) {
        CommandTelemetry.instance.record(
          CommandSample(
            lane: lane,
            duration: sw.elapsed,
            bytes: budget.used,
            wireBytes: stdoutWireBytes,
            compressed: compressed,
            success: effectiveExit == 0,
          ),
        );
      }

      if (!compressed) {
        recordSample(exitCode);
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
      final effectiveExit = realExit ?? (exitCode != 0 ? exitCode : -1);
      recordSample(effectiveExit);
      return SSHCommandResult(
        exitCode: effectiveExit,
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
      // If the open itself was the slow part, `session` is still null here
      // and there is nothing to kill yet — the flag makes openAndDrain kill
      // the channel itself the moment the open finally resolves, rather than
      // letting the command run on unattended. (A cleanup keyed on `attempt`
      // settling would not do: a never-exiting command never settles it.)
      timedOut = true;
      _killAndClose(session);
      recordFailureSample();
      throw SSHCommandTimeout(gitArgs.join(' '));
    } catch (_) {
      // Any other drain failure — canonically SSHOutputExceeded from the byte
      // budget — leaves the remote process alive and still streaming. The
      // `finally` close() is NOT enough here: dartssh2's close() only sends
      // channel EOF and then waits for the remote side to close, while the
      // session keeps buffering the incoming data (now listenerless) without
      // bound — the exact OOM the budget exists to prevent, just moved one
      // layer down. Kill the process like the timeout path does; the local
      // executor's `finally { process?.kill(); }` is this same rule.
      _killAndClose(session);
      recordFailureSample();
      rethrow;
    } finally {
      // Covers the success path: close the channel promptly rather than
      // relying on it being collected once the process exits.
      session?.close();
    }
  }

  /// Grace between TERM and KILL on a timed-out / cancelled session. Short
  /// enough that a wedged process doesn't hold `.git/index.lock` long; long
  /// enough that a polite exit can flush and release locks first.
  static const Duration killGrace = Duration(milliseconds: 400);

  /// Best-effort remote termination + channel close for a timed-out command.
  /// Safe to call with a null [session] (nothing to do yet) and safe to call
  /// more than once (dartssh2 sessions tolerate repeated `close()`). See
  /// [command_formatter.dart]'s `exec`-based invocation for why the signal is
  /// actually delivered to the real process rather than a shell wrapper.
  ///
  /// Escalation: TERM immediately, then KILL after [killGrace] if the session
  /// is still around — a process that ignores TERM must not keep running
  /// unattended (or holding locks) after the client has given up.
  void _killAndClose(SSHSession? session) {
    killAndCloseSession(session);
  }

  /// Shared by request/response timeout cleanup and stream [cancel].
  static Future<void> killAndCloseSession(SSHSession? session) async {
    if (session == null) return;
    try {
      session.kill(SSHSignal.TERM);
    } catch (_) {}
    try {
      session.close();
    } catch (_) {}
    // Escalate after a short grace so an ignored TERM still dies. Fire-and-
    // forget: the caller's future must not wait on a hung process.
    unawaited(
      Future<void>.delayed(killGrace, () {
        try {
          session.kill(SSHSignal.KILL);
        } catch (_) {}
        try {
          session.close();
        } catch (_) {}
      }),
    );
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
    OperationDescriptor? operation,
    OperationEventCallback? onOperationEvent,
  }) async {
    final lifecycle = OperationLifecycleEmitter.begin(
      operation,
      onOperationEvent,
    );
    lifecycle?.started();
    // Pin generation at open time — same contract as execute()'s enqueue pin.
    final gen = _clientManager.generation;
    // Prefer the dedicated stream client (dual-client mode) so long-lived
    // watchers/traces do not consume MaxSessions on the command connection.
    // Falls back to the command client when stream open degraded.
    final client = _clientManager.streamClient;
    if (client == null) {
      throw Exception('SSH connection not established.');
    }
    if (_clientManager.clientGeneration != gen) {
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
      // Superseded while the channel was opening — kill the session rather
      // than handing the caller a stream bound to a retired generation.
      if (_clientManager.generation != gen ||
          _clientManager.clientGeneration != gen) {
        await killAndCloseSession(session);
        throw SSHCommandSuperseded(gitArgs.join(' '));
      }
      _activeStreams++;
      return _ActivityStreamHandle(
        _SshSessionStreamHandle(
          session,
          onByte: _noteStreamByte,
          onClosed: _noteStreamClosed,
        ),
        lifecycle,
      );
    } on TimeoutException {
      // If the open eventually does resolve in the background, don't leak the
      // session it produces — terminate and close it, mirroring `_run`'s
      // post-timeout cleanup above.
      unawaited(attempt.then(killAndCloseSession, onError: (_) {}));
      throw SSHCommandTimeout(gitArgs.join(' '));
    } on SSHChannelOpenError {
      CommandTelemetry.instance.recordChannelOpenError();
      lifecycle?.failed();
      rethrow;
    } catch (_) {
      lifecycle?.failed();
      rethrow;
    }
  }
}

class _ActivityStreamHandle implements CommandStreamHandle {
  _ActivityStreamHandle(this._inner, this._lifecycle) {
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
