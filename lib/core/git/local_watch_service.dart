import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';
import '../local/linked_worktree_probe.dart';
import 'coalescer.dart';
import 'watch_event.dart';
import 'watch_path_filter.dart';

/// One directory this watcher subscribes to, plus how to turn the absolute paths
/// it reports back into the repo-root-relative shape every downstream consumer
/// expects.
class _WatchRoot {
  final String dir;

  /// Absolute event path → the repo-relative path to publish. Returning `''`
  /// drops the event ([shouldTriggerWatch] rejects the empty string).
  final String Function(String absolutePath) relativize;

  const _WatchRoot(this.dir, this.relativize);
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
  /// Maximum consecutive (re)start attempts before degrading to polling — a
  /// watch stream that keeps erroring (e.g. a flaky network-mounted volume
  /// misbehaving under FSEvents) must never leave the UI silently
  /// un-refreshed. Mirrors [RemoteWatchService]'s reasoning.
  static const int _maxRestarts = 3;

  /// Strips [root] from an absolute event path, yielding a root-relative one.
  ///
  /// [prefix] is prepended to the result, which is what maps an event in the
  /// common git dir (`<main>/.git/refs/heads/x`) onto the path it would have in
  /// an ordinary repo (`.git/refs/heads/x`).
  static String Function(String) _relativizer(String root, {String prefix = ''}) {
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

  Stream<RepoWatchEvent> watch(
    String repoPath, {
    Duration trailing = const Duration(milliseconds: 150),
    Duration maxWait = const Duration(seconds: 1),
    Duration minInterval = const Duration(seconds: 1),
    Duration pollInterval = const Duration(seconds: 5),
    Duration recoveryInterval = const Duration(minutes: 3),
  }) {
    late final StreamController<RepoWatchEvent> controller;
    final subs = <StreamSubscription<FileSystemEvent>>[];
    Timer? pollTimer;
    Timer? restartTimer;
    Timer? recoveryTimer;
    Coalescer? coalescer;
    var mode = WatchMode.stopped;
    var cancelled = false;
    var restarts = 0;
    late Future<void> Function() start;
    late void Function() scheduleRestart;

    // Resolved once per watch, not per restart: the layout of a checkout can't
    // change while it's open (only `worktree move`/`repair` does that, and both
    // go through a full reconnect).
    final roots = _rootsFor(repoPath);

    // The paths seen since the last fire. Drained into the tick the coalescer
    // eventually emits, so consumers learn *what* moved and not merely that
    // something did. A poll/restart tick fires with this empty, which is
    // exactly the "unknown scope" [RepoWatchEvent.paths] documents.
    final pending = <String>{};

    // A burst is unbounded (a `git clean`, a branch switch, a build emitting
    // thousands of objects); the tick only needs enough of it to decide what to
    // refresh. Past this many distinct paths the set stops being a useful
    // description of the burst, so it is dropped and the tick degrades to
    // unknown scope — which consumers already handle as "refresh everything".
    const maxPaths = 512;
    var overflowed = false;

    void emit() {
      if (controller.isClosed) return;
      final paths = overflowed ? const <String>{} : Set<String>.from(pending);
      pending.clear();
      overflowed = false;
      controller.add(
        RepoWatchEvent(at: DateTime.now(), mode: mode, paths: paths),
      );
    }

    void startPolling() {
      mode = WatchMode.polling;
      pollTimer?.cancel();
      emit();
      pollTimer = Timer.periodic(pollInterval, (_) => emit());
      // A watcher that degrades to polling must not stay degraded for the
      // rest of the session — periodically retry event-driven watching so a
      // transient volume issue is picked back up.
      recoveryTimer?.cancel();
      recoveryTimer = Timer.periodic(recoveryInterval, (_) {
        if (cancelled) return;
        restarts = 0;
        start().catchError((_) => scheduleRestart());
      });
    }

    Future<void> teardownWatcher() async {
      // Cancel the subscriptions *before* dropping `coalescer` — the listener
      // dereferences `coalescer!`, so an event delivered in the window
      // between nulling it and cancelling the subs would throw a null-check
      // error inside the stream callback. Mirrors RemoteWatchService.
      for (final sub in subs) {
        await sub.cancel();
      }
      subs.clear();
      coalescer?.cancel();
      coalescer = null;
    }

    scheduleRestart = () {
      if (cancelled || controller.isClosed) return;
      if (restarts >= _maxRestarts) {
        startPolling();
        return;
      }
      mode = WatchMode.stopped;
      // Emit immediately so the UI's status dot reflects the outage for the
      // whole restart-backoff window, not just once it gives up.
      emit();
      restarts++;
      restartTimer?.cancel();
      restartTimer = Timer(Duration(seconds: restarts * 2), () {
        if (cancelled || controller.isClosed) return;
        start().catchError((_) => scheduleRestart());
      });
    };

    start = () async {
      recoveryTimer?.cancel();
      recoveryTimer = null;
      // Stop any polling loop too — a successful recovery must not leave the
      // periodic poll timer emitting refresh ticks forever alongside the
      // event-driven watcher. Mirrors RemoteWatchService.
      pollTimer?.cancel();
      pollTimer = null;
      await teardownWatcher();
      if (cancelled) return;

      mode = WatchMode.eventDriven;
      coalescer = Coalescer(
        trailing: trailing,
        maxWait: maxWait,
        minInterval: minInterval,
        onFire: emit,
      );

      try {
        for (final root in roots) {
          subs.add(
            Directory(root.dir).watch(recursive: true).listen(
              (event) {
                restarts = 0;
                mode = WatchMode.eventDriven;
                final path = root.relativize(event.path);
                if (!shouldTriggerWatch(path)) return;
                if (pending.length >= maxPaths) {
                  overflowed = true;
                  pending.clear();
                }
                if (!overflowed) pending.add(path);
                coalescer!.signal();
              },
              onDone: scheduleRestart,
              onError: (Object _) => scheduleRestart(),
            ),
          );
        }
      } catch (e) {
        // A small minority of filesystems (some network mounts) can reject
        // `Directory.watch()` outright rather than erroring through the
        // stream — treat that the same as a stream error. Any root failing
        // restarts them ALL: a linked worktree whose common-git-dir watch died
        // would still see file edits but never learn that HEAD moved, which is
        // worse than an honest restart-then-poll.
        developer.log(
          'Directory.watch failed to start: $e',
          name: 'LocalWatchService',
        );
        await teardownWatcher();
        scheduleRestart();
        return;
      }

      // The watcher is now armed. Announce it with one eventDriven tick, same
      // reasoning as RemoteWatchService: turns the status dot green
      // immediately instead of sitting grey until the first real change.
      emit();
    };

    Future<void> stop() async {
      cancelled = true;
      restartTimer?.cancel();
      pollTimer?.cancel();
      recoveryTimer?.cancel();
      await teardownWatcher();
      if (!controller.isClosed) await controller.close();
    }

    controller = StreamController<RepoWatchEvent>(
      onListen: () {
        start().catchError((Object _) => scheduleRestart());
      },
      onCancel: stop,
    );
    return controller.stream;
  }
}
