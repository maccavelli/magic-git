import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/features/repository/commit_composer.dart';
import 'package:remote_magic_git/features/repository/commit_composer_controller.dart';

CommitComposerController _controller({bool gpg = false}) {
  final controller = CommitComposerController(
    repoPath: '/repo',
    generatePreview: () async => null,
    loadGpgSignConfigured: () async => gpg,
  );
  controller.updateStaged(count: 2, signature: 'a');
  return controller;
}

Future<void> _pump(
  WidgetTester tester,
  CommitComposerController controller,
  CommitComposerPresentation presentation, {
  VoidCallback? onCollapse,
}) async {
  await tester.pumpWidget(
    MacosApp(
      home: SizedBox(
        width: 800,
        height: 420,
        child: CommitComposer(
          controller: controller,
          presentation: presentation,
          branchLabel: 'feature/composer',
          onAccept: (_) async {},
          onCollapse: onCollapse,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('collapsed form exposes staged count, branch, and expansion', (
    tester,
  ) async {
    final controller = _controller();
    addTearDown(controller.dispose);
    await _pump(tester, controller, CommitComposerPresentation.collapsed);

    expect(find.textContaining('2 staged files'), findsOneWidget);
    expect(find.textContaining('feature/composer'), findsOneWidget);
    expect(find.text('Commit…'), findsOneWidget);
    expect(find.byType(MacosTextField), findsNothing);
  });

  testWidgets('expanded form shows message, GPG disclosure, and actions', (
    tester,
  ) async {
    final controller = _controller(gpg: true);
    addTearDown(controller.dispose);
    await _pump(tester, controller, CommitComposerPresentation.expanded);

    expect(find.byType(MacosTextField), findsOneWidget);
    expect(find.textContaining('GPG signing is configured'), findsOneWidget);
    expect(find.text('Accept'), findsOneWidget);
    expect(find.text('Accept + Push'), findsOneWidget);
    expect(find.text('Clear'), findsOneWidget);
  });
}
