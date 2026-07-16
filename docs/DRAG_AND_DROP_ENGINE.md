# Drag-and-Drop Engine — Feasibility & Design Report

**Status:** proposal for review (not yet implemented)
**Scope:** a canonical, reusable drag-and-drop (DnD) engine for Magic Git, with the
signature interaction being **drag an item out of a tab panel and drop it onto a
nav-rail tab** to trigger a git/forge workflow (e.g. commit → *Branches* = new
branch from that commit; branch → *Worktrees* = new worktree from that branch).

This report merges two research passes: (A) reconnaissance of the actual codebase,
and (B) web research into DnD UX across Tower, Fork, GitKraken, GitHub Desktop, and
GitHub/GitLab web. Sources for (B) are cited inline in §2.

---

## 0. Executive verdict

**Feasible, and most of the substrate already exists.** The app already ships a
working `Draggable<GitRef>` → `DragTarget<GitRef>` pair (branch chips → commit
rows, with a post-drop merge/rebase menu), a `ContextMenuOverlay` choice-menu
mechanism, a `runLogged`/`runGuarded` dispatch contract with **automatic undo
journaling** in `GitService`, and repoPath-keyed family providers plus a
`_selectPage(index)` hook for post-drop navigation. What's missing is (1) a
**generalized payload vocabulary** (today only `GitRef` is draggable), (2) a
**rule registry** mapping *(payload, drop-zone) → actions* so workflows are data,
not bespoke widget wiring, and (3) **drop targets on the nav rail**, which is the
one genuine architectural obstacle.

**The one load-bearing obstacle:** the nav rail is macOS-native `macos_ui`
`Sidebar` + `SidebarItems`, fed a `const List<SidebarItem>` (`app_shell.dart:643`).
`SidebarItem` is an opaque *data* object, not a widget, and `SidebarItems` exposes
no per-item builder — **so individual nav items cannot be wrapped in a
`DragTarget`.** The recommended fix (§3.1) is to replace `SidebarItems` with a
small custom column of visually-identical nav rows that we control. This is a
contained, reversible change and it *unlocks the report's best idea* (§4.1, the
rail that lights up its valid drop zones the instant you pick something up).

**Recommendation:** build the canonical engine (§3), replace the sidebar item
list with a custom nav rail (§3.1), and ship the interactions in the phased
roadmap (§5), starting with the two you named — commit→Branches and
branch→Worktrees — because they are unambiguous, non-destructive, and showcase
the whole pattern.

---

## 1. What the codebase already gives us

*(Full file:line map in the appendix, §8.)*

| Building block | Where | Reuse |
|---|---|---|
| `Draggable<GitRef>` (branch chips) | `ref_chip.dart:178`, gated by `enableDrag` | Generalize its payload |
| `DragTarget<GitRef>` + drop menu | `history_view.dart:1640` (`_onBranchDropped`) | The template for every drop |
| `ContextMenuOverlay.show(ctx, offset, entries)` | `context_menu.dart:45` | The post-drop verb menu |
| `BusyActionState.runLogged/runGuarded` | `busy_action.dart:34` | Dispatch + busy-gate + error dialog |
| `confirmAction(...destructive)` | `actions.dart:150` | Confirm gate for destructive drops |
| `guardedBranchSwitch(...)` | `branch_switch.dart:22` | Dirty-tree guardrail on checkout |
| Auto-undo journaling | `GitService._runCaptured` | Undo toast "for free" on most mutations |
| `pageIndexProvider` + `_selectPage(i)` | `tab_ui_providers.dart:10`, `app_shell.dart:230` | Navigate to a tab after a drop |
| repoPath-keyed families | `statusProvider`, `refsProvider`, `gitWorktreesProvider`, `stashesProvider`, `logProvider` | Read source objects; refresh after |

**Draggable data models that exist today** (all `git_service.dart` except files):
`GitCommit` (hash/parents/subject, `:624`), `GitRef` (name/oid/isLocalBranch/
shortName, `:137`), `GitStash` (index/oid/message, `:430`), `GitWorktree`
(path/branch/headOid, `:272`), and `GitFileStatus` (path/staged/unstaged,
`git_porcelain_parser.dart:1`).

