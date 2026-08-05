import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/features/branches/pinned_branches.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _repo = '/repo/path';

/// A minimal widget that materialises a [WidgetRef] by living in a
/// [UncontrolledProviderScope] tree long enough to call [setPinnedBranch].
class _RefHarness extends ConsumerStatefulWidget {
  final Future<void> Function(WidgetRef ref) onRef;
  const _RefHarness(this.onRef);

  @override
  ConsumerState<_RefHarness> createState() => _RefHarnessState();
}

class _RefHarnessState extends ConsumerState<_RefHarness> {
  late final Future<void> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.onRef(ref);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _future,
      builder: (_, snapshot) {
        if (snapshot.hasError) throw snapshot.error!;
        return const SizedBox.shrink();
      },
    );
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
    testWidgets('pins a branch and refreshes the provider', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: _RefHarness(
            (ref) => setPinnedBranch(ref, _repo, 'main', pinned: true),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final storage = await SharedPreferences.getInstance();
      expect(storage.getStringList('pinnedBranches_$_repo'), ['main']);
      final updated = await container.read(
        pinnedBranchesProvider(_repo).future,
      );
      expect(updated, {'main'});
    });

    testWidgets('unpins a branch and refreshes the provider', (tester) async {
      SharedPreferences.setMockInitialValues({
        'pinnedBranches_$_repo': ['main', 'develop'],
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: _RefHarness(
            (ref) => setPinnedBranch(ref, _repo, 'main', pinned: false),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final updated = await container.read(
        pinnedBranchesProvider(_repo).future,
      );
      expect(updated, {'develop'});
    });

    testWidgets('unpinning the last branch removes the prefs key', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        'pinnedBranches_$_repo': ['main'],
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: _RefHarness(
            (ref) => setPinnedBranch(ref, _repo, 'main', pinned: false),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey('pinnedBranches_$_repo'), isFalse);
    });
  });
}
