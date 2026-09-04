---
status: proposed
date: 2026-09-03
associated-madr: "0023-MADR-commit-and-push-perceived-freeze.md"
---
# Implement the commit-and-push responsiveness work

Associated MADR: [0023-MADR-commit-and-push-perceived-freeze.md](0023-MADR-commit-and-push-perceived-freeze.md)

## Goal

Make commit-and-push *feel* immediate, then remove the work that is genuinely
ours. In priority order:

1. **P1** — the app stops looking frozen: show a real committing/pushing state
   and stop holding a modal over a push that is already streaming its progress.
2. **P2** — one refresh per commit+push instead of four.
3. **B8** — the one parse that can stall frames goes off the UI isolate.
4. **P3** — delete fixed per-operation overhead, and fix two latent bugs found
   alongside it.
5. **A1** — batch `_sync`'s bookkeeping, 4 round trips into 1.
6. **A2** — incremental History. Sequenced last, guarded narrowly, and the one
   item where "it turns out to do nothing" is an acceptable outcome.

The `pre-push` hook — the largest single term at ~9.5 s — **was already fixed**
(2026-09-03, recorded in the MADR). Nothing in this plan depends on it.

## Corrections to the MADR, established while gathering exact code

Two of the MADR's prescriptions are wrong as written. **Both must be amended in
the MADR before the corresponding phase executes.**

**C1 — "drop the redundant invalidation at `commit_dialog.dart:92`" would ship a
refresh gap.** It is not redundant. The two commit surfaces do not share a path:

* **Dock** (`repo_status_view.dart:824-826`) commits inside `runGuarded`, whose
  `finally` calls `refreshAfterAction()` → full `repoMutationFamilies`.
  Line 92 never runs on this path.
* **Sheet** (`commit_dialog.dart:81-86`) calls `git.commit` **raw** — no
  `runGuarded`, no `runLogged`, no refresh of any kind. Line 92 is the **only**
  invalidation the sheet's commit ever gets. With `push: false` it is already
  the sole refresh; with `push: true` it is covered today only because `_push`
  happens to do a full-set refresh — **which P2 removes**. Deleting line 92
  after narrowing `_push` breaks *both* sheet variants.

Corrected shape: give the sheet's commit the same refresh contract the dock
already has, and let `_push` do the narrow fetch-set refresh for the push.

**C2 — "resolve the upstream remote from `GitBranchInfo.upstream`" is not a
rename.** Two problems:

* `GitBranchInfo.upstream` is the upstream **shorthand** (`origin/main`), not
  the remote name. Deriving the remote requires a **longest-prefix match against
  the snapshot's `remotes` list** — *not* `split('/').first`, because remote
  names may legally contain `/`, and because a branch tracking a *local* branch
  yields a bare branch name with no remote prefix at all. The existing probe
  special-cases that as `'.'` (`git_service.dart:4981-4983`); porcelain never
  prints `.`, it prints the local branch shorthand, so a naive split would
  return `main` as a "remote name" and silently drop the credential helper.
* **`GitService` holds no cached snapshot.** `_snapshotInFlight`
  (`git_service.dart:1947`) holds in-flight futures only and is cleared on
  completion. Calling `_snapshot()` from `push()` would issue a whole new
  combined round trip — *worse* than the 37.6 ms probe it replaces.

Corrected shape: **plumb the value in from the caller**, which already has it in
RAM, keeping the existing probe as the fallback. Details in Phase 4.

## Scope

**In scope:** P1, P2, P3, A1, A2, B8, and the bugs the MADR lists that fall
inside them (B1–B7, B9).

**Out of scope:**

* The `pre-push` hook — already fixed.
* `--no-verify` on the app's commit or push. Rejected in the MADR on principle:
  the app must not disable a user's hooks to flatter its own timings.
* libgit2 / in-process git (0001).
* Raising `networkTimeout`, or cancelling an in-flight fetch/push (0020
  residuals).
* Streaming progress across the secondary-window proxy channel (0020 residual).
* Making `git commit` non-exclusive. It genuinely takes `.git/index.lock`.

## Conventions that bind every phase

Same as 0022's, and not restated per phase:

