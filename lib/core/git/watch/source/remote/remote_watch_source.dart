import 'dart:async';

import '../../../../ssh/ssh_command_executor.dart';
import '../../../remote_watch_service.dart'
    show RemoteWatchService, RemoteWatcherTool, remoteWatcherArgs;
import '../../../watch_diagnostics.dart' show WatchTransition;
import '../../admission/watch_admission.dart';
import '../../watch_timings.dart';
import '../surface_rearm_policy.dart';
import '../watch_source.dart';
import 'git_dir_resolver.dart';
import 'watch_lease.dart';
import 'watcher_process.dart';
import 'watcher_tool_probe.dart';

/// A watcher on a remote host, composed of the units that each own one job:
/// the tool probe, the git-dir resolver, admission, the lease, the process and
/// the re-arm policy. This was one 503-line closure (MADR 0045 F6).
///
/// One source per watcher stream, so its caches live as long as that stream.
final class RemoteWatchSource implements WatchSource {
  RemoteWatchSource({
    required this.executor,
    required this.probe,
    required this.gitDirOf,
    required this.admission,
    required this.hostKey,
    required this.capacity,
    required this.timings,
    required this.record,
    this.onDiagnostic,
  }) : _rearmPolicy = SurfaceRearmPolicy(debounce: timings.rearmDebounce);

  /// Where the host commands go.
  final CommandExecutor executor;
  final WatcherToolProbe probe;
  final GitDirResolver gitDirOf;
  final WatchAdmission admission;
  final String Function() hostKey;

  /// The host's watcher ceiling, read on every arm.
  final int Function() capacity;
  final WatchTimings timings;

  /// Files one transition against this source's repository.
  final void Function(WatchTransition kind, String cause) record;
  final void Function(String line)? onDiagnostic;

  /// Debounces deliberate re-arms. Spans arms; cancelled by every close.
  final SurfaceRearmPolicy _rearmPolicy;

  /// This repository's resolved git dir, cached like the tool and forgotten
  /// with it.
  String? _gitDir;

  /// Forgets the cached tool and git dir, so the next arm asks the host again.
  /// Called while recovering from polling.
  void invalidateCaches() {
    probe.invalidate();
    _gitDir = null;
  }

