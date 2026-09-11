import 'dart:async';
import 'bounded_watch.dart';
import 'watch/engine/watch_engine.dart';
import 'watch/source/local/directory_watch_source.dart';
import 'watch/watch_timings.dart';
import 'watch_diagnostics.dart';
import 'watch_event.dart';
import 'watch_path_filter.dart';

/// Native-filesystem-event equivalent of [RemoteWatchService] for a repo on
/// this machine's own filesystem: no spawned `fswatch`/`inotifywait` process
/// at all — just `dart:io`'s `Directory.watch(recursive: true)`. Produces the
/// same `Stream<RepoWatchEvent>` shape (reusing [Coalescer] and
/// [shouldTriggerWatch] unchanged) so `repoWatchProvider`'s consumers need
/// zero changes to serve either backend.
///
/// ## Linked worktrees
///
/// Watching a linked worktree's directory alone would observe **nothing** about
/// git. Its `.git` is a FILE, written once at creation and never touched again;
/// its HEAD, index and reflog live in `<main>/.git/worktrees/<id>`, and the
/// branches it moves live in the shared `<main>/.git/refs` and `packed-refs`. A
/// commit made there writes zero git metadata inside the worktree folder — so a
/// recursive watch of it sees the changed working-tree files and never learns
/// that HEAD moved.
///
/// So a linked worktree needs a second root: the **common git dir**. That single
/// root is enough, because the worktree's own admin dir is *inside* it
/// (`<main>/.git/worktrees/<id>` ⊂ `<main>/.git`) — one recursive watch covers
/// this checkout's HEAD and index as well as the shared refs and `packed-refs`.
///
/// Events from it are rewritten to look like `.git/…` paths relative to the repo
/// root — which is exactly what they'd be in an ordinary repo. That is the whole
/// point: [shouldTriggerWatch], [RepoWatchEvent.touchesGitState] and every
/// consumer's refresh gating then work on a linked worktree **unmodified**,
/// instead of growing a parallel code path.
class LocalWatchService {
  LocalWatchService({this.onDiagnostic});

  /// Where this service's own failures go — the local twin of
  /// [RemoteWatchService.onDiagnostic].
  ///
  /// Without it a local repo was silent: it drives the same `WatchEngine`,
  /// with the same restart budget and the same degrade-to-polling, but nothing
  /// reached the output log, so "why is this repo polling" was unanswerable for
  /// exactly half the backends (0026 deviation (c)).
  final void Function(String line)? onDiagnostic;

  /// Files one transition against [repoPath].
  ///
  /// [WatchTransitionRecord.liveWatchers] is always 0 here and that is not a
  /// placeholder: a local watch holds no host processes, so there is no budget
  /// to report. The field distinguishes a leaked slot from a leaked process on
  /// the remote side; locally neither exists.
  void _record(
    String repoPath,
    WatchTransition kind,
    String cause,
    int restarts,
  ) {
    watchDiagnostics
        .forRepo(repoPath)
        .add(
          WatchTransitionRecord(
            at: DateTime.now(),
            kind: kind,
            repoPath: repoPath,
            cause: cause,
            liveWatchers: 0,
            restarts: restarts,
          ),
        );
    if (kind == WatchTransition.degradedToPolling) {
      final summary = watchDiagnostics.forRepo(repoPath).degradationSummary;
      if (summary != null) onDiagnostic?.call(summary);
    }
  }

  /// Watches [repoPath] for changes.
  ///
  /// [bounded], when supplied, switches to the scoped work-tree surface for a
  /// dotfiles-style repo (git-dir points + tracked-file dirs, watched
  /// non-recursively) instead of a recursive watch of the whole work tree — see
  /// [BoundedWatchSpec]. Only pass it when the repo's type toggle marks it as
  /// such; an ordinary repo leaves it null and behaves exactly as before. Mirror
  /// of [RemoteWatchService.watch]'s `bounded` so the DI hub can pick the backend
  /// without either caring which it got.
  Stream<RepoWatchEvent> watch(
    String repoPath, {
    BoundedWatchSpecSource? bounded,
    Duration trailing = WatchTimings.defaultTrailing,
    Duration maxWait = WatchTimings.defaultMaxWait,
    Duration minInterval = WatchTimings.defaultMinInterval,
    Duration pollInterval = WatchTimings.defaultPollInterval,
    Duration recoveryInterval = WatchTimings.defaultRecoveryInterval,
  }) {
    // The roots, the listener and the re-arm policy are the source's (MADR 0045
    // section 4); this service is the per-backend engine factory.
    return WatchEngine(
      source: DirectoryWatchSource(onDiagnostic: onDiagnostic),
      repoPath: repoPath,
      bounded: bounded,
      timings: WatchTimings(
        trailing: trailing,
        maxWait: maxWait,
        minInterval: minInterval,
        pollInterval: pollInterval,
        recoveryInterval: recoveryInterval,
      ),
      onTransition: (kind, cause, restarts) =>
          _record(repoPath, kind, cause, restarts),
    ).events;
  }
}
