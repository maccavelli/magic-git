// The SSH channel a watcher arm opens, as a test double.
//
// Eleven hand-rolled versions of this existed across ten files, five of them
// byte-identical. That was not untidiness: these doubles encode the ARM
// PROTOCOL — what a live watcher's channel does and when — and eleven copies
// means a protocol change has no single place to land. MADR 0044 changed it
// (an arm now settles on a readiness marker rather than on a 250 ms timer),
// seven files went red in their own terms, and the plan that made the change
// undercounted the doubles by seven because there was nowhere to look.
//
// What the copies got wrong is worth stating precisely, because it is the
// failure mode this file exists to prevent: a double that never wrote to
// stderr was modelling a host that cannot exist. The arming script emits
// `watchArmedMarker` before the watcher looks at the filesystem, so "silent"
// was only ever true of EVENTS, never of the channel. They did not go stale —
// they described something false, and passed.
//
// See docs/0044-MADR-the-watcher-follows-the-active-tab.md, amendment 0044.2.

import 'dart:async';

import 'package:remote_magic_git/core/git/bounded_watch.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';

/// A watcher's channel, in one of the three states a test ever needs.
///
/// Named constructors rather than flags, because what the eleven doubles
/// disagreed on was the SCENARIO — did this arm succeed, was it refused, did
/// the host say nothing at all — and a boolean called `announcesReadiness` at a
/// call site says none of that. Everything else they varied on (an observable
/// teardown, a slow teardown, drivable output) is an option on
/// [FakeWatcherHandle.armed], because each is something a test asserts about
/// rather than a different kind of channel.
class FakeWatcherHandle implements CommandStreamHandle {
  FakeWatcherHandle._({
    required this.stderrOnListen,
    required int? exitCode,
    required bool exitsAtOnce,
    this.cancelDelay = Duration.zero,
    this.onTeardown,
  }) : _exitWith = exitCode {
    if (exitsAtOnce) _exit.complete(exitCode);
  }

  /// A watcher that armed and is waiting — the healthy steady state, and what
  /// nine of the eleven doubles were trying to be.
  ///
  /// Announces [watchArmedMarker] and never exits, which is the pair that
  /// matters: `exitCode` completing is how a refusal is detected, so a live
  /// watcher must never complete it, and the marker is the only other thing
  /// that can settle the arm.
  factory FakeWatcherHandle.armed({
    Duration cancelDelay = Duration.zero,
    void Function()? onTeardown,
  }) => FakeWatcherHandle._(
    stderrOnListen: watchArmedMarker,
    exitCode: null,
    exitsAtOnce: false,
    cancelDelay: cancelDelay,
    onTeardown: onTeardown,
  );

  /// A script-level refusal: the process has already exited with [code].
  ///
  /// Emits no marker, and that is the point rather than an omission — both
  /// refusals exit before the script reaches the marker, so a double that
  /// announced one would let the arm read a refusal as a live watcher and
  /// silently disable the exclusion the lock exists for.
  ///
  /// [stderrLine] is what the script said on its way out, e.g.
  /// `mg-watch: lock held by <token>`, which the arm reads to name the
  /// incumbent.
  factory FakeWatcherHandle.refused(int code, {String? stderrLine}) =>
      FakeWatcherHandle._(
        stderrOnListen: stderrLine,
        exitCode: code,
        exitsAtOnce: true,
      );

  /// A host that produces neither signal: no marker, no exit.
  ///
  /// The only thing `RemoteWatchService.armSignalCeiling` is for. Nothing on a
  /// real host is known to behave this way — which is exactly why a test has to
  /// construct it deliberately, and why this is not the default.
  factory FakeWatcherHandle.silentHost() => FakeWatcherHandle._(
    stderrOnListen: null,
    exitCode: null,
    exitsAtOnce: false,
  );

  /// Written to stderr when the arm first subscribes, or null for a channel
  /// that says nothing.
  ///
  /// ON FIRST LISTEN, never from the constructor. A broadcast controller drops
  /// what is added before a listener attaches, where the real SSH stream queues
  /// it (`SSHSession._stderrController`, 0024 H3) — so a double that announced
  /// early would settle the arm before the race began and prove nothing about
  /// the ordering it exists to pin.
  final String? stderrOnListen;

  /// How long teardown takes to finish.
  ///
  /// Non-zero only where a test cares about the ORDER of a teardown against the
  /// next arm — the window MADR 0043 F4 measured on a real host.
  final Duration cancelDelay;

  /// Called once, when [cancel] completes. Replaces the `_log.add('teardown')`
  /// one double grew and the bare flag three others did.
  final void Function()? onTeardown;

  final int? _exitWith;
  final _exit = Completer<int?>();
  final _out = StreamController<String>.broadcast();
  late final StreamController<String> _err = StreamController<String>.broadcast(
    onListen: () {
      final line = stderrOnListen;
      if (line != null && !_err.isClosed) _err.add('$line\n');
    },
  );

  /// True once [cancel] has run.
  var cancelled = false;

  /// Chunks the service's listener has actually taken from stdout.
  ///
  /// Delivery is one event per microtask and the listener body is synchronous,
  /// so once this reaches the number pushed, the last callback has run — which
  /// is how a test knows the parse happened without sleeping.
  var delivered = 0;

  /// How many times each stream has been subscribed.
  ///
  /// Not preserved from any of the eleven — added, because "exactly one stderr
  /// listener, on every path" is the invariant that let `_incumbentToken` and
  /// its second 250 ms timeout be deleted (MADR 0044 phase 2), and nothing
  /// enforced it. A second listener on the real dartssh2 stream throws.
  var stdoutListens = 0;
  var stderrListens = 0;

  /// Pushes a stdout chunk, as a watcher emitting event records would.
  void emitStdout(String chunk) {
    if (!_out.isClosed) _out.add(chunk);
  }

  /// Pushes a stderr line, as a watcher reporting a diagnostic would.
  void emitStderr(String chunk) {
    if (!_err.isClosed) _err.add(chunk);
  }

  /// Ends the process with [code], or with this handle's own status.
  void exitNow([int? code]) {
    if (!_exit.isCompleted) _exit.complete(code ?? _exitWith);
  }

  @override
  Stream<String> get stdout {
    stdoutListens++;
    return _out.stream.map((c) {
      delivered++;
      return c;
    });
  }

  @override
  Stream<String> get stderr {
    stderrListens++;
    return _err.stream;
  }

  @override
  Future<int?> get exitCode => _exit.future;

  @override
  Future<void> cancel() async {
    if (cancelled) return;
    cancelled = true;
    if (cancelDelay > Duration.zero) await Future<void>.delayed(cancelDelay);
    if (!_exit.isCompleted) _exit.complete(null);
    // NOT AWAITED, and that is load-bearing. A refusal is torn down before the
    // stdout listener is attached, and closing an unsubscribed
    // single-subscription controller returns a future that never completes —
    // `await handle.cancel()` hangs and the arm never returns. That cost a
    // debugging session once, in a comment only one of the eleven could see.
    // The real handle closes an SSH session and has no such wait.
    unawaited(_out.close());
    unawaited(_err.close());
    onTeardown?.call();
  }
}
