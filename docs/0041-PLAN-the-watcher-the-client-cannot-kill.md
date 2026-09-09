---
status: "proposed"
date: 2026-09-09
associated-madr: "0041-MADR-the-watcher-the-client-cannot-kill.md"
---
# Implement: make teardown reach the host, then re-derive the ceiling

Associated MADR:
[0041-MADR-the-watcher-the-client-cannot-kill.md](0041-MADR-the-watcher-the-client-cannot-kill.md)

## Goal

Close the defect the MADR proves: a watcher the client starts survives the
client, for up to six minutes, with the client's ledger and the host's reality
disagreeing the whole time. Then remove the ceiling of 2, which is currently the
only thing bounding that residue and is otherwise measured at three orders of
magnitude away from the resource it names.

Five phases, one commit each, each independently revertable. Phase 5 is
droppable without invalidating the rest; phase 4 must not land before phase 1.

## Determinism note — what has already been proven, and where

This plan is written after the host experiments, not before, so the shell it
specifies is text that has already run rather than text that looks right. Every
script fragment below was executed on the reporting host during the MADR
session. Where a step says "verified", the numbers are in the MADR's finding of
that name, and the shape below is the shape that produced them:

| Fragment | Proven by | Result |
| --- | --- | --- |
| The whole replacement lease loop | 6 cases, host | arms once; dies on stdin EOF; dies on stale lease; removes its own pid file; no residue |
| `exec` inside `{ …; } &` | case 6, host | the loop's child is the watcher itself, not a wrapper subshell |
| `cat <&3` on a **saved** descriptor | F11 | required — `( cat; kill ) &` reads `/dev/null` and fires instantly |
| `@./.git/objects` (this spelling only) | F9 probe | 9 watches → 5; `@.git/objects` and `@<absolute>` do **not** work |
| one `--exclude` + `@`-paths | F8/F9 probe | `.lock` suppressed, objects/logs never delivered, no "only the last option" warning |

Two of those were found by a probe failing first — the `/dev/null` stdin rule
and the `./`-prefix requirement — which is exactly why they are pinned here
rather than left to implementation.

## Scope

**In scope**

* `lib/core/git/bounded_watch.dart` — the lease loop, the three arming script
  builders, the sweep's lock handling.
* `lib/core/git/remote_watch_service.dart` — teardown, the early-exit read, the
  ceiling, the recursive argv.
* `lib/core/git/watch_lifecycle.dart` — one new `WatchUnavailableReason`.
* `lib/core/providers/app_providers.dart` — one wiring line for the derived
  ceiling (`grep -a`; the file is grep-binary).
* Tests named per phase, plus a new mutation catalogue
  `tool/mutations/0041-watcher-teardown.json`.

**Explicitly out of scope**

* `LocalWatchService` and the local backend. `Directory.watch()` is in-process;
  none of this applies.
* Phase 3 of MADR 0040 (`_reconcileSlots`, `LIVE <token>` reporting). MADR 0041
  F6 says it corrects the wrong direction at the wrong time; it is not
  re-landed, and this plan does not re-add it.
* Per-session (`(scope, host)`) keying of the ceiling. F5 is the reason; phase 4
  keys by host and says so.
* Answering the MADR's open question (what re-armed a repository with a 46 s
  old heartbeat). Phase 2 adds the observation that answers it; reading the
  answer is a follow-up, not a step here.

## Implementation Steps

### Phase 1 — replace the lease loop with the shape that dies when its client does

**Why one phase and not two.** The MADR describes this as a watchdog change and
a re-walk removal. They are not separable in practice: with the outer `while :`
loop retained, the stdin watchdog kills the watcher, `wait` returns, the loop
sees a fresh lease and immediately re-arms. Splitting would ship an intermediate
shape that has **not** been verified, which is worse than one larger change
whose exact text has. It is one commit, and `git revert` restores the current
loop whole.

