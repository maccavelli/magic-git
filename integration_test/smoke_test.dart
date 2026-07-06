import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:remote_magic_git/main.dart' as app;

/// Smoke harness for on-device / CI runs with a reachable SSH host.
/// Requires `INTEGRATION_SSH_HOST` (and related env) — skipped when unset.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('app launches the connection form', (tester) async {
    app.main();
    await tester.pumpAndSettle();
    expect(find.text('Connect'), findsOneWidget);
  });
}
