import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';

void main() {
  test('in-flight begin makes isRecent true past the echo window', () {
    final t = DateTime.utc(2026, 1, 1);
    final tracker = OwnMutationTracker(now: () => t);
    tracker.begin('/r');
    expect(
      tracker.isRecent(
        '/r',
        t.add(const Duration(seconds: 10)),
        const Duration(seconds: 3),
      ),
      isTrue,
    );
    tracker.end('/r');
  });

  test('end marks the 3s echo window', () {
    final t = DateTime.utc(2026, 1, 1);
    final tracker = OwnMutationTracker(now: () => t);
    tracker.begin('/r');
    tracker.end('/r');
    expect(
      tracker.isRecent(
        '/r',
        t.add(const Duration(seconds: 1)),
        const Duration(seconds: 3),
      ),
      isTrue,
    );
    expect(
      tracker.isRecent(
        '/r',
        t.add(const Duration(seconds: 4)),
        const Duration(seconds: 3),
      ),
      isFalse,
    );
  });

  test('nested begin/end does not mark while outer is in-flight', () {
    var t = DateTime.utc(2026, 1, 1);
    final tracker = OwnMutationTracker(now: () => t);
    tracker.begin('/r');
    tracker.begin('/r');
    tracker.end('/r');
    expect(
      tracker.isRecent(
        '/r',
        t.add(const Duration(seconds: 10)),
        const Duration(seconds: 3),
      ),
      isTrue,
      reason: 'outer begin still in-flight',
    );
    t = t.add(const Duration(seconds: 10));
    tracker.end('/r');
    expect(
      tracker.isRecent(
        '/r',
        t.add(const Duration(seconds: 1)),
        const Duration(seconds: 3),
      ),
      isTrue,
    );
    expect(
      tracker.isRecent(
        '/r',
        t.add(const Duration(seconds: 4)),
        const Duration(seconds: 3),
      ),
      isFalse,
    );
  });

  test('clear drops in-flight so a reconnect cannot suppress', () {
    final t = DateTime.utc(2026, 1, 1);
    final tracker = OwnMutationTracker(now: () => t);
    tracker.begin('/r');
    tracker.clear();
    expect(tracker.isRecent('/r', t, const Duration(seconds: 3)), isFalse);
  });

  test('withOwnMutation ends (and marks) when the body throws', () async {
    final t = DateTime.utc(2026, 1, 1);
    final tracker = OwnMutationTracker(now: () => t);
    await expectLater(
      () => withOwnMutation(tracker, '/r', () async => throw StateError('x')),
      throwsStateError,
    );
    expect(
      tracker.isRecent(
        '/r',
        t.add(const Duration(seconds: 10)),
        const Duration(seconds: 3),
      ),
      isFalse,
    );
    expect(
      tracker.isRecent(
        '/r',
        t.add(const Duration(seconds: 1)),
        const Duration(seconds: 3),
      ),
      isTrue,
    );
  });
}