1. **Analyzer-clean on the first pass**, to the repo's strict modes.
2. **Never `dart format` globally** — only files this plan edits.
3. **Never write commit message text.** `git commit --no-edit` only.
4. **Never `git push`** unless asked in that same turn.
5. **Never run `live-forge` tests.** Note `test/create_repo_wire_live_test.dart`
   asserts forge-auth argv and is **`live-forge`-tagged — do not run it** even
   though Phase 4 changes code it covers.
6. **A check is not trusted until seen to fail.** Every new test names the
   deliberate breakage that must make it fail, run against a **scratch clone**,
   with an assertion that the sabotage target existed before editing.
7. **Deviations stop execution** — evidence, real resolutions, decision,
   recorded here, then proceed.
8. **Per-phase commit**, gated on **no new analyzer issues and no new test
   failures relative to the Phase 0 baseline** — compare the failing **set** and
   the **passing count**, since a file that fails to compile reports one
   "loading" failure while silently not running its whole suite.
9. `lib/core/providers/app_providers.dart` and `lib/core/git/git_service.dart`
   are grep-binary — use `grep -a`.

## Implementation Steps

### Phase 0 — Baseline

Identical method to 0022's: take it on a **pristine `git clone --local` at
HEAD**, `flutter pub get` → `analyze` → `test`, nothing edited during the run.
Record the analyzer issue list and the **complete failing-test set**, not counts
alone.

Expect the two known pre-existing `unawaited_return_in_try_block` warnings and
the 48 `workspace_golden_test.dart` golden failures. **Acceptance:** both
recorded verbatim; any *unexplained* failure blocks the plan.

---

### Phase 1 — P1: the app stops looking frozen

**Objective.** Feedback during commit+push, and the modal no longer outlives the
commit. This changes no git timing and is the phase that answers the complaint.

**Two prerequisites, first, in this order.**

1. **Guard the post-dispose notify.** `commit_composer_controller.dart` has a
   `_disposed` flag and a guarded `_notifyListeners()`, but `submit()`'s
   `finally` (`:365`) and `clearDraft` (`:162`) call **raw** `notifyListeners()`.
   Once the sheet can pop while `submit()` is still awaiting the push, a
   controller rebuild (the provider does `ref.watch(gitServiceProvider)`) can
   dispose the instance mid-flight and that raw call throws. Change both to
   `_notifyListeners()`.
2. **Thread an `operationId` through `_streamGitOp`.** `startStream` **already**
   accepts `{OperationId? operationId}` and `firstIndexForOperation` already
   exists (`output_log.dart:153`, `:160`) — no caller passes one. Without it the
   reveal path cannot scroll to the push's output and a *running* Activity
   Center row has no Output button, so "your push is still running, see Output"
   would point at something the app cannot navigate to.

**Then the change itself.**

3. **Render the committing state.** `commit_composer.dart:238` gates the only
   `ProgressCircle` on `loadingPreview && message.isEmpty`. Add a
   `controller.committing` indicator, and extend `_statusText` (`:472-493`),
   which currently keeps showing *"Generated by prepare-commit-msg. Review,
   Edit, or Accept."* for the whole span — text that instructs the user to press
   a button the same state has disabled.
4. **Pop the sheet when the commit lands, not when the push finishes.**
   `commit_dialog.dart:_accept` (`:73-103`) awaits `submit()`, which runs commit
   **then** push internally (`commit_composer_controller.dart:336`, `:354`).
   `CommitComposerOutcome` already distinguishes `localCommitted` from
   `pushSucceeded`. The sheet must close on the commit and let the push
   continue.
   **This requires a seam `submit()` does not currently offer** — it gives no
   callback between commit and push. Add one (e.g. an `onLocalCommitted`
   callback invoked after `clearDraft()` at `:347` and before the push branch),
   rather than restructuring the two-phase contract.
5. **Narrow the Escape interception.** `commit_dialog.dart:58-71` passes
   `() => _controller.committing`, which swallows Escape for commit *and* push.
   It should swallow only while the commit itself is in flight.

