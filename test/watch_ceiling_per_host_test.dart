// MADR 0039 F4. The watcher ceiling is two live watchers **per host**, and the
// counter has to be keyed that way because the process now holds one live
// session per tab (multi-tab, `11689cc`, 2026-07-12).
//
// The check this replaces could not see the defect. `watch_ceiling_recovery_test`
// asserts that two service *instances* share one ceiling — true whatever the
// counter is keyed by, and still asserted there, unchanged. What was never
// asserted is that two *hosts* do not: with a global counter, whichever tab
// armed first spent the whole budget and a second host was starved having
// consumed nothing, degrading to polling at 48 host processes per minute
// (MADR 0026).

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/remote_watch_service.dart';
import 'package:remote_magic_git/core/git/watch/admission/host_watcher_budget.dart';
import 'package:remote_magic_git/core/git/watch/admission/watch_admission.dart';
import 'package:remote_magic_git/core/git/watch_diagnostics.dart';
import 'package:remote_magic_git/core/git/watch_event.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'helpers/conventional_git_dir.dart';
import 'helpers/fake_watcher_handle.dart';
import 'helpers/watch_settle.dart';

/// Reports a watcher tool and arms successfully, so every arm holds a slot.
class _ArmsAlways extends SSHCommandExecutor {
  _ArmsAlways() : super(SSHClientManager());

  @override
  Future<SSHCommandResult> execute({
    required String repoPath,
    required List<String> gitArgs,
    Map<String, String>? extraEnv,
    String? stdin,
    Duration timeout = SSHCommandExecutor.defaultTimeout,
    int retries = 0,
    ExecLane lane = ExecLane.exclusive,
    bool compress = false,
    Duration? activityIdle,
    OperationDescriptor? operation,
    OperationEventCallback? onOperationEvent,
    CommandOutputCallback? onOutput,
  }) async =>
      const SSHCommandResult(exitCode: 0, stdout: 'inotifywait\n', stderr: '');

  @override
  Future<SSHStreamHandle> executeStream({
    required String repoPath,
    required List<String> gitArgs,
    Map<String, String>? extraEnv,
    Duration openTimeout = SSHCommandExecutor.defaultTimeout,
    OperationDescriptor? operation,
    OperationEventCallback? onOperationEvent,
  }) async => FakeWatcherHandle.armed();
}

/// A service on [host] whose ceiling is two.
///
/// The cap is derived from the transport's stream budget since MADR 0041 phase
/// 4, so the budget is stated here rather than inherited from a constant: 4
/// channels less the 2 reserved for the CI trace and clone progress. Every test
/// in this file is about how a budget of two is shared BETWEEN hosts, so the
/// number itself has to be deliberate.
RemoteWatchService _serviceOn(String host, HostWatcherBudget budget) =>
    RemoteWatchService(
      _ArmsAlways(),
      hostKey: () => host,
      streamBudget: () => 4,
      admission: WatchAdmission(budget: budget),
      gitDirOf: conventionalGitDir,
    );

/// Refused arms this repo has recorded. Every ceiling refusal files an
/// `armFailed` transition, so this counts attempts that could only lose —
/// which is the whole cost of announcing a release to the wrong host.
int _ceilingRefusals(String repoPath) => watchDiagnostics
    .forRepo(repoPath)
    .records
    .where(
      (r) =>
          r.kind == WatchTransition.armFailed && r.cause.startsWith('ceiling'),
    )
    .length;

