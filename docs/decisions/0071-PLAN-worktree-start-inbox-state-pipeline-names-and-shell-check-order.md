---
status: "in-progress"
date: 2026-09-24
associated-madr: "0071-MADR-worktree-start-inbox-state-pipeline-names-and-shell-check-order.md"
verified: 2026-09-24
---

# Implement: worktree start, Inbox state, pipeline names, and the shell check order

Associated MADR:
[0071-MADR-worktree-start-inbox-state-pipeline-names-and-shell-check-order.md](0071-MADR-worktree-start-inbox-state-pipeline-names-and-shell-check-order.md)

## Goal

Fix the five defects the MADR records, each at its source, each with a regression test that is
seen to fail without the fix:

1. A commit (or a remote branch) dropped on Worktrees opens Add Worktree as "Existing branch".
2. Closed and merged requests appear in the Forge Inbox.
3. A GitLab merge-request pipeline shows its raw ref in the detail title, and the filter cannot
   find it by the name its row shows.
4. A `~` repository path hides a Windows host whose SSH banner does not say Windows.
5. Add Worktree cuts off its buttons in a window shorter than about 610 px.

## Scope

In scope, by file:

| File | Defects |
|---|---|
| `lib/features/worktrees/add_worktree_sheet.dart` | 1, 5 |
| `lib/features/dnd/drop_registry.dart` | 1 |
| `lib/features/history/history_view.dart` | 1 (caller) |
| `lib/features/branches/branches_view.dart` | 1 (two callers) |
| `lib/features/github/github_panel.dart` | 2 |
| `lib/features/gitlab/gitlab_panel.dart` | 2, 3 |
| `lib/core/providers/app_providers.dart` | 4 |
| `macos/Runner/help_book.json` | 1 (the drag-and-drop line) |
| `test/navdrop_dispatch_test.dart` | 1 |
| `test/add_worktree_sheet_test.dart` | 1, 5 |
| `test/forge_inbox_test.dart` | 2 |
| `test/gitlab_panel_test.dart` | 2, 3 |
| `test/connection_env_reset_test.dart` | 4 |
| `docs/README.md`, this plan, the MADR | records |

Out of scope: the MADR's "More Information" list (wording and palette items), and option 4B
(folding `$HOME` into the environment probe).

## Facts established before writing this plan (2026-09-24)

* Every defect was reproduced on `28e9f84` in a scratch clone. The same test edits, applied to
  the unmodified code, fail on their own assertions with no compile errors and no other test
  disturbed:
  * `navdrop_dispatch_test`: "New branch name" not found after a commit drop (defect 1); the run
    also reports a 53 px overflow of the sheet in the 800×600 view (defect 5).
  * `forge_inbox_test` and `gitlab_panel_test`: "Abandoned idea" (a closed request) is listed in
    the Inbox (defect 2).
  * `gitlab_panel_test`: no widget reads "Pipeline #102  ·  MR !7" (defect 3).
  * `connection_env_reset_test`: `windowsShellPrompt` is null (defect 4).
* The app's smallest window is 640×480 (`WindowBoundsStore.minWidth`/`minHeight`).
* The test edits live in the session scratchpad as an anchored patch script, applied unchanged in
  Phase 0.

## Implementation Steps

### Phase 0 — Records and the failing tests

1. MADR 0071 `status: accepted` (the maintainer's instruction: write the MADR and plan, then
   execute); this plan `in-progress`; a row in `docs/README.md`.
2. Apply the reproduction tests to the tree. Confirm each fails on its own assertion.
3. ~~No commit: a commit with failing tests would fail the gate. Phase 0's files join Phase 1's
   commit.~~ **Replaced by D1:** no commit in Phase 0. Each phase commits its fix with its own
   reproduction test, so every commit passes the suite.

### Phase 1 — Say what you mean to the worktree sheet (defects 1 and 5)

1. In `add_worktree_sheet.dart`, replace `initialCommitish` / `initialBranchName` with:

   ```dart
   sealed class WorktreeStart { const WorktreeStart(); }

   /// Check out an existing local branch in the new worktree.
   final class CheckOutBranch extends WorktreeStart {
     const CheckOutBranch(this.branch);
     final String branch;
   }

   /// A new branch at [startPoint] (a commit, tag or branch; null is HEAD),
   /// named [name] — empty when the user is to type it.
   final class NewBranchAt extends WorktreeStart {
     const NewBranchAt({this.startPoint, this.name = ''});
     final String? startPoint;
     final String name;
   }
   ```

   `AddWorktreeSheet({required repoPath, WorktreeStart? start})`; a null start is the blank sheet
   (New branch at HEAD), as today.
2. `initState` switches on the start: `CheckOutBranch` selects Existing branch with that branch;
   `NewBranchAt` selects New branch, with the start point and the name. The `_revision` field
   keeps its current seeding.
3. Validity follows the popup. Existing branch is valid only when the chosen branch is one of the
   offered branches (local, not checked out elsewhere). The same list feeds the popup, `_valid` and
   `_submit`, so nothing can be submitted that is not shown.
4. Layout: the fields go into `Flexible(SingleChildScrollView(...))`; the Cancel / Create
   Worktree row stays outside it, pinned, as in `local_repo_form.dart:874-895`.
