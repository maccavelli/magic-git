// EditRemoteRepoSheet's git-dir field (0022 L1).
//
// A scoped (bare/dotfiles) repo entry stores a git-dir alongside its work-tree
// path, but the edit sheet offered Label/Path/fsmonitor only — so a git-dir
// that had genuinely MOVED could not be corrected at all: the only route was
// deleting the entry and adding it back, which is also the path that used to
// leak scope state. The sheet had no test of any kind before this.

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/storage/saved_connection.dart';
import 'package:remote_magic_git/features/common/buttons.dart';
import 'package:remote_magic_git/features/switcher/edit_entry_sheets.dart';

const _scopedRepo = '/home/you';
const _plainRepo = '/srv/git/project';

SavedConnection _conn({bool scoped = true}) {
  const base = SavedConnection(
    id: 'c1',
    label: 'Bastion',
    host: 'h',
    port: 22,
    username: 'u',
    repoPath: _scopedRepo,
    repoPaths: [_scopedRepo, _plainRepo],
  );
  return scoped
      ? base.withScopedGitDir(_scopedRepo, '/home/you/.home.git')
      : base;
}

Future<EditRemoteRepoResult?> _pump(
  WidgetTester tester, {
  required SavedConnection conn,
  required String repo,
}) async {
  EditRemoteRepoResult? result;
  await tester.pumpWidget(
    MacosApp(
      debugShowCheckedModeBanner: false,
      home: Builder(
        builder: (context) => CupertinoButton(
          child: const Text('open'),
          onPressed: () async {
            result = await showMacosSheet<EditRemoteRepoResult?>(
              context: context,
              builder: (_) => EditRemoteRepoSheet(conn: conn, repo: repo),
            );
          },
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return result;
}

void main() {
  testWidgets('a scoped repo can have its git-dir corrected', (tester) async {
    await _pump(tester, conn: _conn(), repo: _scopedRepo);

    expect(find.text('Git directory'), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(MacosTextField, '/home/you/.home.git'),
      '/home/you/dotfiles.git',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    // The sheet is the unit under test; its resolved value is the contract.
    expect(find.text('Git directory'), findsNothing, reason: 'sheet closed');
  });

  testWidgets('an ordinary repo is not offered a git-dir', (tester) async {
    // The field would be meaningless for a repo whose .git is where git
    // expects it, and an input that means nothing invites a value that breaks
    // things.
    await _pump(tester, conn: _conn(), repo: _plainRepo);

    expect(find.text('Git directory'), findsNothing);
    expect(find.text('Path on the host'), findsOneWidget);
  });

  testWidgets('a scoped repo cannot be saved with a blank git-dir', (
    tester,
  ) async {
    // Blank means "not scoped", which for this entry is false: every command
    // would then run unscoped and fail "not a git repository".
    await _pump(tester, conn: _conn(), repo: _scopedRepo);

    await tester.enterText(
      find.widgetWithText(MacosTextField, '/home/you/.home.git'),
      '',
    );
    await tester.pumpAndSettle();

    // AppPushButton, not PushButton: find.byType(PushButton) does not match
    // the app's subclass.
    final save = tester.widget<AppPushButton>(
      find.ancestor(
        of: find.text('Save'),
        matching: find.byType(AppPushButton),
      ),
    );
    expect(save.onPressed, isNull, reason: 'Save must be disabled');
  });
}
