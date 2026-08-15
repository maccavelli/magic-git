---
status: proposed
date: 2026-08-15
decision-makers: maccavelli (maintainer)
consulted: six parallel read-only exploration agents plus parent verification of HIGH citations
informed: implementers of 0004 / 0006 / 0008 residual work
---

# Treat the 2026-08-15 UI/UX debug pass as the current prioritized remediation backlog

## Context and Problem Statement

Magic Git is a macOS-only Flutter Git client (macos_ui + Riverpod) that drives
`git` / `gh` / `glab` on a local or remote host. The 2026-08-06 UI/UX audit
([0004-MADR-ui-ux-deep-debug-audit.md](0004-MADR-ui-ux-deep-debug-audit.md))
and its plan closed the HIGH correctness track (H1–H8) and most locked MED
items. Later records then changed the chrome and workspace model:

* [0005-MADR-task-centered-adaptive-repository-workspace.md](0005-MADR-task-centered-adaptive-repository-workspace.md)
  — task-centered adaptive workspace.
* [0006-MADR-hybrid-native-title-bar-context-bar.md](0006-MADR-hybrid-native-title-bar-context-bar.md)
  — hybrid native title bar (accepted; main window still
  `TitleBarStyle.hidden` at `lib/main.dart:54`).
* [0008-MADR-unified-repository-chrome.md](0008-MADR-unified-repository-chrome.md)
  — one toolbar + a populated menu bar (partially landed: Dart menu spec,
  grouped sync control on Repository, honest primary-action kinds, Back/Forward
  in the context bar, stash `--include-untracked` unified).

Those initiatives added seams that 0004 never exercised: a native Repository /
Branch / Stash / Forge / Worktree menu, session navigation history, a shared
file-selection provider, hide-reviewed filters, worktree checkout tabs, and
forge merge-readiness on list-tier rows.

A fresh, full-surface UI/UX debug pass on 2026-08-15 found **new**
correctness bugs and incomplete wiring. Several 0004 / 0007 residuals are
stale in the *favorable* direction (they shipped). Several 0008 “no code”
claims are also stale (chrome Phases 0–3 largely exist). The remaining
problems are concentrated in:

1. **Silent or wrong actions** — menus that dim, toggles that no-op, help
   chords that fire a different verb, ESC-cancelled drops that still commit.
2. **Half-built seams** — location restore, worktree-tab handlers, commit
   shortcuts, hide-reviewed, conflict “mark resolved.”
3. **Misleading chrome** — “Ready to merge” on incomplete data, `branchLabel:
   "GitHub"`, Help Book chords that do not match `kKeymapActions`.

The decision to make is:

> How should this new pass be treated relative to 0004’s historical backlog
> and 0008’s unfinished chrome work, and in what order should the verified
> findings be fixed?

This record is the decision for **prioritization**. The findings are evidence,
not optional design alternatives. They were verified against source on
2026-08-15. Tests and a live `.app` were **not** re-run; HIGH items should get
regression tests when fixed.

### Relationship to earlier records

* **Does not supersede 0004.** 0004 remains the historical record of that
  cycle. Its HIGH track is still closed. Do not re-open H1–H8, L1–L5, M8
  comments, M13 selection, or M15 host-key reject as new bugs.
* **Does not supersede 0008.** Unfinished chrome (sync group on every screen,
  History menu, native `NSToolbar`) stays in 0008. This record only claims a
  finding when the *shipped* 0008 surface is incorrect or incomplete in a
  user-visible way (menu enablement, location restore, worktree-tab handlers).
* **Does not implement 0006.** The title-bar flip remains gated on live macOS
  verification. It is listed as a known residual, not a new architecture
  proposal.
* **0007 status claims** about M7 / M13 / M2 / M14 are stale: Labels now
  say “view only”; `repoFileSelectionProvider` exists; zoom-reset uses
  `fullscreen_exit`; palette rows have `Semantics`.

### Audit method

* Six parallel read-only explorations: shell/chrome/keymap/menu; Repository
  status/commit/diff/conflicts; History/Branches/Stash/Worktrees/Recovery/
  Dashboard; Forge (GitHub + GitLab); viewer / secondary windows / DnD;
  connection / onboarding / settings / Help.
* Parent cross-check of every HIGH citation below against the current tree
  (handler maps, `canMergeNow`, `filterRepoChangeRows`, `PanelShortcuts`
  publish, worktree early-return, Help JSON vs `kKeymapActions`).
* Search tools used `rg -a` where needed. `.flutter-sdk/`, `build/`, and
  `.dart_tool/` were excluded.

### Scope

In scope: user-visible correctness, incomplete wiring, misleading chrome,
keymap / palette / menu disagreement, secondary-window honesty, Help/docs
that teach the wrong chord.

Out of scope as *new* product work (already decided elsewhere): inline
code-review threads (0002), GitHub live job logs (0004 M10), network-enabled
markdown images (0004 M11), native `WindowKind.diff` (0004 L6), submodule
management UI (0004 L4), full GPG signing (0001 / 0004 H7 disclosure only),
viewer engine residuals already in `viewer_engine_findings.md` (0004 L7).

## Decision Drivers

* **User-visible correctness** — silent no-ops and wrong-object actions beat
  polish.
* **Honesty of shipped chrome** — a menu item, filter toggle, Help shortcut,
  or “Ready to merge” strip must do what it says.
* **Single sources of truth** — `kKeymapActions`, `kPanelActionOwner`,
  `kMenuBarMenus`, and panel handler maps must agree; Help must not invent
  chords.
* **Root-cause fixes** — finish the declared seam (location adapter, reviewed
  paths, worktree `PanelShortcuts`) rather than adding another button.
* **Scope control** — 0006 title bar, 0008 remaining chrome geometry, and
  forge comment-thread graphs stay on their own records.

## Considered Options