void main() {
  late HostWatcherBudget hostBudget;

  setUp(() {
    hostBudget = HostWatcherBudget();
    watchDiagnostics.clear();
  });
  // Wait for in-flight arms before the next test starts: an arm takes real time
  // to decide (see [settleArm]), so a test can end with one still running. Each
  // test counts against its own budget (MADR 0045 phase 2), so a late release
  // can no longer skew the next test's count as it did when the counter was
  // process-wide.
  tearDown(() async {
    await settleArm();
  });

  test('one host filling its budget does not starve another host', () async {
    final alpha = _serviceOn('alpha', hostBudget);
    final beta = _serviceOn('beta', hostBudget);

    // Tab 1 (host alpha) takes both of alpha's slots.
    final a1 = alpha.watch('/one').listen((_) {});
    final a2 = alpha.watch('/two').listen((_) {});
    await settleArm();

    expect(hostBudget.liveFor('alpha'), 2);
    expect(hostBudget.liveFor('beta'), 0);

    // A third repo on alpha is correctly refused — the budget protects the host
    // from accumulating processes, and that has not changed.
    final refused = <RepoWatchEvent>[];
    final a3 = alpha.watch('/three').listen(refused.add);
    await settleArm();
    expect(refused.last.mode, WatchMode.polling);

    // Tab 2 is on a different host and has spent nothing. It must get a live
    // watcher. With a process-global counter it did not — this is F4.
    final onBeta = <RepoWatchEvent>[];
    final b1 = beta.watch('/one').listen(onBeta.add);
    await settleArm();

    expect(
      onBeta.last.mode,
      WatchMode.eventDriven,
      reason: 'host beta has its own budget and has consumed none of it',
    );
    expect(hostBudget.liveFor('beta'), 1);
    expect(hostBudget.liveTotal, 3, reason: 'alpha 2 + beta 1');

    await a1.cancel();
    await a2.cancel();
    await a3.cancel();
    await b1.cancel();
  });

  test('a freed slot wakes a repo waiting on that host, not another', () async {
    final alpha = _serviceOn('alpha', hostBudget);
    final beta = _serviceOn('beta', hostBudget);

    final a1 = alpha.watch('/one').listen((_) {});
    final a2 = alpha.watch('/two').listen((_) {});
    final b1 = beta.watch('/one').listen((_) {});
    final b2 = beta.watch('/two').listen((_) {});
    await settleArm();
    expect(hostBudget.liveFor('alpha'), 2);
    expect(hostBudget.liveFor('beta'), 2);

    // Both hosts now have a repo stuck on polling.
    final alphaWaiting = <RepoWatchEvent>[];
    final betaWaiting = <RepoWatchEvent>[];
    final a3 = alpha.watch('/three').listen(alphaWaiting.add);
    final b3 = beta.watch('/three').listen(betaWaiting.add);
    await settleArm();
    expect(alphaWaiting.last.mode, WatchMode.polling);
    expect(betaWaiting.last.mode, WatchMode.polling);

    // Free one slot on beta only.
    await b1.cancel();
    await settleArm();

    expect(
      betaWaiting.last.mode,
      WatchMode.eventDriven,
      reason: 'the waiting repo on beta takes the slot beta just freed',
    );
    expect(
      alphaWaiting.last.mode,
      WatchMode.polling,
      reason:
          'alpha is still full — a release elsewhere must not wake it into '
          'an arm attempt that can only be refused',
    );

    await a1.cancel();
    await a2.cancel();
    await a3.cancel();
    await b2.cancel();
    await b3.cancel();
  });

  test(
    'releasing credits the host that reserved, and the map empties',
    () async {
      final alpha = _serviceOn('alpha', hostBudget);

      final a1 = alpha.watch('/one').listen((_) {});
      await settleArm();
      expect(hostBudget.liveFor('alpha'), 1);

      await a1.cancel();
      await settleArm();

      expect(hostBudget.liveFor('alpha'), 0);
      expect(
        hostBudget.liveTotal,
        0,
        reason:
            'a released slot must not linger as a zero entry that reads as '
            'a leaked watcher in diagnostics',
      );
    },
  );

  test('a release elsewhere does not make a waiting repo re-probe', () async {
    // The mode is the same either way — a woken repo on a full host simply gets
    // refused again — so asserting the mode cannot see this. What differs is
    // the wasted work: an unfiltered release wakes every waiting repo on every
    // host, and each one runs an arm attempt that can only be refused. The
    // refusals are recorded, so they are what this counts. (Host commands are
    // NOT: the tool probe is cached for the stream's life, so a wake spends no
    // command and counting those would have proved nothing.)
    final alpha = _serviceOn('alpha', hostBudget);
    final beta = _serviceOn('beta', hostBudget);

    final a1 = alpha.watch('/one').listen((_) {});
    final a2 = alpha.watch('/two').listen((_) {});
    final b1 = beta.watch('/one').listen((_) {});
    final b2 = beta.watch('/two').listen((_) {});
    await settleArm();

    final alphaWaiting = <RepoWatchEvent>[];
    final a3 = alpha.watch('/three').listen(alphaWaiting.add);
    final b3 = beta.watch('/three').listen((_) {});
    await settleArm();
    expect(alphaWaiting.last.mode, WatchMode.polling);

    final refusalsBefore = _ceilingRefusals('/three');
    expect(refusalsBefore, greaterThan(0));

    // Free a slot on beta. Alpha is untouched and still full.
    await b1.cancel();
    await settleArm();

    expect(
      _ceilingRefusals('/three'),
      refusalsBefore,
      reason:
          'a slot freed on another host must not wake this repo into an '
          'arm attempt it can only lose',
    );
    expect(alphaWaiting.last.mode, WatchMode.polling);

    await a1.cancel();
    await a2.cancel();
    await a3.cancel();
    await b2.cancel();
    await b3.cancel();
  });

  test('a slot is credited back to the host that reserved it', () async {
    // The connection can move under a long-lived service — a reconnect to a
    // different host, a backend switch. Releasing against whatever `hostKey()`
    // says NOW would refund a host that never paid, and leave the reserving
    // host's budget permanently short by one.
    var host = 'alpha';
    final exec = _ArmsAlways();
    final service = RemoteWatchService(
      exec,
      hostKey: () => host,
      streamBudget: () => 4,
      admission: WatchAdmission(budget: hostBudget),
      gitDirOf: conventionalGitDir,
    );

    final sub = service.watch('/one').listen((_) {});
    await settleArm();
    expect(hostBudget.liveFor('alpha'), 1);

    host = 'beta'; // the session moved while the watcher was live

    await sub.cancel();
    await settleArm();

    expect(
      hostBudget.liveFor('alpha'),
      0,
      reason: 'the slot must come back to alpha, which reserved it',
    );
    expect(
      hostBudget.liveFor('beta'),
      0,
      reason: 'beta never reserved anything and must not be credited',
    );
  });
}
