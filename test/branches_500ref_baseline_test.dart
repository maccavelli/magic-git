// Phase 0 baseline: capture command count for 500-ref Browse paint.
// This establishes the performance envelope before Phase 1 adds comparison
// providers. Phase 7 will verify that Browse stays within this envelope.

import 'dart:typed_data';

import 'package:flutter/gestures.dart' show PointerScrollEvent;
import 'package:flutter/widgets.dart' show ListView;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/forge/branch_forge_status.dart';
import 'package:remote_magic_git/core/git/branch_comparison.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/core/utils/git_porcelain_parser.dart';
import 'package:remote_magic_git/features/branches/branches_view.dart';

const _repo = '/repo';
const _mainOid = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

/// Generates [count] fake local branch refs plus a few remotes and tags.
List<GitRef> _generateRefs({int localCount = 500}) {
  final refs = <GitRef>[
    const GitRef(
      name: 'refs/heads/main',
      oid: _mainOid,
      isHead: true,
      subject: 'main branch',
    ),
  ];

  // Local branches with realistic divergence patterns.
  for (var i = 0; i < localCount; i++) {
    final name = 'feature/$i';
    refs.add(
      GitRef(
        name: 'refs/heads/$name',
        oid: 'oid_${i.toRadixString(16).padLeft(40, '0')}',
        isHead: false,
        subject: 'commit on $name',
        ahead: i % 10,
        behind: (i % 5) * 2,
        upstream: i % 3 == 0 ? 'origin/$name' : null,
      ),
    );
  }

  // Remote branches.
  for (var i = 0; i < 50; i++) {
    refs.add(
      GitRef(
        name: 'refs/remotes/origin/feature/$i',
        oid: 'oid_${i.toRadixString(16).padLeft(40, '0')}',
        isHead: false,
        subject: 'remote commit',
      ),
    );
  }

  // Tags.
  for (var i = 0; i < 20; i++) {
    refs.add(
      GitRef(
        name: 'refs/tags/v1.$i',
        oid: 'tag_${i.toRadixString(16).padLeft(40, '0')}',
        isHead: false,
        subject: 'tag $i',
      ),
    );
  }

  return refs;
}

class _CountingExecutor implements CommandExecutor {
  final List<String> commands = [];

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
    commands.add(gitArgs.join(' '));
    // Return empty success for any command — we're just counting invocations.
    return const SSHCommandResult(exitCode: 0, stdout: '', stderr: '');
  }

  @override
  Future<SSHStreamHandle> executeStream({
    required String repoPath,
    required List<String> gitArgs,
    Map<String, String>? extraEnv,
    Duration openTimeout = SSHCommandExecutor.defaultTimeout,
  }) async {
    throw UnimplementedError('Stream execution not needed for baseline test');
  }

  @override
  Future<void> uploadBytes(String remotePath, Uint8List bytes) async {
    throw UnimplementedError('Upload not needed for baseline test');
  }

  @override
  void configureEnvironment({
    String? path,
    Map<String, String> binaries = const {},
  }) {}

  @override
  String? resolvedBinaryPath(String name) => null;

  @override
  void setForgeTokenNeutralization(Iterable<String> vars) {}

  @override
  void resetEnvironment() {}
}

