// Unit tests for the create-repository pipeline (MADR 0033 Phase 4).
//
// These reach sequencing that was previously only testable by pumping the
// whole wizard: `runCreateRepo` takes an executor, a log sink and a plain
// request, so each phase can be driven directly. That is the point of the
// extraction — MADR 0030 calls this the "seam" failure shape.
//
// Written AFTER the extraction landed, in a separate commit, so that tests
// shaped to match the refactor cannot be mistaken for evidence that the
// refactor changed nothing. The evidence for that is the 39 pre-existing
// widget tests passing unedited.

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/features/workspace/create_repo_pipeline.dart';

import 'helpers/create_repo_harness.dart';

class _RecordingLog implements CreateRepoLog {
  final List<String> labels = [];
  final List<String> errors = [];

  @override
  void logResult(String label, SSHCommandResult result) => labels.add(label);

  @override
  void logError(String label, String detail) => errors.add('$label: $detail');
}

CreateRepoRequest _request({
  bool existing = false,
  String name = 'proj',
  String? forgePath,
  String parentDir = '/srv',
  String existingFolder = '/srv/app',
  String branch = 'main',
  CreateRemoteMode remote = CreateRemoteMode.none,
  String remoteUrl = '',
  bool replaceOrigin = false,
  bool addReadme = false,
  bool commitAll = false,
  bool identityValid = false,
  String authorName = '',
  String authorEmail = '',
  String description = '',
}) => CreateRepoRequest(
  existing: existing,
  name: name,
  forgePath: forgePath ?? name,
  parentDir: parentDir,
  existingFolder: existingFolder,
  branch: branch,
  host: 'example.com',
  remote: remote,
  private: true,
  description: description,
  remoteUrl: remoteUrl,
  addReadme: addReadme,
  commitAll: commitAll,
  replaceOrigin: replaceOrigin,
  createParents: false,
  isLocalTarget: false,
  identityValid: identityValid,
  authorName: authorName,
  authorEmail: authorEmail,
);

const _deps = CreateRepoDeps(ensureForgeLogin: _noLogin, isActive: _active);
Future<void> _noLogin() async {}
bool _active() => true;

Future<CreateRepoOutcome> _run(
  FakeCreateExecutor exec,
  _RecordingLog log,
  CreateRepoRequest request,
) => runCreateRepo(executor: exec, log: log, request: request, deps: _deps);

/// Flattens the recorded argv lists so a test can ask "was git init issued?"
/// without caring where in the sequence it landed.
List<String> _joined(FakeCreateExecutor exec) => [
  for (final c in exec.calls) c.join(' '),
];

