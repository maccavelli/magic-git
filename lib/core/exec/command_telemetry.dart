import 'package:flutter/foundation.dart';

import 'command_lanes.dart';

/// One completed command's measurements — see [CommandTelemetry].
@immutable
class CommandSample {
  final ExecLane lane;
  final Duration duration;

  /// Bytes this process buffered for the command (decompressed for a
  /// compressed read).
  final int bytes;

  /// Bytes that actually crossed the wire for stdout (differs from [bytes]
  /// only for compressed reads). Equal to the stdout portion of [bytes] for
  /// everything else.
  final int wireBytes;
  final bool compressed;
  final bool success;

  const CommandSample({
    required this.lane,
    required this.duration,
    required this.bytes,
    required this.wireBytes,
    required this.compressed,
    required this.success,
  });
}

/// Session-wide command measurements, recorded by both executors (SSH and
/// local) and read by the Dashboard. A process-wide singleton rather than a
/// provider: the executors are plain classes with no Riverpod access, and
/// one shared sink keeps the recording call a one-liner on their hot path.
///
/// Keeps a bounded ring of recent samples (for latency percentiles/sparkline)
/// plus running totals. [reset] is called on every connect, so the numbers
/// always describe the current session.
class CommandTelemetry extends ChangeNotifier {
  CommandTelemetry._();
  static final CommandTelemetry instance = CommandTelemetry._();

  static const int _ringCapacity = 200;

  final List<CommandSample> _ring = [];
  int _commandCount = 0;
  int _totalBytes = 0;
  int _totalWireBytes = 0;
  int _compressedBytes = 0;
  int _compressedWireBytes = 0;
  int _channelOpenErrors = 0;
  int _openStreams = 0;
  int _peakOpenStreams = 0;

  /// Recent samples, oldest first (bounded at [_ringCapacity]).
  List<CommandSample> get samples => List.unmodifiable(_ring);

  /// Commands recorded since the last [reset].
  int get commandCount => _commandCount;

  /// Total buffered (post-decompression) bytes since the last [reset].
  int get totalBytes => _totalBytes;

  /// Total wire bytes since the last [reset].
  int get totalWireBytes => _totalWireBytes;

  /// Decompressed vs wire totals for compressed reads only — what the gzip
  /// layer actually saved on the link.
  int get compressedBytes => _compressedBytes;
  int get compressedWireBytes => _compressedWireBytes;

  /// Times an SSH channel open failed this session (e.g. MaxSessions /
  /// `SSHChannelOpenError`). Evidence for dual-client capacity work.
  int get channelOpenErrors => _channelOpenErrors;

  /// Live long-lived streams currently open (watcher, CI trace, batch).
  int get openStreams => _openStreams;

  /// Peak concurrent long-lived streams this session.
  int get peakOpenStreams => _peakOpenStreams;

  /// Mean duration across the recent ring; zero when empty.
  Duration get averageDuration {
    if (_ring.isEmpty) return Duration.zero;
    final total = _ring.fold<int>(0, (n, s) => n + s.duration.inMicroseconds);
    return Duration(microseconds: total ~/ _ring.length);
  }

  /// p95 duration across the recent ring; zero when empty.
  Duration get p95Duration {
    if (_ring.isEmpty) return Duration.zero;
    final sorted = [for (final s in _ring) s.duration.inMicroseconds]..sort();
    return Duration(microseconds: sorted[(sorted.length * 95 ~/ 100)
        .clamp(0, sorted.length - 1)]);
  }

  void record(CommandSample sample) {
    _ring.add(sample);
    if (_ring.length > _ringCapacity) _ring.removeAt(0);
    _commandCount++;
    _totalBytes += sample.bytes;
    _totalWireBytes += sample.wireBytes;
    if (sample.compressed) {
      _compressedBytes += sample.bytes;
      _compressedWireBytes += sample.wireBytes;
    }
    notifyListeners();
  }

  /// Records a failed SSH channel open (typically MaxSessions pressure).
  void recordChannelOpenError() {
    _channelOpenErrors++;
    notifyListeners();
  }

  /// Tracks a newly opened long-lived stream handle.
  void streamOpened() {
    _openStreams++;
    if (_openStreams > _peakOpenStreams) _peakOpenStreams = _openStreams;
    notifyListeners();
  }

  /// Tracks a closed/cancelled long-lived stream handle.
  void streamClosed() {
    if (_openStreams > 0) _openStreams--;
    notifyListeners();
  }

  /// Clears everything — called when a new session connects, so the dashboard
  /// describes the current connection rather than the app's lifetime.
  void reset() {
    _ring.clear();
    _commandCount = 0;
    _totalBytes = 0;
    _totalWireBytes = 0;
    _compressedBytes = 0;
    _compressedWireBytes = 0;
    _channelOpenErrors = 0;
    _openStreams = 0;
    _peakOpenStreams = 0;
    notifyListeners();
  }
}
