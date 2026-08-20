// ActivityCommandExecutor is a pass-through decorator: it must hand every
// transport parameter to the inner executor untouched, and add exactly two
// things — a resolved OperationDescriptor when the caller supplied none, and
// its own event sink when the caller supplied none.
//
// Both substitutions are `??`, so a regression that overrides the caller
// instead of filling in for it is invisible without these assertions. The
// executeStream asymmetry (deliberately no descriptor, so the file watcher
// and CI trace do not post background activity) is asserted too, because it
// reads like an omission and would otherwise be "fixed".

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/exec/activity_command_executor.dart';
import 'package:remote_magic_git/core/exec/operation_activity.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';

import 'helpers/mock_executor.dart';

const _repo = '/srv/repo';

OperationDescriptor _descriptor(
  String label, {
  ExecLane lane = ExecLane.read,
}) => OperationDescriptor(
  repositoryPath: _repo,
  label: label,
  kind: OperationKind.background,
  lane: lane,
);

/// Records what the decorator asked the resolver for, and what it answered.
class _SpyResolver {
  final List<({String repositoryPath, ExecLane lane, List<String> argv})>
  calls = [];
  OperationDescriptor? answer;

  OperationDescriptor? call({
    required String repositoryPath,
    required ExecLane lane,
    required List<String> argv,
  }) {
    calls.add((repositoryPath: repositoryPath, lane: lane, argv: argv));
    return answer;
  }
}

({
  ActivityCommandExecutor exec,
  MockExecutor inner,
  _SpyResolver resolver,
  List<OperationEvent> events,
})
_build({bool streaming = false}) {
  final inner = MockExecutor(
    onStream: streaming ? (_) => MockStreamHandle() : null,
  );
  final resolver = _SpyResolver()..answer = _descriptor('resolved');
  final events = <OperationEvent>[];
  return (
    exec: ActivityCommandExecutor(
      inner,
      onOperationEvent: events.add,
      resolveDescriptor: resolver.call,
    ),
    inner: inner,
    resolver: resolver,
    events: events,
  );
}

void main() {
  test('execute forwards every parameter unchanged', () async {
    final h = _build();
    void sink(OperationEvent e) {}

    await h.exec.execute(
      repoPath: _repo,
      gitArgs: const ['git', 'status'],
      extraEnv: const {'GIT_TERMINAL_PROMPT': '0'},
      stdin: 'payload',
      timeout: const Duration(seconds: 42),
      retries: 3,
      lane: ExecLane.sync,
      compress: true,
      activityIdle: const Duration(seconds: 17),
      onOperationEvent: sink,
    );

    final call = h.inner.calls.single;
    expect(call.repoPath, _repo);
    expect(call.gitArgs, const ['git', 'status']);
    expect(call.extraEnv, const {'GIT_TERMINAL_PROMPT': '0'});
    expect(call.stdin, 'payload');
    expect(call.timeout, const Duration(seconds: 42));
    expect(call.retries, 3);
    expect(call.lane, ExecLane.sync);
    expect(call.compress, isTrue);
    expect(call.activityIdle, const Duration(seconds: 17));
    expect(identical(call.onOperationEvent, sink), isTrue);
  });

  test('a null operation is filled from the resolver', () async {
    final h = _build();
    final resolved = _descriptor('resolved', lane: ExecLane.exclusive);
    h.resolver.answer = resolved;

    await h.exec.execute(
      repoPath: _repo,
      gitArgs: const ['git', 'commit'],
      lane: ExecLane.exclusive,
    );

    // The resolver saw exactly what the caller passed — a decorator that
    // resolved against stale or defaulted values would still "work".
    final asked = h.resolver.calls.single;
    expect(asked.repositoryPath, _repo);
    expect(asked.lane, ExecLane.exclusive);
    expect(asked.argv, const ['git', 'commit']);

    expect(identical(h.inner.calls.single.operation, resolved), isTrue);
  });

  test('an explicit operation wins over the resolver', () async {
    final h = _build();
    final mine = _descriptor('caller supplied');

    await h.exec.execute(
      repoPath: _repo,
      gitArgs: const ['git', 'log'],
      operation: mine,
    );

    expect(h.resolver.calls, isEmpty);
    expect(identical(h.inner.calls.single.operation, mine), isTrue);
  });

  test('a null resolver answer stays null on the inner call', () async {
    final h = _build();
    h.resolver.answer = null;

    await h.exec.execute(repoPath: _repo, gitArgs: const ['git', 'log']);

    expect(h.resolver.calls, hasLength(1));
    expect(h.inner.calls.single.operation, isNull);
  });

  test('a caller callback wins over the decorator default', () async {
    final h = _build();
    void mine(OperationEvent e) {}

    await h.exec.execute(repoPath: _repo, gitArgs: const ['a']);
    await h.exec.execute(
      repoPath: _repo,
      gitArgs: const ['b'],
      onOperationEvent: mine,
    );

    // Without a caller callback the decorator's own sink goes through…
    expect(h.inner.calls[0].onOperationEvent, isNotNull);
    expect(identical(h.inner.calls[0].onOperationEvent, mine), isFalse);
    // …and with one, the caller's wins.
    expect(identical(h.inner.calls[1].onOperationEvent, mine), isTrue);
  });

  test('executeStream never resolves a descriptor', () async {
    final h = _build(streaming: true);

    await h.exec.executeStream(
      repoPath: _repo,
      gitArgs: const ['fswatch', '.'],
      extraEnv: const {'X': '1'},
      openTimeout: const Duration(seconds: 9),
    );

    // Deliberate asymmetry (activity_command_executor.dart): a resolved
    // descriptor here would post activity for background watching.
    expect(h.resolver.calls, isEmpty);
    final call = h.inner.streamCalls.single;
    expect(call.operation, isNull);
    expect(call.extraEnv, const {'X': '1'});
    expect(call.openTimeout, const Duration(seconds: 9));
    // The event sink is still substituted — only the descriptor is not.
    expect(call.onOperationEvent, isNotNull);
  });

  test('executeStream still honours an explicit operation', () async {
    final h = _build(streaming: true);
    final mine = _descriptor('trace');

    await h.exec.executeStream(
      repoPath: _repo,
      gitArgs: const ['glab', 'ci', 'trace'],
      operation: mine,
    );

    expect(identical(h.inner.streamCalls.single.operation, mine), isTrue);
  });

  test('uploadBytes and configureEnvironment pass through', () async {
    final h = _build();

    await h.exec.uploadBytes(
      '/tmp/x',
      Uint8List.fromList([7, 8]),
      routingRepo: _repo,
    );
    h.exec.configureEnvironment(
      path: '/usr/bin',
      binaries: const {'git': '/usr/bin/git'},
    );

    expect(h.inner.uploads.single.$1, '/tmp/x');
    expect(h.inner.uploads.single.$2, Uint8List.fromList([7, 8]));
    expect(h.inner.uploads.single.$3, _repo);
    expect(h.inner.environments.single.$1, '/usr/bin');
    expect(h.inner.environments.single.$2, const {'git': '/usr/bin/git'});
  });
}
