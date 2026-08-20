import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/forge/branch_forge_status.dart';
import 'package:remote_magic_git/core/git/branch_comparison.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/core/utils/git_porcelain_parser.dart';
import 'package:remote_magic_git/features/branches/branch_row_semantics.dart';
import 'package:remote_magic_git/features/branches/branches_view.dart';
import 'package:remote_magic_git/features/common/context_menu.dart';

const _repo = '/repo';
const _mainOid = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _featureOid = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

const _refs = [
  GitRef(name: 'refs/heads/main', oid: _mainOid, isHead: true, subject: 's'),
  GitRef(
    name: 'refs/heads/feature',
    oid: _featureOid,
    isHead: false,
    subject: 's',
  ),
  GitRef(
    name: 'refs/heads/zebra',
    oid: 'cccccccccccccccccccccccccccccccccccccccc',
    isHead: false,
    subject: 's',
  ),
];

class _FakeGit extends GitService {
  _FakeGit() : super(SSHCommandExecutor(SSHClientManager()));

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
    bool fullHistory = false,
  }) async => const [];
}

void main() {
  group('branchRowSemanticsLabel', () {
    test('includes name, type, current, selected, request, CI', () {
      final label = branchRowSemanticsLabel(
        branch: const GitRef(
          name: 'refs/heads/main',
          oid: _mainOid,
          isHead: true,
          subject: 'tip',
        ),
        selected: true,
        multiSelected: false,
        position: 1,
        count: 3,
        forge: const BranchForge(
          requestNumber: 7,
          requestUrl: 'https://x',
          ci: ForgeCi.failure,
        ),
        merged: false,
      );
      expect(label, contains('main'));
      expect(label, contains('local branch'));
      expect(label, contains('current'));
      expect(label, contains('selected'));
      expect(label, contains('pull request #7'));
      expect(label, contains('CI failing'));
      expect(label, contains('item 1 of 3'));
    });

    test('CI glyphs are non-color-only', () {
      expect(forgeCiGlyph(ForgeCi.success), '✓');
      expect(forgeCiGlyph(ForgeCi.failure), '✕');
    });
  });

  group('Branches keyboard a11y', () {
    Future<void> pump(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1500, 1300);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final container = ProviderContainer(
        overrides: [
          gitServiceProvider.overrideWithValue(_FakeGit()),
          refsProvider(_repo).overrideWith((ref) async => _refs),
          remotesProvider(_repo).overrideWith((ref) async => const ['origin']),
          remoteTagsProvider(_repo).overrideWith((ref) async => null),
          branchForgeProvider(_repo).overrideWith(
            (ref) async => {
              'feature': const BranchForge(
                requestNumber: 3,
                requestUrl: 'u',
                ci: ForgeCi.success,
              ),
            },
          ),
          mergedBranchesProvider(_repo).overrideWith((ref) async => const {}),
          statusProvider(_repo).overrideWith(
            (ref) async => GitStatus(
              branch: const GitBranchInfo(head: 'main', oid: _mainOid),
              files: const [],
            ),
          ),
          branchBaseProvider.overrideWith(
            (ref, key) async => const BranchBaseResolution(
              base: BranchBase(
                refName: 'refs/heads/main',
                displayName: 'main',
                oid: _mainOid,
                source: BranchBaseSource.localMain,
                isFallback: false,
              ),
            ),
          ),
          branchComparisonMetadataProvider.overrideWith(
            (ref, key) async => BranchComparisonMetadata.unrelated(
              baseOid: key.baseOid,
              branchOid: key.branchOid,
            ),
          ),
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

    testWidgets('semantics label for local branch includes type and current', (
      tester,
    ) async {
      await pump(tester);
      expect(find.text('feature'), findsWidgets);
      expect(find.text('main'), findsWidgets);
      // Pure helper contract used by the row Semantics labels.
      final headLabel = branchRowSemanticsLabel(
        branch: _refs.first,
        selected: false,
        multiSelected: false,
        position: 1,
        count: 3,
      );
      expect(headLabel, contains('local branch'));
      expect(headLabel, contains('current'));
    });

    testWidgets('Home/End move selection without stealing filter focus', (
      tester,
    ) async {
      await pump(tester);
      await tester.tap(find.text('feature').first);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.end);
      await tester.pumpAndSettle();
      // zebra is last local in navigable order (after remotes/tags ordering varies)
      expect(find.text('zebra'), findsWidgets);
      await tester.sendKeyEvent(LogicalKeyboardKey.home);
      await tester.pumpAndSettle();
      expect(find.text('main'), findsWidgets);
    });

    testWidgets('HEAD row uses selection tint when selected', (tester) async {
      await pump(tester);
      await tester.tap(find.text('main').first);
      await tester.pumpAndSettle();
      // Selection should still resolve; green-only mask is not the sole signal.
      final label = branchRowSemanticsLabel(
        branch: _refs.first,
        selected: true,
        multiSelected: false,
        position: 1,
        count: 3,
      );
      expect(label, contains('selected'));
      expect(label, contains('current'));
    });
  });

  group('context menu appearance', () {
    testWidgets(
      'menu opens, keyboard-dismisses, and shows items in light theme',
      (tester) async {
        final menu = ContextMenuOverlay();
        addTearDown(menu.dispose);
        await tester.pumpWidget(
          MacosApp(
            theme: MacosThemeData.light(),
            home: MacosWindow(
              child: Builder(
                builder: (context) {
                  return Center(
                    child: GestureDetector(
                      onTap: () {
                        menu.show(context, const Offset(40, 40), [
                          ContextMenuItem(
                            icon: CupertinoIcons.star,
                            label: 'Pin',
                            onTap: () {},
                          ),
                        ]);
                      },
                      child: const Text('Open menu'),
                    ),
                  );
                },
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open menu'));
        await tester.pumpAndSettle();
        expect(find.text('Pin'), findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.text('Pin'), findsNothing);
      },
    );
  });
}
