---
status: accepted
date: 2026-08-15
decision-makers: maccavelli (maintainer)
consulted: current help_book.json v1.1, kKeymapActions, kMenuBarMenus, 0005/0008/0009 workspace and chrome records
informed: implementers of the Help Book rewrite
verified: 2026-08-20
---

# Rewrite the in-app Help Book against the current workspace and bind taught shortcuts to the keymap

## Context and Problem Statement

Magic Git ships a native Help window (Help ▸ Support & Help, ⌘?) whose
content is the hand-authored JSON book at `macos/Runner/help_book.json`
(version **1.1**, title *Magic Git User Guide*). The renderer
(`HelpView.swift` / `HelpViewLegacy`) is a searchable topic browser. It
does not generate text from the running app.

The book was written against an earlier six-tab client. Since then the
product has grown a task-centered adaptive workspace
([0005-MADR](0005-MADR-task-centered-adaptive-repository-workspace.md)),
a single context bar plus a real menu bar
([0008-MADR](0008-MADR-unified-repository-chrome.md)), remappable
shortcuts, a command palette with entity prefixes, docked File View,
Dashboard, Recovery, Activity, multi-repo File tabs and saved
workspaces, clone/create wizards, a file viewer with remote edit,
blame, file history, image/LFS diffs, and first-class drag-and-drop.
[0009-MADR](0009-MADR-ui-ux-debug-pass-backlog.md) finding **M27**
already called the book “broadly stale.” Phase 10 of 0009 closed the
*dangerous-chord* subset (H18: ⌘⇧B is checkout, not All Branches;
bogus ⌘⇧C / ⌘⇧O / ⌘S / ⌘? rows; landing/PEM/overlay sentences
touched) and added a word-overlap test. It did **not** rewrite the
product model, add the missing surfaces, or generate shortcuts from
`kKeymapActions`.

The live app now has **96** remappable actions in
`lib/core/settings/keymap.dart`. The book lists **24** shortcut chips
across **12** topics in **4** categories. Several remaining sentences
still teach the wrong control or the wrong verb.

The decision to make is:

> How should in-app Help be brought into agreement with the current
> application, and what must be added, changed, or deleted so that
> Help cannot again silently drift from `kKeymapActions`, the menu
> bar, and the workspace the user actually sees?

This record is the **assessment and the rewrite decision**. Findings
were verified against source on 2026-08-15 (parent read of the book,
keymap, menus, settings, landing, workspace models, plus three
read-only explorations; parent re-checked every HIGH claim below).
Tests and a live `.app` were **not** re-run. No Help JSON was edited
in this cycle.

### Relationship to earlier records

* **Does not supersede 0009.** 0009 remains the UI/UX remediation
  backlog. H18 and the Phase 10 M27 chord audit stay closed. This
  record takes the *coverage and model* half of M27 that Phase 10
  explicitly left open (“shortcuts were not generated from
  `kKeymapActions`”; Getting Started was only patched).
* **Does not reopen 0005 / 0008 architecture.** Help must *describe*
  the shipped workspace and chrome. It must not invent the unused
  inspector slot (0009 L4), the 0006 native title bar (still
  `TitleBarStyle.hidden`), or palette `issue:` / `request:` / `ci:`
  results (parser stubs; hint already dropped, 0009 M7).
* **Does not replace** the live Keyboard Shortcuts sheet (⌘/) or
  Settings → Keyboard Mappings. Those remain the source of *current*
  bindings. Help teaches factory defaults plus workflows.

### Audit method

* Read `macos/Runner/help_book.json` end-to-end (4 categories, 12
  topics, every `shortcuts[]` row and body sentence that names a
  control or chord).
* Compared against `kKeymapActions`, `kMenuBarMenus`, Settings,
  Connections Manager / landing / reconnect overlay, workspace size
  classes and view options, and the six sidebar panels.
* Three parallel read-only explorations: workspace chrome and
  session; per-panel capabilities vs the six tab topics; keymap,
  palette, viewer, DnD, secondary windows, undo, clone/create, tool
  health, Help window itself.
* Parent verification of every HIGH claim against the cited file.

## Decision Drivers

* **Honesty.** A Help sentence that names a button, filter, or chord
  must invoke the same verb the app runs. Teaching checkout as a
  filter, amend as ⌘↩, or stash-as-optional-untracked is worse than
  silence.
* **Coverage of the shipped workspace.** After 0005/0008 the thing
  users live in is a context bar + adaptive panes + File/View menus,
  not six isolated “Main Application Tabs.”
