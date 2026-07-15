/// Shared request/response output draining for SSH and local executors.
///
/// Behavior-preserving extract: bounds memory for one-shot commands that
/// materialize full stdout/stderr as [String]. Streaming handles are exempt.
library;

/// Thrown when a request/response command's stdout (or stderr) grows past
/// [maxCommandOutputChars] / [maxCommandOutputBytes]. Never retried — a retry
/// would just reproduce the same oversized output.
class SSHOutputExceeded implements Exception {
  final String command;
  const SSHOutputExceeded(this.command);

  @override
  String toString() =>
      'SSH command output exceeded the maximum buffer size: $command';
}

/// Post-decode backstop on decoded characters a single request/response stream
/// may accumulate. Primary ceiling is [maxCommandOutputBytes].
const int maxCommandOutputChars = 50 * 1024 * 1024;

/// Primary in-memory output ceiling in **raw bytes** (pre-decode), shared
/// across a command's stdout+stderr via [OutputByteBudget].
const int maxCommandOutputBytes = 50 * 1024 * 1024;

/// A mutable byte budget shared across one command's stdout and stderr, so their
/// *combined* buffered output — not each stream independently — is what the cap
/// bounds. [charge] is called per raw byte chunk before decoding; the first
/// charge that pushes the running total over [limit] throws [SSHOutputExceeded].
/// Single-threaded by construction (both streams drain on the same isolate), so
/// the shared counter needs no synchronization.
class OutputByteBudget {
  OutputByteBudget([this.limit = maxCommandOutputBytes]);

  final int limit;
  int _used = 0;

  /// Total bytes charged so far — for tests/diagnostics.
  int get used => _used;

  void charge(int bytes, String command) {
    _used += bytes;
    if (_used > limit) throw SSHOutputExceeded(command);
  }
}

/// Accumulates a decoded [chunks] stream into a single String, aborting with
/// [SSHOutputExceeded] once more than [maxChars] characters have arrived.
Future<String> collectBounded(
  Stream<String> chunks,
  String command, {
  int maxChars = maxCommandOutputChars,
}) async {
  final buffer = StringBuffer();
  var total = 0;
  await for (final chunk in chunks) {
    total += chunk.length;
    if (total > maxChars) {
      throw SSHOutputExceeded(command);
    }
    buffer.write(chunk);
  }
  return buffer.toString();
}

/// Passes a raw byte stream through unchanged while charging each chunk's
/// length against [budget] *before* UTF-8 decoding.
Stream<List<int>> boundedBytes(
  Stream<List<int>> bytes,
  OutputByteBudget budget,
  String command,
) async* {
  await for (final chunk in bytes) {
    budget.charge(chunk.length, command);
    yield chunk;
  }
}
