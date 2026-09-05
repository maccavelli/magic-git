---
status: "proposed"
date: 2026-09-04
associated-madr: "0027-MADR-watcher-reclamation-cannot-reclaim.md"
---

# Give every watcher its own identity, and make reclamation provable

Associated MADR: [0027-MADR-watcher-reclamation-cannot-reclaim.md](0027-MADR-watcher-reclamation-cannot-reclaim.md)

## Goal

Make the connect sweep and the heartbeat lease able to reclaim an orphaned
watcher — which today neither can, in any configuration — by giving each watcher
instance its own lease and registry files and an identity check that is both
precise and portable.

**Success is not "the code changed".** It is: a sweep script, executed against a
real process tree, kills an orphan and spares a live watcher; and the two
orphans currently resident on `admdevops` are reclaimed by the new sweep and are
not by the old one.

## Scope

**In scope**

* Per-instance lease and registry files: `mg-watch.<token>.pid` / `.hb`.
* A `ps`-based identity check replacing the `/proc/<pid>/comm` classification.
* Per-instance staleness in both the lease loop and the sweep, replacing the
  per-repo "is anyone watching this repo" test.
* Discovery of every instance's files at sweep time, replacing the single
  overwritten path.
* Pruning of stale file pairs whose pid is gone.
* Executable tests that run the scripts against real processes.

**Out of scope**

* `maxConcurrentWatchers`, `pollInterval`, `recoveryInterval`, `heartbeatInterval`,
  `leaseStaleAfter` — no tuning; this plan changes identity, not budgets.
* The `start()` serialisation from 0026 — done, and unrelated.
* 0025 H2 (a ceiling refusal being indistinguishable from "no watcher tool")
  and H3 (teardown not killing the remote process). Both remain open; neither is
  addressed here.
* Local (`LocalWatchService`) watching, which spawns no host processes.

## Preconditions

```sh
flutter --version | head -1          # must equal FLUTTER_VERSION (3.47.2)
flutter pub get --enforce-lockfile   # "Got dependencies!"
git status --short                   # empty
flutter analyze                      # No issues found!
flutter test                         # 3479 passing, 2 skipped, 0 failing
```

Any deviation from **3479 / 2 / 0**: stop and prompt — the baseline moved.

**Do not clean the host.** The two orphans on `admdevops` (`3503545`,
`3504806`, both `ppid 1`, no children) are this plan's live fixture. Phase 5
uses them, and they cannot be recreated on demand.

## Implementation Steps

### Phase 1 — A portable, precise identity check

**Files.** `lib/core/git/bounded_watch.dart`; `test/watcher_sweep_exec_test.dart` (new).

The decisive defect first, and on its own, so its fix is provable in isolation.

Replace the classification test in `watcherSweepScript`:

```sh
c=$(cat /proc/"$p"/comm 2>/dev/null || echo)      # Linux-only; matches 'sh' never
case "$c" in inotifywait|fswatch) kill -TERM "$p" ...
```

with an identity test — does the process at `$p` carry *this instance's own*
pid-file path in its command line:

```sh
cmd=$(ps -o command= -p "$p" 2>/dev/null || echo)
case "$cmd" in *"$marker"*) kill -TERM "$p"; rm -f "$f" ;; esac
```

The marker needs no new plumbing: the script already embeds its pid-file path,
so it is already in the watcher's command line.

**1a. Negative test — executable, not textual.** The string assertions in
`bounded_watch_test.dart` are what let this defect ship, so the new test spawns
a real process and runs the real script:

```dart
test('the sweep reclaims a process whose command line carries the marker', () async {
  // a real `sh -c "... <marker> ...; sleep 300"` in a temp dir, its pid recorded
  await runSweep();
  expect(await isAlive(pid), isFalse);
});
test('the sweep spares a process that does NOT carry the marker', () async {
  expect(await isAlive(otherPid), isTrue);
});
```

**Required red:** the first test against today's script — the process survives,
because `comm` is `sh` and (on this Mac) `/proc` does not exist. `Expected:
false / Actual: true`.

> Runnable on macOS **only because** the check is `ps`-based. That is not
> convenience; it is the reason the defect was invisible. Keep these tests
> executable — never re-express them as `contains(...)` assertions.

**Acceptance.** Both tests red then green; existing `bounded_watch_test.dart`
passes unchanged; suite +2. **Commit.**

### Phase 2 — Per-instance files

**Files.** `lib/core/git/bounded_watch.dart`, `lib/core/git/remote_watch_service.dart`;
`test/bounded_watch_test.dart`, `test/remote_watch_service_test.dart`.

`watchPidFile`/`watchHeartbeatFile` (`remote_watch_service.dart:155-156`) gain a
token; the arm (`:339-340`) and the heartbeat writer (`:447`) use the same one
for the life of that watcher. The token is generated per arm — monotonic counter
plus start time is sufficient; it needs to be unique among *live* watchers, not
globally unguessable.

```dart
static String watchPidFile(String gitDir, String token) =>
    '$gitDir/mg-watch.$token.pid';
static String watchHeartbeatFile(String gitDir, String token) =>
    '$gitDir/mg-watch.$token.hb';
```

**2a. Negative test.** Two arms for one repo must not share files:

