---
status: accepted
date: 2026-08-28
verified: 2026-08-28
decision-makers: [Maintainer]
consulted: []
informed: []
---

# Make fetch, pull, and push feel live: split pull, stream progress, and stop refreshing the world

## Context and Problem Statement

Fetch, pull, and push in Magic Git have become laggy and janky: the UI
freezes or greys out for the whole transfer, output stays blank until the
command dies or finishes, and the rest of the workspace hitch-steps while
the op is still on the wire.

This is a macOS-only Flutter client that runs `git` on a host — SSH
(`SSHCommandExecutor`) or this Mac (`LocalCommandExecutor`) — through
`CommandLaneScheduler`. Network ops are supposed to be the load the
scheduler was built for: fetch/push on `ExecLane.sync` (overlap reads, one
sync at a time, dedicated SSH sync client when attached), pull as an
index/worktree mutation, activity deadlines so a quiet peer dies, clone
already streams `--progress` into the output log.

The open questions for this pass:

1. What **correctness / stall bugs** make a transfer look hung, or kill one
   that is still moving?
2. What **scheduler and argv choices** make the op itself slower than git
   needs to be?
3. What **UI contracts** (busy gate, buffered output, post-op refresh)
   turn a legitimate network wait into workspace jank?
4. How should remediation be **prioritized** without reopening libgit2
   ([0001-MADR-native-git-libgit2.md](0001-MADR-native-git-libgit2.md)) or
   the SSH engine records (0011 / 0013 / 0014)?

This MADR is the decision record for direction and priority. The findings
are evidence, not optional design alternatives — they were verified against
source on 2026-08-28. Tests and a live session were **not** re-run; numbers
below are from the tree, not a production drop ring.

### Audit method

* Read `GitService.fetch` / `pull` / `push` and the probe helpers they call
  (`_upstreamRemote`, `_forgeAuthArgs`) in `lib/core/git/git_service.dart`.
* Read the executor drain (`SSHCommandExecutor._runBody`,
  `LocalCommandExecutor._run`), `ActivityDeadline`, `CommandLaneScheduler`,
  and `CommandFormatter.defaultEnv`.
* Read the UI runners: `BusyActionState.runLogged`, `RepoStatusView`
  `_fetch` / `_pull` / `_push` / `_sync` / `_logPulled` / `_logPushed`,
  `autoFetchProvider`, `ConnectionController.fetchInBackground`.
* Read post-op refresh: `repoMutationFamilies`, `refreshAfterMutation`,
  `RepoStatusView` / `HistoryView` watch listeners, `refreshRemoteTags`.
* Cross-check clone's live-progress path (`CloneController` +
  `OutputLogNotifier.startStream`) against fetch/pull/push, which still
  buffer then `logResult`.
* Cross-check `docs/ARCHITECTURE_PLAN.md` §0.1 (sync client exists so pack
  transfer does not share a TCP connection with interactive reads).

## Decision Drivers

* **A transfer that is still emitting (or could emit) bytes must not be
  declared idle.** The activity deadline is a stall detector, not a "git
  was quiet because nobody asked it to talk" detector.
* **Interactive reads must keep flowing during pack transfer.** That is why
  the sync lane and the third SSH client exist
  ([0014-MADR-ssh-engine-next-wave-hardening.md](0014-MADR-ssh-engine-next-wave-hardening.md),
  `ARCHITECTURE_PLAN.md` §0.1).
* **The busy gate serializes index/worktree mutations, not the network.**
  Holding it across fetch/push fights the scheduler the services already
  declared.
* **Refresh in proportion to what moved.** A fetch that does not move HEAD
  must not re-walk History. A no-op fetch must not look like a commit.
* **Root-cause argv and lane choices, not longer timeouts.** Widening
  `networkTimeout` hides a silent transfer; it does not make it live.
* **Scope control.** Submodule UI, LFS, and a full progress parser are
  product; `--progress`, pull-split, and refresh-scope are not.

## Considered Options

* **A. Tune timeouts and leave argv/lanes/UI as they are** — raise the
  stall budget, keep `git pull` exclusive for the whole network, keep
  `git fetch --all --prune` on every path, keep buffered output.
