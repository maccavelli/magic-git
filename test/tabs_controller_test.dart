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

  test('closing the last tab leaves a fresh blank landing tab', () async {
    final c = makeController();
    addTearDown(c.dispose);
    c.ensureInitialTab();
    c.openOrFocus(connectionId: 'c1', repoPath: '/a', connect: (_) {}); // reuses it
    await c.close(c.activeId!);
    expect(c.tabs, hasLength(1));
    expect(c.active!.isBlank, isTrue);
  });
}
