// The Create Tag sheet: annotated-by-default with the message mirroring the
// name until edited, client-side name validation with specific messages, a
// push-after-create checkbox that exists only when a remote does, persisted
// defaults, and the create-succeeded/push-failed split that must never lose
// the created tag.

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/features/branches/create_tag_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _repo = '/repo';

class _RecordingGit extends GitService {
  _RecordingGit() : super(SSHCommandExecutor(SSHClientManager()));

  final createCalls = <(String name, String? message, String ref)>[];
  final pushCalls = <(String name, String remote)>[];

  /// When set, createTag throws it (the name-collision case).
  GitException? failCreateWith;

  @override
  Future<void> createTag(
    String repoPath,
    String name, {
    String? message,
    String ref = 'HEAD',
  }) async {
    final fail = failCreateWith;
    if (fail != null) throw fail;
    createCalls.add((name, message, ref));
  }

  @override
  Future<SSHCommandResult> pushTag(
    String repoPath,
    String name, {
    String remote = 'origin',
  }) async {
    pushCalls.add((name, remote));
    return const SSHCommandResult(exitCode: 0, stdout: '', stderr: '');
  }
}

Future<_RecordingGit> _pump(
  WidgetTester tester, {
  List<String> remotes = const ['origin'],
  String? initialRef,
  String? initialRefLabel,
}) async {
  tester.view.physicalSize = const Size(900, 1200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final git = _RecordingGit();
  final container = ProviderContainer(
    overrides: [
      gitServiceProvider.overrideWithValue(git),
      remotesProvider(_repo).overrideWith((ref) async => remotes),
      remoteTagsProvider(_repo).overrideWith((ref) async => null),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MacosApp(
        debugShowCheckedModeBanner: false,
        // Behind a launcher so the sheet sits on a poppable route — the
        // successful-submit path closes itself with Navigator.pop.
        home: Builder(
          builder: (context) => PushButton(
            controlSize: ControlSize.large,
            onPressed: () => showMacosSheet<bool>(
              context: context,
              builder: (_) => CreateTagSheet(
                repoPath: _repo,
                initialRef: initialRef,
                initialRefLabel: initialRefLabel,
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return git;
}

Finder get _createButton => find.widgetWithText(PushButton, 'Create Tag');

VoidCallback? _createEnabled(WidgetTester tester) =>
    tester.widget<PushButton>(_createButton).onPressed;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('annotated by default: the message mirrors the name until '
      'edited, and one field is enough to submit', (tester) async {
    final git = await _pump(tester);

    // Annotated default on → the message field is present.
    expect(find.text('Tag message'), findsOneWidget);
    expect(_createEnabled(tester), isNull, reason: 'no name yet');

    await tester.enterText(find.byType(MacosTextField).first, 'v1.2.23');
    await tester.pump();
    expect(_createEnabled(tester), isNotNull,
        reason: 'the mirrored message satisfies the annotated requirement');

    await tester.tap(_createButton);
    await tester.pumpAndSettle();

    expect(git.createCalls, [('v1.2.23', 'v1.2.23', 'HEAD')]);
    expect(git.pushCalls, [('v1.2.23', 'origin')],
        reason: 'push-after-create defaults ON — the whole point');
    expect(find.byType(CreateTagSheet), findsNothing,
        reason: 'the sheet closes after a successful create');
  });

  testWidgets('an invalid name names its violation and disables Create',
      (tester) async {
    await _pump(tester);

    await tester.enterText(find.byType(MacosTextField).first, 'v1..2');
    await tester.pump();
    expect(find.text('A tag name cannot contain "..".'), findsOneWidget);
    expect(_createEnabled(tester), isNull);
  });

  testWidgets('unchecking Annotated hides the message and creates a '
      'lightweight tag; unchecking Push skips the push; both choices persist',
      (tester) async {
    final git = await _pump(tester);

    await tester.enterText(find.byType(MacosTextField).first, 'wip');
    // First checkbox = annotated, second = push-after-create.
    await tester.tap(find.byType(MacosCheckbox).first);
    await tester.pump();
    expect(find.text('Tag message'), findsNothing);
    await tester.tap(find.byType(MacosCheckbox).last);
    await tester.pump();

    await tester.tap(_createButton);
    await tester.pumpAndSettle();

    expect(git.createCalls, [('wip', null, 'HEAD')],
        reason: 'no message → lightweight');
    expect(git.pushCalls, isEmpty);

    // The sheet remembers both choices for next time.
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('tagAnnotatedByDefault'), isFalse);
    expect(prefs.getBool('tagPushAfterCreate'), isFalse);
  });

  testWidgets('no remote → no push checkbox, and the create is local-only',
      (tester) async {
    final git = await _pump(tester, remotes: const []);

    expect(find.textContaining('after creating'), findsNothing);

    await tester.enterText(find.byType(MacosTextField).first, 'v1');
    await tester.pump();
    await tester.tap(_createButton);
    await tester.pumpAndSettle();

    expect(git.createCalls, hasLength(1));
    expect(git.pushCalls, isEmpty);
  });

  testWidgets('a commit handed in from History becomes the tag target and '
      'the sheet says so', (tester) async {
    final git = await _pump(
      tester,
      initialRef: 'abc123def',
      initialRefLabel: 'abc123d — fix the thing',
    );

    expect(find.textContaining('abc123d — fix the thing'), findsOneWidget);

    await tester.enterText(find.byType(MacosTextField).first, 'v2');
    await tester.pump();
    await tester.tap(_createButton);
    await tester.pumpAndSettle();

    expect(git.createCalls.single.$3, 'abc123def');
  });

  testWidgets('a name collision surfaces the error and keeps the sheet open '
      'for another attempt', (tester) async {
    final git = await _pump(tester);
    git.failCreateWith = const GitException(
      'git tag failed',
      SSHCommandResult(
        exitCode: 128,
        stdout: '',
        stderr: "fatal: tag 'v1' already exists",
      ),
    );

    await tester.enterText(find.byType(MacosTextField).first, 'v1');
    await tester.pump();
    await tester.tap(_createButton);
    await tester.pumpAndSettle();

    expect(find.textContaining('already exists'), findsOneWidget);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    expect(find.byType(CreateTagSheet), findsOneWidget,
        reason: 'still open — fix the name and try again');
    expect(git.pushCalls, isEmpty,
        reason: 'no push after a failed create');
  });
}