* **A. Record findings only; fix ad hoc as users report**
* **B. Accept this pass as the current prioritized remediation backlog** —
  fix HIGH correctness/wiring first, then MED discoverability, then LOW
  polish; keep 0004 / 0006 / 0008 as historical or architectural records
* **C. Freeze feature work and clear every HIGH+MED+LOW item in one pass** —
  including Help rewrite, full a11y, GH live logs, and 0006/0008 chrome

## Decision Outcome

Chosen option: **"B. Accept this pass as the current prioritized remediation backlog"**, because the highest-severity defects are concentrated in seams that already exist and already have tests nearby (menu enablement, handler maps, merge-plan construction, change-list filter, session-exit guard). Option A leaves Help teaching a checkout chord, a hide-reviewed toggle that does nothing, and a menu bar that is dark on five of six screens. Option C folds 0006 live-preview work and remaining 0008 geometry into a correctness pass and blocks unrelated delivery.

When a companion PLAN is written, it should reuse this record’s finding IDs
and must not invent new architecture. Unfinished 0008 chrome that is *not*
listed as HIGH here stays on [0008-PLAN-unified-repository-chrome.md](0008-PLAN-unified-repository-chrome.md).

### Consequences

* Good, because new HIGH bugs have file-level evidence and a clear order.
* Good, because already-fixed 0004 / 0007 items are marked closed here, so
  they are not re-implemented.
* Good, because 0008’s remaining “delete the second band” work is not mixed
  into conflict/merge correctness.
* Neutral, because severity is static-analysis judgment; live macOS QA may
  re-rank a few MED items (especially P1 menu focus and title-bar feel).
* Neutral, because this record is proposed until the maintainer accepts it.
* Bad, because without a companion PLAN the backlog can rot the same way
  0004’s residual list did — mitigate by opening `0009-PLAN-…` when the first
  remediation cycle is scheduled.
* Bad, because some MED items need a product call (Help generation, File
  menu, inspector population) rather than a one-line fix.

### Confirmation

* Each HIGH citation below is closed when the cited file:line no longer
  demonstrates the defect, and a targeted test fails before / passes after.
* `flutter analyze` and ordinary `flutter test` stay green. Do not run
  `live-forge` tests unless explicitly asked.
* This MADR’s HIGH section is empty or marked fixed after a remediation
  cycle (update status/date and a short Remediation log; do not silently
  rewrite historical findings).
* Companion PLAN: [0009-PLAN-ui-ux-debug-pass-backlog.md](0009-PLAN-ui-ux-debug-pass-backlog.md)
  owns phased delivery, file-level steps, tests, and exit criteria. It must
  not invent new architecture without amending this decision.

## Pros and Cons of the Options

### A. Record findings only; fix ad hoc

* Good, because zero process overhead.
* Bad, because Help ⌘⇧B, hide-reviewed, worktree-tab menus, and the
  Ready-to-merge flash will be rediscovered as unrelated “random” bugs.
* Bad, because 0004 already showed that unowned residual lists drift.

### B. Authoritative prioritized backlog (chosen)

* Good, because it separates active correctness from 0006/0008 chrome.
* Good, because it maps to existing contracts (keymap handler, `displayError`,
  menu = second route, `WorkspaceLocationAdapter`).
* Neutral, because it still needs a scheduled PLAN to become executable.
* Bad, because a long appendix can be mistaken for a commitment to ship
  every LOW item (it is not).

### C. Freeze features; clear everything

* Good, because maximum polish, including Help and a11y.
* Bad, because Help rewrite, GH live logs, inspector population, and the
  0006 title-bar flip are multi-day and independently gated.
* Bad, because it blocks forge/branches work already in flight.

## More Information

### Severity legend

| Sev | Meaning |
| --- | --- |
| **HIGH** | Incorrect behavior, silent failure, or active broken path users can hit |
| **MED** | Incomplete wiring, misleading UI, or discoverability inconsistency |
| **LOW** | Polish, intentional residual, or documented deferral |

---

### HIGH — fix first

#### H1. Native git/forge menus only enable on the owning sidebar page

* **Where:** `lib/features/common/panel_shortcuts.dart:66-82`;
  `macos/Runner/MainFlutterWindow.swift` `validateMenuItem` (enabled iff id ∈
  `enabledActionIds`)
* **Evidence:** `PanelShortcuts` publishes only the *active* panel’s non-null
  handler ids. Dispatch in `app_shell.dart` *would* switch panels, but a
  dimmed item cannot be chosen. From History, Repository ▸ Fetch is dead even
  though `_fetch` has no selection gate.
* **User impact:** The 0008 menu bar looks complete and is mostly unusable
  unless the matching sidebar page is already open — the opposite of HIG
  “learn commands from the menu.”
* **Fix:** Enable any menu id a connected session can reach; keep
  selection-gated verbs dimmed. Let dispatch switch panel then run.

#### H2. Opening a worktree checkout tab tears down every Worktree handler

* **Where:** `lib/features/worktrees/worktrees_view.dart:610-655` vs `:694-726`
* **Evidence:** A selected worktree tab returns a `Column` +
  `NestedWorkspaceScope` *before* `PanelShortcuts` is built. Palette consume
  is age-gated (`palette_intents.dart`, ~3s) and then expires.
* **User impact:** While *inside* a worktree, Worktree ▸ Add / Repair / Remove
  and ⌘K equivalents silently no-op.
* **Fix:** Always wrap the Worktrees page in `PanelShortcuts`. When a tab is
  selected, bind add/repairAll/prune globally and the rest to that tab’s
  worktree.

#### H3. Back / Forward and palette entities never restore a location

* **Where:** `lib/features/common/workspace_navigation.dart:9-15,91-96,133-147`
* **Evidence:** `WorkspaceLocationAdapter.applyWorkspaceLocation` and
  `takePendingForPanel` have **zero production callers**.
  `restoreWorkspaceLocation` only `select`s `panelIndex`. Palette entity
  `run` is `onGoToPanel`; `dispatchEntity` exists and is never called.
  Screens still `visit(...)`, so history records panel flips, not objects.
