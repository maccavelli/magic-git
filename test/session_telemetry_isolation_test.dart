// MADR 0039 F5. `CommandTelemetry` was a process-wide singleton whose doc said
// its figures "describe the current connection" — and every tab recorded into
// it, while `reset()` (called on each connect) wiped whichever tab happened to
// be looking at the Dashboard. Latency percentiles mixed hosts, `countsByLabel`
// attributed one tab's refresh storm to another's session, and the open/peak
// stream gauges counted across connections.
//
// It is now one instance per container. `CommandTelemetry.instance` survives as
// the default for callers with no session — a secondary window runs in its own
// engine, where process-wide and session-wide are the same thing.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/exec/command_telemetry.dart';
import 'package:remote_magic_git/core/exec/local_command_executor.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';

import 'helpers/app_scope.dart';
import 'helpers/fake_ssh_client.dart';

CommandSample _sample(String label) => CommandSample(
  lane: ExecLane.read,
  duration: const Duration(milliseconds: 40),
  bytes: 128,
  wireBytes: 128,
  compressed: false,
  success: true,
  label: label,
);

void main() {
  setUp(CommandTelemetry.instance.reset);

  test('each container gets its own sink', () {
    final a = appProviderContainer();
    final b = appProviderContainer();
    addTearDown(a.dispose);
    addTearDown(b.dispose);

    final sinkA = a.read(commandTelemetryProvider);
    final sinkB = b.read(commandTelemetryProvider);

    expect(identical(sinkA, sinkB), isFalse);
    expect(identical(sinkA, CommandTelemetry.instance), isFalse);
    expect(identical(a.read(commandTelemetryProvider), sinkA), isTrue);
  });

  test('a command recorded in one session is invisible to the other', () {
    final a = appProviderContainer();
    final b = appProviderContainer();
    addTearDown(a.dispose);
    addTearDown(b.dispose);

    a.read(commandTelemetryProvider).record(_sample('git status'));

    expect(a.read(commandTelemetryProvider).commandCount, 1);
    expect(
      b.read(commandTelemetryProvider).commandCount,
      0,
      reason: 'the Dashboard must describe the tab it is open in',
    );
    expect(b.read(commandTelemetryProvider).countsByLabel, isEmpty);
    expect(
      CommandTelemetry.instance.commandCount,
      0,
      reason: 'a session with a sink of its own never touches the fallback',
    );
  });

  test('a connect in one session does not reset the other', () {
    final a = appProviderContainer();
    final b = appProviderContainer();
    addTearDown(a.dispose);
    addTearDown(b.dispose);

    a.read(commandTelemetryProvider).record(_sample('git log'));
    b.read(commandTelemetryProvider).record(_sample('git log'));

    // What ConnectionController does on every connect attempt — including each
    // retry of an auto-reconnect.
    b.read(commandTelemetryProvider).reset();

    expect(
      a.read(commandTelemetryProvider).commandCount,
      1,
      reason: 'B connecting used to zero the numbers A was reading',
    );
    expect(b.read(commandTelemetryProvider).commandCount, 0);
  });

  test('the local executor records into the sink it was given', () async {
    // Constructing the executor proves only that the argument exists. This runs
    // a real command through it and follows where the sample lands — the only
    // thing that catches a body still reaching for `CommandTelemetry.instance`.
    final sink = CommandTelemetry();
    final executor = LocalCommandExecutor(telemetry: sink);
    final dir = Directory.systemTemp.createTempSync('telemetry_scope_');
    addTearDown(() => dir.deleteSync(recursive: true));

    final result = await executor.execute(
      repoPath: dir.path,
      gitArgs: ['sh', '-c', 'true'],
    );

    expect(result.isSuccess, isTrue);
    expect(sink.commandCount, 1);
    expect(sink.countsByLabel.keys, contains('sh -c'));
    expect(
      CommandTelemetry.instance.commandCount,
      0,
      reason: 'the process-wide fallback must not see a session\'s commands',
    );
  });

  test('the SSH executor records into the sink it was given', () async {
    final sink = CommandTelemetry();
    final manager = SSHClientManager(telemetry: sink);
    final executor = SSHCommandExecutor(manager, telemetry: sink);
    manager.bindTestClients(command: FakeSshClient());

    final result = await executor.execute(repoPath: '/r', gitArgs: ['true']);

    expect(result.isSuccess, isTrue);
    expect(sink.commandCount, 1);
    expect(CommandTelemetry.instance.commandCount, 0);
  });

  test('the providers hand their own sink to both executors', () async {
    final container = appProviderContainer();
    addTearDown(container.dispose);
    final sink = container.read(commandTelemetryProvider);
    final dir = Directory.systemTemp.createTempSync('telemetry_wiring_');
    addTearDown(() => dir.deleteSync(recursive: true));

    await container
        .read(localExecutorProvider)
        .execute(repoPath: dir.path, gitArgs: ['sh', '-c', 'true']);

    expect(
      sink.commandCount,
      1,
      reason: 'localExecutorProvider must pass commandTelemetryProvider along',
    );
    expect(CommandTelemetry.instance.commandCount, 0);
  });

  test('an executor built without a sink falls back to the singleton', () {
    // The secondary window's engine, and every test that constructs an executor
    // directly, rely on this default — it is why ~15 existing test files needed
    // no edit.
    final executor = LocalCommandExecutor();
    final ssh = SSHCommandExecutor(SSHClientManager());

    expect(executor, isNotNull);
    expect(ssh, isNotNull);
    expect(CommandTelemetry.instance.commandCount, 0);
  });

  test('no call site in app_providers reaches the process-wide sink', () {
    // A membership scan, like `branch_diff_lru_test`'s clear-list guard, and for
    // the same reason: the invariant is "no call site in this file reaches the
    // singleton", which is a property of the source rather than of any one
    // behaviour. Driving `ConnectionController.connect()` end-to-end would pin
    // one of the three reset sites at the cost of a stubbed handshake; this pins
    // all of them, plus the drop recorder, and fails on a fourth added later.
    //
    // Read as bytes: `app_providers.dart` carries bytes that make tools treat it
    // as binary (see AGENTS.md), and a lenient decode is the honest way to scan
    // it — the same trap that hid three of these call sites from an earlier
    // `grep -rn` (MADR 0039 amendment 0039.2).
    final source = const Utf8Decoder(
      allowMalformed: true,
    ).convert(File('lib/core/providers/app_providers.dart').readAsBytesSync());

    expect(
      source,
      contains('commandTelemetryProvider'),
      reason: 'sanity: the scan is reading the file it thinks it is',
    );
    expect(
      'CommandTelemetry.instance'.allMatches(source),
      isEmpty,
      reason:
          'every telemetry call site in the session controller must go '
          'through commandTelemetryProvider, or one tab resets another\'s '
          'Dashboard figures on connect',
    );
  });
}
