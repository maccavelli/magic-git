// KeepAliveLru bounds a keepAlive'd provider cache two ways: a hard entry-count
// cap (governs list-valued caches), and — for entries that report a payload
// size — a byte budget so a few very large diffs/blobs can't pin unbounded MB
// just because they fit under the count cap. Eviction closes the KeepAliveLink
// so the entry is free to autoDispose.

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/providers/keep_alive_lru.dart';
import 'package:riverpod/misc.dart' show KeepAliveLink;

class _FakeLink implements KeepAliveLink {
  bool closed = false;
  @override
  void close() => closed = true;
}

void main() {
  test('count cap evicts the least-recently-used entry and closes its link', () {
    final lru = KeepAliveLru<String>(2);
    final a = _FakeLink(), b = _FakeLink(), c = _FakeLink();
    lru.touch('a', a);
    lru.touch('b', b);
    lru.touch('c', c); // 'a' is now LRU and over capacity 2

    expect(a.closed, isTrue);
    expect(b.closed, isFalse);
    expect(c.closed, isFalse);
    expect(lru.length, 2);
  });

  test('touch refreshes recency so a re-touched key survives eviction', () {
    final lru = KeepAliveLru<String>(2);
    // A rebuild for the same key passes a *fresh* ref.keepAlive() link, so the
    // prior link for that key is closed and replaced — model that with a2.
    final a1 = _FakeLink(), a2 = _FakeLink(), b = _FakeLink(), c = _FakeLink();
    lru.touch('a', a1);
    lru.touch('b', b);
    lru.touch('a', a2); // 'a' becomes most-recent (a1 replaced); 'b' now LRU
    lru.touch('c', c); // over capacity → evict 'b'

    expect(a1.closed, isTrue); // replaced by a2
    expect(b.closed, isTrue); // evicted as LRU
    expect(a2.closed, isFalse); // survives — it was re-touched
    expect(c.closed, isFalse);
    expect(lru.length, 2);
  });

  test('an entry over maxEntryBytes is released immediately', () {
    final lru = KeepAliveLru<String>(24, maxEntryBytes: 1000, maxTotalBytes: 100000);
    final big = _FakeLink();
    lru.touch('big', big);
    lru.reportSize('big', 5000); // over the per-entry cap

    expect(big.closed, isTrue);
    expect(lru.length, 0);
    expect(lru.totalBytes, 0);
  });

  test('byte budget evicts LRU size-known entries but never the just-reported '
      'key', () {
    // Budget 100, per-entry cap 100. Three entries of 60 each: after the third
    // reports, total would be 180 > 100, so the two oldest are evicted until
    // back under budget — but the just-reported 'c' is kept.
    final lru = KeepAliveLru<String>(24, maxTotalBytes: 100, maxEntryBytes: 100);
    final a = _FakeLink(), b = _FakeLink(), c = _FakeLink();
    lru.touch('a', a);
    lru.reportSize('a', 60);
    lru.touch('b', b);
    lru.reportSize('b', 60); // total 120 > 100 → evict 'a'
    expect(a.closed, isTrue);
    expect(lru.totalBytes, 60);

    lru.touch('c', c);
    lru.reportSize('c', 60); // total 120 > 100 → evict 'b', keep 'c'
    expect(b.closed, isTrue);
    expect(c.closed, isFalse);
    expect(lru.totalBytes, 60);
    expect(lru.length, 1);
  });

  test('small entries under budget are all retained (count cap governs)', () {
    final lru = KeepAliveLru<String>(24, maxTotalBytes: 100000, maxEntryBytes: 100000);
    final links = [for (var i = 0; i < 10; i++) _FakeLink()];
    for (var i = 0; i < 10; i++) {
      lru.touch('k$i', links[i]);
      lru.reportSize('k$i', 100);
    }
    expect(links.every((l) => !l.closed), isTrue);
    expect(lru.length, 10);
    expect(lru.totalBytes, 1000);
  });

  test('reportSize for a key already evicted by the count cap is a no-op', () {
    final lru = KeepAliveLru<String>(1);
    final a = _FakeLink(), b = _FakeLink();
    lru.touch('a', a);
    lru.touch('b', b); // evicts 'a'
    // 'a's fetch resolves late — must not resurrect it or corrupt bookkeeping.
    lru.reportSize('a', 50);
    expect(lru.length, 1);
    expect(lru.totalBytes, 0);
  });

  test('evict drops one key (closing its link + freeing its bytes) and is a '
      'no-op for an absent key', () {
    final lru = KeepAliveLru<String>(24, maxTotalBytes: 100000, maxEntryBytes: 100000);
    final a = _FakeLink(), b = _FakeLink();
    lru.touch('a', a);
    lru.reportSize('a', 100);
    lru.touch('b', b);
    lru.reportSize('b', 40);

    // Releasing a failed fetch: evicting 'a' closes its link so the errored
    // provider can autoDispose (so a re-watch retries) and reclaims its bytes.
    lru.evict('a');
    expect(a.closed, isTrue);
    expect(b.closed, isFalse);
    expect(lru.length, 1);
    expect(lru.totalBytes, 40, reason: "'a's 100 bytes were reclaimed");

    // Evicting a key that isn't present must not corrupt accounting.
    lru.evict('missing');
    expect(lru.length, 1);
    expect(lru.totalBytes, 40);
  });

  test('clear closes every retained link and resets byte accounting', () {
    final lru = KeepAliveLru<String>(24);
    final a = _FakeLink(), b = _FakeLink();
    lru.touch('a', a);
    lru.reportSize('a', 100);
    lru.touch('b', b);
    lru.clear();

    expect(a.closed, isTrue);
    expect(b.closed, isTrue);
    expect(lru.length, 0);
    expect(lru.totalBytes, 0);
  });
}
