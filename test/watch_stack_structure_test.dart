// MADR 0045 phase 6. Structural guards for the watcher stack: what the migration
// removed stays removed, because each of these came back once already or was
// the shape a defect lived in.
//
// The top-level `watchDiagnostics` — the log every watcher records into — is
// outside the static scan by construction: it is not `static`. MADR 0045
// section 6 retains it.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// A `static` that is not `const`: process-wide state a second tab shares.
final _mutableStatic = RegExp(
  r'^\s*static\s+(?!const\b)(?:final\s+|late\s+|var\s+)?[\w<>?, ]+\s+\w+\s*(=|;)',
);

/// A real-time wait in a test.
final _realTimeWait = RegExp(
  r'settleArm\(|Future\.delayed|Future<void>\.delayed|\bsleep\(',
);

/// Watcher tests that keep real time, each for a reason fake time cannot meet.
const _realTimeAllowed = <String, String>{
  'watch_lease_teardown_exec_test.dart':
      'runs the real arming script under a real sh, with real child processes',
  'watcher_sweep_exec_test.dart':
      'runs the real sweep script against real processes',
  'worktree_lock_key_exec_test.dart':
      'runs real git and the real lock script in a real linked worktree',
  'local_watch_bounded_test.dart':
      'arms a real Directory.watch, whose events come from the operating system',
  'local_watch_service_test.dart':
      'arms a real Directory.watch, whose events come from the operating system',
  'local_watch_worktree_test.dart':
      'arms a real Directory.watch over real git worktrees',
  'directory_watch_source_test.dart':
      'arms a real Directory.watch over real git worktrees',
  'watch_diagnostics_local_test.dart':
      'arms a real Directory.watch (MADR 0045 plan, deviation (r))',
  'watch_stack_structure_test.dart':
      'this file: it names the patterns it scans for',
};

String _read(File file) =>
    // Lenient: one file in lib/ carries bytes a strict decode rejects.
    utf8.decode(file.readAsBytesSync(), allowMalformed: true);

List<File> _dartFiles(String directory, {bool recursive = true}) =>
    Directory(directory)
        .listSync(recursive: recursive)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));

void main() {
  test('no mutable static in the watch stack', () {
    final scanned = [
      ..._dartFiles('lib/core/git/watch'),
      for (final path in const [
        'lib/core/git/remote_watch_service.dart',
        'lib/core/git/local_watch_service.dart',
        'lib/core/git/bounded_watch.dart',
        'lib/core/git/watch_diagnostics.dart',
      ])
        File(path),
    ];
    expect(scanned, hasLength(greaterThan(4)), reason: 'the scan found files');

    final found = [
      for (final file in scanned)
        for (final (i, line) in _read(file).split('\n').indexed)
          if (_mutableStatic.hasMatch(line)) '${file.path}:${i + 1}: $line',
    ];
    expect(
      found,
      isEmpty,
      reason:
          'the watcher budget, the shared-watch map and the token counter were '
          'each process-wide statics shared by every tab (MADR 0045 F7)',
    );
  });

  test('the retired machinery is gone', () {
    const retired = [
      'watchLifecycle(',
      '_SharedWatch',
      '_liveByHost',
      'resetWatcherCount',
      'sharedTeardownGrace',
      '_detectWatcher',
    ];
    final found = [
      for (final file in _dartFiles('lib'))
        for (final name in retired)
          if (_read(file).contains(name)) '${file.path}: $name',
    ];
    expect(
      found,
      isEmpty,
      reason:
          'each was replaced by one owner — the engine, admission, the budget, '
          'the tool probe — and a second copy is how drift starts',
    );
  });

  test('watcher logic tests do not sleep', () {
    final watcherTests = _dartFiles('test', recursive: false).where((file) {
      final name = file.uri.pathSegments.last;
      return name.contains('watch') && name.endsWith('_test.dart');
    }).toList();
    expect(
      _realTimeAllowed.keys.where((name) => !File('test/$name').existsSync()),
      isEmpty,
      reason:
          'an allow-list entry naming no file would silently cover whatever '
          'takes that name next',
    );

    final found = [
      for (final file in watcherTests)
        if (!_realTimeAllowed.containsKey(file.uri.pathSegments.last))
          for (final (i, line) in _read(file).split('\n').indexed)
            if (_realTimeWait.hasMatch(line)) '${file.path}:${i + 1}: $line',
    ];
    expect(
      found,
      isEmpty,
      reason:
          'a watcher logic test runs its timers in fake time: real waits made '
          'this suite load-sensitive and produced false mutation survivors '
          '(MADR 0045 F8)',
    );
  });
}
