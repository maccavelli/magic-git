---
status: "complete"
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

Out of scope: the MADR's "More Information" list (wording and palette items). ~~And option 4B
(folding `$HOME` into the environment probe).~~ **4B is in scope by D2 (Phase 6).**

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

### Phase 6 — `$HOME` from the environment probe (D2; MADR Amendment 0071.1)

1. `lib/core/ssh/environment_probe.dart`: the probe script prints `HOME=$HOME`;
   `RemoteEnvironment` gains `home` (absolute, else null), carried by `withVersions`;
   `resolve` runs from `/` and no longer takes a path.
2. `lib/core/providers/app_providers.dart`: `_resolveEnvironment` takes no path and returns the
   environment it installed (the cache on a same-host reconnect), or null when detection
   failed. `connect` runs it first inside the cmd.exe handler, then expands `~` paths from
   its `home`, throwing `HomePathUnresolved` when `home` is null. `_remoteHome` is removed.
   The provisioning and `reprobeBinaries` callers drop their path argument.
3. Tests, `test/connection_env_reset_test.dart`: the fake probe reports `HOME=`. The `~` group
   asserts one POSIX command before validation (the probe, from `/`), no separate `$HOME`
   lookup, expansion from the probe's `home`, and the honest failure when `home` is empty.
   The Phase 4 Windows case must still pass unchanged. Any other test that pinned the
   probe's directory is updated to `/`, and listed in the execution record.
4. Mutations: the probe without `HOME=` → the `~` tests; `~` expansion before the probe →
   the Windows `~` case; the probe run from the repository path → the from-`/` assertion.
5. `flutter analyze`, the full suite, the records check; the plan back to `complete`.
6. Commit, then push everything (the maintainer asked for both).

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

* **D2 (2026-09-24), option 4B brought into scope.** After Phase 5, the maintainer asked for
  the `$HOME` lookup to move into the environment probe. It changes defect 4's decision, so
  the MADR carries Amendment 0071.1, and Phase 6 is added. The plan returns to `in-progress`
  until Phase 6 lands. Files added to scope: `lib/core/ssh/environment_probe.dart`.

### Phase 0 (2026-09-24)

* MADR 0071 `accepted`, this plan `in-progress`, the index row added. Records check: 0
  findings.
* The reproduction tests applied to the tree unchanged from the scratch run.
  Run in the tree, exactly the five new tests failed, each on its own assertion.

### Phase 1 (2026-09-24), defects 1 and 5 — commit `ce5cf4e`

* `add_worktree_sheet.dart`: `WorktreeStart` (`CheckOutBranch`, `NewBranchAt`) replaces
  `initialCommitish` / `initialBranchName`. Existing branch is valid only for a branch in
  `_offered`, the set the popup shows. The fields scroll inside `Flexible`; the action row is
  pinned below them.
* Callers: `drop_registry.dart` (`_worktreeStartFor`: a local branch, a remote branch, any other
  ref; and a commit), `history_view.dart`, and both `branches_view.dart` sites. No reference to
  the old parameters remains in `lib/` or `test/`.
* `help_book.json` `drag_and_drop`: what each drop on Worktrees does.
* Tests: the commit drop (Phase 0); a remote-branch drop (New branch, named `feat/login`); a
  local-branch drop (Existing branch); in `add_worktree_sheet_test`, Create Worktree disabled for
  a branch the popup does not offer, and the 640x480 case.
* `flutter analyze`: No issues found. `navdrop_dispatch_test` + `add_worktree_sheet_test`:
  `+16: All tests passed!`. Full suite: only the four reproduction tests of defects 2-4 failed,
  as expected before their phases.
* **Two slips in the commit itself.** This record was meant to land with `ce5cf4e`; the edit
  that wrote it was blocked, and the commit had been issued alongside it, so it went out without
  this entry. It lands in the next phase's commit instead (no amend, by rule). And the
  hook-generated message of `ce5cf4e` names all five fixes, because the MADR and plan it carries
  describe them; its code fixes defects 1 and 5 only.

### Phases 2 and 3 (2026-09-24), defects 2 and 3 — one commit (D1)

* `github_panel.dart` and `gitlab_panel.dart`: the Inbox lists a change request only when
  `forgeChangeRequestIsOpen(state)`.
* `gitlab_panel.dart`: the pipeline detail title uses `prettyPipelineRef`; the Pipelines filter
  matches the pretty name as well as the raw ref, sha and status.
