// LocalWatchService drives the local backend's status refresh off dart:io's
// real Directory.watch (no fswatch/inotifywait subprocess). It had zero
// coverage, yet a wrong relativize/filter silently makes the local backend
// either never refresh or refresh on every event. fakeAsync can't drive real
// filesystem events, so this is a real-FS integration test with small watcher
// durations and bounded waits.
@Tags(['integration'])
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/local_watch_service.dart';
import 'package:remote_magic_git/core/git/watch_event.dart';

void main() {
  late Directory dir;
  late LocalWatchService svc;
  final subs = <StreamSubscription<RepoWatchEvent>>[];

  setUp(() async {
    // Canonicalize the temp path so it shares the exact prefix that
    // FileSystemEvent.path carries (macOS reports /private/var/…), which
    // LocalWatchService.relativize strips before filtering.
    final raw = await Directory.systemTemp.createTemp('local_watch_');
    dir = Directory(raw.resolveSymbolicLinksSync());
    svc = LocalWatchService();
  });

  tearDown(() async {
    for (final s in subs) {
      await s.cancel();
    }
    subs.clear();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  Stream<RepoWatchEvent> watch() => svc.watch(
    dir.path,
    trailing: const Duration(milliseconds: 40),
    maxWait: const Duration(milliseconds: 120),
    minInterval: const Duration(milliseconds: 40),
  );

  Future<void> pumpUntil(
    bool Function() condition, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) {
        fail('condition not satisfied within $timeout');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  test(
    'announces eventDriven on listen, then coalesces a real edit into a tick',
    () async {
      final events = <RepoWatchEvent>[];
      subs.add(watch().listen(events.add));

      // The watcher arms and immediately announces itself (green status dot),
      // rather than sitting grey until the first real change.
      await pumpUntil(() => events.isNotEmpty);
      expect(events.first.mode, WatchMode.eventDriven);

      final before = events.length;
      File('${dir.path}/foo.txt').writeAsStringSync('hello');

      await pumpUntil(() => events.length > before);
      expect(events.last.mode, WatchMode.eventDriven);
    },
  );

  test(
    'filters .git/index.lock churn but stays live for real changes',
    () async {
      // Pre-create .git BEFORE listening so its own directory-create event
      // isn't part of what's under test.
      Directory('${dir.path}/.git').createSync();

      final events = <RepoWatchEvent>[];
      subs.add(watch().listen(events.add));
      await pumpUntil(() => events.isNotEmpty); // announce tick
      final afterAnnounce = events.length;

      // Git-op lock churn must NOT trigger a refresh.
      File('${dir.path}/.git/index.lock').writeAsStringSync('');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(
        events.length,
        afterAnnounce,
        reason: '.git/index.lock is git-op noise and must be filtered out',
      );

      // …but the watcher is still live: a real working-tree edit does trigger,
      // proving the absence above was the filter, not a dead watcher.
      File('${dir.path}/real.txt').writeAsStringSync('x');
      await pumpUntil(() => events.length > afterAnnounce);
      expect(events.last.mode, WatchMode.eventDriven);
    },
  );
}
