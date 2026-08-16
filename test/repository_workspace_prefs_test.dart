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

  // Named for what it does, not for a schema version — real v1 payloads are
  // exercised by the `legacy v1 records` group below.
  test('round-trip retains layout fields and clamps unsafe dimensions', () {
    const original = RepositoryWorkspacePrefs(
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
      visibleToolbarSlots: {WorkspaceToolbarSlot.back},
    );

    final decoded = RepositoryWorkspacePrefs.decode(original.encode());
    expect(decoded.version, RepositoryWorkspacePrefs.currentVersion);
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
    expect(decoded.visibleToolbarSlots, {WorkspaceToolbarSlot.back});
  });

  // The default set is duplicated nowhere, but it IS a hand-written literal.
  // A slot added to the enum and not to it would silently ship as hidden-by-
  // default — the exact shape of the bug this file's v1 tests describe.
  test('the default slot set covers every slot', () {
    expect(defaultVisibleToolbarSlots, WorkspaceToolbarSlot.values.toSet());
    expect(
      const RepositoryWorkspacePrefs().visibleToolbarSlots,
      WorkspaceToolbarSlot.values.toSet(),
    );
  });

  group('legacy v1 records', () {
    // WorkspaceToolbarSlot once had exactly two members, so a COMPLETE v1
    // record reads as "everything except Back/Forward is hidden" under today's
    // nine-member enum. That is what emptied the context bar down to a lone
    // primary action ("Fetch" on a clean, in-sync repository) for any
    // repository first opened while that build was current.
    String v1({List<String>? slots}) => jsonEncode({
      'version': 1,
      'preset': 'commit',
      'navigatorWidth': 400.0,
      'inspectorWidth': 360.0,
      'taskDockHeight': 220.0,
      'navigatorCollapsed': true,
      'inspectorCollapsed': false,
      'taskDockCollapsed': true,
      'inspectorPinned': false,
      'filesPinned': true,
      'diffLayout': 'split',
      'ignoreWhitespace': true,
      'diffContextLines': 7,
      'grouping': 'directory',
      'showToolbarLabels': true,
      'visibleToolbarSlots': ?slots,
    });

    test('a complete two-slot v1 record is restored to the full bar', () {
      final decoded = RepositoryWorkspacePrefs.decode(
        v1(slots: const ['back', 'forward']),
      );
      expect(decoded.visibleToolbarSlots, WorkspaceToolbarSlot.values.toSet());
    });

    test('a v1 record with no slot key is restored to the full bar', () {
      final decoded = RepositoryWorkspacePrefs.decode(v1());
      expect(decoded.visibleToolbarSlots, WorkspaceToolbarSlot.values.toSet());
    });

    test('migrating preserves every other v1 field', () {
      final decoded = RepositoryWorkspacePrefs.decode(v1());
      expect(decoded.version, RepositoryWorkspacePrefs.currentVersion);
      expect(decoded.preset, WorkspacePreset.commit);
      expect(decoded.navigatorWidth, 400);
      expect(decoded.navigatorCollapsed, isTrue);
      expect(decoded.filesPinned, isTrue);
      expect(decoded.diffLayout, RepositoryDiffLayout.split);
      expect(decoded.ignoreWhitespace, isTrue);
      expect(decoded.diffContextLines, 7);
      expect(decoded.grouping, RepositoryChangeGrouping.directory);
      expect(decoded.showToolbarLabels, isTrue);
    });

    test('a v2 record still honours an explicit partial choice', () {
      const hidden = RepositoryWorkspacePrefs(
        visibleToolbarSlots: {WorkspaceToolbarSlot.refresh},
      );
      final decoded = RepositoryWorkspacePrefs.decode(hidden.encode());
      expect(decoded.visibleToolbarSlots, {WorkspaceToolbarSlot.refresh});
    });

    test('a v2 record honours hiding every slot', () {
      const none = RepositoryWorkspacePrefs(visibleToolbarSlots: {});
      expect(
        RepositoryWorkspacePrefs.decode(none.encode()).visibleToolbarSlots,
        isEmpty,
      );
    });

    test('an unknown future version falls back to defaults', () {
      final decoded = RepositoryWorkspacePrefs.decode(
        jsonEncode({'version': 99, 'navigatorWidth': 400.0}),
      );
      expect(decoded.visibleToolbarSlots, WorkspaceToolbarSlot.values.toSet());
      expect(
        decoded.navigatorWidth,
        RepositoryWorkspacePrefs.defaultNavigatorWidth,
      );
    });
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

  test('built-in presets change only pane arrangement state', () {
    const original = RepositoryWorkspacePrefs(
      diffLayout: RepositoryDiffLayout.split,
      ignoreWhitespace: true,
      diffContextLines: 12,
      grouping: RepositoryChangeGrouping.directory,
      showToolbarLabels: true,
      filesPinned: true,
    );

    for (final preset in WorkspacePreset.values) {
      final applied = applyWorkspacePreset(original, preset);
      expect(applied.preset, preset);
      expect(applied.diffLayout, original.diffLayout);
      expect(applied.ignoreWhitespace, original.ignoreWhitespace);
      expect(applied.diffContextLines, original.diffContextLines);
      expect(applied.grouping, original.grouping);
      expect(applied.showToolbarLabels, original.showToolbarLabels);
      expect(applied.visibleToolbarSlots, original.visibleToolbarSlots);
      expect(applied.filesPinned, original.filesPinned);
    }
  });

  test('preset arrangements have deterministic pane visibility', () {
    const original = RepositoryWorkspacePrefs();
    final review = applyWorkspacePreset(original, WorkspacePreset.review);
    final commit = applyWorkspacePreset(original, WorkspacePreset.commit);
    final investigate = applyWorkspacePreset(
      original,
      WorkspacePreset.investigate,
    );
    final minimal = applyWorkspacePreset(original, WorkspacePreset.minimal);

    expect(review.taskDockCollapsed, isTrue);
    expect(review.inspectorPinned, isFalse);
    expect(commit.taskDockCollapsed, isFalse);
    expect(commit.inspectorCollapsed, isTrue);
    expect(investigate.inspectorPinned, isTrue);
    expect(investigate.inspectorCollapsed, isFalse);
    expect(minimal.navigatorCollapsed, isTrue);
    expect(minimal.inspectorCollapsed, isTrue);
    expect(minimal.taskDockCollapsed, isTrue);
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
      // The witness is a field whose default is `false`, so "reverted to the
      // default" is distinguishable from "still holding the stored value".
      await saveRepositoryWorkspacePrefs(
        identity: identity,
        next: const RepositoryWorkspacePrefs(navigatorCollapsed: true),
      );
      expect(
        (await loadRepositoryWorkspacePrefs(
          identity: identity,
        )).navigatorCollapsed,
        isTrue,
      );
      expect((await SharedPreferences.getInstance()).getKeys(), isEmpty);

      clearSessionRepositoryWorkspacePrefs();
      expect(
        (await loadRepositoryWorkspacePrefs(
          identity: identity,
        )).navigatorCollapsed,
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
