// Test doubles for the dartssh2 surface `SSHCommandExecutor` actually uses.
//
// The executor only ever calls `client.execute(...)` and then works the
// returned session: it drains `stdout`/`stderr`, feeds `stdin` (sideloads),
// calls `flush()`, and awaits `waitForExit()`. These fakes make that path
// drivable without a socket, a server, or `/usr/sbin/sshd`, so the lane
// routing, the busy split, the activity deadline and the stdin order can each
// be asserted as behaviour rather than read off the source.
//
// [FakeSshClient] *extends* SSHClient rather than implementing it.
// `implements` would mean stubbing ~45 public members (22 final fields, 6
// getters, 17 methods). Extending inherits all of them and needs only
// `execute` and a few lifecycle members overridden — dartssh2 3.3.0's
// constructor just builds an `SSHTransport`, which listens on the socket
// stream and writes a version banner. It schedules no timers, so nothing is
// left pending at teardown.
//
// [FakeSshSession] must `implements SSHSession`: the production constructor
// requires an `SSHChannel`, which cannot be built without a live connection.

import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

/// A socket that swallows the handshake bytes dartssh2 writes on construction
/// and never answers. [done] completes only on [destroy], so the transport
/// neither closes nor errors on its own.
class NullSshSocket implements SSHSocket {
  final StreamController<Uint8List> _incoming = StreamController<Uint8List>();
  final StreamController<List<int>> _outgoing = StreamController<List<int>>();
  final Completer<void> _done = Completer<void>();

  @override
  Stream<Uint8List> get stream => _incoming.stream;

  @override
  StreamSink<List<int>> get sink => _outgoing.sink;

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> close() async => destroy();

  @override
  void destroy() {
    if (!_done.isCompleted) _done.complete();
    _incoming.close().ignore();
    _outgoing.close().ignore();
  }

  @override
  Future<void> flush() async {}
}

/// Records the order of the stdin operations the executor performs.
///
/// `addStream` must stay distinguishable from `add`: streaming the payload is
/// exactly what 0014 T7 changed, and a regression to a single buffered
/// `write`/`add` has to be visible here.
class RecordingStdin implements StreamSink<Uint8List> {
  RecordingStdin(this._ops);

  final List<String> _ops;
  final Completer<void> _done = Completer<void>();
  final BytesBuilder _received = BytesBuilder(copy: false);

  /// Everything written, in order, whatever path it took.
  Uint8List get bytes => Uint8List.fromList(_received.toBytes());

  @override
  void add(Uint8List data) {
    _ops.add('add');
    _received.add(data);
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {
    _ops.add('addError');
  }

  @override
  Future<void> addStream(Stream<Uint8List> stream) async {
    _ops.add('addStream');
    await for (final chunk in stream) {
      _received.add(chunk);
    }
  }

  @override
  Future<void> close() async {
    _ops.add('close');
    if (!_done.isCompleted) _done.complete();
  }

  @override
  Future<void> get done => _done.future;
}

/// A session whose streams and exit code the test drives directly.
class FakeSshSession implements SSHSession {
  FakeSshSession({
    StreamController<Uint8List>? stdout,
    StreamController<Uint8List>? stderr,
    Completer<int?>? exit,
  }) : _stdout = stdout ?? StreamController<Uint8List>(),
       _stderr = stderr ?? StreamController<Uint8List>(),
       _exit = exit ?? Completer<int?>() {
    _stdin = RecordingStdin(stdinOps);
    if (stdout == null) _stdout.close().ignore();
    if (stderr == null) _stderr.close().ignore();
    if (exit == null) _exit.complete(0);
  }

  /// `'addStream'` / `'add'` / `'write'` / `'flush'` / `'close'`, in the order
  /// the executor performed them.
  final List<String> stdinOps = [];

  // Closed in the constructor when this session owns them; when a test
  // injects controllers to drive the streams, the test owns the closing.
  // ignore: close_sinks
  final StreamController<Uint8List> _stdout;
  // ignore: close_sinks
  final StreamController<Uint8List> _stderr;
  final Completer<int?> _exit;
  // The executor closes stdin itself — that close is the behaviour under test.
  // ignore: close_sinks
  late final RecordingStdin _stdin;

  /// The bytes that reached stdin, whichever path they took.
  Uint8List get stdinBytes => _stdin.bytes;

