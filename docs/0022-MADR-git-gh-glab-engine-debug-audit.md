---
status: accepted
date: 2026-09-03
decision-makers: maccavelli (maintainer)
consulted: five parallel read-only audit agents (executor/transport, GitService
  core, watch/coalescing pipeline, gh/glab forge layer, scope-lifecycle
  verification), then five further agents that re-read the exact current code
  for every finding before the plan was written
informed: implementers of 0022-PLAN
verified: 2026-09-03
---

# Treat the 2026-09-03 git/gh/glab engine-layer debug pass as the current prioritized remediation backlog

## Context and Problem Statement

Magic Git drives `git`/`glab`/`gh` on a host — remote over SSH (dartssh2) or
the local Mac via `Process.start` — through the `CommandExecutor` seam
(`lib/core/ssh/`, `lib/core/exec/`), with `GitService`
(`lib/core/git/git_service.dart`), `GhService`, and `GlabService` built on top,
plus a real-time filesystem-watch pipeline feeding status refresh
(`lib/core/git/*_watch_service.dart`, `coalescer.dart`, `bounded_watch.dart`).

This engine layer already has an extensive decision history —
[0011](0011-MADR-ssh-transport-stability-hardening.md),
[0012](0012-MADR-adopt-dartssh2-v3.md),
[0013](0013-MADR-prefer-dartssh2-v3-over-dartssh3.md),
[0014](0014-MADR-ssh-engine-next-wave-hardening.md),
[0015](0015-MADR-ssh-engine-and-ui-unit-test-gaps.md)/[0016](0016-PLAN-ssh-engine-and-ui-coverage-tail.md),
[0017](0017-MADR-provider-retry-policy-on-providers.md),
[0018](0018-MADR-transport-readiness-is-not-an-error.md),
[0019](0019-MADR-pin-glab-origin-host-on-every-call.md),
[0020](0020-MADR-fetch-pull-push-lag.md),
[0021](0021-MADR-create-repo-identity-and-origin.md) — plus two maintainer-memory
audits from 2026-07-19 (connections/scoped-repo, Forge+Branches) whose claimed
fixes and claimed-deferred items had never been re-verified against the tree in
a single pass.

The maintainer asked for a fresh, full-surface deep dive of the engine layer
specifically — bugs, gaps, incomplete or missing wiring — with the goal that
the git/gh/glab integrations be seamless and function flawlessly. This record
is that findings pass and the decision about how to consume it.

**The decision to make is:** how should these findings be treated relative to
the prior records, and in what order should they be fixed?

## Audit method

Two rounds, both read-only.

**Round 1 (five parallel agents), by subsystem:** executor/transport
(`lib/core/ssh/*`, `lib/core/exec/*`, the pop-out relay); GitService core
(`git_service.dart` read in full, plus `git_cat_file_batch.dart`,
`unified_diff.dart`, `git_porcelain_parser.dart`); the watch/coalescing
pipeline; the gh/glab forge layer; and a verification agent that re-checked
every claim from the 2026-07-19 memory audits against HEAD `433a9a6` using
`git log`/`git blame` plus direct reading, since that memory was 45+ days old
and self-described several items as uncommitted.

**Round 2 (five parallel agents), by finding:** before writing the plan, each
finding's exact current code, fix shape, and test idiom was re-gathered so the
plan could specify precise edits. **This round disproved one finding and
sharpened seven** — see "Record of corrections".

Every claim carries a `file:line`. Agents were instructed to separate verified
facts from suspicions they had not fully traced. The parent session
cross-referenced overlapping findings — two agents independently converged on
the scoped-forge gap (H2) from different entry points — but did not re-read
every cited line itself; citations are as reported, except where Round 2
re-read them.

Not used in either round: a full test-suite run, a live SSH host, or a built
`.app`. Three items are therefore explicitly unsettled; see Confirmation.

## Relationship to earlier records

* **Supersedes nothing.** 0011/0014/0015/0017/0018/0019/0020/0021 shipped work
  was spot-checked and confirmed present and correct except where a finding
  below says otherwise (H3, M11).
