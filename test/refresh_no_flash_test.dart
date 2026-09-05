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
import 'dart:io';

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

  // ---- the guard --------------------------------------------------------
  //
  // The behavioural test above proves the property for one panel. This stops a
  // NEW render site from shipping without it, which is how both of the
  // affected sites got there: they predated Phase 7, which changed refresh
  // into reload underneath them.

  test(
    'every .when() on a snapshot-derived provider skips loading on reload',
    () {
      // The derived set is read from source, not hardcoded — a hardcoded list
      // would silently stop covering a provider that starts deriving later.
      final providersSrc = File(
        'lib/core/providers/app_providers.dart',
      ).readAsStringSync();
      final derived = <String>{};
      final decls = RegExp(
        r'^final (\w+Provider)\s*=',
        multiLine: true,
      ).allMatches(providersSrc).toList();
      for (var i = 0; i < decls.length; i++) {
        final start = decls[i].start;
        final end = i + 1 < decls.length
            ? decls[i + 1].start
            : providersSrc.length;
        if (providersSrc
            .substring(start, end)
            .contains('repoSnapshotProvider(')) {
          derived.add(decls[i][1]!);
        }
      }
      expect(
        derived,
        isNotEmpty,
        reason: 'the scan must find the derived providers at all',
      );

      final offenders = <String>[];
      for (final f
          in Directory('lib/features')
              .listSync(recursive: true)
              .whereType<File>()
              .where((f) => f.path.endsWith('.dart'))) {
        final src = f.readAsStringSync();
        for (final m in RegExp(
          r'final\s+(\w+)\s*=\s*ref\.watch\((\w+Provider)\(',
        ).allMatches(src)) {
          if (!derived.contains(m[2])) continue;
          final varName = m[1]!;
          for (final w in RegExp('\\b$varName\\.when\\(').allMatches(src)) {
            // Look at the next 40 LINES, not a byte count. A char window is
            // the wrong unit and said so loudly: at 500 chars this reported
            // repo_status_view as an offender when the flag WAS present but
            // sat behind an eight-line comment explaining why it is there.
            final window = src.substring(w.end).split('\n').take(40).join('\n');
            if (!window.contains('skipLoadingOnReload')) {
              final line =
                  '\n'.allMatches(src.substring(0, w.start)).length + 1;
              offenders.add('${f.path}:$line  $varName.when() on ${m[2]}');
            }
          }
        }
      }

      expect(
        offenders,
        isEmpty,
        reason:
            'these render a value derived from repoSnapshotProvider through '
            '.when() without skipLoadingOnReload, so every refresh replaces them '
            'with a spinner while the previous data is still held:\n'
            '${offenders.join('\n')}',
      );
    },
  );
}
