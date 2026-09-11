---
status: "in-progress"
date: 2026-09-11
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
   * *(Added 2026-09-10, deviations (a)–(c) in the execution record.)*
     - `tool/mutate.py` enforces the baseline itself: `BASELINE RED` stops the run.
     - A failed run is a kill only when a named test failed. **DOES NOT COMPILE** and
       **OBSERVED BY NO TEST** are broken entries, fixed like a DID NOT APPLY.
     - At each phase boundary, before any catalogue runs, `tool/mutate.py --check` on the
       catalogues that phase runs must report every entry sound.
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
`test/watch_shared_path_test.dart`. *(Deviation (a), 2026-09-10: plus `tool/mutate.py` —
see the execution record.)*

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
   *(Deviation (d), 2026-09-10: also `_withoutIgnoredPaths` becomes a `Stream.asyncMap`,
   so leaving the provider reaches the watcher; plus `watch_diagnostics.dart`'s doc
   comment, `test/repo_watch_ignore_filter_test.dart`, a re-listen test in
   `repo_watch_provider_sharing_test.dart`, and one 0045 catalogue entry.)*
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
  | `the last subscriber leaving tears the watcher down` | Kept (service level) *(deviation (d): kept, but its `exec.handles.single` cannot hold without sharing — the assertions become every handle cancelled, never two live, and the budget back to zero)* |
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
| `p2: exclusion is released before the host claims` | `a new subscriber waits for a pending teardown before arming` *(deviation (e): that test cannot observe the order and the entry survived; killed by `the next watcher waits for the host claims, not just the channel`)* |
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
  `local_watch_worktree_test.dart`, run against the source. *(Deviation (g), 2026-09-10:
  that file has five tests, and had five at `6c25baa`; all five are ported.)*
* **`test/worktree_lock_key_exec_test.dart`, tagged `integration`.** Using real `git` and
  `sh`, it makes a temporary repository and a linked worktree, and gets the expected git
  dir with `git -C <wt> rev-parse --absolute-git-dir`. It builds `recursiveWatchScript` with
  that git dir, stamps the heartbeat, and runs `sh -c` with a shim `inotifywait`
  (following the pattern in `watch_lease_teardown_exec_test.dart`). *(Deviation (f),
  2026-09-10: that pattern called `pkill`; it is replaced first, and this test uses the
  replacement — the shim records its own PID, and only recorded PIDs are killed.)* Two
  tests:
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
  `BackingOff(attempt)`, `Polling(reason)`, `Stopped`. *(Deviation (i), 2026-09-11: `Arming(attempt)`
  — under rule 3 no current re-arm request can arrive while arming, so the flag could never be
  set; collapse is rule 3's.)*
* **`lib/core/git/watch/engine/watch_engine.dart`:** `final class WatchEngine({required
  WatchSource source, required String repoPath, BoundedWatchSpecSource? bounded,
  WatchTimings timings = WatchTimings.standard, WatchTransitionSink? onTransition,
  Stream<void>? budgetReleased})`, with `Stream<RepoWatchEvent> get events`. *(Recorded in the
  execution record: also `void Function()? onPollingRecoveryAttempt`, which rule 4 needs, and a
  `@visibleForTesting` `debugPost(EngineEvent)`.)* Rules:
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
       stream. *(Deviation (j), 2026-09-11: Cancel leaves the attempt current and moves to
       `Stopped`, where the in-flight result is settled — `SourceArmed` closed, `SourceAborted`
       recorded as `stopped: arm aborted`, `SourceUnavailable` neither recorded nor polled.)*
  5. **Every transition** that `watchLifecycle` reports through `onTransition` is reported
     with the same kind and cause text, in the same order. *(Deviation (j): except the
     `degradedToPolling` `watchLifecycle` recorded for a refusal arriving after cancel, along
     with the two timers it leaked.)*

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
`WatchTimings.forTest()` durations equal to the helper's current values. *(Deviation (h),
2026-09-10: `forTest()` does not have those values; the helper builds its own coherent
`WatchTimings` — recovery 2 days rather than 1 — see the execution record.)* Add:

* `an arm result from a superseded attempt is closed, not adopted`;
* `a source arriving after cancel is closed`;
* `many re-arms while arming collapse into a single follow-up` (ported from
  `watch_transition_wiring_test.dart`);
* `overlapping starts tear down every armed source` (ported likewise);
* `a budget release wakes only a ceiling refusal`;
* *(deviation (j))* `a refusal arriving after cancel starts no polling`;
* *(deviation (k))* `a re-arm spends no restart budget and emits no stopped tick`.

4.2 **`test/watch_transition_wiring_test.dart`:** replace `watchLifecycle(` and
`WatchHooks` with the engine and `FunctionWatchSource`, assertions unchanged.

**Catalogue — add to 0045:**

| Label | Killed by |
| --- | --- |
| `p4: a stale arm result is adopted` | `an arm result from a superseded attempt is closed, not adopted` |
| `p4: a source arriving after cancel is left open` | `a source arriving after cancel is closed` |
| `p4: a re-arm spends the restart budget` | `watch_engine_test.dart`, `surface_rearm_policy_test.dart` *(deviation (k): `a re-arm spends no restart budget and emits no stopped tick`; the policy test builds no engine)* |
| `p4: a budget release wakes every refusal` | `a budget release wakes only a ceiling refusal`, `a refusal that is NOT the ceiling is not woken by a slot release` |
| `p4: path overflow is ignored` | `path overflow at maxPaths emits empty paths set` |
| *(deviation (j))* `p4: a refusal after cancel starts polling` | `a refusal arriving after cancel starts no polling` |

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

## Execution Record

### Phase 0 — preconditions

* Flutter 3.47.2; `flutter pub get --enforce-lockfile` → `Got dependencies!`.
* `HEAD` was `7898950` with exactly the three expected docs files dirty; committed as
  `6c25baa`.
* Baseline: `flutter analyze` → no issues. `flutter test` →
  `03:40 +3956 ~3 -2: Some tests failed.` The two failures are exactly
  `a subscriber leaving while a build is deferred orphans nothing` and
  `arriving, leaving and arriving during a teardown arms once, after it`.

### Phase 1 — foundations

**Complete — code committed as `1d71f14`** (19 files: the ten `lib` files, five new tests,
`tool/mutate.py` and the 0041, 0044 and 0045 catalogues; `test/watch_shared_path_test.dart`
untouched). Gate at commit: `flutter analyze` no issues; `dart format --output=none
--set-exit-if-changed` on the 15 staged Dart files, 0 changed; the identifier scan
`+2: All tests passed!`; no Dart file changed after the full-suite run below, and no test
reads `tool/` or the catalogues. The generated commit message describes the watch-stack
modules only; the harness work is recorded here, in deviations (a)–(c).

Code complete: formatted, `flutter analyze` clean, targeted tests
`+120: All tests passed!`, and the full suite `03:33 +3979 ~3 -2` — the 23 new unit tests
pass, and the only failures are the same two. The acceptance grep found one stale doc
comment in `bounded_watch.dart` still naming `_isWatcherStartupNoise`; it was corrected,
and the grep is now clean.

Catalogue census before any run: 0041 had 2 DID NOT APPLY entries (the two `p5` noise
entries, as predicted) and 0044 had 2 (`the marker is treated as startup noise`, as
predicted, and **`the incumbent is captured but never kept`, not predicted**). All four
were re-anchored onto the lines that now own the same behaviour: three into
`stderr_line_reader.dart`, and the incumbent entry onto `incumbent ??= token;` in the arm.
`tool/mutations/0045-watch-stack.json` was created with the six phase-1 entries.

#### Deviation (a) — the mutation harness mirrored no new directory, and reported false kills (2026-09-10)

**Found.** The first catalogue runs printed `mirrored 12 uncommitted file(s)`, reported a
column of `KILLED` lines, and then crashed on `FileNotFoundError` for files under
`lib/core/git/watch/`. `mirror_working_tree` in `tool/mutate.py` reads plain
`git status --porcelain`, which lists a new untracked directory as the single entry
`?? lib/core/git/watch/`, and skips it: `if not os.path.isfile(src): continue`. Nothing
checks that the unmutated tree passes before mutating, and a failing exit code counts as
a kill.

**Reproduced, not inferred.** In a scratch worktree at `HEAD`, holding exactly the 12
files the harness copied and **no mutation**, `bounded_watch_test.dart` failed to build:

```
lib/core/git/bounded_watch.dart:2:8: Error: Error when reading
'lib/core/git/watch/watch_timings.dart': No such file or directory
```

So the 25 `KILLED` lines from 0041 and the first 4 from 0044 were compile errors, not
kills, and are not recorded as results.

