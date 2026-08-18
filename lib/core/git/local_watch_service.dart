import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';
import '../local/linked_worktree_probe.dart';
import 'bounded_watch.dart';
import 'watch_event.dart';
import 'watch_lifecycle.dart';
import 'watch_path_filter.dart';

/// One directory this watcher subscribes to, plus how to turn the absolute paths
/// it reports back into the repo-root-relative shape every downstream consumer
/// expects.
class _WatchRoot {
  final String dir;

  /// Absolute event path → the repo-relative path to publish. Returning `''`
  /// drops the event ([shouldTriggerWatch] rejects the empty string).
  final String Function(String absolutePath) relativize;

  /// Watch the whole subtree ([recursive] = true, ordinary and linked-worktree
  /// roots) or only this directory's own entries (false). Non-recursive is what
  /// keeps a scoped work-tree ($HOME) from arming a recursive watch over its
  /// entire tree — see the bounded-dotfiles roots in [LocalWatchService.watch].
  final bool recursive;

  const _WatchRoot(this.dir, this.relativize, {this.recursive = true});
}

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
  /// Strips [root] from an absolute event path, yielding a root-relative one.
  ///
  /// [prefix] is prepended to the result, which is what maps an event in the
  /// common git dir (`<main>/.git/refs/heads/x`) onto the path it would have in
  /// an ordinary repo (`.git/refs/heads/x`).
  static String Function(String) _relativizer(
    String root, {
    String prefix = '',
  }) {
    final rootWithSlash = root.endsWith('/') ? root : '$root/';
    return (String path) {
      // macOS FSEvents also emits a directory-granularity event for the root
      // itself, whose path is exactly the root (no trailing component). Left
      // un-stripped it becomes an absolute path that bypasses every
      // relative-path noise rule in `shouldTriggerWatch` and fires on every
      // git-op churn. Map it to the empty string so that filter drops it — the
      // real child that changed always arrives as its own specific event.
      if (path == root) return '';
      if (!path.startsWith(rootWithSlash)) return path;
      return '$prefix${path.substring(rootWithSlash.length)}';
    };
  }

  /// The directories to watch for [repoPath].
  ///
  /// Ordinary repo: just the repo root — its `.git` is inside it, so one
  /// recursive watch already sees everything (this is the pre-existing
  /// behaviour, byte for byte).
  ///
  /// Linked worktree: the worktree root (for working-tree files) plus the common
  /// git dir, remapped to `.git/…`. Uses [probeLocalRepo] rather than `git
  /// rev-parse` deliberately — it reads the worktree's own `.git` file, so it
  /// needs no subprocess and works before any grant on the main repo is held.
  static List<_WatchRoot> _rootsFor(String repoPath) {
    final roots = [_WatchRoot(repoPath, _relativizer(repoPath))];

    final probe = probeLocalRepo(repoPath);
    final wt = probe.worktree;
    if (probe.kind != LocalRepoKind.linkedWorktree || wt == null) return roots;

    roots.add(
      _WatchRoot(
        wt.gitCommonDir,
        // `<main>/.git/refs/heads/x`  ->  `.git/refs/heads/x`
        // `<main>/.git/worktrees/f/HEAD` -> `.git/worktrees/f/HEAD`
        // Both then pass shouldTriggerWatch and set touchesGitState, exactly as
        // the same changes would in an ordinary repo. Objects and logs are
        // dropped by the existing filter, so a fetch or gc doesn't flood us —
        // the same protection the repo-root watch already relies on.
        _relativizer(wt.gitCommonDir, prefix: '.git/'),
      ),
    );
    return roots;
  }

  /// The bounded, **non-recursive** roots for a scoped work-tree (dotfiles)
  /// repo: each directory in [spec] watched on its own, with git-dir events
  /// remapped to `.git/…` by [relativizeBoundedEvent] so the shared filter and
  /// [RepoWatchEvent.touchesGitState] work unchanged — the local-backend twin
  /// of [RemoteWatchService]'s bounded arming. `?? ''` drops any event outside
  /// the spec (the empty string is rejected by [shouldTriggerWatch]).
  static List<_WatchRoot> _boundedRoots(BoundedWatchSpec spec) => [
    for (final dir in spec.watchDirs)
      _WatchRoot(
        dir,
        (path) => relativizeBoundedEvent(path, spec) ?? '',
        recursive: false,
      ),
  ];

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
    BoundedWatchSpec? bounded,
    Duration trailing = const Duration(milliseconds: 150),
    Duration maxWait = const Duration(seconds: 1),
    Duration minInterval = const Duration(seconds: 1),
    Duration pollInterval = const Duration(seconds: 5),
    Duration recoveryInterval = const Duration(minutes: 3),
  }) {
    // Resolved once per watch, not per restart: the layout of a checkout can't
    // change while it's open (only `worktree move`/`repair` does that, and both
    // go through a full reconnect).
    final roots = bounded != null
        ? _boundedRoots(bounded)
        : _rootsFor(repoPath);

    return watchLifecycle(
      trailing: trailing,
      maxWait: maxWait,
      minInterval: minInterval,
      pollInterval: pollInterval,
      recoveryInterval: recoveryInterval,
      arm: (hooks) async {
        final subs = <StreamSubscription<FileSystemEvent>>[];
        Future<void> teardown() async {
          for (final sub in subs) {
            await sub.cancel();
          }
          subs.clear();
        }

        try {
          for (final root in roots) {
            subs.add(
              Directory(root.dir)
                  .watch(recursive: root.recursive)
                  .listen(
                    (event) {
                      hooks.noteActivity();
                      final path = root.relativize(event.path);
                      if (shouldTriggerWatch(path)) {
                        hooks.signalPath(path);
                      }
                      // A move has both a source and a destination. The source may be
                      // a transient lock (e.g. `.git/index.lock`) that
                      // [shouldTriggerWatch] correctly suppresses; the destination is
                      // the real file that changed (e.g. `.git/index`), and ignoring
                      // it misses git's atomic state updates on Linux/inotify.
                      if (event is FileSystemMoveEvent) {
                        final dst = event.destination;
                        if (dst != null) {
                          final dstPath = root.relativize(dst);
                          if (shouldTriggerWatch(dstPath)) {
                            hooks.signalPath(dstPath);
                          }
                        }
                      }
                    },
                    onDone: hooks.scheduleRestart,
                    onError: (Object _) => hooks.scheduleRestart(),
                  ),
            );
          }
        } catch (e) {
          // A small minority of filesystems (some network mounts) can reject
          // `Directory.watch()` outright rather than erroring through the
          // stream — treat that the same as a stream error. Any root failing
          // restarts them ALL: a linked worktree whose common-git-dir watch
          // died would still see file edits but never learn that HEAD moved,
          // which is worse than an honest restart-then-poll.
          developer.log(
            'Directory.watch failed to start: $e',
            name: 'LocalWatchService',
          );
          await teardown();
          rethrow; // the engine schedules the restart
        }

        return WatchArmed(teardown);
      },
    );
  }
}
