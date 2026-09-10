import '../ssh/shell_escaper.dart';
import 'watch/watch_timings.dart';

/// Bounded watch surface for a **scoped work-tree repo** — the dotfiles pattern
/// where a single git-dir (e.g. `~/.home.git`) has its work tree set to a huge
/// directory (e.g. `$HOME`). A recursive watch of that work tree is a
/// non-starter: on a real bastion `$HOME` measured 257k directories against a
/// host `fs.inotify.max_user_watches` of 524k — one repo would claim ~half the
/// entire per-user inotify budget, take seconds and hundreds of MB of kernel
/// memory to arm, and drown the app in events from caches and build output it
/// can never act on.
///
/// The key simplification this mode is allowed to make (and the reason it is
/// gated behind an explicit repo-type toggle): such a repo runs with
/// `status.showUntrackedFiles=no`, so **untracked files do not matter**. The
/// only things that can change what the UI shows are:
///
///   1. an edit to a **tracked** working-tree file, and
///   2. a change to **git's own state** — the index, HEAD, or a ref.
///
/// So the watch surface collapses to a small, explicit set of directories,
/// watched **non-recursively**:
///
///   * the parent directory of every tracked file (from `git ls-files`), so a
///     content edit to any tracked dotfile fires — and nothing else in `$HOME`
///     does, and
///   * a few fixed points inside the git-dir: its root (`index`, `HEAD`,
///     `packed-refs`, `ORIG_HEAD`, `MERGE_HEAD`, lock files all live directly
///     here) and `refs/heads` (branch ref writes). Object writes land under
///     `objects/xx/…`, which a *non-recursive* git-dir-root watch never sees —
///     so a commit or gc floods nothing.
///
/// This is the same multi-root, path-remapping strategy `LocalWatchService`
/// already uses for a linked worktree (watch the worktree dir + the common git
/// dir, rewrite git-dir events to look like `.git/…`), specialized for a
/// tracked-only work tree.
class BoundedWatchSpec {
  /// Absolute git-dir (e.g. `/home/u/.home.git`). Trailing slash stripped.
  final String gitDir;

  /// Absolute work tree (e.g. `/home/u`). Trailing slash stripped.
  final String workTree;

  /// Absolute directories to watch **non-recursively** — the parent dirs of
  /// tracked files (deduped, sorted), plus the git-dir watch points. This is
  /// the complete inotify/fswatch surface for the repo.
  final List<String> watchDirs;

  const BoundedWatchSpec({
    required this.gitDir,
    required this.workTree,
    required this.watchDirs,
  });
}

String _stripTrailingSlash(String p) =>
    (p.length > 1 && p.endsWith('/')) ? p.substring(0, p.length - 1) : p;

/// POSIX dirname of a repo-relative, forward-slash path. `'a/b/c'` → `'a/b'`;
/// a bare filename (`'.bashrc'`) → `''` (meaning the work-tree root itself).
String _relDir(String relPath) {
  final i = relPath.lastIndexOf('/');
  return i < 0 ? '' : relPath.substring(0, i);
}

/// Computes the bounded watch surface for [gitDir] / [workTree] given the
/// repo's [trackedFiles] (the raw, work-tree-relative output of `git ls-files`,
/// forward-slash separated).
///
/// The result watches every tracked file's parent directory plus the git-dir
/// signal points — no more. [trackedFiles] whose directory can't be formed are
/// skipped; an empty list still yields the git-dir points so state changes are
/// seen even before anything is tracked.
BoundedWatchSpec computeBoundedWatchSpec({
  required String gitDir,
  required String workTree,
  required Iterable<String> trackedFiles,
}) {
  final gd = _stripTrailingSlash(gitDir);
  final wt = _stripTrailingSlash(workTree);

  // Git-dir signal points: the root (index, HEAD, ORIG_HEAD, MERGE_HEAD,
  // packed-refs, lock files) plus the loose-ref dirs for branch and tag writes.
  // `refs/heads`/`refs/tags` may not exist yet (fresh/tagless repo); the arming
  // layer existence-guards each path (see boundedInotifyScript) so a missing one
  // is skipped rather than aborting the watcher.
  final dirs = <String>{gd, '$gd/refs/heads', '$gd/refs/tags'};

  for (final f in trackedFiles) {
    final rel = f.trim();
    if (rel.isEmpty) continue;
    final d = _relDir(rel);
    dirs.add(d.isEmpty ? wt : '$wt/$d');
  }

  final sorted = dirs.toList()..sort();
  return BoundedWatchSpec(gitDir: gd, workTree: wt, watchDirs: sorted);
}

