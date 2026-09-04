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

  /// The command that produced this sample, as issued — `gitArgs.join(' ')`.
  ///
  /// Raw, not normalised: [CommandTelemetry.countsByLabel] buckets it. Keeping
  /// the raw form here means a sample can still be read back in full for
  /// diagnosis, while the counter aggregates.
  final String label;

  const CommandSample({
    required this.lane,
    required this.duration,
    required this.bytes,
    required this.wireBytes,
    required this.compressed,
    required this.success,
    required this.label,
  });
}

/// Why an unexpected SSH session drop was recorded.
enum TransportDropCause { monitor, transportError, remoteClosed }

/// One unexpected transport drop — see [CommandTelemetry.recordTransportDrop].
@immutable
class TransportDropSample {
  final TransportDropCause cause;
  final int failures;
  final bool busy;
  final Duration connectionAge;
  final DateTime at;
  final String? peerReason;

  const TransportDropSample({
    required this.cause,
    required this.failures,
    required this.busy,
    required this.connectionAge,
    required this.at,
    this.peerReason,
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
  static const int _dropRingCapacity = 20;

  final List<CommandSample> _ring = [];
  final List<TransportDropSample> _dropRing = [];
  int _commandCount = 0;
  int _totalBytes = 0;
  int _totalWireBytes = 0;
  int _compressedBytes = 0;
  int _compressedWireBytes = 0;
  int _channelOpenErrors = 0;
  int _openStreams = 0;
  int _peakOpenStreams = 0;
  final Map<String, int> _countsByLabel = {};

  /// Recent samples, oldest first (bounded at [_ringCapacity]).
  List<CommandSample> get samples => List.unmodifiable(_ring);

  /// Commands recorded since the last [reset], bucketed by normalised label.
  ///
  /// Unbounded by the sample ring on purpose: the ring holds 200 samples for
  /// latency percentiles, but the question this answers — *which* commands a
  /// gesture caused, and how many of each — needs the whole session. A repo
  /// refresh that fires fifteen times is invisible in a 200-sample window once
  /// anything else happens (0025 Finding B).
  Map<String, int> get countsByLabel => Map.unmodifiable(_countsByLabel);

  /// Buckets a raw command label so the same command counts once.
  ///
  /// `git <subcommand> [<first following token>]`, with `-c key=value` pairs
  /// and leading global flags dropped, and any `--format`/`--pretty` collapsed.
  /// Without the `-c` rule the refs read splits into two buckets, because it
  /// carries `-c i18n.logOutputEncoding=UTF-8` and the plain form does not.
  /// Shell wrappers collapse to `sh -c`: their script is opaque and unique per
  /// call, so bucketing on it would defeat the point.
  @visibleForTesting
  static String bucketLabel(String raw) {
    final tokens = raw.trim().split(RegExp(r'\s+'))
      ..removeWhere((t) => t.isEmpty);
    if (tokens.isEmpty) return '(empty)';
    final exe = tokens.first.split('/').last;
    if (exe == 'sh' || exe == 'bash') return '$exe -c';

    var i = 1;
    while (i < tokens.length) {
      final t = tokens[i];
      if (t == '-c') {
        i += 2; // the pair
        continue;
      }
      if (t.startsWith('-')) {
        i += 1; // a global flag before the subcommand
        continue;
      }
      break;
    }
    if (i >= tokens.length) return exe;
    final sub = tokens[i];
    if (i + 1 >= tokens.length) return '$exe $sub';
    var next = tokens[i + 1];
    if (next.startsWith('--format') || next.startsWith('--pretty')) {
      next = '--format=…';
    }
    return '$exe $sub $next';
  }

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

  /// Unexpected drops, oldest first (bounded at [_dropRingCapacity]).
  /// Survives [reset] so the dashboard can still answer "why did it just
  /// drop" after the reconnect that follows.
  List<TransportDropSample> get drops => List.unmodifiable(_dropRing);

  /// Monitor-declared deaths in [drops]. Target is 0 in a healthy session.
  int get monitorKillCount =>
      _dropRing.where((d) => d.cause == TransportDropCause.monitor).length;

  void recordTransportDrop(TransportDropSample sample) {
    _dropRing.add(sample);
    if (_dropRing.length > _dropRingCapacity) _dropRing.removeAt(0);
    notifyListeners();
  }

  /// Test isolation only — production [reset] deliberately leaves [drops].
  @visibleForTesting
  void clearDrops() {
    _dropRing.clear();
    notifyListeners();
  }

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
    return Duration(
      microseconds:
          sorted[(sorted.length * 95 ~/ 100).clamp(0, sorted.length - 1)],
    );
  }

  void record(CommandSample sample) {
    _ring.add(sample);
    final bucket = bucketLabel(sample.label);
    _countsByLabel[bucket] = (_countsByLabel[bucket] ?? 0) + 1;
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

  /// Session marker for stream accounting — bumped by [reset]. A handle
  /// records the epoch it opened under and hands it back on close, so a
  /// previous session's handles still tearing down during a reconnect can't
  /// decrement the *new* session's open-stream count (the old `> 0` guard
  /// prevented negatives, not misattribution).
  int _streamEpoch = 0;

  /// Tracks a newly opened long-lived stream handle. The returned token must
  /// be passed to [streamClosed] when the handle dies.
  int streamOpened() {
    _openStreams++;
    if (_openStreams > _peakOpenStreams) _peakOpenStreams = _openStreams;
    notifyListeners();
    return _streamEpoch;
  }

  /// Tracks a closed/cancelled long-lived stream handle opened under [epoch].
  void streamClosed(int epoch) {
    if (epoch != _streamEpoch) return; // opened before the last reset
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
    _countsByLabel.clear();
    _streamEpoch++; // orphan the previous session's still-closing handles
    notifyListeners();
  }
}
