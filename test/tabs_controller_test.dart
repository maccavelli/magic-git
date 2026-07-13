// TabsController: separate-root-per-tab isolation, blank-landing-tab reuse,
// dedupe by (connectionId, repoPath), and close = disconnect-then-dispose.
// Each tab gets a recorder ConnectionController via the containerFactory seam,
// so connect/disconnect are observable and no real SSH is touched.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/storage/saved_connection.dart';
import 'package:remote_magic_git/features/tabs/tabs_controller.dart';

class _Recorder extends ConnectionController {
  final calls = <String>[];
  bool disconnected = false;

  @override
  ConnectionState build() => const ConnectionState();

  @override
  Future<void> connectToSaved(SavedConnection conn, {String? repoPath}) async {
    calls.add('save:${conn.id}:$repoPath');
  }

  @override
  Future<void> connectLocal(String repoPath, {String? label, String? id}) async {
    calls.add('local:$repoPath:$id');
  }

  @override
  Future<void> disconnect() async => disconnected = true;
}

const _conn = SavedConnection(
  id: 'c1',
  label: 'P',
  host: 'h',
  port: 22,
  username: 'u',
  repoPath: '/a',
  repoPaths: ['/a'],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  TabsController makeController() => TabsController(
    containerFactory: (overrides) => ProviderContainer(
      retry: (_, _) => null,
      overrides: [connectionProvider.overrideWith(_Recorder.new), ...overrides],
    ),
  );

  void connectSaved(ProviderContainer c, String repoPath) =>
      c.read(connectionProvider.notifier).connectToSaved(_conn, repoPath: repoPath);

  test('blank landing tab is reused for the first repo; new repos open new tabs',
      () {
    final c = makeController();
    addTearDown(c.dispose);
    final t0 = c.ensureInitialTab();
    expect(t0.isBlank, isTrue);
    expect(c.tabs, hasLength(1));

    final t1 = c.openOrFocus(
      connectionId: 'c1',
      repoPath: '/a',
      connect: (cont) => connectSaved(cont, '/a'),
    );
    expect(t1.id, t0.id, reason: 'the blank tab is reused, not duplicated');
    expect(c.tabs, hasLength(1));
    expect((t1.container.read(connectionProvider.notifier) as _Recorder).calls,
        ['save:c1:/a']);
    expect(t1.connectionId, 'c1');
    expect(t1.repoPath, '/a');

    final t2 = c.openOrFocus(
      connectionId: 'c1',
      repoPath: '/b',
      connect: (cont) => connectSaved(cont, '/b'),
    );
    expect(t2.id, isNot(t1.id));
    expect(c.tabs, hasLength(2));
    expect(c.activeId, t2.id);
  });

  test('dedupe focuses an already-open (connectionId, repoPath) tab', () {
    final c = makeController();
    addTearDown(c.dispose);
    c.ensureInitialTab();
    final t1 = c.openOrFocus(
      connectionId: 'c1',
      repoPath: '/a',
      connect: (cont) => connectSaved(cont, '/a'),
    );
    final t2 = c.openOrFocus(
      connectionId: 'c1',
      repoPath: '/b',
      connect: (cont) => connectSaved(cont, '/b'),
    );
    c.activate(t2.id);

    var connectCalled = false;
    final again = c.openOrFocus(
      connectionId: 'c1',
      repoPath: '/a',
      connect: (_) => connectCalled = true,
    );
    expect(again.id, t1.id);
    expect(connectCalled, isFalse, reason: 'an open repo is focused, not reconnected');
    expect(c.activeId, t1.id);
    expect(c.tabs, hasLength(2));
  });

  test('each tab is an isolated session container', () {
    final c = makeController();
    addTearDown(c.dispose);
    c.ensureInitialTab();
    final t1 = c.openOrFocus(connectionId: 'c1', repoPath: '/a', connect: (_) {});
    final t2 = c.openOrFocus(connectionId: 'c1', repoPath: '/b', connect: (_) {});
    expect(
      identical(t1.container.read(activeExecutorProvider),
          t2.container.read(activeExecutorProvider)),
      isFalse,
    );
    expect(
      identical(t1.container.read(connectionProvider.notifier),
          t2.container.read(connectionProvider.notifier)),
      isFalse,
    );
  });

  test('close disconnects the session, then disposes the container', () async {
    final c = makeController();
    addTearDown(c.dispose);
    c.ensureInitialTab();
    final t1 = c.openOrFocus(connectionId: 'c1', repoPath: '/a', connect: (_) {});
    final t2 = c.openOrFocus(connectionId: 'c1', repoPath: '/b', connect: (_) {});
    final rec2 = t2.container.read(connectionProvider.notifier) as _Recorder;
    final closed = t2.container;

    await c.close(t2.id);
    expect(rec2.disconnected, isTrue, reason: 'graceful disconnect before dispose');
    expect(() => closed.read(activeExecutorProvider), throwsA(anything),
        reason: 'container disposed');
    expect(c.tabs, hasLength(1));
    expect(c.activeId, t1.id);
  });

  test('closing the active tab reassigns active synchronously — never null-active '
      'during the disconnect await', () async {
    final c = makeController();
    addTearDown(c.dispose);
    c.ensureInitialTab();
    final t1 = c.openOrFocus(connectionId: 'c1', repoPath: '/a', connect: (_) {});
    final t2 = c.openOrFocus(connectionId: 'c1', repoPath: '/b', connect: (_) {});
    expect(c.activeId, t2.id);

    // Do NOT await: disconnect() is async, so these assertions run DURING the
    // teardown window. `active` must already point at the neighbor — TabsHost's
    // MacosApp builder derefs `active!` on any rebuild (which a background tab's
    // connection flip can trigger mid-close), so a transient null would crash.
    final pending = c.close(t2.id);
    expect(c.active, isNotNull, reason: 'no null-active window during disconnect');
    expect(c.activeId, t1.id);
    await pending;
    expect(c.activeId, t1.id);
    expect(c.tabs, hasLength(1));
  });

  test('closing the last tab leaves a fresh blank landing tab', () async {
    final c = makeController();
    addTearDown(c.dispose);
    c.ensureInitialTab();
    c.openOrFocus(connectionId: 'c1', repoPath: '/a', connect: (_) {}); // reuses it
    await c.close(c.activeId!);
    expect(c.tabs, hasLength(1));
    expect(c.active!.isBlank, isTrue);
  });

  test('newTab opens a fresh blank tab, but reuses an already-blank active one',
      () {
    final c = makeController();
    addTearDown(c.dispose);
    final t0 = c.ensureInitialTab();
    // Active tab is already blank — "+" focuses it rather than stacking a
    // duplicate empty tab.
    final again = c.newTab();
    expect(again.id, t0.id);
    expect(c.tabs, hasLength(1));

    // With a connected active tab, "+" opens a new blank landing tab.
    c.openOrFocus(connectionId: 'c1', repoPath: '/a', connect: (_) {});
    final fresh = c.newTab();
    expect(fresh.isBlank, isTrue);
    expect(c.tabs, hasLength(2));
    expect(c.activeId, fresh.id);
  });

  test('reorder moves a tab to its target slot; active tab is unchanged', () {
    final c = makeController();
    addTearDown(c.dispose);
    c.ensureInitialTab();
    final a = c.openOrFocus(connectionId: 'a', repoPath: '/a', connect: (_) {});
    final b = c.openOrFocus(connectionId: 'b', repoPath: '/b', connect: (_) {});
    final cc = c.openOrFocus(connectionId: 'c', repoPath: '/c', connect: (_) {});
    c.activate(b.id);
    expect(c.tabs.map((t) => t.id), [a.id, b.id, cc.id]);

    // Drag the first tab to the end.
    c.reorder(0, 2);
    expect(c.tabs.map((t) => t.id), [b.id, cc.id, a.id]);
    expect(c.activeId, b.id, reason: 'reorder tracks by id, not position');

    // Drag it back to the front.
    c.reorder(2, 0);
    expect(c.tabs.map((t) => t.id), [a.id, b.id, cc.id]);

    // Out-of-range / no-op reorders are safe.
    c.reorder(1, 1);
    c.reorder(9, 0);
    expect(c.tabs.map((t) => t.id), [a.id, b.id, cc.id]);
  });

  test('stops opening new tabs at the cap; dedupe/focus still work', () {
    final c = makeController();
    addTearDown(c.dispose);
    c.ensureInitialTab();
    // Fill to the cap: the blank tab is reused for the first, then new tabs.
    for (var i = 0; i < TabsController.maxTabs; i++) {
      c.openOrFocus(connectionId: 'c$i', repoPath: '/r$i', connect: (_) {});
    }
    expect(c.tabs, hasLength(TabsController.maxTabs));
    expect(c.canOpenTab, isFalse);

    // A brand-new repo past the cap does NOT open a ninth tab.
    var connected = false;
    c.openOrFocus(
      connectionId: 'overflow',
      repoPath: '/over',
      connect: (_) => connected = true,
    );
    expect(c.tabs, hasLength(TabsController.maxTabs));
    expect(connected, isFalse, reason: 'no ninth session is created');

    // "+" is a no-op at the cap.
    c.newTab();
    expect(c.tabs, hasLength(TabsController.maxTabs));

    // An already-open repo is still focused (dedupe never blocked by the cap).
    final again = c.openOrFocus(
      connectionId: 'c0',
      repoPath: '/r0',
      connect: (_) {},
    );
    expect(again.connectionId, 'c0');
    expect(c.activeId, again.id);
    expect(c.tabs, hasLength(TabsController.maxTabs));
  });
}
