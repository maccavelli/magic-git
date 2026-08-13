/// Wire codec for proxying `CommandExecutor.execute` calls from a secondary
/// window's isolate to the main isolate over that window's per-window hub
/// method channel, plus the [WindowDescriptor] a child pulls at boot.
///
/// Pure Dart by design — no channel imports — so every encode/decode pair is
/// unit-testable without platform machinery. All payloads are
/// `Map<String, Object?>` of StandardMethodCodec-safe values (String, int,
/// bool, List, Map); enums travel by `.name`, Durations as milliseconds.
///
/// Command **text payloads travel as UTF-8 bytes (`Uint8List`), never as
/// strings**: git output routinely contains embedded NULs (`status -z`,
/// `check-ignore -z`, binary diffs), and while Dart's own StandardMethodCodec
/// round-trips U+0000 in a string faithfully, the native ObjC codec the
/// window relay hops through does not — everything after the first NUL is
/// lost. That truncation silently beheaded the combined status/refs snapshot
/// (whose first section is NUL-delimited porcelain) on every secondary-window
/// fetch, which is why the History pop-out never showed ref decorations.
/// Typed data is length-prefixed raw bytes in every codec implementation, so
/// it is immune by construction. Applies to stdout/stderr (response) and
/// stdin (request); argv/env strings cannot contain NUL by OS contract and
/// stay strings.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../ssh/ssh_command_executor.dart';

/// Encodes command text for the wire — see the library doc for why bytes.
Uint8List _wireBytes(String text) => Uint8List.fromList(utf8.encode(text));

/// Decodes wire text: bytes from a current peer; a plain string is accepted
/// as a defensive fallback (both engines always run the same binary, so this
/// only matters to hand-built test payloads). Malformed sequences are
/// replaced rather than thrown — the executor's own decoding posture.
String _wireText(Object? value) => switch (value) {
  final Uint8List bytes => const Utf8Decoder(
    allowMalformed: true,
  ).convert(bytes),
  final String text => text,
  _ => '',
};

/// The identity a secondary window's child isolate pulls from native at boot
/// (over the bootstrap channel): which window it is and what to render. The
/// per-window hub/lifecycle channel names are DERIVED from [windowId] via
/// `window_channels.dart` rather than carried here, so this codec stays pure
/// (no channel-name knowledge) and there is one owner of the naming scheme.
class WindowDescriptor {
  /// Dart-minted, stable for this window's whole life. Names its channels.
  final String windowId;

  /// [WindowKind] name (`history` / `detachedRepo`) — the wire discriminator.
  final String kind;

  /// The repo this window is pinned to for repo-bound kinds; null for History
  /// (which follows the active session and learns its repo via `requestState`).
  final String? repoPath;

  /// Initial native window title (native reveals with this; the child may push
  /// a refined one via `setWindowTitle`).
  final String? title;

  /// The active connection's label at open time, for the initial title.
  final String? connectionLabel;

  const WindowDescriptor({
    required this.windowId,
    required this.kind,
    this.repoPath,
    this.title,
    this.connectionLabel,
  });

  Map<String, Object?> encode() => {
    'windowId': windowId,
    'kind': kind,
    'repoPath': repoPath,
    'title': title,
    'connectionLabel': connectionLabel,
  };

  static WindowDescriptor decode(Map<Object?, Object?> map) => WindowDescriptor(
    windowId: map['windowId'] as String? ?? '',
    kind: map['kind'] as String? ?? '',
    repoPath: map['repoPath'] as String?,
    title: map['title'] as String?,
    connectionLabel: map['connectionLabel'] as String?,
  );
}

/// One `execute()` call's parameters, typed. Mirrors
/// [CommandExecutor.execute]'s signature exactly.
class ExecuteRequest {
  final String repoPath;
  final List<String> gitArgs;
  final Map<String, String>? extraEnv;
  final String? stdin;
  final Duration timeout;
  final int retries;
  final ExecLane lane;
  final bool compress;
  final OperationDescriptor? operation;

  const ExecuteRequest({
    required this.repoPath,
    required this.gitArgs,
    this.extraEnv,
    this.stdin,
    required this.timeout,
    required this.retries,
    required this.lane,
    required this.compress,
    this.operation,
  });
}

Map<String, Object?> encodeExecuteRequest(ExecuteRequest request) => {
  'repoPath': request.repoPath,
  'gitArgs': request.gitArgs,
  'extraEnv': request.extraEnv,
  // Bytes, not a string: stdin may be NUL-delimited (`check-ignore -z`).
  'stdin': request.stdin == null ? null : _wireBytes(request.stdin!),
  'timeoutMs': request.timeout.inMilliseconds,
  'retries': request.retries,
  'lane': request.lane.name,
  'compress': request.compress,
  'operation': request.operation?.toWire(),
};

ExecuteRequest decodeExecuteRequest(Map<Object?, Object?> map) {
  // An unknown lane name (a version-skewed sender) degrades to exclusive —
  // the documented safe default for anything that doesn't declare otherwise.
  final laneName = map['lane'] as String? ?? '';
  final lane = ExecLane.values.asNameMap()[laneName] ?? ExecLane.exclusive;
  return ExecuteRequest(
    repoPath: map['repoPath'] as String,
    gitArgs: (map['gitArgs'] as List).cast<String>(),
    extraEnv: (map['extraEnv'] as Map?)?.cast<String, String>(),
    stdin: map['stdin'] == null ? null : _wireText(map['stdin']),
    timeout: Duration(milliseconds: map['timeoutMs'] as int),
    retries: map['retries'] as int? ?? 0,
    lane: lane,
    compress: map['compress'] as bool? ?? false,
    operation: OperationDescriptor.fromWire(map['operation']),
  );
}