* **B. Accept this audit as the prioritized backlog and the technical
  direction** — split pull into fetch (sync) + integrate (exclusive);
  force `--progress` and stream it like clone; scope `--all` to the
  call sites that mean all remotes; stop busy-gating fetch/push; refresh
  refs/status after fetch, not History; drop the extra auth probes and
  the post-fetch `ls-remote` from the critical path. Companion PLAN
  required before source changes.
* **C. Replace CLI git for network ops (libgit2 / git2dart / in-process
  fetch)** — already rejected by 0001; would not fix the UI busy gate or
  the refresh-scope bugs on its own.

## Decision Outcome

Chosen option: **"B. Accept this audit as the prioritized backlog and the
technical direction"**, because the lag is not one slow `git` — it is a
stack of documented choices that fight each other: pull occupies the
exclusive barrier (and the command SSH client) for a pack transfer the
sync client was built to carry; fetch/push never pass `--progress`, so the
stall detector and the UI both see silence; every fetch is `--all --prune`
including the post-commit "update ahead/behind" path; and every completion
invalidates History. Option A treats the symptom. Option C reopens a
closed decision and misses the UI/refresh half.

This record does **not** authorise implementation. A paired PLAN is
required before any source change.

### Consequences

* Good, because HIGH items have file-level evidence and a single
  technical direction (pull-split, `--progress`, refresh-scope).
* Good, because the sync-lane / sync-client investment in 0014 starts
  covering pull's fetch half, which today never uses it.
* Good, because clone already proves the streaming-output pattern
  (`OutputLogNotifier.startStream` + `--progress`).
* Neutral, because live macOS QA may re-rank a MED (dead remotes, `--jobs`)
  above a HIGH if a particular host is the user's daily driver.
* Bad, because splitting `git pull` is a behaviour-preserving refactor
  that must keep `PullMode` (ff-only / rebase / merge), forge credential
  helpers, and the output-log "files moved" report — a companion PLAN has
  to spell the argv, not hand-wave "fetch then merge".
* Bad, because streaming progress through `execute()` (on-queue) is new
  surface: `executeStream` is the wrong tool (it bypasses the scheduler).
  The PLAN must add a progress callback on the request/response path, not
  route fetch off-queue.

### Confirmation

* HIGH fixes land analyzer-clean with targeted tests: fetch/pull/push argv
  (`--progress`; pull is fetch+integrate; probes do not precede the
  network op), lane assertions (fetch/push/fetch-half of pull are
  `ExecLane.sync`; integrate is `ExecLane.exclusive`), activityIdle still
  rides the network command, History is not in the fetch refresh set.
* A fetch against a non-TTY executor produces stderr progress frames that
  the output log tails *before* the process exits (clone already pins this
  shape in `output_log_stream_test.dart`).
* An in-flight fetch does not set `BusyActionState.busy` on Repository;
  an in-flight pull still does.
* This MADR's HIGH section is empty or marked fixed after a remediation
  cycle (update `verified:` and a short Remediation log; do not silently
  rewrite historical findings).
* Companion PLAN: [0020-PLAN-fetch-pull-push-lag.md](0020-PLAN-fetch-pull-push-lag.md)
  owns phased delivery. It must not invent a different architecture
  without amending this decision.

## Pros and Cons of the Options

### A. Tune timeouts and leave argv/lanes/UI as they are

* Good, because zero design work.
* Bad, because a silent `git fetch` without `--progress` is *supposed* to
  look idle — raising `networkTimeout` only delays the false stall kill.
* Bad, because pull still head-of-line-blocks every status/diff/log read
  for the whole pack transfer.
* Bad, because the post-commit and auto-fetch paths still fetch every
  remote and then re-walk History.

### B. Prioritized backlog + technical direction (chosen)

* Good, because each HIGH maps to one root cause (lane, argv, refresh
  set, busy gate, missing `--progress`).
* Good, because it reuses clone's streaming log and 0014's sync client
  rather than adding a fourth transport.
