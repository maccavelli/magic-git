import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/settings/repository_workspace_prefs.dart';
import 'package:remote_magic_git/features/common/repository_context.dart';
import 'package:remote_magic_git/features/common/repository_context_bar.dart';
import 'package:remote_magic_git/features/common/repository_workspace_scaffold.dart';
import 'package:remote_magic_git/features/common/tool_icon_button.dart';

const _snapshot = RepositoryContextSnapshot(
  repositoryPath: '/projects/magic-git',
  repositoryName: 'magic-git',
  connectionLabel: 'Development Mac',
  branchLabel: 'feature/context-bar',
  upstreamLabel: 'origin/feature/context-bar',
  ahead: 2,
  changedCount: 4,
  hasUpstream: true,
  hasConfiguredRemote: true,
);

Future<void> _pump(WidgetTester tester, double width) async {
  tester.view.physicalSize = Size(width, 200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      child: MacosApp(
        home: SizedBox(
          width: width,
          child: RepositoryContextBar(
            snapshot: _snapshot,
            primaryAction: resolvePrimaryRepositoryAction(_snapshot),
            onToggleSidebar: () {},
            onPrimaryAction: (_) {},
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('compact bar keeps primary action and discloses metadata', (
    tester,
  ) async {
    await _pump(tester, 640);
    expect(find.text('Push'), findsOneWidget);
    expect(find.bySemanticsLabel('Repository details'), findsWidgets);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is ToolIconButton && widget.tooltip == 'Toggle sidebar',
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('standard bar renders status without compact disclosure', (
    tester,
  ) async {
    await _pump(tester, 900);
    expect(find.textContaining('4 changed'), findsOneWidget);
    expect(find.bySemanticsLabel('Repository details'), findsNothing);
    expect(find.text('Push'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('label preference affects secondary actions, not primary', (
    tester,
  ) async {
    RepositoryWorkspacePrefs? changed;
    tester.view.physicalSize = const Size(1100, 300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        child: MacosApp(
          home: SizedBox(
            width: 1100,
            height: 300,
            child: RepositoryWorkspaceScaffold(
              repositoryContext: RepositoryContextBar(
                snapshot: _snapshot,
                primaryAction: resolvePrimaryRepositoryAction(_snapshot),
                onBack: () {},
                onForward: () {},
                onPrimaryAction: (_) {},
              ),
              canvas: const SizedBox.shrink(),
              preferences: const RepositoryWorkspacePrefs(
                showToolbarLabels: true,
              ),
              onPreferencesChanged: (next) => changed = next,
              workspaceOptionsEnabled: true,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Back'), findsOneWidget);
    expect(find.text('Forward'), findsOneWidget);
    expect(find.text('Push'), findsOneWidget);
    final viewOptions = find.bySemanticsLabel('Workspace view options');
    expect(viewOptions, findsOneWidget);
    await tester.tap(viewOptions);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Minimal preset'));
    await tester.pumpAndSettle();
    expect(changed?.preset, WorkspacePreset.minimal);
    expect(changed?.showToolbarLabels, isTrue);
    expect(tester.takeException(), isNull);
  });
}
