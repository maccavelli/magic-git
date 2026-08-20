import 'dart:typed_data';

import '../ssh/ssh_command_executor.dart';

typedef OperationDescriptorResolver =
    OperationDescriptor? Function({
      required String repositoryPath,
      required ExecLane lane,
      required List<String> argv,
    });

/// Decorates an executor with per-tab activity reporting while forwarding all
/// transport behavior unchanged. Call sites may provide a more specific
/// descriptor; otherwise the injected resolver supplies a curated generic one
/// without exposing raw argv.
class ActivityCommandExecutor implements CommandExecutor {
  ActivityCommandExecutor(
    this._inner, {
    required this.onOperationEvent,
    required this.resolveDescriptor,
  });

  final CommandExecutor _inner;
  final OperationEventCallback onOperationEvent;
  final OperationDescriptorResolver resolveDescriptor;

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
  }) => _inner.execute(
    repoPath: repoPath,
    gitArgs: gitArgs,
    extraEnv: extraEnv,
    stdin: stdin,
    timeout: timeout,
    retries: retries,
    lane: lane,
    compress: compress,
    activityIdle: activityIdle,
    operation:
        operation ??
        resolveDescriptor(repositoryPath: repoPath, lane: lane, argv: gitArgs),
    onOperationEvent: onOperationEvent ?? this.onOperationEvent,
  );

  /// Note the asymmetry with [execute]: no [resolveDescriptor] call.
  ///
  /// Deliberate. Streams here are long-lived *reads* — the file watcher and
  /// the CI log trace — so a resolved descriptor would post an activity entry
  /// for background watching, which is exactly the noise
  /// `OperationVisibility.background` exists to suppress. A caller that does
  /// want one still passes `operation:` explicitly.
  @override
  Future<SSHStreamHandle> executeStream({
    required String repoPath,
    required List<String> gitArgs,
    Map<String, String>? extraEnv,
    Duration openTimeout = SSHCommandExecutor.defaultTimeout,
    OperationDescriptor? operation,
    OperationEventCallback? onOperationEvent,
  }) => _inner.executeStream(
    repoPath: repoPath,
    gitArgs: gitArgs,
    extraEnv: extraEnv,
    openTimeout: openTimeout,
    operation: operation,
    onOperationEvent: onOperationEvent ?? this.onOperationEvent,
  );

  @override
  Future<void> uploadBytes(
    String remotePath,
    Uint8List bytes, {
    String? routingRepo,
  }) => _inner.uploadBytes(remotePath, bytes, routingRepo: routingRepo);

  @override
  void configureEnvironment({
    String? path,
    Map<String, String> binaries = const {},
  }) => _inner.configureEnvironment(path: path, binaries: binaries);

  @override
  String? resolvedBinaryPath(String name) => _inner.resolvedBinaryPath(name);

  @override
  void setForgeTokenNeutralization(Iterable<String> vars) =>
      _inner.setForgeTokenNeutralization(vars);

  @override
  void resetEnvironment() => _inner.resetEnvironment();
}