**Safety — verified, not assumed.** `commitComposerControllerProvider` is a
plain `Provider.family`, **not** `autoDispose` (`commit_composer_controller.dart:370-371`),
and `repo_status_view.dart:1555` also watches it, so it outlives the sheet.
`onPush` closes over `RepoStatusView`, not the dialog. Nothing the push reads is
owned by the sheet.

**State the plan must record, not discover later:** `_push` passes
`holdBusy: false` (`repo_status_view.dart:1000`), so the workspace is **already**
interactive during a push — nothing today prevents starting a second commit
while the first push is in flight. Popping the sheet *exposes* this; it does not
create it. If that is unacceptable it needs its own decision, not a silent
guard bolted onto this phase.

**Tests.** `ls test/ | grep -i commit` for the existing suites. New:
a `committing` state renders an indicator and does not render the
"Review, Edit, or Accept" instruction; the sheet pops on `localCommitted` while
the push future is still pending; Escape is swallowed during commit and honoured
during push.

**Negative test.** Revert the pop-on-commit and assert the sheet is still
mounted while the push is pending — the test must fail.

**Acceptance.** Baseline-relative analyzer/tests; the three new tests pass and
fail when reverted.

---

### Phase 2 — P2: one refresh per commit+push

**Objective.** Four full-set fan-outs (≈22–40 git processes for a one-file
commit) become one narrow one.

1. **`_push` refreshes the fetch set.** `repo_status_view.dart:983-1001` passes
   no `refresh:`, so `busy_action.dart:152` falls back to the full 11-family
   set. Pass `refresh: () => refreshAfterFetch(ref, repoPath)`, exactly as
   `_fetch` does (`:866`). Justified by `repoFetchFamilies`' own docstring
   (`app_providers.dart:2937-2940`): *"Providers a fetch **or push** can
   stale… Not History, stashes, reflog, snapshots, or worktrees — those do not
   move when HEAD and the worktree do not."* The delta dropped is exactly
   `logProvider`, `logSearchProvider`, `stashesProvider`, `reflogProvider`,
   `magicSnapshotsProvider`, `gitWorktreesProvider`.
   Leave `refreshRemoteTags` (`:1016`) alone, and note `_push`'s
   "Pull, then Push" branch (`:949-953`) delegates to `_sync`, which keeps the
   full set — correct, the pull moves HEAD.
2. **Wrap `_pull`, `_push`, `_sync` in `withOwnMutation`** — copying `_fetch`
   (`:852-862`) and `_fetchPrune` (`branches_view.dart:1611-1636`).
   **Placement is load-bearing: wrap the INSIDE of the `runLogged` body closure,
   never the `runLogged(...)` call.** Two reasons, both verified:
   * `runLogged`'s `finally` refresh (`busy_action.dart:152`) must run *after*
     `end()`/`mark()`, so the mark precedes the invalidation and the watcher
     echo ≤3 s later is suppressed. Outer wrapping inverts that order.
   * `runLogged`'s catch `await showErrorDialog(...)` blocks on the user, and
     `isRecent` returns true unconditionally while in-flight
     (`app_providers.dart:2732`). Outer wrapping would keep `_inFlight > 0` for
     as long as the dialog is open, suppressing **genuinely external** changes
     indefinitely.
3. **Filter `COMMIT_EDITMSG`.** `watch_path_filter.dart:23-30` drops `*.lock`,
   `/objects/`, `/logs/`, `/fsmonitor--daemon/` inside `.git`, but not
   `COMMIT_EDITMSG` — which git writes ~250 ms into every commit, firing a full
   invalidation that then queues behind the commit's own exclusive barrier.
   Use `endsWith('/COMMIT_EDITMSG')` so both `.git/COMMIT_EDITMSG` and
   `sub/.git/COMMIT_EDITMSG` match.
   **Safe:** nothing in `lib/` reads it — the only occurrence is a comment at
   `git_service.dart:3308` saying the app deliberately avoids it.
   `docs/ARCHITECTURE_PLAN.md:422-425` already prescribes ignoring it; the
   filter simply never implemented that half. (`MERGE_MSG` *is* read, on demand
   via a shell read, never via a watch tick — leave it alone.)
