import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/providers/app_providers.dart';
import 'file_content.dart';

/// A file's working-tree contents, read via `GitService.readFile` (a plain
/// `cat` — identical local and over SSH) and classified into text / binary /
/// too-large for the viewer. Keyed by (repoPath, path).
///
/// Plain `autoDispose` (no keep-alive cache): file contents can be large, so
/// freeing them the moment the viewer window closes is the right default — a
/// reopen costs one cheap `cat`. The `FutureProvider` still memoizes the
/// classification for as long as a window keeps it watched, so rebuilds don't
/// re-scan.
final fileContentProvider = FutureProvider.autoDispose
    .family<FileContent, (String, String)>((ref, key) async {
      final (repoPath, path) = key;
      final raw = await ref.watch(gitServiceProvider).readFile(repoPath, path);
      return FileContent.classify(raw);
    });