**Pre-existing.** `tool/mutate.py` is untouched by this work. Earlier catalogue runs were
valid because they only ever added files inside directories git already tracked, which
plain `--porcelain` lists individually. The mirror also skips deleted paths, which phase 4
would have hit when it removes `watch_lifecycle.dart`.

**Decision: resolution 1, fix the harness properly.**

* Mirror with `git status --porcelain --untracked-files=all`.
* Delete in the worktree anything deleted in the working tree.
* Stop with an error on any listed path that is neither copied nor deleted.
* Before the first mutation, run the union of the catalogue's `tests` on the unmutated
  worktree, and stop with a "baseline red" error if it fails. That makes rule 4 part of
  the tool.

The rejected alternative fixed the mirroring alone, which would have left every other way
an unmutated tree can fail producing silent false kills. Committing phase 1 first, so the
files became tracked, was not offered: it hides the defect and inverts this plan's
verify-then-commit order.

**Scope added to phase 1:** `tool/mutate.py`.

**Executed.** `mirror_working_tree` now reads
`git status --porcelain --untracked-files=all -z`, copies every listed file, removes a
deleted path (and a rename's old name) from the worktree, and exits naming any path that
is neither. It returns `(copied, deleted)`. Before the first mutation, `main` runs
`flutter test` on the union of the selected entries' `tests` (the whole suite if any
entry has none), and on failure prints `BASELINE RED`, lists the failing tests and exits 2.
The failing-test-name parser the kill report already used is now the shared
`failing_test_names`. The docstring's load-bearing properties gain a fourth.

**The fix was seen to fail both ways, outside the tree.**

* *Mirror.* A scratch-directory check built a throwaway repository and worktree with a
  modified file, a staged rename, a deleted file, an untracked file two directories deep
  under a new directory, and — separately — an untracked symlink to a directory. Against
  the fixed harness: all 7 checks `PASS`; the symlink stopped the mirror with
  `mirror: cannot mirror 'dirlink' ('??') — neither a file nor a deletion`. Against the
  committed harness (`git show HEAD:tool/mutate.py`, copied to the scratch directory):
  5 of 7 `FAIL` — the new-directory file, the deletion, the rename's old name, the counts
  (`copied=2 deleted=0`), and the unmirrorable path, which it skipped.
* *Baseline.* A scratch catalogue whose one entry names `test/watch_timings_test.dart`
  and `test/watch_shared_path_test.dart` — the second red by design since `7898950` —
  printed `mirrored 20 uncommitted file(s), removed 0 deleted` (the 20 paths
  `git status --porcelain --untracked-files=all` lists), then
  `BASELINE RED: the unmutated tree fails the tests this catalogue relies on — no mutation
  result would be valid.`, named exactly the two known failures, applied no mutation, and
  exited `2`. `git worktree list` afterwards showed only the main tree.

**Catalogue runs, on the fixed harness,** one at a time, with no other test run in
progress. Each mirrored the same 20 paths and passed its baseline first:

```text
tool/mutate.py 0041-watcher-teardown   baseline green: 5 test file(s)   27 killed, 0 survived, 0 did not apply
tool/mutate.py 0044-arm-readiness      baseline green: 3 test file(s)   10 killed, 0 survived, 0 did not apply
tool/mutate.py 0045-watch-stack        baseline green: 5 test file(s)    6 killed, 0 survived, 0 did not apply
```

Every re-anchored entry was killed by the tests that owned the behaviour before it moved:
the two `p5` noise entries by `watcher diagnostics startup chatter is dropped…`, the
marker entry by `an arm settles on the marker, not on the ceiling`, and the incumbent
entry by `a lock refusal is still a refusal, and still names its incumbent`.

*(Superseded: one of those 27 kills was a compile failure — deviation (b). The final runs,
on the harness as committed, are recorded at the end of deviation (c).)*

#### Deviation (b) — a 0041 entry has never compiled, and was counted as a kill (2026-09-10)

**Found.** One 0041 kill was a load failure, not a named test:
`p2: a failing lease removal escapes the teardown → loading …/watch_lease_release_test.dart`.
The entry replaces the `catch (_)` in `releaseHostClaims` with
`} on _NeverThrown catch (_) {`, and `_NeverThrown` is defined nowhere. It never has been,
since the entry was added in `6f2550e`.

**Evidence.**

* *Every catalogue this phase runs was checked.* A scratch-directory script applied each
  of the 43 mutations in 0041, 0044 and 0045 in a scratch worktree and ran
  `dart analyze --format=machine` on the mutated file, reporting only errors the unmutated
  file lacks. Exactly one entry failed to compile:
  `NON_TYPE_IN_CATCH_CLAUSE: The name '_NeverThrown' isn't a type and can't be used in an on-catch clause.`
* *Reproduced by hand,* in a scratch worktree, running `flutter test
  test/watch_lease_release_test.dart` three ways:

  | variant | exit | output |
  | --- | --- | --- |
  | unmutated | 0 | `+9: All tests passed!` |
  | the entry verbatim | 1 | `Compilation failed for testPath=…: lib/core/git/remote_watch_service.dart:797:18: Error: '_NeverThrown' isn't a type.` — no test ran |
  | `} on FormatException catch (_) {` | 1 | `a removal that throws does not fail the teardown [E]`, `SSH transport is not ready yet: rm`, thrown from `releaseHostClaims` |

* *Pre-existing.* The replacement has named `_NeverThrown` since `6f2550e` added the entry;
  `dc62cde` (the 0043 deviation (f) re-anchor) changed only the lines around it, and this
  work did not touch it before this deviation. The run counts that include it are the 0041
  plan's `Verification, as run`, the 0043 plan's deviation (f) and `Verification, as run`,
  and the 0044 plan's catalogue block, all recording `27 killed`.
* *The contract was sound, but it was never proved.* The test does detect an escaping
  removal error: the compiling variant is killed by exactly the test that names the
  contract. What was missing was the sabotage evidence for it.
* *Same class as deviation (a).* The harness reads any non-zero exit as a kill, so a
  mutation that does not build is indistinguishable from one a test caught. The baseline
  guard cannot see this: the baseline compiles, and the mutation does not.

**Decision: resolution 1, fully implemented and hardened.**

* Re-anchor the entry to the verified compiling form, `} on FormatException catch (_) {`,
  keeping its label.
* Stop `tool/mutate.py` from reading a failed run as a kill. A mutation is **KILLED** only
  when at least one named test failed. A run whose output carries the tester's
  compile-failure marker, `Compilation failed for testPath=` (emitted by
  `flutter_tools/lib/src/test/flutter_platform.dart:662` on the pinned 3.47.2), is
  **DOES NOT COMPILE**. A failed run with no named test failure (nothing but `loading`
  pseudo-tests, or no `[E]` line at all) is **NOT OBSERVED**. Both are broken entries that
  fail the run, exactly as DID NOT APPLY does.
* Keep that detector honest. After the baseline, and before the first mutation, the
  harness runs a compile canary. It writes a `lib` file with a type error and a test that
  imports it into the scratch worktree, and requires that run to classify as DOES NOT
  COMPILE; otherwise it stops with `CANARY`. A Flutter upgrade that rewords the marker
  therefore stops the harness instead of silently turning compile failures back into
  kills.
* Record the correction where the count was recorded. Annotate each `27 killed` line
  above — not rewritten — to say one of the 27 was a compile failure, and point here.

**Rejected.** Fixing the entry alone leaves the next non-compiling mutation counted as a
kill with nothing to notice it; the analyzer check that found this one lives only in a
scratch directory. An analyzer pre-pass per mutation was not chosen as the detector: it
adds a few seconds an entry, and it judges what the analyzer thinks rather than what the
tester actually failed to build.

**Scope added to phase 1:** the 0041 entry (the catalogue is already in scope), the
further `tool/mutate.py` change, and annotations to
`docs/0041-PLAN-the-watcher-the-client-cannot-kill.md`,
`docs/0043-PLAN-a-watcher-refused-by-its-own-session.md` and
`docs/0044-PLAN-the-watcher-follows-the-active-tab.md`.

**Executed.**

* `tool/mutate.py` gained `classify_failure`, `compile_canary` and `package_name`, a fifth
  load-bearing property in its docstring, and a summary line that counts
  `did not compile` and `observed by no test` beside `did not apply`. Property 4's
  opening sentence no longer says a failing run is a kill. The canary writes
  `lib/mutate_compile_canary.dart` (`const int mutateCompileCanary = 'not an int';`) and
  `test/mutate_compile_canary_test.dart` into the scratch worktree, refuses to overwrite
  either, and removes both before the first mutation.