* `flutter analyze`: No issues found. `forge_inbox_test` + `gitlab_panel_test`:
  `+25: All tests passed!`.
* This commit also carries the Phase 1 record above.

### Phase 4 (2026-09-24), defect 4

* `app_providers.dart`: `_remoteHome` throws `CmdExeShellDetected` when the lookup fails with
  cmd.exe's rejection (`looksLikeCmdExe`). In `connect`, the `~` expansion moved inside the
  `try … on CmdExeShellDetected` that already wrapped the environment probe, so the forced
  Windows check covers whichever POSIX command runs first.
* `flutter analyze`: No issues found. `connection_env_reset_test` + `home_path_test`:
  `+18: All tests passed!` (the new case, and the existing Windows and `~` cases).

### Phase 5 (2026-09-24), proof and records

* Mutation runs in a scratch clone of `7847808`. Baseline over the five test files first:
  `+56: All tests passed!`. Then each mutation, alone, against its named tests; every one failed
  on its own assertion, none on a compile error:

  | Mutation | Test that failed | Assertion |
  |---|---|---|
  | M1 a dropped commit becomes `CheckOutBranch` | commit drop on Worktrees | "New branch name" not found |
  | M2 Existing branch valid when not offered | branch checked out elsewhere | Create Worktree enabled |
  | M3 the action row back inside the scroll view | the smallest window | Create Worktree bottom 593 > 480 |
  | M4 GitHub Inbox without the open filter | closed and merged pull requests | "Abandoned idea" listed |
  | M5 GitLab Inbox without the open filter | closed and merged merge requests | "Abandoned idea" listed |
  | M6 raw ref in the pipeline title | MR pipeline | "Pipeline #102  ·  MR !7" not found (line 353) |
  | M7 filter without the pretty name | MR pipeline | "MR !7" row filtered out (line 364) |
  | M8 the `~` block outside the `try` | `~` path on a hidden-banner host | no Windows prompt |
  | M9 `_remoteHome` without the cmd.exe check | `~` path on a hidden-banner host | no Windows prompt |

* At `7847808`: `flutter analyze` No issues found; full suite `03:00 +4407 ~3: All tests
  passed!`; `dart run scripts/tools/records.dart check` 0 findings.
* Every acceptance criterion is met. Plan `complete`; MADR 0071 stays `accepted`.

### Phase 6 (2026-09-24), `$HOME` from the environment probe (D2; Amendment 0071.1)

* `environment_probe.dart`: the script prints `HOME=$HOME`; `RemoteEnvironment.home` holds it
  when absolute, else null; `withVersions` keeps it, and a new `withPath` replaces the
  hand-written copy in `app_providers.dart` that would have dropped it. `resolve` takes no path
  and runs from `/`.
* `app_providers.dart`: `_resolveEnvironment` takes no path and returns what it installed (the
  cache on a same-host reconnect) or null. `connect` runs it first, inside the cmd.exe handler,
  then expands `~` from its `home`, else `HomePathUnresolved`. `_remoteHome` is gone. The local
  backend, provisioning and `reprobeBinaries` callers drop their path argument.
* Tests: `environment_probe_test` (HOME parsed from `/`, only absolute, kept by `withVersions`
  and `withPath`; the script prints it) and `connection_env_reset_test` (one POSIX command
  before validation, the probe from `/`; no separate lookup; the empty-HOME failure). Four more
  files only drop the argument `resolve` no longer takes: `create_repo_wire_live_test`,
  `namespace_recency_live_test`, `project_issue_wire_live_test` (live-forge; compiled by
  `flutter analyze`, not run) and `ssh_live_transport_test`. No other test pinned the probe's
  directory.
* Mutations, in a scratch clone of `7f013e4` plus this phase's files; baseline `+35: All tests
  passed!`. Each caught on an assertion, none on a compile error:

  | Mutation | Failed |
  |---|---|
  | P1 the script without `HOME=` | the probe script prints HOME |
  | P2 the parser ignores `HOME=` | HOME parsed; `~` expanded from the probe |
  | P3 a separate `$HOME` lookup comes back | the `~` group (3) and both Windows cases |
  | P4 the probe runs from `.` | HOME from `/`; `~` expanded; probe from `/` |
  | P5 `withPath` drops `home` | HOME kept by `withPath` |

  The Phase 5 mutations M8 and M9 targeted code this phase removed; P3 now guards the same
  ordering.
* `flutter analyze`: No issues found. Full suite: `03:08 +4409 ~3: All tests passed!`. Records
  check: 0 findings.
* Plan `complete` again.
