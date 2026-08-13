// stashList parsing: the reflog subject (%gs) is the one free-text field, so
// the format puts it LAST. A stray field-separator byte inside it must only
// over-split the trailing field (which is rejoined) and never dislodge the
// relative-date column — the same robustness parseRefs gives the commit
// subject.

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';

const _sep = GitService.fieldSep;

/// Feeds `git stash list` a canned stdout so the inline parser can be exercised
/// without a real repo. Every other method is unused here.
class _CannedExecutor extends SSHCommandExecutor {
  _CannedExecutor(this.stdout) : super(SSHClientManager());
  final String stdout;

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
    OperationDescriptor? operation,
    OperationEventCallback? onOperationEvent,
  }) async => SSHCommandResult(exitCode: 0, stdout: stdout, stderr: '');
}

const _oidA = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _oidB = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

Future<List<GitStash>> _parse(String stdout) =>
    GitService(_CannedExecutor(stdout)).stashList('/repo');

// Format order mirrors git_service: %gd, %H, %cr, %gs.
String _row(String gd, String oid, String date, String subject) =>
    [gd, oid, date, subject].join(_sep);

void main() {
  test(
    'parses index, oid, branch, subject and date from a normal row',
    () async {
      final stashes = await _parse(
        _row(
          'stash@{0}',
          _oidA,
          '2 hours ago',
          'WIP on main: abc1234 tweak it',
        ),
      );
      expect(stashes, hasLength(1));
      final s = stashes.single;
      expect(s.index, 0);
      expect(s.oid, _oidA);
      expect(s.branch, 'main');
      expect(s.relativeDate, '2 hours ago');
      expect(s.subject, 'tweak it');
    },
  );

  test(
    'a separator byte inside the message does not dislodge the date',
    () async {
      // The adversarial case: a Unit-Separator smuggled into %gs. Pre-fix this
      // shoved %cr past f[3] and a message fragment showed up as the date.
      const poisoned = 'On main: note${_sep}with a separator';
      final stashes = await _parse(
        _row('stash@{0}', _oidA, '3 days ago', poisoned),
      );
      expect(stashes, hasLength(1));
      final s = stashes.single;
      // The date column is intact...
      expect(s.relativeDate, '3 days ago');
      // ...and the stray byte is stripped from the rejoined message.
      expect(s.message, 'On main: notewith a separator');
      expect(s.subject, 'notewith a separator');
      expect(s.branch, 'main');
    },
  );

  test('parses multiple rows and preserves per-row index', () async {
    final stashes = await _parse(
      '${_row('stash@{0}', _oidA, '1 hour ago', 'WIP on main: newer')}\n'
      '${_row('stash@{1}', _oidB, '2 days ago', 'On feature: older')}',
    );
    expect(stashes.map((s) => s.index), [0, 1]);
    expect(stashes.map((s) => s.oid), [_oidA, _oidB]);
    expect(stashes.map((s) => s.branch), ['main', 'feature']);
    expect(stashes.map((s) => s.subject), ['newer', 'older']);
  });

  test('an empty message yields an empty-ish subject, not a crash', () async {
    final stashes = await _parse(_row('stash@{0}', _oidA, '5 minutes ago', ''));
    expect(stashes, hasLength(1));
    expect(stashes.single.relativeDate, '5 minutes ago');
    expect(stashes.single.message, '');
  });

  test('a truncated row (missing the message field) is skipped', () async {
    // Only three fields — the parser needs four (gd, oid, cr, gs).
    final stashes = await _parse(['stash@{0}', _oidA, '1 hour ago'].join(_sep));
    expect(stashes, isEmpty);
  });
}
