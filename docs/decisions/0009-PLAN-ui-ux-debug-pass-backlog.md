---
status: "executed"
date: 2026-08-15
verified: 2026-08-20
---
# Implement the 2026-08-15 UI/UX debug-pass backlog

Associated MADR: [0009-MADR-ui-ux-debug-pass-backlog.md](0009-MADR-ui-ux-debug-pass-backlog.md)

- Status: **executed.** 45+ distinct backlog ids (H1–H20, M1–M34, L1–L18) are cited by `lib/` source comments as the reason for the code that implements them.

  *Status corrected 2026-08-20:* this line read "proposed, for review. No production code written," which was false against the tree. The original wording, and the residuals it lists, follow. Anything still open is a residual of an executed plan, not an unstarted one. Superseded text:

  > No production code written by this
  document. Citations re-verified against `master` `c79977c` on 2026-08-15
  by a six-agent pass; corrections are folded into the text below.
- Date: 2026-08-15
- MADR decision: Option B — treat the 2026-08-15 pass as the current
  prioritized remediation backlog
- Owner: implementation agent + maintainer review
- Delivery model: incremental, analyzer-clean phases; maintainer creates
  commits (`git commit --no-edit` only; no agent-written commit messages)
- Sequencing rules:
  1. This plan is the executable authority for delivery order.
  2. Work starts at **Phase 0**. Do not start Phase 10+ (capacity MED/LOW)
     while any HIGH in Phases 0–8 is open.
  3. Unit tests land **in the same work slice** as production code for each
     phase’s Required tests table.
  4. Do **not** run `live-forge` tests unless the maintainer explicitly asks.
  5. Rationale stays in the MADR; this plan owns steps, files, tests, and
     exit criteria. A conflict requires an explicit MADR amendment or a plan
     correction — the plan does not silently supersede the MADR.
  6. Finding IDs (`H1`…`H20`, `M1`…`M34`, `L1`…`L22`) are stable
     cross-references to the MADR’s More Information section.
- SDK / quality bar: match repo strict analyzer (`strict-casts` /
  `strict-inference` / `strict-raw-types`, `prefer_final_locals`,
  `prefer_const_constructors`, `unawaited_futures`, `avoid_dynamic_calls`);
  `flutter analyze` + ordinary `flutter test` green before staging.
  Never write commit message text.

This plan turns MADR 0009 into an executable sequence grounded in the tree
on 2026-08-15 (`master` at `c79977c`, clean working tree) plus the seams
already designed by 0004 / 0005 / 0008.

---

## Assessment of MADR 0009

Every HIGH citation was re-read against source before this plan was written.

**Confirmed (do not re-litigate).**

* H1 — `PanelShortcuts._schedulePublish` publishes only the active panel’s
  non-null handlers (`panel_shortcuts.dart:79-82`). Swift
  `validateMenuItem` enables iff `enabledActionIds.contains` (`MainFlutterWindow.swift:514-521`). Dispatch *would* switch panels
  (`app_shell.dart:804-809`).
* H2 — worktree checkout tab returns a `Column` at
  `worktrees_view.dart:610-655` *before* `PanelShortcuts` at `:722`.
* H3 — `applyWorkspaceLocation` / `takePendingForPanel` have no production
  callers. `visit()` does **not** set `pending`; only `_restore` does
  (`workspace_navigation.dart:58-96`). Palette `_openPaletteEntity`
  (`app_shell.dart:282-328`) visits then selects the page.
* H4 — navigator `canPublish` / `canCreateRequest` require `!local.isHead`
  (`branch_navigator.dart:774-787`); detail does not
  (`branch_detail.dart:608-645`).
* H5 — tree `onOpenFile` has no unmerged flag (`file_view.dart:198-209`);
  `_openFileFromTree` maps to unstaged (`repo_status_view.dart:1811-1824`).
* H6 — conflict menu is Ours/Theirs only (`repo_status_view.dart:2556-2572`).
  `GitService.stage` is already `git add -- :(literal)` (`git_service.dart:3088-3089`) and is the mark-resolved primitive.
* H7 — production `filterRepoChangeRows` is called without `reviewedPaths`
  (`repo_status_view.dart:2284`). Filter logic itself is correct
  (`repo_change_filter.dart:82-84`).
* H8 — `commit.confirm` / `commit.confirmAndPush` are bound only in
  `commit_dialog.dart`. Live UI is `CommitComposer`. `kPanelActionOwner`
  excludes `commit.*` by design (`panel_actions.dart:22-24`).
* H9 — `multi_file_review.dart:98-107` loads `fileDiffProvider`;
  `RepoChangeSection.conflict` bulk actions are `[]` (`:213`).
* H10 — `mergePlanForGitHub` leaves list-tier `unknown` unblocked
  (`merge_plan.dart:183-194`); `canMergeNow = reasons.isEmpty && !autoAlready`
  (`:351`). Strip shows “Checking…” only when `detailLoading &&
  plan.blockedReasons.isEmpty && !plan.canMergeNow`
  (`merge_readiness.dart:25`).
  `test/merge_plan_test.dart:57-59` **asserts** list-tier `canMergeNow == true`.
* H11 — `_approve` invalidates the list only (`github_panel.dart:1010-1012`).
  Merge paths already invalidate detail (`:1042-1043`).
* H12 — unseeded base is the literal `'main'`
  (`create_pr_form.dart:78-80`; `create_mr_form.dart:84-86`).
  `GhRepoMergePolicy.defaultBranch` already exists (`merge_plan.dart:76-94`).
* H13 — detail looks up `dashboard.value?.releases` only
  (`project_sections.dart:455-464`).
* H14 — secondary `_body` is History or `RepoStatusView` only
  (`secondary_window_main.dart:984-995`). Sole `ViewerHost` is in
  `AppShell`.
* H15 — `openRemoteFile` has no try/catch
  (`remote_edit_service.dart:93-147`); sync path already notices.
* H16 — menu channel is process-wide on `MainFlutterWindow`.
* H17 — branch-row `onAcceptWithDetails` has no `dragStateProvider` null
  guard (`branch_navigator.dart:1496-1508`); History/DropZone/staging
  banner do.
* H18 — Help `⌘⇧B` = All Branches (`help_book.json:134-150`); keymap
  `history.checkout` = ⇧⌘B (`keymap.dart:508-514`).
* H19 — `registerAndActivateLocal` returns `void` and early-returns on
  failed connect (`workspace_registration.dart:18-28`); clone still
  sets `_finished = true` (`clone_sheet.dart:369-379`).
* H20 — Create Escape registry always calls `_requestClose`
  (`create_repo_sheet.dart:263-266`).

**Corrected (narrower than the MADR wording).**

* H10 must be fixed in **the strip / button gate**, not by flipping
  `mergePlanForGitHub` list-tier `canMergeNow`. That value is an intentional
  “do not hard-block a list row” contract, covered by
  `test/merge_plan_test.dart:57-59`. Using it as “Ready to merge” is the
  UI bug.
* H3 palette path: `onOpenEntity` already visits with the entity identity.
  `dispatchEntity` is not required if `reveal()` sets `pending` after
  `visit`. Do not change `visit()` itself to always set `pending` —
  `_selectPage` visits `identity: 'panel:$index'`, which adapters must
  ignore.
* H6 is not a missing git primitive. `_stage` / `git.stage` already mark
  a conflict resolved. The gap is the missing menu/toolbar entry on the
  conflict section.

**Resolved (the MADR left A/B choices).**

