import 'package:flutter/widgets.dart';

/// [WidgetsFlutterBinding] with a self-healing frame clock, used by EVERY
/// secondary-window engine.
///
/// The macOS embedder's vsync waiter is armed when the engine runs. A custom
/// entrypoint forces run() BEFORE the view can join a window (view load
/// auto-launches `main` otherwise), so a secondary engine's waiter falls back
/// to a viewless path whose frame timestamps never advance — probe evidence:
/// frames render (100-frame batches) but `vsyncStart=0µs` on every frame and an
/// AnimationController pinned at 0.0 forever. Frozen animation clocks leave
/// every pushed route (menus, sheets, dialogs) stuck at its entrance
/// transition's opacity-0 frame: an invisible modal barrier. This is also what
/// makes an `allowHeadlessExecution` engine survivable while it has no attached
/// view — so it's load-bearing for occlusion-based pausing too.
///
/// Fix at the exact seam the timestamps enter Dart: when the engine's clock is
/// not advancing, substitute a monotonic wall clock. Healthy timestamps pass
/// through untouched, so this degrades to a no-op if a future Flutter fixes the
/// embedder (re-check via the "vsync probe" line in hw-debug.log on upgrades).
class SecondaryWindowBinding extends WidgetsFlutterBinding {
  // Canonical custom-binding pattern: `WidgetsBinding.instance` THROWS on an
  // uninitialized isolate, so existence is tracked with our own field set in
  // initInstances, never probed through the framework getter.
  static SecondaryWindowBinding? _instance;

  static SecondaryWindowBinding ensureInitialized() {
    if (_instance == null) SecondaryWindowBinding();
    return _instance!;
  }

  @override
  void initInstances() {
    super.initInstances();
    _instance = this;
  }

  final Stopwatch _clock = Stopwatch()..start();
  Duration _lastPassed = Duration.zero;

  @override
  void handleBeginFrame(Duration? rawTimeStamp) {
    // null = warm-up frame; the framework substitutes its own stopwatch.
    if (rawTimeStamp == null) return super.handleBeginFrame(null);
    var timeStamp = rawTimeStamp;
    if (timeStamp <= _lastPassed) {
      // Engine clock frozen (or rewound): synthesize forward motion.
      timeStamp = _clock.elapsed;
      if (timeStamp <= _lastPassed) {
        timeStamp = _lastPassed + const Duration(microseconds: 1);
      }
    }
    _lastPassed = timeStamp;
    super.handleBeginFrame(timeStamp);
  }
}