* **Single source of truth for chords.** Factory-default shortcuts
  live in `kKeymapActions`. Help must not invent chords and must not
  silently miss a default-bound action.
* **Do not document unfinished seams.** Inspector pane, 0006 title
  bar, and empty palette scopes stay out of Help until they work.
* **Keep the native Help window.** Searchable topics, callouts, and
  a Help menu item are the right macOS shape. The Keyboard Shortcuts
  sheet is a cheat sheet, not a user guide.
* **Maintainability.** A rewrite that cannot be regression-tested
  will rot the same way v1.1 did.

## Considered Options

* **A. Patch only the remaining WRONG sentences** (continue the 0009
  M27 style: fix amend-via-⌘↩, stash untracked, Forge filters,
  Branches ⌘⇧Y, worktree-as-File-tab, drop-on-window, new-host key
  prompt).
* **B. Authored rewrite of the book to a current-product information
  architecture, with tests that bind Help chords and required topics
  to `kKeymapActions` / a topic contract** (this record’s catalog is
  the punch list). Factory defaults stay in JSON; Help discloses that
  remaps live under ⌘/ and Settings.
* **C. Generate the Help Book from code** (keymap labels, menu spec,
  Settings blurbs) at build time, with little or no authored prose.
* **D. Retire the Help Book** and point Help ▸ Support & Help at the
  Keyboard Shortcuts sheet plus Settings section copy.

## Decision Outcome

Chosen option: **"B. Authored rewrite plus contract tests"**, because
the gap is the *product model* (workspace, menus, File View,
Dashboard, clone/create, viewer, DnD, undo honesty), not a handful of
chords. Option A leaves the 0005/0008 workspace, the native
Repository/Branch/Stash/Forge/Worktree menus, and most of the 96
keymap actions undocumented. Option C can emit accurate shortcut
tables but cannot write workflows (“Stash Changes always includes
untracked; the message lives on Stash ▸ Stash with Message…”).
Option D throws away search, Getting Started, and every
non-shortcut capability.

* Implementation Plan: [0010-PLAN-in-app-help-book-rewrite.md](./0010-PLAN-in-app-help-book-rewrite.md)
  (Option B accepted 2026-08-15; the plan reuses the finding IDs
  below and does not invent new architecture).

### Locked product gates (for the companion plan)

| Gate | Locked choice |
| --- | --- |
| **G1** | Keep `help_book.json` + `HelpView` as the delivery mechanism. Do not move Help into Flutter. |
| **G2** | Teach **factory-default** chords. Disclose once that remaps are in Keyboard Shortcuts (⌘/) and Settings → Keyboard Mappings. Do not build a Swift↔Dart live-keymap channel in this rewrite. |
| **G3** | Every Help `shortcuts[]` chord that exists in `kKeymapActions` must name the same verb as that action’s `label` (stricter than today’s word-overlap test). |
| **G4** | Every **default-bound** `kKeymapActions` entry appears at least once in the book (shortcut chip or Commands topic row). Unbound-by-default actions may be taught as menu/palette-only, without inventing a chord. |
| **G5** | Do not document the inspector as a working pane, 0006’s native title bar, or palette `issue:` / `request:` / `ci:` results. |
| **G6** | Bump `help_book.json` `version` to **2.0**. Forbidden stale phrases (Confirmation) must fail CI. |
| **G7** | Native Help ⌘? stays Help. Flutter ⌘/ stays the shortcuts sheet. The book must distinguish them. |

## Consequences

* Good, because Help will describe the workspace, menus, and panels
  users actually have, instead of a 2026-early six-tab client.
* Good, because contract tests stop the H18 class of “Help teaches a
  different verb” regressions and stop silent omission of new default
  bindings.
* Good, because 0009 M27’s leftover (generate-from-keymap /
  rewrite Getting Started) gets a dedicated home instead of sitting
  as a half-closed MED item.
* Bad, because an authored rewrite is a writing project: every new
  default-bound keymap action will need a Help mention or the
  completeness test will fail.
* Bad, because Help will still show factory defaults after a user
  remaps — mitigated by the one-time disclosure and by ⌘/.
* Neutral, because the Help *window* (search, split view, legacy
  macOS 12 without search) is unchanged. Legacy still cannot search;
  that is a renderer limit, not a content defect.

## Pros and Cons of the Options

### Option B: Authored rewrite plus contract tests (chosen)

Rewrite `help_book.json` to the IA in “Proposed information
architecture,” using the finding tables as the punch list. Extend
`test/help_book_json_test.dart` (and keep Swift decode tests).

