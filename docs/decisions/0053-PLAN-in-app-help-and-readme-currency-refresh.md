---
status: "in-progress"
date: 2026-09-18
associated-madr: "0053-MADR-in-app-help-and-readme-currency-refresh.md"
---

# Implement the in-app Help, README and build guide currency refresh

Associated MADR:
[0053-MADR-in-app-help-and-readme-currency-refresh.md](0053-MADR-in-app-help-and-readme-currency-refresh.md)
(`accepted`, 2026-09-18). Finding IDs (W, I, M, S, R, B) are the MADR's, and this plan cites them without
restating the evidence.

## Goal

Ship the MADR's Option B. Each item below is proven by a check that has been seen to fail:

1. **Help Book v3.0.** Every W finding is corrected, every I topic completed, and every M area covered, in the
   MADR's 34-topic information architecture (7 categories, including the new Troubleshooting category).
2. **Drift guards** in `test/help_book_json_test.dart`:
   * label anchors (a quoted UI label must still exist in source);
   * menu coverage (every menu item title appears in the book);
   * forbidden phrases for W1–W21;
   * a schema guard for section fields the renderer silently drops.
3. **Help machinery.**
   * **S1:** search matches bullet `items` and `code`, in both the macOS 13+ view and the macOS 12 Legacy view.
   * **S2:** `HelpDataModelTests.swift` compiles, is a member of the `RunnerTests` target, and runs.
4. **App copy (W9).** The Settings sheet's intro names every setting that saves immediately.
5. **README** rewritten around R1–R5.
6. **`docs/BUILD_MACOS.md`** revised around B1–B9, and **`build_macos.sh`** fixed for B8.

## Scope

### Files this plan may change

| File | Phases | Why |
|---|---|---|
| `docs/decisions/0053-MADR-…`, `0053-PLAN-…` (this file), `docs/README.md` | 0, 12 | Records, execution log, index |
| `docs/0010-MADR-in-app-help-book-rewrite.md` | 0 | "Amended by 0053" note (the MADR amends 0010's locked IA and category ban) |
| `docs/0010-PLAN-in-app-help-book-rewrite.md` | 12 | Note that Phase 7's maintainer review is carried by this plan's Phase 12 |
| `macos/Runner/help_book.json` | 1–8 | The book |
| `test/help_book_json_test.dart` | 1–8 | Contract and guards |
| `lib/features/settings/settings_sheet.dart` | 3 | W9 intro copy (the only `lib/` edit) |
| `test/settings_sheet_keymap_test.dart` | 3 | Pins the W9 copy; the test is updated with it |
| `macos/Runner/HelpDataModel.swift` | 9 | Shared, testable search predicate (S1) |
| `macos/Runner/HelpView.swift` | 9 | Both views use the predicate; Legacy gains `.searchable` (S1) |
| `macos/RunnerTests/HelpDataModelTests.swift` | 9 | Compile fix, and new search tests (S2) |
| `macos/Runner.xcodeproj/project.pbxproj` | 9 | Add the test file to the `RunnerTests` target (S2) |
| `tool/mutations/0053-help-book.json` | 10 | Mutation catalogue for the guards |
| `README.md` | 11 | R1–R5 |
| `docs/BUILD_MACOS.md` | 11 | B1–B7, B9 |
| `build_macos.sh` | 11 | B8 |

Any other file needed is a **deviation**: stop and prompt, per the rules below.

### Out of scope

* **S4 (links from the app into Help).** The MADR defers it. Topic IDs are kept stable so later work has fixed
  targets.
* **Moving `docs/BUILD_MACOS.md` into `docs/guides/`.** That belongs to the pending layout migration (B9).
* **Changing product behaviour.** Where Help and the app disagree, Help follows the app. The one exception is
  W9's copy, which the MADR decides. If execution finds a *product* defect (a label that is wrong in the app,
  not in Help), it is a deviation to prompt on, not something to fix silently or to document around.
* **Palette `issue:` / `request:` / `ci:`, the inspector pane, and the 0006 title bar.** Help still does not
  teach these (0010 G5).

## Conventions used by every phase

**SDK check**, before the first command of each session:

```sh
flutter --version | head -1          # must print Flutter 3.47.2
flutter pub get --enforce-lockfile   # must print "Got dependencies!"
```

If either disagrees, use `./.flutter-sdk/bin/flutter` for every command in this plan.

**Gate**, run before every commit. Each status is captured, never piped:

```sh
S=<scratchpad>
dart format --output=none --set-exit-if-changed <every .dart file the phase staged>; FMT=$?
flutter analyze > "$S/p<N>-analyze.log" 2>&1; AN=$?
flutter test test/help_book_json_test.dart > "$S/p<N>-help.log" 2>&1; HT=$?
flutter test > "$S/p<N>-full.log" 2>&1; FULL=$?
python3 -m json.tool macos/Runner/help_book.json > /dev/null; JSON=$?
```

All five must be `0`. The full run's final line is read in full and recorded in the execution record. A
failure is read from the whole log, never from a `grep` or `tail` of it. Phases that touch no `.dart` file
skip `FMT`. Phases that touch no book or test skip nothing else: the full suite always runs.

**Commit**, per phase:
1. `git add` the phase's files by explicit path (never `-A`).
2. `git commit --no-edit`, so the global `prepare-commit-msg` hook writes the message.
3. `git log -1 --format=%B`, to read the message back.

Code/book commits and execution-record commits are separate: the phase commit first, then a docs commit that
appends "Phase N, executed" to this plan. Nothing is pushed.

**Seen to fail.** Every content phase follows the same order:
1. Add the phase's contract entries to `test/help_book_json_test.dart`: the locked topic list, required facts,
   forbidden phrases, label anchors.
2. Run the Help test against the **unchanged** book and record the named failures (test name + reason text).
   This is a real-tree run, legitimate only because the content has not been written yet; nothing is broken on
   purpose.
3. Write the content, and run it green.

A contract entry that passes in step 2 guards nothing new. Either it pins something already correct (say so in
the record) or it is mis-written (rewrite it). Deliberate breakage of the *mechanisms* happens only in Phase
10, through `tool/mutate.py` in its scratch worktree, never in the real tree.

