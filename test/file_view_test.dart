// Widget tests for the file-view pane: dirty folders render green, clean ones
// blue, names white; dirty dirs auto-expand; clicking a changed file invokes
// onOpenFile; expand/collapse toggles child rows; and a status-only change
// recolors atomically without rebuilding the tree or losing expansion state.

import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart'
    show PointerDeviceKind, kSecondaryMouseButton;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:macos_window_utils/widgets/transparent_macos_sidebar.dart';

import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/git/repo_tree.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/settings/repository_workspace_prefs.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/core/storage/repository_ui_identity.dart';
import 'package:remote_magic_git/core/utils/git_porcelain_parser.dart';
import 'package:remote_magic_git/features/common/tool_icon_button.dart';
import 'package:remote_magic_git/features/repository/file_view.dart';
import 'package:remote_magic_git/features/viewer/viewer_providers.dart';
import 'package:remote_magic_git/features/window/secondary_window_scope.dart';
import 'package:riverpod/misc.dart' show Override;
import 'package:shared_preferences/shared_preferences.dart';

const _repo = '/srv/repo';

// Status-free structure: shape only, colored by the overlay at render time.
RepoNode _fixture() => const RepoNode(
  name: '',
  path: '',
  isDir: true,
  children: [
    RepoNode(
      name: 'lib',
      path: 'lib',
      isDir: true,
      children: [
        RepoNode(name: 'main.dart', path: 'lib/main.dart', isDir: false),
      ],
    ),
    RepoNode(
      name: 'docs',
      path: 'docs',
      isDir: true,
      children: [
        RepoNode(name: 'readme.md', path: 'docs/readme.md', isDir: false),
      ],
    ),
    RepoNode(name: 'todo.txt', path: 'todo.txt', isDir: false),
  ],
);

// lib is dirty (main.dart modified); todo.txt is a new untracked file.
const _overlay = RepoStatusOverlay(
  dirtyDirs: {'lib'},
  changed: {
    'lib/main.dart': GitFileStatus(
      path: 'lib/main.dart',
      statusX: '.',
      statusY: 'M',
    ),
    'todo.txt': GitFileStatus(path: 'todo.txt', statusX: '?', statusY: '?'),
  },
  untrackedDirs: {},
);

// lib/main.dart is partially staged (staged AND unstaged at once) — used to
// prove the staged/unstaged toggle in the context menu.
const _overlayMixed = RepoStatusOverlay(
  dirtyDirs: {'lib'},
  changed: {
    'lib/main.dart': GitFileStatus(
      path: 'lib/main.dart',
      statusX: 'M',
      statusY: 'M',
    ),
  },
  untrackedDirs: {},
);

// lib/main.dart is conflicted (UU) — the tree must route it to the conflict
// pane, not a plain diff, and offer Mark Resolved (0009 H5 / H6).
const _overlayConflict = RepoStatusOverlay(
  dirtyDirs: {'lib'},
  changed: {
    'lib/main.dart': GitFileStatus(
      path: 'lib/main.dart',
      statusX: 'U',
      statusY: 'U',
    ),
  },
  untrackedDirs: {},
);

// docs turns dirty too — used to prove a status-only refresh recolors.
const _overlayDocsDirty = RepoStatusOverlay(
  dirtyDirs: {'lib', 'docs'},
  changed: {
    'lib/main.dart': GitFileStatus(
      path: 'lib/main.dart',
      statusX: '.',
      statusY: 'M',
    ),
    'docs/readme.md': GitFileStatus(
      path: 'docs/readme.md',
      statusX: '.',
      statusY: 'M',
    ),
    'todo.txt': GitFileStatus(path: 'todo.txt', statusX: '?', statusY: '?'),
  },
  untrackedDirs: {},
);

// A flippable overlay source so a test can simulate a status-only refresh.
class _OverlaySource extends Notifier<RepoStatusOverlay> {
  @override
  RepoStatusOverlay build() => _overlay;
  void set(RepoStatusOverlay o) => state = o;
}

final _overlaySource = NotifierProvider<_OverlaySource, RepoStatusOverlay>(
  _OverlaySource.new,
);

