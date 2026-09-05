---
status: "in-progress"
date: 2026-09-04
associated-madr: "0025-MADR-unaccounted-host-side-work.md"
---

# Implement the host process economy work

Associated MADR: [0025-MADR-unaccounted-host-side-work.md](0025-MADR-unaccounted-host-side-work.md)

## Goal

Take one one-file commit+push from **123 git processes to ≤15**, take orphaned
watchers from *accumulating indefinitely* to **0**, and put a **named,
enforced ceiling** on every long-lived resource so neither can recur unnoticed.

Every phase either removes work or bounds it. No phase adds machinery before
the work it would carry has been reduced.

## Scope

**In scope.** Findings A and B from MADR 0025, and its extended-scope items
C1–C3, D1–D3, E and F1–F3.

**Out of scope.** The Riverpod provider graph's shape, transport correctness
(0024 closed it), and forge CLI behaviour. This plan changes *what is asked
for, how often, and by how many processes* — not how the app is wired.

**Separately gated.** Phase 12 (D1, the persistent command session) is
specified in full but **is not authorized by approval of this plan**. It
introduces a single point of failure that nothing else here does. Phases 0–11
stand complete without it.

## Phasing rationale

The order is not by severity. It is:

1. **Measure before changing** (P1). MADR 0025 forbids remediating Finding B
   before attribution, and every later phase's acceptance is a delta against a
   number that does not exist yet.
2. **Then the one fix that is already certain** (P2) — a named defect with a
   named cause, small enough to carry no risk.
3. **Then bound the resource** (P3) before fixing the leak (P4), because the
   sweep needs the registry, and because a ceiling that exists first is what
   stops the leak recurring in a form nobody predicted.
4. **Then reduce demand** (P5–P7). Largest wins, no host-side machinery, all
   testable offline.
5. **Then remove redundancy** (P8) once the watcher is stable enough to change.
6. **Then make the remaining work cheaper** (P9–P11).
7. **Architecture last** (P12), when there is least left for it to carry — and
   when its payoff can be measured against a number that has stopped moving.

Phases 5–7 are independent of 3–4 and may be reordered against them if the
maintainer prefers the leak fixed sooner; nothing else may move.

## Execution rules

Binding for every phase.

0. **`flutter` means the pinned SDK.** `build_macos.sh:41` pins **3.47.2** and
   the machine's `flutter` now matches, so bare `flutter` is correct. Verify
   once per session before Phase 0:
   ```sh
   flutter --version | head -1          # must match FLUTTER_VERSION
   flutter pub get --enforce-lockfile   # must print "Got dependencies!"
   ```
   If they disagree, stop — this is what produced 0024's deviation (a) and two
   plans' worth of wrong baselines.
1. **Phase 0 completes before any file is edited.**
2. **Negative test first.** Write it, run it against the unfixed tree, record
   the **verbatim** failure in the execution record, then fix. A phase whose
   test was never seen red is not complete and is not committed.
3. **Two-step landing** where a signature changes: land the signature with the
   old body, run the test, record the failure, then land the body.
4. **Never dirty the tree to make a broken input.** Scratch dirs or fakes only.
5. **Assert every scripted edit landed** (checksum before/after).
6. **Read whole test output.** Never judge a failure through `head`/`tail`.
7. **The gate is the passing count and the failing set.** Passing must rise by
   exactly the number of tests added; failing must remain **0**. A count that
   does not rise by the expected amount means a file did not compile — that is
   how 0024 Phase 4 caught `noteLinkRtt`.
8. **Per-phase commit** with exactly `git commit --no-edit`. No `-m`, no
   trailers.
9. **No `git push`.**
10. **Any deviation stops execution and prompts**, with evidence, real
    resolutions, and the cost of doing nothing — then the docs are amended
    before the resolution is executed.
11. **Live-host measurements use the instruments validated in MADR 0025**:
    `trace2.eventTarget` (global config, backed up, restored byte-identical)
    for command counts; `/proc/<pid>/comm` + `/status` for process enumeration.
    **Never `ps -u USER -C name`** — it ORs its selectors. **Never `/proc`
    sampling for short-lived processes** — it missed 16 of 17.

## Phase table

| # | Item | Files (primary) | Risk | Depends on |
|---|---|---|---|---|
| 0 | Baseline, offline + live | — | none | — |
| 1 | Attribution instrumentation | `command_telemetry.dart`, `ssh_command_executor.dart` | low | 0 |
| 2 | F3a — bracket the commit sheet | `commit_dialog.dart` | low | 0 |
| 3 | C3 — lease registry + ceilings | `bounded_watch.dart`, `remote_watch_service.dart` | medium | 0 |
| 4 | C1 — self-terminating watcher | `bounded_watch.dart` | medium | 3 |
| 5 | F2 — path-scoped invalidation | `watch_event.dart`, `app_providers.dart`, `repo_status_view.dart` | medium | 1 |
| 6 | F1 — fingerprint short-circuit | `git_service.dart`, `app_providers.dart` | medium | 1, 5 |
| 7 | F3b — refresh generation | `app_providers.dart` | medium | 5, 6 |
| 8 | C2 — stop double-watching | `app_providers.dart`, `remote_watch_service.dart` | medium | 3, 4 |
| 9 | E — long-lived parse worker | new `parse_worker.dart`, `git_service.dart` | medium | 0 |
| 10 | D2 — bundle the refresh triple | `git_service.dart` | medium | 1, 5, 6 |
| 11 | D3 — `cat-file` session | `git_cat_file_batch.dart` | medium | 10 |
| 12 | D1 — persistent command session | `ssh_command_executor.dart` (+new) | **high** | **separate approval** |

---

## Phase 0 — Baseline

**Offline.**

```sh
git status --short                    # must be empty
git rev-parse HEAD                    # record
flutter analyze  2>&1 | tee "$S/p0-analyze.txt"
flutter test     2>&1 | tee "$S/p0-test.txt"
```