**Label discipline.** A label is added to `_labelAnchors` only after it is found verbatim in the source corpus
(the test's own corpus function; see Phase 1). A label built at runtime ("Abort <Verb>", "Reset to <up>?") is
anchored by its **static literal fragment** as written in source (for example `Reconcile with `), never by a
reconstructed whole. Help quotes labels exactly, in source case.

**Content rules** (MADR "Rules for the content"):
* Exact source labels.
* GitHub and GitLab differences stated where they exist.
* Searchable facts go in `items` or `paragraph`.
* A heading's words go in `text` (the renderer shows only `text` for headings).
* `items` and `paragraph` sections carry no `title` (the renderer drops it).
* Every topic has a `summary` and at least 3 `keywords`.
* New topics carry shortcut chips only for default-bound actions (0010 G3/G4).

**Deviations.** Anything the plan does not cover (a pre-existing defect, a wrong step, an extra file, a MADR
fact the code contradicts) means **stop and prompt**, with:
* the evidence;
* real resolutions only;
* the cost of doing nothing.

Once resolved, add a dated entry here, amend the MADR if a fact or decision changed, then continue.

## Implementation Steps

### Phase 0 — Baseline and records

1. Run the SDK check.
2. Run `flutter analyze` and the full `flutter test` on the unmodified tree, with output to the scratchpad.
   Record the analyzer result and the suite's final line verbatim; that line is the baseline. Record
   `flutter test test/help_book_json_test.dart` (expected `+11: All tests passed!`, as observed 2026-09-18).
3. Set the MADR to `status: "accepted"` (with the date) and this plan to `status: "in-progress"`. Update the
   `docs/README.md` 0053 row to show `accepted`, with a plan link and `in progress`.
4. Add a short note under the frontmatter of `docs/0010-MADR-in-app-help-book-rewrite.md`:
   > Amended by 0053-MADR-in-app-help-and-readme-currency-refresh.md: the locked topic list (G6) and the
   > `troubleshooting` category-id ban.

   The existing text is not rewritten.
5. Commit the records (docs only).

**Acceptance:** tree clean after the commit, and baseline figures recorded under "Phase 0, executed".

### Phase 1 — Guard infrastructure (green on the current book)

This phase adds the mechanisms. It adds no new content requirements.

In `test/help_book_json_test.dart`:

1. **Source corpus.** Add `String _sourceCorpus()`. It returns the concatenated text of every `*.dart` file
   under `lib/` (via `Directory('lib').listSync(recursive: true)`) plus
   `macos/Runner/MainFlutterWindow.swift`, read once in `setUpAll`.
2. **Label anchors.** Add `const _labelAnchors = <String, List<String>>{}` (topic id → labels) and a test,
   `quoted UI labels exist in their topic and in source`. For each entry it asserts:
   * `_topicBlob(book, topic)` contains the label (Help quotes it);
   * `_sourceCorpus()` contains the label (the app still shows it).

   Both assertions give a reason naming the topic and label. Seed the map with labels the **current** book
   already quotes correctly. Each was confirmed present in both the book and `lib/` on 2026-09-18, and is
   re-checked at execution:
   * `tab_repository`: `Hide reviewed`, `Mark Resolved`
   * `tab_stashes`: `Stash with Message…`
   * `tab_worktrees`: `Add Worktree` (the book has no ellipsis form; the source has both)
   * `tab_branches`: `Fetch & Prune`
   * `settings`: `Known Hosts`, `Keyboard Mappings`
3. **Schema guard.** Add the test `sections carry only fields the renderer shows`. It asserts:
   * every `heading` has a non-empty `text`;
   * `items` and `paragraph` sections have no `title`;
   * `callout` has `text`;
   * `code` has `code`;
   * every topic has at least 3 `keywords`.
4. **Menu coverage machinery**, with an empty requirement. Add two helpers:
   * `Iterable<String> _menuTitles(List<MenuBarItem>)`, which recurses into `items` and skips `separator`
     entries;
   * `Set<String> _nativeMenuTitles()`, which extracts every `title: "…"` literal from
     `MainFlutterWindow.swift` and subtracts a named `_nonMenuTitles` set: `Help`, `Window`, and any other
     non-item literal found during execution, each commented with its line.

   A companion test asserts every `_nonMenuTitles` entry still occurs in the Swift source, so the exclusion list
   cannot go stale. The coverage **assertion** itself is added in Phase 7, when the book gains the menu
   titles.
5. Run the Help test. It must be green: the anchors are correct and the schema already holds, as verified
   2026-09-18.

**Seen to fail** for these mechanisms happens in Phase 10.

**Acceptance:** Help test green with the new tests present; gate `0`; commit.

### Phase 2 — Getting Started (W5, W6, W7, I1–I5, M1, M2)

**Contract first.**
* **Locked topic list** for `getting_started`: `overview`, `quickstart`, **`connections_manager`**,
  `clone_create`, `tabs_workspaces`.
* **Forbidden phrases.** Add a new test, `Help does not teach the 0053 falsehoods`, which holds a
  `_falsehoods0053` list that Phases 2–7 extend. 0010's existing forbidden-phrase test is untouched. This
  phase's entries:
  * `opens the macOS folder panel` (W7)
  * `alias a set of tabs` (W6)
  * `Close tab, Log out, Disconnect, Quit, and Close window confirm when` (W5)
* **Required facts:**
  * `overview`: `Connections`, `Location`, `Logout`, `This Mac`
  * `quickstart`: `Add Existing Repository`, `Choose…`, `Browse…`, `Repository path`, `Git directory`,
    `GitHub token`, `GitLab token`, `Save connection`
  * `connections_manager`: `Local Repositories`, `Remote Repositories`, `Edit connection`,
    `Delete connection`, `Remove repository`, `Edit repository`, `fsmonitor`, `dotfiles`, `Choose a folder`,
    `globe`, `folder`
  * `clone_create`: `URL`, `Folder name`, `Create parent folders if missing`, `Namespace`, `Recently active`,
    `Visibility`, `own tab`, `8`
  * `tabs_workspaces`: `Rename Tab`, `Are you sure you want to quit?`, `drag`, `Maximum of 8 tabs open`
* **Label anchors** (each checked in the corpus first):
  * `Add Existing Repository`
  * `Scoped work-tree repo (dotfiles)`
  * `Add SSH Remote`
  * `Edit connection`
  * `Choose This Folder`
  * `Save to Local Repositories`
  * `Create parent folders if missing`
  * `Search namespaces…`
  * `Rename active tab`
  * `Only saved repositories can have aliases`
  * `Are you sure you want to quit?`
  * `Log out?`

Run the test and record the red failures.

**Content.**
* Revise `overview` (I1), `quickstart` (W7, I2), `clone_create` (I3, I4) and `tabs_workspaces` (W5, W6, I5).
* Write `connections_manager` (M1, M2) with:
  * a summary;
  * keywords (`connections`, `manager`, `saved`, `edit`, `dotfiles`, `scoped`, `git-dir`, `fsmonitor`,
    `location`);
  * a heading per area: Manager, Editing entries, Scoped/dotfiles repositories, The remote folder browser,
    Location and names.

The MADR's M1/M2 and I1–I5 bullets are the content inventory: every listed label and behaviour appears in the
book. Nothing in the inventory is dropped without a recorded deviation.

**Acceptance:** Help test green; gate `0`; commit.

### Phase 3 — The Workspace, and the Settings copy (W2–W4, W8–W11, I6–I8, M11)

**Contract first.**
* **Forbidden phrases:**
  * `Leading controls: Back, Forward, then Fetch` (W2)
  * `one emphasized` (W3)
  * `⋯ control opens Repository details` (W4)
  * `View ▸ Show Dashboard,` (W8, with the trailing comma; the corrected text says `Show Dashboard View`)
  * `except Keyboard Mappings and Forget Host` (W9)
  * `defaults to 3 minutes` (W10)
  * `or this book` (W11)
* **Required facts:**
  * `workspace_chrome`: `View options`, `More sync actions`, `green`, `orange`, `grey`, `recommended`,
    `Commit in Focused sheet`
  * `file_view_and_output`: `live`, `Clear output`, `2000`
  * `dashboard_recovery_activity`: `Show Dashboard View`, `Show Recovery View`, `Measure`, `Restore…`,
    `7 days`, `Canceled`, `Dock`
  * `settings`: `Open files with`, `System default`, `stall`, `30 minutes`, `Terminal.app`
* **Label anchors:**
  * `More sync actions`
  * `Commit in `, the static fragment of the commit-surface label (`workspace_view_options.dart`). If the
    source builds the full label from `CommitSurface.label`, anchor `Focused sheet` and `Task dock` instead.
  * `Show Dashboard View`, `Show Recovery View`
  * `Clear output`
  * `Open files with`
  * `Restore files`, `Delete snapshot`

**Settings copy (W9), test first.** In `test/settings_sheet_keymap_test.dart`, change the expected text to
`Keyboard Mappings, Forget Host and Open files with save immediately`. Keep the test name's intent, retitled to
`Settings discloses every setting that saves immediately`. Run it: it must fail against the current copy.
Record the failure. Then change `lib/features/settings/settings_sheet.dart:173-178` to:

> App-wide preferences: command timeouts, who commits are authored as, default pull/push behavior, which app
> opens files, background fetching, trusted SSH hosts, and keyboard shortcuts. Changes apply after Save.
> Keyboard Mappings, Forget Host and Open files with save immediately.

Run the test green.

**Content.** Revise `workspace_chrome` (W2–W4, I6), `file_view_and_output` (I7),
`dashboard_recovery_activity` (W8, I8) and `settings` (W9–W11, M11). The Settings topic's sentence about what
saves immediately uses the same words as the sheet.

**Acceptance:** both tests green; gate `0` (`FMT` covers the two staged `.dart` files); commit.

### Phase 4 — Panels I: Repository, Committing, Sync, Stashes (W1, W17, W18, I9, M3, M4)

**Contract first.**
* **Locked topic list** for `panels`. It grows phase by phase and never lists a topic the book doesn't have
  yet. Here it becomes `tab_repository`, **`committing`**, **`sync_fetch_pull_push`**, `tab_history`,
  `tab_branches`, `tab_stashes`, `tab_forge`, `tab_worktrees`. Phases 5 and 6 insert their new IDs at the
  MADR's positions.
* **Forbidden phrases:**
  * `expands the composer in the task dock` (W1)
  * `are Stash-menu only` (W17)
  * `Repository menu only` (W18)
* **Required facts:**
  * `tab_repository`: `Use Ours (HEAD)`, `Use Theirs (incoming)`, `Use Onto (ours)`, `Abort `, `Stage All`,
    `Unstage All`, `Branches`
  * `committing`: `Focused sheet`, `Task dock`, `background`, `Co-author`, `Regenerate`,
    `prepare-commit-msg`, `--no-gpg-sign`, `Amend Last Commit…`, ~~`Committed, but the push failed.`~~
    `error dialog`, `Failed` (Deviation D1, 2026-09-18)
  * `sync_fetch_pull_push`: `--prune`, `@{upstream}`, `Fast-forward only`, `Remote has new commits`,
    `Pull, then Push`, `Force push`, `staging`, `Auto-fetch`, `This branch has no upstream yet`
  * `tab_stashes`: `Apply latest stash`, `Pop latest stash`, `Clear all stashes…`, `Apply, restoring staged files`
* **Label anchors:**
  * `Use Ours (HEAD)`, `Use Theirs (incoming)`, `Use Onto (ours)`, `Use Commit (theirs)`
  * `Unstage All`, `Stage All`
  * `Committed. Pushing… you can close this; it continues in the background.`
  * `Regenerate`, `Add co-author`
  * `Remote has new commits`, `Pull, then Push`, `Push anyway`
  * `This branch has no upstream yet`, `No remote is configured`
  * `Apply latest stash`, `Pop latest stash`, `Clear all stashes…`, `Create branch from stash…`
* **Shortcut chips:**
  * `committing`: `repository.focusCommit`, `commit.confirm`, `commit.confirmAndPush`
  * `sync_fetch_pull_push`: `repository.fetch`, `repository.pull`, `repository.push`, `repository.sync`,
    `repository.forcePush`

  The existing chip tests validate these.

Run the test and record the red failures.

**Content.** Revise `tab_repository` (W18, I9). Its commit paragraph shrinks to a pointer to `committing`.
Write `committing` (W1, M3) and `sync_fetch_pull_push` (M4). Revise `tab_stashes` (W17).

**Acceptance:** Help test green; gate `0`; commit.

### Phase 5 — Panels II: History, Branches, Branch sync and recovery, Worktrees (W14–W16, I10–I12, M5–M8)

**Contract first.**
* **Topic list.** Insert **`branch_sync_recovery`** after `tab_branches`.
* **Forbidden phrases:**
  * `Hide merges is a separate chip` (W14)
  * `Bulk pin, hide, and delete-if-merged sit on the list` (W15)
  * `Unmerged branches confirm.` (W16)
* **Required facts:**
  * `tab_history`: `Hide merges`, `path:`, `since:`, `Clear filters`, `Interactive rebase`, `Pick`, `Squash`,
    `Fixup`, `Drop`, `History of`, `J`, `Recovery`
  * `tab_branches`: `Review`, `Compared with`, `Sort`, `Unhide`, `branches selected`, `Force Delete`,
    `Remove Worktree and Delete`, `Create Tag`, `Annotated`, `local only`
  * `branch_sync_recovery`: `Not published`, `Diverged`, `gone`, `Reconcile…`, `Merge`, `Rebase`, `Reset`,
    `⌘Z`, `allow unrelated histories`, `Clean up stale branches?`, `Set upstream`, `Publish`, `Advanced`,
    `in progress`
  * `tab_worktrees`: `Open in Window`, `Remove Worktree and Delete Branch…`, `No worktrees yet`,
    `Open it when done`, `Terminal.app`, `Prune stale worktrees`
* **Label anchors:**
  * `Hide merges`, `Filter by author, date, or path`, `Clear filters`, `Interactive rebase`
  * `Reconcile…`, `Reconcile with `, `Merge Anyway`, `Clean up stale branches?`, `Not published`, `Diverged`
  * `Unhide`, `Delete if merged…`, `Force Delete`, `Compared with`
  * `Open in Window`, `Remove Worktree and Delete Branch…`, `No worktrees yet`, `Open it when done`
* **Shortcut chips.** None are new. `branch_sync_recovery` carries no chips (its verbs are unbound).

Run the test and record the red failures.

**Content.** Revise `tab_history` (W14, I10, M7), `tab_branches` (W15, W16, I11, M6) and `tab_worktrees`
(I12, M8). Write `branch_sync_recovery` (M5), with one heading per sync state. Each state gets:
* what the row shows;
* what the detail pane says;
* which action resolves it.

Plus Reconcile's three paths and their risks, the unrelated-histories merge, stale-branch cleanup, Set
upstream vs Publish, and the pending banner.

**Acceptance:** Help test green; gate `0`; commit.

### Phase 6 — Forge (W19–W21, I13, M9)

**Contract first.**
* **Topic list.** Insert **`forge_requests_and_issues`** and **`forge_ci`** after `tab_forge`.
* **Forbidden phrases:**
  * `merged and closed work is not a status chip` (W19)
  * `sit on the detail More menu` (W20)
  * `New Issue is Forge-menu only` (W21)
* **Required facts:**
  * `tab_forge`: `No blockers`, `Show closed pull requests`, `Show closed merge requests`, `Reopen`,
    `Update branch`, `Rebase onto target`, `Re-run Failed Jobs`, `collapse`
  * `forge_requests_and_issues`: `Squash and merge`, `Rebase and merge`, `Merge method`,
    `Delete source branch after merge`, `Request changes…`, `GitHub only`, `Start work`, `Assign to me`,
    `Create as draft`, `Discard draft?`, `New issue`
  * `forge_ci`: `live`, `GitLab`, `Logs are available once it completes.`, `Jump to latest`,
    `Re-run failed jobs`, `Retry pipeline`
* **Label anchors:**
  * `No blockers`, `Show closed pull requests`, `Show closed merge requests`, `Update branch`,
    `Rebase onto target`
  * `Squash and merge`, `Rebase and merge`, `Merge method`, `Delete source branch after merge`
  * `Start work`, `Assign to me`, `Create as draft`, `Discard draft?`, `New issue`
  * `Jump to latest`, `Re-run failed jobs`, `Retry pipeline`
  * `Logs are available once it completes.`. If the source literal carries a `\n` before this sentence,
    anchor the sentence fragment only.
* **Shortcut chips:**
  * `forge_requests_and_issues`: `github.newPr`, `gitlab.newMr`, `github.approve`, `gitlab.approve`,
    `github.merge`, `gitlab.merge`
  * `forge_ci`: `github.rerun`, `gitlab.retry`

Run the test and record the red failures.

**Content.** Revise `tab_forge` (W19–W21, I13): the panel, Inbox, Browse, and lists. It points to the two new
topics. Write `forge_requests_and_issues` (the M9 menus, merge sheet, forms, comments and issues) and
`forge_ci` (the M9 CI viewer). Every GitHub/GitLab difference is stated.

**Acceptance:** Help test green; gate `0`; commit.

### Phase 7 — Files, Commands, Safety; menu coverage switched on (W12, W13, I14–I19, M12)

**Contract first.**
* **Forbidden phrases:**
  * `Switch Code and Preview` (W12)
  * `On a local repo, Open uses the macOS opener` (W12)
  * `While a pop-out is key` (W13)
* **Required facts:**
  * `viewer_and_remote_edit`: `Source`, `Preview`, `Open file`, `Open files with`, `Remote Edit Conflict`
  * `diffs_blame_history`: `Side by Side`, `Overlay`, `Slider`, `Previous changed file`
  * `drag_and_drop`: `stash`, `New branch from`, `Show history of`, `selection`
  * `secondary_windows`: `Open in Window`, `Waiting for session…`, `native secondary windows`
  * `feature_palette`: `Switch to tab`, `Open workspace`, `Manage Saved Workspaces`, `Recovery: Browse Reflog & Snapshots`
  * `menus_and_keymap`: `Re-run Failed Jobs`, `Merge Merge Request…`
  * `undo_recovery`: `Files Changed Since`
  * `tool_health`: `Environment health`, `Required`, `Feature`, `Optional`, `2.24`, `fswatch`, `inotifywait`
* **Label anchors:**
  * `Source`: too generic to anchor meaningfully, so it is **not** anchored; the required fact covers it
  * `Remote Edit Conflict`, `Side by Side`, `Overlay`, `Slider`, `Previous changed file`
  * `Waiting for session…`, `Manage Saved Workspaces`, `Recovery: Browse Reflog & Snapshots`
  * `Files Changed Since`, `Environment health`, `Install from file…`
* **Menu coverage assertion** (new test, `every menu item title appears in the book`). Every title from
  `_menuTitles(kMenuBarMenus)` and `_nativeMenuTitles()` occurs somewhere in the book. The failure reason names
  the missing titles.

Run the test and record the red failures. The current book lacks, for example, `Re-run Failed Jobs`,
`Show Recovery View` and `Repair All Worktree Links`. The full missing list is recorded.

**Content.** Revise the four Files topics, `feature_palette`, `undo_recovery` and `tool_health`. Extend
`menus_and_keymap` with a **Menus** section listing every menu's item titles as `items`, grouped by menu, with
native View items included. This is where menu coverage is met.

**Acceptance:** Help test green, including menu coverage; gate `0`; commit.

### Phase 8 — Troubleshooting category (M10); version 3.0

**Contract first.**
* **Categories.** The expected list becomes `getting_started`, `workspace`, `panels`, `files`, `commands`,
  `safety`, **`troubleshooting`**. Remove the assertion `isNot(contains('troubleshooting'))`, and replace it
  with a comment citing the 0053 amendment. Keep the `tabs` and `features` bans.
* **Locked topic list** for `troubleshooting`: `trouble_connection`, `trouble_forge`, `trouble_refresh`,
  `trouble_access`.
* **Version.** Assert `version` is `3.0`.
* **Required facts:**
  * `trouble_connection`: `Connection interrupted`, `Host Key Changed`, `Refresh Key and Continue`,
    `Scan environment`
  * `trouble_forge`: `auth login`, `Open Dashboard`, `rate limited`, `No remote detected`,
    `Unsupported forge`, `self-hosted`
  * `trouble_refresh`: `Polling for changes (watcher unavailable)`, `orange`, `fswatch`, `inotifywait`,
    `fsmonitor`
  * `trouble_access`: `Grant access to this worktree`, `Grant access to the main repository`,
    `credentials.json`, `0600`
* **Label anchors:**
  * `Open Dashboard`, `No remote detected`, `Unsupported forge`
  * `Polling for changes (watcher unavailable)`, `Polling fallback`
  * `Grant access to this worktree`, `Grant access to the main repository`
  * `Refresh Key and Continue`
  * `was rate limited by the forge`: the static fragment in `lib/core/forge/forge_rate_limit.dart`, checked
    first

Run the test and record the red failures.

**Content.** Add the category (`id: troubleshooting`, title `Troubleshooting`, SF Symbol `wrench.and.screwdriver`)
and its four topics. Each is written as **symptom → cause → fix**, one heading per symptom. Set the book's
`version` to `3.0`.

**Acceptance:** Help test green; the book has 34 topics in 7 categories. Assert this by a count in the test:
add `expect(totalTopics, 34)` to the IA test. Gate `0`; commit.

### Phase 9 — Help machinery: search (S1) and the Swift test (S2)

1. **Shared predicate.** In `macos/Runner/HelpDataModel.swift` (Foundation-only), add
   `public enum HelpSearch { public static func matches(_ topic: HelpTopic, query: String) -> Bool }`. It keeps
   today's behaviour (trim the query; an empty query matches everything; lowercase `contains`) and extends it
   to each section's `items` and `code`.
2. **Views.**
   * `HelpView.filteredTopics` calls `HelpSearch.matches`.
   * `HelpViewLegacy` gains `@State searchText` and the same results/categories list switch as `HelpView`,
     using `List` + `Button` as today, with `.searchable(text:prompt:)` (macOS 12 API, within the 12.0
     deployment target).
3. **Tests, written first.** In `macos/RunnerTests/HelpDataModelTests.swift`:
   * move the stray assertions at lines 87-92 into `testHelpBookDecoding`, where `topic` is in scope;
   * add `testSearchMatchesItems` (a topic whose only match is a bullet);
   * add `testSearchMatchesCode`;
   * add `testEmptyQueryMatchesAll`;
   * add `testSearchIsCaseInsensitive`;
   * update `testLoadBookFromBundleOrFile` to assert the `troubleshooting` category and its four topic IDs.
4. **Target membership.** Add `HelpDataModelTests.swift` to the `RunnerTests` target in `project.pbxproj`:
   one `PBXFileReference`, one `PBXBuildFile`, a child of the `RunnerTests` group, and an entry in that target's
   Sources build phase. Edit with a Python script in the scratchpad. It generates 24-hex-digit IDs that don't
   collide, asserts each anchor occurs exactly once before inserting, and asserts each insertion afterwards.
   Confirm with `xcodebuild -list -workspace macos/Runner.xcworkspace` (output to the scratchpad).
5. **Run the Swift tests.**

   ```sh
   xcodebuild test -workspace macos/Runner.xcworkspace -scheme Runner \
     -destination 'platform=macOS' -derivedDataPath "$S/dd0053" > "$S/p9-xctest.log" 2>&1; XT=$?
   ```

   * **Red first.** Run once *before* step 1's predicate exists (the tests reference `HelpSearch`), and record
     the compile or test failure.
   * **Then green.** Run again after steps 1–2; `XT` must be `0`, with `HelpDataModelTests` listed as passed
     in the log.
   * **Known risk, decided now.** `DebugProfile.entitlements` includes `keychain-access-groups`, and this
     machine has no signing identity. If the test run fails on signing rather than on a test, that is a
     **deviation**: stop and prompt. Resolutions to offer:
     * the maintainer runs step 5 on a machine with a development team configured;
     * add a Debug-only test entitlements selection mirroring 0042's xcconfig mechanism (grows the phase by
       one xcconfig and one entitlements file).

     Skipping the target, or disabling code signing for the test run, is not offered.
