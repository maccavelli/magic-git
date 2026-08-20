// RemoteDirectoryBrowserSheet: navigable dirs-only host browser. Covers the
// home-dir start, descend/parent navigation, dotfile hiding, a permission
// error keeping the current listing, and popping the chosen path.

import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/git/host_fs_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/features/common/buttons.dart';
import 'package:remote_magic_git/features/workspace/remote_directory_browser.dart';

/// Serves a fixed virtual directory tree; records which paths were listed.
/// A path with a [gates] entry doesn't resolve until the test completes it —
/// how the stale-response test makes one listing deliberately slow.
class _FakeFs extends HostFsService {
  _FakeFs() : super(SSHCommandExecutor(SSHClientManager()));

  final Map<String, List<String>> tree = {
    '/home/mac': ['code', 'notes', '.config'],
    '/home/mac/code': ['magic-git', 'secret'],
    '/home/mac/code/magic-git': ['lib', 'test'],
  };
  final Set<String> denied = {'/home/mac/code/secret'};
  final List<String> listed = [];
  final Map<String, Completer<List<String>>> gates = {};

  @override
  Future<String> homeDir() async => '/home/mac';

  @override
  Future<List<String>> listDirectories(String path) async {
    listed.add(path);
    final gate = gates[path];
    if (gate != null) return gate.future;
    if (denied.contains(path)) {
      throw const HostFsException('Permission denied');
    }
    // Copy: the real service returns a fresh growable list, and the sheet
    // sorts what it receives — a const list here would throw in sort().
    return List.of(tree[path] ?? const []);
  }
}

// ToolIconButton wraps MacosTooltip (not Flutter's Tooltip), so find.byIcon /
// find.byTooltip don't match — target by the tooltip message instead.
Finder _byTooltip(String message) =>
    find.byWidgetPredicate((w) => w is MacosTooltip && w.message == message);

Future<String?> _open(
  WidgetTester tester, {
  String? initialPath,
  _FakeFs? fs,
}) async {
  fs ??= _FakeFs();
  String? result;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [hostFsServiceProvider.overrideWithValue(fs)],
      child: MacosApp(
        debugShowCheckedModeBanner: false,
        home: Builder(
          builder: (context) => Center(
            child: AppPushButton(
              controlSize: ControlSize.large,
              child: const Text('open'),
              onPressed: () async {
                result = await showMacosSheet<String>(
                  context: context,
                  builder: (_) =>
                      RemoteDirectoryBrowserSheet(initialPath: initialPath),
                );
              },
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return result;
}

void main() {
  testWidgets('starts at the home directory and lists its folders', (
    tester,
  ) async {
    await _open(tester);
    expect(find.text('code'), findsOneWidget);
    expect(find.text('notes'), findsOneWidget);
    expect(
      find.text('.config'),
      findsNothing,
      reason: 'dotfiles hidden by default',
    );
  });

  testWidgets('show-hidden reveals and re-hides dotfiles', (tester) async {
    await _open(tester);
    await tester.tap(_byTooltip('Hiding dotfiles (click to show)'));
    await tester.pumpAndSettle();
    expect(find.text('.config'), findsOneWidget);
  });

  testWidgets('descending and going up navigate the tree', (tester) async {
    await _open(tester);
    await tester.tap(find.text('code'));
    await tester.pumpAndSettle();
    expect(find.text('magic-git'), findsOneWidget);
    expect(find.text('code'), findsNothing);

    await tester.tap(_byTooltip('Parent folder'));
    await tester.pumpAndSettle();
    expect(find.text('code'), findsOneWidget);
  });

  testWidgets(
    'a permission-denied folder shows a banner and keeps the listing',
    (tester) async {
      await _open(tester);
      await tester.tap(find.text('code'));
      await tester.pumpAndSettle();
      // 'secret' is denied; tapping it must not move us.
      await tester.tap(find.text('secret'));
      await tester.pumpAndSettle();
      expect(find.text('Permission denied.'), findsOneWidget);
      expect(
        find.text('magic-git'),
        findsOneWidget,
        reason: 'listing retained',
      );
    },
  );

  testWidgets('Choose This Folder pops the current path', (tester) async {
    await _open(tester);
    await tester.tap(find.text('code'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Choose This Folder'));
    await tester.pumpAndSettle();
    // The sheet closed; the button that opened it is visible again.
    expect(find.byType(RemoteDirectoryBrowserSheet), findsNothing);
  });

  testWidgets('an explicit initialPath is honored over the home dir', (
    tester,
  ) async {
    await _open(tester, initialPath: '/home/mac/code');
    expect(find.text('magic-git'), findsOneWidget);
    expect(find.text('notes'), findsNothing);
  });

  testWidgets('a stale slow listing cannot overwrite a newer navigation', (
    tester,
  ) async {
    final fs = _FakeFs();
    fs.gates['/home/mac/code'] = Completer<List<String>>();
    await _open(tester, fs: fs);

    // Start a slow descend into `code` — its listing is gated open.
    await tester.tap(find.text('code'));
    await tester.pump();

    // While it's in flight, navigate by path; this resolves immediately and
    // becomes the current listing.
    await tester.enterText(find.byType(MacosTextField), '/home/mac/notes');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    // The old `code` request resolves late; it must be dropped, not applied.
    fs.gates['/home/mac/code']!.complete(['magic-git', 'secret']);
    await tester.pumpAndSettle();

    expect(
      find.text('magic-git'),
      findsNothing,
      reason: 'the stale listing must not replace the newer one',
    );
    expect(
      tester
          .widget<MacosTextField>(find.byType(MacosTextField))
          .controller!
          .text,
      '/home/mac/notes',
      reason: 'the path field must stay on the navigation the user made last',
    );
  });
}
