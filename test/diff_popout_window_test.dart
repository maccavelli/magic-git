// The Repository panel's diff "pop-out": clicking Pop out relocates the diff
// into a floating DiffPopoutWindow (hiding the inline panel); its own close
// button returns the diff to the inline panel; its side-by-side toggle is
// independent of the inline toggle it was seeded from.

import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/git/watch_event.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/core/utils/git_porcelain_parser.dart';
import 'package:remote_magic_git/features/common/split_diff_view.dart';
import 'package:remote_magic_git/features/repository/diff_popout_window.dart';
import 'package:remote_magic_git/features/repository/hunk_diff_view.dart';
import 'package:remote_magic_git/features/repository/repo_status_view.dart';

const _repo = '/srv/repo';

const _diff =
    'diff --git a/lib/a.dart b/lib/a.dart\n'
    'index 111..222 100644\n'
    '--- a/lib/a.dart\n'
    '+++ b/lib/a.dart\n'
    '@@ -1,2 +1,2 @@\n'
    ' keep\n'
    '-old\n'
    '+new\n';

class _FakeGitService extends GitService {
  _FakeGitService() : super(SSHCommandExecutor(SSHClientManager()));
}

class _HiddenFileView extends FileViewVisibility {
  @override
  bool build() => false;
}

Finder _byMacosTooltip(String message) =>
    find.byWidgetPredicate((w) => w is MacosTooltip && w.message == message);