Map<String, Object?> encodeExecuteResult(SSHCommandResult result) => {
  'ok': true,
  'exitCode': result.exitCode,
  // Bytes, not strings — NUL-bearing output must survive the native hop
  // (see the library doc; this is what broke the pop-out's snapshot).
  'stdout': _wireBytes(result.stdout),
  'stderr': _wireBytes(result.stderr),
  'operationId': result.operationId?.value,
};

/// Encodes a thrown error into the failure envelope. The three typed executor
/// exceptions keep their identity (each carries only a command string, so
/// they reconstruct losslessly on the other side); anything else degrades to
/// `other` with its message.
Map<String, Object?> encodeExecuteError(Object error) => switch (error) {
  SSHCommandTimeout(:final command) => {
    'ok': false,
    'error': 'timeout',
    'command': command,
  },
  SSHCommandSuperseded(:final command) => {
    'ok': false,
    'error': 'superseded',
    'command': command,
  },
  SSHOutputExceeded(:final command) => {
    'ok': false,
    'error': 'outputExceeded',
    'command': command,
  },
  _ => {'ok': false, 'error': 'other', 'message': error.toString()},
};

/// Decodes the response envelope: a success becomes an [SSHCommandResult];
/// a failure re-throws the original exception *type* — callers above the
/// executor pattern-match on [SSHCommandTimeout]/[SSHCommandSuperseded]/
/// [SSHOutputExceeded], so preserving the type is the contract. `other`
/// failures become [ProxyExecuteException].
SSHCommandResult decodeExecuteResponse(Map<Object?, Object?> map) {
  if (map['ok'] == true) {
    return SSHCommandResult(
      exitCode: map['exitCode'] as int,
      stdout: _wireText(map['stdout']),
      stderr: _wireText(map['stderr']),
      operationId: switch (map['operationId']) {
        final String value when value.isNotEmpty => OperationId(value),
        _ => null,
      },
    );
  }
  final command = map['command'] as String? ?? '';
  switch (map['error']) {
    case 'timeout':
      throw SSHCommandTimeout(command);
    case 'superseded':
      throw SSHCommandSuperseded(command);
    case 'outputExceeded':
      throw SSHOutputExceeded(command);
    default:
      throw ProxyExecuteException(
        map['message'] as String? ?? 'unknown proxy error',
      );
  }
}

/// A main-isolate failure that has no typed equivalent (or a broken bridge).
/// Shown to the user verbatim by the standard error dialogs, so the message
/// carries everything known.
class ProxyExecuteException implements Exception {
  final String message;
  const ProxyExecuteException(this.message);

  @override
  String toString() => message;
}

/// One `uploadBytes` call's parameters for the secondary-window hub.
class UploadBytesRequest {
  final String remotePath;
  final Uint8List bytes;

  /// Session-routing key (repo the main isolate must own) — see
  /// [CommandExecutor.uploadBytes] `routingRepo`.
  final String routingRepo;

  const UploadBytesRequest({
    required this.remotePath,
    required this.bytes,
    required this.routingRepo,
  });
}

Map<String, Object?> encodeUploadBytesRequest(UploadBytesRequest request) => {
  'remotePath': request.remotePath,
  'bytes': request.bytes,
  'routingRepo': request.routingRepo,
};

UploadBytesRequest decodeUploadBytesRequest(Map<Object?, Object?> map) {
  final raw = map['bytes'];
  final Uint8List bytes = switch (raw) {
    final Uint8List b => b,
    final List<int> list => Uint8List.fromList(list),
    _ => Uint8List(0),
  };
  return UploadBytesRequest(
    remotePath: map['remotePath'] as String? ?? '',
    bytes: bytes,
    routingRepo: map['routingRepo'] as String? ?? '',
  );
}

/// Success envelope for uploadBytes (void on the real executor).
Map<String, Object?> encodeUploadBytesResult() => {'ok': true};

/// Failure envelope — reuses execute error tags where meaningful.
Map<String, Object?> encodeUploadBytesError(Object error) =>
    encodeExecuteError(error);

/// Decodes an uploadBytes reply: returns on success, throws on failure.
void decodeUploadBytesResponse(Map<Object?, Object?> map) {
  if (map['ok'] == true) return;
  // Reuse execute decoder by forcing a throw path.
  decodeExecuteResponse(map);
}

/// The connection snapshot pushed to (and requested by) the History window.
/// Phase/backend stay raw enum *names* here — the codec must not drag the
/// provider layer in; each side converts with its own enums in scope.
class ConnectionEventPayload {
  final String phase;
  final String backend;
  final String? repoPath;
  final String? connectionLabel;
  final String? host;

  const ConnectionEventPayload({
    required this.phase,
    required this.backend,
    this.repoPath,
    this.connectionLabel,
    this.host,
  });

  Map<String, Object?> encode() => {
    'phase': phase,
    'backend': backend,
    'repoPath': repoPath,
    'connectionLabel': connectionLabel,
    'host': host,
  };

  static ConnectionEventPayload decode(Map<Object?, Object?> map) =>
      ConnectionEventPayload(
        phase: map['phase'] as String? ?? '',
        backend: map['backend'] as String? ?? '',
        repoPath: map['repoPath'] as String?,
        connectionLabel: map['connectionLabel'] as String?,
        host: map['host'] as String?,
      );
}
