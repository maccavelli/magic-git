import '../../bounded_watch.dart';
import '../../watch_lifecycle.dart';
import 'watch_source.dart';

/// Drives `watchLifecycle`'s arm callback from a [WatchSource].
///
/// Temporary: phase 4's engine consumes sources directly and this is deleted
/// with `watchLifecycle`. Until then it is the whole translation — one signal,
/// one hook — so neither side has to know the other's shape.
Future<WatchArm> Function(WatchHooks hooks) armFromSource(
  WatchSource source, {
  required String repoPath,
  required int Function() attempt,
  BoundedWatchSpecSource? bounded,
}) => (hooks) async {
  final outcome = await source.arm(
    ArmRequest(
      repoPath: repoPath,
      bounded: bounded,
      cancelled: hooks.cancelled,
      attempt: attempt(),
    ),
  );
  switch (outcome) {
    case SourceUnavailable(:final reason):
      return WatchUnavailable(reason);
    case SourceAborted():
      return const WatchAborted();
    case SourceArmed(source: final armed):
      final subscription = armed.signals.listen((signal) {
        switch (signal) {
          case PathChanged(:final path):
            hooks.signalPath(path);
          case SourceActivity():
            hooks.noteActivity();
          case RearmRequested():
            hooks.rearm();
          case SourceDied():
            hooks.scheduleRestart();
        }
      });
      return WatchArmed(() async {
        // The source first, in its own order — budget, channel, host claims,
        // exclusion — and only then this subscription, so nothing it reports
        // while closing is dropped.
        await armed.close();
        await subscription.cancel();
      });
  }
};
