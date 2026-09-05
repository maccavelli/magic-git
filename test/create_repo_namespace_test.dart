// MADR 0031 Phases 2 and 3 — a namespace on the create-repository sheet,
// and the suggestions offered beneath it.
//
// The risk this file exists for is a **silent mis-create**: a project created
// in one place while the app wires origin to another. That is exactly what
// `--group` would cause, so the composed path is asserted to reach
// `resolveOriginUrl` as the *same string* that was created, rather than being
// trusted because the composition looked right.
//
// Phase 3's contract is the opposite of an assertion about the list: the
// field is free text, so a suggestion fetch that hangs forever or throws
// must be *invisible*. Those tests assert the field is still there and the
// create still composes, not that anything was suggested.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/forge/forge.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/features/common/buttons.dart';
import 'package:remote_magic_git/features/common/inline_action_button.dart';
import 'package:remote_magic_git/features/workspace/create_repo_sheet.dart';

import 'helpers/create_repo_harness.dart';

Finder _namespaceField() => find.byWidgetPredicate(
  (w) => w is MacosTextField && w.placeholder == 'team/subgroup',
);

const _noOrigin = SSHCommandResult(
  exitCode: 2,
  stdout: '',
  stderr: 'fatal: No such remote',
);

/// Drives the wizard to Review in GitHub mode with [name], optionally under
/// [namespace].
Future<FakeCreateExecutor> _toReview(
  WidgetTester tester, {
  required String name,
  String? namespace,
  String forge = 'GitHub',
}) async {
  final (_, exec, _) = await pumpConnected(tester);
  await nextStep(tester); // Source
  await tester.tap(find.widgetWithText(AppPushButton, forge));
  await tester.pumpAndSettle();
  await nextStep(tester); // Remote → Details
  await tester.enterText(nameField(), name);
  await tester.pumpAndSettle();
  if (namespace != null) {
    await tester.enterText(_namespaceField(), namespace);
    await tester.pumpAndSettle();
  }
  await nextStep(tester); // Details → Review
  return exec;
}