void main() {
  testWidgets('500-ref Browse first paint command count', (tester) async {
    final refs = _generateRefs(localCount: 500);
    final exec = _CountingExecutor();
    final git = GitService(exec);

    final container = ProviderContainer(
      overrides: [
        gitServiceProvider.overrideWithValue(git),
        refsProvider(_repo).overrideWith((ref) async => refs),
        remotesProvider(_repo).overrideWith((ref) async => const ['origin']),
        remoteTagsProvider(_repo).overrideWith((ref) async => null),
        branchForgeProvider(_repo).overrideWith((ref) async => const {}),
        mergedBranchesProvider(_repo).overrideWith((ref) async => const {}),
        // Stub base/status so the list baseline is not dominated by base
        // discovery. Comparison (rev-list / merge-tree / patch) must stay zero.
        statusProvider(_repo).overrideWith(
          (ref) async => GitStatus(
            branch: const GitBranchInfo(head: 'main', oid: _mainOid),
            files: const [],
          ),
        ),
        branchBaseProvider.overrideWith(
          (ref, key) async => const BranchBaseResolution(
            base: BranchBase(
              refName: 'refs/heads/main',
              displayName: 'main',
              oid: _mainOid,
              source: BranchBaseSource.localMain,
              isFallback: false,
            ),
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
          home: BranchesView(repoPath: _repo),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Record the command count after first paint.
    final firstPaintCommandCount = exec.commands.length;

    // Browse first paint must NOT issue review-summary / merge-tree / patch
    // commands. Base may be resolved, but never per-branch rev-list or log
    // range comparison for the unselected list.
    final comparisonCommands = exec.commands
        .where(
          (cmd) =>
              cmd.contains('rev-list') ||
              cmd.contains('merge-tree') ||
              cmd.contains('branch-review') ||
              cmd.contains('branch-cmp') ||
              (cmd.contains('diff') && cmd.contains('...')),
        )
        .toList();

    expect(
      comparisonCommands,
      isEmpty,
      reason:
          'Browse first paint should not issue comparison commands. '
          'Found: $comparisonCommands',
    );

    // The first paint should only issue the minimal provider set:
    // - refs (for-each-ref)
    // - remotes (remote -v or similar)
    // - remoteTags (ls-remote --tags)
    // - mergedBranches (branch --merged)
    // - branchForge (lazy, may not resolve during first paint)
    //
    // Allow up to 10 commands for the initial provider set. This is a baseline,
    // not a strict assertion — Phase 7 will tune this based on measurements.
    expect(
      firstPaintCommandCount,
      lessThanOrEqualTo(10),
      reason:
          'Browse first paint issued $firstPaintCommandCount commands. '
          'Commands: ${exec.commands}',
    );

    // Log the baseline for future reference (not a test assertion).
    // ignore: avoid_print
    print('500-ref Browse first paint: $firstPaintCommandCount commands');
  });

  testWidgets('500-ref Browse scroll performance', (tester) async {
    final refs = _generateRefs(localCount: 500);
    final exec = _CountingExecutor();
    final git = GitService(exec);

    final container = ProviderContainer(
      overrides: [
        gitServiceProvider.overrideWithValue(git),
        refsProvider(_repo).overrideWith((ref) async => refs),
        remotesProvider(_repo).overrideWith((ref) async => const ['origin']),
        remoteTagsProvider(_repo).overrideWith((ref) async => null),
        branchForgeProvider(_repo).overrideWith((ref) async => const {}),
        mergedBranchesProvider(_repo).overrideWith((ref) async => const {}),
        statusProvider(_repo).overrideWith(
          (ref) async => GitStatus(
            branch: const GitBranchInfo(head: 'main', oid: _mainOid),
            files: const [],
          ),
        ),
        branchBaseProvider.overrideWith(
          (ref, key) async => const BranchBaseResolution(
            base: BranchBase(
              refName: 'refs/heads/main',
              displayName: 'main',
              oid: _mainOid,
              source: BranchBaseSource.localMain,
              isFallback: false,
            ),
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
          home: BranchesView(repoPath: _repo),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final commandsAfterPaint = exec.commands.length;

    // Scroll the list to trigger virtualization. Start away from an interactive
    // row so the gesture cannot select a branch and legitimately start that
    // selection's recent-commits provider.
    final list = find.byType(ListView);
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: tester.getCenter(list),
        scrollDelta: const Offset(0, 500),
      ),
    );
    await tester.pumpAndSettle();

    // Scrolling should NOT issue additional commands — ListView.builder
    // only constructs visible rows, and row construction is pure (no git calls).
    final commandsAfterScroll = exec.commands.length;
    expect(
      commandsAfterScroll,
      equals(commandsAfterPaint),
      reason:
          'Scrolling issued ${commandsAfterScroll - commandsAfterPaint} '
          'additional commands. Browse rows must be pure widget construction.',
    );

    // ignore: avoid_print
    print(
      '500-ref Browse scroll: ${commandsAfterScroll - commandsAfterPaint} '
      'additional commands',
    );
  });
}
