---
status: "accepted"
date: 2026-09-24
decision-makers: [Maintainer]
consulted: [the 2026-09-24 help-book audit (panels and troubleshooting sweeps), reproductions of every defect in a scratch clone of 28e9f84]
informed: [Magic Git contributors]
verified: 2026-09-24
---

# Say what you mean to the worktree sheet, keep the Inbox to open work, name MR pipelines everywhere, and check the shell before the first POSIX command

## Context and Problem Statement

The help-book audit of 2026-09-24 listed four suspected defects that no one had reproduced. Each is
now reproduced by a test that fails on the unmodified code (commit `28e9f84`), in a scratch clone.
A fifth defect turned up while reproducing the first. The maintainer asked for all five to be fixed
under one record.

### 1. A commit dropped on Worktrees opens the sheet as "Existing branch"

`AddWorktreeSheet` takes two optional strings and reads meaning into their combination
(`lib/features/worktrees/add_worktree_sheet.dart:117-125`):

```dart
if (widget.initialCommitish != null && widget.initialBranchName == null) {
  _basis = _Basis.existingBranch;
  _existingBranch = widget.initialCommitish;
}
```

A starting point with no branch name is taken to be *a branch to check out*. History knows this
and passes `initialBranchName: ''` precisely so the sheet opens on New branch
(`lib/features/history/history_view.dart:862-867`, whose comment says so). The Worktrees drop does
not: `_newWorktreeFrom` passes only `initialCommitish` for both a dropped branch and a dropped
commit (`lib/features/dnd/drop_registry.dart:97-118`, `:305-313`). A dropped commit therefore
opens as Existing branch with the commit hash as the branch.

The sheet then compounds it. Its popup shows `_existingBranch` only when that branch is on offer
(`add_worktree_sheet.dart:510-512`), but `_valid` accepts any non-null value (`:190`). So the
sheet shows **no selection** and still enables **Create Worktree**, and submitting runs
`git worktree add <path> <hash>` (`:296-301`). git accepts a commit there and creates a
**detached** worktree, in a folder named `<repo>-<40-character hash>`, from a sheet that said
"Existing branch".

The same path is reachable two more ways. A **remote branch** can be dragged (History ref chips,
`lib/features/history/ref_chip.dart:184`), and on Worktrees it lands in Existing branch mode as
`origin/foo`, again detaching. A **local branch already checked out** in another worktree is not
offered by the popup (`:470`) but can still arrive as the initial value.

**Reproduced.** Dropping a commit on the Worktrees rail item (`test/navdrop_dispatch_test.dart`)
opens Add Worktree without its "New branch name" field.

### 2. Closed and merged requests appear in the Inbox

Browse and the Inbox read one list: `pullRequestsProvider` / `mergeRequestsProvider`. "Show
closed pull requests" (or merge requests) widens that list through `includeClosed`
(`lib/core/providers/app_providers.dart:6442-6448`, `:5922`). The Inbox builders iterate it with no
state test (`lib/features/github/github_panel.dart:489-505`,
`lib/features/gitlab/gitlab_panel.dart:525-541`), so once Browse shows closed requests the Inbox
lists closed and merged ones as work to do. A shared helper that answers "is this change request
open?" for both forges' spellings already exists, `forgeChangeRequestIsOpen`
(`lib/features/forge/issue_actions.dart:32`); the Inbox never calls it.

**Reproduced** on both forges (`test/forge_inbox_test.dart`, `test/gitlab_panel_test.dart`): a
closed and a merged request are listed in the Inbox.

### 3. A merge-request pipeline is named by its raw ref in its detail pane

GitLab runs merge-request pipelines on synthetic refs, `refs/merge-requests/<iid>/head` or
`/merge`. `prettyPipelineRef` decodes them to "MR !N" (`gitlab_panel.dart:44-54`) and the list
row uses it (`:768`). The detail title does not: `'Pipeline #$pipelineId  ·  ${pipeline.ref}'`
(`:845`). The Pipelines filter matches the raw ref only (`:362`), so typing the "!7" the row
shows finds nothing.

