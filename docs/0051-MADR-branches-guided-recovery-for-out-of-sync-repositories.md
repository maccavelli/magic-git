---
status: "proposed"
date: 2026-09-17
decision-makers: [Maintainer]
consulted: []
informed: [Magic Git contributors]
verified: 2026-09-17
---

# Branches gains named, guided recovery actions for diverged and out-of-sync repositories, instead of reporting a number and leaving the terminal to fix it

## Context and Problem Statement

Working the same repository from several hosts (Windows, Linux, macOS — each a separate SSH connection
or local checkout) makes it easy to forget a push or a pull. The result is a family of "exceptions to
the rule" states — a branch with no upstream, a branch that exists on one clone but was never fetched to
another, two clones that have each committed to the same branch and diverged, a branch whose remote
sibling was deleted or force-pushed over — none of which the ordinary merge/pull button in the Branches
tab can resolve, and some of which it resolves *unsafely* if used naively (a diverged branch's "Merge
into current" is not wrong, but a user who actually wanted to discard one side's commits has no route to
that from the UI at all).

Today the Branches tab **reports** these states — an ahead/behind count, a "gone" badge — and stops
there. Resolving them means dropping to a terminal and running a command the UI never suggested. This
record catalogues what out-of-sync scenarios actually look like, what the app already has to work with,
what's missing, and proposes closing the gap with named, risk-labeled, in-app actions.

### F1 — Current architecture

The Branches tab is a master-detail navigator (`lib/features/branches/branch_navigator.dart`,
`branch_detail.dart`, `branches_view.dart`), governed by
[0003-MADR-base-relative-branches-workspace.md](0003-MADR-base-relative-branches-workspace.md) (accepted,
executed), which chose to retain this navigator shape and added base-relative review. Backing providers
— `branchBaseProvider`, `branchReviewProvider`, `branchMergePreviewProvider`
(`lib/core/providers/app_providers.dart`) — feed `BranchReviewSummary`/`BranchReviewFailure`
(`lib/core/git/branch_comparison.dart`). Ahead/behind counts come from a `for-each-ref
%(ahead-behind:<base>)` atom (`git_service.dart:3473-3529`, from MADR 0039).

### F2 — GitService already covers most of what a reconciliation needs

Verified present, each already instrumented (retried, journaled where the operation is undoable, or
both):

* `merge`/`mergeAbort`/`mergeContinue` (`git_service.dart:4741, 4892, ~4875`) — `MergeMode.{normal,
  noFf, ffOnly, squash}`.
* `rebaseInteractive` (`:4793`) and **`rebaseOnto(repoPath, upstream)`** (`:4853`) — the latter's own doc
  comment states it plainly: *"a plain, non-interactive `git rebase`... replays the current branch's
  commits since its merge-base with `upstream` on top of `upstream`."* A basic rebase-onto-upstream
  action needs no new primitive.
* `rebaseContinue`/`rebaseAbort`, `cherryPick`/`cherryPickAbort`/`cherryPickContinue`,
  `revert`/`revertAbort`/`revertContinue`, `amAbort`/`amContinue` — the full continue/abort set for
  every kind of paused operation git recognises.
* `reset` (`:4554`, soft/mixed/hard) — **journaled**: every mode records an undo entry
  (`UndoOpKind.resetSoft/resetMixed/resetHard`), so a hard reset back to a remote tip is already
  reversible from the app's own undo stack, not just from git's reflog.
* `fetch`, `pull` (`PullMode.ffOnly|merge|rebase`), `push` (`PushForce.none|withLease|force`) —
  force-with-lease is already the safer default option, not just plain `--force`.
* Full stash suite (`push/pop/apply/drop/branch/clear/show/list`, `:5606-5881`).
* `setUpstream`/`unsetUpstream` (`:4209, 4230`) — see F7.
* `reflog(repoPath, ...)` (`:2594`) returning `List<ReflogEntry>` — see F3.

### F3 — Single-clone recovery already exists and is out of this record's scope

`lib/features/recovery/recovery_sheet.dart` (642 lines) is a full reflog browser: checkout a past state,
create a branch at a reflog entry, soft- or hard-reset the current branch to it, restore files from it,
and browse the app's own undo snapshots alongside git's reflog. This already covers "I need to get back
to where I was before something went wrong" for a **single** clone's own history. It does not, and
cannot, help when the divergent state lives on a *different* clone's object store (a commit made and
reset away on a Linux host has no reflog trace on a macOS clone that never fetched it) — that is a
different problem, addressed below, and this record does not touch the Recovery sheet.