**Service methods that can be drop *actions*** (already present, mostly journaled):
`branchFrom`, `createBranch`, `checkout`, `cherryPick`, `revert`, `reset`, `merge`,
`rebaseOnto`, `createTag`, `push`, `addWorktree` *(the worktree-create drop)*,
`stashApply`, plus forge `createMergeRequest`/`createPullRequest`,
`checkoutMergeRequest`/`checkoutPullRequest`. **No new git plumbing is required for
the phase-1 interactions** — they all bottom out in existing service calls behind
the `CommandExecutor` seam, so they work identically on remote and local backends.

---

## 2. Web research digest — what users actually love, request, and hate

### The gold standard: GitKraken's drop-hint menu
Drag a branch, drop it on another branch, and **a verb-labeled menu pops up** —
"Merge dev into production", "Rebase X onto Y". The drop does **not** execute; you
pick the verb. The menu *is* the confirmation and makes the operation
self-documenting. This is the single most-praised gesture in the entire corpus
("you can merge or rebase by dragging branches to each other… lowers the risk of
taking the wrong branch"). *Adopt this pattern wholesale — we already do a
narrow version of it in the history drop menu.*
Sources: help.gitkraken.com/gitkraken-desktop/branching-and-merging/,
news.ycombinator.com/item?id=13999458, /item?id=25045939, /item?id=38907917.

### The widest surface: Tower — and it validates the nav-drop idea
Tower is the direct precedent for **drop-target-semantics** (the *where* encodes
the *what*), which is exactly the user's nav-rail concept:
- commit → **Branches/Tags header** → create branch/tag from commit
- commit → **Working Copy** → cherry-pick
- branch → **Worktrees group** → create a worktree
- branch → **Pull Requests section** → create a PR
- files → **Stashes** → partial stash; stash/file → **Working Copy** → apply
Source: git-tower.com/help/mac/faq-and-tips/tips-and-tricks/drag-drop.
*Tower drops onto **sidebar section headers**; our innovation is dropping onto
**nav tabs**, which is the same mental model applied to our IA.*

### The others (bounding the design)
- **Fork** — drag stage/unstage, drag branch-onto-branch (merge-vs-rebase
  popover), and (Aug 2025) drag-reorder/squash in interactive rebase.
- **GitHub Desktop** — commit-history DnD only: drag-to-cherry-pick (2.7),
  drag-to-squash + drag-to-reorder (2.9); Undo lives in a success banner, no
  pre-drop confirm; ships a **one-time coach-mark per gesture** for discoverability.
- **GitHub/GitLab web** — no git-graph DnD at all (file upload + issue boards
  only); GitLab's board DnD is a cautionary tale of unreliable drag.
Sources: git-fork.com/releasenotes, github.blog/…/github-desktop-2-9-…,
github.com/desktop/desktop/issues/12419.

### Most-requested-but-missing (open opportunities)
- **Drag-to-reorder/cherry-pick/squash commits** — the strongest organic demand
  in the corpus (Sublime Merge #1194, 34👍; GitKraken feedback #617726).
- **Drag a branch label onto a commit to move the pointer** (`git branch -f`) —
  GitKraken's #2 request, nobody ships it well.
- **Drag files Unstaged→Staged** — open against GitKraken; SourceTree's removal of
  it caused a user revolt.

### What reviewers hate (our non-negotiable guardrails)
- **Accidental destructive drags with no abort** — GitKraken users had to drop to
  the CLI (`git cherry-pick --abort`) or re-clone. *(feedback.gitkraken.com/…/315381)*
- **Dropping a commit back onto its own branch** broke GitHub Desktop. *(#11915)*
- **ESC not cancelling an in-progress drag** — GitHub Desktop had to add it. *(#11925)*
- **Reorders firing too easily** — users wanted a modifier to "arm" the drag.
- **Unreliable drag** (GitLab boards jumping/snapping back) is the loudest
  complaint of all — *a drag that misfires is worse than no drag.*

**Distilled principles:**
1. Ambiguity is resolved by **drop target** first, and a **verb menu** only for the
   genuinely ambiguous (merge-vs-rebase). Don't over-menu.
2. **Destructive drops confirm by default; a modifier bypasses.**
3. **ESC cancels; invalid targets show a "can't drop" state; same-target is a no-op.**
4. **Always keep the right-click / command-palette equivalent** — DnD is never the
   only path (also buys accessibility).
5. **Teach it** — DnD is invisible until discovered; coach-marks or a lit-up rail.

---

## 3. The canonical engine

The design goal from the brief — *"canonicalized, and readily available moving
forward"* — means new workflows should be **registry entries, not new widgets.**
Four pieces:

### 3.0 A unified payload vocabulary
Replace the `GitRef`-only `Draggable` with one sealed payload type so every
draggable surface speaks the same language:

```dart
sealed class DragItem {
  const DragItem();
  String get shortLabel;            // for the drag feedback chip
}
class DragRef     extends DragItem { final GitRef ref; }
class DragCommit  extends DragItem { final GitCommit commit; }
class DragStash   extends DragItem { final GitStash stash; }
class DragFiles   extends DragItem { final List<GitFileStatus> files; }
class DragWorktree extends DragItem { final GitWorktree worktree; }
```

A single `DragItemDraggable` widget (wrapping Flutter's `Draggable<DragItem>`)
provides the shared feedback ghost, `childWhenDragging` fade, and
`pointerDragAnchorStrategy`, so every panel drags consistently. The existing
`RefChip` becomes a thin caller.

### 3.1 Drop zones — including the nav rail
A `DropZone({required DropZoneId id, required Widget child})` widget wraps any
target — a nav row, a panel header, a list row — and internally is a
`DragTarget<DragItem>` that (a) asks the registry whether the payload is
acceptable, (b) renders the accept/reject affordance, and (c) on accept invokes
the registry to run or present the actions.

`DropZoneId` enumerates the nav tabs (`repository`, `history`, `branches`,
`stashes`, `forge`, `project`, `worktrees`) plus in-panel zones (`workingCopy`,
`stagedList`, `unstagedList`, `commitRow`, `branchLabel`, …).

**Nav-rail obstacle & fix.** Because `macos_ui` `SidebarItems` can't host per-item
`DragTarget`s (§0), introduce a `NavRail` widget: a custom `Column` of `NavRow`s
that reproduces the `SidebarItem` look (leading `MacosIcon`, label, selected
tint, hover) and wraps each row in a `DropZone`. It reads/writes the same
`pageIndexProvider`/`visitedPagesProvider`, so behavior is unchanged when nothing
is being dragged. This is the root-cause fix (vs. hit-testing inside one big
`DragTarget`, which fights the framework and can't light individual items).

### 3.2 The rule registry — where workflows live
One table maps *(payload kind, zone) → list of `DropAction`s*:

```dart
class DropAction {
  final String label;              // "New branch from a1b2c3d"
  final IconData icon;
  final bool destructive;          // gates confirm-by-default
  final Future<void> Function(DropContext ctx) run;
}
typedef DropRule = List<DropAction> Function(DragItem item, DropContext ctx);

final Map<(Type, DropZoneId), DropRule> kDropRegistry = { … };
```

`DropContext` carries `ref`, `repoPath`, the current branch, and the dispatch
helpers (`runLogged`, `confirmAction`, `selectPage`). Adding "drag commit →
Worktrees" later is **one registry entry**, not a widget change — that is the
"canonicalized, readily available" property the brief asked for.

Resolution flow on drop:
1. Registry returns the actions for *(payload, zone)*.
2. **0 actions** → the zone already showed "can't drop"; no-op.
3. **1 unambiguous non-destructive action** → run it directly, then
   `selectPage(zone)` to reveal the result.
4. **>1 action, or any destructive action** → open `ContextMenuOverlay` at the
   drop point with the verb list (GitKraken pattern); destructive items confirm
   (or bypass with ⌥) before dispatch.

### 3.3 The drag controller — reactive affordances
A tiny `dragStateProvider` (a `Notifier<DragItem?>`) is set on `onDragStarted` and
cleared on end/cancel. The `NavRail` watches it so that **the moment a drag
begins, every zone that can accept the payload lights up** (§4.1). This is the
mechanism that solves the discoverability problem the research flagged, and it's
cheap — one provider, no per-frame work.

---

## 4. The nav-rail interaction model (the core proposal)

### 4.1 "The rail becomes a launchpad"
When you pick up an item, the nav rail transforms: acceptable tabs brighten and
swap their label for the **action they'll perform**, unacceptable tabs dim. Pick
up a commit and the rail says, at a glance:

```
  Repository   → Cherry-pick here
  History      · (dim)
  Branches     → New branch / tag…      ← highlighted
  Stashes      · (dim)
  Forge        · (dim)
  Project      · (dim)
  Worktrees    → New worktree…          ← highlighted
```

This directly answers the #1 UX complaint across every client — *DnD is invisible
until you stumble onto it* — without modal coach-marks. It's innovative (no
surveyed client repurposes its primary nav as a drop launchpad) and it's honest
(it only lights what will actually work).

### 4.2 Payload × nav-tab matrix
Legend: **✓** phase-1 (unambiguous, safe), **▲** later phase,
⚠ destructive (confirm-gated), — not offered.

| Drag ↓ / Drop → | Repository (working copy) | History | Branches | Stashes | Forge | Worktrees |
|---|---|---|---|---|---|---|
| **Commit** | ▲ Cherry-pick into current ⚠ | ▲ Filter history to here | **✓ New branch from commit** / New tag | — | ▲ New branch + start PR | **✓ New worktree at commit** (detached) |
| **Branch** | ▲ Checkout (guarded) | ▲ Show branch history | ▲ Merge / Rebase / New branch from | — | **✓ Create PR/MR from branch** | **✓ New worktree for branch** |
| **Stash** | ▲ Apply / Pop ⚠ | — | ▲ Branch from stash | ▲ (reorder n/a) | — | — |
| **File(s)** | ▲ Stage / Unstage | — | — | **✓ Stash selected files** | — | — |
| **Worktree** | ▲ Open worktree | ▲ Its history | — | — | — | ▲ (remove via panel) |

**Phase-1 set (the four to build first):** commit→Branches, commit→Worktrees,
branch→Worktrees, branch→Forge, files→Stashes. All are single-verb,
non-destructive, and map to existing service calls (`branchFrom`, `addWorktree`,
`createPullRequest`/`createMergeRequest`, `stash push -- <paths>`).

### 4.3 Worked examples
- **Commit → Branches.** Drop opens (or, if you configure single-verb, directly
  runs) `branchFrom(repoPath, name, sha)`. Because a name is needed, this one
  shows a tiny inline name field seeded with a suggestion, then dispatches via
  `runLogged` (undo toast free) and `selectPage(branches)`.
- **Branch → Worktrees.** `addWorktree(repoPath, path: <picked>, newBranch or
  commitish: branch.shortName)`; on success `selectPage(worktrees)` reveals it.
- **Branch → Forge.** Routes to `createPullRequest`/`createMergeRequest` for the
  active forge; `selectPage(forge)` opens the new MR/PR. Highest-value for a
  forge-integrated client and unique among "drop-on-nav" designs.

---

## 5. Phased roadmap

**Phase 0 — engine substrate (no user-visible change yet).**
`DragItem` vocabulary, `DragItemDraggable`, `DropZone`, `dragStateProvider`,
`kDropRegistry` skeleton, and the `NavRail` replacement for `SidebarItems`
(verified pixel-identical when idle). Port the *existing* branch→commit
merge/rebase drop onto the new engine to prove parity. Tests: registry resolution
(pure), NavRail idle-equivalence widget test.

**Phase 1 — the named wins.** commit→Branches, commit→Worktrees, branch→Worktrees,
branch→Forge, files→Stashes, plus the "rail lights up" affordance (§4.1). Each is
one registry entry + making the source rows draggable. Widget tests simulating
drag→drop→dispatch (mirroring `history_drag_merge_test.dart`).

**Phase 2 — in-panel power moves.** branch→Branches (merge/rebase/new-from),
stash→Repository (apply/pop ⚠), commit→Repository (cherry-pick ⚠),
files→staged/unstaged drag-to-stage, navigational drops (branch→History filter).

**Phase 3 — history surgery & advanced.** Drag-to-reorder / drag-to-squash inside
an interactive-rebase editor (the most-requested-but-missing gesture industry-wide;
builds on `rebaseInteractive`), and drag-a-branch-label-onto-a-commit to move the
pointer ⚠ (GitKraken's unfilled #2 request — a differentiator).

Each phase is independently shippable; nothing after Phase 0 blocks anything else.

---

## 6. Safety rails & discoverability (baked into the engine, not per-feature)

- **ESC cancels an in-progress drag** (`Draggable` + a global escape handler).
- **Post-drop verb menu is the confirm** for ambiguous ops; **destructive drops
  confirm by default via `confirmAction(destructive: true)`, with ⌥ to bypass.**
- **Invalid/no-op targets** render a dim "can't drop" state and reject the drop;
  **same-source guards** (branch onto its own tip, commit onto its own branch)
  prevent the GitHub Desktop #11915 class of bug.
- **Undo toast** comes free from `_runCaptured` journaling for the journaled ops;
  for the few network/non-journaled ones (push, PR create), the success banner
  states what happened and offers the inverse where one exists.
- **Right-click + command-palette equivalents stay** for every drop action — DnD
  is additive. This also gives us keyboard/accessibility parity; a future
  **click-to-pick / click-to-place** mode (pick an item, then click a lit nav
  zone) reuses the *same* `dragStateProvider` + registry and gets trackpad/touch/
  motor-accessibility "for free."
- **Discoverability** is handled primarily by the lit-up rail (§4.1); a one-time
  coach-mark on first launch after the feature ships is a cheap backstop.
- **Reliability is a feature.** Because we dispatch through the tested
  `runLogged`/service layer rather than bespoke drag code, we avoid the
  silently-failing-drag reputation that sank GitLab's boards.

---

## 7. Decisions for review

1. **Nav-rail replacement** — OK to swap `macos_ui` `SidebarItems` for a custom
   `NavRail` column (required for per-tab drop targets and the lit-up affordance)?
   *(Recommended: yes — it's the root-cause fix and contained.)*
2. **Direct-run vs. always-menu** for single-verb drops — run immediately and
   navigate, or always show a one-item confirm menu? *(Recommended: direct-run for
   non-destructive, menu only for ambiguous/destructive.)*
3. **Phase-1 scope** — the five in §4.2, or trim to just your two named examples
   (commit→Branches, branch→Worktrees) for a first cut?
4. **Naming a worktree/branch on drop** — inline mini-field vs. a small sheet?
5. **Click-to-pick accessibility mode** — Phase 1 or deferred? *(It's cheap once
   the registry exists; recommend Phase 2.)*

---

## 8. Appendix — codebase reference map

- **Sidebar / nav:** `app_shell.dart:623` (`Sidebar`), `:643` (`SidebarItems`),
  `:650-677` (the 7 `SidebarItem`s, order: Repository 0, History 1, Branches 2,
  Stashes 3, Forge 4, Project 5, Worktrees 6). Switch: `_selectPage`
  `app_shell.dart:230`; state `pageIndexProvider` `tab_ui_providers.dart:10`,
  `visitedPagesProvider` `:26`; mount gating `app_shell.dart:720`.
- **Existing DnD:** `ref_chip.dart:178` (`Draggable<GitRef>`, `enableDrag` `:159`);
  `history_view.dart:1640` (`DragTarget<GitRef>`), `:1764` `_onBranchDropped`,
  `:1793` `_actMergeInto`, `:1809` `_actRebaseOnto`, `:1748` `_currentBranchName`.
  These are the only two Draggable/DragTarget sites in the app.
- **Models:** `GitCommit` `git_service.dart:624`, `GitRef` `:137`, `GitStash`
  `:430`, `GitWorktree` `:272`, `GitFileStatus` `git_porcelain_parser.dart:1`.
- **Action methods:** `checkout` `:2430`, `createBranch` `:2455`, `branchFrom`
  `:2923`, `cherryPick` `:2771`, `reset` `:2848`, `merge` `:3034`, `rebaseOnto`
  `:3146`, `rebaseInteractive` `:3086`, `createTag` `:3279`, `push` `:3241`,
  `addWorktree` `:1086`, `stashApply` `:3558`. Forge:
  `glab_service.dart:902` `createMergeRequest`, `:956` `checkoutMergeRequest`;
  `gh_service.dart:465` `createPullRequest`, `:544` `checkoutPullRequest`.
- **Dispatch/feedback:** `busy_action.dart:34` (`BusyActionState`, `runLogged` `:91`,
  `runGuarded` `:49`); `actions.dart:150` `confirmAction`; `branch_switch.dart:22`
  `guardedBranchSwitch`; `context_menu.dart:45` `ContextMenuOverlay.show`.
- **Grep-binary files** (use `grep -a`/Read): `app_providers.dart`,
  `git_porcelain_parser.dart`.

*Web sources are cited inline in §2; full set gathered from official docs,
changelogs, GitHub/GitLab issue trackers, Hacker News, Product Hunt, and Capterra.
Caveats: GitKraken feedback vote counts are snippet-approximate (Cloudflare-
blocked); Reddit was unretrievable; vendor comparison copy treated as advocacy.*
