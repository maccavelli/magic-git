// The busy split (0014 T3): `SSHCommandExecutor` reports command-lane and
// sync-lane activity separately, so a long `git fetch` pauses only the sync
// client's dead-peer monitor while the command client keeps probing.
//
// `SSHClientManager.registerBusyProbes` wires `commandBusy` / `syncBusy` /
// `streamBusy` into the three monitors at executor construction; that the
// monitors skip a probe while their own `isBusy` closure is true is already
// covered by `connection_health_monitor_test.dart`. What is asserted here is
// the half that feeds it: that the two counters move independently.

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';

import 'helpers/fake_ssh_client.dart';

/// Yields until [predicate] holds, so the assertion does not depend on how
/// many microtasks the lane scheduler happens to take before it starts a job.
Future<void> until(bool Function() predicate, {String? reason}) async {
  for (var i = 0; i < 200; i++) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail(reason ?? 'condition never became true');
}

void main() {
  test('a hung read marks commandBusy, never syncBusy', () async {
    final manager = SSHClientManager();
    final executor = SSHCommandExecutor(manager);
    final command = FakeSshClient(hangExecute: true);
    final sync = FakeSshClient();
    manager.bindTestClients(command: command, sync: sync);

    final pending = executor.execute(
      repoPath: '/r',
      gitArgs: ['git', 'status'],
      lane: ExecLane.read,
      timeout: const Duration(seconds: 30),
    );

    await until(() => executor.commandBusy, reason: 'read never started');
    expect(executor.commandBusy, isTrue);
    expect(executor.syncBusy, isFalse);
    expect(executor.transportBusy, isTrue);

    command.completeExecute();
    await pending;

    expect(executor.commandBusy, isFalse);
    expect(executor.syncBusy, isFalse);
    expect(executor.transportBusy, isFalse);
  });

  test('a hung sync marks syncBusy, never commandBusy', () async {
    final manager = SSHClientManager();
    final executor = SSHCommandExecutor(manager);
    final command = FakeSshClient();
    final sync = FakeSshClient(hangExecute: true);
    manager.bindTestClients(command: command, sync: sync);

    final pending = executor.execute(
      repoPath: '/r',
      gitArgs: ['git', 'fetch'],
      lane: ExecLane.sync,
      timeout: const Duration(seconds: 30),
    );

    await until(() => executor.syncBusy, reason: 'sync never started');
    expect(executor.syncBusy, isTrue);
    expect(executor.commandBusy, isFalse);
    expect(executor.transportBusy, isTrue);

    sync.completeExecute();
    await pending;

    expect(executor.syncBusy, isFalse);
    expect(executor.commandBusy, isFalse);
    expect(executor.transportBusy, isFalse);
  });
}
