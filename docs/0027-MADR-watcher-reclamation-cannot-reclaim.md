---
status: "proposed"
date: 2026-09-04
decision-makers: [Maintainer]
consulted: []
informed: [Magic Git contributors]
verified: 2026-09-04
---

# Give every watcher its own identity: the lease and the sweep cannot reclaim anything

## Context and Problem Statement

MADR 0025 built two mechanisms to stop watcher processes accumulating on the
host — a heartbeat **lease** so a watcher self-terminates when its client is
gone (C1, Phase 4), and a **PID registry swept at connect** so anything left
behind is reclaimed (C3, Phase 3). Both shipped, both are covered by tests, and
both passed.

The post-fix capture for [0026](0026-MADR-degraded-watch-poll-diagnosis.md)
found two lease shells alive at `ppid 1`, aged ~19 minutes, with **zero child
processes** — resident, watching nothing, left by the previous app instance.
Neither mechanism had reclaimed them, and neither ever could have.

**Recorded as [0025 C5](0025-MADR-unaccounted-host-side-work.md).** This record
is the decision about how to fix it.

## What is actually wrong

Four defects, established on the live host. **Each one alone is sufficient to
prevent reclamation**, so fixing any three still reclaims nothing.

### 1. The sweep can never match what the registry records *(decisive)*

`_recordPid` (`bounded_watch.dart`) writes the **lease shell's own** pid:

```sh
printf %s "$$" > <git-dir>/mg-watch.pid
```

`watcherSweepScript` then refuses to signal anything that is not a watcher
binary:

```sh
c=$(cat /proc/"$p"/comm 2>/dev/null || echo)
case "$c" in inotifywait|fswatch) kill -TERM "$p" ...
```

`$$` in the outer `sh -c` is a **shell**, so `comm` is `sh` and the `case` never
matches. Verified live:

```
mg-watch.pid names pid: 331312
  /proc/331312/comm = 'sh'
  -> NO MATCH ('sh') -> sweep skips it
```

**The sweep has never been able to kill anything, in any configuration.** It is
a no-op by construction, not a mechanism that failed under unusual conditions.

Recording the shell is the *correct* intent — the shell carries
`trap cleanup TERM ... kill "$c"`, so signalling it kills the watcher **and**
stops the re-arm loop, where signalling `inotifywait` alone would let the loop
immediately re-arm. The guard, not the record, is what disagrees with the design.

### 2. A fresh heartbeat aborts the sweep before it examines anything

`watcherSweepScript` opens with:

```sh
[ -n "$(find $hb -mmin -5 2>/dev/null)" ] && exit 0;
```

A heartbeat newer than the window means "the client is alive, nothing to
reclaim". But the heartbeat is per **repository**, so this asks *"is anyone
watching this repo?"* rather than *"is this particular watcher's owner gone?"*.

The docstring assumes "a heartbeat left by a previous session is by definition
stale". A rebuild-and-relaunch — the maintainer's normal loop, and exactly what
produced the observed orphans — leaves it **seconds** old. The sweep exits
immediately, and never retries: it runs once, at connect.

### 3. A live successor holds its predecessor's lease open forever

`_leaseLoop` tests the same per-repo file:

```sh
[ -n "$(find $hb -mmin -5 2>/dev/null)" ] || exit 0;
```

The current app refreshes that file every 60 s. An orphaned watcher for the same
repo therefore sees a fresh lease and never exits. Verified live:

```
mg-watch.hb   mtime age 0s   (written by the CURRENT app)
find mg-watch.hb -mmin -5 -> FRESH: an orphan re-checking its lease would NOT exit
```

Self-termination is disabled **precisely when orphans accumulate** — while the
repo is actively watched.

### 4. The registry holds one pid and overwrites it

`printf %s "$$" > <pidfile>` is a truncating write, and the path is one per
repo. Each arm overwrites its predecessor, so the registry names only the newest
watcher. Live: `mg-watch.pid` named `331312` while orphans `3503545` and
`3504806` were still running, recorded nowhere.

### Why the tests passed

The single test covering this asserts the script's **text**:

```dart
expect(s, contains('inotifywait'));
expect(s, contains('kill -TERM'));
```

It never executes the script against a process tree, so it cannot observe that
the pid handed to `kill` is a shell the `case` will reject. Both halves are
individually correct and contradict each other, which is the one thing a
string-containment assertion cannot see. This is the failure mode
`AGENTS.md` warns about: a check that has only ever been watched passing.

## Decision Drivers