4. **Give the sheet's commit a refresh contract** — see correction **C1**.
   Do **not** delete `commit_dialog.dart:92`. Move the invalidation so it fires
   when the commit lands rather than after `submit()` returns, using the
   `onLocalCommitted` seam Phase 1 adds. That also removes the orphaning: today
   line 92 fires *after* `_push` already invalidated, discarding in-flight reads
   whose git processes keep running and holding read-lane slots (the hazard is
   documented at `repo_status_view.dart:518-526`).
5. **Move `_logPushed` off the awaited span** (0020 M3, which landed against
   `_busy` but never against this surface's modal). `repo_status_view.dart:1005-1013`
   runs two reads — one a real `git diff --name-status` — inside the span the
   sheet waits on.
6. **B9, decide explicitly.** `branchBaseProvider` is in **both** family lists
   and, in Review mode only (`branches_view.dart:298`), awaits a `gh`/`glab`
   call that the cache does **not** short-circuit (`app_providers.dart:3550-3557`
   re-fetches unconditionally when `allowForgeFetch` is true). Either make the
   forge branch non-blocking or drop `branchBaseProvider` from the *mutation*
   set (the fetch set already has it). **Choose one and record why** — this is a
   behaviour decision, not a mechanical edit.

**Tests.** `repo_mutation_refresh_test.dart:286-305` is a **source-text scan**
idiom; a `_push` equivalent can follow it, but a **behavioural** assertion is
stronger and available: `repo_status_watch_refresh_test.dart`'s harness keeps
`logProvider(_repo)` mounted via `container.listen` as a fetch counter — drive a
push and assert `logProvider` does **not** refetch while `refsProvider` does.
Add the `COMMIT_EDITMSG` case to `watch_path_filter_test.dart`'s noisy-paths
list. Note `repo_mutation_refresh_test.dart:242-284` **bans hand-rolled
invalidations** anywhere in `lib/` outside `app_providers.dart` — new code must
go through the helpers.

**Negative tests.** Revert `_push`'s `refresh:` → the log-refetch test must
fail. Remove the `COMMIT_EDITMSG` clause → its filter case must fail.

---

### Phase 3 — B8: the refs parse goes off the UI isolate

**Objective.** Remove the only mechanism that can freeze *frames*.

`git_service.dart:2156-2159`: the porcelain parse is gated at
`_isolateThreshold` (32 KiB) and the `for-each-ref refs/heads refs/remotes
refs/tags` parse on the very next line — routinely the **larger** section — is
not. Mirror the gate.

**Put the gate in `_assembleSnapshot`, not inside `parseRefsDetailed`**, which
is synchronous and used directly by `test/refs_parse_test.dart` and the legacy
`parseRefs` facade. `_assembleSnapshot` is already `async`
(`git_service.dart:2122`), and `Isolate.run` captures only `refsStdout` (a
`String`); `RefsResult` is a plain class of `String`/`int?`/`bool` finals, so it
is sendable.

**Tests.** A large synthetic ref payload (>32 KiB) parses identically to the
small path. Watch `test/workspace_performance_baseline_test.dart` — it holds the
parse budgets and will trip first on any snapshot regression.

---

### Phase 4 — P3: delete the fixed per-operation overhead

**4a. Upstream remote without the probe** — see correction **C2**.

Add an optional parameter (e.g. `String? upstreamRemote`) to `fetch`, `pull`,
`push`; when null, fall back to today's `_upstreamRemote` probe unchanged.
Callers in `repo_status_view.dart` fill it from
`statusProvider(repoPath).value?.branch`, already in RAM.

The derivation **must** be a longest-prefix match of `GitBranchInfo.upstream`
against the snapshot's `remotes` list. It must reproduce every fallback the
probe has:

| case | probe today | required |
|---|---|---|
| tracking `origin/main` | `origin` | `origin` |
| no upstream configured | `origin` | `origin` |
| detached HEAD | `origin` | `origin` |
| tracking a **local** branch (`.`) | `origin` | `origin` — a bare branch name matches no remote, so prefix-match yields none |
| remote name containing `/` | correct | correct only via prefix match, **not** `split('/')` |

**Two cases the snapshot cannot answer, and the plan does not pretend
otherwise:** an unborn branch with a configured upstream (whether git emits
`# branch.upstream` alongside `# branch.oid (initial)` is version-dependent and
was **not** verified against a live git), and a half-configured
`branch.<n>.remote` with no resolvable `.merge`. Both degrade to `origin`, which
is auth-only degradation — the same class the probe's own fallback accepts. If
either matters, keep the probe for `oid == null`. **Verify the unborn case
against real git during execution rather than assuming.**

**4b. Gate credential helpers on scheme.** `_forgeAuthArgs`
(`git_service.dart:4922-4949`) holds the URL in a local at `:4938`, so the gate
is a guard at that call site. **No "is SSH" helper exists** — write it as
**"is HTTP(S)"** so unknown schemes keep today's behaviour: `ssh://`, `git://`,
`file://` and the scp-like `git@host:owner/repo` form (which has no `://` at
all) all fall through to no helper.

**Do NOT** fold in the `fetch --all` half in this phase.
`forgeGitAuthConfigArgsAll` (`git_service.dart:5020-5023`) installs both helpers
blind with **no URL lookup at all**; gating it needs every remote's URL, which
means either a new cached `git config --get-regexp '^remote\..*\.url$'` read or
folding URLs into the snapshot. Both are worthwhile and both are a different
change — record as a follow-up, do not smuggle it in.

**4c. Pull's integrate half gets a real timeout.** `git_service.dart:5086-5094`
passes no `timeout`, taking `SSHCommandExecutor.defaultTimeout` = **60 s**
(`ssh_command_executor.dart:300`). A long rebase, or a merge invoking a merge
driver or `post-merge` hook, is SIGTERM'd mid-operation leaving
`.git/rebase-merge` behind. Use `commitTimeout` (5 min).
**State explicitly whether `merge` (`git_service.dart:4675-4714`) and
`cherryPick` are in scope** — they take the same 60 s default. Recommended:
same phase, same reasoning; if excluded, say so here.

**4d. `onOutput` for the four network ops that lack it** — `pushTags` (`:5223`),
`deleteRemoteTag` (`:5257`), `deleteRemoteBranch` (`:4183`), `lsRemoteTags`
(`:5295`). Note `lsRemoteTags`' only caller is `remoteTagsProvider`
(`app_providers.dart:4164-4178`), a **provider with no `OutputLogNotifier`** —
so an `onOutput` there has no consumer today; either skip it or say why it is
added anyway. The five view call sites in `branches_view.dart` use buffered
`log.logResult`, so they need `_streamGitOp`-equivalent wiring to benefit.

**Tests — this phase breaks the most.** `test/mutations_test.dart` pins the
probe argv (`const upstreamProbe`, `:585`) and **all six call indices** of
`'fetch / pull / push'` (`:591`), plus `:639` (hard count `networkCalls == 7`),
`:684`, `:699`, `:723` (the memoization 4a replaces), `:744`, `:863`
(`'pull fetch is sync; integrate is exclusive'` — **4c must not disturb this**),
and `:902` (`'a branch tracking a non-origin remote routes auth through THAT
remote'` — **the exact scenario 4a's prefix match must still satisfy; treat it
as the acceptance test**). Scheme gating also touches
`test/forge_detection_test.dart:192`.

**Negative tests.** Replace the prefix match with `split('/').first` → the
non-origin-remote test and a new local-branch-tracking test must fail. Revert
4c's timeout → assert the integrate call carries `commitTimeout`.

---

### Phase 5 — A1: batch `_sync`'s bookkeeping

**Objective.** 6 bookkeeping round trips → 3 (or 2), and kill a literal
duplicate.

`_sync` (`repo_status_view.dart:1020-1054`) plus `_logPulled`/`_logPushed`
(`:1056-1081`) issue, in order: `rev-parse HEAD` (**before** the pull) →
*pull* → `rev-parse @{upstream}` (**between** pull and push) → *push* →
`rev-parse HEAD` → `diff --name-status` → **`rev-parse HEAD` again** →
`diff --name-status`.

**Only the last four are batchable.** The first two are ordering-critical —
`before` must precede the pull, `pushBase` must sit between pull and push.
Batch #3–#6 into one `sh -c` capture script issued after the push, mirroring
`_runCaptured`'s `printf`-separator pattern (`git_service.dart:5935-5945`,
separator `_undoSep` at `:1938`). That collapses the duplicate `rev-parse HEAD`
and takes 6 → 3.

