// Tests for the remote binary/OS resolver: parsing the probe output, merging
// settings overrides over discovery, and PATH augmentation.

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/ssh/environment_probe.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';

class _FakeExecutor extends SSHCommandExecutor {
  _FakeExecutor(this._out, {this.exitCode = 0}) : super(SSHClientManager());
  final String _out;
  final int exitCode;
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
    return SSHCommandResult(exitCode: exitCode, stdout: _out, stderr: '');
  }
}

void main() {
  test('parses OS, augmented PATH, and discovered binaries', () async {
    const out =
        'OS=Darwin\n'
        'PATH=/opt/homebrew/bin:/usr/bin:/bin\n'
        'BIN=git=/usr/bin/git\n'
        'BIN=glab=/opt/homebrew/bin/glab\n'
        'BIN=fswatch=\n'
        'BIN=inotifywait=\n'
        'BIN=stdbuf=/usr/bin/stdbuf\n';
    final env = await EnvironmentResolver(_FakeExecutor(out)).resolve('/repo');

    expect(env.os, 'macos');
    expect(env.osLabel, 'macOS');
    expect(env.pathOf('git'), '/usr/bin/git');
    expect(env.pathOf('glab'), '/opt/homebrew/bin/glab');
    // Empty ⇒ not found (excluded from the map).
    expect(env.has('fswatch'), isFalse);
    expect(env.path, '/opt/homebrew/bin:/usr/bin:/bin');
  });

  test('connect-time probe script spawns no tool (no --version pass)', () {
    // The versions round trip is deliberately deferred to probeVersions —
    // gh/glab update checks must never sit on the connect critical path.
    expect(
      EnvironmentResolver.probeScriptForTest,
      isNot(contains('--version')),
    );
  });

  test('augmented PATH puts per-user dirs ahead of /usr/local/bin', () {
    // A system shim (e.g. a glab/gh wrapper) in /usr/local/bin must never
    // shadow the user's own ~/.local/bin install — otherwise the injected
    // `!glab auth git-credential` helper resolves to the shim and HTTPS forge
    // auth breaks with "could not read Username".
    final script = EnvironmentResolver.probeScriptForTest;
    expect(script, contains(r'u="$HOME/.local/bin:$HOME/bin"'));
    // `u` is spliced ahead of the shared package dirs (`c`) in the aug PATH.
    expect(script, contains(r'aug="$u:$c:'));
    expect(
      script.indexOf(r'$HOME/.local/bin'),
      lessThan(script.indexOf('/usr/local/bin')),
      reason: 'per-user dirs must precede /usr/local/bin in the probe script',
    );
  });

  test('probeVersions parses VER lines, normalizing to x.y.z', () async {
    const out =
        'VER=git=git version 2.39.3 (Apple Git-145)\n'
        'VER=glab=glab 1.40.0\n'
        'VER=gh=gh version 2.62 (2024-01-01)\n'; // no patch → .0
    final exec = _FakeExecutor(out);
    final versions = await EnvironmentResolver(exec).probeVersions({
      'git': '/usr/bin/git',
      'glab': '/opt/homebrew/bin/glab',
      'gh': '/opt/homebrew/bin/gh',
    });

    expect(versions['git'], '2.39.3');
    expect(versions['glab'], '1.40.0');
    expect(versions['gh'], '2.62.0');
    // One sh round trip; every binary invoked by its escaped absolute path,
    // with the CLIs' update checks explicitly suppressed.
    final script = exec.calls.single.last;
    expect(exec.calls.single.take(2), ['sh', '-c']);
    expect(script, contains("'/usr/bin/git' --version"));
    expect(script, contains('GH_NO_UPDATE_NOTIFIER=1'));
    expect(script, contains('GLAB_CHECK_UPDATE=false'));
  });

  test(
    'probeVersions: no parseable token → absent; empty input → no probe',
    () async {
      const out = 'VER=inotifywait=inotifywait: unrecognized option\n';
      final exec = _FakeExecutor(out);
      final versions = await EnvironmentResolver(
        exec,
      ).probeVersions({'inotifywait': '/usr/bin/inotifywait'});
      expect(versions, isEmpty);

      final idle = _FakeExecutor('');
      expect(await EnvironmentResolver(idle).probeVersions(const {}), isEmpty);
      expect(idle.calls, isEmpty, reason: 'no binaries → no round trip');
    },
  );

  test('withVersions merges only versions for resolved tools', () {
    const env = RemoteEnvironment(
      os: 'linux',
      path: '/usr/bin',
      found: {'git': '/usr/bin/git'},
    );
    final merged = env.withVersions({'git': '2.44.0', 'gh': '2.62.0'});
    expect(merged.versionOf('git'), '2.44.0');
    expect(merged.versionOf('gh'), isNull, reason: 'gh was never found');
    expect(merged.found, env.found);
  });

  test('overrides win over discovery and prepend their dir to PATH', () async {
    const out =
        'OS=Linux\n'
        'PATH=/usr/bin:/bin\n'
        'BIN=glab=/usr/bin/glab\n';
    final env = await EnvironmentResolver(
      _FakeExecutor(out),
    ).resolve('/repo', overrides: {'glab': '/custom/tools/glab'});

    expect(env.os, 'linux');
    expect(env.pathOf('glab'), '/custom/tools/glab'); // override wins
    expect(env.overridden, contains('glab'));
    expect(env.path.split(':').first, '/custom/tools'); // dir prepended
  });

  test('probe failure falls back to overrides only', () async {
    final env = await EnvironmentResolver(
      _FakeExecutor('', exitCode: 1),
    ).resolve('/repo', overrides: {'git': '/x/git'});

    expect(env.os, 'unknown');
    expect(env.pathOf('git'), '/x/git');
  });

  group('the connect probe is not blocking (0024 P1)', () {
    test('spawns no login shell and waits on nothing', () {
      final script = EnvironmentResolver.probeScriptForTest;
      // Up to 3s of connect latency in 30 forked sleeps, re-paid on each of up
      // to 20 auto-reconnect attempts, for directories the per-OS list below
      // already covers in the common case.
      expect(script, isNot(contains('sleep')));
      expect(script, isNot(contains('SHELL')));
      expect(script, isNot(contains('-lc')));
      // ...and with it goes the guessable temp file (0024 M4): `$$` is the
      // probe shell's PID, and a plain `>` redirect follows symlinks, so on a
      // shared host another user could pre-plant one at that path. The commit
      // message preview already uses mktemp for exactly this reason.
      expect(script, isNot(contains(r'$$')));
      expect(script, isNot(contains('mg_lp')));
    });

    test('still resolves the per-OS package dirs and every catalog binary', () {
      final script = EnvironmentResolver.probeScriptForTest;
      expect(script, contains('/opt/homebrew/bin'));
      expect(script, contains(r'$HOME/.local/bin'));
      expect(script, contains('command -v'));
      expect(script, contains('echo "OS='));
      expect(script, contains('echo "PATH='));
    });
  });

  group('login-shell PATH parsing is defensive', () {
    test('a shell that prints a banner contributes nothing', () {
      // .zshrc files print MOTDs, version-manager chatter and warnings onto
      // the same stdout as the value. Appending that to a PATH whose ordering
      // is load-bearing is how a /usr/local/bin shim ends up shadowing the
      // real glab.
      expect(
        EnvironmentResolver.parseLoginShellPath(
          'OS=Linux\nPATH=/usr/bin:/bin\nBIN=git=/usr/bin/git',
        ),
        isEmpty,
      );
      expect(
        EnvironmentResolver.parseLoginShellPath('nvm: version 20\n/usr/bin'),
        isEmpty,
      );
    });

    test('a plain PATH parses to its absolute entries', () {
      expect(
        EnvironmentResolver.parseLoginShellPath(
          '/opt/homebrew/bin:/usr/bin:/bin\n',
        ),
        ['/opt/homebrew/bin', '/usr/bin', '/bin'],
      );
    });

    test('relative and empty entries are refused', () {
      expect(
        EnvironmentResolver.parseLoginShellPath('.:..:/usr/bin::rel/bin'),
        ['/usr/bin'],
      );
    });

    test('a pathological shell cannot flood the PATH', () {
      final huge = List.generate(500, (i) => '/d\$i').join(':');
      expect(
        EnvironmentResolver.parseLoginShellPath(huge, maxEntries: 64),
        hasLength(64),
      );
    });
  });

  group('login-shell PATH reconciliation', () {
    test('appends only unknown directories, in order, never prepending', () {
      // Appended, never prepended: per-user-before-system ordering is
      // load-bearing. A /usr/local/bin shim that shadows the real glab breaks
      // the injected `!glab auth git-credential` helper.
      const current = '/home/u/.local/bin:/opt/homebrew/bin:/usr/bin';
      final merged = EnvironmentResolver.mergeLoginShellPath(current, const [
        '/opt/homebrew/bin', // already known — must not move or duplicate
        '/opt/custom/bin', // new — appended at the end
        '/usr/bin', // already known
      ]);
      expect(
        merged,
        '/home/u/.local/bin:/opt/homebrew/bin:/usr/bin:/opt/custom/bin',
      );
    });

    test('nothing new leaves the PATH byte-identical', () {
      const current = '/a:/b';
      expect(
        EnvironmentResolver.mergeLoginShellPath(current, const ['/b', '/a']),
        current,
      );
    });

    test('blank and duplicate entries are dropped', () {
      expect(
        EnvironmentResolver.mergeLoginShellPath('/a', const [
          '',
          '  ',
          '/c',
          '/c',
        ]),
        '/a:/c',
      );
    });
  });
}
