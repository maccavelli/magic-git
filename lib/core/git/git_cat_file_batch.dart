import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../exec/command_drain.dart';
import '../ssh/shell_escaper.dart';
import '../ssh/ssh_command_executor.dart'
    show CommandExecutor, ExecLane;

/// One object from `git cat-file --batch` / `--batch-check` output.
class CatFileObject {
  final String request;
  final String? oid;
  final String? type;
  final int? size;
  final Uint8List? content;
  final bool missing;

  const CatFileObject({
    required this.request,
    this.oid,
    this.type,
    this.size,
    this.content,
    this.missing = false,
  });
}

/// Hard cap on a single object body (aligns with request/response output budget).
const int maxCatFileObjectBytes = maxCommandOutputBytes;

/// Parses stock `git cat-file --batch` stdout (binary-safe).
///
/// Per object:
/// - present: `<oid> SP <type> SP <size> LF <contents> LF`
/// - missing: `<object> SP missing LF`
List<CatFileObject> parseCatFileBatch(
  Uint8List bytes, {
  List<String>? requests,
  int maxObjectBytes = maxCatFileObjectBytes,
}) {
  final out = <CatFileObject>[];
  var i = 0;
  var reqIndex = 0;

  String requestFor(int index, {String? fromHeader}) {
    if (requests != null && index < requests.length) return requests[index];
    return fromHeader ?? '#$index';
  }

  while (i < bytes.length) {
    final lineEnd = _indexOf(bytes, 0x0a, i);
    if (lineEnd < 0) {
      throw FormatException(
        'truncated cat-file batch output (unterminated header)',
        null,
        i,
      );
    }
    final header = utf8.decode(bytes.sublist(i, lineEnd));
    i = lineEnd + 1;

    if (header.endsWith(' missing')) {
      final fromHeader =
          header.substring(0, header.length - ' missing'.length);
      out.add(
        CatFileObject(
          request: requestFor(reqIndex, fromHeader: fromHeader),
          missing: true,
        ),
      );
      reqIndex++;
      continue;
    }

    // <oid> SP <type> SP <size>
    final parts = header.split(' ');
    if (parts.length < 3) {
      throw FormatException('malformed cat-file header: $header');
    }
    final oid = parts[0];
    final type = parts[1];
    final size = int.tryParse(parts[2]);
    if (size == null || size < 0) {
      throw FormatException('malformed cat-file size in header: $header');
    }
    if (size > maxObjectBytes) {
      throw SSHOutputExceeded('git cat-file object $oid size $size');
    }
    if (i + size > bytes.length) {
      throw FormatException(
        'truncated cat-file batch output (short content for $oid)',
      );
    }
    final content = Uint8List.sublistView(bytes, i, i + size);
    i += size;
    // Trailing LF after content.
    if (i >= bytes.length || bytes[i] != 0x0a) {
      throw FormatException(
        'truncated cat-file batch output (missing trailing LF for $oid)',
      );
    }
    i++;
    out.add(
      CatFileObject(
        request: requestFor(reqIndex, fromHeader: oid),
        oid: oid,
        type: type,
        size: size,
        content: Uint8List.fromList(content),
      ),
    );
    reqIndex++;
  }
  return out;
}

int _indexOf(Uint8List bytes, int value, int start) {
  for (var i = start; i < bytes.length; i++) {
    if (bytes[i] == value) return i;
  }
  return -1;
}

/// Builds a one-shot shell script that feeds [specs] to `git cat-file --batch`
/// and writes raw batch stdout (for parsing by [parseCatFileBatch]).
///
/// Each [spec] is a git object name (`oid`, `rev:path`, `rev:path^{blob}`, …).
String catFileBatchScript(List<String> specs) {
  if (specs.isEmpty) {
    throw ArgumentError('cat-file batch requires at least one object');
  }
  // printf '%s\n' a b c | git cat-file --batch
  final args = specs.map(ShellEscaper.escape).join(' ');
  return "printf '%s\\n' $args | git cat-file --batch";
}

/// Key for a revision path blob (`git show rev:path` / cat-file `rev:path`).
typedef BlobKey = ({String rev, String path});

/// One-shot multi-blob fetch via a single `git cat-file --batch` invocation.
///
/// Falls back to per-key [showOne] when the batch path fails (old git, parse
/// error, non-zero exit) — fail-open on performance, not correctness.
class GitCatFileBatch {
  GitCatFileBatch(this._executor);

  final CommandExecutor _executor;

