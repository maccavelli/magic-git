// Pins the injection defense end to end: a caller-controlled value must reach
// the host as a single literal token, never as shell syntax.
//
// Deliberately NOT a source scan. Scanning for `ShellEscaper.escape` call
// sites was considered and rejected (MADR 0017 G2): the files that build
// shell text hold 16 escaped interpolations and 125 bare ones, and nearly all
// the bare ones are error messages — a scan would be ~90% noise, and noise
// gets allowlisted until it means nothing. "Did someone call the escaper" is
// also not the property anyone cares about. This drives the real services
// with adversarial payloads and asserts the property itself, so it holds
// however the escaping is spelled.
//
// The rule: CommandFormatter escapes every argv element wholesale, so a
// caller value riding in an element — even composed into one, like git's
// `:(literal)<path>` pathspec — is literal by construction. The one place
// that protection does not reach is the script handed to `sh -c`: one argv
// element to the formatter, a whole program to the shell. Any caller value
// inside it must already be escaped. That is what this asserts.

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/git/host_fs_service.dart';
import 'package:remote_magic_git/core/ssh/command_formatter.dart';
import 'package:remote_magic_git/core/ssh/shell_escaper.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';

/// Shell metacharacters in every position that has mattered: command
/// separation, substitution (both spellings), a newline (which reasoning
/// about `;` alone does not cover), an option-lookalike, and a bare
/// apostrophe — single quoting is exactly what the escaper does, so a value
/// containing one is the case most likely to break it.
const _payloads = <String>[
  r"'; touch /tmp/pwned; '",
  r'$(touch /tmp/pwned)',
  '`touch /tmp/pwned`',
  'a\nrm -rf /',
  '--upload-pack=touch /tmp/pwned',
  "it's a branch",
];

/// Records argv without touching SSH.
class _Recorder extends SSHCommandExecutor {
  _Recorder() : super(SSHClientManager());

  final List<List<String>> calls = [];
  final List<String> repoPaths = [];

  /// Some callers parse stdout (`probePath`); give them something valid.
  String stdout = '';

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
    Duration? activityIdle,
    OperationDescriptor? operation,
    OperationEventCallback? onOperationEvent,
  }) async {
    calls.add(gitArgs);
    repoPaths.add(repoPath);
    return SSHCommandResult(exitCode: 0, stdout: stdout, stderr: '');
  }
}

/// Fails unless every appearance of [payload] across [calls] is safe.
void expectNeverSyntax(List<List<String>> calls, String payload, String what) {
  // Escaping a value that contains an apostrophe rewrites it ('it'\''s'), so
  // an escaped token does not contain the raw payload as a substring. Look
  // for either form, or the coverage guard below misfires on exactly the
  // payloads that matter most.
  final escaped = ShellEscaper.escape(payload);
  var seen = 0;
  for (final argv in calls) {
    final isScript = argv.length >= 3 && argv[0] == 'sh' && argv[1] == '-c';
    for (var i = 0; i < argv.length; i++) {
      final arg = argv[i];
      final raw = arg.contains(payload);
      if (!raw && !arg.contains(escaped)) continue;
      seen++;
      // Everything but an `sh -c` script is a single argv element, which
      // CommandFormatter escapes whole — safe however it was composed.
      if (!(isScript && i == 2)) continue;
      expect(
        arg,
        contains(escaped),
        reason:
            '$what interpolated a caller value into an `sh -c` script '
            'unescaped. Interpolate ShellEscaper.escape(value), never the '
            'value itself.',
      );
    }
  }
  expect(
    seen,
    greaterThan(0),
    reason:
        '$what never passed the payload to the executor — the case is not '
        'actually covered, so fix the invocation rather than trusting it',
  );
}

void main() {
  for (final payload in _payloads) {
    group('payload ${payload.replaceAll('\n', r'\n')}', () {
      test('GitService keeps caller values literal', () async {
        final exec = _Recorder();
        final git = GitService(exec);

        await git.stage('/repo', payload);
        await git.checkout('/repo', payload);
        await git.createBranch('/repo', payload, checkout: false);
        await git.deleteBranch('/repo', payload);
        await git.commit('/repo', message: payload);
        await git.pushTags('/repo', [payload]);
        await git.deleteRemoteTag('/repo', 'origin', payload);
        await git.fileHistory('/repo', payload);
        await git.diffRange('/repo', payload);

        expectNeverSyntax(exec.calls, payload, 'GitService');
      });

      test('a caller-controlled repo path stays literal', () async {
        // The repo path comes from the connection form, so it is as
        // caller-controlled as a branch name. It rides `repoPath`, becoming
        // the `cd` target — assert on the formatted command, which is where
        // the path actually meets the shell.
        final exec = _Recorder();
        final git = GitService(exec);
        final repo = '/repo/$payload';

        await git.stage(repo, 'lib/main.dart');

        expect(exec.repoPaths, contains(repo));
        // The command opens with an env prelude, so match the `cd` clause
        // rather than the start of the string.
        expect(
          CommandFormatter.format(repoPath: repo, gitArgs: exec.calls.first),
          contains('cd ${ShellEscaper.escape(repo)} &&'),
        );
      });

      test('HostFsService keeps caller paths literal', () async {
        final exec = _Recorder()..stdout = 'exists'; // probePath parses it
        final fs = HostFsService(exec);

        await fs.makeDirs('/tmp/$payload');
        await fs.probePath('/tmp/$payload');
        await fs.listDirectories('/tmp/$payload');

        expectNeverSyntax(exec.calls, '/tmp/$payload', 'HostFsService');
      });
    });
  }

  test(
    'a repo path with a quote cannot break out of an sh -c script',
    () async {
      // The regression this whole file exists for: `mkdir -p --` composes the
      // path into a script string, so it is the one shape where a raw
      // interpolation would be exploitable rather than merely wrong.
      final exec = _Recorder();
      final fs = HostFsService(exec);
      const path = "/tmp/it's; touch /tmp/pwned";

      await fs.makeDirs(path);

      final script = exec.calls.single.last;
      expect(script, contains(ShellEscaper.escape(path)));
      expect(
        script.replaceAll(ShellEscaper.escape(path), ''),
        isNot(contains('touch /tmp/pwned')),
        reason: 'the payload survived outside the escaped token',
      );
    },
  );
}