* Good, because prose can explain *why* (stash always
  `--include-untracked`; File View only at ≥ 1200 unless pinned).
* Good, because the existing Help window and search keep working.
* Good, because tests have a concrete contract (G3–G6).
* Bad, because it is a large writing pass, not a one-line fix.
* Neutral, because shortcuts stay static defaults (G2).

### Option A: Patch only WRONG sentences

* Good, because small and ships fast.
* Bad, because the book still has no workspace, menus, File View,
  Dashboard, clone/create, viewer, or DnD topics.
* Bad, because the next feature cycle will rot it again — there is
  still no completeness test.

### Option C: Generate Help from code

* Good, because chords cannot drift from `kKeymapActions`.
* Bad, because keymap labels are not user-guide prose and have no
  workflows, warnings, or callouts.
* Bad, because Settings blurbs and menu titles are incomplete
  coverage of Connections, Recovery, and File View.

### Option D: Retire the Help Book

* Good, because one less document to rot.
* Bad, because ⌘/ is a remappable-action list, not Getting Started,
  not “what the context bar is,” not clone/create, not host keys.
* Bad, because macOS users expect Help ▸ Support & Help to be a
  guide.

## Findings

Status key used below:

| Status | Meaning |
| --- | --- |
| **WRONG** | Help teaches a control, verb, or chord the app does not run. Fix or delete. Highest priority. |
| **STALE** | Once roughly true; names, placement, or details have moved. Rewrite. |
| **MISSING** | Shipped, user-visible, and undocumented. Add. |
| **OK** | Accurate enough to keep (may still move under the new IA). |
| **OUT** | Must **not** be documented as working (unfinished or intentionally inert). |

### Current book vs current app (inventory)

| Book (v1.1) | Live app |
| --- | --- |
| 4 categories: Getting Started, Main Application Tabs, Tier 1 Core Features, Diagnostics & Support | Sidebar of **six panels** inside a **0005 workspace** (navigator / canvas / task dock / activity), plus File tabs, View panes, native menus |
| 12 topics | 96 keymap actions; File / Repository / Branch / Stash / Forge / Worktree menus; Settings with 8 sections |
| 24 shortcut chips | ~40 default-bound chords plus unbound menu/palette verbs |
| “Main Application Tabs” | Sidebar pages (⌘1–⌘6). **File tabs** are multi-repo sessions (⌘T), a different object |
| Help window version not shown in the UI | Keyboard Shortcuts sheet (⌘/) is generated from the live keymap |

The Help *window* itself is fine: Help ▸ Support & Help opens
`HelpWindowController` (“Magic Git Support & Help”). Search covers
title, summary, keywords, shortcut labels/keys, and section text on
macOS 13+. macOS 12 legacy has no search. Book version 1.1 is not
shown in the detail pane. Loader fallback on decode failure is an
empty book labeled version 1.0 (`HelpDataModel.swift`).

### HIGH — Help currently lies

These are the sentences that will make a user do the wrong thing.
They are the first rewrite targets.

