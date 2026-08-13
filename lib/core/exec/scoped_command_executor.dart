import 'dart:typed_data';

import '../ssh/ssh_command_executor.dart';

/// Resolves the scope environment overlay for a repo — the
/// `GIT_DIR`/`GIT_WORK_TREE` a scoped work-tree (dotfiles) repo needs — or null
/// for an ordinary repo. Kept as a function so the caller owns the source of
/// truth (the connection's `scopedGitDirs`) without this layer importing it.
typedef RepoScopeEnvResolver = Map<String, String>? Function(String repoPath);

/// A [CommandExecutor] that transparently injects a repo's scope overlay
/// (`GIT_DIR`/`GIT_WORK_TREE`) into every command's environment, keyed by
/// `repoPath`.
///
/// `GitService` carries its own scope registry and merges the overlay at each
/// call site; the forge services (`GlabService`/`GhService`) have no such
/// plumbing, so on a scoped/dotfiles repo their `gh`/`glab` invocations — and
/// especially the ones that shell git against the working tree (`gh pr
/// checkout`, `glab mr checkout`, `gh issue develop`) or probe `git remote
/// get-url` to detect the forge — ran with only `cwd=repoPath` and resolved the
/// wrong (or no) git dir. Wrapping their executor here fixes that centrally,
/// without threading the overlay through dozens of call sites (and without any
/// risk of missing one). Every other [CommandExecutor] member forwards
/// unchanged.
///
/// The overlay is merged UNDER the caller's own `extraEnv` (`{...scope,
/// ...extraEnv}`) so a call that deliberately sets an env key still wins; in
/// practice the two key sets are disjoint (git-dir vs a forge's host var).
class ScopedCommandExecutor implements CommandExecutor {
  ScopedCommandExecutor(this._inner, this._scopeFor);

  final CommandExecutor _inner;
  final RepoScopeEnvResolver _scopeFor;

  Map<String, String>? _merge(String repoPath, Map<String, String>? extraEnv) {
    final scope = _scopeFor(repoPath);
    if (scope == null || scope.isEmpty) return extraEnv;
    if (extraEnv == null || extraEnv.isEmpty) return scope;
    return {...scope, ...extraEnv};
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
    bool compress = false,
    OperationDescriptor? operation,
    OperationEventCallback? onOperationEvent,
  }) => _inner.execute(
    repoPath: repoPath,
    gitArgs: gitArgs,
    extraEnv: _merge(repoPath, extraEnv),
    stdin: stdin,
    timeout: timeout,
    retries: retries,
    lane: lane,
    compress: compress,
    operation: operation,
    onOperationEvent: onOperationEvent,
  );

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
    extraEnv: _merge(repoPath, extraEnv),
    openTimeout: openTimeout,
    operation: operation,
    onOperationEvent: onOperationEvent,
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
