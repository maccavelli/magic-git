import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../forge/forge.dart';
import '../git/host_fs_service.dart';
import '../github/gh_service.dart';
import '../gitlab/glab_service.dart';
import '../output/output_log.dart';
import '../providers/app_providers.dart';
import '../ssh/ssh_command_executor.dart';
import '../utils/bounded_tail.dart';

/// Lifecycle of one clone job. Terminal phases ([succeeded], [failed],
/// [cancelled]) allow a new [CloneJobController.run].
enum CloneJobPhase {
  idle,
  preparing,
  cloning,
  cleaningUp,
  succeeded,
  failed,
  cancelled,
}

@immutable
class CloneJobState {
  final CloneJobPhase phase;

  /// The destination directory of the current/last job (parent + name).
  final String? destPath;

  /// The latest progress frame from git's stderr (`Receiving objects: 42% …`)
  /// for the in-sheet progress line; the full transcript goes to the output
  /// log.
  final String progressLine;

  /// On [CloneJobPhase.failed]: the tail of stderr, for the sheet's error box.
  final String? error;

  const CloneJobState({
    this.phase = CloneJobPhase.idle,
    this.destPath,
    this.progressLine = '',
    this.error,
  });

  CloneJobState copyWith({
    CloneJobPhase? phase,
    String? destPath,
    String? progressLine,
    String? error,
  }) => CloneJobState(
    phase: phase ?? this.phase,
    destPath: destPath ?? this.destPath,
    progressLine: progressLine ?? this.progressLine,
    error: error ?? this.error,
  );

  bool get isRunning =>
      phase == CloneJobPhase.preparing ||
      phase == CloneJobPhase.cloning ||
      phase == CloneJobPhase.cleaningUp;
}

/// Where a clone comes from.
sealed class CloneSource {
  const CloneSource();
}

/// A repository picked from the forge browse list — cloned via the forge CLI
/// so its stored auth covers private repos.
class ForgeCloneSource extends CloneSource {
  final Forge forge;
  final String host;

  /// `owner/name` (GitHub) or `group/project` (GitLab).
  final String slug;
  const ForgeCloneSource({
    required this.forge,
    required this.host,
    required this.slug,
  });
}

/// An arbitrary URL — plain `git clone`, using whatever auth the host's git
/// already has (SSH keys, credential helper).
class UrlCloneSource extends CloneSource {
  final String url;
  const UrlCloneSource(this.url);
}

class CloneRequest {
  final CloneSource source;

  /// Absolute, existing (or created via [createParents]) parent directory.
  /// For local destinations this is the picker-granted folder.
  final String parentDir;

  /// New directory name — must pass [HostFsService.isValidRepoDirName].
  final String name;

  /// SSH-only toggle: `mkdir -p` the parent if it doesn't exist yet.
  final bool createParents;

  /// Run against this machine's own filesystem ([LocalCommandExecutor])
  /// regardless of the active session's backend. Needed for a "clone to This
  /// Mac" from the disconnected landing, where there is no active local
  /// session to route through [activeExecutorProvider] (the destination
  /// doesn't exist yet, so it can't be opened first).
  final bool local;

  const CloneRequest({
    required this.source,
    required this.parentDir,
    required this.name,
    this.createParents = false,
    this.local = false,
  });
}

/// Runs one clone at a time as an explicit state machine: probe the
/// destination, stream `git clone --progress` through the output log with a
/// live in-sheet progress line, and — on failure or cancel — clean up the
/// partial destination, but only when this very job created it.
class CloneJobController extends Notifier<CloneJobState> {
  bool _cancelled = false;

  /// The live stream handle while a clone runs — what [cancel] SIGTERMs.
  SSHStreamHandle? _activeHandle;

  /// Whether the destination was absent before this job started — the
  /// precondition for the guarded cleanup. A pre-existing destination fails
  /// early and is never eligible for deletion.
  bool _createdByThisJob = false;

  @override
  CloneJobState build() => const CloneJobState();