**Reproduced** (`test/gitlab_panel_test.dart`): the title shows `refs/merge-requests/7/head`, and
filtering by "!7" removes the row.

### 4. A `~` path can hide a Windows host whose banner does not say Windows

MADR 0070 detects a Windows host from the SSH banner, with a fallback for a banner that hides it:
when the host's shell rejects a POSIX command the way cmd.exe does, the connect runs the Windows
check and shows the Git Bash prompt (0070-PLAN D-a). The fallback is bound to **one** command, the
environment probe (`lib/core/ssh/environment_probe.dart:133`, caught at
`app_providers.dart:1609-1616`). Commit `9a9ac21` added a POSIX command ahead of it: resolving a
`~` path runs `sh -c 'printf %s "$HOME"'` first (`app_providers.dart:1592-1607`). Under cmd.exe
that command fails, `_remoteHome` reports `Could not resolve "~" on the host (…'sh' is not
recognized…)`, and the Windows prompt never appears.

Every Windows OpenSSH banner seen so far names Windows, so this needs a customised server. It is
still a regression, and its cause is structural: the check is attached to a command rather than to
the connect's POSIX preamble.

**Reproduced** (`test/connection_env_reset_test.dart`): with a hidden banner, cmd.exe as the shell,
and `~/repo`, the connect ends with no Windows prompt.

### 5. The Add Worktree sheet cuts off its buttons in a short window

Found while reproducing defect 1. The sheet is one unscrolled `Column` inside `SizedSheet`, which
caps a sheet at the window height less 96 px (`lib/features/common/sized_sheet.dart:33`). The
content needs about 610 px of window. The app allows windows down to 480 px
(`WindowBoundsStore.minHeight`), so in any shorter window the sheet overflows and, in a release
build, **Cancel and Create Worktree are simply not visible**. The sheet's own test pumps a
1400×1400 view (`test/add_worktree_sheet_test.dart:58`), which is why nothing caught it.
`local_repo_form.dart:874-895` already fixed the same defect, with a comment recording why.

**Reproduced**: in the 800×600 default test view the sheet overflows by 53 px.

## Decision Drivers

* A sheet must submit only what it shows, and a caller must not be able to say one thing and mean
  another.
* Fix each defect where it starts, not where it shows: the implicit two-string encoding, the
  missing state test, the one-off display of a raw ref, the check bound to one command.
* Reuse what exists: `forgeChangeRequestIsOpen`, `prettyPipelineRef`, `looksLikeCmdExe`,
  `remoteLocalName`, and the scroll-and-pin sheet layout.
* Each fix carries a regression test that is seen to fail without it.

## Considered Options

For defect 1:

* 1A. Pass `initialBranchName: ''` at the drop site, as History does.
* 1B. Replace the two strings with an explicit start (check out a branch, or a new branch at a
  commit or ref), and make the sheet submit only a branch it offers.

For defect 2:

* 2A. Filter change requests to open ones where each Inbox is built.
* 2B. Give the Inbox its own open-only fetch, independent of Browse.

For defect 3:

* 3A. Use `prettyPipelineRef` in the detail title, and let the filter match the pretty name too.

For defect 4:

* 4A. Make the `~` lookup recognise cmd.exe, and put it and the environment probe under the one
  cmd.exe handler.
* 4B. Fold the `$HOME` lookup into the environment probe, so the connect runs one POSIX command
  before validation.

For defect 5:

* 5A. Scroll the fields and pin the action row, as `local_repo_form.dart` does.

## Decision Outcome

Chosen options: **1B, 2A, 3A, 4A, 5A**.