* Neutral, because a PLAN still has to sequence the `execute()` progress
  callback so fetch stays on the sync lane.
* Bad, because "fetch then merge" must not regress conflict / ff-only
  refusal / rebase-in-progress handling that today's single `git pull`
  gives for free.

### C. Replace CLI git for network ops

* Good, because an in-process fetch could report sideband progress
  without `--progress` hacks.
* Bad, because 0001 already rejected libgit2/git2dart: signing, SSH
  remotes, credential helpers, and host git config are the product.
* Bad, because it does not fix the busy gate, `--all` on post-commit
  fetch, or History invalidation — those are app bugs.

## More Information

### Severity legend

| Sev | Meaning |
| --- | --- |
| **HIGH** | Incorrect behaviour, false stall, or a path that freezes interactive git for the whole transfer |
| **MED** | Extra round trips, over-fetch, or refresh that is correct but disproportionately expensive |
| **LOW** | Polish (elapsed ticker, cancel button) that makes a long op honest |

---

### HIGH — fix first

#### H1. `git pull` holds `ExecLane.exclusive` (and the command SSH client) for the entire pack transfer

* **Where:** `lib/core/git/git_service.dart` `pull` (no `lane:` argument,
  so `_run` defaults to `ExecLane.exclusive`); comment at the call site
  says pull "must never overlap concurrent reads".
* **Evidence:** `CommandLaneScheduler` starts an exclusive only from the
  head of the queue with **zero** active reads/syncs, and starts nothing
  behind it until it finishes (`lib/core/exec/command_lanes.dart`). Status,
  diffs, blame, and History therefore queue for the whole `git pull`,
  which is fetch + merge/rebase. `SSHCommandExecutor._run` sends
  `ExecLane.sync` to `_clientManager.syncClient` and everything else to
  `_clientManager.client`. Pull therefore runs pack transfer on the
  **command** TCP connection. `ARCHITECTURE_PLAN.md` §0.1: the sync client
  exists so `fetch`/`push` pack transfer does not share a TCP connection
  with interactive reads. Pull's fetch half never uses it.
* **Why it feels janky:** clicking Pull greys the sync group (`busy` in
  `_syncUnavailability`) *and* every in-flight snapshot/diff sits behind
  the exclusive barrier. On a remote host the panes spinner-loop until
  the merge starts, which is usually milliseconds after the download.
* **Direction:** `git fetch` (sync, `--progress`, prune, the same forge
  helpers) then `git merge --ff-only` / `git rebase` / `git merge`
  according to `PullMode` (exclusive, typically sub-second). Keep one
  user-facing "git pull" in the output log. Do not send the fetch half
  through `executeStream` (off-queue).

#### H2. Fetch, pull, and push never pass `--progress`; the stall detector and the UI both see silence

* **Where:** `GitService.fetch` argv is `fetch --all --prune`; `pull` /
  `push` pass no progress flag. Clone, `gh repo clone`, and `glab repo
  clone` all pass `--progress` (`clone_controller.dart`, `gh_service.dart`,
  `glab_service.dart`).
* **Evidence:** git reports progress on stderr only when stderr is a TTY,
  unless `--progress` is set. Both executors run without a TTY
  (`Process.start` / `SSHClient.execute` of a `sh -c` string).
  `ActivityDeadline.pulse()` runs only when a stdout/stderr chunk arrives
  (`ssh_command_executor.dart` `_runBody`, `local_command_executor.dart`
  `_run`). Idle is `networkTimeout` (default 3 minutes). A still-running
  pack with no bytes on the pipe is killed as `TimeoutException` →
  `SSHCommandTimeout` → "Timed out waiting for the remote command to
  finish." The 30-minute ceiling never comes into play if idle fires
  first. Clone already streams frames with `startStream` + `\r` handling;
  fetch/pull/push call `logResult` **after** `await git.fetch/pull/push`,
  so the output view (open by default) is blank for the whole transfer.
