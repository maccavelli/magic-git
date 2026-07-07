/// A single long-lived isolate that syntax-highlights large files, shared by
/// every open [CodeView].
///
/// Replaces a per-file `Isolate.run`, which spawned a fresh isolate for each
/// large file and — because the `re_highlight` engine is a lazy per-isolate
/// global — re-registered all ~39 grammars every time, then copied the source
/// in and the spans back. Here the engine is registered **once**, in one
/// persistent worker, and only the source (in) and spans (out) cross the
/// boundary. Small files still highlight inline on the main isolate (see
/// `CodeView`), where the engine is likewise registered only once; the worker is
/// used solely for the large-file path where the off-thread cost is worth it.
///
/// Requests are processed serially (re_highlight's `highlight` is synchronous
/// and can't be preempted), so a very large file briefly delays another view's
/// highlight — an acceptable trade for one warm isolate over N cold ones.
/// Superseded results are dropped by the caller's own request token; the worker
/// still finishes an in-flight highlight (same as the old `Isolate.run`).
library;

import 'dart:async';
import 'dart:isolate';

import 'syntax_highlighter.dart';

/// A highlight request sent to the worker.
class _HlRequest {
  final int id;
  final String code;
  final String? lang;
  const _HlRequest(this.id, this.code, this.lang);
}

/// The worker's reply: the compact highlighted document for request [id].
class _HlResponse {
  final int id;
  final HighlightedLines doc;
  const _HlResponse(this.id, this.doc);
}

/// Entry point running in the worker isolate. Registers the engine lazily on the
/// first `highlightDoc` call, then answers requests until the command port is
/// closed. A highlight that throws degrades to a plain document rather than
/// killing the isolate, so the worker stays up for the app's lifetime.
void _highlightIsolateEntry(SendPort toMain) {
  final commands = ReceivePort();
  toMain.send(commands.sendPort);
  commands.listen((message) {
    if (message == null) {
      commands.close();
      return;
    }
    final req = message as _HlRequest;
    HighlightedLines doc;
    try {
      doc = highlightDoc(req.code, req.lang);
    } catch (_) {
      doc = plainDoc(req.code);
    }
    toMain.send(_HlResponse(req.id, doc));
  });
}

/// Main-isolate handle to the shared highlight worker. Lazily spawns the isolate
/// on first use and keeps it warm for the app's lifetime (its resident cost is
/// just the registered grammars). Use the shared [highlightWorker] instance.
class HighlightWorker {
  Isolate? _isolate;
  SendPort? _toWorker;
  ReceivePort? _fromWorker;
  ReceivePort? _onExit;
  Future<void>? _starting;
  int _nextId = 0;
  final _pending = <int, Completer<HighlightedLines>>{};

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
      final resp = msg as _HlResponse;
      _pending.remove(resp.id)?.complete(resp.doc);
    });
    // If the worker ever dies unexpectedly, fail any in-flight requests (the
    // caller falls back to plain text) and reset so the next call respawns.
    onExit.listen((_) => _handleDeath());
    _isolate = await Isolate.spawn(
      _highlightIsolateEntry,
      from.sendPort,
      onExit: onExit.sendPort,
      debugName: 'syntax-highlight',
    );
    _toWorker = await ready.future;
  }

  void _handleDeath() {
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(StateError('highlight worker exited'));
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

  /// Highlights [code] as [lang] on the worker, returning the compact document.
  /// Callers guard against a superseded result with their own request token.
  Future<HighlightedLines> highlight(String code, String? lang) async {
    await _ensureStarted();
    final id = _nextId++;
    final completer = Completer<HighlightedLines>();
    _pending[id] = completer;
    _toWorker!.send(_HlRequest(id, code, lang));
    return completer.future;
  }

  /// Shuts the worker down and clears state. Mainly for tests (so an isolate
  /// doesn't outlive the test); production keeps the worker warm.
  void dispose() {
    _toWorker?.send(null);
    _isolate?.kill(priority: Isolate.beforeNextEvent);
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(StateError('highlight worker disposed'));
    }
    _pending.clear();
    _teardown();
  }
}

/// The process-wide shared highlight worker.
final HighlightWorker highlightWorker = HighlightWorker();
