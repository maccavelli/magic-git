import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/storage/repository_ui_identity.dart';
import 'package:remote_magic_git/features/branches/branch_workspace_prefs.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    clearSessionBranchWorkspacePrefs();
  });

  group('BranchWorkspacePrefs JSON', () {
    test('v1 round-trip', () {
      const original = BranchWorkspacePrefs(
        pinnedBranchNames: ['main', 'dev'],
        hiddenBranchNames: ['tmp'],
        grouped: true,
        collapsedSections: {'branches.tags'},
        collapsedFolderPrefixes: {'feature/'},
        lastMode: 'review',
        browseSort: 'name',
        reviewSort: 'recent',
        selectedBaseRefName: 'refs/heads/main',
        showHidden: true,
      );
      final decoded = BranchWorkspacePrefs.decode(original.encode());
      expect(decoded.version, BranchWorkspacePrefs.currentVersion);
      expect(decoded.pinnedBranchNames, ['main', 'dev']);
      expect(decoded.hiddenBranchNames, ['tmp']);
      expect(decoded.grouped, isTrue);
      expect(decoded.collapsedSections, {'branches.tags'});
      expect(decoded.collapsedFolderPrefixes, {'feature/'});
      expect(decoded.lastMode, 'review');
      expect(decoded.browseSort, 'name');
      expect(decoded.reviewSort, 'recent');
      expect(decoded.selectedBaseRefName, 'refs/heads/main');
      expect(decoded.showHidden, isTrue);
    });
  });

  group('migrateFromLegacy', () {
    test('imports pins and only branches.* collapse bits', () {
      final migrated = BranchWorkspacePrefs.migrateFromLegacy(
        legacyPins: {'main', 'feature'},
        globalCollapsed: {
          'branches.tags',
          'branches.remote',
          'issues', // forge — must not import
        },
      );
      expect(migrated.pinnedBranchNames.toSet(), {'main', 'feature'});
      expect(migrated.collapsedSections, {
        'branches.tags',
        'branches.remote',
      });
      expect(migrated.collapsedSections.contains('issues'), isFalse);
    });
  });

  group('load/save durable', () {
    test('migrates pinnedBranches_<path> once and does not delete legacy', () async {
      SharedPreferences.setMockInitialValues({
        'pinnedBranches_/repo': ['main'],
        'collapsedSections': ['branches.local', 'issues'],
      });
      final identity = RepositoryUiIdentity.ssh(
        connectionId: 'c1',
        gitCommonDir: '/repo/.git',
      );
      final loaded = await loadBranchWorkspacePrefs(
        identity: identity,
        legacyRepoPath: '/repo',
        globalCollapsed: {'branches.local', 'issues'},
      );
      expect(loaded.pinnedBranchNames, ['main']);
      expect(loaded.collapsedSections, {'branches.local'});

      final sp = await SharedPreferences.getInstance();
      // Legacy pin key retained.
      expect(sp.getStringList('pinnedBranches_/repo'), ['main']);
      // New key written.
      expect(
        sp.getString(BranchWorkspacePrefs.storageKeyFor(identity)),
        isNotNull,
      );
    });

    test('second load uses durable record without re-migrating pins', () async {
      final identity = RepositoryUiIdentity.local(
        localRepoId: 'L1',
        gitCommonDir: '/r/.git',
      );
      SharedPreferences.setMockInitialValues({});
      await saveBranchWorkspacePrefs(
        identity: identity,
        next: const BranchWorkspacePrefs(pinnedBranchNames: ['kept']),
      );
      final sp = await SharedPreferences.getInstance();
      await sp.setStringList('pinnedBranches_/r', ['legacy']);

      final loaded = await loadBranchWorkspacePrefs(
        identity: identity,
        legacyRepoPath: '/r',
        globalCollapsed: const {},
      );
      expect(loaded.pinnedBranchNames, ['kept']);
    });
  });

  group('session-only adhoc', () {
    test('never writes SharedPreferences', () async {
      SharedPreferences.setMockInitialValues({});
      final identity = RepositoryUiIdentity.adhoc(
        backend: 'ssh',
        sessionEpoch: 7,
        gitCommonDir: '/tmp/x/.git',
      );
      await saveBranchWorkspacePrefs(
        identity: identity,
        next: const BranchWorkspacePrefs(lastMode: 'review'),
      );
      final sp = await SharedPreferences.getInstance();
      expect(sp.getKeys(), isEmpty);

      final loaded = await loadBranchWorkspacePrefs(
        identity: identity,
        legacyRepoPath: null,
      );
      expect(loaded.lastMode, 'review');

      clearSessionBranchWorkspacePrefs();
      final after = await loadBranchWorkspacePrefs(
        identity: identity,
        legacyRepoPath: null,
      );
      expect(after.lastMode, 'browse');
    });
  });

  group('mergeLateLoadedPrefs', () {
    test('does not clobber user-touched mode or base', () {
      const current = BranchWorkspacePrefs(
        lastMode: 'review',
        selectedBaseRefName: 'refs/heads/develop',
        pinnedBranchNames: ['user-pin'],
      );
      const incoming = BranchWorkspacePrefs(
        lastMode: 'browse',
        selectedBaseRefName: 'refs/heads/main',
        pinnedBranchNames: ['disk-pin'],
        grouped: true,
      );
      final merged = mergeLateLoadedPrefs(
        current: current,
        incoming: incoming,
        touchedMode: true,
        touchedBase: true,
        touchedPins: true,
      );
      expect(merged.lastMode, 'review');
      expect(merged.selectedBaseRefName, 'refs/heads/develop');
      expect(merged.pinnedBranchNames, ['user-pin']);
      expect(merged.grouped, isTrue); // untouched field from disk
    });
  });
}