* **Direction:** pass `--progress` on every network git invocation
  (fetch, pull's fetch half, push, `ls-remote` is instant and can skip).
  Forward stderr chunks to `OutputLogNotifier` *during* `execute()`, on
  the scheduler path. Pulse the activity deadline from those same chunks
  (already wired). Do not raise the default 3-minute stall budget as the
  fix.

#### H3. Manual fetch/push hold `BusyActionState` for the whole network op

* **Where:** `RepoStatusView._fetch` / `_push` / `_sync` and
  `BranchesView._fetchPrune` go through `runLogged(..., dock: true)`.
  `runLogged` sets `_busy = true` for `body`'s entire span
  (`busy_action.dart`). `_syncUnavailability` maps `busy` to "Another
  repository operation is running" on **every** sync verb.
* **Evidence:** `ExecLane.sync` is documented as safe alongside reads and
  as exclusive only among sync ops (`command_lanes.dart`). The busy gate's
  own doc says it exists so overlapping mutations do not race
  `.git/index.lock`. Fetch and push do not take the index lock — that is
  why they are not exclusive. Auto-fetch and `fetchInBackground` already
  run without the busy gate; only the user-visible buttons freeze the
  panel. File-list shortcuts are also gated on `busy`
  (`repo_status_view.dart`).
* **Direction:** `dock: true` can stay (Dock indeterminate bar is the
  right "talking to the network" signal). Do not set `_busy` for fetch /
  push. Keep `_busy` for pull's integrate half (and today's single
  `git pull` until H1 lands). Sync-lane serialization still prevents two
  fetches from racing refs.

#### H4. Every fetch is `git fetch --all --prune`, including paths that only need the current upstream

* **Where:** `GitService.fetch` always passes `--all --prune`. Callers:
  manual Fetch (`RepoStatusView._fetch`, `BranchesView._fetchPrune`),
  `autoFetchProvider` (default every 5 minutes),
  `ConnectionController.fetchInBackground` (after every successful
  commit, "so ahead/behind reflects the remote's current state").
* **Evidence:** `fetchInBackground`'s own comment is about ahead/behind
  of the current branch — that is one remote (the tracked upstream), not
  every remote. `--all` contacts every configured remote, sequentially
  (git's default `fetch.parallel` is 1; no `--jobs` is passed). A dead
  or extra remote (old fork, stale heroku) stretches the whole op to git's
  per-remote connect timeout, inside an activity deadline that cannot see
  progress (H2). Manual Fetch's label is honestly `--all --prune`; the
  post-commit path is not.
* **Direction:** keep `--all --prune` for the Fetch button and for
  auto-fetch (Branches depends on every remote-tracking ref). Change
  post-commit `fetchInBackground` to the current upstream only (the
  remote `_upstreamRemote` already computes, or `GitBranchInfo.upstream`).
  Add `--jobs` on the `--all` paths (host git is 2.48; `--jobs` exists
  since 2.24). Optional later: skip remotes with `skipDefaultUpdate`.

#### H5. A fetch refreshes History, stashes, reflog, and snapshots even when HEAD did not move

* **Where:** `repoMutationFamilies` (`app_providers.dart`) includes
  `logProvider`, `logSearchProvider`, `stashesProvider`, `reflogProvider`,
  `magicSnapshotsProvider` as whole families, plus `statusProvider` /
  `refsProvider` / `remotesProvider`. `refreshAfterMutation`,
  `fetchInBackground`, `autoFetchProvider`, and
  `RepoStatusView._refresh` (via `runLogged` `finally`) all iterate that
  list. `HistoryView`'s watch listener calls `refreshAfterMutation` on
  any `touchesGitState` tick.
* **Evidence:** fetch updates `FETCH_HEAD`, `packed-refs` /
  `refs/remotes/**`, not HEAD, the index, or the worktree. The family set
  is documented as "a single commit-mutating operation (commit,
  cherry-pick, revert, reset, amend, undo…)". Fetch is not that, but it
  uses the same list. Result: after every fetch (manual, auto, post-commit)
  History re-walks, Recovery re-reads reflog/snapshots, and the stash
  list refetches. `RepoStatusView._prefetchDiffs` then warms up to 8 diffs
  on the status landing — worktree content fetch did not change.