Future<void> _pump(
  WidgetTester tester, {
  required OpenFileCallback onOpenFile,
  bool dynamicOverlay = false,
  RepoStatusOverlay? overlay,
  List<Override> extraOverrides = const [],
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ...extraOverrides,
        repoStructureProvider(_repo).overrideWith((ref) async => _fixture()),
        if (dynamicOverlay)
          repoStatusOverlayProvider(
            _repo,
          ).overrideWith((ref) => ref.watch(_overlaySource))
        else
          repoStatusOverlayProvider(
            _repo,
          ).overrideWith((ref) => overlay ?? _overlay),
      ],
      child: MacosApp(
        debugShowCheckedModeBanner: false,
        home: SizedBox(
          width: 900,
          height: 600,
          child: Align(
            alignment: Alignment.centerRight,
            child: FileView(
              maxWidth: 900,
              repoPath: _repo,
              onOpenFile: onOpenFile,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Iterable<MacosIcon> _icons(WidgetTester tester) =>
    tester.widgetList<MacosIcon>(find.byType(MacosIcon));

/// The background color of a file/folder row's tile — transparent unless the
/// row is selected/highlighted.
Color? _tileColor(WidgetTester tester, String path) {
  final container = tester.widget<Container>(
    find
        .descendant(
          of: find.byKey(ValueKey(path)),
          matching: find.byType(Container),
        )
        .first,
  );
  return container.color;
}

Color? _folderColor(WidgetTester tester, String path) {
  // Scope to the row's keyed tile, then pick the folder icon (not the chevron).
  final tile = find.byKey(ValueKey(path));
  final icons = tester.widgetList<MacosIcon>(
    find.descendant(of: tile, matching: find.byType(MacosIcon)),
  );
  for (final ic in icons) {
    if (ic.icon == CupertinoIcons.folder ||
        ic.icon == CupertinoIcons.folder_fill) {
      return ic.color;
    }
  }
  return null;
}

void main() {
  testWidgets('a dragged Files-pane width persists across a remount', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    addTearDown(() => SharedPreferences.setMockInitialValues({}));
    await _pump(
      tester,
      onOpenFile:
          (_, {required staged, required untracked, required conflict}) {},
    );

    // Default width: maxWidth / 4 = 225 (nothing stored).
    expect(tester.getSize(find.byType(FileView)).width, 225);

    // Drag the handle left 55px — the right-docked pane GROWS to 280.
    final pane = tester.getRect(find.byType(FileView));
    final gesture = await tester.startGesture(
      Offset(pane.left + 4, pane.top + 300),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await gesture.moveBy(const Offset(-55, 0));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(tester.getSize(find.byType(FileView)).width, 280);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getDouble('paneWidth_filesTree'), 280);

    // Remount (blank frame, then re-pump): the width used to reset to
    // maxWidth/4 here — now it re-applies from the persisted setting.
    await tester.pumpWidget(const SizedBox());
    await _pump(
      tester,
      onOpenFile:
          (_, {required staged, required untracked, required conflict}) {},
    );
    expect(tester.getSize(find.byType(FileView)).width, 280);
  });

  testWidgets('the pin button is filesPinned\'s writer — it was persisted, '
      'read back, and honoured, but nothing could ever set it', (tester) async {
    SharedPreferences.setMockInitialValues({});
    addTearDown(() => SharedPreferences.setMockInitialValues({}));
    clearSessionRepositoryWorkspacePrefs();

    final identity = RepositoryUiIdentity.local(
      localRepoId: 'test-repo',
      gitCommonDir: '$_repo/.git',
    );
    await _pump(
      tester,
      onOpenFile:
          (_, {required staged, required untracked, required conflict}) {},
      extraOverrides: [
        repositoryUiIdentityProvider(
          _repo,
        ).overrideWith((ref) async => identity),
      ],
    );

    Finder pin(IconData icon) =>
        find.byWidgetPredicate((w) => w is ToolIconButton && w.icon == icon);

    expect(pin(CupertinoIcons.pin), findsOneWidget);
    expect(pin(CupertinoIcons.pin_fill), findsNothing);

    await tester.tap(pin(CupertinoIcons.pin));
    await tester.pumpAndSettle();

    // The state the read site at repo_status_view already consumed — it keeps
    // the tree docked even when the visibility toggle is off.
    expect(
      (await loadRepositoryWorkspacePrefs(identity: identity)).filesPinned,
      isTrue,
    );
    expect(pin(CupertinoIcons.pin_fill), findsOneWidget);

    await tester.tap(pin(CupertinoIcons.pin_fill));
    await tester.pumpAndSettle();
    expect(
      (await loadRepositoryWorkspacePrefs(identity: identity)).filesPinned,
      isFalse,
    );
  });

  testWidgets('dirty folder green, clean folder blue, names white', (
    tester,
  ) async {
    await _pump(
      tester,
      onOpenFile:
          (_, {required staged, required untracked, required conflict}) {},
    );

    expect(find.text('lib'), findsOneWidget);
    expect(find.text('docs'), findsOneWidget);

    final colors = _icons(tester).map((i) => i.color).toList();
    expect(colors, contains(MacosColors.systemGreenColor));
    expect(colors, contains(MacosColors.systemBlueColor));

    final libText = tester.widget<Text>(find.text('lib'));
    expect(libText.style?.color, const Color(0xFFFFFFFF));
  });

  testWidgets('dirty directory auto-expands to reveal its changed file', (
    tester,
  ) async {
    await _pump(
      tester,
      onOpenFile:
          (_, {required staged, required untracked, required conflict}) {},
    );
    // 'lib' is dirty → auto-expanded; 'docs' is clean → collapsed.
    expect(find.text('main.dart'), findsOneWidget);
    expect(find.text('readme.md'), findsNothing);
  });

  testWidgets('changed file shows a colored status letter', (tester) async {
    await _pump(
      tester,
      onOpenFile:
          (_, {required staged, required untracked, required conflict}) {},
    );
    // lib/main.dart is modified (.M) → a yellow 'M' letter (colored text).
    expect(find.text('M'), findsOneWidget);
    final letter = tester.widget<Text>(find.text('M'));
    expect(letter.style?.color, MacosColors.systemYellowColor);
  });

  // 0009 M26: the vibrancy sidebar rides WindowManipulator, which is wired
  // for the main window only — a pop-out paints an opaque pane instead.
  testWidgets('a secondary window gets an opaque pane, not the vibrancy '
      'sidebar', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          repoStructureProvider(_repo).overrideWith((ref) async => _fixture()),
          repoStatusOverlayProvider(_repo).overrideWith((ref) => _overlay),
        ],
        child: MacosApp(
          debugShowCheckedModeBanner: false,
          home: SecondaryWindowScope(
            child: SizedBox(
              width: 900,
              height: 600,
              child: Align(
                alignment: Alignment.centerRight,
                child: FileView(
                  maxWidth: 900,
                  repoPath: _repo,
                  onOpenFile:
                      (
                        _, {
                        required staged,
                        required untracked,
                        required conflict,
                      }) {},
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(TransparentMacOSSidebar), findsNothing);
    expect(find.text('main.dart'), findsOneWidget); // the tree still renders
  });

  testWidgets('the main window keeps the vibrancy sidebar', (tester) async {
    await _pump(
      tester,
      onOpenFile:
          (_, {required staged, required untracked, required conflict}) {},
    );
    expect(find.byType(TransparentMacOSSidebar), findsOneWidget);
  });

  testWidgets('clicking a conflicted file reports conflict, not staged', (
    tester,
  ) async {
    ({bool staged, bool untracked, bool conflict})? opened;
    await _pump(
      tester,
      overlay: _overlayConflict,
      onOpenFile:
          (path, {required staged, required untracked, required conflict}) =>
              opened = (
                staged: staged,
                untracked: untracked,
                conflict: conflict,
              ),
    );

    await tester.tap(find.text('main.dart'));
    await tester.pumpAndSettle();

    expect(opened, (staged: false, untracked: false, conflict: true));
  });

  testWidgets('clicking a changed file invokes onOpenFile', (tester) async {
    String? opened;
    await _pump(
      tester,
      onOpenFile:
          (path, {required staged, required untracked, required conflict}) =>
              opened = path,
    );

    await tester.tap(find.text('main.dart'));
    await tester.pump();
    expect(opened, 'lib/main.dart');
  });

  testWidgets('clicking an untracked file opens it as untracked', (
    tester,
  ) async {
    bool? untrackedFlag;
    await _pump(
      tester,
      onOpenFile:
          (path, {required staged, required untracked, required conflict}) {
            if (path == 'todo.txt') untrackedFlag = untracked;
          },
    );

    // A new file shows a green 'U' and opens via the untracked diff path.
    expect(find.text('U'), findsOneWidget);
    await tester.tap(find.text('todo.txt'));
    await tester.pump();
    expect(untrackedFlag, isTrue);
  });

  testWidgets('expanding a clean directory toggles its children', (
    tester,
  ) async {
    await _pump(
      tester,
      onOpenFile:
          (_, {required staged, required untracked, required conflict}) {},
    );

    expect(find.text('readme.md'), findsNothing);
    await tester.tap(find.text('docs'));
    await tester.pumpAndSettle();
    expect(find.text('readme.md'), findsOneWidget);

    await tester.tap(find.text('docs'));
    await tester.pumpAndSettle();
    expect(find.text('readme.md'), findsNothing);
  });

  testWidgets(
    'clicking a clean tracked file still opens it (staged/untracked both '
    'false), instead of silently doing nothing',
    (tester) async {
      String? opened;
      bool? openedStaged;
      bool? openedUntracked;
      await _pump(
        tester,
        onOpenFile:
            (path, {required staged, required untracked, required conflict}) {
              opened = path;
              openedStaged = staged;
              openedUntracked = untracked;
            },
      );

      // readme.md is clean and under the collapsed 'docs' dir.
      await tester.tap(find.text('docs'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('readme.md'));
      await tester.pump();

      expect(opened, 'docs/readme.md');
      expect(openedStaged, isFalse);
      expect(openedUntracked, isFalse);
    },
  );

  testWidgets(
    'a partially-staged file offers a context-menu toggle for its staged '
    'half, which the default click does not show',
    (tester) async {
      final events = <({bool staged, bool untracked})>[];
      final container = ProviderContainer(
        overrides: [
          repoStructureProvider(_repo).overrideWith((ref) async => _fixture()),
          repoStatusOverlayProvider(_repo).overrideWith((ref) => _overlayMixed),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MacosApp(
            debugShowCheckedModeBanner: false,
            // The context menu is anchored at the right-click's actual screen
            // position and extends further right from there. MacosApp's home
            // slot stretches its child to fill the whole viewport, so a plain
            // `Align(centerRight)` pane sits flush against the *viewport's*
            // right edge with zero margin — leaving no room for a menu that
            // opens rightward. A trailing spacer here reserves that room,
            // independent of viewport size.
            home: Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 600,
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: FileView(
                        maxWidth: 900,
                        repoPath: _repo,
                        onOpenFile:
                            (
                              path, {
                              required staged,
                              required untracked,
                              required conflict,
                            }) => events.add((
                              staged: staged,
                              untracked: untracked,
                            )),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 300),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // A plain click defaults to the unstaged half.
      await tester.tap(find.text('main.dart'));
      await tester.pump();
      expect(events.single, (staged: false, untracked: false));

      // Right-click offers the explicit toggle.
      await tester.tap(find.text('main.dart'), buttons: kSecondaryMouseButton);
      await tester.pumpAndSettle();
      expect(find.text('Staged changes'), findsOneWidget);
      expect(find.text('Unstaged changes'), findsOneWidget);

      await tester.tap(find.text('Staged changes'));
      await tester.pump();
      expect(events.last, (staged: true, untracked: false));
    },
  );

  testWidgets(
    'the context menu clamps on-screen when the pane sits flush against the '
    "window's edge (its real, docked-at-the-right layout) — every item stays "
    'reachable instead of opening clipped off-window',
    (tester) async {
      String? opened;
      bool? openedStaged;
      // Mixed status so all 4 rows show — the widest menu this pane ever
      // opens, and thus the most likely to clip if unclamped.
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            repoStructureProvider(
              _repo,
            ).overrideWith((ref) async => _fixture()),
            repoStatusOverlayProvider(
              _repo,
            ).overrideWith((ref) => _overlayMixed),
          ],
          child: MacosApp(
            debugShowCheckedModeBanner: false,
            // No trailing spacer — the pane's right edge sits exactly at the
            // window edge, same as production.
            home: Align(
              alignment: Alignment.centerRight,
              child: FileView(
                maxWidth: 900,
                repoPath: _repo,
                onOpenFile:
                    (
                      path, {
                      required staged,
                      required untracked,
                      required conflict,
                    }) {
                      opened = path;
                      openedStaged = staged;
                    },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('main.dart'), buttons: kSecondaryMouseButton);
      await tester.pumpAndSettle();

      // Every row must actually be reachable, not just present in the tree —
      // findsOneWidget alone wouldn't catch an off-screen clip. "Unstaged
      // changes" is the second row (would sit right at the edge if the whole
      // card merely got nudged rather than properly clamped).
      expect(find.text('Staged changes'), findsOneWidget);
      expect(find.text('Unstaged changes'), findsOneWidget);
      expect(find.text('Blame'), findsOneWidget);
      expect(find.text('File history'), findsOneWidget);

      await tester.tap(find.text('Unstaged changes'));
      await tester.pump();
      expect(opened, 'lib/main.dart');
      expect(openedStaged, isFalse);
    },
  );

  testWidgets('a status-only change recolors without resetting the tree', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [
        repoStructureProvider(_repo).overrideWith((ref) async => _fixture()),
        repoStatusOverlayProvider(
          _repo,
        ).overrideWith((ref) => ref.watch(_overlaySource)),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MacosApp(
          debugShowCheckedModeBanner: false,
          home: SizedBox(
            width: 900,
            height: 600,
            child: Align(
              alignment: Alignment.centerRight,
              child: FileView(
                maxWidth: 900,
                repoPath: _repo,
                onOpenFile:
                    (
                      _, {
                      required staged,
                      required untracked,
                      required conflict,
                    }) {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Manually expand 'docs' so we can prove the expansion survives a refresh.
    await tester.tap(find.text('docs'));
    await tester.pumpAndSettle();
    expect(find.text('readme.md'), findsOneWidget);
    expect(_folderColor(tester, 'docs'), MacosColors.systemBlueColor);

    // A status-only refresh: docs becomes dirty. The structure provider does
    // not change, so the tree keeps identity — expansion is preserved and only
    // the color updates.
    container.read(_overlaySource.notifier).set(_overlayDocsDirty);
    await tester.pumpAndSettle();

    expect(find.text('readme.md'), findsOneWidget); // still expanded
    expect(_folderColor(tester, 'docs'), MacosColors.systemGreenColor);
  });

  testWidgets(
    'right-click offers "View file", which opens a viewer window — available '
    'even for an untracked file (unlike Blame / File history)',
    (tester) async {
      final container = ProviderContainer(
        overrides: [
          repoStructureProvider(_repo).overrideWith((ref) async => _fixture()),
          repoStatusOverlayProvider(_repo).overrideWith((ref) => _overlay),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MacosApp(
            debugShowCheckedModeBanner: false,
            home: Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 600,
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: FileView(
                        maxWidth: 900,
                        repoPath: _repo,
                        onOpenFile:
                            (
                              _, {
                              required staged,
                              required untracked,
                              required conflict,
                            }) {},
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 300),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // todo.txt is untracked — Blame/File history are disabled for it, but
      // View file is offered and enabled.
      await tester.tap(find.text('todo.txt'), buttons: kSecondaryMouseButton);
      await tester.pumpAndSettle();
      expect(find.text('View file'), findsOneWidget);
      expect(container.read(openFileViewersProvider), isEmpty);

      await tester.tap(find.text('View file'));
      await tester.pumpAndSettle();

      final open = container.read(openFileViewersProvider);
      expect(open.length, 1);
      expect(open.single.repoPath, _repo);
      expect(open.single.path, 'todo.txt');
    },
  );

  testWidgets(
    'right-click highlights the file, so the menu target is unambiguous',
    (tester) async {
      await _pump(
        tester,
        onOpenFile:
            (_, {required staged, required untracked, required conflict}) {},
      );

      // Untouched, the row is not highlighted.
      expect(_tileColor(tester, 'lib/main.dart'), const Color(0x00000000));

      // Right-clicking selects it (like a left-click, like Finder) while the
      // menu is open.
      await tester.tap(find.text('main.dart'), buttons: kSecondaryMouseButton);
      await tester.pumpAndSettle();

      expect(find.text('View file'), findsOneWidget); // menu is open
      expect(
        _tileColor(tester, 'lib/main.dart'),
        MacosColors.systemBlueColor.withValues(alpha: 0.15),
      );
    },
  );

  group('right-click gitignore / delete', () {
    // A file-tree fixture whose `build/` dir is git-ignored, so the
    // "Add to .gitignore" visibility rule (hidden for already-ignored files)
    // can be exercised alongside a plain, not-ignored file.
    RepoNode fixtureWithIgnored() => const RepoNode(
      name: '',
      path: '',
      isDir: true,
      children: [
        RepoNode(name: 'todo.txt', path: 'todo.txt', isDir: false),
        RepoNode(
          name: 'build',
          path: 'build',
          isDir: true,
          ignored: true,
          children: [
            RepoNode(
              name: 'out.o',
              path: 'build/out.o',
              isDir: false,
              ignored: true,
            ),
          ],
        ),
      ],
    );

    Future<ProviderContainer> pumpWithGit(
      WidgetTester tester,
      _RecordingGit git, {
      RepoStatusOverlay? overlay,
    }) async {
      final container = ProviderContainer(
        overrides: [
          gitServiceProvider.overrideWithValue(git),
          repoStructureProvider(
            _repo,
          ).overrideWith((ref) async => fixtureWithIgnored()),
          repoStatusOverlayProvider(
            _repo,
          ).overrideWith((ref) => overlay ?? _overlay),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MacosApp(
            debugShowCheckedModeBanner: false,
            // A trailing spacer reserves room for the menu to open rightward,
            // same as the "View file" test above.
            home: Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 600,
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: FileView(
                        maxWidth: 900,
                        repoPath: _repo,
                        onOpenFile:
                            (
                              _, {
                              required staged,
                              required untracked,
                              required conflict,
                            }) {},
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 300),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return container;
    }

    testWidgets(
      'a conflicted file offers Mark Resolved, which runs git add (0009 H6)',
      (tester) async {
        final git = _RecordingGit();
        const overlay = RepoStatusOverlay(
          dirtyDirs: {},
          changed: {
            'todo.txt': GitFileStatus(
              path: 'todo.txt',
              statusX: 'U',
              statusY: 'U',
            ),
          },
          untrackedDirs: {},
        );
        await pumpWithGit(tester, git, overlay: overlay);

        await tester.tap(find.text('todo.txt'), buttons: kSecondaryMouseButton);
        await tester.pumpAndSettle();
        expect(find.text('Mark Resolved'), findsOneWidget);
        // A UU file reads as staged+unstaged at once — it must not get the
        // mixed-file staged/unstaged toggle.
        expect(find.text('Staged changes'), findsNothing);

        await tester.tap(find.text('Mark Resolved'));
        await tester.pumpAndSettle();
        expect(git.staged, [(_repo, 'todo.txt')]);
      },
    );

    testWidgets('"Add to .gitignore" appends the file via GitService', (
      tester,
    ) async {
      final git = _RecordingGit();
      await pumpWithGit(tester, git);

      await tester.tap(find.text('todo.txt'), buttons: kSecondaryMouseButton);
      await tester.pumpAndSettle();
      expect(find.text('Add to .gitignore'), findsOneWidget);

      await tester.tap(find.text('Add to .gitignore'));
      await tester.pumpAndSettle();
      expect(git.ignored, [(_repo, 'todo.txt')]);
    });

    testWidgets('"Add to .gitignore" is hidden for an already-ignored file', (
      tester,
    ) async {
      final git = _RecordingGit();
      await pumpWithGit(tester, git);

      // build/ is ignored and expands lazily; its ignored child out.o must not
      // offer to re-ignore itself.
      await tester.tap(find.text('build'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('out.o'), buttons: kSecondaryMouseButton);
      await tester.pumpAndSettle();

      expect(find.text('Delete File'), findsOneWidget);
      expect(find.text('Add to .gitignore'), findsNothing);
    });

    testWidgets(
      'Delete File confirms with the honest snapshot/undo copy; Cancel is a '
      'no-op (0009 L9)',
      (tester) async {
        final git = _RecordingGit();
        await pumpWithGit(tester, git);

        await tester.tap(find.text('todo.txt'), buttons: kSecondaryMouseButton);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Delete File'));
        await tester.pumpAndSettle();

        // The service snapshots before removing, so the copy matches the
        // discard/undo convention — never "This action is permanent!".
        expect(
          find.text(
            'Delete "todo.txt"? Its content is snapshotted first — '
            'press ⌘Z to undo, or restore it later from the Recovery view.',
          ),
          findsOneWidget,
        );
        expect(find.textContaining('permanent'), findsNothing);

        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(git.deleted, isEmpty);
      },
    );

    testWidgets('Delete File → confirm deletes the file via GitService', (
      tester,
    ) async {
      final git = _RecordingGit();
      await pumpWithGit(tester, git);

      await tester.tap(find.text('todo.txt'), buttons: kSecondaryMouseButton);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete File'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(git.deleted, [(_repo, 'todo.txt')]);
    });

    testWidgets('the Delete File row is tinted red', (tester) async {
      final git = _RecordingGit();
      await pumpWithGit(tester, git);

      await tester.tap(find.text('todo.txt'), buttons: kSecondaryMouseButton);
      await tester.pumpAndSettle();

      // The trash icon shares its row with the "Delete File" label; find the
      // MacosIcon that is the trash can and assert its red tint.
      final trash = tester
          .widgetList<MacosIcon>(find.byType(MacosIcon))
          .where((i) => i.icon == CupertinoIcons.trash);
      expect(trash, isNotEmpty);
      expect(trash.every((i) => i.color == MacosColors.systemRedColor), isTrue);
    });
  });

  group('_loadLazy repo-identity race', () {
    // A single lazy ignored directory, shared by both repos' fixtures below —
    // the collision that used to let a slower repo's response overwrite a
    // faster one's, keyed only by this shared relative path.
    RepoNode fixtureWithLazyDir() => const RepoNode(
      name: '',
      path: '',
      isDir: true,
      children: [
        RepoNode(
          name: 'vendor',
          path: 'vendor',
          isDir: true,
          ignored: true,
          lazy: true,
        ),
      ],
    );

    testWidgets(
      'a slower repo-A lazy-load response landing after switching to repo B '
      "does not overwrite repo B's own lazy children",
      (tester) async {
        const repoB = '/srv/repo-b';
        final gates = <String, Completer<List<RepoNode>>>{
          _repo: Completer<List<RepoNode>>(),
          repoB: Completer<List<RepoNode>>(),
        };
        final git = _GatedListIgnoredChildrenGit(gates);

        final container = ProviderContainer(
          overrides: [
            gitServiceProvider.overrideWithValue(git),
            repoStructureProvider(
              _repo,
            ).overrideWith((ref) async => fixtureWithLazyDir()),
            repoStatusOverlayProvider(
              _repo,
            ).overrideWith((ref) => RepoStatusOverlay.empty),
            repoStructureProvider(
              repoB,
            ).overrideWith((ref) async => fixtureWithLazyDir()),
            repoStatusOverlayProvider(
              repoB,
            ).overrideWith((ref) => RepoStatusOverlay.empty),
          ],
        );
        addTearDown(container.dispose);

        Widget host(String repoPath) => UncontrolledProviderScope(
          container: container,
          child: MacosApp(
            debugShowCheckedModeBanner: false,
            home: SizedBox(
              width: 900,
              height: 600,
              child: Align(
                alignment: Alignment.centerRight,
                child: FileView(
                  maxWidth: 900,
                  repoPath: repoPath,
                  onOpenFile:
                      (
                        _, {
                        required staged,
                        required untracked,
                        required conflict,
                      }) {},
                ),
              ),
            ),
          ),
        );

        // Expand 'vendor' under repo A — kicks off a request that never
        // completes until its gate is released below.
        await tester.pumpWidget(host(_repo));
        await tester.pumpAndSettle();
        await tester.tap(find.text('vendor'));
        await tester.pump();

        // Switch to repo B (didUpdateWidget resets _lazyChildren/_lazyLoading)
        // and expand its own 'vendor' — a second, independent request.
        await tester.pumpWidget(host(repoB));
        await tester.pumpAndSettle();
        await tester.tap(find.text('vendor'));
        await tester.pump();

        // Repo B's request resolves first.
        gates[repoB]!.complete([
          const RepoNode(
            name: 'b-only.txt',
            path: 'vendor/b-only.txt',
            isDir: false,
            ignored: true,
          ),
        ]);
        await tester.pumpAndSettle();
        expect(find.text('b-only.txt'), findsOneWidget);

        // Repo A's slower, now-stale request finally resolves — it must not
        // clobber repo B's already-displayed children.
        gates[_repo]!.complete([
          const RepoNode(
            name: 'a-only.txt',
            path: 'vendor/a-only.txt',
            isDir: false,
            ignored: true,
          ),
        ]);
        await tester.pumpAndSettle();

        expect(find.text('b-only.txt'), findsOneWidget);
        expect(find.text('a-only.txt'), findsNothing);
      },
    );
  });

  testWidgets(
    'a not-logged-in tree error is shown once forge login has settled',
    (tester) async {
      SharedPreferences.setMockInitialValues(const {});
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            repoStructureProvider(_repo).overrideWith(
              (ref) async => throw const GitException(
                'git ls-files failed',
                SSHCommandResult(
                  exitCode: 128,
                  stdout: '',
                  stderr: 'glab: not logged in',
                ),
              ),
            ),
            repoStatusOverlayProvider(_repo).overrideWith((ref) => _overlay),
          ],
          child: MacosApp(
            debugShowCheckedModeBanner: false,
            home: SizedBox(
              width: 900,
              height: 600,
              child: Align(
                alignment: Alignment.centerRight,
                child: FileView(
                  maxWidth: 900,
                  repoPath: _repo,
                  onOpenFile:
                      (
                        _, {
                        required staged,
                        required untracked,
                        required conflict,
                      }) {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('not logged in'), findsOneWidget);
    },
  );
}

/// Records the right-click mutation calls (add-to-.gitignore / delete) without
/// touching SSH, so the menu wiring can be asserted in isolation.
class _RecordingGit extends GitService {
  _RecordingGit() : super(SSHCommandExecutor(SSHClientManager()));
  final List<(String, String)> ignored = [];
  final List<(String, String)> deleted = [];
  final List<(String, String)> staged = [];

  @override
  Future<void> addToGitignore(String repoPath, String path) async =>
      ignored.add((repoPath, path));

  @override
  Future<void> deleteFile(String repoPath, String path) async =>
      deleted.add((repoPath, path));

  @override
  Future<void> stage(String repoPath, String path) async =>
      staged.add((repoPath, path));
}

/// listIgnoredChildren resolves via a per-repoPath gate the test controls,
/// so a request issued under one repo can be made to resolve strictly after
/// a later request issued under a different repo.
class _GatedListIgnoredChildrenGit extends GitService {
  _GatedListIgnoredChildrenGit(this._gates)
    : super(SSHCommandExecutor(SSHClientManager()));
  final Map<String, Completer<List<RepoNode>>> _gates;

  @override
  Future<List<RepoNode>> listIgnoredChildren(String repoPath, String dir) =>
      _gates[repoPath]!.future;
}