Optionally take `before` from `GitBranchInfo.oid` (in RAM, same source as
Phase 4a) for 6 → 2 — but it must be an explicit read at `_sync` entry, not a
`ref.watch`, or the watcher may have already refreshed it. `pushBase` has no RAM
source (it is `@{upstream}` *after* the pull moved it); keep that round trip.

**Test seam — a real trap.** `test/push_logs_output_test.dart:45-51` fakes this
path by overriding `GitService.revParse` and `GitService.changedFiles` and
asserts `'Pushed — 2 files'` (`:191`). If A1 replaces those with a new batched
method, **both overrides go dead and the test silently stops exercising what it
claims to.** Either make the new method the seam the fake overrides, or update
the test in this same phase. Do not leave it passing vacuously.

**Also add the missing test.** Nothing currently asserts `_sync`'s
pull-then-push ordering or its skip-push-on-pull-failure invariant (documented
at `repo_status_view.dart:950`); `test/sync_group_test.dart` covers the button,
not the body.

---

### Phase 6 — A2: incremental History (guarded, last, may legitimately do nothing)

**Objective.** Stop re-walking 200 commits (`logProvider`) and a ≥500-commit
page (`logSearchProvider`, deeper if the user paged) on every mutation refresh.

**Do the cheap thing first, and consider stopping there.** `logProvider`'s only
consumers are the dashboard's 30-day chart and a 200-capped stat
(`dashboard_sheet.dart:480,541,551`) and the command palette
(`command_palette.dart:770`) — **History does not read it**
(`repo_status_view.dart:498-499`). It may simply not belong in
`repoMutationFamilies` at all: a one-line change with far better risk/reward
than making it incremental. It is a `FutureProvider` with no notifier, so making
*it* incremental would mean converting it to an `AsyncNotifier` — and
`repo_status_watch_refresh_test.dart` uses it as a **fetch-counting probe**
(`:69,83,122,142,159,173,193`), so its refetch cadence is load-bearing in the
suite. Removing it from the mutation set needs a test update, not a silent
deletion (`repo_mutation_refresh_test.dart:169`, `:286`).