6. **Standalone check of the predicate** (independent of step 5, run in the scratchpad):
   * compile `HelpDataModel.swift` with a scratch `main.swift` that loads the real `help_book.json` and
     asserts that searching `gitignore`, `cherry-pick` and `Reconcile` each returns the expected topic IDs:

     ```sh
     swiftc macos/Runner/HelpDataModel.swift "$S/help_main.swift" -o "$S/helpsearch" > "$S/p9-swiftc.log" 2>&1; SC=$?
     "$S/helpsearch" > "$S/p9-search.log" 2>&1; SR=$?
     ```

   * **Seen to fail.** Compile a **scratch copy** of `HelpDataModel.swift` with the `items` clause removed, and
     observe the `gitignore` assertion fail. Record the output.

**Acceptance:**
* `XT` is `0`, or a resolved deviation is recorded.
* `SC` and `SR` are `0`.
* The scratch mutation is seen to fail.
* The Dart gate is `0`.
* Commit (Swift files, pbxproj).

### Phase 10 — Prove the guards fail (mutation catalogue)

Write `tool/mutations/0053-help-book.json`. Each entry changes one file inside `tool/mutate.py`'s scratch
worktree and names `test/help_book_json_test.dart`:

| Label | File | Find → replace | Expected failing test |
|---|---|---|---|
| anchor: label renamed in code | `lib/features/branches/branch_navigator.dart` | `'Reconcile…'` → `'Reconcile'` (the first exact occurrence; the entry targets a unique line) | `quoted UI labels exist in their topic and in source` |
| anchor: label dropped from Help | `macos/Runner/help_book.json` | `Show closed pull requests` → `Show more pull requests` | same |
| menu: new item undocumented | `lib/features/common/menu_bar_spec.dart` | `'Re-run Failed Jobs'` → `'Re-run Failed Jobs Now'` | `every menu item title appears in the book` |
| menu: native item undocumented | `macos/Runner/MainFlutterWindow.swift` | `title: "Show Recovery View"` → `title: "Show Recovery Panel"` | same |
| forbidden: W1 returns | `macos/Runner/help_book.json` | one sentence in `committing` → text containing `expands the composer in the task dock` | `Help does not teach the 0053 falsehoods` (the test that holds W1–W21) |
| schema: dropped heading text | `macos/Runner/help_book.json` | one `"type": "heading", "text"` → `"type": "heading", "title"` | `sections carry only fields the renderer shows` |
| required fact removed | `macos/Runner/help_book.json` | `Reconcile…` in `branch_sync_recovery` → `Reconcile` | `required facts appear in their topics` |
| IA: topic dropped | `macos/Runner/help_book.json` | rename topic id `trouble_forge` → `trouble_forges` | `every locked topic id exists in its category, in order` |