/// Rewrites an absolute watcher event path back to the repo-root-relative,
/// forward-slash shape every downstream consumer ([shouldTriggerWatch],
/// [RepoWatchEvent.touchesGitState]) expects, or null if it falls outside the
/// spec (which should not happen for events from [BoundedWatchSpec.watchDirs]).
///
/// git-dir events become `.git/…` — so `<gitDir>/index` reads as `.git/index`
/// and correctly sets `touchesGitState`, exactly as it would in an ordinary
/// repo. The git-dir is checked **first** because it lives *inside* the work
/// tree (`~/.home.git` ⊂ `$HOME`), so a work-tree prefix test would otherwise
/// swallow it.
String? relativizeBoundedEvent(String absolutePath, BoundedWatchSpec spec) {
  if (absolutePath == spec.gitDir) return '.git';
  if (absolutePath.startsWith('${spec.gitDir}/')) {
    return '.git/${absolutePath.substring(spec.gitDir.length + 1)}';
  }
  if (absolutePath == spec.workTree) return '';
  if (absolutePath.startsWith('${spec.workTree}/')) {
    return absolutePath.substring(spec.workTree.length + 1);
  }
  return null;
}

/// Supplies a freshly-computed [BoundedWatchSpec].
///
/// The watch services take this rather than a spec value because the surface a
/// bounded watch should cover is not stable: every `git add` of a file in a
/// new directory widens it. Passing a value froze the surface for the life of
/// the stream (0022 H5); passing a supplier lets each arm — including a
/// deliberate re-arm — recompute it.
typedef BoundedWatchSpecSource = Future<BoundedWatchSpec> Function();

/// Shell script (for `sh -c`) that arms `inotifywait` over exactly [watchDirs],
/// **non-recursively** (no `-r`), line-buffered via `stdbuf` when available so
/// each event flushes immediately over the pipe (same reasoning as the
/// recursive path). Each directory is shell-escaped and existence-guarded, so a
/// path that does not yet exist (empty-repo `refs/heads`) is silently skipped
/// rather than aborting the whole watcher.
///
/// Emits absolute paths (`%w%f` over absolute watch dirs) for
/// [relativizeBoundedEvent] to remap. Uses `exec` so a channel-close signal
/// reaches inotifywait itself, not a surviving shell wrapper.
/// Exit status a bounded arming script uses for "none of the paths exist".
///
/// Distinct from 0 on purpose. It used to `exit 0`, which reads as a clean
/// watcher death: the lifecycle engine scheduled a restart, burned its budget
/// on three doomed retries, and only then degraded to polling — with nothing
/// said about why. A distinct status lets the caller map it straight to
/// [WatchUnavailable], which degrades to polling immediately *and* keeps
/// retrying on the recovery timer (0022 M6).
const int boundedWatchNoPathsExit = 97;

/// Exit status for "another live watcher already holds this repository".
///
/// Distinct from [boundedWatchNoPathsExit] and from 0 for the same reason that
/// one is distinct: the caller maps it straight to a `WatchUnavailable`, which
/// degrades to polling immediately and keeps retrying on the recovery timer,
/// rather than looking like a watcher that armed and died and spending three
/// doomed restarts first.
const int boundedWatchLockedExit = 98;

