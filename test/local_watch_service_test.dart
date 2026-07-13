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

  test('a tick names the paths the burst touched', () async {
    // Without them a tick can only say "something, somewhere, moved", and every
    // consumer has to assume the worst — which is how a build writing files git
    // ignores ended up re-reading the whole repository several times a second.
    final dir = Directory.systemTemp.createTempSync('watch_paths_');
    addTearDown(() => dir.deleteSync(recursive: true));
    Directory('${dir.path}/.git').createSync();
    Directory('${dir.path}/lib').createSync();

    final events = <RepoWatchEvent>[];
    subs.add(LocalWatchService().watch(dir.path).listen(events.add));
    await pumpUntil(() => events.isNotEmpty); // the start-up announce tick

    // The announce tick has nothing to report and says so: an empty set means
    // "scope unknown", which consumers read as "assume everything".
    expect(events.first.isScoped, isFalse);

    final afterAnnounce = events.length;
    File('${dir.path}/lib/a.dart').writeAsStringSync('x');
    await pumpUntil(() => events.length > afterAnnounce);

    final tick = events.last;
    expect(tick.isScoped, isTrue);
    expect(tick.paths, contains('lib/a.dart'));
    expect(tick.touchesGitState, isFalse);
  });

  test('a tick reports a move in git\'s own state as such', () async {
    final dir = Directory.systemTemp.createTempSync('watch_gitstate_');
    addTearDown(() => dir.deleteSync(recursive: true));
    Directory('${dir.path}/.git').createSync();

    final events = <RepoWatchEvent>[];
    subs.add(LocalWatchService().watch(dir.path).listen(events.add));
    await pumpUntil(() => events.isNotEmpty);
    final afterAnnounce = events.length;

    // Staging, committing, checking out — anything that moves the index. It
    // belongs to no single file, and consumers must widen their scope for it.
    File('${dir.path}/.git/index').writeAsStringSync('x');
    await pumpUntil(() => events.length > afterAnnounce);

    expect(events.last.paths, contains('.git/index'));
    expect(events.last.touchesGitState, isTrue);
  });
}
