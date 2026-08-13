import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show Colors, LinearProgressIndicator;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/settings/repository_workspace_prefs.dart';
import 'package:remote_magic_git/features/common/adaptive_workspace_layout.dart';
import 'package:remote_magic_git/features/common/repository_workspace_scaffold.dart';

enum _FixtureKind {
  clean,
  dirty,
  conflict,
  loading,
  partialError,
  multiFileReview,
  composerExpanded,
  activeOperation,
  repository,
  history,
  branches,
  stashes,
  forge,
  worktrees,
  compactOverlay,
  highContrast,
}

const _sizes = <String, Size>{
  'compact_640x480': Size(640, 480),
  'standard_1080x720': Size(1080, 720),
  'wide_1600x1000': Size(1600, 1000),
};

String _title(_FixtureKind kind) => switch (kind) {
  _FixtureKind.clean => 'Working tree clean',
  _FixtureKind.dirty => '7 changes on feature/workspace',
  _FixtureKind.conflict => '2 conflicts need resolution',
  _FixtureKind.loading => 'Loading repository',
  _FixtureKind.partialError => 'Refresh failed — showing cached data',
  _FixtureKind.multiFileReview => 'Reviewing 8 selected files',
  _FixtureKind.composerExpanded => 'Commit composer expanded',
  _FixtureKind.activeOperation => 'Pushing feature/workspace',
  _FixtureKind.repository => 'Repository · Changes',
  _FixtureKind.history => 'History · Commit graph',
  _FixtureKind.branches => 'Branches · Browse',
  _FixtureKind.stashes => 'Stashes · 3 saved states',
  _FixtureKind.forge => 'Forge · Pull requests and CI',
  _FixtureKind.worktrees => 'Worktrees · 4 checkouts',
  _FixtureKind.compactOverlay => 'Inspector overlay',
  _FixtureKind.highContrast => 'High contrast workspace',
};

Color _accent(_FixtureKind kind) => switch (kind) {
  _FixtureKind.conflict || _FixtureKind.partialError => const Color(0xFFFF6B57),
  _FixtureKind.activeOperation || _FixtureKind.forge => const Color(0xFF58A6FF),
  _FixtureKind.clean => const Color(0xFF4AC26B),
  _FixtureKind.highContrast => Colors.white,
  _ => const Color(0xFFB1BAC4),
};

class _WorkspaceGoldenFixture extends StatelessWidget {
  final _FixtureKind kind;
  final Size size;

  const _WorkspaceGoldenFixture({required this.kind, required this.size});

  @override
  Widget build(BuildContext context) {
    final accent = _accent(kind);
    final highContrast = kind == _FixtureKind.highContrast;
    final overlay = kind == _FixtureKind.compactOverlay;
    return RepaintBoundary(
      key: const Key('golden'),
      child: ColoredBox(
        color: const Color(0xFF191A1F),
        child: RepositoryWorkspaceScaffold(
          repositoryContext: Container(
            height: 52,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              color: const Color(0xFF25262B),
              border: Border(
                bottom: BorderSide(
                  color: highContrast ? Colors.white : const Color(0x445E6470),
                ),
              ),
            ),
            child: Row(
              children: [
                const Icon(
                  CupertinoIcons.chevron_back,
                  size: 14,
                  color: Color(0xFF8B949E),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text(
                    'magic-git  ·  feature/workspace  ·  On this Mac',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: Color(0xFFE6EDF3), fontSize: 13),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.18),
                    border: Border.all(color: accent),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    kind == _FixtureKind.conflict ? 'Resolve' : 'Commit',
                    style: TextStyle(color: accent, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
          navigator: _navigator(accent, highContrast),
          canvas: _canvas(accent, highContrast),
          inspector: _inspector(accent, highContrast),
          taskDock: _taskDock(accent),
          loading: kind == _FixtureKind.loading,
          inspectorVisible: overlay || size.width >= 1200,
          taskDockFocused:
              kind == _FixtureKind.composerExpanded ||
              kind == _FixtureKind.activeOperation,
          activePage: size.width < 720
              ? CompactWorkspacePage.canvas
              : CompactWorkspacePage.navigator,
          preferences: RepositoryWorkspacePrefs(
            inspectorPinned: size.width >= 1200,
            taskDockCollapsed:
                kind != _FixtureKind.composerExpanded &&
                kind != _FixtureKind.activeOperation,
          ),
        ),
      ),
    );
  }

  Widget _navigator(Color accent, bool highContrast) => Container(
    color: const Color(0xFF222328),
    padding: const EdgeInsets.all(12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'FILTER  changed files',
          style: TextStyle(color: Color(0xFF8B949E), fontSize: 11),
        ),
        const SizedBox(height: 12),
        for (var index = 0; index < 7; index++)
          Container(
            height: 34,
            margin: const EdgeInsets.only(bottom: 3),
            padding: const EdgeInsets.symmetric(horizontal: 9),
            decoration: BoxDecoration(
              color: index == 1 ? accent.withValues(alpha: 0.22) : null,
              border: highContrast && index == 1
                  ? Border.all(color: Colors.white, width: 2)
                  : null,
              borderRadius: BorderRadius.circular(5),
            ),
            alignment: Alignment.centerLeft,
            child: Text(
              switch (kind) {
                _FixtureKind.history => 'a1b2c3$index  Commit subject $index',
                _FixtureKind.branches => 'feature/workspace-$index',
                _FixtureKind.stashes => 'stash@{$index}  Saved work',
                _FixtureKind.forge => '#${120 + index}  Review request',
                _FixtureKind.worktrees => 'workspace-$index  feature/$index',
                _ => 'lib/feature_$index.dart',
              },
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Color(0xFFD0D7DE), fontSize: 12),
            ),
          ),
      ],
    ),
  );

