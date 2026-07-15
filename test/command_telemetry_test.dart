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
    t.streamOpened();
    t.streamClosed();
    expect(t.channelOpenErrors, 2);
    expect(t.openStreams, 1);
    expect(t.peakOpenStreams, 2);
    t.reset();
    expect(t.channelOpenErrors, 0);
    expect(t.openStreams, 0);
    expect(t.peakOpenStreams, 0);
  });
}
