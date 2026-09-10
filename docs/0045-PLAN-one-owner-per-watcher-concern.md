---
status: "in-progress"
date: 2026-09-10
associated-madr: "0045-MADR-one-owner-per-watcher-concern.md"
---

# Implement: one owner per watcher concern

Associated MADR: [0045-MADR-one-owner-per-watcher-concern.md](0045-MADR-one-owner-per-watcher-concern.md)

## Goal

Rebuild the client side of the repository watcher so that each concern has exactly
one owner: demand and identity in Riverpod, exclusion and budget in an injected
admission component, sequencing in one engine per watcher, and backend work behind a
`WatchSource` seam built from small units. The host protocol does not change.

The plan is done when all of these hold:

* the orphaned-watcher class (MADR 0043 amendment 0043.1) cannot occur;
* a change of watch parameters always arms the new parameters;
* a remote linked worktree gets a live watcher (MADR 0045 F10);
* no mutable `static` remains in the watch stack;
* watcher logic is tested without wall-clock sleeps;
* every guarantee the watcher mutation catalogues protect still has a mutation that
  kills it;
* MADR 0044's outstanding step 4.3 has been measured on the host.

## Scope

### In

* `lib/core/git/watch/`, a new directory holding the units named in each phase.
* `lib/core/git/remote_watch_service.dart`, `local_watch_service.dart`,
  `watch_lifecycle.dart` (deleted in phase 4), `watch_diagnostics.dart`,
  `bounded_watch.dart` (timing defaults only; no script text changes),
  `git_service.dart` (one function extracted), `lib/core/providers/app_providers.dart`,
  and `lib/features/tabs/tabs_controller.dart`.
* The watcher test files named per phase, new unit tests, one new `integration`-tagged
  executing test, and a structural guard test.
* The watcher mutation catalogues (`0039`, `0040`, `0041`, `0043` and `0044`, for their
  watcher entries only) and a new `tool/mutations/0045-watch-stack.json`.
* The docs: this plan's execution record; MADR 0045's status; MADR 0044's plan (its
  step 4.3 and status); and the README rows.

### Out, and why

* **Host script text and protocol:** the lock prelude, lease loop, stdin-EOF watchdog,
  readiness marker and sweep script. MADR 0045 keeps them. Passing a different git dir
  into the existing builders is not a protocol change.
* **Watching a remote linked worktree's own git dir for git-state ticks** (its index,
  its `HEAD`). The recursive script watches the work tree only. After phase 3 a remote
  worktree arms and reports work-tree edits, but git-state changes made *outside the
  app* reach it only through those edits or through polling. Closing that gap means a
  second watch root, which is a script change, and it needs its own record.
* **MADR 0044 F9**, the ceiling derived from one session's stream budget. The capacity
  arithmetic moves unchanged.
* **The tab-strip dirty-dot blink** (`tab_strip.dart:178`, `asData?.value`), recorded in
  MADR 0044's plan and unrelated to this work.
* **Pop-out windows**, which keep overriding `repoWatchProvider` with an empty stream
  (`secondary_window_main.dart:233`).

## Grounding

These are the facts the steps below depend on. Line numbers cite
`remote_watch_service.dart` at `0d31f51`, which is byte-identical at `7898950`
(`HEAD`, pushed, at plan time).

* **The watch services have two production callers**, both in `repoWatchProvider`
  (`app_providers.dart:3744–3745`). `sweepStaleWatchers` has one caller,
  `_sweepStaleWatchers` (`app_providers.dart:1691–1702`), which keys each repository by
  `scoped[p] ?? '$p/.git'`.
* **`repoWatchProvider` is a `StreamProvider.autoDispose.family<RepoWatchEvent, String>`.**
  14 test files and `secondary_window_main.dart:233` override it using
  `overrideWith((ref, repoPath) => …)` or `repoWatchProvider(path).overrideWith((ref) => …)`,
  and nine more read it without overriding it. **Its name, type and family key must not
  change.**
* **Tab containers have one construction site.** `TabsController._create` calls
  `_containerFactory(overrides)` (`tabs_controller.dart:384`); `_defaultContainerFactory`
  is at line 95.
* **`GitService.repoLayout`** resolves `RepoLayout(toplevel, gitDir, gitCommonDir)` with a
  legacy fallback, and throws `GitException` when both probes fail
  (`git_service.dart:1435–1497`).
* **`package:clock` is a runtime dependency** (`pubspec.yaml`) and **`fake_async` a dev
  dependency.** Riverpod 3.3.2 deprecates `StreamProvider.stream`
  (`riverpod-3.3.2/CHANGELOG.md:393`).
* **The analyzer is strict:** strict casts, inference and raw types, plus
  `unawaited_futures`, `cancel_subscriptions`, `close_sinks`, `prefer_const_constructors`,
  `prefer_const_declarations`, `prefer_final_locals` and `directives_ordering`.
* **Arm-closure anchors in `remote_watch_service.dart`:**

  | What | Line |
  | --- | --- |
  | `_createLifecycle` | 651–1153 |
  | `cachedTool` | 664 |
  | `arm:` | 692 |
  | token | 696 |
  | spec | 710 |
  | ceiling check | 722 |
  | `releaseSlot` | 743 |
  | `gitDir` | 771 |
  | `beat` | 778 |
  | `releaseHostClaims` | 813 |
  | the awaited first stamp | 845 |
  | `executeStream` | 849 |
  | `SSHStreamBudgetExhausted` | 859 |
  | the readiness completer | 890 |
  | the stderr listener | 894 |
  | the race | 946 |
  | the locked refusal | 970 |
  | the no-paths refusal | 1006 |
  | the delimiter | 1026 |
  | the stdout listener | 1027 |
  | the re-arm debounce | 1056 |
  | the heartbeat timer | 1103 |
  | the `WatchArmed` teardown | 1105 |
  | `_detectWatcher` | 1155 |
  | `_SharedWatch` | 182 |
  | `class RemoteWatchService` | 320 |
  | `watch()` | 611 |

* **The `SSHStreamBudgetExhausted` path strands its lease.** It releases the slot and
  returns without calling `releaseHostClaims()`, even though the lease was stamped at
  line 845. Found while planning; fixed in phase 2.
* **Statics used by tests.** `resetWatcherCount` in 11 files; `liveWatchers` in 10;
  `liveWatchersFor` in 5; `maxConcurrentWatchers` in 5.
* **Constructor call sites.** `RemoteWatchService(` in 12 test files;
  `LocalWatchService(` in 4; `watchLifecycle(` and `WatchHooks` in 2 each.
* **Real-time waits.** `settleArm(` appears in 8 test files. The watcher test files hold
  about 100 real-time waits; `watch_lifecycle_test.dart` has 9 tests, all under
  `fakeAsync`.
* **Mutation entries anchored in watcher files:**

  | Catalogue | `remote_watch_service.dart` | `bounded_watch.dart` |
  | --- | --- | --- |
  | 0039 (f4) | 3 | — |
  | 0040 (p1) | 2 | — |
  | 0041 | 16 | 11 |
  | 0043 | 8 | 2 |
  | 0044 | 7 | 3 |

* **File lists referred to by the steps below** (from the census at plan time):
  * **`repoWatchProvider` test files (23):** `app_shell_undo_test.dart`,
    `dashboard_sheet_test.dart`, `deferred_external_change_test.dart`,
    `diff_popout_window_test.dart`, `diff_reload_test.dart`, `history_actions_test.dart`,
    `history_drag_merge_test.dart`, `history_filter_warning_test.dart`,
    `history_mouse_drag_test.dart`, `history_paging_test.dart`,
    `history_rebase_range_test.dart`, `history_ref_chip_overflow_test.dart`,
    `history_search_e2e_test.dart`, `keyboard_shortcuts_test.dart`,
    `push_logs_output_test.dart`, `refresh_no_flash_test.dart`,
    `repo_mutation_refresh_test.dart`, `repo_status_view_test.dart`,
    `repo_status_watch_refresh_test.dart`, `secondary_window_app_test.dart`,
    `window_manager_bridge_test.dart`, `worktree_invalidation_test.dart`,
    `worktrees_view_test.dart`.
  * **`RemoteWatchService(` construction sites (12):** `connect_paths_test.dart`,
    `remote_watch_service_test.dart`, `watch_arm_signal_test.dart`,
    `watch_ceiling_derived_test.dart`, `watch_ceiling_per_host_test.dart`,
    `watch_ceiling_recovery_test.dart`, `watch_diagnostics_both_backends_test.dart`,
    `watch_lease_identity_test.dart`, `watch_lease_release_test.dart`,
    `watch_shared_path_test.dart`, `watch_slot_leak_test.dart`,
    `watch_transition_wiring_test.dart`.
  * **`LocalWatchService(` construction sites (4):** `local_watch_bounded_test.dart`,
    `local_watch_service_test.dart`, `local_watch_worktree_test.dart`,
    `watch_diagnostics_both_backends_test.dart`.
  * **`settleArm(` users (8), plus the helper itself:** `remote_watch_service_test.dart`,
    `watch_ceiling_derived_test.dart`, `watch_ceiling_per_host_test.dart`,
    `watch_ceiling_recovery_test.dart`, `watch_diagnostics_both_backends_test.dart`,
    `watch_lease_identity_test.dart`, `watch_shared_path_test.dart`,
    `watch_transition_wiring_test.dart`; helper `test/helpers/watch_settle.dart`.