**Files:** `lib/core/git/bounded_watch.dart`,
`lib/core/git/remote_watch_service.dart` (argv only — the `-t` seconds vanish
from `remoteWatcherArgs`' call into `recursiveWatchScript`).

**1.1 — `_leaseLoop` is replaced.** New signature: it gains `pidFile` (so the
exit path can remove what the prelude wrote) and `wakeInterval` is renamed
`leasePoll` with a default of **60 s** — the same cadence as
`RemoteWatchService.heartbeatInterval`, because it is now a poll of that file
rather than a watcher restart period.

The generated text, exactly (shell as verified; Dart escaping as the file's
existing style):

```sh
exec 3<&0;
w=; e=; l=;
cleanup() {
  [ -n "$w" ] && kill -TERM "$w" 2>/dev/null;
  [ -n "$e" ] && kill -TERM "$e" 2>/dev/null;
  [ -n "$l" ] && kill -TERM "$l" 2>/dev/null;
  rm -f <pidfile>; exit 0; };
trap cleanup TERM INT HUP;
[ -f <hb> ] || { rm -f <pidfile>; exit 0; };
[ -n "$(find <hb> -mmin -<mins> 2>/dev/null)" ] || { rm -f <pidfile>; exit 0; };
{ <inner> ; } & w=$!;
( cat <&3 >/dev/null 2>&1; kill -TERM "$$" 2>/dev/null ) & e=$!;
( while :; do
    kill -0 "$w" 2>/dev/null || exit 0;
    { [ -f <hb> ] && [ -n "$(find <hb> -mmin -<mins> 2>/dev/null)" ]; } ||
      { kill -TERM "$$" 2>/dev/null; exit 0; };
    sleep <poll>;
  done ) & l=$!;
wait "$w";
cleanup
```

Five things in there are load-bearing and each must carry a comment saying why,
because each is a line a later reader would simplify:

* `exec 3<&0` **before** anything is backgrounded. POSIX assigns `/dev/null` to
  an asynchronous list's stdin when job control is off, so `( cat … ) &` reading
  fd 0 sees EOF at once and kills the watcher milliseconds after it arms —
  indistinguishable from 0027 deviation (b). The watchdog must read the saved
  descriptor.
* `kill -TERM "$$"` from inside a subshell. `$$` is the *invoking* shell's pid
  and does not change in a subshell, so this reaches the loop shell and runs its
  trap. Sending the signal to `$w` instead would kill only the watcher and leave
  the two watchdogs behind.
* `{ <inner> ; } & w=$!` where `<inner>` **execs**. Without `exec`, `$w` is an
  intermediate subshell and `kill "$w"` orphans the real watcher — MADR 0041 F1's
  process tree, and the reason the current `trap`'s `kill "$c"` has never worked.
* The pre-checks remove the pid file before exiting. The prelude writes it before
  the lease is examined, so a lease-absent exit used to leave litter that only a
  connect-time sweep could reclaim.
* `wait "$w"` then `cleanup`. When the watcher dies on its own the two watchdogs
  must go with it; the `cat` watchdog in particular would otherwise linger
  holding fd 3.

**1.2 — the three callers exec, and lose their timeouts.**

* `boundedInotifyScript`: inner becomes
  `if command -v stdbuf >/dev/null 2>&1; then exec stdbuf -oL inotifywait <fmt> "$@"; else exec inotifywait <fmt> "$@"; fi`
  — the `-t $t` is removed. Monitor mode now runs until it is killed.
* `recursiveWatchScript` (inotify branch): the same change, with `.` in place of
  `"$@"`.
* `boundedFswatchScript` and `recursiveWatchScript` (fswatch branch): inner
  becomes `exec fswatch -0 --latency 0.5 …`. **The `timeout` wrapper is deleted
  entirely.** This is a fix, not just a simplification: the current comment
  concedes that on a host without coreutils "the watcher cannot self-terminate";
  with the stdin watchdog it can, on every host.
* `wakeInterval` is removed from all three signatures and `leasePoll` added, with
  the same defaulting discipline (`< 1 → 1`).

**1.3 — tests.**

*New:* `test/watch_lease_teardown_exec_test.dart`, following
`watcher_sweep_exec_test.dart`'s harness exactly — real processes, `kill -0`
liveness, `diedWithin`, a `PATH` shim for the watcher binary, no `contains(...)`
on script text. Six cases, one per proven case above:

| Case | Setup | Assertion |
| --- | --- | --- |
| a | no heartbeat | exits 0, never arms, **no pid file left** |
| b | heartbeat older than `staleAfter` | exits 0, never arms, no pid file left |
| c | fresh lease, stdin held open | arms **exactly once**, stays armed, pid file present and naming the live loop |
| d | then close the child's stdin | whole tree gone within 3 s, pid file removed |
| e | fresh lease, stdin open, lease then touched into the past | whole tree gone, pid file removed (the backstop) |
| f | the loop's direct children | the watcher process itself appears as a child of the loop, not behind a wrapper |

Case (c) is the one that must hold stdin open deliberately. `Process.start`
gives the child a stdin pipe; the test must **not** close it until case (d).
A test that forgets this reproduces the `/dev/null` trap and passes case (d) for
the wrong reason — so case (c) asserting "still armed after 3 s" is what
protects (d) from being vacuous, and (c) must be written first.

Case (f) is what pins 1.1's `exec`. Assert on the process table
(`ps -eo pid,ppid,args`), not on the script text.

*Amended:* `test/host_script_exec_test.dart` — the test
`records its pid and re-arms while the lease is fresh` asserts `arms() > 1`,
which is the contract this phase deliberately reverses. **Strike it and replace**
with `arms exactly once and stays armed`, carrying a comment naming this plan
and saying that a host-side re-arm is now the client's job, so a watcher death is
visible to the lifecycle engine instead of being papered over on the host. Its
two sibling tests (heartbeat absent / lease stale) are unchanged and must still
pass unedited — they are the regression guard for 1.1's pre-checks.

*Amended:* `test/bounded_watch_test.dart` — remove
`expect(armed(), contains('-t 120'))` (the flag is gone) and the test
`kills its child before exiting, so a signal orphans nothing`, whose
`contains('trap')` + `contains('kill')` were both true for months while the kill
went to the wrong process. Its replacement is case (f), which executes. Update
this file's entry in `_compositionOnly` in
`test/assertion_strength_scan_test.dart` to name
`watch_lease_teardown_exec_test.dart` as its behavioural twin.

**1.4 — commit.** `flutter analyze` and the tests below clean, then
`git commit --no-edit`.

**Acceptance:** the six cases pass; `host_script_exec_test.dart` passes with the
two unedited lease tests intact; nothing in `lib/` still generates `-t ` or
`timeout ` for a watcher.

---

### Phase 2 — the client releases its lease at teardown

**Files:** `lib/core/git/remote_watch_service.dart`,
`test/remote_watch_service_test.dart`.

**2.1** In the `WatchArmed` teardown, after `await handle.cancel()`, remove the
heartbeat file for this token — best-effort, `ExecLane.isolated`, 15 s timeout,
`try`/`catch (_)` and `unawaited`, so a disconnected executor cannot make the
teardown throw and cannot delay it.

Order matters and must be commented: the `rm` goes **after** `handle.cancel()`
because the channel close is the sub-second path and the `rm` is a round trip on
a different client. The `rm` is the backstop's backstop — it collapses the
lease-poll path from `staleAfter + poll` to the next poll — and is not the
primary mechanism.

Ownership rule, to be stated in the comment: the **client** removes the
heartbeat because the client wrote it; the **watcher** removes the pid file
(phase 1) because the watcher wrote it. Neither removes the other's, so a
half-dead pair is still exactly what the sweep's two loops are shaped to
reclaim.

**2.2** Record the teardown on `watchDiagnostics` with the cause already
available at that point. This is the observation the MADR's open question needs:
a re-arm 46 s after the last heartbeat currently leaves no record of what ended
the previous stream.

**2.3 — tests.** In `remote_watch_service_test.dart`, using the existing fake
executor: arm, cancel, and assert the recorded commands include a removal naming
this token's heartbeat path — and that a **throwing** executor on that call
still lets the teardown complete without error. The second is the one that
matters; write it by making the fake throw on any `rm`.

**Acceptance:** teardown issues the removal; a failing removal is invisible to
the caller; no test that currently passes is edited except by addition.

---

### Phase 3 — one watcher per repository, enforced by the host

**Files:** `lib/core/git/bounded_watch.dart`,
`lib/core/git/remote_watch_service.dart`, `lib/core/git/watch_lifecycle.dart`,
`test/watch_lease_teardown_exec_test.dart`, `test/watcher_sweep_exec_test.dart`.

In scope by the maintainer's decision of 2026-09-09. What it adds is the only
guard that survives *two app processes* pointed at one host, which no
client-side counter can give; phase 4's bound does not depend on it, so it stays
independently revertable, but it is not optional work.

**3.1** A `mkdir` lock — atomic on POSIX, and unlike `flock(1)` present on macOS
hosts too — acquired in the prelude, released in `cleanup`:

```sh
LOCK=<gitdir>/mg-watch.lock
if mkdir "$LOCK" 2>/dev/null; then printf %s <token> > "$LOCK/token";
else
  o=$(cat "$LOCK/token" 2>/dev/null);
  ohb=<gitdir>/mg-watch.$o.hb;
  if [ -n "$o" ] && [ -f "$ohb" ] && [ -n "$(find "$ohb" -mmin -<mins> 2>/dev/null)" ]; then
    exit 98;
  fi;
  rm -rf "$LOCK"; mkdir "$LOCK" 2>/dev/null || exit 98;
  printf %s <token> > "$LOCK/token";
fi;
```

`cleanup` removes the lock **only if it still holds our token**, so a watcher
whose lock was stolen while it was dying cannot delete the new owner's.

The steal window is a real race and must be commented as one: two arms finding
the same stale lock can both proceed. It is bounded (one extra watcher, reclaimed
by its own lease) and strictly better than the status quo, which has no
exclusion at all.

**3.2** `boundedWatchLockedExit = 98`, beside the existing
`boundedWatchNoPathsExit = 97` and for the same reason it is not `0`.

**3.3** `WatchUnavailableReason.heldByAnother`, and the arm maps 98 to it.
Deliberately **not** wired to the slot-release wake: `watchLifecycle`'s slot
listener is guarded on `degradedReason == ceiling`, so this reason falls through
to the recovery timer, which is correct — a slot freeing up says nothing about
another process's lock.

**3.4** The early-exit read in the arm currently sits inside `if (spec != null)`,
so only bounded arms can report a script-level refusal. **Move it out of that
guard** so the recursive arm can too. Keep the 250 ms cap and the comment
explaining that a live watcher never completes `exitCode`.

**3.5** The sweep removes a lock whose owner's heartbeat is stale, in the same
pass and by the same rule as the pid files.

**3.6 — tests.** Extend `watch_lease_teardown_exec_test.dart`: a second arm
against a held, fresh lock exits 98 and arms nothing; against a held, **stale**
lock it steals and arms; a clean exit removes the lock; a foreign token's lock
is not removed. Extend `watcher_sweep_exec_test.dart` with the stale-lock case.

**Acceptance:** two concurrent arms on one git dir produce exactly one watcher
process and one 98; the loser degrades to polling with `heldByAnother` in its
diagnostic.

---

### Phase 4 — derive the ceiling, keyed by host

**Files:** `lib/core/git/remote_watch_service.dart`,
`lib/core/providers/app_providers.dart`, and four test files.

This re-lands `212e39a` **with one substantive correction**: the counter stays
keyed by host. F5 is the whole reason — per-session keying took the host-wide
bound from 2 to as much as 8 × 6 and left nothing bounding the host at all.

**4.1** Add `int Function()? streamBudget` to the constructor, defaulting to a
function returning `2` (the degraded figure, so a caller that forgets to wire it
is conservative rather than optimistic). Add `reservedStreams = 2`, documented as
the CI job trace and clone progress, which watchers must not starve.

**4.2** `maxConcurrentWatchers` becomes an **instance getter**
`max(1, _streamBudget() - reservedStreams)`. Its doc comment must say, in one
line, that it is keyed by host on purpose and cite 0041 F5 — the reverted
commit's comment said the opposite and that is the mistake most likely to be
re-made.

**4.3** `_liveByHost` stays `Map<String, int>` keyed by host.
`slotReleasesForHost`, `liveWatchersFor` and `resetWatcherCount` are unchanged.
Nothing from 0040's phase 3 (`Set<String>` tokens, `parseSweptLiveTokens`,
`_reconcileSlots`, `LIVE` reporting) is re-added.

