import 'dart:async';

import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/storage/connection_store.dart';
import 'package:remote_magic_git/core/storage/local_repo_store.dart';
import 'package:remote_magic_git/core/storage/saved_connection.dart';
import 'package:remote_magic_git/core/storage/saved_local_repo.dart';
import 'package:remote_magic_git/features/workspace/workspace_registration.dart';

import 'helpers/mock_executor.dart';

const _dest = '/Users/test/my-repo';
const _connId = 'conn-1';

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

class _FakeConnection extends ConnectionController {
  ConnectionState _state;

  _FakeConnection([ConnectionState? state])
      : _state = state ??
            const ConnectionState(
              phase: ConnectionPhase.connected,
              repoPath: '/',
              connectionId: _connId,
            );

  @override
  ConnectionState build() => _state;

  // Recording fields
  String? recordedConnectLocalRepoPath;
  String? recordedConnectLocalLabel;
  String? recordedConnectLocalId;
  String? recordedSetRepoPath;

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

  @override
  void setRepoPath(String path) {
    recordedSetRepoPath = path;
    _state = _state.copyWith(repoPath: path);
  }
}

class _FakeLocalRepoStore extends LocalRepoStore {
  SavedLocalRepo? saved;

  @override
  Future<void> save(SavedLocalRepo repo) async {
    saved = repo;
  }
}

class _FakeConnectionStore extends ConnectionStore {
  SavedConnection? updated;

  @override
  Future<void> updateMetadata(SavedConnection conn) async {
    updated = conn;
  }
}

class _RecordingGitService extends GitService {
  String? fsmonitorPath;
  bool? fsmonitorEnabled;

  _RecordingGitService() : super(MockExecutor());

  @override
  Future<void> setFsmonitor(String repoPath, {required bool enabled}) async {
    fsmonitorPath = repoPath;
    fsmonitorEnabled = enabled;
  }
}

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

class _RefHarness extends ConsumerWidget {
  final Future<void> Function(WidgetRef ref) work;
  final void Function()? onDone;
  const _RefHarness(this.work, {this.onDone});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    work(ref).then((_) => onDone?.call());
    return const SizedBox.shrink();
  }
}

Future<void> _pumpWork(
  WidgetTester tester,
  ProviderContainer container,
  Future<void> Function(WidgetRef ref) work,
) async {
  final done = Completer<void>();
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: _RefHarness(work, onDone: () => done.complete()),
    ),
  );
  for (var i = 0; i < 20; i++) {
    if (done.isCompleted) break;
    await tester.pump(const Duration(milliseconds: 10));
  }
  if (!done.isCompleted) {
    await tester.runAsync(() => done.future.timeout(const Duration(seconds: 5)));
  }
  await tester.pump();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const _bookmarkChannel = MethodChannel('magicgit/bookmarks');

