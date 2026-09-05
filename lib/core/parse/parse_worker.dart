/// A single long-lived isolate that runs the repeated git parses, shared by
/// every [GitService] on the main isolate.
///
/// Replaces four per-call `Isolate.run`s (status, refs, log, blame). Each of
/// those spawned a fresh isolate — a heap and an OS thread — for one parse and
/// tore it down again, and the status/refs pair runs on **every snapshot**, so
/// a single refresh wave could spawn two. Flutter's own guidance is that an
/// isolate is expensive enough to keep rather than recreate; MADR 0025 E counts
/// thirteen `Isolate.run` sites against that.
///
/// Modelled on `features/viewer/highlight_worker.dart`, which made the same
/// change for syntax highlighting: one persistent isolate, request/reply over
/// `SendPort`/`ReceivePort`, serial processing, and a caller-side token for
/// dropping superseded results.
///
/// **One worker, never a pool.** Each isolate costs a heap and an OS thread, so
/// the point of this class is defeated by scaling it out. Requests are handled
/// serially; a large parse briefly delays the next one, which is the trade a
/// warm isolate is bought with.
///
/// **Small parses stay inline.** `GitService` keeps its 32 KiB threshold — the
/// message copy in and the result copy out are not worth it below that.
library;

import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../git/git_service.dart';
import '../utils/git_porcelain_parser.dart';

/// Which parse the worker should run. One entry per **hot repeated** parse
/// migrated off `Isolate.run`; one-shot parses (key decode, gunzip) stay where
/// they are, because serialising them behind this worker would make them worse.
enum ParseJob { status, refs, log, blame }

class _ParseRequest {
  final int id;
  final ParseJob job;
  final String payload;
  const _ParseRequest(this.id, this.job, this.payload);
}

class _ParseResponse {
  final int id;
  final Object? result;
  final String? error;
  const _ParseResponse(this.id, this.result, this.error);
}

/// Runs one job. Top-level so the worker isolate can reach it; every parse it
/// dispatches to is itself top-level and pure.
Object _runJob(ParseJob job, String raw) => switch (job) {
  ParseJob.status => GitPorcelainParser.parseV2(raw),
  ParseJob.refs => parseRefsDetailed(raw),
  ParseJob.log => parseGitLog(raw),
  ParseJob.blame => parseBlame(raw),
};

/// Entry point running in the worker isolate: answers requests until the
/// command port is closed.
///
/// The `catch` is deliberate belt-and-braces rather than a live path: every
/// parser here is total on malformed input by design (they degrade to partial
/// results, they do not throw). It exists so that a future parser which *can*
/// throw fails one request instead of killing a worker the whole app shares.
void _parseIsolateEntry(SendPort toMain) {
  final commands = ReceivePort();
  toMain.send(commands.sendPort);
  commands.listen((message) {
    if (message == null) {
      commands.close();
      return;
    }
    final req = message as _ParseRequest;
    try {
      toMain.send(_ParseResponse(req.id, _runJob(req.job, req.payload), null));
    } catch (e) {
      toMain.send(_ParseResponse(req.id, null, e.toString()));
    }
  });
}

/// Thrown when a parse could not be completed on the worker.
class ParseWorkerException implements Exception {
  final String message;
  const ParseWorkerException(this.message);
  @override
  String toString() => 'ParseWorkerException: $message';
}

/// Main-isolate handle to the shared parse worker.
class ParseWorker {
  /// Isolates spawned over this handle's lifetime. The observable the reuse
  /// property is asserted against.
  int spawnCount = 0;

  int _nextId = 0;

  Isolate? _isolate;
  SendPort? _toWorker;
  ReceivePort? _fromWorker;
  ReceivePort? _onExit;
  Future<void>? _starting;
  final _pending = <int, Completer<Object?>>{};

  Future<void> _ensureStarted() {
    if (_toWorker != null) return Future.value();
    return _starting ??= _start();
  }

  Future<void> _start() async {
    final from = ReceivePort();
    final onExit = ReceivePort();
    _fromWorker = from;
    _onExit = onExit;
    final ready = Completer<SendPort>();
    from.listen((msg) {
      if (msg is SendPort) {
        ready.complete(msg);
        return;
      }
      final resp = msg as _ParseResponse;
      final completer = _pending.remove(resp.id);
      if (completer == null || completer.isCompleted) return;
      if (resp.error != null) {
        completer.completeError(ParseWorkerException(resp.error!));
      } else {
        completer.complete(resp.result);
      }
    });
    // If the worker ever dies, fail everything in flight rather than leaving
    // callers awaiting a reply that can no longer come, and reset so the next
    // call respawns.
    onExit.listen((_) => _handleDeath());
    _isolate = await Isolate.spawn(
      _parseIsolateEntry,
      from.sendPort,
      onExit: onExit.sendPort,
      debugName: 'git-parse',
    );
    spawnCount++;
    _toWorker = await ready.future;
  }

  void _handleDeath() {
    for (final c in _pending.values) {
      if (!c.isCompleted) {
        c.completeError(const ParseWorkerException('parse worker exited'));
      }
    }
    _pending.clear();
    _teardown();
  }

  void _teardown() {
    _fromWorker?.close();
    _onExit?.close();
    _isolate = null;
    _toWorker = null;
    _fromWorker = null;
    _onExit = null;
    _starting = null;
  }

  Future<Object?> _send(ParseJob job, String payload) async {
    await _ensureStarted();
    final id = _nextId++;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    _toWorker!.send(_ParseRequest(id, job, payload));
    return completer.future;
  }

  /// Parses `status --porcelain=v2 -z` output.
  Future<GitStatus> parseStatus(String raw) async =>
      (await _send(ParseJob.status, raw))! as GitStatus;

  /// Parses the `for-each-ref` section, with its non-fatal warnings.
  Future<RefsResult> parseRefs(String raw) async =>
      (await _send(ParseJob.refs, raw))! as RefsResult;

  /// Parses NUL-delimited `git log` output.
  Future<List<GitCommit>> parseLog(String raw) async =>
      (await _send(ParseJob.log, raw))! as List<GitCommit>;

  /// Parses `git blame --porcelain` output.
  Future<List<BlameLine>> parseBlameOutput(String raw) async =>
      (await _send(ParseJob.blame, raw))! as List<BlameLine>;

  /// Kills the live worker so a test can prove the handle recovers rather than
  /// wedging.
  @visibleForTesting
  void debugKillWorker() {
    _isolate?.kill(priority: Isolate.immediate);
    _handleDeath();
  }

  /// Shuts the worker down. Mainly for tests, so an isolate does not outlive
  /// one; production keeps the worker warm for the app's lifetime.
  void dispose() {
    _toWorker?.send(null);
    _isolate?.kill(priority: Isolate.beforeNextEvent);
    for (final c in _pending.values) {
      if (!c.isCompleted) {
        c.completeError(const ParseWorkerException('parse worker disposed'));
      }
    }
    _pending.clear();
    _teardown();
  }
}

/// The process-wide shared parse worker.
final ParseWorker parseWorker = ParseWorker();
