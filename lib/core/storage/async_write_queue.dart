/// Serializes async read-modify-write operations against a shared store.
///
/// Each queued action's full read-then-write runs to completion before the
/// next one starts, so two callers racing on the same underlying data (e.g. a
/// `touch` on connect racing a `save` from an edit sheet) can't interleave
/// their read and write and silently clobber each other's change.
class AsyncWriteQueue {
  Future<void> _queue = Future.value();

  Future<T> run<T>(Future<T> Function() action) {
    final result = _queue.then((_) => action());
    // Chain off the result regardless of success/failure, so one failed
    // write doesn't wedge every write queued after it.
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }
}