* **At `7898950` the three deviation (c) tests are committed and pushed** in
  `test/watch_shared_path_test.dart`. Tests A and B fail against the unchanged
  `remote_watch_service.dart` by design, so **`master` carries two failing tests until
  phase 2 lands**. That file is also **not `dart format`-clean** at `7898950`; phase 2
  migrates it, and its commit gate formats it. The only uncommitted files at plan time
  are this plan, MADR 0045's link to it, and its README row.

## Rules for every phase

1. **Deviations stop the work.** Anything this plan does not cover — a wrong step, a
   file not listed, a pre-existing defect, a fact that contradicts MADR 0045 — is
   reported with evidence, real resolutions and the cost of doing nothing, and waits for
   the maintainer. The docs are amended before the work continues.
2. **Commits** use exactly `git commit --no-edit`. Code and docs are never in one commit.
   Nothing is pushed unless the maintainer asks in that same turn.
3. **The gate before every code commit:** `flutter analyze` reports no issues;
   `dart format --output=none --set-exit-if-changed <each staged .dart file>` exits 0;
   the phase's targeted tests pass; `flutter test` passes in full. Exit statuses are
   captured in variables and never piped through a filter. Logs go to the scratchpad and
   any failure is read in full.
4. **Mutation catalogues** run one at a time, with no other `flutter test` process of
   mine running. Before each run, the union of that catalogue's `tests` lists is run on
   the unmutated tree and must pass; if it does not, the run is invalid and is not
   performed.
   * A **DID NOT APPLY** gets re-anchored to the same guarantee's new line.
   * A **SURVIVED** is reproduced by hand in a scratch `git worktree` before it is
     believed.
   * An entry is retired only where the retirement tables below list it.
5. **Process hygiene.** `pkill` is never used, suggested or called, in any form, on the
   Mac or on a host. I stop only my own background tasks (`TaskStop`), or the exact
   `Process` objects a test spawned. No destructive git commands.
6. **Identifier hygiene.** No hostnames, accounts or repository names go into committed
   content, and `no_real_identifiers_scan_test.dart` stays green.
7. **Host commands are read-only**, except where step 7.4 explicitly says otherwise.

## Implementation Steps

### Phase 0 — preconditions (no code)

0.1 `flutter --version | head -1` must print `Flutter 3.47.2`, and
`flutter pub get --enforce-lockfile` must print `Got dependencies!`.

0.2 `HEAD` must be `7898950` or a descendant touching no watcher file, and
`git status --porcelain` must list exactly these, and nothing else:

* `docs/0045-MADR-one-owner-per-watcher-concern.md`
* `docs/0045-PLAN-one-owner-per-watcher-concern.md`
* `docs/README.md`

0.3 Stage those three docs files and commit (docs).

0.4 Run the baseline into the scratchpad: `flutter analyze` must report no issues, and
`flutter test` must fail **exactly two** tests —
`a subscriber leaving while a build is deferred orphans nothing` and
`arriving, leaving and arriving during a teardown arms once, after it`. Record the pass
count. Any other failure is a deviation.

0.5 No catalogues are run in phase 0. Rule 4 forbids it while those two tests are red.
The last clean results are on record in MADR 0044's plan: 0041 27/0, 0043 10/0,
0044 10/0.

### Phase 1 — foundations, no change in behaviour

**Create:**

* **`lib/core/git/watch/watch_timings.dart`** — `final class WatchTimings`, holding every
  duration and count as a `static const default…` field plus an instance field of the
  same name, set by a `const` constructor that defaults each field to its static:

  | Field | Default | Replaces |
  | --- | --- | --- |
  | `trailing` | 150 ms | `watchLifecycle` default; `LocalWatchService.watch`; `RemoteWatchService.watch`; `_createLifecycle` |
  | `maxWait` | 1 s | the same four |
  | `minInterval` | 1 s | the same four |
  | `pollInterval` | 5 s | the same four |
  | `recoveryInterval` | 3 min | the same four |
  | `maxRestarts` | 3 | `watchLifecycle` default |
  | `restartBackoffStep` | 2 s | `Duration(seconds: restarts * 2)` in `scheduleRestart` |
  | `maxPathsPerTick` | 512 | `const maxPaths = 512` |
  | `armSignalCeiling` | 2 s | `RemoteWatchService.armSignalCeiling` |
  | `heartbeatInterval` | 60 s | `RemoteWatchService.heartbeatInterval` |
  | `leaseStaleAfter` | 5 min | `RemoteWatchService.leaseStaleAfter`; the `staleAfter` defaults in `bounded_watch.dart` |
  | `hostLeasePoll` | 60 s | the `leasePoll` defaults in `bounded_watch.dart` |
  | `releaseTimeout` | 15 s | the two `Duration(seconds: 15)` literals in `beat` and `releaseHostClaims` |
  | `sweepTimeout` | 20 s | the literal in `sweepStaleWatchers` |
  | `admissionGrace` | 3 min | `sharedTeardownGrace` |
  | `rearmDebounce` | 2 s | `_rearmDebounce` in both services |
  | `maxDiagnosticLines` | 20 | `RemoteWatchService.maxDiagnosticLines` |
  | `maxBufferChars` | 1 << 20 | `_maxBufferChars` |

  Plus `static const standard = WatchTimings();`, a `WatchTimings.forTest()` factory that
  shrinks every duration, and `List<String> coherenceErrors()`. That method returns one
  message for each violated rule: `releaseTimeout < admissionGrace`,
  `heartbeatInterval * 3 <= leaseStaleAfter`, `hostLeasePoll < leaseStaleAfter`,
  `armSignalCeiling < releaseTimeout`, `trailing <= maxWait` and
  `pollInterval < recoveryInterval`. It is a method rather than a set of constructor
  asserts because comparing `Duration`s is not a constant expression.

* **`lib/core/git/watch/watch_target.dart`** — `enum WatchBackend { local, ssh }`, and
  `sealed class WatchSurface` with `RecursiveSurface` and `BoundedSurface(gitDir,
  workTree)`. Also `final class WatchTarget(repoPath, surface, backend)`. All carry value
  `==`, `hashCode` and `toString`.

* **`lib/core/git/watch/watcher_id.dart`** — `final class WatcherId(sessionId, repoPath,
  attempt, token?)` with value equality, and `toString` rendering
  `session/attempt[/token]`.

* **`lib/core/git/watch/source/surface_rearm_policy.dart`** — `SurfaceRearmPolicy({required
  Duration debounce})` with two methods. `void onPath(String path, {required bool
  bounded, required void Function() rearm, required bool Function() cancelled})` starts
  or restarts the debounce timer only when `bounded && path.startsWith('.git/')`. `void
  cancel()` stops it.

* **`lib/core/git/watch/source/remote/record_splitter.dart`** —
  `RecordSplitter({required String delimiter, required int maxBufferChars, void
  Function()? onOverflow})`. `List<String> add(String chunk)` returns the complete
  records, keeps the partial tail using a cursor, and drops the tail with `onOverflow`
  once it grows past `maxBufferChars`. This is the logic from the stdout listener at
  lines 1027 onwards.