Every `find` string is taken from the committed tree and asserted to occur exactly once by the harness. Then:

```sh
python3 tool/mutate.py --check tool/mutations/0053-help-book.json > "$S/p10-check.log" 2>&1; CK=$?
python3 tool/mutate.py tool/mutations/0053-help-book.json > "$S/p10-mut.log" 2>&1; MU=$?
```

`CK` and `MU` must be `0`, every entry must be **KILLED** by its named test, and none may be DID NOT APPLY,
DOES NOT COMPILE or OBSERVED BY NO TEST. The whole log is read and the verdict lines recorded.

A Dart-side mutation that edits a `.swift` or `.json` file doesn't compile anything, so the harness's compile
canary doesn't apply to it. The named-test requirement still does.

**Acceptance:** all 8 entries KILLED; gate `0`; commit the catalogue.

### Phase 11 — README, build guide, build script (R1–R5, B1–B9)

1. **`build_macos.sh` (B8), check first.** Copy the tracked script to the scratchpad and run
   `bash "$S/build_copy.sh" --bogus`. Record exit `127` and `die: command not found` (re-establishing the
   2026-09-18 observation). Then, in the tracked script, move the `log()` and `die()` definitions (lines 71-72)
   above the argument loop (line 59). Do this with a Python edit that asserts each moved block occurs exactly
   once and the old position is gone. Copy the fixed script to the scratchpad and re-run with `--bogus`. It
   must exit `1` and print `Unknown option: --bogus (supported: --unsigned, --install)`. The tracked script is
   never run with a bad argument, and no build runs in this phase.
