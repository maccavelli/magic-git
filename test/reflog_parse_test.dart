import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';

const fs = GitService.fieldSep;
const rs = GitService.recordSep;

String rec(
  String hash,
  String short,
  String selector,
  String gs,
  String subject,
) => '$hash$fs$short$fs$selector$fs$gs$fs$subject$rs\n';

void main() {
  test('parseReflog splits action and detail at the first colon', () {
    final raw =
        rec(
          'a' * 40,
          'aaaaaaa',
          'HEAD@{5 minutes ago}',
          'commit: add feature',
          'add feature',
        ) +
        rec(
          'b' * 40,
          'bbbbbbb',
          'HEAD@{2 hours ago}',
          'checkout: moving from main to feature',
          'base commit',
        ) +
        rec(
          'c' * 40,
          'ccccccc',
          'HEAD@{3 days ago}',
          'reset: moving to HEAD~1',
          'older commit',
        ) +
        rec(
          'd' * 40,
          'ddddddd',
          'HEAD@{4 days ago}',
          'rebase (finish): returning to refs/heads/main',
          'rebased',
        ) +
        rec(
          'e' * 40,
          'eeeeeee',
          'HEAD@{5 days ago}',
          'commit (amend): better subject',
          'better subject',
        );

    final entries = parseReflog(raw);
    expect(entries, hasLength(5));

    expect(entries[0].hash, 'a' * 40);
    expect(entries[0].shortHash, 'aaaaaaa');
    expect(entries[0].selector, 'HEAD@{5 minutes ago}');
    expect(entries[0].action, 'commit');
    expect(entries[0].detail, 'add feature');
    expect(entries[0].subject, 'add feature');

    expect(entries[1].action, 'checkout');
    expect(entries[1].detail, 'moving from main to feature');

    expect(entries[2].action, 'reset');
    expect(entries[2].detail, 'moving to HEAD~1');

    expect(entries[3].action, 'rebase (finish)');
    expect(entries[3].detail, 'returning to refs/heads/main');

    expect(entries[4].action, 'commit (amend)');
    expect(entries[4].detail, 'better subject');
  });

  test('a reflog message with no action prefix becomes all-detail', () {
    final entries = parseReflog(
      rec('a' * 40, 'aaaaaaa', 'HEAD@{1 day ago}', 'initial pull', 'first'),
    );
    expect(entries.single.action, '');
    expect(entries.single.detail, 'initial pull');
  });

  test('truncated records are skipped, the rest still parse', () {
    final raw =
        'garbage$rs\n${rec('a' * 40, 'aaaaaaa', 'HEAD@{0}', 'commit: ok', 'ok')}';
    final entries = parseReflog(raw);
    expect(entries, hasLength(1));
    expect(entries.single.detail, 'ok');
  });

  test('an empty subject (e.g. an empty commit message) still parses', () {
    final entries = parseReflog(
      rec('a' * 40, 'aaaaaaa', 'HEAD@{0}', 'reset: moving to HEAD~1', ''),
    );
    expect(entries, hasLength(1));
    expect(entries.single.subject, '');
    expect(entries.single.detail, 'moving to HEAD~1');
  });

  test('the recovery providers are registered for ⌘R / connection resets', () {
    // The documented foot-gun: a repo-scoped fetch family missing from the
    // registry silently survives refresh and disconnect.
    expect(repoScopedFetchFamilies, contains(reflogProvider));
    expect(repoScopedFetchFamilies, contains(magicSnapshotsProvider));
  });
}