/// The line a watcher writes to **stderr** once it holds every claim it needs
/// and its watcher process has been started.
///
/// stderr, not stdout, for three reasons that all matter. stdout is the event
/// channel and is parsed as delimited records, so a marker there would have to
/// be filtered out of every event path. stderr is unbuffered by POSIX, so the
/// line leaves the host the moment it is written rather than sitting in a stdio
/// buffer the way inotifywait's own output does without `stdbuf -oL`. And there
/// is already a precedent for a script-authored line the client matches —
/// `_lockPrelude` writes `mg-watch: lock held by $o` here.
///
/// **Its position in the script is the whole guarantee.** Both refusals exit
/// before it: [boundedWatchNoPathsExit] from the existence filter, and
/// [boundedWatchLockedExit] from `_lockPrelude`. So this line cannot be
/// produced by an arm that was refused, which makes the client's race
/// well-ordered rather than a matter of timing.
///
/// It says "the watcher process was started", not "the watches are
/// established" — exactly what the fixed 250 ms wait it replaces established,
/// which only ever proved "no refusal within 250 ms" (MADR 0044 amendment
/// 0044.1). `inotifywait` does print `Watches established.`, and
/// `StderrLineReader.isStartupNoise` recognises it, but `fswatch` prints no
/// equivalent — so it cannot be the signal for both backends.
const String watchArmedMarker = 'mg-watch: armed';

/// Shell that announces [watchArmedMarker] on stderr.
String _armedMarker() => 'echo ${ShellEscaper.escape(watchArmedMarker)} >&2; ';

/// One repository's exclusive claim, held by one watcher instance.
///
/// [gitDir] is where the claim lives — beside the registry files, so it travels
/// with the repository — and [token] identifies the holder, so a watcher can
/// tell its own lock from a successor's and refuse to delete what it no longer
/// owns.
typedef WatchLock = ({String gitDir, String token});

/// The lock directory for [gitDir]. `mkdir` is the claim: it is atomic on every
/// POSIX filesystem, needs no helper binary, and — unlike `flock(1)`, which is
/// util-linux only — works on the macOS hosts this app also targets.
String watchLockDir(String gitDir) => '$gitDir/mg-watch.lock';

/// Shell that claims [lock], or exits [boundedWatchLockedExit].
///
/// A lock whose holder's lease has gone stale is stolen rather than respected:
/// the holder is by definition gone, and refusing forever would make one
/// crashed session poison a repository until the next connect sweep.
///
/// The steal has a race — two arms finding the same stale lock can both get
/// past it. It is bounded (one extra watcher, reclaimed by its own lease) and
/// strictly better than the status quo, which has no exclusion at all. Making
/// it airtight needs an atomic compare-and-swap the POSIX shell does not have.
String _lockPrelude(WatchLock lock, {required Duration staleAfter}) {
  final dir = ShellEscaper.escape(watchLockDir(lock.gitDir));
  final tok = ShellEscaper.escape(lock.token);
  // The incumbent's heartbeat path, built from a quoted prefix and suffix
  // around the token read out of the lock — `'…/mg-watch.'"$o"'.hb'`.
  final hbPrefix = ShellEscaper.escape('${lock.gitDir}/mg-watch.');
  const hbSuffix = "'.hb'";
  final mins = staleAfter.inMinutes < 1 ? 1 : staleAfter.inMinutes;
  return 'L=$dir; '
      'if mkdir "\$L" 2>/dev/null; then printf %s $tok > "\$L/token"; '
      'else '
      'o=\$(cat "\$L/token" 2>/dev/null); '
      'h=$hbPrefix"\$o"$hbSuffix; '
      'if [ -n "\$o" ] && [ -f "\$h" ] && '
      '[ -n "\$(find "\$h" -mmin -$mins 2>/dev/null)" ]; '
      // Say WHO holds it. Establishing that the "other" watcher was this same
      // session took a host census, an SSH session audit and a question to the
      // maintainer (MADR 0043) — the script knew the answer the whole time and
      // was throwing it away. stderr, because stdout is the event channel.
      'then echo "mg-watch: lock held by \$o" >&2; '
      'exit $boundedWatchLockedExit; fi; '
      'rm -rf "\$L"; mkdir "\$L" 2>/dev/null || exit $boundedWatchLockedExit; '
      'printf %s $tok > "\$L/token"; '
      'fi; ';
}