5. Callers:
   * `drop_registry.dart`: a local branch → `CheckOutBranch(shortName)`; a remote branch →
     `NewBranchAt(startPoint: shortName, name: remoteLocalName(shortName))`; any other ref →
     `NewBranchAt(startPoint: shortName)`; a commit → `NewBranchAt(startPoint: hash)`.
   * `history_view.dart` `_actWorktreeFrom` → `NewBranchAt(startPoint: hash)`.
   * `branches_view.dart` `_checkoutInNewWorktree` → `CheckOutBranch(branch)`; the new-branch
     "New worktree" path → `NewBranchAt(startPoint: start == 'HEAD' ? null : start, name: name)`.
6. Tests:
   * `navdrop_dispatch_test`: the commit-drop case (Phase 0), plus a remote-branch drop that
     opens New branch with the local name prefilled.
   * `add_worktree_sheet_test`: the helper takes `start:`; existing cases keep their meaning. New
     cases: an Existing branch that is not offered leaves Create Worktree disabled; at 640×480 the
     sheet raises no overflow and Create Worktree lies inside the window.
7. `help_book.json`, `drag_and_drop`: say what each drop does. A local branch opens Add Worktree
   checking it out; a commit or a remote branch opens it on a new branch that starts there.
8. Commit.

### Phase 2 — The Inbox is open work (defect 2)

1. `github_panel.dart` `_inboxChildren` and `gitlab_panel.dart`'s Inbox builder: list a change
   request only when `forgeChangeRequestIsOpen(state)`.
2. Tests (Phase 0) pass.
3. ~~Commit.~~ **D1:** committed with Phase 3, because both phases'
   tests are in `test/gitlab_panel_test.dart`.

### Phase 3 — One name for an MR pipeline (defect 3)

1. `gitlab_panel.dart`: the detail title uses `prettyPipelineRef(pipeline.ref)`; the Pipelines
   filter matches `prettyPipelineRef(p.ref)` as well as the raw ref, sha and status.
2. Test (Phase 0) passes.
3. Commit, with Phase 2 (D1).

### Phase 4 — Check the shell before the first POSIX command (defect 4)

1. `_remoteHome`: when the lookup fails and `looksLikeCmdExe(stderr)`, throw
   `CmdExeShellDetected(stderr)`.
2. `connect`: move the `~` expansion inside the existing `try … on CmdExeShellDetected`, so the
   `$HOME` lookup and the environment probe share the forced Windows check.
3. Test (Phase 0) passes. The existing Windows and `~` tests still pass.
4. Commit.

### Phase 5 — Proof and records

1. Mutation runs in a scratch clone (baseline first). Each must fail the named tests:
   * pre-fix `drop_registry.dart` mapping (a commit as `CheckOutBranch`) → the drop test;
   * `_valid` accepting any non-null Existing branch → the not-offered test;
   * the action row moved back inside the scroll view → the 640×480 test;
   * the Inbox's open filter removed, each forge → the Inbox tests;
   * the raw ref in the title → the pipeline test;
   * the filter without the pretty name → the pipeline test;
   * the `~` block outside the `try` → the Windows `~` test;
   * `_remoteHome` without the cmd.exe check → the Windows `~` test.
2. `flutter analyze`; full `flutter test`; `dart run scripts/tools/records.dart check`.
3. Records: this plan `complete`, with the execution record; the MADR stays `accepted`.
4. Commit.

## Verification

```sh
flutter analyze
flutter test test/navdrop_dispatch_test.dart test/add_worktree_sheet_test.dart \
  test/forge_inbox_test.dart test/gitlab_panel_test.dart test/connection_env_reset_test.dart
flutter test
dart run scripts/tools/records.dart check
```

## Acceptance Criteria

* Dropping a commit on Worktrees opens Add Worktree on New branch, starting at the commit.
* Dropping a remote branch opens it on New branch, named after the remote branch.
* Dropping a local branch opens it checking that branch out.
* Add Worktree never enables Create Worktree for an Existing branch it does not show.
* At 640×480 the sheet raises no overflow, and Create Worktree is inside the window.
* The Inbox lists only open pull and merge requests, whatever Browse shows.
* A merge-request pipeline's detail title reads "Pipeline #N  ·  MR !M", and filtering by "!M"
  keeps its row.
* With a hidden banner, cmd.exe as the shell and a `~` path, the connect shows the Git Bash
  prompt.
* Every new test was seen to fail against the pre-fix code or a mutation.
* `flutter analyze` clean; the full suite passes; the records check reports 0 findings.

## Rollout and Rollback

Each phase is one commit and reverts on its own. Phase 1 changes a widget constructor that only
this repository calls, so a revert of Phase 1 restores the old constructor and its callers together.
No settings, storage or wire formats change.

## Execution record

### Deviations

* **D1 (2026-09-24), commit split.** Found before Phase 1: step 0.3 had Phase 1's commit carry
  every reproduction test, which would commit failing tests for defects 2-4. Its stated
  reason was also wrong: the pre-commit gate runs format and analyze, not the suite. The
  maintainer chose: each phase commits its fix with its own test; Phases 2 and 3 share one
  commit because their tests share `test/gitlab_panel_test.dart`. No file is added to scope;
  the MADR is unaffected.

### Phase 0 (2026-09-24)

* MADR 0071 `accepted`, this plan `in-progress`, the index row added. Records check: 0
  findings.
* The reproduction tests applied to the tree unchanged from the scratch run.
