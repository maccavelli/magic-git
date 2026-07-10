// Smoke test: verify the app boots and renders the connection form.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:remote_magic_git/main.dart';

void main() {
  testWidgets('App renders the connection landing page', (
    WidgetTester tester,
  ) async {
    // Build the app inside a ProviderScope, matching how main() runs it.
    // pumpAndSettle drains one-shot timers (e.g. macos_ui's scrollbar
    // fade-out) so none remain pending at test teardown.
    await tester.pumpWidget(const ProviderScope(child: MyApp()));
    await tester.pumpAndSettle();

    // Unconnected, the shell shows the landing page with its two actions.
    expect(find.text('Magic Git'), findsWidgets);
    expect(find.text('Connections Manager'), findsOneWidget);
    // No saved profiles in a fresh test → the recent pulldown is disabled.
    expect(find.text('No Recent Workspaces'), findsOneWidget);
    // The manager panel is not shown until its button is pressed.
    expect(find.text('Connections'), findsNothing);
  });
}
