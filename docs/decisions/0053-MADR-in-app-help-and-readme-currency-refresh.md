---
status: "accepted"
date: 2026-09-18
decision-makers: [Maintainer]
consulted: [macos/Runner/help_book.json v2.0, test/help_book_json_test.dart, lib/ as of fcd70fb, records 0011–0052, README.md, docs/BUILD_MACOS.md, build_macos.sh]
informed: [Magic Git contributors]
verified: 2026-09-18
---

# Bring the in-app Help Book, the README and the macOS build guide back into agreement with the shipped app, widen Help to cover what 0010 never had to, and add guards against drift that do more than check chords

## Context and Problem Statement

Magic Git ships a native Help window (Help ▸ Support & Help, ⌘?). It is a SwiftUI topic browser
(`macos/Runner/HelpView.swift`, `HelpWindowController.swift`) that renders one hand-written JSON book,
`macos/Runner/help_book.json`. The book is bundled as a resource (`macos/Runner.xcodeproj/project.pbxproj:34`).
The menu item is installed natively (`macos/Runner/MainFlutterWindow.swift:801-808`). Nothing in the Flutter
UI links into Help.

The book was last rewritten as v2.0 on 2026-08-15, under
[0010-MADR-in-app-help-book-rewrite.md](../0010-MADR-in-app-help-book-rewrite.md) (commit `345ce75`).
Two small edits followed (`69e784d` on 2026-09-03, `e2f72bf` on 2026-09-08). Since the rewrite, **196
commits have touched `lib/`** and records **0011 through 0052** have been written. Many of those changed
what a user sees, including:

* the commit surface ([0012-MADR-commit-composer-focused-sheet.md](../0012-MADR-commit-composer-focused-sheet.md));
* fetch/pull/push progress ([0020](../0020-MADR-fetch-pull-push-lag.md), [0023](../0023-MADR-commit-and-push-perceived-freeze.md));
* create/clone destinations and namespaces (0021, 0031, 0032, 0036, 0037);
* the preferred editor setting ([0048](../0048-MADR-preferred-editor-and-terminal-as-settings.md));
* Branches guided recovery ([0051](../0051-MADR-branches-guided-recovery-for-out-of-sync-repositories.md));
* the sidebar info card and location glyphs
  ([0052](0052-MADR-sidebar-info-card-location-row-and-plain-connections-button.md)).

Help was not updated for any of them.

0010 bound Help's **shortcuts** to the keymap, and that part has held:

* `kKeymapActions` (97 actions) and `kMenuBarMenus` are byte-identical at `345ce75` and `HEAD`, by an ID and
  title diff.
* `test/help_book_json_test.dart` passes 11/11 on the pinned Flutter 3.47.2 (run 2026-09-18).

0010 did not bind the book's **prose** to anything. Every sentence that names a button, a label, a menu
location or a default is checked only by the "required facts" substring list, and that list checks that
Help *says* something, not that the app still *does* it. So the tests stay green while the prose goes stale.

The root `README.md` (39 lines, last changed 2026-08-15 in `9ecf1f7`) has the same problem. So does
`docs/BUILD_MACOS.md` (87 lines, last changed 2026-08-15 in `9ecf1f7`), the build and install guide the
README sends builders to. It predates [0042](../0042-MADR-the-macos-build-mutates-its-own-inputs.md), which
replaced the build script's entitlement mechanism, and the script's Flutter pinning logic. Both are in scope
for this record.

The question this record answers:

> What must be corrected, added and restructured in the in-app Help Book, the README and the macOS build
> guide so that they describe the app, and the way it is built, as it ships today — and what should guard them so the next 200 commits don't
> silently undo the work again?

### Audit method

* **The book.** I flattened the whole book (`help_book.json`, 6 categories, 24 topics, 1 shortcut
  catalogue) and read every sentence.
* **Four parallel read-only audits** covered disjoint scopes:
  (a) Repository, commit, stashes and diffs;
  (b) Branches, History and Worktrees;
  (c) Forge;
  (d) connections, chrome, sessions, windows, viewer, Settings and the Help window itself.
  Each classified every in-scope Help sentence as CORRECT / WRONG / STALE-INCOMPLETE with `file:line`,
  and listed user-visible capabilities Help omits, with verbatim UI strings.
* **Verification.** I checked every WRONG claim below against the cited source myself before recording
  it. Items the audits marked INFERRED are either marked so here or left out.
* **Direct reads.** I read the Settings sheet, the settings defaults, the tool catalogue, the Help Swift
  sources and tests, and the README directly.
* **Build guide.** I read `docs/BUILD_MACOS.md` line by line against `build_macos.sh`,
  `macos/Runner/Configs/AppInfo.xcconfig`, `.gitignore:67-69` and `project.pbxproj:677`
  (`CODE_SIGN_ENTITLEMENTS = "$(MG_RELEASE_ENTITLEMENTS)"`). I ran one experiment on a **scratchpad copy**
  of `build_macos.sh`, never on the tracked script: `bash ./build_copy.sh --bogus`, which exits 127 (see B8).
  I did not run a build.
* **Not done.** No live `.app` was run. Every finding comes from source, so a string that is built at
  runtime could render slightly differently from the literal quoted here.

### Relationship to earlier records