/// Shell that releases [lock] — but only while this instance still holds it.
///
/// A watcher whose lock was stolen while it was dying must not delete the new
/// owner's claim.
String _unlockFragment(WatchLock lock) => '${watchLockReleaseScript(lock)} ';

/// Releases [lock] — but only while this instance still holds it.
///
/// Issued two ways, and the guard is what makes both safe: by the watcher's own
/// `cleanup()` trap as it exits, and by the CLIENT at teardown, which does not
/// wait for the watcher to notice its channel closed. Whichever gets there
/// first wins and the other becomes a no-op, because both check the token
/// before removing anything.
///
/// The guard is not ceremony. Between deciding to tear down and the removal
/// actually running, another watcher may legitimately have taken this lock —
/// the steal path in [_lockPrelude] exists precisely so a crashed holder does
/// not poison a repository forever. Removing a lock this instance no longer
/// owns would delete a live watcher's exclusion and let a third arm in.
///
/// The client issues this so that the NEXT arm for this repository does not
/// race the dying watcher's own cleanup. That race is short — the host releases
/// in well under a second (MADR 0043 F4) — and it is exactly long enough for a
/// re-arm to be refused by its own predecessor, which is what MADR 0043 is
/// about.
String watchLockReleaseScript(WatchLock lock) {
  final dir = ShellEscaper.escape(watchLockDir(lock.gitDir));
  final tok = ShellEscaper.escape(lock.token);
  return '[ "\$(cat $dir/token 2>/dev/null)" = $tok ] && rm -rf $dir;';
}

