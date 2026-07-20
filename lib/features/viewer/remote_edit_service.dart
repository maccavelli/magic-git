import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';


import '../../core/providers/app_providers.dart';
import '../../core/utils/file_actions.dart';
import '../../core/output/output_log.dart';

class RemoteEditSession {
  final String repoPath;
  final String relativePath;
  final Directory tempDir;
  final File tempFile;
  final StreamSubscription<FileSystemEvent> subscription;
  String lastKnownHash;

  RemoteEditSession({
    required this.repoPath,
    required this.relativePath,
    required this.tempDir,
    required this.tempFile,
    required this.subscription,
    required this.lastKnownHash,
  });
}

class RemoteEditManager extends Notifier<Map<String, RemoteEditSession>> {
  @override
  Map<String, RemoteEditSession> build() {
    ref.onDispose(() {
      for (final session in state.values) {
        session.subscription.cancel();
        try {
          session.tempDir.deleteSync(recursive: true);
        } catch (_) {}
      }
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

  Future<void> openRemoteFile(String repoPath, String path) async {
    final sessionKey = '$repoPath/$path';
    if (state.containsKey(sessionKey)) {
      // Already editing, just bring it to front or re-open
      unawaited(openFiles([state[sessionKey]!.tempFile.absolute.path]));
      return;
    }

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
    
    final tempDir = Directory.systemTemp.createTempSync('magic_git_edit_');
    final tempFile = File('${tempDir.path}/$fileName');
    tempFile.writeAsBytesSync(bytes);

    // 4. Watch
    // We'll use a timer to debounce saves
    Timer? debounce;
    final sub = tempFile.watch(events: FileSystemEvent.modify).listen((event) {
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

    state = {...state, sessionKey: session};

    // 5. Open in editor
    unawaited(openFiles([tempFile.absolute.path]));
  }

  Future<void> _syncFile(String repoPath, String path, File tempFile) async {
    final sessionKey = '$repoPath/$path';
    final session = state[sessionKey];
    if (session == null) return;

    try {
      final newBytes = tempFile.readAsBytesSync();
      
      // Integrity check
      final currentRemoteHash = await _getRemoteHash(repoPath, path);
      if (currentRemoteHash != session.lastKnownHash && currentRemoteHash.isNotEmpty) {
        // Conflict! The remote file changed out-of-band.
        ref.read(outputLogProvider.notifier).logError(
          'Remote Edit Conflict', 
          'The remote file "$path" changed since you opened it. Upload aborted to prevent data loss.'
        );
        return;
      }

      // Upload
      final executor = ref.read(activeExecutorProvider);
      await executor.uploadBytes('$repoPath/$path', newBytes);

      // Update known hash to the newly uploaded file's hash
      final newHash = await _getRemoteHash(repoPath, path);
      session.lastKnownHash = newHash;

      // Invalidate status so UI updates with the new working tree changes
      ref.invalidate(statusProvider(repoPath));
    } catch (e) {
      ref.read(outputLogProvider.notifier).logError(
        'Remote Edit Sync Failed',
        'Failed to sync "$path": $e'
      );
    }
  }
}

final remoteEditServiceProvider = NotifierProvider<RemoteEditManager, Map<String, RemoteEditSession>>(RemoteEditManager.new);
