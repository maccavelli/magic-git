import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../exec/command_drain.dart';
import '../ssh/shell_escaper.dart';
import '../ssh/ssh_command_executor.dart' show CommandExecutor, ExecLane;

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
      final fromHeader = header.substring(0, header.length - ' missing'.length);
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
  // printf '%s\n' a b c | git cat-file --batch, base64'd for transport.
  //
  // The base64 is what makes this binary-safe. The executor decodes stdout as
  // UTF-8 with `allowMalformed: true`, so raw object bytes came back with every
  // invalid sequence replaced by U+FFFD — and because the parser frames objects
  // by git's own byte COUNT, a single bad byte desynced every later object in
  // the batch and silently returned the wrong content for the wrong key
  // (0022 M10).
  //
  // git writes to a temp file first so the exit status stays git's: a pipeline
  // reports its LAST command's status, so piping straight into base64 would
  // turn a failed cat-file into exit 0 with empty output — a silent "no such
  // object" (the same trap readFileBase64 documents).
  final args = specs.map(ShellEscaper.escape).join(' ');
  return 'tmp=\$(mktemp) || exit 1; '
      "printf '%s\\n' $args | git cat-file --batch > \"\$tmp\" || "
      '{ rm -f "\$tmp"; exit 65; }; '
      "base64 < \"\$tmp\" | tr -d '\\r\\n'; rm -f \"\$tmp\"";
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
    // The caller's scope overlay for [repoPath] (GIT_DIR/GIT_WORK_TREE for a
    // scoped work-tree repo) — this class has no scope registry of its own.
    Map<String, String>? extraEnv,
    Future<String> Function(String repoPath, String rev, String path)? showOne,
  }) async {
    if (keys.isEmpty) return {};
    if (keys.length == 1 && showOne != null) {
      final k = keys.first;
      final text = await showOne(repoPath, k.rev, k.path);
      return {k: Uint8List.fromList(utf8.encode(text))};
    }

    final specs = [for (final k in keys) '${k.rev}:${k.path}'];
    try {
      final script = catFileBatchScript(specs);
      final result = await _executor.execute(
        repoPath: repoPath,
        extraEnv: extraEnv,
        gitArgs: ['sh', '-c', script],
        lane: ExecLane.read,
        compress: true,
        retries: 1,
      );
      if (!result.isSuccess) {
        throw StateError('cat-file batch exit ${result.exitCode}');
      }
      // Real bytes, recovered from the base64 the script emits — NOT a
      // re-encode of the lossily-decoded stdout, which is not length-preserving
      // and desynced the whole batch (0022 M10).
      final raw = base64.decode(result.stdout.trim());
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
