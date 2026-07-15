// displayError: the one mapping from thrown errors to user-facing text.
// CLI exceptions lose their class/exit-code debug noise but keep the
// command's stderr (the CLI's own explanation); everything else rides
// humanizeSshError.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/github/gh_service.dart';
import 'package:remote_magic_git/core/gitlab/glab_service.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/core/utils/display_error.dart';

SSHCommandResult _failed(String stderr) =>
    SSHCommandResult(exitCode: 128, stdout: '', stderr: stderr);

void main() {
  test('GitException shows the message and stderr, not the class noise', () {
    final text = displayError(
      GitException('git push failed', _failed('fatal: remote rejected')),
    );
    expect(text, 'git push failed\n\nfatal: remote rejected');
    expect(text, isNot(contains('GitException')));
    expect(text, isNot(contains('exit 128')));
  });

  test('empty stderr collapses to just the message', () {
    expect(
      displayError(GitException('git fetch failed', _failed('  \n'))),
      'git fetch failed',
    );
  });

  test('stderr already embedded in the message is not repeated', () {
    expect(
      displayError(
        GitException('refused: not fully merged', _failed('not fully merged')),
      ),
      'refused: not fully merged',
    );
  });

  test('forge exceptions get the same treatment', () {
    expect(
      displayError(GhException('gh pr merge failed', _failed('GraphQL: 502'))),
      'gh pr merge failed\n\nGraphQL: 502',
    );
    expect(
      displayError(GlabException('glab api failed', _failed('401 Unauthorized'))),
      'glab api failed\n\n401 Unauthorized',
    );
  });

  test('transport errors ride humanizeSshError', () {
    expect(
      displayError(const SSHCommandTimeout('git status')),
      'Timed out waiting for the remote command to finish.',
    );
    expect(displayError(TimeoutException('x')), 'Timed out reaching the host.');
  });

  test('unknown errors lose the "Exception: " prefix', () {
    expect(displayError(Exception('something odd')), 'something odd');
  });
}