* **`lib/core/git/watch/source/remote/stderr_line_reader.dart`** — `sealed class
  StderrLine` with `ReadinessMarker`, `LockHeldBy(token)` and `Diagnostic(line)`, and
  `StderrLineReader({required int maxDiagnosticLines, required int maxBufferChars})`.
  `List<StderrLine> add(String chunk)` recognises `watchArmedMarker` exactly, matches
  `mg-watch: lock held by (\S+)`, filters `Setting up watches` / `Watches established`,
  and emits at most `maxDiagnosticLines` diagnostics. This is the parsing half of the
  stderr listener at lines 894 onwards; its side effects stay in the arm.

**Modify:**

* **`watch_lifecycle.dart`:** parameter defaults come from the `WatchTimings.default…`
  statics, and `maxPaths` and the backoff step come from the statics too. No signature
  changes.
* **`local_watch_service.dart`:** defaults from the statics; `SurfaceRearmPolicy`
  replaces the re-arm block inside the arm listener; delete `_rearmDebounce` (line 182).
* **`remote_watch_service.dart`:**
  * defaults from the statics;
  * `armSignalCeiling`, `heartbeatInterval`, `leaseStaleAfter`, `sharedTeardownGrace` and
    `maxDiagnosticLines` become `static const … = WatchTimings.default…` (names kept,
    since tests use them);
  * the two 15-second literals and the 20-second literal use the statics;
  * `RecordSplitter` replaces the stdout buffer loop;
  * `StderrLineReader` replaces the parsing inside the stderr listener, whose side effects
    stay put (complete `ready`, record `incumbent`, log, `onDiagnostic`);
  * `SurfaceRearmPolicy` replaces the re-arm debounce;
  * delete `_rearmDebounce`, `_maxBufferChars`, `_isWatcherStartupNoise` and `_lockHeldBy`.
* **`bounded_watch.dart`:** the `leasePoll` and `staleAfter` parameter defaults use
  `WatchTimings.defaultHostLeasePoll` and `WatchTimings.defaultLeaseStaleAfter`. Script
  text is unchanged.

**Tests to create:**

* `test/watch_timings_test.dart`:
  * `the standard timings are coherent` — `coherenceErrors()` is empty;
  * `a release timeout at or above the admission grace is incoherent`;
  * `three heartbeats that outlast the stale lease are incoherent`;
  * `forTest keeps every rule`.
* `test/watch_target_test.dart`:
  * `targets with equal fields are equal and hash alike`;
  * `a bounded surface differs from a recursive one on the same path`;
  * `a different git dir is a different target`.
* `test/surface_rearm_policy_test.dart` (fakeAsync):
  * `a .git path on a bounded surface re-arms once after the debounce`;
  * `repeated .git paths inside the debounce collapse to one re-arm`;
  * `a work-tree path never re-arms`;
  * `a recursive surface never re-arms`;
  * `cancel stops a pending re-arm`;
  * `a cancelled engine is not re-armed`.
* `test/record_splitter_test.dart`:
  * `complete records are returned in order`;
  * `a record split across chunks survives intact`;
  * `a trailing partial is kept for the next chunk`;
  * `an undelimited flood past the cap is dropped and reported`;
  * `a large burst is linear` — the 20 000-record burst from
    `remote_watch_service_test.dart`, run at the unit.
* `test/stderr_line_reader_test.dart`:
  * `only the exact marker is a readiness marker`;
  * `the incumbent token is read from a refusal line`;
  * `startup chatter is dropped`;
  * `diagnostics stop at the budget`;
  * `a line split across chunks is read once`.

**Catalogue:** create `tool/mutations/0045-watch-stack.json` with these phase-1 entries.
Each names its killing test file.

| Label | File | Killed by |
| --- | --- | --- |
| `p1: coherence accepts a release timeout at the grace` | `watch_timings.dart` | `watch_timings_test.dart` |
| `p1: the splitter drops the trailing partial` | `record_splitter.dart` | `record_splitter_test.dart` |
| `p1: the reader forwards startup chatter` | `stderr_line_reader.dart` | `stderr_line_reader_test.dart` |
| `p1: any line counts as the readiness marker` | `stderr_line_reader.dart` | `stderr_line_reader_test.dart`, `watch_arm_signal_test.dart` |
| `p1: a work-tree path re-arms a bounded surface` | `surface_rearm_policy.dart` | `surface_rearm_policy_test.dart` |
| `p1: re-arms are not debounced` | `surface_rearm_policy.dart` | `surface_rearm_policy_test.dart` |

**Verify:**

```sh
flutter analyze
dart format --output=none --set-exit-if-changed <every staged .dart file>
flutter test test/watch_timings_test.dart test/watch_target_test.dart \
  test/surface_rearm_policy_test.dart test/record_splitter_test.dart \
  test/stderr_line_reader_test.dart
flutter test test/remote_watch_service_test.dart test/local_watch_bounded_test.dart \
  test/local_watch_service_test.dart test/local_watch_worktree_test.dart \
  test/watch_arm_signal_test.dart test/watch_lease_release_test.dart \
  test/watch_lifecycle_test.dart
flutter test          # passes except exactly the two phase-0 failures
```

Then run the catalogues, per rule 4: `0041-watcher-teardown.json`, then
`0044-arm-readiness.json`, then `0045-watch-stack.json`. Expected DID NOT APPLY entries,
to re-anchor onto the moved lines: 0041 `p5: a real stderr message is filtered as
startup noise` and `p5: startup noise is forwarded again…`, and 0044 `p2: the marker is
treated as startup noise…`. Any other DID NOT APPLY is re-anchored the same way and
listed in the execution record.

**Acceptance:**

* all new tests pass;
* the full suite is unchanged except for the two known failures;
* every run catalogue reports `0 survived, 0 did not apply`;
* `grep -n '_rearmDebounce\|_isWatcherStartupNoise\|_maxBufferChars' lib/core/git/*.dart`
  prints nothing.

**Commit (code):** the new `lib` files, the modified `lib` files, the new tests, and the
0041, 0044 and 0045 catalogue files. Phase 1 does not modify
`test/watch_shared_path_test.dart`.

**Commit (docs):** this plan's execution record for phase 1.

### Phase 2 — admission replaces sharing and the statics

**Create:**

* **`lib/core/git/watch/admission/host_watcher_budget.dart`** — `final class
  HostWatcherBudget`, process-scoped by injection, never static:
  * `BudgetSlot? tryReserve(String host, {required int capacity})` returns null when
    `liveFor(host) >= capacity`;
  * `int liveFor(String host)`, `int get liveTotal`;
  * `Stream<void> releases(String host)`, broadcast and filtered to that host;
  * `BudgetSlot.release()` is idempotent, credits the host that reserved it, removes the
    host's entry at zero, and announces the release on that host only.
* **`lib/core/git/watch/admission/repo_exclusion.dart`** — `final class RepoExclusion`,
  session-scoped. `Future<ExclusionHold?> acquire(String lockKey, {required Duration
  grace, required Future<void> cancelled})`:
  * while another hold exists for the key, it waits on that hold's `released` future,
    racing it against `cancelled` and against the grace (`Future.any`);
  * on cancellation it returns null;
  * on grace expiry it proceeds (the old race, as today) and reports
    `graceExpired: true` on the hold;
  * it then installs its own hold and returns it.
  * `ExclusionHold.release()` is idempotent, and removes the key only while this hold is
    still the installed one.
* **`lib/core/git/watch/admission/watch_admission.dart`** — `final class WatchAdmission({required
  HostWatcherBudget budget})`, which owns one `RepoExclusion`. `Future<AdmissionResult>
  admit({required String host, required int capacity, required String lockKey, required
  Duration grace, required Future<void> cancelled})` returns a sealed result:
  `Admitted(AdmissionTicket)`, `RefusedCeiling(live, capacity)` or `AdmissionCancelled`.
  **Exclusion is acquired before the budget**, so waiting never holds a slot.
  `AdmissionTicket` exposes `releaseBudget()`, `releaseExclusion()` and `releaseAll()`,
  all idempotent.

**Modify `watch_lifecycle.dart`:** `WatchHooks` gains `final Future<void> cancelled`,
backed by `final cancelSignal = Completer<void>()`, completed in `stop()` immediately
after `cancelled = true`.

**Modify `remote_watch_service.dart`:**