* **User impact:** Back/Forward mostly change sidebar pages. “Show this
  commit in History” / “Open this file” do not select the object. 0008’s
  “wire Back/Forward” is half-done.
* **Fix:** Implement adapters on all six screens; palette entity actions
  must `dispatchEntity`.

#### H4. Publish / Create request keymap, palette, and Branch menu refuse HEAD

* **Where:** `lib/features/branches/branch_navigator.dart:774-805` vs
  `lib/features/branches/branch_detail.dart:608-645`
* **Evidence:** Detail `canPublish` / `canCreateRequest` do **not** exclude
  `isHead`. Navigator (the map the menu and palette use) requires
  `!local.isHead`. The comment at `:766-768` claims the predicates “mirror
  branch_detail”; they do not (the `:792-793` comment covers merge/delete
  only).
* **User impact:** The branch you are on — the usual publish / PR target —
  keeps Branch ▸ Publish and Create Pull or Merge Request dimmed. Review
  buttons work; menu / keys / palette do not.
* **Fix:** Drop `!isHead`. Keep unpublished / hasRequest / remotes / busy.

#### H5. File tree never opens the conflict pane

* **Where:** `lib/features/repository/file_view.dart:198-209`;
  `lib/features/repository/repo_status_view.dart:1811-1824`
* **Evidence:** Tree `onOpenFile` only passes `staged` / `untracked`. A `UU`
  file is both, so `staged` is false. `_openFileFromTree` forces
  `_SectionKind.unstaged`. `fromTree` selections skip `reconcile`, so they
  are never rehomed to `conflict`.
* **User impact:** A conflicted file selected from Files looks selected, but
  the detail is a normal diff with no Use Ours / Use Theirs. The Conflicts
  row does not highlight.
* **Fix:** If `statusFor(path)?.isUnmerged`, set `section: conflict`.

#### H6. Manual conflict edits cannot be marked resolved

* **Where:** `repo_status_view.dart:2556-2572` (conflict menu is only Ours /
  Theirs); `_conflictPanel` ~1977-2014; `file_view.dart` tree menu has no
  Stage on unmerged paths
* **Evidence:** Resolve is `git checkout --ours/--theirs` then `git add`.
  There is no “Mark resolved” / `git add -- path` for a file the user edited
  by hand.
* **User impact:** Editing conflict markers (viewer or remote-edit) cannot be
  committed without overwriting the edit via Ours/Theirs.
* **Fix:** Add Stage / Mark resolved on conflict rows, the conflict toolbar,
  and multi-file review.

#### H7. “Hide reviewed paths” is a silent no-op

* **Where:** `lib/features/repository/repo_change_navigator.dart:168-178`;
  `repo_status_view.dart:2281-2284`; `repo_change_filter.dart:59-84`
* **Evidence:** The pulldown flips `includeReviewed`. Production calls
  `filterRepoChangeRows(canonical, effectiveFilter)` with the default
  `reviewedPaths: const {}`. Tests only pass when `reviewedPaths` is
  supplied.
* **User impact:** The toggle and Clear filters appear to work; the list
  does not change.
* **Fix:** Pass `_reviewController.value.reviewed` mapped to `row.identity`.

#### H8. Production commit composer ignores ⌘↩ / ⇧⌘↩

* **Where:** `lib/core/settings/keymap.dart:488-499`;
  `lib/features/repository/commit_dialog.dart:96-101`;
  `commit_composer.dart` (no `commit.*` bindings);
  `lib/features/common/panel_actions.dart:22-24` (excludes `commit.*`)
* **Evidence:** Shortcuts exist and are tested on `CommitDialog`. The live
  UI is the docked `CommitComposer`. Menu / ⌘G call `_expandCommitComposer`,
  not the sheet. `CommitDialog` is test-only in production.
* **User impact:** Keyboard Mappings and tests promise Confirm commit; in
  the real composer the keys do nothing.
* **Fix:** Bind the same handlers on the expanded composer (or stop
  advertising `commit.*` until the sheet is used).

#### H9. Multi-file review of conflicts is the wrong surface

* **Where:** `lib/features/repository/multi_file_review.dart:98-107,178-214`;
  `repo_status_view.dart:2361-2388`
* **Evidence:** Conflict items load `fileDiffProvider(..., staged: false)`,
  not `conflictFileProvider` / `ConflictView`. Bulk actions for `conflict`
  are `[]`.
* **User impact:** Review selected/all on conflicts shows a normal or empty
  diff and no resolve actions.
* **Fix:** Route conflict items to `ConflictView` + Ours/Theirs/Mark
  resolved.

#### H10. GitHub PR detail flashes “Ready to merge” on list-tier data

* **Where:** `lib/features/github/github_panel.dart:733-786`;
  `lib/core/forge/merge_plan.dart:175-196,351-354`;
  `lib/features/forge/merge_readiness.dart:25-48`
* **Evidence:** List JSON has no `mergeable` / `mergeStateStatus` /
  `headOid` (`mergeable` defaults to `unknown`). `mergePlanForGitHub` only
  treats `UNKNOWN` as a block when those exist. A non-draft list PR therefore
  has `canMergeNow == true`. The strip shows “Checking…” only when
  `detailLoading && plan.blockedReasons.isEmpty && !plan.canMergeNow`, and
  the More pulldown (`github_panel.dart:852-866`) recomputes a list-tier
  plan for Admin merge.
* **User impact:** Every PR open paints a green Ready to merge until detail
  lands, then may flip to conflicts / checks / review.
* **Fix:** While `detailLoading`, treat list-tier GitHub plans as unknown;
  hide Merge / auto-merge until detail exists.

