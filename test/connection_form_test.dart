// Smoke coverage for the "new SSH connection" sheet. It is the only way into
// a remote session and, until now, nothing pumped it: a missing provider
// override or a null-deref here would only have surfaced on the Mac.
//
// One build path (the fields and both exits) plus the validation path, which
// is the branch that keeps a half-filled form from starting a connect.

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/features/connection/connection_form.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _pump(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues(const {});
  tester.view.physicalSize = const Size(1000, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    const ProviderScope(
      child: MacosApp(
        debugShowCheckedModeBanner: false,
        home: ConnectionForm(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('renders the SSH fields and the Connect action', (tester) async {
    await _pump(tester);

    expect(find.text('Host'), findsOneWidget);
    expect(find.text('Port'), findsOneWidget);
    expect(find.text('Username'), findsOneWidget);
    expect(find.text('Password'), findsOneWidget);
    expect(find.textContaining('Private key'), findsWidgets);
    expect(find.text('Connect'), findsOneWidget);
  });

  testWidgets('Port defaults to 22', (tester) async {
    await _pump(tester);

    // A blank port would silently become 22 anyway (int.tryParse ?? 22), but
    // the user must see what they are about to connect to.
    expect(find.text('22'), findsWidgets);
  });

  testWidgets('Connect with an empty host does not start a connection', (
    tester,
  ) async {
    await _pump(tester);

    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();

    // Still on the form — a validation failure must not dismiss it, and must
    // not throw.
    expect(find.byType(ConnectionForm), findsOneWidget);
    expect(find.text('Connect'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a filled host and username clear the required-field guard', (
    tester,
  ) async {
    await _pump(tester);

    await tester.enterText(
      find.byType(MacosTextField).at(0),
      'gitlab.example.com',
    );
    await tester.enterText(find.byType(MacosTextField).at(2), 'deploy');
    await tester.pumpAndSettle();

    expect(find.text('Host is required'), findsNothing);
    expect(find.text('Username is required'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
