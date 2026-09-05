// A refresh must not blank the panel.
//
// Since 0025 Phase 7, `statusProvider` derives from `repoSnapshotProvider`, so
// invalidating the snapshot makes the derived provider RELOAD rather than
// refresh. `AsyncValue.when` skips the loading branch on a refresh
// (`skipLoadingOnRefresh` defaults to true) but NOT on a reload
// (`skipLoadingOnReload` defaults to false) — so every post-mutation refresh
// replaced the whole panel with a spinner while the previous data was still
// held. Observed in production as the repository panel "blinking constantly",
// once a degraded watcher started refreshing every few seconds.

import 'dart:async';

import 'package:flutter/cupertino.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/git/repo_tree.dart';
import 'package:remote_magic_git/core/git/watch_event.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/core/utils/git_porcelain_parser.dart';
import 'package:remote_magic_git/features/repository/repo_status_view.dart';

const _repo = '/srv/repo';

class _Git extends GitService {
  _Git() : super(SSHCommandExecutor(SSHClientManager()));
  @override
  Future<List<GitCommit>> log(
    String repoPath, {
    String revision = 'HEAD',
    int maxCount = 200,
    int skip = 0,
    String? grep,
    String? author,
    String? since,
    String? until,
    String? path,
    String? pathQuery,
    String? sha,
    bool all = false,
    bool follow = false,
    bool noMerges = false,
    bool fullHistory = false,
  }) async => const [];
}

class _StubConnection extends ConnectionController {
  _StubConnection(this._state);
  final ConnectionState _state;
  @override
  ConnectionState build() => _state;
}

RepoSnapshot _snap() => RepoSnapshot(
  status: GitStatus(
    branch: const GitBranchInfo(),
    files: const [
      GitFileStatus(path: 'lib/a.dart', statusX: '.', statusY: 'M'),
    ],
  ),
  refs: const [],
  pendingOp: PendingOp.none,
);

void main() {
  testWidgets('a snapshot refresh does not blank the status panel', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    Completer<void>? gate;
    final container = ProviderContainer(
      overrides: [
        gitServiceProvider.overrideWithValue(_Git()),
        repoSnapshotProvider(_repo).overrideWith((ref) async {
          // Held open so the assertion happens while the refetch is genuinely
          // in flight, then released so no timer outlives the tree.
          if (gate != null) await gate.future;
          return _snap();
        }),
        repoWatchProvider(
          _repo,
        ).overrideWith((ref) => const Stream<RepoWatchEvent>.empty()),
        repoStructureProvider(_repo).overrideWith(
          (ref) async =>
              const RepoNode(name: '', path: '', isDir: true, children: []),
        ),
        connectionProvider.overrideWith(
          () => _StubConnection(
            const ConnectionState(backend: ConnectionBackend.ssh),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MacosApp(
          debugShowCheckedModeBanner: false,
          home: RepoStatusView(repoPath: _repo),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.text('lib/a.dart'),
      findsWidgets,
      reason: 'the panel loaded once',
    );

    // The refresh every mutation and every watcher tick performs.
    gate = Completer<void>();
    container.invalidate(repoSnapshotProvider(_repo));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));

    expect(
      find.text('lib/a.dart'),
      findsWidgets,
      reason:
          'the previous status is still held (hasValue is true) and must stay '
          'on screen while the refetch is in flight — replacing it with a '
          'spinner is what made the panel blink on every tick',
    );

    gate.complete();
    await tester.pumpAndSettle();
    expect(find.text('lib/a.dart'), findsWidgets, reason: 'and after it lands');
  });
}