#### H11. Draft / edit / approve / request-changes leave the open detail stale

* **Where:** `github_panel.dart` `_setPrDraft` / `_editPr` / `_approve` /
  `_requestChangesPr`; `gitlab_panel.dart` matching paths
* **Evidence:** Detail prefers `detail ?? list`. These mutations invalidate
  the **list** only. `_requestChangesPr` invalidates **nothing**. Merge /
  auto-merge / update-branch / rebase *do* invalidate detail.
* **User impact:** “Mark ready” looks like a no-op (DRAFT badge + merge
  still blocked). Title/body and review chips stay old.
* **Fix:** After every change-request mutation, invalidate the detail
  provider (and comments + list for reviews).

#### H12. New PR / MR base hardcodes `main`

* **Where:** `lib/features/github/create_pr_form.dart:78-80`;
  `lib/features/gitlab/create_mr_form.dart:84-86`
* **Evidence:** Unseeded open sets base/target to `'main'`.
  `repoMergePolicyProvider` already exposes `defaultBranch`. Chrome “New
  Pull/Merge Request” does not pass `seedBase`.
* **User impact:** `master` / `develop` / `trunk` repos get the wrong
  default; submit fails at the forge or targets a leftover `main`.
* **Fix:** Prefill from `repoMergePolicy.defaultBranch`, then
  `origin/HEAD`, only then `'main'`. Never overwrite a user/seed value.

#### H13. Expanded release tap → “Release not found”

* **Where:** `lib/features/forge/project_sections.dart:455-465` vs `:227-241`
* **Evidence:** After “Show all”, rows come from `projectReleasesProvider`.
  Detail only searches `dashboard.value?.releases` (GraphQL cap, 20).
  Overflow tags miss and render `PaneError('Release not found in dashboard.')`.
* **User impact:** Releases beyond the first page are tappable and then
  dead.
* **Fix:** Resolve the selected tag from the dashboard *or* the expanded
  list (the list model already has notes/author).

#### H14. “View file” in a detached Status window is a silent no-op

* **Where:** `lib/features/repository/file_view.dart:238-242`;
  `lib/features/viewer/viewer_host.dart:16-22`;
  `lib/features/window/secondary_window_main.dart:984-995`
* **Evidence:** Tree context menu writes `openFileViewersProvider`. The only
  `ViewerHost` is stacked in the main `AppShell`. Secondary `_body` is
  `HistoryView` or `RepoStatusView` only. Detached Status still mounts
  `FileView`.
* **User impact:** Right-click → View file in a popped-out Status window
  does nothing. No error.
* **Fix:** Mount `ViewerHost` in the secondary shell, or open the viewer in
  the main window via the hub.

#### H15. Remote-edit *open* has no error surface (H4 residual)

* **Where:** `lib/features/viewer/remote_edit_service.dart:93-147`
* **Evidence:** `openRemoteFile` is not in try/catch. Failures from
  `readFileBase64`, `base64.decode`, `createTempSync`, or `writeAsBytesSync`
  never hit `remoteEditNoticeProvider` (only `_syncFile` /
  `forceUploadAfterConflict` do). Callers fire-and-forget from sync tap
  closures.
* **User impact:** Open file / Open in Default App on SSH can fail with no
  dialog — the class of silent fail 0004 H4 was meant to kill. Sync-path
  notices and proxied `uploadBytes` (H5) are fine.
* **Fix:** Wrap open in the same notice path as sync; await at call sites.

#### H16. Native menu shortcuts always run in the main window’s active tab

* **Where:** `macos/Runner/MainFlutterWindow.swift` menu channel;
  `lib/features/tabs/tabs_host.dart:248-254`;
  `lib/features/window/secondary_window_main.dart:888-905`
* **Evidence:** View ▸ Refresh (⌘R), Preferences, Command Palette, and
  dynamic repo menus target `MainFlutterWindow` → `TabsHost` → the **active
  tab’s** `AppShell`. AppKit key-equivalents fire for the process, not the
  key window. Secondary binds `global.refresh` locally, but the menu wins.
* **User impact:** Detached Status on another worktree: ⌘R refreshes the
  main tab’s repo. ⌘, / ⌘K / View toggles mutate the main shell while a
  secondary window is key.
* **Fix:** Disable or retarget menu equivalents when a secondary window is
  key; or dispatch with `windowId`.

#### H17. Branch-row E2 / merge drops ignore ESC-cancelled drags

* **Where:** `lib/features/branches/branch_navigator.dart:1496-1508` vs
  `lib/features/history/history_view.dart:2061-2063`,
  `lib/features/dnd/drop_zone.dart:49-52`
* **Evidence:** History rows, nav `DropZone`, and the staging banner no-op
  when `dragStateProvider` is null (ESC). Branch-row `onAcceptWithDetails`
  has **no** guard. Flutter still delivers accept after ESC nulls state.
* **User impact:** ESC + release over a branch can still open
  cherry-pick / merge UI — the class the hardening pass claimed was closed.
* **Fix:** Same `ref.read(dragStateProvider) == null` return as every other
  target.

#### H18. Help Book teaches ⌘⇧B as “All Branches”; that chord checks out a commit

* **Where:** `macos/Runner/help_book.json:134-150` vs
  `lib/core/settings/keymap.dart:508-514`
* **Evidence:** Help: “Toggle All Branches Filter” / “press ⌘⇧B”. Keymap
  binds `history.checkout` to ⌘⇧B. All-branches is a toolbar toggle with
  **no** keymap (`history_view.dart` `setHistoryAllBranches`).
* **User impact:** A user following Help on History can detach HEAD instead
  of changing the log filter.
* **Fix:** Align Help with `kKeymapActions` (or add
  `history.toggleAllBranches` and bind it). Prefer generating Help shortcuts
  from the keymap.

#### H19. Clone / Create report success even if the new repo never becomes the workspace