2. **`docs/BUILD_MACOS.md`** is rewritten in the MADR's eight sections:
   1. Prerequisites and the Flutter pin (B4)
   2. Build and entitlement selection (B1, B2)
   3. Credential storage (B3)
   4. Install (B7)
   5. Output and targets (B9)
   6. Signing for real and notarizing (B5, B6)
   7. Troubleshooting
   8. Clean up

   Every command in the guide is checked against `build_macos.sh` or `AppInfo.xcconfig`. Every path is
   checked against the script's variables. The check is written as a scratch Python script that extracts
   backticked commands and paths from the guide and reports any not traceable to a source. Its output is
   recorded, and any residue is explained line by line.
3. **`README.md`** is rewritten in the MADR's seven sections. Facts come only from the MADR's cited sources:
   * `kToolCatalog` for tool versions;
   * `build_macos.sh` for install;
   * AGENTS.md for the pin, `--enforce-lockfile` and `live-forge`;
   * the Help book for where Help lives.

   Links: `docs/README.md`, `docs/ARCHITECTURE_PLAN.md`, `docs/BUILD_MACOS.md`, `AGENTS.md`.
4. **Link check** of the two files. A scratch Python script resolves every relative Markdown link in
   `README.md` and `docs/BUILD_MACOS.md` to an existing path. Output recorded; exit `0` required.