* **The guard is legitimate and must survive.** 0025 records a `ps` selector bug
  that put wrong processes in a kill set. Killing a pid because a file names it
  is dangerous under pid recycling; `sh` is the most-recycled `comm` on any
  host, so simply widening the allowlist to `sh` is the worst available answer.
* **Identity, not classification, is the missing concept.** Every defect above
  is the same mistake: the mechanisms identify a watcher by *what it is*
  (`comm`) or by *which repo it serves* (per-repo files), never by *which
  watcher instance it is*.
* **Reclamation must work while the repo is being watched**, since that is when
  orphans exist.
* **Root-cause only** (`AGENTS.md`): no widening the comm allowlist, no
  shortening the lease so orphans die sooner by luck.

## Considered Options

* **A — Widen the sweep's `comm` allowlist to include `sh`.**
* **B — Record the watcher binary's pid instead of the shell's.**
* **C — Per-instance lease and registry files, with cmdline-verified identity.**
* **D — Abandon host-side reclamation; rely on the client killing its own.**

## Decision Outcome

Chosen option: **"C — per-instance lease and registry files, with
cmdline-verified identity"**, because it is the only option that addresses the
shared cause rather than one symptom, and the only one that keeps the safety
guard meaningful.

Each watcher instance gets a unique token at arm time and owns its own files:

```
<git-dir>/mg-watch.<token>.pid      one per watcher instance, never overwritten
<git-dir>/mg-watch.<token>.hb       refreshed only by THAT instance's client
```

* **Defect 3 disappears**: an orphan tests its own heartbeat, which nobody is
  refreshing, so it exits on schedule. A live successor cannot hold it open.
* **Defect 2 disappears**: the sweep evaluates staleness per instance instead of
  asking whether the repo is watched at all, so it works during normal use.
* **Defect 4 disappears**: files accumulate per instance and are removed on
  reclamation, so every watcher is discoverable.
* **Defect 1 is fixed without weakening the guard**: identity is verified
  against `/proc/<pid>/cmdline` containing that instance's **own** token, which
  a recycled pid cannot satisfy. This is strictly stronger than the `comm`
  check it replaces — `comm` would accept *any* `inotifywait` on the host,
  including one belonging to a different tool or user.

### Consequences

* Good, because reclamation becomes possible at all, which it currently is not.
* Good, because the identity check is more precise than the one it replaces.
* Good, because it makes the mechanism testable end-to-end: a real process tree
  can be spawned and reclaimed in a temp git-dir.
* Bad, because it introduces per-instance files that must be cleaned up; a
  crashed sweep leaves a stale `.pid`/`.hb` pair. They are tiny and
  self-identifying, and the sweep can prune pairs whose pid is gone.
* Bad, because `watch_path_filter.dart` must keep ignoring the new names — it
  currently matches the literal prefix `mg-watch.`, which still holds, but the
  test that pins it must be extended to the tokenised form.
* Neutral, because the ceiling, intervals and poll behaviour are untouched.

### Confirmation

Not confirmed by any script-text assertion — that is what missed this. The
mechanism is confirmed only by an **executable** test that spawns a real
process tree in a temporary git-dir, runs the sweep script against it, and
observes the process gone; plus one that observes a *live* watcher **survive**
the same sweep. Both must be seen to fail before they are trusted: the first
against today's script (which reclaims nothing), the second against a sweep with
the identity check removed.

The live confirmation is the two orphans currently on `admdevops`
(pids `3503545`, `3504806`): a sweep built to this decision must reclaim them,
and today's must not. They are deliberately left in place as the fixture.

## More Information

* [`0025-MADR-unaccounted-host-side-work.md`](0025-MADR-unaccounted-host-side-work.md) — **C5** (this defect), **C1** (the lease), **C3** (the registry and ceilings).
* [`0026-PLAN-degraded-watch-poll-diagnosis.md`](0026-PLAN-degraded-watch-poll-diagnosis.md) — Phase 4, the capture that found it.
* [`0022-MADR-git-gh-glab-engine-debug-audit.md`](0022-MADR-git-gh-glab-engine-debug-audit.md) — **M5**: what *creates* an orphan. This record is what makes one permanent.
* `lib/core/git/bounded_watch.dart` — `_recordPid`, `_leaseLoop`, `watcherSweepScript`.
* `lib/core/git/remote_watch_service.dart` — `watchPidFile` `:155`, `watchHeartbeatFile` `:156`, `sweepStaleWatchers` `:166`.
