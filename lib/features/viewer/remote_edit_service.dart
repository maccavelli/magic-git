import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/output/output_log.dart';
import '../../core/providers/app_providers.dart';
import '../../core/utils/display_error.dart';
import '../../core/utils/file_actions.dart';

class RemoteEditSession {
  final String repoPath;
  final String relativePath;
  final Directory tempDir;
  final File tempFile;
  final StreamSubscription<FileSystemEvent> subscription;
  String lastKnownHash;

  /// Pending local bytes when a conflict aborted an upload — used by
  /// [RemoteEditManager.forceUploadAfterConflict].
  Uint8List? pendingConflictBytes;

  /// The local bytes whose conflict dialog the user dismissed without
  /// overwriting — the watcher's next debounce of the SAME content must not
  /// re-open the dialog (0009 M24); a genuinely new save clears this.
  Uint8List? declinedConflictBytes;

  RemoteEditSession({
    required this.repoPath,
    required this.relativePath,
    required this.tempDir,
    required this.tempFile,
    required this.subscription,
    required this.lastKnownHash,
  });
}

/// User-visible remote-edit event (H4). AppShell / secondary shell listen and
/// show dialogs or toasts; the output log remains a secondary transcript.
class RemoteEditNotice {
  final String title;
  final String message;

  /// When non-null, the shell may offer "Overwrite remote" for this session key.
  final String? conflictSessionKey;

  const RemoteEditNotice({
    required this.title,
    required this.message,
    this.conflictSessionKey,
  });

  bool get isConflict => conflictSessionKey != null;
}

class RemoteEditNoticeNotifier extends Notifier<RemoteEditNotice?> {
  @override
  RemoteEditNotice? build() => null;

  void show(RemoteEditNotice notice) => state = notice;

  void clear() => state = null;
}

final remoteEditNoticeProvider =
    NotifierProvider<RemoteEditNoticeNotifier, RemoteEditNotice?>(
      RemoteEditNoticeNotifier.new,
    );

class RemoteEditManager extends Notifier<Map<String, RemoteEditSession>> {
  /// Mirror of [state] for teardown: reading `state` inside onDispose trips
  /// Riverpod's life-cycle assertion, so cleanup walks this instead.
  Map<String, RemoteEditSession> _sessions = {};

  @override
  Map<String, RemoteEditSession> build() {
    ref.onDispose(() {
      for (final session in _sessions.values) {
        session.subscription.cancel();
        try {
          session.tempDir.deleteSync(recursive: true);
        } catch (_) {}
      }
      _sessions = {};
    });
    return {};
  }

  Future<String> _getRemoteHash(String repoPath, String path) async {
    final executor = ref.read(activeExecutorProvider);
    final res = await executor.execute(
      repoPath: repoPath,
      gitArgs: ['hash-object', path],
    );
    if (!res.isSuccess) {
      return '';
    }
    return res.stdout.trim();
  }

  /// Never throws: every failure (download, decode, temp-file IO, watch)
  /// lands on [remoteEditNoticeProvider] like the sync path's do — callers
  /// fire-and-forget from tap handlers, so a thrown error would be the
  /// silent-fail class 0004 H4 was meant to kill (0009 H15).
  Future<void> openRemoteFile(String repoPath, String path) async {
    final sessionKey = '$repoPath/$path';
    if (state.containsKey(sessionKey)) {
      // Already editing, just bring it to front or re-open
      unawaited(
        ref.read(fileActionsProvider).openFiles([
          state[sessionKey]!.tempFile.absolute.path,
        ]),
      );
      return;
    }

    Directory? tempDir;
    try {
      // 1. Download bytes from working tree
      final git = ref.read(gitServiceProvider);
      final b64 = await git.readFileBase64(repoPath, path);
      final bytes = base64.decode(b64);

      // 2. Snapshot (hash-object)
      final hash = await _getRemoteHash(repoPath, path);

      // 3. Scratch Dir
      // To preserve the extension and name which helps the IDE with syntax highlighting
      final slashIndex = path.lastIndexOf('/');
      final fileName = slashIndex >= 0 ? path.substring(slashIndex + 1) : path;

      tempDir = Directory.systemTemp.createTempSync('magic_git_edit_');
      final tempFile = File('${tempDir.path}/$fileName');
      tempFile.writeAsBytesSync(bytes);

      // 4. Watch the scratch DIRECTORY, not the file: many editors save via
      // temp + rename (atomic saves), so the original inode never sees a
      // modify event again (0009 M24). The dir is exclusive to this file;
      // only events whose path ends in its name count.
      Timer? debounce;
      bool touchesFile(FileSystemEvent event) =>
          event.path.endsWith('/$fileName') ||
          (event is FileSystemMoveEvent &&
              (event.destination?.endsWith('/$fileName') ?? false));
      final sub = tempDir.watch().listen((event) {
        if (!touchesFile(event)) return;
        debounce?.cancel();
        debounce = Timer(const Duration(milliseconds: 500), () {
          unawaited(_syncFile(repoPath, path, tempFile));
        });
      });

      final session = RemoteEditSession(
        repoPath: repoPath,
        relativePath: path,
        tempDir: tempDir,
        tempFile: tempFile,
        subscription: sub,
        lastKnownHash: hash,
      );

      _sessions = {...state, sessionKey: session};
      state = _sessions;

      // 5. Open in editor
      unawaited(
        ref.read(fileActionsProvider).openFiles([tempFile.absolute.path]),
      );
    } catch (e) {
      try {
        tempDir?.deleteSync(recursive: true);
      } catch (_) {}
      final message = 'Failed to open "$path": ${displayError(e)}';
      ref
          .read(outputLogProvider.notifier)
          .logError('Remote Edit Open Failed', message);
      ref
          .read(remoteEditNoticeProvider.notifier)
          .show(
            RemoteEditNotice(title: 'Remote Edit Open Failed', message: message),
          );
    }
  }

