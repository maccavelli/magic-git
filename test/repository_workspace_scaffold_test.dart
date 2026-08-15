// 0009 M19: a workspace that hands the scaffold an onRetry must get a real
// Retry control next to the failure — it used to be stored and dropped.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/features/common/repository_workspace_scaffold.dart';

void main() {
  testWidgets('a workspace error with onRetry renders a Retry control', (
    tester,
  ) async {
    var retried = false;
    await tester.pumpWidget(
      MacosApp(
        home: RepositoryWorkspaceScaffold(
          repositoryContext: const SizedBox(),
          canvas: const SizedBox(),
          error: StateError('boom'),
          onRetry: () => retried = true,
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('Retry'));
    expect(retried, isTrue);
  });

  testWidgets('no Retry control without an onRetry', (tester) async {
    await tester.pumpWidget(
      MacosApp(
        home: RepositoryWorkspaceScaffold(
          repositoryContext: const SizedBox(),
          canvas: const SizedBox(),
          error: StateError('boom'),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Retry'), findsNothing);
  });
}