| Gate | Locked choice | Why |
| --- | --- | --- |
| **G-H1** | Publish a **cross-panel reachable** id set when connected; keep **selection-gated** ids owned by the active panel | Matches the MADR fix text and Apple HIG already quoted in `menu_bar_spec.dart:3-7` / `MainFlutterWindow.swift:511-513`. Does not mount all six IndexedStack children. |
| **G-H8** | Bind `commit.*` on the expanded `CommitComposer`. Keep `CommitDialog` as a test/sheet artifact | The keymap and Keyboard Mappings already advertise the chords. Deleting the ids would shrink discoverability. |
| **G-H14** | Mount `ViewerHost` in the secondary shell | Detached Status already exposes “View file”. Hub-opening a viewer in the main window would surprise the user who popped the status out. |
| **G-H16** | When a secondary window is key, **suppress native key equivalents** on View + dynamic repo menus. Menu *clicks* still target the main session | AppKit menus are process-wide. Retargeting Fetch at a detached Status repo needs a windowId bus 0008 did not build. Key-equivalent theft is the user-visible bug. |
| **G-H18** | Fix Help to match `kKeymapActions`. Do **not** rebind ⇧⌘B | Checkout already owns that chord. Teaching All Branches as a toolbar-only control is honest. Full Help rewrite is M27. |
| **G-M4** | Add File ▸ New Tab / Close Tab. Leave Edit ▸ Undo as text undo | First-responder `undo:` is correct macOS while a field is focused. Git undo stays ⌘Z via Flutter. |
| **G-M7** | Remove `issue:` / `request:` / `ci:` from the palette hint this cycle | Implementing those scopes is product work; an advertised no-op is the bug. |
| **G-M8** | Do **not** delete Stash/Worktrees hamburgers here | Unique operands live there (Apply latest, Repair all). Band deletion stays on 0008. |
| **G-M21** | Feed `userCanMerge == false` into `mergePlanForGitLab`. Stop offering Admin merge unless a real permission bit exists | `supportsAdminBypass: true` always is a lie. Do not invent admin detection. |
| **G-M22** | Create APIs must return the new number/iid when the CLI already prints it; select it. If parsing is unreliable, select by title after list refresh | Do not add a new forge round-trip. |
| **L3 / L4 / L6 / L11–L15 / L22** | Out of this plan | 0006 title bar, inspector population, History menu, GH live logs, viewer L7, `executeStream` proxy. |

**Weaknesses carried forward rather than hidden.**

1. Cross-panel menu enablement (H1) will enable `repository.stageAll` even
   on a clean tree. After dispatch, `consume` hits a null handler and
   no-ops. That is better than a permanently dimmed Fetch. A later
   session-status publisher can tighten it.
2. H16 does not make Repository ▸ Fetch operate on the *detached* repo.
   Clicks still mutate the main tab. Document that in the detached window
   chrome if testers trip on it.
3. H3 adapters cannot restore a location whose provider has not landed
   yet. They must retry on the next data frame (watch the same provider
   they select from) or `markUnavailable`.
4. Help Book is a hand-authored JSON file loaded by Swift
   (`HelpDataModel.swift`). Generating every chord from Dart is M27;
   Phase 0 only removes the dangerous contradiction.

---

## Goal

1. **Eliminate active UI correctness bugs** listed as HIGH in 0009 —
   silent no-ops, wrong-object actions, false success, destructive Help.
2. **Finish declared seams** rather than adding buttons — menu
   enablement, `WorkspaceLocationAdapter`, reviewed-path filter, worktree
   `PanelShortcuts`, commit chords on the live composer, conflict
   mark-resolved via existing `git.stage`.
3. **Make shipped chrome honest** — Ready-to-merge, Help chords, Forge
   `branchLabel`, Activity Center actions, quit/close guards.
4. **Do not reopen 0004 HIGH**, do not implement 0006, do not finish
   leftover 0008 geometry.

---

## Scope

### In scope (this plan)

| Phase | Finding IDs | Outcome |
| --- | --- | --- |
| 0 | H17, H18, H7, H4 | Destructive one-liners + Help contradiction |
| 1 | H2, M31 | Worktree tab keeps handlers; overview selection visible |
| 2 | H1 | Cross-panel menus actually chooseable |
| 3 | H5, H6, H9, L7, M15 | Conflict pane, mark-resolved, review, copy |
| 4 | H8, M12, L8 | Live composer chords; multi-select Space/Discard; Stage All gated |
| 5 | H10–H13, M6, M19, M22 | Forge honesty |
| 6 | H3, M7, M9 | Location restore + palette entities |
| 7 | H14, H15, H16, M24, M25, M26 | Secondary windows + remote-edit open |
| 8 | H19, H20, M29, M30 | Clone/Create success + mid-flight Escape |
| 9 | M5, L1 | Quit / window-close / reconnect Cancel dirty guard; redo toast |
| 10 | M1–M4, M27, M28 | Palette/menu/Help/settings discoverability |
| 11 | remaining MED in the tables below | Only after HIGH is closed |
| 12 | listed LOW only | Adjacent or cheap; never a gate |

### Explicit non-goals (unless 0009 is amended)

* 0006 hybrid title bar (`TitleBarStyle.hidden` stays).
* 0008 leftover geometry (sync group on every screen, deleting hamburgers,
  native `NSToolbar`, History menu = L6).
* Inspector population (L4) and Investigate-preset content.
* Inline code-review threads (0002).
* GitHub live job logs (L12 / 0004 M10).
* Network-enabled markdown images (0004 M11). M34 is a caption or
  “open in browser”, not image fetch.
* Native `WindowKind.diff` (L14).
* Submodule management UI (0004 L4).
* Viewer engine residuals in `viewer_engine_findings.md` (L13).
* Proxying `executeStream` (L22).
* `live-forge` mutating tests.
* Rewriting `ACTION_PLAN.md` history.

### Standing constraints (`AGENTS.md`)

* `flutter analyze` + `flutter test` green before `git add`.
* Never run `live-forge` unprompted.
* `grep -a` / `rg -a` for `lib/core/providers/app_providers.dart`.
* Exclude `.flutter-sdk/`, `build/`, `.dart_tool/` from searches.
* Do not commit `macos/Runner/Release.entitlements` with sandbox keys
  stripped.
* Do not commit or push unless asked. No agent-authored commit messages.

---

## Current architecture (grounding map)

```text
Menu / palette / keys
  kKeymapActions            lib/core/settings/keymap.dart
  kPanelActionOwner         lib/features/common/panel_actions.dart
  kMenuBarMenus             lib/features/common/menu_bar_spec.dart
  AvailableActions          lib/features/common/menu_bar_bridge.dart
                            (one panel owner + shell ids)
  PanelShortcuts            publishes non-null handlers of the ACTIVE panel
  AppShell.listen(menuActionRequestProvider)
                            switch panel → PaletteIntent → same handler
  MainFlutterWindow.validateMenuItem
                            enabled iff id ∈ enabledActionIds
  IndexedStack              unvisited pages are SizedBox.shrink

Navigation
  WorkspaceNavigationHistory.visit     records, does NOT set pending
  WorkspaceNavigationHistory._restore  back/forward, SETS pending
  takePendingForPanel                  production callers: none
  WorkspaceLocationAdapter             designed in 0005, unused

Selection / review
  repoFileSelectionProvider            shared Changes + FileView (M13 done)
  RepoChangeFileRow.identity           "$section:$path"
  filterRepoChangeRows(..., reviewedPaths: {})   H7 hole
  GitService.stage                     git add = mark resolved

Forge
  mergePlanForGitHub                   list-tier unknown ≠ blocked
  MergeReadinessStrip                  treats canMergeNow as Ready
  pullRequestDetailProvider            not invalidated by approve/draft/edit
  create_pr_form / create_mr_form      base default 'main'

Secondary
  WindowKind.history | detachedRepo    no viewer kind
  ViewerHost                           AppShell only
  ProxyCommandExecutor.uploadBytes     already proxied (0004 H5)
  openRemoteFile                       no try/catch (H15)

Help
  macos/Runner/help_book.json          Swift HelpDataLoader
  test/help_book_json_test.dart        structural only; no keymap check
```

Apple HIG already adopted in-tree (do not re-argue):

* “Make every toolbar item available as a command in the menu bar.”
  (`menu_bar_spec.dart:3-4`)
* “If all of a menu’s items are unavailable, the menu itself needs to
  remain available so people can open it and learn about the commands it
  contains.” (`menu_bar_spec.dart:5-7`, `MainFlutterWindow.swift:511-513`)

Git facts this plan relies on (do not re-derive):

