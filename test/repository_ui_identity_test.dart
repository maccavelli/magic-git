import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/storage/repository_ui_identity.dart';

void main() {
  group('RepositoryUiIdentity', () {
    test('ssh and local durable keys encode base64url without padding', () {
      final a = RepositoryUiIdentity.ssh(
        connectionId: 'conn-1',
        gitCommonDir: '/home/u/repo/.git',
      );
      final b = RepositoryUiIdentity.local(
        localRepoId: 'local-1',
        gitCommonDir: '/home/u/repo/.git',
      );

      expect(a.durable, isTrue);
      expect(b.durable, isTrue);
      expect(a.preferenceKey, isNot(contains('=')));
      expect(a.preferenceKey, isNot(contains('/home')));
      expect(a.preferenceKey, isNotEmpty);
      expect(a.preferenceKey, isNot(b.preferenceKey));
    });

    test('linked worktrees with same scope and common dir share identity', () {
      final main = RepositoryUiIdentity.ssh(
        connectionId: 'c1',
        gitCommonDir: '/repo/.git',
      );
      final linked = RepositoryUiIdentity.ssh(
        connectionId: 'c1',
        gitCommonDir: '/repo/.git',
      );
      expect(main, linked);
      expect(main.preferenceKey, linked.preferenceKey);
    });

    test('same path different SSH connection ids differ', () {
      final a = RepositoryUiIdentity.ssh(
        connectionId: 'alice',
        gitCommonDir: '/same/.git',
      );
      final b = RepositoryUiIdentity.ssh(
        connectionId: 'bob',
        gitCommonDir: '/same/.git',
      );
      expect(a.preferenceKey, isNot(b.preferenceKey));
    });

    test('independently saved local ids differ even with same common dir', () {
      final a = RepositoryUiIdentity.local(
        localRepoId: 'bookmark-a',
        gitCommonDir: '/shared/.git',
      );
      final b = RepositoryUiIdentity.local(
        localRepoId: 'bookmark-b',
        gitCommonDir: '/shared/.git',
      );
      expect(a.preferenceKey, isNot(b.preferenceKey));
    });

    test('adhoc is never durable and includes session epoch', () {
      final a = RepositoryUiIdentity.adhoc(
        backend: 'ssh',
        sessionEpoch: 3,
        gitCommonDir: '/tmp/r/.git',
      );
      final b = RepositoryUiIdentity.adhoc(
        backend: 'ssh',
        sessionEpoch: 4,
        gitCommonDir: '/tmp/r/.git',
      );
      expect(a.durable, isFalse);
      expect(a.sessionEpoch, 3);
      expect(a.memoryKey, isNot(b.memoryKey));
      expect(a.scopeKey, contains('adhoc:ssh:3'));
    });

    test('unresolved layout is session-only', () {
      final id = RepositoryUiIdentity.sessionOnlyUnresolved(
        backend: 'local',
        sessionEpoch: 2,
        repoPathFallback: '/tmp/missing',
      );
      expect(id.durable, isFalse);
      expect(id.gitCommonDir, startsWith('unresolved:'));
    });

    test('identity uses public sessionEpoch only — never a controller', () {
      final adhoc = RepositoryUiIdentity.adhoc(
        backend: 'ssh',
        sessionEpoch: 42,
        gitCommonDir: '/x/.git',
      );
      expect(adhoc.sessionEpoch, 42);
      expect(adhoc.scopeKey, 'adhoc:ssh:42');
      final durable = RepositoryUiIdentity.ssh(
        connectionId: 'saved-1',
        gitCommonDir: '/x/.git',
      );
      expect(durable.sessionEpoch, isNull);
      expect(durable.scopeKey, 'ssh:saved-1');
    });
  });
}
