import 'dart:async';
import 'dart:developer' as developer;
import '../ssh/ssh_command_executor.dart';
import 'coalescer.dart';
import 'watch_event.dart';
import 'watch_path_filter.dart';

enum _WatcherTool { fswatch, inotifywait, none }

/// Watches a remote repository for filesystem changes and emits a coalesced
/// [RepoWatchEvent] per settled burst, carrying the active [WatchMode] so the UI
/// can distinguish live events from polling fallback.
///
/// The watcher runs ON the remote host (local kernel watchers and SSHFS cannot
/// observe remotely-originated changes), streaming its event records back over
/// a dedicated SSH channel. If neither fswatch nor inotifywait is available, it
/// falls back to periodic polling so the UI still refreshes.
class RemoteWatchService {
  final CommandExecutor _executor;

  RemoteWatchService(this._executor);

  /// Maximum consecutive event-watcher (re)start attempts before degrading to
  /// polling. A watcher that dies then keeps failing to re-arm (SSH blip, killed
  /// process, remote OOM) must never leave the UI silently un-refreshed.
  static const int _maxRestarts = 3;

  /// Cap on the un-delimited stdout buffer. A watcher tool that streams partial
  /// output without ever emitting the record delimiter (a wedged or misbehaving
  /// fswatch/inotifywait) would otherwise grow `buffer` without bound. Past this
  /// we drop what's accumulated and resync on the next delimiter.
  static const int _maxBufferChars = 1 << 20; // 1 MiB

  Stream<RepoWatchEvent> watch(
    String repoPath, {
    Duration trailing = const Duration(milliseconds: 150),
    Duration maxWait = const Duration(seconds: 1),
    Duration minInterval = const Duration(seconds: 1),
    Duration pollInterval = const Duration(seconds: 5),
    Duration recoveryInterval = const Duration(minutes: 3),
  }) {
    late final StreamController<RepoWatchEvent> controller;
    SSHStreamHandle? handle;
    StreamSubscription<String>? sub;
    Timer? pollTimer;
    Timer? restartTimer;
    Timer? recoveryTimer;
    Coalescer? coalescer;
    var buffer = '';
    var mode = WatchMode.stopped;
    var cancelled = false;
    var restarts = 0;
    // Cached across restarts within this stream's lifetime — the answer can't
    // change between one blip's retries, so there's no need to re-probe the
    // remote for it every time. Cleared while recovering from polling (below),
    // since enough time has passed there that it's worth re-checking.
    _WatcherTool? cachedTool;
    // Forward-declared so `startPolling`'s recovery timer (below) can call
    // them; both are assigned before `watch()` returns, and neither is
    // invoked until a Timer fires or the stream is listened to.
    late Future<void> Function() start;
    late void Function() scheduleRestart;

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
      // A watcher that degrades to polling (repeated restart failures, or no
      // watcher tool found) must not stay degraded for the rest of the
      // session — periodically retry event-driven watching so a recovered
      // network (or a since-installed fswatch/inotifywait) is picked back up.
      recoveryTimer?.cancel();
      recoveryTimer = Timer.periodic(recoveryInterval, (_) {
        if (cancelled) return;
        restarts = 0;
        cachedTool = null;
        start().catchError((_) => scheduleRestart());
      });
    }

    Future<void> teardownWatcher() async {
      // Cancel the stdout subscription *before* dropping `coalescer`: the
      // listener dereferences `coalescer!`, so a chunk delivered in the window
      // between nulling it and cancelling the sub would throw a null-check
      // error inside the stream callback.
      await sub?.cancel();
      sub = null;
      coalescer?.cancel();
      coalescer = null;
      buffer = '';
      await handle?.cancel();
      handle = null;
    }

    scheduleRestart = () {
      if (cancelled || controller.isClosed) return;
      if (restarts >= _maxRestarts) {
        startPolling();
        return;
      }
      mode = WatchMode.stopped;
      // Emit immediately — without this, subscribers keep seeing whatever
      // mode was last emitted (usually `eventDriven`) for the entire restart
      // backoff window, so the UI's "watching" dot stayed lit green through a
      // real outage instead of going grey with the "Watcher stopped"
      // affordance it already has for exactly this state.
      emit();
      restarts++;
      restartTimer?.cancel();
      restartTimer = Timer(Duration(seconds: restarts * 2), () {
        if (cancelled || controller.isClosed) return;
        start().catchError((_) => scheduleRestart());
      });
    };

