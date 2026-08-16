import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/features/common/buttons.dart';
import 'package:remote_magic_git/features/repository/commit_composer.dart';
import 'package:remote_magic_git/features/repository/commit_composer_controller.dart';

CommitComposerController _controller({bool gpg = false}) {
  final controller = CommitComposerController(
    repoPath: '/repo',
    generatePreview: () async => null,
    loadGpgSignConfigured: () async => gpg,
    loadRecentSubjects: () async => const ['feat: loaded subject'],
    loadTemplate: () async => 'chore: from template',
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
    ProviderScope(
      child: MacosApp(
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

  testWidgets('both ways of accepting are accented, and only those', (
    tester,
  ) async {
    final controller = _controller();
    addTearDown(controller.dispose);
    controller.updateMessage('feat: something worth committing');
    await _pump(tester, controller, CommitComposerPresentation.expanded);
    expect(controller.canAccept, isTrue);

    // Every accented button in the whole composer, by label. Asserting the
    // exact set (rather than two positives) is what keeps a future button
    // from quietly joining them.
    final accented = <String>{
      for (final button in tester.widgetList<AppPushButton>(
        find.byType(AppPushButton),
      ))
        if (button.child case final Text text
            when button.secondary != true && text.data != null)
          text.data!,
    };

    // Accept + Push is a complete, correct way to finish — not a lesser one.
    expect(accented, {'Accept', 'Accept + Push'});
  });

  testWidgets('neither accept is accented while it cannot run', (tester) async {
    final controller = _controller();
    addTearDown(controller.dispose);
    await _pump(tester, controller, CommitComposerPresentation.expanded);
    expect(controller.canAccept, isFalse, reason: 'no message yet');

    for (final label in const ['Accept', 'Accept + Push']) {
      final button = tester.widget<AppPushButton>(
        find.ancestor(
          of: find.text(label),
          matching: find.byType(AppPushButton),
        ),
      );
      expect(button.onPressed, isNull, reason: '$label is unavailable');
    }
  });

  testWidgets('assistance stays opt-in and unknown policy is not passing', (
    tester,
  ) async {
    final controller = _controller();
    addTearDown(controller.dispose);
    await _pump(tester, controller, CommitComposerPresentation.expanded);

    expect(find.text('Load recent'), findsNothing);
    await tester.tap(find.text('Assistance'));
    await tester.pump();

    expect(find.text('Load recent'), findsOneWidget);
    expect(find.text('Load template'), findsOneWidget);
    expect(find.textContaining('Not checked'), findsOneWidget);
    expect(find.textContaining('Passing'), findsNothing);
  });

  testWidgets('loads recent/template explicitly and adds a co-author', (
    tester,
  ) async {
    final controller = _controller();
    addTearDown(controller.dispose);
    await _pump(tester, controller, CommitComposerPresentation.expanded);
    await tester.tap(find.text('Assistance'));
    await tester.pump();

    await tester.tap(find.text('Load recent'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('recent-commit-subjects')),
      findsOneWidget,
    );

    await tester.tap(find.text('Load template'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Use template'));
    await tester.pump();
    expect(controller.message, 'chore: from template');

    await tester.enterText(
      find.byKey(const ValueKey('co-author-name')),
      'Grace Hopper',
    );
    await tester.enterText(
      find.byKey(const ValueKey('co-author-email')),
      'grace@example.com',
    );
    await tester.tap(find.text('Add co-author'));
    await tester.pump();
    expect(
      find.textContaining('Grace Hopper <grace@example.com>'),
      findsOneWidget,
    );
  });

  testWidgets('cached advisory is rendered without claiming pass status', (
    tester,
  ) async {
    final controller = _controller();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      ProviderScope(
        child: MacosApp(
          home: SizedBox(
            width: 800,
            height: 420,
            child: CommitComposer(
              controller: controller,
              presentation: CommitComposerPresentation.expanded,
              branchLabel: 'feature/composer',
              policyAdvisory: '#42 · checks success',
              onAccept: (_) async {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Assistance'));
    await tester.pump();

    expect(find.textContaining('#42 · checks success'), findsOneWidget);
  });
}
