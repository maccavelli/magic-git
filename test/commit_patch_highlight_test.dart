// CommitPatchView (history commit diffs) now syntax-highlights each file's code
// rows against that file's language, while keeping the add/remove sense.

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/features/common/commit_patch_view.dart';

const _repo = '/repo';
const _hash = 'abc1234';

const _patch =
    'commit abc1234\n'
    'Author: Dev <d@e>\n'
    '\n'
    '    tweak\n'
    '\n'
    'diff --git a/lib/foo.dart b/lib/foo.dart\n'
    'index 111..222 100644\n'
    '--- a/lib/foo.dart\n'
    '+++ b/lib/foo.dart\n'
    '@@ -1,3 +1,3 @@\n'
    ' class Foo {\n'
    '-  final int value = 1;\n'
    '+  final int value = 2;\n'
    ' }\n';

class _FakeGit extends GitService {
  _FakeGit() : super(SSHCommandExecutor(SSHClientManager()));
}

List<Color> _leafColors(WidgetTester tester) {
  final colors = <Color>[];
  void walk(InlineSpan s) {
    if (s is TextSpan) {
      if ((s.text?.isNotEmpty ?? false) && s.style?.color != null) {
        colors.add(s.style!.color!);
      }
      for (final c in s.children ?? const <InlineSpan>[]) {
        walk(c);
      }
    }
  }

  for (final rt in tester.widgetList<RichText>(find.byType(RichText))) {
    walk(rt.text);
  }
  return colors;
}

Future<void> _pump(WidgetTester tester) async {
  final container = ProviderContainer(
    overrides: [gitServiceProvider.overrideWithValue(_FakeGit())],
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
}

void main() {
  testWidgets('code rows carry more than one syntax colour', (tester) async {
    await _pump(tester);
    // A recognised .dart file yields several token colours across its code rows
    // (keywords vs identifiers vs numbers), not one flat green/red.
    expect(_leafColors(tester).toSet().length, greaterThan(1));
  });

  testWidgets('the changed line still renders', (tester) async {
    await _pump(tester);
    // The added content is still present (highlighting doesn't drop text).
    expect(find.textContaining('final int value = 2;'), findsOneWidget);
  });
}