**Expected, from MADR 0025:** `No issues found!` and **`+3430 ~2`, 0 failing**.
Any difference: stop and prompt — the baseline moved.

**Live.** With the app running against a real host, capture the reference
numbers all later phases are measured against, using the validated method:

1. Back up `~/.gitconfig` on the host (`cp -p`), record its sha256.
2. `git config --global trace2.eventTarget <file>`; `trace2.eventBrief false`.
3. **Control:** run *n* known git invocations; the trace must log ≥ *n*. If it
   does not, stop — the instrument is broken (this has happened twice).
4. Truncate the trace. Perform **one one-file commit+push** in the app.
5. Record: total start events, counts per argv shape.
6. Enumerate host processes from `/proc`: watchers, their PPid, ages.
7. Restore `~/.gitconfig`; verify byte-identical against the backup; remove
   the trace file.

**Record verbatim:** total processes (expected ≈123), the per-command table,
the watcher census, and inotify instances in use.

**Acceptance.** Offline gate met; live numbers recorded; `~/.gitconfig`
restored byte-identical; no temp files or samplers left on the host.

**Commit.** None.

---

## Phase 1 — Attribution: make every command name its origin

**Why first.** MADR 0025 refuses to remediate Finding B before attribution, and
15 of the 123 processes are still unattributed (`rev-parse --git-dir`, no call
site in `lib/`). Every later phase's acceptance is "the count for *this*
provider fell".

**Files.** `lib/core/exec/command_telemetry.dart`,
`lib/core/ssh/ssh_command_executor.dart`, `lib/core/exec/local_command_executor.dart`;
tests in `test/command_telemetry_test.dart`, `test/ssh_command_executor_test.dart`.

### 1a. Negative test

```dart
test('a sample records which command produced it', () {
  CommandTelemetry.instance.reset();
  CommandTelemetry.instance.record(const CommandSample(
    lane: ExecLane.read, duration: Duration(milliseconds: 5),
    bytes: 10, wireBytes: 10, compressed: false, success: true,
    label: 'git status',
  ));
  expect(CommandTelemetry.instance.countsByLabel['git status'], 1);
});

test('counts aggregate per label, not per sample', () { /* 3 statuses, 1 log */ });
```

**Two-step landing:** `CommandSample.label` and `countsByLabel` land first with
`countsByLabel` returning `const {}`. **Required red:** `Expected: <1> / Actual: <null>`.

### 1b. Edit

1. `CommandSample` gains `final String label;` (required). It is the
   already-computed `gitArgs.join(' ')` — `_runBody` builds exactly this string
   for its byte-budget messages, so no new work.
2. `CommandTelemetry` gains `Map<String,int> get countsByLabel`, backed by a
   counter incremented in `record`, and `void resetCounts()`.
3. Labels are **normalised before counting** so they aggregate: drop `-c k=v`
   pairs, keep the subcommand and up to two following non-value tokens. This is
   the same shape used to analyse the 123 in MADR 0025 and must produce the
   same buckets.
4. Both executors pass the label at their existing `record(...)` sites.

**Acceptance.** Both tests red then green. The Dashboard's existing `commands`
stat is unchanged. Full suite `+3432 ~2`, 0 failing.

**Commit.** `git add -u && git commit --no-edit`.

---

## Phase 2 — F3a: bracket the commit sheet

**Finding.** MADR 0025 B. `repo_status_view.dart` wraps mutations in
`withOwnMutation` — **4 call sites**; `commit_dialog.dart` has **0** and relies
on `refreshAfterMutation`, which only `mark()`s *after* the fact
(`app_providers.dart:3020-3021`). A point-in-time stamp cannot suppress an echo
that already arrived, and `add -A`, `commit` and `push` all write during the
gesture.

**Files.** `lib/features/repository/commit_dialog.dart`;
`test/commit_dialog_test.dart`.

### 2a. Negative test

```dart
testWidgets('the commit sheet suppresses the echo of its own commit', (t) async {
  // The tracker must be in-flight for the whole commit, not merely stamped
  // after it: the index and ref writes that generate the echo happen while
  // the command is still running.
  late bool inFlightDuringCommit;
  // ... pump the sheet with a commit callback that samples
  // tracker.isRecent(repo, DateTime.now(), window) mid-commit ...
  expect(inFlightDuringCommit, isTrue,
      reason: 'the mutation must be bracketed, not stamped afterwards');
});
```

**Required red:** `Expected: true / Actual: <false>` — nothing marks the repo
until the commit has already returned.

### 2b. Edit

In `commit_dialog.dart`, wrap the `commit:` callback body:

```dart
      commit: (message) async {
        // Bracketed, not stamped afterwards. `refreshAfterMutation` marks only
        // once the command has returned, so every index/ref write the commit
        // makes *while running* reaches the watcher unsuppressed and buys a
        // full refresh wave each (0025 B / F3a). The inline composer in
        // repo_status_view.dart has always bracketed; this surface did not.
        await withOwnMutation(
          ref.read(ownMutationTrackerProvider),
          widget.repoPath,
          () => ref.read(gitServiceProvider).commit(widget.repoPath, message: message),
        );
        return true;
      },
```

The push path (`widget.onPush`) is already bracketed by its caller in
`repo_status_view.dart:_push`; do not double-wrap — the tracker is refcounted
(`_inFlight`), so a double wrap is safe but hides which surface owns it.

**Acceptance.** Test red then green; existing `commit_dialog_test.dart` cases
pass unchanged; full suite +1.

**Live check (recorded, not gating).** Re-run the Phase 0 live capture. Record
the new total. A fall is expected; the size is not predicted here.

**Commit.**

---

## Phase 3 — C3: a lease registry with enforced ceilings

**Finding.** MADR 0025 C3. Nothing bounds host processes; 0024 M2 showed a
budget that lives only in a comment is a budget that gets forgotten.

