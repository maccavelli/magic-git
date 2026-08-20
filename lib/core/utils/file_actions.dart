import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class FileActions {
  const FileActions();

  /// Reveals [absolutePath] in Finder, with it selected. Local-machine only —
  /// callers must gate this behind the active connection being local (an SSH
  /// repo's files live on the remote host's disk, not this one).
  Future<void> revealInFinder(String absolutePath) =>
      Process.run('open', ['-R', absolutePath]);

  /// Opens each of [absolutePaths] in its default application. Local-machine
  /// only — see [revealInFinder].
  Future<void> openFiles(List<String> absolutePaths) =>
      Process.run('open', absolutePaths);

  /// Copies [text] to the system clipboard.
  Future<void> copyToClipboard(String text) =>
      Clipboard.setData(ClipboardData(text: text));
}

final fileActionsProvider = Provider<FileActions>((ref) => const FileActions());

/// Backward compatibility for callers not using the provider yet
Future<void> revealInFinder(String absolutePath) =>
    const FileActions().revealInFinder(absolutePath);
Future<void> openFiles(List<String> absolutePaths) =>
    const FileActions().openFiles(absolutePaths);
Future<void> copyToClipboard(String text) =>
    const FileActions().copyToClipboard(text);
