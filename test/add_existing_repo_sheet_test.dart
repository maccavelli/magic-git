// The Add Existing Repository sheet's scoped-repo behaviors:
//  * scoped-toggle ↔ fsmonitor interlock: git's fsmonitor daemon is never
//    valid on a scoped work-tree repo (it would index the entire work tree —
//    all of $HOME for a dotfiles repo — and git refuses it on a bare git-dir
//    anyway), so flipping the scoped toggle on must force the fsmonitor
//    toggle off AND disable it until scoped is off again.
//  * manual-toggle prefill: flipping the scoped toggle on by hand (which
//    permanently stops auto-detect from touching the toggle) still probes the
//    picked folder and pre-fills the empty git-dir field — the user should
//    never have to type a path detection can find.
//
// (The folder-pick auto-detection that flips the toggle automatically is
// exercised against real git in scoped_repo_autodetect_test.dart — the native
// picker doesn't run under `flutter test`.)
@Tags(['integration'])
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/features/connection/local_repo_form.dart';

/// The MacosSwitch sitting in the same Row as the label [text] — the switches
/// carry no semantics of their own, so the row label is the stable handle.
Finder _switchNear(String text) => find.descendant(
  of: find.ancestor(of: find.textContaining(text), matching: find.byType(Row)),
  matching: find.byType(MacosSwitch),
);

Future<void> _pump(WidgetTester tester, {String? initialPickedPath}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        savedConnectionsProvider.overrideWith((ref) async => const []),
        savedLocalReposProvider.overrideWith((ref) async => const []),
      ],
      child: MacosApp(
        debugShowCheckedModeBanner: false,
        home: AddExistingRepoSheet(initialPickedPath: initialPickedPath),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('turning the scoped toggle on forces fsmonitor off and disables '
      'it; turning it off re-enables', (tester) async {
    await _pump(tester);

    final fsmonitor = _switchNear('Enable filesystem monitor');
    final scoped = _switchNear('Scoped work-tree repo');

    // Enable fsmonitor first so the interlock has something to clear.
    await tester.ensureVisible(fsmonitor);
    await tester.tap(fsmonitor);
    await tester.pumpAndSettle();
    expect(tester.widget<MacosSwitch>(fsmonitor).value, isTrue);

    await tester.ensureVisible(scoped);
    await tester.tap(scoped);
    await tester.pumpAndSettle();

    final locked = tester.widget<MacosSwitch>(fsmonitor);
    expect(locked.value, isFalse, reason: 'scoped must clear fsmonitor');
    expect(
      locked.onChanged,
      isNull,
      reason: 'fsmonitor must be disabled while scoped',
    );
    expect(find.textContaining('Not available for a scoped'), findsOneWidget);

    // Off again: editable once more, but stays off — no silent re-enable.
    await tester.tap(scoped);
    await tester.pumpAndSettle();
    final unlocked = tester.widget<MacosSwitch>(fsmonitor);
    expect(unlocked.value, isFalse);
    expect(unlocked.onChanged, isNotNull);
  });

  testWidgets('manually toggling scoped on pre-fills the git-dir from the '
      'picked folder', (tester) async {
    // macos_ui's AccentColorListener calls a real platform channel at MacosApp
    // mount. In an ordinary widget test the unanswered call never resolves;
    // under `runAsync` (which this test needs for real git IO) the
    // MissingPluginException actually surfaces and fails the test — answer it.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('appkit_ui_element_colors'),
          (call) async => <String, double>{'hueComponent': 0.6},
        );
    // A real bare-redirect dotfiles fixture — the probe runs real git, so the
    // whole test body runs under runAsync (real process futures never resolve
    // inside the fake-async test zone).
    final tempDir = await tester.runAsync(
      () => Directory.systemTemp.createTemp('magic_git_prefill_'),
    );
    addTearDown(() => tempDir!.deleteSync(recursive: true));
    final root = tempDir!.resolveSymbolicLinksSync();
    final work = Directory('$root/home')..createSync();
    final workTree = work.resolveSymbolicLinksSync();
    final init = await tester.runAsync(
      () => Process.run('git', ['init', '--bare', '$workTree/.home.git']),
    );
    expect(init!.exitCode, 0, reason: init.stderr.toString());
    final bare = Directory('$workTree/.home.git').resolveSymbolicLinksSync();
    File('$workTree/.git').writeAsStringSync('gitdir: $bare\n');

    await _pump(tester, initialPickedPath: workTree);

    final scoped = _switchNear('Scoped work-tree repo');
    await tester.ensureVisible(scoped);
    // Tap INSIDE runAsync so the fire-and-forget probe's futures are created
    // in the real zone — real Process IO started from the fake-async zone
    // never completes.
    await tester.runAsync(() => tester.tap(scoped));
    await tester.pump();

    // Poll for the pre-filled field (the probe spawns several git processes).
    var found = false;
    for (var i = 0; i < 100 && !found; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
      found = find.widgetWithText(MacosTextField, bare).evaluate().isNotEmpty;
    }
    expect(
      found,
      isTrue,
      reason: 'the git-dir field should be pre-filled with the probed git-dir',
    );
  });
}
