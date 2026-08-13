import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/features/common/async_views.dart';

Widget _host(Widget child) => MacosApp(
  theme: MacosThemeData.dark(),
  home: MacosWindow(child: SizedBox.expand(child: child)),
);

void main() {
  testWidgets('workspace empty state explains the state and offers recovery', (
    tester,
  ) async {
    var invoked = false;
    await tester.pumpWidget(
      _host(
        WorkspaceEmptyState(
          icon: CupertinoIcons.folder,
          title: 'Working tree clean',
          message: 'There are no changes to review.',
          actionLabel: 'Open Files',
          onAction: () => invoked = true,
        ),
      ),
    );

    expect(find.text('Working tree clean'), findsOneWidget);
    expect(find.text('There are no changes to review.'), findsOneWidget);
    await tester.tap(find.text('Open Files'));
    expect(invoked, isTrue);
  });

  testWidgets('partial error retains last-known-good content and retry', (
    tester,
  ) async {
    var retried = false;
    await tester.pumpWidget(
      _host(
        WorkspacePartialError(
          error: StateError('refresh failed'),
          onRetry: () => retried = true,
          child: const Text('existing content'),
        ),
      ),
    );

    expect(find.textContaining('refresh failed'), findsOneWidget);
    expect(find.text('existing content'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    expect(retried, isTrue);
  });

  testWidgets('stale and unavailable states communicate without color alone', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const Column(
          children: [
            WorkspaceStaleBanner(message: 'Cached results'),
            Expanded(
              child: WorkspaceUnavailable(
                title: 'CI unavailable',
                message: 'No forge remote is configured.',
              ),
            ),
          ],
        ),
      ),
    );
    expect(find.text('Cached results'), findsOneWidget);
    expect(find.text('CI unavailable'), findsOneWidget);
    expect(find.text('No forge remote is configured.'), findsOneWidget);
  });
}