* **1B**, because 1A repairs one caller and leaves the trap for the next. The combination
  "starting point, no name" meant "branch" to the sheet and "commit" to the drop. An explicit
  start states which, and the drop decides by what was dropped: a local branch is checked out, a
  remote branch starts a new local branch of the same name, and a commit starts a new branch the
  user names. Separately, the sheet's validity follows the popup: an Existing branch that is not
  offered is not a choice, so Create Worktree stays disabled until one is made.
* **2A**, because the list is already fetched and the helper already exists. 2B would double the
  requests for the same data. The Inbox is defined as open work, so the rule belongs where the
  Inbox is assembled.
* **3A**: one name for one thing, wherever it appears.
* **4A**, because it fixes the cause (the check was attached to a command) at the size of the
  bug. 4B is the tidier end state, one round trip instead of two, but it changes the environment
  probe, its cache and `RemoteEnvironment`, which is more than this regression warrants. It
  remains open as a later improvement.
* **5A**: the house pattern, already proven.

### Consequences

* Good, because every defect is fixed at its source, with a failing-then-passing test.
* Good, because `AddWorktreeSheet` callers must now say what they mean, and the compiler checks
  every call site.
* Good, because the Add Worktree sheet works at the app's smallest window.
* Neutral, because dropping a remote branch on Worktrees now prefills a new local branch named
  after it. If that local branch already exists, git refuses and the sheet shows git's message.
* Bad, because the `~` lookup and the environment probe stay two round trips (4B deferred).

### Confirmation

* Each defect's regression test fails on the pre-fix code and passes after, run in a scratch clone.
* Mutation runs show each new guard fails when its fix is removed.
* `flutter analyze` is clean and the full suite passes.
* `test/add_worktree_sheet_test.dart` gains a case at the 640×480 minimum window, showing Create
  Worktree on screen with no overflow.

## Pros and Cons of the Options

### 1A. Pass `initialBranchName: ''` at the drop site

* Good, because it is one line.
* Bad, because the encoding stays implicit, and a dropped remote branch still detaches.
* Bad, because the sheet can still submit a value it does not show.

### 1B. An explicit start, and validity that follows the popup

* Good, because the meaning is in the type, and every caller is visible to the compiler.
* Good, because remote branches and commits are handled on purpose.
* Neutral, because five call sites and one test helper change.

### 2A. Filter at the Inbox

* Good, because it is a one-condition change per forge, using the existing helper.

### 2B. A separate open-only fetch for the Inbox

* Good, because Browse's scope could never leak into the Inbox.
* Bad, because the same data is fetched twice, for a problem a filter solves.

### 3A. Pretty name in the title and the filter

* Good, because the row, the detail and the filter agree.

### 4A. One cmd.exe handler around the POSIX preamble

* Good, because any POSIX command added to the preamble later is covered by the same handler.
* Bad, because the round trips stay separate.

### 4B. `$HOME` from the environment probe

* Good, because it saves a round trip and removes the ordering question entirely.
* Bad, because the probe runs from the repository path, which is the thing `~` must first
  resolve, so it would have to run from `/`. It also touches the probe script, the environment
  cache and `RemoteEnvironment`.

### 5A. Scroll the fields, pin the actions

* Good, because it is the layout `local_repo_form.dart` already uses for the same reason.

## More Information

* Implementation: [0071-PLAN-worktree-start-inbox-state-pipeline-names-and-shell-check-order.md](0071-PLAN-worktree-start-inbox-state-pipeline-names-and-shell-check-order.md).
* Related: [0070-MADR-native-windows-hosts-over-ssh.md](0070-MADR-native-windows-hosts-over-ssh.md)
  (the cmd.exe fallback in defect 4); commit `9a9ac21` (the `~` expansion that preceded it).
* Out of scope, listed with these in the same audit: the ⌘B shortcut label, leftover
  "Connections Manager" and "Connections list" wording, the "Absolute path" hints, the palette's
  missing Toggle Navigator, and a ShellCheck warning in `build_macos.sh`.
