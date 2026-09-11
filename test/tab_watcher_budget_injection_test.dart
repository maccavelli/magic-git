// MADR 0045 phase 2. The host watcher budget is one per process, by injection.
//
// Each tab is its own root ProviderContainer, so a provider cannot be shared
// between tabs by declaring it: every container builds its own. The budget
// belongs to the host, so `TabsController` hands every container it creates
// the one instance it owns. Were that override lost, each tab would get its own
// ceiling and eight tabs would multiply the host's bound by eight — MADR 0041
// F5, which the process-wide static used to prevent by accident.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/features/tabs/tabs_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A connection that is simply there.
class _Idle extends ConnectionController {
  @override
  ConnectionState build() => const ConnectionState();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('every tab container reads the same host budget', () {
    final controller = TabsController(
      containerFactory: (overrides) => ProviderContainer(
        retry: (_, _) => null,
        overrides: [connectionProvider.overrideWith(_Idle.new), ...overrides],
      ),
    );
    addTearDown(controller.dispose);

    final first = controller.openOrFocus(
      connectionId: 'c1',
      repoPath: '/a',
      connect: (_) {},
    );
    final second = controller.openOrFocus(
      connectionId: 'c1',
      repoPath: '/b',
      connect: (_) {},
    );
    expect(second.id, isNot(first.id), reason: 'two tabs, two root containers');

    final budget = first.container.read(hostWatcherBudgetProvider);
    expect(
      identical(second.container.read(hostWatcherBudgetProvider), budget),
      isTrue,
      reason: 'the budget belongs to the host, so every tab counts against one',
    );
    expect(
      identical(first.container.read(watchAdmissionProvider).budget, budget),
      isTrue,
      reason: 'and admission is built on that budget, not on one of its own',
    );
    expect(
      identical(
        first.container.read(watchAdmissionProvider),
        second.container.read(watchAdmissionProvider),
      ),
      isFalse,
      reason:
          'exclusion is per SESSION: two tabs on one repository must still meet '
          'at the host lock, not wait on each other',
    );
  });
}
