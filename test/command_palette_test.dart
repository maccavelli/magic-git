// The ⌘K command palette: it lists navigation commands and local-branch
// checkout targets, filters as you type, and arrow-key + Enter runs the
// highlighted command (proving keyboard nav works from inside its search field).

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/features/common/command_palette.dart';

const _repo = '/repo';

const _refs = [
  GitRef(name: 'refs/heads/main', oid: 'aaa', isHead: true, subject: 's'),
  GitRef(name: 'refs/heads/feature-x', oid: 'bbb', isHead: false, subject: 's'),
  GitRef(
    name: 'refs/remotes/origin/main',
    oid: 'aaa',
    isHead: false,
    subject: 's',
  ),
];

class _Recorder {
  int cloneOpened = 0;
  int createOpened = 0;
  int? panel;
  String? checkedOut;
  int refreshed = 0;
}

Future<void> _open(WidgetTester tester, _Recorder rec) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [refsProvider(_repo).overrideWith((ref) async => _refs)],
      child: MacosApp(
        debugShowCheckedModeBanner: false,
        home: Builder(
          builder: (context) => Center(
            child: PushButton(
              controlSize: ControlSize.large,
              onPressed: () => showMacosSheet<void>(
                context: context,
                builder: (_) => CommandPalette(
                  repoPath: _repo,
                  onGoToPanel: (i) => rec.panel = i,
                  onRefresh: () => rec.refreshed++,
                  onOpenSettings: () {},
                  onOpenShortcuts: () {},
                  onOpenConnections: () {},
                  onCloneRepository: () => rec.cloneOpened++,
                  onCreateRepository: () => rec.createOpened++,
                  onCheckoutBranch: (b) => rec.checkedOut = b,
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('lists navigation commands', (tester) async {
    await _open(tester, _Recorder());

    expect(find.text('Go to Repository'), findsOneWidget);
    expect(find.text('Go to History'), findsOneWidget);
    expect(find.text('Refresh'), findsOneWidget);
  });

  testWidgets('Clone/Create Repository commands invoke their callbacks', (
    tester,
  ) async {
    final rec = _Recorder();
    await _open(tester, rec);

    await tester.enterText(find.byType(MacosTextField), 'clone');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clone Repository'));
    await tester.pumpAndSettle();
    expect(rec.cloneOpened, 1);

    await _open(tester, rec);
    await tester.enterText(find.byType(MacosTextField), 'create');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create Repository'));
    await tester.pumpAndSettle();
    expect(rec.createOpened, 1);
  });

  testWidgets('offers local-branch checkouts but not remote-tracking refs', (
    tester,
  ) async {
    await _open(tester, _Recorder());
    // Narrow to just the checkout rows (they live below the fold otherwise).
    await tester.enterText(find.byType(MacosTextField), 'checkout ');
    await tester.pumpAndSettle();

    expect(find.text('Checkout main'), findsOneWidget);
    expect(find.text('Checkout feature-x'), findsOneWidget);
    // A remote-tracking ref would detach HEAD, so it isn't offered.
    expect(find.text('Checkout origin/main'), findsNothing);
  });

  testWidgets('filters the list as the query is typed', (tester) async {
    await _open(tester, _Recorder());

    await tester.enterText(find.byType(MacosTextField), 'feat');
    await tester.pumpAndSettle();

    expect(find.text('Checkout feature-x'), findsOneWidget);
    expect(find.text('Go to Repository'), findsNothing);
  });

  testWidgets('Enter runs the highlighted command; Arrow-Down moves the '
      'highlight', (tester) async {
    final rec = _Recorder();
    await _open(tester, rec);

    // First command (Go to Repository, index 0) is highlighted by default.
    // Arrow-Down → History (panel 1), Enter runs it and closes the palette.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(rec.panel, 1);
    expect(find.byType(CommandPalette), findsNothing); // closed
  });

  testWidgets('running a checkout command invokes the guarded checkout', (
    tester,
  ) async {
    final rec = _Recorder();
    await _open(tester, rec);

    await tester.enterText(find.byType(MacosTextField), 'feature-x');
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(rec.checkedOut, 'feature-x');
  });

  testWidgets('Escape closes the palette', (tester) async {
    await _open(tester, _Recorder());
    expect(find.byType(CommandPalette), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(CommandPalette), findsNothing);
  });
}