5. **R/B checklist.** For each of R1–R5 and B1–B9, record the line in the new text that resolves it.
6. **No identifiers.** Grep both files for hostnames, account names and absolute home paths other than
   `~/…`/`$HOME` placeholders, per the global rule.

**Acceptance:**
* The script's bad-argument behaviour is seen both ways.
* The link check exits `0`.
* The checklist is complete.
* The gate is `0`.
* Commit (`build_macos.sh`, `docs/BUILD_MACOS.md`, `README.md`).

### Phase 12 — Close

1. Run the full gate once more and record the final lines.
2. **Maintainer checks** (cannot be done by an engineer; recorded as open until done):
   * **Help.** Build with `./build_macos.sh --unsigned --install`. Open Help ▸ Support & Help (⌘?). Walk all
     34 topics. Search `gitignore`, `Reconcile`, `rate limit`, `dotfiles`, and confirm each finds its topic.
     This also discharges `0010-PLAN-in-app-help-book-rewrite.md` Phase 7.
   * **Build guide.** Follow the revised `docs/BUILD_MACOS.md` from a fresh clone and report any step that
     doesn't match.
3. Update the records:
   * this plan's status (`complete` only once both maintainer checks are done, `in-progress` otherwise, with
     the residual named);
   * the MADR's `verified:` date;
   * the `docs/README.md` 0053 row, and a note on the 0010 row that its Phase 7 is carried by 0053's Phase 12;
   * a one-line pointer in `docs/0010-PLAN-in-app-help-book-rewrite.md` to the same effect.
4. Commit the records.

## Verification

| Check | Command / evidence | Required |
|---|---|---|
| Help contract | `flutter test test/help_book_json_test.dart` | green; red-first failures recorded for Phases 2–8 |
| Guards fail on demand | `python3 tool/mutate.py tool/mutations/0053-help-book.json` | 8/8 KILLED by the named test |
| Settings copy | `flutter test test/settings_sheet_keymap_test.dart` | green; red-first recorded |
| Whole app | `flutter analyze`, full `flutter test` | clean / all passed; figures recorded per phase |
| Swift search and test target | `xcodebuild test … -scheme Runner` | `HelpDataModelTests` passed, or a resolved deviation |
| Search predicate, independent | scratch `swiftc` harness + scratch mutation | passes on real code, fails on the mutated copy |
| Book shape | IA test (`34` topics, 7 categories, `version` `3.0`) | green |
| Build script | scratch copies, before and after, with `--bogus` | 127 before; 1 + usage message after |
| README / build guide | scratch link check + R/B checklist + command traceability | exit 0; every finding mapped |
| Running app | maintainer, Phase 12 | recorded |

**Acceptance criteria for the plan as a whole:**
* Every W, I, M, S, R and B finding in the MADR maps to a phase whose record shows it resolved, or to a
  recorded deviation.
* No check was trusted without being seen to fail.
* The tree is clean after each phase.

## Rollout and Rollback

* **Rollout.** Help ships inside the `.app` bundle, so users see v3.0 on their next build and install. There
  is no migration, no settings change and no persisted data. The README and build guide take effect on
  merge.
* **Rollback.** Each phase is one commit (plus its record commit), so `git revert <sha>` of a phase commit
  restores the previous book, test and copy together. The contract test and the book always move in the same
  commit, so a revert never leaves a red suite. Reverting Phase 9 restores the old search, and the Swift test
  file returns to being outside the target. Reverting Phase 11's `build_macos.sh` change restores the exit-127
  behaviour and nothing else.
* **Nothing is pushed.** When the plan completes, the branch is reported as ahead by N commits and the push
  command is offered.

## Execution record

Plan approved by the maintainer on 2026-09-18.

### Phase 0, executed

* SDK check: `Flutter 3.47.2 • channel stable`; `flutter pub get --enforce-lockfile` printed
  "Got dependencies!".
* Baseline, unmodified tree at `fcd70fb` plus the uncommitted records:
  * `flutter analyze`: `No issues found! (ran in 5.6s)`, exit 0.
  * `flutter test`: `03:39 +4189 ~3: All tests passed!`, exit 0.
  * `flutter test test/help_book_json_test.dart`: `+11: All tests passed!` (observed while writing the MADR,
    same tree).
* Records: MADR set to `accepted`, this plan to `in-progress`, index row updated. Amendment note added
  under 0010-MADR's frontmatter.
* Commit `6778107` (message from the hook).

### Phase 1, executed

* Added to `test/help_book_json_test.dart`:
  * `_sourceCorpus()`: every `lib/**/*.dart` file plus `MainFlutterWindow.swift`, read once in `setUpAll`.
  * `_labelAnchors`, seeded with the 7 labels the plan names (`Add Worktree` without an ellipsis, as the plan
    already corrected).
  * `_menuTitles`, `_nativeMenuTitles` and `_nonMenuTitles = {'View', 'Help'}`. These are the only
    `title: "…"` literals in `MainFlutterWindow.swift` that name a menu rather than an item (lines
    402-403, 794-795).
* New tests:
  * `quoted UI labels exist in their topic and in source`;
  * `sections carry only fields the renderer shows`;
  * `non-menu title exclusions still exist in the native source`.
* Help test: `+14: All tests passed!` (was +11). Green on the current book, as planned. The mechanisms are
  shown to fail in Phase 10.
* Gate:
  * `dart format`: 0 changed.
  * `flutter analyze`: `No issues found!`.
  * `flutter test`: `03:39 +4192 ~3: All tests passed!`.
  * JSON valid.
* Commit `011d00f`.

### Phase 2, executed

* **Contract.**
  * `connections_manager` added to the locked `getting_started` list.
  * New test `Help does not teach the 0053 falsehoods`, holding `_falsehoods0053` (W5, W6, W7).
  * `_requiredFacts0053`, merged into the existing required-facts loop.
  * 12 label anchors, all confirmed present in `lib/` first.
* **Red run** against the unchanged book (`flutter test test/help_book_json_test.dart`, exit 1) had 4 named
  failures:
  * `quoted UI labels exist in their topic and in source`: "topic quickstart must quote the UI label 'Add
    Existing Repository'".
  * `Help does not teach the 0053 falsehoods`: "not contains 'opens the macOS folder panel'".
  * `every locked topic id exists in its category, in order`: "at location [2] is 'clone_create' instead of
    'connections_manager'".
  * `required facts appear in their topics`: "topic overview must contain 'Connections'".