void main() {
  CreateRepositorySheet.successPopDelay = Duration.zero;

  testWidgets('a namespace composes into the positional create argument', (
    tester,
  ) async {
    final exec = await _toReview(
      tester,
      name: 'repo',
      namespace: 'team/subgroup',
    );
    exec.results.add(okResult('absent')); // probe
    exec.results.add(okResult('')); // git init
    exec.results.add(okResult('')); // gh repo create (prints nothing)
    exec.results.add(_noOrigin); // get-url: missing
    exec.results.add(
      okResult('{"login":"me"}'),
    ); // resolveOriginUrl → gh api user
    exec.results.add(
      okResult(
        '{"sshUrl":"git@github.com:team/subgroup/repo.git",'
        '"url":"https://github.com/team/subgroup/repo"}',
      ),
    );
    exec.results.add(okResult('')); // git remote add
    exec.results.add(okResult('https://github.com/team/subgroup/repo.git\n'));
    await pumpCreate(tester);

    final joined = exec.calls.map((c) => c.join(' ')).toList();
    expect(
      joined.any((c) => c.startsWith('gh repo create team/subgroup/repo')),
      isTrue,
      reason: 'the full path is the positional argument\n${joined.join('\n')}',
    );
    expect(
      joined.any((c) => c.contains('--group')),
      isFalse,
      reason: '--group would break resolveOriginUrl (MADR 0031)',
    );
  });

  testWidgets(
    'the created path is the same string origin is resolved against',
    (tester) async {
      final exec = await _toReview(
        tester,
        name: 'repo',
        namespace: 'team/subgroup',
      );
      exec.results.add(okResult('absent'));
      exec.results.add(okResult(''));
      exec.results.add(okResult('')); // create prints nothing → forces lookup
      exec.results.add(_noOrigin);
      exec.results.add(
        okResult(
          '{"sshUrl":"git@github.com:team/subgroup/repo.git",'
          '"url":"https://github.com/team/subgroup/repo"}',
        ),
      );
      exec.results.add(okResult(''));
      exec.results.add(okResult('https://github.com/team/subgroup/repo.git\n'));
      await pumpCreate(tester);

      final joined = exec.calls.map((c) => c.join(' ')).toList();
      final created = joined.firstWhere((c) => c.startsWith('gh repo create'));
      final createdPath = created.split(' ')[3];
      // `gh repo view <path>` is the lookup. A bare `repo` here would mean the
      // create and the lookup disagreed — the silent mis-create.
      final viewed = joined.firstWhere(
        (c) => c.startsWith('gh repo view'),
        orElse: () => '',
      );
      expect(createdPath, 'team/subgroup/repo');
      expect(
        viewed,
        contains('team/subgroup/repo'),
        reason:
            'origin resolved against a different path than was created:\n'
            'created=$created\nviewed=$viewed',
      );
    },
  );

  testWidgets('an empty namespace still creates a bare name', (tester) async {
    final exec = await _toReview(tester, name: 'new-proj');
    exec.results.add(okResult('absent'));
    exec.results.add(okResult(''));
    exec.results.add(okResult('https://github.com/me/new-proj\n'));
    exec.results.add(_noOrigin);
    exec.results.add(okResult('https'));
    exec.results.add(okResult(''));
    exec.results.add(okResult('https://github.com/me/new-proj.git\n'));
    await pumpCreate(tester);

    final joined = exec.calls.map((c) => c.join(' ')).toList();
    expect(joined, contains('gh repo create new-proj --private'));
  });

  testWidgets('a slash in the NAME is still refused, in newFolder mode', (
    tester,
  ) async {
    final (_, _, _) = await pumpConnected(tester);
    await nextStep(tester); // Source (newFolder is the default)
    await nextStep(tester); // Remote (none is the default)
    await tester.enterText(nameField(), 'team/repo');
    await tester.pumpAndSettle();
    expect(
      tester.widget<AppPushButton>(continueButton()).onPressed,
      isNull,
      reason: 'the name is also the directory name; it must stay one segment',
    );
  });

  testWidgets('a malformed namespace blocks Continue', (tester) async {
    final (_, _, _) = await pumpConnected(tester);
    await nextStep(tester);
    await tester.tap(find.widgetWithText(AppPushButton, 'GitHub'));
    await tester.pumpAndSettle();
    await nextStep(tester);
    await tester.enterText(nameField(), 'repo');
    await tester.pumpAndSettle();

    for (final bad in ['/team', 'team/', 'team//sub', 'team/../sub']) {
      await tester.enterText(_namespaceField(), bad);
      await tester.pumpAndSettle();
      expect(
        tester.widget<AppPushButton>(continueButton()).onPressed,
        isNull,
        reason: 'namespace "$bad" should be rejected',
      );
    }
    await tester.enterText(_namespaceField(), 'team/subgroup');
    await tester.pumpAndSettle();
    expect(
      tester.widget<AppPushButton>(continueButton()).onPressed,
      isNotNull,
      reason: 'a well-formed namespace must be accepted',
    );
  });

  testWidgets('the namespace field only exists in forge modes', (tester) async {
    await pumpConnected(tester);
    await nextStep(tester); // Source
    await nextStep(tester); // Remote (none) → Details
    expect(_namespaceField(), findsNothing);
  });

  // -------------------------------------------------------------------------
  // Phase 3 — suggestions beneath the field
  // -------------------------------------------------------------------------

  testWidgets('offered namespaces fill the field when tapped', (tester) async {
    final (_, _, _) = await pumpConnected(
      tester,
      extraOverrides: [
        forgeNamespacesProvider.overrideWith(
          (ref, key) async => ['me', 'team/subgroup'],
        ),
      ],
    );
    await nextStep(tester);
    await tester.tap(find.widgetWithText(AppPushButton, 'GitHub'));
    await tester.pumpAndSettle();
    await nextStep(tester);
    await tester.enterText(nameField(), 'repo');
    await tester.pumpAndSettle();

    final chip = find.widgetWithText(InlineActionButton, 'team/subgroup');
    expect(chip, findsOneWidget);
    await tester.tap(chip);
    await tester.pumpAndSettle();

    expect(
      find.text('Creates team/subgroup/repo on the forge.'),
      findsOneWidget,
    );
  });

  testWidgets(
    'a forge that never answers leaves the field usable and composing',
    (tester) async {
      // Never completes: the sheet must not wait on it, at any point.
      final exec = await _toReviewWithNamespaces(
        tester,
        (ref, key) => Completer<List<String>>().future,
      );
      final joined = exec.calls.map((c) => c.join(' ')).toList();
      expect(
        joined.any((c) => c.startsWith('gh repo create team/subgroup/repo')),
        isTrue,
        reason: 'a pending suggestion fetch must not block the create',
      );
    },
  );

  testWidgets('a throwing namespace service shows no error and no spinner', (
    tester,
  ) async {
    final exec = await _toReviewWithNamespaces(
      tester,
      (ref, key) async => throw StateError('forge unreachable'),
    );
    final joined = exec.calls.map((c) => c.join(' ')).toList();
    expect(
      joined.any((c) => c.startsWith('gh repo create team/subgroup/repo')),
      isTrue,
      reason: 'a failed suggestion fetch must not block the create',
    );
  });
}

/// Drives a GitHub create of `team/subgroup/repo` with [namespaces] overriding
/// the suggestion provider, asserting along the way that the namespace field
/// itself never disappears and no spinner replaces the form.
Future<FakeCreateExecutor> _toReviewWithNamespaces(
  WidgetTester tester,
  Future<List<String>> Function(Ref ref, (Forge, String, bool) key) namespaces,
) async {
  final (_, exec, _) = await pumpConnected(
    tester,
    extraOverrides: [forgeNamespacesProvider.overrideWith(namespaces)],
  );
  await nextStep(tester);
  await tester.tap(find.widgetWithText(AppPushButton, 'GitHub'));
  await tester.pumpAndSettle();
  await nextStep(tester);

  // The field is the contract; the list is a convenience.
  expect(_namespaceField(), findsOneWidget);
  expect(find.byType(ProgressCircle), findsNothing);

  await tester.enterText(nameField(), 'repo');
  await tester.pumpAndSettle();
  await tester.enterText(_namespaceField(), 'team/subgroup');
  await tester.pumpAndSettle();
  expect(_namespaceField(), findsOneWidget);
  expect(find.byType(ProgressCircle), findsNothing);

  await nextStep(tester);
  exec.results.add(okResult('absent'));
  exec.results.add(okResult(''));
  exec.results.add(okResult('https://github.com/team/subgroup/repo\n'));
  exec.results.add(_noOrigin);
  exec.results.add(okResult('https'));
  exec.results.add(okResult(''));
  exec.results.add(okResult('https://github.com/team/subgroup/repo.git\n'));
  await pumpCreate(tester);
  return exec;
}