* **[0010-MADR-in-app-help-book-rewrite.md](../0010-MADR-in-app-help-book-rewrite.md)** stays accepted. This
  record keeps its gates G1 (JSON + native `HelpView`), G2 (teach factory defaults), G3/G4 (chips bound to
  `kKeymapActions`), G5 (don't teach unfinished seams) and G7 (⌘? is Help, ⌘/ is the shortcuts sheet).
  It **amends** two things:
  * the **locked topic list** (G6's information architecture), because the product has outgrown it;
  * the **category-id ban on `troubleshooting`**. That ban was aimed at the v1.1 category's stale content,
    not at the idea of troubleshooting.
* 0010-PLAN Phase 7 (maintainer review of the v2.0 book on a running `.app`) is still open. The book it would
  review is now the one found stale here, so that review is better done once, against the result of this
  record.
* This record does **not** reopen any product decision in 0011–0052. It describes them.

## Findings

IDs are stable so that a plan can cite them. **W** means Help says something false today. **I** means a
topic is true but incomplete in a way that misleads. **M** means a capability has no Help coverage at all.
**S** means a defect in the Help machinery. **R** means the README. **B** means the macOS build guide
(`docs/BUILD_MACOS.md`) or the script it documents.

### W — Help teaches something the app no longer does (all verified)

| ID | Topic | Help says | App does | Evidence |
|---|---|---|---|---|
| W1 | `tab_repository` | "⌘G expands the composer in the task dock" | ⌘G, the **Commit…** button and the Continue primary open the **focused sheet** by default. The dock is opt-in through View options: "Commit in Focused sheet" / "Commit in Task dock". | `lib/core/settings/repository_workspace_prefs.dart:128-144`; `lib/features/repository/repo_status_view.dart:875-913`; `lib/features/common/workspace_view_options.dart:84-92` |
| W2 | `workspace_chrome` | Leading "Back, Forward, then Fetch · Pull · Push · Sync"; trailing "Stash, Refresh, Activity, view options" | The order is Back, Forward and identity/status, then View options, Activity, Stash, Refresh, and the sync group **last**. | `lib/features/common/repository_context_bar.dart:116-215` |
| W3 | `workspace_chrome` | Sync group has "one emphasized" verb | Every verb that applies right now is accented. The **recommended** verb carries the ↓N ↑M badge. Below 720 px only the recommended verb keeps a button. | `repository_context_bar.dart:629-690` |
| W4 | `workspace_chrome` | "Below 720 px a ⋯ control opens Repository details" | It is a hover tooltip with the accessibility label "Repository details", and nothing opens. | `repository_context_bar.dart:549-571` |
| W5 | `tabs_workspaces` | Quit confirms "when the tree is dirty or …" | Quit **always** asks "Are you sure you want to quit?". When work is at risk the title becomes "Some repositories have active items pending…". | `lib/features/tabs/tabs_host.dart:359-372`; `lib/features/common/session_exit_guard.dart:100-106` |
| W6 | `tabs_workspaces` | Saved Workspaces "alias a set of tabs" | Aliases belong to the **active tab**: "Rename active tab" opens "Rename Tab", and a blank entry clears it. Unsaved repos can't be aliased ("Only saved repositories can have aliases"). | `lib/features/tabs/saved_workspaces_sheet.dart:47-55, 226-244` |
| W7 | `quickstart` | "Add existing repository opens the macOS folder panel" | It opens the **Add Existing Repository** sheet, which has these fields: Location (Local / this session / a saved connection), Folder (Choose… / Browse…), Save repository, Label, filesystem monitor, and Scoped work-tree repo (dotfiles). The folder panel opens only from Choose… on a local location. | `lib/features/connection/local_repo_form.dart:898-1248` |
| W8 | `dashboard_recovery_activity` | "View ▸ Show Dashboard" | The menu item is **Show Dashboard View**. Recovery's **Show Recovery View** is never named. | `macos/Runner/MainFlutterWindow.swift:432-436` |
| W9 | `settings` | "Changes apply after Save, except Keyboard Mappings and Forget Host" | **Opening files ▸ Open files with** also saves immediately. The Settings sheet's own intro sentence has the same omission. | `lib/features/settings/settings_sheet.dart:175-178, 245-265` |
| W10 | `settings` | "network (fetch/pull/push) defaults to 3 minutes" | Three minutes is now a **stall budget**. A transfer is killed after 3 minutes with *no output*, and one that keeps printing may run up to 30 minutes. | `settings_sheet.dart:182-190`; `lib/core/git/git_service.dart:1089-1094` |
| W11 | `settings` | "Open Settings from … or this book" | The Help window has no control that opens Settings. | `macos/Runner/HelpView.swift` (no such action) |
| W12 | `viewer_and_remote_edit` | "Switch **Code** and Preview"; "On a local repo, Open uses the macOS opener" | The toggle is **Source** / Preview, and Preview is the default for Markdown, HTML and SVG. **Open file** uses Settings ▸ Open files with (default "System default"), for local files and for SSH temp copies alike. | `lib/features/viewer/viewer_window.dart:88-99, 426-438`; `lib/features/viewer/remote_edit_service.dart:117-119, 181-183` |
| W13 | `secondary_windows` | Key equivalents are stripped "while a pop-out is key" | Stripping applies to **native secondary windows** (History, detached Status), not to the in-window diff pop-out. | `MainFlutterWindow.swift:31-93` |
| W14 | `tab_history` | "Hide merges is a separate chip" | It is a **checkbox** in the advanced filter row, which the slider icon ("Filter by author, date, or path") opens. | `lib/features/history/history_view.dart:1832, 1952-1955` |
| W15 | `tab_branches` | "Bulk pin, hide, and delete-if-merged sit on the list"; "pin, hide" as row verbs | In **Review** mode, selecting 2+ branches turns the detail pane into "N branches selected" with Pin / Unpin / Hide / Delete if merged…. There is no single-branch Hide: hidden branches come back through the eye toggle, then **Unhide**. | `lib/features/branches/branches_view.dart:690-722`; `branch_navigator.dart:1034, 2098` |
| W16 | `tab_branches` | "Unmerged branches confirm" (on delete) | **Every** delete confirms. An unmerged branch gets a second **Force Delete** confirmation. A branch checked out in a worktree offers **Remove Worktree and Delete**. | `branches_view.dart:1299-1390` |
| W17 | `tab_stashes` | "Apply latest, Pop latest, and Clear all are Stash-menu only" | They are also in the Stashes header ≡ menu. This was already false at `345ce75`. | `lib/features/stash/stash_view.dart:546-606` |
| W18 | `tab_repository` | Callout: Pull with Rebase/Merge, Push and Set Upstream, Push Tags, Force Push, Unstage All and Abort are "Repository menu only" | The pull/push variants are in the context bar's **More sync actions** overflow. **Unstage All** is a button in the commit bar. **Abort <Verb>** is on the pending banner. (The "no default shortcut" part is correct.) | `repository_context_bar.dart:620-627`; `repo_status_view.dart:2165-2171`; `lib/features/common/pending_op_banner.dart:92-103` |
| W19 | `tab_forge` | "merged and closed work is not a status chip" (implies it can't be reached) | **Show closed pull requests / merge requests** widens the list to closed **and** merged items. The detail pane shows State, and **Reopen** is offered on closed items. | `lib/features/github/github_panel.dart:410-421, 686-691`; `lib/features/gitlab/gitlab_panel.dart:444-455` |
| W20 | `tab_forge` | "Update branch and Rebase onto target sit on the detail More menu" | Both are **action-bar buttons**, shown only when the branch needs updating. The More menu holds Comment…, Request changes… (GitHub), Mark ready / Convert to draft, Edit…, and Close/Reopen. | `github_panel.dart:892-898, 930-966`; `gitlab_panel.dart:937-943, 972-1000` |
| W21 | `tab_forge` | "New Issue is Forge-menu only" | It is also the **+** ("New issue") button on the Issues section header, and a palette command. | `lib/features/forge/project_sections.dart:115-116`; `lib/features/common/command_palette.dart:169-172` |

### I — True but incomplete in a way that misleads

* **I1 `overview`.** Help lists panels and File tabs. It never mentions the sidebar **session info card**
  (Repository row with ahead/behind, dirty and conflict dots and a status tooltip; **Location** row "This
  Mac" or the SSH host), the fixed **Connections** button, or **Logout** ("Log out?" / "Log Out").
  Sources: `lib/features/switcher/current_repo_indicator.dart:104-219`,
  `lib/features/switcher/connection_switcher.dart:74-138`.
* **I2 `quickstart`.** The SSH form ("Add SSH Remote") has a required **Repository path** field, a **Git
  directory** field (scoped/dotfiles repos: GIT_DIR, with the path used as GIT_WORK_TREE), **Save connection**
  + Label, and **GitLab token / GitHub token** fields. Help calls the tokens "host tokens".
  Source: `lib/features/connection/connection_form.dart:393-480`.
* **I3 `clone_create`, Clone.**
  * Source has a **URL** tab and the forge browse. The browse lists repos you own, so an organisation's repo
    needs URL.
  * Help's "Location" step is really **Folder name** + **Parent folder** (Choose… / Browse…), **Create parent
    folders if missing**, fsmonitor, and **Save to Local Repositories** + Label.
  * Progress streams live.
  * Source: `lib/features/workspace/clone_sheet.dart:711-1183`.
* **I4 `clone_create`, Create.**
  * Target lists This Mac, saved connections, and "<host> (this session)".
  * Remote adds Visibility, Forge host, Project description, Replace existing origin, and Existing remote.
  * Details adds a searchable **Namespace (optional)** field with **Recently active** and **All you can create
    in** groups. Recency is learned from repositories you open (0031/0032/0037).
  * First commit is "Add a README" or "Commit all existing contents".
  * Identity prefills from Settings and is written to the repo, not to Settings (0021).
  * The result **opens in its own tab**, or focuses an existing one. It stays in the current tab only for an
    unsaved local result or the unsaved current session. At 8 tabs it is refused (0036).
  * Sources: `lib/features/workspace/create_repo_sheet.dart:116, 921-1343`;
    `create_repo_steps/namespace_field.dart:334-452`; `workspace_open_in_tab.dart:24-32`.
* **I5 `tabs_workspaces`.** Help omits the per-tab ✕, the **+** button ("Maximum of 8 tabs open"), drag to
  reorder, the location glyph on each tab, and that Close Tab is disabled with one tab open. It also omits
  what a Saved Workspace restores: the alias and layout preset per repo, plus the active tab.
  Sources: `lib/features/tabs/tab_strip.dart:63-108, 280-282`; `saved_workspace_actions.dart:250, 283`.
* **I6 `workspace_chrome`.**
  * The watch-health dot's colours are unexplained: green for a live watcher, orange for polling, grey for
    stopped (`repository_context_bar.dart:288-294`).
  * View options also holds the commit-surface choice (W1).
  * The overflow is named **More sync actions**.
  * Hovering a dimmed sync verb explains why it is dimmed: "A fetch or push is already running", "This branch
    has no upstream yet", "No remote is configured", "Repository is disconnected", "Another repository
    operation is running" (`repo_status_view.dart:1998-2023`).
* **I7 `file_view_and_output` / `output_log`.**
  * Fetch, pull, push, sync, Fetch & Prune and clone now **stream live** into Output (`--progress`).
  * After a pull, push or sync, Output lists the pulled or pushed files.
  * The header has Clear output / Hide output view and a resize handle, and scrollback is 2000 lines.
  * Pull runs as two steps (fetch, then merge/rebase), so a Pull shows two commands.
  * Sources: `lib/core/output/output_log.dart:60, 148-161`; `lib/features/repository/output_view.dart:117-158`;
    `git_service.dart:5218-5272`.
* **I8 `dashboard_recovery_activity`.**
  * Dashboard also shows Authentication (this Mac and the host), Link latency, Repository upstream state,
    Commit activity (30 days), Commands (this session), Change watcher, and Repository footprint with
    **Measure** (`lib/features/dashboard/dashboard_sheet.dart:159-797`).
  * Recovery has actions: **Restore…** (Checkout this state, Create branch here…, Reset soft/hard, Copy hash)
    and snapshot **Actions** (Restore files, Delete snapshot). Snapshots are taken before each discard or
    delete and kept for **7 days** (`lib/features/recovery/recovery_sheet.dart:187, 393-432`).
  * Activity shows Queued / Running / Completed / Failed / Canceled with live timers, and row buttons
    Output / Undo / **Recovery**. Its icon spins while work runs (`lib/features/common/activity_center.dart:58-108, 282-357`).
  * The Dock icon shows progress: indeterminate for network operations, a percentage for clone
    (`lib/core/local/dock_progress.dart`).
* **I9 `tab_repository`.**
  * Conflict actions are labelled **Use Ours (HEAD)** / **Use Theirs (incoming)**. During a rebase they
    become **Use Onto (ours)** / **Use Commit (theirs)** (`lib/features/repository/conflict_view.dart:11-14`).
  * The commit bar shows "N staged files · <branch>" with Unstage All, Stage All and Commit…
    (`repo_status_view.dart:2131-2211`).
  * The pending banner's button is **Abort <Verb>**, and since 0051 the banner also appears in Branches.
* **I10 `tab_history`.**
  * Filter aliases `path:`, `commit:`, `since:` and `until:` also work.
  * A bare 5+ character hash finds a commit.
  * Wildcards and quoting are supported.
  * The advanced row has author, dates and path fields.
  * The footer shows a match count and **Clear filters**.
  * Bulk cherry-pick/revert is disabled when the selection contains a merge commit.
  * Sources: `lib/features/history/log_filter.dart:74-82`; `history_view.dart:1135-1137, 1812-1817, 1880-2006`.
* **I11 `tab_branches`.**
  * The context-bar primary **Fetch & Prune** now offers a stale-branch cleanup afterwards (see M5).
  * The empty-selection dashboard in Review adds Merged and Conflicts filter chips and **Scan for conflicts**.
  * Help's "no Rebase item on the context menu" is still true, but **Reconcile…** now offers a rebase.
  * The drag-onto-HEAD dialog is titled "Combine with <current>".
* **I12 `tab_worktrees`.**
  * Overview chips: branch or "(detached abc1234)", missing, locked / locked: <reason>, main worktree, open,
    capped at 2 plus "+N" (0049).
  * With only the main worktree, the empty state **No worktrees yet** replaces the list
    (`lib/features/worktrees/worktrees_view.dart:836-838, 1103-1142, 1304-1319`).
* **I13 `tab_forge`.**
  * Inbox has a fifth, orthogonal **No blockers** chip, and Inbox is the saved default.
  * Inbox holds open requests, failed or running CI, and open issues.
  * Every section collapses (state persisted), and Labels are view-only.
  * GitHub ⌥⌘R re-runs **failed** jobs only; the Forge menu names it "Re-run Failed Jobs".
  * Sources: `lib/features/forge/forge_inbox.dart:170, 254-280`; `github_panel.dart:1461-1483`;
    `lib/features/common/menu_bar_spec.dart:196`.
* **I14 `diffs_blame_history`.**
  * Image diffs have three modes (**Side by Side / Overlay / Slider**), with dimensions and sizes, and fall back
    to "Binary image change" with Open in Default App.
  * Blame is also on the Changes and file-tree menus.
  * Sources: `lib/features/common/image_diff_view.dart:200-412`; `lib/features/repository/file_view.dart:314`.
* **I15 `drag_and_drop`.** Four drops are missing:
  * a stash card onto Repository (Apply / Pop);
  * a commit onto Branches ("New branch from <sha>");
  * a commit onto History ("Show <sha> in History");
  * a branch onto History ("Show history of <name>").

  Dragging a selected row carries the whole selection (`lib/features/dnd/drop_registry.dart`,
  `repo_status_view.dart:3078-3080`).
* **I16 `undo_recovery`.**
  * Undo can prompt **Files Changed Since** → Overwrite.
  * A stale undo is discarded with an error.
  * Clicking a hinted toast runs the undo.
  * Sources: `lib/features/app_shell.dart:541-572`; `lib/features/common/undo_toast.dart:17-20`.
* **I17 `tool_health`.**
  * The doctor sheet is **Environment health** (Re-check, Install with …, Install from file…, Copy command).
  * The banner has Dismiss.
  * The tiers are labelled Required / Feature / Optional.
  * Minimums: git ≥ 2.24, gh ≥ 2.0. fswatch (macOS hosts) and inotifywait (Linux hosts) are optional, with
    polling as the fallback.
  * Sources: `lib/core/settings/tool_catalog.dart:68-170`; `lib/features/settings/environment_health_sheet.dart`.
* **I18 `secondary_windows`.** The detached Status window's only entry point is Worktrees ▸ **Open in
  Window**. Its title is "Status — <repo> (<connection>)". It shows "Waiting for session…" and a
  reconnecting banner, and it works on linked worktrees (0047).
  Source: `lib/features/window/secondary_window_main.dart:677-686, 1029-1049`.
* **I19 `feature_palette`.**
  * go: also lists **Switch to tab <name>** and **Open workspace <name>**.
  * app: has **Manage Saved Workspaces**.
  * git: has **Recovery: Browse Reflog & Snapshots**.
  * Sources: `lib/features/common/command_palette.dart:421, 481-548`.

### M — Capabilities with no Help coverage at all

* **M1 — Connections Manager as a place.**
  * Local and Remote Repositories sections; expandable connections with "N repos"; "(unsaved)" sessions; the
    worktree chip.
  * **Edit connection** (a blank secret keeps the stored one), **Delete connection**, **Remove repository**,
    the per-entry fsmonitor toggle.
  * **Edit repository**: Label, Path on the host, and Git directory for scoped remote entries (`bd4df81`).
  * The remote folder browser **Choose a folder** (dotfiles toggle, Choose This Folder).
  * One location glyph everywhere (0052.1/0052.2).
  * One repository name everywhere: tab alias, otherwise the folder name (0052).
  * Sources: `connection_switcher.dart:312-733`; `lib/features/switcher/edit_entry_sheets.dart:160-552`;
    `lib/features/workspace/remote_directory_browser.dart:146-230`; `lib/features/common/session_location.dart`.
* **M2 — Scoped / dotfiles repositories.**
  * Auto-detection on Add Existing.
  * Git directory on SSH profiles and remote entries.
  * fsmonitor is disabled while scoped.
  * Sources: `local_repo_form.dart:1158-1248`; `connection_form.dart:454-480`.
* **M3 — The commit flow in full.**
  * Sheet vs dock (W1).
  * The sheet closes when the local commit lands and the push **continues in the background** ("Committed.
    Pushing… you can close this; it continues in the background.").
  * Accept alone triggers a quiet fetch.
  * Co-authors; Load recent / Load template; **Regenerate** when the staged set changes; **Edit** for a
    prepare-commit-msg message; the GPG notice.
  * "Committed, but the push failed."
  * Sources: `lib/features/repository/commit_dialog.dart:61-139`; `commit_composer.dart:171-501`;
    `commit_composer_controller.dart:379`.
* **M4 — Fetch, pull, push and their guardrails.**
  * What each verb runs: Fetch is `--all --prune`, submodules off, jobs 4. Pull is fetch then ff-only / merge /
    rebase against @{upstream} per Settings.
  * **Remote has new commits** → Pull, then Push / Push anyway.
  * **Force push** confirmation.
  * Staging stays usable during fetch and push; pull and sync lock it.
  * Auto-fetch (every 5 minutes by default).
  * Sources: `repo_status_view.dart:1001-1248`; `git_service.dart:5170-5272`.
* **M5 — Branches guided recovery (0051, shipped 2026-09-17).**
  * Row chips **Not published** / **Diverged**, the **gone** marker, and the ahead/behind bar.
  * Detail-pane explanations for each state, including **share no common history**.
  * **Reconcile…**: Merge / Rebase / Reset, with Reset reversible through ⌘Z.
  * **Merge (allow unrelated histories)…** → Merge Anyway.
  * **Clean up stale branches?** after Fetch & Prune, with a Force Delete follow-up.
  * **Set upstream** validation that points to Publish.
  * The pending-operation banner in Branches.
  * The detail menu renamed **Advanced**, with the full item list.
  * Sources: `branch_navigator.dart:1725-1905, 2022-2109`; `branch_detail.dart:593-835`;
    `branches_view.dart:1444-1531, 1798-1822, 1909-1941`.
* **M6 — Branches review tooling.**
  * **Compared with** base picker; **Sort** (Smart/Activity/Name/Ahead/Behind); **Filter** (Unpublished,
    Upstream gone, In a worktree, Has a request, No request, Failing CI, Mine).
  * Comparison inspector: Overview / Changes / Commits, and **Readiness** (git 2.38+).
  * Bulk delete sheet "Delete merged into <base>".
  * Stale toggle "N stale (no commit in 3 months)".
  * Tags: local only / differs from <remote>, Push tag, Push N to <remote>, Delete Local Only / Local and on
    <remote>, and the **Create Tag** sheet (Annotated, message, push after creating).
  * Remote-branch delete.
  * Keyboard: Home/End/PgUp/PgDn, type-to-find, ⇧F10, Esc.
  * Sources: `branch_navigator.dart:539-2155`; `branch_detail.dart:1153-1588`;
    `lib/features/branches/create_tag_sheet.dart`; `branch_bulk_delete_sheet.dart`.
* **M7 — History extras.**
  * **Interactive rebase** sheet: Pick/Squash/Fixup/Drop, drag to reorder or squash; Reword unavailable;
    disabled on the root commit.
  * Branch-scoped history "History of <branch>" (from Branches ▸ Advanced ▸ Open reachable history).
  * Diff header: wrap, Copy full SHA, larger window, actions menu.
  * The Recovery icon on the filter bar.
  * J/K navigation; a click on the minimap scrolls there.
  * Sources: `lib/features/history/rebase_sheet.dart:233-303`; `history_view.dart:421-436, 1635-1642, 1859, 2612-2672`.
* **M8 — Worktrees verbs beyond the menu.**
  * Row menu: **Open in Window**, Reveal in Finder, Open in Terminal (always Terminal.app, per the 0048
    amendment), Copy Path, **Remove Worktree and Delete Branch…**.
  * Inline Repair / Prune on missing rows.
  * Strip ≡ menu (Prune stale, Repair all).
  * Add sheet: Based on, Create in, Folder name, **Open it when done**; the post-create command is remembered
    and its output goes to Output.
  * Confirmations.
  * Sources: `worktrees_view.dart:200-583, 873-988`; `lib/features/worktrees/add_worktree_sheet.dart:205-674`.
* **M9 — Forge, beyond the list.** From the Forge audit, all verified against the named files.
  * PR/MR row right-click menus: Open in browser, Copy link/#N, Check out branch, Comment…, Approve, Request
    changes… (GitHub), Mark ready / Convert to draft, Edit…, Merge / **Squash and merge** / **Rebase and merge**
    (disabled on drafts), Close/Reopen.
  * The **merge sheet**: Merge method, Delete source branch, commit Title/Body; the merge is pinned to the head
    SHA.
  * Inline **create forms** for PR, MR and Issue: reviewers, assignees, labels, milestone, draft, preview; the
    branch is pushed with `-u` first; "Discard draft?".
  * **Issues as first-class items**: row menu, detail action bar, **Start work** (GitHub `gh issue develop`),
    Assign to me.
  * Comments band (last 50).
  * CI viewer: GitLab streams live logs with **Jump to latest** and a 256 KB cap. **GitHub shows a job's log
    only after the job completes** ("Logs are available once it completes.").
  * Labels, Milestones and Releases detail.
  * Sources: `github_panel.dart`, `gitlab_panel.dart`, `lib/features/forge/issue_actions.dart`,
    `create_pr_form.dart`, `create_mr_form.dart`, `issue_create_form.dart`, `merge_options_sheet.dart`,
    `lib/features/gitlab/pipeline_jobs_view.dart`, `lib/features/github/run_jobs_view.dart:95-105`.
* **M10 — Troubleshooting that users will actually hit.** No topic covers any of the following, though
  each has a real UI string:
  * Forge sign-in failure ("run `gh|glab auth login` on the target" + **Open Dashboard**,
    `lib/features/forge/forge_widgets.dart:210-241`).
  * **Rate limited** ("Try again in …", `lib/core/forge/forge_rate_limit.dart:45-49`).
  * **No remote detected**, **Unsupported forge** (`forge_panel.dart:102-111`).
  * GitLab "no project at <path>" (`lib/core/gitlab/glab_service.dart:1124-1129`).
  * Self-hosted GitLab: glab is pinned to the origin host (0019).
  * The watcher falling back to polling ("Polling for changes (watcher unavailable)",
    `repo_status_view.dart:1682`; Dashboard "Polling fallback", `dashboard_sheet.dart:635`).
  * Sandbox grant prompts ("Grant access to this worktree", "Grant access to the main repository").
  * Unsigned builds storing secrets in a `0600` dotfile rather than the Keychain.
* **M11 — Settings ▸ Opening files.** "Open files with" (Choose… / Reset, default System default) and why
  Open in Terminal is always Terminal.app (0048). Source: `settings_sheet.dart:245-265, 656-668`.
* **M12 — Menu item names.** Help teaches shortcut labels but never the **menu item titles** users actually
  see. The Forge menu, for example, says "Re-run Failed Jobs" and "Merge Merge Request…", not "Re-run Selected
  Workflow Run" (`menu_bar_spec.dart:179-211`).

### S — Defects in the Help machinery itself

* **S1 — Search can't find bullet points.** `HelpView.filteredTopics` matches titles, summaries, keywords,
  chips and a section's `text`/`title`, but **not `items`** (`macos/Runner/HelpView.swift:18-30`). The Legacy
  view has no search at all. Most of the book's concrete facts are bullets, so searching "gitignore",
  "Esc" or "cherry-pick" misses the topic that answers it.
* **S2 — The Swift test has never compiled.** `macos/RunnerTests/HelpDataModelTests.swift` is **not in the
  Xcode project** (it has no `project.pbxproj` entry; only `RunnerTests.swift` is a member). It has never been
  compiled, which is why lines 87-92 can reference a `topic` that is out of scope. It gives no protection.
* **S3 — The contract tests only check chords.** `test/help_book_json_test.dart` verifies chords, the
  topic list and "required facts" substrings. Nothing ties a quoted UI label ("Show closed pull requests",
  "Reconcile…") to a string that still exists in `lib/`, and nothing requires a menu item to be documented.
  That is why W1–W21 and I1–I19 accumulated under a green suite.
* **S4 — Help can't be reached from where the question arises.** It is reachable only from the Help menu,
  and no sheet or panel links to a topic. This record names S4 but does **not** decide it (see *More
  Information*).

### R — README and build documentation

* **R1.** "manages repositories **without a working-tree clone**" is true only for SSH sessions. A local
  session operates on a working tree on this Mac.
* **R2.** The feature list is 5 bullets. It omits History, Stashes, Worktrees, multi-tab sessions and saved
  workspaces, clone/create, the command palette and remappable shortcuts, undo and recovery, drag and drop,
  the file viewer and remote edit, dotfiles/scoped repos, guided branch recovery and Tool Health.
* **R3.** There are no **install or first-run** instructions (`./build_macos.sh --unsigned --install`,
  Gatekeeper), no host prerequisites with versions (git ≥ 2.24; gh ≥ 2.0; `gh auth login` / `glab auth login`
  on the target; optional fswatch or inotifywait), and no pointer to the in-app Help (⌘?).
* **R4.** The development section omits the **pinned Flutter 3.47.2** and `--enforce-lockfile`, which
  AGENTS.md calls load-bearing. It also omits the `live-forge` warning. The README does not link to the records
  index `docs/README.md`, which the documentation standard requires.
* **R5.** The README sends builders to `docs/BUILD_MACOS.md` and repeats its `--unsigned` advice. That
  guide is itself stale; see B1–B9.

### B — The macOS build guide (`docs/BUILD_MACOS.md`)

Each row was checked against the file named in the Evidence column.

| ID | Guide says (line) | What actually happens | Evidence |
|---|---|---|---|
| B1 | "`--unsigned` temporarily removes that entitlement (and restores it after the build)" (42-44) | Nothing is removed or restored. The script writes the gitignored `macos/Runner/Configs/Local.xcconfig` on **every** run, setting `MG_RELEASE_ENTITLEMENTS` to `Runner/Release-unsigned.entitlements` (unsigned) or `Runner/Release.entitlements` (signed). The Release configuration signs with that variable. The strip-and-restore approach is exactly what 0042 removed after it shipped stripped entitlements to git three times. | `build_macos.sh:197-218`; `AppInfo.xcconfig` (`#include? "Local.xcconfig"`); `project.pbxproj:677`; 0042 |
| B2 | "`--unsigned` also strips the app-sandbox entitlement" so the dotfile lands in the real home (78-80) | Same mechanism as B1. The unsigned **file** simply has no `com.apple.security.app-sandbox` key; nothing is stripped. | `build_macos.sh:28-33, 209-213`; AGENTS.md "Critical safety rules" |
| B3 | "No Apple ID … 'Save connection' won't persist" (30) | It **does** persist, in `~/.config/magic_git/credentials.json` (0600). The guide's own line 76, the script's header (34-37) and its closing message (270-272) all say so. The guide contradicts itself. | `build_macos.sh:34-37, 270-272` |
| B4 | "the script fetches a pinned SDK into `./.flutter-sdk`" (20-21) | The script first uses a `flutter` on `PATH` **if its tag is exactly** `FLUTTER_VERSION`. Only otherwise does it clone into `.flutter-sdk`, and it re-fetches if the vendored copy is a different version. The guide never names the pin (**3.47.2**) and never says why it matters: a mismatched SDK rewrites `pubspec.lock` and fails the 48 goldens, per AGENTS.md. | `build_macos.sh:45, 143-187` |
| B5 | To sign properly, "set a Development Team under Signing, and `flutter build macos --release`" (84-86) | **This is a trap.** Plain `flutter build macos` does not rewrite `Local.xcconfig`, so after any `--unsigned` run it still selects `Release-unsigned.entitlements`. A "properly signed" build then silently ships with **no sandbox and no keychain-access-groups**. On the audited machine `Local.xcconfig` currently holds the unsigned selection. The script's own comment says the selection is written in both modes precisely so that a signed build "can never inherit a stale selection". That holds only if the build goes through the script. | `build_macos.sh:197-202`; `macos/Runner/Configs/Local.xcconfig:1`; AGENTS.md ("always use the script") |
| B6 | "archive/notarize for distribution" (86) | This is missing the script's warning: `ENABLE_HARDENED_RUNTIME` must be set to YES before notarizing, and must stay **off** for ad-hoc builds. Otherwise dyld refuses the embedded `FlutterMacOS.framework` ("different Team IDs") and the app dies at launch. | `build_macos.sh:22-27` |
| B7 | Install is shown only as `--unsigned --install` (55); a manual `ditto` recipe (63-67) | `--install` works with a signed build too. It also removes the **build-dir copy** under `build/macos/Build/Products/Release` and refreshes LaunchServices, so only one icon shows. The guide's manual recipe does not remove that copy, and the script's own printed recipe does (`build_macos.sh:258-265`). Following the guide therefore leaves a duplicate Launchpad icon. | `build_macos.sh:102-124, 246-265` |
| B8 | (not covered) | **Script defect.** An unknown option calls `die` at line 66 before `die` is defined at line 72. Running a scratchpad copy with `--bogus` exits **127** with `line 66: die: command not found`, instead of the intended "Unknown option … (supported: --unsigned, --install)". The guide can't document the usage error, because the script never prints it. | `build_macos.sh:61-72`; scratch run, exit 127 |
| B9 | (not covered) | The guide doesn't say where the build writes its output (`build/macos/Build/Products/Release/Magic Git.app` plus `RemoteMagicGit-macos.zip`), what macOS it targets (deployment target **12.0**), or that `Local.xcconfig` is generated and gitignored and must not be committed. It also sits flat in `docs/`, where the documentation standard puts user guides in `docs/guides/`. | `build_macos.sh:48-50`; `project.pbxproj:511, 593`; `.gitignore:67-69` |

## Decision Drivers

* **Honesty first.** A wrong sentence costs more than a missing one. W1–W21 are fixed before anything is
  added.
* **Help answers "how do I …" for what users do daily.** Committing, syncing, recovering a diverged branch,
  reviewing and merging a PR, and fixing a failed connection or sign-in. Today those are either absent (M3, M4,
  M5, M9, M10) or scattered.
* **Keep 0010's delivery model** (G1, G2, G5, G7). The native window and the JSON book are the right macOS
  shape, and nothing found here argues for moving Help into Flutter.
* **Drift must fail a test.** Per the repository's "enforce in source, not docs" practice, anything this
  record fixes must fail the suite if it rots again (S3). A guard must be shown to fail before it is trusted.
* **Findable.** A fact nobody can search for might as well be missing (S1).
* **README serves a newcomer first, a contributor second.** What the app is, what it needs, how to install
  it and where Help is — then how to build and test.
* **A build guide must not produce a wrong artifact.** B5 turns documented advice into an app shipped without
  its sandbox and Keychain entitlements. A guide that contradicts the script it documents is worse than no
  guide at all.

## Considered Options

* **A — Patch the wrong sentences only.** Fix W1–W21 in place, fix B1–B3 and B5 in the build guide, and
  leave coverage and structure alone.
* **B — Revise and extend the authored book, amend 0010's topic list, add prose-drift guards, fix search,
  and rewrite the README.** Fix W and I, add topics for M1–M12, fix S1 and S2, add guards against S3, rewrite
  the README around R1–R5, revise `BUILD_MACOS.md` around B1–B9, and fix the B8 script defect.
* **C — Generate the book from code.** Extract labels, menus, settings and palette entries at build time, and
  keep only a thin authored layer.
* **D — Move Help into Flutter.** Render the book in-app, with deep links from every sheet, and retire
  `HelpView.swift`.

## Decision Outcome

Chosen option: **"B — Revise and extend the authored book, with drift guards"**, because:

* the gap is mostly **coverage of workflows** (M3–M10), and that needs written prose;
* the wrong sentences (W) are symptoms of a missing guard (S3) that option A would leave in place;
* option C cannot explain *why* Reconcile offers three paths or *when* staging is locked;
* option D reopens 0010 G1 to solve S4, which this record deliberately does not decide.

### Book changes (v2.0 → v3.0)

The version becomes **3.0**, because the topic list changes. 0010's category order is kept, and one category
is added. New topic IDs are marked **(new)**. Every other ID is kept, so no existing reference breaks.

| Category (`id`) | Topics, in order |
|---|---|
| Getting Started (`getting_started`) | `overview` (fix I1) · `quickstart` (fix W7, I2) · **`connections_manager` (new — M1, M2)** · `clone_create` (fix I3, I4) · `tabs_workspaces` (fix W5, W6, I5) |
| The Workspace (`workspace`) | `workspace_chrome` (fix W2–W4, I6) · `file_view_and_output` (fix I7) · `dashboard_recovery_activity` (fix W8, I8) · `settings` (fix W9–W11, M11) |
| Panels (`panels`) | `tab_repository` (fix W18, I9) · **`committing` (new — W1, M3)** · **`sync_fetch_pull_push` (new — M4)** · `tab_history` (fix W14, I10, M7) · `tab_branches` (fix W15, W16, I11, M6) · **`branch_sync_recovery` (new — M5)** · `tab_stashes` (fix W17) · `tab_forge` (fix W19–W21, I13) · **`forge_requests_and_issues` (new — M9 minus CI)** · **`forge_ci` (new — the M9 CI viewer)** · `tab_worktrees` (fix I12, M8) |
| Files, Diffs & Windows (`files`) | `viewer_and_remote_edit` (fix W12) · `diffs_blame_history` (fix I14) · `drag_and_drop` (fix I15) · `secondary_windows` (fix W13, I18) |
| Commands & Shortcuts (`commands`) | `feature_palette` (fix I19) · `menus_and_keymap` (add M12, the menu item titles) |
| Safety & Diagnostics (`safety`) | `feature_ssh` · `undo_recovery` (fix I16) · `tool_health` (fix I17) · `output_log` |
| **Troubleshooting (`troubleshooting`, new — M10)** | **`trouble_connection`** (reconnect, host key changed, missing tools) · **`trouble_forge`** (sign-in, rate limit, no remote, unsupported forge, GitLab project not found, self-hosted GitLab) · **`trouble_refresh`** (watch dot colours, polling fallback, fsmonitor) · **`trouble_access`** (sandbox grant prompts, unsigned-build credential storage) |

Rules for the content:

* Every UI element named in Help uses the **exact label from source**, in the same case.
* Wherever GitHub and GitLab differ (Request changes, Start work, live logs, squash options), Help says so.
* Facts that users will search for (labels, verbs, error text) go in `items` or `paragraph` sections, both
  of which are searchable once S1 is fixed.
* G5 still applies: the inspector, the native title bar and palette `issue:` / `request:` / `ci:` are not
  taught.

### Machinery changes

* **S1.** `HelpView` search also matches `items` and `code`. The Legacy view gains the same filter, or the
  fact that it has no search is written down in the book's overview. The plan picks one.
* **S2.** Either add `HelpDataModelTests.swift` to the `RunnerTests` target and fix lines 87-92, or delete
  it as dead code. The plan decides which after checking that the RunnerTests target builds with
  `xcodebuild test`. A test file that cannot compile must not stay in the tree looking like coverage.
* **S3 — three new guards in `test/help_book_json_test.dart`:**
  1. **Label anchors.** A table of the UI labels Help quotes, mapped to their topic. The test asserts each
     label still occurs as a string literal under `lib/` (or in `MainFlutterWindow.swift` for native menu
     titles). Renaming "Reconcile…" in code fails the suite until Help follows.
  2. **Menu coverage.** Every item title in `kMenuBarMenus`, and every natively installed View-menu title,
     appears somewhere in the book.
  3. **Forbidden phrases.** A new list of the W1–W21 falsehoods ("expands the composer in the task dock",
     "Stash-menu only", "not a status chip", "opens the macOS folder panel", …), next to 0010's existing
     list.

  The contract's topic list is updated to the table above. The `troubleshooting` category-id ban is lifted
  and replaced by the four locked topic IDs.
* **App copy (W9).** The Settings sheet's own intro (`settings_sheet.dart:175-178`) gets the same correction
  as Help, so the sheet and Help agree. It is the only `lib/` change in this decision.

### README and build documentation

* **README.md** is rewritten around R1–R4, in this order:
  1. what it is (with R1 corrected);
  2. features, grouped by panel;
  3. requirements: Mac, and the host with its tool versions and auth;
  4. install and first run;
  5. where Help lives (⌘?, ⌘/, ⌘K);
  6. development (pinned Flutter, `--enforce-lockfile`, analyze/test, `live-forge` warning);
  7. links (`docs/README.md`, `docs/ARCHITECTURE_PLAN.md`, `docs/BUILD_MACOS.md`, `AGENTS.md`).
* **`docs/BUILD_MACOS.md`** is revised in full around B1–B9, in this order:
  1. **Prerequisites.** Xcode and CocoaPods, as today. Flutter is resolved to the pin **3.47.2**, from `PATH`
     when it matches exactly and vendored otherwise. The pin's consequences, and the
     `flutter --version` / `--enforce-lockfile` checks, are taken from AGENTS.md.
  2. **Build.** `--unsigned` vs signed, explained by the **entitlement selection**: two tracked files, and the
     generated, gitignored `Local.xcconfig` that is written on every run. Replaces B1/B2.
  3. **Credential storage.** One consistent account: unsigned builds persist to the `0600` dotfile, and signed
     builds use the Keychain. Replaces the B3 contradiction.
  4. **Install.** `--install` for either mode, with what it removes (legacy bundle, build-dir copy) and why.
     The manual `ditto` recipe gains the build-dir removal the script already prints (B7).
  5. **Output and targets.** Paths, zip name, macOS 12.0 minimum (B9).
  6. **Signing for real and notarizing.** Always through `./build_macos.sh`, never plain
     `flutter build macos`, with the reason (B5). Hardened runtime on for notarization only (B6).
  7. **Troubleshooting.** The "entitlements that require signing" error, Gatekeeper and quarantine, the
     duplicate-icon cause, and "Entitlements file … was modified during the build" as a sign that something
     edited a tracked entitlements file (0042).
  8. **Clean up.**

  The guide stays at `docs/BUILD_MACOS.md`. Moving it to `docs/guides/` is part of the pending repository-wide
  layout migration, which needs a link checker first. Doing it here would break inbound links (README,
  AGENTS.md, records) with nothing to catch them. B9's location note is recorded for that migration, not
  acted on.
* **`build_macos.sh` (B8)** gets its `log` / `die` definitions moved above the argument loop, so an unknown
  option prints the intended usage error. This is the only script change in this decision. It is included
  because the revised guide documents the script's options and their error, and would otherwise describe a
  message the script never prints. Confirmation re-runs `--bogus` against a scratch copy of the fixed
  script and expects the usage message with exit status 1.

### Consequences

* Good, because every sentence a user reads is re-checked against today's code, and the 21 known
  falsehoods are fixed with a test preventing each from returning.
* Good, because the workflows users ask about most (committing, syncing, diverged branches, PR review and
  merge, sign-in failures) get task-shaped topics instead of a line in a panel description.
* Good, because label anchors and menu coverage make **renames and new menu items** fail the suite. That is
  the most common way the v2.0 book went stale.
* Good, because search finds facts written as bullets.
* Neutral, because the book grows from 24 to 34 topics and roughly doubles in size. `help_book.json` stays
  one file, and the renderer needs no structural change.
* Bad, because label anchors don't detect a **new feature with no label in Help**. The guards catch drift in
  what is documented, not omission of what isn't. Omission stays a review duty, and the plan records that
  plainly rather than implying coverage.
* Bad, because every UI rename now touches two files. That is the intended cost.
* Bad, because the maintainer's review of the running `.app` (inherited from 0010-PLAN Phase 7) is still
  needed, and it is larger.

### Confirmation

* `flutter test test/help_book_json_test.dart` is green, with the new guards present.
* Each new guard is **seen to fail** against a scratch copy of a broken input before it is trusted:
  * a label renamed in a temp copy of `lib/`;
  * a menu item removed from the book copy;
  * a forbidden phrase reinserted.

  Each failure is recorded in the plan.
* `flutter analyze` is clean, and the full `flutter test` suite passes.
* Search for the terms in S1 returns the expected topic. The plan picks the mechanism: a unit test of the
  filter, or maintainer verification.
* The maintainer opens Help ▸ Support & Help on a built `.app` and reads each new topic. This also closes
  0010-PLAN Phase 7.
* Each of the R1–R5 findings is checked against the finished README, and each of B1–B9 against the finished
  `BUILD_MACOS.md`: every command and path in the guide appears in `build_macos.sh` or the xcconfig it
  names.
* B8: a scratch copy of the fixed `build_macos.sh` run with `--bogus` prints "Unknown option" and exits 1.
  The unfixed copy was already seen to fail (exit 127), so this check has been observed both ways.
* The maintainer runs `./build_macos.sh --unsigned --install` once, following the revised guide on a real Mac.

## Pros and Cons of the Options

### A — Patch the wrong sentences only

* Good, because it is small: 21 sentence edits plus four build-guide corrections.
* Good, because it removes every known falsehood.
* Bad, because M1–M12 stay undocumented. The things users most need help with (Reconcile, the commit
  sheet's background push, forge sign-in failures) remain invisible.
* Bad, because S3 is untouched, so the next wave of renames goes stale exactly as this one did.
* Bad, because it leaves the README a five-bullet stub, and leaves the build guide without install
  cleanup (B7), notarization (B6) or the Flutter pin (B4).

### B — Revise, extend and guard

* Good, because it covers correctness, coverage, findability and drift in one pass.
* Good, because it keeps 0010's accepted delivery model and shortcut contract, both of which proved
  sound.
* Neutral, because it amends 0010's topic list, which is a deliberate and recorded change.
* Bad, because it is the largest content effort of the four options (≈10 new topics, 30+ revised sections).
* Bad, because label anchors need upkeep when Help deliberately paraphrases rather than quotes.

### C — Generate the book from code

* Good, because labels and menus would never drift.
* Bad, because a generator cannot write "Reconcile offers Merge, Rebase and Reset; Reset is reversible with
  ⌘Z" or explain when staging is locked. The value is in the prose.
* Bad, because 0010 already rejected it (its G2), and nothing since changes that reasoning.
* Bad, because many labels are built at runtime ("Abort <Verb>", "Reset to <up>?"), and static
  extraction would miss them.

### D — Move Help into Flutter

* Good, because it would allow deep links from every sheet (S4) and a single toolchain.
* Bad, because it reopens 0010 G1 without new evidence against the native window.
* Bad, because it reworks the delivery mechanism when what is actually broken is the content.
* Bad, because pop-out windows run a second engine, so Help would need its own relay path.

## More Information

* **S4 (links from the app into Help) is deliberately not decided here.** The smallest version is a
  platform-channel method `openHelp(topicId)` that selects a topic in `HelpView`, plus a "?" affordance on a
  few high-value surfaces (Reconcile, Environment health, the forge sign-in error). It changes UI across
  several features and deserves its own record once the v3.0 topic IDs are stable. This record keeps topic IDs
  stable partly so that later work has fixed targets.
* **Evidence base.** Four read-only audits (Repository/commit/stashes; Branches/History/Worktrees; Forge;
  connections/chrome/sessions) and direct reads, all against `fcd70fb`. Every W row was re-checked by the
  author against the cited lines.
* **Counts used above.** `help_book.json`: 6 categories, 24 topics, 62 catalogue chips.
  `kKeymapActions`: 97 (unchanged since `345ce75`). `lib/` commits since `345ce75`: 196.
* **Build-guide evidence.** `build_macos.sh`, `macos/Runner/Configs/AppInfo.xcconfig`, `.gitignore`,
  `project.pbxproj`, the working copy of `Local.xcconfig`, and the one scratch run described under B8.
* **Related records.** [0010-MADR-in-app-help-book-rewrite.md](../0010-MADR-in-app-help-book-rewrite.md)
  (amended here),
  [0012-MADR-commit-composer-focused-sheet.md](../0012-MADR-commit-composer-focused-sheet.md),
  [0020-MADR-fetch-pull-push-lag.md](../0020-MADR-fetch-pull-push-lag.md),
  [0036-MADR-choosing-a-create-destination-while-connected.md](../0036-MADR-choosing-a-create-destination-while-connected.md),
  [0042-MADR-the-macos-build-mutates-its-own-inputs.md](../0042-MADR-the-macos-build-mutates-its-own-inputs.md),
  [0048-MADR-preferred-editor-and-terminal-as-settings.md](../0048-MADR-preferred-editor-and-terminal-as-settings.md),
  [0051-MADR-branches-guided-recovery-for-out-of-sync-repositories.md](../0051-MADR-branches-guided-recovery-for-out-of-sync-repositories.md),
  [0052-MADR-sidebar-info-card-location-row-and-plain-connections-button.md](0052-MADR-sidebar-info-card-location-row-and-plain-connections-button.md).
* **Implementation plan.**
  [0053-PLAN-in-app-help-and-readme-currency-refresh.md](0053-PLAN-in-app-help-and-readme-currency-refresh.md)
  (approved 2026-09-18; execution in progress).

## Amendment 0053.1 (2026-09-18): M3's push-failure message is not what users see

M3 lists "Committed, but the push failed." (`commit_composer_controller.dart:379`) as part of the commit flow.
Execution found that the message is set only when the push callback throws, and the production callback
(`_push`, via `runLogged` in `lib/features/common/busy_action.dart:137-150`) never does. It catches the error,
shows an error dialog with git's message, logs to Output, and returns `false`.

A failed push after a commit therefore appears as:
* an error dialog;
* the command in Output;
* a Failed row in Activity;
* the commit kept locally.

Help teaches that instead, and does not quote the controller string. The decision is unchanged. See
0053-PLAN Deviation D1.

## Amendment 0053.2 (2026-09-18): Debug and Profile get an unsigned entitlements selection so S2 can run

S2's confirmation assumed the `RunnerTests` target could run once the test file was a member. It cannot on a
machine with no development team. The Runner target's Debug and Profile configurations sign with
`DebugProfile.entitlements`, whose `keychain-access-groups` requires a certificate: `xcodebuild test` exits
65 before any test runs. That configuration dates from the initial commit.

The decision is widened, with the maintainer's approval, to include the same mechanism
[0042-MADR-the-macos-build-mutates-its-own-inputs.md](../0042-MADR-the-macos-build-mutates-its-own-inputs.md)
chose for Release:
* a second tracked file, `DebugProfile-unsigned.entitlements`, that differs by exactly `keychain-access-groups`;
* an xcconfig variable, `MG_DEBUG_ENTITLEMENTS`, defaulting to the existing file;
* the unsigned selection passed only on the test command line.

Nothing edits an entitlements file in place. Default Debug, Profile and Release builds sign exactly as before.
`test/macos_entitlements_canon_test.dart` pins the new pair. See 0053-PLAN Deviation D3.
