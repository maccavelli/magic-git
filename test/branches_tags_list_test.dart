// The branches panel's tags section: sorted newest-first by creatordate
// (for-each-ref's default refname order reads oldest-to-newest for release
// tags), collapsed to the 10 most recent, with a "Show more" row that expands
// the rest in place.

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/features/branches/branches_view.dart';

const _repo = '/repo';

class _FakeGit extends GitService {
  _FakeGit() : super(SSHCommandExecutor(SSHClientManager()));
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

Future<void> _pump(WidgetTester tester) async {
  // Tall surface so every built row is on-stage — the assertions below are
  // about which rows exist, not about scrolling.
  tester.view.physicalSize = const Size(900, 1800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [
      gitServiceProvider.overrideWithValue(_FakeGit()),
      refsProvider(_repo).overrideWith((ref) async => _refs()),
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
}