void main() {
  late FakeCreateExecutor exec;
  late _RecordingLog log;

  setUp(() {
    exec = FakeCreateExecutor();
    log = _RecordingLog();
  });

  group('destination resolution', () {
    test('a new folder lands under the parent, an adopted one is itself', () {
      expect(_request(name: 'proj', parentDir: '/srv').dest, '/srv/proj');
      expect(
        _request(existing: true, existingFolder: '/srv/app/').dest,
        '/srv/app',
      );
    });
  });

  group('pre-checks', () {
    test(
      'a folder nested inside another repo is refused before any write',
      () async {
        exec.results.add(okResult('/srv')); // rev-parse --show-toplevel
        final outcome = await _run(
          exec,
          log,
          _request(existing: true, existingFolder: '/srv/app'),
        );
        expect(outcome.error, contains('inside another Git repository'));
        expect(
          exec.calls,
          hasLength(1),
          reason: 'nothing beyond the probe ran',
        );
      },
    );

    test('an existing destination stops a new-folder create', () async {
      exec.results.add(okResult('exists')); // HostFsService.probePath
      final outcome = await _run(exec, log, _request());
      expect(outcome.error, 'The destination already exists: /srv/proj');
      expect(_joined(exec), isNot(contains(startsWith('git init'))));
    });

    test(
      'a missing parent stops the create when createParents is off',
      () async {
        exec.results.add(okResult('noparent'));
        final outcome = await _run(exec, log, _request());
        expect(outcome.error, "The parent folder doesn't exist: /srv");
      },
    );
  });

  group('existing-origin guard', () {
    test('refuses when Replace existing origin is off', () async {
      exec.results
        ..add(okResult('/srv/app')) // already a repo root
        ..add(okResult('git@example.com:me/app.git')); // origin exists
      final outcome = await _run(
        exec,
        log,
        _request(
          existing: true,
          remote: CreateRemoteMode.customUrl,
          remoteUrl: 'git@example.com:me/new.git',
        ),
      );
      expect(outcome.error, contains('already has an origin remote'));
      expect(
        _joined(exec),
        isNot(contains('git remote remove origin')),
        reason: 'a refusal must not mutate the repository',
      );
    });

    test('removes and rewires when the user opted in', () async {
      exec.results
        ..add(okResult('/srv/app')) // rev-parse --show-toplevel
        ..add(okResult('git@example.com:me/old.git')) // origin exists
        ..add(okResult('')) // git remote remove origin
        ..add(okResult('abc123')) // rev-parse --verify HEAD -> hasCommit
        ..add(okResult('')) // git remote add origin <url>
        ..add(okResult('')) // git push -u origin HEAD
        ..add(okResult('git@example.com:me/new.git')); // verify
      final outcome = await _run(
        exec,
        log,
        _request(
          existing: true,
          replaceOrigin: true,
          remote: CreateRemoteMode.customUrl,
          remoteUrl: 'git@example.com:me/new.git',
        ),
      );
      expect(outcome.error, isNull);
      expect(outcome.warnings, isEmpty);
      expect(
        _joined(exec),
        containsAllInOrder([
          'git remote remove origin',
          'git remote add origin git@example.com:me/new.git',
          'git push -u origin HEAD',
        ]),
      );
    });
  });

  group('init', () {
    test('is skipped when the folder is already a repository', () async {
      exec.results
        ..add(okResult('/srv/app')) // already a repo root
        ..add(okResult('abc123')); // rev-parse --verify HEAD
      final outcome = await _run(exec, log, _request(existing: true));
      expect(outcome.error, isNull);
      expect(_joined(exec), isNot(contains(startsWith('git init'))));
    });

    test(
      'runs in the parent with the chosen branch for a new folder',
      () async {
        exec.results
          ..add(okResult('absent')) // probePath
          ..add(okResult('')); // git init
        final outcome = await _run(exec, log, _request(branch: 'trunk'));
        expect(outcome.error, isNull);
        expect(_joined(exec), contains('git init -b trunk -- proj'));
      },
    );

    test('a failing init stops the run and reports stderr', () async {
      exec.results
        ..add(okResult('absent'))
        ..add(
          const SSHCommandResult(
            exitCode: 1,
            stdout: '',
            stderr: 'permission denied',
          ),
        );
      final outcome = await _run(exec, log, _request());
      expect(outcome.error, 'permission denied');
    });
  });

  group('warnings do not fail the run', () {
    test('a failed identity write warns and the repository is kept', () async {
      exec.results
        ..add(okResult('absent')) // probePath
        ..add(okResult('')) // git init
        ..add(
          const SSHCommandResult(exitCode: 1, stdout: '', stderr: 'no config'),
        ); // git config --local user.name
      final outcome = await _run(
        exec,
        log,
        _request(
          identityValid: true,
          authorName: 'Ada',
          authorEmail: 'ada@example.com',
        ),
      );
      expect(
        outcome.error,
        isNull,
        reason: 'the repo exists; this is a warning',
      );
      expect(outcome.dest, '/srv/proj');
      expect(
        outcome.warningText,
        contains('Could not write git identity into the new repository'),
      );
    });
  });

  group('remote modes', () {
    test('none wires nothing and verifies nothing', () async {
      exec.results
        ..add(okResult('absent'))
        ..add(okResult(''));
      final outcome = await _run(exec, log, _request());
      expect(outcome.error, isNull);
      expect(outcome.warnings, isEmpty);
      expect(
        _joined(exec),
        isNot(contains(startsWith('git remote'))),
        reason: 'no origin was promised, so none is wired or checked',
      );
    });

    test('customUrl adds origin but does not push without a commit', () async {
      exec.results
        ..add(okResult('absent')) // probePath
        ..add(okResult('')) // git init
        ..add(okResult('')) // git remote add origin
        ..add(okResult('https://example.com/me/proj.git')); // verify
      final outcome = await _run(
        exec,
        log,
        _request(
          remote: CreateRemoteMode.customUrl,
          remoteUrl: 'https://example.com/me/proj.git',
        ),
      );
      expect(outcome.error, isNull);
      expect(outcome.warnings, isEmpty);
      expect(_joined(exec), isNot(contains(startsWith('git push'))));
    });

    test('a promised origin that never appears becomes a warning', () async {
      exec.results
        ..add(okResult('absent')) // probePath
        ..add(okResult('')) // git init
        ..add(okResult('')) // git remote add origin
        ..add(const SSHCommandResult(exitCode: 2, stdout: '', stderr: ''));
      final outcome = await _run(
        exec,
        log,
        _request(
          remote: CreateRemoteMode.customUrl,
          remoteUrl: 'https://example.com/me/proj.git',
        ),
      );
      expect(outcome.error, isNull);
      expect(outcome.warningText, contains('no "origin" remote is'));
    });
  });

  group('deps', () {
    test(
      'a forge target logs into the host before the CLI is queried',
      () async {
        var loginCalls = 0;
        exec.results
          ..add(okResult('absent'))
          ..add(okResult(''));
        await runCreateRepo(
          executor: exec,
          log: log,
          request: _request(remote: CreateRemoteMode.github),
          deps: CreateRepoDeps(
            ensureForgeLogin: () async => loginCalls++,
            isActive: () => true,
          ),
        );
        expect(loginCalls, 1);
      },
    );

    test(
      'a host that goes away mid-run abandons instead of continuing',
      () async {
        exec.results.add(okResult('absent'));
        final outcome = await runCreateRepo(
          executor: exec,
          log: log,
          request: _request(),
          deps: CreateRepoDeps(
            ensureForgeLogin: _noLogin,
            isActive: () => false,
          ),
        );
        expect(outcome.aborted, isTrue);
        expect(outcome.error, isNull);
        expect(
          _joined(exec),
          isNot(contains(startsWith('git init'))),
          reason: 'work stops when the sheet is gone',
        );
      },
    );
  });
}
