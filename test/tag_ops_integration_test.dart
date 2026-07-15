// Tag remote operations against real git with a real (file-protocol) remote:
// what lsRemoteTags actually parses, that its unpeeled oid equals the local
// GitRef.oid (tag OBJECT, not commit) and correctly predicts push rejection
// for a re-tagged name, and the pushTags / deleteRemoteTag round trips. The
// unit tests pin the argv; only real git can pin what the argv MEANS.
@Tags(['integration'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/exec/local_command_executor.dart';
import 'package:remote_magic_git/core/git/git_service.dart';

void main() {
  late Directory tempDir;
  late String origin;
  late String repo;
  late GitService git;

  Future<String> raw(List<String> args, {String? cwd}) async {
    final result = await Process.run(
      'git',
      args,
      workingDirectory: cwd ?? repo,
    );
    expect(
      result.exitCode,
      0,
      reason: 'setup `git ${args.join(' ')}` failed: ${result.stderr}',
    );
    return (result.stdout as String).trim();
  }

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('tag_ops_');
    final root = tempDir.resolveSymbolicLinksSync();
    origin = '$root/origin';
    repo = '$root/repo';
    Directory(origin).createSync(recursive: true);
    git = GitService(LocalCommandExecutor());

    await raw(['init', '-q', '--bare', origin], cwd: root);
    await raw(['init', '-q', '-b', 'main', repo], cwd: root);
    await raw(['config', 'user.name', 'T']);
    await raw(['config', 'user.email', 't@t']);
    await raw(['config', 'commit.gpgsign', 'false']);
    await raw(['commit', '-q', '--allow-empty', '-m', 'one']);
    await raw(['remote', 'add', 'origin', origin]);
    await raw(['push', '-q', '-u', 'origin', 'main']);
  });

  tearDown(() => tempDir.deleteSync(recursive: true));

  Future<GitRef> tagRef(String name) async => (await git.refs(
        repo,
      )).singleWhere((r) => r.name == 'refs/tags/$name');

  test('full cycle: create → ls-remote empty → push → present with the tag-'
      'object oid → re-tag diverges and is rejected → delete on remote',
      () async {
    await git.createTag(repo, 'wip'); // lightweight
    await git.createTag(repo, 'v1.0', message: 'release notes'); // annotated

    expect(await git.lsRemoteTags(repo), isEmpty,
        reason: 'nothing pushed yet — and an empty map is NOT null (the '
            'remote was reachable and answered "no tags")');

    await git.pushTag(repo, 'v1.0');
    final afterOne = await git.lsRemoteTags(repo);
    final local = await tagRef('v1.0');
    expect(afterOne, {'v1.0': local.oid},
        reason: 'the unpeeled ls-remote oid IS the local tag object');
    expect(local.oid, isNot(local.peeledOid),
        reason: 'annotated: tag object and peeled commit differ — comparing '
            'peeled oids would be the wrong equality');

    // Bulk push covers the remaining local-only tag.
    await git.pushTags(repo, ['wip', 'v1.0']);
    expect((await git.lsRemoteTags(repo))!.keys.toSet(), {'wip', 'v1.0'});

    // Re-tag v1.0 at the SAME commit with a different message: the peeled
    // commit is identical, but the ref-level oid differs — the state the
    // tags list must show as "differs", because a push IS rejected.
    await raw(['tag', '-d', 'v1.0']);
    await raw(['tag', '-a', '-m', 'rewritten notes', 'v1.0']);
    final retagged = await tagRef('v1.0');
    final remote = (await git.lsRemoteTags(repo))!;
    expect(remote['v1.0'], isNot(retagged.oid));
    expect(retagged.peeledOid, local.peeledOid,
        reason: 'same commit — only the tag object changed');
    await expectLater(
      () => git.pushTag(repo, 'v1.0'),
      throwsA(isA<GitException>()),
    );

    await git.deleteRemoteTag(repo, 'origin', 'v1.0');
    expect((await git.lsRemoteTags(repo))!.keys.toSet(), {'wip'});
    expect(await raw(['tag', '--list', 'v1.0']), 'v1.0',
        reason: 'the local tag is untouched by the remote delete');
  });

  test('an unreachable remote yields null (unknown), never a throw', () async {
    await raw(['remote', 'set-url', 'origin', '/nonexistent/nowhere.git']);
    expect(await git.lsRemoteTags(repo), isNull);
  });
}