* **Direction:** split the refresh set. Fetch/push invalidate
  `statusProvider` (ahead/behind), `refsProvider`, `remotesProvider`,
  `branchReviewProvider` / `branchBaseProvider`. They do **not**
  invalidate log / logSearch / stashes / reflog / snapshots unless HEAD
  moved (pull's integrate half, or a push that was a fast-forward of the
  current branch's upstream — still not a History rewrite). Pull after
  H1 uses the full mutation set only for the integrate step.

#### H6. Own-mutation suppression is armed *after* the fetch, so mid-fetch ref updates refresh the world live

* **Where:** `fetchInBackground` and `autoFetchProvider` call
  `ownMutationTracker.mark` only after `await fetch(...)`. Manual fetch
  marks in `runLogged` `finally`, also after the command. Watch listeners
  in `RepoStatusView` and `HistoryView` skip only ticks inside a 3-second
  window *after* that mark.
* **Evidence:** `git fetch --all` updates refs as each remote finishes.
  Those writes are `.git/FETCH_HEAD` / `.git/refs/**` /
  `.git/packed-refs` — `shouldTriggerWatch` lets them through (it only
  drops locks, `objects/`, `logs/`, `fsmonitor--daemon/`).
  `RepoWatchEvent.touchesGitState` is true, so both mounted panels
  (`IndexedStack`) invalidate `repoMutationFamilies` **during** the
  still-running fetch. Fetch is sync, so those reads run concurrently
  with the pack transfer (H5's History walk on the command client, while
  the sync client is busy). The 3-second suppress window cannot cover a
  multi-remote fetch. History's listener even *marks* own-mutation on an
  external fetch's first tick, which then hides later remotes' updates
  for 3 seconds — the wrong suppress, at the wrong time.
* **Direction:** treat the fetch as in-flight from enqueue to settle,
  then let one refresh run when it ends. Watcher echoes during the op
  are the fetch's own writes.
* **Clarification (PLAN):** `OwnMutationTracker.mark` records a
  timestamp; `isRecent` is `at - last < 3s`. Marking at fetch *start*
  expires mid-transfer. The PLAN adds a begin/end refcount on the
  same tracker; `end` then `mark`s so the existing 3 s echo window
  still covers the post-command watcher tick. That is the MADR's
  "in flight flag", not a second mechanism.

---

### MED — correctness-adjacent cost

#### M1. Pull and push pay two extra host round trips before git starts

* **Where:** `_upstreamRemote` (`sh -c` with `git symbolic-ref` +
  `git config --get`) then `_forgeAuthArgs` (`git remote get-url`).
  Pinned in `test/mutations_test.dart` `'fetch / pull / push'`. Fetch
  skips both and installs *both* forge helpers (`forgeGitAuthConfigArgsAll`).
* **Evidence:** those probes are `ExecLane.read`, 15 s timeout, no
  `activityIdle`. On SSH they are two full channel-open/exec/drain
  cycles before the exclusive/sync op is even enqueued. Exclusive pull
  then waits for whatever reads are still in flight (including these).
  `GitBranchInfo.upstream` (`origin/main`) is already in the porcelain
  snapshot the UI has in RAM. Remote URLs are stable for a session.
* **Direction:** resolve the tracked remote from landed status / refs;
  cache `get-url` per `(repoPath, remote)` until remotes change. Keep
  the degradation path (empty helper list, never block the push).

#### M2. After a successful fetch, `refreshRemoteTags` starts `git ls-remote --tags` on the sync lane

* **Where:** `RepoStatusView._fetch` and `autoFetchProvider` invalidate
  `remoteTagsProvider` after fetch. That provider `keepAlive`s for 5
  minutes, so invalidation immediately re-runs `GitService.lsRemoteTags`
  (`ExecLane.sync`, `networkTimeout`, another `_forgeAuthArgs` probe).
* **Evidence:** manual fetch's `runLogged` has already dropped `_busy`
  before `refreshRemoteTags`. The user-visible op looks finished; a
  following Push then waits behind `ls-remote` because only one sync
  runs at a time. Fetch `--prune` already updated `refs/tags` *local*
  tracking for tags it follows; a full remote tag listing is a Tags-UI
  concern, not a fetch-completion concern.
* **Direction:** do not invalidate `remoteTagsProvider` from auto-fetch
  or from a generic Fetch. Keep `refreshRemoteTags` on tag push / remote
  tag delete / the Tags panel's own retry.

#### M3. `_logPulled` / `_logPushed` add rev-parse + `git diff --name-status` after the network op

* **Where:** `RepoStatusView._pull` / `_push` / `_sync`. `_sync` is
  pull-then-push with *four* extra reads around the two network commands.
* **Evidence:** `changedFiles` is a real `git diff --name-status` on
  `ExecLane.read` (`git_service.dart`). Useful in the output log; it
  extends the busy span (H3) and sits on the exclusive-to-read handoff
  after pull. For a no-op pull (HEAD unchanged) the extra diff is skipped
  (`before == after`), but the two `rev-parse` calls still run.
* **Direction:** keep the file list; run it after releasing the busy
  gate (or from the already-landed snapshot). Do not put it on the
  exclusive lane.

#### M4. Host `fetch.recurseSubmodules` is inherited; there is no submodule fetch UI

* **Where:** no `--recurse-submodules=` on fetch/pull/push. 0004 / 0005
  document submodule management as an intentional product deferral.
  Porcelain already badges gitlink rows (0009 M17).
* **Evidence:** git's default is `on-demand`; a host with
  `fetch.recurseSubmodules=yes` (or a superproject whose gitlinks moved)
  will recurse into populated submodules inside our one `git fetch --all`.
  That is unbounded extra network, with no UI to explain it.
* **Direction:** pass `--recurse-submodules=no` on app-driven fetch/pull
  until a submodule UI exists and opts in.

#### M5. `inotifywait` watches `.git/objects/` on the wire; `fswatch` does not

* **Where:** `RemoteWatchService._watcherArgs`: fswatch passes
  `--exclude '\.git/objects/'` (and logs, locks, fsmonitor). inotifywait
  is `inotifywait -m -r -e modify,create,delete,move --format %w%f .`
  with **no** excludes. `shouldTriggerWatch` drops `objects/` only after
  the path has already crossed the SSH stream.
* **Evidence:** a typical fetch writes a pack + idx (a handful of
  events), so this is usually noise rather than a 512-path overflow.
  A fetch that unpacks loose objects, or a `gc` concurrent with the
  session, streams one record per object over the watcher channel.
  Local `Directory.watch` filters in-process before `signalPath`.
* **Direction:** exclude `.git/objects`, `.git/logs`, and `*.lock` in
  the inotifywait argv (or `--exclude` if the installed inotifywait
  supports it; otherwise a small wrapper). Match fswatch.

#### M6. Fetch installs both `gh` and `glab` credential helpers for every remote

* **Where:** `forgeGitAuthConfigArgsAll` clears helpers then appends
  `!gh auth git-credential` and `!glab auth git-credential`. Fetch
  always uses this because `--all` "may touch remotes of either forge".
* **Evidence:** for each HTTPS remote git walks the helper list. A
  GitLab remote may spawn `gh` first (no-op or a slow miss) then `glab`.
  SSH remotes ignore helpers; the `-c` args are then cheap. Post-H4
  single-remote fetch can use `forgeGitAuthConfigArgs` for that remote
  only (pull/push already do).
* **Direction:** after H4, `--all` keeps both helpers; single-remote
  fetch uses the matching one. Do not run `get-url` on the network
  critical path (M1).

---

### LOW — honesty while a long op runs

#### L1. Activity Center does not tick while an op is running, and the toolbar icon does not spin

* **Where:** `activity_center.dart` `_ActivityRow` computes
  `record.elapsed(DateTime.now())` with no ticker; the button uses a
  static `CupertinoIcons.arrow_2_circlepath` when `active > 0`.
  `OperationDescriptor.supportsCancellation` defaults to false; fetch /
  pull / push never set it true.
* **Evidence:** `operationActivityProvider` only rebuilds on phase
  changes (queued → running → terminal). A two-minute fetch shows
  "Running · 0s" until it finishes. Clone is the only cancellable
  long network op today.
* **Direction:** ticker while the sheet shows a running record; an
  animated icon on the button. Cancellation is a later PLAN phase: it
  needs a kill that is safe for `git fetch` / `git push` (the executors
  already kill on timeout).

#### L2. Auto-fetch can occupy the sync lane under a user Fetch/Push with no explanation

* **Where:** `autoFetchProvider` fires `git.fetch(..., background: true)`
  on a timer. Visibility `background` hides it from Activity Center
  (`OperationActivityNotifier.report` returns early). User Fetch then
  enqueues on the same single sync slot.
* **Evidence:** the user sees H3's busy state (today) or a queued
  Activity row (after H3) with no "auto-fetch in progress" copy.
* **Direction:** either let a user-visible sync cancel/supersede a
  background fetch, or show background sync in Activity Center as a
  non-error row. Do not disable auto-fetch as the fix.

---

### What is already true (do not re-solve)

* Fetch and push are `ExecLane.sync`; only one runs at a time; reads
  overlap them. Pull is the exception (H1).
* Triple SSH client when attached: command / stream / sync. Stream
  death does not close sync, and vice versa. Read cap stays 4.
* `GIT_TERMINAL_PROMPT=0` and `GIT_OPTIONAL_LOCKS=0` on every command.
  HTTPS forge auth is per-command `credential.helper` `-c`, never a
  token in argv.
* `ActivityDeadline` idle + 30-minute ceiling is the right *shape* for
  network ops. It is starved of pulses without `--progress` (H2), not
  mis-designed.
* Clone streaming (`startStream`, `--progress`, Dock determinate
  fraction from git's `%`) is the template for fetch/push output.
* Watcher object-store suppression *in the filter* is correct
  (`shouldTriggerWatch`). fswatch also excludes at source; inotifywait
  does not (M5).
* `remoteTagsProvider` is deliberately out of `repoMutationFamilies`
  because `ls-remote` is a network round trip. Auto-fetch putting it
  back (M2) is the bug, not the original split.
* Auto-fetch already refuses to arm on a repo with no configured
  remote (`auto_fetch_test.dart`).

---

### Recommended PLAN shape (not authorised)

When a companion PLAN is requested, phase in this order so each commit
is testable without depending on the progress-callback work:

1. **H2 argv + H4 scope + M4 recurse flag** — `--progress`,
   `--recurse-submodules=no`, post-commit fetch of upstream only,
   `--jobs` on `--all`. Stall detector starts receiving pulses even
   before the UI tails them.
2. **H5 / H6 refresh scope** — fetch/push refresh set; mark
   own-mutation at start. History stops hitching mid-fetch.
3. **H3 busy gate** — fetch/push no longer freeze Repository. Dock
   bar stays.
4. **H1 pull split** — fetch (sync) + integrate (exclusive). Pull
   finally uses the sync client.
5. **H2 streaming + M1/M2/M3** — on-queue stderr tail; cache auth
   probes; stop auto `ls-remote`; move name-status logging off the
   busy span.
6. **M5 / L1 / L2** — inotifywait excludes; Activity Center ticker;
   background-sync visibility.

Residuals that wait for a product decision: submodule fetch UI, a
determinate Dock bar for fetch (clone already parses `%`), user-facing
Fetch All vs Fetch Upstream as two buttons.

---

### Related records

* [0001-MADR-native-git-libgit2.md](0001-MADR-native-git-libgit2.md) —
  do not replace CLI git.
* [0014-MADR-ssh-engine-next-wave-hardening.md](0014-MADR-ssh-engine-next-wave-hardening.md)
  — sync client, activity deadline, read cap 4.
* [ARCHITECTURE_PLAN.md](ARCHITECTURE_PLAN.md) §0.1 — transport truth
  this audit measured against.

### Remediation log

| Date | Change |
| --- | --- |
| 2026-08-28 | Phases 1–6 shipped: `9294e3c`, `c0de555`, `1ffb1cf`, `3713ffb`, `5ebb81d`, `9cc17ac`. Status `accepted`. |