| ID | Topic | Help claim | Live fact | Evidence |
| --- | --- | --- | --- | --- |
| **H1** | `tab_repository` | “Toggle 'Amend last commit' or press ⌘↩ to rewrite HEAD.” | There is **no** amend checkbox. ⌘↩ is `commit.confirm` (a new commit). Working-tree amend is Repository ▸ Amend Last Commit… (`repository.amend`, unbound). History HEAD amend is `history.amend` (⌘⇧↩, History-scoped). | `help_book.json` Diff Inspection paragraph; `commit_composer.dart` (no amend field); `keymap.dart` `commit.confirm` / `repository.amend` / `history.amend`; `menu_bar_spec.dart` Amend Last Commit… |
| **H2** | `tab_stashes` | “Click 'Stash Changes' to specify a custom message and optionally include untracked files.” | **Stash Changes** (context-bar primary, ⇧⌘S, hamburger) is immediate `git stash push --include-untracked`. No prompt. Untracked is **not** optional (0008 unification). A message is **Stash ▸ Stash with Message…** (`stashes.stashWithMessage`, unbound). | `stash_view.dart` `_stashAll`; `help_book.json` Creating & Inspecting Stashes |
| **H3** | `tab_forge` | “Filter PRs/MRs by status (Open, Merged, Closed, Mine).” | Those filters are gone. Live: **Inbox \| Browse**; Inbox chips **All / PRs\|MRs / CI / Issues** (+ optional No blockers). Lists are open items plus a text filter. Closed work drops off the list. | `forge_inbox.dart`; `github_panel.dart` list construction |
| **H4** | `tab_branches` | Shortcut “Sync / Fetch Remotes” = ⌘⇧Y | ⌘⇧Y is `repository.sync` (**Sync**, Repository-scoped). Fetch is ⌘⇧F. Branches’ context-bar primary is **Fetch & Prune**, no default chord. Following Help on Branches runs nothing (or the wrong panel’s Sync). | `keymap.dart` `repository.sync` / `repository.fetch`; `branches_view.dart` primary action |
| **H5** | `tab_worktrees` | “Opening a worktree loads it as a tab in your multi-tab workspace.” | Deliberately **not** a File tab (`TabsController`, cap 8). Worktrees open a **nested strip** inside the Worktrees panel: Overview \| checkout tabs, each with Changes / History / Branches / Stashes. Forge is omitted on purpose. | `worktrees_view.dart` class comment L51–75; `_subPanels` |
| **H6** | `quickstart` | Drop the folder onto the window to open a local repo. | Landing has **no** folder drop target. Local open is Connections Manager ▸ Add existing repository (Finder panel) or Recents. | `connection_landing.dart`; no `DropTarget` under `lib/features/connection/` |
| **H7** | `feature_ssh` | New host **or** changed fingerprint shows a host-key prompt. | First contact is **silent TOFU** (known-hosts write). The modal is **Host Key Changed** only, with Cancel Connection / Refresh Key and Continue. | `app_shell.dart` Host Key Changed dialog; `ssh_client_manager.dart` TOFU comment |
| **H8** | `tab_repository` | “Toggle 'Amend last commit' or press ⌘↩” also implies a persistent bottom subject+description pane. | Commit is a collapsed **Commit…** bar; ⌘G expands the **task-dock** composer (one message field, Accept / Accept + Push). | `repo_status_view.dart` `_commitBar` + `taskDock:`; `commit_composer.dart` |
| **H9** | `feature_palette` | “Destructive actions (such as **staging** …) present an Undo Toast.” | Staging / unstaging is **not** an undo journal kind. Undo covers commit, amend, resets, checkout, branch/tag, stash drop/pop/clear, discard, remove files, and hard-reset-shaped merge/rebase/cherry-pick/revert. | `undo_types.dart`; Help Global Undo Engine paragraph |
| **H10** | `tab_branches` | “Use the context menu to Rebase active branch onto target branch.” | There is **no** Rebase context-menu item. Rebase is a **drop** onto the current branch (`DropOp.rebase`). | `branch_navigator.dart` `DropOp`; context menu inventory |

### MED — stale placement, names, or incomplete truth

Still usable as a starting paragraph, but they describe the old chrome.

| ID | Topic | Stale claim | Live fact |
| --- | --- | --- | --- |
| **M1** | Category `tabs` | “Main Application Tabs” | Six **sidebar panels**. File ▸ New Tab / Close Tab are **repository sessions**. |
| **M2** | `tab_repository` | “Staged Changes and Unstaged Changes lists” | Sections are **Conflicts / Staged / Changes / Untracked**, plus filter chips, hide-reviewed, group-by status/directory. |
| **M3** | `tab_repository` | Line staging = “Drag to select specific diff lines in the right pane” (implied done) | Unified, whitespace-exact, blame-off diffs only; then **Stage / Unstage / Discard Selection**. Split and ignore-whitespace are read-only. Per-hunk buttons exist. Hunk nav ⌥↑/↓ and ⌘⇧K are **not** in `kKeymapActions`. |
| **M4** | `tab_repository` | ⌘⇧⌫ “Discard Unstaged Changes” | Action is discard **selected file(s)** (`repository.discard`). Staged discard is context-menu only. |
| **M5** | `tab_history` | “All Branches button in the History toolbar” | Icon in the **filter bar** (tooltip “Show all branches”). Context-bar primary is Refresh. 0009 H18 body text about ⌘⇧B is already correct — keep it. |
| **M6** | `tab_history` | Action list: Checkout, Create Branch, Create Tag, Cherry-pick, Revert | Also: Branch from… in a new worktree, Interactive rebase, Reset soft/mixed/hard, Amend (HEAD), multi-select cherry-pick/revert, copy N SHAs. Create Branch is **Branch from…** (⌘⇧N), not ⌘⇧B. |
| **M7** | `tab_branches` | “⌘B to create a new branch from current HEAD” | Opens the **New branch** sheet (name + start-at, default selected ref or HEAD), then Here vs new worktree. Keymap label is “Focus new branch field.” |
| **M8** | `tab_worktrees` | “Automatically creates a security-scoped bookmark” | Local only. SSH has no sandbox bookmark. Terminal-created worktrees prompt once on first open. |
| **M9** | `quickstart` | Recents + Connections Manager + PEM-only SSH | Recents label is **Recent Repositories**. SSH also supports **password** and tokens, optional scoped git-dir. After Stop Retrying the landing is **Connection lost** (Reconnect / Start Fresh), not the card. Overlay title is **Connection interrupted**. |
| **M10** | `feature_palette` | “search commands, branch names, worktrees, or **settings**” | Settings is the **Open Settings** command, not a settings-key search. Live prefixes: `go:`, `git:`, `forge:`, `app:`, `branch:`, `commit:`, `file:`, `stash:`, `worktree:`. `file:` is changed paths only. |
| **M11** | `tool_health` | Checks **on startup**; missing from **PATH**; banner with install guidance | Runs on a **live connection**. Banner + Settings ▸ External tools ▸ Scan. Doctor distinguishes essential vs feature vs outdated; one-click install when safe; sideload drop zone. |
| **M12** | `output_log` | Output Log & Recovery as one topic | Accurate chords (⇧⌘O / ⇧⌘U). Recovery is a **sheet** (reflog + `refs/magic-git/snapshots/`), not a “view” in the Output sense. Output is a docked command log, visible by default. |
| **M13** | `overview` | “tabbed multi-repository workspace” only | True but incomplete: no File tab how-to, no saved workspaces, no session-exit guard, no dirty/conflict dots. |
| **M14** | `feature_ssh` | Custom executor, passphrase, custom ports | Still true. Missing: local backend is first-class and uses the same UI; reconnect Cancel confirms when the session is at risk (0009 M5). |

