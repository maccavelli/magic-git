// recentConnectionsProvider: newest-first by lastConnectedAt, capped at 3,
// with never-connected profiles sorted last.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/storage/saved_connection.dart';

SavedConnection _c(String id, DateTime? at) => SavedConnection(
  id: id,
  label: id,
  host: 'h',
  port: 22,
  username: 'u',
  repoPath: '/r',
  lastConnectedAt: at,
);

void main() {
  test('returns the 3 newest by lastConnectedAt, nulls last', () async {
    final all = [
      _c('never', null),
      _c('old', DateTime.utc(2026, 1, 1)),
      _c('newest', DateTime.utc(2026, 6, 1)),
      _c('mid', DateTime.utc(2026, 3, 1)),
    ];
    final container = ProviderContainer(
      overrides: [savedConnectionsProvider.overrideWith((ref) => all)],
    );
    addTearDown(container.dispose);
    await container.read(savedConnectionsProvider.future);

    final recent = container.read(recentConnectionsProvider);
    expect(recent.map((c) => c.id).toList(), ['newest', 'mid', 'old']);
  });

  test(
    'never-connected profiles keep their stored order (stable tiebreaker)',
    () async {
      // All null timestamps: the comparator treats them as equal, so ordering
      // must fall back to the original stored index rather than reordering.
      final all = [
        _c('a', null),
        _c('b', null),
        _c('c', null),
        _c('d', null),
      ];
      final container = ProviderContainer(
        overrides: [savedConnectionsProvider.overrideWith((ref) => all)],
      );
      addTearDown(container.dispose);
      await container.read(savedConnectionsProvider.future);

      final recent = container.read(recentConnectionsProvider);
      expect(recent.map((c) => c.id).toList(), ['a', 'b', 'c']);
    },
  );

  test('is empty when there are no saved connections', () async {
    final container = ProviderContainer(
      overrides: [
        savedConnectionsProvider.overrideWith((ref) => const <SavedConnection>[]),
      ],
    );
    addTearDown(container.dispose);
    await container.read(savedConnectionsProvider.future);
    expect(container.read(recentConnectionsProvider), isEmpty);
  });
}
