import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/forge/forge.dart';
import 'package:remote_magic_git/core/forge/namespace_history.dart';
import 'package:remote_magic_git/core/forge/namespace_suggestions.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/providers/provider_retry_policy.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/core/storage/connection_store.dart';
import 'package:remote_magic_git/core/storage/saved_connection.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('NamespaceSuggestions', () {
    test('ordered puts recent first, then the rest without repeating', () {
      const s = NamespaceSuggestions(
        recent: ['team/beta'],
        all: ['me', 'team/alpha', 'team/beta'],
      );
      expect(s.ordered, ['team/beta', 'me', 'team/alpha']);
    });

    test('an empty set is empty', () {
      expect(NamespaceSuggestions.empty.isEmpty, isTrue);
      expect(NamespaceSuggestions.empty.ordered, isEmpty);
    });

    test('recent entries not in all are still ordered first', () {
      // The composer filters stale history before constructing this, but the
      // model itself must not silently drop what it was handed.
      const s = NamespaceSuggestions(recent: ['gone'], all: ['me']);
      expect(s.ordered, ['gone', 'me']);
    });
  });

  group('namespaceSuggestionsProvider composes the two sources', () {
    ProviderContainer build({
      required List<String> creatable,
      List<String> history = const [],
      List<String> forgeRecent = const [],
    }) {
      SharedPreferences.setMockInitialValues({
        if (history.isNotEmpty)
          'namespaceHistory_${namespaceHistoryKey(Forge.gitlab, 'gitlab.example')}':
              history,
      });
      return ProviderContainer(
        retry: noProviderRetry,
        overrides: [
          forgeNamespacesProvider.overrideWith((ref, key) async => creatable),
          activeExecutorProvider.overrideWithValue(
            _EventsExecutor(forgeRecent),
          ),
          connectionStoreProvider.overrideWithValue(_FakeStore()),
          savedConnectionsProvider.overrideWith((ref) async => const []),
        ],
      );
    }

    Future<NamespaceSuggestions> read(ProviderContainer c) => c.read(
      namespaceSuggestionsProvider((
        Forge.gitlab,
        'gitlab.example',
        false, // SSH path: the fake executor stands in for the host
        null,
      )).future,
    );

    test('recent comes from history first, then the forge feed', () async {
      final c = build(
        creatable: const ['me', 'a', 'b', 'c'],
        history: const ['c'],
        forgeRecent: const ['b'],
      );
      addTearDown(c.dispose);

      final s = await read(c);
      expect(s.recent, [
        'c',
        'b',
      ], reason: 'history leads; it is free and offline');
      expect(s.ordered, ['c', 'b', 'me', 'a']);
    });

    test(
      'a namespace the account can no longer create in is dropped',
      () async {
        // Stale history, not a suggestion — offering it would fail the create.
        final c = build(creatable: const ['me'], history: const ['revoked']);
        addTearDown(c.dispose);

        expect((await read(c)).recent, isEmpty);
      },
    );

    test(
      'but a FAILED creatable lookup keeps history rather than wiping it',
      () async {
        // An empty `all` means the lookup failed, not that the account may create
        // nowhere. Dropping every remembered namespace then would be worse than
        // offering a stale one — and the field is free text either way.
        final c = build(creatable: const [], history: const ['remembered']);
        addTearDown(c.dispose);

        final s = await read(c);
        expect(s.recent, ['remembered']);
        expect(s.all, isEmpty);
      },
    );

    test('no history and no events still yields the creatable list', () async {
      final c = build(creatable: const ['me', 'team/alpha']);
      addTearDown(c.dispose);

      final s = await read(c);
      expect(s.recent, isEmpty);
      expect(s.ordered, ['me', 'team/alpha']);
    });
  });
}

/// Answers `glab api events` with a fixed set of project ids, and each
/// `projects/<id>` with a namespace named after it.
class _EventsExecutor extends SSHCommandExecutor {
  _EventsExecutor(this.namespaces) : super(SSHClientManager());
  final List<String> namespaces;

  @override
  Future<SSHCommandResult> execute({
    required String repoPath,
    required List<String> gitArgs,
    Map<String, String>? extraEnv,
    String? stdin,
    Duration timeout = SSHCommandExecutor.defaultTimeout,
    int retries = 0,
    ExecLane lane = ExecLane.exclusive,
    bool compress = false,
    Duration? activityIdle,
    OperationDescriptor? operation,
    OperationEventCallback? onOperationEvent,
    CommandOutputCallback? onOutput,
  }) async {
    final joined = gitArgs.join(' ');
    String body;
    if (joined.contains(' events')) {
      body =
          '[${[for (var i = 0; i < namespaces.length; i++) '{"project_id":$i}'].join(',')}]';
    } else if (joined.contains('projects/')) {
      final id =
          int.tryParse(
            RegExp(r'projects/(\d+)').firstMatch(joined)?.group(1) ?? '',
          ) ??
          0;
      body =
          '{"namespace":{"full_path":"${id < namespaces.length ? namespaces[id] : ''}"}}';
    } else {
      body = '{}';
    }
    return SSHCommandResult(
      exitCode: 0,
      stdout: 'HTTP/2.0 200 OK\r\n\r\n$body',
      stderr: '',
    );
  }
}

class _FakeStore extends ConnectionStore {
  @override
  Future<void> updateMetadata(SavedConnection conn) async {}
  @override
  Future<void> touch(String id, {DateTime? when}) async {}
}
