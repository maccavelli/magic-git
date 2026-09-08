// CreateRepositorySheet: submit gating, plain git init argv + registration,
// git identity (local user.name/user.email + authored initial commit),
// the GitHub forge-first mechanism (branch field disabled, gh argv), the
// GitLab init-then-create path where a forge failure still registers the
// local repo with a warning, the custom-URL mode (init + git remote add),
// and the post-create origin verification shared by all remote modes.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/forge/forge.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/output/output_log.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/settings/app_settings.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/features/common/buttons.dart';
import 'package:remote_magic_git/features/common/field_styles.dart';
import 'package:remote_magic_git/features/workspace/create_repo_sheet.dart';

import 'helpers/app_scope.dart';
import 'helpers/create_repo_harness.dart';

void main() {
  // Don't wait out the green-bar flash before the success pop.
  CreateRepositorySheet.successPopDelay = Duration.zero;

  testWidgets('the Details step gates Continue until a valid name exists', (
    tester,
  ) async {
    await pumpConnected(tester);
    await nextStep(tester); // Source → Remote (parent prefilled from session)
    await nextStep(tester); // Remote → Details (default: no remote)

    expect(tester.widget<AppPushButton>(continueButton()).onPressed, isNull);

    await tester.enterText(nameField(), 'new-proj');
    await tester.pumpAndSettle();
    expect(tester.widget<AppPushButton>(continueButton()).onPressed, isNotNull);

    await tester.enterText(nameField(), '../evil');
    await tester.pumpAndSettle();
    expect(tester.widget<AppPushButton>(continueButton()).onPressed, isNull);
  });

  testWidgets('Add a README gates Continue until a git identity is filled', (
    tester,
  ) async {
    await pumpConnected(tester);
    await nextStep(tester); // Source
    await nextStep(tester); // Remote
    await tester.enterText(nameField(), 'new-proj');
    await tester.pumpAndSettle();
    expect(
      tester.widget<AppPushButton>(continueButton()).onPressed,
      isNotNull,
      reason: 'identity is optional until an initial commit is on',
    );
    expect(
      tester.widget<MacosTextField>(authorNameField()).decoration,
      kAppTextFieldDecoration,
      reason: 'optional identity is not outlined as an error',
    );
    expect(
      tester.widget<MacosTextField>(authorEmailField()).decoration,
      kAppTextFieldDecoration,
    );

    await tapReadme(tester);
    expect(
      tester.widget<AppPushButton>(continueButton()).onPressed,
      isNull,
      reason: 'README commit requires name + email',
    );
    expect(
      tester.widget<MacosTextField>(authorNameField()).decoration,
      kAppTextFieldErrorDecoration,
      reason: 'required empty name is outlined in red',
    );
    expect(
      tester.widget<MacosTextField>(authorEmailField()).decoration,
      kAppTextFieldErrorDecoration,
      reason: 'required empty email is outlined in red',
    );

    await tester.enterText(authorNameField(), testAuthorName);
    await tester.pumpAndSettle();
    expect(
      tester.widget<AppPushButton>(continueButton()).onPressed,
      isNull,
      reason: 'email still missing',
    );
    expect(
      tester.widget<MacosTextField>(authorNameField()).decoration,
      kAppTextFieldDecoration,
      reason: 'a filled name drops the error outline',
    );
    expect(
      tester.widget<MacosTextField>(authorEmailField()).decoration,
      kAppTextFieldErrorDecoration,
    );

    await tester.enterText(authorEmailField(), 'not-an-email');
    await tester.pumpAndSettle();
    expect(
      tester.widget<AppPushButton>(continueButton()).onPressed,
      isNull,
      reason: 'email must contain an @ with both sides',
    );
    expect(
      tester.widget<MacosTextField>(authorEmailField()).decoration,
      kAppTextFieldErrorDecoration,
      reason: 'an implausible email stays outlined',
    );

    await tester.enterText(authorEmailField(), '@x');
    await tester.pumpAndSettle();
    expect(
      tester.widget<AppPushButton>(continueButton()).onPressed,
      isNull,
      reason: 'email must have a local part before @',
    );
    expect(
      tester.widget<MacosTextField>(authorEmailField()).decoration,
      kAppTextFieldErrorDecoration,
    );

    await tester.enterText(authorEmailField(), 'x@');
    await tester.pumpAndSettle();
    expect(
      tester.widget<AppPushButton>(continueButton()).onPressed,
      isNull,
      reason: 'email must have a domain after @',
    );
    expect(
      tester.widget<MacosTextField>(authorEmailField()).decoration,
      kAppTextFieldErrorDecoration,
    );

    await tester.enterText(authorEmailField(), testAuthorEmail);
    await tester.pumpAndSettle();
    expect(tester.widget<AppPushButton>(continueButton()).onPressed, isNotNull);
    expect(
      tester.widget<MacosTextField>(authorNameField()).decoration,
      kAppTextFieldDecoration,
    );
    expect(
      tester.widget<MacosTextField>(authorEmailField()).decoration,
      kAppTextFieldDecoration,
    );
  });

  testWidgets('git identity prefills from Settings', (tester) async {
    final stub = StubConnection(
      const ConnectionState(
        phase: ConnectionPhase.connected,
        repoPath: '/srv/repo',
        repoPaths: ['/srv/repo'],
        connectionId: 'c1',
        connectionLabel: 'Prod',
        host: 'h',
      ),
    );
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    await tester.pumpWidget(
      appProviderScope(
        overrides: [
          connectionProvider.overrideWith(() => stub),
          activeExecutorProvider.overrideWithValue(FakeCreateExecutor()),
          connectionStoreProvider.overrideWithValue(FakeConnectionStore()),
          savedConnectionsProvider.overrideWith((ref) async => [testConn]),
          gitServiceProvider.overrideWithValue(
            GitService(FakeCreateExecutor()),
          ),
          appSettingsProvider.overrideWith(PrefillSettings.new),
        ],
        child: const MacosApp(
          debugShowCheckedModeBanner: false,
          home: CreateRepositorySheet.connected(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await nextStep(tester); // Destination (MADR 0036, 2A) → Source
    await nextStep(tester); // Source
    await nextStep(tester); // Remote
    expect(
      tester.widget<MacosTextField>(authorNameField()).controller?.text,
      'Jane Developer',
    );
    expect(
      tester.widget<MacosTextField>(authorEmailField()).controller?.text,
      'jane@example.com',
    );
  });

  testWidgets(
    'Settings-prefilled identity is not marked required when README is on',
    (tester) async {
      await pumpConnected(
        tester,
        extraOverrides: [appSettingsProvider.overrideWith(PrefillSettings.new)],
      );
      await nextStep(tester); // Source
      await nextStep(tester); // Remote
      await tester.enterText(nameField(), 'new-proj');
      await tester.pumpAndSettle();
      await tapReadme(tester);

      expect(
        tester.widget<AppPushButton>(continueButton()).onPressed,
        isNotNull,
        reason: 'prefilled name+email already satisfy the commit identity',
      );
      expect(
        tester.widget<MacosTextField>(authorNameField()).decoration,
        kAppTextFieldDecoration,
        reason: 'a Settings-populated name must not outline as required',
      );
      expect(
        tester.widget<MacosTextField>(authorEmailField()).decoration,
        kAppTextFieldDecoration,
        reason: 'a Settings-populated email must not outline as required',
      );
    },
  );

  testWidgets(
    'identity required outline clears when Settings loads after open',
    (tester) async {
      final settings = LateSettings();
      await pumpConnected(
        tester,
        extraOverrides: [appSettingsProvider.overrideWith(() => settings)],
      );
      await nextStep(tester); // Source
      await nextStep(tester); // Remote
      await tester.enterText(nameField(), 'new-proj');
      await tester.pumpAndSettle();
      await tapReadme(tester);

      expect(
        tester.widget<MacosTextField>(authorNameField()).decoration,
        kAppTextFieldErrorDecoration,
        reason: 'empty identity is required while Settings is still default',
      );
      expect(tester.widget<AppPushButton>(continueButton()).onPressed, isNull);

      settings.arrive();
      await tester.pumpAndSettle();

      expect(
        tester.widget<MacosTextField>(authorNameField()).controller?.text,
        'Jane Developer',
      );
      expect(
        tester.widget<MacosTextField>(authorEmailField()).controller?.text,
        'jane@example.com',
      );
      expect(
        tester.widget<MacosTextField>(authorNameField()).decoration,
        kAppTextFieldDecoration,
      );
      expect(
        tester.widget<MacosTextField>(authorEmailField()).decoration,
        kAppTextFieldDecoration,
      );
      expect(
        tester.widget<AppPushButton>(continueButton()).onPressed,
        isNotNull,
        reason: 'arriving Settings identity satisfies the required gate',
      );
    },
  );

  testWidgets('Review lists the git identity', (tester) async {
    await pumpConnected(tester);
    await nextStep(tester); // Source
    await nextStep(tester); // Remote
    await tester.enterText(nameField(), 'new-proj');
    await tester.pumpAndSettle();
    await fillIdentity(tester);
    await nextStep(tester); // Details → Review
    expect(find.text('Git identity'), findsOneWidget);
    expect(find.text('Ada Lovelace · ada@example.com'), findsOneWidget);
  });

  testWidgets('typed identity is not overwritten when Settings loads', (
    tester,
  ) async {
    final settings = LateSettings();
    await pumpConnected(
      tester,
      extraOverrides: [appSettingsProvider.overrideWith(() => settings)],
    );
    await nextStep(tester); // Source
    await nextStep(tester); // Remote
    await tester.enterText(nameField(), 'new-proj');
    await tester.pumpAndSettle();
    await fillIdentity(tester);

    settings.arrive();
    await tester.pumpAndSettle();

    expect(
      tester.widget<MacosTextField>(authorNameField()).controller?.text,
      testAuthorName,
      reason: 'a typed name must not snap back to Settings',
    );
    expect(
      tester.widget<MacosTextField>(authorEmailField()).controller?.text,
      testAuthorEmail,
      reason: 'a typed email must not snap back to Settings',
    );
  });

  testWidgets(
    'the forge host prefills from the CLI sign-in, but never overwrites a '
    'typed host',
    (tester) async {
      final stub = StubConnection(
        const ConnectionState(
          phase: ConnectionPhase.connected,
          repoPath: '/srv/repo',
          repoPaths: ['/srv/repo'],
          connectionId: 'c1',
          connectionLabel: 'Prod',
          host: 'h',
        ),
      );
      await tester.pumpWidget(
        appProviderScope(
          overrides: [
            connectionProvider.overrideWith(() => stub),
            activeExecutorProvider.overrideWithValue(FakeCreateExecutor()),
            connectionStoreProvider.overrideWithValue(FakeConnectionStore()),
            savedConnectionsProvider.overrideWith((ref) async => [testConn]),
            gitServiceProvider.overrideWithValue(
              GitService(FakeCreateExecutor()),
            ),
            forgeAuthHostProvider.overrideWith(
              (ref, key) async =>
                  key.$1 == Forge.gitlab ? 'gitlab.example.com' : null,
            ),
          ],
          child: const MacosApp(
            debugShowCheckedModeBanner: false,
            home: CreateRepositorySheet.connected(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await nextStep(tester); // Destination (MADR 0036, 2A) → Source
      await nextStep(tester); // Source → Remote

      await tester.tap(find.widgetWithText(AppPushButton, 'GitLab'));
      await tester.pumpAndSettle();

      Finder hostField() => find.byWidgetPredicate(
        (w) => w is MacosTextField && w.controller?.text != '',
      );
      expect(
        find.text('gitlab.example.com'),
        findsOneWidget,
        reason: 'stock default replaced by the CLI sign-in host',
      );
      expect(hostField(), findsWidgets);

      // A user-typed host survives switching forges and re-resolution.
      await tester.enterText(
        find.byWidgetPredicate(
          (w) =>
              w is MacosTextField && w.controller?.text == 'gitlab.example.com',
        ),
        'gitlab.other.example',
      );
      await tester.pumpAndSettle();
      expect(find.text('gitlab.other.example'), findsOneWidget);
      expect(
        find.text('gitlab.example.com'),
        findsNothing,
        reason: 'typed host was not overwritten by the prefill',
      );
    },
  );

  testWidgets('the progress bar tracks the current step left to right', (
    tester,
  ) async {
    // Deliberately renumbered: the connected wizard gained a Destination step
    // in front of Source (MADR 0036, 2A), so it is five steps, not four.
    await pumpConnected(tester, pastDestination: false);
    expect(find.text('Step 1 of 5 — Destination'), findsOneWidget);
    await nextStep(tester);
    expect(find.text('Step 2 of 5 — Source'), findsOneWidget);
    await nextStep(tester);
    expect(find.text('Step 3 of 5 — Remote'), findsOneWidget);
    await nextStep(tester);
    expect(find.text('Step 4 of 5 — Details'), findsOneWidget);
  });

  testWidgets('plain create: git init -b main in the parent, then activates', (
    tester,
  ) async {
    final (stub, exec, store) = await pumpConnected(tester);
    await nextStep(tester); // Source
    await nextStep(tester); // Remote (None)
    await tester.enterText(nameField(), 'new-proj');
    await tester.pumpAndSettle();
    await nextStep(tester); // Details → Review

    exec.results.add(okResult('absent')); // probe
    await tester.tap(createButton());
    await tester.pumpAndSettle();

    expect(exec.calls.last, ['git', 'init', '-b', 'main', '--', 'new-proj']);
    expect(stub.repoPathsSet, ['/srv/new-proj']);
    // Deliberately dropped: `store.updated…allRepoPaths`. The sheet no longer
    // persists the path itself; the real `finalizeProvisioned` does, in the
    // tab that dialled (MADR 0036, 3B). Without a tab host this stub IS that
    // tab, and `repoPathsSet` above is its finalize.
    expect(store.updated, isEmpty);
    expect(find.byType(CreateRepositorySheet), findsNothing, reason: 'popped');
  });

  testWidgets(
    'a filled git identity is written into the new repo even without a README',
    (tester) async {
      final settings = GuardSettings();
      // The spy itself must be seen to fire, or a 0-write assert is noise.
      await settings.setPreferences(
        committerName: 'should-count',
        committerEmail: 'x@y',
      );
      expect(settings.preferenceWrites, 1);
      settings.preferenceWrites = 0;

      final (stub, exec, _) = await pumpConnected(
        tester,
        extraOverrides: [appSettingsProvider.overrideWith(() => settings)],
      );
      await nextStep(tester); // Source
      await nextStep(tester); // Remote (None)
      await tester.enterText(nameField(), 'new-proj');
      await tester.pumpAndSettle();
      await fillIdentity(tester);
      await nextStep(tester); // Details → Review

      exec.results.add(okResult('absent')); // probe
      exec.results.add(okResult('')); // git init
      queueIdentityConfig(exec);
      await tester.tap(createButton());
      await tester.pumpAndSettle();

      expect(
        exec.calls.map((c) => c.join(' ')),
        containsAllInOrder([
          'git init -b main -- new-proj',
          'git config --local user.name $testAuthorName',
          'git config --local user.email $testAuthorEmail',
        ]),
      );
      expect(stub.repoPathsSet, ['/srv/new-proj']);
      expect(find.byType(CreateRepositorySheet), findsNothing);
      expect(
        exec.calls.map((c) => c.join(' ')),
        isNot(contains(identityCommit)),
        reason: 'README off — no initial commit',
      );
      expect(
        exec.calls.any((c) => c.take(3).join(' ') == 'git remote add'),
        isFalse,
        reason: 'Remote None — no origin',
      );
      expect(
        settings.preferenceWrites,
        0,
        reason: 'create must not write identity into Settings',
      );
    },
  );

  testWidgets('an existing destination fails with a clear error', (
    tester,
  ) async {
    final (stub, exec, _) = await pumpConnected(tester);
    await nextStep(tester); // Source
    await nextStep(tester); // Remote (None)
    await tester.enterText(nameField(), 'new-proj');
    await tester.pumpAndSettle();
    await nextStep(tester); // Details → Review

    exec.results.add(okResult('exists')); // probe
    await tester.tap(createButton());
    await tester.pumpAndSettle();

    expect(find.textContaining('already exists'), findsOneWidget);
    expect(stub.repoPathsSet, isEmpty);
    expect(
      exec.calls.every((c) => c.first != 'git'),
      isTrue,
      reason: 'no init issued',
    );
  });

  const noOrigin = SSHCommandResult(
    exitCode: 2,
    stdout: '',
    stderr: "error: No such remote 'origin'",
  );

  /// API-only create (empty stdout → no create-output URL, exercising the
  /// lookup fallback) → missing origin → protocol probe → view lookup →
  /// remote add → verify.
  void queueGithubOriginWire(
    FakeCreateExecutor exec, {
    required String name,
    bool push = false,
  }) {
    exec.results.add(okResult('')); // gh repo create (API only)
    exec.results.add(noOrigin); // get-url: missing
    exec.results.add(okResult('https')); // git_protocol (probed first)
    exec.results.add(
      okResult(
        '{"url":"https://github.com/me/$name","sshUrl":'
        '"git@github.com:me/$name.git"}',
      ),
    ); // gh repo view
    exec.results.add(okResult('')); // git remote add
    if (push) exec.results.add(okResult('')); // git push -u
    exec.results.add(okResult('https://github.com/me/$name.git\n')); // verify
  }

  void queueGitlabOriginWire(
    FakeCreateExecutor exec, {
    required String name,
    bool push = false,
  }) {
    exec.results.add(okResult('')); // glab repo create --skipGitInit
    exec.results.add(noOrigin); // get-url: missing
    exec.results.add(
      okResult(''),
    ); // glab config get git_protocol (unset → https)
    exec.results.add(
      okResult('HTTP/2.0 200 OK\n\n{"username":"me"}'),
    ); // glab api user
    exec.results.add(
      okResult(
        'HTTP/2.0 200 OK\n\n'
        '{"http_url_to_repo":"https://gitlab.com/me/$name.git",'
        '"ssh_url_to_repo":"git@gitlab.com:me/$name.git"}',
      ),
    ); // glab api projects
    exec.results.add(okResult('')); // git remote add
    if (push) exec.results.add(okResult('')); // git push -u
    exec.results.add(okResult('https://gitlab.com/me/$name.git\n')); // verify
  }

  testWidgets(
    'GitHub mode inits on the chosen branch, API-creates, wires origin, '
    'and verifies',
    (tester) async {
      final (stub, exec, _) = await pumpConnected(tester);
      await nextStep(tester); // Source
      await tester.tap(find.widgetWithText(AppPushButton, 'GitHub'));
      await tester.pumpAndSettle();
      await nextStep(tester); // Remote → Details
      await tester.enterText(nameField(), 'new-proj');
      await tester.pumpAndSettle();

      final branchField = tester.widget<MacosTextField>(
        find.byWidgetPredicate(
          (w) => w is MacosTextField && w.placeholder == 'main',
        ),
      );
      expect(
        branchField.enabled,
        isNot(isFalse),
        reason: 'init-first: the user branch is authoritative',
      );
      await nextStep(tester); // Details → Review

      exec.results.add(okResult('absent')); // probe
      exec.results.add(okResult('')); // git init
      queueGithubOriginWire(exec, name: 'new-proj');
      await tester.tap(createButton());
      await tester.pumpAndSettle();

      final joined = exec.calls.map((c) => c.join(' ')).toList();
      expect(
        joined,
        containsAllInOrder([
          'git init -b main -- new-proj',
          'gh repo create new-proj --private',
          'git remote get-url origin',
          'gh repo view new-proj --json url,sshUrl',
          'git remote add origin https://github.com/me/new-proj.git',
          'git remote get-url origin',
        ]),
        reason: 'API-only create; Magic Git owns origin wiring',
      );
      expect(
        joined.any((c) => c.contains('--source') || c.contains('--remote')),
        isFalse,
        reason: 'never ask gh to nest local git ops',
      );
      expect(stub.repoPathsSet, ['/srv/new-proj']);
      expect(find.byType(CreateRepositorySheet), findsNothing);
    },
  );

  testWidgets(
    "the URL printed by gh repo create is the primary origin source — no "
    "view lookup round trip at all",
    (tester) async {
      final (stub, exec, _) = await pumpConnected(tester);
      await nextStep(tester); // Source
      await tester.tap(find.widgetWithText(AppPushButton, 'GitHub'));
      await tester.pumpAndSettle();
      await nextStep(tester); // Remote → Details
      await tester.enterText(nameField(), 'new-proj');
      await tester.pumpAndSettle();
      await nextStep(tester); // Details → Review

      exec.results.add(okResult('absent')); // probe
      exec.results.add(okResult('')); // git init
      exec.results.add(
        okResult('https://github.com/me/new-proj\n'),
      ); // gh repo create prints the new repo URL
      exec.results.add(noOrigin); // get-url: missing
      exec.results.add(okResult('https')); // git_protocol
      exec.results.add(okResult('')); // git remote add
      exec.results.add(
        okResult('https://github.com/me/new-proj.git\n'),
      ); // verify
      await tester.tap(createButton());
      await tester.pumpAndSettle();

      final joined = exec.calls.map((c) => c.join(' ')).toList();
      expect(
        joined,
        contains('git remote add origin https://github.com/me/new-proj.git'),
        reason: 'origin wired from the create output alone',
      );
      expect(
        joined.any((c) => c.startsWith('gh repo view')),
        isFalse,
        reason: 'no lookup round trip when create already printed the URL',
      );
      expect(stub.repoPathsSet, ['/srv/new-proj']);
      expect(find.byType(CreateRepositorySheet), findsNothing);
    },
  );

  testWidgets(
    'the README option commits before the GitHub publish; we push with -u',
    (tester) async {
      final (stub, exec, _) = await pumpConnected(tester);
      await nextStep(tester); // Source
      await tester.tap(find.widgetWithText(AppPushButton, 'GitHub'));
      await tester.pumpAndSettle();
      await nextStep(tester); // Remote → Details
      await tester.enterText(nameField(), 'new-proj');
      await tester.pumpAndSettle();
      await tapReadme(tester);
      await fillIdentity(tester);
      await nextStep(tester); // Details → Review

      exec.results.add(okResult('absent')); // probe
      exec.results.add(okResult('')); // git init
      queueIdentityConfig(exec);
      exec.results.add(okResult('')); // git add
      exec.results.add(okResult('')); // git commit
      queueGithubOriginWire(exec, name: 'new-proj', push: true);
      await tester.tap(createButton());
      await tester.pumpAndSettle();

      expect(exec.uploads['/srv/new-proj/README.md'], '# new-proj\n');
      expect(
        exec.calls.map((c) => c.join(' ')),
        containsAllInOrder([
          'git init -b main -- new-proj',
          'git config --local user.name $testAuthorName',
          'git config --local user.email $testAuthorEmail',
          'git add -- README.md',
          identityCommit,
          'gh repo create new-proj --private',
          'git remote add origin https://github.com/me/new-proj.git',
          'git -c credential.helper= -c credential.helper=!gh auth git-credential '
              'push -u origin main',
        ]),
      );
      expect(stub.repoPathsSet, ['/srv/new-proj']);
      expect(find.byType(CreateRepositorySheet), findsNothing);
    },
  );

  testWidgets(
    'GitLab mode inits first; a failed forge publish still registers the '
    'repo and shows a warning',
    (tester) async {
      final (stub, exec, _) = await pumpConnected(tester);
      await nextStep(tester); // Source
      await tester.tap(find.widgetWithText(AppPushButton, 'GitLab'));
      await tester.pumpAndSettle();
      await nextStep(tester); // Remote → Details
      await tester.enterText(nameField(), 'new-proj');
      await tester.pumpAndSettle();
      await nextStep(tester); // Details → Review

      exec.results.add(okResult('absent')); // probe
      exec.results.add(okResult('')); // git init succeeds
      exec.results.add(
        const SSHCommandResult(
          exitCode: 1,
          stdout: '',
          stderr: '401 unauthorized',
        ),
      ); // glab repo create fails
      exec.results.add(noOrigin); // ensure: origin missing
      // cloneUrl retries fail (empty results → empty success → null)
      await pumpCreate(tester);

      expect(
        exec.calls.map((c) => c.take(2).join(' ')),
        containsAllInOrder(['git init', 'glab repo']),
      );
      expect(
        exec.calls.map((c) => c.join(' ')),
        contains('git remote get-url origin'),
        reason: 'ensure always runs even after create failure',
      );
      expect(stub.repoPathsSet, [
        '/srv/new-proj',
      ], reason: 'local repo registered despite forge failure');
      expect(
        find.byType(CreateRepositorySheet),
        findsOneWidget,
        reason: 'stays open to show the warning',
      );
      expect(find.textContaining('publishing to GitLab failed'), findsWidgets);

      await tester.tap(find.widgetWithText(AppPushButton, 'Close'));
      await tester.pumpAndSettle();
      expect(find.byType(CreateRepositorySheet), findsNothing);
    },
  );

  testWidgets(
    'GitLab mode with a README wires origin and pushes the initial commit',
    (tester) async {
      final (stub, exec, _) = await pumpConnected(tester);
      await nextStep(tester); // Source
      await tester.tap(find.widgetWithText(AppPushButton, 'GitLab'));
      await tester.pumpAndSettle();
      await nextStep(tester); // Remote → Details
      await tester.enterText(nameField(), 'new-proj');
      await tester.pumpAndSettle();
      await tapReadme(tester);
      await fillIdentity(tester);
      await nextStep(tester); // Details → Review

      exec.results.add(okResult('absent')); // probe
      exec.results.add(okResult('')); // git init
      queueIdentityConfig(exec);
      exec.results.add(okResult('')); // git add
      exec.results.add(okResult('')); // git commit
      queueGitlabOriginWire(exec, name: 'new-proj', push: true);
      await tester.tap(createButton());
      await tester.pumpAndSettle();

      expect(
        exec.calls.map((c) => c.join(' ')),
        containsAllInOrder([
          'git init -b main -- new-proj',
          'git config --local user.name $testAuthorName',
          'git config --local user.email $testAuthorEmail',
          identityCommit,
          'glab repo create new-proj --private --skipGitInit',
          'git remote get-url origin',
          'git remote add origin https://gitlab.com/me/new-proj.git',
          'git -c credential.helper= -c credential.helper=!glab auth git-credential '
              'push -u origin main',
        ]),
      );
      expect(stub.repoPathsSet, ['/srv/new-proj']);
      expect(find.byType(CreateRepositorySheet), findsNothing);
    },
  );

  testWidgets(
    'Custom URL mode gates on a URL, then inits, wires origin, and verifies',
    (tester) async {
      final (stub, exec, _) = await pumpConnected(tester);
      await nextStep(tester); // Source
      await tester.tap(find.widgetWithText(AppPushButton, 'Custom URL'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<AppPushButton>(continueButton()).onPressed,
        isNull,
        reason: 'no URL entered yet',
      );

      const url = 'https://gitlab.example.com/me/new-proj.git';
      await tester.enterText(
        find.byWidgetPredicate(
          (w) =>
              w is MacosTextField &&
              (w.placeholder?.startsWith('git@host:') ?? false),
        ),
        url,
      );
      await tester.pumpAndSettle();
      await nextStep(tester); // Remote → Details
      await tester.enterText(nameField(), 'new-proj');
      await tester.pumpAndSettle();
      await nextStep(tester); // Details → Review

      exec.results.add(okResult('absent')); // probe
      exec.results.add(okResult('')); // git init
      exec.results.add(okResult('')); // git remote add
      exec.results.add(okResult('$url\n')); // verify
      await tester.tap(createButton());
      await tester.pumpAndSettle();

      expect(
        exec.calls,
        containsAllInOrder([
          ['git', 'init', '-b', 'main', '--', 'new-proj'],
          ['git', 'remote', 'add', 'origin', url],
          ['git', 'remote', 'get-url', 'origin'],
        ]),
      );
      expect(stub.repoPathsSet, ['/srv/new-proj']);
      expect(find.byType(CreateRepositorySheet), findsNothing);
    },
  );

  testWidgets('partial forge create (non-zero exit) still wires origin when the '
      'project exists and is discoverable', (tester) async {
    final (stub, exec, _) = await pumpConnected(tester);
    await nextStep(tester); // Source
    await tester.tap(find.widgetWithText(AppPushButton, 'GitHub'));
    await tester.pumpAndSettle();
    await nextStep(tester); // Remote → Details
    await tester.enterText(nameField(), 'new-proj');
    await tester.pumpAndSettle();
    await tapReadme(tester);
    await fillIdentity(tester);
    await nextStep(tester); // Details → Review

    exec.results.add(okResult('absent')); // probe
    exec.results.add(okResult('')); // git init
    queueIdentityConfig(exec);
    exec.results.add(okResult('')); // git add
    exec.results.add(okResult('')); // git commit
    // Create exits non-zero after the API project already exists (classic
    // nested-git failure under --source path — or any post-create error).
    exec.results.add(
      const SSHCommandResult(
        exitCode: 1,
        stdout: '',
        stderr: 'failed to add remote: git not found',
      ),
    );
    exec.results.add(noOrigin); // ensure: missing
    exec.results.add(okResult('https')); // git_protocol (probed first)
    exec.results.add(
      okResult(
        '{"url":"https://github.com/me/new-proj","sshUrl":'
        '"git@github.com:me/new-proj.git"}',
      ),
    ); // view still finds the project
    exec.results.add(okResult('')); // remote add
    exec.results.add(okResult('')); // push
    // verify after ensure (downgrade create failure) + step-4 verify
    exec.results.add(okResult('https://github.com/me/new-proj.git\n'));
    exec.results.add(okResult('https://github.com/me/new-proj.git\n'));
    await tester.tap(createButton());
    await tester.pumpAndSettle();

    expect(
      exec.calls.map((c) => c.join(' ')),
      containsAllInOrder([
        'gh repo create new-proj --private',
        'git remote get-url origin',
        'gh repo view new-proj --json url,sshUrl',
        'git remote add origin https://github.com/me/new-proj.git',
        'git -c credential.helper= -c credential.helper=!gh auth git-credential '
            'push -u origin main',
      ]),
      reason: 'ensure runs after failed create; origin still wired',
    );
    expect(stub.repoPathsSet, ['/srv/new-proj']);
    expect(
      find.byType(CreateRepositorySheet),
      findsNothing,
      reason: 'origin ok → create failure downgraded, sheet pops',
    );
  });

  testWidgets(
    'gh create succeeds but clone URL is unresolvable: the repo is kept '
    'and the sheet warns',
    (tester) async {
      final (stub, exec, _) = await pumpConnected(tester);
      await nextStep(tester); // Source
      await tester.tap(find.widgetWithText(AppPushButton, 'GitHub'));
      await tester.pumpAndSettle();
      await nextStep(tester); // Remote → Details
      await tester.enterText(nameField(), 'new-proj');
      await tester.pumpAndSettle();
      await nextStep(tester); // Details → Review

      exec.results.add(okResult('absent')); // probe
      exec.results.add(okResult('')); // git init
      exec.results.add(okResult('')); // gh repo create
      exec.results.add(noOrigin); // ensure: missing
      // All cloneUrl attempts fail (retries included — empty queue → empty ok).
      exec.results.add(
        const SSHCommandResult(exitCode: 1, stdout: '', stderr: 'not found'),
      );
      await pumpCreate(tester);

      expect(stub.repoPathsSet, [
        '/srv/new-proj',
      ], reason: 'repo is kept and registered');
      expect(
        find.byType(CreateRepositorySheet),
        findsOneWidget,
        reason: 'stays open to show the warning',
      );
      expect(find.textContaining('clone URL could not be'), findsWidgets);
    },
  );

  // --- Existing-folder source -----------------------------------------

  Future<void> toExistingFolder(WidgetTester tester, String path) async {
    await tester.tap(find.widgetWithText(AppPushButton, 'Existing folder'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byWidgetPredicate(
        (w) => w is MacosTextField && w.placeholder == '/srv/app',
      ),
      path,
    );
    await tester.pumpAndSettle();
  }

  const notARepo = SSHCommandResult(
    exitCode: 128,
    stdout: '',
    stderr:
        'fatal: not a git repository (or any of the parent '
        'directories): .git',
  );
  const unbornHead = SSHCommandResult(exitCode: 1, stdout: '', stderr: '');

  testWidgets('Commit all gates Continue until a git identity is filled', (
    tester,
  ) async {
    await pumpConnected(tester);
    await toExistingFolder(tester, '/srv/app');
    await nextStep(tester); // Source
    await nextStep(tester); // Remote (None)
    expect(
      tester.widget<AppPushButton>(continueButton()).onPressed,
      isNotNull,
      reason: 'identity is optional until commit-all is on',
    );
    expect(
      tester.widget<MacosTextField>(authorNameField()).decoration,
      kAppTextFieldDecoration,
    );

    final commitAll = find.byWidgetPredicate(
      (w) =>
          w is MacosTooltip &&
          w.message.startsWith('Commit all existing contents'),
    );
    await tester.ensureVisible(commitAll);
    await tester.pumpAndSettle();
    await tester.tap(commitAll);
    await tester.pumpAndSettle();

    expect(
      tester.widget<AppPushButton>(continueButton()).onPressed,
      isNull,
      reason: 'commit-all requires name + email',
    );
    expect(
      tester.widget<MacosTextField>(authorNameField()).decoration,
      kAppTextFieldErrorDecoration,
    );
    expect(
      tester.widget<MacosTextField>(authorEmailField()).decoration,
      kAppTextFieldErrorDecoration,
    );

    await fillIdentity(tester);
    expect(tester.widget<AppPushButton>(continueButton()).onPressed, isNotNull);
    expect(
      tester.widget<MacosTextField>(authorNameField()).decoration,
      kAppTextFieldDecoration,
    );
    expect(
      tester.widget<MacosTextField>(authorEmailField()).decoration,
      kAppTextFieldDecoration,
    );
  });

  testWidgets(
    'existing folder that is not a repo yet: init in place, publish to '
    'GitHub without push',
    (tester) async {
      final (stub, exec, _) = await pumpConnected(tester);
      await toExistingFolder(tester, '/srv/app');
      await nextStep(tester); // Source
      await tester.tap(find.widgetWithText(AppPushButton, 'GitHub'));
      await tester.pumpAndSettle();
      await nextStep(tester); // Remote → Details
      await tester.enterText(nameField(), 'app-repo');
      await tester.pumpAndSettle();
      await nextStep(tester); // Details → Review

      exec.results.add(notARepo); // classify: not a repo
      exec.results.add(okResult('')); // git init (in place)
      exec.results.add(unbornHead); // HEAD doesn't resolve — nothing to push
      queueGithubOriginWire(exec, name: 'app-repo');
      await tester.tap(createButton());
      await tester.pumpAndSettle();

      expect(
        exec.calls.map((c) => c.join(' ')),
        containsAllInOrder([
          'git rev-parse --show-toplevel',
          'git init -b main',
          'git rev-parse --verify --quiet HEAD',
          'gh repo create app-repo --private',
          'git remote add origin https://github.com/me/app-repo.git',
        ]),
      );
      expect(stub.repoPathsSet, [
        '/srv/app',
      ], reason: 'the folder itself becomes the workspace');
      expect(find.byType(CreateRepositorySheet), findsNothing);
    },
  );

  testWidgets('existing repo with history: init skipped, origin wired, commits '
      'pushed with git push -u', (tester) async {
    final (stub, exec, _) = await pumpConnected(tester);
    await toExistingFolder(tester, '/srv/app');
    await nextStep(tester); // Source
    await tester.tap(find.widgetWithText(AppPushButton, 'GitHub'));
    await tester.pumpAndSettle();
    await nextStep(tester); // Remote → Details
    await tester.enterText(nameField(), 'app-repo');
    await tester.pumpAndSettle();
    await nextStep(tester); // Details → Review

    exec.results.add(okResult('/srv/app\n')); // classify: repo root
    exec.results.add(noOrigin); // origin guard: nothing wired yet
    exec.results.add(okResult('abc123\n')); // HEAD resolves — history exists
    queueGithubOriginWire(exec, name: 'app-repo', push: true);
    await tester.tap(createButton());
    await tester.pumpAndSettle();

    expect(
      exec.calls.map((c) => c.join(' ')),
      containsAllInOrder([
        'gh repo create app-repo --private',
        'git remote add origin https://github.com/me/app-repo.git',
        'git -c credential.helper= -c credential.helper=!gh auth git-credential '
            'push -u origin HEAD',
      ]),
    );
    expect(
      exec.calls.map((c) => c.take(2).join(' ')),
      isNot(contains('git init')),
      reason: 'already a repository — never re-inited',
    );
    expect(stub.repoPathsSet, ['/srv/app']);
    expect(find.byType(CreateRepositorySheet), findsNothing);
  });

  testWidgets(
    'existing repo with history does not rewrite identity unless commit-all is on',
    (tester) async {
      final (stub, exec, _) = await pumpConnected(tester);
      await toExistingFolder(tester, '/srv/app');
      await nextStep(tester); // Source
      await nextStep(tester); // Remote (None)
      await fillIdentity(tester);
      await nextStep(tester); // Details → Review

      exec.results.add(okResult('/srv/app\n')); // classify: repo root
      exec.results.add(okResult('abc123\n')); // HEAD resolves
      await tester.tap(createButton());
      await tester.pumpAndSettle();

      final joined = exec.calls.map((c) => c.join(' ')).toList();
      expect(
        joined,
        isNot(contains('git config --local user.name $testAuthorName')),
        reason: 'alreadyRepo without commit-all must not write user.name',
      );
      expect(
        joined,
        isNot(contains('git config --local user.email $testAuthorEmail')),
        reason: 'alreadyRepo without commit-all must not write user.email',
      );
      expect(
        exec.calls.map((c) => c.take(2).join(' ')),
        isNot(contains('git init')),
        reason: 'already a repository — never re-inited',
      );
      expect(stub.repoPathsSet, ['/srv/app']);
      expect(find.byType(CreateRepositorySheet), findsNothing);
    },
  );

  testWidgets(
    'an existing origin blocks the publish until "Replace existing origin" '
    'is enabled, then gets removed and rewired',
    (tester) async {
      final (stub, exec, _) = await pumpConnected(tester);
      await toExistingFolder(tester, '/srv/app');
      await nextStep(tester); // Source
      await tester.tap(find.widgetWithText(AppPushButton, 'GitHub'));
      await tester.pumpAndSettle();
      await nextStep(tester); // Remote → Details
      await tester.enterText(nameField(), 'app-repo');
      await tester.pumpAndSettle();
      await nextStep(tester); // Details → Review

      exec.results.add(okResult('/srv/app\n')); // classify: repo root
      exec.results.add(okResult('git@old-host:me/app.git\n')); // origin exists
      await tester.tap(createButton());
      await tester.pumpAndSettle();

      expect(
        find.textContaining('already has an origin remote'),
        findsOneWidget,
      );
      expect(stub.repoPathsSet, isEmpty, reason: 'nothing was touched');
      expect(find.byType(CreateRepositorySheet), findsOneWidget);

      // Go back to the Remote step, opt in, and retry.
      await tester.tap(find.widgetWithText(AppPushButton, 'Back'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(AppPushButton, 'Back'));
      await tester.pumpAndSettle();
      final replaceToggle = find.byWidgetPredicate(
        (w) =>
            w is MacosTooltip &&
            w.message.startsWith('Replace existing origin'),
      );
      await tester.ensureVisible(replaceToggle);
      await tester.pumpAndSettle();
      await tester.tap(replaceToggle);
      await tester.pumpAndSettle();
      await nextStep(tester); // Remote → Details
      await nextStep(tester); // Details → Review

      exec.results.add(okResult('/srv/app\n')); // classify: repo root
      exec.results.add(okResult('git@old-host:me/app.git\n')); // origin exists
      exec.results.add(okResult('')); // git remote remove origin
      exec.results.add(okResult('abc123\n')); // HEAD resolves
      queueGithubOriginWire(exec, name: 'app-repo', push: true);
      await tester.tap(createButton());
      await tester.pumpAndSettle();

      expect(
        exec.calls.map((c) => c.join(' ')),
        contains('git remote remove origin'),
      );
      expect(
        exec.calls.map((c) => c.join(' ')),
        contains('git remote add origin https://github.com/me/app-repo.git'),
      );
      expect(stub.repoPathsSet, ['/srv/app']);
      expect(find.byType(CreateRepositorySheet), findsNothing);
    },
  );

  testWidgets('a folder nested inside another repo is refused', (tester) async {
    final (stub, exec, _) = await pumpConnected(tester);
    await toExistingFolder(tester, '/srv/app');
    await nextStep(tester); // Source
    await tester.tap(find.widgetWithText(AppPushButton, 'GitHub'));
    await tester.pumpAndSettle();
    await nextStep(tester); // Remote → Details
    await tester.enterText(nameField(), 'app-repo');
    await tester.pumpAndSettle();
    await nextStep(tester); // Details → Review

    exec.results.add(okResult('/srv\n')); // classify: toplevel is a parent
    await tester.tap(createButton());
    await tester.pumpAndSettle();

    expect(
      find.textContaining('inside another Git repository'),
      findsOneWidget,
    );
    expect(stub.repoPathsSet, isEmpty);
    expect(find.byType(CreateRepositorySheet), findsOneWidget);
  });

  testWidgets(
    'existing folder + commit-all + custom URL: contents committed, origin '
    'wired, and HEAD pushed with -u',
    (tester) async {
      final (stub, exec, _) = await pumpConnected(tester);
      await toExistingFolder(tester, '/srv/app');
      await nextStep(tester); // Source
      await tester.tap(find.widgetWithText(AppPushButton, 'Custom URL'));
      await tester.pumpAndSettle();
      const url = 'git@gitea.example.com:me/app.git';
      await tester.enterText(
        find.byWidgetPredicate(
          (w) =>
              w is MacosTextField &&
              (w.placeholder?.startsWith('git@host:') ?? false),
        ),
        url,
      );
      await tester.pumpAndSettle();
      await nextStep(tester); // Remote → Details
      final commitAll = find.byWidgetPredicate(
        (w) =>
            w is MacosTooltip &&
            w.message.startsWith('Commit all existing contents'),
      );
      await tester.ensureVisible(commitAll);
      await tester.pumpAndSettle();
      await tester.tap(commitAll);
      await tester.pumpAndSettle();
      await fillIdentity(tester);
      await nextStep(tester); // Details → Review

      exec.results.add(notARepo); // classify: not a repo
      exec.results.add(okResult('')); // git init (in place)
      queueIdentityConfig(exec);
      exec.results.add(okResult('')); // git add --all
      exec.results.add(okResult('')); // git commit
      exec.results.add(okResult('')); // git remote add
      exec.results.add(okResult('')); // git push -u origin HEAD
      exec.results.add(okResult('$url\n')); // verify
      await tester.tap(createButton());
      await tester.pumpAndSettle();

      expect(
        exec.calls.map((c) => c.join(' ')),
        containsAllInOrder([
          'git init -b main',
          'git config --local user.name $testAuthorName',
          'git config --local user.email $testAuthorEmail',
          'git add --all',
          identityCommit,
          'git remote add origin $url',
          'git push -u origin HEAD',
          'git remote get-url origin',
        ]),
      );
      expect(stub.repoPathsSet, ['/srv/app']);
      expect(find.byType(CreateRepositorySheet), findsNothing);
    },
  );

  // 0009 H20: Escape (and the title X — both share _requestClose) must not
  // tear the session down under a running create; the footer Cancel is
  // already disabled for exactly that reason.
  testWidgets('Escape during a running create neither closes nor aborts', (
    tester,
  ) async {
    final (stub, exec, _) = await pumpConnected(tester);
    await nextStep(tester); // Source
    await nextStep(tester); // Remote (None)
    await tester.enterText(nameField(), 'new-proj');
    await tester.pumpAndSettle();
    await nextStep(tester); // Details → Review

    exec.gate = Completer<void>();
    exec.results.add(okResult('absent')); // probe (parked behind the gate)
    await tester.tap(createButton());
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    // The mid-flight progress chrome can overflow the tight test surface;
    // drain those non-fatal layout exceptions (same as pumpCreate).
    // ignore: invalid_use_of_protected_member
    while (tester.takeException() != null) {}
    expect(
      find.byType(CreateRepositorySheet),
      findsOneWidget,
      reason: 'mid-create Escape must be ignored',
    );

    exec.gate!.complete();
    exec.gate = null;
    await tester.pumpAndSettle();
    // ignore: invalid_use_of_protected_member
    while (tester.takeException() != null) {}
    expect(stub.repoPathsSet, ['/srv/new-proj']);
    expect(find.byType(CreateRepositorySheet), findsNothing);
  });

  testWidgets('Back is inert once a create has finished', (tester) async {
    // Give the finished (green) window a real duration so it can be observed:
    // the file-wide default is zero so the other tests don't wait it out.
    CreateRepositorySheet.successPopDelay = const Duration(seconds: 1);
    addTearDown(() => CreateRepositorySheet.successPopDelay = Duration.zero);

    final (stub, exec, _) = await pumpConnected(tester);
    await nextStep(tester); // Source
    await nextStep(tester); // Remote (None)
    await tester.enterText(nameField(), 'new-proj');
    await tester.pumpAndSettle();
    await nextStep(tester); // Details -> Review

    exec.results.add(okResult('absent')); // probe
    await tester.tap(createButton());
    await tester.pump(); // runs _submit up to the success-pop delay
    // The "Creating..." footer overflows the test surface by a few pixels;
    // drain that non-fatal layout exception so the behavioural asserts run
    // (same reason `pumpCreate` does it).
    // ignore: invalid_use_of_protected_member
    while (tester.takeException() != null) {}

    // Inside the finished window: created and registered, not yet popped.
    expect(stub.repoPathsSet, ['/srv/new-proj'], reason: 'create completed');
    expect(find.byType(CreateRepositorySheet), findsOneWidget);

    final back = tester.widget<AppPushButton>(
      find.widgetWithText(AppPushButton, 'Back'),
    );
    expect(back.onPressed, isNull, reason: 'Back must be inert after finish');

    // Let the success-pop timer expire so no timer outlives the test.
    await tester.pumpAndSettle(const Duration(seconds: 2));
  });

  testWidgets('selecting an SSH destination does not dial', (tester) async {
    // Deliberately inverted: this pinned dial-on-selection, and MADR 0036
    // decision 6B dials at the first commitment to the host instead — Browse…
    // or Create — so a cancelled wizard never has a tab to unwind.
    final (stub, _, _) = await pumpLanding(tester);
    await chooseDestination(tester, 'Prod');

    expect(stub.dialed, isEmpty);
    expect(find.text('Connecting…'), findsNothing);
  });

  testWidgets(
    'switching destination mid-hang-up does not setState on a disposed sheet',
    (tester) async {
      // F4 (MADR 0034). `_onDestChanged` awaits the hang-up of an adopted
      // session — a real network round trip — and then calls setState with no
      // `mounted` guard; dismissing the sheet inside that window used to throw
      // "setState() called after dispose()". Re-pointed for MADR 0036 (6B):
      // selection no longer dials, so the session is adopted through Browse…,
      // the first commitment to the host.
      final (stub, _, _) = await pumpLanding(tester);
      final abort = Completer<void>();
      stub.abortGate = abort;
      await chooseDestination(tester, 'Prod');
      await nextStep(tester); // Destination → Source

      // Browse… dials (instantly here) and opens the host's directory browser.
      await tester.tap(find.widgetWithText(AppPushButton, 'Browse…').first);
      await tester.pumpAndSettle();
      expect(stub.dialed.single.id, 'c1', reason: 'Browse… adopted a session');
      // `byTooltip` matches Material's Tooltip; this app's is MacosTooltip.
      // Two carry 'Close' now — the sheet's own and the browser's on top.
      await tester.tap(
        find
            .byWidgetPredicate((w) => w is MacosTooltip && w.message == 'Close')
            .last,
      );
      await tester.pumpAndSettle();

      // Back to Destination, switch to This Mac: the hang-up parks.
      await tester.tap(find.widgetWithText(AppPushButton, 'Back'));
      await tester.pumpAndSettle();
      await tester.tap(destinationPopup());
      await tester.pumpAndSettle();
      await tester.tap(find.text('This Mac').last);
      await tester.pump();
      expect(stub.aborts, 1, reason: 'the hang-up must actually be in flight');

      // The sheet goes away while the hang-up is still outstanding.
      await tester.pumpWidget(const MacosApp(home: Text('gone')));
      await tester.pump();

      abort.complete();
      await tester.pumpAndSettle();

      expect(
        tester.takeException(),
        isNull,
        reason: 'the resumed continuation must not touch a disposed State',
      );
    },
  );

  // -------------------------------------------------------------------------
  // MADR 0036 Phase 2 — today's connected behaviour, pinned.
  //
  // These pass against unedited `lib/`. Phase 3 changes two of them ON
  // PURPOSE (the SSH create will open its own tab; the Destination step will
  // appear) and must say so in the test when it does.
  // -------------------------------------------------------------------------
  group("connected: today's behaviour, pinned (MADR 0036 Phase 2)", () {
    testWidgets(
      'a connected SSH create provisions in its own tab and leaves the '
      'current tab alone',
      (tester) async {
        // Deliberately inverted from the Phase 2 pin "runs on the current
        // session and switches the current tab": MADR 0036 decision 3B.
        final tabs = RecordingTabs();
        installTabs(tabs);
        final (stub, exec, _) = await pumpConnected(tester);
        await nextStep(tester); // Source
        await nextStep(tester); // Remote (None)
        await tester.enterText(nameField(), 'new-proj');
        await tester.pumpAndSettle();
        await nextStep(tester); // Details → Review

        tabs.exec.results.add(okResult('absent')); // probe, in the NEW tab
        await tester.tap(createButton());
        await tester.pumpAndSettle();

        expect(tabs.opened, hasLength(1), reason: 'one tab was opened');
        final spawned = tabs.stubIn(tabs.tabs.single);
        expect(spawned.dialed.single.id, 'c1', reason: 'dialled there');
        expect(tabs.exec.calls.last, [
          'git',
          'init',
          '-b',
          'main',
          '--',
          'new-proj',
        ], reason: 'the init ran on the new tab\'s executor');
        expect(spawned.finalized.single.repoPath, '/srv/new-proj');
        // The tab the wizard was opened from is untouched.
        expect(exec.calls, isEmpty, reason: 'nothing ran on this tab');
        expect(stub.repoPathsSet, isEmpty, reason: 'this tab did not switch');
        expect(stub.dialed, isEmpty);
      },
    );

    testWidgets('a saved local create opens in its own tab', (tester) async {
      // Deliberately inverted from the Phase 2 pin "opens in the current
      // tab": MADR 0036 decision 3B. (5B keeps the current tab for an UNSAVED
      // local create — its own test in Phase 4.)
      final tabs = RecordingTabs();
      installTabs(tabs);
      installFolderPicker('/Users/me/projects');
      final counting = CountingScopedAccess();
      final previousAccess = CreateRepositorySheet.scopedAccess;
      CreateRepositorySheet.scopedAccess = counting.access;
      addTearDown(() => CreateRepositorySheet.scopedAccess = previousAccess);
      final (stub, exec, _) = await pumpConnectedLocal(tester);

      await tester.tap(chooseFolderButton()); // Source: parent folder
      await tester.pumpAndSettle();
      await nextStep(tester); // Source → Remote
      await nextStep(tester); // Remote (None) → Details
      await tester.enterText(nameField(), 'new-proj');
      await tester.pumpAndSettle();
      await nextStep(tester); // Details → Review

      exec.respond = localCreateOk;
      await pumpCreate(tester);

      expect(
        exec.calls.map((c) => c.join(' ')),
        containsAllInOrder(['git init -b main -- new-proj']),
        reason: 'ran on the LOCAL executor of the tab it started in',
      );
      expect(tabs.opened, hasLength(1), reason: 'one tab was opened');
      expect(tabs.opened.single.repoPath, '/resolved');
      final spawned = tabs.stubIn(tabs.tabs.single);
      expect(spawned.localConnects, ['/resolved'], reason: 'opened there');
      expect(stub.localConnects, isEmpty, reason: 'not in this tab');
      expect(counting.acquired, hasLength(1), reason: 'one grant, held');
      expect(counting.released, isEmpty);
    });

    testWidgets('a connected sheet shows the Destination step', (tester) async {
      // Deliberately inverted from the Phase 2 pin: MADR 0036 decision 2A.
      await pumpConnected(tester, pastDestination: false);
      expect(destinationPopup(), findsOneWidget);
    });
  });

  // -------------------------------------------------------------------------
  // MADR 0036 Phases 3+4 — the destination choice, and where the result opens.
  // -------------------------------------------------------------------------
  group('connected: the destination choice (MADR 0036 Phase 3)', () {
    testWidgets('it opens on the current SSH session', (tester) async {
      await pumpConnected(tester, pastDestination: false);
      expect(
        tester.widget<MacosPopupButton<String?>>(destinationPopup()).value,
        'c1',
        reason: 'the wizard opens on where the user is (2A)',
      );
    });

    testWidgets('a local session opens on This Mac', (tester) async {
      await pumpConnectedLocal(tester, pastDestination: false);
      expect(
        tester.widget<MacosPopupButton<String?>>(destinationPopup()).value,
        isNull,
      );
    });

    testWidgets('it refuses at the tab cap and runs nothing', (tester) async {
      final tabs = RecordingTabs()..capReached = true;
      installTabs(tabs);
      final (stub, exec, _) = await pumpConnected(tester);
      await nextStep(tester); // Source
      await nextStep(tester); // Remote (None)
      await tester.enterText(nameField(), 'new-proj');
      await tester.pumpAndSettle();
      await nextStep(tester); // Details → Review

      expect(
        tester.widget<AppPushButton>(createButton()).onPressed,
        isNull,
        reason: 'refused up front (7A), not silently no-op\'d by openOrFocus',
      );
      expect(find.text(CreateRepositorySheet.capMessage), findsOneWidget);
      expect(tabs.connectRan, 0);
      expect(exec.calls, isEmpty);
      expect(stub.dialed, isEmpty);
    });

    testWidgets('an unsaved local create is not gated by the cap', (
      tester,
    ) async {
      final tabs = RecordingTabs()..capReached = true;
      installTabs(tabs);
      installFolderPicker('/Users/me/projects');
      await pumpConnectedLocal(tester);
      await tester.tap(chooseFolderButton());
      await tester.pumpAndSettle();
      await nextStep(tester); // Source → Remote
      await nextStep(tester); // Remote → Details
      await tester.enterText(nameField(), 'new-proj');
      await tester.pumpAndSettle();
      // Turn off "Save to Local Repositories" (5B: opens in place, no tab).
      await tapSaveLocal(tester);
      await nextStep(tester); // Details → Review

      expect(tester.widget<AppPushButton>(createButton()).onPressed, isNotNull);
      expect(find.text(CreateRepositorySheet.capMessage), findsNothing);
      expect(
        find.text('Opens in this tab (not saved to Local Repositories)'),
        findsOneWidget,
      );
    });
  });

  group('the result opens in its own tab (MADR 0036 Phase 4)', () {
    testWidgets("the current session's output log is intact after a routed "
        'create', (tester) async {
      final tabs = RecordingTabs();
      installTabs(tabs);
      final (_, exec, _) = await pumpConnected(tester);
      // Seed this tab's log; a session takeover would clear it (P4).
      final own = ProviderScope.containerOf(
        tester.element(find.byType(CreateRepositorySheet)),
        listen: false,
      );
      own.read(outputLogProvider.notifier).logInfo('before the create');
      await nextStep(tester); // Source
      await nextStep(tester); // Remote (None)
      await tester.enterText(nameField(), 'new-proj');
      await tester.pumpAndSettle();
      await nextStep(tester); // Details → Review
      tabs.exec.results.add(okResult('absent'));
      await tester.tap(createButton());
      await tester.pumpAndSettle();

      expect(tabs.opened, hasLength(1));
      expect(
        own.read(outputLogProvider).lines.map((OutputLine l) => l.text),
        contains('before the create'),
        reason: 'this tab\'s log was not cleared by a takeover',
      );
      expect(exec.calls, isEmpty);
    });

    testWidgets('an unsaved local create opens in the current tab and opens '
        'no tab', (tester) async {
      final tabs = RecordingTabs();
      installTabs(tabs);
      installFolderPicker('/Users/me/projects');
      final (stub, exec, _) = await pumpConnectedLocal(tester);
      await tester.tap(chooseFolderButton());
      await tester.pumpAndSettle();
      await nextStep(tester); // Source → Remote
      await nextStep(tester); // Remote → Details
      await tester.enterText(nameField(), 'new-proj');
      await tester.pumpAndSettle();
      await tapSaveLocal(tester);
      await nextStep(tester); // Details → Review

      exec.respond = localCreateOk;
      await pumpCreate(tester);

      expect(stub.localConnects, ['/Users/me/projects/new-proj']);
      expect(tabs.opened, isEmpty, reason: 'no tab: nothing to reopen from');
    });

    testWidgets('no grant leaks when openOrFocus declines', (tester) async {
      final tabs = RecordingTabs();
      installTabs(tabs);
      installFolderPicker('/Users/me/projects');
      final counting = CountingScopedAccess();
      final previousAccess = CreateRepositorySheet.scopedAccess;
      CreateRepositorySheet.scopedAccess = counting.access;
      addTearDown(() => CreateRepositorySheet.scopedAccess = previousAccess);
      final (_, exec, _) = await pumpConnectedLocal(tester);
      await tester.tap(chooseFolderButton());
      await tester.pumpAndSettle();
      await nextStep(tester); // Source → Remote
      await nextStep(tester); // Remote → Details
      await tester.enterText(nameField(), 'new-proj');
      await tester.pumpAndSettle();
      await nextStep(tester); // Details → Review

      // The racing double-open: the up-front cap check passes, but the tab
      // host declines the open and never runs `connect`. The grant acquired
      // for it backs no session and must be released, or it leaks for the
      // app's lifetime.
      tabs.declineOpens = true;
      exec.respond = localCreateOk;
      await pumpCreate(tester);

      expect(counting.acquired, hasLength(1));
      expect(counting.released, ['/resolved'], reason: 'released on decline');
      expect(tabs.connectRan, 0);
      expect(
        find.text('The repository was created but could not be opened.'),
        findsOneWidget,
      );
    });

    testWidgets('a failed dial closes the tab it opened', (tester) async {
      final tabs = RecordingTabs()..spawnedDialResult = null;
      installTabs(tabs);
      final (_, exec, _) = await pumpConnected(tester);
      await nextStep(tester); // Source
      await nextStep(tester); // Remote (None)
      await tester.enterText(nameField(), 'new-proj');
      await tester.pumpAndSettle();
      await nextStep(tester); // Details → Review
      await tester.tap(createButton());
      await tester.pumpAndSettle();

      expect(tabs.opened, hasLength(1), reason: 'opened to dial in');
      expect(tabs.closed, hasLength(1), reason: 'closed again: no session');
      expect(find.text('Could not connect to host.'), findsOneWidget);
      expect(find.byType(CreateRepositorySheet), findsOneWidget);
      expect(exec.calls, isEmpty);
      expect(tabs.exec.calls, isEmpty);
    });

    testWidgets('a failed create after the dial closes the tab and aborts '
        'the session', (tester) async {
      final tabs = RecordingTabs();
      installTabs(tabs);
      await pumpConnected(tester);
      await nextStep(tester); // Source
      await nextStep(tester); // Remote (None)
      await tester.enterText(nameField(), 'new-proj');
      await tester.pumpAndSettle();
      await nextStep(tester); // Details → Review
      tabs.exec.results.add(okResult('absent')); // probe
      tabs.exec.results.add(
        const SSHCommandResult(exitCode: 128, stdout: '', stderr: 'boom'),
      ); // git init fails
      await tester.tap(createButton());
      await tester.pumpAndSettle();

      // The tab is closed by then, so read the stub RecordingTabs kept.
      final spawned = tabs.spawned.single;
      expect(spawned.dialed, hasLength(1));
      expect(spawned.aborts, 1, reason: 'the dialled session was hung up');
      expect(tabs.closed, hasLength(1), reason: 'and its tab closed');
      expect(find.byType(CreateRepositorySheet), findsOneWidget);
      expect(find.textContaining('boom'), findsOneWidget);
    });

    testWidgets('the destination control is dead while Browse… is dialling '
        '(MADR 0022 H4, UI half)', (tester) async {
      final gate = Completer<int?>();
      final tabs = RecordingTabs()..spawnedDialGate = gate;
      installTabs(tabs);
      await pumpConnected(tester); // on Source
      await tester.tap(find.widgetWithText(AppPushButton, 'Browse…').first);
      await tester.pump();
      await tester.pump(); // the dial is in flight, parked on the gate

      await tester.tap(find.widgetWithText(AppPushButton, 'Back'));
      await tester.pump();
      expect(
        tester.widget<MacosPopupButton<String?>>(destinationPopup()).onChanged,
        isNull,
        reason: 'switching mid-dial would adopt host A\'s session under B',
      );
      expect(find.text('Connecting…'), findsOneWidget);

      gate.complete(null); // let the dial fail so the test can settle
      await tester.pumpAndSettle();
    });
  });

  // -------------------------------------------------------------------------
  // MADR 0036 Phase 1 — a create on a chosen saved host, end to end.
  //
  // Before this group, the only landing-mode tests dialled (1339) or guarded
  // a mid-hang-up dispose (1376); none pressed Create. The `sshProvision`
  // branch of `registerAndActivate` had never been driven by a test.
  // -------------------------------------------------------------------------
  group('landing: a create on a chosen saved host (MADR 0036 Phase 1)', () {
    testWidgets(
      'creates on the chosen host and finalizes the provisioned session',
      (tester) async {
        final (stub, exec, _) = await pumpLanding(tester);
        await chooseDestination(tester, 'Prod');
        expect(
          stub.dialed,
          isEmpty,
          reason:
              'no dial on selection — inverted from Phase 1 as first '
              'written: MADR 0036 decision 6B dials at the first commitment',
        );

        await nextStep(tester); // Destination → Source
        await tester.enterText(parentField(), '/srv/git');
        await tester.pumpAndSettle();
        await nextStep(tester); // Source → Remote (None)
        await nextStep(tester); // Remote → Details
        await tester.enterText(nameField(), 'new-proj');
        await tester.pumpAndSettle();
        await nextStep(tester); // Details → Review

        exec.results.add(okResult('absent')); // probe
        await tester.tap(createButton());
        await tester.pumpAndSettle();

        // `exec.calls` is a List<List<String>>: `contains([...])` would compare
        // the inner lists by identity, so assert the last call by value as the
        // connected test does — and the probe's path first, which is what
        // proves the parent came from the field, not from This Mac.
        expect(
          exec.calls.first.join(' '),
          contains("p='/srv/git/new-proj'"),
          reason: 'the existence probe targets the chosen host path',
        );
        expect(exec.calls.last, [
          'git',
          'init',
          '-b',
          'main',
          '--',
          'new-proj',
        ]);
        expect(stub.dialed.single.id, 'c1', reason: 'dialled at submit');
        expect(stub.finalized.single.repoPath, '/srv/git/new-proj');
        expect(stub.finalized.single.token, 7);
        expect(
          find.byType(CreateRepositorySheet),
          findsNothing,
          reason: 'popped',
        );
      },
    );

    testWidgets(
      'a failed dial keeps the sheet open, shows the error, and runs nothing',
      (tester) async {
        final (stub, exec, _) = await pumpLanding(tester, dialResult: null);
        await chooseDestination(tester, 'Prod');
        // Under 6B the host is dialled at submit, so the failure surfaces
        // there — the steps in between are navigable, and must stay so.
        await nextStep(tester); // Destination → Source
        await tester.enterText(parentField(), '/srv/git');
        await tester.pumpAndSettle();
        await nextStep(tester); // Source → Remote
        await nextStep(tester); // Remote → Details
        await tester.enterText(nameField(), 'new-proj');
        await tester.pumpAndSettle();
        await nextStep(tester); // Details → Review
        await tester.tap(createButton());
        await tester.pumpAndSettle();

        expect(stub.dialed.single.id, 'c1', reason: 'one dial, at submit');
        expect(find.text('Could not connect to host.'), findsOneWidget);
        expect(exec.calls, isEmpty, reason: 'nothing ran on any executor');
        expect(stub.finalized, isEmpty);
        expect(find.byType(CreateRepositorySheet), findsOneWidget);
      },
    );

    testWidgets('the parent path comes from the chosen host, not This Mac', (
      tester,
    ) async {
      await pumpLanding(tester);
      await chooseDestination(tester, 'Prod');
      await nextStep(tester); // Destination → Source

      expect(parentField(), findsOneWidget);
      expect(find.text('Parent folder on this Mac'), findsNothing);
    });
  });
}

/// Parks `beginProvisioning` so a test can observe the in-flight dial.
