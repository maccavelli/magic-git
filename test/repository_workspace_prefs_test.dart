import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/settings/pane_layout.dart';
import 'package:remote_magic_git/core/settings/repository_workspace_prefs.dart';
import 'package:remote_magic_git/core/storage/repository_ui_identity.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    clearSessionRepositoryWorkspacePrefs();
  });

  test('v1 round-trip retains layout fields and clamps unsafe dimensions', () {
    const original = RepositoryWorkspacePrefs(
      navigatorMode: RepositoryNavigatorMode.files,
      preset: WorkspacePreset.investigate,
      navigatorWidth: 9999,
      inspectorWidth: 10,
      taskDockHeight: 400,
      navigatorCollapsed: true,
      inspectorCollapsed: true,
      taskDockCollapsed: true,
      inspectorPinned: true,
      filesPinned: true,
      diffLayout: RepositoryDiffLayout.split,
      ignoreWhitespace: true,
      diffContextLines: 12,
      grouping: RepositoryChangeGrouping.directory,
      showToolbarLabels: true,
    );

    final decoded = RepositoryWorkspacePrefs.decode(original.encode());
    expect(decoded.version, RepositoryWorkspacePrefs.currentVersion);
    expect(decoded.navigatorMode, RepositoryNavigatorMode.files);
    expect(decoded.preset, WorkspacePreset.investigate);
    expect(decoded.navigatorWidth, RepositoryWorkspacePrefs.maxNavigatorWidth);
    expect(decoded.inspectorWidth, RepositoryWorkspacePrefs.minInspectorWidth);
    expect(decoded.taskDockHeight, 400);
    expect(decoded.navigatorCollapsed, isTrue);
    expect(decoded.inspectorPinned, isTrue);
    expect(decoded.filesPinned, isTrue);
    expect(decoded.diffLayout, RepositoryDiffLayout.split);
    expect(decoded.ignoreWhitespace, isTrue);
    expect(decoded.diffContextLines, 12);
    expect(decoded.grouping, RepositoryChangeGrouping.directory);
    expect(decoded.showToolbarLabels, isTrue);
  });

  test('transient workspace state is absent from the durable schema', () {
    final json = jsonDecode(const RepositoryWorkspacePrefs().encode());
    expect(json, isA<Map<String, Object?>>());
    final keys = (json as Map<String, Object?>).keys;
    expect(keys, isNot(contains('selection')));
    expect(keys, isNot(contains('query')));
    expect(keys, isNot(contains('output')));
    expect(keys, isNot(contains('activity')));
    expect(keys, isNot(contains('commitMessage')));
  });

  test('same path and common dir on different hosts remain isolated', () async {
    final hostA = RepositoryUiIdentity.ssh(
      connectionId: 'host-a',
      gitCommonDir: '/srv/repo/.git',
    );
    final hostB = RepositoryUiIdentity.ssh(
      connectionId: 'host-b',
      gitCommonDir: '/srv/repo/.git',
    );
    await saveRepositoryWorkspacePrefs(
      identity: hostA,
      next: const RepositoryWorkspacePrefs(navigatorWidth: 500),
    );

    expect(
      (await loadRepositoryWorkspacePrefs(identity: hostA)).navigatorWidth,
      500,
    );
    expect(
      (await loadRepositoryWorkspacePrefs(identity: hostB)).navigatorWidth,
      RepositoryWorkspacePrefs.defaultNavigatorWidth,
    );
  });

  test('linked worktrees under one saved SSH identity share layout', () async {
    final main = RepositoryUiIdentity.ssh(
      connectionId: 'host-a',
      gitCommonDir: '/srv/repo/.git',
    );
    final linked = RepositoryUiIdentity.ssh(
      connectionId: 'host-a',
      gitCommonDir: '/srv/repo/.git',
    );
    await saveRepositoryWorkspacePrefs(
      identity: main,
      next: const RepositoryWorkspacePrefs(filesPinned: true),
    );
    expect(
      (await loadRepositoryWorkspacePrefs(identity: linked)).filesPinned,
      isTrue,
    );
  });

  test(
    'ad-hoc identities remain in memory and clear with the session',
    () async {
      final identity = RepositoryUiIdentity.adhoc(
        backend: 'local',
        sessionEpoch: 3,
        gitCommonDir: '/tmp/repo/.git',
      );
      await saveRepositoryWorkspacePrefs(
        identity: identity,
        next: const RepositoryWorkspacePrefs(taskDockCollapsed: true),
      );
      expect(
        (await loadRepositoryWorkspacePrefs(
          identity: identity,
        )).taskDockCollapsed,
        isTrue,
      );
      expect((await SharedPreferences.getInstance()).getKeys(), isEmpty);

      clearSessionRepositoryWorkspacePrefs();
      expect(
        (await loadRepositoryWorkspacePrefs(
          identity: identity,
        )).taskDockCollapsed,
        isFalse,
      );
    },
  );

  test(
    'first durable load seeds the applicable legacy width without deleting it',
    () async {
      SharedPreferences.setMockInitialValues({'paneWidth_filesTree': 540.0});
      final identity = RepositoryUiIdentity.local(
        localRepoId: 'local-1',
        gitCommonDir: '/repo/.git',
      );
      final loaded = await loadRepositoryWorkspacePrefs(
        identity: identity,
        legacyPaneWidths: const {PaneId.filesTree: 540},
      );
      expect(loaded.navigatorWidth, 540);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getDouble('paneWidth_filesTree'), 540);
      expect(
        prefs.getString(RepositoryWorkspacePrefs.storageKeyFor(identity)),
        isNotNull,
      );
    },
  );

  test('future or corrupt records fall back safely', () async {
    final identity = RepositoryUiIdentity.ssh(
      connectionId: 'host-a',
      gitCommonDir: '/repo/.git',
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      RepositoryWorkspacePrefs.storageKeyFor(identity),
      '{"version":999,"navigatorWidth":700}',
    );
    expect(
      (await loadRepositoryWorkspacePrefs(identity: identity)).navigatorWidth,
      RepositoryWorkspacePrefs.defaultNavigatorWidth,
    );

    await prefs.setString(
      RepositoryWorkspacePrefs.storageKeyFor(identity),
      'not-json',
    );
    expect(
      (await loadRepositoryWorkspacePrefs(identity: identity)).navigatorWidth,
      RepositoryWorkspacePrefs.defaultNavigatorWidth,
    );
  });

  test(
    'concurrent updates serialize per identity without field loss',
    () async {
      final identity = RepositoryUiIdentity.ssh(
        connectionId: 'host-a',
        gitCommonDir: '/repo/.git',
      );
      await Future.wait([
        updateRepositoryWorkspacePrefs(
          identity: identity,
          update: (current) => current.copyWith(filesPinned: true),
        ),
        updateRepositoryWorkspacePrefs(
          identity: identity,
          update: (current) => current.copyWith(navigatorWidth: 510),
        ),
      ]);

      final loaded = await loadRepositoryWorkspacePrefs(identity: identity);
      expect(loaded.filesPinned, isTrue);
      expect(loaded.navigatorWidth, 510);
    },
  );
}
