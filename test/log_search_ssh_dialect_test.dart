// History search over the REMOTE dialect: the exact argv GitService.log
// builds, serialized by CommandFormatter into the one shell string the SSH
// backend actually executes, run through a real `ssh localhost` hop into a
// real login shell against a real repo.
//
// This is the layer none of the other search tests touch. Locally, argv goes
// straight to Process.start and no shell ever sees it; remotely EVERY search
// pattern — ERE with escaped metacharacters, `:(icase,glob)` pathspecs, the
// \x1f/\x1e pretty-format separators, the gzip exit trailer — must survive
// ShellEscaper + a login shell + (optionally) a gzip pipe. A quoting bug here
// is invisible to every local test and breaks search only for the SSH
// backend, which is this app's primary use.
//
// Skipped automatically when `ssh localhost` isn't available (Remote Login
// off) — the dialect is then untestable on this machine, not passing.
@Tags(['integration'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/exec/local_command_executor.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/ssh/command_formatter.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';

/// Records the argv of every execute call and answers with success, so
/// [GitService.log] runs its full argument construction and hands us the
/// exact command the SSH backend would send.
class _ArgvCapture extends LocalCommandExecutor {
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
    Duration? activityIdle,
    OperationDescriptor? operation,
    OperationEventCallback? onOperationEvent,
    CommandOutputCallback? onOutput,
  }) async {
    calls.add(gitArgs);
    return const SSHCommandResult(exitCode: 0, stdout: '', stderr: '');
  }
}

void main() {
  final sshProbe = Process.runSync('ssh', [
    '-o',
    'BatchMode=yes',
    '-o',
    'ConnectTimeout=3',
    'localhost',
    'true',
  ]);
  final sshAvailable = sshProbe.exitCode == 0;

  late Directory tempDir;
  late String repo;

  Future<void> raw(List<String> args) async {
    final result = await Process.run('git', args, workingDirectory: repo);
    expect(
      result.exitCode,
      0,
      reason: 'setup `git ${args.join(' ')}` failed: ${result.stderr}',
    );
  }

  Future<void> commitFile(String path, String content, String message) async {
    final file = File('$repo/$path');
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
    await raw(['add', '--all']);
    await raw(['commit', '-q', '-m', message]);
  }

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('ssh_dialect_');
    repo = '${tempDir.resolveSymbolicLinksSync()}/repo';
    Directory(repo).createSync(recursive: true);
    await raw(['init', '-q', '-b', 'main']);
    await raw(['config', 'user.name', 'Mac Smith']);
    await raw(['config', 'user.email', 'mac@example.com']);
    await raw(['config', 'commit.gpgsign', 'false']);
    await commitFile('lib/a.dart', 'a\n', 'feat: first feature');
    await commitFile('lib/b.dart', 'b\n', 'fix [WIP] patch collapse');
    await commitFile('docs/c.md', 'c\n', "docs: O'Brien's user guide");
  });

  tearDown(() => tempDir.deleteSync(recursive: true));

  /// The argv [GitService.log] would send for these criteria.
  Future<List<String>> argvFor({
    String? grep,
    String? author,
    String? pathQuery,
  }) async {
    final capture = _ArgvCapture();
    await GitService(
      capture,
    ).log(repo, grep: grep, author: author, pathQuery: pathQuery);
    expect(capture.calls, hasLength(1));
    return capture.calls.single;
  }

  /// Serializes [argv] exactly as the SSH executor does and runs it through a
  /// real ssh hop; returns the parsed commits.
  Future<List<GitCommit>> overSsh(
    List<String> argv, {
    bool compress = false,
  }) async {
    final script = CommandFormatter.format(
      repoPath: repo,
      gitArgs: argv,
      compressOutput: compress,
    );
    if (!compress) {
      final result = await Process.run('ssh', ['localhost', script]);
      expect(result.exitCode, 0, reason: 'stderr: ${result.stderr}');
      return parseGitLog(result.stdout as String);
    }
    final result = await Process.run('ssh', [
      'localhost',
      script,
    ], stdoutEncoding: null);
    expect(result.exitCode, 0, reason: 'stderr: ${result.stderr}');
    final inflated = String.fromCharCodes(
      gzip.decode(result.stdout as List<int>),
    );
    final (exit, body) = SSHCommandExecutor.splitExitTrailer(inflated);
    expect(exit, 0, reason: 'the command inside the gzip pipe failed');
    return parseGitLog(body);
  }

  List<String> subjects(List<GitCommit> commits) => [
    for (final c in commits) c.subject,
  ];

  group(
    'search argv survives ShellEscaper + a real login shell',
    () {
      test('ERE-escaped metacharacters ([WIP])', () async {
        final hits = await overSsh(await argvFor(grep: '[WIP]'));
        expect(subjects(hits), ['fix [WIP] patch collapse']);
      });

      test('multi-word AND with --all-match', () async {
        final hits = await overSsh(await argvFor(grep: 'collapse patch'));
        expect(subjects(hits), ['fix [WIP] patch collapse']);
      });

      test("an author term with an apostrophe (O'Brien) — the single-quote "
          'escaping worst case', () async {
        final hits = await overSsh(await argvFor(grep: "O'Brien's"));
        expect(subjects(hits), ["docs: O'Brien's user guide"]);
      });

      test('glob pathspecs (:(icase,glob)**/*…*)', () async {
        final hits = await overSsh(await argvFor(pathQuery: 'B.DART'));
        expect(subjects(hits), ['fix [WIP] patch collapse']);
      });

      test(
        'the \\x1f/\\x1e pretty-format separators survive the wire',
        () async {
          final hits = await overSsh(await argvFor());
          expect(hits, hasLength(3));
          expect(hits.first.authorName, 'Mac Smith');
          expect(hits.first.authorEmail, 'mac@example.com');
          expect(hits.first.parents, hasLength(1));
        },
      );

      test('the gzip pipe + exit trailer (compress path)', () async {
        final hits = await overSsh(
          await argvFor(grep: '[WIP]'),
          compress: true,
        );
        expect(subjects(hits), ['fix [WIP] patch collapse']);
      });
    },
    skip: sshAvailable ? false : 'ssh localhost unavailable (Remote Login off)',
  );
}