* `git add <path>` marks a conflict resolved. Already `GitService.stage`.
* During rebase, `ours` is the upstream onto which you are rebasing and
  `theirs` is the commit being replayed (`git-rebase(1)`). M15 relabels
  only; it does not swap the flags.
* Many GUI editors save via temp + rename. A `FileSystemEvent.modify`-only
  watch misses that (M24).

---

## Product gates — locked for review

Maintainer can reject a row before Phase 0. After acceptance these are
not optional inside their phase.

| Gate | Phase | Locked choice | Implementation summary |
| --- | --- | --- | --- |
| **G-H1** | 2 | Cross-panel reachable set | `kCrossPanelMenuActionIds` + `AvailableActions.publishSession` |
| **G-H8** | 4 | Bind composer | `CommitComposer` CallbackShortcuts for `commit.confirm*` |
| **G-H14** | 7 | ViewerHost in secondary | Stack `ViewerHost` in `secondary_window_main.dart` |
| **G-H16** | 7 | Suppress key equivalents when secondary is key | Swift `NSWindow` key-window observers (new — `magicgit/windows` has no focus signal) |
| **G-H18** | 0 | Help matches keymap | Delete false ⇧⌘B; do not steal checkout |
| **G-M4** | 10 | File menu tabs only | `global.newTab` / `global.closeTab` in `kMenuBarMenus` or App/File |
| **G-M7** | 6 | Drop empty palette scopes from the hint | Keep the scopes in the parser; stop advertising them |
| **G-M21** | 11 | `userCanMerge`; no fake admin | Plan field + hide Admin unless a real bit exists |

---

## Implementation Steps

### Phase 0 — Destructive one-liners (H17, H18, H7, H4)

Independent of every later phase. Ship first.

#### 0.1 — H17: ESC-cancelled drops on branch rows

In `lib/features/branches/branch_navigator.dart` `onAcceptWithDetails`
(`:1496`), as the first statement:

```dart
if (ref.read(dragStateProvider) == null) return;
```

`branch_navigator.dart` imports `drag_item.dart` but not
`../dnd/drag_state.dart` (which declares `dragStateProvider`) — add that
import. Match `history_view.dart:2062-2063` and `drop_zone.dart:49-52`.
Do not change `onWillAcceptWithDetails`.

*Test:* extend `test/branch_commit_drop_test.dart`. No existing test
simulates an ESC-cancelled drag (`test/nav_rail_test.dart` only shows
`dragStateProvider` wiring) — write the cancel case fresh: pump a branch
row, start a `DragCommit`, null `dragStateProvider` (what ESC does),
deliver `onAcceptWithDetails`, assert the merge / cherry-pick confirm is
**not** shown.

#### 0.2 — H18: Help must not teach checkout as All Branches

In `macos/Runner/help_book.json` topic `tab_history`:

* Remove the shortcut object
  `{"label": "Toggle All Branches Filter", "keys": "⌘⇧B"}`.
* Rewrite the paragraph at the “All Branches Scope vs HEAD Scope”
  heading: the control is the History toolbar toggle, not a chord.
  ⇧⌘B is Checkout selected commit (confirm dialog).
* Leave `{"label": "Open History in New Window", "keys": "⌘⇧H"}` —
  that matches `global.openHistoryWindow`.

*Test:* extend `test/help_book_json_test.dart`:

1. Parse every `shortcuts[].keys` in the book.
2. If a chord is also a `KeyBinding` default in `kKeymapActions`, the
   Help label’s verb must match that action’s `label` (normalize
   case/punctuation). Fail on ⇧⌘B ↔ anything other than
   `history.checkout`.
3. Assert no Help shortcut string equals `⌘⇧B` / `⇧⌘B` except checkout.

Do **not** add `history.toggleAllBranches` in this phase.

#### 0.3 — H7: pass reviewed identities into the filter

In `repo_status_view.dart` `_fileList` (`:2281-2284`):

```dart
final reviewed = {
  for (final item in _reviewController.value.reviewed) item.pathIdentity,
};
final result = filterRepoChangeRows(
  canonical,
  effectiveFilter,
  reviewedPaths: reviewed,
);
```

`_reviewController.value.reviewed` is a `Set<ReviewItemId>` and its
matching getter is `pathIdentity` (`repo_review_state.dart:17`) — there is
no `.identity` on `ReviewItemId`. It already produces the same
`'${section.name}:$path'` format as `RepoChangeFileRow.identity`
(`repo_change_model.dart:46`). Do not invent a second key.

*Test:* widget test on the Repository change list (extend
`test/repo_status_view_test.dart` or `test/repo_change_filter_test.dart`):

1. Existing unit tests that pass `reviewedPaths` still pass.
2. New widget test: mark one row reviewed, flip “Hide reviewed paths”,
   assert that path’s row is gone and “Clear filters” appears.
3. Negative: with `includeReviewed: true`, reviewed rows still show.

#### 0.4 — H4: Publish / Create request allow HEAD

In `branch_navigator.dart:774-787` delete `!local.isHead &&` from both
`canPublish` and `canCreateRequest`. Keep `unpublished`, `remotes`,
`!hasRequest`, `onPublish` / `onCreateRequest`, `!busy`.

Rewrite the mirror-comment at `:766-768` so it is true: predicates now
match `branch_detail.dart:609-613`. (The comment at `:792-793` belongs to
merge/delete and stays.)

*Test:* extend `test/branches_keymap_handlers_test.dart` or
`test/branches_navigator_test.dart`. Select HEAD, unpublished, remotes
non-empty: `branches.publish` handler is non-null. Select HEAD,
published, no request: `branches.createRequest` handler is non-null.
Select HEAD, has request: `createRequest` is null. Non-HEAD unpublished
still publishes.

#### Phase 0 acceptance

* H17/H18/H7/H4 citations no longer demonstrate the defect.
* `flutter analyze` + the new/extended tests green.
* No chrome geometry changes.

| Required tests | File |
| --- | --- |
| ESC drop no-ops | `test/branch_commit_drop_test.dart` (extend) |
| Help ⇧⌘B ≠ All Branches | `test/help_book_json_test.dart` (extend) |
| Hide reviewed hides | `test/repo_change_filter_test.dart` + widget |
| HEAD can publish / create request | `test/branches_keymap_handlers_test.dart` or navigator test |

---

### Phase 1 — Worktree tab keeps its handlers (H2, M31)

#### 1.1 — H2: one `PanelShortcuts` around both branches

Restructure `worktrees_view.dart` `build` so the `tabs.selected != null`
early return (`:610`) **does not skip** the handler map (`:694-726`).

Deterministic shape:

1. Compute `handlers` **before** the tab/overview fork.
2. When a checkout tab is selected:
   * `worktrees.add` / `repairAll` / `prune` stay bound (same as overview).
   * `open` / `lock` / `unlock` / `move` / `repair` / `remove` bind to
     **that tab’s** `tabWorktree` (not `_selectedOverviewPath`).
   * `remove` stays null when `tabWorktree.isMain`.
   * `lock` / `unlock` follow `isLocked` exactly as overview.
3. Wrap **both** the tab `Column` and the overview scaffold in
   `PanelShortcuts` (one wrapper above the `if (tabs.selected != null)`).
4. `menu_bar_spec_test.dart` already greps
   `lib/features/worktrees/worktrees_view.dart` for `'$id':` — keep those
   string keys in this file.

Do not mount a second `PanelShortcuts`. `AvailableActions` is single-owner.

#### 1.2 — M31: overview selection is visible

In `_row` (`worktrees_view.dart:938-950`) tint when
`wt.path == _selectedOverviewPath`, not only when `open`. Open tabs may
use a second, weaker marker (e.g. a trailing “open” caption) so the
keymap operand and the tab state are distinguishable.

#### Phase 1 acceptance

* With a worktree tab selected, Worktree ▸ Add / Repair All / Prune are
  enabled; Repair / Remove target the open checkout; ⌘K `worktrees.add`
  runs (palette consume finds the handler within 3s).
* Tapping a main worktree (cannot open a tab) highlights it and enables
  Repair.