### MISSING — shipped surfaces with no Help topic

Grouped by the proposed IA. These are add-topics, not one-line patches.

#### Workspace and chrome (0005 / 0008)

| ID | Surface | What Help must teach | Evidence |
| --- | --- | --- | --- |
| **W1** | Size classes | Compact **&lt; 720**, standard 720–1199, wide **≥ 1200**. Compact: navigator XOR canvas; sync group collapses to overflow; sidebar toggle on the bar. Sidebar itself hides at 760. | `repository_workspace_models.dart` `WorkspaceSizeClass`; `repository_context_bar.dart`; `app_shell.dart` |
| **W2** | Context bar | Identity (name, branch, watch-health dot), status summary, SSH link chips, Back / Forward, **Fetch · Pull · Push · Sync** (one emphasized + overflow variants), Stash, Refresh, Activity, view options. Compact **⋯** “Repository details.” Primary action is always visible. | `repository_context_bar.dart`; `repository_workspace_prefs.dart` `WorkspaceToolbarSlot` |
| **W3** | View options / presets | Show secondary labels; show/hide each toolbar slot; presets **Review / Commit / Investigate / Minimal**. Default: all slots on, labels off, Review. | `workspace_view_options.dart` |
| **W4** | File View | View ▸ Show File View / ⇧⌘E. Docked third pane, **on by default but invisible until width ≥ 1200 unless pinned**. Pin / hide / collapse all. Not a Changes\|Files switch (that switch is gone). | `file_view.dart`; `repo_status_view.dart` width gate |
| **W5** | Dashboard | View ▸ Show Dashboard / ⇧⌘D. Session telemetry (connection, latency, heatmap last 200 commits, watcher/tools/forge, object-store). Not the Forge tab. | `dashboard_sheet.dart`; `keymap.dart` `global.toggleDashboard` |
| **W6** | Activity | Context-bar bell/spinner → live Activity sheet (running / failed ops, reveal in Output, undo newest). | `activity_center.dart` |
| **W7** | Appearance | Settings ▸ Density Compact/Comfortable (default Comfortable), High contrast, Reduce Motion follows macOS. Dark-only. | `settings_sheet.dart` Workspace appearance |
| **W8** | Native menus | File (New Tab ⌘T, Close Tab unbound), Repository, Branch, Stash, Forge, Worktree, plus App Settings…, View toggles, Help. Unavailable items dim in place (HIG). Cross-panel verbs switch to the owning panel. | `menu_bar_spec.dart`; 0009 H1 |
| **W9** | Pane focus | View menu Focus Navigator / Canvas / Inspector / Task Dock / Activity — **all unbound**. Inspector focus is **OUT** (no screen passes `inspector:`). Do not invent chords. | `keymap.dart` `global.focus*` |

