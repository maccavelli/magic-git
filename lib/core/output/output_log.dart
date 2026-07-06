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

  /// Logs a command that failed before producing a result (timeout, non-git
  /// error, …).
  void logError(String command, String message) {
    _add([
      OutputLine('\$ $command', OutputLineKind.command),
      ..._split(message, OutputLineKind.error),
    ]);
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

final outputLogProvider = NotifierProvider<OutputLogNotifier, OutputLogState>(
  OutputLogNotifier.new,
);
