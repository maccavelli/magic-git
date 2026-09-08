// MADR 0038 F7 — the tab lifecycle every workspace entry point runs, tested
// directly for the first time.
//
// Until this file, `WorkspaceProvisioning` and `workspace_open_in_tab.dart` —
// 257 lines carrying session takeover, tab routing and the security-scoped
// grant guard — had **zero** direct test callers across the whole suite. They
// were exercised only as a side effect of pumping three sheet UIs, which is
// why the tab lifecycle beside them could be hand-copied into all three sheets
// and drift unnoticed.
//
// Everything here runs with no `pumpWidget`. That is the point: these are
// invariants of the lifecycle, not of any sheet.

import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/local/scoped_access.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/providers/provider_retry_policy.dart';
import 'package:remote_magic_git/core/storage/local_repo_store.dart';
import 'package:remote_magic_git/core/storage/saved_local_repo.dart';
import 'package:remote_magic_git/features/tabs/tabs_controller.dart';
import 'package:remote_magic_git/features/workspace/workspace_flow.dart';
import 'package:remote_magic_git/features/workspace/workspace_registration.dart';
import 'package:riverpod/misc.dart' show Override;

/// A tabs controller whose tabs are cheap containers, and which records the
/// closes and activations the flow performs.
class _Tabs extends TabsController {
  _Tabs({this.cap = 8})
    : super(
        containerFactory: (List<Override> overrides) =>
            ProviderContainer(retry: noProviderRetry, overrides: overrides),
      );

  final int cap;
  final List<String> closed = [];
  final List<String> activated = [];

  @override
  bool get canOpenTab => tabs.length < cap;

  @override
  Future<void> close(String id) async {
    closed.add(id);
    await super.close(id);
  }

  @override
  void activate(String id) {
    activated.add(id);
    super.activate(id);
  }
}

/// Records what a local open asked of the session. Ported from
/// `workspace_registration_test.dart`, where the same fake was driven through a
/// pumped `_RefHarness` widget to obtain a `WidgetRef`; the function now takes
/// a [ProviderContainer], so no widget is needed at all.
class _FakeConnection extends ConnectionController {
  _FakeConnection([ConnectionState? state])
    : _state =
          state ??
          const ConnectionState(
            phase: ConnectionPhase.connected,
            repoPath: '/',
            connectionId: 'conn-1',
          );

  ConnectionState _state;
  String? recordedConnectLocalRepoPath;
  String? recordedConnectLocalLabel;
  String? recordedConnectLocalId;

  @override
  ConnectionState build() => _state;

  @override
  Future<void> connectLocal(
    String repoPath, {
    String? label,
    String? id,
    String? mainRepoPath,
    String? gitDir,
  }) async {
    recordedConnectLocalRepoPath = repoPath;
    recordedConnectLocalLabel = label;
    recordedConnectLocalId = id;
    _state = _state.copyWith(
      phase: ConnectionPhase.connected,
      repoPath: repoPath,
    );
  }
}

/// A connect that never lands — the phase stays disconnected, exactly what a
/// bad path or a dead transport produces.
class _FailingConnection extends _FakeConnection {
  _FailingConnection()
    : super(const ConnectionState(phase: ConnectionPhase.disconnected));

  @override
  Future<void> connectLocal(
    String repoPath, {
    String? label,
    String? id,
    String? mainRepoPath,
    String? gitDir,
  }) async {
    recordedConnectLocalRepoPath = repoPath;
  }
}

class _FakeLocalRepoStore extends LocalRepoStore {
  SavedLocalRepo? saved;

  @override
  Future<void> save(SavedLocalRepo repo) async => saved = repo;
}

/// Counts native start/stop so a grant leak is visible.
class _Grants {
  final List<String> acquired = [];
  final List<String> released = [];
  late final ScopedAccess access = ScopedAccess(
    startAccessing: (bookmark) async {
      acquired.add(bookmark);
      return '/resolved';
    },
    stopAccessing: (path) async => released.add(path),
  );
}