#### Session, landing, Settings

| ID | Surface | What Help must teach |
| --- | --- | --- |
| **S1** | File tabs | ⌘T new; Close Tab via File menu (⌘W is viewer-owned); cap 8; strip hidden with one tab; orange dirty / red conflict dots; middle-click close. |
| **S2** | Saved workspaces | Connections toolbar + palette **Manage Saved Workspaces**; save / open / delete / tab alias. |
| **S3** | Session exit | Close tab / Log out / Disconnect / Quit / Close window confirm when dirty or a merge/rebase/cherry-pick/revert is in progress. |
| **S4** | Clone / Create | Two wizards from Connections / palette. Clone: destination → source (GH/GL or URL) → location → review. Create: destination → empty vs existing → remote (GH/GL / URL / none) → details → review. Failed clone deletes the partial folder. |
| **S5** | Settings contents | Timeouts (network 3 min / commit 5 min, floor 5s); committer identity; always `--no-gpg-sign`; Pull/Sync mode (default fast-forward only); push tags; auto-fetch (default every 5 min); appearance; Known Hosts (Forget saves immediately); Keyboard Mappings (saves immediately); External tools. |
| **S6** | Help vs Shortcuts | ⌘? = this book. ⌘/ = live cheat sheet. Settings → Customize = remapper. |

#### Per-panel capabilities the six topics omit

| ID | Panel | Missing capabilities |
| --- | --- | --- |
| **P1** | Repository | Hide reviewed / Review selected / Review all visible; multi-file review; conflict Continue / Abort / Ours / Theirs / Mark Resolved; ignore whitespace ⌥⌘W; expand context ⌥⌘X; blame gutter + Blame sheet; in-canvas diff pop-out; image diffs; drag-to-stage banner; commit assistance (recent subjects, template, policy advisory); Accept + Push ⌘⇧↩; menu-only pull rebase/merge, push + upstream, push tags, force-with-lease ⌃⌘U, force no-lease, Unstage All, abort pending. |
| **P2** | History | Filter grammar `author:` / `file:` / `sha:` / `after:` / `before:`; Hide merges; zoom ⌘= / ⌘− / ⌘0 + pinch / ⌘-scroll; interactive rebase ⌘⇧R; cherry-pick ⌥⌘C; branch-from ⌘⇧N; two-commit compare; minimap; drop branch onto a commit (merge/rebase/move). |
| **P3** | Branches | Browse \| Review; pin / hide / folder grouping; tags ⌘⇧T; publish; Create PR/MR; Open CI; Compare with Base; bulk pin/hide/delete-if-merged; checkout in new worktree; empty-selection dashboard stats. |
| **P4** | Stashes | Filter; Pop ⌥⌘P; Drop ⌘⌫; apply/pop `--index`; Create branch from stash; Apply/Pop latest; Clear all (Recovery-aware). |
| **P5** | Forge | New PR/MR ⌘N; New Issue (menu); Approve ⌥⌘A; Merge ⌘⇧M; retry/re-run ⌥⌘R; Cancel auto-merge; merge-readiness strip; Update branch / Rebase onto target; comments; close/draft; Inbox pin/snooze; Browse sections (Issues, Labels, Milestones, Releases, Workflows/Pipelines). |
| **P6** | Worktrees | Full verb set (menu/palette, all unbound): add, open, lock/unlock, move, repair, repair all, prune, remove (+ optional delete branch). Add sheet: new/existing/detached, copy ignored files, post-create command. Nested workspace; Forge omitted. |

#### Files, windows, DnD, undo

| ID | Surface | What Help must teach |
| --- | --- | --- |
| **F1** | File viewer windows | Floating viewers: Code vs Preview; wrap ⌥Z; find ⌘F; copy contents ⇧⌘C; close ⌘W / Escape. Markdown preview links open in the browser. |
| **F2** | Remote edit | Open in Default App copies to a temp file, watches the parent directory, uploads on save, conflict overwrite. Local repos use `openFiles`. |
| **F3** | Blame / file history | Blame sheet and inline gutter (off by default). File history (`--follow`) from the **file tree**, not the Changes list. |
| **F4** | Image / LFS | Before/after image diffs. LFS pointers are named as pointers (`git lfs pull`), not “binary image.” |
| **F5** | File tree extras | View file, Open, Mark Resolved, staged/unstaged halves, Add to .gitignore, Delete (undoable, discard copy). |
| **F6** | Secondary windows | Native History window (⇧⌘H, singleton). Detached repo window (full status). In-window diff pop-out (not a native window). Menu key-equivalents suppressed while a pop-out is key (0009 H16). |
| **F7** | Drag and drop | Staging banner; files → Stashes (path-scoped stash); commit → Repository (cherry-pick); local branch → Forge (create PR/MR); commit/branch → Worktrees (add sheet); History/Branches in-panel merge/rebase/move. Esc cancels. |
| **F8** | Undo / Redo | ⌘Z undoes the last **git** operation (toast, 5s, hover pause). ⌘⇧Z redo is **narrow** (atomic tag create/delete). Edit ▸ Undo is still text undo. Staging is not undoable (see H9). |

