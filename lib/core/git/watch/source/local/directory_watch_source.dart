import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import '../../../../local/linked_worktree_probe.dart';
import '../../../bounded_watch.dart';
import '../../../watch_path_filter.dart';
import '../../watch_timings.dart';
import '../surface_rearm_policy.dart';
import '../watch_source.dart';

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
  /// entire tree.
  final bool recursive;

  const _WatchRoot(this.dir, this.relativize, {this.recursive = true});
}

/// A repository on this machine's own filesystem, watched through `dart:io`'s
/// `Directory.watch` — no spawned process at all.
///
/// ## Linked worktrees
///
/// Watching a linked worktree's directory alone would observe **nothing** about
/// git. Its `.git` is a FILE, written once at creation and never touched again;
/// its HEAD, index and reflog live in `<main>/.git/worktrees/<id>`, and the
/// branches it moves live in the shared `<main>/.git/refs` and `packed-refs`. A
/// commit made there writes zero git metadata inside the worktree folder.
///
/// So a linked worktree needs a second root: the **common git dir**. That single
/// root is enough, because the worktree's own admin dir is *inside* it — one
/// recursive watch covers this checkout's HEAD and index as well as the shared
/// refs and `packed-refs`. Its events are rewritten to look like `.git/…` paths
/// relative to the repo root, which is exactly what they would be in an
/// ordinary repo, so [shouldTriggerWatch] and every consumer work unmodified.
final class DirectoryWatchSource implements WatchSource {
  DirectoryWatchSource({
    this.onDiagnostic,
    Duration rearmDebounce = WatchTimings.defaultRearmDebounce,
  }) : _rearmPolicy = SurfaceRearmPolicy(debounce: rearmDebounce);

  /// Where this source's own failures go.
  final void Function(String line)? onDiagnostic;

  /// Debounces deliberate re-arms. Spans arms; cancelled by every close.
  final SurfaceRearmPolicy _rearmPolicy;

  /// An ORDINARY repo's roots, resolved on its first arm and kept: the layout of
  /// a checkout can't change while it is open (only `worktree move`/`repair`
  /// does that, and both go through a full reconnect). A BOUNDED repo's roots
  /// are resolved per arm instead — its surface is derived from the tracked-file
  /// set, which every `git add` can widen (0022 H5).
  List<_WatchRoot>? _fixedRoots;

  @override
  Future<SourceArm> arm(ArmRequest request) async {
    var cancelled = false;
    unawaited(request.cancelled.then((_) => cancelled = true));

    final bounded = request.bounded;
    final spec = bounded == null ? null : await bounded();
    if (cancelled) return const SourceAborted();
    final roots = spec != null
        ? _boundedRoots(spec)
        : (_fixedRoots ??= _rootsFor(request.repoPath));

    // Synchronous, like the remote source: one signal per changed path must
    // not queue a microtask each.
    final signals = StreamController<SourceSignal>(sync: true);
    void emit(SourceSignal signal) {
      if (!signals.isClosed) signals.add(signal);
    }

    final subs = <StreamSubscription<FileSystemEvent>>[];
    Future<void> teardown() async {
      _rearmPolicy.cancel();
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
                  emit(const SourceActivity());
                  final path = root.relativize(event.path);
                  if (shouldTriggerWatch(path)) {
                    emit(PathChanged(path));
                    // A bounded surface derives from the index, so a git-state
                    // write can mean the surface is now too small. Recompute
                    // and re-arm, debounced.
                    _rearmPolicy.onPath(
                      path,
                      bounded: spec != null,
                      rearm: () => emit(const RearmRequested()),
                      cancelled: () => cancelled,
                    );
                  }
                  // A move has both a source and a destination. The source may
                  // be a transient lock (e.g. `.git/index.lock`) that
                  // [shouldTriggerWatch] correctly suppresses; the destination
                  // is the real file that changed (e.g. `.git/index`), and
                  // ignoring it misses git's atomic state updates on inotify.
                  if (event is FileSystemMoveEvent) {
                    final destination = event.destination;
                    if (destination != null) {
                      final destinationPath = root.relativize(destination);
                      if (shouldTriggerWatch(destinationPath)) {
                        emit(PathChanged(destinationPath));
                      }
                    }
                  }
                },
                onDone: () => emit(const SourceDied('watch ended')),
                onError: (Object e) {
                  // Say what died before restarting: locally this used to
                  // arrive only as a silent restart, so a watch that could
                  // never start burned its budget with nothing to chase
                  // (0026 deviation (c)).
                  onDiagnostic?.call('watch error: $e');
                  emit(SourceDied('watch error: $e'));
                },
              ),
        );
      }
    } catch (e) {
      // Some filesystems (network mounts) reject `Directory.watch()` outright
      // rather than erroring through the stream. Any root failing restarts
      // them ALL: a linked worktree whose common-git-dir watch died would still
      // see file edits but never learn that HEAD moved.
      developer.log(
        'Directory.watch failed to start: $e',
        name: 'LocalWatchService',
      );
      onDiagnostic?.call('Directory.watch failed to start: $e');
      await teardown();
      unawaited(signals.close());
      rethrow; // the engine schedules the restart
    }

    return SourceArmed(
      _ArmedDirectories(signals, () async {
        await teardown();
        // Not awaited: an unlistened single-subscription stream never
        // finishes closing, and close() must not depend on a listener.
        unawaited(signals.close());
      }),
    );
  }

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
      // itself, whose path is exactly the root. Left un-stripped it becomes an
      // absolute path that bypasses every relative-path noise rule and fires on
      // every git-op churn; the real child always arrives as its own event.
      if (path == root) return '';
      if (!path.startsWith(rootWithSlash)) return path;
      return '$prefix${path.substring(rootWithSlash.length)}';
    };
  }

  /// The directories to watch for [repoPath].
  ///
  /// Ordinary repo: just the repo root — its `.git` is inside it. Linked
  /// worktree: the worktree root plus the common git dir, remapped to `.git/…`.
  /// Uses [probeLocalRepo] rather than `git rev-parse` deliberately — it reads
  /// the worktree's own `.git` file, so it needs no subprocess and works before
  /// any grant on the main repo is held.
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
        _relativizer(wt.gitCommonDir, prefix: '.git/'),
      ),
    );
    return roots;
  }

  /// The bounded, **non-recursive** roots for a scoped work-tree (dotfiles)
  /// repo: each directory in [spec] watched on its own, with git-dir events
  /// remapped to `.git/…` by [relativizeBoundedEvent]. `?? ''` drops any event
  /// outside the spec.
  static List<_WatchRoot> _boundedRoots(BoundedWatchSpec spec) => [
    for (final dir in spec.watchDirs)
      _WatchRoot(
        dir,
        (path) => relativizeBoundedEvent(path, spec) ?? '',
        recursive: false,
      ),
  ];
}

final class _ArmedDirectories implements ArmedSource {
  _ArmedDirectories(this._signals, this._close);

  final StreamController<SourceSignal> _signals;
  final Future<void> Function() _close;

  @override
  Stream<SourceSignal> get signals => _signals.stream;

  @override
  Future<void> close() => _close();
}