* The 0041 entry's replacement is now `} on FormatException catch (_) {` plus its closing
  brace.
* The catalogue JSON had been re-serialised with one-space indentation while phase 1
  re-anchored it, turning a three-entry change into a 486-line diff. Each catalogue was
  rewritten in its own committed style, checked by reproducing `HEAD` byte-for-byte
  (0041 two-space, 0044 one-space) with the content asserted unchanged; the new 0045
  takes the two-space style most committed catalogues use.

**Seen to fail, both ways, outside the tree.**

* *Classifier, on real tester output.* The logs the hand reproduction captured:
  the `_NeverThrown` run → `DOES NOT COMPILE`, evidence
  `lib/core/git/remote_watch_service.dart:797:18: Error: '_NeverThrown' isn't a type.`;
  the compiling run → `KILLED` by `a removal that throws does not fail the teardown`; a
  `loading … [E]`-only output and an empty output → `OBSERVED BY NO TEST`. On the same
  `_NeverThrown` output the committed harness's rule gives `KILLED`, naming only the
  `loading …` pseudo-test.
* *End to end.* A scratch catalogue of one control and two negatives:

  ```text
  baseline green: 2 test file(s)
  compile canary recognised: a mutation that does not build is not a kill
  KILLED  : control: the re-anchored lease-removal entry is killed
            -> a removal that throws does not fail the teardown
  DOES NOT COMPILE: negative: the _NeverThrown form does not compile
            -> lib/core/git/remote_watch_service.dart:797:18: Error: '_NeverThrown' isn't a type.
  OBSERVED BY NO TEST: negative: a load-time throw is observed by no test
            -> loading …/test/watch_timings_test.dart

  1 killed, 0 survived, 0 did not apply, 1 did not compile, 1 observed by no test
  ```

  and exit `1`.
* *Canary.* A scratch copy of the harness with its marker misspelled
  (`'Compilation failed for testPathX='`), run on the same catalogue, passed the baseline
  and then stopped before any mutation:
  `CANARY: a deliberate compile error was classified 'OBSERVED BY NO TEST', not 'DOES NOT COMPILE'. …`
  and exit `3`. No canary file was left in the working tree.

#### Deviation (c) — every catalogue checked: a second entry that never compiled, and 15 stale anchors (2026-09-10)

**Found.** Deviation (b)'s evidence covered only the three catalogues phase 1 runs. The
same scratch-directory check was then run over all ten catalogues in `tool/mutations/`
(215 entries), applying each mutation in a scratch worktree and running `dart analyze` on
the mutated file. It reported 16 entries: `215 entries analysed, 16 do not compile`.

* *A second entry that has never compiled.* `0043-one-watcher-per-repo.json`
  `p1: the factory is not refreshed, so a rebuild keeps a stale closure` replaces
  `shared.build = () => _createLifecycle(` with `shared.buildOnce ??= () => _createLifecycle(`:
  `UNDEFINED_GETTER` / `UNDEFINED_SETTER: The getter 'buildOnce' isn't defined for the type '_SharedWatch'.`
  `git log --all -S buildOnce` finds one commit, `dc62cde`, and in it only the catalogue
  file — the member never existed in `lib/`. Its recorded counts, `10 killed`, are the 0043
  plan's `Verification, as run` and the 0044 plan's catalogue block and phase-3 record.
  Phase 2 of this plan already retires the entry ("There is no factory").
* *Fifteen stale anchors,* all DID NOT APPLY: 2 in `0032-namespaces.json`
  (`sheet: active connection not resolved for history`,
  `clone: active connection not resolved for history`) and 13 in `0036-destination.json`.
  Every target file exists; no anchor matches. Each anchor matched exactly once at its
  catalogue's own last commit (`56c767d` for 0032, `5af35c7` for 0036). Stepping through
  every later commit that touched each target file, the first where the anchor stopped
  matching once was, all on 2026-09-08: `dc78436` (both 0032 entries), `fdd0d7b` (4),
  `6117172` (4), `2e1f841` (4) and `c818bb0` (1). *(Corrected before commit: a first
  attribution by `git log -S` on each anchor's first line wrongly named `116b861` and
  `ee0c4a6`, where anchors were introduced, and missed `c818bb0`.)* For two entries the
  distinctive identifier (`provisionTarget`, `_ensureProvisionTab`) is nowhere in `lib/`.
  These were never false results — the harness reports them — but no record mentions them,
  and their catalogues no longer exercise those contracts.

**Pre-existing.** No catalogue other than 0041, 0044 and 0045 is touched by this work, and
the two watcher-unrelated catalogues were last changed on 2026-09-07 and 2026-09-08.

**Decision: resolution 1.**

* Reproduce the 0043 entry by hand, annotate its three recorded counts, and leave the
  entry to phase 2's planned retirement. Re-anchoring it now cannot be verified — its test
  file carries the two phase-0 failures until phase 2 — and phase 2 deletes the code it
  targets.
* Promote the check into `tool/mutate.py --check [catalogue …]` (every catalogue by
  default): for each entry, confirm it applies exactly once and that the package still
  analyses without a new error, running no tests. Verify it both ways — it must flag
  today's 16 entries, and pass the clean 0041, 0044 and 0045 catalogues.
* Write a standalone plan to re-anchor or retire the 15 stale 0032 and 0036 entries, for
  the maintainer's review after phase 1 commits.

**Rejected.** Fixing the 15 inside phase 1 grows it with workspace-feature code unrelated to
the watcher stack. Annotating alone, with no check mode, leaves the next broken or stale
entry to be found only when someone happens to run its catalogue — which is how both
false kills stood through three MADRs.

**Scope added to phase 1:** the `--check` mode in `tool/mutate.py`, and annotations to
`docs/0043-PLAN-a-watcher-refused-by-its-own-session.md` and
`docs/0044-PLAN-the-watcher-follows-the-active-tab.md`. The standalone plan is a separate
document and not part of phase 1.

**Executed.**

* *The 0043 entry, reproduced by hand* in a scratch worktree, running its
  `test/watch_shared_path_test.dart`: unmutated, exit 1 with exactly the two phase-0
  failures and no compile failure; with the entry applied verbatim, exit 1 and
  `DOES NOT COMPILE`:
  `lib/core/git/remote_watch_service.dart:590:12: Error: The getter 'buildOnce' isn't defined for the type '_SharedWatch'.`
  The three recorded counts are annotated.
* *`tool/mutate.py --check [catalogue …]`* (every catalogue in `tool/mutations/` when none
  is named). It creates the scratch worktree as a run does, requires
  `flutter pub get --enforce-lockfile` to succeed, and then:
  * requires the unmutated package to analyse with no `ERROR` (`BASELINE RED`, exit 2);
  * plants `lib/mutate_compile_canary.dart` and requires `dart analyze` to report an error
    against it (`CANARY`, exit 3);
  * for each entry, reports `DID NOT APPLY` unless the anchor matches exactly once, and
    otherwise applies it, runs `dart analyze --format=machine .` over the whole package,
    and reports `DOES NOT COMPILE` with the errors if there are any — the whole package,
    because a mutation that compiles in its own file can break a file that uses it;
  * stops if `dart analyze` exits outside 0–3, since an analysis that never completed
    would otherwise read as "no errors";
  * exits 1 on any broken entry and prints the elapsed time.
* Run mode now shares the worktree setup, removes the worktree if mirroring fails, and
  reads anchors through the same function — so a missing target file, or an empty
  `find`, is `DID NOT APPLY` instead of a crash (or, for an empty `find` on an empty
  file, a spurious apply). It also passes `--enforce-lockfile` to `flutter pub get`.
  With zero or two catalogues and no `--check`, it exits 2 with a usage error and creates
  no worktree.

**`--check` seen to fail, outside the tree.**

* *Canary.* A scratch copy whose error parser never matches (`fields[0] == 'ERROR_NEVER'`)
  passed the baseline — an empty error set — and then stopped:
  `CANARY: a planted type error was not reported by `dart analyze` — an entry that does not compile would pass the check.`,
  exit `3`.
* *Exit-code guard.* A scratch copy passing `dart analyze` an unknown flag stopped before
  judging anything: `dart analyze did not complete (exit 64)`, followed by the analyzer's
  usage text.