**Then, only if still warranted, the guarded prepend for `logSearchProvider`.**
Mechanically the model supports it: the list is a plain `List<GitCommit>`,
`loadMore` already does an ordered merge with hash dedupe
(`app_providers.dart:4436-4437`), and `_depth` survives invalidation. What
breaks:

* **A prepend is sound only for a fast-forward.** `rev-list old..new` names new
  commits but says nothing about commits that *disappeared* — amend, rebase,
  `reset --hard`, squash-merge, undo and interactive rebase all rewrite history
  and all go through `repoMutationFamilies`. Proving the tip only moved forward
  needs an ancestry check, i.e. **an extra round trip on the path being
  optimised** — unless the mutating site supplies its pre-mutation HEAD.
  `_runCaptured` already captures `preHead`/`postHead` in-script, which is the
  natural source, but plumbing an OID pair from `GitService`'s undo capture to a
  Riverpod notifier (and across the window relay) is the bulk of the work.
* **`--all` cannot prepend at all.** `CommitGraph.build` requires
  parent-before-child ordering and `git_service.dart:2380-2389` names `--all` as
  the case where topo and date order diverge; a commit on another branch
  interleaves mid-list, not at the top.
* **`sha:` queries have no incremental form** (`--no-walk`, `_exhausted = true`).
* `_exhausted` and `loadMore`'s `--skip=current.length` contract need
  re-derivation once length ≠ one `--max-count=_depth` walk.