### F4 — The right-click context menu (`branch_navigator.dart:1936-2020`, `_localMenu`)

Check out / Switch to its worktree / Check out in a new worktree… — then, if not on the current branch:
Merge into current, Merge (no fast-forward), Merge (fast-forward only), Squash merge — then Set
upstream…, [Unset upstream, if one is set] — Rename…, Pin/Unpin, [Unhide, while hidden rows are shown],
Copy name — Delete branch.

### F5 — The "More" menu (`branch_detail.dart:691-753`, `MacosPulldownButton(title: 'More', ...)`)

Check out (or Switch to worktree) / New worktree… / [Create Pull/Merge Request, if a forge request can
be opened] / [Open on Forge] / [Open reachable history] / Merge into current / **Set upstream…** /
Rename… / Pin/Unpin / Delete. It is missing, relative to the context menu: **Merge (no fast-forward)**,
**Merge (fast-forward only)**, **Squash merge**, and **Unset upstream**. A user working from the detail
pane — the natural place to be when investigating *why* a branch won't sync — has fewer options than one
right-clicking the same branch in the list.

### F6 — The upstream bug, reproduced in code, not just reported

`_setUpstream` (`branches_view.dart:1651-1666`) prompts for a target defaulting to `origin/<name>` and
calls `git.setUpstream(repoPath, name, target)`, which runs exactly:

```
git branch --set-upstream-to=<target> --end-of-options <branch>
```

**This git command only points a local branch at a remote-tracking ref that already exists** —
`refs/remotes/origin/<name>` must already be present in the local object database. For a branch that has
never been pushed anywhere, that ref does not exist, and the command fails. The correct action for that
case is `_publishBranch` (`branches_view.dart:1172`), which runs `git.push(..., setUpstream: true)` —
`git push -u origin <branch>`, creating the remote branch and the tracking link in one step
(`git_service.dart:5266`). **Nothing connects the two.** "Set upstream…" is offered unconditionally in
both menus with no check that its target exists and no message steering a user whose branch has never
been pushed toward Publish instead. This is the concrete instance of "I have not been able to get it to
work via the app menu" and is fixed by this record (Decision Outcome, item 1).

### F7 — Divergence is reported as a number, never explained or acted on

`_divergenceCluster` (`branch_navigator.dart:1746-1800`) shows `↑n ↓n` against the comparison base (or
plain `branch.ahead`/`branch.behind` in Browse mode) and a `gone` badge when upstream was deleted. That
is the entire surface: a count and a tooltip. Nothing distinguishes "behind only, a fast-forward pull
would just work" from "diverged, plain merge/pull will create a merge commit or be refused" from "no
common ancestor at all" — and nothing offers an action beyond the plain merge-mode buttons already in
F4/F5, which do not cover reset-to-remote, rebase, or an unrelated-histories merge.

### F8 — Fetch & Prune exists; bulk cleanup of what it finds does not

`git fetch --all --prune` is already the Branches tab's primary toolbar action
(`branches_view.dart:611-618`, `RepositoryPrimaryActionKind.fetchAndPrune`) — this record does not need
to add fetch/prune itself. What's missing is the next step: after a prune, branches newly marked `gone`
(F7's badge) have no bulk "these N branches no longer exist on the remote — delete them?" affordance;
each must be deleted one at a time, and only if a user notices the badge.

### F9 — Interrupted operations are already fully handled, just not from here

`pendingOpProvider` and a banner in `lib/features/repository/repo_status_view.dart` (`:1470-1560`)
already detect a paused merge/rebase/cherry-pick/revert/am and offer **Continue** or **Abort**, wired to
the exact GitService methods in F2. This is the most likely scenario when a rebase or merge was left
mid-conflict on one host and the repo is then opened from another: every other git command refuses until
it's resolved, and the explanation lives on the Status tab. A user working in Branches sees only that
"Merge into current" mysteriously fails, with no link to the banner that already explains why.

### F10 — What research says these scenarios need, and what maps to what's already true here

A survey of git's own documentation and community canonical answers on multi-clone divergence (sources:
git-scm.com/book, jvns.ca, graphite.dev, git-tower.com, oneuptime.com, and others) converges on:

| Scenario | Symptom | Resolution(s) | Risk | Already in GitService? |
| --- | --- | --- | --- | --- |
| Diverged (both sides have unique commits) | `git status`/pull reports "have diverged, N and M commits" | Rebase local onto remote; merge remote in; reset to remote (discard local) | rebase: needs confirmation · merge: safe · reset: destructive | Yes — `rebaseOnto`, `merge`, `reset` all exist; **no UI ties them to this specific state** |
| No upstream configured | push/pull fail "no upstream branch"; `git branch -vv` shows none | `push -u` (never pushed) or `--set-upstream-to` (remote ref exists) | safe, either way | Yes, but **the UI doesn't distinguish which one applies** (F6) |
| Branch exists remotely, never fetched here | Invisible in the local branch list | `fetch`, then track the remote branch | safe | fetch exists; **no explicit "bring this remote branch's tracking local branch over" action** surfaced distinctly from checkout |
| Stale/deleted remote-tracking (`[gone]`) | `git branch -vv` shows `: gone]` | `fetch --prune`, then delete the local branch | prune: safe · delete: needs confirmation | Both exist (F8); **no bulk action tying prune's result to cleanup** |
| Force-pushed history rewrite | `fetch` reports "(forced update)"; pull produces odd results | Rebase onto the new tip, or reset to it after a backup | needs confirmation / destructive | `rebaseOnto`, `reset` exist; app's own undo journal (F2) already stands in for "backup first" |
| Unrelated histories | `fatal: refusing to merge unrelated histories` | Confirm via `merge-base` that there's truly no common ancestor, then `merge --allow-unrelated-histories` as an explicit opt-in | destructive-shaped (always needs confirmation) | **`merge-base` check and the `--allow-unrelated-histories` flag are both absent** — the one real gap in git primitives |
| Interrupted operation | Any command refuses "conclude your merge/rebase/etc first" | Abort or continue | abort: safe (restores prior state) · continue: needs confirmation | Fully present (F9); **not surfaced from Branches** |

GUI precedent (GitHub Desktop, GitKraken): turn a failing terminal command into a **named-strategy
decision dialog** — "Your branches have diverged: Rebase / Merge / Reset?" — rather than raw git error
text. That pattern, not a wizard that tries to handle everything in one screen, is what item 3 of the
Decision Outcome follows.

## Decision Drivers

* Every scenario in F10 should be resolvable from Magic Git without a terminal — that is the whole
  premise of the app, and it currently stops at "here is a number."
* A destructive action (reset discarding local commits, an unrelated-histories merge) must never run
  without a confirmation naming exactly what is at risk, and must route through the app's existing undo
  journal (F2) wherever the operation already supports it — not invent a second, parallel safety net.
* The context menu and the (renamed) Advanced menu must offer the same actions for the same branch. A
  capability that exists in one and not the other is a bug, not a feature difference (F5).
* Fix the confirmed upstream/publish defect (F6) as part of this work — it is the single most concrete,
  reported complaint, and the model that fixes it (distinguishing "never pushed" from "remote ref
  exists") is the same model the rest of this record needs anyway.
* Prefer surfacing what already exists (F9's abort/continue, F8's fetch/prune) over building new
  mechanisms, and add the smallest new primitive that closes each real gap (F10's `merge-base` and
  `--allow-unrelated-histories`) rather than reinventing git plumbing.
* A single ahead/behind number is not an adequate description of state once "diverged" and "unrelated
  histories" are both possible outcomes; the UI needs a named state, not just a count.

## Considered Options

* **A — Fix the upstream bug and rename the menu only.** No new sync-state model, no new actions.
* **B — A, plus menu parity and explanatory text.** Sync the Advanced menu with the context menu; add
  hover/inline explanations of what ahead/behind and gone mean. No new git capability, no reconciliation
  flow.
* **C — B, plus a named divergence-state model and guided reconciliation actions.** Classify each
  branch's sync state (synced / ahead / behind / diverged / unrelated histories / no upstream / stale
  tracking / operation in progress) from data already fetched plus one new lightweight check
  (`merge-base`), surface it as a labeled state instead of a bare count, and offer a per-state action set
  — a "Reconcile…" dialog for diverged/unrelated-histories branches (rebase / merge / reset, each risk-
  labeled), a smart upstream fix, a bulk stale-branch cleanup after Fetch & Prune, and a link from
  Branches to the existing pending-op abort/continue banner.