  @override
  StreamSink<Uint8List> get stdin => _stdin;

  @override
  Stream<Uint8List> get stdout => _stdout.stream;

  @override
  Stream<Uint8List> get stderr => _stderr.stream;

  @override
  Future<void> flush() async => stdinOps.add('flush');

  /// Records rather than throws: a regression from `addStream` back to a
  /// single buffered write must show up in [stdinOps], not as a crash that
  /// could be mistaken for an unrelated fake limitation.
  @override
  void write(Uint8List data) => stdinOps.add('write');

  @override
  Future<int?> waitForExit({Duration? timeout}) {
    final wait = _exit.future;
    return timeout == null
        ? wait
        : wait.timeout(timeout, onTimeout: () => null);
  }

  @override
  void close() => _completeExit(null);

  @override
  void kill(SSHSignal signal) => _completeExit(null);

  void _completeExit(int? code) {
    if (!_exit.isCompleted) _exit.complete(code);
  }

  @override
  int? get exitCode => _exit.isCompleted ? 0 : null;

  @override
  SSHSessionExitSignal? get exitSignal => null;

  @override
  Future<void> get done => _exit.future;

  /// Typed `Never` rather than `SSHChannel`: the class is not exported from
  /// `package:dartssh2`, and `Never` is a subtype of every type, so this is a
  /// valid override without reaching into the package's `src/`. The executor
  /// never touches it.
  @override
  Never get channel =>
      throw UnimplementedError('FakeSshSession exposes no channel');

  @override
  void resizeTerminal(
    int width,
    int height, [
    int pixelWidth = 0,
    int pixelHeight = 0,
  ]) {}
}

/// A client that hands out [FakeSshSession]s and records what it was asked to
/// run. Identity matters: tests assert *which* client object a lane used.
class FakeSshClient extends SSHClient {
  FakeSshClient({this.hangExecute = false})
    : super(
        NullSshSocket(),
        username: 'test',
        // Production connects with keepAlive off (0013/0014); a fake must not
        // reintroduce a timer the real client does not have.
        keepAliveInterval: null,
      );

  /// When true, [execute] never completes until [completeExecute] is called —
  /// the way to hold a command inside `_run` and observe the busy probes.
  final bool hangExecute;

  /// Command strings passed to [execute], in order. These are formatted shell
  /// strings (`cd '<repo>' && …`), not argv — match with `contains`.
  final List<String> executeCommands = [];

  /// Every session handed out, in the same order as [executeCommands].
  final List<FakeSshSession> sessions = [];

  /// Streams/exit for the next session, when a test needs to drive it. The
  /// test that supplies a controller also closes it.
  // ignore: close_sinks
  StreamController<Uint8List>? nextStdout;
  // ignore: close_sinks
  StreamController<Uint8List>? nextStderr;
  Completer<int?>? nextExit;

  Completer<SSHSession>? _hung;
  final Completer<void> _done = Completer<void>();
  bool _closed = false;

  @override
  Future<SSHSession> execute(
    String command, {
    SSHPtyConfig? pty,
    SSHX11Config? x11,
    Map<String, String>? environment,
  }) {
    executeCommands.add(command);
    if (hangExecute) {
      final hung = _hung ??= Completer<SSHSession>();
      return hung.future;
    }
    return Future<SSHSession>.value(_newSession());
  }

  /// Releases a [hangExecute] client, handing the caller a live session.
  FakeSshSession completeExecute() {
    final session = _newSession();
    _hung?.complete(session);
    _hung = null;
    return session;
  }

  FakeSshSession _newSession() {
    final session = FakeSshSession(
      stdout: nextStdout,
      stderr: nextStderr,
      exit: nextExit,
    );
    nextStdout = null;
    nextStderr = null;
    nextExit = null;
    sessions.add(session);
    return session;
  }

  /// Completes [done], the way a dead transport would.
  void killTransport() {
    if (!_done.isCompleted) _done.complete();
  }

  @override
  Future<void> get done => _done.future;

  @override
  bool get isClosed => _closed;

  @override
  Future<void> ping() async {}

  @override
  Future<void> flush() async {}

  @override
  Future<void> close() async {
    _closed = true;
    killTransport();
    socket.destroy();
  }
}
