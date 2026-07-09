import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../ssh/ssh_command_executor.dart';

/// Kind of a single output line, used for colouring in the output view.
enum OutputLineKind { command, stdout, stderr, success, error, info }

@immutable
class OutputLine {
  final String text;
  final OutputLineKind kind;
  const OutputLine(this.text, this.kind);
}

@immutable
class OutputLogState {
  /// Whether the output view is shown at the bottom of the repository panel.
  final bool visible;
  final List<OutputLine> lines;

  const OutputLogState({this.visible = false, this.lines = const []});

  OutputLogState copyWith({bool? visible, List<OutputLine>? lines}) =>
      OutputLogState(
        visible: visible ?? this.visible,
        lines: lines ?? this.lines,
      );
}

/// App-wide buffer of operation output shown in the repository panel's output
/// view. Operations (push/pull/sync to start) append their command + stdout/
/// stderr + a status line; the view renders it. Visibility is toggled from the
/// native "View → Show Output View" menu item, so output is always buffered and
/// simply revealed when the view is shown.
class OutputLogNotifier extends Notifier<OutputLogState> {
  /// Retained scrollback cap — oldest lines drop first.
  static const int maxLines = 2000;

  @override
  OutputLogState build() =>
      const OutputLogState(visible: true); // open by default on startup/connect

  void setVisible(bool value) {
    if (state.visible != value) state = state.copyWith(visible: value);
  }

  void toggle() => setVisible(!state.visible);

  void clear() {
    if (state.lines.isNotEmpty) state = state.copyWith(lines: const []);
  }

  void _add(List<OutputLine> incoming) {
    if (incoming.isEmpty) return;
    final existing = state.lines;
    final List<OutputLine> capped;
    if (incoming.length >= maxLines) {
      capped = incoming.sublist(incoming.length - maxLines);
    } else {
      final keepFromExisting = maxLines - incoming.length;
      capped = [
        if (existing.length > keepFromExisting)
          ...existing.sublist(existing.length - keepFromExisting)
        else
          ...existing,
        ...incoming,
      ];
    }
    state = state.copyWith(lines: capped);
  }

  static List<OutputLine> _split(String text, OutputLineKind kind) {
    final normalized = text.replaceAll('\r\n', '\n').trimRight();
    if (normalized.isEmpty) return const [];
    return [for (final l in normalized.split('\n')) OutputLine(l, kind)];
  }

  /// Logs a command and its result: a `$ <command>` header, then its stdout and
  /// stderr, then a success/failure status line. Handles both successful and
  /// failed [SSHCommandResult]s (a failed command's result is carried on the
  /// thrown [GitException]).
  void logResult(String command, SSHCommandResult result) {
    _add([
      OutputLine('\$ $command', OutputLineKind.command),
      ..._split(result.stdout, OutputLineKind.stdout),
      ..._split(result.stderr, OutputLineKind.stderr),
      OutputLine(
        result.isSuccess
            ? '✓ completed'
            : '✗ exited with code ${result.exitCode}',
        result.isSuccess ? OutputLineKind.success : OutputLineKind.error,
      ),
    ]);
  }

  /// Logs a standalone informational line (no `$ command` header) — session
  /// milestones like the connect-stage timing summary.
  void logInfo(String message) => _add(_split(message, OutputLineKind.info));

  /// Logs a command that failed before producing a result (timeout, non-git
  /// error, …).
  void logError(String command, String message) {
    _add([
      OutputLine('\$ $command', OutputLineKind.command),
      ..._split(message, OutputLineKind.error),
    ]);
  }

  /// Begins a live, incrementally-updated transcript for a long-running
  /// command (a streamed `git clone --progress`): logs the `$ <command>`
  /// header now and returns a session whose [OutputStreamSession.append] feeds
  /// decoded chunks as they arrive. The batch APIs above log only finished
  /// results; this is the streaming counterpart the output view tails live.
  OutputStreamSession startStream(String command) {
    _add([OutputLine('\$ $command', OutputLineKind.command)]);
    return OutputStreamSession._(this);
  }

  /// Removes [transient] if it is still identically the last line (the
  /// session's in-place progress line), then appends [incoming] through the
  /// usual cap logic. The identity check is what makes streaming safe under
  /// interleaving: if another logger appended in between, the transient is no
  /// longer last and simply stays as a historical line.
  void _upsertStream(OutputLine? transient, List<OutputLine> incoming) {
    final lines = state.lines;
    if (transient != null &&
        lines.isNotEmpty &&
        identical(lines.last, transient)) {
      state = state.copyWith(lines: lines.sublist(0, lines.length - 1));
    }
    _add(incoming);
  }

