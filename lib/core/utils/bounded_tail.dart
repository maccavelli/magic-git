/// A [StringBuffer]-shaped sink that keeps only the last [maxChars] characters
/// written to it.
///
/// For a long-lived stream whose consumer only ever needs a bounded *tail* —
/// e.g. a CI job's stderr, read once at the end merely to detect a failure and
/// quote a one-line error — buffering every chunk for the whole run would grow
/// without bound. This retains a fixed-size window instead.
///
/// Compaction is amortized O(1): the backing buffer is only rewritten once it
/// grows past twice the cap, then trimmed back to the last [maxChars]. So the
/// resident size stays within `[maxChars, 2 * maxChars)` and no per-chunk copy
/// is paid.
class BoundedTail {
  BoundedTail(this.maxChars) : assert(maxChars > 0);

  final int maxChars;
  final StringBuffer _buf = StringBuffer();
  int _len = 0;

  /// Appends [chunk], dropping the oldest characters if the retained content
  /// would exceed twice [maxChars].
  void write(String chunk) {
    _buf.write(chunk);
    _len += chunk.length;
    if (_len > maxChars * 2) {
      final tail = _buf.toString().substring(_len - maxChars);
      _buf
        ..clear()
        ..write(tail);
      _len = maxChars;
    }
  }

  /// The retained tail: the last [maxChars] characters written (or everything,
  /// if less than that has been written).
  @override
  String toString() {
    final s = _buf.toString();
    return s.length > maxChars ? s.substring(s.length - maxChars) : s;
  }
}