1. Delete `_SharedWatch` and its class doc comment (182 to the end of the class), the
   `_shared` map, and the statics `_liveByHost`, `_slotReleases`, `slotReleases`,
   `slotReleasesForHost`, `liveWatchers`, `liveWatchersFor` and `resetWatcherCount`.
   Delete `sharedTeardownGrace`, whose uses become `WatchTimings.defaultAdmissionGrace`.
2. Add the constructor parameter `WatchAdmission? admission`, stored as `admission ??
   WatchAdmission(budget: HostWatcherBudget())`. A service built without one gets its own
   private budget; production always passes one (step 7 below).
3. `watch()` returns `_createLifecycle(repoPath, …)` directly.
4. Inside the arm, move `final gitDir = spec?.gitDir ?? '$repoPath/.git';` from line 771
   to immediately after the spec is resolved. Replace the ceiling check and
   `_liveByHost` reservation (lines 720–747) with `await admission.admit(host: host,
   capacity: maxConcurrentWatchers, lockKey: gitDir, grace: WatchTimings.defaultAdmissionGrace,
   cancelled: hooks.cancelled)`:
   * `RefusedCeiling` → keep today's diagnostic text and `_record(armFailed, 'ceiling
     $live/$capacity')`, and return `WatchUnavailable(ceiling)`;
   * `AdmissionCancelled` → return `WatchAborted()`;
   * `Admitted(ticket)` → continue.
5. Release per exit path, replacing every `releaseSlot()`:

   | Exit path (anchor at `0d31f51`) | Order |
   | --- | --- |
   | `SSHStreamBudgetExhausted` (859) | `releaseBudget()`, `await releaseHostClaims()` **(new — this path stranded its lease)**, `releaseExclusion()` |
   | cancelled after the stream opened (after 859) | `releaseBudget()`, `await handle.cancel()`, `await releaseHostClaims()`, `releaseExclusion()` |
   | locked refusal (970) | `releaseBudget()`, cancel the handles, `await releaseHostClaims()`, `releaseExclusion()` |
   | no-paths refusal (1006) | `releaseBudget()`, cancel the handles, `await releaseHostClaims()`, `releaseExclusion()` |
   | catch-all (after 1105) | `releaseBudget()`, `await releaseHostClaims()`, `releaseExclusion()`, `rethrow` |
   | `WatchArmed` teardown (1105) | `releaseBudget()` first (wakes ceiling waiters early, as today), cancel the subscriptions and handle, `await releaseHostClaims()`, `releaseExclusion()` **last** |

6. `slotReleased:` becomes `admission.budget.releases(_hostKey())`. `_record`'s
   `liveWatchers` becomes `admission.budget.liveTotal`. `maxConcurrentWatchers` is
   unchanged.
7. **`app_providers.dart`:** add `hostWatcherBudgetProvider = Provider<HostWatcherBudget>((ref)
   => HostWatcherBudget())` and `watchAdmissionProvider = Provider<WatchAdmission>((ref) =>
   WatchAdmission(budget: ref.watch(hostWatcherBudgetProvider)))`.
   `remoteWatchServiceProvider` passes `admission: ref.watch(watchAdmissionProvider)`.
8. **`tabs_controller.dart`:** add the field `final HostWatcherBudget _watcherBudget =
   HostWatcherBudget();`. In `_create`, call `_containerFactory([hostWatcherBudgetProvider
   .overrideWithValue(_watcherBudget), ...overrides])`.

**Migrate the tests (statics → injected admission):**

* In each of these 11 files — `remote_watch_service_test.dart`,
  `watch_arm_signal_test.dart`, `watch_ceiling_derived_test.dart`,
  `watch_ceiling_per_host_test.dart`, `watch_ceiling_recovery_test.dart`,
  `watch_diagnostics_both_backends_test.dart`, `watch_lease_identity_test.dart`,
  `watch_lease_release_test.dart`, `watch_shared_path_test.dart`,
  `watch_slot_leak_test.dart` and `watch_transition_wiring_test.dart`:
  * `setUp(RemoteWatchService.resetWatcherCount)` becomes a per-test `final budget =
    HostWatcherBudget();`;
  * services are built with `admission: WatchAdmission(budget: budget)`;
  * `RemoteWatchService.liveWatchers` becomes `budget.liveTotal`, and
    `liveWatchersFor(h)` becomes `budget.liveFor(h)`;
  * **tests asserting that two services share one ceiling pass the same `budget` to
    both.** Assertion values do not change.
* In `watch_shared_path_test.dart` (contract changes recorded in MADR 0045 section 2):

  | Existing test | Phase 2 |
  | --- | --- |
  | `two concurrent watchers of one path arm exactly once` | Replaced by `two concurrent watch() calls on one path never hold the lock together`: the log is `['arm', 'teardown', 'arm']` once the first is cancelled, and never two live handles |
  | `both subscribers receive the same events` | Moved to the new provider test |
  | `a late subscriber gets the current state without waiting` | Moved to the new provider test |
  | `the watcher survives one subscriber leaving` | Moved to the new provider test |
  | `the last subscriber leaving tears the watcher down` | Kept (service level) |
  | `two different paths still get two watchers` | Kept |
  | `two services on one path arm twice — sharing is per connection` | Kept; its reason text now cites separate exclusions |
  | `a stream that is never listened to arms nothing` | Kept |
  | `a rebuilt caller re-arms after the last subscriber left` | Kept |
  | `a new subscriber waits for a pending teardown before arming` | Kept, assertions unchanged |
  | A, B, C (deviation (c)) | Kept, assertions unchanged; C's `RemoteWatchService.sharedTeardownGrace` becomes `WatchTimings.defaultAdmissionGrace` |
  | *(new)* `a rebuild with new parameters arms the new surface` | Recursive `watch`, then in the same flush cancel it and `watch(bounded: …)`; the arms are `[recursive, bounded]` and one handle is live |

**Create tests:**

* `test/host_watcher_budget_test.dart`:
  * `reserve refuses at capacity`;
  * `release credits the reserving host`;
  * `a release is announced on its own host only`;
  * `release is idempotent`;
  * `the host entry empties at zero`.
* `test/repo_exclusion_test.dart` (fakeAsync):
  * `a second acquire waits for the first release`;
  * `a cancelled wait returns null and installs nothing`;
  * `the grace expiry proceeds and says so`;
  * `a stale release does not remove a newer hold`;
  * `different keys never wait on each other`.
* `test/watch_admission_test.dart`:
  * `exclusion is acquired before the budget`;
  * `a ceiling refusal installs no hold`;
  * `releaseAll is idempotent`.
* `test/repo_watch_provider_sharing_test.dart` — a `ProviderContainer` overriding
  `remoteWatchServiceProvider` with a service over a recording executor:
  * `two listeners on one repository arm one watcher`;
  * `both listeners receive the same events`;
  * `a late listener gets the current mode immediately`;
  * `one listener leaving keeps the watcher`;
  * `the last listener leaving tears the watcher down`.
* `test/tab_watcher_budget_injection_test.dart` — `TabsController` with a recording
  container factory: `every tab container reads the same host budget`.

**Catalogue changes:**

| Catalogue | Entry | Action |
| --- | --- | --- |
| 0039 | `f4: the ceiling counts every host together again` | Re-anchor onto `HostWatcherBudget` host keying |
| 0039 | `f4: a released slot is announced to every host` | Re-anchor onto `releases(host)` filtering |
| 0039 | `f4: the release credits the current host, not the reserving one` | Re-anchor onto `BudgetSlot.release` |
| 0040 | both `p1` entries | Re-anchor onto the catch-all's `releaseBudget()` |
| 0041 | `p4: each service instance gets its own budget (per-session keying)` | Re-anchor: `tabs_controller.dart` stops injecting the shared budget; killed by `tab_watcher_budget_injection_test.dart` and `watch_ceiling_recovery_test.dart` |
| 0043 | `p1: sharing removed — every watch() builds its own watcher` | **Retire.** Sharing is Riverpod's (MADR 0045 section 1). Replaced by the 0045 entry `p2: the facade family key includes a per-listen nonce` in phase 5, and in the interim by `p2: exclusion does not wait for a predecessor` |
| 0043 | `p1: the watcher is built eagerly, not on the first subscriber` | Re-anchor: arming in `watch()` before listen; killed by `a stream that is never listened to arms nothing` |
| 0043 | `p1: the last event is not replayed to a late subscriber` | **Retire.** Replay is Riverpod's `AsyncValue`, not our code; `a late listener gets the current mode immediately` stays as the check |
| 0043 | `p1: the shared map is static, so two tabs share one watcher` | Re-anchor: the `RepoExclusion` map made static; killed by `two services on one path arm twice` |
| 0043 | `p1: the factory is not refreshed, so a rebuild keeps a stale closure` | **Retire.** There is no factory. Replaced by the 0045 entry `p2: the lifecycle ignores the bounded parameter` |
| 0043 | `p2: a new arm does not wait for a pending teardown` | Re-anchor onto `RepoExclusion.acquire` |
| 0044 | `p2: a refused arm keeps its slot` | Re-anchor onto the locked refusal's `releaseBudget()` |