  /// Runs [request] to completion. Returns true on success. Safe to call only
  /// when no job is running (guarded); terminal states allow a re-run.
  Future<bool> run(CloneRequest request) async {
    if (state.isRunning) return false;
    _cancelled = false;
    _createdByThisJob = false;

    // Local requests force the local executor even when no local session is
    // active (clone-to-This-Mac from the landing); everything else follows the
    // active session's backend.
    final executor = request.local
        ? ref.read(localExecutorProvider)
        : ref.read(activeExecutorProvider);
    final fs = HostFsService(executor);
    final dest = HostFsService.joinPath(request.parentDir, request.name);
    state = CloneJobState(phase: CloneJobPhase.preparing, destPath: dest);

    if (!HostFsService.isValidRepoDirName(request.name)) {
      return _fail('"${request.name}" is not a valid folder name.');
    }
    if (!request.parentDir.startsWith('/')) {
      return _fail('The destination folder must be an absolute path.');
    }

    // --- Pre-checks -------------------------------------------------------
    try {
      switch (await fs.probePath(dest)) {
        case PathProbe.exists:
          return _fail('The destination already exists: $dest');
        case PathProbe.noParent:
          if (!request.createParents) {
            return _fail(
              "The parent folder doesn't exist: ${request.parentDir}",
            );
          }
          if (_cancelled) return _finishCancelled();
          await fs.makeDirs(request.parentDir);
        case PathProbe.absent:
          break;
      }
    } catch (e) {
      return _fail('$e');
    }
    if (_cancelled) return _finishCancelled();
    _createdByThisJob = true;

    // --- Stream the clone -------------------------------------------------
    final argv = switch (request.source) {
      ForgeCloneSource(forge: Forge.github, :final slug) =>
        GhService.cloneArgv(slug: slug, dirName: request.name),
      ForgeCloneSource(forge: Forge.gitlab, :final slug) =>
        GlabService.cloneArgv(pathWithNamespace: slug, dirName: request.name),
      ForgeCloneSource() => throw StateError('not a forge source'),
      UrlCloneSource(:final url) => [
        'git',
        'clone',
        '--progress',
        '--',
        url,
        request.name,
      ],
    };
    final extraEnv = switch (request.source) {
      ForgeCloneSource(forge: Forge.github, :final host) =>
        GhService.hostEnv(host),
      ForgeCloneSource(forge: Forge.gitlab, :final host) =>
        GlabService.hostEnv(host),
      _ => null,
    };

    final log = ref.read(outputLogProvider.notifier);
    // Reveal the transcript; the view tails it live.
    log.setVisible(true);
    final session = log.startStream(argv.join(' '));
    final stderrTail = BoundedTail(4000);

    int? exitCode;
    try {
      final handle = await executor.executeStream(
        repoPath: request.parentDir,
        gitArgs: argv,
        extraEnv: extraEnv,
      );
      state = state.copyWith(phase: CloneJobPhase.cloning);
      if (_cancelled) {
        // Cancelled between the open and here — kill it right away.
        await handle.cancel();
      }
      _activeHandle = handle;
      final outDone = handle.stdout
          .listen((chunk) => session.append(chunk, OutputLineKind.stdout))
          .asFuture<void>()
          .catchError((_) {});
      final errDone = handle.stderr.listen((chunk) {
        session.append(chunk, OutputLineKind.stderr);
        stderrTail.write(chunk);
        final frame = _latestFrame(chunk);
        if (frame.isNotEmpty) {
          state = state.copyWith(progressLine: frame);
        }
      }).asFuture<void>().catchError((_) {});

      exitCode = await handle.exitCode;
      // Let the tail of the streams drain so the transcript is complete.
      await Future.wait([outDone, errDone]);
    } catch (e) {
      session.fail('$e');
      _activeHandle = null;
      await _cleanupPartial(fs, request, dest);
      return _cancelled ? _finishCancelled() : _fail('$e');
    }
    _activeHandle = null;
    session.close(exitCode: exitCode);

    if (exitCode == 0 && !_cancelled) {
      state = state.copyWith(phase: CloneJobPhase.succeeded);
      return true;
    }

    await _cleanupPartial(fs, request, dest);
    if (_cancelled) return _finishCancelled();
    final tail = stderrTail.toString().trim();
    return _fail(
      tail.isEmpty ? 'git clone exited with code $exitCode' : tail,
    );
  }

  /// Cancels the running job: SIGTERM to the clone, then the same guarded
  /// cleanup as a failure. Idempotent; a no-op when nothing is running.
  Future<void> cancel() async {
    if (!state.isRunning) return;
    _cancelled = true;
    await _activeHandle?.cancel();
  }

  /// Returns the job to [CloneJobPhase.idle] — called when the sheet closes.
  void reset() {
    if (!state.isRunning) state = const CloneJobState();
  }

  /// Deletes the partial destination, but only when this job created it (the
  /// probe said absent) — a best-effort step whose own failure is logged and
  /// never masks the original error.
  Future<void> _cleanupPartial(
    HostFsService fs,
    CloneRequest request,
    String dest,
  ) async {
    if (!_createdByThisJob) return;
    state = state.copyWith(phase: CloneJobPhase.cleaningUp);
    try {
      if (await fs.probePath(dest) == PathProbe.exists) {
        await fs.removeDirGuarded(
          path: dest,
          expectedParent: request.parentDir,
          expectedName: request.name,
        );
      }
    } catch (e) {
      ref
          .read(outputLogProvider.notifier)
          .logError('cleanup of $dest', '$e');
    }
  }

  bool _fail(String message) {
    state = state.copyWith(phase: CloneJobPhase.failed, error: message);
    return false;
  }

  bool _finishCancelled() {
    state = state.copyWith(phase: CloneJobPhase.cancelled);
    return false;
  }

  /// The last `\r`- or `\n`-delimited frame in [chunk] with content — what a
  /// terminal would currently show for git's progress output.
  static String _latestFrame(String chunk) {
    final frames = chunk.split(RegExp(r'[\r\n]'));
    for (var i = frames.length - 1; i >= 0; i--) {
      final f = frames[i].trim();
      if (f.isNotEmpty) return f;
    }
    return '';
  }
}

final cloneJobProvider = NotifierProvider<CloneJobController, CloneJobState>(
  CloneJobController.new,
);
