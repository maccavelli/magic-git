/// Which transport a watched repository lives behind.
enum WatchBackend { local, ssh }

/// What a watcher watches: the whole work tree, or an explicit bounded surface.
///
/// A static parameter, and so part of a watcher's identity: a different surface
/// is a different watcher (MADR 0045 section 1). The dynamic part of a bounded
/// surface — which directories its tracked files live in — is not here; it is
/// recomputed on every arm.
sealed class WatchSurface {
  const WatchSurface();
}

/// A recursive watch of the whole work tree.
final class RecursiveSurface extends WatchSurface {
  const RecursiveSurface();

  @override
  bool operator ==(Object other) => other is RecursiveSurface;

  @override
  int get hashCode => (RecursiveSurface).hashCode;

  @override
  String toString() => 'RecursiveSurface()';
}

/// A scoped work-tree repository's bounded surface: its git dir and work tree.
final class BoundedSurface extends WatchSurface {
  const BoundedSurface({required this.gitDir, required this.workTree});

  final String gitDir;
  final String workTree;

  @override
  bool operator ==(Object other) =>
      other is BoundedSurface &&
      other.gitDir == gitDir &&
      other.workTree == workTree;

  @override
  int get hashCode => Object.hash(BoundedSurface, gitDir, workTree);

  @override
  String toString() => 'BoundedSurface($gitDir, $workTree)';
}

/// Everything that identifies one watcher, and nothing that changes while it
/// runs.
///
/// A value, so it can key a provider family: a change to any field is a
/// different key, and a different key is a different watcher. That is what
/// retires inferring "did the parameters change?" from the timing of rebuilds
/// (MADR 0045 F3).
final class WatchTarget {
  const WatchTarget({
    required this.repoPath,
    required this.surface,
    required this.backend,
  });

  final String repoPath;
  final WatchSurface surface;
  final WatchBackend backend;

  @override
  bool operator ==(Object other) =>
      other is WatchTarget &&
      other.repoPath == repoPath &&
      other.surface == surface &&
      other.backend == backend;

  @override
  int get hashCode => Object.hash(repoPath, surface, backend);

  @override
  String toString() => 'WatchTarget($repoPath, $surface, ${backend.name})';
}
