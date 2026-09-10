/// Splits a watcher's stdout into delimited event records.
///
/// A cursor, not repeated re-slicing: `buffer = buffer.substring(...)` per
/// record copies the whole remainder and restarts the scan at 0, which is
/// quadratic in the chunk — measured at 522 ms of UI-isolate time for a
/// 20 000-event `git checkout` burst at dartssh2's 32 KiB packet size, against
/// about 1 ms this way (0024 A1). One remainder copy per chunk.
final class RecordSplitter {
  RecordSplitter({
    required this.delimiter,
    required this.maxBufferChars,
    this.onOverflow,
  });

  /// The record terminator: `\n` for inotifywait, NUL for fswatch.
  final String delimiter;

  /// Past this, an unterminated partial is dropped rather than buffered without
  /// bound — a wedged tool streaming output that never completes a record.
  final int maxBufferChars;

  /// Called when a partial is dropped for exceeding [maxBufferChars].
  final void Function()? onOverflow;

  var _buffer = '';

  /// Adds [chunk] and returns every record it completes, in order. An
  /// unterminated tail is kept for the next chunk.
  List<String> add(String chunk) {
    _buffer += chunk;
    final records = <String>[];
    var start = 0;
    var idx = _buffer.indexOf(delimiter, start);
    while (idx >= 0) {
      records.add(_buffer.substring(start, idx));
      start = idx + delimiter.length;
      idx = _buffer.indexOf(delimiter, start);
    }
    if (start > 0) _buffer = _buffer.substring(start);
    if (_buffer.length > maxBufferChars) {
      _buffer = '';
      onOverflow?.call();
    }
    return records;
  }
}