  Widget _canvas(Color accent, bool highContrast) => Container(
    color: const Color(0xFF1E1E1E),
    padding: const EdgeInsets.all(20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          _title(kind),
          style: TextStyle(
            color: accent,
            fontSize: 19,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 16),
        if (kind == _FixtureKind.partialError)
          Container(
            padding: const EdgeInsets.all(10),
            color: const Color(0x33FF6B57),
            child: const Text(
              'Could not refresh origin. Cached content remains usable.',
              style: TextStyle(color: Color(0xFFFFB4A9), fontSize: 12),
            ),
          ),
        Expanded(
          child: SingleChildScrollView(
            child: kind == _FixtureKind.conflict
                ? const Text(
                    '<<<<<<< ours\nfinal workspace = current;\n=======\nfinal workspace = incoming;\n>>>>>>> theirs',
                    style: TextStyle(
                      color: Color(0xFFFFB4A9),
                      fontFamily: 'Menlo',
                      fontSize: 12,
                      height: 1.55,
                    ),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: List.generate(
                      10,
                      (index) => Text(
                        '${index + 1}'.padLeft(3) +
                            (index == 3
                                ? '  + final polishedWorkspace = true;'
                                : '    repository workspace content line $index'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: index == 3 ? accent : const Color(0xFF9DA5B4),
                          fontFamily: 'Menlo',
                          fontSize: 11,
                          height: 1.55,
                        ),
                      ),
                    ),
                  ),
          ),
        ),
        if (kind == _FixtureKind.activeOperation) ...[
          LinearProgressIndicator(
            value: 0.64,
            color: accent,
            backgroundColor: const Color(0xFF343740),
          ),
        ],
      ],
    ),
  );

  Widget _inspector(Color accent, bool highContrast) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: const Color(0xFF292A30),
      border: Border(
        left: BorderSide(color: highContrast ? Colors.white : accent),
      ),
    ),
    child: const Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('INSPECTOR', style: TextStyle(color: Color(0xFF8B949E))),
        SizedBox(height: 14),
        Text('Selection details', style: TextStyle(color: Color(0xFFE6EDF3))),
        SizedBox(height: 8),
        Text('Ready to review', style: TextStyle(color: Color(0xFF7EE787))),
      ],
    ),
  );

  Widget _taskDock(Color accent) => Container(
    color: const Color(0xFF202126),
    padding: const EdgeInsets.all(14),
    child: Row(
      children: [
        Expanded(
          child: Text(
            kind == _FixtureKind.activeOperation
                ? 'Pushing 4 of 6 objects…'
                : 'Commit message: Polish repository workspace',
            style: const TextStyle(color: Color(0xFFD0D7DE), fontSize: 12),
          ),
        ),
        Text('READY', style: TextStyle(color: accent, fontSize: 11)),
      ],
    ),
  );
}

void main() {
  const accentChannel = MethodChannel('appkit_ui_element_colors');
  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          accentChannel,
          (_) async => <String, double>{'hueComponent': 0.6},
        );
  });
  tearDownAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(accentChannel, null);
  });
  for (final entry in _sizes.entries) {
    for (final kind in _FixtureKind.values) {
      testWidgets('${entry.key} ${kind.name}', (tester) async {
        tester.view.physicalSize = entry.value;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          MacosApp(
            debugShowCheckedModeBanner: false,
            theme: MacosThemeData.dark(),
            home: SizedBox.fromSize(
              size: entry.value,
              child: _WorkspaceGoldenFixture(kind: kind, size: entry.value),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 100));

        await expectLater(
          find.byKey(const Key('golden')),
          matchesGoldenFile('goldens/workspace/${entry.key}_${kind.name}.png'),
        );
      });
    }
  }
}