* *The three verdicts, and why the whole package is analysed.* A scratch catalogue of a
  sound entry (0045's coherence mutation), a stale anchor, and a rename of
  `SurfaceRearmPolicy.cancel()` — a member its own file never calls, asserted by the
  fixture builder before writing:

  ```text
  baseline clean: the unmutated package analyses without an error
  analyzer canary recognised: a planted type error is reported
  check_catalogue.json: 3 entries
    DID NOT APPLY [0 matches]: stale: an anchor that matches nothing
    DOES NOT COMPILE: cross-file: the policy's cancel() renamed; its own file stays clean
            -> lib/core/git/local_watch_service.dart: UNDEFINED_METHOD: The method 'cancel' isn't defined for the type 'SurfaceRearmPolicy'.
            -> lib/core/git/remote_watch_service.dart: UNDEFINED_METHOD: The method 'cancel' isn't defined for the type 'SurfaceRearmPolicy'.
            -> test/surface_rearm_policy_test.dart: UNDEFINED_METHOD: The method 'cancel' isn't defined for the type 'SurfaceRearmPolicy'.

  3 entries in 1 catalogue(s): 1 sound, 1 did not apply, 1 do not compile (0m 22s)
  ```

  exit `1`. No error is reported against the mutated file itself, so the scratch check's
  per-file analysis would have passed this entry. (A first version of this fixture renamed
  `WatchTimings.defaultMaxRestarts`, which the class's own constructor uses; it proved
  nothing about other files and was replaced.)

**`--check` over the real catalogues.**

* *Every catalogue* (`tool/mutate.py --check`): exactly the 16 entries the scratch check
  found, and no other — the whole-package analysis added none.

  ```text
  baseline clean: the unmutated package analyses without an error
  analyzer canary recognised: a planted type error is reported
  0043-one-watcher-per-repo.json: 10 entries
    DOES NOT COMPILE: p1: the factory is not refreshed, so a rebuild keeps a stale closure
            -> lib/core/git/remote_watch_service.dart: UNDEFINED_GETTER: The getter 'buildOnce' isn't defined for the type '_SharedWatch'.
            -> lib/core/git/remote_watch_service.dart: UNDEFINED_SETTER: The setter 'buildOnce' isn't defined for the type '_SharedWatch'.

  215 entries in 10 catalogue(s): 199 sound, 15 did not apply, 1 do not compile (12m 49s)
  ```

  with the 15 `DID NOT APPLY [0 matches]` lines for 0032 (2) and 0036 (13), and exit `1`.
* *The phase-1 catalogues* (`--check` on 0041, 0044 and 0045):
  `43 entries in 3 catalogue(s): 43 sound, 0 did not apply, 0 do not compile (2m 54s)`,
  exit `0`.

About 3.6 s an entry on this machine: under three minutes for the watcher catalogues at a
phase boundary, and about thirteen for the full sweep — longer than the "few minutes"
estimated when this resolution was chosen.

*(The standalone plan this resolution called for is written:
[0046-PLAN-restore-stale-workspace-mutation-entries.md](0046-PLAN-restore-stale-workspace-mutation-entries.md),
status `proposed`, awaiting the maintainer's review. Its 14 re-anchors were checked by
script against the tree — old anchor 0 matches, new anchor 1, killing test present by title —
and compiled with `tool/mutate.py --check`, whose first pass caught two candidates that did not
compile; after they were rewritten it reported `14 entries in 1 catalogue(s): 14 sound`.)*

**Final catalogue runs, on the harness as committed,** one at a time, after the checks and
with no other test run in progress. Each mirrored the same 23 paths, passed its baseline,
and recognised the compile canary:

```text
tool/mutate.py 0041-watcher-teardown  baseline green: 5 test file(s)  27 killed, 0 survived, 0 did not apply, 0 did not compile, 0 observed by no test
tool/mutate.py 0044-arm-readiness    baseline green: 3 test file(s)  10 killed, 0 survived, 0 did not apply, 0 did not compile, 0 observed by no test
tool/mutate.py 0045-watch-stack      baseline green: 5 test file(s)  6 killed, 0 survived, 0 did not apply, 0 did not compile, 0 observed by no test
```

Every kill names a real test; none rests on a `loading …` pseudo-test. The re-anchored
`p2: a failing lease removal escapes the teardown` is killed by exactly
`a removal that throws does not fail the teardown`.

### Phase 2 — admission replaces sharing and the statics

**Complete — code committed as `6defce4`** (31 files: 8 in `lib`, 17 tests, 6 catalogues;
`test/watch_shared_path_test.dart` included, which ends the two-failure state). Gate at
commit: `dart format --output=none --set-exit-if-changed` on the 25 staged Dart files, 0
changed; `flutter analyze` and the full suite as recorded under deviation (e). The generated
commit message describes admission and the release paths; the ignored-path filter's fix is
recorded in deviation (d) and amendment 0045.1.

Implemented as written: `lib/core/git/watch/admission/` (`HostWatcherBudget`,
`RepoExclusion`, `WatchAdmission`); `WatchHooks.cancelled`; `RemoteWatchService` without
`_SharedWatch`, its map or its statics, admitting through an injected `WatchAdmission` and
releasing per exit path in the table's order; the two providers and `TabsController`'s
budget; the 11 test files migrated so every service a test builds shares that test's budget
and keeps its own exclusion; `watch_shared_path_test.dart` per the contract table; and the
five new test files. `flutter analyze`: no issues. Tests A and B pass.

The first targeted run (`flutter test` on the five new files, the 11 migrated files,
`tabs_controller_test.dart` and `watch_lifecycle_test.dart`) reported three failures. One
was an assertion of mine in a new test, `exclusion is acquired before the budget`, which
expected the woken waiter to be refused when, with capacity two and one slot held, it is
admitted; the expectation was corrected — the property under test, that the waiter holds no
slot while it waits, is asserted earlier in the same test. The other two are deviation (d).

#### Deviation (d) — leaving the provider does not reach a quiet watcher; a kept test cannot hold; one unlisted file (2026-09-10)

**Found, 1 — pre-existing, and made worse by this phase.** `repoWatchProvider` returns
`_withoutIgnoredPaths(oracle, repoPath, raw)`, an `async*` function looping
`await for (final event in raw)`. It has had that form since it was added in `d3b2fda`
(2026-07-13), while its doc comment says it is an `asyncMap`. Cancelling an `async*`
stream takes effect only at its next `yield`; the VM says so in
`dart-sdk/lib/_internal/vm/lib/async_patch.dart`, `_AsyncStarStreamController.onCancel`:
"Cancellation does not affect an async generator that is suspended at an await." A quiet
watcher never brings the generator to a `yield`.

* *The new test that found it:* `repo_watch_provider_sharing_test.dart`,
  `the last listener leaving tears the watcher down` — `Expected: true, Actual: <false>`
  on the handle's `cancelled`, after both listeners closed and a 500 ms settle.
* *Observed, not inferred* — scratch probes in gitignored `build/`, on this tree:

  ```text
  PROBE control-direct: handles=1 cancelled=[true]
  PROBE wrapper-quiet: cancelled=false cancelFutureCompleted=false
  PROBE wrapper-after-one-event: cancelled=true cancelFutureCompleted=true
  PROBE provider-quiet: exists=false cancelled=false
  PROBE provider-after-one-event: cancelled=true
  ```

  Riverpod disposed the provider (`exists=false`); the watcher stayed live until one
  event reached it.
* *Pre-existing:* the same probe in a scratch worktree at `4e4a854`, 0 uncommitted
  entries, printed the identical five lines.
* *Worse under this phase:* a view that leaves a quiet repository and returns.

  ```text
  HEAD         relisten-quiet-3s: seen=[AsyncLoading, eventDriven] handles=1 cancelled=[false]
  this tree    relisten-quiet-3s: seen=[AsyncLoading] handles=1 cancelled=[false]
  this tree    relisten-after-old-event: seen=[AsyncLoading, eventDriven] handles=2 cancelled=[true, false]
  ```

  On `HEAD` the returning listener re-attached to the still-live shared watcher. Here the
  new watcher waits on the stale watcher's exclusion hold, and showed no mode after three
  seconds; by design it would wait up to `WatchTimings.defaultAdmissionGrace` and then meet
  its own session's host lock. That last step was not run out.
* *Not fixed by a later phase:* phase 5's facade still returns `_withoutIgnoredPaths(…)`,
  and MADR 0045 F11 lists the function as kept.

**Found, 2.** `watch_shared_path_test.dart`, `the last subscriber leaving tears the watcher
down`, kept by the contract table "(service level)": `Bad state: Too many elements` at
`exec.handles.single`. Without sharing, the second subscriber arms its own watcher once the
first leaves. A scratch probe of the same sequence, five runs, printed the same line each
time: `after log=[arm, teardown, arm, teardown] handles=2 cancelled=[true, true]
liveFor(host)=0`. The intent holds; the assertion is sharing's.

**Found, 3.** `lib/core/git/watch_diagnostics.dart:71`, a file not in this phase's list,
documents `WatchTransitionRecord.liveWatchers` as "`RemoteWatchService.liveWatchers` at
this instant" — a member this phase deletes.

**Decision** (maintainer: "1 and fix 3", read as resolution 1 for findings 1 and 2):

1. `_withoutIgnoredPaths` becomes `raw.asyncMap(…)` with the empty results dropped — the
   form its own doc comment describes. `Stream.asyncMap` sets
   `controller.onCancel = subscription.cancel`, so leaving reaches the watcher at once, and
   pauses its source while each classification is pending, so ticks stay ordered. Its four
   behaviours are unchanged — an unscoped tick passes through; an ignore-source path forgets
   the repository's verdicts; a classification error fails open; a wholly ignored tick is
   dropped — and, having had no test at the provider level, get one each in
   `test/repo_watch_ignore_filter_test.dart`. `repo_watch_provider_sharing_test.dart` gains
   `a returning listener on a quiet repository gets a watcher at once`. MADR 0045 gains
   amendment 0045.1.
2. The kept test keeps its title and level, and asserts what the design guarantees: every
   handle cancelled, never two live at once, and the budget back to zero.
3. The doc comment names the admission budget.

**Rejected.** A hand-rolled `StreamController` with an ordered processing chain does the
same with more code to own. Retiring the service-level test would lose the only
service-level check that a second, sequential watcher is torn down too. Deferring to
phase 5 was not offered: that phase keeps the function as it is.

**Scope added to phase 2:** `_withoutIgnoredPaths` in `lib/core/providers/app_providers.dart`;
`lib/core/git/watch_diagnostics.dart`; `test/repo_watch_ignore_filter_test.dart`; one test in
`test/repo_watch_provider_sharing_test.dart`; the 0045 catalogue entry
`p2: leaving the ignored-path filter does not reach the watcher`.

**Executed.**

* `_withoutIgnoredPaths` is `raw.asyncMap<RepoWatchEvent?>(…)`, dropping the null results with
  `.where(…).map(…)`; its doc comment gains the cancellation reason and cites amendment 0045.1.
* `test/repo_watch_ignore_filter_test.dart`, eight tests through the real `repoWatchProvider`,
  with a scripted service and a scripted oracle: the four behaviours, a partly ignored tick,
  order while one tick waits on git, and leaving — both while quiet and while a tick waits on
  git.
* `repo_watch_provider_sharing_test.dart`: `a returning listener on a quiet repository gets a
  watcher at once`.
* The kept test asserts that no handle is left live and that the log alternates `arm` and
  `teardown` — each watcher gone before the next arms — rather than a count of watchers.
* `watch_diagnostics.dart:71` documents the field as `HostWatcherBudget.liveTotal`.
* Two doc comments in the new admission files named retired identifiers as history; they were
  reworded so the phase's acceptance grep is clean, rather than read as an exception to it.

**Catalogue changes, as executed.** Every new anchor was asserted to match once before any
catalogue was written; 0041, 0043, 0044 and 0045 were re-serialised in their committed styles,
0039 and 0040 edited in place entry by entry.

| Catalogue | Entry | Executed |
| --- | --- | --- |
| 0039 | `f4: the ceiling counts every host together again` | `host_watcher_budget.dart`: `final live = liveFor(host);` → `liveTotal` |
| 0039 | `f4: a released slot is announced to every host` | `host_watcher_budget.dart`: the `where((h) => h == host)` filter removed |
| 0039 | `f4: the release credits the current host, not the reserving one` | `host_watcher_budget.dart`: `_budget._release(host)` credits a host that never reserved — the slot no longer carries a "current host" to mis-credit, so the sabotage is crediting anyone but the reserver |
| 0040 | `p1: the catch-all is removed, so four of five failures strand the slot` | the catch-all's `ticket.releaseBudget()` removed; the `rethrow` entry applied unchanged |
| 0041 | `p2: teardown does not release the lease` | re-anchored onto the teardown tail, which now ends in `releaseExclusion()` |
| 0041 | `p2: a failing lease removal escapes the teardown` | re-anchored at the closure's new indentation, outside the `try` |
| 0041 | `p2: teardown removes the pid file, which is not the client's` | re-anchored at the new indentation |
| 0041 | `p4: each service instance gets its own budget (per-session keying)` | `tabs_controller.dart`: the `hostWatcherBudgetProvider` override removed; tests `tab_watcher_budget_injection_test.dart`, `watch_ceiling_recovery_test.dart` |
| 0043 | `p1: sharing removed — every watch() builds its own watcher` | **retired** |
| 0043 | `p1: the last event is not replayed to a late subscriber` | **retired** |
| 0043 | `p1: the factory is not refreshed, so a rebuild keeps a stale closure` | **retired** |
| 0043 | `p1: the watcher is built eagerly, not on the first subscriber` | `watch()` arms a lifecycle before returning one |
| 0043 | `p1: the shared map is static, so two tabs share one watcher` | `watch_admission.dart`: one process-wide `RepoExclusion` for every admission |
| 0043 | `p2: teardown does not give the lock back` | the same teardown-tail re-anchor as 0041's |
| 0043 | `p2: a new arm does not wait for a pending teardown` | `repo_exclusion.dart`: the wait loop's condition made never-true by an opaque `identical` test, which keeps null promotion |
| 0044 | `p2: a refused arm keeps its slot` | the locked refusal's `ticket.releaseBudget()` removed |
| 0045 | six `p2` entries from the table above | added |
| 0045 | `p2: leaving the ignored-path filter does not reach the watcher` | added (deviation (d)): an `async*` pass-through in front of the `asyncMap` |

**Verification, so far.**

```text
flutter analyze                                   No issues found!
targeted: 6 new, 11 migrated, tabs_controller,
          watch_lifecycle                         00:33 +126: All tests passed!
flutter test                                      03:58 +4008 ~3: All tests passed!   (phase 1: +3979 ~3 -2)
grep '_SharedWatch|_liveByHost|_slotReleases|
      resetWatcherCount|sharedTeardownGrace' lib  exit 1, no output
tool/mutate.py --check  0039 0040 0041 0043 0044 0045
                                                  106 entries in 6 catalogue(s): 106 sound, 0 did not apply, 0 do not compile (7m 25s)
```

**Catalogue runs,** one at a time with no other test run in progress; each mirrored 34 paths,
passed its baseline and recognised the compile canary:

```text
tool/mutate.py 0039-globals-and-heuristics  47 killed, 0 survived, 0 did not apply, 0 did not compile, 0 observed by no test
tool/mutate.py 0040-watcher-ceiling          2 killed, 0 survived, 0 did not apply, 0 did not compile, 0 observed by no test
tool/mutate.py 0041-watcher-teardown        27 killed, 0 survived, 0 did not apply, 0 did not compile, 0 observed by no test
tool/mutate.py 0043-one-watcher-per-repo     7 killed, 0 survived, 0 did not apply, 0 did not compile, 0 observed by no test
tool/mutate.py 0044-arm-readiness           10 killed, 0 survived, 0 did not apply, 0 did not compile, 0 observed by no test
tool/mutate.py 0045-watch-stack             12 killed, 1 survived, 0 did not apply, 0 did not compile, 0 observed by no test
  SURVIVOR : p2: exclusion is released before the host claims
```

#### Deviation (e) — no test observes that exclusion outlives the host claims (2026-09-10)

**Found.** `p2: exclusion is released before the host claims` moves `ticket.releaseExclusion()`
ahead of `await releaseHostClaims()` in the `WatchArmed` teardown, so this session's next
watcher of the repository may arm while the host still holds the previous watcher's lock — the
self-refusal MADR 0043 F3 and F4 describe. It survived. The table named
`a new subscriber waits for a pending teardown before arming` as its killer, but that test's
executor answers the release at once and logs `teardown` when the channel closes, which is
before the release: nothing in it can see the order between the release and the exclusion.

**Reproduced by hand,** in a scratch worktree mirroring the 34 uncommitted paths:

```text
entry-unmutated    exit=0 passed
entry-mutated      exit=0 passed          (00:23 +11: All tests passed!)
```

**A test that observes it, seen to fail.** A scratch test whose executor holds the release open
on a gate while the next subscriber arrives, run in the same worktree:

```text
probe-unmutated    exit=0 passed
probe-mutated      exit=1 KILLED  -> the next watcher waits for the host claims, not just the channel
  Expected: ['arm', 'teardown', 'release-start']
    Actual: ['arm', 'teardown', 'release-start', 'arm']
```

**Decision: resolution 1.** The test joins `test/watch_shared_path_test.dart`, which is already
the entry's test list, so the catalogue is unchanged; 0045 is run again.

**Rejected.** Filing it in `watch_lease_release_test.dart` would have grouped it by lease rather
than by exclusion, and changed the entry's test list.

**Scope added to phase 2:** one test and its gated executor in `test/watch_shared_path_test.dart`.

**Executed.** `watch_shared_path_test.dart` gained `_GatedRelease`, an executor that holds the
lease-and-lock release open on a gate and logs around it, and
`the next watcher waits for the host claims, not just the channel`, asserting
`['arm', 'teardown', 'release-start']` while the release is held and
`['arm', 'teardown', 'release-start', 'release-done', 'arm']` once it completes.

**Final verification** (after deviations (d) and (e)):

```text
flutter analyze                          No issues found! (ran in 5.9s)
flutter test test/watch_shared_path_test.dart
                                         00:26 +12: All tests passed!
tool/mutate.py 0045-watch-stack          baseline green: 10 test file(s); compile canary recognised
                                         13 killed, 0 survived, 0 did not apply, 0 did not compile, 0 observed by no test
                                         p2: exclusion is released before the host claims
                                           -> the next watcher waits for the host claims, not just the channel
flutter test                             03:50 +4009 ~3: All tests passed!   (phase 1: +3979 ~3 -2)
```

The other five catalogues were run before deviation (e), whose change is one test in a file
none of them names.

### Phase 3 — the source seam and lock-key resolution

**Complete — code committed as `d77e34a`** (39 files: 12 in `lib`, 23 tests, 4 catalogues). Gate
at commit: `dart format --output=none --set-exit-if-changed` on the 35 staged Dart files, 0
changed; `flutter analyze`, no issues; the full suite and catalogues as recorded below. The
generated commit message describes the source seam and `resolveRepoLayout`; the `pkill` removal
(deviation (f)), the synchronous signals and the executing lease test are recorded here.

#### Deviation (f) — a committed test calls `pkill` (2026-09-10)

**Found** while reading the pattern this phase's worktree test is told to follow.
`test/watch_lease_teardown_exec_test.dart` calls `Process.run('pkill', ['-f', marker])`
twice, with `marker = 'mg-lease-exec-probe'`:

* line 86, in `tearDown` — a backstop so no shim watcher outlives a test;
* line 359, in `a lock whose holder is gone is stolen, not respected` — after SIGKILLing
  the first watcher's `sh`, to take its orphaned shim payload down too, simulating a holder
  that crashed.

A repository-wide search (excluding the vendored SDK, `build/` and `.dart_tool/`) finds no
other call; the only other mentions are rule 5 and this phase's own "No `pkill`". The calls
arrived in `cb18fc1` and `96bdab1` (2026-09-09, MADR 0041) and are on `origin/master`.
`pkill` is forbidden in any form by the maintainer and by rule 5.

**It ran during this work.** Every full-suite run in phases 0–2 and every run of the 0041
and 0043 catalogues — which name this file for many of their mutations — executed those
calls. It was not noticed until this phase's pattern pointed at the file.

**Decision: resolution 1.** Kill only exact PIDs the test itself recorded. The shim writes
its own PID to a file in the test's temporary directory before `exec` — which keeps the PID —
so every recorded PID is a payload that test started. Before a recorded PID is killed, its
argv must still start with that test's own temporary directory, because a payload that exited
on its own may have had its PID reused. `tearDown` kills those, then runs the existing process
census and **fails** if any marker process is still alive, rather than killing whatever
matches. Line 359 kills the first watcher's recorded payload. This phase's worktree test uses
the same pattern.

**Rejected.** Killing by the PID the product script writes to its own pid file is also exact,
but ties cleanup to the behaviour under test: a regression in that pid recording would leak
processes silently instead of failing.

**Scope added to phase 3:** `test/watch_lease_teardown_exec_test.dart`.

**Executed.** The shim appends its own `$$` to `payload.pids` in the test's temporary
directory before `exec`. `recordedPayloads()` reads them; `killOwnPayload(pid)` sends SIGKILL
only when `ps -o args= -p <pid>` still starts with `<shimDir>/mg-lease-exec-probe`.
`tearDown` kills the recorded payloads, waits for the existing census (`liveWatchers()`, moved
above `setUp` so `tearDown` may call it) to read zero, deletes the directory, and fails with
`a shim watcher outlived its test` if it did not. The stolen-lock test kills the crashed
holder's recorded payload and waits for it to die. `flutter analyze`: no issues (one
`use_null_aware_elements` info fixed on the way). `flutter test
test/watch_lease_teardown_exec_test.dart`: `00:11 +18: All tests passed!`.
`grep -rn pkill test lib tool`: no output (exit 1). No marker process alive afterwards.