### OUT — do not teach as working

| ID | Surface | Why |
| --- | --- | --- |
| **X1** | Inspector pane | Prefs + Investigate preset exist; no screen passes `inspector:`. `global.focusInspector` is inert by design (0009 L4 / 0008). |
| **X2** | 0006 native title bar | Still `TitleBarStyle.hidden` (`lib/main.dart`). |
| **X3** | Palette `issue:` / `request:` / `ci:` | Parser accepts them; results stay empty (0009 M7). Hint already stopped advertising them. |
| **X4** | Folder-drop on the landing window | Not implemented (H6). Do not re-promise it. |
| **X5** | New-host SSH confirmation prompt | Silent TOFU (H7). Teach Known Hosts + Host Key Changed only. |

### Shortcut contract (today vs required)

Help `shortcuts[]` vs `kKeymapActions` defaults today:

| Help label | Keys | Verdict |
| --- | --- | --- |
| Global Command Palette | ⌘K | OK (`global.commandPalette`) |
| Refresh Repository State | ⌘R | OK chord; prefer keymap label “Refresh” |
| Preferences & Settings | ⌘, | OK (`global.openSettings`); UI title is **Settings** |
| Stage / Unstage Selected File | Space | OK |
| Stage All Changes | ⌘⇧A | OK |
| Discard Unstaged Changes | ⌘⇧⌫ | Chord OK; **label wrong** (M4) |
| Toggle Side-by-Side Diff | ⌥⌘S | OK |
| Confirm & Commit | ⌘↩ | OK as confirm; body text H1 still lies |
| Checkout Selected Commit | ⌘⇧B | OK (H18) |
| Open History in New Window | ⌘⇧H | OK |
| Copy Commit SHA | ⌘C | OK |
| Filter History Log | ⌘F | OK |
| Create New Branch | ⌘B | Chord OK; **label overstates** (M7) |
| Merge Selected Branch | ⌘⇧M | OK on Branches (also GH/GL merge in other scopes) |
| Delete Selected Branch | ⌘⌫ | OK |
| Sync / Fetch Remotes | ⌘⇧Y | **WRONG** (H4) |
| Stash Working Changes | ⌘⇧S | OK |
| Apply Selected Stash | ⌥⌘A | OK |
| Switch to Forge / Worktrees | ⌘5 / ⌘6 | OK |
| Keyboard Shortcuts Sheet | ⌘/ | OK — must stay distinct from Help ⌘? |
| Undo Last Action | ⌘Z | Chord OK; say **Undo Git Operation** (H9) |
| Toggle Output / Recovery | ⇧⌘O / ⇧⌘U | OK |

**Default-bound actions with no Help chip** (G4 gap): ⌘⇧Z redo, ⌘T new tab, ⇧⌘E File View, ⇧⌘D Dashboard, ⇧⌘F/P/L fetch/push/pull, ⌃⌘U force-with-lease, ⌥⌘W/X whitespace/context, ⌘G composer, ⌘⇧↩ commit+push, ⌘⇧T tag, ⌥⌘C cherry-pick, ⌘⇧N branch-from, ⌘⇧R interactive rebase, history zoom trio, ⌥⌘P stash pop, ⌘N new PR/MR, ⌥⌘R retry/rerun, viewer ⌘W / ⇧⌘C / ⌥Z / ⌘F.

The current test (`test/help_book_json_test.dart`) only requires
word-overlap with *some* owner of the chord. That is why “Sync /
Fetch Remotes” on ⌘⇧Y still passes (`sync` ∩ `Sync (pull, then
push)`). G3 replaces that with verb agreement against the owning
action’s label.

## Proposed information architecture

Replace the four v1.1 categories with six. Topic ids are the
contract the companion plan and `help_book_json_test.dart` should
assert (G6). Keep existing ids where the topic is rewritten in
place so bookmarks/search stay stable.