/// Supervises [inner] — a watcher invocation, which must `exec` — so that it
/// dies when the client that started it does.
///
/// This has to live on the host because the client is exactly what is missing
/// at the moment of failure, and because **the client cannot kill it**:
/// `session.kill(TERM)` is an RFC 4254 `"signal"` channel request OpenSSH's
/// sshd does not implement, and closing the channel reaches a watcher blocked
/// in `select()` not at all — with no event to write it never takes `EPIPE`
/// (0025 A). Proven on a real host: without what follows, killing the client
/// leaves the whole tree running indefinitely; with it, the tree is gone in
/// under five seconds (MADR 0041 F1, F11).
///
/// Three things watch the watcher, each covering what the others cannot:
///
///  * **stdin EOF** — the fast path, and the only immediate one. The client
///    cannot signal this shell, but closing the channel closes its stdin, so a
///    reader on it learns at once.
///  * **the lease poll** — the backstop for a client that stops refreshing
///    [heartbeat] while the connection stays up. It re-reads the lease every
///    [leasePoll] *without touching the watcher*. The previous design could
///    only check the lease when the watcher exited, so the check landed at
///    unpredictable intervals and cost a full recursive re-walk each time
///    (0041 F2).
///  * **the trap** — turns a signal into the same orderly shutdown.
///
/// `exec 3<&0` runs before anything is backgrounded and the watchdog reads fd
/// 3, never fd 0. POSIX assigns `/dev/null` to an asynchronous list's standard
/// input when job control is off, so `( cat … ) &` reading fd 0 sees EOF the
/// instant it starts and kills the watcher milliseconds after it arms — which
/// is indistinguishable from 0027 deviation (b), where every arm died in ~5 ms
/// and the repository polled forever at 48 host processes a minute.
///
/// `kill -TERM "$$"` from inside a watchdog: `$$` is the *invoking* shell's pid
/// and does not change in a subshell, so it reaches this loop and runs its
/// trap. Signalling the watcher directly would leave the other watchdogs behind.
///
/// [inner] must `exec`. Without it `$w` is the subshell that `{ …; } &` forked
/// and the watcher is that subshell's child, so killing `$w` orphans the very
/// process this exists to own — which is precisely what the previous
/// `kill "$c"` did (0041 F1's process tree).
///
/// `find -mmin` rather than `stat`: `stat -c %Y` is GNU-only and the fswatch
/// arm targets macOS.
String _leaseLoop({
  required String inner,
  required String heartbeat,
  required Duration staleAfter,
  required Duration leasePoll,
  String? pidFile,
  WatchLock? lock,
}) {
  final hb = ShellEscaper.escape(heartbeat);
  final mins = staleAfter.inMinutes < 1 ? 1 : staleAfter.inMinutes;
  final poll = leasePoll.inSeconds < 1 ? 1 : leasePoll.inSeconds;
  // The prelude records the pid before the lease is examined, so every exit
  // path removes it again. Without this a lease-absent arm left a pid file only
  // a connect-time sweep could reclaim, and litter of exactly that shape is
  // what made a re-armed repository look like two live watchers (0041 F4).
  // Everything this instance claimed, given back on every exit path. The lock
  // half is a no-op when this instance no longer holds it — see
  // [_unlockFragment].
  final release =
      (pidFile == null ? '' : 'rm -f ${ShellEscaper.escape(pidFile)}; ') +
      (lock == null ? '' : _unlockFragment(lock));
  final leaseAlive =
      '[ -f $hb ] && [ -n "\$(find $hb -mmin -$mins 2>/dev/null)" ]';
  return 'exec 3<&0; '
      'w=; e=; l=; '
      'cleanup() { '
      '[ -n "\$w" ] && kill -TERM "\$w" 2>/dev/null; '
      '[ -n "\$e" ] && kill -TERM "\$e" 2>/dev/null; '
      '[ -n "\$l" ] && kill -TERM "\$l" 2>/dev/null; '
      '${release}exit 0; }; '
      'trap cleanup TERM INT HUP; '
      '{ $leaseAlive; } || { ${release}exit 0; }; '
      '{ $inner; } & w=\$!; '
      '${_armedMarker()}'
      '( cat <&3 >/dev/null 2>&1; kill -TERM "\$\$" 2>/dev/null ) & e=\$!; '
      '( while :; do '
      'kill -0 "\$w" 2>/dev/null || exit 0; '
      '{ $leaseAlive; } || { kill -TERM "\$\$" 2>/dev/null; exit 0; }; '
      'sleep $poll; '
      'done ) & l=\$!; '
      'wait "\$w"; '
      'cleanup';
}

String boundedInotifyScript(
  List<String> watchDirs, {
  String? pidFile,
  String? heartbeat,
  WatchLock? lock,
  Duration leasePoll = WatchTimings.defaultHostLeasePoll,
  Duration staleAfter = WatchTimings.defaultLeaseStaleAfter,
}) {
  final joined = watchDirs.map(ShellEscaper.escape).join(' ');
  const fmt = '-m -e modify,create,delete,move --format %w%f';
  // Build the existence-filtered positional list once, then exec inotifywait on
  // it. `set --` re-quotes safely; the loop drops any missing path.
  final prelude =
      'set -- $joined; '
      'for d; do [ -e "\$d" ] && set -- "\$@" "\$d"; shift; done; '
      '[ "\$#" -gt 0 ] || exit $boundedWatchNoPathsExit; '
      // The claim comes BEFORE the pid file, so a refusal leaves nothing
      // behind — and AFTER the existence filter, so a repository with no
      // watchable paths never takes a lock it cannot use.
      '${lock == null ? '' : _lockPrelude(lock, staleAfter: staleAfter)}'
      '${_recordPid(pidFile)}';
  if (heartbeat == null) {
    // Unchanged legacy form for callers that supply no lease.
    return '$prelude'
        '${_armedMarker()}'
        'if command -v stdbuf >/dev/null 2>&1; then '
        'exec stdbuf -oL inotifywait $fmt "\$@"; '
        'else exec inotifywait $fmt "\$@"; fi';
  }
  // Identical to the legacy form above, and deliberately so: the watcher runs
  // until it is killed. The `-t` that used to bound it existed only so the
  // shell could wake and re-check the lease, which the poll now does without
  // tearing the watch down (0041 F2).
  const inner =
      'if command -v stdbuf >/dev/null 2>&1; then '
      'exec stdbuf -oL inotifywait $fmt "\$@"; '
      'else exec inotifywait $fmt "\$@"; fi';
  return '$prelude'
      '${_leaseLoop(inner: inner, heartbeat: heartbeat, staleAfter: staleAfter, leasePoll: leasePoll, pidFile: pidFile, lock: lock)}';
}