**The census seen to fail.** In a scratch worktree, a copy of the test with the tearDown's
kill loop removed, running only `a refusal names the token that holds the lock` — which
SIGKILLs its first watcher's shell and leaves the payload:

```text
00:09 +0 -1: one watcher per repository a refusal names the token that holds the lock [E]
  Expected: true
    Actual: <false>
  a shim watcher outlived its test
```

The one payload that run leaked was then killed by its exact PID, identified by its argv under
that run's own `mg-lease-teardown-` directory; zero marker processes remained.

#### Deviation (g) — the plan counts three worktree watch tests; there are five (2026-09-10)

**Found.** Step "`test/directory_watch_source_test.dart` — the three tests from
`local_watch_worktree_test.dart`" is wrong as written: `grep -c '^  test('` on that file reports
5 at `6c25baa`, when this plan was written, and 5 at `HEAD`. The five are a commit made in the
linked worktree is seen as git state; a branch moved in the main repository is seen from the
worktree; an ordinary edit is not git state; a bare repository's worktree sees git state; an
ordinary repository watches one root.

**Decision** (maintainer: "all 5"): all five are ported, run against `DirectoryWatchSource`.

**Rejected.** Porting three would have left two behaviours of the roots that moved guarded only
through `LocalWatchService`.

**Scope added to phase 3:** none beyond the file the plan names.