**Files.** `lib/core/git/bounded_watch.dart`, `lib/core/git/remote_watch_service.dart`;
`test/bounded_watch_test.dart`, `test/remote_watch_service_test.dart`.

### 3a. Negative tests

```dart
test('the arming script writes a lease naming this session', () {
  final s = boundedInotifyScript(['/r/.git'], lease: '/r/.git/mg-watch.lease');
  expect(s, contains('mg-watch.lease'));
  expect(s, contains('echo'));      // pid recorded
});

test('watcher arms are refused past the ceiling', () async {
  // executor with maxConcurrentWatchers armed, then one more
  await expectLater(service.watch('/r7'), emitsThrough(
      predicate<RepoWatchEvent>((e) => e.mode == WatchMode.polling)));
});

test('the ceiling is a named constant, asserted', () {
  expect(RemoteWatchService.maxConcurrentWatchers, 2);
});
```

**Required red:** the script contains no lease; the seventh arm succeeds.

### 3b. Edit

1. `bounded_watch.dart`: both arming scripts accept a `lease` path and write
   `"$$ $(date +%s)"` to it before `exec`.
2. `remote_watch_service.dart`: a `_liveWatchers` counter, a
   `static const int maxConcurrentWatchers = 2`, and an arm that returns
   `WatchUnavailable()` with an `onDiagnostic` line when the ceiling is
   reached — degrading to polling **and saying so**, reusing the H3 channel
   0024 already built.
3. A `sweepStaleWatchers(repoPaths)` that, at connect, reads each lease and
   `kill -TERM`s a recorded PID whose lease is older than
   `leaseStaleAfter` (a named constant) **and** whose `comm` is
   `inotifywait`/`fswatch`. Verified per-PID before signalling — the
   discipline MADR 0025 records as the reason nothing was killed on bad data.

**Acceptance.** Three tests red then green. The existing bounded-watch script
tests pass unchanged (the lease is additive). Full suite +3.

**Commit.**

---

## Phase 4 — C1: a watcher that dies on its own

**Finding.** MADR 0025 A + C1. Every client-side teardown path already works;
the leak is that `inotifywait` blocks in `select()` and never learns its reader
is gone — an upstream property, so no teardown fix can reach it.

**Files.** `lib/core/git/bounded_watch.dart`; `test/bounded_watch_test.dart`.

### 4a. Negative test

```dart
test('the watcher wakes periodically and re-checks its lease', () {
  final s = boundedInotifyScript(['/r/.git'], lease: '/r/.git/mg-watch.lease');
  // -t is what forces select() to return; without it the process can never
  // observe anything, including its own abandonment.
  expect(s, contains('-t '));
  expect(s, contains('mg-watch.lease'));
  expect(s, isNot(contains('exec stdbuf -oL inotifywait -m -e')),
      reason: 'the unbounded -m arm cannot self-terminate');
});
```

**Required red:** the script still uses unbounded `-m`.

### 4b. Edit

Rewrite both arming scripts as a bounded re-arm loop:

```sh
while :; do
  [ -f "$LEASE" ] || exit 0                       # lease gone: nobody is listening
  now=$(date +%s); ts=$(cut -d' ' -f2 "$LEASE" 2>/dev/null || echo 0)
  [ $((now - ts)) -lt $STALE ] || exit 0          # lease stale: client is gone
  inotifywait -t $INTERVAL <flags> "$@" || true   # returns on event OR timeout
done
```

The app refreshes the lease's timestamp over the live channel on each watch
tick it receives (cheap: one `touch`-equivalent, on the isolated lane).

**Live confirmation, and the only one that closes A.** After a week of ordinary
use including at least one sleep/VPN-drop cycle, enumerate from `/proc`:
orphaned watcher count must be **0**. A unit test cannot establish this; the
failure needs a real dropped TCP.

**Acceptance.** Test red then green; all existing watcher tests pass unchanged;
full suite +1. **A is not marked closed until the live check is recorded.**

**Commit.**

---

## Phase 5 — F2: invalidate by path, not by family set

**Finding.** MADR 0025 F2. `repo_status_view.dart:1529` calls
`_invalidateMutationFamilies()` — all 12 — for *any* `.git/` path, though
`RepoWatchEvent` already classifies what moved and
`repo_status_view.dart:1501` already consumes that classification for
worktree edits.

**Files.** `lib/core/git/watch_event.dart`, `lib/core/providers/app_providers.dart`,
`lib/features/repository/repo_status_view.dart`. Tests go in the existing
`test/repo_mutation_refresh_test.dart` (which already covers this exact
invalidation path and already builds `RepoWatchEvent`s) — **no new test file**,
so the existing cases act as the regression guard for the narrowed set.

### 5a. Negative test

```dart
test('a refs-only change does not invalidate status', () {
  const e = RepoWatchEvent(at: …, mode: WatchMode.eventDriven,
      paths: {'.git/refs/heads/main'});
  expect(e.touchedAreas, {GitArea.refs});
  expect(familiesFor(e.touchedAreas, '/r'), isNot(contains(statusProvider)));
});

test('an index change invalidates status but not remotes', () { … });

test('an unscoped tick still invalidates everything', () {
  // "empty means unknown, not nothing" - the documented contract.
});
```

**Required red:** `touchedAreas` and `familiesFor` do not exist; two-step
landing with `touchedAreas` returning `GitArea.values.toSet()` (i.e. today's
behaviour) makes the first two fail while the third passes.

### 5b. Edit

1. `watch_event.dart`: `enum GitArea { index, refs, stash, reflog, worktree, unknown }`
   and `Set<GitArea> get touchedAreas`, derived from the paths already carried.
   `unknown` for an unscoped tick — preserving the documented *"empty means
   unknown, not nothing"* contract exactly.
2. `app_providers.dart`: `List<ProviderOrFamily> familiesFor(Set<GitArea>, String repoPath)`,
   with `repoMutationFamilies` remaining the answer for `unknown`. The mapping
   is written **once**, beside the existing list, so the two cannot drift.
