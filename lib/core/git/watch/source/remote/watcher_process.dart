import 'dart:async';
import 'dart:developer' as developer;

import '../../../../ssh/ssh_command_executor.dart';
import '../../../bounded_watch.dart';
import '../../../remote_watch_service.dart' show RemoteWatcherTool;
import '../../../watch_path_filter.dart';
import '../../watch_timings.dart';
import '../watch_source.dart' show WatchUnavailableReason;
import 'record_splitter.dart';
import 'stderr_line_reader.dart';

/// What settled an arm: a refusal's exit status, or the readiness marker.
///
/// A record rather than a sentinel exit code — `null` is a legitimate status
/// for a process killed by a signal, so any in-band marker would collide with
/// it (MADR 0044).
typedef _ArmProbe = ({int? exit, bool ready});

/// How opening a watcher process ended.
sealed class WatcherOpen {
  const WatcherOpen();
}

/// The watcher is running and reporting.
final class WatcherOpened extends WatcherOpen {
  const WatcherOpened(this.process);
  final WatcherProcess process;
}

/// The host script refused the arm by exit status.
final class WatcherRefused extends WatcherOpen {
  const WatcherRefused(
    this.reason, {
    required this.incumbent,
    required this.discard,
  });
  final WatchUnavailableReason reason;

  /// The token that holds the lock, read when asked rather than when the
  /// refusal was decided: the line naming it can arrive just after the status.
  final String? Function() incumbent;

  /// Cancels the stderr listener and the channel.
  final Future<void> Function() discard;
}

/// The caller cancelled while the channel was opening.
final class WatcherCancelled extends WatcherOpen {
  const WatcherCancelled(this.discard);

  /// Cancels the channel.
  final Future<void> Function() discard;
}

/// The transport has no stream channel left for a watcher.
final class WatcherBudgetSpent extends WatcherOpen {
  const WatcherBudgetSpent(this.error);
  final SSHStreamBudgetExhausted error;
}

/// One watcher process on the host: its channel, the race that decides its
/// arm, and its output.
///
/// It owns no claims. The lease, the lock and the budget are the source's, and
/// the source releases them in the order the admission design fixes (plan
/// decision (e)), which is why a refusal hands back a [WatcherRefused.discard]
/// rather than tearing itself down.
final class WatcherProcess {
  WatcherProcess._(this._stdout, this._stderr, this._handle);

  final StreamSubscription<String> _stdout;
  final StreamSubscription<String> _stderr;
  final CommandStreamHandle _handle;