#### Phase 3, executed

**Created.** `lib/core/git/watch/source/watch_source.dart` (`ArmRequest`, `SourceArm`,
`ArmedSource`, `SourceSignal`, `WatchSource`); `source/lifecycle_adapter.dart`
(`armFromSource`, temporary until phase 4); under `source/remote/`: `git_dir_resolver.dart`,
`watcher_tool_probe.dart`, `watch_lease.dart` (`stamp()` throws `WatchLeaseException`),
`watcher_process.dart` (`WatcherOpened`/`WatcherRefused`/`WatcherCancelled`/
`WatcherBudgetSpent`), `remote_watch_source.dart`; `source/local/directory_watch_source.dart`;
`test/helpers/conventional_git_dir.dart`. `resolveRepoLayout` is top-level in
`git_service.dart`, with `repoLayout` and `scopedRepoLayout` delegating and the legacy script
asserted byte-identical.

**Modified.** `RemoteWatchService` takes `required GitDirResolver gitDirOf`, builds a
`RemoteWatchSource` per stream and arms through `armFromSource`; `_detectWatcher`, the arm
closure and `_ArmProbe` are gone from it (the typedef and its doc moved to
`watcher_process.dart`), and it gains `resolveSweepTargets`, which the connect-time sweep in
`app_providers.dart` now calls — the plan put that loop in `_sweepStaleWatchers`; it lives on the
service so `connect_paths_test.dart` can drive it, and the provider only calls it (with an
attempt/`mounted` check after the awaits). `LocalWatchService` arms through
`DirectoryWatchSource`. Every `RemoteWatchService(` in 13 test files — 48 constructions — and
the scripted subclass in `repo_watch_ignore_filter_test.dart` pass
`gitDirOf: conventionalGitDir`; the plan's "12 test files" predates phase 2's additions.

**Implementation notes.** A `WatcherRefused` carries the incumbent as a getter, read after the
channel is discarded and the host claims released — as the arm read it — because the `lock held
by` line can arrive just after the exit status. An armed source's `close()` does not await its
signal controller's close: an unlistened single-subscription stream never finishes closing.
Cancellation reaches a source as `ArmRequest.cancelled`, a future, rather than the engine's
synchronous flag, so a source observes it one microtask later than the arm did; admission and
the engine's own `if (cancelled)` after `WatchArmed` still close anything armed in that window.

**Two fixes the gate forced.**

* *A burst's paths were queued, not delivered.* The first full suite failed
  `record splitting a large burst costs linear time, not a copy per record`:
  `Expected: a value less than <50>, Actual: <164>`; run alone three times, 142, 141 and 141 ms.
  Each path crossed the new seam as an asynchronously delivered `PathChanged`. Both sources'
  signal controllers are now `sync: true` — still single-subscription, so nothing before listen is
  lost — and the same test passed three times alone.
