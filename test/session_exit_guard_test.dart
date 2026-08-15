// The dirty/pending disconnect guard (audit H8). Shipped without tests; this
// pins its actual branches.
//
// Two contracts here are easy to break by accident and are asserted
// explicitly: the confirm button's label is derived by a case-sensitive
// substring match on the *title* (so renaming a caller's title silently
// changes the button), and a failed status fetch BLOCKS the exit rather than
// letting it through.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/core/utils/git_porcelain_parser.dart';
import 'package:remote_magic_git/features/common/session_exit_guard.dart';

const _repo = '/srv/repo';

GitStatus _clean() =>
    GitStatus(branch: const GitBranchInfo(head: 'main'), files: const []);

GitStatus _dirty() => GitStatus(
  branch: const GitBranchInfo(head: 'main'),
  files: const [GitFileStatus(path: 'a.dart', statusX: '.', statusY: 'M')],
);

class _FakeGit extends GitService {
  _FakeGit({this._status, this.throwOnStatus = false})
    : super(SSHCommandExecutor(SSHClientManager()));

  final GitStatus? _status;
  final bool throwOnStatus;
  int statusCalls = 0;

  @override
  Future<GitStatus> status(String repoPath) async {
    statusCalls++;
    if (throwOnStatus) throw Exception('host unreachable');
    return _status ?? _clean();
  }
}

