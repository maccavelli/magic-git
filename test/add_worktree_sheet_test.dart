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

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/features/worktrees/add_worktree_sheet.dart';

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
}) async {
  tester.view.physicalSize = const Size(1400, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final container = ProviderContainer(
    overrides: [refsProvider(_repo).overrideWith((ref) async => _refs)],
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
    final create = tester.widget<PushButton>(
      find.ancestor(
        of: find.text('Create Worktree'),
        matching: find.byType(PushButton),
      ),
    );
    expect(create.onPressed, isNull);
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
}
