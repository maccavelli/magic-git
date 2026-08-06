import 'dart:async';
import 'dart:typed_data';

import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';

/// A single recorded `execute()` call.
class MockExecCall {
  final String repoPath;
  final List<String> gitArgs;
  final Map<String, String>? extraEnv;
  final String? stdin;
  final Duration timeout;
  final int retries;
  final ExecLane lane;
  final bool compress;

  const MockExecCall({
    required this.repoPath,
    required this.gitArgs,
    this.extraEnv,
    this.stdin,
    required this.timeout,
    required this.retries,
    required this.lane,
    required this.compress,
  });
}

/// A single recorded `executeStream()` call.
class MockStreamCall {
  final String repoPath;
  final List<String> gitArgs;
  final Map<String, String>? extraEnv;
  final Duration openTimeout;

  const MockStreamCall({
    required this.repoPath,
    required this.gitArgs,
    this.extraEnv,
    required this.openTimeout,
  });
}

/// A simple [CommandStreamHandle] backed by in-memory controllers.
///
/// Use [emitStdout] / [emitStderr] to push lines after construction.
/// Use [resolveExitCode] to complete the exit code future.
class MockStreamHandle extends CommandStreamHandle {
  final StreamController<String> _stdoutCtrl;
  final StreamController<String> _stderrCtrl;
  final Completer<int?> _exitCodeCompleter;
  bool _cancelled = false;

  MockStreamHandle({
    Stream<String>? stdout,
    Stream<String>? stderr,
    Future<int?>? exitCode,
  })  : _stdoutCtrl = StreamController<String>.broadcast(),
        _stderrCtrl = StreamController<String>.broadcast(),
        _exitCodeCompleter = Completer<int?>() {
    if (stdout != null) {
      stdout.listen(
        _stdoutCtrl.add,
        onDone: _stdoutCtrl.close,
        onError: _stdoutCtrl.addError,
      );
    }
    if (stderr != null) {
      stderr.listen(
        _stderrCtrl.add,
        onDone: _stderrCtrl.close,
        onError: _stderrCtrl.addError,
      );
    }
    if (exitCode != null) exitCode.then((c) => _exitCodeCompleter.complete(c));
  }

  @override
  Stream<String> get stdout => _stdoutCtrl.stream;

  @override
  Stream<String> get stderr => _stderrCtrl.stream;

  @override
  Future<int?> get exitCode => _exitCodeCompleter.future;

  @override
  Future<void> cancel() async {
    _cancelled = true;
    close();
  }

  bool get isCancelled => _cancelled;

  void emitStdout(String line) {
    if (!_stdoutCtrl.isClosed) _stdoutCtrl.add(line);
  }

  void emitStderr(String line) {
    if (!_stderrCtrl.isClosed) _stderrCtrl.add(line);
  }

  void resolveExitCode(int? code) => _exitCodeCompleter.complete(code);

  /// Closes both output streams so [stdout.toList] / [stderr.toList] complete.
  void close() {
    if (!_stdoutCtrl.isClosed) _stdoutCtrl.close();
    if (!_stderrCtrl.isClosed) _stderrCtrl.close();
  }
}

/// A reusable mock [CommandExecutor] for service-layer tests.
///
/// Default behaviour (when no callback matches):
///  - `execute()` returns [defaultResult] (or a zero-exit empty result).
///  - `executeStream()` throws [UnimplementedError] unless [onStream] is set.
///
/// Use [onExecute] for per-call custom results, throw, or inspection.
/// Use [onStream] for streaming mocks.
///
/// Every call is recorded in [calls] / [streamCalls] for later assertions.
class MockExecutor extends CommandExecutor {
  final SSHCommandResult defaultResult;

  final SSHCommandResult? Function(MockExecCall call)? onExecute;
  final CommandStreamHandle Function(MockStreamCall call)? onStream;

  final List<MockExecCall> calls = [];
  final List<MockStreamCall> streamCalls = [];

  MockExecutor({
    SSHCommandResult? defaultResult,
    this.onExecute,
    this.onStream,
  }) : defaultResult = defaultResult ??
            const SSHCommandResult(exitCode: 0, stdout: '', stderr: '');

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
    final call = MockExecCall(
      repoPath: repoPath,
      gitArgs: gitArgs,
      extraEnv: extraEnv,
      stdin: stdin,
      timeout: timeout,
      retries: retries,
      lane: lane,
      compress: compress,
    );
    calls.add(call);
    final result = onExecute?.call(call);
    if (result != null) return result;
    return defaultResult;
  }

  @override
  Future<SSHStreamHandle> executeStream({
    required String repoPath,
    required List<String> gitArgs,
    Map<String, String>? extraEnv,
    Duration openTimeout = SSHCommandExecutor.defaultTimeout,
  }) async {
    final call = MockStreamCall(
      repoPath: repoPath,
      gitArgs: gitArgs,
      extraEnv: extraEnv,
      openTimeout: openTimeout,
    );
    streamCalls.add(call);
    final result = onStream?.call(call);
    if (result != null) return result;
    throw UnimplementedError('MockExecutor.executeStream not configured');
  }

  @override
  Future<void> uploadBytes(String remotePath, Uint8List bytes, {String? routingRepo}) async {}

  @override
  void configureEnvironment({
    String? path,
    Map<String, String> binaries = const {},
  }) {}

  @override
  String? resolvedBinaryPath(String name) => null;

  @override
  void setForgeTokenNeutralization(Iterable<String> vars) {}

  @override
  void resetEnvironment() {}

  /// Convenience: returns the first call's `gitArgs`, or null if none.
  List<String>? get lastArgs => calls.isEmpty ? null : calls.last.gitArgs;

  /// Convenience: returns the first call's `gitArgs`, or null if none.
  List<String>? get firstArgs => calls.isEmpty ? null : calls.first.gitArgs;
}