**Add to 0045:**

| Label | Killed by |
| --- | --- |
| `p2: exclusion does not wait for a predecessor` | `a new subscriber waits for a pending teardown before arming`, A, B |
| `p2: a cancelled exclusion wait still installs a hold` | A, `repo_exclusion_test.dart` |
| `p2: exclusion is released before the host claims` | `a new subscriber waits for a pending teardown before arming` |
| `p2: the stream-budget path strands its lease` | a new test in `watch_lease_release_test.dart`: `a stream-budget refusal gives back the lease it stamped` |
| `p2: the admission grace is unbounded` | C |
| `p2: the lifecycle ignores the bounded parameter` | `a rebuild with new parameters arms the new surface` |

**Verify:**

```sh
flutter analyze
dart format --output=none --set-exit-if-changed <every staged .dart file>
flutter test test/host_watcher_budget_test.dart test/repo_exclusion_test.dart \
  test/watch_admission_test.dart test/repo_watch_provider_sharing_test.dart \
  test/tab_watcher_budget_injection_test.dart
flutter test <the 11 migrated files>
flutter test          # zero failures: A and B now pass
```

Then the catalogues, one at a time: `0039`, `0040`, `0041`, `0043`, `0044`, `0045`.

**Acceptance:**

* the full suite passes with no failures;
* `grep -rn '_SharedWatch\|_liveByHost\|_slotReleases\|resetWatcherCount\|sharedTeardownGrace' lib`
  prints nothing;
* every catalogue reports `0 survived, 0 did not apply`;
* retirements are exactly the three listed.

**Commit (code):** includes the migrated `test/watch_shared_path_test.dart`, which makes A
and B pass and ends the two-failure state on `master`.

**Commit (docs):** the phase 2 record, including the retirement table as executed.

### Phase 3 — the source seam and lock-key resolution

**Create:**

* **`lib/core/git/watch/source/watch_source.dart`:**
  * `final class ArmRequest(repoPath, bounded, cancelled, attempt)`;
  * `sealed class SourceArm` with `SourceArmed(ArmedSource)`,
    `SourceUnavailable(WatchUnavailableReason)` and `SourceAborted`;
  * `abstract interface class ArmedSource { Stream<SourceSignal> get signals; Future<void>
    close(); }`;
  * `sealed class SourceSignal` with `PathChanged(path)`, `SourceActivity`,
    `RearmRequested` and `SourceDied(cause)`;
  * `abstract interface class WatchSource { Future<SourceArm> arm(ArmRequest request); }`.
* **`lib/core/git/watch/source/lifecycle_adapter.dart`** *(temporary; deleted in
  phase 4)*: `Future<WatchArm> Function(WatchHooks) armFromSource(WatchSource source, {required
  String repoPath, BoundedWatchSpecSource? bounded, required int Function() attempt})`.
  It maps signals to hooks — `PathChanged` → `signalPath`, `SourceActivity` →
  `noteActivity`, `RearmRequested` → `rearm`, `SourceDied` → `scheduleRestart` — and
  `SourceArmed` → `WatchArmed(source.close)`.
* **`lib/core/git/watch/source/remote/git_dir_resolver.dart`:** `typedef GitDirResolver
  = Future<String> Function(String repoPath)`, and `GitDirResolver
  gitDirResolverFor(CommandExecutor executor)`, which returns
  `(await resolveRepoLayout(executor, repoPath)).gitDir`.
