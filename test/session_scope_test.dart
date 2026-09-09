import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/providers/session_scope.dart';

import 'helpers/app_scope.dart';

void main() {
  group('sessionScopeProvider', () {
    test('is stable within one container', () {
      final container = appProviderContainer();
      addTearDown(container.dispose);

      final first = container.read(sessionScopeProvider);
      final second = container.read(sessionScopeProvider);

      expect(
        identical(first, second),
        isTrue,
        reason:
            'a plain Provider caches its value; a fresh mint per read '
            'would split every partition keyed on it mid-session',
      );
      expect(first, second);
    });

    test('two containers get distinct scopes', () {
      final a = appProviderContainer();
      final b = appProviderContainer();
      addTearDown(a.dispose);
      addTearDown(b.dispose);

      final scopeA = a.read(sessionScopeProvider);
      final scopeB = b.read(sessionScopeProvider);

      expect(scopeA, isNot(scopeB));
      expect(scopeA.id, isNot(scopeB.id));
      expect(
        {scopeA, scopeB},
        hasLength(2),
        reason: 'the partitions are Map keys — they must not collide',
      );
    });

    test('a third container does not reuse a disposed scope id', () {
      final first = appProviderContainer();
      final firstScope = first.read(sessionScopeProvider);
      first.dispose();

      final second = appProviderContainer();
      addTearDown(second.dispose);

      expect(
        second.read(sessionScopeProvider),
        isNot(firstScope),
        reason:
            'ids are monotonic, never recycled: a recycled id would let a '
            'new session inherit a dead one\'s cache and prefs entries',
      );
    });

    test('can be overridden, so isolation tests can pin ids', () {
      const pinned = SessionScope(9999);
      final container = appProviderContainer(
        overrides: [sessionScopeProvider.overrideWithValue(pinned)],
      );
      addTearDown(container.dispose);

      expect(container.read(sessionScopeProvider), pinned);
    });

    test('equality and hashCode are by id alone', () {
      expect(const SessionScope(7), const SessionScope(7));
      expect(const SessionScope(7).hashCode, const SessionScope(7).hashCode);
      expect(const SessionScope(7), isNot(const SessionScope(8)));
      expect(const SessionScope(7).toString(), 'session#7');
    });
  });
}