| Required tests | File |
| --- | --- |
| Handlers exist on the tab branch | widget test in `test/worktrees_view_test.dart` (or new `test/worktrees_handlers_test.dart`): select a tab, read that `PanelShortcuts.handlers['worktrees.add'] != null` |
| Overview tint follows `_selectedOverviewPath` | same file |
| Existing `menu_bar_spec_test` still green | `test/menu_bar_spec_test.dart` |

---

### Phase 2 — Cross-panel menus (H1)

Depends on Phase 1 so Worktree items have a live handler after switch.

#### 2.1 — Classify ids

Add to `lib/features/common/panel_actions.dart` (next to
`kPanelActionOwner`, one source of truth):

```dart
/// Menu ids that a connected session may run after switching panels.
/// Selection-gated verbs are deliberately absent.
const Set<String> kCrossPanelMenuActionIds = {
  'repository.fetch',
  'repository.pull',
  'repository.pullRebase',
  'repository.pullMerge',
  'repository.push',
  'repository.pushSetUpstream',
  'repository.pushTags',
  'repository.forcePush',
  'repository.forcePushHard',
  'repository.sync',
  'repository.stash',
  'repository.stageAll',
  'repository.unstageAll',
  'repository.focusCommit',
  'repository.amend',
  'branches.newBranch',
  'branches.createTag',
  'stashes.stashWithMessage',
  'forge.newIssue',
  'github.newPr',
  'gitlab.newMr',
  'worktrees.add',
  'worktrees.repairAll',
  'worktrees.prune',
};
```

Everything else in `kMenuBarMenus` stays **selection-gated**: enabled
only when the owning panel is active and its handler is non-null.

Do not put `repository.abortPending`, `branches.publish`,
`stashes.apply`, `github.merge`, `worktrees.remove`, or any `history.*`
in this set.

#### 2.2 — Publish the session set

In `AvailableActions` (`menu_bar_bridge.dart`):

* Add `_sessionIds` + `publishSession(Set<String> ids)` (mirror
  `publishShell`).
* `_recompute` = `_panelIds ∪ _shellIds ∪ _sessionIds`.

In `AppShell`, when `connected`, post-frame
`publishSession(kCrossPanelMenuActionIds)`; when not,
`publishSession(const {})`.

Forge-host gating: `github.*` / `gitlab.*` stay in the set only if
`forgeProvider` for the active repo is that host. If forge is still
loading, omit both host-specific create verbs; keep `forge.newIssue`.

#### 2.3 — Do not change dispatch

`app_shell.dart:804-809` already switches panel and parks
`PaletteIntent`. `visitedPagesProvider.visit` mounts the IndexedStack
child. `PanelShortcuts` consume runs on the next frame. Age gate is 3s
(`palette_intents.dart:41`) — enough for a first mount.

Inactive panels must keep publishing **empty** handler maps (so they do
not steal `_owner`). Only the active panel’s selection-gated ids overlay
the session set.

#### 2.4 — Swift comment

Update `MainFlutterWindow.swift:510-513` to say enablement is
“reachable in this session or runnable on the active panel”, not “the
active panel can currently run.”

#### Phase 2 acceptance

* From History, Repository ▸ Fetch is enabled and, when chosen, switches
  to Repository and runs `_fetch`.
* From Repository with no stash selected, Stash ▸ Apply Stash is dimmed.
* From Worktrees overview with nothing selected, Worktree ▸ Remove is
  dimmed; Add is enabled.
* Disconnect clears the session set.

| Required tests | File |
| --- | --- |
| Session ∪ panel union | extend `test/menu_bar_bridge_test.dart` |
| Cross-panel set ⊆ `kKeymapActions` and ⊆ `kPanelActionOwner` | extend `test/menu_bar_spec_test.dart` |
| Fetch enabled with History as active panel | widget or unit: publish session + empty panel → `repository.fetch` ∈ state |
| Selection-gated absent from session set | assert `kCrossPanelMenuActionIds` contains none of `stashes.apply`, `branches.delete`, `worktrees.remove`, `github.merge` |

---

### Phase 3 — Conflicts (H5, H6, H9, M15, L7)

#### 3.1 — H5: tree opens the conflict section

Extend `FileView.onOpenFile` (and `_openFileFromTree`) with
`{required bool conflict}` (or derive inside RSV from
`statusFor(path)?.isUnmerged`).

In `file_view.dart:198-209`, if `s?.isUnmerged == true`, pass
`conflict: true` and do **not** treat the file as staged/unstaged.

In `_openFileFromTree`:

```dart
_selectionKind = conflict
    ? _SectionKind.conflict
    : untracked
    ? _SectionKind.untracked
    : staged
    ? _SectionKind.staged
    : _SectionKind.unstaged;
```

`fromTree` selections skip `reconcile` — do not rely on reconcile to
fix this.

*Test:* status with one `UU` path; invoke tree open; expect
`repoFileSelectionProvider` section == conflict and the conflict toolbar
(Use Ours / Use Theirs) is on screen, not `DiffView`.

#### 3.2 — H6: Mark resolved = existing `git.stage`

On the conflict toolbar (`repo_status_view.dart:1997-2007`) and the
conflict context menu (`:2556-2572`) add:

* **Mark Resolved** → `_stage(path)` / `_stageMany(paths)`.

Label: “Mark Resolved” (not “Stage”) on the conflict section so it is
not confused with staging an unmerged half. Tooltip: “git add — keep the
working-tree file as the resolution.”

Do **not** add a new `GitService` method.

Tree context menu (`file_view.dart:234-308`): if `isUnmerged`, offer
Mark Resolved in addition to Open/View.

#### 3.3 — H9: review uses ConflictView

In `multi_file_review.dart`:

* If `active.section == RepoChangeSection.conflict`, watch
  `conflictFileProvider((repoPath, path))` and build `ConflictView`
  (same widget `_conflictPanel` uses).
* Bulk actions for conflict: Use Ours / Use Theirs / Mark Resolved.
  Thread callbacks from RSV (`_resolveMany`, `_stageMany`).

Do not load `fileDiffProvider` for conflict items.

#### 3.4 — M15 / L7 copy

* Relabel Ours/Theirs by `pendingOpProvider`:
  * `PendingOp.rebase` → “Use Onto (ours)” / “Use Commit (theirs)” with
    a caption that git’s ours is the upstream.
  * otherwise → “Use Ours (HEAD)” / “Use Theirs (incoming)”.
* Fix `conflict_view.dart:158-159` to `'Use Ours / Use Theirs above'`
  (drop the doubled “Use”).

Do not swap the `useOurs` boolean.

#### Phase 3 acceptance

* Tree-click on `UU` opens ConflictView.
* Mark Resolved runs `git add` and the file leaves the conflict section.
* Review-all on a mixed selection shows ConflictView for conflict items
  and offers the three resolve actions.
* Binary conflict empty-state grammar is correct.

| Required tests | File |
| --- | --- |
| Tree → conflict section | `test/repo_file_selection_test.dart` or RSV widget test |
| Mark resolved calls `stage` | RSV / fake-git unit |
| Review conflict branch | `test/multi_file_review_test.dart` (new or extend) |
| Rebase label | widget test with `PendingOp.rebase` |
| L7 string | `test/conflict_view_test.dart` if present; else grep-style widget test |

---

### Phase 4 — Commit chords and multi-select (H8, M12, L8)

#### 4.1 — H8: bind `commit.*` on the live composer

In `CommitComposer` (`commit_composer.dart`), when
`presentation != collapsed` and the message field can accept, wrap the
expanded body in `CallbackShortcuts` (this file already documents that
dialog/sheet-scoped shortcuts must fire while typing —
`panel_shortcuts.dart:21-23`):

* `commit.confirm` → `onAccept(false)` if `controller.canAccept`
* `commit.confirmAndPush` → `onAccept(true)` if `controller.canAccept`

Resolve activators via `resolveShortcuts(ref.watch(keymapProvider), …)`
so remaps apply.

Keep `CommitDialog` tests. Do not route `commit.*` through
`kPanelActionOwner` (they are not panel-switchable; they only mean
something inside the composer).