* *A new test asserted script text without executing it.* `assertion_strength_scan_test.dart`
  enumerated `watch_lease_test.dart`, which matched `watchLockReleaseScript(...)` in the issued
  command. Rather than list it as composition-only, `releasing is token-guarded and best-effort`
  now runs the exact command the lease issues with a real `sh` against a real lock: owned by the
  token, lease and lock removed with exit 0; owned by someone else, the lease removed and the lock
  kept. Its first form expected exit 0 in both cases, and failed — the guard `[ token = ours ] &&
  rm` is false for a stolen lock, which the lease ignores by design — so the stolen case asserts
  effects only.

**Verification, so far.**

```text
flutter analyze                                   No issues found!
flutter test <the five new unit tests + connect_paths_test>
                                                  00:00 +21: All tests passed!
flutter test test/worktree_lock_key_exec_test.dart
                                                  00:00 +2: All tests passed!   (both tests seen)
flutter test test/watch_lease_test.dart test/assertion_strength_scan_test.dart
                                                  00:00 +6: All tests passed!
flutter test                                      03:40 +4034 ~3: All tests passed!   (phase 2: +4009 ~3)
grep -nE '_detectWatcher|beat\(|releaseHostClaims\(' lib/core/git/remote_watch_service.dart
                                                  exit 1, no output
```

**Catalogue changes.** 17 entries re-anchored onto the units the behaviour moved to — 0041's
three `p2` entries (teardown tail → `remote_watch_source.dart`; the release catch and the pid-file
entry → `watch_lease.dart`) and three `p3` entries (→ `watcher_process.dart`); 0043's teardown and
stranded-lease entries (→ `remote_watch_source.dart`); 0044's five race and stderr entries
(→ `watcher_process.dart`) and its refused-slot entry (→ `remote_watch_source.dart`); 0045's
three `p2` entries (→ `remote_watch_source.dart`). Where a new unit test also guards an entry,
that file joined the entry's tests. Four entries added to 0045: `p3: the lock key ignores the
resolver`, `p3: a failed stamp is swallowed`, `p3: the probe cache survives recovery`, `p3: the
sweep keys by the conventional path`.

**Catalogue runs.** `--check` first, then each catalogue, one at a time with no other test run in
progress; each mirrored 41 paths, passed its baseline and recognised the compile canary:

```text
tool/mutate.py --check 0041 0043 0044 0045   61 entries in 4 catalogue(s): 61 sound, 0 did not apply, 0 do not compile (4m 03s)
tool/mutate.py 0041-watcher-teardown         27 killed, 0 survived, 0 did not apply, 0 did not compile, 0 observed by no test
tool/mutate.py 0043-one-watcher-per-repo      7 killed, 0 survived, 0 did not apply, 0 did not compile, 0 observed by no test
tool/mutate.py 0044-arm-readiness            10 killed, 0 survived, 0 did not apply, 0 did not compile, 0 observed by no test
tool/mutate.py 0045-watch-stack              17 killed, 0 survived, 0 did not apply, 0 did not compile, 0 observed by no test
```

The four new entries were killed by: `p3: the lock key ignores the resolver` → `a linked worktree
is locked by its resolved git dir`; `p3: a failed stamp is swallowed` → `a failed stamp throws with
the host's reason`, `a lease that cannot be stamped fails the arm without opening a stream`;
`p3: the sweep keys by the conventional path` → `the connect-time sweep keys a worktree by its
resolved git dir`; `p3: the probe cache survives recovery` → `invalidate probes again` and
`recovering from polling back to event-driven stops the poll ticks` — the plan's named killer,
`a failed watcher probe retries instead of caching "none"`, is not among them, since a failed
probe caches nothing to invalidate.

**Observed, and left open.** In that last mutated run `record splitting a large burst costs linear
time, not a copy per record` also failed, although a no-op `invalidate()` does not touch record
splitting. The test measures wall-clock time against 50 ms; it passed three times alone after the
synchronous-signal fix, and once in the full suite. It is likely load-sensitive near its bound when
two test files run together. The entry's kill does not depend on it; the test's margin is named
here rather than widened.


### Phase 4 — one engine replaces `watchLifecycle`

Landed in `360b846`, with deviations (h)–(l) and MADR amendment 0045.2.

#### Deviation (h) — `WatchTimings.forTest()` does not have the helper's durations (2026-09-10)

**Found.** Step 4.1 ports the nine `watch_lifecycle_test.dart` tests "with identical names and
assertions", through a `fastEngine` helper "with `WatchTimings.forTest()` durations equal to the
helper's current values". They are not equal:

| duration | `fastLifecycle` (`watch_lifecycle_test.dart:12-23`) | `WatchTimings.forTest()` (`watch_timings.dart:37-52`) |
| --- | --- | --- |
| trailing / maxWait / minInterval | 0 / 10 ms / 0 | 0 / 10 ms / 0 |
| pollInterval | 1 day | 50 ms |
| recoveryInterval | 1 day | 200 ms |
| restartBackoffStep | 2 s (the engine default) | 10 ms |

`noteActivity resets the restart budget` spends the budget and waits 1 s expecting no further arm
until `noteActivity`; a 200 ms recovery would re-arm several times in that second and break its arm
count. `scheduleRestart triggers re-arm after backoff` documents and waits out a 2 s backoff. Read
from the code; the engine does not yet exist to run it. The helper's own values are also incoherent
by `WatchTimings.coherenceErrors()`, which rejects `pollInterval >= recoveryInterval`, so
`forTest()` cannot simply be changed to them.

**Decision: resolution 1** (maintainer: "option 1"). The helper builds its own `WatchTimings`:
trailing 0, maxWait 10 ms, minInterval 0, pollInterval 1 day, recoveryInterval **2 days**, the
backoff step at its 2 s default, `maxRestarts` from its argument. No ported test elapses near a day,
so the nine keep identical names, assertions and timing, and the value is coherent. `forTest()` is
unchanged.

**Rejected.** The helper's exact values (poll and recovery both 1 day) would run the engine under
timings `coherenceErrors()` rejects, silently.

**Scope added to phase 4:** none beyond the files the plan names.

**Recorded, no decision needed.**

* Step 4.1 ports two tests from `watch_transition_wiring_test.dart` into the engine test while
  step 4.2 keeps them there, assertions unchanged; both are kept, as written.
* `WatchEngine` takes `void Function()? onPollingRecoveryAttempt`, which the plan's signature
  omits. Rule 4 requires it: `watchLifecycle` calls it before each recovery arm, and the remote
  service passes `RemoteWatchSource.invalidateCaches` so the tool and git dir are asked again.
* The public API cannot produce a superseded attempt — no second arm starts while one is in
  flight — so `an arm result from a superseded attempt is closed, not adopted` posts through a
  `@visibleForTesting` `debugPost(EngineEvent)`, named by the repository's `debug…` convention.

#### Deviation (i) — `Arming.rearmPending` can never be set (2026-09-11)

**Found.** Rule 3 drops any event whose attempt is not current, and a source's signals reach
the engine only once it is adopted (`ArmedSource.signals`, `watch_source.dart:65-72`). While
`Arming(n+1)`, the replaced source's signals carry `n` and are stale, and the new source is not
yet listened to; the poll and recovery timers are cancelled when the arm begins, and
`BudgetReleased` wakes only `Polling(ceiling)`. No current re-arm request can arrive while
arming, so the flag is unreachable. Traced by hand through the ported
`many re-arms during one slow arm collapse into a single follow-up`: under rule 3 the three
requests yield the asserted `armCalls == 2`.

**Decision: resolution 1** (maintainer: "follow your recommendations"). `Arming(attempt)`, with
a doc comment stating that collapse is rule 3.

**Rejected.** Letting the replaced source's re-arm set the flag contradicts rule 3, and when that
source is slow to close it turns the ported test's three requests into two follow-ups.

**Scope added:** none.

#### Deviation (j) — a result arriving after cancel: rules 3–4 against rule 5, and a leak (2026-09-11)

**Found.** Rule 4 closes a `SourceArmed` arriving after `Cancel` "via rule 3", which makes the
in-flight attempt stale; rule 3 would then also drop a `SourceAborted`, yet a source aborts only
once cancelled, so `stopped: arm aborted` — which rule 5 requires — could never be recorded.
Probed on the unmodified tree with a gitignored scratch test (`build/probe/`): cancel while the
arm is gated, then resolve it.

| resolves as | transitions | periodic timers before → after |
| --- | --- | --- |
| unavailable (`heldByAnother`) | `stopped: stream cancelled`, `degradedToPolling: arm unavailable: heldByAnother` | 0 → 2 |
| aborted | `stopped: stream cancelled`, `stopped: arm aborted` | 0 → 0 |
| armed | `stopped: stream cancelled` (torn down once) | 0 → 0 |

