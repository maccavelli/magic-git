// The branches panel's tags section: sorted newest-first by creatordate
// (for-each-ref's default refname order reads oldest-to-newest for release
// tags), collapsed to the 10 most recent, with a "Show more" row that expands
// the rest in place.

import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/features/branches/branches_view.dart';
import 'package:remote_magic_git/features/common/buttons.dart';
import 'package:remote_magic_git/features/common/inline_action_button.dart';
import 'package:remote_magic_git/features/common/tool_icon_button.dart';

const _repo = '/repo';

class _FakeGit extends GitService {
  _FakeGit() : super(SSHCommandExecutor(SSHClientManager()));

  final deleted = <String>[];
  final deletedRemote = <(String remote, String name)>[];
  final pushedBulk = <List<String>>[];

  @override
  Future<void> deleteTag(String repoPath, String name) async {
    deleted.add(name);
  }

  @override
  Future<SSHCommandResult> deleteRemoteTag(
    String repoPath,
    String remote,
    String name,
  ) async {
    deletedRemote.add((remote, name));
    return const SSHCommandResult(exitCode: 0, stdout: '', stderr: '');
  }

  @override
  Future<SSHCommandResult> pushTags(
    String repoPath,
    List<String> names, {
    String remote = 'origin',
  }) async {
    pushedBulk.add(names);
    return const SSHCommandResult(exitCode: 0, stdout: '', stderr: '');
  }
}

/// One branch plus 13 tags fed in refname order (v1 first) while their
/// creation dates run the other way — the view must sort by date, not echo
/// git's order.
List<GitRef> _refs() => [
  const GitRef(name: 'refs/heads/main', oid: 'aaa', isHead: true, subject: 's'),
  for (var i = 1; i <= 13; i++)
    GitRef(
      name: 'refs/tags/v$i',
      oid: 'bbb$i',
      isHead: false,
      subject: 's',
      creatorDate: 1000 + i,
    ),
];