* **Content.**
  * Revised `overview`, `quickstart`, `clone_create` and `tabs_workspaces`.
  * New `connections_manager` topic, inserted after `quickstart`.
  * Every label was re-read from source (`connection_form.dart`, `local_repo_form.dart`,
    `connection_switcher.dart`, `edit_entry_sheets.dart`, `current_repo_indicator.dart`, `clone_sheet.dart`,
    `create_repo_sheet.dart`, `namespace_field.dart`, `remote_directory_browser.dart`, `tab_strip.dart`,
    `saved_workspaces_sheet.dart`, `session_exit_guard.dart`, `tabs_host.dart`).
  * Written through a scratch serializer that reproduces the committed file byte for byte (checked before
    each write).
* **The guards caught my own drafts three times**, each fixed in content:
  * a new sentence reused the banned W7 phrase;
  * 0010's lowercase `password` fact was lost;
  * 0010's `git identity` fact was lost.
* **Analyzer.** The first gate found 2 errors in my loop over the merged required-facts entries (an untyped
  list literal inferred `dynamic`). I typed it `<MapEntry<String, List<String>>>`. The full suite was re-run
  after the fix.
* **Gate:**
  * `dart format`: 0 changed.
  * `flutter analyze`: `No issues found!`.
  * Help test: `+15: All tests passed!`.
  * `flutter test`: `03:36 +4193 ~3: All tests passed!`.
  * JSON valid.
* Commit `0eb21cb`.

### Phase 3, executed

* **Settings copy (W9), test first.**
  * `test/settings_sheet_keymap_test.dart` was retitled `Settings discloses every setting that saves
    immediately` and now expects "Keyboard Mappings, Forget Host and Open files with save immediately".
  * Red run: exit 1, `Settings discloses every setting that saves immediately [E]` — "Found 0 widgets with
    text containing Keyboard Mappings, …".
  * `settings_sheet.dart`'s intro then changed to the plan's wording, and the test ran green (`+5`).
* **Help contract.**
  * Seven W falsehoods added (W2, W3, W4, W8, W9, W10, W11).
  * Required facts for the four Workspace topics.
  * Anchors: `More sync actions`; `Commit in ` (the static fragment of `'Commit in ${surface.label}'`, as the
    label discipline requires) plus `Focused sheet`; `Show Dashboard View` and `Show Recovery View` (native
    source); `Restore files`; `Delete snapshot`; `Clear output`; `Open files with`.
  * All were confirmed in the corpus first.
* **Red run:** exit 1, with 3 named failures:
  * the label-anchor test ("topic workspace_chrome must quote the UI label 'More sync actions'");
  * the falsehoods test ("not contains 'Leading controls: Back, Forward, then Fetch'");
  * the required-facts test.
* **Content.** Revised `workspace_chrome`, `file_view_and_output`, `dashboard_recovery_activity` and
  `settings`. Facts were re-read from:
  * `repository_context_bar.dart` (order, watch-dot colours, sync overflow);
  * `workspace_view_options.dart`;
  * `output_log.dart` (`maxLines = 2000`);
  * `dashboard_sheet.dart`;
  * `recovery_sheet.dart` (`snapshotExpiry` of 7 days, Restore…/Actions items);
  * `activity_center.dart` (phases, tooltip);
  * `dock_progress.dart`;
  * `settings_sheet.dart` (`_fetchChoices`, `_minTimeoutSecs = 5`);
  * `git_service.dart:1089-1094`.
* **The guards caught one more of my own drafts:** 0010's `Auto-fetch` fact was lost from `settings`, and I
  restored it.
* **Gate.**
  * The first `dart format` check flagged my settings-test edit (exit 1). I formatted it and re-ran the whole
    gate on the final bytes:
    * `dart format`: 0 changed.
    * `flutter analyze`: `No issues found!`.
    * `flutter test`: `03:35 +4193 ~3: All tests passed!`.
    * Targeted Help + Settings tests: `+20`.
    * JSON valid.
* Commit `205b0d0`.

### Deviation D1 (2026-09-18): a failed push after a commit never shows "Committed, but the push failed."

* **Found.** During Phase 4, before any Phase 4 edit, and checked by reading the unmodified tree. MADR M3,
  and this plan's `committing` required fact, say a failed push shows "Committed, but the push failed."
  (`commit_composer_controller.dart:379`). That message is set only when the push callback **throws**. The
  real callback is `_push`, which runs through `runLogged` (`lib/features/common/busy_action.dart:137-150`);
  `runLogged` catches every error, shows an error dialog with git's message, logs to Output and returns
  `false`, so it never throws. The commit sheet has also already closed when the commit landed
  (`commit_dialog.dart:82-94`).

  What a user sees is: an error dialog, the command in Output, the operation marked Failed in Activity, and
  the commit kept locally. `test/commit_composer_controller_test.dart:84-101` covers the path production
  takes (`push: () async => false`). No test covers the throw branch.
* **Decision (maintainer).** Teach the real behaviour.
  * The required fact is struck through above and replaced with `error dialog` and `Failed`.
  * MADR 0053 carries Amendment 0053.1 correcting M3.
  * No code change: the controller's catch branch remains a guard for any future push callback that throws.
  * No files added to the phase.

### Phase 4, executed

* **Deviation D1** was raised and resolved before any Phase 4 edit (see its entry; records commit
  `f5da8fe`).
* **Contract.**
  * `committing` and `sync_fetch_pull_push` added to the locked `panels` list.
  * W1, W17 and W18 added to `_falsehoods0053`.
  * Required facts added for the four topics, with D1's `error dialog` and `Failed` replacing the
    controller string.
  * Anchors:
    * the conflict-side labels are built as `'Use ${sides.ours}'` from `conflictSideLabels`, so they are
      anchored by their static fragments `Ours (HEAD)`, `Theirs (incoming)`, `Onto (ours)` and
      `Commit (theirs)`;
    * the background-push status line by its literal first half,
      `Committed. Pushing… you can close this; it continues in the `;
    * the other 14 as whole labels.
  * All were confirmed in the corpus first.
* **Red run:** exit 1, with 4 named failures:
  * the label-anchor test ("topic tab_repository must quote the UI label 'Ours (HEAD)'");
  * the falsehoods test ("not contains 'expands the composer in the task dock'");
  * the topic-order test ("at location [1] is 'tab_history' instead of 'committing'");
  * the required-facts test.
* **Content.**
  * Revised `tab_repository`: commit detail moved out; right-click menu, commit bar, conflict labels,
    pending banner and the corrected shortcut callout added.
  * New `committing` and `sync_fetch_pull_push`.
  * Revised `tab_stashes`.
  * Facts were re-read from `repo_status_view.dart`, `conflict_view.dart`, `commit_composer.dart`,
    `commit_dialog.dart`, `commit_composer_controller.dart`, `busy_action.dart`, `stash_view.dart`,
    `repository_clean_state.dart`, and `git_service.dart` (fetch/pull/push argv; pull is not journaled).
  * Chips moved with their verbs: commit chips to `committing`, sync chips to `sync_fetch_pull_push`.
    `tab_repository` keeps its staging and diff chips.
* **Gate:**
  * `dart format`: 0 changed.
  * `flutter analyze`: `No issues found!`.
  * Help test: `+15`.
  * `flutter test`: `03:38 +4193 ~3: All tests passed!`.
  * JSON valid.
* Commit `4fd2cff`.

### Phase 5, executed