* **Where:** `lib/features/workspace/clone_sheet.dart:369-379`;
  `create_repo_sheet.dart:755-768`;
  `lib/features/workspace/workspace_registration.dart:25-28`
* **Evidence:** After clone/create, `_register` is awaited and the sheet
  always goes green and pops. `registerAndActivateLocal` returns silently if
  `connectLocal` fails (`if (!…isConnected) return`). SSH
  `finalizeProvisioned` is not checked for `false`.
* **User impact:** Folder exists on disk; UI says Complete; user is still
  on the previous session (or landing) with no error.
* **Fix:** `_register` must return success/failure. Only set `_finished` /
  pop on a live session.

#### H20. Create: Escape / X abort provisioning while `git init` / forge publish is running

* **Where:** `lib/features/workspace/create_repo_sheet.dart:263-266,1026-1028,1141-1145`
* **Evidence:** Footer Cancel is disabled while `_submitting`, but the
  title X and Escape always call `_requestClose` → `abortProvisioning`.
  Clone at least cancels the job first.
* **User impact:** Accidental Escape mid-create can tear down the SSH
  session under an in-flight `git init` / `gh repo create`, leaving a
  half-created repo.
* **Fix:** Ignore Escape/X while submitting, or confirm and cancel
  cooperatively.

---

### MED — wiring, discoverability, misleading chrome

| ID | Item | Evidence | Fix direction |
| --- | --- | --- | --- |
| M1 | Palette catalog omits eight menu/keymap repository verbs | `command_palette.dart:115-158` vs `keymap.dart:698-744` (`pullRebase`, `pullMerge`, `pushSetUpstream`, `pushTags`, `forcePushHard`, `unstageAll`, `amend`, `abortPending`) | Generate `_panelActions` from `kPanelActionOwner` |
| M2 | Remappable Flutter shortcuts vs hardcoded native View chords | `MainFlutterWindow.swift` still installs fixed ⇧⌘O/E/D/U and ⌘R/⌘K; keymap remaps only `CallbackShortcuts` | Push current bindings to Swift, or drop native key equivalents |
| M3 | Activity Center is a tap-time snapshot; Undo/Recovery never wired | `activity_center.dart`; only Repository passes `onRevealOutput`; `onUndo` / `onOpenRecovery` unused | Watch `operationActivityProvider`; wire undo/recovery; `EscapeDismissible` |
| M4 | Edit ▸ Undo/Redo is text undo; no File / tab menu | `MainMenu.xib` Edit first-responder `undo:`; `global.closeTab` unbound; no next/previous tab | File ▸ New/Close/Next/Previous Tab; retarget or label Edit Undo |
| M5 | Quit / red-button / reconnect Cancel skip dirty + pending-op guards | `tabs_host.dart:272-280,325-337`; `app_shell.dart:1051-1052` vs `session_exit_guard.dart` | Same guard (or a multi-tab summary) before terminate/close |
| M6 | Forge chrome still sets `branchLabel` to `"GitHub"` / `"GitLab"` | `forge_workspace.dart:84`; compact metadata prints `0 ahead, 0 behind` | Real HEAD in `branchLabel`; omit ahead/behind when unknown |
| M7 | Palette `issue:` / `request:` / `ci:` scopes are empty stubs | `command_palette.dart` still advertises them (“Phase 8”) | Implement or drop from the hint |
| M8 | Stash / Worktrees still stack extra action chrome | Stash hamburger + context-bar Stash; Worktrees Add + strip Add; checkout tab replaces sync group with Refresh | Leave filters; move duplicate verbs to menu only |
| M9 | “Compare Changes” is a no-op once already in Review | `branch_detail.dart:647-653`; `onCompare` only `_setMode(review)` | Scroll to inspector, or retitle |
| M10 | History drop merge/rebase has no confirm | `history_view.dart:2215-2289` vs Branches confirm | Reuse Branches confirm copy |
| M11 | History checkout always threatens detached HEAD | `history_view.dart:706-713` vs `recovery_sheet.dart:442-463` | Same branch-at-OID lookup as Recovery |
| M12 | Space / Discard ignore multi-select | `repo_status_view.dart` `_selected` is null when `paths.length != 1` | Call `_stageMany` / `_discardMany` |
| M13 | “Review all visible” only reviews the first section | `repo_status_view.dart:2372-2388` | Walk sections or change the label |
| M14 | Merge/cherry-pick/revert conflicts have no Continue action at all | `_pendingBanner` (`repo_status_view.dart:1180-1217`) renders Continue only for rebase; others say “resolve conflicts and commit” | Real `--continue` per op; prefill `MERGE_MSG` / `CHERRY_PICK_HEAD` |
| M15 | Use Ours / Use Theirs copy is merge vocabulary | Wrong during rebase (git swaps ours/theirs) | Relabel by `pendingOp` |
| M16 | Diff pop-out is a thinner clone (no image, no line stage, stale context) | `diff_popout_window.dart` vs `_diffPanel` | Share `_diffPanel` / `DiffViewControls` |
| M17 | Image / LFS / gitlink can lie | LFS pointers → “Binary image change” (`image_diff_view.dart:375`); porcelain v2 `<sub>` field is never parsed, so gitlinks go undetected in status UI | Detect pointers; parse the sub field; don’t send pointers to `ImageDiffView` |
| M18 | `displayError` still bypassed in composer + multi-file review | `commit_composer_controller.dart` `$caught`; `multi_file_review.dart` `$error` | Route through `displayError` |
| M19 | Forge detect `onRetry` is dead | `RepositoryWorkspaceScaffold` stores `onRetry` and never renders it | Use `WorkspacePartialError` / Retry |
| M20 | Token expiry is Dashboard-only | Forge lists are generic `SectionError`; tool-health banner is binaries only | Inline auth callout on 401 / “auth” |
| M21 | Merge enablement not honest everywhere | GitLab `userCanMerge` parsed but unused (`models.dart:86,143`); GitHub plan hardcodes `supportsAdminBypass: true` (`merge_plan.dart:362`; GitLab already passes `false`); row Merge only disables drafts | Feed permission into the plan; dim with `blockedSummary` |
| M22 | Create PR/MR/issue success does not select the new item | Services return `void` though `gh`/`glab` print the created URL; selection becomes `ForgeNothingSel` | Parse the printed URL for number/iid and `_select` |
| M23 | GitLab jobs do not poll; GH PR checks pick one run per branch | `pipeline_jobs_view.dart`; `github_panel.dart` newest run per `headBranch` | Poll jobs; match PR head SHA |
| M24 | Remote-edit misses atomic saves; conflict can re-open on autosave | Watch is `modify` only; many editors write temp+rename | Watch parent dir; pause after dismiss |
| M25 | Detached Status treats local repos as SSH for Open/Reveal | Secondary does not override `connectionProvider`, whose backend defaults to SSH (`app_providers.dart:739`); viewer “Open in Default App” gates on the same `isLocal` | Gate on `windowSessionProvider.backend` |
| M26 | Detached FileView uses `TransparentMacOSSidebar` | Forbidden in secondary (`secondary_window_main.dart` comment) | Opaque pane when not the main window |
| M27 | Help Book is broadly stale (landing, reconnect, chords) | `help_book.json` vs live landing / overlay / keymap (⌘P, ⌘⇧O, ⌘S, ⌘⇧Y, ⌘?) | Generate shortcuts from `kKeymapActions`; rewrite Getting Started |
| M28 | Settings auto-fetch can silently turn a custom interval Off | Choices `{0,5,10,15,30}` (`settings_sheet.dart:50`); initState coerces an unseen stored value to 0 (`:67-69`) and Save persists it | Include the stored value, or persist only on explicit change |
| M29 | Clone/Create can leak a provisioned SSH session | `dispose` does not abort (Add Existing does) | Same dispose / mid-dial abort as `AddExistingRepoSheet` |
| M30 | Remote directory browser copy says double-click; rows navigate on single tap | `remote_directory_browser.dart:156-159,263-266` | Match copy to single-tap, or implement select vs enter |
| M31 | Overview worktree selection is invisible | Row tint is `open` (tab), not `_selectedOverviewPath` | Highlight the keymap operand |
| M32 | Recovery snapshot fetch failure looks like “no snapshots” | `snapshotsAsync.value ?? const []` | `when` + `displayError` |
| M33 | Dashboard “year” heatmap is last ~200 commits | `logProvider` `maxCount = 200` into a 53-week grid | Dedicated `--since` walk, or honest caption |
| M34 | Markdown preview links look live and do nothing | `preview_view.dart` styled `a:` + empty `onTapLink` (M11 residual) | Caption, or “open in browser” |