**4.4** `app_providers.dart` — one line in `remoteWatchServiceProvider`:
`streamBudget: () => ref.read(executorProvider).maxConcurrentStreams`, with the
comment explaining it is a callback because the budget changes when the stream
client degrades or is re-dialled. **Use `grep -a`** to find the provider; the
file is classified binary by plain grep.

**4.5 — tests.** Nine static references to `RemoteWatchService.maxConcurrentWatchers`
across four files must move to an instance:

* `test/watch_slot_leak_test.dart` (2)
* `test/watch_transition_wiring_test.dart` (2)
* `test/watch_ceiling_recovery_test.dart` (1)
* `test/remote_watch_service_test.dart` (4, including
  `expect(RemoteWatchService.maxConcurrentWatchers, 2)`, which becomes an
  assertion about the derivation rather than the constant)

Add `test/watch_ceiling_derived_test.dart`: budget 8 → cap 6; budget 2
(degraded) → cap 1 via the floor, not via arithmetic; the cap is read **per
arm**, so a budget that drops between arms is honoured; and — the one this phase
exists to protect — **two service instances in different session scopes on the
same host share one budget.** That last test is the regression guard for F5 and
is the reason the key is not a tuple.

**Acceptance:** with a healthy connection and N repositories open,
`min(N, 6)` watch and the rest poll; the host-wide total does not scale with the
number of tabs.