Update the keymap label for `repository.focusCommit` from
“Open commit dialog” to “Focus commit composer” (`keymap.dart:428-429`).
(That handler is gated on `status.staged.isNotEmpty` —
`repo_status_view.dart:1539-1541`; this phase changes the label only,
not the gate.)

#### 4.2 — M12: Space / Discard honor multi-select

In RSV handler map (`repo_status_view.dart:1524-1538`):

* If `_selectedPaths.length > 1` and `_selectionKind != null`, bind
  `repository.toggleStage` / `repository.discard` to `_stageMany` /
  `_unstageMany` / `_discardMany` for that section (same rules as the
  context menu).
* `_selected` staying null for `length != 1` is fine; do not force a
  fake single selection.

#### 4.3 — L8: Stage All button uses the same gate as the shortcut

`_commitBar` Stage All `onPressed` is null when
`unstaged.isEmpty && untracked.isEmpty` (the keymap already does this
at `:1496-1500`).

#### Phase 4 acceptance

* With the composer expanded and a valid message, ⌘↩ commits and ⇧⌘↩
  commits-and-pushes. Bindings follow Keyboard Mappings.
* Multi-select + Space stages/unstages every selected path of that
  section.
* Clean tree: Stage All is dimmed.

| Required tests | File |
| --- | --- |
| Composer ⌘↩ / ⇧⌘↩ | new `test/commit_composer_shortcuts_test.dart` (pump composer, send keys, assert `onAccept` args) |
| Existing dialog tests still pass | `test/commit_dialog_*.dart` if any |
| Multi-select Space | extend RSV keyboard test |
| Stage All dimmed | RSV widget test |

---

### Phase 5 — Forge honesty (H10–H13, M6, M19, M22)

#### 5.1 — H10: never announce Ready while detail is in flight

`MergeReadinessStrip` already takes `detailLoading` / `onRetry`, and
`_prDetail` already computes `final loading = detailAsync.isLoading &&
detail == null` (`github_panel.dart:743`) and passes it (`:782`). Two
gates are missing:

* `merge_readiness.dart:25` shows Checking only when `detailLoading &&
  plan.blockedReasons.isEmpty && !plan.canMergeNow`. Reduce the
  condition to `detailLoading` alone — Checking wins over any list-tier
  verdict.
* In `_prDetail`, render Merge (`:841-843`) and Enable auto-merge
  (`:824-830`) only when `!loading`; `_prMorePulldown` (`:852-866`)
  recomputes a list-tier plan from the row, so gate its Admin-merge item
  on `!loading` too. The strip’s Checking state is the only merge
  signal.

**Do not change** `mergePlanForGitHub` list-tier `canMergeNow`. Leave
`test/merge_plan_test.dart:57-59` as-is.

*Test:* new widget test on `MergeReadinessStrip(detailLoading: true,
plan: planWithCanMergeNowTrue)` expects “Checking mergeability…” and
finds no “Ready to merge”.

#### 5.2 — H11: invalidate detail (and comments) after every CR mutation

GitHub — also invalidate
`pullRequestDetailProvider((repoPath, number))` (and the comments
provider the panel already uses) from:

* `_approve` (`github_panel.dart:1010-1012`)
* `_setPrDraft`
* `_editPr` (`:1354`)
* `_requestChangesPr` (currently invalidates **nothing**)

GitLab — same for `_approve`, `_setMrDraft`, `_editMr` against
`mergeRequestDetailProvider`.

Extract a tiny `_invalidateChangeRequest(int number)` on each panel so
this cannot drift again.

*Test:* existing panel tests that stub `invalidate` — assert the detail
family is invalidated after approve / draft / edit / request-changes.

#### 5.3 — H12: default base is policy, then origin/HEAD, then `main`

Shared helper (put next to the forms or in `forge_create_coordinator.dart`):

```text
seedBase
  ?? repoMergePolicy.defaultBranch
  ?? status.branch.upstream?.replaceFirst(RegExp(r'^[^/]+/'), '')
  ?? 'main'
```

Never overwrite a non-empty controller / `initialBase` (PR form) /
`initialTarget` (MR form).

Wire chrome “New Pull/Merge Request” (`_createPr`,
`github_panel.dart:974-976`, and the GitLab equivalent) to select
`ForgeCreatingChangeRequest(seedBase: …)` from that helper instead of
`const ForgeCreatingChangeRequest()` — the panels already thread
`seedBase` / `seedSource` into the forms (`github_panel.dart:673-677`,
`gitlab_panel.dart:740-744`). Branches’ `openCreateChangeRequest`
(`forge_create_coordinator.dart:22`) already passes seeds — do not
clobber them. `GlRepoMergePolicy.defaultBranch` covers the GitLab side
(`merge_plan.dart:104-105`).

*Test:* form unit/widget: policy `defaultBranch: 'develop'` + no
`initialBase` → controller text is `develop`. `initialBase: 'release'`
wins. No policy, no seed → `'main'` (legacy fallback).

#### 5.4 — H13: resolve releases from dashboard **or** the expanded list

In `project_sections.dart` `ForgeReleaseSel` (`:455-464`):

1. Look up `tagName` in `dashboard.value?.releases`.
2. Else in `projectReleasesProvider` (the “Show all” source at `:227-241`).
3. Else if either is still loading, show `ProgressCircle`.
4. Else `PaneError` (keep the existing string).

Do not add a third fetch this phase. The expanded list model already
has notes/author.

*Test:* select a tag present only in the expanded list; detail renders
notes, not “Release not found in dashboard.”

#### 5.5 — M6: Forge chrome uses a real branch

In `forge_workspace.dart:84` stop assigning `branchLabel: forgeLabel`.

* Set `branchLabel` from `statusProvider(repoPath).value?.branch.head`
  (or the same supplement cache other screens use).
* Put the host name on `supplement.forgeLabel` (already a field) or in
  `repositoryName` suffix — not in the Branch slot.
* Do not pass `ahead: 0, behind: 0` unless status supplied them.
  `_CompactMetadata` / `_StatusSummary` must omit ahead/behind when
  null, never print “0 ahead, 0 behind” by default
  (`repository_context_bar.dart:481`).

#### 5.6 — M19: scaffold actually uses `onRetry`

`RepositoryWorkspaceScaffold` (`repository_workspace_scaffold.dart:61-92`)
stores `onRetry` and renders `SectionError(failure)` only.

When `error != null && onRetry != null`, render the existing
`WorkspacePartialError` / `SectionError` **with** a Retry control that
calls `onRetry`. This is scaffold-wide (History/Branches benefit too).

#### 5.7 — M22: select the created item

`gh pr create` / `glab mr create` (and issue create) print the created
item’s **URL** on stdout; the services capture the output but return
`Future<void>` (`gh_service.dart:617`, `glab_service.dart:1023`). Parse
the trailing number/iid from that URL, change the return type to
`int?`, and `_select(...)`.

If parsing fails (unexpected output): after `invalidate` + `onClose`,
select the list row whose title matches the just-submitted title
(first match). Document that collision case in a code comment.

Do not add a new API hop.

#### Phase 5 acceptance

* Opening a PR never shows a green Ready strip before detail lands.
* Mark ready / approve / edit / request-changes refresh the open pane.
* New PR on a `develop`-default repo does not target `main`.
* “Show all” releases are openable.
* Forge context bar does not read `Branch: GitHub`.

| Required tests | File |
| --- | --- |
| Strip Checking overrides canMergeNow | new `test/merge_readiness_test.dart` |
| List-tier plan unchanged | existing `test/merge_plan_test.dart:57-59` |
| Invalidate detail after approve | `test/github_panel_test.dart` / `gitlab_panel_test.dart` |
| Base prefills | `test/create_pr_form_test.dart` / `create_mr_form_test.dart` |
| Expanded release detail | `test/forge_show_more_test.dart` or project_sections test |
| Retry rendered | scaffold / forge_panel widget test |

---

### Phase 6 — Location restore (H3, M7, M9)

#### 6.1 — `reveal()` sets pending without changing `visit()`

In `WorkspaceNavigationHistory`:

```dart
void reveal(WorkspaceFocus location) {
  visit(location);
  if (state.current == location) {
    state = state.copyWith(pending: location, clearUnavailable: true);
  }
}
```

`visit()` stays as-is (sidebar `_selectPage` must not mark `panel:N`
pending).

`_openPaletteEntity` (`app_shell.dart:325`) calls `reveal` instead of
`visit`.

Back/forward already set pending via `_restore`. No change.

#### 6.2 — Adapters on all six screens

Each screen, once per build when `widget.isActive` (or via
`ref.listen` on `workspaceNavigationProvider`):

```dart
final pending = ref
    .read(workspaceNavigationProvider(key).notifier)
    .takePendingForPanel(<this panel index>);
if (pending != null) unawaited(_apply(pending));
```

Apply table (deterministic):

| Panel | `kind` | Action |
| --- | --- | --- |
| Repository (0) | `path` | Select that path; if `statusFor` is unmerged, section = conflict (reuse H5). Else staged/unstaged/untracked as today. |
| History (1) | `revision` | Select the commit whose `hash` == `identity`. If not in the loaded page, trigger the existing filter/search by SHA, then select. If still missing → `markUnavailable`. |
| Branches (2) | `branch` | Select the ref whose `shortName` / `name` == `identity`; switch to Review if compare is the point. |
| Stashes (3) | `stash` | Select stash whose `oid` == `identity`. |
| Forge (4) | `issue` / `request` / `pipeline` | `_select(ForgeIssueSel / ForgeChangeRequestSel / ForgeCiRunSel)`. |
| Worktrees (5) | `worktree` | Set `_selectedOverviewPath` or open that tab if already in `tabs.open`. |

Ignore `kind == repository` and identities matching `panel:\d+`.

**Ordering:** apply pending *before* the screen’s existing post-frame
`visit(currentSelection)`, so restore is not overwritten (MADR H3).

If the provider is still loading, do **not** `takePendingForPanel`
until `hasValue` — otherwise you consume and drop. Pattern: read
`state.pending` without taking; take only when data can resolve it.

#### 6.3 — Palette entity `run` is not enough

`command_palette.dart:904,926,952` `run: () => onGoToPanel(n)` plus
`onOpenEntity` is OK **after** 6.1 (`reveal`). Add a test that
`onOpenEntity` is invoked and pending is set.

#### 6.4 — M7: stop advertising empty scopes

In the palette placeholder (`command_palette.dart:1045-1048`) remove
`issue:`, `request:`, `ci:`. Leave the parser enums so a later phase
can fill them. Empty `switch` arms stay empty (G-M7).

#### 6.5 — M9: Compare Changes in Review

If `mode == BranchWorkspaceMode.review`, do not use a primary button
whose `onTap` is `_setMode(review)`.

* Either retitle to a non-button header “Comparing with &lt;base&gt;”
* Or `onTap` scrolls the comparison inspector into view
  (`Scrollable.ensureVisible` on a `GlobalKey` already on that widget,
  or add one).

Browse-mode “Compare Changes” may still switch to Review.

#### Phase 6 acceptance

* Palette “Show commit in History” selects that commit, not just panel 1.
* Back from a file selection returns to that file, not a blank Repository.
* Unavailable identity calls `markUnavailable` (already tested in
  `workspace_navigation_test.dart`).
* Palette hint no longer lists `issue:`.

| Required tests | File |
| --- | --- |
| `reveal` sets pending | extend `test/workspace_navigation_test.dart` |
| History applies revision | extend `test/history_actions_test.dart` (no `history_view_test.dart` exists) or a new adapter test with a fake log |
| File path applies selection | RSV + `repoFileSelectionProvider` |
| Palette open-entity sets pending | `test/command_palette_test.dart` |
| Hint text | palette widget test |

---

### Phase 7 — Secondary windows and remote-edit (H14, H15, H16, M24–M26)

#### 7.1 — H14: `ViewerHost` in the secondary shell

In `secondary_window_main.dart`, stack `ViewerHost` above `_body` the
same way `AppShell` does (`app_shell.dart:954`). Override
`openFileViewersProvider` is already per-engine — no hub required
(G-H14).

Detached Status “View file” then opens an in-window viewer inside that
engine. History pop-out gets the same host (harmless if unused).

Do not add `WindowKind.viewer`.

#### 7.2 — H15: `openRemoteFile` uses the notice path

Wrap the body of `RemoteEditManager.openRemoteFile`
(`remote_edit_service.dart:93-147`) in try/catch. On failure, push
`remoteEditNoticeProvider` with `displayError(e)` (same shape as
`_syncFile` at `:181-193`).

Call sites (`file_view.dart:251`, `repo_status_view.dart:2612-2615`,
`viewer_window.dart:586`, `image_diff_view.dart:408`) fire-and-forget
from sync closures; that stays safe only if the method itself never
throws. Prefer the internal catch so a forgotten site cannot surface an
unhandled async error.

*Test:* extend `test/remote_edit_service_test.dart` — stub
`readFileBase64` to throw; expect a notice; expect no uncaught error.

#### 7.3 — M24: watch the parent directory; pause after a declined conflict

* Watch the temp file’s **parent** for create/modify/move whose basename
  matches the session file (covers atomic save).
* After the user dismisses a conflict without overwriting, set a
  `declinedHash` (or pause the watch) until the next **explicit**
  “Overwrite” / new editor mtime that differs from the declined one.
  Do not re-open the dialog on the 500ms debounce of the same bytes.

Success: keep status invalidation; add a short toast (“Uploaded
path”). `UndoToast` already carries a plain message (see “Nothing to
undo”, `app_shell.dart:552-555`), so no new architecture is needed.

#### 7.4 — M25: local vs SSH in secondary

`WindowSession.backend` is already on the wire
(`secondary_window_main.dart:283-313`) and unused for Open/Reveal.

Override `connectionProvider` (or a small `isLocalWorkspaceProvider`)
from the snapshot so `connectionProvider.isLocal` is true for local
detached Status. Then existing Open/Reveal branches work.

Do not send local files through `openRemoteFile`.

#### 7.5 — M26: no `TransparentMacOSSidebar` in secondary

In `file_view.dart:467-473`, skip `TransparentMacOSSidebar` when
`embedded == true` **or** when a new
`SecondaryWindowScope.isSecondary(context)` (InheritedWidget set in
`secondary_window_main`) is true. Paint an opaque pane.

`secondary_window_main.dart:14-16` already forbids WindowManipulator.

#### 7.6 — H16: suppress native key equivalents when a secondary window is key

G-H16.

Native (`MainFlutterWindow.swift` + `SecondaryWindowController.swift`):

* When the key window is a secondary Flutter window, set
  `keyEquivalent = ""` on View-toggle items and on every dynamic
  `kMenuBarMenus` item (keep titles; clicks still `dispatchAction` to
  the main tab).
* When the main window becomes key again, restore equivalents from the
  last installed keymap (today they are baked at `installViewMenuItems`
  / `installMenus`).
* There is no key-window signal today — `magicgit/windows` carries only
  open/close/front. Observe `NSWindow.didBecomeKeyNotification` /
  `didResignKeyNotification` in Swift; no Dart traffic is needed.

Dart: no change to `TabsHost` dispatch. Child
`secondary_window_main.dart:888-905` local `global.refresh` then wins
for ⌘R.

Do not implement windowId-targeted Fetch this cycle.

*Test:* Swift test if the project already has a hook; otherwise a
Dart/unit test that the restore table is the single source, plus a
comment in `test/window_manager_bridge_test.dart`. Live verification
is listed under Confirmation.

#### Phase 7 acceptance

* Detached Status → View file opens a viewer in that window.
* Failed remote-edit open shows the same notice style as a sync
  conflict.
* Detached **local** Status: Reveal in Finder exists; Open file does
  not copy to `magic_git_edit_*`.
* ⌘R with a detached Status key refreshes that window’s repo, not the
  main tab.

| Required tests | File |
| --- | --- |
| ViewerHost present in secondary | `test/secondary_window_app_test.dart` |
| openRemoteFile notice | `test/remote_edit_service_test.dart` |
| backend-local Open path | secondary + file_view test |
| no TransparentMacOSSidebar when secondary | file_view widget test |