---

### LOW — polish and known residuals

| ID | Item | Notes |
| --- | --- | --- |
| L1 | Redo empty journal is silent; undo toasts | Mirror “Nothing to undo” (`app_shell.dart:552-555` vs `:602-604`) |
| L2 | Tab close control is not its own accessible action | Chip wraps activate + dirty + close |
| L3 | 0006 hybrid title bar still off | `TitleBarStyle.hidden`; not a new proposal |
| L4 | Inspector slot never populated | `inspector:` unused; Investigate preset / `global.focusInspector` inert by design (0008 out of scope) |
| L5 | `history.amend` not HEAD-gated | Palette can amend real HEAD while a non-HEAD row is selected |
| L6 | History has no native menu; revert/reset are context-only | 0008 second-route gap |
| L7 | Binary conflict string “Use Use Ours / Use Theirs above” | Leftover doubling in `conflict_view.dart:158-159` |
| L8 | Stage All button stays enabled when there is nothing to stage | Keymap already nulls; button does not |
| L9 | File-tree Delete copy says permanent; service records undo | Match discard copy |
| L10 | Status-list tooltips omit real shortcuts | Space / ⌘G / ⌘⌥S |
| L11 | Labels are honestly view-only | 0007 “missing caption” is stale; keep |
| L12 | GH live job logs still a placeholder | 0004 M10; documented |
| L13 | Viewer L7 residuals | Trailing newline, `itemExtent`, overlong-line highlight kill, `SelectionArea` — `viewer_engine_findings.md` |
| L14 | Diff pop-out is in-window float | 0004 L6 accepted |
| L15 | No worktree drag source | Docs already list as later |
| L16 | Saved-workspace name dialog disposes controller on pop | Use `promptText` |
| L17 | Settings “apply after Save” vs immediate keymap / forget-host | Disclose, or one transaction |
| L18 | Connection forms: no Enter-to-submit; disabled button has no field reason | Match wizard `onSubmitted` |
| L19 | Stash empty-state copy points at “the menu” | Primary CTA is the context bar |
| L20 | Worktrees overview has no arrow-key list nav | History/Branches/Stash do |
| L21 | Sparse Semantics outside chrome / branch rows | M14 residual on lists |
| L22 | `executeStream` is an explicit proxy hole | Fine today; crash if a pop-out later streams |

---

### What looks solid (do not re-open as bugs)

* **0004 HIGH track (H1–H8)** — worktrees index 5; branch keymap handlers
  exist; rebase range-fetch surfaces `displayError`; remote-edit *sync*
  notices; `uploadBytes` proxied; `displayError` on major panel errors;
  GPG `--no-gpg-sign` caption when config is true; dirty logout / tab-close
  via `confirmSessionExit` (window-close is M5, not a regression of H8’s
  stated scope).
* **0004 LOW L1 / L2 / L3 / L5** — empty-undo toast; tab middle-click +
  dirty badge; rebase reword footnote; hunk-staging banners.
