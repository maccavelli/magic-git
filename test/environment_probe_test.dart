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
  }) async => SSHCommandResult(exitCode: exitCode, stdout: _out, stderr: '');
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

  test('parses tool versions from VER lines, normalizing to x.y.z', () async {
    const out =
        'OS=Darwin\n'
        'PATH=/usr/bin:/bin\n'
        'BIN=git=/usr/bin/git\n'
        'VER=git=git version 2.39.3 (Apple Git-145)\n'
        'BIN=glab=/opt/homebrew/bin/glab\n'
        'VER=glab=glab 1.40.0\n'
        'BIN=gh=/opt/homebrew/bin/gh\n'
        'VER=gh=gh version 2.62 (2024-01-01)\n'; // no patch → .0
    final env = await EnvironmentResolver(_FakeExecutor(out)).resolve('/repo');

    expect(env.versionOf('git'), '2.39.3');
    expect(env.versionOf('glab'), '1.40.0');
    expect(env.versionOf('gh'), '2.62.0');
  });

  test('a version with no parseable token is simply absent', () async {
    const out =
        'OS=Linux\n'
        'PATH=/usr/bin:/bin\n'
        'BIN=inotifywait=/usr/bin/inotifywait\n'
        'VER=inotifywait=inotifywait: unrecognized option\n';
    final env = await EnvironmentResolver(_FakeExecutor(out)).resolve('/repo');

    expect(env.has('inotifywait'), isTrue);
    expect(env.versionOf('inotifywait'), isNull);
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
}