3. `repo_status_view.dart:1529`: invalidate `familiesFor(event.touchedAreas, …)`
   rather than the whole set.

**Acceptance.** Three tests red then green; every existing refresh test passes
unchanged; full suite +3.

**Live check (recorded).** Re-run the Phase 0 capture; record the new total and
the per-command table.

**Commit.**

---

## Phase 6 — F1: fingerprint short-circuit

> **DECLINED ON EVIDENCE — 2026-09-04.** Not executed; see **deviation (a)**
> (the witness cannot gate `status`) and **deviation (b)** (almost no target
> remains). Steps below stand as written.

**Finding.** MADR 0025 F1. Most of the 15 refresh triples observed a repository
identical to the one the previous wave saw.

**Files.** `lib/core/git/git_service.dart`, `lib/core/providers/app_providers.dart`;
`test/git_service_fingerprint_test.dart`.

### 6a. Negative test

```dart
test('an unchanged repo is not re-read', () async {
  final exec = _CountingExecutor();
  final git = GitService(exec);
  await git.statusIfChanged('/r');          // reads
  await git.statusIfChanged('/r');          // must not read again
  expect(exec.statusCalls, 1);
  expect(exec.fingerprintCalls, 2);
});

test('a changed fingerprint forces a re-read', () async { … });
```

**Required red:** two full reads.

### 6b. Edit

1. `repoFingerprint(repoPath)` — **one** command returning HEAD oid, `.git/index`
   size+mtime, `packed-refs` mtime and the loose-ref count.
2. A per-repo last-fingerprint map on `GitService`, cleared by
   `_invalidateRemoteCaches` and on disconnect (the existing session-scoped
   cache pattern — `_upstreamRemoteByRepo` is the model).
3. The refresh path calls the fingerprint first and skips the triple when it is
   unchanged.

**Safety.** A collision costs a missed refresh only if the index changes with
identical size *and* mtime; the next watcher tick catches it. State this in the
code, not only here.

**Acceptance.** Two tests red then green; full suite +2. Live capture recorded.

**Commit.**

---

## Phase 7 — F3b: supersede in-flight refresh waves

> **EXECUTED — 2026-09-04**, commit `84882e2`, but **not by the mechanism
> below**: the fetch seam was shared rather than waves superseded. See the
> execution record and **deviation (c)**.

**Finding.** MADR 0025 F3. Wave *n+1* arriving while *n* is in flight, with no
change between them, should supersede rather than both completing.

**Files.** `lib/core/providers/app_providers.dart`; `test/refresh_generation_test.dart`.

### 7a. Negative test

```dart
test('a superseded refresh wave does not issue its commands', () async {
  // three refreshes requested inside one window, fingerprint unchanged
  expect(exec.calls, 1);
});
```

**Required red:** `Expected: <1> / Actual: <3>`.

### 7b. Edit

A per-repo monotonic refresh generation. A wave records the generation it was
issued for; on completion, if the generation has moved and the fingerprint has
not, it is dropped rather than applied. `CommandLaneScheduler` is the in-tree
precedent for supersession.

**Acceptance.** Test red then green; full suite +1. Live capture recorded.

**Commit.**

---

## Phase 8 — C2: stop watching what git is already watching

> **DECLINED ON EVIDENCE — 2026-09-04.** Not executed. The steps below stand as
> written so the record shows what was planned; see **deviation (e)** for why
> the premise does not hold and MADR amendment C2.1 for the correction. Do not
> implement this phase from the text below.

**Finding.** MADR 0025 C2. `core.fsmonitor=true` is set by this app
(`app_providers.dart:1606` → `git_service.dart:2319`), confirmed live on both
host repos — so git runs its own daemon over the same tree the app watches.

**Files.** `lib/core/providers/app_providers.dart`,
`lib/core/git/remote_watch_service.dart`; `test/remote_watch_service_test.dart`.

### 8a. Negative test

```dart
test('a repo with fsmonitor enabled watches only git-dir signal points', () async {
  // the work tree is git's daemon's job; ours is HEAD/index/refs
  expect(spec.watchDirs, everyElement(startsWith(gitDir)));
});
```

**Required red:** the work-tree directories are still in the surface.

### 8b. Edit

When `core.fsmonitor` is enabled for a repo **and** `git fsmonitor--daemon
status` reports support (`git_service.dart:2304` already probes exactly this),
reduce the watch surface to the git-dir signal points `computeBoundedWatchSpec`
already computes, and let `git status` be fast because the daemon makes it so.

**Risk, stated.** A work-tree edit then reaches the app only via the next
git-state event or a poll. Whether that is acceptable is a **behavioural
decision**: if it degrades responsiveness in the live check, revert this phase
— it is the one phase here that trades a user-visible property for resources.

**Acceptance.** Test red then green; full suite +1; live check confirms
work-tree edits still surface within the poll interval.

**Commit.**

---

## Phase 9 — E: one long-lived parse worker

> **EXECUTED — 2026-09-04**, commit `0a9e0d4`. See the execution record for the
> observed red, and for the one test in 9a that could not be written.

**Finding.** MADR 0025 E. **13** `Isolate.run` call sites, each spawning and
tearing down an isolate per invocation, against Flutter's own guidance — and
`lib/features/viewer/highlight_worker.dart` is the in-tree proof of the fix.

**Files.** new `lib/core/parse/parse_worker.dart`, `lib/core/git/git_service.dart`;
`test/parse_worker_test.dart`.

### 9a. Negative test

```dart
test('repeated parses reuse one isolate', () async {
  final before = ParseWorker.instance.spawnCount;
  for (var i = 0; i < 5; i++) { await ParseWorker.instance.parseStatus(sample); }
  expect(ParseWorker.instance.spawnCount - before, 1);
});
test('a parse failure does not kill the worker', () async { … });
```

**Required red:** `Expected: <1> / Actual: <5>` (two-step landing: `ParseWorker`
delegates to `Isolate.run` first).