* **Shared file selection (0004 M13 / 0007 “missing”)** —
  `repoFileSelectionProvider` is real. Residual is H5 (tree → conflict).
* **Stash `--include-untracked`** — unified; Apply latest vs selected is
  labeled, not a silent divergence.
* **Worktree Repair operand** — per-tree vs “Repair all worktree links.”
* **Host-key dialog** — `barrierDismissible: false` + fail-closed
  `rejectHostKeyChange` in `.then`.
* **Page-index lockstep** — sidebar / `IndexedStack` / `DropZoneId` /
  `global.panel1`–`panel6` / `kWorktreesPageIndex = 5`.
* **Palette → `PaletteIntent` → `PanelShortcuts`** — right shape when the
  panel is mounted; yields to `EditableText` / `SelectionArea`.
* **DnD A–E including History E1/E2** — in-panel menus and confirms exist
  (H17 is the remaining ESC hole on *branch rows*).
* **Forge comments** — list + post + invalidate on issues and PRs/MRs
  (H11 is the leftover mutation-cache hole, not write-only UI).
* **Labels “view only”** — caption present; chips non-interactive.
* **Palette-row Semantics** — `palette_row_semantics.dart` +
  `command_palette.dart` `Semantics`.
* **Zoom-reset glyph** — `CupertinoIcons.fullscreen_exit`, not a third
  magnifier.

---

### Suggested remediation order (when scheduled)

1. **H17** ESC guard on branch-row drops (one-line, destructive).
2. **H18** Help ⌘⇧B (or generate Help from keymap) — destructive surprise.
3. **H7** hide-reviewed wiring (toggle already exists).
4. **H4** drop `!isHead` on publish / create-request.
5. **H2** keep `PanelShortcuts` on worktree tabs.
6. **H1** menu enablement across panels (makes 0008’s menu real).
7. **H5 / H6 / H9** conflict pane + mark-resolved + review surface.
8. **H8** bind `commit.*` on the live composer.
9. **H10 / H11 / H12 / H13** forge honesty (flash, stale detail, `main`,
   releases).
10. **H3** location adapters (unblocks Back/Forward and palette entities).
11. **H14 / H15 / H16 / M24 / M25** secondary-window + remote-edit open.
12. **H19 / H20** clone/create success and mid-flight Escape.
13. **M5** quit / window-close dirty guard.
14. **M1–M4, M6–M8** palette/menu/activity/chrome honesty.
15. Remaining MED, then LOW only when adjacent work touches them.

0006 title bar (L3) and remaining 0008 geometry stay on those records.

### Related documents

* [0004-MADR-ui-ux-deep-debug-audit.md](0004-MADR-ui-ux-deep-debug-audit.md) —
  previous cycle; HIGH track closed.
* [0004-PLAN-ui-ux-deep-debug-audit.md](0004-PLAN-ui-ux-deep-debug-audit.md) —
  historical delivery; do not reopen its phases.
* [0006-MADR-hybrid-native-title-bar-context-bar.md](0006-MADR-hybrid-native-title-bar-context-bar.md)
  / [0006-PLAN-hybrid-native-title-bar-context-bar.md](0006-PLAN-hybrid-native-title-bar-context-bar.md)
  — title bar still gated.
* [0008-MADR-unified-repository-chrome.md](0008-MADR-unified-repository-chrome.md)
  / [0008-PLAN-unified-repository-chrome.md](0008-PLAN-unified-repository-chrome.md)
  — chrome architecture; this record owns *correctness of what shipped*.
* [0007-MADR-docs-completion-audit.md](0007-MADR-docs-completion-audit.md) —
  several “claimed complete but missing” items have since landed (see
  “looks solid”).
* `docs/DRAG_AND_DROP_ENGINE.md` — A–E shipped; H17 is the live residual.
* `docs/viewer_engine_findings.md` — L13.

### Remediation log

