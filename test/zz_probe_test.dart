import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/features/history/history_view.dart';
import 'package:remote_magic_git/features/history/ref_chip.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _tip = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _mid = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

/// The log answers at once; refs take a beat longer — the ordinary case, since
/// they are two separate commands racing on the read lane.
class _SlowRefsGit extends GitService {
  _SlowRefsGit() : super(SSHCommandExecutor(SSHClientManager()));

  @override
  Future<List<GitCommit>> log(
    String repoPath, {
    String revision = 'HEAD',
    int maxCount = 200,
    int skip = 0,
    String? grep,
    String? author,
    String? since,
    String? until,
    String? path,
    String? pathQuery,
    String? sha,
    bool all = false,
    bool follow = false,
    bool noMerges = false,
  }) async => const [
    GitCommit(
      hash: _tip,
      shortHash: 'aaaaaaa',
      authorName: 'Dev',
      authorEmail: 'd@e',
      date: '2026-07-13T10:00',
      parents: [_mid],
      subject: 'newest',
    ),
    GitCommit(
      hash: _mid,
      shortHash: 'bbbbbbb',
      authorName: 'Dev',
      authorEmail: 'd@e',
      date: '2026-07-12T10:00',
      parents: [],
      subject: 'older',
    ),
  ];

  @override
  Future<List<GitRef>> refs(String repoPath) async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    return const [
      GitRef(
        name: 'refs/heads/main',
        oid: _tip,
        isHead: true,
        subject: 'newest',
      ),
    ];
  }

  @override
  Future<String> showCommit(
    String repoPath,
    String hash, {
    String? path,
    int? context,
  }) async => 'diff --git a/x b/x\n@@ -1 +1 @@\n-a\n+b';
}

void main() {
  testWidgets('the chip appears when refs land after the commits', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer(
      overrides: [gitServiceProvider.overrideWithValue(_SlowRefsGit())],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MacosApp(
          debugShowCheckedModeBanner: false,
          home: HistoryView(repoPath: '/srv/repo'),
        ),
      ),
    );

    await tester.pump(); // the log lands
    await tester.pump();
    // ignore: avoid_print
    print('rows=${find.text('newest').evaluate().length} '
        'chips=${find.byType(RefChip).evaluate().length}  (refs still in flight)');

    await tester.pump(const Duration(milliseconds: 400)); // refs land
    await tester.pumpAndSettle();
    // ignore: avoid_print
    print('rows=${find.text('newest').evaluate().length} '
        'chips=${find.byType(RefChip).evaluate().length}  (refs landed)');

    expect(find.text('newest'), findsOneWidget);
    expect(
      find.byType(RefChip),
      findsOneWidget,
      reason: 'refs landing after the log must still decorate the tip',
    );
  });
}
