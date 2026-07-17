// Keyboard reach into the Stashes panel: ↑/↓ walk the selection (and the
// preview follows), and the panel-scoped shortcuts act on the selected stash by
// its stable identity — ⌥⌘A apply (by OID), ⌥⌘P pop (index + expected OID),
// ⌘⌫ drop (through its destructive confirm). Selection and shortcuts are the
// same wiring the command palette dispatches, so pinning them here covers both.

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/features/stash/stash_view.dart';

/// Spies the apply/pop/drop wiring — which identity each keyboard action hands
/// the service — without touching SSH.
class _KbGit extends GitService {
  _KbGit() : super(SSHCommandExecutor(SSHClientManager()));

  final List<(int, String)> drops = [];
  final List<(int, String)> pops = [];
  final List<String> applies = [];

  @override
  Future<SSHCommandResult> stashApply(
    String repoPath,
    String oid, {
    bool restoreIndex = false,
  }) async {
    applies.add(oid);
    return const SSHCommandResult(exitCode: 0, stdout: '', stderr: '');
  }

  @override
  Future<SSHCommandResult> stashPop(
    String repoPath,
    int index, {
    required String expectedOid,
    bool restoreIndex = false,
  }) async {
    pops.add((index, expectedOid));
    return const SSHCommandResult(exitCode: 0, stdout: '', stderr: '');
  }

  @override
  Future<SSHCommandResult> stashDrop(
    String repoPath,
    int index, {
    required String expectedOid,
  }) async {
    drops.add((index, expectedOid));
    return const SSHCommandResult(exitCode: 0, stdout: '', stderr: '');
  }
}

const _repo = '/repo';
const _oidA = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _oidB = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

final _stashes = [
  const GitStash(
    index: 0,
    oid: _oidA,
    branch: 'main',
    message: 'WIP on main: abc1234 first',
    relativeDate: '2 hours ago',
  ),
  const GitStash(
    index: 1,
    oid: _oidB,
    branch: 'feature',
    message: 'On feature: second',
    relativeDate: '3 days ago',
  ),
];

Future<_KbGit> _pump(WidgetTester tester) async {
  final git = _KbGit();
  final container = ProviderContainer(
    overrides: [
      gitServiceProvider.overrideWithValue(git),
      stashesProvider(_repo).overrideWith((ref) async => _stashes),
      // Distinct patches so the preview reveals which stash is selected.
      stashDiffProvider((_repo, _oidA)).overrideWith((ref) async => 'PATCH-A'),
      stashDiffProvider((_repo, _oidB)).overrideWith((ref) async => 'PATCH-B'),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MacosApp(
        debugShowCheckedModeBanner: false,
        home: SizedBox(
          width: 1000,
          height: 700,
          child: StashView(repoPath: _repo),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return git;
}

/// Presses [trigger] with the given modifiers held, then releases — enough to
/// fire a SingleActivator, which triggers on the modified key-down.
Future<void> _combo(
  WidgetTester tester,
  LogicalKeyboardKey trigger, {
  bool meta = false,
  bool alt = false,
}) async {
  if (meta) await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
  if (alt) await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
  await tester.sendKeyDownEvent(trigger);
  await tester.sendKeyUpEvent(trigger);
  if (alt) await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
  if (meta) await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('↓ then ↑ walk the selection and the preview follows', (
    tester,
  ) async {
    await _pump(tester);
    // Tap the first card to take list focus and select stash@{0}.
    await tester.tap(find.text('first'));
    await tester.pumpAndSettle();
    expect(find.text('PATCH-A'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(find.text('PATCH-B'), findsOneWidget, reason: '↓ moved to stash@{1}');
    expect(find.text('PATCH-A'), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(find.text('PATCH-A'), findsOneWidget, reason: '↑ moved back');
  });

  testWidgets('⌥⌘A applies the selected stash by OID', (tester) async {
    final git = await _pump(tester);
    await tester.tap(find.text('second'));
    await tester.pumpAndSettle();

    await _combo(tester, LogicalKeyboardKey.keyA, meta: true, alt: true);
    expect(git.applies, [_oidB]);
  });

  testWidgets('⌥⌘P pops the selected stash by index and expected OID', (
    tester,
  ) async {
    final git = await _pump(tester);
    await tester.tap(find.text('second'));
    await tester.pumpAndSettle();

    await _combo(tester, LogicalKeyboardKey.keyP, meta: true, alt: true);
    expect(git.pops, [(1, _oidB)]);
  });

  testWidgets('⌘⌫ drops the selected stash after the destructive confirm', (
    tester,
  ) async {
    final git = await _pump(tester);
    await tester.tap(find.text('first'));
    await tester.pumpAndSettle();

    await _combo(tester, LogicalKeyboardKey.backspace, meta: true);
    expect(git.drops, isEmpty, reason: 'nothing before the confirm');
    await tester.tap(find.text('Drop'));
    await tester.pumpAndSettle();
    expect(git.drops, [(0, _oidA)]);
  });

  testWidgets('shortcuts are inert with nothing selected', (tester) async {
    final git = await _pump(tester);
    // No selection: the handlers are null, so the bindings don't exist.
    await _combo(tester, LogicalKeyboardKey.keyA, meta: true, alt: true);
    await _combo(tester, LogicalKeyboardKey.keyP, meta: true, alt: true);
    expect(git.applies, isEmpty);
    expect(git.pops, isEmpty);
  });
}