* **`lib/core/git/watch/source/remote/watcher_tool_probe.dart`:**
  `WatcherToolProbe(CommandExecutor)`. `Future<RemoteWatcherTool> tool(String repoPath)`
  holds the cached value and runs `_detectWatcher`'s command and parsing; `void
  invalidate()`.
* **`lib/core/git/watch/source/remote/watch_lease.dart`:** `WatchLease({required executor,
  required repoPath, required gitDir, required token, required WatchTimings timings})`.
  * `pidFile` and `heartbeatFile` getters;
  * `Future<void> stamp()` **throws `WatchLeaseException` (with the command's stderr)** if
    the `touch` fails;
  * `void startHeartbeat()` and `void stopHeartbeat()` (best-effort, as today);
  * `Future<void> releaseHostClaims()` (best-effort, `releaseTimeout`, token-guarded
    `watchLockReleaseScript`).
* **`lib/core/git/watch/source/remote/watcher_process.dart`:** `WatcherProcess.open(...)`
  holds `executeStream`, mapping `SSHStreamBudgetExhausted` to
  `SourceUnavailable(streamBudget)`. It wires stderr through `StderrLineReader` before
  the race; runs the readiness race and refusal decoding (98 → `heldByAnother` with the
  incumbent; 97 on a bounded surface → `noWatchedPaths`); wires stdout through
  `RecordSplitter` to the relativize-and-filter step; and has `close()` in today's order.
* **`lib/core/git/watch/source/remote/remote_watch_source.dart`:**
  `RemoteWatchSource implements WatchSource`, composed of the probe, the resolver, the
  admission, `WatchLease`, `WatcherProcess` and `SurfaceRearmPolicy`. Its order is: tool
  (unavailable if none) → spec → **lock key = `spec?.gitDir ?? await gitDirOf(repoPath)`**
  (cached per source per repository, invalidated with the tool cache) → `admit` → lease
  `stamp` → `WatcherProcess.open` → `SourceArmed`. The phase-2 release table applies to
  every exit.
* **`lib/core/git/watch/source/local/directory_watch_source.dart`:**
  `DirectoryWatchSource implements WatchSource`. It moves `_WatchRoot`, `_rootsFor`,
  `_boundedRoots` and the `Directory.watch` listener body, with move destinations, from
  `local_watch_service.dart`, and uses `SurfaceRearmPolicy`.

**Modify:**

* **`git_service.dart`:** extract `_resolveRepoLayout`, `_parseRepoLayoutLines` and
  `_legacyRepoLayoutScript` into the top-level `Future<RepoLayout>
  resolveRepoLayout(CommandExecutor executor, String repoPath, {Map<String, String>?
  extraEnv, int retries = 0})` in the same file. `GitService.repoLayout` delegates to it,
  passing `_readRetries` and `_scopeEnvFor(repoPath)`. Behaviour is identical.
* **`remote_watch_service.dart`:** the constructor gains `required GitDirResolver
  gitDirOf`; the arm becomes `armFromSource(RemoteWatchSource(...))`; delete
  `_detectWatcher`, `cachedTool`, `beat`, `releaseHostClaims` and the listeners, which now
  live in their units.
* **`local_watch_service.dart`:** the arm becomes `armFromSource(DirectoryWatchSource(...))`.
* **`app_providers.dart`:**
  * `remoteWatchServiceProvider` passes `gitDirOf: gitDirResolverFor(ref.watch(executorProvider))`;
  * `_sweepStaleWatchers` builds `repos` by resolving each non-scoped path through the same
    resolver, sequentially, skipping (and logging through `onDiagnostic`) any path whose
    resolution throws.
* **Every `RemoteWatchService(` in the 12 test files, including `connect_paths_test.dart`,**
  passes `gitDirOf: conventionalGitDir` from the new `test/helpers/conventional_git_dir.dart`
  (`Future<String> conventionalGitDir(String repoPath) async => '$repoPath/.git';`).

**Create tests:**

* `test/git_dir_resolver_test.dart`:
  * `a linked worktree resolves to its own git dir`;
  * `the legacy fallback is used when --path-format is rejected`;
  * `a failed resolution throws`.
* `test/watcher_tool_probe_test.dart`:
  * `the tool is probed once`;
  * `invalidate probes again`;
  * `a failed probe throws rather than caching none`.
* `test/watch_lease_test.dart`:
  * `the paths live in the resolved git dir`;
  * `a failed stamp throws with the host's reason`;
  * `releasing is token-guarded and best-effort`.
* `test/watcher_process_test.dart`:
  * `the marker settles the arm`;
  * `98 is heldByAnother and names the incumbent`;
  * `97 on a bounded surface is noWatchedPaths`;
  * `97 on a recursive surface is not a refusal`;
  * `stream-budget exhaustion is unavailable, not thrown`.
* `test/remote_watch_source_test.dart`:
  * `a linked worktree is locked by its resolved git dir`;
  * `a scoped repository is locked by its spec's git dir`;
  * `a lease that cannot be stamped fails the arm without opening a stream`.
* `test/directory_watch_source_test.dart` — the three tests from
  `local_watch_worktree_test.dart`, run against the source.
* **`test/worktree_lock_key_exec_test.dart`, tagged `integration`.** Using real `git` and
  `sh`, it makes a temporary repository and a linked worktree, and gets the expected git
  dir with `git -C <wt> rev-parse --absolute-git-dir`. It builds `recursiveWatchScript` with
  that git dir, stamps the heartbeat, and runs `sh -c` with a shim `inotifywait`
  (following the pattern in `watch_lease_teardown_exec_test.dart`). Two tests:
  * `a worktree armed with its resolved git dir holds a live watcher` — the marker is on
    stderr, the process is alive, and the lock dir exists under the resolved git dir;
  * `a worktree armed with the conventional key is refused` — exit 98, no marker.

  **Teardown closes stdin** (the stdin-EOF watchdog removes the tree), awaits exit, and
  then calls `kill()` on the test's own `Process` objects. No `pkill`.

**Catalogues:**

* **Expected DID NOT APPLY entries**, re-anchored onto the unit each behaviour moved to:
  0041 `p2` (3) → `watch_lease.dart`; 0041 `p3` (3) → `watcher_process.dart`; 0041 `p5`
  `--exclude` and `@`-path entries stay in `remote_watch_service.dart` (`remoteWatcherArgs`
  does not move); 0043 `p2: teardown does not give the lock back` → `watch_lease.dart`;
  0043 `p3` → `remote_watch_source.dart`; the 0044 `p2` entries (7) →
  `watcher_process.dart` or `remote_watch_source.dart`.
* **Add to 0045:**

  | Label | Killed by |
  | --- | --- |
  | `p3: the lock key ignores the resolver` | `remote_watch_source_test.dart` |
  | `p3: a failed stamp is swallowed` | `watch_lease_test.dart`, `remote_watch_source_test.dart` |
  | `p3: the probe cache survives recovery` | `a failed watcher probe retries instead of caching "none"` |
  | `p3: the sweep keys by the conventional path` | a new `connect_paths_test.dart` test, `the connect-time sweep keys a worktree by its resolved git dir` |

**Verify:**

```sh
flutter analyze
dart format --output=none --set-exit-if-changed <every staged .dart file>
flutter test test/git_dir_resolver_test.dart test/watcher_tool_probe_test.dart \
  test/watch_lease_test.dart test/watcher_process_test.dart \
  test/remote_watch_source_test.dart test/directory_watch_source_test.dart
flutter test test/worktree_lock_key_exec_test.dart
flutter test
```

Then the catalogues, one at a time: `0041`, `0043`, `0044`, `0045`.

**Acceptance:**

* the full suite passes;
* the worktree executing test passes, with both of its tests seen;
* `remote_watch_service.dart` contains no `_detectWatcher`, `beat(` or
  `releaseHostClaims(` definitions;
* every catalogue reports `0 survived, 0 did not apply`.

**Commits:** code, then docs.

### Phase 4 — one engine replaces `watchLifecycle`

**Create:**

* **`lib/core/git/watch/engine/engine_event.dart`:** a sealed `EngineEvent`, each variant
  carrying `attempt` where it applies:
  * `Start`;
  * `ArmResolved(attempt, SourceArm)`;
  * `ArmThrew(attempt, error)`;
  * `Signalled(attempt, SourceSignal)`;
  * `RestartDue(attempt)`;
  * `PollDue`;
  * `RecoveryDue`;
  * `BudgetReleased`;
  * `Cancel`.
* **`lib/core/git/watch/engine/engine_state.dart`:** a sealed `EngineState` —
  `Idle`, `Arming(attempt, rearmPending)`, `Armed(attempt, ArmedSource)`,
  `BackingOff(attempt)`, `Polling(reason)`, `Stopped`.
* **`lib/core/git/watch/engine/watch_engine.dart`:** `final class WatchEngine({required
  WatchSource source, required String repoPath, BoundedWatchSpecSource? bounded,
  WatchTimings timings = WatchTimings.standard, WatchTransitionSink? onTransition,
  Stream<void>? budgetReleased})`, with `Stream<RepoWatchEvent> get events`. Rules:
  1. **A mailbox:** a `Queue<EngineEvent>` and `_drain()` with a reentrancy guard; every
     state change happens inside `_handle(event)`, synchronously.
  2. **Effects are asynchronous and post back tagged.** Arming calls `source.arm(ArmRequest(…,
     attempt: _attempt))`, and the result is posted as `ArmResolved` or `ArmThrew` carrying
     that attempt.
  3. **A stale event** (its `attempt` is not the current `_attempt`) is dropped; if it
     carries a `SourceArmed`, that source's `close()` is called first. Nothing else about a
     stale event is processed.
  4. **Behaviour preserved exactly from `watchLifecycle`:**
     * an arm emits one `eventDriven` tick;
     * `SourceUnavailable` leads to `Polling`, with a poll tick every `pollInterval` and a
       recovery every `recoveryInterval`;
     * a death leads to `BackingOff` with `restarts * restartBackoffStep`, emits a
       `stopped` tick, and degrades to `Polling` once `maxRestarts` is spent;
     * activity resets `restarts`;
     * re-arming spends no budget, emits no `stopped`, and collapses to at most one pending
       re-arm while arming;
     * `BudgetReleased` wakes only `Polling(ceiling)`;
     * more than `maxPathsPerTick` paths overflow to an unscoped tick;
     * `Cancel` completes the cancellation future, cancels every timer, closes the current
       source (and any later `SourceArmed` via rule 3), records `stopped`, and closes the
       stream.
  5. **Every transition** that `watchLifecycle` reports through `onTransition` is reported
     with the same kind and cause text, in the same order.

**Modify:**

* **`remote_watch_service.dart` and `local_watch_service.dart`:** `watch()` returns
  `WatchEngine(source: …, repoPath: …, bounded: …, timings: …, onTransition: …,
  budgetReleased: …).events`.
* Move `WatchUnavailableReason` into `source/watch_source.dart` and update its imports.
* **Delete** `lib/core/git/watch_lifecycle.dart`, `source/lifecycle_adapter.dart` and
  `test/watch_lifecycle_test.dart` — the last only after step 4.1 has passed.

**Tests:**

4.1 **`test/watch_engine_test.dart`.** Port the nine tests of `watch_lifecycle_test.dart`,
with identical names and assertions. Replace the `fastLifecycle` helper with a
`fastEngine({required Future<SourceArm> Function(ArmRequest) arm, int maxRestarts = 3})`
that builds a `WatchEngine` over the new `test/helpers/function_watch_source.dart` with
`WatchTimings.forTest()` durations equal to the helper's current values. Add:

* `an arm result from a superseded attempt is closed, not adopted`;
* `a source arriving after cancel is closed`;
* `many re-arms while arming collapse into a single follow-up` (ported from
  `watch_transition_wiring_test.dart`);
* `overlapping starts tear down every armed source` (ported likewise);
* `a budget release wakes only a ceiling refusal`.

4.2 **`test/watch_transition_wiring_test.dart`:** replace `watchLifecycle(` and
`WatchHooks` with the engine and `FunctionWatchSource`, assertions unchanged.

**Catalogue — add to 0045:**

| Label | Killed by |
| --- | --- |
| `p4: a stale arm result is adopted` | `an arm result from a superseded attempt is closed, not adopted` |
| `p4: a source arriving after cancel is left open` | `a source arriving after cancel is closed` |
| `p4: a re-arm spends the restart budget` | `watch_engine_test.dart`, `surface_rearm_policy_test.dart` |
| `p4: a budget release wakes every refusal` | `a budget release wakes only a ceiling refusal`, `a refusal that is NOT the ceiling is not woken by a slot release` |
| `p4: path overflow is ignored` | `path overflow at maxPaths emits empty paths set` |

**Verify:**

```sh
flutter analyze
dart format --output=none --set-exit-if-changed <every staged .dart file>
flutter test test/watch_engine_test.dart test/watch_transition_wiring_test.dart \
  test/remote_watch_service_test.dart test/local_watch_service_test.dart
flutter test
```

Then the catalogues, one at a time: `0041`, `0043`, `0044`, `0045`.

**Acceptance:**

* `grep -rn 'watchLifecycle\|WatchHooks\|WatchArmed(' lib test` prints nothing;
* all nine ported names exist in `watch_engine_test.dart` and pass;
* the full suite passes;
* every catalogue reports `0 survived, 0 did not apply`.

**Commits:** code, then docs.

### Phase 5 — identity in Riverpod, behind the unchanged facade

**Create `lib/core/git/watch/watch_runtime.dart`:** `final class WatchRuntime({required
RemoteWatchService remote, required LocalWatchService local, required Future<List<String>>
Function(String repoPath) listTrackedFiles, required String sessionId})`, with
`Stream<RepoWatchEvent> watch(WatchTarget target)` and `Future<void>
sweepStaleWatchers(...)`.

* `watch()` picks the service by `target.backend`.
* For a `BoundedSurface` it builds the bounded supplier from `listTrackedFiles` and
  `computeBoundedWatchSpec`, including today's degrade-on-error behaviour from
  `repoWatchProvider` (an empty tracked list, logged).

**Modify `app_providers.dart`:**

1. Add `watchTargetProvider = Provider.autoDispose.family<WatchTarget, String>`, built from
   `connectionProvider.select(backend)` and `connectionProvider.select(scopedGitDirFor(repoPath))`.
2. Add `watchRuntimeProvider = Provider<WatchRuntime>`, wrapping the existing service
   providers, `gitServiceProvider.listTrackedFiles` and `sessionScopeProvider.id`.
3. Add `watcherProvider = StreamProvider.autoDispose.family<RepoWatchEvent, WatchTarget>((ref,
   target) => ref.watch(watchRuntimeProvider).watch(target), retry: noProviderRetry)`.
4. **Rewrite the body of `repoWatchProvider`, keeping its declaration:**
   * `final target = ref.watch(watchTargetProvider(repoPath));`
   * a facade-owned `StreamController<RepoWatchEvent>.broadcast()`, closed through
     `ref.onDispose` (annotated `// ignore: close_sinks` with the reason);
   * `ref.listen(watcherProvider(target), (_, next) { final v = next.value; if (v != null
     && !controller.isClosed) controller.add(v); }, fireImmediately: true);`
   * return `_withoutIgnoredPaths(oracle, repoPath, controller.stream)`.
5. `_sweepStaleWatchers` calls `ref.read(watchRuntimeProvider).sweepStaleWatchers(...)`.

**Test first — this confirms MADR 0045's unrun claim before anything depends on it.**
`test/repo_watch_facade_test.dart`:

* `invalidating the facade keeps an unchanged target's watcher` — after
  `container.invalidate(repoWatchProvider)` and a settle, the arm count is still 1 and no
  teardown has been recorded;
* `a changed scoped git dir replaces the watcher` — the first is torn down, and the second
  arms on the bounded surface;
* `the facade's events are the watcher's events, filtered`;
* `an override of repoWatchProvider still replaces the whole chain`.

**If the first test fails**, the claim in MADR 0045 section 1 is contradicted. That is a
deviation: stop, and prompt with the evidence.

**Catalogue — add to 0045:**

| Label | Killed by |
| --- | --- |
| `p5: the facade family key includes a per-listen nonce` | `invalidating the facade keeps an unchanged target's watcher` |
| `p5: the target ignores the scoped git dir` | `a changed scoped git dir replaces the watcher` |
| `p5: the facade forwards unfiltered events` | `the facade's events are the watcher's events, filtered` |

**Verify:**

```sh
flutter analyze
dart format --output=none --set-exit-if-changed <every staged .dart file>
flutter test test/repo_watch_facade_test.dart test/repo_watch_provider_sharing_test.dart
flutter test <the 23 repoWatchProvider test files listed under Grounding>
flutter test
```

Then the catalogues, one at a time: `0039`, `0041`, `0043`, `0044`, `0045`.

**Acceptance:**

* the facade tests pass;
* the 23 provider-consuming test files pass unmodified;
* the full suite passes;
* every catalogue reports `0 survived, 0 did not apply`.

**Commits:** code, then docs.

### Phase 6 — identity on records, tests without sleeps, structural guards

**Modify:**

* **`watch_diagnostics.dart`:**
  * `WatchTransitionRecord` gains `final WatcherId? watcher`, and `toString` appends
    ` watcher=<id>` when it is present;
  * `degradationSummary` appends ` watcher <id>` when the degradation record carries one;
  * `WatchDiagnostics.forRepo` is unchanged.
* **Engine and sources:** attach `WatcherId(sessionId, repoPath, attempt, token)` to every
  record they produce (the token on remote arms only). `sessionId` reaches the services
  from `WatchRuntime`.
* **Move logic tests onto `fakeAsync`.** Replace every `settleArm()`, `Future.delayed` and
  `Future<void>.delayed` in these files with `fakeAsync` and `async.elapse`/`flushMicrotasks`,
  keeping every assertion value:
  * `remote_watch_service_test.dart`, `watch_arm_signal_test.dart`,
    `watch_ceiling_derived_test.dart`, `watch_ceiling_per_host_test.dart`,
    `watch_ceiling_recovery_test.dart`, the remote half of
    `watch_diagnostics_both_backends_test.dart`, `watch_lease_identity_test.dart`,
    `watch_lease_release_test.dart`, `watch_shared_path_test.dart` and
    `watch_transition_wiring_test.dart`.
  * Elapsed-time assertions in `watch_arm_signal_test.dart` (`lessThan(250 ms)` and
    `>= armSignalCeiling`) use fake elapsed time.
  * Delete `test/helpers/watch_settle.dart`.
* **Allow-listed, keeping real time** because they drive real processes or real
  filesystem events: `watch_lease_teardown_exec_test.dart`, `watcher_sweep_exec_test.dart`,
  `worktree_lock_key_exec_test.dart`, `local_watch_bounded_test.dart`,
  `local_watch_service_test.dart`, `local_watch_worktree_test.dart`,
  `directory_watch_source_test.dart`, and the local half of
  `watch_diagnostics_both_backends_test.dart`.

**Create `test/watch_stack_structure_test.dart`:**

* `no mutable static in the watch stack` — scans `lib/core/git/watch/**`,
  `remote_watch_service.dart`, `local_watch_service.dart`, `bounded_watch.dart` and
  `watch_diagnostics.dart` with
  `^\s*static\s+(?!const\b)(?:final\s+|late\s+|var\s+)?[\w<>?, ]+\s+\w+\s*(=|;)`, and
  expects no matches.
* `the retired machinery is gone` — none of `watchLifecycle(`, `_SharedWatch`,
  `_liveByHost`, `resetWatcherCount`, `sharedTeardownGrace`, `_detectWatcher` appears in
  `lib`.
* `watcher logic tests do not sleep` — no `settleArm(`, `Future.delayed`,
  `Future<void>.delayed` or `sleep(` in `test/*watch*_test.dart` outside the allow-list
  above, with one written reason per allow-list entry.
* The top-level `watchDiagnostics` is outside the scan by construction (it is not
  `static`). It is recorded in the test's header as retained by MADR 0045 section 6.

**Seen to fail:** each of the three guard tests is run against a scratch copy of the
tree in a temp directory with one violation injected — a `static var` in a watch file,
`_liveByHost` restored, a `settleArm()` added to a logic test. The failure output is
recorded in the execution record.

**Catalogue:** run every watcher catalogue, one at a time — `0039`, `0040`, `0041`,
`0043`, `0044`, `0045` — and add to 0045:

| Label | Killed by |
| --- | --- |
| `p6: records lose the watcher id` | `watch_diagnostics_test.dart`, `watch_transition_wiring_test.dart` |
| `p6: the summary drops the watcher id` | `watch_diagnostics_test.dart` |

**Verify:**

```sh
flutter analyze
dart format --output=none --set-exit-if-changed <every staged .dart file>
flutter test test/watch_stack_structure_test.dart test/watch_diagnostics_test.dart
flutter test <every file in the fakeAsync migration list>
flutter test
```

Then the catalogues, one at a time.

**Acceptance:**

* the guard tests pass, and each has been seen to fail;
* the watcher logic tests contain no real-time waits outside the allow-list;
* the full suite passes;
* every catalogue reports `0 survived, 0 did not apply`.

**Commits:** code, then docs.

### Phase 7 — host verification with the maintainer, then close the records

7.1 Run `./build_macos.sh --unsigned --install`. The maintainer quits and reopens the app.
Check that the installed `CFBundleShortVersionString` matches `git describe --tags` at
`HEAD`.

7.2 **Registry census** (read-only, over SSH) with one remote tab active: exactly one
watcher, one lock, one pid file and one heartbeat per armed repository, and no
`mg-watch: armed` in any file.

7.3 **Reconnect.** Start the bounded host-side sampler (the 25-minute registry sampler
from MADR 0044's plan, read-only). The maintainer disconnects and reconnects the remote
tab from the switcher. The sampler must show each armed repository torn down once and
re-armed once. Five minutes after reconnecting, every heartbeat must have a pid file
beside it, and every lock a live watcher.

7.4 **The foreign-lock refusal still refuses** — a repeat of MADR 0044's 4.4(b), the
only step that writes to a host. Stage a foreign lock on a background repository using
exact paths (`mkdir <gitDir>/mg-watch.lock`, write a foreign token, `touch` the foreign
heartbeat). Refresh that heartbeat from a background task that `TaskStop` stops. The
maintainer opens the tab. The Output pane must show `heldByAnother` naming the foreign
token with `restarts spent 0`, and there must be no stranded heartbeat. Clean up by exact
path: `rm -rf <gitDir>/mg-watch.lock` and `rm -f <gitDir>/mg-watch.<foreign>.hb`.

7.5 **A remote linked worktree arms live.** The maintainer opens a detached window on a
remote linked worktree from the Worktrees page. The host must show the lock under
`<gitCommonDir>/worktrees/<name>/mg-watch.lock` and a watcher whose working directory is
the worktree, and the Output pane must show no `heldByAnother`. **If no remote linked
worktree exists, creating one is a write to the host: ask first.**

7.6 **MADR 0044 step 4.3.** With the sampler running, the maintainer switches between two
remote tabs six times. Report each heartbeat-to-lock interval and the median against
0044's 250 ms acceptance.

7.7 **Docs:**

* MADR 0045 → `status: accepted`, with today's `verified:`;
* this plan → `status: complete`, with the full execution record;
* MADR 0044's plan → 4.3 result, `status: complete`;
* MADR 0044 amendment 0044.3 → a closing sentence;
* the README rows for 0043, 0044 and 0045.

Commit (docs).

## Verification

The whole-plan gate:

```sh
flutter --version | head -1                       # Flutter 3.47.2
flutter analyze                                   # No issues found
flutter test                                      # all pass
flutter test test/worktree_lock_key_exec_test.dart
flutter test test/watch_stack_structure_test.dart
tool/mutate.py tool/mutations/0039-globals-and-heuristics.json
tool/mutate.py tool/mutations/0040-watcher-ceiling.json
tool/mutate.py tool/mutations/0041-watcher-teardown.json
tool/mutate.py tool/mutations/0043-one-watcher-per-repo.json
tool/mutate.py tool/mutations/0044-arm-readiness.json
tool/mutate.py tool/mutations/0045-watch-stack.json
```

Each catalogue must end `N killed, 0 survived, 0 did not apply`, run one at a time.

## Acceptance Criteria

1. `_SharedWatch`, `_liveByHost`, `_slotReleases`, `resetWatcherCount`,
   `sharedTeardownGrace`, `watchLifecycle` and `_detectWatcher` do not exist in `lib`.
   Enforced by `watch_stack_structure_test.dart`.
2. There is no mutable `static` in the watch stack, enforced by the same test.
3. The deviation (c) tests A, B and C, and `a rebuild with new parameters arms the new
   surface`, pass.
4. `worktree_lock_key_exec_test.dart` passes: the resolved key arms, and the conventional
   key exits 98.
5. `invalidating the facade keeps an unchanged target's watcher` passes.
6. The nine ported engine tests pass with unchanged assertions, and the stale-attempt
   tests pass.
7. Watcher logic tests contain no real-time waits outside the written allow-list.
8. Every watcher catalogue reports 0 survived and 0 did not apply. Retirements are
   exactly the three in phase 2, each replaced as listed.
9. The full suite passes, `flutter analyze` is clean, and every committed Dart file is
   formatted.
10. On the host, steps 7.2–7.5 pass as specified and 7.6's median is reported against
    0044's 250 ms.
11. The document statuses and README rows are updated as in 7.7.

## Rollout and Rollback

Each phase is one code commit and one docs commit, and each code commit leaves the suite
green. **The phases stack**: 2 needs 1, 3 needs 2's admission, 4 needs 3's source seam,
5 needs 4's engine, and 6 needs 5's runtime.

Rollback reverts code commits newest-first (`git revert --no-edit <sha>`, one per phase,
from the newest phase down to the target). It never resets and never rewrites history.
Because the host protocol is unchanged, **a rollback needs no host clean-up**: leases
left by a rolled-back build are reclaimed by the connect-time sweep, exactly as today.

Nothing is pushed unless the maintainer asks in that same turn.

## Decisions taken while planning

These refine MADR 0045 without changing its decision. Each is recorded so the plan and the
record agree.

* **(a) `ArmRequest(repoPath, bounded, cancelled, attempt)` is the source input** until
  phase 5 builds requests from a `WatchTarget`. That lets the source seam land (phase 3)
  before target identity (phase 5) without migrating callers twice.
* **(b) The facade forwards through `ref.listen(…, fireImmediately: true)`** into a
  controller it owns, because `StreamProvider.stream` is deprecated in Riverpod 3.3.2.
  Its family key and type stay unchanged, because 14 test files and the pop-out window
  override it.
* **(c) `RemoteWatchService` and `LocalWatchService` stay as the per-backend engine
  factories** that `WatchRuntime` uses; they stop being the providers' public API. This
  spares 16 test files a second constructor migration. "Retired" in MADR 0045 means
  retired as providers.
* **(d) `GitDirResolver` is a required constructor parameter,** with no production
  default. Tests pass `conventionalGitDir` explicitly, so nothing can silently reintroduce
  F10's `'$repoPath/.git'` key.
* **(e) Every arm exit releases the budget first and the exclusion last, after host
  claims.** This includes the stream-budget path, which today strands the lease it
  stamped.
* **(f) `WatchTimings` exposes `static const` defaults and a `const` constructor;
  coherence is a method.** Comparing `Duration`s is not a constant expression, so the
  rules live in `coherenceErrors()`, which a test enforces.
* **(g) The top-level `watchDiagnostics` instance is kept.** MADR 0045 section 6 adds
  identity to records rather than re-keying the store; the guard test states it.

## Risks

* **A lease stamp that now fails loudly (phase 3)** could contradict a test that encodes
  today's silent stamp. If one exists, that is a deviation, to be settled before proceeding.
* **The Riverpod listener-regain claim (phase 5)** is confirmed by the phase's first test.
  A failure is a deviation.
* **The facade's `fireImmediately` forwarding** could change when the first event reaches
  consumers. `repo_status_watch_refresh_test.dart` and the 23 provider-consuming files are
  the check.
* **Moving logic tests to `fakeAsync` (phase 6)** could hide an ordering the real event loop
  exercised. The executing and filesystem tests stay allow-listed, and the catalogues run
  after the move.
* **About 45 mutation entries change anchor over four phases.** Rule 4 treats every
  DID NOT APPLY as work, not as a pass.
* **The worktree git-state gap** (see Out) is a known limitation that this plan makes
  visible rather than fixes.