void main() {
  // No `testWidgets` in this file — that is the point — so nothing else
  // initializes the binding, and the mock method-channel handler the ported
  // tests install needs one.
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderContainer origin;
  late _Tabs tabs;

  setUp(() {
    origin = ProviderContainer(retry: noProviderRetry);
    addTearDown(origin.dispose);
    tabs = _Tabs();
    addTearDown(tabs.dispose);
  });

  /// A tab that is **not** blank, and is therefore never reused by `newTab()`
  /// (`tabs_controller.dart:248-255`). Without this a test that means "the
  /// user is working in a tab" silently gets the landing case instead — where
  /// the flow correctly reuses the blank tab and closes nothing — and a loop
  /// that fills tabs with blank ones never reaches the cap at all.
  RepoTab occupied(_Tabs controller, String id) {
    final t = controller.newTab()
      ..connectionId = id
      ..repoPath = '/srv/$id';
    controller.activate(t.id);
    return t;
  }

  WorkspaceFlow flow({ScopedAccess? access, _Tabs? controller}) =>
      WorkspaceFlow(
        origin: origin,
        tabsOverride: controller ?? tabs,
        accessOverride: access,
      );

  group('claiming a tab', () {
    test('the origin container is used until a tab is claimed', () async {
      final f = flow();
      expect(f.tab, isNull);
      expect(f.container, same(origin));

      await f.ensureTab();

      expect(f.tab, isNotNull);
      expect(
        f.container,
        same(f.tab!.container),
        reason:
            'work runs in the claimed tab, not the sheet it was opened from',
      );
    });

    test('the captured container never follows the active tab', () async {
      // MADR 0038 F3 in its structural form: a sheet's `ref` re-resolves to
      // whichever tab is active (tabs_host.dart:500-505), which is why the
      // sheets captured `own` by hand. The flow has no ambient ref at all.
      final f = flow();
      await f.ensureTab();
      final claimed = f.container;
      // The dial would fill these in; without them the claimed tab is still
      // blank and `newTab()` below hands back that same tab.
      f.tab!
        ..connectionId = 'dialled'
        ..repoPath = '/srv/dialled';

      // Someone clicks another tab mid-flight. It must be OCCUPIED: the tab
      // the flow just claimed is blank, so `newTab()` would hand back that
      // same tab and the active tab would never actually change — the
      // mutation `the flow re-resolves its container` survived on exactly
      // that.
      final other = occupied(tabs, 'other');
      expect(other.id, isNot(f.tab!.id), reason: 'a genuinely different tab');
      expect(tabs.activeId, other.id);

      expect(f.container, same(claimed));
      expect(f.container, isNot(same(other.container)));
    });

    test('a second ensureTab claims nothing new', () async {
      final f = flow();
      await f.ensureTab();
      final first = f.tab;
      await f.ensureTab();
      expect(f.tab, same(first));
    });

    test('with no tabs host, the sheet works in its own container', () async {
      final f = WorkspaceFlow(origin: origin, tabsOverride: null);
      TabsController.current = null;
      addTearDown(() => TabsController.current = null);

      expect(await f.ensureTab(), isTrue, reason: 'not a refusal');
      expect(f.tab, isNull);
      expect(f.container, same(origin));
    });
  });

  group('the tab cap', () {
    test('a flow that opens a tab is refused at the cap', () {
      final full = _Tabs(cap: 1);
      addTearDown(full.dispose);
      full.newTab();

      final f = flow(controller: full);
      expect(f.refusedAtTabCap(opensNewTab: true), isTrue);
    });

    test('a flow that opens no tab is never refused', () {
      final full = _Tabs(cap: 1);
      addTearDown(full.dispose);
      full.newTab();

      expect(
        flow(controller: full).refusedAtTabCap(opensNewTab: false),
        isFalse,
        reason: 'an unsaved local open lands in place (MADR 0036, 5B)',
      );
    });

    test('a flow refused at the cap claims nothing', () async {
      final full = _Tabs(cap: 1);
      addTearDown(full.dispose);
      full.newTab();
      final before = full.tabs.length;

      final f = flow(controller: full);
      expect(await f.ensureTab(), isFalse);
      expect(f.tab, isNull);
      expect(full.tabs, hasLength(before), reason: 'no tab was opened');
    });

    test('a flow already holding a tab is not refused again', () async {
      final f = flow();
      await f.ensureTab();
      // Fill the rest with OCCUPIED tabs: `newTab()` reuses a blank active
      // tab, so a loop of blank ones never reaches the cap — it spins.
      var n = 0;
      while (tabs.canOpenTab) {
        occupied(tabs, 'filler${n++}');
      }
      expect(f.refusedAtTabCap(opensNewTab: true), isFalse);
    });
  });

  group('giving the tab back', () {
    test('abandon closes the claimed tab and returns to the origin', () async {
      final home = occupied(tabs, 'home');
      final f = flow();
      await f.ensureTab();
      final claimed = f.tab!;

      // `occupied` activates the home tab itself, so `contains(home.id)` would
      // pass on the setup's own activation and prove nothing — which is how
      // the mutation `abandon does not return to the origin tab` survived.
      // Measure only what `abandon` adds.
      final before = tabs.activated.length;

      await f.abandon(releaseSession: () async {});

      expect(tabs.closed, [claimed.id]);
      expect(tabs.activated.skip(before), [
        home.id,
      ], reason: 'the user lands back where they opened the sheet from');
      expect(f.tab, isNull);
    });

    test('the session is released before the tab is closed', () async {
      final order = <String>[];
      occupied(tabs, 'home');
      final f = flow();
      await f.ensureTab();
      final claimed = f.tab!;

      await f.abandon(
        releaseSession: () async {
          // The clone sheet's routed-job teardown runs here, and it ran before
          // resetProvisioning in the hand-rolled copy — which is why this is a
          // callback rather than a fixed call.
          order.add('release');
        },
      );
      order.add('closed:${tabs.closed.single}');

      expect(order, ['release', 'closed:${claimed.id}']);
    });

    test('abandon with no claimed tab still releases the session', () async {
      var released = false;
      final f = flow();

      await f.abandon(releaseSession: () async => released = true);

      expect(released, isTrue);
      expect(tabs.closed, isEmpty);
    });

    test('a reused blank tab is left alone', () async {
      // The landing page: the active tab is already blank, `newTab()` reuses
      // it rather than stacking a second empty one, and closing it would take
      // the workspace the user is in.
      final blank = tabs.ensureInitialTab();
      tabs.activate(blank.id);
      final f = flow();
      await f.ensureTab();

      expect(f.tab!.id, blank.id, reason: 'the blank tab was reused');

      await f.abandon(releaseSession: () async {});

      expect(tabs.closed, isEmpty);
    });

    test(
      'keep() hands the tab over, so a later abandon closes nothing',
      () async {
        final home = occupied(tabs, 'home');
        final f = flow();
        await f.ensureTab();

        // Measure only what `abandon` does: `occupied` activates the home tab
        // itself, so asserting on the whole list would pass on the setup's own
        // activation and prove nothing.
        final activationsBefore = tabs.activated.length;
        final closedBefore = tabs.closed.length;

        f.keep(); // the work succeeded; the tab IS the workspace now
        await f.abandon(releaseSession: () async {});

        expect(tabs.closed, hasLength(closedBefore));
        expect(tabs.activated, hasLength(activationsBefore));
        expect(home.id, isNot(f.tab?.id));
      },
    );
  });

  group('placing the result (MADR 0038 F3/F8)', () {
    test(
      'a local result opens in the captured container, not the active tab',
      () async {
        // F3 in its observable form. The sheets used to reach `openResult`'s
        // local branches through a `WidgetRef`, which re-resolves to whichever
        // tab is active (`tabs_host.dart:500-505`) — so clicking another tab
        // during a clone connected the finished repository into THAT tab.
        final mine = _FakeConnection();
        final theirs = _FakeConnection();
        final own = ProviderContainer(
          retry: noProviderRetry,
          overrides: [connectionProvider.overrideWith(() => mine)],
        );
        addTearDown(own.dispose);

        final other = _Tabs();
        addTearDown(other.dispose);
        final elsewhere = other.newTab()
          ..connectionId = 'other'
          ..repoPath = '/srv/other';
        elsewhere.container.read(connectionProvider.notifier);
        other.activate(elsewhere.id);

        final f = WorkspaceFlow(origin: own, tabsOverride: other);

        final ok = await f.openResult(
          const WorkspaceOpenRequest(
            dest: '/Users/me/app',
            isLocalTarget: true,
            saveLocal: false,
            localLabel: 'App',
          ),
        );

        expect(ok, isTrue);
        expect(mine.recordedConnectLocalRepoPath, '/Users/me/app');
        expect(
          theirs.recordedConnectLocalRepoPath,
          isNull,
          reason: 'the active tab is not where the result belongs',
        );
      },
    );

    test('an SSH result with no connection or token reports false', () async {
      final f = flow();
      expect(
        await f.openResult(
          const WorkspaceOpenRequest(
            dest: '/srv/app',
            isLocalTarget: false,
            saveLocal: false,
          ),
        ),
        isFalse,
        reason: 'a silent true here flashes green Complete (0009 H19)',
      );
    });
  });

  // -------------------------------------------------------------------------
  // Ported from `workspace_registration_test.dart` (MADR 0038, maintainer's
  // decision 2026-09-08). The function moved from a `WidgetRef` to a
  // `ProviderContainer` in this phase (F3), so these no longer need a pumped
  // `_RefHarness` widget to obtain a ref — which is the whole point of the
  // port, not an incidental tidy.
  //
  // NOTE, recorded not acted on: `registerAndActivateLocal`'s single
  // production caller (`WorkspaceFlow.openResult`) always passes
  // `save: false`, and did so before this refactor too — a saved local result
  // goes through `saveLocalRepo` + `openLocalRepoInTab` instead. The
  // `save: true` branch below is therefore unreachable in production today.
  // Pre-existing, adjacent to MADR 0038 F6, and out of scope here.
  // -------------------------------------------------------------------------
  group('registerAndActivateLocal', () {
    const bookmarks = MethodChannel('magicgit/bookmarks');
    const dest = '/Users/test/my-repo';

    setUp(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(bookmarks, (call) async => null);
    });
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(bookmarks, null);
    });

    ({
      ProviderContainer container,
      _FakeConnection conn,
      _FakeLocalRepoStore store,
    })
    build({bool failing = false}) {
      final conn = failing ? _FailingConnection() : _FakeConnection();
      final store = _FakeLocalRepoStore();
      final c = ProviderContainer(
        retry: noProviderRetry,
        overrides: [
          connectionProvider.overrideWith(() => conn),
          localRepoStoreProvider.overrideWithValue(store),
          savedLocalReposProvider.overrideWith((ref) async => const []),
        ],
      );
      addTearDown(c.dispose);
      return (container: c, conn: conn, store: store);
    }

    test('save:false calls connectLocal without persisting', () async {
      final h = build();

      await registerAndActivateLocal(h.container, dest: dest, save: false);

      expect(h.conn.recordedConnectLocalRepoPath, dest);
      expect(h.conn.recordedConnectLocalId, isNull);
      expect(h.store.saved, isNull);
    });

    // 0009 H19: a connect that never lands must report false — the sheets used
    // to flash the green Complete state regardless.
    test('a failed connect reports false and persists nothing', () async {
      final h = build(failing: true);

      final result = await registerAndActivateLocal(
        h.container,
        dest: dest,
        save: true,
      );

      expect(result, isFalse);
      expect(h.conn.recordedConnectLocalRepoPath, dest);
      expect(h.store.saved, isNull);
    });

    test('save:true persists SavedLocalRepo with bookmark data', () async {
      final h = build();

      await registerAndActivateLocal(
        h.container,
        dest: dest,
        label: 'My Repo',
        save: true,
      );

      expect(h.conn.recordedConnectLocalId, isNotNull);
      expect(h.store.saved, isNotNull);
      expect(h.store.saved!.repoPath, dest);
      expect(h.store.saved!.label, 'My Repo');
      expect(
        h.store.saved!.id,
        h.conn.recordedConnectLocalId,
        reason: 'the session id must match the persisted record',
      );
    });

    test('save:true with empty label passes null to connectLocal', () async {
      final h = build();

      await registerAndActivateLocal(h.container, dest: dest, save: true);

      expect(h.conn.recordedConnectLocalLabel, isNull);
      expect(h.store.saved!.label, '');
    });
  });

  group('the grant registry', () {
    test('is the injected one, resolved lazily', () {
      final grants = _Grants();
      final f = flow(access: grants.access);
      expect(f.scopedAccess, same(grants.access));
    });

    test('falls back to the process-wide registry', () {
      expect(flow().scopedAccess, same(ScopedAccess.instance));
    });
  });
}
