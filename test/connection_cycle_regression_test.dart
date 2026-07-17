// Pins the provider-graph acyclicity of the connect path — against the REAL
// provider wiring, with real git in a temp repo.
//
// The bug this guards: ConnectionController methods did
// `ref.read(gitServiceProvider)` (and `ref.read(ignoreOracleProvider)`) — both
// providers depend, via the executor, on connectionProvider itself, so those
// reads are self-references. Riverpod's debug cycle detector throws
// `CircularDependencyError` on them, which crashed EVERY connect in debug
// builds; in release the assert is compiled out and the cycle silently
// poisoned the graph. No other test caught it because they all override
// gitServiceProvider with a fake, severing the dependency chain the detector
// walks — so this test deliberately uses the real graph (asserts are on in
// `flutter test`, so any reintroduced cyclic read fails here loudly).
@Tags(['integration'])
library;

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<String> _raw(String repo, List<String> args) async {
  final result = await Process.run('git', args, workingDirectory: repo);
  expect(result.exitCode, 0, reason: 'setup git $args: ${result.stderr}');
  return (result.stdout as String).trim();
}

void main() {
  late Directory tempDir;
  late String repo;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempDir = Directory.systemTemp.createTempSync('conn_cycle_');
    repo = '${tempDir.resolveSymbolicLinksSync()}/repo';
    Directory(repo).createSync(recursive: true);
    await _raw(repo, ['init', '-q', '-b', 'main']);
    await _raw(repo, ['config', 'user.name', 'T']);
    await _raw(repo, ['config', 'user.email', 't@t']);
    await _raw(repo, ['config', 'commit.gpgsign', 'false']);
    File('$repo/f.txt').writeAsStringSync('x\n');
    await _raw(repo, ['add', '-A']);
    await _raw(repo, ['commit', '-q', '-m', 'base']);
  });

  tearDown(() => tempDir.deleteSync(recursive: true));

  test('connectLocal completes with the REAL provider graph (no cycles)', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    // Would throw CircularDependencyError before the fix.
    await container
        .read(connectionProvider.notifier)
        .connectLocal(repo, label: 'cycle-pin');

    final state = container.read(connectionProvider);
    expect(state.isConnected, isTrue, reason: 'error: ${state.error}');
    expect(state.repoPath, repo);

    // setRepoPath used to hit the ignore-oracle self-reference via
    // _invalidateRepoState — exercise it too (same path, same repo is a no-op,
    // so re-point at the same repo through the mutating branch).
    container.read(connectionProvider.notifier).setRepoPath('$repo/.');
    // Reaching here without a CircularDependencyError is the assertion.

    await container.read(connectionProvider.notifier).disconnect();
  });
}