/// fswatch equivalent of [boundedInotifyScript]: watch exactly [watchDirs],
/// non-recursively (fswatch recurses only with `-r`), NUL-delimited (`-0`)
/// like the recursive path.
///
/// Runs through `sh -c` rather than as bare argv **because fswatch needs the
/// same existence guard inotifywait does**, for a different reason. inotifywait
/// aborts outright when handed a missing path; fswatch merely skips it — but a
/// skipped path is never retried, so a bounded watch armed before the first
/// `git tag` exists would never see `refs/tags` appear (0022 M6). Filtering
/// here keeps both backends honest about what they are actually watching, and
/// lets an all-missing set report [boundedWatchNoPathsExit] identically.
///
/// `exec` for the same reason as the inotify script: a channel close must reach
/// fswatch itself, not a surviving shell wrapper.
String boundedFswatchScript(
  List<String> watchDirs, {
  String? pidFile,
  String? heartbeat,
  WatchLock? lock,
  Duration leasePoll = WatchTimings.defaultHostLeasePoll,
  Duration staleAfter = WatchTimings.defaultLeaseStaleAfter,
}) {
  final joined = watchDirs.map(ShellEscaper.escape).join(' ');
  final prelude =
      'set -- $joined; '
      'for d; do [ -e "\$d" ] && set -- "\$@" "\$d"; shift; done; '
      '[ "\$#" -gt 0 ] || exit $boundedWatchNoPathsExit; '
      // The claim comes BEFORE the pid file, so a refusal leaves nothing
      // behind — and AFTER the existence filter, so a repository with no
      // watchable paths never takes a lock it cannot use.
      '${lock == null ? '' : _lockPrelude(lock, staleAfter: staleAfter)}'
      '${_recordPid(pidFile)}';
  if (heartbeat == null) {
    return '$prelude${_armedMarker()}exec fswatch -0 --latency 0.5 "\$@"';
  }
  // The `timeout` wrapper is gone, and with it the caveat that a bare macOS
  // host without coreutils could not self-terminate: fswatch has no `-t` of its
  // own, but it no longer needs one — stdin EOF reaches it through the trap on
  // every host (0041 F11).
  const inner = 'exec fswatch -0 --latency 0.5 "\$@"';
  return '$prelude'
      '${_leaseLoop(inner: inner, heartbeat: heartbeat, staleAfter: staleAfter, leasePoll: leasePoll, pidFile: pidFile, lock: lock)}';
}

/// Records the arming shell's pid so a later sweep can find the watcher.
///
/// `$$` is the shell about to `exec`, so the pid written is the one the watcher
/// itself will run under — there is no wrapper to confuse a sweep. Empty when
/// no pid file is wanted, which keeps every existing caller's script identical.
String _recordPid(String? pidFile) => pidFile == null
    ? ''
    : 'printf %s "\$\$" > ${ShellEscaper.escape(pidFile)}; ';

