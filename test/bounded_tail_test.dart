// BoundedTail keeps only the last N characters written — the bound that stops
// a long-lived stream's stderr tail (glab ci trace) from growing without limit.

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/utils/bounded_tail.dart';

void main() {
  test('retains everything when under the cap', () {
    final tail = BoundedTail(16);
    tail.write('hello');
    tail.write(' world');
    expect(tail.toString(), 'hello world');
  });

  test('keeps only the last maxChars once over the cap', () {
    final tail = BoundedTail(5);
    tail.write('abcdefghij'); // 10 chars into a cap of 5
    expect(tail.toString(), 'fghij');
  });

  test('retains the tail across many small writes (bounded growth)', () {
    final tail = BoundedTail(8);
    for (var i = 0; i < 1000; i++) {
      tail.write('0123456789'); // 10k chars total, cap 8
    }
    // The stream ends "...0123456789", so the retained tail is its last 8.
    final out = tail.toString();
    expect(out.length, 8);
    expect(out, '23456789');
  });

  test('a single oversized write is trimmed to the tail', () {
    final tail = BoundedTail(4);
    tail.write('abcdefghijklmnop');
    expect(tail.toString(), 'mnop');
  });

  test('exact-cap boundary keeps the whole content', () {
    final tail = BoundedTail(4);
    tail.write('abcd');
    expect(tail.toString(), 'abcd');
  });
}