  /// Logs the files affected by an operation (from `git diff --name-status`
  /// lines) under a header, one per line, color-coded by change kind. No-op for
  /// an empty list.
  void logFiles(String header, List<String> nameStatus) {
    final files = nameStatus.where((l) => l.trim().isNotEmpty).toList();
    if (files.isEmpty) return;
    final n = files.length;
    _add([
      OutputLine('$header — $n file${n == 1 ? '' : 's'}', OutputLineKind.info),
      for (final l in files) _fileLine(l),
    ]);
  }

  // Renders one `git diff --name-status` line as "  <code> <path>", turning a
  // rename's "R100\told\tnew" into "old → new", colored by the change kind.
  static OutputLine _fileLine(String nameStatus) {
    final parts = nameStatus.split('\t');
    final code = (parts.isNotEmpty && parts.first.isNotEmpty)
        ? parts.first
        : '?';
    final path = parts.length >= 3
        ? '${parts[1]} → ${parts.last}'
        : (parts.length >= 2 ? parts[1] : nameStatus);
    final kind = switch (code[0]) {
      'A' => OutputLineKind.success,
      'D' => OutputLineKind.error,
      'M' || 'T' => OutputLineKind.stderr,
      _ => OutputLineKind.stdout,
    };
    return OutputLine('  ${code.padRight(2)} $path', kind);
  }
}

/// A live command's incremental writer into the output log, created by
/// [OutputLogNotifier.startStream].
///
/// Feed decoded stdout/stderr chunks through [append]; fully terminated lines
/// are appended permanently, while the trailing partial line — with `\r`
/// progress frames (`Receiving objects:  42% …`) collapsed to the text after
/// the last `\r` — renders as a single transient line that is rewritten in
/// place on each chunk. stdout and stderr keep separate partial buffers (they
/// are independent streams whose chunks interleave mid-line); the transient
/// line always shows the most recently active one. Finish with exactly one
/// [close] (or [fail] for a pre-exit error); the session is inert afterwards.
class OutputStreamSession {
  OutputStreamSession._(this._notifier);

  final OutputLogNotifier _notifier;

  /// Un-terminated tail per kind, raw (may still contain `\r` frames).
  final Map<OutputLineKind, String> _partials = {};

  /// The transient line object currently at the end of the log (if any) —
  /// matched by identity in [OutputLogNotifier._upsertStream].
  OutputLine? _transient;

  bool _closed = false;

  void append(String chunk, OutputLineKind kind) {
    if (_closed || chunk.isEmpty) return;
    final combined =
        (_partials[kind] ?? '') + chunk.replaceAll('\r\n', '\n');
    final segments = combined.split('\n');
    _partials[kind] = segments.removeLast();

    final finalized = [
      for (final line in segments) OutputLine(_collapseCr(line), kind),
    ];
    final partialText = _collapseCr(_partials[kind]!);
    final next = partialText.isEmpty ? null : OutputLine(partialText, kind);
    _notifier._upsertStream(_transient, [...finalized, ?next]);
    _transient = next;
  }

  /// Finalizes the transcript: flushes any partial lines, then appends the
  /// status line — `✓ completed` for exit 0, `✗ exited with code N`, or
  /// `✗ terminated` when the process died without an exit code (cancelled).
  void close({int? exitCode}) {
    if (_closed) return;
    _closed = true;
    _notifier._upsertStream(_transient, [
      ..._flushPartials(),
      OutputLine(
        exitCode == 0
            ? '✓ completed'
            : exitCode == null
            ? '✗ terminated'
            : '✗ exited with code $exitCode',
        exitCode == 0 ? OutputLineKind.success : OutputLineKind.error,
      ),
    ]);
    _transient = null;
  }

  /// Finalizes the transcript for a failure that happened before the command
  /// could exit (channel open failure, superseded connection, …).
  void fail(String message) {
    if (_closed) return;
    _closed = true;
    _notifier._upsertStream(_transient, [
      ..._flushPartials(),
      ...OutputLogNotifier._split(message, OutputLineKind.error),
    ]);
    _transient = null;
  }

  List<OutputLine> _flushPartials() {
    final flushed = <OutputLine>[];
    for (final kind in OutputLineKind.values) {
      final text = _collapseCr(_partials[kind] ?? '');
      if (text.isNotEmpty) flushed.add(OutputLine(text, kind));
    }
    _partials.clear();
    return flushed;
  }

  /// A `\r`-carrying segment shows only what a terminal would after the last
  /// carriage return — the final progress frame.
  static String _collapseCr(String line) {
    final i = line.lastIndexOf('\r');
    return i < 0 ? line : line.substring(i + 1);
  }
}

final outputLogProvider = NotifierProvider<OutputLogNotifier, OutputLogState>(
  OutputLogNotifier.new,
);