void main() {
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_bookmarkChannel, (call) async => null);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_bookmarkChannel, null);
  });

  group('registerAndActivateLocal', () {
    testWidgets('save:false calls connectLocal without persisting', (
      tester,
    ) async {
      final conn = _FakeConnection();
      final localStore = _FakeLocalRepoStore();
      final container = ProviderContainer(overrides: [
        connectionProvider.overrideWith(() => conn),
        localRepoStoreProvider.overrideWithValue(localStore),
        savedLocalReposProvider.overrideWith((ref) async => const []),
      ]);
      addTearDown(container.dispose);

      await _pumpWork(
        tester,
        container,
        (ref) => registerAndActivateLocal(ref, dest: _dest, save: false),
      );

      expect(conn.recordedConnectLocalRepoPath, _dest);
      expect(conn.recordedConnectLocalId, isNull);
      expect(localStore.saved, isNull);
    });

    testWidgets('save:true persists SavedLocalRepo with bookmark data', (
      tester,
    ) async {
      final conn = _FakeConnection();
      final localStore = _FakeLocalRepoStore();
      final container = ProviderContainer(overrides: [
        connectionProvider.overrideWith(() => conn),
        localRepoStoreProvider.overrideWithValue(localStore),
        savedLocalReposProvider.overrideWith((ref) async => const []),
      ]);
      addTearDown(container.dispose);

      await _pumpWork(
        tester,
        container,
        (ref) => registerAndActivateLocal(
          ref,
          dest: _dest,
          save: true,
          label: 'my project',
        ),
      );

      expect(conn.recordedConnectLocalRepoPath, _dest);
      expect(conn.recordedConnectLocalId, isNotEmpty);
      expect(conn.recordedConnectLocalLabel, 'my project');
      final saved = localStore.saved;
      expect(saved, isNotNull);
      expect(saved!.id, conn.recordedConnectLocalId);
      expect(saved.repoPath, _dest);
      expect(saved.label, 'my project');
      // Under test SecurityScopedBookmark.create returns null → bookmarkData ''
      expect(saved.bookmarkData, '');
    });

    testWidgets('save:true with empty label passes null to connectLocal', (
      tester,
    ) async {
      final conn = _FakeConnection();
      final container = ProviderContainer(overrides: [
        connectionProvider.overrideWith(() => conn),
        localRepoStoreProvider.overrideWithValue(_FakeLocalRepoStore()),
        savedLocalReposProvider.overrideWith((ref) async => const []),
      ]);
      addTearDown(container.dispose);

      await _pumpWork(
        tester,
        container,
        (ref) => registerAndActivateLocal(ref, dest: _dest, save: true),
      );

      expect(conn.recordedConnectLocalLabel, isNull);
    });
  });

  group('registerAndActivateSshActive', () {
    const savedConn = SavedConnection(
      id: _connId,
      label: 'my server',
      host: 'example.com',
      port: 22,
      username: 'user',
      repoPath: '/home/user/project',
      repoPaths: [],
    );

    testWidgets('updates connection metadata and sets repoPath', (
      tester,
    ) async {
      final conn = _FakeConnection();
      final store = _FakeConnectionStore();
      final container = ProviderContainer(overrides: [
        connectionProvider.overrideWith(() => conn),
        connectionStoreProvider.overrideWithValue(store),
        savedConnectionsProvider.overrideWith(
          (ref) async => [savedConn],
        ),
        gitServiceProvider.overrideWithValue(_RecordingGitService()),
      ]);
      addTearDown(container.dispose);

      await _pumpWork(
        tester,
        container,
        (ref) => registerAndActivateSshActive(ref, dest: _dest, fsmonitor: false),
      );

      final updated = store.updated;
      expect(updated, isNotNull);
      expect(updated!.allRepoPaths, contains(_dest));
      expect(conn.recordedSetRepoPath, _dest);
    });

    testWidgets('with fsmonitor calls setFsmonitor on git service', (
      tester,
    ) async {
      final conn = _FakeConnection();
      final git = _RecordingGitService();
      final container = ProviderContainer(overrides: [
        connectionProvider.overrideWith(() => conn),
        connectionStoreProvider.overrideWithValue(_FakeConnectionStore()),
        savedConnectionsProvider.overrideWith(
          (ref) async => [savedConn],
        ),
        gitServiceProvider.overrideWithValue(git),
      ]);
      addTearDown(container.dispose);

      await _pumpWork(
        tester,
        container,
        (ref) => registerAndActivateSshActive(
          ref,
          dest: _dest,
          fsmonitor: true,
        ),
      );

      expect(git.fsmonitorPath, _dest);
      expect(git.fsmonitorEnabled, isTrue);
    });

    testWidgets('with label saves it in connection metadata', (
      tester,
    ) async {
      final conn = _FakeConnection();
      final store = _FakeConnectionStore();
      final container = ProviderContainer(overrides: [
        connectionProvider.overrideWith(() => conn),
        connectionStoreProvider.overrideWithValue(store),
        savedConnectionsProvider.overrideWith(
          (ref) async => [savedConn],
        ),
        gitServiceProvider.overrideWithValue(_RecordingGitService()),
      ]);
      addTearDown(container.dispose);

      await _pumpWork(
        tester,
        container,
        (ref) => registerAndActivateSshActive(
          ref,
          dest: _dest,
          fsmonitor: false,
          label: 'work',
        ),
      );

      final updated = store.updated;
      expect(updated, isNotNull);
      expect(updated!.repoLabelFor(_dest), 'work');
    });

    testWidgets('without connectionId (ad-hoc) skips metadata mutation', (
      tester,
    ) async {
      final conn = _FakeConnection(
        const ConnectionState(phase: ConnectionPhase.connected),
      );
      final store = _FakeConnectionStore();
      final container = ProviderContainer(overrides: [
        connectionProvider.overrideWith(() => conn),
        connectionStoreProvider.overrideWithValue(store),
        savedConnectionsProvider.overrideWith(
          (ref) async => [savedConn],
        ),
        gitServiceProvider.overrideWithValue(_RecordingGitService()),
      ]);
      addTearDown(container.dispose);

      await _pumpWork(
        tester,
        container,
        (ref) => registerAndActivateSshActive(ref, dest: _dest, fsmonitor: false),
      );

      expect(store.updated, isNull);
      expect(conn.recordedSetRepoPath, _dest);
    });
  });
}