  @override
  Future<SourceArm> arm(ArmRequest request) async {
    var cancelled = false;
    unawaited(request.cancelled.then((_) => cancelled = true));
    final repoPath = request.repoPath;

    // ONE identity per arm. Every re-arm is a new watcher instance with its own
    // lease and registry files (0027).
    final token = RemoteWatchService.newWatchToken();
    final tool = await probe.tool(repoPath);
    if (cancelled) return const SourceAborted();
    if (tool == RemoteWatcherTool.none) {
      record(WatchTransition.armFailed, 'no watcher tool');
      return const SourceUnavailable(WatchUnavailableReason.noTool);
    }

    // Resolved on every arm: the tracked-file set changes constantly on a
    // dotfiles repo, and a frozen surface missed newly tracked directories
    // (0022 H5).
    final bounded = request.bounded;
    final spec = bounded == null ? null : await bounded();
    if (cancelled) return const SourceAborted();

    // Resolved ONCE per arm and reused for the release: a connection that
    // changes host mid-arm must not credit the slot to a host that never paid.
    final host = hostKey();
    // The directory the host script locks, and so the key this session's
    // exclusion waits on. A scoped repository names it; any other asks git,
    // because `<repo>/.git` is a FILE in a linked worktree (MADR 0045 F10).
    final lockKey = spec?.gitDir ?? (_gitDir ??= await gitDirOf(repoPath));
    if (cancelled) return const SourceAborted();

    final AdmissionTicket ticket;
    switch (await admission.admit(
      host: host,
      capacity: capacity(),
      lockKey: lockKey,
      grace: timings.admissionGrace,
      cancelled: request.cancelled,
    )) {
      case RefusedCeiling(:final live, capacity: final ceiling):
        onDiagnostic?.call(
          'watcher ceiling reached for $host '
          '($live/$ceiling) — polling $repoPath instead',
        );
        record(WatchTransition.armFailed, 'ceiling $live/$ceiling');
        return const SourceUnavailable(WatchUnavailableReason.ceiling);
      case AdmissionCancelled():
        return const SourceAborted();
      case Admitted(ticket: final admitted):
        ticket = admitted;
    }

    final lease = WatchLease(
      executor: executor,
      repoPath: repoPath,
      gitDir: lockKey,
      token: token,
      timings: timings,
    );
    // Single-subscription, so nothing reported before the engine listens is
    // lost. SYNCHRONOUS, because a burst reports one path per record: queued
    // delivery cost a 20,000-record burst ~140 ms against the ~1 ms a direct
    // call took, and `a large burst costs linear time` caught it. Every add
    // is guarded: a listener can outlive the close.
    final signals = StreamController<SourceSignal>(sync: true);
    void emit(SourceSignal signal) {
      if (!signals.isClosed) signals.add(signal);
    }

    // EVERY exit from here releases the ticket, in one order: budget first, so
    // a repository refused by the ceiling can take the slot at once; host claims
    // next; the exclusion last, only once the host has given its lock back
    // (plan decision (e)). The explicit releases below each pair with their own
    // cause, and the catch-all is the guarantee (MADR 0040 F8).
    try {
      // STAMP THE LEASE BEFORE ARMING, and wait for it: the watcher's first act
      // is to test for it (0027 deviation (b)).
      await lease.stamp();

      final opened = await WatcherProcess.open(
        executor: executor,
        repoPath: repoPath,
        args: remoteWatcherArgs(
          tool,
          spec,
          pidFile: lease.pidFile,
          heartbeat: lease.heartbeatFile,
          lock: lease.lock,
        ),
        tool: tool,
        spec: spec,
        timings: timings,
        isCancelled: () => cancelled,
        onDiagnostic: onDiagnostic,
        onActivity: () => emit(const SourceActivity()),
        onPath: (path) {
          emit(PathChanged(path));
          // A bounded surface is derived from the index, so a git-state change
          // can mean it no longer covers every tracked directory (0022 H5).
          _rearmPolicy.onPath(
            path,
            bounded: spec != null,
            rearm: () => emit(const RearmRequested()),
            cancelled: () => cancelled,
          );
        },
        onDied: (cause) {
          record(WatchTransition.stopped, cause);
          emit(SourceDied(cause));
        },
      );

      switch (opened) {
        case WatcherBudgetSpent(:final error):
          ticket.releaseBudget();
          // The lease was stamped above and no watcher will ever read it.
          await lease.releaseHostClaims();
          ticket.releaseExclusion();
          onDiagnostic?.call('$error — falling back to polling for this repo');
          record(WatchTransition.armFailed, 'stream budget');
          unawaited(signals.close());
          return const SourceUnavailable(WatchUnavailableReason.streamBudget);
        case WatcherCancelled(:final discard):
          ticket.releaseBudget();
          await discard();
          await lease.releaseHostClaims();
          ticket.releaseExclusion();
          unawaited(signals.close());
          return const SourceAborted();
        case WatcherRefused(:final reason, :final incumbent, :final discard):
          ticket.releaseBudget();
          await discard();
          // A refusal never reaches a teardown, so without this every refused
          // arm strands its lease (MADR 0043 F6). It claimed no lock, and the
          // release declines to remove one this token does not own.
          await lease.releaseHostClaims();
          if (reason == WatchUnavailableReason.heldByAnother) {
            final token = incumbent();
            final held = token == null ? '' : ' (token $token)';
            onDiagnostic?.call(
              'another live watcher already holds $repoPath$held '
              '— polling here',
            );
            record(WatchTransition.armFailed, 'held by another watcher$held');
          } else {
            record(WatchTransition.armFailed, 'no watched paths');
          }
          ticket.releaseExclusion();
          unawaited(signals.close());
          return SourceUnavailable(reason);
        case WatcherOpened(:final process):
          lease.startHeartbeat();
          return SourceArmed(
            _ArmedRemote(signals, () async {
              ticket.releaseBudget();
              lease.stopHeartbeat();
              _rearmPolicy.cancel();
              await process.close();
              // AWAITED: the exclusion is released only after it, so "this
              // watcher is gone" means "the host lock is gone" (MADR 0043 F3,
              // F4).
              await lease.releaseHostClaims();
              // LAST. Only now may this session's next watcher of the
              // repository ask the host for the lock this one gave back.
              ticket.releaseExclusion();
              // Not awaited: an unlistened single-subscription stream never
              // finishes closing, and close() must not depend on a listener.
              unawaited(signals.close());
            }),
          );
      }
    } catch (_) {
      // Idempotent, so safe on paths that already released. The host claims
      // too: a failure past admission may have stamped a lease.
      ticket.releaseBudget();
      await lease.releaseHostClaims();
      ticket.releaseExclusion();
      unawaited(signals.close());
      // Rethrow rather than degrade: the engine turns a throw into a scheduled
      // restart, which is the right answer to a transport blip.
      rethrow;
    }
  }
}

final class _ArmedRemote implements ArmedSource {
  _ArmedRemote(this._signals, this._close);

  final StreamController<SourceSignal> _signals;
  final Future<void> Function() _close;

  @override
  Stream<SourceSignal> get signals => _signals.stream;

  @override
  Future<void> close() => _close();
}