---

### Phase 8 — Clone / Create (H19, H20, M29, M30)

#### 8.1 — H19: registration returns success

Change `registerAndActivateLocal` /
`registerAndActivateSshActive` (`workspace_registration.dart`) to
`Future<bool>` (or a small `{ok, warning}` record).

* `false` when `!connection.isConnected` after `connectLocal` /
  `finalizeProvisioned == false`.
* Save failures stay warnings (session is open) — return `true` +
  warning string. Do not swallow connect failure.

Clone (`clone_sheet.dart:369-379`) and Create
(`create_repo_sheet.dart:755-768`):

```dart
final ok = await _register(dest);
if (!ok) {
  setState(() => _error = 'The repository was created but could not be opened.');
  return;
}
setState(() => _finished = true);
```

Create’s success path also has a `_completedWarning` stay-open branch
(`create_repo_sheet.dart:759-762`) — preserve it.

*Test:* extend `test/workspace_registration_test.dart` — failed
`connectLocal` returns `false`. Clone widget test: `_register` false →
no pop, error visible.

#### 8.2 — H20: ignore Escape/X while Create is submitting

In `create_repo_sheet.dart`:

* `_requestClose`: if `_submitting`, return (or confirm “Cancel
  create? The remote command may still finish.”). Default: **ignore**
  (safer; matches disabled footer Cancel at `:1811-1832`).
* Escape registry (`:263-266`) calls the same `_requestClose`.

Clone already cancels the job first (`clone_sheet.dart:420-427`) —
leave it.

#### 8.3 — M29: dispose aborts provisioning

In Clone and Create `dispose`, if `_provisionToken != null`, abort
(same as `local_repo_form.dart:243-258`). After `beginProvisioning`,
if `!mounted`, abort before `return false`
(`clone_sheet.dart:280-283`, `create_repo_sheet.dart:341-344`).

#### 8.4 — M30: remote browser copy

Change the description (`remote_directory_browser.dart:156-159`) to
“Click a folder to open it. Use Choose This Folder to pick the
directory you are in.” Do not implement a second click grammar.

#### Phase 8 acceptance

* Failed open after a successful clone does not show the green Complete
  state.
* Escape during Create submit does not call `abortProvisioning`.
* Popping Clone via barrier/dispose does not leave a provisioned
  session.

| Required tests | File |
| --- | --- |
| bool registration | `test/workspace_registration_test.dart` |
| Create Escape while submitting | create_repo_sheet widget test |
| dispose abort | clone_sheet / create_repo_sheet (token nulled or abort invoked) |
| browser copy | string test or golden-free widget test |

---

### Phase 9 — Session exit and redo toast (M5, L1)

#### 9.1 — M5: quit / red-button / reconnect Cancel use the guard

`confirmSessionExit` (`session_exit_guard.dart:14-58`) already exists
and is tested (`test/session_exit_guard_test.dart`).

* `_onPrepareToTerminate` (`tabs_host.dart:272-280`) and
  `onWindowClose` (`:325-337`): before `_disconnectAllTabs`, for each
  tab whose `connection.isConnected && repoPath != null`, call
  `confirmSessionExit` with title `'Quit Magic Git?'` (terminate) or
  `'Close window?'` (red button). Any Cancel aborts the whole quit;
  do not disconnect the tabs already confirmed.
  `confirmSessionExit(context, container, repoPath:, title:)` derives
  its confirm-button label from `title.contains('Close')` (“Close Tab”
  vs “Log Out”) — add an explicit label parameter so a quit title does
  not render “Log Out”.
* Multi-tab: one dialog listing dirty/pending tabs (path + reason),
  not N dialogs. Reuse `confirmAction` with a joined message.
* Reconnect overlay Cancel (`app_shell.dart:1051-1052`): if status is
  readable, `confirmSessionExit` with title `'Disconnect?'`. If the
  drop made status unreadable, skip (cannot prompt honestly) and
  disconnect — document that in a comment.

`tabs_controller.close` stays dialog-free (callers already confirm).

#### 9.2 — L1: redo empty toast

In `app_shell.dart:602-604`, on `RedoStatus.nothingToRedo`, show the
same soft toast pattern as `UndoStatus.nothingToUndo` (`:552-555`)
with “Nothing to redo”.

#### Phase 9 acceptance

* ⌘Q with a dirty tab shows one confirm; Cancel leaves sessions up.
* Clean tabs quit without a dialog.
* ⇧⌘Z with an empty redo journal toasts.

| Required tests | File |
| --- | --- |
| Multi-tab message builder | unit next to `session_exit_guard_test.dart` |
| Terminate path calls the guard | tabs_host test with a fake window manager if one exists; otherwise extract `_confirmQuit` and unit-test it |
| Redo toast | app_shell / undo overlay test |

---

### Phase 10 — Discoverability (M1–M4, M27, M28)

Do not start while Phases 0–8 HIGH items are open.

#### 10.1 — M1: palette catalog = panel-owned keymap

Generate `_panelActions` from `kPanelActionOwner` keys + a small
`id → (category, icon)` map. Missing icons default to
`CupertinoIcons.square`. This adds the eight repository verbs
(`pullRebase`, `pullMerge`, `pushSetUpstream`, `pushTags`,
`forcePushHard`, `unstageAll`, `amend`, `abortPending`).

`repository.amend` already has a distinct keymap label (“Amend last
commit (working tree)”). Do not reuse `history.amend`’s label.

*Test:* `test/command_palette_test.dart` — every `kPanelActionOwner`
key appears in the catalog.

#### 10.2 — M3: Activity Center is live and wired

* Make the sheet a `ConsumerWidget` that **watches**
  `operationActivityProvider` (stop closing over tap-time `records`).
* `RepositoryContextBar` exposes only `onRevealOutput` today
  (`repository_context_bar.dart:51`) — add `onUndo` / `onOpenRecovery`
  params, then pass:
  * `onUndo` → same handler as `global.undo`
  * `onOpenRecovery` → `recoveryVisibleProvider.notifier.toggle()`
  * `onRevealOutput` already forwarded from RSV; pass it from the
    **shell** so every screen’s bar can reveal Output
* Wrap the sheet in `EscapeDismissible`.
* On Reveal Output: pop the sheet first, then show the pane.

#### 10.3 — M2: remappable View chords (partial)

Push current `keymapProvider` bindings for
`global.toggleOutput/FileView/Dashboard/Recovery`,
`global.refresh`, `global.commandPalette` to Swift after load/edit
(extend the existing `installViewMenuItems` path). If a binding is
empty, clear the key equivalent.

Full fight-resolution with AppKit is enough; do not rebuild the menu
on every keystroke — debounce on keymap write (SettingsBus already
exists).

#### 10.4 — M4 / G-M4: File menu tabs

`global.newTab` (⌘T) and `global.closeTab` (deliberately unbound)
already exist with live shell handlers (`keymap.dart:289-301`,
`app_shell.dart:868-871`) — the only gap is menu exposure. Add a File
menu (or Window items) for both via `kMenuBarMenus` / the same Swift
generic builder. **Leave Close Tab unbound by default**; the menu is
the discoverability path. Do not steal viewer ⌘W (`viewer.close`,
`keymap.dart:669`; the ⌘W-ownership comment sits at `:295-296`).

`global.nextTab` / `global.prevTab` do not exist and the tab controller
has no neighbor-activation API — skip cycling this phase; do not
invent it.

#### 10.5 — M27: Help chords from keymap + Getting Started rewrite

After H18:

* Any remaining Help `shortcuts[].keys` that collide with a
  `kKeymapActions` default must name that action (test from Phase 0
  grows to **all** chords).
* Rewrite Getting Started: Connections Manager + Recents (not “Open
  Local Folder”); PEM load/paste (not “key path”); reconnect is a
  full-window overlay (not a banner); palette is ⌘K only (not ⌘P);
  shortcuts sheet is ⌘/; stash is ⇧⌘S; sync is ⇧⌘Y.

