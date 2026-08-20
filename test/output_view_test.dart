// Verifies the output-view render path: feeding the OutputLogNotifier a result
// must clear the placeholder and render the command + status lines. This pins
// down whether "push shows nothing" is a render-layer bug or upstream of it.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

import 'package:remote_magic_git/core/output/output_log.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/features/repository/output_view.dart';

void main() {
  testWidgets('OutputView renders lines appended to the notifier', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MacosApp(
          debugShowCheckedModeBanner: false,
          home: SizedBox(
            width: 800,
            height: 600,
            child: OutputView(maxHeight: 600),
          ),
        ),
      ),
    );
    await tester.pump();

    // Before any output, the placeholder is shown.
    expect(find.text('No output yet.'), findsOneWidget);

    // Simulate what _push does: log a successful command result.
    container
        .read(outputLogProvider.notifier)
        .logResult(
          'git push',
          const SSHCommandResult(
            exitCode: 0,
            stdout: '',
            stderr: 'To gitlab:me/repo.git\n   abc123..def456  main -> main',
          ),
        );
    await tester.pump();

    // Placeholder gone; the command header and status line are rendered.
    expect(find.text('No output yet.'), findsNothing);
    expect(find.text('\$ git push'), findsOneWidget);
    expect(find.text('✓ completed'), findsOneWidget);
    expect(find.text('   abc123..def456  main -> main'), findsOneWidget);
  });
}
