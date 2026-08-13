// The commit patch viewer end to end: a hunk that git cut off at 3 context
// lines, an expander, a click, and the real surrounding code appearing — read
// from the file's blob at that commit.

import 'dart:convert';

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/features/common/commit_patch_view.dart';
import 'package:remote_magic_git/features/common/image_diff_view.dart';

const _repo = '/repo';
const _hash = 'abc1234';

/// f.dart as of the commit: 40 lines.
final _blob = [for (var i = 1; i <= 40; i++) 'line $i'].join('\n');

/// The commit changed line 20, so git's -U3 shows only 17-23.
const _patch =
    'commit abc1234\n'
    'Author: Dev <d@e>\n'
    '\n'
    '    tweak line 20\n'
    '\n'
    'diff --git a/f.dart b/f.dart\n'
    'index 111..222 100644\n'
    '--- a/f.dart\n'
    '+++ b/f.dart\n'
    '@@ -17,7 +17,7 @@\n'
    ' line 17\n'
    ' line 18\n'
    ' line 19\n'
    '-line 20\n'
    '+line 20\n'
    ' line 21\n'
    ' line 22\n'
    ' line 23\n';

const _binaryPatch =
    'commit abc1234\n'
    'Author: Dev <d@e>\n'
    '\n'
    '    update logo\n'
    '\n'
    'diff --git a/logo.png b/logo.png\n'
    'index 111..222 100644\n'
    'Binary files a/logo.png and b/logo.png differ\n';

final _pngBase64 = base64.encode(
  base64.decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8'
    'AAAAASUVORK5CYII=',
  ),
);

class _BlobGit extends GitService {
  _BlobGit() : super(SSHCommandExecutor(SSHClientManager()));

  int blobFetches = 0;
  final List<String> imageFetches = [];

  @override
  Future<String> showBlob(String repoPath, String rev, String path) async {
    blobFetches++;
    return _blob;
  }

  @override
  Future<String> showBlobBase64(
    String repoPath,
    String revision,
    String path, {
    int maxBytes = kImageDiffMaxEncodedBytes,
  }) async {
    imageFetches.add('$revision:$path');
    return _pngBase64;
  }
}

/// The gap controls draw with [MacosIcon], which `find.byIcon` (an `Icon`
/// finder) doesn't see.
Finder _chevron(IconData icon) =>
    find.byWidgetPredicate((w) => w is MacosIcon && w.icon == icon);