* **D — C, plus proactive background conflict scanning** (GitKraken-style: scan every local branch
  against its base for future merge conflicts before the user asks).

## Decision Outcome

Chosen option: **"C — named divergence states with guided, risk-labeled reconciliation actions"**,
because it is the option that actually answers the scenarios in F10 using primitives the app mostly
already has, closes the two concrete defects (F5's menu gap, F6's upstream bug) as part of the same
model rather than as a separate patch, and stays a scoped, shippable-in-phases piece of work. D's
proactive scanning is a materially different feature — background work, a notification surface, false-
positive management — that deserves its own record once C's per-branch state model exists to build on;
it is not needed to answer the multi-host divergence problem this record was raised for.

Concretely, in four parts:

**1. Fix the upstream defect and the menu-parity gap (no new git capability).**

* `_setUpstream`'s prompt path is replaced by two distinct, correctly-gated actions: **Publish…** (push
  `-u`, offered when the branch has no upstream and no matching `refs/remotes/<remote>/<name>` exists)
  and **Set upstream…** (point at an existing remote-tracking ref, offered — and only offered — when one
  exists). Whichever does not apply is omitted from the menu, not merely disabled, so there is nothing
  to click that will fail.
* The "More" menu (renamed **Advanced**, per the request) gains **Merge (no fast-forward)**, **Merge
  (fast-forward only)**, **Squash merge**, and **Unset upstream** — full parity with the context menu.

**2. A per-branch `BranchSyncState`**, computed from data already fetched (the ahead/behind atom, refs,
upstream) plus one new call:

```dart
enum BranchSyncState {
  upToDate, aheadOnly, behindOnly, diverged,
  unrelatedHistories, noUpstream, staleTracking, // gone
}
```

`diverged` vs `unrelatedHistories` is the one distinction that needs new information: a **new**
`GitService.mergeBase(repoPath, a, b)` returning the merge-base OID or `null`. Per F10's own diagnostic
guidance, a `null` merge-base means genuinely unrelated histories; a real OID with both ahead and behind
counts positive means an ordinary divergence. `operationInProgress` reuses the existing `pendingOp`
value rather than joining this enum, since it already has its own provider and UI (F9) and gates
everything else regardless of sync state.

This state replaces the bare `↑n ↓n` in both the navigator row and the detail pane with a short label
(e.g. "Diverged", "No upstream", "Stale — deleted on remote") and a tooltip stating the actual git-level
reason (matching the git status text a terminal would show), not just a number.

**3. A "Reconcile…" action**, appearing in both menus only when a branch's state warrants it, opening a
dialog that names the state and offers exactly the actions that apply to it — the "turn a failing
command into a named-strategy choice" pattern from F10:

