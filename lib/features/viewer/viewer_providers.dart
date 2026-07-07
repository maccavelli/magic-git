import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' show Size;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/providers/app_providers.dart';
import '../../core/ssh/ssh_command_executor.dart';
import 'file_content.dart';
import 'text_decoding.dart';

/// Why a file couldn't be read into the viewer, in terms the UI can act on:
/// [tooLarge] gets the size notice + "open externally" affordance, the rest get
/// a plain "couldn't read this" message.
enum ViewerReadError { tooLarge, timedOut, connectionChanged, unavailable }

/// A read failure translated from the executor's transport-level exceptions
/// (`SSHCommandTimeout`/`SSHOutputExceeded`/`SSHCommandSuperseded`) and
/// `GitException` into one clean, user-facing shape. Without this the viewer's
/// error state would surface raw strings like `"SSH command timed out: cat --
/// path"`.
class ViewerReadException implements Exception {
  final ViewerReadError kind;
  final String message;
  const ViewerReadException(this.kind, this.message);

  @override
  String toString() => message;
}

ViewerReadException _mapReadError(Object e) {
  if (e is ViewerReadException) return e;
  if (e is SSHOutputExceeded) {
    return const ViewerReadException(
      ViewerReadError.tooLarge,
      'This file is too large to open in the viewer.',
    );
  }
  if (e is SSHCommandTimeout) {
    return const ViewerReadException(
      ViewerReadError.timedOut,
      'Timed out reading this file — check your connection and try again.',
    );
  }
  if (e is SSHCommandSuperseded) {
    return const ViewerReadException(
      ViewerReadError.connectionChanged,
      'The connection changed while opening this file — reopen it to try again.',
    );
  }
  return const ViewerReadException(
    ViewerReadError.unavailable,
    "Couldn't read this file. It may have moved, or you may not have "
    'permission to read it.',
  );
}

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
      final git = ref.watch(gitServiceProvider);
      try {
        final raw = await git.readFile(repoPath, path);
        final content = FileContent.classify(raw);
        // A UTF-16/UTF-32 text file (common from Windows tools) has interleaved
        // NUL bytes, so the UTF-8 read misclassifies it as binary. When the
        // decoded prefix carries the tell-tale BOM signature, re-read the raw
        // bytes and decode with the correct codec — but only keep the result if
        // it actually classifies as text, so a genuine binary that happened to
        // start with those bytes stays binary.
        if (content.kind == FileContentKind.binary &&
            hasUtf16Or32BomSignature(raw)) {
          final b64 = await git.readFileBase64(repoPath, path);
          final bytes = base64.decode(b64.replaceAll(RegExp(r'\s'), ''));
          final decoded = decodeUtf16Or32(bytes);
          if (decoded != null) {
            final reclassified = FileContent.classify(decoded);
            if (reclassified.kind == FileContentKind.text) return reclassified;
          }
        }
        return content;
      } catch (e) {
        throw _mapReadError(e);
      }
    });

/// The raw bytes of a (binary, image) file, read via `GitService.readFileBase64`
/// and decoded. Keyed by (repoPath, path). Used by the viewer's image preview;
/// plain `autoDispose` so a possibly-large image is freed when its window
/// closes.
final fileBytesProvider = FutureProvider.autoDispose
    .family<Uint8List, (String, String)>((ref, key) async {
      final (repoPath, path) = key;
      try {
        final b64 = await ref
            .watch(gitServiceProvider)
            .readFileBase64(repoPath, path);
        // `base64` wraps its output (GNU at 76 cols); strip all whitespace
        // before decoding, which is otherwise strict about it.
        return base64.decode(b64.replaceAll(RegExp(r'\s'), ''));
      } catch (e) {
        // A huge image trips the executor's output cap (base64 inflates bytes
        // ~1.37×, so the ceiling bites sooner) — surface it as `tooLarge` so the
        // viewer shows the size notice + open-externally, not a raw error.
        throw _mapReadError(e);
      }
    });

/// The size of the most recently resized viewer window, so a newly opened
/// window reuses it instead of always reverting to the default — session-scoped
/// (in memory), reset on relaunch.
class ViewerLastSize extends Notifier<Size?> {
  @override
  Size? build() => null;

  void set(Size size) => state = size;
}

final viewerLastSizeProvider = NotifierProvider<ViewerLastSize, Size?>(
  ViewerLastSize.new,
);

/// One open file-viewer window: a stable [id] (for widget keys and focus) plus
/// the file it shows.
class ViewerHandle {
  final int id;
  final String repoPath;
  final String path;

  const ViewerHandle({
    required this.id,
    required this.repoPath,
    required this.path,
  });
}

/// The stack of open floating file-viewer windows, front-most last (that
/// ordering is the paint/z-order the host renders). Opening a file already on
/// screen focuses its existing window rather than stacking a duplicate.
class OpenFileViewers extends Notifier<List<ViewerHandle>> {
  int _nextId = 0;

  @override
  List<ViewerHandle> build() => const [];

  /// Opens a viewer for [path] in [repoPath], or brings the existing one to the
  /// front if that exact file is already open. Returns the (new or existing)
  /// window's id.
  int open(String repoPath, String path) {
    for (final v in state) {
      if (v.repoPath == repoPath && v.path == path) {
        focus(v.id);
        return v.id;
      }
    }
    final handle = ViewerHandle(id: _nextId++, repoPath: repoPath, path: path);
    state = [...state, handle];
    return handle.id;
  }

  /// Closes the window with [id] (no-op if already gone).
  void close(int id) => state = [
    for (final v in state)
      if (v.id != id) v,
  ];

  /// Brings the window with [id] to the front of the stack.
  void focus(int id) {
    if (state.isEmpty || state.last.id == id) return;
    ViewerHandle? moved;
    final rest = <ViewerHandle>[];
    for (final v in state) {
      if (v.id == id) {
        moved = v;
      } else {
        rest.add(v);
      }
    }
    if (moved != null) state = [...rest, moved];
  }

  /// Closes the front-most window (⎋). Returns whether one was closed.
  bool closeTop() {
    if (state.isEmpty) return false;
    state = state.sublist(0, state.length - 1);
    return true;
  }

  /// Closes every open window — used when the active repo changes so a stale
  /// repo's files don't linger.
  void closeAll() {
    if (state.isNotEmpty) state = const [];
  }
}

final openFileViewersProvider =
    NotifierProvider<OpenFileViewers, List<ViewerHandle>>(OpenFileViewers.new);
