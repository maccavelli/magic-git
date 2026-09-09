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
///
/// **Entries are partitioned by session scope.** Each instance is one
/// process-global object, but every tab is its own root `ProviderContainer`
/// with its own `KeepAliveLink`s, so an entry belongs to a container and only
/// that container may release it. Every operation therefore takes a `scope`
/// (see `SessionScope`) alongside the key, and [clearScope] releases one
/// session's entries rather than everyone's (MADR 0039 F1/F2).
///
/// The two **bounds stay global and unpartitioned**, deliberately: [capacity]
/// and [maxTotalBytes] describe one process's memory, and giving each of up to
/// eight tabs its own budget would multiply the app's resident cache by eight
/// for no reason. Only the *keys* are scoped.
///
/// **Eviction is cost-aware, not recency-only.** Both bounds ask about size;
/// neither asked what an entry cost to obtain, and over SSH those are very
/// different questions — a 2 KB file diff is one round trip, while a 12 MiB
/// commit patch on a high-latency link is seconds the user watches. Recency
/// alone will happily discard the expensive entry to keep a cheap one touched
/// more recently, which is the opposite of what a cache on a slow link is for.
/// [reportSize] therefore also takes the measured [Duration] the fetch took, and
/// eviction picks the least valuable entry under a Greedy-Dual-Size-Frequency
/// rule (MADR 0039 A3):
///
///   `value = clock + hits × (costMillis / bytes)`
///
/// The `clock` term is Greedy-Dual's ageing: it is set to the value of the last
/// entry evicted, so a once-hot expensive entry cannot pin the cache forever.
/// With uniform costs the ordering degenerates to plain LRU, so a local repo —
/// where every fetch is cheap — behaves exactly as it did.
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

  /// One entry's identity: the owning session plus the caller's key. A record,
  /// so structural equality does the work — two containers asking for the same
  /// repo path and commit hash are two entries, not one.
  final _order = <(Object, K)>[]; // least-recently-used first
  final _links = <(Object, K), KeepAliveLink>{};
  final _sizes = <(Object, K), int>{}; // reported payload sizes (code units)

  /// What each entry cost to fetch, in milliseconds. Absent means the fetch has
  /// not resolved — the entry is IN FLIGHT and is never chosen for eviction.
  final _costs = <(Object, K), int>{};

  /// How many times each entry has been touched (Greedy-Dual's frequency term).
  final _hits = <(Object, K), int>{};

  /// Each entry's eviction score, **fixed at the moment it was admitted or last
  /// re-referenced** — not recomputed from the live clock.
  ///
  /// That distinction is the whole ageing mechanism, and getting it wrong makes
  /// the clock term do nothing: if every entry's score is recomputed against the
  /// current clock, they all rise together and their *order* never changes, so a
  /// once-hot expensive entry outranks everything admitted after it for the life
  /// of the session. Stored, the clock is the floor that later admissions start
  /// from, and an old high score is eventually overtaken.
  final _values = <(Object, K), double>{};

  int _totalBytes = 0;

  /// Greedy-Dual ageing term: the value of the most recently evicted entry.
  /// Everything admitted after an eviction starts above it, so an old entry with
  /// a once-high value ages out instead of pinning the cache.
  double _clock = 0;

  /// (Re)scores [entry] from the current clock. A no-op while its fetch has not
  /// resolved — an entry with no known cost has no score, which is how in-flight
  /// entries are kept out of the candidate set.
  void _rescore((Object, K) entry) {
    final cost = _costs[entry];
    if (cost == null) return;
    final bytes = _sizes[entry] ?? 1;
    final hits = _hits[entry] ?? 1;
    _values[entry] = _clock + hits * (cost / (bytes < 1 ? 1 : bytes));
  }

  /// The entry eviction should take next, or null when there is nothing to take.
  ///
  /// Candidates are entries whose cost is known; among them the lowest value
  /// wins, ties broken by recency (`_order` is least-recently-used first, and
  /// `firstWhere`-style iteration therefore prefers the older). When *nothing*
  /// has a known cost — every entry still in flight, or a cache that has never
  /// reported — it falls back to plain LRU so the bounds still bind.
  (Object, K)? _evictionCandidate({(Object, K)? except}) {
    (Object, K)? best;
    double? bestValue;
    for (final entry in _order) {
      if (entry == except) continue;
      final value = _values[entry];
      if (value == null) continue;
      if (bestValue == null || value < bestValue) {
        best = entry;
        bestValue = value;
      }
    }
    if (best != null) {
      _clock = bestValue!;
      return best;
    }
    for (final entry in _order) {
      if (entry != except) return entry;
    }
    return null;
  }

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
  ///
  /// That reasoning holds only **within one container**, which is why entries
  /// are scoped. Across two containers a repeated key is not a rebuild — it is a
  /// second, live provider element in a different tab — and dropping its link
  /// leaked it: pinned forever, invisible to both bounds. Scoping makes the
  /// precondition true again rather than weakening the rule (MADR 0039 F2).
  void touch(Object scope, K key, KeepAliveLink link) {
    final entry = (scope, key);
    _links.remove(entry);
    _order.remove(entry);
    _order.add(entry);
    _links[entry] = link;
    _hits[entry] = (_hits[entry] ?? 0) + 1;
    // A re-reference re-scores from the current clock — the frequency term is
    // only worth anything if a second read actually moves the entry.
    _rescore(entry);
    while (_order.length > capacity) {
      final victim = _evictionCandidate(except: entry);
      if (victim == null) break;
      _evict(victim);
    }
  }

  /// Records [key]'s payload size once its fetch resolves, then evicts to the
  /// byte budget. An entry over [maxEntryBytes] is released immediately;
  /// otherwise least-recently-used size-known entries are dropped until the
  /// summed size is back under [maxTotalBytes]. The just-touched [key] is never
  /// the entry evicted here. A [key] already gone (evicted by the count cap
  /// before its fetch resolved) is ignored.
  /// [cost] is how long the fetch took — the measurement that makes eviction
  /// cost-aware. Omitted, the entry is scored as if it were free, which ranks it
  /// for eviction ahead of anything that reported a real cost.
  void reportSize(Object scope, K key, int bytes, {Duration? cost}) {
    final entry = (scope, key);
    if (!_links.containsKey(entry)) return;
    _totalBytes -= _sizes.remove(entry) ?? 0;
    if (bytes > maxEntryBytes) {
      _evict(entry);
      return;
    }
    _sizes[entry] = bytes;
    _totalBytes += bytes;
    // Recorded even when zero: a *known* cost of zero is what puts an entry at
    // the front of the eviction queue, where an UNKNOWN cost means "still in
    // flight" and keeps it out of the queue entirely.
    _costs[entry] = cost?.inMilliseconds ?? 0;
    _rescore(entry);
    // The byte budget is global, so this may evict another session's entry —
    // correct, and the point of keeping one budget for one process. What it may
    // never do is evict on the strength of a *different* session's report for
    // the same key, which is what an unscoped map did.
    while (_totalBytes > maxTotalBytes) {
      final victim = _evictionCandidate(except: entry);
      if (victim == null) break;
      _evict(victim);
    }
  }

  /// Drops [key], closing its [KeepAliveLink] so the provider is free to
  /// autoDispose. Used to release a FAILED fetch: without it the link pins the
  /// provider's `AsyncError`, and the immutable-tier caches (commit patches,
  /// file history) never invalidate — so a transient network blip would make
  /// re-selecting that commit return the cached failure forever instead of
  /// retrying. A [key] not present is a no-op.
  void evict(Object scope, K key) => _evict((scope, key));

  void _evict((Object, K) entry) {
    _links.remove(entry)?.close();
    _order.remove(entry);
    _totalBytes -= _sizes.remove(entry) ?? 0;
    _costs.remove(entry);
    _hits.remove(entry);
    _values.remove(entry);
  }

  /// Releases the links [scope] holds, and only those. Called alongside
  /// `ref.invalidate` in `ConnectionController._invalidateRepoState` so a stale
  /// connection's entries don't linger in this bookkeeping.
  ///
  /// Scoped, not global, because `_invalidateRepoState` runs in **one** tab's
  /// container while this object is shared by all of them: a global clear
  /// released every other tab's cached patches on any tab's connect — including
  /// each attempt of an auto-reconnect (MADR 0039 F1).
  void clearScope(Object scope) {
    for (final entry in _order.toList()) {
      if (entry.$1 == scope) _evict(entry);
    }
  }

  /// Releases every held link in every scope. Teardown and tests only —
  /// production clears one session at a time via [clearScope].
  void clear() {
    for (final link in _links.values) {
      link.close();
    }
    _links.clear();
    _order.clear();
    _sizes.clear();
    _costs.clear();
    _hits.clear();
    _values.clear();
    _totalBytes = 0;
    _clock = 0;
  }

  /// The number of entries currently retained across every scope — for
  /// tests/diagnostics.
  int get length => _order.length;

  /// The number of entries [scope] currently holds — for tests/diagnostics.
  int lengthFor(Object scope) =>
      _order.where((entry) => entry.$1 == scope).length;

  /// Summed size of the entries whose payload size has been reported — for
  /// tests/diagnostics.
  int get totalBytes => _totalBytes;
}