---

### Phase 5 — fix the watch surface *(independent; may land any time after phase 1)*

**Files:** `lib/core/git/remote_watch_service.dart` (`_inotifyExcludeFlags`,
`remoteWatcherArgs`), `lib/core/git/bounded_watch.dart`
(`recursiveWatchScript`), `test/bounded_watch_test.dart`.

**5.1** Replace the four `--exclude` flags with **one**, and add `@`-path
exclusions. Verified argv, in this exact spelling:

```text
inotifywait -m -r -e modify,create,delete,move --exclude '\.lock$' \
  --format %w%f . @./.git/objects @./.git/logs @./.git/fsmonitor--daemon
```

Two details that must be pinned by comment because both were found by
experiment and neither is guessable:

* **`--exclude` takes only the last occurrence.** inotify-tools says so on
  stderr and it was reproduced: of `--exclude '/a/' --exclude '/b/'`, only `/b/`
  applied. Reducing to one flag removes the trap structurally rather than
  working around it.
* **`@` paths must be spelled `./…`** when the watch root is `.`. Measured:
  `@./.git/objects` took a 9-directory tree to 5 watches; `@.git/objects` and
  the absolute form both left it at 9. inotifywait matches the string it builds
  while walking, and that string is `./`-prefixed.

`--exclude` filters events *after* the kernel delivered them; `@` prevents the
watch. That is why both are present and why the `.lock` case stays a
`--exclude` — lock files live in `.git/` itself, which must stay watched.