/// Pumps a bare host and returns both the context to hand the guard and the
/// container that owns the repo's state.
///
/// Deliberately NOT a repo view: those animate, and `pumpAndSettle` would
/// never return.
Future<({BuildContext context, ProviderContainer container})> _host(
  WidgetTester tester, {
  GitStatus? status,
  PendingOp pending = PendingOp.none,
  GitService? git,
  bool overrideStatus = true,
}) async {
  final container = ProviderContainer(
    overrides: [
      gitServiceProvider.overrideWithValue(git ?? _FakeGit(status: status)),
      if (overrideStatus)
        statusProvider(_repo).overrideWith((ref) async => status ?? _clean()),
      pendingOpProvider(_repo).overrideWith((ref) => pending),
    ],
  );
  addTearDown(container.dispose);

  late BuildContext captured;
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MacosApp(
        debugShowCheckedModeBanner: false,
        home: Builder(
          builder: (context) {
            captured = context;
            return const Center(child: Text('host'));
          },
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (context: captured, container: container);
}

void main() {
  testWidgets('a clean tree with no pending op exits without asking', (
    tester,
  ) async {
    final host = await _host(tester);

    final result = confirmSessionExit(
      host.context,
      host.container,
      repoPath: _repo,
      title: 'Log out?',
    );
    await tester.pumpAndSettle();

    expect(find.byType(MacosAlertDialog), findsNothing);
    expect(await result, isTrue);
  });

  testWidgets('a dirty tree asks, and Confirm proceeds', (tester) async {
    final host = await _host(tester, status: _dirty());

    final result = confirmSessionExit(
      host.context,
      host.container,
      repoPath: _repo,
      title: 'Log out?',
    );
    await tester.pumpAndSettle();

    expect(
      find.textContaining('You have uncommitted changes'),
      findsOneWidget,
    );
    await tester.tap(find.text('Log Out'));
    await tester.pumpAndSettle();
    expect(await result, isTrue);
  });

  testWidgets('Cancel keeps the session', (tester) async {
    final host = await _host(tester, status: _dirty());

    final result = confirmSessionExit(
      host.context,
      host.container,
      repoPath: _repo,
      title: 'Log out?',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(await result, isFalse);
  });

  testWidgets('Escape keeps the session', (tester) async {
    final host = await _host(tester, status: _dirty());

    final result = confirmSessionExit(
      host.context,
      host.container,
      repoPath: _repo,
      title: 'Log out?',
    );
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(await result, isFalse);
  });

  testWidgets('a clean tree still asks when an operation is mid-flight, and '
      'names it', (tester) async {
    final host = await _host(tester, pending: PendingOp.rebase);

    final result = confirmSessionExit(
      host.context,
      host.container,
      repoPath: _repo,
      title: 'Log out?',
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('A rebase is still in progress'), findsOneWidget);
    // The only Recovery affordance is this prose — there is no button.
    expect(find.textContaining('Use Recovery'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(await result, isFalse);
  });

  testWidgets('dirty AND pending shows both reasons plus the host note', (
    tester,
  ) async {
    final host = await _host(
      tester,
      status: _dirty(),
      pending: PendingOp.cherryPick,
    );

    final result = confirmSessionExit(
      host.context,
      host.container,
      repoPath: _repo,
      title: 'Log out?',
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('You have uncommitted changes'), findsOneWidget);
    expect(
      find.textContaining('A cherryPick is still in progress'),
      findsOneWidget,
    );
    expect(
      find.textContaining('does not delete files on the host'),
      findsOneWidget,
    );

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(await result, isFalse);
  });

  group('confirm label is derived from the title', () {
    testWidgets('"Close tab?" yields a Close Tab button', (tester) async {
      final host = await _host(tester, status: _dirty());

      final result = confirmSessionExit(
        host.context,
        host.container,
        repoPath: _repo,
        title: 'Close tab?',
      );
      await tester.pumpAndSettle();

      // Substring match on 'Close', case-sensitive — a caller that retitles to
      // e.g. 'close tab?' would silently get the Log Out button instead.
      expect(find.text('Close Tab'), findsOneWidget);
      expect(find.text('Log Out'), findsNothing);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(await result, isFalse);
    });

    testWidgets('"Log out?" yields a Log Out button', (tester) async {
      final host = await _host(tester, status: _dirty());

      final result = confirmSessionExit(
        host.context,
        host.container,
        repoPath: _repo,
        title: 'Log out?',
      );
      await tester.pumpAndSettle();

      expect(find.text('Log Out'), findsOneWidget);
      expect(find.text('Close Tab'), findsNothing);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(await result, isFalse);
    });
  });

  group('cold status', () {
    testWidgets('fetches the status before deciding, then asks', (
      tester,
    ) async {
      final git = _FakeGit(status: _dirty());
      final host = await _host(tester, git: git, overrideStatus: false);

      final result = confirmSessionExit(
        host.context,
        host.container,
        repoPath: _repo,
        title: 'Log out?',
      );
      await tester.pumpAndSettle();

      expect(git.statusCalls, greaterThan(0));
      expect(
        find.textContaining('You have uncommitted changes'),
        findsOneWidget,
      );

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(await result, isFalse);
    });

    testWidgets('a failed status fetch BLOCKS the exit rather than assuming '
        'the tree is clean', (tester) async {
      final git = _FakeGit(throwOnStatus: true);
      final host = await _host(tester, git: git, overrideStatus: false);

      final result = confirmSessionExit(
        host.context,
        host.container,
        repoPath: _repo,
        title: 'Log out?',
      );
      await tester.pumpAndSettle();

      // runAction surfaces the failure, and the guard returns false: we cannot
      // know whether there was uncommitted work, so we do not let the session
      // go. Deliberate, and worth pinning — the opposite default would lose
      // work silently.
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(await result, isFalse);
    });
  });

  testWidgets('confirms against the container it is handed, not the ambient '
      'one — the tab-strip case closes a background tab', (tester) async {
    // The closing tab (dirty) is NOT the tab whose scope the widget tree sits
    // in (clean). tab_strip.dart passes the former explicitly.
    final foreign = ProviderContainer(
      overrides: [
        gitServiceProvider.overrideWithValue(_FakeGit(status: _dirty())),
        statusProvider(_repo).overrideWith((ref) async => _dirty()),
        pendingOpProvider(_repo).overrideWith((ref) => PendingOp.none),
      ],
    );
    addTearDown(foreign.dispose);

    final host = await _host(tester); // ambient container is clean

    final result = confirmSessionExit(
      host.context,
      foreign,
      repoPath: _repo,
      title: 'Close tab?',
    );
    await tester.pumpAndSettle();

    expect(
      find.textContaining('You have uncommitted changes'),
      findsOneWidget,
      reason: 'the guard must read the passed container; reading the ambient '
          'one would let a dirty background tab close silently',
    );

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(await result, isFalse);
  });

  // 0009 M5: the quit / window-close path shows ONE summary for every
  // session with work at stake, and never blocks on a network round-trip.
  group('quit summary', () {
    ProviderContainer session({
      required GitStatus status,
      PendingOp pending = PendingOp.none,
    }) {
      final container = ProviderContainer(
        overrides: [
          statusProvider(_repo).overrideWith((ref) => status),
          pendingOpProvider(_repo).overrideWith((ref) => pending),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('collects only sessions whose landed state has work at stake', () {
      final dirty = session(status: _dirty());
      final clean = session(status: _clean());
      final rebasing = session(status: _clean(), pending: PendingOp.rebase);
      // A session whose status never landed (hard drop): counts as clean —
      // quit must not wait on it.
      final cold = ProviderContainer(
        overrides: [
          statusProvider(
            _repo,
          ).overrideWith((ref) => Completer<GitStatus>().future),
          pendingOpProvider(
            _repo,
          ).overrideWith((ref) => Completer<PendingOp>().future),
        ],
      );
      addTearDown(cold.dispose);

      final atRisk = sessionsAtRisk([
        (dirty, _repo),
        (clean, _repo),
        (rebasing, _repo),
        (cold, _repo),
      ]);

      expect(atRisk, hasLength(2));
      expect(atRisk[0].dirty, isTrue);
      expect(atRisk[1].pending, PendingOp.rebase);
    });

    test('the summary lists one line per session with its reasons', () {
      final message = sessionExitSummaryMessage([
        (repoPath: '/srv/app', dirty: true, pending: PendingOp.none),
        (repoPath: '/srv/lib', dirty: true, pending: PendingOp.merge),
      ]);
      expect(message, contains('• /srv/app — uncommitted changes'));
      expect(
        message,
        contains('• /srv/lib — uncommitted changes, merge in progress'),
      );
      expect(message, contains('left'));
    });

    testWidgets('an explicit confirmLabel overrides the title derivation', (
      tester,
    ) async {
      final host = await _host(tester, status: _dirty());

      final result = confirmSessionExit(
        host.context,
        host.container,
        repoPath: _repo,
        title: 'Disconnect?',
        confirmLabel: 'Disconnect',
      );
      await tester.pumpAndSettle();

      expect(find.text('Disconnect'), findsOneWidget);
      expect(find.text('Log Out'), findsNothing);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(await result, isFalse);
    });
  });
}