* **Corrects two stale memory-only claims** never written into a MADR: the
  add-repo/clone provisioning-race fix was described as done and is verified
  **not** present (H4); the scoped-repo forge gap was described as closed by
  `ScopedCommandExecutor` and is verified **partly** open (H2).
* **Confirms fixed — do not re-open as new bugs:** GIT_DIR/GIT_WORK_TREE scope
  injection across every git-running `GitService` call site; `-uall` forced
  unconditionally; `reconnect()` losing scope; the five local-repo reopen
  sites; cross-host scope poisoning; `setRepoPath` registration; the persisted
  scope-map leak on delete/edit; pop-out scope re-injection; porcelain v2 /
  `for-each-ref` / NUL-log parsing; cross-host watch-cache invalidation; the
  coalescer. Full list with citations below.

## Scope

**In scope:** correctness bugs, incomplete or missing wiring, silent failures,
and optimization gaps in the git/gh/glab command-execution, parsing, scope, and
watch layers.

**Out of scope:** UI/UX presentation already covered by
[0004](0004-MADR-ui-ux-deep-debug-audit.md)/[0009](0009-MADR-ui-ux-debug-pass-backlog.md);
LFS, submodules, Code Owners, stacked branches, commit signing (each needs its
own MADR per [0007](0007-MADR-docs-completion-audit.md)); 0019 Phase 8
(maintainer-only live check, correctly still open and not re-litigated).

## Decision Drivers

* Silent failures — a feature that stops working with no error surfaced —
  outrank loud ones. Several findings here are invisible to the user until
  something they expected to happen simply didn't.
* A finding that can corrupt persisted state (which host a saved connection
  points at) or mis-authenticate against the wrong forge outranks one that
  merely under-serves a workflow.
* Two independent agents converging on one root cause from different paths is
  stronger evidence than either alone, and should be fixed as one systemic item
  rather than three line-patches.
* Findings whose current reachability is zero (dead code) are real defects to
  record but must not block live bugs — they are landmines for future wiring.
* A claim that survives only because nobody re-checked it is worth less than a
  claim re-verified today. This is why Round 2 exists, and why it was allowed
  to overturn Round 1.

## Considered Options

* Fix everything in discovery order across the five subsystem reports.
* Triage into one severity-ranked backlog spanning all subsystems, fix HIGH
  first, and let the maintainer choose how much of MEDIUM/LOW to take — the
  pattern established by [0009](0009-MADR-ui-ux-debug-pass-backlog.md) and the
  2026-07-19 audits.
* Defer into a generic backlog file with no prioritization.

## Decision Outcome

Chosen option: **a single severity-ranked backlog spanning all five
subsystems, ordered HIGH first**, because the findings cluster around a few
root causes — scope-awareness gaps in forge call sites, a lane default that
does not distinguish "read-only preview" from "long-running compute", a relay
codec never extended when a fourth typed exception was added, and a watch spec
frozen at arm time — rather than being independent one-line bugs. An unranked
list would bury the item with data-integrity consequences (H4) and the ones
that silently disable whole features (H2, H5) beneath fifteen lower-stakes
items.

**On the maintainer's instruction to "scope all findings", the paired plan
covers every item** — HIGH, MEDIUM, LOW, the new N1–N3, and H1' — rather than
a chosen tier. The ranking below governs *order*; the plan's phases follow it.

The paired plan is
[0022-PLAN-git-gh-glab-engine-debug-audit.md](0022-PLAN-git-gh-glab-engine-debug-audit.md).

### Consequences

* Good, because the item with the highest blast radius (H4) and the two that
  silently disable features (H2, H5) get fixed first regardless of where a
  later session stops.
* Good, because H2's four call sites — one found via the forge audit, three via
  the scope-lifecycle audit — are recorded as one architectural gap with one
  fix shape, instead of being patched piecemeal by two sessions unaware of each
  other.
* Good, because Round 2 caught a false HIGH before any code was written on it.
  The cost of that round was a few hours; the cost of "hardening" a
  non-vulnerability would have been a permanent, wrong constraint on the
  GitLab merge path plus two inverted test assertions.
* Neutral, because M5 and the live half of H2 depend on a real remote host and
  cannot be closed from this tree; the plan budgets explicit live verification
  rather than asserting them.