/// Script that reclaims watcher processes whose client is gone.
///
/// The client refreshes [heartbeat] while it is alive. A heartbeat older than
/// [staleAfter] means no one is reading these watchers' output any more — the
/// state that produced 19 orphans, because a watcher blocked in `select()`
/// never writes and so never learns its reader has gone (0025 A).
///
/// Every pid is re-verified before being signalled — by **identity**, not by
/// classification. The process's command line must contain the pid-file path
/// this app constructed, which a recycled pid cannot satisfy.
///
/// That check is not ceremony: 0025 records a `ps` selector bug that put the
/// wrong processes in a kill set, caught only because the set was printed
/// before it was used.
///
/// It replaces a `/proc/<pid>/comm` test that could never match (0027). The pid
/// recorded is the lease **shell's** — deliberately, since signalling the shell
/// runs its `trap` and stops the re-arm loop, where signalling `inotifywait`
/// alone would let the loop immediately re-arm — but the guard only accepted
/// `inotifywait`/`fswatch`, so the `case` never fired and the sweep reclaimed
/// nothing, ever. `/proc` is also Linux-only, while this file supports macOS
/// hosts (see the `find -mmin` choice below), so the check was dead twice over.
/// `ps -o command=` is POSIX and works on both — and, unlike `/proc`, lets the
/// sweep be tested by executing it against a real process.
String watcherSweepScript(
  List<String> gitDirs, {
  required Duration staleAfter,
}) {
  // Both shapes: the tokenised per-instance form, and the pre-0027 single pair
  // that hosts running an earlier build still carry. These two literals are the
  // ONLY definition of the legacy names — `RemoteWatchService` used to declare
  // them as well, unused, and the duplicate was removed (MADR 0034 F6) rather
  // than imported, because that file already imports this one. `${f%.pid}.hb` derives the
  // right heartbeat for either — `mg-watch.<tok>.pid` -> `mg-watch.<tok>.hb`,
  // and `mg-watch.pid` -> `mg-watch.hb`. Without the legacy glob the orphans
  // that motivated this work would never be reclaimed (0027 Phase 4).
  final globs = gitDirs
      .expand(
        (d) => [
          '${ShellEscaper.escape('$d/mg-watch.')}*.pid',
          ShellEscaper.escape('$d/mg-watch.pid'),
        ],
      )
      .join(' ');
  // Heartbeats are globbed separately because a lease can outlive its pid file
  // — see the second loop below.
  final hbGlobs = gitDirs
      .expand(
        (d) => [
          '${ShellEscaper.escape('$d/mg-watch.')}*.hb',
          ShellEscaper.escape('$d/mg-watch.hb'),
        ],
      )
      .join(' ');
  final lockDirs = gitDirs
      .map((d) => ShellEscaper.escape(watchLockDir(d)))
      .join(' ');
  final mins = staleAfter.inMinutes < 1 ? 1 : staleAfter.inMinutes;
  // `find -mmin` rather than `stat -c %Y`: the latter is GNU-only and this
  // runs against macOS hosts too. A heartbeat NEWER than the window means the
  // client is alive and there is nothing to reclaim.
  // Staleness is evaluated PER INSTANCE, inside the loop, against that
  // instance's own heartbeat. The previous form opened with a single
  // `[ -n "$(find <shared hb> -mmin -N)" ] && exit 0` — one repo-wide test that
  // asked "is anyone watching this repo?" rather than "is this watcher's owner
  // gone?". Any healthy watcher therefore aborted the whole sweep before it
  // examined a single pid, which is how two orphans survived a
  // rebuild-and-relaunch on the host and reached 19 minutes (0027 defect 2).
  return 'for f in $globs; do '
      '[ -f "\$f" ] || continue; '
      'hb="\${f%.pid}.hb"; '
      '[ -n "\$(find "\$hb" -mmin -$mins 2>/dev/null)" ] && continue; '
      'p=\$(cat "\$f" 2>/dev/null); '
      'case "\$p" in ""|*[!0-9]*) rm -f "\$f" "\$hb"; continue ;; esac; '
      'cmd=\$(ps -o command= -p "\$p" 2>/dev/null || echo); '
      'case "\$cmd" in *"\$f"*) kill -TERM "\$p" 2>/dev/null ;; esac; '
      'rm -f "\$f" "\$hb"; '
      'done; '
      // A heartbeat with no pid file beside it. The loop above never visits
      // one, because it iterates PID files and derives the heartbeat from
      // them — so these accumulated, one per failed arm, forever (three were
      // found on the host aged 14.5 hours).
      //
      // Since the lease is now stamped BEFORE the watcher is armed (0027
      // deviation (b)), every arm that fails after stamping leaves one. That
      // also means a heartbeat with no pid is exactly what an arm IN FLIGHT
      // looks like — so the staleness test is not optional here, it is what
      // separates litter from a watcher that is still starting up.
      'for h in $hbGlobs; do '
      '[ -f "\$h" ] || continue; '
      '[ -f "\${h%.hb}.pid" ] && continue; '
      '[ -n "\$(find "\$h" -mmin -$mins 2>/dev/null)" ] && continue; '
      'rm -f "\$h"; '
      'done; '
      // A lock whose holder's lease has gone stale. The holder is gone, so the
      // claim is worthless — and left in place it refuses every future watcher
      // of this repository until someone removes it by hand. A FRESH lease is
      // left strictly alone: that lock belongs to a live watcher, possibly
      // another session's, and is none of this sweep's business (0041 F12).
      'for L in $lockDirs; do '
      '[ -d "\$L" ] || continue; '
      'o=\$(cat "\$L/token" 2>/dev/null); '
      'lh="\${L%/*}/mg-watch.\$o.hb"; '
      '[ -n "\$o" ] && [ -n "\$(find "\$lh" -mmin -$mins 2>/dev/null)" ] '
      '&& continue; '
      'rm -rf "\$L"; '
      'done; true';
}