### 9b. Edit

Model on `highlight_worker.dart` exactly — one persistent isolate, request/reply
over `SendPort`/`ReceivePort`, serial processing, superseded results dropped by
the caller's token. Migrate the **hot repeated** parses only: status
(`git_service.dart:2157`), refs (`:2165`), log (`:2510`), blame (`:2877`).
Leave one-shot parses (key decode, gunzip) on `Isolate.run` — they are not
repeated and the worker's serialisation would make them worse.

**Constraints from the official docs, stated so the plan does not trip:** no
Flutter APIs or `rootBundle` in the worker; closures and sockets are not
sendable; each isolate costs a heap and an OS thread — so **one** worker, never
a pool.

**Acceptance.** Two tests red then green; every existing parse test passes
unchanged; full suite +2.

**Commit.**

---

## Phase 10 — D2: one process for the refresh triple

> **ALREADY IMPLEMENTED — 2026-09-04.** Not executed; `_snapshot` bundled the
> refresh triple before this plan was written. See **deviation (b)**.

**Finding.** MADR 0025 D2. `status`, `for-each-ref` and `remote` always appear
together and appeared 15 times each.

**Files.** `lib/core/git/git_service.dart`; `test/git_service_snapshot_test.dart`.

### 10a. Negative test

```dart
test('the refresh triple costs one command', () async {
  await git.repoSnapshot('/r');
  expect(exec.calls, 1);
});
test('a failing part does not fail the whole snapshot', () async { … });
```

**Required red:** `Expected: <1> / Actual: <3>`.

### 10b. Edit

`repoSnapshot(repoPath)` composing one `sh -c` that runs the three commands and
frames each with a record separator — the shape `setFsmonitorMany`
(`git_service.dart:2319`) already uses, including per-part failure isolation.
Fail open to the three individual calls, as `GitCatFileBatch` does.

**Acceptance.** Two tests red then green; full suite +2. Live capture recorded.

**Commit.**

---

## Phase 11 — D3: `cat-file --batch` as a session

> **DECLINED ON EVIDENCE — 2026-09-04.** Not executed. The steps below stand as
> written so the record shows what was planned; see **deviation (f)** for the
> two grounds and MADR amendment D3.1 for the prerequisites a future attempt
> needs. The file list below is known to be incomplete.

**Files.** `lib/core/git/git_cat_file_batch.dart`; `test/git_cat_file_batch_test.dart`.

Hold one `git cat-file --batch` per repo over a stream handle rather than
spawning per batch. It is git's own long-lived query interface and the class
already fails open to per-key `showOne`.

**Negative test:** two successive batches issue one process, not two.
**Required red:** `Expected: <1> / Actual: <2>`.

**Ceiling.** One per connection, counted against Phase 3's registry and the
stream budget 0024 M2 enforces.

**Acceptance.** Test red then green; existing batch tests pass unchanged;
full suite +1.

**Commit.**

---

## Phase 12 — D1: persistent command session *(requires separate approval)*

**Not authorized by approval of this plan.**

One long-lived `sh` per connection reading length-prefixed requests and writing
framed responses, replacing channel-per-command. Removes the two round trips
0024 P2 measured (`CHANNEL_OPEN` + confirmation, then `exec` with `wantReply`)
and the per-command fork.

**Binding constraints**, carried from 0024 P2 and extended:

* reads only; never `exclusive` (the barrier *is* the `.git/index.lock`
  guarantee) and never `sync`;
* one deadline per request; a wedged session is torn down and the per-command
  path resumes;
