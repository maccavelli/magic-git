// parseRefs and the GitRef helpers it feeds — previously untested despite
// carrying the worktree-awareness and (now) upstream-divergence logic every
// branch surface renders from.

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/git_service.dart';

const _sep = '';

String _line({
  String head = ' ',
  String name = 'refs/heads/main',
  String oid = 'aaa',
  String upstream = '',
  String subject = 's',
  String peeled = '',
  String worktree = '',
  String track = '',
  String created = '',
}) => [
  head,
  name,
  oid,
  upstream,
  subject,
  peeled,
  worktree,
  track,
  created,
].join(_sep);

void main() {
  group('upstream:track parsing', () {
    test('ahead and behind, alone or together', () {
      final refs = parseRefs(
        [
          _line(name: 'refs/heads/both', track: '[ahead 2, behind 1]'),
          _line(name: 'refs/heads/ahead', track: '[ahead 7]'),
          _line(name: 'refs/heads/behind', track: '[behind 3]'),
          _line(name: 'refs/heads/insync', track: ''),
        ].join('\n'),
        _sep,
      );
      expect((refs[0].ahead, refs[0].behind), (2, 1));
      expect((refs[1].ahead, refs[1].behind), (7, 0));
      expect((refs[2].ahead, refs[2].behind), (0, 3));
      expect((refs[3].ahead, refs[3].behind), (0, 0));
      expect(refs.map((r) => r.upstreamGone), everyElement(isFalse));
    });

    test('[gone] marks the upstream as deleted', () {
      final refs = parseRefs(_line(track: '[gone]'), _sep);
      expect(refs.single.upstreamGone, isTrue);
      expect(refs.single.ahead, 0);
      expect(refs.single.behind, 0);
    });

    test('an old git echoing the atom reads as no tracking data', () {
      final refs = parseRefs(_line(track: '%(upstream:track)'), _sep);
      expect(refs.single.upstreamGone, isFalse);
      expect((refs.single.ahead, refs.single.behind), (0, 0));
    });

    test('a six-field line (git without the newer atoms) still parses', () {
      final refs = parseRefs(
        ['*', 'refs/heads/main', 'aaa', 'origin/main', 'subject', ''].join(
          _sep,
        ),
        _sep,
      );
      expect(refs.single.isHead, isTrue);
      expect(refs.single.worktreePath, isNull);
      expect((refs.single.ahead, refs.single.behind), (0, 0));
    });
  });

  group('isCheckedOutElsewhere', () {
    test('true only for a non-head local branch with a worktree path', () {
      final refs = parseRefs(
        [
          _line(name: 'refs/heads/held', worktree: '/wt/held'),
          _line(head: '*', name: 'refs/heads/current', worktree: '/repo'),
          _line(name: 'refs/heads/free'),
          _line(name: 'refs/remotes/origin/held', worktree: '/wt/held'),
        ].join('\n'),
        _sep,
      );
      expect(refs[0].isCheckedOutElsewhere, isTrue);
      expect(refs[0].elsewhereWorktreePath, '/wt/held');
      expect(refs[1].isCheckedOutElsewhere, isFalse,
          reason: 'the current branch is checked out HERE');
      expect(refs[2].isCheckedOutElsewhere, isFalse);
      expect(refs[3].isCheckedOutElsewhere, isFalse,
          reason: 'remotes are never "checked out elsewhere"');
    });

    test('a pre-2.23 git echoing %(worktreepath) is filtered by shape', () {
      final refs = parseRefs(_line(worktree: '%(worktreepath)'), _sep);
      expect(refs.single.worktreePath, isNull);
    });
  });

  group('creatordate parsing', () {
    test('epoch seconds parse; the tags list sorts on them newest-first', () {
      final refs = parseRefs(
        [
          _line(name: 'refs/tags/v1', created: '1000'),
          _line(name: 'refs/tags/v2', created: '3000'),
        ].join('\n'),
        _sep,
      );
      expect(refs[0].creatorDate, 1000);
      expect(refs[1].creatorDate, 3000);
    });

    test('a pre-2.7 git echoing the atom reads as no date', () {
      final refs = parseRefs(_line(created: '%(creatordate:unix)'), _sep);
      expect(refs.single.creatorDate, isNull);
    });

    test('an eight-field line (git without the atom) still parses', () {
      final refs = parseRefs(
        [' ', 'refs/tags/v1', 'aaa', '', 's', '', '', ''].join(_sep),
        _sep,
      );
      expect(refs.single.creatorDate, isNull);
    });
  });
}
