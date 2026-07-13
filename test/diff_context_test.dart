// Hunk context in the History diffs. git's default patch carries 3 context
// lines either side of a change, so a hunk routinely ends mid-expression and
// reads as a truncated diff — the expand-context toggle widens it, and the
// widened patch must not be served from the cache of the narrow one.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/settings/app_settings.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';

/// Records the argv of every command, so the `-U<n>` git actually received is
/// observable rather than inferred.
class _RecordingExecutor extends SSHCommandExecutor {
  _RecordingExecutor() : super(SSHClientManager());

  final List<List<String>> commands = [];

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
    commands.add(gitArgs);
    // Echo the context back, so two different -U values yield two different
    // patches — that's what makes a key collision visible.
    final u = gitArgs.firstWhere((a) => a.startsWith('-U'), orElse: () => '-U?');
    return SSHCommandResult(exitCode: 0, stdout: 'patch at $u', stderr: '');
  }
}

void main() {
  test('showCommit passes the context through as -U<n>', () async {
    final exec = _RecordingExecutor();
    final git = GitService(exec);

    await git.showCommit('/repo', 'abc123');
    expect(
      exec.commands.single,
      isNot(contains(startsWith('-U'))),
      reason: 'no context asked for → git uses its own default',
    );

    exec.commands.clear();
    await git.showCommit('/repo', 'abc123', context: 25);
    expect(exec.commands.single, contains('-U25'));
    // The flag must precede --end-of-options, or git reads it as a pathspec.
    final args = exec.commands.single;
    expect(
      args.indexOf('-U25'),
      lessThan(args.indexOf('--end-of-options')),
      reason: '-U25 after --end-of-options would be treated as a revision',
    );
  });

  test('the same commit at two context widths is two cache entries', () async {
    final exec = _RecordingExecutor();
    final container = ProviderContainer(
      overrides: [gitServiceProvider.overrideWithValue(GitService(exec))],
    );
    addTearDown(container.dispose);

    const narrow = AppSettingsNotifier.defaultDiffContext;
    const wide = AppSettingsNotifier.expandedDiffContext;

    final a = await container.read(
      commitDiffProvider(('/repo', 'abc123', narrow)).future,
    );
    final b = await container.read(
      commitDiffProvider(('/repo', 'abc123', wide)).future,
    );

    // Without the context in the provider key, `b` would be served the cached
    // narrow patch and expanding context would silently do nothing.
    expect(a, 'patch at -U3');
    expect(b, 'patch at -U25');
    expect(exec.commands, hasLength(2), reason: 'each width fetched once');
  });

  test('expanded context is the wider of the two', () {
    expect(
      AppSettingsNotifier.expandedDiffContext,
      greaterThan(AppSettingsNotifier.defaultDiffContext),
    );
  });
}
