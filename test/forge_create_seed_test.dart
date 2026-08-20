import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/features/forge/forge_prefs.dart';
import 'package:remote_magic_git/features/forge/forge_selection.dart';

void main() {
  test('forgeCreateSeed stores baseRef and clears', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final n = container.read(forgeCreateSeedProvider.notifier);
    n.set('/repo', 'feature', baseRef: 'main');
    final seed = container.read(forgeCreateSeedProvider);
    expect(seed?.repoPath, '/repo');
    expect(seed?.branch, 'feature');
    expect(seed?.baseRef, 'main');
    n.clear();
    expect(container.read(forgeCreateSeedProvider), isNull);
  });

  test('ForgeCreatingChangeRequest carries seedBase', () {
    const sel = ForgeCreatingChangeRequest(
      seedSource: 'feature',
      seedBase: 'develop',
    );
    expect(sel.seedSource, 'feature');
    expect(sel.seedBase, 'develop');
  });

  test('historyNavigationIntent set and clear', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final n = container.read(historyNavigationIntentProvider.notifier);
    n.set('/repo', 'feature');
    expect(
      container.read(historyNavigationIntentProvider)?.revision,
      'feature',
    );
    n.clear();
    expect(container.read(historyNavigationIntentProvider), isNull);
  });
}