    start = () async {
      // An active attempt is underway — pause the polling-recovery retries
      // until it's clear whether this one succeeds.
      recoveryTimer?.cancel();
      recoveryTimer = null;
      await teardownWatcher();
      if (cancelled) return;

      final tool = cachedTool ??= await _detectWatcher(repoPath);
      if (cancelled) return;

      if (tool == _WatcherTool.none) {
        startPolling();
        return;
      }

      mode = WatchMode.eventDriven;
      coalescer = Coalescer(
        trailing: trailing,
        maxWait: maxWait,
        minInterval: minInterval,
        onFire: emit,
      );

      final newHandle = await _executor.executeStream(
        repoPath: repoPath,
        gitArgs: _watcherArgs(tool),
      );
      if (cancelled) {
        await newHandle.cancel();
        return;
      }
      handle = newHandle;

      final delimiter = tool == _WatcherTool.fswatch ? '\u0000' : '\n';
      sub = newHandle.stdout.listen(
        (chunk) {
          restarts = 0;
          mode = WatchMode.eventDriven;
          buffer += chunk;
          var idx = buffer.indexOf(delimiter);
          while (idx >= 0) {
            final event = buffer.substring(0, idx);
            buffer = buffer.substring(idx + 1);
            if (shouldTriggerWatch(event)) coalescer!.signal();
            idx = buffer.indexOf(delimiter);
          }
          // Whatever remains is an unterminated partial record. If it has grown
          // past a sane bound, the watcher is emitting output that never
          // completes a record — drop it and resync on the next delimiter
          // rather than buffering unbounded.
          if (buffer.length > _maxBufferChars) {
            developer.log(
              'watcher output exceeded $_maxBufferChars chars with no '
              'delimiter; dropping buffered partial',
              name: 'RemoteWatchService',
            );
            buffer = '';
          }
        },
        onDone: scheduleRestart,
        onError: (Object _) => scheduleRestart(),
      );

      // The watcher is now armed. Announce it with one eventDriven tick so the
      // status dot turns green immediately (and pulls a fresh status) instead of
      // sitting grey — indistinguishable from "stopped" — until the first file
      // change happens to arrive. This does NOT reset the restart budget: only a
      // real event (a stdout chunk) counts as proof the watcher is healthy, so a
      // watcher that arms then dies repeatedly still degrades to polling.
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

  Future<_WatcherTool> _detectWatcher(String repoPath) async {
    final result = await _executor.execute(
      repoPath: repoPath,
      gitArgs: [
        'sh',
        '-c',
        'if command -v fswatch >/dev/null 2>&1; then echo fswatch; '
            'elif command -v inotifywait >/dev/null 2>&1; then echo inotifywait; '
            'else echo none; fi',
      ],
    );
    switch (result.stdout.trim()) {
      case 'fswatch':
        return _WatcherTool.fswatch;
      case 'inotifywait':
        return _WatcherTool.inotifywait;
      default:
        return _WatcherTool.none;
    }
  }

  List<String> _watcherArgs(_WatcherTool tool) {
    switch (tool) {
      case _WatcherTool.fswatch:
        return [
          'fswatch',
          '-0',
          '--latency',
          '0.5',
          '--exclude',
          r'\.git/.*\.lock$',
          '--exclude',
          r'\.git/objects/',
          '--exclude',
          r'\.git/logs/',
          '--exclude',
          r'\.git/fsmonitor--daemon/',
          '.',
        ];
      case _WatcherTool.inotifywait:
        // inotifywait writes events with stdio, which **block-buffers** when
        // stdout is a pipe (our SSH channel has no TTY). A single change (~a few
        // bytes) would then sit unflushed in the ~4KB buffer and never reach the
        // app, so the live watcher looks dead. `stdbuf -oL` forces line-buffered
        // output so each event flushes immediately; fall back to bare
        // inotifywait if stdbuf is unavailable. (fswatch flushes per batch on
        // its own, so it needs no such wrapper.)
        return [
          'sh',
          '-c',
          'if command -v stdbuf >/dev/null 2>&1; then '
              'exec stdbuf -oL inotifywait -m -r '
              '-e modify,create,delete,move --format %w%f .; '
              'else exec inotifywait -m -r '
              '-e modify,create,delete,move --format %w%f .; fi',
        ];
      case _WatcherTool.none:
        return const [];
    }
  }

}
