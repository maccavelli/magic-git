// TabsController: each tab gets its own isolated session container (distinct
// executors), dedupe focuses an existing tab, shared root providers stay
// single-instance, and closing a tab disposes its container + re-activates a
// neighbor.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/tabs/tabs_controller.dart';

void main() {
  test('tabs are isolated sessions; dedupe, share root, dispose on close', () {
    final root = ProviderContainer();
    addTearDown(root.dispose);
    final tabs = TabsController(root);
    addTearDown(tabs.dispose);

    final a = tabs.openOrFocus(connectionId: 'c1', repoPath: '/a', title: 'a');
    final b = tabs.openOrFocus(connectionId: 'c2', repoPath: '/b', title: 'b');
    expect(tabs.tabs, hasLength(2));
    expect(tabs.activeId, b.id, reason: 'a freshly opened tab is active');

    // Each tab's session seam is its own instance.
    expect(
      identical(
        a.container.read(activeExecutorProvider),
        b.container.read(activeExecutorProvider),
      ),
      isFalse,
      reason: 'tabs must not share an executor',
    );
    expect(
      identical(
        a.container.read(sshClientManagerProvider),
        b.container.read(sshClientManagerProvider),
      ),
      isFalse,
      reason: 'tabs must not share an SSH client',
    );

    // Shared root provider is one instance across tabs.
    expect(
      identical(
        a.container.read(connectionStoreProvider),
        b.container.read(connectionStoreProvider),
      ),
      isTrue,
      reason: 'shared stores stay single-instance',
    );

    // Dedupe: re-selecting an open (connectionId, repoPath) focuses it.
    final again = tabs.openOrFocus(connectionId: 'c1', repoPath: '/a');
    expect(again.id, a.id);
    expect(tabs.tabs, hasLength(2), reason: 'no duplicate tab');
    expect(tabs.activeId, a.id, reason: 'dedupe activates the existing tab');

    // Close disposes the container and re-activates a neighbor.
    final closed = a.container;
    tabs.closeTab(a.id);
    expect(tabs.tabs, hasLength(1));
    expect(tabs.activeId, b.id);
    expect(
      () => closed.read(activeExecutorProvider),
      throwsA(anything),
      reason: 'closed tab container is disposed',
    );
  });

  test('openOrFocus notifies listeners', () {
    final root = ProviderContainer();
    addTearDown(root.dispose);
    final tabs = TabsController(root);
    addTearDown(tabs.dispose);

    var notifications = 0;
    tabs.addListener(() => notifications++);
    tabs.openOrFocus(connectionId: 'c1', repoPath: '/a');
    tabs.openOrFocus(connectionId: 'c1', repoPath: '/a'); // dedupe → no-op activate
    tabs.openOrFocus(connectionId: 'c2', repoPath: '/b');
    expect(notifications, 2, reason: 'two real opens; the dedupe re-focus of the '
        'already-active tab does not notify');
  });
}