**5.2** The fswatch arm is unchanged: it accepts repeated `--exclude` correctly
and is not affected. The bounded arms pass no excludes at all and are not
affected. Say so in the comment, so the asymmetry does not read as an oversight.

**5.3** Surface the diagnostic. `maxDiagnosticLines` is 20 and every arm spends
one of them on `Setting up watches. Beware…`. Filter that specific line out of
the forwarded diagnostics — it is noise on every arm — so a real message like
`upper limit on inotify watches reached`, or a future
`--exclude: only the last option…`, is not crowded out. Filter by exact prefix
match, not a regex, and comment why each filtered line is filtered.

**5.4 — tests.** `bounded_watch_test.dart` may assert only composition: that
exactly one `--exclude` is emitted, and that the three `@` paths appear in
`./`-prefixed form. That is a legitimate `contains` under 0029 — it pins
composition, not behaviour — and the behaviour is not testable in this suite
because macOS has no `inotifywait` and the existing tests use a shim. State that
limit in the file, and record the host measurement below as the behavioural
evidence instead of pretending a shim proves it.

**Acceptance (host, not suite):** on the largest repository, the arm's
`inotifywait` holds directory-count-minus-`.git/objects`-and-`logs` watch
descriptors — measured before at 701/701, expected after at ~437 — and a fetch
puts no `.git/objects/**` event on the wire.

---

## Verification

Run at every phase boundary, not only at the end:

```sh
flutter --version | head -1                  # must match FLUTTER_VERSION (3.47.2)
flutter pub get --enforce-lockfile           # must say "Got dependencies!"
flutter analyze                              # clean
dart format --output=none --set-exit-if-changed lib test
flutter test                                 # full suite
tool/mutate.py tool/mutations/0041-watcher-teardown.json
```

Capture long output to a file and read it back rather than piping through
`tail` — a pipeline exits with the last command's status, and a filtered gate is
not a gate.

Per-phase targeted runs:

```sh
# 1
flutter test test/watch_lease_teardown_exec_test.dart test/host_script_exec_test.dart \
             test/bounded_watch_test.dart test/assertion_strength_scan_test.dart
# 2
flutter test test/remote_watch_service_test.dart
# 3
flutter test test/watch_lease_teardown_exec_test.dart test/watcher_sweep_exec_test.dart
# 4
flutter test test/watch_ceiling_derived_test.dart test/watch_ceiling_per_host_test.dart \
             test/watch_ceiling_recovery_test.dart test/watch_slot_leak_test.dart \
             test/watch_transition_wiring_test.dart test/remote_watch_service_test.dart
# 5
flutter test test/bounded_watch_test.dart
```

### The mutation catalogue

`tool/mutations/0041-watcher-teardown.json`, run in full at **every** phase
boundary — MADR 0039 D9's rule, after a stale anchor was silently un-armed by a
later phase's reformat and reported DID-NOT-APPLY. A DID-NOT-APPLY line is a
broken entry, never a pass.

| Label | Mutation | Must be killed by |
| --- | --- | --- |
| the watchdog reads fd 0 instead of the saved descriptor | `cat <&3` → `cat` | case (c) — the watcher must still be armed after 3 s |
| stdin EOF is not wired at all | delete the `e=$!` watchdog line | case (d) |
| the trap kills the wrapper, not the watcher | drop `exec ` from the inotify inner | case (f) |
| the lease backstop is gone | delete the `l=$!` watchdog | case (e) |
| a lease-absent exit leaves its pid file | `{ rm -f <pid>; exit 0; }` → `exit 0` | case (a) |
| teardown does not release the lease | remove the heartbeat `rm` (phase 2) | phase 2's test |
| the ceiling is keyed per session again | `Map<String, int>` → `Map<(Object, String), int>` | the two-scopes-one-budget test (4.5) |
| the floor is arithmetic, not a floor | `max(1, …)` → the bare subtraction | the degraded-budget test |
| the excludes collapse to the old four | restore the four-flag string | 5.4's "exactly one `--exclude`" |
| the `@` paths lose their `./` | `@./.git/objects` → `@.git/objects` | 5.4's composition assertion |

### Checks seen to fail

Per the standing rule, no new check is trusted until it has been watched to
fail, against a scratch copy and never by dirtying the tree. The mutation
catalogue is that mechanism for phases 1–5 and runs in a scratch `git worktree`.
Two of these have already been observed failing, before any code was written:

* the `/dev/null` stdin trap — a probe written the natural way killed its watcher
  instantly, which is the exact signature mutation 1 recreates;
* the `./` prefix — `@.git/objects` left the watch count unchanged at 9, which is
  what mutation 10 recreates.

Record in the execution log what each survivor turned out to be. MADR 0037 and
0038 both found that most survivors are tests proving something other than what
they claim, not holes in the code, and that reading the code before writing a
new assertion is what separates the two.

### Host acceptance, after phases 1–2

Run against the reporting host with the app rebuilt. Calibrate every count the
way MADR 0041 F3 does — two shells per watcher, plus the query matching itself —
or repeat the mistake this plan exists to correct:

```sh
# live watchers, calibrated: distinct tokens, not process matches
pgrep -af mg-watch | grep -o 'mg-watch\.[a-z0-9]*\.pid' | sort -u | wc -l

# registry litter: pid/hb pairs with no live process
find <repo-root> -name 'mg-watch.*' | wc -l
```

| Check | Before | Expected after |
| --- | --- | --- |
| Quit the app, wait 10 s, census | tree alive up to 6 min | zero processes, zero registry files |
| One repository's token pairs during a session | up to 2 (one live, one litter) | exactly 1 |
| `inotifywait` age vs its loop shell's age | child much younger (re-walks) | equal — armed once, never re-walked |
| Watch descriptors on the largest repository | 701 of 701 directories | ~437 (phase 5) |

