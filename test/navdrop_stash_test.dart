// B1/B2 dispatch: dragging working-copy files onto Stashes runs a partial
// stash, and dragging a stash onto Repository offers apply/pop. The path runs
// through the drag source -> DropZone -> registry -> action handler; the git
// service is faked so nothing real runs.

import 'package:flutter/cupertino.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/features/dnd/drag_item.dart';
import 'package:remote_magic_git/features/dnd/drop_registry.dart';
import 'package:remote_magic_git/features/dnd/nav_rail.dart';

const _repo = '/srv/repo';

class _FakeConnection extends ConnectionController {
  @override
  ConnectionState build() =>
      const ConnectionState(phase: ConnectionPhase.connected, repoPath: _repo);
}

/// Records the stash calls the drops make, so tests assert on the args rather
/// than reaching a real executor.
class _RecordingGit extends GitService {
  _RecordingGit() : super(SSHCommandExecutor(SSHClientManager()));

  List<String>? pushedPaths;
  bool? pushedUntracked;

  @override
  Future<SSHCommandResult> stashPush(
    String repoPath, {
    String? message,
    bool includeUntracked = false,
    List<String> paths = const [],
  }) async {
    pushedPaths = paths;
    pushedUntracked = includeUntracked;
    return const SSHCommandResult(stdout: '', stderr: '', exitCode: 0);
  }
}

const _files = DragFiles(['lib/a.dart', 'lib/b.dart']);

const _stash = DragStash(
  GitStash(
    index: 0,
    oid: 'deadbeefdeadbeef',
    branch: 'main',
    message: 'WIP on main: 1234567 in-progress work',
  ),
);

const _items = [
  NavRailItem(
    icon: CupertinoIcons.folder,
    label: 'Repository',
    zone: DropZoneId.repository,
  ),
  NavRailItem(
    icon: CupertinoIcons.tray_2,
    label: 'Stashes',
    zone: DropZoneId.stashes,
  ),
];

Future<void> _dragOnto(
  WidgetTester tester,
  Finder source,
  Finder target,
) async {
  final from = tester.getCenter(source);
  final to = tester.getCenter(target);
  final gesture = await tester.startGesture(from);
  await tester.pump(const Duration(milliseconds: 100));
  await gesture.moveBy(const Offset(0, -20)); // exceed touch slop
  await tester.pump();
  await gesture.moveTo(to);
  await tester.pump();
  await gesture.up();
  await tester.pumpAndSettle();
}

Future<void> _pump(WidgetTester tester, GitService git, DragItem item) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        connectionProvider.overrideWith(_FakeConnection.new),
        gitServiceProvider.overrideWithValue(git),
      ],
      child: MacosApp(
        debugShowCheckedModeBanner: false,
        home: Row(
          children: [
            DragItemDraggable(
              item: item,
              immediate: true,
              child: const SizedBox(
                width: 120,
                height: 44,
                child: Center(child: Text('SOURCE')),
              ),
            ),
            SizedBox(
              width: 240,
              height: 600,
              child: NavRail(
                currentIndex: 0,
                onChanged: (_) {},
                items: _items,
                selectPage: (_) {},
                refresh: () {},
              ),
            ),
          ],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('dropping files on Stashes runs a partial stash of those paths', (
    tester,
  ) async {
    final git = _RecordingGit();
    await _pump(tester, git, _files);
    await _dragOnto(tester, find.text('SOURCE'), find.text('Stashes'));

    // The single non-destructive action ran immediately: exactly the dropped
    // paths, with untracked included so a brand-new file could be dragged too.
    expect(git.pushedPaths, ['lib/a.dart', 'lib/b.dart']);
    expect(git.pushedUntracked, isTrue);
  });

  testWidgets('dropping a stash on Repository offers apply and pop', (
    tester,
  ) async {
    final git = _RecordingGit();
    await _pump(tester, git, _stash);
    await _dragOnto(tester, find.text('SOURCE'), find.text('Repository'));

    // Two safe choices -> the verb menu (no git runs until one is chosen).
    expect(find.textContaining('Apply stash@{0}'), findsOneWidget);
    expect(find.textContaining('Pop stash@{0}'), findsOneWidget);
  });
}