* Bad, because this is large — 4 HIGH, 12 MEDIUM, 8 LOW across three
  subsystems and sixteen plan phases. No single commit closes it, and the
  watch-pipeline phases touch a shared engine used by every repo, not only the
  scoped ones the findings concern.

## Findings

Severity, one-line defect, failure scenario, citation. IDs are stable and are
what 0022-PLAN's phases reference. **These entries already incorporate Round
2's corrections** — where an entry differs from what Round 1 reported, the
"Record of corrections" section at the end says so.

### HIGH

**H2 — Bare/dotfiles-scoped repos are forge-broken across four call sites that
bypass `ScopedCommandExecutor` (systemic; found independently by two agents).**
`ScopedCommandExecutor` (`lib/core/exec/scoped_command_executor.dart`) and
`scopedForgeExecutorProvider` (`app_providers.dart:311-335`) exist so glab/gh
commands on a scoped repo carry the right GIT_DIR/GIT_WORK_TREE, and
`glabServiceProvider`/`ghServiceProvider` use them correctly. But:

* `finalizeProvisioned` (`app_providers.dart:2478-2496`) logs the forge token
  in via `GlabService(_activeExecutor)`/`GhService(_activeExecutor)` — the raw
  executor. `loginWithToken` (`glab_service.dart:101-129`,
  `gh_service.dart:72-94`) shells `git remote get-url origin`; on a scoped repo
  that resolves nothing, and the failure is swallowed into a non-fatal warning
  (`:2482-2496`), so the connection "succeeds" with the token never logged in.
* `originRemoteUrlProvider` (`:4949-4961`), `forgeProvider` (`:4969-4990`), and
  `sessionAuthStatusProvider` (`:5140-5169`) build on the raw
  `activeExecutorProvider`, so the Forge tab shows `Forge.none`, browser links
  are null, and Dashboard auth cannot resolve an Enterprise host — on a repo
  that has a perfectly good forge remote.

Net effect: the exact repo shape the scoped-repo work was built to support
cannot use the Forge tab at all, and its stored token silently never logs in.
Round 2 additions: `connect()` is **already correct** (`:1652-1664`, scoped
providers, run after `scopedGitDirs` is published) and `connectLocal()` does no
token login, so only `finalizeProvisioned` is broken among the three; and
`finalizeProvisioned` **cannot** be fixed by substituting the scoped provider,
because its state is not published until `:2544`, after the logins run.

**H3 — Pop-out windows lose `SSHTransportNotReady`'s type crossing the proxy
relay, reintroducing the symptom 0018 fixed for the main window.**
`encodeExecuteError` (`exec_proxy_codec.dart:171-188`) has arms for
`SSHCommandTimeout`, `SSHCommandSuperseded`, and `SSHOutputExceeded` but not
`SSHTransportNotReady`, so it crosses as a generic `ProxyExecuteException`.
`isTransportNotReady` (`display_error.dart:59`) is an exact `is` test, so the
spinner branch never engages and the pane renders the literal string
`SSH transport is not ready yet: <command>` — on every cold connect or
reconnect race in any detached-repo window.
`test/exec_proxy_codec_test.dart:200-237` pins exactly the other three types
and was never extended when this fourth one was added: a coverage gap, not a
check that was seen to fail and accepted.