The first row is a **pre-existing defect**: `watchLifecycle` starts its poll and recovery timers
for a stream that no longer exists, and they run for the life of the process; the remote service
also writes "polling …" to the Output log for it. It is reachable in production:
`RemoteWatchSource` returns `SourceUnavailable` for a host refusal (`remote_watch_source.dart:194-214`)
without re-checking cancellation.

**Decision: resolution 1.** `Cancel` leaves the attempt current and moves to `Stopped`; there the
in-flight result is settled — `SourceArmed` closed, `SourceAborted` recorded as today,
`SourceUnavailable` neither recorded nor polled, `ArmThrew` ignored as today. A superseded attempt
is still rule 3's. The stale path and the after-cancel path stay separate code, each with its own
test and catalogue entry. MADR amendment 0045.2.

**Rejected.** Resolution 2 — still recording `degradedToPolling`, without the timers — keeps rule 5
to the letter and keeps the Output log reporting a poll for a watcher that is gone.

**Scope added:** the test `a refusal arriving after cancel starts no polling` and the catalogue
entry `p4: a refusal after cancel starts polling`, both in files already in scope.

#### Deviation (k) — `p4: a re-arm spends the restart budget` has no killing test (2026-09-11)

**Found.** The catalogue table names `watch_engine_test.dart` and `surface_rearm_policy_test.dart`.
None of the fourteen planned engine tests asserts on the budget or a `stopped` tick after a re-arm;
`surface_rearm_policy_test.dart` exercises the debounce and never builds an engine; and no test in
`test/` pins it (`grep` for a re-arm with budget, stopped or restart finds only the lifecycle
backoff test; the bounded 0022 H5 test asserts paths). The entry would survive.

**Decision: resolution 1.** Add `a re-arm spends no restart budget and emits no stopped tick` to
`watch_engine_test.dart` and name it as the killer.

**Scope added:** that test, in a file already in scope.

#### Deviation (l) — the MADR's injected timer factory is not in the plan (2026-09-11)

**Found.** MADR section 3: "Timers come from an injected clock and timer factory … so every engine
test runs under `fakeAsync`". The plan's `WatchEngine` constructor carries neither.

**Decision: resolution 1.** Follow the plan: the engine uses zone timers, which `fakeAsync`
controls — the nine `watch_lifecycle_test.dart` tests already run that way. MADR amendment 0045.2
records it.

**Rejected.** Timer-factory parameters that no production caller would set.

**Scope added:** none.

#### Phase 4, executed

**Created.** `lib/core/git/watch/engine/engine_event.dart` (the nine events), `engine_state.dart`
(`Idle`, `Arming(attempt)`, `Armed`, `BackingOff`, `Polling(reason)`, `Stopped`) and
`watch_engine.dart`; `test/helpers/function_watch_source.dart` (`FunctionWatchSource`, and
`FakeArmedSource`, whose signals are synchronous and single-subscription like both real sources');
`test/watch_engine_test.dart` — the nine ported tests, the plan's five, and one each from
deviations (j) and (k).

**Modified.** Both services return `WatchEngine(…).events`, building a `WatchTimings` from
`watch()`'s five duration parameters; the remote one passes `source.invalidateCaches` and
`admission.budget.releases(host)` as before. `WatchUnavailableReason` moved into
`watch_source.dart`, its doc reworded for the engine; `watcher_process.dart`,
`remote_watch_source.dart` and `watcher_process_test.dart` import it from there. The two
`watch_transition_wiring_test.dart` tests build an engine over `FunctionWatchSource`, assertions
unchanged. The acceptance grep's comment hits in `watch_diagnostics.dart`,
`remote_watch_service.dart`, `local_watch_service.dart` and `remote_watch_service_test.dart` are
reworded.

**Deleted.** `lib/core/git/watch_lifecycle.dart`, `lib/core/git/watch/source/lifecycle_adapter.dart`
and `test/watch_lifecycle_test.dart` — after `flutter test test/watch_engine_test.dart
test/watch_lifecycle_test.dart` reported `00:00 +25: All tests passed!`, the old nine beside the
new sixteen.

**Implementation notes.**

* *The engine does not await a replaced source's subscription cancel.* The first run of the engine
  test failed five tests the same way — the second arm never began (`scheduleRestart triggers
  re-arm after backoff`: `Expected: an object with length of <2>, Actual: [0]`). Temporary prints,
  removed before any other run, placed it: the arm reached `await previousSignals?.cancel()` and
  continued only after the test had already failed, outside `fakeAsync`'s control. The engine now
  cancels the subscription unawaited when a source is replaced, and on cancel, and awaits only the
  source's `close()`. Nothing is lost by the reorder: from that point everything the replaced source
  reports carries a stale attempt and rule 3 drops it. The adapter's close-then-cancel order existed
  so a closing source's reports still reached the hooks; the engine has no use for them.
* *The restart timer is cancelled when an arm begins.* The lifecycle function left it running, so a
  re-arm during backoff was followed by a second arm; here a late `RestartDue` would be stale anyway.
* *Tick mode is a field of its own.* Activity while polling made ticks `eventDriven` while the poll
  kept running, and the budget-release wake checked that mode; `_mode` keeps both exactly.
* *The ported tests' group is `WatchEngine`, not the old function's name*, which the acceptance grep
  forbids anywhere in `test/`; the nine test names are unchanged, checked against
  `git show HEAD:test/watch_lifecycle_test.dart`.
* *`_createLifecycle` keeps its name*: 0043's and 0045's `bounded` entries anchor on its call.

**Verification.**

```text
flutter test test/watch_engine_test.dart test/watch_lifecycle_test.dart
                                                  00:00 +25: All tests passed!   (before the deletion)
flutter analyze                                   No issues found!
dart format --output=none --set-exit-if-changed <14 changed .dart files>
                                                  exit 1: watch_engine.dart, watch_engine_test.dart; formatted, then exit 0
grep -rn 'watchLifecycle\|WatchHooks\|WatchArmed(' lib test
                                                  exit 1, no output
flutter test test/watch_engine_test.dart test/watch_transition_wiring_test.dart \
  test/remote_watch_service_test.dart test/local_watch_service_test.dart
                                                  00:08 +41: All tests passed!
flutter test                                      03:43 +4041 ~3: All tests passed!   (phase 3: +4034 ~3)
tool/mutate.py --check 0041 0043 0044 0045        67 entries in 4 catalogue(s): 67 sound, 0 did not apply, 0 do not compile (4m 26s)
```

The count is phase 3's plus the sixteen engine tests less the nine deleted. `record splitting a
large burst costs linear time, not a copy per record` — the test the synchronous signals were for —
passed in the full suite with every path now crossing the mailbox.

**Catalogue changes.** Six entries added to 0045: the plan's five, and `p4: a refusal after cancel
starts polling` (deviation (j)).

**Catalogue runs.** After `--check`, each catalogue one at a time with no other test run in
progress; each mirrored 18 uncommitted paths and 3 deletions, passed its baseline and recognised
the compile canary:

```text
tool/mutate.py 0041-watcher-teardown         27 killed, 0 survived, 0 did not apply, 0 did not compile, 0 observed by no test
tool/mutate.py 0043-one-watcher-per-repo      7 killed, 0 survived, 0 did not apply, 0 did not compile, 0 observed by no test
tool/mutate.py 0044-arm-readiness            10 killed, 0 survived, 0 did not apply, 0 did not compile, 0 observed by no test
tool/mutate.py 0045-watch-stack              23 killed, 0 survived, 0 did not apply, 0 did not compile, 0 observed by no test
```

The six new entries were killed by: `p4: a stale arm result is adopted` → `an arm result from a
superseded attempt is closed, not adopted`; `p4: a source arriving after cancel is left open` → `a
source arriving after cancel is closed`; `p4: a refusal after cancel starts polling` → `a refusal
arriving after cancel starts no polling`; `p4: a re-arm spends the restart budget` → `a re-arm spends
no restart budget and emits no stopped tick` (deviation (k)'s test, and no other); `p4: a budget
release wakes every refusal` → `a budget release wakes only a ceiling refusal` and `a refusal that is
NOT the ceiling is not woken by a slot release`; `p4: path overflow is ignored` → `path overflow at
maxPaths emits empty paths set`. Each new engine test is thereby seen to fail against the defect it
names; `a refusal arriving after cancel starts no polling` was also seen as the defect itself, on the
unmodified tree, by deviation (j)'s probe.

**Commit.** Code `360b846`. Its message is the hook's and does not name the deviations; they are
(h)–(l) above.

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