Future<_BlobGit> _pump(WidgetTester tester, {String diff = _patch}) async {
  final git = _BlobGit();
  final container = ProviderContainer(
    overrides: [gitServiceProvider.overrideWithValue(git)],
  );
  addTearDown(container.dispose);
  await tester.binding.setSurfaceSize(const Size(900, 700));
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MacosApp(
        debugShowCheckedModeBanner: false,
        home: SizedBox(
          height: 700,
          child: CommitPatchView(repoPath: _repo, hash: _hash, diff: diff),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return git;
}

void main() {
  testWidgets('binary image commit offers lazy bounded visual comparison', (
    tester,
  ) async {
    final git = await _pump(tester, diff: _binaryPatch);
    expect(find.text('Review logo.png'), findsOneWidget);
    expect(git.imageFetches, isEmpty);

    await tester.tap(find.text('Review logo.png'));
    await tester.pumpAndSettle();

    expect(find.byType(ImageDiffView), findsOneWidget);
    expect(git.imageFetches, ['$_hash^:logo.png', '$_hash:logo.png']);
    await tester.tap(find.text('Text patch'));
    await tester.pump();
    expect(find.textContaining('Binary files'), findsOneWidget);
  });

  testWidgets('the gaps git left are shown as expanders, and cost nothing', (
    tester,
  ) async {
    final git = await _pump(tester);

    // The gap ABOVE the hunk is known from the hunk header alone (lines 1-16),
    // so it can be offered precisely without fetching anything.
    expect(find.textContaining('Show 16 lines'), findsOneWidget);
    // The gap BELOW it runs to the end of the file, whose length is not knowable
    // from the patch — so it offers to show more without claiming a count.
    expect(find.textContaining('Show more'), findsOneWidget);

    // No blob is fetched until the user actually asks to expand — otherwise
    // every commit selection would cost one git command per file touched.
    expect(git.blobFetches, 0);
  });

  testWidgets('clicking an expander reveals the real surrounding code', (
    tester,
  ) async {
    final git = await _pump(tester);

    // The lines above the hunk are not in the patch at all.
    expect(find.text(' line 16'), findsNothing);

    await tester.tap(find.textContaining('Show 16 lines'));
    await tester.pumpAndSettle();

    expect(git.blobFetches, 1);
    // The whole gap (lines 1-16) is revealed, as context, in the right place.
    expect(find.text(' line 1'), findsOneWidget);
    expect(find.text(' line 16'), findsOneWidget);
    // …and it is no longer offered for expansion.
    expect(find.textContaining('Show 16 lines'), findsNothing);
    // The hunk's own lines are untouched.
    expect(find.text('+line 20'), findsOneWidget);
    // With the blob now in hand, the trailing gap knows its real size (lines
    // 24-40) instead of the vague "Show more" it offered before, and — being
    // small — offers to swallow it in one click.
    expect(find.textContaining('Show 17 lines'), findsOneWidget);
  });

  testWidgets('what a click opens, a click closes', (tester) async {
    await _pump(tester);

    // Down-chevron to open…
    expect(_chevron(CupertinoIcons.chevron_down), findsWidgets);
    expect(_chevron(CupertinoIcons.chevron_up), findsNothing);

    await tester.tap(find.textContaining('Show 16 lines'));
    await tester.pumpAndSettle();
    expect(find.text(' line 16'), findsOneWidget);

    // …and an up-chevron to close, which is the only signal the user gets that
    // the click will minimize rather than expand.
    expect(_chevron(CupertinoIcons.chevron_up), findsOneWidget);
    expect(find.textContaining('Hide 16 lines'), findsOneWidget);
    await tester.tap(find.textContaining('Hide 16 lines'));
    await tester.pumpAndSettle();

    expect(find.text(' line 16'), findsNothing);
    expect(find.text(' line 1'), findsNothing);
    // Back to where it started: offered again, not consumed.
    expect(find.textContaining('Show 16 lines'), findsOneWidget);
    expect(find.text('+line 20'), findsOneWidget);
  });

  testWidgets('the whole expander row is the click target', (tester) async {
    await _pump(tester);

    // Not the chevron — the far end of the row, well past the label. Inside a
    // SelectionArea a Text installs its own I-beam cursor, which made the row
    // look (and, for the icon-only hit target, behave) as though only the 11px
    // chevron was live.
    final row = find.ancestor(
      of: find.textContaining('Show 16 lines'),
      matching: find.byType(GestureDetector),
    );
    final box = tester.getRect(row.first);
    await tester.tapAt(Offset(box.right - 4, box.center.dy));
    await tester.pumpAndSettle();

    expect(find.text(' line 16'), findsOneWidget);
  });

  testWidgets('a stale blob is never spliced', (tester) async {
    // A blob that does NOT match the hunks (everything shifted by one). A naive
    // splice would render line 15's text where line 16 belongs — silently wrong
    // code presented as part of the commit. It must refuse instead.
    final git = _ShiftedBlobGit();
    final container = ProviderContainer(
      overrides: [gitServiceProvider.overrideWithValue(git)],
    );
    addTearDown(container.dispose);
    await tester.binding.setSurfaceSize(const Size(900, 700));
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MacosApp(
          debugShowCheckedModeBanner: false,
          home: SizedBox(
            height: 700,
            child: CommitPatchView(repoPath: _repo, hash: _hash, diff: _patch),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.textContaining('Show 16 lines'));
    await tester.pumpAndSettle();

    // Nothing spliced: not the shifted lines, not anything.
    expect(find.text(' line 16'), findsNothing);
    expect(find.text(' shifted'), findsNothing);
    // The patch itself still renders in full.
    expect(find.text('+line 20'), findsOneWidget);
  });
}

class _ShiftedBlobGit extends GitService {
  _ShiftedBlobGit() : super(SSHCommandExecutor(SSHClientManager()));

  @override
  Future<String> showBlob(String repoPath, String rev, String path) async =>
      ['shifted', for (var i = 1; i <= 40; i++) 'line $i'].join('\n');
}