**H4 — The clone and create-repo wizards have no defense against a mid-dial
host switch, so the wrong host's session can be finalized into the wrong saved
connection.**
In `lib/features/workspace/clone_sheet.dart:273-303` and
`lib/features/workspace/create_repo_sheet.dart:403-433`, `_ensureProvisioned`
checks only `!mounted` after the `beginProvisioning` await; the Destination
dropdown gates only on `_submitting` (`clone_sheet.dart:573`,
`create_repo_sheet.dart:1353`). Sequence: pick host A (dial starts); pick host
B before it resolves — `_resetProvisioning` is a no-op because the token is
still null, and the re-entry bails on the `_provisioning` guard, so B is never
dialed; A's dial resolves and its token is adopted under `_destConnectionId ==
B`; `_register` then reads `conn` from B (`:424`) with A's token (`:425`), and
`finalizeProvisioned` promotes **host A's live session** while persisting the
repo into **host B's** `SavedConnection` (`:2503-2513`) and reporting B's
identity in `ConnectionState` (`:2532-2545`).
A 2026-07-19 memory claimed this fixed; it is not. Round 2 found the fix
**already exists in-repo** at `lib/features/connection/local_repo_form.dart:295-325`
— identity guard, awaited abort, `_provisioning` cleared, dropdown gated, with
a comment describing this precise bug — and that this third caller is itself
untested. A controller-layer guard is also available and is the load-bearing
half: `beginProvisioning` records `_lastConnectionId` (`:2335`), so
`finalizeProvisioned` can reject a mismatched `conn` for any caller.

**H5 — The bounded watch spec is computed once at arm time and never
recomputed, so a scoped repo silently stops reflecting real changes.**
`repoWatchProvider` (`app_providers.dart:3311-3352`, TODO at `:3317`) calls
`listTrackedFiles` once and bakes the resulting `watchDirs` into the closure
passed to `watchLifecycle`'s `arm`; the restart-with-backoff logic
(`watch_lifecycle.dart:198-240`) re-invokes that **same closure**, never
recomputing. So a file newly tracked in a directory not already watched — `git
add` in a new subdirectory of `$HOME` — goes unwatched until the provider is
torn down (tab close, reconnect, repo switch), with no error and the watch
indicator still green.
Broader than the TODO's "index change" framing. Round 2 additions: the **local
backend has the same freeze** (`local_watch_service.dart:145-150`, whose
justifying comment is true for linked worktrees and false for bounded mode);
re-arming is mechanically achievable because `.git/index` already flows as a
`touchesGitState` path in bounded mode (`bounded_watch.dart:86` →
`:110-113` → `watch_path_filter.dart:22-30` → `watch_event.dart:59-60`, proven
by `test/local_watch_bounded_test.dart:125-135`); but `hooks.scheduleRestart`
must **not** be the trigger, since it paints a "stopped" tick, applies backoff,
and burns the restart budget (`watch_lifecycle.dart:160-179`).

### MEDIUM

**H1' — glab's field-flag semantics are documented wrongly in-source, and the
remote glab version is uncontrolled.** (Replaces the refuted H1; see Record of
corrections.) `glab_service.dart:461` documents `-f` as `--field`. It is
`--raw-field`; `--field` is `-F`, and `-F` **is** the flag that performs
`@filename` substitution. The code is correct today, but that comment is
exactly what would make a future edit — "correcting" the flag, or adding a
typed field — introduce a real file-disclosure bug on
`glab_service.dart:1565-1568`, the one site in all of `lib/` that passes
user-typed free text through a field flag. Separately, the app drives glab on
hosts whose version it does not control, and glab's own 1.116 help documents
that `--raw-field` handling has changed across versions; whether an older
`--raw-field` did `@` substitution was not testable offline and is unverified.

**M1 — Stale forge-credential-helper selection after a branch switch.**
`_upstreamRemoteByRepo` and `_remoteUrlByRepo` (`git_service.dart:1059-1062`)
are keyed by `repoPath` only and have **no** `clear`, `remove`, or invalidation
anywhere in the file; `checkout` (`:3310`) and `checkoutTrackingBranch`
(`:3337`) do not touch them, and `GitService` lives for the connection. The
push/fetch *target* is unaffected (a null remote is a no-op spread; git
resolves its own upstream) — what breaks is `_forgeAuthArgs`
(`:4972`, `:5026`), which uses the stale name to choose which forge CLI's
credential helper to install (`forge.dart:127-138`), so a branch tracking a
different-forge remote gets the wrong CLI answering `auth git-credential` and
HTTPS auth fails. `checkoutTrackingBranch` is the sharper case: it *creates*
the tracking relationship, so the cached value is wrong by construction.
`:4898` also memoizes the `'origin'` fallback permanently, so a repo whose HEAD
was detached at first pull answers `origin` forever. **Zero test coverage of
any kind** (`grep` for `upstreamRemote`/`_forgeAuthArgs` in `test/` is empty).

**M2 — `generateCommitMessage` holds the exclusive barrier for up to five
minutes.** `git_service.dart:3292-3297` passes no `lane:`, taking
`ExecLane.exclusive` (a FIFO barrier blocking all reads and syncs) with the
5-minute `commitTimeout`. Its own docstring anticipates "a slow AI generator"
(`:3274`). It mutates nothing — it round-trips a `mktemp` scratch file under
the git-dir — so previewing a commit message can freeze status, diff, and
blame across the app for the hook's whole duration.

**M3 — Pop-out mutations report to the main window's Activity Center, and the
pop-out's own never shows them.** Three defects, all required for the fix:
the hub's execute handler binds `onOperationEvent` to the main-isolate
container (`window_manager_bridge.dart:610-612`) though the originating window
id is in scope (`:542`); `ProxyCommandExecutor.execute` accepts
`onOperationEvent` and silently discards it
(`proxy_command_executor.dart:115`); and the child's `gitServiceProvider`
override has neither the `ActivityCommandExecutor` wrap nor `onOperationEvent`
(`secondary_window_main.dart:182-214`), despite a comment at `:178` claiming
it is "identical construction … except undo records". So a commit or push run
in a detached window lands in the main window's list — possibly for a repo that
window isn't showing — while the pop-out's own Activity Center stays empty.
`OperationEvent` has no wire form (`operation_activity.dart:130-151`), unlike
`OperationDescriptor` (`:84`, `:96`), so one must be defined; and
`OperationActivityStore.apply` drops any event whose first phase is not
`queued` (`:299`), so the whole ordered lifecycle must be relayed.

**M4 — Reopen for PRs/MRs is implemented, tested, and unreachable.**
`reopenMergeRequest` (`glab_service.dart:1631-1638`) and `reopenPullRequest`
(`gh_service.dart:1099-1108`) exist with a ready label
(`forge_operation_labels.dart:50`) and **zero** UI call sites, while close
**is** wired (`github_panel.dart:1265`, `gitlab_panel.dart:1309`). Closing a
PR/MR from Magic Git is a one-way door. Round 2 addition: the lists are
open-only (`gh_service.dart:376-377` hardcodes `--state open`; `glab mr list`
takes GitLab's `opened` default), so a closed item vanishes entirely — **list
state is a prerequisite for the action, not an enhancement**. Models already
carry `state` and need no change. The issue path (`issue_actions.dart:264-269`)
is the precedent to copy, but its Reopen branch is itself untested.

**M5 — Remote watcher processes may outlive their SSH channel (suspicion, not
reproduced).** `killAndCloseSession` (`ssh_command_executor.dart:1013-1043`)
sends `SSHSignal.TERM`, then `close()`, then escalates to `KILL`. RFC 4254's
`signal` request is optional and OpenSSH's sshd is widely documented as not
honoring it for non-pty exec channels — in which case both signals are no-ops
down the same path, and cleanup rests on channel close causing SIGPIPE at the
watcher's next write, which on a quiet repo may be far away or never. `exec` in
the arming script (`bounded_watch.dart:129-130`) is the only mitigation, and it
addresses a different failure (a surviving shell wrapper), not this one. There
is no trap, no PID file, no reconnect-time sweep. Systemic rather than
watch-specific: the same path backs CI trace streaming. **Requires a live host
to settle.**

**M6 — Bounded-watch arming fails silently in two different ways.**
`boundedFswatchArgs` (`bounded_watch.dart:148-154`) passes `watchDirs` straight
to fswatch with **no existence guard**, and fswatch errors on a nonexistent
path — so a bounded fswatch arm on a tagless repo (no `refs/tags`) fails
outright on a macOS remote host. Independently of H5. And
`boundedInotifyScript`'s guard has its own flaw: `exit 0` when every path is
missing (`:138`) reads as a clean death, burning the restart budget into
polling with no diagnostic.
Round 2 **refuted** the original theory for the local backend: a live Dart
reproduction confirmed macOS `Directory.watch()` self-heals on a path created
later (FSEvents watches by path, not inode), so "crashes the watcher → 5s poll"
is false there and must not be carried forward.

**M7 — The live scope registry leaks on delete, repoint, and switch.**
`_deleteRepo` (`connection_switcher.dart:847`) and `_editRepo` (`:896-943`)
clear the **persisted** `scopedGitDirs` entry but never call
`GitService.unregisterRepoScope`, which has **zero production callers**
(`git_service.dart:1166`; only tests). `setRepoPath`
(`app_providers.dart:2156-2161`) only ever *adds* scope. So within one
connected session, an ordinary repo opened at a path a scoped repo just vacated
silently inherits its GIT_DIR/GIT_WORK_TREE — and, because `isRepoScoped` also
gates untracked-file semantics (`git_service.dart:1976`, `:2050`), its status
output changes too.

**M8 — Three comment-listing JSON decodes run on the UI isolate.**
`decodeJsonMaybeOffThread` (`forge_json.dart:25-30`) is the convention every
other decode site follows, except `GlabService.listIssueComments` (`:1426`),
`GlabService.listMergeRequestNotes` (`:1453`), and
`GhService._parseIssueComments` (`:927`, backing both issue and PR comments) —
exactly the busy-thread payloads the 32 KiB threshold exists for. 0019's plan
deliberately left these un-migrated during host-pinning; this is that flagged
residual.

**M9 — No rate-limit handling anywhere in the forge layer.** No 403/429
detection, retry, backoff, or distinguishing signal exists; a rate-limited
burst (page-walking jobs/pipelines/MRs on repo switch) surfaces as an ordinary
opaque exception. `branch_forge_status.dart:168` documents "rate limited" as
one of the failure modes `branchForgeProvider` deliberately collapses to
`const {}`.

**M10 — `showBlobsBatch` corrupts non-UTF-8 blobs (dead code today).**
`git_cat_file_batch.dart:187` re-encodes `result.stdout` — already lossily
decoded with `allowMalformed: true` — via `utf8.encode`, which is not
length-preserving (a 4-byte invalid sequence becomes a 3-byte replacement
character). `parseCatFileBatch` frames objects by git's byte-count header, so
one bad byte desyncs **every subsequent object**, and the non-`requireAll` path
then returns wrong content for the wrong key **silently** (`:190-199`) rather
than throwing. `GitService.showBlobsBatch` (`git_service.dart:2931`) has zero
callers in `lib/`, so it cannot fire today. Round 2 additions: the documented
sequential fallback is lossy too (`:211`), so `git_service.dart:2929-2930`'s
claim that it is "correct, slower" is false; and the existing test
(`test/git_cat_file_batch_test.dart:244-266`) is ASCII-only, its fixture
builder calling `utf8.decode` **without** `allowMalformed`, so the harness
itself cannot express the failing case.

**M11 — 0018's status is stale and its built architecture differs from its
plan (process gap).** The typed exception, humanizer branch, spinner call
sites, and readiness gate are all shipped
(`ssh_command_executor.dart:95-101,289-295,716-731,1074-1088`;
`ssh_error_messages.dart:71-75`; `display_error.dart:59`) — except H3's
secondary-window gap. Yet both 0018 files say `status: proposed` and
`README.md:46` repeats it, so a reader concludes the bug class is fully open.
Separately, the plan's Phase 1c specified a standalone `ReadinessGatedExecutor`
decorator at the provider seam; what shipped is an inline gate inside
`SSHCommandExecutor` coupled to `SSHClientManager` — never recorded as a
deviation, as the repo's own amendment rule requires.

**N1 — A failed `listTrackedFiles` leaves a scoped repo entirely unwatched.**
`repoWatchProvider` builds the bounded spec through `Stream.fromFuture(...)`
(`app_providers.dart:3339-3349`), *outside* `watchLifecycle` — so a thrown
`GitException` or timeout errors the whole provider stream instead of degrading
to polling. The repo silently stops refreshing, with no watcher and no poll.

### LOW

**L1 — Scoped repos have no editable git-dir.**
`edit_entry_sheets.dart:273-403` (remote) and `:406-475` (local) offer
Label/Path/fsmonitor only, and the Path hint ("the one containing .git") is not
scope-aware. A genuinely moved git-dir is correctable only by delete + re-add;
everything short of that relies on the connect-time self-heal.

**L2 — Pending-operation detection ignores its own exit code, and drops `am`.**
`git_service.dart:2082-2151` switches on `pendingStdout` alone; `pending.exitCode`
is never passed to `_assembleSnapshot`, unlike `statusExit`/`refsExit` (throw)
and `remotesExit` (documented degrade). A failing script is indistinguishable
from a genuine "none" — the dangerous direction, since this gates the
session-exit guard. Round 2 found a **second, live bug in the same block**: the
script emits `am` (`:1900`) but the consuming switch (`:2147-2153`) has no
`'am'` case, so an in-progress `git am` reports as no pending operation.

**L3 — `undoExecute`/`redoExecute` build no `OperationDescriptor`.**
`git_service.dart:5934-5952`, `:5958-5977` call the executor directly, so undo
and redo never appear in the Activity Center. Round 2 addition: neither passes
`lane:` either, so both rely on `execute`'s default — while `undoExecute`'s doc
claims "on the exclusive lane", which nothing in its body establishes.

**L4 — The diff parser has no copy-detection branch.**
`unified_diff.dart:216-287` handles `rename from/to` but not `copy from/to`, so
a copied file classifies as `modified` while carrying `oldPath != newPath` — a
state no other path produces. Round 2 scoping: this repo never passes
`-C`/`--find-copies` itself, so such headers arrive only from a host
`diff.renames = copies` config or an imported patch. Real but rare.

**L5 — glab subcommand paths trust the exit code alone (already-documented
residual).** `api()`/`graphql()` correctly parse HTTP status via `-i`
(`glab_service.dart:490-513`, `:700-722`), but every subcommand path relies
solely on `result.isSuccess`, as its own comment at `:1799-1803` says.
0019 already names `glab mr list` as an example; recorded here for completeness
of the engine picture, not as new work 0019 missed.

**L6 — `forgeRepoListProvider` builds forge services on the raw executor.**
`app_providers.dart:5045-5065` looks identical to the correctly scoped
provider pattern in the same file but bypasses `scopedForgeExecutorProvider`.
Harmless today (`listRepos(host:)` takes no `repoPath`), and a latent trap: a
future edit threading a `repoPath` through would silently reintroduce H2.

**N2 — Both merge-message fields are sent on every GitLab merge.**
`gitlab_panel.dart:1276` passes `mergeCommitMessage: options.body ?? options.subject`
alongside `squashMessage: options.subject`, so `merge_commit_message` and
`squash_commit_message` both go out regardless of the chosen method, and a
blank body silently reuses the subject as the merge-commit body.

**N3 — Two stale comments assert what the code contradicts.** Each would
mislead the next editor into reintroducing a fixed bug:
`glab_service.dart:461` (`-f` called `--field`; this is the H1' trap), and
`app_providers.dart:2205-2209`, which claims `activeExecutorProvider` watches
`connectionProvider` and would trip the cycle guard — false per `:230-239` and
`:202-218`, and disproved in production by `_connectForgeLogins`, which reads
those providers from inside the same notifier and ships.

## Confirmed fixed / non-issues (do not re-open)

* Scope injection is complete across every git-running `GitService` call site
  (~50 direct `_executor.execute` sites checked; the six without `extraEnv` —
  `validateLocalRepoRoot`, `gitfileRedirectTarget`, `readFile`,
  `readFileBase64`, `readFileBase64Bounded`, `conflictFile` — legitimately
  don't run `git`), backed by a real-git integration test
  (`test/git_dir_scope_integration_test.dart`).
* `-uall` is gated on `isRepoScoped` in both snapshot paths
  (`git_service.dart:1976`, `:2050`).
* Porcelain v2, `for-each-ref`, NUL-delimited log, and reflog parsing are
  correct against the documented formats, including all unmerged stage combos,
  rename/copy pairing, paths with spaces, and truncated input.
* `reconnect()` restores `scopedGitDirs` (`app_providers.dart:2105-2121`); the
  five local reopen sites pass `gitDir:`; `clearAllRepoScopes()` runs before
  every validate/register; `setRepoPath` registers the switched-to scope;
  delete/edit clear the **persisted** map correctly (only the live-registry
  leak, M7, remains); the pop-out relay re-injects scope
  (`window_manager_bridge.dart:578-595`).
* Cross-host cache invalidation on reconnect/switch is correct and complete
  (`app_providers.dart:1031-1041`, all six call sites traced).
* The coalescer's trailing/maxWait/minInterval precedence and its `cancel()`
  reset are correct; no lost-event or never-settling burst found.
* SSH escaping (`shell_escaper.dart`, `command_formatter.dart`), generation
  pinning against post-reconnect stale-host execution, and cleanup in
  `SSHClientManager`/`ActivityDeadline` are correct.
* 0019 Phase 8 is accurately marked maintainer-only; no drift.
* GitLab-only feature gaps (no assign-to-me, no MR request-changes, no
  issue→branch Start work) are intentional and unchanged.

## Record of corrections

Round 2 re-read every finding's code before the plan was written. Kept here in
full: a findings record that quietly absorbs its own errors teaches nothing
about how much to trust the rest of it.

**H1 — REFUTED in full. There is no injection vulnerability.** Round 1 claimed
that `GlabService.mergeMergeRequest` and `enableMergeRequestAutoMerge` exposed
free text to glab's `@filename` substitution via `-f`, rating it HIGH/security.
Verified false against the installed binaries (glab 1.116.0, gh 2.99.0), using
an RFC 2606 `.invalid` host so no network was reached and nothing mutated:

* `-f` **is** `--raw-field` ("Add a string parameter"), which performs no value
  transformation. `-F`/`--field` is the flag that reads `@filename`.
* `-F` with a missing file fails at parse time; `-f` with the same value
  transmits the literal string `"@/path"` in the JSON body, confirmed via
  `GLAB_DEBUG_HTTP=1`.
* A full sweep of `lib/` found only four field-emitting sites, of which exactly
  one carries user-typed free text (`glab_service.dart:1565-1568`).
* `enableMergeRequestAutoMerge` carries **no** free text at all — fixed
  booleans and a hex SHA — so the finding was wrong about that method twice.

What survives is the in-source documentation trap and the uncontrolled remote
version, recorded as **H1' (MEDIUM)**. The plan's Phase 10 therefore pins the
flag with a test rather than "hardening" a non-vulnerability; had this gone
unchecked, it would have traded a proven hardening (glab's advisory exit codes
are cross-checked via `-i`) for an imagined risk.

**Seven findings sharpened** — each now folded into the entry above: H2 (only
`finalizeProvisioned` is broken; and it cannot use the scoped provider,
because of ordering); H4 (wrong file paths in Round 1 — the sheets live in
`lib/features/workspace/` — plus the fix already exists at
`local_repo_form.dart:295-325`, and a controller-layer guard is available);
H5 (applies to the local backend too; `scheduleRestart` is the wrong trigger);
M6 (worse for remote fswatch, and the local "poll fallback" theory is refuted);
M10 (the fallback is lossy too; silent wrong-key returns); L2 (`am` is a second
live bug); M1 (zero coverage; permanent `origin` memoization).

**Three findings added by Round 2:** N1, N2, N3 above.

## Confirmation

Confirmed by: `flutter analyze` reported clean on the files each agent read;
`file:line` citations for every claim, re-read in Round 2 for every item the
plan touches; `git log`/`git blame` cross-referencing for the scope-lifecycle
claims; a live non-mocked Dart reproduction of `Directory.watch()` on a missing
path (M6); and an offline probe of glab 1.116 / gh 2.99 that refuted H1.

**Not** confirmed by a full test-suite run, a live SSH host, or a built `.app`.
Three items are unsettled and must be closed by evidence during execution, not
assumed:

* **M5** — whether the target sshd honors the signal request at all.
* **H2's live half** — a real bare/dotfiles repo carrying a forge remote.
* **H1' point 2** — whether any glab version the app might drive performed `@`
  substitution on `--raw-field`.

One process note belongs on the record: during early execution the plan's own
Phase 0 baseline was run incorrectly (a background suite run overlapped
in-flight edits), so the first baseline was void and had to be re-taken. The
plan's Execution Record carries the detail.

## More Information

Paired plan:
[0022-PLAN-git-gh-glab-engine-debug-audit.md](0022-PLAN-git-gh-glab-engine-debug-audit.md),
covering all findings at the maintainer's request. Execution began 2026-09-03.