  /// User dismissed a conflict without overwriting — remember the declined
  /// bytes so the watcher's next debounce of the same content doesn't
  /// re-open the dialog (0009 M24).
  void declineConflict(String sessionKey) {
    final session = state[sessionKey];
    if (session == null) return;
    session.declinedConflictBytes = session.pendingConflictBytes;
  }

  static bool _sameBytes(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  Future<void> _syncFile(String repoPath, String path, File tempFile) async {
    final sessionKey = '$repoPath/$path';
    final session = state[sessionKey];
    if (session == null) return;

    try {
      final newBytes = tempFile.readAsBytesSync();

      // Integrity check
      final currentRemoteHash = await _getRemoteHash(repoPath, path);
      if (currentRemoteHash != session.lastKnownHash &&
          currentRemoteHash.isNotEmpty) {
        // The user already declined overwriting exactly this content — do
        // not re-open the dialog on the watcher's next tick (0009 M24).
        final declined = session.declinedConflictBytes;
        if (declined != null && _sameBytes(newBytes, declined)) return;
        session.pendingConflictBytes = newBytes;
        final message =
            'The remote file "$path" changed since you opened it. '
            'Upload aborted to prevent data loss.';
        ref
            .read(outputLogProvider.notifier)
            .logError('Remote Edit Conflict', message);
        ref
            .read(remoteEditNoticeProvider.notifier)
            .show(
              RemoteEditNotice(
                title: 'Remote Edit Conflict',
                message: message,
                conflictSessionKey: sessionKey,
              ),
            );
        return;
      }

      await _upload(session, newBytes);
    } catch (e) {
      final message = 'Failed to sync "$path": ${displayError(e)}';
      ref
          .read(outputLogProvider.notifier)
          .logError('Remote Edit Sync Failed', message);
      ref
          .read(remoteEditNoticeProvider.notifier)
          .show(
            RemoteEditNotice(
              title: 'Remote Edit Sync Failed',
              message: message,
            ),
          );
    }
  }

  Future<void> _upload(RemoteEditSession session, List<int> newBytes) async {
    final bytes = newBytes is Uint8List
        ? newBytes
        : Uint8List.fromList(newBytes);
    final executor = ref.read(activeExecutorProvider);
    await executor.uploadBytes(
      '${session.repoPath}/${session.relativePath}',
      bytes,
      routingRepo: session.repoPath,
    );

    final newHash = await _getRemoteHash(
      session.repoPath,
      session.relativePath,
    );
    session.lastKnownHash = newHash;
    session.pendingConflictBytes = null;
    session.declinedConflictBytes = null;
    ref.invalidate(statusProvider(session.repoPath));
  }

  /// User chose to overwrite the remote after a conflict notice.
  Future<void> forceUploadAfterConflict(String sessionKey) async {
    final session = state[sessionKey];
    if (session == null) return;
    final bytes =
        session.pendingConflictBytes ?? session.tempFile.readAsBytesSync();
    try {
      // Accept current remote as base, then upload local bytes.
      session.lastKnownHash = await _getRemoteHash(
        session.repoPath,
        session.relativePath,
      );
      await _upload(session, bytes);
    } catch (e) {
      final message =
          'Failed to overwrite "${session.relativePath}": ${displayError(e)}';
      ref
          .read(outputLogProvider.notifier)
          .logError('Remote Edit Sync Failed', message);
      ref
          .read(remoteEditNoticeProvider.notifier)
          .show(
            RemoteEditNotice(
              title: 'Remote Edit Sync Failed',
              message: message,
            ),
          );
    }
  }
}

final remoteEditServiceProvider =
    NotifierProvider<RemoteEditManager, Map<String, RemoteEditSession>>(
      RemoteEditManager.new,
    );