Future<_FakeGit> _pump(
  WidgetTester tester, {
  List<GitRef>? refs,
  List<String> remotes = const ['origin'],
  // The remote's tag listing; null = unknown (unreachable / no remote) —
  // the state in which the view must show NO badges and keep push enabled.
  Map<String, String>? remoteTags,
}) async {
  // Tall surface so every built row is on-stage — the assertions below are
  // about which rows exist, not about scrolling.
  tester.view.physicalSize = const Size(900, 1800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final git = _FakeGit();
  final container = ProviderContainer(
    overrides: [
      gitServiceProvider.overrideWithValue(git),
      refsProvider(_repo).overrideWith((ref) async => refs ?? _refs()),
      remotesProvider(_repo).overrideWith((ref) async => remotes),
      // Overridden in every pump: the real provider keeps a five-minute
      // keepAlive timer that widget tests would flag as still pending.
      remoteTagsProvider(_repo).overrideWith((ref) async => remoteTags),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MacosApp(
        debugShowCheckedModeBanner: false,
        home: BranchesView(repoPath: _repo),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return git;
}

void main() {
  testWidgets(
    'tags render newest-first and collapse to the 10 most recent',
    (tester) async {
      await _pump(tester);

      expect(find.text('Tags (13)'), findsOneWidget);

      // The 10 newest (v13..v4) are visible; the 3 oldest are not.
      expect(find.text('v13'), findsOneWidget);
      expect(find.text('v4'), findsOneWidget);
      expect(find.text('v3'), findsNothing);
      expect(find.text('v1'), findsNothing);

      // Newest at the top, despite being fed last.
      expect(
        tester.getTopLeft(find.text('v13')).dy,
        lessThan(tester.getTopLeft(find.text('v4')).dy),
      );

      expect(find.text('Show 3 more tags'), findsOneWidget);
    },
  );

  testWidgets('the Show more row expands the list in place', (tester) async {
    await _pump(tester);

    await tester.tap(find.text('Show 3 more tags'));
    await tester.pumpAndSettle();

    expect(find.text('v1'), findsOneWidget);
    expect(find.text('v13'), findsOneWidget);
    expect(find.text('Show 3 more tags'), findsNothing);
    // Oldest lands at the bottom.
    expect(
      tester.getTopLeft(find.text('v3')).dy,
      lessThan(tester.getTopLeft(find.text('v1')).dy),
    );
  });

  // ---- remote-tag awareness (the "tags don't push by default" fix) --------

  /// Three tags with distinct remote states.
  List<GitRef> threeTags() => [
    const GitRef(
      name: 'refs/heads/main',
      oid: 'aaa',
      isHead: true,
      subject: 's',
    ),
    for (final (i, name) in ['synced', 'moved', 'unpushed'].indexed)
      GitRef(
        name: 'refs/tags/$name',
        oid: 'oid-$name',
        isHead: false,
        subject: 's',
        creatorDate: 1000 + i,
      ),
  ];

  // The per-tag push affordance is the detail pane's button now (select the
  // tag row to reveal it): 'Push to origin' when it can push, a disabled
  // 'Already on origin' when in sync.
  Future<void> expectPush(
    WidgetTester tester,
    String tag, {
    required bool enabled,
  }) async {
    await tester.tap(find.text(tag));
    await tester.pumpAndSettle();
    final btn = tester.widget<InlineActionButton>(
      find.byWidgetPredicate(
        (w) =>
            w is InlineActionButton &&
            (w.label == 'Push to origin' || w.label == 'Already on origin'),
      ),
    );
    expect(btn.onPressed != null, enabled);
  }

  testWidgets('badges follow the remote listing: local-only orange, differs '
      'red, in-sync none with a disabled push button', (tester) async {
    await _pump(
      tester,
      refs: threeTags(),
      remoteTags: {'synced': 'oid-synced', 'moved': 'other-oid'},
    );

    expect(find.text('local only'), findsOneWidget);
    expect(find.text('differs from origin'), findsOneWidget);

    await expectPush(tester, 'unpushed', enabled: true);
    await expectPush(tester, 'synced', enabled: false);
    await expectPush(tester, 'moved', enabled: true);

    expect(find.text('Push 1 to origin'), findsOneWidget,
        reason: 'only the local-only tag counts — not the diverged one');
  });

  testWidgets('an unknown remote listing (null) shows no badges and leaves '
      'push enabled — unknown is not forbidden', (tester) async {
    await _pump(tester, refs: threeTags(), remoteTags: null);

    expect(find.text('local only'), findsNothing);
    expect(find.text('differs from origin'), findsNothing);
    // Nothing selected → no push affordance anywhere (header hidden too).
    expect(find.textContaining('Push', findRichText: true), findsNothing);
    // Selecting a tag reveals an enabled push (unknown is not forbidden).
    await expectPush(tester, 'unpushed', enabled: true);
  });

  testWidgets('a repo with NO configured remote hides the push affordances '
      'entirely', (tester) async {
    await _pump(tester, refs: threeTags(), remotes: const [], remoteTags: null);

    expect(
      find.byWidgetPredicate(
        (w) => w is ToolIconButton && w.tooltip.contains('origin'),
      ),
      findsNothing,
    );
  });

  // Delete lives on the tag row's right-click menu now.
  Future<void> tapTrash(WidgetTester tester, String tag) async {
    await tester.tap(find.text(tag),
        buttons: kSecondaryButton, warnIfMissed: false);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete tag'));
    await tester.pumpAndSettle();
  }

  testWidgets('deleting a tag known to be on the remote escalates to the '
      'three-way choice; "local and remote" runs both deletes',
      (tester) async {
    final git = await _pump(
      tester,
      refs: threeTags(),
      remoteTags: {'synced': 'oid-synced'},
    );

    await tapTrash(tester, 'synced');
    expect(find.textContaining('also exists on "origin"'), findsOneWidget);

    await tester.tap(find.text('Delete Local and on origin'));
    await tester.pumpAndSettle();

    expect(git.deleted, ['synced']);
    expect(git.deletedRemote, [('origin', 'synced')]);
  });

  testWidgets('deleting a local-only tag keeps the plain confirm — no '
      'remote step to offer', (tester) async {
    final git = await _pump(
      tester,
      refs: threeTags(),
      remoteTags: {'synced': 'oid-synced'},
    );

    await tapTrash(tester, 'unpushed');
    expect(find.text('Delete Local and on origin'), findsNothing);

    await tester.tap(find.widgetWithText(AppPushButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(git.deleted, ['unpushed']);
    expect(git.deletedRemote, isEmpty);
  });

  testWidgets('the header "Push N" affordance pushes exactly the local-only '
      'tags in one call', (tester) async {
    final git = await _pump(
      tester,
      refs: threeTags(),
      remoteTags: {'synced': 'oid-synced', 'moved': 'other-oid'},
    );

    await tester.tap(find.text('Push 1 to origin'));
    await tester.pumpAndSettle();
    expect(find.textContaining('exist only locally'), findsOneWidget);

    await tester.tap(find.widgetWithText(AppPushButton, 'Push'));
    await tester.pumpAndSettle();

    expect(git.pushedBulk, [
      ['unpushed'],
    ]);
  });
}