  /// Opens a watcher running [args] and settles its arm.
  static Future<WatcherOpen> open({
    required CommandExecutor executor,
    required String repoPath,
    required List<String> args,
    required RemoteWatcherTool tool,
    required BoundedWatchSpec? spec,
    required WatchTimings timings,
    required bool Function() isCancelled,
    required void Function() onActivity,
    required void Function(String path) onPath,
    required void Function(String cause) onDied,
    void Function(String line)? onDiagnostic,
  }) async {
    final CommandStreamHandle handle;
    try {
      handle = await executor.executeStream(repoPath: repoPath, gitArgs: args);
    } on SSHStreamBudgetExhausted catch (e) {
      // Deterministic, not a blip: retrying just hits the same wall (0024 M2).
      return WatcherBudgetSpent(e);
    }
    if (isCancelled()) return WatcherCancelled(handle.cancel);

    // STDERR IS READ FROM HERE, NOT FROM THE ARMED PATH.
    //
    // It carries three things and the arm needs the first two before it can
    // decide anything: the readiness marker that says this arm succeeded, the
    // incumbent's token when it did not, and the watcher's own diagnostics for
    // the rest of its life. ONE listener, on every path: dartssh2's stderr is
    // single-subscription, so a second listener would throw. Attaching before
    // the race also shortens the window in which `SSHSession._stderrController`
    // queues unread output in the Dart heap (0024 H3).
    final ready = Completer<void>();
    String? incumbent;
    // What each line MEANS is decided by the reader; what to do about it stays
    // here, where the race and the diagnostics live (MADR 0045 F6).
    final stderrLines = StderrLineReader(
      maxDiagnosticLines: timings.maxDiagnosticLines,
      maxBufferChars: timings.maxBufferChars,
    );
    final errSub = handle.stderr.listen((chunk) {
      for (final line in stderrLines.add(chunk)) {
        switch (line) {
          case ReadinessMarker():
            // Addressed to this client, not to the user.
            if (!ready.isCompleted) ready.complete();
          case LockHeldBy(:final token):
            incumbent ??= token;
          case Diagnostic(line: final text):
            developer.log(text, name: 'RemoteWatchService');
            onDiagnostic?.call(text);
        }
      }
    }, onError: (Object _) {});

    Future<void> discard() async {
      // The listener's cancel is not awaited: it stops delivery at the call,
      // and its future waits on nothing — the channel is what `handle.cancel`
      // releases.
      unawaited(errSub.cancel());
      await handle.cancel();
    }

    // A script-level refusal arrives as an exit STATUS, not an exception: the
    // arming scripts exit with a distinct code when none of their paths exist
    // yet (0022 M6) or when another live watcher already holds the repository
    // (0041 F12). EVERY arm reads this; the lock refusal can come from the
    // recursive script too.
    //
    // SETTLED ON A SIGNAL, NOT ON A CLOCK (MADR 0044 F7). The race is
    // well-ordered because both refusals exit BEFORE the marker is emitted, so a
    // refused arm cannot produce it and an armed one always does.
    final probe =
        await Future.any<_ArmProbe>([
          handle.exitCode.then((c) => (exit: c, ready: false)),
          ready.future.then((_) => (exit: null, ready: true)),
        ]).timeout(
          timings.armSignalCeiling,
          onTimeout: () => (exit: null, ready: false),
        );
    // A record rather than a sentinel exit code, because null is a legitimate
    // status for a process killed by a signal.
    final early = probe.exit;
    if (!probe.ready && early == null) {
      // Neither signal inside the ceiling. Nothing on a real host is known to
      // do this, which is exactly why it is worth saying out loud.
      onDiagnostic?.call(
        'no readiness signal from the watcher on $repoPath within '
        '${timings.armSignalCeiling.inMilliseconds}ms — arming anyway',
      );
    }
    if (early == boundedWatchLockedExit) {
      return WatcherRefused(
        WatchUnavailableReason.heldByAnother,
        incumbent: () => incumbent,
        discard: discard,
      );
    }
    if (spec != null && early == boundedWatchNoPathsExit) {
      return WatcherRefused(
        WatchUnavailableReason.noWatchedPaths,
        incumbent: () => null,
        discard: discard,
      );
    }

    final delimiter = tool == RemoteWatcherTool.fswatch ? '\u0000' : '\n';
    // Linear splitting lives in the splitter (0024 A1). Past the cap the
    // watcher is emitting output that never completes a record: drop the
    // partial and resync on the next delimiter rather than buffering unbounded.
    final records = RecordSplitter(
      delimiter: delimiter,
      maxBufferChars: timings.maxBufferChars,
      onOverflow: () => developer.log(
        'watcher output exceeded ${timings.maxBufferChars} '
        'chars with no delimiter; dropping buffered partial',
        name: 'RemoteWatchService',
      ),
    );
    // Handed to the process, whose close() cancels it; the lint cannot see that.
    // ignore: cancel_subscriptions
    final stdoutSub = handle.stdout.listen(
      (chunk) {
        onActivity();
        for (final event in records.add(chunk)) {
          // Bounded mode watches absolute paths; remap them to the
          // repo-relative (`.git/…` for git-dir) shape the filter expects.
          // Recursive mode already emits repo-relative paths (cwd = repo).
          final path = spec == null
              ? event
              : relativizeBoundedEvent(event, spec);
          if (path != null && shouldTriggerWatch(path)) onPath(path);
        }
      },
      // WHY the stream ended, so a watcher that exited on its own is told apart
      // from a channel that errored under it (MADR 0041's open question).
      onDone: () => onDied('watcher exited'),
      onError: (Object e) => onDied('stream error: ${e.runtimeType}'),
    );
    return WatcherOpened(WatcherProcess._(stdoutSub, errSub, handle));
  }

  /// Cancels the output listeners, then the channel — stdout first — and
  /// completes once the channel has closed.
  ///
  /// Only the channel's close is awaited. A listener's cancel stops delivery
  /// at the call, and on the SSH session's streams its future waits on nothing
  /// (no `onCancel`); awaiting it only made a teardown under `fakeAsync` stall
  /// before it reached the channel (MADR 0045 plan, deviation (s)).
  Future<void> close() async {
    unawaited(_stdout.cancel());
    unawaited(_stderr.cancel());
    await _handle.cancel();
  }
}
