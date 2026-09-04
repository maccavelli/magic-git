// Pins the re-entry guard in `helpers/fake_snapshot.dart`.
//
// The two mixins there differ only in which virtual seam their `snapshot()`
// calls. Pairing a fake with the wrong one used to recurse forever through
// `await`, flooding the microtask queue so no timer — including `flutter
// test`'s own `--timeout` — could ever fire: the run hung with no error, no
// stack, and no failing test name. That is what cost the 0025 Phase 7 landing
// a full debugging cycle, so the failure mode is pinned rather than described.
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/core/utils/git_porcelain_parser.dart';

import 'helpers/fake_snapshot.dart';

/// The exact mistake `_FakeGit` made: overrides refs(), but mixes in the
/// status-shaped mixin. Before the guard this recursed forever.
class _WrongMixin extends GitService with FakeSnapshot {
  _WrongMixin() : super(SSHCommandExecutor(SSHClientManager()));
  @override
  Future<List<GitRef>> refs(String repoPath) async => const [];
}

/// The mirror mistake: overrides status(), but mixes in the refs-shaped mixin.
class _WrongMixinMirror extends GitService with FakeRefsSnapshot {
  _WrongMixinMirror() : super(SSHCommandExecutor(SSHClientManager()));
  @override
  Future<GitStatus> status(String repoPath) async =>
      GitStatus(branch: const GitBranchInfo(), files: const []);
}

/// The correct pairing, to prove the guard does not fire on a good fake.
class _RightMixin extends GitService with FakeRefsSnapshot {
  _RightMixin() : super(SSHCommandExecutor(SSHClientManager()));
  @override
  Future<List<GitRef>> refs(String repoPath) async => const [];
}

void main() {
  test('wrong mixin (status-shaped on a refs fake) throws, does not hang', () {
    expect(
      _WrongMixin().snapshot('/r'),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          allOf(
            contains('re-entered through status()'),
            contains('FakeRefsSnapshot'),
          ),
        ),
      ),
    );
  });

  test('wrong mixin (refs-shaped on a status fake) throws, does not hang', () {
    expect(
      _WrongMixinMirror().snapshot('/r'),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          allOf(
            contains('re-entered through refs()'),
            contains('FakeSnapshot'),
          ),
        ),
      ),
    );
  });

  test('correct pairing resolves normally', () async {
    final snap = await _RightMixin().snapshot('/r');
    expect(snap.refs, isEmpty);
    expect(snap.status.files, isEmpty);
  });

  test('two concurrent snapshots of one fake do not false-positive', () async {
    final git = _RightMixin();
    final both = await Future.wait([git.snapshot('/r'), git.snapshot('/r')]);
    expect(both, hasLength(2));
  });
}