* `diverged`: **Rebase onto `<upstream>`** (needs confirmation — replays local commits; runs
  `rebaseOnto`, already undo-journaled) · **Merge `<upstream>` into this branch** (safe — preserves both
  histories; runs `merge`) · **Reset to `<upstream>`** (destructive — discards local-only commits; runs
  the existing instrumented `reset(..., mode: hard)`, and the dialog states plainly that this is
  reversible from the app's Undo menu, per F2, rather than inventing a separate backup step).
* `unrelatedHistories`: **Merge (allow unrelated histories)…** only, always requiring its own typed
  confirmation (never a default/pre-selected option) — a new `GitService` method or `merge()` parameter
  adding `--allow-unrelated-histories`.
* `staleTracking`: **Delete stale branch**, plus a bulk variant: after Fetch & Prune completes and finds
  newly-gone branches, a summary offers "N branches no longer exist on the remote — clean up?"

**4. Cross-tab discoverability for interrupted operations.** When `pendingOpProvider` is not `none`, the
Branches row and detail pane for the affected repository show a small inline indicator ("Rebase in
progress…") that opens the same Continue/Abort affordance the Status tab already has (F9) — no new
GitService method, no new abort/continue logic, just a second place the existing state is visible.

### Consequences

* Good, because every scenario a multi-host workflow actually produces (F10's table) has a named,
  in-app resolution, and the two concrete defects reported (upstream, menu parity) are fixed as part of
  the same model rather than bolted on separately.
* Good, because destructive actions route through the app's existing undo journal (F2) instead of a new,
  parallel safety mechanism — one system to trust, not two.
* Good, because the new git surface is small: one read (`merge-base`) and one write parameter
  (`--allow-unrelated-histories`); everything else is UI over primitives already instrumented.
* Neutral, because the "Reconcile…" dialog is new UI that has to earn its keep — three or four choices,
  clearly labeled, or it becomes exactly the wall of unexplained options this record exists to replace.
* Bad, because `BranchSyncState` is another piece of state every branch row computation now carries,
  and a state machine that's wrong in an edge case (e.g. a branch with no upstream *and* an in-progress
  operation) needs a defined precedence, not an implicit one.

### Confirmation

* A branch with local-only commits and a remote with different commits ahead shows `diverged`, not a
  bare ahead/behind count, and offers Rebase/Merge/Reset — each verified against a real diverged pair in
  a scratch repo, including that Reset appears in the app's Undo menu afterward.
* A branch created fresh, never pushed: **Publish…** is offered, **Set upstream…** is not. A branch whose
  remote-tracking ref exists but isn't linked: the reverse. Neither ever fails with today's raw
  `--set-upstream-to` error.
* Two repos with genuinely unrelated histories (`git merge-base` returns nothing) show `unrelatedHistories`
  and only the allow-unrelated-histories action, requiring its own confirmation text.
* After Fetch & Prune finds branches newly marked gone, a bulk cleanup offer appears and deleting via it
  removes exactly those branches.
* With a rebase left mid-conflict (via the Status tab, as today), opening Branches shows the in-progress
  indicator, and it opens the same Continue/Abort dialog Status already has.
* The Advanced menu (renamed from More) and the right-click context menu offer the identical action set
  for the same branch, verified item-for-item.

## Pros and Cons of the Options

### A — Fix the upstream bug and rename only

* Good, because it is the smallest possible change and fixes the one bug already reported by name.
* Bad, because it leaves every other scenario in F10 exactly as unresolved as today — the actual
  complaint ("it reports what to do manually but doesn't let me act") is untouched.

### B — A, plus menu parity and explanatory text

* Good, because it closes the concrete menu-asymmetry defect and makes the existing ahead/behind number
  at least explain itself.
* Bad, because "explains itself" without an action attached is still "go open a terminal" — it improves
  the diagnosis, not the cure, for diverged/unrelated-histories/stale-cleanup scenarios.

### C — B, plus named divergence states and guided reconciliation *(chosen)*

* Good, because it is the option that actually lets a user resolve a diverged or unrelated-histories
  repository inside the app, which is the request this record was raised to answer.
* Good, because every new action reuses an existing, already-instrumented GitService primitive except
  for `merge-base` and `--allow-unrelated-histories`.
* Neutral, because it is more UI surface than A/B — a new dialog, a new per-branch state, two new menu
  items — and needs its own implementation plan sized accordingly.
* Bad, because a wrongly-classified state (e.g. a false `diverged` reading from a stale ahead/behind
  cache) would offer the wrong reconciliation options; the state computation needs to be as trustworthy
  as the merge-mode buttons it's replacing the plain count with.

### D — C, plus proactive background conflict scanning

* Good, because it matches GitKraken's most-cited UX advantage — surfacing a future conflict before the
  user attempts the merge that would hit it.
* Bad, because it is a genuinely different feature (background scanning, a notification/badge surface,
  false-positive tolerance) layered on top of C's per-branch state rather than an extension of the
  reconciliation dialog itself, and does not answer the specific "my clones are out of sync" problem
  this record exists for — it answers "will my next merge conflict," a related but separate question.
* Bad, because it costs continuous background git work (a `merge-tree`-style check per branch pair) with
  no natural cache-invalidation story yet designed, which C avoids by reusing the merge-base check
  already run on demand by the existing merge-preview path (Amendment 0051.1).

## Amendments

### 0051.1 — three things already built, found while drafting the plan (2026-09-17)

**What this record assumed.** That `merge-base`/unrelated-histories detection needed a new
`GitService.mergeBase()` method (F10, Decision Outcome item 2); that fixing the upstream defect meant
conditionally hiding whichever of Publish/Set-upstream doesn't apply (Decision Outcome item 1); and, more
implicitly, that the "Reconcile…" dialog (item 3) was new UI to build from nothing.

**What the plan-drafting investigation found.** All three already exist, in whole or in the load-bearing
part:

1. **`merge-base` and unrelated-histories detection already exist and already render.**
   `GitService._mergeTreePreviewUnlocked` already runs `git merge-base` and returns
   `BranchMergePreview.unrelated()` when it finds none; a separate `ComparisonAncestry.unrelated` flag is
   already computed and the detail pane already shows "No common ancestor…" for it — with no action
   attached, which is the actual gap. No new `mergeBase()` method is needed; the only new primitive is
   `allowUnrelatedHistories` as a `merge()` parameter, wired to the display that already exists.
2. **The "Reconcile…" dialog is largely already built.** `_dropOnCurrent` (the drag-and-drop "combine
   branches" flow) already offers a named Merge-vs-Rebase choice through the generic `chooseAction<T>`
   dialog primitive and a `DropOp` enum — it is wired only from drag-and-drop, not from either menu. The
   plan extends this existing mechanism (a third "Reset to upstream" choice, new menu call sites) instead
   of inventing new dialog machinery.
3. **The upstream fix is narrower than F6/the Decision Outcome stated.** `_publishBranch`'s menu
   visibility is already gated on `upstream == null` — already correct, nothing to hide. `_setUpstream` is
   a free-text prompt (not fixed to `origin/<name>`) that simply never validates its typed target against
   the real ref list before calling `git branch --set-upstream-to`. The fix is that validation and its
   error message, not conditional menu-item visibility.

**Decision unchanged.** Option C stands; this only corrects how much of it already exists, which is more
than F10 credited, and narrows the plan's actual new-code surface accordingly.

## More Information

* **Origin.** Maintainer request: multi-host (Windows/Linux/macOS) development on the same repositories
  produces diverged branches, missing upstreams, and other exception states the Branches tab reports but
  cannot act on; "Set upstream…" specifically does not work via the app menu.
* **Code this record reads.** `lib/features/branches/branch_navigator.dart` (`_localMenu`,
  `_divergenceCluster`), `branch_detail.dart` (`moreItems`/`More` button), `branches_view.dart`
  (`_setUpstream`, `_publishBranch`, `_fetchPrune`, the primary-action wiring);
  `lib/core/git/git_service.dart` (merge/rebase/cherry-pick/revert/am/reset/stash/upstream/reflog
  methods, `:2594-5881`); `lib/features/recovery/recovery_sheet.dart` (existing single-clone reflog
  recovery, out of this record's scope); `lib/features/repository/repo_status_view.dart` (existing
  pending-op abort/continue banner); `lib/core/providers/app_providers.dart` (branch-related providers,
  `pendingOpProvider`).
* **Governing record.** [0003-MADR-base-relative-branches-workspace.md](0003-MADR-base-relative-branches-workspace.md)
  — this record extends that navigator, does not replace it.
* **Research sources consulted** (web): git-scm.com's Pro Git book (reflog, merge-base, unrelated
  histories); jvns.ca, graphite.dev, oneuptime.com, git-tower.com on diverged-branch resolution
  strategies and risk framing; geeksforgeeks.org and vancelucas.com on upstream configuration;
  betterstack.com on stale remote-tracking cleanup; dev.to (vast-cow) and datacamp.com on force-push
  recovery; adamj.eu and tecadmin.net on interrupted-operation state files; git-scm.com/book on
  `rerere`/`range-diff`. GUI precedent from gitkraken.com/help.gitkraken.com and general comparison
  write-ups on GitHub Desktop's/Sourcetree's conflict and divergence handling (directional UX signal,
  not a technical spec).
* **Not established.** The exact precedence when a branch is simultaneously `noUpstream` and mid-
  operation, or `staleTracking` and `diverged` against a different base — the state machine's tie-
  breaking rules belong in the implementation plan, grounded in what combinations are actually reachable
  once `BranchSyncState` is built against real repositories. Whether `git fsck --lost-found`-based
  dangling-commit recovery (a single-clone, not multi-clone, scenario) is worth adding to the existing
  Recovery sheet is a separate, smaller question this record does not decide either way.
* **No implementation exists.** This record proposes a decision; a plan follows only on approval.
