import 'dart:async';

import 'package:flutter/services.dart';

import '../ssh/ssh_client_manager.dart' show ConnectionHealthMonitor;
import '../ssh/ssh_command_executor.dart';
import '../window/window_channels.dart';
import 'exec_proxy_codec.dart';

/// A secondary window's [CommandExecutor]: forwards every `execute()` call over
/// that window's per-window hub channel to the main isolate, which runs it on
/// the real executor. This is what lets a second window's entire provider stack
/// (GitService, log/diff/blame providers, mutations) run unchanged — and it
/// keeps the correctness properties that two independent executors would break:
/// all commands still flow through the main isolate's single
/// [CommandLaneScheduler] (mutations stay globally serialized) and command
/// telemetry stays unified.
///
/// No id-multiplexing is needed for concurrency: each `invokeMethod` platform
/// message carries its own reply handle, so any number of in-flight calls
/// resolve independently and possibly out of order — ordering is enforced
/// where it belongs, in the main isolate's lane scheduler. The per-window
/// channel name means two windows' proxies never share a channel, so this
/// property holds no matter how many windows are open.
class ProxyCommandExecutor implements CommandExecutor {
  ProxyCommandExecutor({
    required this.channel,
    this.onMutationCompleted,
    this.probeInterval = defaultProbeInterval,
    this.probeTimeout = defaultProbeTimeout,
    this.deadProbes = defaultDeadProbes,
  });

  /// Builds a proxy bound to [windowId]'s hub channel — the normal way a child
  /// constructs one, from the id in its [WindowDescriptor].
  ProxyCommandExecutor.forWindow(
    String windowId, {
    this.onMutationCompleted,
    this.probeInterval = defaultProbeInterval,
    this.probeTimeout = defaultProbeTimeout,
    this.deadProbes = defaultDeadProbes,
  }) : channel = MethodChannel(windowHubChannel(windowId));

  final MethodChannel channel;

  /// Fired after any exclusive-lane command returns a result — success *or*
  /// non-zero exit, because a failed mutation (a conflicted cherry-pick) has
  /// still mutated the repo. The History window shell uses this to mark its
  /// own-mutation tracker and tell the main window to refresh; hooking here
  /// catches every mutation path without touching GitService or HistoryView.
  final void Function(String repoPath)? onMutationCompleted;

  /// How often the main window is pinged while this proxy is waiting on it.
  static const Duration defaultProbeInterval = Duration(seconds: 5);

  /// How long a single ping may take. A ping is answered off the main isolate's
  /// command path — it doesn't queue behind anything — so a live main window
  /// replies to one promptly even mid-`git`, and this can be tight.
  static const Duration defaultProbeTimeout = Duration(seconds: 10);

  /// Consecutive silent pings before the main window is declared gone. More than
  /// one, so a single hiccup (a long frame, a stalled event loop) can't fail
  /// commands that were about to succeed.
  static const int defaultDeadProbes = 2;

  /// Liveness-probe tuning. Overridable so a test can drive the real machinery
  /// on a short clock instead of waiting out the production one.
  final Duration probeInterval;
  final Duration probeTimeout;
  final int deadProbes;

  /// One entry per `execute` still waiting on a reply. Completing one with an
  /// error is how the liveness probe abandons a call that will never be answered.
  final Set<Completer<Never>> _outstanding = {};

  /// The liveness probe, alive only while calls are outstanding. This is the
  /// same [ConnectionHealthMonitor] that watches the SSH transport — reused
  /// rather than re-implemented, notably for its never-stack-probes guard: a
  /// hand-rolled `Timer.periodic` here once let one ~15 s main-isolate stall
  /// time out two *overlapping* pings and hit [deadProbes] in a single
  /// hiccup, abandoning commands that were about to succeed. The monitor
  /// counts only sequential unanswered pings. A stopped monitor can't be
  /// restarted, so each probing episode constructs a fresh one.
  ConnectionHealthMonitor? _monitor;

  /// Runs [gitArgs] on the main isolate, and — the whole point of the machinery
  /// below — comes back *even if the main isolate never answers*.
  ///
  /// A platform message carries its own reply handle, so if the far side stops
  /// answering (the window's hub handler is torn down between send and reply, the
  /// native relay drops the message while a window is closing) there is nothing
  /// to fail: the future simply never completes. The provider waiting on it never
  /// leaves `AsyncLoading`, and the pane spins forever with no error anywhere.
  ///
  /// The fix is deliberately **not** a timeout on the command. A proxied command
  /// can legitimately take an unbounded amount of wall-clock time — the main
  /// isolate runs it through its lane scheduler, so a diff can sit queued behind
  /// a five-minute commit before it even starts — and a clock long enough never to
  /// kill that is far too long to be any use as a liveness signal. Those are two
  /// different questions, and this asks the right one: not "is my command taking
  /// too long?" but "is anyone still there?" — which is cheap and quick to
  /// answer, whatever the command is doing.
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
    final request = ExecuteRequest(
      repoPath: repoPath,
      gitArgs: gitArgs,
      extraEnv: extraEnv,
      stdin: stdin,
      timeout: timeout,
      retries: retries,
      lane: lane,
      compress: compress,
      operation: operation,
    );

    final abandoned = Completer<Never>();
    _outstanding.add(abandoned);
    _startProbing();

