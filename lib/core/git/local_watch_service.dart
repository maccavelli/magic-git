import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';
import 'coalescer.dart';
import 'watch_event.dart';
import 'watch_path_filter.dart';

/// Native-filesystem-event equivalent of [RemoteWatchService] for a repo on
/// this machine's own filesystem: no spawned `fswatch`/`inotifywait` process
/// at all — just `dart:io`'s `Directory.watch(recursive: true)`. Produces the
/// same `Stream<RepoWatchEvent>` shape (reusing [Coalescer] and
/// [shouldTriggerWatch] unchanged) so `repoWatchProvider`'s consumers need
/// zero changes to serve either backend.
class LocalWatchService {
  /// Maximum consecutive (re)start attempts before degrading to polling — a
  /// watch stream that keeps erroring (e.g. a flaky network-mounted volume
  /// misbehaving under FSEvents) must never leave the UI silently
  /// un-refreshed. Mirrors [RemoteWatchService]'s reasoning.
  static const int _maxRestarts = 3;

  Stream<RepoWatchEvent> watch(
    String repoPath, {
    Duration trailing = const Duration(milliseconds: 150),
    Duration maxWait = const Duration(seconds: 1),
    Duration minInterval = const Duration(seconds: 1),
    Duration pollInterval = const Duration(seconds: 5),
    Duration recoveryInterval = const Duration(minutes: 3),
  }) {
    late final StreamController<RepoWatchEvent> controller;
    StreamSubscription<FileSystemEvent>? sub;
    Timer? pollTimer;
    Timer? restartTimer;
    Timer? recoveryTimer;
    Coalescer? coalescer;
    var mode = WatchMode.stopped;
    var cancelled = false;
    var restarts = 0;
    late Future<void> Function() start;
    late void Function() scheduleRestart;

    // `FileSystemEvent.path` comes back prefixed with whatever string
    // `repoPath` itself was, not repo-root-relative like fswatch/inotifywait
    // emit — strip that prefix so `shouldTriggerWatch` sees the same shape
    // either backend produces.
    final rootWithSlash = repoPath.endsWith('/') ? repoPath : '$repoPath/';
    String relativize(String path) => path.startsWith(rootWithSlash)
        ? path.substring(rootWithSlash.length)
        : path;

    void emit() {
      if (!controller.isClosed) {
        controller.add(RepoWatchEvent(at: DateTime.now(), mode: mode));
      }
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
      // Cancel the subscription *before* dropping `coalescer` — the listener
      // dereferences `coalescer!`, so an event delivered in the window
      // between nulling it and cancelling the sub would throw a null-check
      // error inside the stream callback. Mirrors RemoteWatchService.
      await sub?.cancel();
      sub = null;
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
        sub = Directory(repoPath).watch(recursive: true).listen(
          (event) {
            restarts = 0;
            mode = WatchMode.eventDriven;
            if (shouldTriggerWatch(relativize(event.path))) {
              coalescer!.signal();
            }
          },
          onDone: scheduleRestart,
          onError: (Object _) => scheduleRestart(),
        );
      } catch (e) {
        // A small minority of filesystems (some network mounts) can reject
        // `Directory.watch()` outright rather than erroring through the
        // stream — treat that the same as a stream error.
        developer.log(
          'Directory.watch failed to start: $e',
          name: 'LocalWatchService',
        );
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
