import 'package:riverpod/misc.dart' show KeepAliveLink;

/// Bounds a `ref.keepAlive()`'d autoDispose family provider's cache to a
/// least-recently-used window, closing evicted entries' [KeepAliveLink]s so they
/// are free to autoDispose. Used by the diff/blame/file-history families: over
/// SSH, re-fetching a file/commit you just closed is the opposite of using
/// memory for speed, but caching forever would grow unbounded across a long
/// session — this caps it.
///
/// Two independent bounds:
/// - a [capacity] ceiling on the *number* of retained entries (governs the
///   list-valued caches, whose payload size isn't reported), and
/// - a [maxTotalBytes] budget across the entries whose payload size *is* reported
///   via [reportSize] (so a handful of very large commit patches / whole-file
///   diffs can't pin tens–hundreds of MB just because they're few enough to fit
///   the count cap), with a per-entry [maxEntryBytes] above which an entry is not
///   worth pinning at all and is released immediately.
class KeepAliveLru<K> {
  KeepAliveLru(
    this.capacity, {
    this.maxTotalBytes = 8 * 1024 * 1024,
    this.maxEntryBytes = 4 * 1024 * 1024,
  });

  /// Hard ceiling on the number of retained entries (evicted least-recently-used
  /// first) — governs the list-valued caches, whose payload size isn't reported.
  final int capacity;

  /// Byte budget across the entries whose payload size *is* reported (via
  /// [reportSize]). Bounds how much *content* — not just how many entries — a
  /// string-valued cache (huge commit patches, whole-file diffs) can pin.
  final int maxTotalBytes;

  /// An entry whose payload exceeds this is not worth pinning at all: re-fetching
  /// one very large diff/blob over SSH is cheaper than holding it for the whole
  /// session, so it is released immediately and left to autoDispose.
  final int maxEntryBytes;

  final _order = <K>[]; // least-recently-used first
  final _links = <K, KeepAliveLink>{};
  final _sizes = <K, int>{}; // reported payload sizes (code units)
  int _totalBytes = 0;

  /// Records [link] as [key]'s keep-alive, evicting to [capacity].
  ///
  /// The link this *replaces* is dropped, never closed — and that distinction is
  /// load-bearing. [touch] is only ever called from a provider's build body, so
  /// a second touch for the same key means that provider **rebuilt**, and a
  /// [KeepAliveLink] is bound to the build that created it: `Ref.keepAlive()`
  /// closes over that build's link list, and Riverpod discards the list on every
  /// rebuild (`runOnDispose` nulls it, and it runs before the body re-runs). The
  /// link being replaced here is therefore already void — Riverpod released it
  /// the moment the rebuild began, and [link] is the one now holding the element
  /// up.
  ///
  /// Closing it anyway ran Riverpod's `mayNeedDispose()` bookkeeping against the
  /// superseded build, which tore the freshly-built element down. The read in
  /// flight then landed on a dead element and its value was never published, so
  /// the provider sat in `AsyncLoading` forever — a diff pane that spins and
  /// never loads. The way in was ordinary: open file A's diff, click file B (A
  /// is now unwatched, but still pinned here), let anything touch A on disk — a
  /// build, a formatter, an editor autosave — so the watcher marks it stale and
  /// invalidates it while unwatched; then click back to A. Permanent spinner.
  ///
  /// [_evict] still closes, and must: there the link is the *current* build's,
  /// and releasing it is the entire point of this class.
  void touch(K key, KeepAliveLink link) {
    _links.remove(key);
    _order.remove(key);
    _order.add(key);
    _links[key] = link;
    while (_order.length > capacity) {
      _evict(_order.first);
    }
  }

  /// Records [key]'s payload size once its fetch resolves, then evicts to the
  /// byte budget. An entry over [maxEntryBytes] is released immediately;
  /// otherwise least-recently-used size-known entries are dropped until the
  /// summed size is back under [maxTotalBytes]. The just-touched [key] is never
  /// the entry evicted here. A [key] already gone (evicted by the count cap
  /// before its fetch resolved) is ignored.
  void reportSize(K key, int bytes) {
    if (!_links.containsKey(key)) return;
    _totalBytes -= _sizes.remove(key) ?? 0;
    if (bytes > maxEntryBytes) {
      _evict(key);
      return;
    }
    _sizes[key] = bytes;
    _totalBytes += bytes;
    for (final k in _order.toList()) {
      if (_totalBytes <= maxTotalBytes) break;
      if (k == key) continue;
      _evict(k);
    }
  }

  /// Drops [key], closing its [KeepAliveLink] so the provider is free to
  /// autoDispose. Used to release a FAILED fetch: without it the link pins the
  /// provider's `AsyncError`, and the immutable-tier caches (commit patches,
  /// file history) never invalidate — so a transient network blip would make
  /// re-selecting that commit return the cached failure forever instead of
  /// retrying. A [key] not present is a no-op.
  void evict(K key) => _evict(key);

  void _evict(K key) {
    _links.remove(key)?.close();
    _order.remove(key);
    _totalBytes -= _sizes.remove(key) ?? 0;
  }

  /// Releases every held link. Called alongside `ref.invalidate` in
  /// `ConnectionController._invalidateRepoState` so a stale connection's entries
  /// don't linger in this bookkeeping (harmless — they'd just occupy capacity
  /// until evicted — but there's no reason to let them).
  void clear() {
    for (final link in _links.values) {
      link.close();
    }
    _links.clear();
    _order.clear();
    _sizes.clear();
    _totalBytes = 0;
  }

  /// The number of entries currently retained — for tests/diagnostics.
  int get length => _order.length;

  /// Summed size of the entries whose payload size has been reported — for
  /// tests/diagnostics.
  int get totalBytes => _totalBytes;
}
