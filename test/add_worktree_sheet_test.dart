// The Add Worktree sheet's destination is composed from TWO fields — "Create in"
// (the folder macOS authorizes) and "Folder name" — rather than one combined
// path.
//
// That split is not cosmetic. A macOS sandbox grant covers a folder and its
// contents, and `git worktree add` has to CREATE a new directory — so the
// permission has to sit on the *parent*. With a single "Location: /a/b/c-feat"
// field, the folder actually being authorized (`/a/b`) is invisible, and the
// pre-filled path reads as ready-to-go when the app in fact has no permission to
// write there at all. Create then dies on a raw "permission denied" from git.

import 'package:flutter/cupertino.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/features/common/buttons.dart';
import 'package:remote_magic_git/features/worktrees/add_worktree_sheet.dart';

/// Pins the connection to a fixed state (the app default in tests is the SSH
/// backend), so the sheet's local-only affordances can be tested both ways.
class _StubConnection extends ConnectionController {
  _StubConnection(this._state);
  final ConnectionState _state;

  @override
  ConnectionState build() => _state;
}

const _repo = '/Users/x/wt-demo/app';

const _refs = [
  GitRef(name: 'refs/heads/main', oid: 'aaa', isHead: true, subject: 's'),
  GitRef(
    name: 'refs/heads/hotfix/login',
    oid: 'bbb',
    isHead: false,
    subject: 's',
  ),
  // Already checked out in a worktree — git refuses to check it out again, so
  // the sheet must not offer it.
  GitRef(
    name: 'refs/heads/feature/auth',
    oid: 'ccc',
    isHead: false,
    subject: 's',
    worktreePath: '/Users/x/wt-demo/app-feature-auth',
  ),
];