* **Contract.**
  * `branch_sync_recovery` inserted after `tab_branches` in the locked list.
  * W14, W15 and W16 added to `_falsehoods0053`.
  * Required facts for the four topics.
  * 21 anchors, all confirmed in `lib/` first. Two are static fragments: `Reconcile with ` and
    `History of ` (the latter is a required fact, not an anchor).
* **Red run:** exit 1, with 4 named failures:
  * the label-anchor test ("topic tab_history must quote the UI label 'Filter by author, date, or path'");
  * the falsehoods test ("not contains 'Hide merges is a separate chip'");
  * the topic-order test ("at location [5] is 'tab_stashes' instead of 'branch_sync_recovery'");
  * the required-facts test ("topic tab_history must contain 'path:'").
* **Content.**
  * Revised `tab_history`, `tab_branches` and `tab_worktrees`.
  * New `branch_sync_recovery`: one heading per sync state, plus Reconcile's three paths, the
    unrelated-histories merge, stale cleanup, Set upstream vs Publish, the pending banner, and the Advanced
    menu.
  * Facts were re-read from `branch_detail.dart` (585-840), `branches_view.dart` (1214 Publish =
    `push(setUpstream: true)`; 1420-1540; 1790-1945), `branch_navigator.dart` (chips; Review toolbar
    940-1130), `create_tag_sheet.dart`, `history_view.dart` (filter bar 1800-2010),
    `rebase_sheet.dart`, and `worktrees_view.dart` (row menu 470-590, strip 870-990).
* **Gate:**
  * `dart format`: 0 changed.
  * `flutter analyze`: `No issues found!`.
  * Help test: `+15`.
  * `flutter test`: `03:37 +4193 ~3: All tests passed!`.
  * JSON valid.
* Commit `b4bd008`.

### Phase 6, executed

* **Contract.**
  * `forge_requests_and_issues` and `forge_ci` inserted after `tab_forge`.
  * W19, W20 and W21 added to `_falsehoods0053`.
  * Required facts for the three topics.
  * 18 anchors, all confirmed in `lib/`. `Logs are available once it completes.` is anchored as the
    sentence after the literal's `\n` (`run_jobs_view.dart:101`), as the plan allowed.
* **Red run:** exit 1, with 4 named failures:
  * the label-anchor test ("topic tab_forge must quote the UI label 'No blockers'");
  * the falsehoods test ("not contains 'merged and closed work is not a status chip'");
  * the topic-order test ("at location [8] is 'tab_worktrees' instead of 'forge_requests_and_issues'");
  * the required-facts test.
* **Content.**
  * Revised `tab_forge`: panel, Inbox and Browse, open/closed/merged, and the detail pane.
  * New `forge_requests_and_issues`: create forms, rows and menus, merging, review and editing, issues.
  * New `forge_ci`: jobs, logs, and the difference between GitHub and GitLab logs.
  * Chips moved with their verbs: request chips to `forge_requests_and_issues`, re-run/retry chips to
    `forge_ci`.
  * Facts were re-read from `merge_readiness.dart`, `create_pr_form.dart`, `github_panel.dart`
    (auto-merge 836-915) and `run_jobs_view.dart`. The rest come from the Forge audit's cited lines, and
    every quoted label is pinned by an anchor.
* **Guards caught two of my drafts:**
  * 0010's `New Issue` fact was missing from `tab_forge`;
  * 0010's OUT-seam guard caught "New issue: the …", which contains the banned palette prefix `issue:`.
    I reworded it; `issue:`, `request:` and `ci:` each now occur 0 times in the new text.
* **Gate:**
  * `dart format`: 0 changed.
  * `flutter analyze`: `No issues found!`.
  * Help test: `+15`.
  * `flutter test`: `03:41 +4193 ~3: All tests passed!`.
  * JSON valid.
* Commit `bb830f7`.

### Deviation D2 (2026-09-18): 0010's contract requires the false word "Code" in the viewer topic

* **Found.** During Phase 7, when the corrected content ran against the contract. 0010's `required` map
  requires `'Code'` in `viewer_and_remote_edit`, but the viewer's toggle tooltips are **Source** and
  **Preview** (`lib/features/viewer/viewer_window.dart:429, 436`). "Code" appears in the UI nowhere, only in
  the internal enum `_ViewerMode.code`. It is the same falsehood as W12. The plan fixed W12's sentence and
  required `Source`, but did not list 0010's `'Code'` fact as needing to change. Checked by reading the tree.
  Every other 0010 fact for Phase 7's topics still holds.
* **Decision (maintainer).** In 0010's list, replace `'Code'` with `'Source'`, with a comment citing 0053 W12.
  The assertion is not loosened: it requires the toggle's real name, and `_falsehoods0053` separately bans
  "Switch Code and Preview". No MADR amendment, because W12 already decides this. No file is added:
  `test/help_book_json_test.dart` is already in Phase 7's scope.

### Phase 7, executed

* **Contract.**
  * W12 (twice) and W13 added to `_falsehoods0053`.
  * Required facts for the eight topics.
  * 13 anchors, all confirmed in `lib/`.
  * `Overlay` is **not** anchored: it occurs 83 times in `lib/`, mostly as Flutter's `Overlay` widget, so its
    presence proves nothing. The same reasoning the plan applied to `Source`; a required fact covers it
    instead.
  * New test `every menu item title appears in the book`, over `kMenuBarMenus` plus the native titles.
* **Red run:** exit 1, with 4 named failures, including the new menu test. Its reason listed the 24 titles
  the v2.0 book never mentioned:
  * Repository: Abort Pending Operation…
  * Branch: New Branch…, New Tag…, Merge into Current Branch
  * Stash: Apply Stash, Pop Stash, Drop Stash…, Apply Latest Stash, Pop Latest Stash, Clear All Stashes…
  * Forge: New Pull Request…, New Merge Request…, Approve Merge Request, Merge Pull Request…, Merge Merge
    Request…
  * Worktree: Lock Worktree, Unlock Worktree, Move Worktree…, Repair Worktree, Repair All Worktree Links,
    Prune Stale Worktrees
  * View: Focus Canvas, Focus Task Dock, Focus Activity
* **Content.**
  * Revised `viewer_and_remote_edit`, `diffs_blame_history`, `drag_and_drop`, `secondary_windows`,
    `feature_palette`, `undo_recovery` and `tool_health`.
  * `menus_and_keymap` gained a Menus list of every menu's items, taken from `kMenuBarMenus`' structure plus
    the native View and Help items. Its 62 chips are untouched.
  * Facts were re-read from `viewer_window.dart` (Preview default for Markdown/HTML/SVG, lines 85-100),
    `app_shell.dart` 530-790 (undo prompts, host key, remote edit), `diff_view_controls.dart`,
    `multi_file_review.dart`, `image_diff_view.dart` (Overlay at opacity 0.5), `drop_registry.dart`,
    `environment_health_sheet.dart`, `command_palette.dart` and `blame_sheet.dart`.
* **Deviation D2** was raised and resolved (see its entry; records commit `247d3f8`).
* **Gate:**
  * `dart format`: 0 changed.
  * `flutter analyze`: `No issues found!`.
  * Help test: `+16`.
  * `flutter test`: `03:41 +4194 ~3: All tests passed!`.
  * JSON valid.
* Commit `b000061`.