| Date | Change |
| --- | --- |
| 2026-08-15 | Initial pass recorded; status `proposed` pending maintainer review. Static verification only; no production code changed. |
| 2026-08-15 | Companion [0009-PLAN-ui-ux-debug-pass-backlog.md](0009-PLAN-ui-ux-debug-pass-backlog.md) written for review (phased HIGH→MED→LOW delivery; product gates locked in the plan). |
| 2026-08-15 | Six-agent re-verification against `master` `c79977c`. Corrections: H4 mirror-comment is at `:766-768`; H10 strip condition has three conjuncts and the More pulldown also uses a list-tier plan; H15 call sites are sync fire-and-forget; M5 line refs; M17 porcelain `<sub>` field unparsed (status parsing has no `isSubmodule`); M21 `supportsAdminBypass` is GitHub-side only; M22 CLIs print a URL, not a bare number; M25/M28 evidence precision; remediation-order typo H24/H25 → M24/M25. All 20 HIGH defects confirmed real. |
| 2026-08-15 | Phase 0 remediated: H17 (ESC-cancelled drops on branch rows now no-op), H18 (Help teaches ⌘⇧B as Checkout Selected Commit), H7 (reviewed identities wired into `filterRepoChangeRows`), H4 (HEAD can publish / create request from menu, keys, palette). |
| 2026-08-15 | Phase 1 remediated: H2 (one `PanelShortcuts` above the worktree tab/overview fork — checkout tabs keep add/repairAll/prune and bind the per-tree verbs to the open checkout), M31 (overview tint follows the selected row; open tabs get an "open" chip). |
| 2026-08-15 | Phase 2 remediated: H1 (`kCrossPanelMenuActionIds` + `AvailableActions.publishSession` — a connected session enables cross-panel menu verbs; host-specific create verbs gated on detected forge; selection-gated verbs stay panel-owned; Swift enablement comment updated). |
| 2026-08-15 | Phase 3 remediated: H5 (tree opens unmerged paths on the conflict pane via a `conflict` flag on `OpenFileCallback`), H6 (Mark Resolved = existing `git.stage` on the conflict toolbar, conflict context menu, and file tree), H9 (multi-file review renders conflicts in `ConflictView` with Use Ours/Theirs/Mark Resolved), M15 (`conflictSideLabels` says Onto/Commit during a rebase), L7 (binary-conflict copy fixed). |
| 2026-08-15 | Phase 4 remediated: H8 (`CommitComposer` binds `commit.confirm`/`commit.confirmAndPush` via the live keymap; `repository.focusCommit` relabeled "Focus commit composer"), M12 (Space/discard chords act on multi-selections through the context menu's bulk helpers), L8 (Stage All button gated like its shortcut). |
| 2026-08-15 | Phase 5 remediated: H10 (Checking wins over any list-tier plan; Merge/auto-merge/Admin-merge hidden while detail loads), H11 (`_invalidateChangeRequest` refreshes list+detail+comments after approve/draft/edit/request-changes on both forges), H12 (create forms prefill base/target from the merge policy's default branch; 'main' is last-resort), H13 (release detail also resolves from the expanded REST list), M6 (forge Branch slot names the real HEAD; ahead/behind only printed with an upstream), M19 (scaffold renders Retry), M22 (create services return the number/iid parsed from the printed URL; panels select the new PR/MR/issue). |
| 2026-08-15 | Phase 6 remediated: H3 (`reveal()` sets pending; adapters on all six screens apply restored/palette locations once data lands — with a stale-echo guard so a screen's post-frame re-visit can't undo a Back; palette entities now select the object), M7 (palette hint no longer advertises `issue:`/`request:`/`ci:`), M9 ("Compare Changes" in Review reads "Comparing changes" instead of a silent no-op button). |
| 2026-08-15 | Phase 7 remediated: H14 (`ViewerHost` stacked in the secondary shell), H15 (`openRemoteFile` never throws — failures land on the notice like sync's; a latent onDispose state-read fixed en route), H16 (Swift key-window observer strips this window's menu key equivalents while a pop-out is key; restored on regain), M24 (scratch-dir watch catches atomic temp+rename saves; a declined conflict is not re-asked for identical bytes), M25 (`WindowConnection` projects the wire backend so detached local repos get local affordances), M26 (`SecondaryWindowScope` swaps the vibrancy sidebar for an opaque pane in pop-outs). |
| 2026-08-15 | Phase 8 remediated: H19 (`registerAndActivate*` / clone & create `_register` return success; failures show an error instead of green Complete), H20 (Escape/title-X ignored while a create is submitting), M29 (clone/create dispose + unmounted-dial races abort provisioning), M30 (remote browser copy matches its single-click behavior). |
| 2026-08-15 | Phase 9 remediated: M5 (⌘Q and the red button show ONE at-stake summary — `sessionsAtRisk` + `sessionExitSummaryMessage`; native terminate is declinable via a bool reply + `terminateNow` re-entry; reconnect-overlay Cancel confirms when status is readable; `confirmSessionExit` gained an explicit confirmLabel), L1 (empty redo journal toasts "Nothing to redo"). |
| 2026-08-15 | Phase 10 remediated: M1 (palette catalog derived from `kPanelActionOwner` — the eight menu-only repository verbs now searchable), M2 (`setViewMenuShortcuts` pushes live keymap bindings to the native View items; re-pushed on every persisted rebind), M3 (Activity sheet watches the provider live, Escape-dismissible; Reveal pops first; Undo only on the newest undoable record via the `global.undo` route; Recovery wired), M4 (File ▸ New Tab / Close Tab via the generic menu builder, positioned after the app menu; shell-routed `global.*` menu ids legitimized), M27 (Help: quickstart rewritten to the real landing/PEM/overlay flows; bogus ⌘⇧C/⌘⇧O/⌘S/⌘? chords fixed; version 1.1; test audits EVERY chord against keymap defaults), M28 (custom auto-fetch interval listed and preserved instead of coerced to Off). |
| 2026-08-15 | Phase 11 remediated: M10 (History drop merge/rebase confirm with Branches-parity copy), M11 (checkout prefers the local branch at that OID — honest confirm, no needless detached HEAD), M13 (Review all visible walks every visible section), M14 (`mergeContinue`/`cherryPickContinue`/`revertContinue` + a Continue button for every pending op; composer prefills the prepared `MERGE_MSG`/`rebase-merge/message` over generation via `pendingCommitMessage`), M16 (pop-out gains image routing, line-selection staging, and a live shared context toggle), M17 (LFS pointers named honestly in the image comparison; submodule rows badged — the porcelain `sub` field was already parsed, contrary to the audit note), M18 (`displayError` in the composer controller and multi-file review), M20 (`ForgeListError` auth callout + Open Dashboard link on gh/glab list failures), M21 (GitLab `userCanMerge == false` hard-blocks; GitHub Admin-merge pulldown removed — no real capability bit exists), M23 (GitLab jobs auto-poll while live; GitHub PR checks prefer the head-SHA run over the branch-name match), M32 (snapshot load errors shown, never the empty state), M33 (heatmap caption scoped to "last 200 commits"), M34 (Markdown preview web links open externally; other schemes stay inert). |
| 2026-08-15 | Phase 12 (partial) remediated: L2 (tab close button has its own Semantics node + "Close tab" tooltip), L5 (`history.amend` handler HEAD-gated like the row menu — a non-HEAD selection disables it), L9 (file-tree Delete copy matches the discard convention — snapshot + ⌘Z — since the service records undo), L10 (Stage/Unstage, split-diff, and Commit… affordances teach their live keymap bindings in tooltips), L16 (saved-workspace name and rename-tab dialogs use the shared `promptText` sheet, which owns its controller; `promptText` gained `allowEmpty` so a confirmed blank still means "clear the alias"). Outstanding: L17, L18, L19, L20. |
