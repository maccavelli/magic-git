import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
  const FileActions({this.launch = Process.run});

  /// How a command is launched — see [LaunchRunner].
  final LaunchRunner launch;

  /// Reveals [absolutePath] in Finder, with it selected. Local-machine only —
  /// callers must gate this behind the active connection being local (an SSH
  /// repo's files live on the remote host's disk, not this one).
  Future<void> revealInFinder(String absolutePath) =>
      launch('open', ['-R', absolutePath]);

  /// Opens each of [absolutePaths] in **the user's own default application for
  /// that file type** — plain `open <path>`, which is exactly what
  /// double-clicking the file in Finder does. Local-machine only; see
  /// [revealInFinder].
  ///
  /// No editor is pinned here, deliberately. `-a 'Visual Studio Code'` was
  /// pinned in `5e93607` and is wrong twice over: it imposes one contributor's
  /// editor on every user, and on a Mac without VS Code installed `open` exits
  /// non-zero — so the action opened nothing whatsoever, silently, because the
  /// result was discarded. Which editor a `.dart` or `.md` file belongs to is
  /// the user's choice, already expressed in Launch Services, and this is the
  /// call that honours it.
  ///
  /// `open -t` is the fallback for the one case the default-app path genuinely
  /// cannot serve: a type with no registered handler at all (an extensionless
  /// `LICENSE`, say), where `open` fails rather than guessing. `-t` is the
  /// user's default *text* editor — still their choice, not ours.
  Future<void> openFiles(List<String> absolutePaths) async {
    if (absolutePaths.isEmpty) return;
    final byType = await launch('open', absolutePaths);
    if (byType.exitCode == 0) return;
    final asText = await launch('open', ['-t', ...absolutePaths]);
    if (asText.exitCode == 0) return;
    throw FileOpenException(absolutePaths, _detail(byType, asText));
  }

  /// Copies [text] to the system clipboard.
  Future<void> copyToClipboard(String text) =>
      Clipboard.setData(ClipboardData(text: text));

  static String _detail(ProcessResult byType, ProcessResult asText) {
    final first = '${byType.stderr}'.trim();
    final second = '${asText.stderr}'.trim();
    return [
      if (first.isNotEmpty) first,
      if (second.isNotEmpty && second != first) second,
    ].join('; ');
  }
}

final fileActionsProvider = Provider<FileActions>((ref) => const FileActions());

/// Backward compatibility for callers not using the provider yet
Future<void> revealInFinder(String absolutePath) =>
    const FileActions().revealInFinder(absolutePath);
Future<void> openFiles(List<String> absolutePaths) =>
    const FileActions().openFiles(absolutePaths);
Future<void> copyToClipboard(String text) =>
    const FileActions().copyToClipboard(text);
