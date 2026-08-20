// The Project tab's inline new-issue form: title-gated submit, a forge-neutral
// create dispatch, in-flight Cancel lock, and dismiss-on-success.

import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/forge/forge.dart';
import 'package:remote_magic_git/core/github/gh_service.dart';
import 'package:remote_magic_git/core/gitlab/glab_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/features/common/buttons.dart';
import 'package:remote_magic_git/features/forge/issue_create_form.dart';

const _repo = '/repo';

class _FakeGh extends GhService {
  _FakeGh() : super(SSHCommandExecutor(SSHClientManager()));
  final List<String> created = [];

  /// When set, [createIssue] blocks on it — lets a test hold a submit "in
  /// flight" to observe the busy/disabled UI.
  Completer<void>? gate;

  @override
  Future<int?> createIssue(
    String repoPath, {
    required String title,
    String body = '',
    List<String> labels = const [],
    List<String> assignees = const [],
    String? milestone,
  }) async {
    created.add(
      '$title|$body|${labels.join(',')}|${assignees.join(',')}|'
      '${milestone ?? ''}',
    );
    if (gate != null) await gate!.future;
    return null;
  }
}

class _FakeGlab extends GlabService {
  _FakeGlab() : super(SSHCommandExecutor(SSHClientManager()));
}

Future<_FakeGh> _pumpForm(WidgetTester tester, {VoidCallback? onClose}) async {
  tester.view.physicalSize = const Size(900, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final gh = _FakeGh();
  final container = ProviderContainer(
    overrides: [
      ghServiceProvider.overrideWithValue(gh),
      glabServiceProvider.overrideWithValue(_FakeGlab()),
      forgeProvider(_repo).overrideWith((ref) async => Forge.github),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MacosApp(
        debugShowCheckedModeBanner: false,
        home: IssueCreateForm(
          repoPath: _repo,
          labels: const [],
          milestones: const [],
          onClose: onClose ?? () {},
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return gh;
}

AppPushButton _button(WidgetTester tester, String label) =>
    tester.widget<AppPushButton>(find.widgetWithText(AppPushButton, label));

void main() {
  testWidgets('Create is disabled until a title is entered', (tester) async {
    await _pumpForm(tester);
    expect(_button(tester, 'Create issue').onPressed, isNull);

    await tester.enterText(find.byType(MacosTextField).first, 'My bug');
    await tester.pump();
    expect(_button(tester, 'Create issue').onPressed, isNotNull);
  });

  testWidgets('submitting creates the issue and dismisses the form', (
    tester,
  ) async {
    var closed = false;
    final gh = await _pumpForm(tester, onClose: () => closed = true);

    await tester.enterText(find.byType(MacosTextField).first, 'My bug');
    await tester.pump();
    await tester.tap(find.widgetWithText(AppPushButton, 'Create issue'));
    await tester.pumpAndSettle();

    expect(gh.created, ['My bug||||']);
    expect(closed, isTrue, reason: 'a successful create closes the form');
  });

  testWidgets('Cancel is disabled while a submit is in flight', (tester) async {
    final gh = await _pumpForm(tester);
    gh.gate = Completer<void>(); // hold the create open

    await tester.enterText(find.byType(MacosTextField).first, 'My bug');
    await tester.pump();
    await tester.tap(find.widgetWithText(AppPushButton, 'Create issue'));
    await tester.pump(); // enters _submitting; createIssue awaits the gate

    expect(
      _button(tester, 'Cancel').onPressed,
      isNull,
      reason: 'a create in flight must not be cancellable',
    );

    gh.gate!.complete();
    await tester.pumpAndSettle();
    expect(gh.created, ['My bug||||']);
  });
}
