import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/features/app_shell.dart';
import 'package:remote_magic_git/features/connection/connection_landing.dart';

void main() {
  testWidgets('640px window hides the main sidebar without losing content', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(640, 480);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      const ProviderScope(
        child: MacosApp(home: SizedBox.expand(child: AppShell())),
      ),
    );
    await tester.pumpAndSettle();

    final contentContext = tester.element(find.byType(ConnectionLanding));
    expect(MacosWindowScope.of(contentContext).isSidebarShown, isFalse);
    expect(find.text('Connections Manager'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