Future<void> pump(
  WidgetTester tester, {
  String? initialCommitish,
  String? initialBranchName,
  bool localBackend = false,
}) async {
  tester.view.physicalSize = const Size(1400, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final container = ProviderContainer(
    overrides: [
      refsProvider(_repo).overrideWith((ref) async => _refs),
      if (localBackend)
        connectionProvider.overrideWith(
          () => _StubConnection(
            const ConnectionState(backend: ConnectionBackend.local),
          ),
        ),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MacosApp(
        debugShowCheckedModeBanner: false,
        home: AddWorktreeSheet(
          repoPath: _repo,
          initialCommitish: initialCommitish,
          initialBranchName: initialBranchName,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Field order in the sheet, top to bottom.
const _branchField = 0;
const _parentField = 1;
const _folderNameField = 2;

String fieldText(WidgetTester tester, int index) => tester
    .widgetList<MacosTextField>(find.byType(MacosTextField))
    .elementAt(index)
    .controller!
    .text;

AppPushButton createButton(WidgetTester tester) => tester.widget<AppPushButton>(
  find.ancestor(
    of: find.text('Create Worktree'),
    matching: find.byType(AppPushButton),
  ),
);

void main() {
  testWidgets('the parent folder and the folder name are separate fields', (
    tester,
  ) async {
    await pump(tester);

    // The folder that will be AUTHORIZED is shown on its own, so you can see and
    // choose it — it defaults to the repo's parent, where a sibling worktree
    // conventionally goes.
    expect(find.text('Create in'), findsOneWidget);
    expect(find.text('Folder name'), findsOneWidget);
    expect(fieldText(tester, _parentField), '/Users/x/wt-demo');
  });

  testWidgets('the folder name is derived from the branch, and previewed', (
    tester,
  ) async {
    await pump(tester);

    await tester.enterText(
      find.byType(MacosTextField).at(_branchField),
      'feature/billing',
    );
    await tester.pumpAndSettle();

    // `feature/billing` -> `app-feature-billing`: slashes would nest
    // directories, and the repo name keeps sibling worktrees identifiable.
    expect(fieldText(tester, _folderNameField), 'app-feature-billing');
    // And the composed destination is spelled out, so there is no doubt.
    expect(
      find.text('→ /Users/x/wt-demo/app-feature-billing'),
      findsOneWidget,
    );
  });

  testWidgets('a destination inside the repository is rejected', (
    tester,
  ) async {
    await pump(tester);

    await tester.enterText(find.byType(MacosTextField).at(_branchField), 'x');
    await tester.pumpAndSettle();

    // Nesting a worktree inside the main worktree makes its files show up as
    // untracked noise in the parent's own status. git allows it; we don't.
    // Point the parent at the repo itself -> the worktree would land inside it.
    await tester.enterText(find.byType(MacosTextField).at(_parentField), _repo);
    await tester.pumpAndSettle();

    expect(
      find.textContaining('outside the repository'),
      findsOneWidget,
    );
    // …and Create is unavailable while that is true.
    final create = tester.widget<AppPushButton>(
      find.ancestor(
        of: find.text('Create Worktree'),
        matching: find.byType(AppPushButton),
      ),
    );
    expect(create.onPressed, isNull);
  });

  testWidgets('a typed detached revision is kept, and enables Create', (
    tester,
  ) async {
    // The bug this pins: the Revision field was built with a FRESH controller
    // on every build and a no-op onChanged, so typed text never reached state
    // and was wiped by the next rebuild — Create could never enable, making
    // Detached mode entirely unusable from the standalone Add flow.
    await pump(tester);

    await tester.tap(find.text('Detached'));
    await tester.pumpAndSettle();
    // No revision yet — nothing to check out, so Create must be off.
    expect(createButton(tester).onPressed, isNull);

    // The Revision field sits where the branch field does in the other modes.
    await tester.enterText(find.byType(MacosTextField).at(0), 'v2.1.0');
    await tester.pumpAndSettle();

    expect(fieldText(tester, 0), 'v2.1.0');
    // The folder name derives from the revision, like it does from a branch.
    expect(fieldText(tester, _folderNameField), 'app-v2.1.0');
    expect(createButton(tester).onPressed, isNotNull);
  });

  testWidgets('Detached pre-fills the revision it was opened with', (
    tester,
  ) async {
    // Opened from a branch/commit context ("Checkout in New Worktree…"), then
    // switched to Detached: the starting point carries over as the revision.
    await pump(tester, initialCommitish: 'hotfix/login');

    await tester.tap(find.text('Detached'));
    await tester.pumpAndSettle();

    expect(fieldText(tester, 0), 'hotfix/login');
    expect(createButton(tester).onPressed, isNotNull);
  });

  testWidgets('a branch checked out elsewhere is not offered', (tester) async {
    await pump(tester);

    await tester.tap(find.text('Existing branch'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Choose a branch'));
    await tester.pumpAndSettle();

    // `hotfix/login` is free; `feature/auth` is held by a worktree and git would
    // refuse it outright, so it never appears as a choice.
    expect(find.text('hotfix/login'), findsWidgets);
    expect(find.text('feature/auth'), findsNothing);
    // And the sheet says why, rather than silently shortening the list.
    expect(
      find.textContaining('already checked out in another worktree'),
      findsOneWidget,
    );
  });

  testWidgets(
    'the Choose… folder picker is hidden on the SSH backend, where it would '
    'browse the wrong machine',
    (tester) async {
      // The picker browses the local filesystem and doubles as the macOS
      // sandbox grant; on a remote repo the parent is a directory on the
      // remote host, so offering the local picker wrote a local path into a
      // remote destination. Plain text entry is the whole flow there.
      await pump(tester); // default harness state: SSH backend
      expect(find.text('Choose…'), findsNothing);
    },
  );

  testWidgets('the Choose… folder picker is offered on the local backend', (
    tester,
  ) async {
    await pump(tester, localBackend: true);
    expect(find.text('Choose…'), findsOneWidget);
  });

  testWidgets(
    'an initial branch that is already checked out elsewhere does not crash '
    'the existing-branch popup',
    (tester) async {
      // The popup only offers branches no worktree holds, but the initial
      // value arrives from a caller — a value the popup does not offer used
      // to trip MacosPopupButton's exactly-one-item assertion.
      await pump(tester, initialCommitish: 'feature/auth');
      expect(tester.takeException(), isNull);
      // The guarded popup falls back to its hint instead.
      expect(find.text('Choose a branch'), findsOneWidget);
    },
  );
}