## Rollout and Rollback

* One commit per phase, `git commit --no-edit` only — the `prepare-commit-msg`
  hook writes the message from the staged diff. No `-m`, no heredoc, no
  trailers.
* Nothing is pushed unless the maintainer asks in that same turn.
* Code and docs commit **separately**: MADR 0039 D4 records a hook crediting five
  unimplemented phases when they shared one commit.
* Rollback is `git revert` of a single commit per phase. The dependency is
  one-way: phase 4 must not stand on a tree where phase 1 has been reverted,
  because the cap is what bounds the residue phase 1 removes. If phase 1 is ever
  reverted, revert phase 4 first — the same ordering trap that made
  `git revert 212e39a` alone conflict during 0040.
* A rebuild is required before any host acceptance check. The behaviour lives in
  a script the app generates at arm time, so a running build keeps generating
  the old one.
* Phase 5 may be dropped without touching the others. Phase 3 is in scope
  (decision 1 above) but stays independently revertable. Phase 2 is
  independently useful and phase 1 is worth shipping alone.

## Decisions taken

Recorded 2026-09-09, before execution. The questions are kept as asked so the
record shows what was decided and not merely what was done.

1. ~~**Phase 3 in or out.**~~ **In.** The `mkdir` lock ships. It is still one
   commit and still independently revertable, but it is scope, not an option:
   F12's duplicate is reachable today through two saved connections to one host,
   and no client-side counter survives two app processes.
2. ~~**`leasePoll` at 60 s or 120 s.**~~ **60 s**, as written in step 1.1 —
   matching `RemoteWatchService.heartbeatInterval`. Worst case for the backstop
   is `staleAfter + 60 s`; it costs one `sleep` and one `find` per watcher per
   minute, and it is now rarely the path that fires.
3. ~~**Should amendment 0040.2 carry a pointer to its correction.**~~ **Yes.**
   Added to `0040-MADR-the-watcher-ceiling-is-the-wrong-limit.md` as a dated
   pointer at the end of the amendment, and to that record's index row. The
   amendment's own text is left standing: it recorded what was believed at the
   time, and rewriting it would hide that the misreading happened.

## Deviations

### (a) 2026-09-09, phase 1 — a fifth test file pins the `-t` contract

**Found.** The full suite failed on
`test/remote_watch_service_test.dart:627`, in
`the arm actually uses a leased, self-terminating script (0025 C1)`:

```text
Expected: contains '-t '
  Actual: 'printf %s "$$" > …; exec 3<&0; w=; e=; l=; cleanup() { … }'
   Which: does not contain '-t '
  bounded wait, not blocking
```

The same test also asserts `contains('trap')`, which still passes.

**Why it is a deviation.** Phase 1's file list named four test files
(`watch_lease_teardown_exec_test.dart`, `host_script_exec_test.dart`,
`bounded_watch_test.dart`, `assertion_strength_scan_test.dart`). This is a
fifth, and the plan's rule is that a file which must be touched but is not in
the list is a deviation, not a detail.

**Genuinely pre-existing?** No — the opposite. It is caused by this phase, and
deliberately: `-t` is removed by decision, and this assertion pins the flag that
was removed. Confirmed by reading the failure against the phase's own diff
rather than by reverting anything.

**Resolution taken.** Update the assertion to the contract that replaced it —
the arm must carry the stdin-EOF watchdog on a saved descriptor, and must not
carry `-t`. Two alternatives were rejected: keeping `-t` abandons the approved
change, and deleting the assertion is a workaround that removes a guard rather
than moving it. `test/remote_watch_service_test.dart` is added to phase 1's file
list.

**Also recorded, not acted on.** `dart format --set-exit-if-changed lib test`
reports 8 files changed that this work never touched (`undo_scripts_test.dart`
among them) — pre-existing formatting drift. The pre-commit gate gates staged
files, and these are not staged. Not this plan's to tidy.

## Execution record

*(Added per phase as it lands: what the phase did, the verification output
rather than a summary of it, and what was not done and why.)*
