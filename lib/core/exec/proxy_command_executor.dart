import 'package:flutter/services.dart';

import '../ssh/ssh_command_executor.dart';
import 'exec_proxy_codec.dart';

/// The History window's [CommandExecutor]: forwards every `execute()` call
/// over the `magicgit/history/hub` channel to the main isolate, which runs it
/// on the real executor. This is what lets the second window's entire
/// provider stack (GitService, log/diff/blame providers, mutations) run
/// unchanged — and it keeps the correctness properties that two independent
/// executors would break: all commands still flow through the main isolate's
/// single [CommandLaneScheduler] (mutations stay globally serialized) and
/// command telemetry stays unified.
///
/// No id-multiplexing is needed for concurrency: each `invokeMethod` platform
/// message carries its own reply handle, so any number of in-flight calls
/// resolve independently and possibly out of order — ordering is enforced
/// where it belongs, in the main isolate's lane scheduler.
class ProxyCommandExecutor implements CommandExecutor {
  ProxyCommandExecutor({
    this.channel = const MethodChannel('magicgit/history/hub'),
    this.onMutationCompleted,
  });

  final MethodChannel channel;

  /// Fired after any exclusive-lane command returns a result — success *or*
  /// non-zero exit, because a failed mutation (a conflicted cherry-pick) has
  /// still mutated the repo. The History window shell uses this to mark its
  /// own-mutation tracker and tell the main window to refresh; hooking here
  /// catches every mutation path without touching GitService or HistoryView.
  final void Function(String repoPath)? onMutationCompleted;

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
    final request = ExecuteRequest(
      repoPath: repoPath,
      gitArgs: gitArgs,
      extraEnv: extraEnv,
      stdin: stdin,
      timeout: timeout,
      retries: retries,
      lane: lane,
      compress: compress,
    );
    final Map<Object?, Object?>? reply;
    try {
      reply = await channel.invokeMethod<Map<Object?, Object?>>(
        'execute',
        encodeExecuteRequest(request),
      );
    } on PlatformException catch (e) {
      // The relay or the main-isolate handler is gone (window closing,
      // bridge torn down). Surface something a human can read — the standard
      // error dialogs show `$e` verbatim.
      throw ProxyExecuteException(
        'The main window could not run this command: '
        '${e.message ?? e.code}',
      );
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

  /// Never needed: `GitService`'s entire surface is request/response
  /// (verified — zero `executeStream` call sites), and the History window
  /// receives watcher ticks as pushed events instead of running a watcher.
  @override
  Future<SSHStreamHandle> executeStream({
    required String repoPath,
    required List<String> gitArgs,
    Map<String, String>? extraEnv,
    Duration openTimeout = SSHCommandExecutor.defaultTimeout,
  }) => throw UnsupportedError(
    'executeStream is not proxied to the History window',
  );

  @override
  Future<void> uploadBytes(String remotePath, Uint8List bytes) =>
      throw UnsupportedError('uploadBytes is not proxied to the History window');

  /// Environment ownership stays with the main isolate's real executor —
  /// these are deliberate no-ops, not errors, because the connection
  /// controller in this isolate never runs (the calls simply must not throw
  /// if something incidental invokes them).
  @override
  void configureEnvironment({String? path, Map<String, String> binaries = const {}}) {}

  @override
  void setForgeTokenNeutralization(Iterable<String> vars) {}

  @override
  void resetEnvironment() {}
}
