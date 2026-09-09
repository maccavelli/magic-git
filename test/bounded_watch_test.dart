// Bounded watch surface for a scoped work-tree (dotfiles) repo: instead of a
// recursive watch of the whole work tree ($HOME — measured 257k dirs on a real
// bastion), watch only the git-dir signal points and the parent directory of
// each tracked file, non-recursively. This proves the surface computation, the
// absolute→repo-relative event remap (which lets the shared filter and
// touchesGitState work unchanged), and that the emitted watcher command is
// genuinely non-recursive.

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/bounded_watch.dart';
import 'package:remote_magic_git/core/git/watch_path_filter.dart';

void main() {
  const gitDir = '/home/u/.home.git';
  const workTree = '/home/u';

  // A representative slice of a real dotfiles working set: a top-level file,
  // two files sharing one dir (must dedupe), and a nested dir.
  const tracked = [
    '.bashrc',
    '.config/bash/aliases.sh',
    '.config/bash/env.sh',
    '.claude/CLAUDE.md',
  ];

  group('computeBoundedWatchSpec', () {
    test('collapses to git-dir points + unique tracked-file dirs', () {
      final spec = computeBoundedWatchSpec(
        gitDir: gitDir,
        workTree: workTree,
        trackedFiles: tracked,
      );
      expect(spec.gitDir, gitDir);
      expect(spec.workTree, workTree);
      expect(spec.watchDirs, [
        '/home/u', // from .bashrc (dirname is the work-tree root)
        '/home/u/.claude',
        '/home/u/.config/bash', // aliases.sh + env.sh deduped to one dir
        '/home/u/.home.git', // git-dir root
        '/home/u/.home.git/refs/heads', // branch-ref writes
        '/home/u/.home.git/refs/tags', // tag-ref writes
      ]);
      // Four tracked files across three dirs + three git-dir points = six —
      // versus a recursive watch of every directory under $HOME.
      expect(spec.watchDirs.length, 6);
    });

    test('trailing slashes stripped; empty tracked list still watches git', () {
      final spec = computeBoundedWatchSpec(
        gitDir: '$gitDir/',
        workTree: '$workTree/',
        trackedFiles: const [],
      );
      expect(spec.gitDir, gitDir);
      expect(spec.workTree, workTree);
      expect(spec.watchDirs, [
        '/home/u/.home.git',
        '/home/u/.home.git/refs/heads',
        '/home/u/.home.git/refs/tags',
      ]);
    });
  });

  group('relativizeBoundedEvent', () {
    late BoundedWatchSpec spec;
    setUp(() {
      spec = computeBoundedWatchSpec(
        gitDir: gitDir,
        workTree: workTree,
        trackedFiles: tracked,
      );
    });

    test(
      'git-dir events become .git/… (checked before the work-tree prefix)',
      () {
        // The git-dir lives INSIDE the work tree, so precedence matters.
        expect(relativizeBoundedEvent('$gitDir/index', spec), '.git/index');
        expect(
          relativizeBoundedEvent('$gitDir/refs/heads/main', spec),
          '.git/refs/heads/main',
        );
        expect(relativizeBoundedEvent(gitDir, spec), '.git');
      },
    );

    test('work-tree events become repo-relative', () {
      expect(
        relativizeBoundedEvent('$workTree/.config/bash/aliases.sh', spec),
        '.config/bash/aliases.sh',
      );
      expect(relativizeBoundedEvent('$workTree/.bashrc', spec), '.bashrc');
      expect(relativizeBoundedEvent(workTree, spec), '');
    });

    test('paths outside the spec are dropped', () {
      expect(relativizeBoundedEvent('/etc/passwd', spec), isNull);
      expect(relativizeBoundedEvent('/home/other/.bashrc', spec), isNull);
    });

    test('remapped paths flow through the shared filter correctly', () {
      // Index/ref writes trigger and read as git state; object/log churn is
      // dropped exactly as in an ordinary repo — the whole point of the remap.
      final index = relativizeBoundedEvent('$gitDir/index', spec)!;
      expect(shouldTriggerWatch(index), isTrue);
      expect(index.startsWith('.git/'), isTrue); // sets touchesGitState

      final edit = relativizeBoundedEvent(
        '$workTree/.config/bash/env.sh',
        spec,
      )!;
      expect(shouldTriggerWatch(edit), isTrue);

      expect(
        shouldTriggerWatch(
          relativizeBoundedEvent('$gitDir/objects/aa/bb', spec)!,
        ),
        isFalse,
      );
      expect(
        shouldTriggerWatch(relativizeBoundedEvent('$gitDir/logs/HEAD', spec)!),
        isFalse,
      );
    });
  });

  group('boundedInotifyScript', () {
    test('is non-recursive and watches the explicit dir list', () {
      final spec = computeBoundedWatchSpec(
        gitDir: gitDir,
        workTree: workTree,
        trackedFiles: tracked,
      );
      final script = boundedInotifyScript(spec.watchDirs);

      // The core claim: NO recursive flag anywhere. A recursive watch of $HOME
      // is exactly what this mode exists to avoid.
      expect(script.contains('-r'), isFalse);

      expect(script.contains('inotifywait'), isTrue);
      expect(script.contains('--format %w%f'), isTrue);
      expect(script.contains('stdbuf -oL'), isTrue); // line-buffered flush
      // Every watch dir is present (shell-escaped).
      for (final d in spec.watchDirs) {
        expect(script.contains("'$d'"), isTrue, reason: 'missing $d');
      }
    });

    test('escapes paths with shell metacharacters', () {
      final script = boundedInotifyScript(["/home/u/it's a dir"]);
      expect(script.contains(r"'/home/u/it'\''s a dir'"), isTrue);
    });
  });

  // 0025 C3. Nothing bounds host processes today: 19 inotifywait orphans were
  // found on the real host, oldest 16.9 days, four predating an app upgrade.
  // 0024 M2 showed a budget that lives only in a comment is one that gets
  // forgotten, so these are constants with tests, not prose.
  group('watch lease registry', () {
    test('the inotify arm records its pid where a sweep can find it', () {
      final s = boundedInotifyScript([
        '/r/.git',
      ], pidFile: '/r/.git/mg-watch.pid');
      expect(s, contains('mg-watch.pid'));
      // $$ is the arming shell, and `exec` makes the watcher inherit it — so
      // the pid recorded is the process a sweep must actually signal.
      expect(s, contains(r'$$'));
      expect(s, contains('exec'));
    });

    test('the fswatch arm records its pid too', () {
      final s = boundedFswatchScript([
        '/r/.git',
      ], pidFile: '/r/.git/mg-watch.pid');
      expect(s, contains('mg-watch.pid'));
      expect(s, contains(r'$$'));
    });

    test('no pid file means the script is unchanged', () {
      // The recursive (non-bounded) path and every existing caller must keep
      // working untouched.
      expect(boundedInotifyScript(['/r/.git']), isNot(contains('mg-watch')));
    });

    test('the sweep script is built from the paths it was given', () {
      final s = watcherSweepScript([
        '/r1/.git',
      ], staleAfter: const Duration(minutes: 5));
      expect(s, contains('mg-watch.'));
      expect(s, contains('-mmin -5'), reason: 'portable staleness, not stat');
      // WHETHER IT RECLAIMS ANYTHING IS NOT ASSERTED HERE, ON PURPOSE.
      //
      // This test used to also assert `contains('inotifywait')` and
      // `contains('kill -TERM')`, and passed for months while the script could
      // not reclaim a single process: it recorded a shell's pid and then
      // signalled only pids whose `comm` was `inotifywait`/`fswatch`, so the
      // `case` never fired (0027). Both strings were present; the contradiction
      // between them is invisible to substring matching.
      //
      // The behaviour now lives in `watcher_sweep_exec_test.dart`, which
      // spawns a real process and checks whether it is still there afterwards.
      // Do not re-add behavioural assertions here.
    });
  });

  // 0025 C1 established that no client-side teardown can reach the watcher:
  // inotifywait blocks in select() and, with no event to write, never takes a
  // SIGPIPE. `-t` was the lever chosen then — a watcher that exits on its own
  // timeout so the shell can wake and re-check the lease.
  //
  // MADR 0041 replaced that lever. `-t` bounded the leak at ~6 minutes and paid
  // a full recursive re-walk per wake, and the loop's `kill "$c"` signalled the
  // subshell rather than the watcher, so it orphaned what it claimed to own.
  // The watcher now runs until it is killed, and three watchdogs kill it: stdin
  // EOF (immediate, and the only thing that reaches a process the client cannot
  // signal), a lease poll that does not disturb the watch, and the trap.
  //
  // COMPOSITION ONLY, per 0029. Everything about how these actually behave is
  // executed against real processes in watch_lease_teardown_exec_test.dart and
  // host_script_exec_test.dart. The two assertions this group used to make —
  // `contains('-t 120')` and `contains('trap')` + `contains('kill')` — are gone
  // rather than updated: the second was true for months while the kill went to
  // the wrong pid, which is exactly the failure text assertions cannot see.
  group('leased watcher', () {
    String armed() => boundedInotifyScript(
      ['/r/.git'],
      pidFile: '/r/.git/mg-watch.pid',
      heartbeat: '/r/.git/mg-watch.hb',
      leasePoll: const Duration(seconds: 60),
      staleAfter: const Duration(minutes: 5),
    );

    test('the lease it polls is the one it was given', () {
      final s = armed();
      expect(s, contains('mg-watch.hb'));
      expect(s, contains('-mmin -5'), reason: 'staleAfter as find minutes');
      expect(s, contains('sleep 60'), reason: 'leasePoll as sleep seconds');
    });

    test('the watcher is exec-ed, so the supervised pid is the watcher', () {
      // Composition of the one detail that decides whether `kill "$w"` reaches
      // the watcher or an intermediate subshell. The behaviour — that the
      // loop's direct child IS the watcher — is asserted against a real
      // process table in watch_lease_teardown_exec_test.dart.
      expect(armed(), contains('exec stdbuf -oL inotifywait'));
      expect(armed(), isNot(contains('-t ')));
    });

    test('the eof watchdog reads the saved descriptor, never fd 0', () {
      // POSIX gives an asynchronous list /dev/null for stdin when job control
      // is off, so `( cat … ) &` on fd 0 would fire instantly and kill the
      // watcher milliseconds after it arms (0027 deviation (b) all over again).
      final s = armed();
      expect(s, contains('exec 3<&0'));
      expect(s, contains('cat <&3'));
    });

    test('without a heartbeat the script is the old unbounded form', () {
      // Every existing caller keeps working untouched.
      expect(boundedInotifyScript(['/r/.git']), contains('exec'));
      expect(boundedInotifyScript(['/r/.git']), isNot(contains('-t ')));
    });
  });

  // ---- the recursive watch surface (MADR 0041 phase 5) -------------------
  //
  // COMPOSITION ONLY, and here that is a limit worth stating rather than a
  // convention being followed. The behaviour of `--exclude` and `@<path>` is
  // inotifywait's, this suite runs on macOS where there is no inotifywait, and
  // the executing tests shim it — so a shim can only ever confirm the argv it
  // was handed. What these assertions pin is the two things that were measured
  // on a real host and are silently wrong if they drift (0041 F8, F9):
  //
  //   * exactly ONE --exclude, because inotifywait honours only the last and
  //     four of them meant three were dead;
  //   * @-paths spelled `./…`, because that is the only spelling that works
  //     when the watch root is `.` — 9 watches to 5, where `@.git/objects` and
  //     an absolute path both left it at 9.

  group('recursive watch surface', () {
    String recursive() => recursiveWatchScript(
      inotify: true,
      excludes: r"--exclude '\.lock$' ",
      unwatched: ' @./.git/objects @./.git/logs @./.git/fsmonitor--daemon',
      pidFile: '/r/.git/mg-watch.t.pid',
      heartbeat: '/r/.git/mg-watch.t.hb',
    );

    test('emits exactly one --exclude', () {
      expect(
        '--exclude '.allMatches(recursive()).length,
        // Once per branch of the stdbuf fork, and no more.
        2,
        reason:
            'inotifywait takes only the LAST --exclude and warns about it; '
            'more than one per branch means the earlier ones do nothing',
      );
    });

    test('the unwatched subtrees are @-paths, and carry the ./ prefix', () {
      final s = recursive();
      for (final p in const [
        '@./.git/objects',
        '@./.git/logs',
        '@./.git/fsmonitor--daemon',
      ]) {
        expect(s, contains(p), reason: 'missing $p');
      }
      expect(
        s,
        isNot(contains('@.git/')),
        reason: 'the bare form matches nothing and fails silently',
      );
    });

    test('the @-paths come after the watch root, not before it', () {
      final s = recursive();
      expect(
        s.indexOf('@./.git/objects'),
        greaterThan(s.indexOf('--format %w%f .')),
        reason: 'the verified form puts them after the root',
      );
    });

    test('the fswatch branch takes no @-paths', () {
      // fswatch has no such flag, and accepts repeated --exclude correctly, so
      // it needs neither half of this. Stated so the asymmetry reads as a
      // decision rather than an oversight.
      final s = recursiveWatchScript(
        inotify: false,
        excludes: '',
        unwatched: ' @./.git/objects',
        pidFile: '/r/.git/mg-watch.t.pid',
        heartbeat: '/r/.git/mg-watch.t.hb',
      );
      expect(s, isNot(contains('@./.git/objects')));
      expect(s, contains('fswatch'));
    });
  });
}