* `AsyncNotifier.build` cannot read `state` before assigning, so the previous
  list needs a plain field — which `test/history_paging_test.dart` (10 tests,
  several asserting exact command counts, e.g. `:207` "a refresh re-walks the
  whole displayed prefix in ONE call") will police hard.

**Defensible scope:** a fast-forward-only prepend for a single-revision,
unfiltered query with an ancestor-proven tip move, falling back to today's full
re-walk everywhere else. That is four guards protecting one optimisation.
**The plan states plainly: if those guards are rarely satisfied in practice,
this phase correctly does nothing, and that is an acceptable result — not a
reason to loosen them.**

---

### Phase 7 — Final verification

1. `flutter analyze` — no new issues vs Phase 0.
2. `flutter test` — failing **set** identical to Phase 0; passing count ≥
   baseline + new tests.
3. Confirm every negative test was run and observed failing.
4. **Measure the outcome, do not assert it.** Re-time a one-file commit+push in
   the real app and record: wall clock, whether the workspace stayed
   interactive, and the number of git processes for one commit+push (compare
   against the ≈22–40 baseline). A plan about perceived performance that ships
   without a measurement has not been verified.
5. Fill in the Execution Record: what each phase did, verbatim verification
   output, every deviation dated with its decision, and anything **not** done
   with the reason.
6. Report the branch is ahead by N commits and **offer** the push command.

## Verification

Per phase: analyzer and suite compared to the Phase 0 baseline by **set and
count**; the phase's own tests passing; each new test observed failing against a
deliberately broken scratch clone.

```sh
flutter pub get
flutter analyze
flutter test
flutter test test/<file>_test.dart
flutter test --plain-name "substring"
```

Never `--run-skipped -t live-forge`.

## Rollout and Rollback

**Rollout.** One commit per phase, in order, on a branch off `master`.
Phases 1–2 are the user-visible ones and are worth landing and *using* before
the rest. Phase 3 is independent. Phase 4 is the most test-disruptive. Phases 5
and 6 are optional tail.

**Rollback.** Each phase is one revertable commit over a disjoint file set,
except Phases 1 and 2, which share `commit_dialog.dart` (the `onLocalCommitted`
seam) — revert as a pair.

**Risk, highest first.**

* **Phase 4a** — a wrong remote derivation silently installs the wrong
  credential helper and breaks HTTPS auth. Mitigated by keeping the probe as
  fallback and by treating `mutations_test.dart:902` as the acceptance test.
* **Phase 1** — the sheet popping while a push runs is a deliberate interaction
  change; it also exposes that a second commit can already be started mid-push.
* **Phase 6** — largest change, most tests, most likely to be abandoned.
* **Phase 2's `COMMIT_EDITMSG` filter** — suppressing a watch path is
  irreversible-feeling if wrong; mitigated by the grep proving nothing reads it.

**No migration.** Nothing changes a persisted schema.

## Execution Record

### Phase 0 — Baseline (2026-09-03)

Taken on a pristine `git clone --local` at HEAD `8971b7d`, clean, nothing
edited during the run.

* **Analyzer: 2 issues** — the two known pre-existing
  `unawaited_return_in_try_block` warnings (`pinned_branches.dart:29`,
  `image_diff_view.dart:105`).
* **Suite: `+3340 ~2 -48`** — all 48 failures in `workspace_golden_test.dart`
  (the known un-accepted goldens), 2 skipped (`live-forge`).
* Gate for every phase: that failing **set**, and a passing count not below
  3340.

### Phase 1 — P1: the app stops looking frozen (2026-09-03) — **COMPLETE**

**Done.**
* **Post-dispose guards.** `clearDraft` and `submit()`'s `finally` used raw
  `notifyListeners()`; both now use the `_disposed`-guarded `_notifyListeners()`.
  Necessary because the sheet now closes while `submit()` is still awaiting the
  push, and a controller rebuild in that window would otherwise throw.
* **`onLocalCommitted` seam** on `submit()`, fired after `clearDraft()` and
  before the push branch — the callback the two-phase contract never offered.
* **`localCommitLanded`** on the controller: `committing` alone cannot tell the
  two halves apart, and they want opposite treatment — the commit is brief and
  must not be interrupted, the push is a long wait the user must be able to
  walk away from.
* **The sheet closes on the commit**, not the push. `closeOnCommit()` refreshes
  for the commit and pops; a belt-and-braces call after `submit()` returns
  covers a future refactor that drops the seam.
* **Escape narrowed** to `committing && !localCommitLanded`.
* **Real feedback**: a `ProgressCircle` gated on `committing` — previously the
  only spinner was gated on `loadingPreview` — and `_statusText` now says
  "Committing…" then "Committed. Pushing… you can close this; it continues in
  the background", instead of "Review, Edit, or Accept", which had been
  instructing the user to press a button the same state disabled.

**Deviation (a) executed** — see above: `operationId` plumbed through
`_run`/`fetch`/`pull`/`push`, `_streamGitOp` mints one id for both the
transcript and the operation, and `outputAnchorId` is now emitted for
`running` so a push is reachable from the Activity Center *while* it runs
rather than only after it ends.

**Collateral, caught by the analyzer:** seven test fakes override
`fetch`/`pull`/`push` and needed the new parameter (`auto_fetch_test`,
`branches_view_guards_test`, `commit_dialog_test`, `create_mr_form_test`,
`create_pr_form_test`, `push_logs_output_test`, `repo_status_view_test`). Left
unfixed these fail to **compile**, which reports as one "loading" failure while
silently not running the whole file — the exact miss the hardened gate exists
to catch.

**Test added.** `commit_dialog_test.dart`: with the push gated open, the commit
lands, the push is still outstanding, and `CommitDialog` is **gone**. Note it
pumps explicit frames rather than `pumpAndSettle` — the committing spinner
animates for as long as the push is outstanding, so settling would time out.
The pre-existing "Escape is blocked while a commit is in flight" still passes,
so narrowing Escape did not weaken it.

**Negative test — seen to fail.** Seam disconnected in a scratch clone (with an
assert that the wiring existed first): `Expected: no matching candidates /
Actual: Found 1 widget with type "CommitDialog"` — the sheet still up while the
push hangs, which is the reported symptom exactly.

**Verification.** Analyzer: 2, the baseline's. Suite: `+3341 ~2 -48`, failing
set **identical** to baseline.

### DEVIATION 2026-09-03 (a) — Phase 1's prerequisite #2 was wrong as written

**What the plan said.** "Thread an `operationId` through `_streamGitOp`.
`startStream` **already** accepts `{OperationId? operationId}` … no caller
passes one." — implying a one-line wiring.

**Why it is wrong.** `startStream` does accept one, but the id has to *match*
the Activity Center row's, and it cannot:

* `_run` builds its `OperationDescriptor` with **no id**, so the executor mints
  one internally (`OperationLifecycleEmitter.begin` → `descriptor.id ??
  OperationId.next()`). Only `_runCaptured` sets an explicit id
  (`git_service.dart:5948`). An id minted in `_streamGitOp` would simply be a
  *different* id, so revealing by the row's id would find nothing in the log —
  worse than leaving it unwired.
* `outputAnchorId` is emitted **only on terminal phases**
  (`operation_activity.dart:267-272`), so a *running* row has no Output button
  regardless of ids.

Doing it properly needs an optional `OperationId` on the network methods →
`_run` → the descriptor, **plus** a running-phase anchor. That is a GitService
signature change the plan did not cost.

**Decision (maintainer, 2026-09-03): option 2 — do it now.** The alternative
offered was deferring it as a follow-up, since Phase 1's core value was already
delivered and the shipped copy ("you can close this; it continues in the
background") does not promise navigation. Chosen instead to complete the
feature so a running push is reachable from the Activity Center rather than
only from a docked view the user may have hidden.

**Scope added to Phase 1:** `git_service.dart` (`_run`, `fetch`, `pull`,
`push`), `operation_activity.dart` (running-phase anchor).



Not yet executed. This plan is `proposed`.

**Corrections C1 and C2 were applied to the MADR on 2026-09-03**, before any
implementation, as Amendments A1 and A2 there. The original prescriptions are
struck through in place rather than rewritten, so the MADR shows what was
decided and what disproved it. This plan's C1/C2 and the MADR's A1/A2 are the
same two corrections stated for their two audiences — no daylight between them.

On approval, each phase appends what it did, verbatim verification output, dated
deviations, and anything deliberately skipped with its reason.