Bump `help_book.json` `version`.

#### 10.6 — M28: auto-fetch pulldown includes the stored value

`_fetchChoices = [0, 5, 10, 15, 30]` (`settings_sheet.dart:50`);
`initState` coerces an unseen stored value to 0 (`:67-69`) and `_save`
persists it (`:106-111`). Insert the stored value as an extra menu item
and keep it selected; only an explicit Off pick may save 0.

#### Phase 10 acceptance

* ⌘K lists Pull (rebase), Unstage all, Amend (working tree), Abort
  pending.
* Activity sheet updates while a fetch runs; Escape closes it; Undo
  appears on an undoable record.
* Help Getting Started matches the landing page.
* Opening Settings on a 7-minute interval does not show Off.

| Required tests | File |
| --- | --- |
| Palette completeness | `test/command_palette_test.dart` |
| Activity watch + Escape | `test/activity_center_test.dart` (extend — exists) |
| Help vs keymap | `test/help_book_json_test.dart` |
| Auto-fetch custom value | no `settings_sheet_test.dart` exists — extend `test/app_settings_test.dart` or add a sheet test |

---

### Phase 11 — Remaining MED

Each row is one PR-sized slice. Do not start until Phase 5 (forge) and
Phase 6 (navigation) are green — several rows touch those files.

| ID | Slice | Files | Done when |
| --- | --- | --- | --- |
| M10 | Confirm History drop merge/rebase | `history_view.dart:2215-2289` | Same `confirmAction` copy as `branches_view.dart:1302-1326` |
| M11 | Checkout prefers a branch at that OID | `history_view.dart:706-713` | Reuse Recovery’s lookup (`recovery_sheet.dart:442-463`) |
| M13 | Review all visible | `repo_status_view.dart:2372-2388` | Walk every visible section, or label “Review section” |
| M14 | Sequencer Continue | RSV `_pendingBanner` (`:1180-1217`), `git_service.dart` | Merge/cherry-pick/revert gain a Continue running the matching `--continue` (today only rebase has one); composer prefills `MERGE_MSG` / cherry-pick/revert message files |
| M16 | Share diff controls with pop-out | `diff_popout_window.dart`, `_diffPanel` | Image routing + line stage + live context in the float |
| M17 | LFS / gitlink honesty | `image_diff_view.dart:375`; porcelain v2 `<sub>` field (currently unparsed) | Pointer files never hit `ImageDiffView`; parse the sub field and badge gitlinks as submodules |
| M18 | `displayError` in composer + review | `commit_composer_controller.dart`, `multi_file_review.dart:181-182` | No raw `GitException:` in those two surfaces |
| M20 | Forge auth callout | `forge_panel.dart`, `auth_status.dart` | 401 / “auth” list errors show Dashboard-equivalent copy + link to Environment Health |
| M21 | `userCanMerge` + no fake admin | `merge_plan.dart:362` (GitHub plan; GitLab already passes `false` at `:538`), `lib/core/gitlab/models.dart:86,143` | GitLab `userCanMerge == false` blocks `canMergeNow`; GitHub Admin merge hidden unless a real bit exists (G-M21) |
| M23 | GL job poll; GH checks by head SHA | `pipeline_jobs_view.dart`, `github_panel.dart:147-157` | Jobs refresh while running; PR checks prefer `headOid` |
| M32 | Snapshot error ≠ empty | `recovery_sheet.dart:150-176` | `snapshotsAsync.when` + `displayError` |
| M33 | Heatmap caption | `dashboard_sheet.dart:524-541` | Title says “Last 200 commits” or a dedicated `--since` walk |
| M34 | Preview link honesty | `preview_view.dart:103-107` | Caption, or `onTapLink` → `openUrl`; no network images |

Required tests: one focused test per row, in the existing file for that
surface when one exists.

---

### Phase 12 — Adjacent LOW only

Never a release gate. Do when the file is already open.

| ID | Slice |
| --- | --- |
| L2 | Separate Semantics + tooltip “Close tab” on `_CloseButton` |
| L5 | `history.amend` handler = `hasCommits && _isHead(selected)` |
| L9 | File-tree Delete copy matches discard (snapshot + ⌘Z) |
| L10 | Stage / Commit / split-diff tooltips include the live binding |
| L16 | Saved-workspace name uses `promptText` |
| L17 | Settings blurb: Keyboard Mappings and Forget Host save immediately |
| L18 | Connection / Add Existing `onSubmitted` + first-invalid-field caption |
| L19 | Stash empty-state points at the context-bar “Stash Changes” |
| L20 | Worktrees overview arrow-key nav (copy Stash `stepSelection`) |

**Skip:** L3 (0006), L4 (inspector), L6 (History menu / 0008), L11
(keep view-only), L12 (GH live logs), L13 (viewer engine doc), L14
(in-window diff), L15 (worktree drag), L21 (full a11y pass), L22
(`executeStream`).

---

## Verification

### Per-phase

Each phase’s Required tests table is the definition of done for that
phase. A phase is not merged (from this plan’s point of view) until:

1. The MADR citation for each included HIGH no longer demonstrates the
   defect.
2. `flutter analyze` is clean.
3. `flutter test` for the listed files, then full `flutter test` before
   the maintainer stages.

### Cross-phase invariants (run after Phases 2, 6, 7, 10)

```sh
flutter analyze
flutter test test/menu_bar_spec_test.dart \
             test/menu_bar_bridge_test.dart \
             test/help_book_json_test.dart \
             test/session_exit_guard_test.dart \
             test/workspace_navigation_test.dart \
             test/workspace_registration_test.dart \
             test/merge_plan_test.dart \
             test/remote_edit_service_test.dart
```

Do **not** run `flutter test --run-skipped -t live-forge …`.

### Live macOS (maintainer; not a CI gate)

After Phases 2, 7, and 9, a running `.app`
(`./build_macos.sh --unsigned`) should confirm:

* From History, Repository ▸ Fetch is enabled and fetches.
* Detached Status: View file opens; ⌘R refreshes that window.
* ⌘Q on a dirty tab confirms once.

H16 key-equivalent suppression cannot be fully proven in widget tests.

### Analyzer / style

Write to the repo idioms on the first pass (`final` locals, `const`
constructors, no `unawaited` without a reason). Do not “fix lints
after.”

---

## Rollout and Rollback

### Rollout

* Phase 0 is safe to ship alone (Help + ESC + filter + HEAD publish).
* Phases 1–2 are the 0008 menu-bar completeness fix; ship together if
  possible (H1 without H2 re-dims Worktree items inside a checkout).
* Phases 3–5 are independent user-visible correctness; each may ship
  as its own commit.
* Phase 6 (location restore) can land after 0–5; it is the largest
  behavioral change and should not mix with conflict/forge diffs.
* Phases 7–9 touch window/quit paths — prefer a dedicated commit each.
* Phases 10–12 are discoverability; skippable if a release cuts after
  HIGH.

Maintainer commits with `git commit --no-edit` after `flutter analyze`
and `flutter test`.

### Rollback

* Every phase is revertible by reverting its commit(s). No schema
  migration. Keymap ids added in Phase 10 (`global.nextTab` if any)
  are additive; removing them is safe (overrides for unknown ids are
  ignored on load).
* Help Book: keep the JSON valid (`test/help_book_json_test.dart`).
  Reverting Phase 0.2 restores the dangerous ⇧⌘B line — do not revert
  0.2 without a replacement sentence.
* `registerAndActivate*` return-type change (Phase 8) is source-only;
  revert the sheet call sites together.

### Doc updates at the end of a phase

* Append one line to the MADR Remediation log (date + finding IDs
  closed). Do not rewrite historical findings.
* Do not mark 0004 / 0008 plans implemented from this work.
* If a phase discovers that a locked gate is wrong, stop and amend
  0009 (or this plan) rather than smuggling a new architecture.

---

## Suggested first commit (after review)

Phase 0 only, four hunks, four test files. That is the smallest
diff that removes a destructive Help chord, an ESC-drop hole, a
no-op filter, and a dimmed Publish on HEAD.
