import 'dart:developer' as developer;

import '../bounded_watch.dart';
import '../local_watch_service.dart';
import '../remote_watch_service.dart';
import '../watch_event.dart';
import 'watch_target.dart';

/// Turns a [WatchTarget] into a watcher, on the backend the target names.
///
/// What `repoWatchProvider` used to do inline — pick the service, build a
/// bounded surface's supplier — behind the value `watcherProvider` keys on
/// (MADR 0045 section 1).
final class WatchRuntime {
  const WatchRuntime({
    required this.remote,
    required this.local,
    required this.listTrackedFiles,
    required this.sessionId,
  });

  final RemoteWatchService remote;
  final LocalWatchService local;

  /// The files git tracks in a repository, asked on every bounded arm.
  final Future<List<String>> Function(String repoPath) listTrackedFiles;

  /// The session — one tab's container — these watchers belong to, as a
  /// `WatcherId` names it.
  final String sessionId;

  /// A watcher for [target]. Every call builds its own; sharing one is
  /// Riverpod's, through `watcherProvider`.
  Stream<RepoWatchEvent> watch(WatchTarget target) {
    final BoundedWatchSpecSource? bounded = switch (target.surface) {
      RecursiveSurface() => null,
      BoundedSurface(:final gitDir, :final workTree) => _boundedSpec(
        target.repoPath,
        gitDir: gitDir,
        workTree: workTree,
      ),
    };
    // Exhaustive switch (no default) so a new backend can't silently fall
    // through to the SSH watcher.
    return switch (target.backend) {
      WatchBackend.local => local.watch(target.repoPath, bounded: bounded),
      WatchBackend.ssh => remote.watch(target.repoPath, bounded: bounded),
    };
  }

  /// A SUPPLIER, not a value: the service calls it on every arm, so a re-arm
  /// picks up files tracked since the watch started (0022 H5).
  BoundedWatchSpecSource _boundedSpec(
    String repoPath, {
    required String gitDir,
    required String workTree,
  }) => () async {
    List<String> tracked;
    try {
      tracked = await listTrackedFiles(repoPath);
    } catch (e) {
      // Never let this kill the watcher. It used to run through
      // Stream.fromFuture OUTSIDE the lifecycle engine, so a transport blip or
      // a GitException errored the whole provider and the repo went unwatched
      // with no polling fallback at all (0022 N1). Degrade instead: an empty
      // tracked list still yields the git-dir watch points, so git-state
      // changes are still seen, and the next re-arm can recover the full
      // surface.
      developer.log(
        'listTrackedFiles failed for $repoPath; watching git-dir only: $e',
        name: 'repoWatchProvider',
      );
      tracked = const [];
    }
    return computeBoundedWatchSpec(
      gitDir: gitDir,
      workTree: workTree,
      trackedFiles: tracked,
    );
  };

  /// Reclaims the host's watcher processes whose client is gone, for
  /// [repoPaths], each keyed by its resolved git dir.
  ///
  /// [stillWanted] is asked between resolving and sweeping, so a connect that
  /// has been superseded meanwhile sweeps nothing.
  Future<void> sweepStaleWatchers(
    Iterable<String> repoPaths,
    Map<String, String> scopedGitDirs, {
    required bool Function() stillWanted,
  }) async {
    final targets = await remote.resolveSweepTargets(repoPaths, scopedGitDirs);
    if (!stillWanted()) return;
    await remote.sweepStaleWatchers(targets);
  }
}
