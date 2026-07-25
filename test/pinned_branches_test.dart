import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/features/branches/pinned_branches.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _repo = '/repo/path';

/// A minimal widget that materialises a [WidgetRef] by living in a
/// [UncontrolledProviderScope] tree long enough to call [setPinnedBranch].
class _RefHarness extends ConsumerWidget {
  final Future<void> Function(WidgetRef ref) onRef;
  const _RefHarness(this.onRef);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    onRef(ref);
    return const SizedBox.shrink();
  }
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
  });

  group('pinnedBranchesProvider', () {
    test('returns empty set when nothing is stored', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final set = await container.read(pinnedBranchesProvider(_repo).future);
      expect(set, isEmpty);
    });

    test('returns stored branches', () async {
      SharedPreferences.setMockInitialValues({
        'pinnedBranches_$_repo': ['main', 'develop'],
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final set = await container.read(pinnedBranchesProvider(_repo).future);
      expect(set, {'main', 'develop'});
    });
  });

  group('setPinnedBranch', () {
    testWidgets('pins a branch and refreshes the provider',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const _RefHarness(_doPin),
        ),
      );
      // Let the async call in _doPin complete.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      final updated = await container.read(pinnedBranchesProvider(_repo).future);
      expect(updated, {'main'});
    });

    testWidgets('unpins a branch and refreshes the provider',
        (tester) async {
      SharedPreferences.setMockInitialValues({
        'pinnedBranches_$_repo': ['main', 'develop'],
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const _RefHarness(_doUnpin),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      final updated = await container.read(pinnedBranchesProvider(_repo).future);
      expect(updated, {'develop'});
    });

    testWidgets('unpinning the last branch removes the prefs key',
        (tester) async {
      SharedPreferences.setMockInitialValues({
        'pinnedBranches_$_repo': ['main'],
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const _RefHarness(_doUnpinLast),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey('pinnedBranches_$_repo'), isFalse);
    });
  });
}

Future<void> _doPin(WidgetRef ref) async {
  await setPinnedBranch(ref, _repo, 'main', pinned: true);
}

Future<void> _doUnpin(WidgetRef ref) async {
  await setPinnedBranch(ref, _repo, 'main', pinned: false);
}

Future<void> _doUnpinLast(WidgetRef ref) async {
  await setPinnedBranch(ref, _repo, 'main', pinned: false);
}
