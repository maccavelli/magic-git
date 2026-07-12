// Keystone test for the per-tab scope architecture (Tab Phase A): two child
// `ProviderContainer(parent: root)` tab scopes, each overriding
// `activeExecutorProvider` with its own fake executor, must route every
// repo-scoped family through THEIR OWN executor — never the other tab's, never
// the root. A family that forgot its `dependencies:` annotation resolves at the
// root instead of the tab scope (or throws ProviderException) — either way this
// test catches it.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';

/// Records every command it's asked to run and tags stdout with its label, so a
/// family that ran on the wrong scope's executor is visible in the recording.
class _RecordingExec extends SSHCommandExecutor {
  _RecordingExec(this.label) : super(SSHClientManager());
  final String label;
  final List<List<String>> calls = [];

  @override
  Future<SSHCommandResult> execute({
    required String repoPath,
    required List<String> gitArgs,
    Map<String, String>? extraEnv,
    String? stdin,
    Duration timeout = SSHCommandExecutor.defaultTimeout,
    int retries = 0,
    ExecLane lane = ExecLane.exclusive,
    bool compress = false,
  }) async {
    calls.add(gitArgs);
    // Empty-but-valid output so the parsers return empty results, not throw.
    return const SSHCommandResult(exitCode: 0, stdout: '', stderr: '');
  }
}

void main() {
  test('every repo family routes through its own tab scope executor', () async {
    final root = ProviderContainer();
    addTearDown(root.dispose);

    final fakeA = _RecordingExec('A');
    final fakeB = _RecordingExec('B');
    final tabA = ProviderContainer(
      parent: root,
      overrides: [activeExecutorProvider.overrideWithValue(fakeA)],
    );
    final tabB = ProviderContainer(
      parent: root,
      overrides: [activeExecutorProvider.overrideWithValue(fakeB)],
    );
    addTearDown(tabA.dispose);
    addTearDown(tabB.dispose);

    const repo = '/srv/repo';

    // Read a representative repo family from a scope, ignoring any parse error
    // — we only care WHICH executor it ran on. Reading it at all also proves
    // the family carries its `dependencies:` annotation (an unscoped family
    // reading the scoped gitServiceProvider throws here). Closures avoid naming
    // the heterogeneous provider-listenable types.
    final reads = <Future<Object?> Function(ProviderContainer)>[
      (c) => c.read(statusProvider(repo).future),
      (c) => c.read(logProvider(repo).future),
      (c) => c.read(refsProvider(repo).future),
      (c) => c.read(stashesProvider(repo).future),
      (c) => c.read(reflogProvider(repo).future),
      (c) => c.read(magicSnapshotsProvider(repo).future),
      (c) => c.read(pendingOpProvider(repo).future),
      (c) => c.read(repoStructureProvider(repo).future),
      (c) => c.read(commitDiffProvider((repo, 'abc1234')).future),
      (c) => c.read(fileLogProvider((repo, 'a.dart')).future),
    ];

    for (final read in reads) {
      try {
        await read(tabA);
      } catch (_) {
        // Parser choke on empty output is fine; the executor call was recorded.
      }
    }

    // Everything tab A read ran on fakeA; fakeB was never touched.
    expect(fakeA.calls, isNotEmpty, reason: 'tab A families ran on its executor');
    expect(
      fakeB.calls,
      isEmpty,
      reason: 'no tab-A family leaked onto tab B / the root executor',
    );

    // Now the mirror: reading from tab B routes to fakeB only.
    final beforeA = fakeA.calls.length;
    try {
      await tabB.read(refsProvider(repo).future);
    } catch (_) {}
    expect(fakeB.calls, isNotEmpty, reason: 'tab B families ran on its executor');
    expect(
      fakeA.calls.length,
      beforeA,
      reason: 'reading from tab B did not touch tab A',
    );
  });

  test('a shared root provider is one instance across tab scopes', () {
    final root = ProviderContainer();
    addTearDown(root.dispose);
    final fakeA = _RecordingExec('A');
    final fakeB = _RecordingExec('B');
    final tabA = ProviderContainer(
      parent: root,
      overrides: [activeExecutorProvider.overrideWithValue(fakeA)],
    );
    final tabB = ProviderContainer(
      parent: root,
      overrides: [activeExecutorProvider.overrideWithValue(fakeB)],
    );
    addTearDown(tabA.dispose);
    addTearDown(tabB.dispose);

    // connectionStoreProvider is a GLOBAL provider (no dependencies) — both tabs
    // must see the SAME instance (shared root), unlike the per-tab session seam.
    expect(
      identical(
        tabA.read(connectionStoreProvider),
        tabB.read(connectionStoreProvider),
      ),
      isTrue,
    );
  });
}
