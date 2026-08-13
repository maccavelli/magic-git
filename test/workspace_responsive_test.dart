import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/settings/repository_workspace_prefs.dart';
import 'package:remote_magic_git/features/common/repository_context.dart';
import 'package:remote_magic_git/features/common/repository_context_bar.dart';
import 'package:remote_magic_git/features/common/repository_workspace_scaffold.dart';

const _snapshot = RepositoryContextSnapshot(
  repositoryPath: '/workspace/a-very-long-repository-name',
  repositoryName: 'a-very-long-repository-name',
  connectionLabel: 'Local',
  hostLabel: 'On this Mac',
  branchLabel: 'feature/accessible-responsive-workspace',
  upstreamLabel: 'origin/feature/accessible-responsive-workspace',
  ahead: 12,
  behind: 3,
  changedCount: 47,
  conflictCount: 2,
  hasUpstream: true,
  hasConfiguredRemote: true,
);

Widget _host(Size size, double scale, VoidCallback primary) => ProviderScope(
  child: MacosApp(
    debugShowCheckedModeBanner: false,
    home: MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(scale)),
      child: SizedBox(
        width: size.width,
        height: size.height,
        child: RepositoryWorkspaceScaffold(
          repositoryContext: RepositoryContextBar(
            snapshot: _snapshot,
            primaryAction: const RepositoryPrimaryAction(
              kind: RepositoryPrimaryActionKind.resolve,
              label: 'Resolve',
            ),
            onPrimaryAction: (_) => primary(),
          ),
          navigator: const Center(child: Text('47 changed files')),
          canvas: const Center(child: Text('Selected diff')),
          inspector: const Center(child: Text('Inspector')),
          inspectorVisible: true,
          preferences: const RepositoryWorkspacePrefs(inspectorPinned: true),
        ),
      ),
    ),
  ),
);

void main() {
  for (final size in const [
    Size(640, 480),
    Size(1080, 720),
    Size(1600, 1000),
  ]) {
    for (final scale in const [1.0, 1.3, 1.6]) {
      testWidgets('${size.width.toInt()}x${size.height.toInt()} at ${scale}x '
          'keeps primary action reachable without overflow', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        var invoked = false;
        await tester.pumpWidget(_host(size, scale, () => invoked = true));
        await tester.pump();

        expect(tester.takeException(), isNull);
        expect(find.text('Resolve'), findsOneWidget);
        await tester.tap(find.text('Resolve'));
        expect(invoked, isTrue);
      });
    }
  }
}
