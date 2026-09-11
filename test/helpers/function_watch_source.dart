import 'dart:async';

import 'package:remote_magic_git/core/git/watch/source/watch_source.dart';

/// A [WatchSource] whose arm is a function, so a test decides every outcome and
/// when it arrives.
final class FunctionWatchSource implements WatchSource {
  const FunctionWatchSource(this._arm);

  final Future<SourceArm> Function(ArmRequest request) _arm;

  @override
  Future<SourceArm> arm(ArmRequest request) => _arm(request);
}

/// An armed source a test drives by hand.
///
/// Its signals are synchronous and single-subscription, like both real
/// sources: anything reported before the engine listens is kept until it does.
final class FakeArmedSource implements ArmedSource {
  FakeArmedSource({this.onClose});

  /// Called on every [close], before the signals close.
  final void Function()? onClose;

  final _signals = StreamController<SourceSignal>(sync: true);

  /// How many times [close] was called.
  var closes = 0;

  bool get closed => closes > 0;

  void signalPath(String path) => _emit(PathChanged(path));

  void noteActivity() => _emit(const SourceActivity());

  void rearm() => _emit(const RearmRequested());

  void die([String cause = 'died']) => _emit(SourceDied(cause));

  void _emit(SourceSignal signal) {
    if (!_signals.isClosed) _signals.add(signal);
  }

  @override
  Stream<SourceSignal> get signals => _signals.stream;

  @override
  Future<void> close() async {
    closes++;
    onClose?.call();
    // Not awaited: an unlistened single-subscription stream never finishes
    // closing.
    unawaited(_signals.close());
  }
}
