// MADR 0039 F3 — ad-hoc (unsaved) workspace preferences live in process-global
// maps, and every tab is its own session. Two things went wrong there:
//
//  * a connect in ANY tab called an unconditional `.clear()`, so another tab's
//    navigator width, toolbar slots, pins and collapse state vanished under the
//    user with no action of theirs;
//  * the discriminator for ad-hoc identities was `sessionEpoch`, which is
//    `ConnectionController._attempt` — a PER-CONTROLLER counter. Two tabs'
//    first ad-hoc connections are both `adhoc:ssh:1`, so with a matching
//    gitCommonDir they shared one record outright.
//
// Durable identities are deliberately NOT partitioned: they persist to
// SharedPreferences under a saved id and are meant to be shared across tabs.

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/settings/repository_workspace_prefs.dart';
import 'package:remote_magic_git/core/storage/repository_ui_identity.dart';
import 'package:remote_magic_git/features/branches/branch_workspace_prefs.dart';
import 'package:shared_preferences/shared_preferences.dart';

RepositoryUiIdentity _adhoc(int scopeId) => RepositoryUiIdentity.adhoc(
  backend: 'ssh',
  sessionEpoch: 1, // the collision: every tab's first attempt is epoch 1
  gitCommonDir: '/srv/repo/.git',
  sessionScopeId: scopeId,
);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    clearAllSessionRepositoryWorkspacePrefs();
    clearAllSessionBranchWorkspacePrefs();
  });

  group('identity', () {
    test(
      'two sessions at the same epoch and path are different identities',
      () {
        final a = _adhoc(1);
        final b = _adhoc(2);

        expect(
          a.scopeKey,
          b.scopeKey,
          reason: 'the epoch alone cannot tell them apart',
        );
        expect(a.memoryKey, b.memoryKey);
        expect(
          a,
          isNot(b),
          reason: 'the session scope is what separates two concurrent tabs',
        );
        expect({a, b}, hasLength(2));
      },
    );

    test('the durable preference key is unchanged by this partition', () {
      // Byte-identity, pinned: the durable key is written to SharedPreferences,
      // so changing it would orphan every saved repository's stored layout on
      // upgrade. The literal below is the pre-partition value.
      final durable = RepositoryUiIdentity.ssh(
        connectionId: 'conn-1',
        gitCommonDir: '/srv/repo/.git',
      );

      expect(durable.sessionScopeId, 0);
      expect(durable.preferenceKey, 'c3NoOmNvbm4tMQAvc3J2L3JlcG8vLmdpdA');
    });
  });

  group('repository workspace prefs', () {
    test('a clear in one session leaves the other session intact', () async {
      final a = _adhoc(1);
      final b = _adhoc(2);

      await saveRepositoryWorkspacePrefs(
        identity: a,
        next: const RepositoryWorkspacePrefs(navigatorWidth: 321),
      );
      await saveRepositoryWorkspacePrefs(
        identity: b,
        next: const RepositoryWorkspacePrefs(navigatorWidth: 654),
      );

      // Session 2 reconnects. Session 1 did nothing.
      clearSessionRepositoryWorkspacePrefsFor(2);

      expect(
        (await loadRepositoryWorkspacePrefs(identity: a)).navigatorWidth,
        321,
        reason: 'a reconnect in another tab must not reset this tab\'s layout',
      );
      expect(
        (await loadRepositoryWorkspacePrefs(identity: b)).navigatorWidth,
        RepositoryWorkspacePrefs.defaultNavigatorWidth,
      );
    });

    test('two sessions do not share one stored record', () async {
      final a = _adhoc(1);
      final b = _adhoc(2);

      await saveRepositoryWorkspacePrefs(
        identity: a,
        next: const RepositoryWorkspacePrefs(navigatorWidth: 321),
      );

      expect(
        (await loadRepositoryWorkspacePrefs(identity: b)).navigatorWidth,
        RepositoryWorkspacePrefs.defaultNavigatorWidth,
        reason:
            'both are adhoc:ssh:1 on the same git dir — only the session '
            'scope keeps them apart',
      );
      expect(
        (await loadRepositoryWorkspacePrefs(identity: a)).navigatorWidth,
        321,
      );
    });

    test('a durable identity survives every session clear', () async {
      final durable = RepositoryUiIdentity.ssh(
        connectionId: 'conn-1',
        gitCommonDir: '/srv/repo/.git',
      );
      await saveRepositoryWorkspacePrefs(
        identity: durable,
        next: const RepositoryWorkspacePrefs(navigatorWidth: 400),
      );

      clearSessionRepositoryWorkspacePrefsFor(0);
      clearSessionRepositoryWorkspacePrefsFor(1);
      clearAllSessionRepositoryWorkspacePrefs();

      expect(
        (await loadRepositoryWorkspacePrefs(identity: durable)).navigatorWidth,
        400,
        reason: 'durable prefs are on disk and shared across tabs by design',
      );
    });
  });

  group('branch workspace prefs', () {
    test('a clear in one session leaves the other session intact', () async {
      final a = _adhoc(1);
      final b = _adhoc(2);

      await saveBranchWorkspacePrefs(
        identity: a,
        next: const BranchWorkspacePrefs(lastMode: 'review'),
      );
      await saveBranchWorkspacePrefs(
        identity: b,
        next: const BranchWorkspacePrefs(lastMode: 'review'),
      );

      clearSessionBranchWorkspacePrefsFor(2);

      expect(
        (await loadBranchWorkspacePrefs(
          identity: a,
          legacyRepoPath: null,
        )).lastMode,
        'review',
        reason:
            'a reconnect in another tab must not drop this tab\'s pins '
            'and collapse state',
      );
      expect(
        (await loadBranchWorkspacePrefs(
          identity: b,
          legacyRepoPath: null,
        )).lastMode,
        'browse',
      );
    });

    test('two sessions do not share one stored record', () async {
      final a = _adhoc(1);
      final b = _adhoc(2);

      await saveBranchWorkspacePrefs(
        identity: a,
        next: const BranchWorkspacePrefs(grouped: true),
      );

      expect(
        (await loadBranchWorkspacePrefs(
          identity: b,
          legacyRepoPath: null,
        )).grouped,
        isFalse,
      );
      expect(
        (await loadBranchWorkspacePrefs(
          identity: a,
          legacyRepoPath: null,
        )).grouped,
        isTrue,
      );
    });
  });
}