/// Recursive (whole-work-tree) watcher script with the same lease loop the
/// bounded arms use.
///
/// The recursive form is the one that leaked most: of the 19 orphans found on
/// the host, the majority carried this argv, four of them from a build old
/// enough to predate the `--exclude` flags (0025 A). Bounding it matters more
/// than bounding the bounded arm, not less.
String recursiveWatchScript({
  required bool inotify,
  required String excludes,
  String unwatched = '',
  String? pidFile,
  String? heartbeat,
  WatchLock? lock,
  Duration leasePoll = WatchTimings.defaultHostLeasePoll,
  Duration staleAfter = WatchTimings.defaultLeaseStaleAfter,
}) {
  // The claim comes BEFORE the pid file, so a refusal leaves nothing behind.
  final prelude =
      (lock == null ? '' : _lockPrelude(lock, staleAfter: staleAfter)) +
      _recordPid(pidFile);
  if (inotify) {
    const fmt = '-m -r -e modify,create,delete,move';
    // `exec`, so the pid the lease loop holds is the watcher's own — see
    // [_leaseLoop]. No `-t`: the watch is established once and kept, rather
    // than torn down and re-walked every two minutes (0041 F2).
    // [unwatched] goes AFTER the watch root: `@<path>` arguments stop those
    // subtrees being watched at all, where `--exclude` only filters events the
    // kernel already delivered. The fswatch branch has no equivalent and takes
    // none.
    final inner =
        'if command -v stdbuf >/dev/null 2>&1; then '
        'exec stdbuf -oL inotifywait $fmt $excludes--format %w%f .$unwatched; '
        'else exec inotifywait $fmt $excludes--format %w%f .$unwatched; fi';
    return '$prelude'
        '${_leaseLoop(inner: inner, heartbeat: heartbeat!, staleAfter: staleAfter, leasePoll: leasePoll, pidFile: pidFile, lock: lock)}';
  }
  const inner =
      "exec fswatch -0 --latency 0.5 --exclude '\\.git/.*\\.lock\$' "
      r"--exclude '\.git/objects/' --exclude '\.git/logs/' "
      r"--exclude '\.git/fsmonitor--daemon/' .";
  return '$prelude'
      '${_leaseLoop(inner: inner, heartbeat: heartbeat!, staleAfter: staleAfter, leasePoll: leasePoll, pidFile: pidFile, lock: lock)}';
}
