// CommandTelemetry: the session-wide command measurement sink behind the
// dashboard's throughput/wire-savings stats — ring bounding, totals,
// percentiles, and the reset-on-connect contract.

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/exec/command_lanes.dart';
import 'package:remote_magic_git/core/exec/command_telemetry.dart';

CommandSample _sample({
  int ms = 100,
  int bytes = 1000,
  int wire = 1000,
  bool compressed = false,
}) => CommandSample(
  lane: ExecLane.read,
  duration: Duration(milliseconds: ms),
  bytes: bytes,
  wireBytes: wire,
  compressed: compressed,
  success: true,
);

void main() {
  setUp(CommandTelemetry.instance.reset);

  test('records totals and separates compressed wire savings', () {
    final t = CommandTelemetry.instance;
    t.record(_sample(bytes: 1000, wire: 1000));
    t.record(_sample(bytes: 5000, wire: 500, compressed: true));

    expect(t.commandCount, 2);
    expect(t.totalBytes, 6000);
    expect(t.totalWireBytes, 1500);
    expect(t.compressedBytes, 5000);
    expect(t.compressedWireBytes, 500);
  });

  test('average and p95 come from the recent ring', () {
    final t = CommandTelemetry.instance;
    for (var i = 1; i <= 100; i++) {
      t.record(_sample(ms: i));
    }
    expect(t.averageDuration.inMilliseconds, 50);
    expect(t.p95Duration.inMilliseconds, 96);
  });

  test('the ring is bounded but totals keep counting', () {
    final t = CommandTelemetry.instance;
    for (var i = 0; i < 250; i++) {
      t.record(_sample(bytes: 1));
    }
    expect(t.samples.length, 200);
    expect(t.commandCount, 250);
    expect(t.totalBytes, 250);
  });

  test('reset clears everything and notifies', () {
    final t = CommandTelemetry.instance;
    var notified = 0;
    t.addListener(() => notified++);
    t.record(_sample());
    t.reset();
    expect(t.commandCount, 0);
    expect(t.samples, isEmpty);
    expect(t.totalWireBytes, 0);
    expect(notified, 2);
  });

  test('channel open errors and stream counts reset with the session', () {
    final t = CommandTelemetry.instance;
    t.recordChannelOpenError();
    t.recordChannelOpenError();
    t.streamOpened();
    final epoch = t.streamOpened();
    t.streamClosed(epoch);
    expect(t.channelOpenErrors, 2);
    expect(t.openStreams, 1);
    expect(t.peakOpenStreams, 2);
    t.reset();
    expect(t.channelOpenErrors, 0);
    expect(t.openStreams, 0);
    expect(t.peakOpenStreams, 0);
  });

  test("a previous session's late streamClosed cannot misattribute", () {
    final t = CommandTelemetry.instance;
    // A watcher stream opened under session A...
    final oldEpoch = t.streamOpened();
    // ...still tearing down while a reconnect resets the dashboard and the
    // new session opens its own stream.
    t.reset();
    final newEpoch = t.streamOpened();
    // The old handle's close must not decrement the new session's count.
    t.streamClosed(oldEpoch);
    expect(t.openStreams, 1);
    t.streamClosed(newEpoch);
    expect(t.openStreams, 0);
  });

  test('peakOpenStreams is sticky across closes until reset', () {
    final t = CommandTelemetry.instance;
    final e1 = t.streamOpened();
    final e2 = t.streamOpened();
    final e3 = t.streamOpened();
    expect(t.peakOpenStreams, 3);
    t.streamClosed(e1);
    t.streamClosed(e2);
    t.streamClosed(e3);
    expect(t.openStreams, 0);
    expect(t.peakOpenStreams, 3);
  });

  test('drop ring records causes and monitorKillCount', () {
    final t = CommandTelemetry.instance..clearDrops();
    t.recordTransportDrop(
      TransportDropSample(
        cause: TransportDropCause.monitor,
        failures: 3,
        busy: false,
        connectionAge: const Duration(seconds: 10),
        at: DateTime.now(),
      ),
    );
    t.recordTransportDrop(
      TransportDropSample(
        cause: TransportDropCause.transportError,
        failures: 0,
        busy: true,
        connectionAge: Duration.zero,
        at: DateTime.now(),
        peerReason: '3: no matching key exchange method found',
      ),
    );
    expect(t.drops, hasLength(2));
    expect(t.monitorKillCount, 1);
    expect(t.drops.last.peerReason, contains('no matching'));
  });

  test('reset does not clear drops', () {
    final t = CommandTelemetry.instance..clearDrops();
    t.recordTransportDrop(
      TransportDropSample(
        cause: TransportDropCause.remoteClosed,
        failures: 0,
        busy: false,
        connectionAge: Duration.zero,
        at: DateTime.now(),
      ),
    );
    t.reset();
    expect(t.drops, hasLength(1));
    expect(t.monitorKillCount, 0);
  });

  test('drop ring is bounded at 20', () {
    final t = CommandTelemetry.instance..clearDrops();
    for (var i = 0; i < 25; i++) {
      t.recordTransportDrop(
        TransportDropSample(
          cause: TransportDropCause.remoteClosed,
          failures: 0,
          busy: false,
          connectionAge: Duration.zero,
          at: DateTime.now(),
        ),
      );
    }
    expect(t.drops, hasLength(20));
  });
}
