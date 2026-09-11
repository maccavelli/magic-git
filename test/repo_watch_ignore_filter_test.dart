// MADR 0045 amendment 0045.1. The ignored-path filter between the watcher and
// every view, pinned where it runs: behind `repoWatchProvider`.
//
// It had no test at this level. Its four behaviours were described in comments,
// and its form — an `async*` generator whose doc comment called it an
// `asyncMap` — let a quiet repository's watcher outlive its last listener,
// because an `async*` stream observes a cancel only at its next `yield`. Each
// behaviour gets a test here, and so do the two properties `asyncMap` is for:
// order, and a cancel that reaches the watcher.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/bounded_watch.dart';
import 'package:remote_magic_git/core/git/ignore_oracle.dart';
import 'package:remote_magic_git/core/git/remote_watch_service.dart';
import 'package:remote_magic_git/core/git/watch/watch_timings.dart';
import 'package:remote_magic_git/core/git/watch_event.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';

import 'helpers/conventional_git_dir.dart';

const _repo = '/repo';

/// A watch service whose events the test writes, and whose cancel it can see.
class _ScriptedService extends RemoteWatchService {
  _ScriptedService()
    : super(
        SSHCommandExecutor(SSHClientManager()),
        gitDirOf: conventionalGitDir,
      );

  var cancelled = false;
  // Closed in the test file's tearDown, which the lint cannot see.
  // ignore: close_sinks
  late final StreamController<RepoWatchEvent> events =
      StreamController<RepoWatchEvent>(onCancel: () => cancelled = true);

  @override
  Stream<RepoWatchEvent> watch(
    String repoPath, {
    BoundedWatchSpecSource? bounded,
    Duration trailing = WatchTimings.defaultTrailing,
    Duration maxWait = WatchTimings.defaultMaxWait,
    Duration minInterval = WatchTimings.defaultMinInterval,
    Duration pollInterval = WatchTimings.defaultPollInterval,
    Duration recoveryInterval = WatchTimings.defaultRecoveryInterval,
    String sessionId = '',
  }) => events.stream;
}

/// An oracle whose answers the test decides, recording what it was asked.
class _ScriptedOracle implements GitIgnoreOracle {
  /// What happened, in order: `forget:<repo>` and `visible:<paths>`.
  final calls = <String>[];

  /// The answer to each `visible` call; the default sees everything.
  Future<Set<String>> Function(Set<String> paths) answer = (paths) async =>
      paths;

  @override
  void forgetRepo(String repoPath) => calls.add('forget:$repoPath');

  @override
  void clear() => calls.add('clear');

  @override
  Future<Set<String>> visible(String repoPath, Set<String> paths) {
    calls.add('visible:${paths.toList()..sort()}');
    return answer(paths);
  }
}

/// A connection that is simply there: SSH, no scoped git-dir.
class _Idle extends ConnectionController {
  @override
  ConnectionState build() => const ConnectionState();
}

RepoWatchEvent _tick(
  Set<String> paths, {
  WatchMode mode = WatchMode.eventDriven,
}) => RepoWatchEvent(at: DateTime(2026, 9, 10), mode: mode, paths: paths);

void main() {
  late _ScriptedService service;
  late _ScriptedOracle oracle;
  late ProviderContainer container;
  late List<RepoWatchEvent> delivered;
  late ProviderSubscription<AsyncValue<RepoWatchEvent>> subscription;

  setUp(() {
    service = _ScriptedService();
    oracle = _ScriptedOracle();
    container = ProviderContainer(
      retry: (_, _) => null,
      overrides: [
        connectionProvider.overrideWith(_Idle.new),
        remoteWatchServiceProvider.overrideWithValue(service),
        ignoreOracleProvider.overrideWithValue(oracle),
      ],
    );
    delivered = [];
    subscription = container.listen<AsyncValue<RepoWatchEvent>>(
      repoWatchProvider(_repo),
      (_, next) {
        final event = next.value;
        if (event != null) delivered.add(event);
      },
    );
  });
  tearDown(() async {
    container.dispose();
    await service.events.close();
  });

  test('an unscoped tick passes through without asking git', () async {
    service.events.add(_tick(const {}, mode: WatchMode.polling));
    await pumpEventQueue();

    expect(delivered.map((e) => e.mode), [WatchMode.polling]);
    expect(
      oracle.calls,
      isEmpty,
      reason:
          'a poll or restart tick means "refresh everything"; there is '
          'nothing to filter and nothing may be assumed',
    );
  });

  test('a wholly ignored tick is dropped', () async {
    oracle.answer = (_) async => const {};
    service.events.add(_tick({'build/app.o', '.dart_tool/x'}));
    service.events.add(_tick(const {}, mode: WatchMode.polling));
    await pumpEventQueue();

    expect(
      delivered.map((e) => e.mode),
      [WatchMode.polling],
      reason:
          'build churn git will never report must not refresh status or '
          'invalidate a diff — and must not stop the ticks behind it',
    );
  });

  test('a partly ignored tick keeps only what git can see', () async {
    oracle.answer = (paths) async =>
        paths.where((p) => p.startsWith('lib/')).toSet();
    service.events.add(_tick({'lib/main.dart', 'build/app.o'}));
    await pumpEventQueue();

    expect(delivered.single.paths, {'lib/main.dart'});
  });

  test(
    "an edited .gitignore forgets the repository's verdicts first",
    () async {
      service.events.add(_tick({'.gitignore', 'lib/main.dart'}));
      await pumpEventQueue();

      expect(
        oracle.calls,
        ['forget:$_repo', 'visible:[.gitignore, lib/main.dart]'],
        reason:
            'every cached verdict came from the old ignore rules, so they go '
            'before this tick is classified with them',
      );
      expect(delivered, hasLength(1));
    },
  );

  test('a classification error fails open', () async {
    oracle.answer = (_) async => throw StateError('git check-ignore failed');
    service.events.add(_tick({'lib/main.dart'}));
    await pumpEventQueue();

    expect(
      delivered.single.paths,
      {'lib/main.dart'},
      reason:
          'a tick that could not be classified is a real change: the converse '
          'is a pane that silently stops updating',
    );
  });

  test('ticks stay in order when one waits on git', () async {
    final slow = Completer<Set<String>>();
    oracle.answer = (_) => slow.future;
    service.events.add(_tick({'lib/slow.dart'}));
    service.events.add(_tick(const {}, mode: WatchMode.polling));
    await pumpEventQueue();

    expect(
      delivered,
      isEmpty,
      reason: 'the later tick must not overtake the one still waiting on git',
    );

    slow.complete({'lib/slow.dart'});
    await pumpEventQueue();

    expect(delivered.map((e) => e.mode), [
      WatchMode.eventDriven,
      WatchMode.polling,
    ]);
  });

  test('leaving reaches the watcher while the repository is quiet', () async {
    service.events.add(_tick(const {}, mode: WatchMode.eventDriven));
    await pumpEventQueue();
    expect(service.cancelled, isFalse);

    subscription.close();
    await container.pump();
    await pumpEventQueue();

    expect(
      service.cancelled,
      isTrue,
      reason:
          'an `async*` filter would hold the watcher until its next event — '
          'for a quiet repository, its process, lease, lock and slot',
    );
  });

  test('leaving reaches the watcher while a tick waits on git', () async {
    oracle.answer = (_) => Completer<Set<String>>().future;
    service.events.add(_tick({'lib/main.dart'}));
    await pumpEventQueue();

    subscription.close();
    await container.pump();
    await pumpEventQueue();

    expect(service.cancelled, isTrue);
  });
}