Future<void> _pump(WidgetTester tester) async {
  final container = ProviderContainer(
    overrides: [
      gitServiceProvider.overrideWithValue(_FakeGitService()),
      statusProvider(_repo).overrideWith(
        (ref) async => GitStatus(
          branch: const GitBranchInfo(),
          files: const [
            GitFileStatus(path: 'lib/a.dart', statusX: '.', statusY: 'M'),
          ],
        ),
      ),
      pendingOpProvider(_repo).overrideWith((ref) async => PendingOp.none),
      repoWatchProvider(_repo).overrideWith(
        (ref) => const Stream<RepoWatchEvent>.empty(),
      ),
      fileViewVisibleProvider.overrideWith(_HiddenFileView.new),
      refsProvider(_repo).overrideWith((ref) async => const []),
      // Sibling of the refs override: the views now read CONFIGURED
      // remotes (remotesProvider), not remote-tracking refs.
      remotesProvider(_repo).overrideWith((ref) async => const <String>[]),
      fileDiffProvider((
        _repo,
        'lib/a.dart',
        false,
        false,
        3,
      )).overrideWith((ref) async => _diff),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MacosApp(
        debugShowCheckedModeBanner: false,
        home: RepoStatusView(repoPath: _repo),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'Pop out relocates the diff into a floating window and hides the inline '
    'panel',
    (tester) async {
      await _pump(tester);
      await tester.tap(find.text('lib/a.dart'));
      await tester.pumpAndSettle();

      expect(_byMacosTooltip('Close diff'), findsOneWidget);
      expect(find.byType(DiffPopoutWindow), findsNothing);

      await tester.tap(_byMacosTooltip('Open diff in a larger window'));
      await tester.pumpAndSettle();

      expect(find.byType(DiffPopoutWindow), findsOneWidget);
      expect(_byMacosTooltip('Close diff'), findsNothing);
      expect(_byMacosTooltip('Close pop-out'), findsOneWidget);
      // The diff itself still renders, now inside the pop-out.
      expect(find.text('+new'), findsOneWidget);
    },
  );

  testWidgets(
    'closing the pop-out returns the diff to the inline panel',
    (tester) async {
      await _pump(tester);
      await tester.tap(find.text('lib/a.dart'));
      await tester.pumpAndSettle();
      await tester.tap(_byMacosTooltip('Open diff in a larger window'));
      await tester.pumpAndSettle();

      await tester.tap(_byMacosTooltip('Close pop-out'));
      await tester.pumpAndSettle();

      expect(find.byType(DiffPopoutWindow), findsNothing);
      expect(_byMacosTooltip('Close diff'), findsOneWidget);
      expect(find.text('+new'), findsOneWidget);
    },
  );

  testWidgets(
    "the pop-out's side-by-side toggle is independent and switches its own "
    'rendering',
    (tester) async {
      await _pump(tester);
      await tester.tap(find.text('lib/a.dart'));
      await tester.pumpAndSettle();
      await tester.tap(_byMacosTooltip('Open diff in a larger window'));
      await tester.pumpAndSettle();

      // Seeded from the inline panel's untouched default: unified, not split.
      expect(find.byType(HunkDiffView), findsOneWidget);
      expect(find.byType(SplitDiffView), findsNothing);

      await tester.tap(_byMacosTooltip('Side-by-side'));
      await tester.pumpAndSettle();

      expect(find.byType(SplitDiffView), findsOneWidget);
      expect(find.byType(HunkDiffView), findsNothing);
    },
  );

  testWidgets(
    'toggling side-by-side on grows a narrow pop-out toward 85% of its host',
    (tester) async {
      await _pump(tester);
      await tester.tap(find.text('lib/a.dart'));
      await tester.pumpAndSettle();
      await tester.tap(_byMacosTooltip('Open diff in a larger window'));
      await tester.pumpAndSettle();

      // Opens at 60% of the host — narrower than two comfortable columns.
      final initial = tester.getSize(find.byType(DiffPopoutWindow));

      await tester.tap(_byMacosTooltip('Side-by-side'));
      await tester.pumpAndSettle();
      final grown = tester.getSize(find.byType(DiffPopoutWindow));
      expect(grown.width, greaterThan(initial.width),
          reason: 'split needs the room of two columns');

      // Toggling split OFF leaves the size alone (a nudge, not a constraint).
      await tester.tap(_byMacosTooltip('Side-by-side'));
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(DiffPopoutWindow)).width, grown.width);
    },
  );

  testWidgets(
    'the resize handle grows the window and clamps it to a minimum size',
    (tester) async {
      await _pump(tester);
      await tester.tap(find.text('lib/a.dart'));
      await tester.pumpAndSettle();
      await tester.tap(_byMacosTooltip('Open diff in a larger window'));
      await tester.pumpAndSettle();

      final initial = tester.getSize(find.byType(DiffPopoutWindow));
      final handle = find.byIcon(CupertinoIcons.arrow_up_left_arrow_down_right);

      await tester.drag(handle, const Offset(80, 60));
      await tester.pumpAndSettle();
      final grown = tester.getSize(find.byType(DiffPopoutWindow));
      expect(grown.width, greaterThan(initial.width));
      expect(grown.height, greaterThan(initial.height));

      // A large shrink clamps to the minimum rather than collapsing further.
      await tester.drag(handle, const Offset(-5000, -5000));
      await tester.pumpAndSettle();
      final shrunk = tester.getSize(find.byType(DiffPopoutWindow));
      expect(shrunk.width, 420);
      expect(shrunk.height, 280);
    },
  );

  testWidgets('Escape closes the pop-out and returns the diff inline', (
    tester,
  ) async {
    await _pump(tester);
    await tester.tap(find.text('lib/a.dart'));
    await tester.pumpAndSettle();
    await tester.tap(_byMacosTooltip('Open diff in a larger window'));
    await tester.pumpAndSettle();
    expect(find.byType(DiffPopoutWindow), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(find.byType(DiffPopoutWindow), findsNothing);
    expect(_byMacosTooltip('Close diff'), findsOneWidget);
  });

  testWidgets(
    'a pop-out near the edge is pulled back inside when its bounds shrink',
    (tester) async {
      Widget host(Size bounds) {
        return MacosApp(
          debugShowCheckedModeBanner: false,
          home: MacosWindow(
            child: ContentArea(
              builder: (_, _) => Stack(
                children: [
                  DiffPopoutWindow(
                    repoPath: _repo,
                    path: 'lib/a.dart',
                    staged: false,
                    untracked: false,
                    initialSplit: false,
                    initialIgnoreWs: false,
                    contextLines: 3,
                    bounds: bounds,
                    onHunkAction: (_, _, _) {},
                    onClose: () {},
                  ),
                ],
              ),
            ),
          ),
        );
      }

      final container = ProviderContainer(
        overrides: [
          gitServiceProvider.overrideWithValue(_FakeGitService()),
          fileDiffProvider((
            _repo,
            'lib/a.dart',
            false,
            false,
            3,
          )).overrideWith((ref) async => _diff),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: host(const Size(800, 600)),
        ),
      );
      await tester.pumpAndSettle();

      // Park the window against the bottom-right corner.
      final titleBar = tester.getTopLeft(find.byType(DiffPopoutWindow));
      await tester.dragFrom(
        titleBar + const Offset(20, 10),
        const Offset(2000, 2000),
      );
      await tester.pumpAndSettle();

      // The content area shrinks (window resized / sidebar widened). The
      // pop-out must be re-fitted and pulled fully back inside — previously it
      // stayed at its old offset with the resize handle stranded off-screen.
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: host(const Size(500, 400)),
        ),
      );
      await tester.pumpAndSettle();

      final rect = tester.getRect(find.byType(DiffPopoutWindow));
      expect(rect.right, lessThanOrEqualTo(500));
      expect(rect.bottom, lessThanOrEqualTo(400));
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.top, greaterThanOrEqualTo(0));
    },
  );

  testWidgets(
    'builds without throwing when the content area is narrower than the min',
    (tester) async {
      // The pop-out lives in the content area (window minus sidebar), which can
      // be narrower than its 420 minimum even when the whole window isn't. The
      // size clamp used to throw ArgumentError (lower > upper) in initState.
      final container = ProviderContainer(
        overrides: [
          gitServiceProvider.overrideWithValue(_FakeGitService()),
          fileDiffProvider((
            _repo,
            'lib/a.dart',
            false,
            false,
            3,
          )).overrideWith((ref) async => _diff),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MacosApp(
            debugShowCheckedModeBanner: false,
            home: MacosWindow(
              child: ContentArea(
                builder: (_, _) => Stack(
                  children: [
                    DiffPopoutWindow(
                      repoPath: _repo,
                      path: 'lib/a.dart',
                      staged: false,
                      untracked: false,
                      initialSplit: false,
                      initialIgnoreWs: false,
                      contextLines: 3,
                      bounds: const Size(380, 300), // below the 420×280 minimum
                      onHunkAction: (_, _, _) {},
                      onClose: () {},
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(DiffPopoutWindow), findsOneWidget);
    },
  );

  testWidgets(
    'selecting a different file while popped out keeps it popped out',
    (tester) async {
      final container = ProviderContainer(
        overrides: [
          gitServiceProvider.overrideWithValue(_FakeGitService()),
          statusProvider(_repo).overrideWith(
            (ref) async => GitStatus(
              branch: const GitBranchInfo(),
              files: const [
                GitFileStatus(path: 'lib/a.dart', statusX: '.', statusY: 'M'),
                GitFileStatus(path: 'lib/b.dart', statusX: '.', statusY: 'M'),
              ],
            ),
          ),
          pendingOpProvider(_repo).overrideWith((ref) async => PendingOp.none),
          repoWatchProvider(_repo).overrideWith(
            (ref) => const Stream<RepoWatchEvent>.empty(),
          ),
          fileViewVisibleProvider.overrideWith(_HiddenFileView.new),
          refsProvider(_repo).overrideWith((ref) async => const []),
          // Sibling of the refs override: the views now read CONFIGURED
          // remotes (remotesProvider), not remote-tracking refs.
          remotesProvider(_repo).overrideWith((ref) async => const <String>[]),
          fileDiffProvider((
            _repo,
            'lib/a.dart',
            false,
            false,
            3,
          )).overrideWith((ref) async => _diff),
          fileDiffProvider((
            _repo,
            'lib/b.dart',
            false,
            false,
            3,
          )).overrideWith((ref) async => _diff),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MacosApp(
            debugShowCheckedModeBanner: false,
            home: RepoStatusView(repoPath: _repo),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('lib/a.dart'));
      await tester.pumpAndSettle();
      await tester.tap(_byMacosTooltip('Open diff in a larger window'));
      await tester.pumpAndSettle();
      expect(find.byType(DiffPopoutWindow), findsOneWidget);

      // The pop-out defaults to roughly centered, covering the file list
      // beneath it — drag it out of the way (by its title bar) before
      // clicking a row, exactly as a real user would need to.
      final titleBar = tester.getTopLeft(find.byType(DiffPopoutWindow));
      await tester.dragFrom(titleBar + const Offset(20, 10), const Offset(2000, 2000));
      await tester.pumpAndSettle();

      await tester.tap(find.text('lib/b.dart'));
      await tester.pumpAndSettle();

      expect(find.byType(DiffPopoutWindow), findsOneWidget);
      expect(_byMacosTooltip('Close diff'), findsNothing);
    },
  );
}
