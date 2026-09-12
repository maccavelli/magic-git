import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../output/output_log.dart';

/// Launches a command. Injected so a test can assert what *would* be launched
/// without launching it; production passes [Process.run].
typedef LaunchRunner =
    Future<ProcessResult> Function(String executable, List<String> arguments);

/// macOS could not open the paths at all: no application is registered for the
/// type, and the default text editor did not take them either.
///
/// Thrown rather than discarded. A failed `open` used to be dropped on the
/// floor — the menu item did nothing, said nothing, and logged nothing — which
/// is the silent-fail class 0004 H4 exists to kill.
class FileOpenException implements Exception {
  const FileOpenException(this.paths, this.detail);

  final List<String> paths;
  final String detail;

  @override
  String toString() {
    final what = paths.length == 1 ? paths.single : '${paths.length} files';
    return detail.isEmpty
        ? 'Could not open $what.'
        : 'Could not open $what: $detail';
  }
}

class FileActions {
  const FileActions({this.launch = Process.run, this.onNotice});

  /// How a command is launched — see [LaunchRunner].
  final LaunchRunner launch;

  /// Where "your chosen application could not be used" goes. Optional: the
  /// file still opened, so this is news rather than an error (MADR 0048).
  final void Function(String message)? onNotice;

  /// Reveals [absolutePath] in Finder, with it selected. Local-machine only —
  /// callers must gate this behind the active connection being local (an SSH
  /// repo's files live on the remote host's disk, not this one).
  ///
  /// Deliberately not configurable: Finder is the file manager, and revealing
  /// implies no choice of application.
  Future<void> revealInFinder(String absolutePath) =>
      launch('open', ['-R', absolutePath]);

  /// Opens each of [absolutePaths] in [bundleId] when one is chosen, and
  /// otherwise in **the user's own default application for that file type** —
  /// plain `open <path>`, exactly what double-clicking in Finder does.
  /// Local-machine only; see [revealInFinder].
  ///
  /// No application is ever pinned in code. `-a 'Visual Studio Code'` was
  /// pinned in `5e93607` and is wrong twice over: it imposes one contributor's
  /// editor on every user, and on a Mac without VS Code `open` exits non-zero,
  /// so the action opened nothing whatsoever — silently, because the result was
  /// discarded.
  ///
  /// The chain, each step taken only when the one before exits non-zero:
  ///
  /// 1. `open -b <bundleId>` — the chosen application, by identity, so the
  ///    choice survives it being moved or renamed (MADR 0048 F4);
  /// 2. `open` — the per-type default;
  /// 3. `open -t` — the default *text* editor, which covers a type with no
  ///    registered handler at all (an extensionless `LICENSE`);
  /// 4. [FileOpenException].
  ///
  /// A chosen application that did not take the files is reported through
  /// [onNotice] **once**, and only when a later step succeeded: if nothing
  /// opened, the thrown exception is the whole story.
  Future<void> openFiles(
    List<String> absolutePaths, {
    String bundleId = '',
  }) async {
    if (absolutePaths.isEmpty) return;

    var chosenFailed = false;
    if (bundleId.isNotEmpty) {
      final chosen = await launch('open', ['-b', bundleId, ...absolutePaths]);
      if (chosen.exitCode == 0) return;
      chosenFailed = true;
    }

    final byType = await launch('open', absolutePaths);
    if (byType.exitCode == 0) {
      _noteChosenUnused(chosenFailed, bundleId);
      return;
    }

    final asText = await launch('open', ['-t', ...absolutePaths]);
    if (asText.exitCode == 0) {
      _noteChosenUnused(chosenFailed, bundleId);
      return;
    }

    throw FileOpenException(absolutePaths, _detail(byType, asText));
  }

  /// Opens Terminal.app at [path].
  ///
  /// **Deliberately not configurable** (MADR 0048 amendment 0048.1). Handing a
  /// directory to an arbitrary terminal is not a contract: `open` passes it as
  /// a trailing argument, and a terminal that reads trailing arguments as a
  /// command — WezTerm does — rejects it and exits, which looks like a window
  /// flashing open and closing. Terminal.app accepts a directory and is the one
  /// terminal macOS guarantees is present.
  ///
  /// The exit status is checked, unlike the `Process.run` this replaces:
  /// `open` reports "no such application" by exiting non-zero rather than by
  /// throwing, so the old form could fail in complete silence (MADR 0048 F3).
  /// Note it reports only that Launch Services *dispatched* — an application
  /// that starts and then exits still yields 0.
  Future<void> openInTerminal(String path) async {
    final result = await launch('open', ['-a', 'Terminal', path]);
    if (result.exitCode == 0) return;
    throw FileOpenException([path], '${result.stderr}'.trim());
  }

  /// Copies [text] to the system clipboard.
  Future<void> copyToClipboard(String text) =>
      Clipboard.setData(ClipboardData(text: text));

  void _noteChosenUnused(bool chosenFailed, String bundleId) {
    if (!chosenFailed) return;
    onNotice?.call(
      'Could not open with $bundleId — used the system default instead.',
    );
  }

  static String _detail(ProcessResult byType, ProcessResult asText) {
    final first = '${byType.stderr}'.trim();
    final second = '${asText.stderr}'.trim();
    return [
      if (first.isNotEmpty) first,
      if (second.isNotEmpty && second != first) second,
    ].join('; ');
  }
}

final fileActionsProvider = Provider<FileActions>(
  (ref) => FileActions(
    // "Your chosen application could not be used" is news rather than a
    // failure — the file did open — so it goes to the Output pane instead of
    // interrupting a successful action with a dialog.
    onNotice: (message) =>
        ref.read(outputLogProvider.notifier).logError('open file', message),
  ),
);

/// Backward compatibility for callers not using the provider yet
Future<void> revealInFinder(String absolutePath) =>
    const FileActions().revealInFinder(absolutePath);
Future<void> openFiles(List<String> absolutePaths) =>
    const FileActions().openFiles(absolutePaths);
Future<void> copyToClipboard(String text) =>
    const FileActions().copyToClipboard(text);