```dart
test('two watcher instances own distinct lease files', () { … });
```

**Required red:** `Expected: <2> distinct paths / Actual: <1>`.

**2b.** `watch_path_filter_test.dart` extended to the tokenised names. The
filter matches the literal prefix `mg-watch.` and so still holds — but that is
now load-bearing for a name shape no test covers.

**Required red:** assert a tokenised path is filtered, with the prefix check
removed.

**Acceptance.** Tests red then green; suite +N. **Commit.**

### Phase 3 — Per-instance staleness, in both directions

**Files.** `lib/core/git/bounded_watch.dart`, `lib/core/git/remote_watch_service.dart`;
`test/watcher_sweep_exec_test.dart`.

Both the lease loop and the sweep currently ask *"is anyone watching this
repo?"*. Both must ask *"is **this** watcher's owner gone?"* — the lease loop by
testing its own `.hb`, the sweep by testing each instance's `.hb` rather than
bailing on a single shared one:

```sh
[ -n "$(find $hb -mmin -$mins 2>/dev/null)" ] && exit 0;   # DELETE: aborts everything
```

`sweepStaleWatchers` (`:166`) enumerates `mg-watch.*.pid` in the git-dir instead
of being handed one path, and evaluates each pair independently.

**3a. Negative test — the exact production scenario.** A live watcher and an
orphan for the **same repo**, with the live one's heartbeat fresh:

```dart
test('a fresh sibling heartbeat does not protect an orphan', () async {
  expect(await isAlive(orphanPid), isFalse);
  expect(await isAlive(livePid), isTrue);
});
```

**Required red:** `Expected: false / Actual: true` — today a fresh sibling
heartbeat aborts the sweep before it looks at anything, which is precisely how
the `admdevops` orphans survived a rebuild.

**3b.** A stale pair whose pid is gone is pruned, so files do not accumulate.

**Acceptance.** Tests red then green; suite +N. **Commit.**

### Phase 4 — Migration: reclaim what the old scheme left

**Files.** `lib/core/git/bounded_watch.dart`; `test/watcher_sweep_exec_test.dart`.

Existing hosts carry legacy `mg-watch.pid` / `mg-watch.hb` — including the two
orphans on `admdevops`, which name a shell and have no token. The sweep must
reclaim those too, or this plan leaves the exact processes that motivated it
running forever.

The legacy pid file names a lease shell whose command line contains
`mg-watch.pid`, so the same `ps` marker test identifies it. Sweep the legacy
pair as a special case, then delete it.

**4a. Negative test.** A legacy-shaped pair, reclaimed and its files removed.
**Required red:** the legacy process survives.

**Acceptance.** Test red then green. **Commit.**

### Phase 5 — Live confirmation against the fixture

**No code.** The two orphans on `admdevops` are the fixture, and the check runs
in one direction that cannot be faked:

1. Record the fixture: `ps -o pid=,ppid=,etimes=,command= -p 3503545 3504806`.
2. Run **today's** sweep script against them by hand → they must **survive**
   (confirming the defect on the real host, not only in a test).
3. Run the **new** sweep script → they must be gone, and their files removed.
4. Confirm no live watcher of the running app was harmed: census before and
   after, and the app still reports event-driven watching.
5. Leave the host clean: no stray files, no `trace2` keys, `~/.gitconfig`
   untouched (this phase writes no git config at all).

**Acceptance.** Both directions observed and recorded verbatim — the old script
sparing them is as much a required result as the new script reclaiming them.

## Verification

**Per phase:** the phase's own tests, plus

```sh
flutter analyze          # No issues found!
flutter test             # passing rises by exactly the tests added; failing 0
```

**Whole-plan acceptance.**

1. Every negative test observed red, verbatim, in the execution record.
2. `flutter analyze` clean; `flutter test` 0 failing throughout.
3. **No test in this plan asserts script text where it could execute the
   script.** String assertions are what let this defect ship; a reviewer should
   be able to check this by grepping the new tests for `contains(`.
4. Phase 5 recorded in both directions on the live host.
5. Nothing from the out-of-scope list touched — in particular no interval or
   ceiling retuned.
6. The host left clean, and `0025 C5` updated to point at the outcome.

## Rollout and Rollback

The change is confined to the watcher's own lease/registry files and the sweep
script. Rollback is reverting the phase commits; the only residue on a host is
tokenised `mg-watch.*` file pairs, which a reverted build ignores (they match
neither the legacy path nor the filter's prefix rule) and which are removed by
the next sweep that understands them.

The risk that matters is **killing the wrong process**. It is bounded by the
identity check being *narrower* than what it replaces: today's guard would
accept any `inotifywait` on the host; the new one requires the process's command
line to contain a path this app constructed for this repo. Phase 1's second
test — a process the sweep must **spare** — exists for exactly this and is not
optional.

## Execution record

*(Empty until approved. Filled in during execution: what each phase did, the
verbatim red-test output, the live confirmation, and a dated entry for every
deviation.)*

| Phase | Status | Commit | Red-test observed | Result |
|---|---|---|---|---|
| 1 | not started | — | — | — |
| 2 | not started | — | — | — |
| 3 | not started | — | — | — |
| 4 | not started | — | — | — |
| 5 | not started | — | — | — |