* per-request byte budgets (0024 H2's wire and decode bounds both apply);
* cancellation of one request must not kill the session;
* **flag-gated, default off**, per-command path retained verbatim.

**Why last.** It is the only proposal that creates a single point of failure,
and its payoff is proportional to the command count — which phases 2–11 exist
to reduce. Approving it before them would be paying the risk for work that is
about to disappear.

**Required before approval.** The live command count after Phase 11. If phases
2–11 reach the ≤15 target, D1's remaining value is ~30 round trips per gesture
and may not justify the risk. That is a decision to take on the number, not now.

> **The number was taken on 2026-09-04** — see the re-measurement below. The
> ≤15 target was **not** reached (76 processes, ≈42 app commands per gesture),
> so on the letter of this gate D1 is live, and its measured value is ≈3.7 s of
> protocol overhead per commit+push (≈1–2 s of wall clock at the read lane's
> 4-way concurrency, 51 ms RTT). **Still not approved**, on the re-measurement's
> own evidence: 53 % of all observed host processes came from the degraded-poll
> path (**MADR 0025 C4**), which D1 does not address and would merely make
> cheaper. C4 is bug-shaped, carries no single point of failure, and by decision
> driver 5 comes first. Re-decide D1 against a window with C4 removed.

---

## Verification

**Per phase:** the phase's own commands, plus

```sh
flutter analyze          # No issues found!
flutter test             # passing rises by exactly the tests added; failing 0
```

**Whole-plan acceptance.**

1. Every phase's negative test was observed red, with its verbatim failure in
   the execution record.
2. `flutter analyze` clean; `flutter test` **0 failing** throughout.
3. The MADR's success table re-measured with the validated instruments and
   recorded — **including any target not reached**:

| measure | baseline | target | measured 2026-09-04 |
|---|---|---|---|
| git processes, one commit+push | 123 | ≤ 15 | **76 — missed** |
| refresh triples per commit+push | 15 | 1–2 | **7 — attributed; the target was mis-specified (see below)** |
| long-lived host processes per connection | ≈40 observed | ≤ 6, enforced | **3 at rest — met** |
| orphaned watchers after a week incl. sleep/VPN drop | 19 / ~17 days | 0 | **0 — met (one window, not a week)** |
| repeated `Isolate.run` call sites | 13 | hot parses on 1 worker | **4 on 1 worker — met** |

### Re-measurement — 2026-09-04 (after phases 1-5, 7, 9)

Method as Phase 0, against `percona-postgres` on the live host, with the app
connected. Control passed (**7 start events for 5 known invocations**) before
the capture, per the rule that an instrument is not trusted until it has been
seen to work — this one had failed twice before. `~/.gitconfig` restored
byte-identical afterwards (sha256 `3134c8a2…` before and after), trace file and
backups removed, nothing left on the host.

**156 git processes over a 21-minute window, separating into three regimes with
no overlap:**

| regime | duration | processes | character |
|---|---|---|---|
| A | 0-92 s | **83** | 4 processes every 5 s, no user action |
| B | 92-1240 s | **0** | connected, idle, event-driven |
| C | last 42 s | **76** | one one-file commit+push |

* **Idle is free.** Nineteen minutes connected cost zero git processes, so no
  remaining proposal can be justified by steady-state cost.
* **The gesture cost 76 processes**, from ≈42 app-level `execute()` calls — the
  snapshot's three gits are siblings under one `sh -c`, so the seven
  status/for-each-ref/remote triples are **7 commands, not 21**.
* **Regime A is a new finding**, recorded as **MADR 0025 C4**: 53 % of all
  observed processes came from a 5-second metronome that only runs in
  `watchLifecycle`'s degraded mode — 48 processes per minute, with a 3-minute
  recovery interval, so one bad arm can cost ~140 processes. Two live
  `inotifywait` processes were present *during* that polling, which host-side
  data cannot explain and which needs app-side instrumentation of the mode
  transitions.
* **RTT to the host: 51 ms** (median TCP connect to :22; ICMP blocked). This is
  the number D1's approval turns on — see Phase 12.

4. Every ceiling is a named constant with a test that fails when exceeded.
5. `~/.gitconfig` on any measured host restored byte-identical; no samplers,
   temp files or stray processes left behind.

**Explicitly not claimed on completion.** Timing (`t_abs` was unavailable, so
no wall-clock figure is established), whether the workspace stays interactive
during a push, and D1's benefit.

## Rollout and Rollback

**Rollout.** Sequential commits on `master`. Only Phase 8 changes a
user-visible property (work-tree event latency); only Phase 12 is flagged.

**Rollback.** Per phase, `git revert <sha>`. Dependencies are listed in the
phase table; reverting a phase with dependents requires reverting them first.
The two that warrant naming:

* **Phase 4** changes how watchers are armed. Reverting restores the unbounded
  `-m` arm — and the leak with it.
* **Phase 8** trades work-tree watch coverage for resources. It is the most
  likely revert, and the cheapest: one condition.

**Kill switch.** Only Phase 12 gets one. A flag per phase would be eleven flags
guarding eleven small changes, which is more risk than the changes carry.

### Deviation (a) — 2026-09-04 — Phase 6's fingerprint cannot gate `status`

Found before writing any Phase 6 code, by testing the witness on the host
rather than trusting the plan's safety argument: a work-tree edit changes
nothing in the git-dir, so HEAD, index size/mtime and `packed-refs` are all
identical across an edit that `status` reports. The plan claimed the only risk
was an index changing with identical size and mtime; in fact the index does not
change at all, and `GIT_OPTIONAL_LOCKS=0` ensures `git status` will not rewrite
it either.

**Decision (maintainer): narrow F1 to refs-derived reads only.**
`for-each-ref`, `remote` and `log` depend on nothing but git-dir state, so the
witness is exact for them. `status` is never gated. MADR 0025 F1 carries the
correction.

### Deviation (b) — 2026-09-04 — Phase 10 is already implemented, and Phase 6 has no target left

**Found** while looking for Phase 6's gating point.
`git_service.dart:1366-1391`: `status()`, `refs()` and `pendingOp()` all
resolve through `_snapshot(repoPath)`, which issues **one** `sh -c` running
`status --porcelain=v2`, `for-each-ref` and `remote` with framed output — and
`_snapshot` (`:1958-1970`) already **deduplicates concurrent callers** through
`_snapshotInFlight`, so three providers asking at once share one command.

Two consequences:

* **Phase 10 (D2) is redundant.** The refresh triple was bundled and deduped
  before this plan was written. The 15×`status` / 15×`for-each-ref` /
  15×`remote` in the 123-process trace are therefore **15 invocations of one
  bundled command**, each spawning three git processes — not three separate
  reads repeated fifteen times. MADR 0025 D2 and the measurement's reading of
  the table are both corrected by this.
* **Phase 6 (F1) has almost no target.** The snapshot cannot be gated, because
  `status` rides it (deviation (a)). The only separately-invoked refs-derived
  reads left are `log` (4 in the trace) and `branch --merged` (9) — 13 of 123,
  and each would pay a fingerprint round trip, making a *single* call worse.

**Decision (maintainer): skip both, and re-measure before continuing.**
Phases 7–11 are to be decided against the actual remaining command count now
that Phases 2 and 5 have landed, rather than against the original 123 — which
is the MADR's own rule that Finding B is not remediated before it is
attributed. F1 is recorded as **declined on evidence** (the shape 0023 used for
its A2); D2 as **already implemented**.

## Execution record

| Phase | Status | Commit | Red-test observed | Live delta |
|---|---|---|---|---|
| 0 | baseline captured | — | n/a (measurement) | 123 host commands in the reference trace |
| 1 | executed | `cd659fe` | `countsByLabel` absent → compile error, then `Expected: 3 / Actual: 1` on bucketing | attribution only |
| 2 | executed | `1ca5863` | commit not bracketed → the echoed watcher tick re-refreshed | one refresh wave removed per commit |
| 3 | executed | `7735f13` | ceiling absent → 4 watchers armed where 2 are allowed | watcher ceiling = 2; stale sweep on connect |
| 4 | executed | `3ec893c` | wiring test red once the heartbeat arg was removed from the arm | watchers self-terminate after a 5 min lease gap |
| 5 | executed | `0dc4cba` | area-scoped invalidation absent → a work-tree tick invalidated ref families | refresh fan-out scoped by `GitArea` |
| 6 | **declined on evidence** | — | — | see deviation (a): the witness cannot gate `status` |
| 7 | executed | `84882e2` | `Expected: <1> / Actual: <3>` — three providers, three fetches | one snapshot command per refresh wave instead of ~2.5 |
| 8 | **declined on evidence** | — | — | see deviation (e): fsmonitor is a query accelerator, not a notification source |
| 9 | executed | `0a9e0d4` | `Expected: <1> / Actual: <5>` — five calls, five isolates | four hot parses share one persistent isolate |
| 10 | **already implemented** | — | — | see deviation (b): `_snapshot` bundled the triple before this plan |
| 11 | **declined on evidence** | — | — | see deviation (f): no production caller, and the transport cannot carry a session |
| 12 | **not authorized** | — | — | needs separate approval |

### Phase 7 as executed — F3 by sharing the fetch, not by superseding waves

The plan's 7b proposed a per-repo refresh **generation**: let each wave issue
its commands, then drop the result if a later wave had superseded it. That
suppresses the *effect* of a redundant wave but not the command — the host
still runs it. Deviation (b) had already established that `_snapshot` bundles
`status`/`for-each-ref`/`remote` into one `sh -c` and dedupes **strictly
concurrent** callers, which located the real leak precisely: `statusProvider`,
`refsProvider` and `pendingOpProvider` were three independent fetches, and
Riverpod rebuilds them as their listeners settle rather than in one instant, so
each wave slipped past the in-flight dedup two or three times. Six refresh
triggers produced fifteen snapshot commands.

So the fix moves the fetch seam instead: a single `repoSnapshotProvider` owns
the round trip, and `statusProvider` / `refsProvider` / `pendingOpProvider`
become synchronous views of it. One wave, one command, by construction — no
generation counter, and nothing to keep in sync. `GitService.snapshot()` is now
public so it is the seam tests intercept.

**Verification.** `test/repo_snapshot_sharing_test.dart` — three tests: the
sharing property (red at `Expected: <1> / Actual: <3>`), invalidation reaching
all three views, and a scan asserting no feature invalidates a derived view
instead of the fetch. Full suite: **3464 passed, 2 skipped** (the `live-forge`
pair), analyzer clean.

### Deviation (c) — 2026-09-04 — moving the fetch seam silently hung the suite

**Found** during Phase 7, after the sharing test was already green. The whole
run hung with no error, no stack and no failing test name — `flutter test`'s
own `--timeout 30s` did not fire either.

Moving the seam from `status()` to `snapshot()` meant fakes overriding
`status()` no longer intercepted, so `test/helpers/fake_snapshot.dart` gained a
mixin supplying a `snapshot()` built from the fake's override — and a twin,
`FakeRefsSnapshot`, for fakes overriding `refs()` instead. `_FakeGit` in
`test/secondary_window_app_test.dart:69` overrides `refs()` but was given the
status-shaped mixin. Its `snapshot()` called `status()`, whose base
implementation now resolves back through `snapshot()`: unbounded recursion
through `await`. That floods the microtask queue, and Dart drains every
microtask before any timer — which is why the test framework's own timeout
timer could never run. The inability to time out *was* the diagnostic.

**Decision: fix the pairing, and make the wrong pairing loud.** `_FakeGit` moves
to `FakeRefsSnapshot` (its `_HeadMoveGit` subclass overrides `fakeStatus`
instead of `status()` so the controllable HEAD still reaches the snapshot), and
both mixins now detect re-entry and throw a named `StateError` naming the seam
and the mixin to use instead. Detection is zone-scoped, not a flag, so two
genuinely concurrent snapshots of one repo — the case `_snapshotInFlight`
exists to collapse — do not false-positive.

**Instrument verified.** `test/fake_snapshot_guard_test.dart` pins it: both
wrong pairings throw with the expected message, the correct pairing resolves,
and concurrent snapshots do not trip the guard. Files added to the phase's
scope: `test/helpers/fake_snapshot.dart`, `test/fake_snapshot_guard_test.dart`,
and the 16 test files whose fakes took a mixin.

### Deviation (d) — 2026-09-04 — a diagnostic commit reached the remote

A temporary `mgTraceRefresh` instrumentation commit (`12903f1`) was committed
and pushed by the maintainer along with the phase work. It was removed with
`git revert` (`d34e662`) rather than a history rewrite, because the commit was
already published.

### Phase 9 as executed — the worker, and what could not be tested

`lib/core/parse/parse_worker.dart` holds one persistent isolate, modelled on
`features/viewer/highlight_worker.dart`: request/reply over
`SendPort`/`ReceivePort`, serial processing, a `spawnCount` observable, and
`onExit`-driven recovery that fails in-flight work rather than leaving callers
awaiting a reply that can no longer come. The four **hot repeated** parses moved
onto it — status (`git_service.dart:2168`), refs (`:2176`), log (`:2521`),
blame (`:2890`). One-shot parses (key decode, gunzip) stayed on `Isolate.run`,
and `GitService`'s 32 KiB inline threshold is unchanged, both as the plan
specified.

**Red observed**, via the two-step landing the plan asked for — step 1 spawned a
fresh isolate per call, which is today's `Isolate.run` behaviour expressed
through `Isolate.spawn` so a test can reach it at all:

```
00:01 +0 -1: repeated parses reuse one isolate [E]
  Expected: <1>
    Actual: <5>
```

Then green at 1 once the isolate persisted. Full suite **3468 passed, 2
skipped, 0 failures** (from 3464; +4 tests), analyzer clean, on Flutter 3.47.2
— checked against `FLUTTER_VERSION` before starting, per AGENTS.md.

**The plan's second test could not be written.** 9a specified *"a parse failure
does not kill the worker"*. None of the four parsers has a throw site: they are
total on malformed input by design, degrading to partial results. There is no
input that makes one fail, so the assertion has no way to be true-then-false and
would have been a check that had never been seen to fail. The worker's `catch`
is kept and documented as belt-and-braces for a future parser that *can* throw,
and the reachable resilience property is tested instead: an isolate death fails
in-flight work and the next call respawns and answers.

**Deviation in scope:** `test/snapshot_fallback_test.dart` pinned the old
mechanism by literal string (`contains('Isolate.run(() => parseRefsDetailed')`)
and failed. It was updated to `contains('parseWorker.parseRefs(')` — the
invariant it guards (the ref parse never runs on the UI isolate) is unchanged;
only the spelling of the hop moved. That failure doubles as proof the scan
works: it was observed failing on the real source, not assumed to.

### Deviation (e) — 2026-09-04 — Phase 8 declined: fsmonitor does not notify anyone

**Found** before writing any Phase 8 code, by checking the daemon's interface
rather than trusting the finding. `git fsmonitor--daemon` (git 2.55.0) has four
verbs — `start`, `run`, `stop`, `status` — and git's manual states it
"communicates directly with commands like `git status` using the simple IPC
interface". It is a query accelerator for **git**, with no subscribe and no
third-party client path.

The plan's stated mitigation is also false. 8b says a work-tree edit would still
reach the app "via the next git-state event or a poll"; but
`watch_lifecycle.dart:149` starts the 5 s poll **only** in degraded mode, and
`start()` cancels `pollTimer` on a successful arm (`:227`) — deliberately, to
fix a bug where recovery left the poll running forever. A healthy watcher polls
not at all, so shrinking the surface to git-dir points would leave a tracked
work-tree edit with no route to the UI at any latency.

Separately, the surface Phase 8 proposed reusing is unavailable to the repos it
targets: fsmonitor is refused for scoped repos
(`local_repo_form.dart:414-416`), and `computeBoundedWatchSpec` exists only for
scoped repos.

**Decision (maintainer): decline.** MADR 0025 carries amendment C2.1. The one
true observation inside C2 — the daemon is a long-lived host process the app
causes, never counts and never reclaims — is reassigned to **C3**'s registry
and ceilings, where it costs no user-visible behaviour.

### Deviation (f) — 2026-09-04 — Phase 11 declined: nothing calls it, and the transport cannot carry it

**Found** before writing any Phase 11 code, on two independent grounds.

**No caller.** `GitService.showBlobsBatch` (`git_service.dart:2989`) is
referenced nowhere in `lib/features/`; the only invocations in the tree are its
own tests. Its doc comment already records this as deliberate — *"Deliberately
unconsumed by the UI today (evaluated, not an oversight)"*. The per-batch spawn
the phase would eliminate happens zero times per session.

**No transport.** A session needs raw bytes out and incremental stdin in, and
the executor seam has neither. `CommandStreamHandle.stdout` is `Stream<String>`
UTF-8-decoded with `allowMalformed: true`
(`ssh_command_executor.dart:133-137`, decode at `:185`) — the exact lossy path
0022 M10 fixed, where one replaced byte desyncs a parser that frames objects by
git's byte count and returns the wrong content for the wrong key. And
`executeStream` takes no stdin; the one-shot path closes stdin immediately and
says why (`:920-929`): a process that reads stdin forever never exits and holds
its channel open — which is what `cat-file --batch` is. Supplying both means a
new byte-level bidirectional stream across all three `CommandExecutor`
implementations plus the pop-out relay, where
`ProxyCommandExecutor.executeStream` throws `UnsupportedError`. The plan's file
list (`git_cat_file_batch.dart` and its test) understates the work by three
executors and a relay.

**Decision (maintainer): decline.** MADR 0025 carries amendment D3.1, which
records the prerequisites so a future burst caller reopens it with a correct
estimate rather than this one.

### Attribution of the seven refresh triples — 2026-09-04

The re-measurement recorded 7 snapshots for one commit+push against a target of
1-2 and left it as "missed". Attributing it, per this record's own rule that a
finding is not remediated before it is attributed.

**Measured, offline and deterministically**, by counting `repoSnapshotProvider`
fetches through the real `RepoStatusView` refresh path with the snapshot as the
overridden seam:

```
ATTR initial-load=1  stage-delta=1
```

**One mutation costs exactly one snapshot.** There is no amplification left to
remove — Phase 7 took it out, and this confirms it end to end rather than by
reading the provider graph.

So the seven are seven *triggers*, and four of them are by design:

| # | trigger | why it refreshes |
|---|---|---|
| 1 | stage | the index changed |
| 2 | commit | HEAD and the index changed |
| 3 | **post-commit background fetch** | `ConnectionController.fetchInBackground` invalidates `repoFetchFamilies`, which includes the snapshot |
| 4 | push | remote-tracking refs moved |

The remaining ~3 are watcher ticks for the gesture's **own** filesystem changes,
arriving more than three seconds after the mutation returned.
`_ownMutationSuppressWindow` is `Duration(seconds: 3)`
(`repo_status_view.dart:328`) measured from when the command completes, but the
host's inotify events for a commit or a push — index, `refs/`, `logs/`,
remote-tracking updates — can land later than that, at which point they are
indistinguishable from an external change and are answered honestly.

**The target was wrong, not the code.** "1-2 refresh triples per commit+push"
was written when one trigger cost ~2.5 snapshots *and* when the triple was
believed to be three separate reads (corrected by deviation (b)). A gesture that
stages, commits, fetches and pushes changes repository state four times;
refreshing once or twice would mean showing stale state after three of them.
**Four is the floor, and the floor is met.**

**Not remedied, deliberately.** The only reducible part is the late self-inflicted
ticks, and the available levers are both bad: widening the 3 s window trades a
real cost for the risk of suppressing genuine external changes for longer, and
content-keyed suppression is F1, already declined on evidence (deviation (a)) —
the witness cannot gate `status`. Three extra snapshots (nine host processes)
per gesture does not justify either. Recorded as understood and accepted rather
than left reading as an open miss.
