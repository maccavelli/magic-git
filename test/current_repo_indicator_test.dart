// CurrentRepoIndicator: the bottom-of-sidebar active-repo tile now surfaces the
// working-tree state (dirty/conflict dot + ahead/behind) from the already-
// resolved statusProvider.

import 'package:flutter/widgets.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/utils/git_porcelain_parser.dart';
import 'package:remote_magic_git/features/switcher/current_repo_indicator.dart';

class _StubConnection extends ConnectionController {
  _StubConnection(this._state);
  final ConnectionState _state;
  @override
  ConnectionState build() => _state;
}

Future<void> _pump(WidgetTester tester, GitStatus status) async {
  const state = ConnectionState(
    phase: ConnectionPhase.connected,
    repoPath: '/srv/repo',
    repoPaths: ['/srv/repo'],
    connectionLabel: 'Prod',
    host: 'host',
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        connectionProvider.overrideWith(() => _StubConnection(state)),
        statusProvider.overrideWith((ref, repo) async => status),
      ],
      child: const MacosApp(
        home: MacosWindow(
          child: ContentArea(
            builder: _builder,
          ),
        ),
      ),
    ),
  );
  await tester.pump(); // resolve the status future
}

Widget _builder(BuildContext context, ScrollController _) =>
    const Align(alignment: Alignment.bottomCenter, child: CurrentRepoIndicator());

bool _isDot(Widget w, Color color) {
  if (w is! Container) return false;
  final d = w.decoration;
  return d is BoxDecoration && d.shape == BoxShape.circle && d.color == color;
}

void main() {
  testWidgets('clean + in sync shows the repo but no status dot', (tester) async {
    await _pump(
      tester,
      GitStatus(branch: const GitBranchInfo(head: 'main'), files: const []),
    );
    expect(find.text('repo'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (w) => _isDot(w, MacosColors.systemOrangeColor) ||
            _isDot(w, MacosColors.systemRedColor),
      ),
      findsNothing,
    );
  });

  testWidgets('a dirty tree shows an orange dot', (tester) async {
    await _pump(
      tester,
      GitStatus(
        branch: const GitBranchInfo(head: 'main'),
        files: const [GitFileStatus(path: 'a.dart', statusX: '.', statusY: 'M')],
      ),
    );
    expect(
      find.byWidgetPredicate((w) => _isDot(w, MacosColors.systemOrangeColor)),
      findsOneWidget,
    );
  });

  testWidgets('conflicts show a red dot', (tester) async {
    await _pump(
      tester,
      GitStatus(
        branch: const GitBranchInfo(head: 'main'),
        files: const [GitFileStatus(path: 'a.dart', statusX: 'U', statusY: 'U')],
      ),
    );
    expect(
      find.byWidgetPredicate((w) => _isDot(w, MacosColors.systemRedColor)),
      findsOneWidget,
    );
  });

  testWidgets('ahead/behind counts render', (tester) async {
    await _pump(
      tester,
      GitStatus(
        branch: const GitBranchInfo(head: 'main', ahead: 2, behind: 1),
        files: const [],
      ),
    );
    expect(find.text('2'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
  });
}
