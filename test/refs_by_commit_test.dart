import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/git_service.dart';

GitRef ref(String name, String oid, {bool head = false, String? peeled}) =>
    GitRef(name: name, oid: oid, isHead: head, subject: 's', peeledOid: peeled);

void main() {
  group('refsByCommit', () {
    test('groups multiple refs on the same commit', () {
      final map = refsByCommit([
        ref('refs/heads/main', 'aaa', head: true),
        ref('refs/remotes/origin/main', 'aaa'),
        ref('refs/heads/feature', 'bbb'),
      ]);
      expect(map['aaa'], hasLength(2));
      expect(map['bbb'], hasLength(1));
    });

    test('orders HEAD, local, remote, tag within a commit', () {
      final map = refsByCommit([
        ref('refs/tags/v1', 'aaa'),
        ref('refs/remotes/origin/main', 'aaa'),
        ref('refs/heads/main', 'aaa', head: true),
        ref('refs/heads/other', 'aaa'),
      ]);
      final names = map['aaa']!.map((r) => r.name).toList();
      expect(names.first, 'refs/heads/main'); // HEAD first
      expect(names.last, 'refs/tags/v1'); // tag last
      // remote sorts after local branches
      expect(
        names.indexOf('refs/remotes/origin/main'),
        greaterThan(names.indexOf('refs/heads/other')),
      );
    });

    test('annotated tag is grouped under its peeled commit', () {
      final map = refsByCommit([
        // Tag object is ddd, but it points at commit ccc.
        ref('refs/tags/v2', 'ddd', peeled: 'ccc'),
      ]);
      expect(map.containsKey('ddd'), isFalse);
      expect(map['ccc'], hasLength(1));
      expect(map['ccc']!.single.isTag, isTrue);
    });
  });
}