| Category | Topics (id) | Notes |
| --- | --- | --- |
| **Getting Started** | `overview` (rewrite), `quickstart` (rewrite), `clone_create` (**new**), `tabs_workspaces` (**new**) | Landing, Connections, Recents, local vs SSH, TOFU vs Host Key Changed, reconnect overlay, File tabs, saved workspaces, session exit. |
| **The Workspace** | `workspace_chrome` (**new**), `file_view_and_output` (**new**), `dashboard_recovery_activity` (**new**), `settings` (**new**) | Context bar, size classes, view options, File View, Output, Dashboard, Recovery, Activity, Settings sections, Help vs ⌘/. |
| **Panels** | `tab_repository`, `tab_history`, `tab_branches`, `tab_stashes`, `tab_forge`, `tab_worktrees` (all rewritten) | Keep ids. Stop calling them “tabs.” Each topic lists its context-bar primary, default chords, and menu-only verbs. |
| **Files, Diffs & Windows** | `viewer_and_remote_edit` (**new**), `diffs_blame_history` (**new**), `drag_and_drop` (**new**), `secondary_windows` (**new**) | Viewer, blame, file history, image/LFS, pop-outs. |
| **Commands & Shortcuts** | `feature_palette` (rewrite), `menus_and_keymap` (**new**) | Prefixes, entity scopes, native menus, remapping, G3/G4 table. |
| **Safety & Diagnostics** | `feature_ssh` (rewrite), `undo_recovery` (**new**, split from palette), `tool_health` (rewrite), `output_log` (keep, trim Recovery into the workspace topic) | Honest undo; tool doctor; no startup-PATH myth. |

Suggested first-open topic remains `overview`.

### Voice and scope rules for authors

* Name controls as they appear in the UI (“Stash Changes”, “Host Key
  Changed”, “Inbox”, “Fetch & Prune”).
* When a verb has two entry points, say which one prompts and which
  one does not (Stash Changes vs Stash with Message…).
* Do not document OUT rows (X1–X5).
* Prefer one callout for “Help shows factory defaults; remaps are
  under ⌘/” rather than repeating it in every topic.
* Do not invent chords for unbound actions. Say “Repository menu” or
  “command palette.”
* Destructive git facts stay explicit: stash always includes
  untracked; commits are unsigned (`--no-gpg-sign`); force push with
  lease vs force push.

## Confirmation

The rewrite is done when all of the following hold:

1. **H1–H10** sentences are gone from `help_book.json` (string
   search in `test/help_book_json_test.dart` for the forbidden
   phrases: `rewrite HEAD`, `optionally include untracked`,
   `Open, Merged, Closed, Mine`, `Sync / Fetch Remotes`,
   `multi-tab workspace` in the worktrees topic, `drop the folder`,
   `new remote host or if a server's fingerprint`).
2. **G3** — every Help `shortcuts[]` chord that matches a
   `kKeymapActions` default agrees with that action’s `label` verb
   (not mere word-overlap with *any* owner).
3. **G4** — every default-bound keymap action appears in the book.
4. Required topic ids from the IA table exist, have non-empty
   sections, and the `tabs` category title no longer says “Main
   Application Tabs.”
5. Book `version` is `2.0`. `HelpDataModelTests` still decodes the
   bundle. `test/help_book_json_test.dart` stays green.
6. No new topic documents X1–X5 as working.
7. A maintainer opens Help ▸ Support & Help on a Mac and can
   complete: connect (local + SSH), find File View / Dashboard /
   Settings, stash with and without a message, amend without using
   ⌘↩, open a worktree *inside* Worktrees (not as a File tab).

## More Information

* Book and renderer: `macos/Runner/help_book.json`,
  `HelpDataModel.swift`, `HelpView.swift`, `HelpWindowController.swift`,
  `MainFlutterWindow.swift` `installHelpMenuItems`.
* Tests: `test/help_book_json_test.dart` (structural + H18 + M27
  word-overlap); `macos/RunnerTests/HelpDataModelTests.swift`.
* Sources of truth for the rewrite: `lib/core/settings/keymap.dart`,
  `lib/features/common/menu_bar_spec.dart`,
  `lib/features/settings/settings_sheet.dart`,
  `lib/features/common/repository_workspace_models.dart`,
  `lib/features/common/repository_context_bar.dart`.
* Prior Help work: 0009 H18, 0009 M27 / Phase 10 (v1.1 chord audit).
* Workspace/chrome the book must now describe: 0005, 0008.
* Help book introduced in `e61ac61`; macOS 12 fallback in `39e93ff`;
  last content pass was 0009 Phase 10 (v1.1).