    final Map<Object?, Object?>? reply;
    try {
      reply = await Future.any<Map<Object?, Object?>?>([
        channel.invokeMethod<Map<Object?, Object?>>(
          'execute',
          encodeExecuteRequest(request),
        ),
        // Completes only with an error, and only when the probe has given up.
        abandoned.future,
      ]);
    } on PlatformException catch (e) {
      // The relay or the main-isolate handler answered with a failure (window
      // closing, bridge torn down). Surface something a human can read — the
      // standard error dialogs show `$e` verbatim.
      throw ProxyExecuteException(
        'The main window could not run this command: ${e.message ?? e.code}',
      );
    } on MissingPluginException {
      // The window's hub channel has no handler any more: the main window has
      // already forgotten this window (see WindowManagerBridge._forget). Not a
      // PlatformException, so it used to escape the catch above as a raw,
      // unreadable error.
      throw const ProxyExecuteException(
        'The main window is no longer accepting commands for this window.',
      );
    } finally {
      _outstanding.remove(abandoned);
      if (_outstanding.isEmpty) _stopProbing();
    }

    if (reply == null) {
      throw const ProxyExecuteException(
        'The main window returned no response for this command.',
      );
    }
    final result = decodeExecuteResponse(reply);
    if (lane == ExecLane.exclusive) {
      onMutationCompleted?.call(repoPath);
    }
    return result;
  }

  /// Arms the liveness probe if it isn't already running. The ping itself is
  /// cheap by construction: the main window's hub answers it without touching
  /// a session, an executor or the lane scheduler, so it says only what it is
  /// meant to say — "I am here and I am reading my channel". Any failure
  /// counts as silence (a timeout, a dead relay, a hub with no handler left) —
  /// what it is doesn't matter; that it isn't answering does.
  void _startProbing() {
    _monitor ??= ConnectionHealthMonitor(
      ping: () => channel.invokeMethod<void>('ping'),
      onDead: () => _abandonOutstanding(
        'The main window stopped responding, so this command was abandoned. '
        'It may still be running there.',
      ),
      interval: probeInterval,
      pingTimeout: probeTimeout,
      failureThreshold: deadProbes,
    )..start();
  }

  /// Fails every call still waiting on the main window. Their commands may well
  /// still be running over there — this only stops *this* window waiting on an
  /// answer that is never coming, which is the difference between an error the
  /// user can act on and a pane that spins for the rest of the session.
  void _abandonOutstanding(String message) {
    final pending = _outstanding.toList();
    _outstanding.clear();
    _stopProbing();
    for (final call in pending) {
      if (!call.isCompleted) {
        call.completeError(ProxyExecuteException(message), StackTrace.current);
      }
    }
  }

  void _stopProbing() {
    _monitor?.stop();
    _monitor = null;
  }

  /// Drops the liveness probe. Called when the window is going away — an
  /// abandoned probe timer would otherwise keep firing at a channel nobody is
  /// listening to.
  void dispose() {
    _abandonOutstanding('This window is closing.');
  }

  /// Never needed: `GitService`'s entire surface is request/response
  /// (verified — zero `executeStream` call sites), and a secondary window
  /// receives watcher ticks as pushed events instead of running a watcher.
  @override
  Future<SSHStreamHandle> executeStream({
    required String repoPath,
    required List<String> gitArgs,
    Map<String, String>? extraEnv,
    Duration openTimeout = SSHCommandExecutor.defaultTimeout,
    OperationDescriptor? operation,
    OperationEventCallback? onOperationEvent,
  }) => throw UnsupportedError(
    'executeStream is not proxied to a secondary window',
  );

  /// Relays file upload to the main isolate (remote-edit sync). Requires
  /// [routingRepo] so the hub can pick the owning session like `execute`.
  @override
  Future<void> uploadBytes(
    String remotePath,
    Uint8List bytes, {
    String? routingRepo,
  }) async {
    final repo = routingRepo;
    if (repo == null || repo.isEmpty) {
      throw const ProxyExecuteException(
        'uploadBytes from a secondary window requires routingRepo '
        '(the repository path that owns the file).',
      );
    }
    final request = UploadBytesRequest(
      remotePath: remotePath,
      bytes: bytes,
      routingRepo: repo,
    );

    final abandoned = Completer<Never>();
    _outstanding.add(abandoned);
    _startProbing();

    final Map<Object?, Object?>? reply;
    try {
      reply = await Future.any<Map<Object?, Object?>?>([
        channel.invokeMethod<Map<Object?, Object?>>(
          'uploadBytes',
          encodeUploadBytesRequest(request),
        ),
        abandoned.future,
      ]);
    } on PlatformException catch (e) {
      throw ProxyExecuteException(
        'The main window could not upload this file: ${e.message ?? e.code}',
      );
    } on MissingPluginException {
      throw const ProxyExecuteException(
        'The main window is no longer accepting uploads for this window.',
      );
    } finally {
      _outstanding.remove(abandoned);
      if (_outstanding.isEmpty) _stopProbing();
    }

    if (reply == null) {
      throw const ProxyExecuteException(
        'The main window returned no response for this upload.',
      );
    }
    decodeUploadBytesResponse(reply);
    onMutationCompleted?.call(repo);
  }

  /// Environment ownership stays with the main isolate's real executor —
  /// these are deliberate no-ops, not errors, because the connection
  /// controller in this isolate never runs (the calls simply must not throw
  /// if something incidental invokes them).
  @override
  void configureEnvironment({
    String? path,
    Map<String, String> binaries = const {},
  }) {}

  /// Null: this proxy holds no resolved environment (it lives in a pop-out
  /// window and relays exec calls to the main isolate, whose real executor
  /// owns binary resolution and does the `argv[0]` rewrite). Forge credential
  /// helpers fall back to the bare CLI name here. Mutations and uploads are
  /// proxied via [execute] / [uploadBytes] — this window is not read-only.
  @override
  String? resolvedBinaryPath(String name) => null;

  @override
  void setForgeTokenNeutralization(Iterable<String> vars) {}

  @override
  void resetEnvironment() {}
}