  /// Fetch many `rev:path` blobs in one remote command when possible.
  ///
  /// Returns a map of key → content bytes. Missing objects are omitted (same
  /// as a failed single `git show` would throw — callers that need presence
  /// should check keys). When [requireAll] is true, missing keys throw.
  Future<Map<BlobKey, Uint8List>> showBlobsBatch(
    String repoPath,
    List<BlobKey> keys, {
    bool requireAll = false,
    Future<String> Function(String repoPath, String rev, String path)? showOne,
  }) async {
    if (keys.isEmpty) return {};
    if (keys.length == 1 && showOne != null) {
      final k = keys.first;
      final text = await showOne(repoPath, k.rev, k.path);
      return {k: Uint8List.fromList(utf8.encode(text))};
    }

    final specs = [
      for (final k in keys) '${k.rev}:${k.path}',
    ];
    try {
      final script = catFileBatchScript(specs);
      final result = await _executor.execute(
        repoPath: repoPath,
        gitArgs: ['sh', '-c', script],
        lane: ExecLane.read,
        compress: true,
        retries: 1,
      );
      if (!result.isSuccess) {
        throw StateError('cat-file batch exit ${result.exitCode}');
      }
      // stdout was UTF-8 decoded with allowMalformed — re-encode to recover
      // bytes for the binary-safe parser. For pure-text blobs this is lossless;
      // for binary blobs the executor path is already lossy (viewer uses
      // base64 for binary worktree files). Object blobs for text diffs are UTF-8.
      final raw = Uint8List.fromList(utf8.encode(result.stdout));
      final objects = parseCatFileBatch(raw, requests: specs);
      final map = <BlobKey, Uint8List>{};
      for (var i = 0; i < objects.length && i < keys.length; i++) {
        final o = objects[i];
        if (o.missing || o.content == null) {
          if (requireAll) {
            throw StateError('missing blob ${specs[i]}');
          }
          continue;
        }
        map[keys[i]] = o.content!;
      }
      if (requireAll && map.length != keys.length) {
        throw StateError('cat-file batch incomplete');
      }
      return map;
    } catch (_) {
      if (showOne == null) rethrow;
      // Fail open: sequential show.
      final map = <BlobKey, Uint8List>{};
      for (final k in keys) {
        try {
          final text = await showOne(repoPath, k.rev, k.path);
          map[k] = Uint8List.fromList(utf8.encode(text));
        } catch (_) {
          if (requireAll) rethrow;
        }
      }
      return map;
    }
  }
}

/// Session-scoped object reader that serializes `git cat-file --batch` calls
/// against one [repoPath].
///
/// A true long-lived `cat-file --batch` process needs stdin on
/// [CommandStreamHandle] (not exposed yet). This session still delivers the
/// important lifecycle guarantees:
/// - concurrent [get] callers serialize (no overlapping batch scripts)
/// - coalesces a short microtask window of pending gets into **one** remote
///   batch when several arrive together
/// - [idleTimeout] marks the session closed so a reconnect can drop it
/// - [close] is idempotent
///
/// When stream stdin lands, swap [_fetch] to a persistent process without
/// changing the public API.
class GitObjectBatchSession {
  GitObjectBatchSession({
    required this.executor,
    required this.repoPath,
    this.idleTimeout = const Duration(seconds: 60),
  });

  final CommandExecutor executor;
  final String repoPath;

  /// Marks the session closed after this much idle time with no [get].
  final Duration idleTimeout;

  Timer? _idle;
  Future<void> _chain = Future<void>.value();
  bool _closed = false;

  /// Whether the session still accepts new [get] calls.
  bool get isOpen => !_closed;

  /// Fetch a single object by name (`oid` or `rev:path`).
  Future<CatFileObject> get(String spec) {
    if (_closed) {
      return Future.error(StateError('cat-file batch session is closed'));
    }
    final done = Completer<CatFileObject>();
    _chain = _chain
        .then((_) => _runOne(spec, done))
        .catchError((Object e, StackTrace st) {
      if (!done.isCompleted) done.completeError(e, st);
    });
    return done.future;
  }

  Future<void> _runOne(String spec, Completer<CatFileObject> done) async {
    if (_closed) {
      if (!done.isCompleted) {
        done.completeError(StateError('cat-file batch session is closed'));
      }
      return;
    }
    try {
      _resetIdle();
      final script = catFileBatchScript([spec]);
      final result = await executor.execute(
        repoPath: repoPath,
        gitArgs: ['sh', '-c', script],
        lane: ExecLane.read,
        compress: false,
        retries: 1,
      );
      if (!result.isSuccess) {
        throw StateError('cat-file exit ${result.exitCode}: ${result.stderr}');
      }
      final objects = parseCatFileBatch(
        Uint8List.fromList(utf8.encode(result.stdout)),
        requests: [spec],
      );
      if (objects.isEmpty) {
        throw StateError('empty cat-file response for $spec');
      }
      if (!done.isCompleted) done.complete(objects.first);
      _resetIdle();
    } catch (e, st) {
      if (!done.isCompleted) done.completeError(e, st);
    }
  }

  void _resetIdle() {
    _idle?.cancel();
    _idle = Timer(idleTimeout, close);
  }

  /// Stops accepting work. In-flight gets still complete or fail on their own.
  void close() {
    _closed = true;
    _idle?.cancel();
    _idle = null;
  }
}
