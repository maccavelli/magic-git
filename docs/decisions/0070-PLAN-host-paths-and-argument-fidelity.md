---
status: "in-progress"
date: 2026-09-24
associated-madr: "0070-MADR-native-windows-hosts-over-ssh.md"
verified: 2026-09-24
---

# Implement Windows host paths and argument fidelity: one canonical path form, and user text that reaches git unchanged

Associated MADR:
[0070-MADR-native-windows-hosts-over-ssh.md](0070-MADR-native-windows-hosts-over-ssh.md),
Amendment 0070.3 (accepted with this plan). The first plan for the same MADR is
[0070-PLAN-git-bash-detection-and-enablement.md](0070-PLAN-git-bash-detection-and-enablement.md).

## Goal

On a Windows host whose SSH shell is Git Bash:

1. Every host path the app stores, compares, joins, labels or hands to git is in one canonical
   form, git's own `X:/a/b` (Amendment 0070.3, decision 1). The defects caused by comparing a
   git-printed `C:/…` with a stored `/c/…` or `C:\…` are gone.
2. User text passed to git as an argument (commit, tag, merge and stash messages; History
   filters) arrives unchanged (decision 2).

POSIX hosts and the local backend behave byte-for-byte as today.

## Scope

In scope:

* **New:** `lib/core/utils/host_path.dart`, `test/host_path_test.dart`.
* **Transport:** `lib/core/ssh/ssh_command_executor.dart` (`configureEnvironment`, the per-command
  env); `lib/core/ssh/command_formatter.dart` (unchanged signature; the env map carries the
  variable); `lib/core/exec/proxy_command_executor.dart` and `local_command_executor.dart` (the new
  parameter only).
* **Connect and ingestion:** `lib/core/providers/app_providers.dart` (connect; a
  `hostPathStyleProvider`); `lib/core/git/git_service.dart` (`validateRepoPath`,
  `parseRefsDetailed`'s `worktreePath`, the gitfile target); `lib/core/git/host_fs_service.dart`
  (`homeDir`).
* **Defect sites** (Phase 4 lists each with its line).
* **Labels and dedupe** (Phase 5).
* **Docs:** `macos/Runner/help_book.json` (`windows_hosts`), `docs/architecture.md` (the
  Windows paragraph), the MADR (Amendment 0070.3 status), `docs/README.md`.
* **Tests:** listed per phase.

Out of scope:

* the bridge, `WindowsArgv`, SFTP, the watcher and tree-kill (Amendment 0070.3, decision 3);
* switching drives in the remote folder browser (`/` is the Git install directory, F20);
* a custom MSYS `cygdrive` prefix (anything other than the default `/c`);
* rewriting Recent Repositories entries saved before this change (they keep working; their
  labels are fixed in Phase 5);
* the first 0070 plan's three device checks that were not run (Copy, Denied, Settings path).
  They stay with that plan.

## Facts this plan is built on

All measured on the maintainer's host on 2026-09-24, read-only (Amendment 0070.3, F12-F20):

* git prints `C:/…` everywhere (F12); the app stores `/c/…`, `C:\…` or `C:/…` (F13); git returns
  the true case, and the shell echoes the typed case (F14).
* MSYS rewrites `/…` arguments into native programs, user text included (F15).
  `MSYS_NO_PATHCONV=1` stops it and is inherited (F16). Under it, git accepts `C:/…` and rejects
  `/c/…`, in arguments and in `GIT_DIR` (F17).

And from the code (a full inventory of host-path sites in `lib/`, 2026-09-24):

* `CommandFormatter.format` exports its `env` map before every command (`command_formatter.dart:103-150`);
  `configureEnvironment` sets the PATH and binaries (`ssh_command_executor.dart:452`).
* The environment probe reports `os == 'windows'` for MINGW/MSYS/CYGWIN (`environment_probe.dart:172-179`),
  before validation.
* `validateRepoPath` runs `git rev-parse --is-inside-work-tree` (`git_service.dart:1287-1305`).
* Read and confirmed defects:
  * `git_service.dart:1034` `worktreePath: wt.startsWith('/') ? wt : null` gets `C:/…` (F12), so it
    is always null on Windows;
  * `create_repo_pipeline.dart:334` `top != dest`;
  * `edit_entry_sheets.dart:323`, `:327` `startsWith('/')`;
  * `worktrees_view.dart:647` the dead-tab sweep against git's paths;
  * `git_service.dart:1530` a gitfile target tested with `startsWith('/')`.
* Predicted from reading, to be confirmed by the Phase 0 tests: the remaining sites in Phase 4.

## Implementation Steps

### Phase 0 — Records and failing tests

1. MADR Amendment 0070.3 `accepted`; this plan `in-progress`; `docs/README.md` row updated with
   this plan. (Only after the maintainer approves.)
2. Write each test below against the **current** API, run it, and record the failure. A failure
   that is a compile error does not count; those tests are written in the phase that adds the API.
   * `test/refs_parse_test.dart` (`parseRefsDetailed`, `git_service.dart:976`): a `for-each-ref`
     record with `%(worktreepath)` = `C:/Users/u/wt` parses to a non-null `worktreePath`.
   * `test/create_repo_pipeline_test.dart`: an existing repository at a folder whose
     `--show-toplevel` is `C:/Users/u/r`, chosen as `/c/Users/u/r`, is accepted as "already a
     repository", not refused as "inside another Git repository".
   * `test/edit_remote_repo_sheet_test.dart`: an entry at `C:/Users/u/r` with git-dir
     `C:/Users/u/r.git` can be saved.
   * `test/worktrees_view_test.dart`: with the repository at `/c/Users/u/r`, a tab opened for
     `/c/Users/u/r-feat` survives a rebuild when git lists `C:/Users/u/r-feat`.
   * `test/git_service_test.dart` (layout): a `.git` gitfile `gitdir: C:/Users/u/r/.git/worktrees/w`
     is taken as absolute.

### Phase 1 — `HostPath` (pure)

`lib/core/utils/host_path.dart`, no I/O, no Flutter imports:

```dart
enum HostPathStyle { posix, windows }

abstract final class HostPath {
  /// posix: unchanged. windows: `X:\a`, `x:/a/`, `/x/a` (a single-letter MSYS drive mount) →
  /// `X:/a`; `/x` → `X:/`; `\\srv\share\a` → `//srv/share/a`; anything else unchanged
  /// (an MSYS mount such as `/tmp` is only the host's to map).
  static String canonical(String path, HostPathStyle style);

  /// posix: starts with `/`. windows: canonical form starts with `X:/` or `//`.
  static bool isAbsolute(String path, HostPathStyle style);

  /// Absolute in some style: `/…`, `X:/`, `X:\`, `//`, `\\`. For a path whose host is unknown
  /// (a saved entry of another connection). A drive prefix is never a POSIX absolute path.
  static bool looksAbsolute(String path);

  /// Equal after [canonical]; case-insensitive for windows.
  static bool same(String a, String b, HostPathStyle style);

  /// [child] is [parent] or below it, under [same]'s rules.
  static bool isInside(String child, String parent, HostPathStyle style);

  /// The last segment. Splits on `/`, and also on `\` when the path has a drive or UNC prefix,
  /// so a legacy `C:\Users\u\r` labels as `r` with no style needed.
  static String basename(String path);

  static String dirname(String path, HostPathStyle style);   // `X:/` stays `X:/`
  static String join(String base, String rel, HostPathStyle style);
}
```

`test/host_path_test.dart`:

* A table of cases for each function, both styles. It covers `/c/…`, `/C/…`, `C:\…`, `c:/…/`,
  `C:/`, `/c`, UNC, `/tmp`, relative paths, trailing slashes, and a POSIX path named `/c/…` (which
  stays unchanged under `posix`).
* Properties: `canonical` is idempotent; `same(a, canonical(a))`; `posix` is the identity for
  every input.

### Phase 2 — Argument fidelity

1. ~~`CommandExecutor.configureEnvironment` gains `HostPathStyle style = HostPathStyle.posix`.~~
   **D1:** `CommandExecutor` gains `setHostPathStyle(HostPathStyle style)`, as
   `setForgeTokenNeutralization` does. On the
   SSH executor, `windows` adds `MSYS_NO_PATHCONV=1` to the env map every command exports (the
   same map that carries `PATH`), and `resetEnvironment` returns it to `posix`. The activity and
   scoped wrappers forward it. The proxy executor takes the parameter and stays a no-op
   (`proxy_command_executor.dart:307-310`): pop-out windows relay every command to the main
   window's executor, which carries it. The local executor ignores it.
2. `_resolveEnvironment` calls `setHostPathStyle` with `windows` when the probe reports
   `os == 'windows'`, and `posix` otherwise. The reconnect cache passes it the same way.
3. `hostPathStyleProvider` (sync `Provider`): `windows` when the backend is SSH and
   `binaryEnvironmentProvider.os == 'windows'`, else `posix`.
4. Tests (`test/command_formatter_test.dart`, `test/connection_env_reset_test.dart`):
   * after a Windows probe, every command string exports `MSYS_NO_PATHCONV=1`;
   * after a Linux probe, and on the local backend, none does.

### Phase 3 — Canonical on the way in

1. **Connect** (`app_providers.dart`, after the probe and the `~` expansion): on `windows`, pass
   `repoPath`, `repoPaths`, `fsmonitorPaths` and both sides of `scopedGitDirs` through
   `HostPath.canonical`.
2. **Case from git.** ~~`validateRepoPath` runs `git rev-parse --is-inside-work-tree --show-toplevel`
   (one call, as now) and returns the top level.~~ **D2:** `validateRepoPath` is unchanged; a new
   `GitService.topLevel(repoPath)` runs `git rev-parse --show-toplevel`, called only on `windows`,
   before validation. When `HostPath.same(top, repoPath)`,
   the connect adopts `top`. ~~A scoped repository, whose top level is its work tree, is compared the
   same way and adopts it only when equal.~~ A scoped repository is not looked up (it needs its
   scope to be found); it is canonicalized but keeps its typed case. ~~The post-connect save
   (`connection_form.dart` `_saveValidatedPath`) already stores `state.repoPath`, so saved entries
   become canonical on their next connect.~~ **D3:** when a Windows connect's canonical form
   differs from what a saved connection holds, the connect rewrites that connection's metadata
   (repoPath, repoPaths de-duplicated by `HostPath.same`, fsmonitorPaths, the keys of repoLabels
   and scopedGitDirs, and git-dir values), as `_healSavedScopedGitDir` does for a git-dir. The
   form's `_saveValidatedPath` merges the **stored** list re-read after the connect, not its
   pre-connect snapshot.
3. **Folder browser.** `HostFsService.homeDir()` returns `HostPath.canonical(pwd, style)`; the
   service takes the style from its caller (`remote_directory_browser.dart`, via the provider).
   Browsing then produces `C:/Users/<user>/…` from the first listing.
4. Tests (`test/connection_env_reset_test.dart`, `test/host_fs_service_test.dart`):
   * a Windows host connected with `/c/Users/u/r` ends with `state.repoPath == 'C:/Users/u/r'`;
   * with `c:/users/U/R`, it takes git's `C:/Users/u/r`;
   * a Linux host with `/c/data` keeps `/c/data`;
   * `homeDir` on Windows is `C:/Users/u`.

### Phase 4 — Defect sites

Each gets the test from Phase 0 (or one written here) before its fix:

| Site | Change |
|---|---|
| `git_service.dart:1034` | `HostPath.looksAbsolute(wt) ? wt : null` |
| `git_service.dart:1530` | `HostPath.looksAbsolute(target) ? target : '$repoPath/$target'` |
| `create_repo_pipeline.dart:332-334` | `!HostPath.same(top, dest, style)`; the style comes from the sheet |
| `edit_entry_sheets.dart:323`, `:327` | `HostPath.looksAbsolute` |
| `add_worktree_sheet.dart:198`, `:204`, `:238` | `HostPath.basename` / `dirname` / `isAbsolute` with the style |
| `worktrees_view.dart:647` (sweep), `:301-306`, `:435` (forget/close), `:400`, `:404` (Move guard) | compare with `HostPath.same` / `isInside` |
| `clone_sheet.dart:183`, `:441`; `create_repo_sheet.dart:267`, `:270` | `HostPath.isAbsolute` with the style, and `canonical` on the way in |
| **D5:** `lib/core/workspace/clone_controller.dart:170-177` | canonical parent in the clone container's style (POSIX for a local clone); `HostPath.isAbsolute` and `HostPath.join` |
| `remote_directory_browser.dart:131`, `:272-280` | `HostPath.dirname`; `X:/` is a root like `/` |

### Phase 5 — Labels and duplicates

1. Replace host-path basenames with `HostPath.basename`:
   * `saved_connection.dart:138-140`
   * `tab_ui_providers.dart:70-72`
   * `connection_switcher.dart:618`, `:651`
   * `saved_workspaces_sheet.dart:133`, `:233`, `:257`
   * `app_providers.dart:654-657` (`_pathBasename`)
   * `command_palette.dart:331-334` (`_repoBasename`)
   * `window_manager_bridge.dart:542`
   * `secondary_window_main.dart:676`

   A legacy `C:\…` entry then labels as its folder name.
2. `SavedConnection.dedupePaths` stays exact-string; it receives canonical paths from Phase 3.
   `tabs_controller.dart:139`, `:445-452` (`openOrFocus`) compares with
   `HostPath.same(…, style)` so a case variant focuses the open tab.
3. Tests: a label test per site family, with `C:\Users\u\repo` → `repo` and POSIX unchanged; and
   `openOrFocus` with a case variant.

### Phase 6 — Docs

* `help_book.json`, `windows_hosts`:
  * Windows repositories appear as `C:/…`;
  * any typed form is accepted;
  * text starting with `/` is kept as typed;
  * the hook note (Amendment 0070.3, Consequences).
* `docs/architecture.md`: one paragraph on the canonical form and `MSYS_NO_PATHCONV`.
* The help-book label anchors gain the new strings.

### Phase 7 — Device gate (the maintainer's host; mutating steps need consent)

Read-only first, then in a scratch repository under `%TEMP%`, created and removed by the gate
with the maintainer's consent:

| Check | Expected |
|---|---|
| Connect with the saved `/c/…` entry | Title, tab and Workspaces show `C:/Users/<user>/gitrepos/magic-cli-remote`; the saved entry is rewritten to that on this connect |
| Branches in the scratch repo with a second worktree | A branch checked out there shows the worktree chip; Delete is dimmed with the reason |
| Commit with message `/usr/bin broken` | `git log -1 --format=%s` on the host reads `/usr/bin broken` |
| History filter `/usr` | Finds that commit |
| Add worktree, open when done | The new tab stays open after the next refresh (failed on first run: deviation D8; passed on 2026-09-25 after D8's fix) |
| A sample `pre-commit` hook that echoes `$1`-style path arguments to a native program | Documents the F16 difference; recorded, not a failure |

### Phase 8 — Proof and records

* Mutations, in a scratch clone with the baseline first. Each must fail its named test:
  * `canonical` without the MSYS-drive rule;
  * `same` case-sensitive on Windows;
  * the formatter without `MSYS_NO_PATHCONV`;
  * connect without canonicalization;
  * `worktreePath` back to `startsWith('/')`;
  * the pipeline back to `!=`;
  * the sweep back to `contains`.
* `flutter analyze`, the full suite, the records check; this plan `complete`.

## Verification

```sh
flutter analyze
flutter test test/host_path_test.dart test/command_formatter_test.dart \
  test/connection_env_reset_test.dart test/host_fs_service_test.dart
flutter test
dart run scripts/tools/records.dart check
```

## Acceptance Criteria

* On a Windows host, `state.repoPath` and every saved path written by a connect are canonical
  `X:/…`, in git's case.
* Every command to a Windows host exports `MSYS_NO_PATHCONV=1`; no command to any other host does.
* A commit message, tag message, merge message, stash message or History filter starting with `/`
  reaches git unchanged (device gate).
* The Phase 4 sites behave on Windows paths, each pinned by a test that failed before its fix.
* A legacy `C:\…` entry labels as its folder name everywhere Phase 5 lists.
* POSIX hosts and the local backend: the full suite passes unchanged, and `HostPath` under
  `posix` is the identity.
* Every new test was seen to fail (Phase 0 or a mutation); `flutter analyze` is clean; the records
  check reports 0 findings.

## Rollout and Rollback

One commit per phase. Phases 1-2 change no behaviour on POSIX hosts. Phase 3 rewrites saved paths
on Windows hosts only as they connect. That is forward-compatible: a revert keeps working with the
canonical form, because `cd` and git accept `C:/…` with or without conversion (F17). Reverting
Phase 2 alone would bring back F15.

## Execution record

### Deviations

* **D1 (2026-09-24), how the executor learns the host style.** Step 2.1 gave
  `configureEnvironment` a new parameter and listed the SSH, proxy and local executors. In fact
  the activity and scoped wrapper executors must forward it, and test fakes implement the
  interface. A new parameter would change every override: 5 executors and 11 fakes. The
  maintainer chose a separate `setHostPathStyle` method, following
  `setForgeTokenNeutralization`. Files added to Phase 2: `lib/core/exec/activity_command_executor.dart`,
  `lib/core/exec/scoped_command_executor.dart`, and the four fakes that `implements` the
  interface: `test/scoped_forge_providers_test.dart`, `test/branches_500ref_baseline_test.dart`,
  `test/scoped_forge_executor_test.dart`, `test/git_cat_file_batch_test.dart`. The MADR is
  unaffected.

* **D2 (2026-09-24), how the connect takes git's case.** Step 3.2 had `validateRepoPath`
  return the top level from its one `rev-parse`. That changes its return type, and seven test
  fakes override it with `Future<void>` (`auto_fetch_test`, `watch_transport_release_test`,
  `auto_reconnect_test`, `local_backend_test`, `namespace_open_recording_test`,
  `connection_race_test` twice), none in the plan. The maintainer chose a separate,
  Windows-only `GitService.topLevel`: one extra round trip on Windows connects, no change for
  POSIX hosts or the fakes. A scoped repository is not looked up, so it keeps its typed case
  (still canonical). No file is added to scope.

* **D3 (2026-09-24), saved Windows paths.** Step 3.2 claimed the form's post-connect save
  makes saved entries canonical. The code contradicts it: a connect from the Workspaces sheet
  never runs that save, and the save merges the pre-connect snapshot (`known.allRepoPaths`), so
  `/c/…` would stay beside `C:/…`. The maintainer chose to rewrite the saved metadata at
  connect, and to have the form merge the stored list. Files added:
  `lib/features/connection/connection_form.dart`, `test/connection_form_test.dart`.

* **D4 (2026-09-24), the browser test's fake.** Giving `HostFsService.homeDir` the planned
  `style` parameter made the fake's override in `test/remote_directory_browser_test.dart`
  (line 34) invalid; that file was not in the plan. The maintainer chose to update the fake's
  signature, keeping the planned API. File added: `test/remote_directory_browser_test.dart`.

* **D5 (2026-09-24), the clone check lives in the controller.** The inventory listed
  `clone_controller.dart:170`, `:176` with the clone sheet; the Phase 4 table dropped it. It is
  where a `C:/…` destination is refused (`startsWith('/')`) and joined (`joinPath`), so fixing
  the sheet alone would leave Windows clones refused. The maintainer added it. Files added:
  `lib/core/workspace/clone_controller.dart`, `test/clone_controller_test.dart`.

* **D6 (2026-09-24), the root README.** `README.md:48` said Windows tabs "show the full
  `C:\…` path", which Phase 5 made false. The root README was not in the plan's file list
  (only `docs/README.md`). The maintainer added it. File added: `README.md`.

* **D7 (2026-09-24), found at the device gate: the provisioning route.** Adding the scratch
  repository through Add Existing Repository with a typed `C:\…` path left the live path as
  typed; the app's Output read `watcher: polling C:\Users\<user>\…\mg-gate`. That route, and
  a finished clone or create, goes through `finalizeProvisioned` (`app_providers.dart:3122`),
  which Phase 3 did not cover: it canonicalized only in `connect()`. The maintainer chose to
  canonicalize there too, sharing one helper (`_hostSpelling`) with `connect()`. Files added:
  `test/connection_provisioning_test.dart`. Then the gate's add step is redone.
  Executed: `_hostSpelling` canonicalizes and, for an unscoped repository, adopts git's
  case, and `connect()` and `finalizeProvisioned()` now both call it. The new test types
  `C:\Users\u\temp\new` at a fake MINGW host, whose git reports `C:/Users/u/Temp/New`. Both
  mutations were run in a scratch clone of the working tree:
  - skipping the call in `finalizeProvisioned` failed the test (`Actual: 'C:\\Users\\u\\temp\\new'`);
  - returning the canonical form without git's case failed it (`Actual: 'C:/Users/u/temp/new'`),
    and also failed the `connect()` test in `test/connection_env_reset_test.dart`.
  The baseline was green first.

* **D8 (2026-09-24), found at the device gate: an opened worktree tab is swept before the list
  knows it.** Add Worktree with "Open it when done" created `mg-gate-wt` on the host, and no tab
  opened. The sheet opens the tab (`add_worktree_sheet.dart:416`) before anything refreshes the
  worktree list; `WorktreesView._add` refreshes only after the sheet closes
  (`worktrees_view.dart:492`). In between, the view's dead-tab sweep (`:658`) finds the new tab
  missing from the stale list and drops it. A host with a file watcher usually refreshes the list
  first, from its `.git/worktrees/` event; the Windows host only polls. This is not specific to
  Windows and predates 0070. The lines date from `6adf595` (2026-07-14). A widget test that opens
  a tab missing from the current list failed the same way in scratch clones at `21afbb4` (before
  this plan) and at `b7857ea`, with POSIX paths (`Actual: []`). Move reopens its tab at the new
  path (`:449`) inside its guarded action, and the refresh runs only after that action, so it is
  exposed the same way. The maintainer chose "openers refresh first" (superseded on 2026-09-25,
  below):
  - the sheet refreshes the repository's providers after a successful create, then opens the tab;
  - Move refreshes before it reopens the tab;
  - the sweep never judges a tab dead from a list that is still reloading.
  Files added: `lib/features/worktrees/add_worktree_sheet.dart`,
  `lib/features/worktrees/worktrees_view.dart` (both already in Phase 4) and
  `test/worktrees_view_test.dart`. Then the gate's Add Worktree check is redone.

  **Correction (2026-09-25): the cause stated above is not confirmed.**
  - The reproduction cited above opens a tab for a worktree that never appears in the list. It
    shows only that the sweep drops a tab missing from a settled list, which is the sweep's
    purpose. It does not show that the list was stale when the device's tab opened.
  - Each of the three fixes was reverted on its own in a scratch clone carrying these changes,
    with a green baseline (20 tests):
    - the sheet opens the tab without refreshing;
    - the sweep judges a reloading list;
    - Move reopens without refreshing.
    `test/worktrees_view_test.dart` still passed 20 of 20 each time, so no test yet fails
    without them.
  - The fixes are committed as the maintainer chose. The device failure is still unexplained,
    and the gate's Add Worktree check has not been redone. Both stay open until a test
    reproduces the device failure and fails without the fix.

  **Diagnosis (2026-09-25): the sweep judged a list that was still reloading.**
  - `WorktreesView.build` sweeps every open tab whose path is not in `worktreesAsync.value`.
    While the list reloads, Riverpod still serves the previous list as that value. So a tab
    opened for a worktree created or moved a moment ago was swept in the next frame, before the
    new list arrived.
  - The tests missed it because the fake list answered at once. In a widget test the refresh a
    caller starts after the sheet closes completes before the next frame, so the sweep never
    saw a stale list. Over SSH, `git worktree list` takes a round trip.
  - With a 300 ms delay on the fake list (`test/worktrees_view_test.dart`, the `listing`
    pump), both D8 tests fail without the guard, with the device's symptom:
    `Expected: [<…>/app-new]  Actual: []`, and the same for Move.
  - Nothing here depends on the host, or on whether it has a watcher. It was observed only on
    the Windows host.
  - On the device, in the scratch repository on the Windows host:
    - the build from `4ee7534`, with none of D8's changes: Add Worktree with "Open it when
      done" created the worktree, the list showed it, and no tab opened;
    - the build from `478100d`: the same steps opened the new worktree's tab, and it was
      still open 18 s later.
  - **Only the guard is needed.** With the delay in place, each fix was reverted on its own:
    - the guard (`!worktreesAsync.isLoading`): both D8 tests failed;
    - the sheet's refresh before opening, and Move's refresh before reopening: both tests
      still passed.

    Every caller of `AddWorktreeSheet` already refreshes the repository as soon as the sheet
    closes: the Worktrees panel, both Branches entry points, History, and a drop. Move
    refreshes after its guarded action. Each of these starts the reload before the next
    frame, and the guard holds the sweep until that reload settles.

  **Decision (2026-09-25):** the maintainer chose to remove the two early refreshes, so the fix
  is the guard alone and every line of it is proven by a failing test. The test pump keeps the
  round-trip delay for the D8 tests. The first resolution above ("openers refresh first") is
  superseded by this one. Files are unchanged: `lib/features/worktrees/add_worktree_sheet.dart`,
  `lib/features/worktrees/worktrees_view.dart` and `test/worktrees_view_test.dart`. The gate's
  Add Worktree check is redone on a build of the final change.

  **Executed (2026-09-25):**
  - Against the commit before D8, the `lib/` change is now the guard alone:
    `add_worktree_sheet.dart` is back to its earlier text, and Move reopens its tab as it did.
    The Add test's name and comment no longer blame a missing watcher.
  - In a scratch clone carrying these files, `test/worktrees_view_test.dart` passed 20 of 20.
    With the guard removed it failed 2 of 20, both D8 tests, each at its tab assertion with
    `Actual: []`.
  - `flutter analyze` was clean, the full suite gave `+4453 ~3: All tests passed!`, and the
    records check had 0 findings.
  - Gate redone on a build of exactly this tree, in the scratch repository on the Windows host:
    Add Worktree with "Open it when done" opened the new worktree's tab, and it was still open
    20 s later. The tab opened by the earlier `478100d` build was still open about 20 minutes
    after it was created.

* **D9 (2026-09-24), found by D8's Move test: switching worktree tabs writes a provider during a
  build.** The Move test failed with Riverpod's "Tried to modify a provider while the widget tree
  was building", raised from `RepoStatusView.didUpdateWidget` (`repo_status_view.dart:585`).
  - The worktree workspace is not keyed by worktree (`worktrees_view.dart:813`), so a tab switch
    retargets the same `RepoStatusView` at another path.
  - On a path change, that view clears the file selection. Since `0316880` (2026-08-14) the
    selection lives in `repoFileSelectionProvider(repoPath)`, keyed per repository, so the clear
    writes to the *new* repository's provider mid-build and wipes that repository's selection.
  - This predates this plan and is not specific to Windows. Opening a second worktree tab while
    one is showing failed with the same stack in a scratch clone at `b7857ea`, which has no D8
    code. D8's Move fix reaches it because the reopened tab retargets the view.
  - Several later tests in the same run failed only as fallout; each passes on its own.
  The maintainer chose to stop the stale reset. The selection is already kept per repository, so
  the new one brings its own, and only widget-local state is reset on a path change. Behaviour
  change: returning to a worktree tab shows that worktree's last selection instead of none. File
  added: `lib/features/repository/repo_status_view.dart`. Test: a tab switch in
  `test/worktrees_view_test.dart`. Seen to fail (2026-09-24): with the reset put back in a
  scratch clone, 12 tests in that file failed.

* **D10 (2026-09-25), found by Phase 8's mutations: two provisioning routes are untested.**
  Phase 8's catalogue added two entries beyond the seven listed: "connect without
  canonicalization" was split into its path lists and its repository path, and the gitfile target
  got its own entry. One survived: `_hostSpelling` returning the typed `repoPath` instead of
  `HostPath.canonical(repoPath, style)` (`app_providers.dart:2951`). `connect()` canonicalizes
  before it calls the helper, so there the mutation changes nothing. `finalizeProvisioned()`
  (`:3174`) does not, so two of its routes would keep a typed `C:\…` with no test failing:
  - a scoped (dotfiles) repository, where the helper returns before asking git;
  - a repository git does not report (`topLevel` returns null).

  The code is right today. What is missing is a test that pins it. Found on the unmodified tree.
  The maintainer chose to add both cases to `test/connection_provisioning_test.dart` (already in
  scope from D7), each seen to fail under the mutation, and to commit the catalogue as
  `scripts/tools/mutations/0070-host-paths.json`, as MADRs 0032 to 0054 did, so `mutate.py
  --check` keeps it from going stale. Files added: `scripts/tools/mutations/0070-host-paths.json`.

### Phase 0 (2026-09-24)

* The maintainer approved the plan and Amendment 0070.3, accepting the hook trade-off. Records:
  the amendment `accepted`, this plan `in-progress`, the index row.
* Three tests were written against the current API; each failed on its own assertion:
  * `refs_parse_test`: `worktreePath` expected `C:/Users/u/wt/held`, was null
    (`git_service.dart:1034`);
  * `git_service_test`: the gitfile target came back `C:/Users/u/w/C:/Users/u/r/.git/worktrees/w`
    (`:1530`);
  * `edit_remote_repo_sheet_test`: Save was disabled for a `C:/…` entry
    (`edit_entry_sheets.dart:323`, `:327`).
* The `create_repo_pipeline_test` and `worktrees_view_test` cases need the host style, which
  Phases 2-4 add. As step 2 provides, they are written in Phase 4, where each is still seen to
  fail before its fix.
* These tests commit with their fixes (Phase 4), so no commit carries a failing test.

### Phase 1 (2026-09-24)

* `lib/core/utils/host_path.dart`: `HostPathStyle` and `HostPath`, as specified.
* `test/host_path_test.dart`: `+15: All tests passed!`. One expectation in my first draft was
  wrong: "POSIX labels match `posix_path.basename`" ran over Windows-shaped samples too, where the
  label differs by design. It now runs over every POSIX-shaped sample, and asserts that there are
  more than ten; the Windows labels are pinned in their own test.
* Commit `3aedcb6`. Its hook-generated message also names `MSYS_NO_PATHCONV`, because the plan
  and amendment it carries describe it; that code is Phase 2's.

### Phase 2 (2026-09-24), with D1

* `CommandExecutor.setHostPathStyle` (no-op default). The SSH executor stores it, adds
  `MSYS_NO_PATHCONV=1` to every command's env for `windows`, and `resetEnvironment` returns it to
  `posix`. The activity and scoped wrappers forward it; local and proxy are explicit no-ops; the
  four `implements` fakes gained a no-op. `ssh_command_executor.dart` re-exports `HostPathStyle`.
  For tests, `commandEnvFor` and `hostPathStyle` give a read-only view.
* `app_providers.dart`: `hostPathStyleFor(backend, os)`, used by `_resolveEnvironment` (both the
  fresh probe and the reconnect cache) and by the new `hostPathStyleProvider`.
* Tests: `command_formatter_test` (Windows exports `MSYS_NO_PATHCONV='1'` beside `GIT_DIR`; POSIX
  and a reset executor do not) and `connection_env_reset_test` (the Git Bash connect sets
  `windows` on the executor and the provider; the Linux connect stays `posix`). Together with
  `provider_retry_policy_test`: `+39: All tests passed!`. `flutter analyze`: No issues found.
* Commit `2cf175f`.

### Phase 3 (2026-09-24), with D2, D3, D4

* Connect (`app_providers.dart`): on `windows`, `repoPath`, `repoPaths`, `fsmonitorPaths` and
  `scopedGitDirs` pass through `HostPath.canonical` after the probe. For an unscoped repository,
  `GitService.topLevel` (D2) supplies git's case when `HostPath.same`. After `touch`, awaited,
  `_canonicalizeSavedPaths` rewrites the saved connection with `SavedConnection.canonicalPaths`
  (D3), reading the store itself.
* `connection_form.dart` `_saveValidatedPath` merges the stored list re-read after the connect,
  for a connection that has connected before (D3).
* `HostFsService.homeDir({style})` returns the canonical form; the folder browser passes
  `hostPathStyleProvider` (the browser test's fake gained the parameter, D4).
* Tests:
  * `connection_env_reset_test`: `/c/users/u/repo` → git's `C:/Users/u/Repo`, and the typed
    `C:\` path canonical; the saved connection rewritten, three spellings to two entries, its
    label rekeyed, `lastConnectedAt` kept; a Linux `/c/data` unchanged.
  * `host_fs_service_test`: Windows `homeDir` is `C:/Users/u`, POSIX unchanged.
  * `saved_connection_test`: `canonicalPaths` merges every map, takes `caseOf`, and is the
    identity under POSIX.
  * `connection_form_test`: the save merges the stored list, not the pre-connect copy.
* `flutter analyze`: No issues found. Those five files with `remote_directory_browser_test`:
  `+65: All tests passed!`. They are seen to fail in Phase 8's mutations.
* `no_real_identifiers_scan_test` caught my first test data: a capital `U` in the account
  segment (`/C/USERS/U/R`) reads as an account name. The account segment is now the `u`
  placeholder, with the case varied elsewhere. Full suite: only the three Phase 0 tests fail.
* Commit `6c116b1`.

### Phase 4 (2026-09-24), with D5

* `git_service.dart`: `worktreePath` and the gitfile target use `HostPath.looksAbsolute` (it still
  rejects an old git's echoed `%(worktreepath)`).
* `edit_entry_sheets.dart`: `looksAbsolute` for the path and git-dir.
* `create_repo_pipeline.dart`: `CreateRepoRequest.pathStyle`; `dest` canonical;
  `!HostPath.same(top, dest, style)`. `create_repo_sheet.dart` passes the style of the container
  the create runs in (`runIn`, the provisioned target's own tab), POSIX for This Mac.
* **Within the plan's API, where the host is unknown at validation time:** the create and clone
  sheets validate a typed path with `looksAbsolute`, because a saved-connection target is not
  provisioned yet. The canonical form is applied when the job runs, in the target's style.
* `clone_controller.dart` (D5): `_run` canonicalizes the request's parent once, in the
  container's style, and checks `HostPath.isAbsolute`; `CloneRequest.withParentDir` added.
* `add_worktree_sheet.dart`: `HostPath.basename`; on Windows `HostPath.dirname` and
  `HostPath.isInside`; `HostPath.isAbsolute`; a `\` in the folder name is refused on Windows. The
  POSIX default-parent expression is kept byte-for-byte (for a repository at `/repo` it still
  gives `''`).
* `worktrees_view.dart`: the dead-tab sweep keeps a tab when git lists it under `HostPath.same`;
  the Move no-op and inside-repository guards use `same` and `isInside` on Windows, and keep the
  symlink-aware check otherwise.
* `remote_directory_browser.dart`: `_parentFor` — `C:/` is its own parent, like `/`; `atRoot`
  follows it.
* Tests: the three Phase 0 tests now pass. New:
  * `add_worktree_sheet_test`: a `C:/Users/u/app` repository gets parent `C:/Users/u` and can
    create;
  * `create_repo_pipeline_test`: `/c/Users/u/app`, reported by git as `C:/Users/u/app`, is taken
    as the repository;
  * `clone_controller_test`: a `C:\Users\u\src` parent is canonical and accepted;
  * `worktrees_view_test`: a case-variant tab survives a rebuild;
  * `remote_directory_browser_test`: Up lists `C:/Users/u`, `C:/Users`, `C:/`, and stops.
* The touched files' suites: `+202` (with the Phase 0 tests), then `+67` for the five with new
  cases. `flutter analyze`: No issues found.
* Commit `c0398a5`.

### Phase 5 (2026-09-24)

* Labels use `HostPath.basename` at every site listed:
  * `saved_connection.dart` `repoDisplayName`;
  * `tab_ui_providers.dart` `repositoryDisplayName`;
  * `connection_switcher.dart` (two);
  * `saved_workspaces_sheet.dart` (three);
  * `app_providers.dart` `_pathBasename`;
  * `command_palette.dart` `_repoBasename`;
  * `window_manager_bridge.dart` and `secondary_window_main.dart` (window titles).

  Four files dropped the `posix_path` import they no longer used.
* `tabs_controller.dart`: `_holds` compares a tab's repository by the tab's own
  `hostPathStyleProvider`, in `_find` (dedupe) and `containerForRepo`.
* Tests: `saved_connection_test` (a legacy `C:\` entry labels as its folder; POSIX unchanged)
  and `tabs_controller_test` (the tab name; a case variant focuses the open Windows tab, and
  `containerForRepo` finds it). My first draft of the tab test opened the tab in the blank landing
  tab, whose container predates the Windows override, so it compared as POSIX; the test now
  starts without a landing tab. `+31: All tests passed!`; `flutter analyze`: No issues found.
* Commit `8c8f4dd`. Its hook-generated message says "(0070.5)"; it is this plan's Phase 5,
  under Amendment 0070.3. The commit command also ran after the test run with `;` rather than
  on its exit status; the suite had passed (`+4444`), and later commits are gated on it.

### Phase 6 (2026-09-24), with D6

* `help_book.json`, `windows_hosts`:
  * any typed form is accepted, and paths are kept as git prints them, in the folder's case,
    with the tab named after the folder;
  * text starting with `/` reaches git as typed;
  * a warning callout, "Hooks see paths unconverted" (the Amendment 0070.3 trade-off);
  * the stale "full C:\… path" sentence removed from "Not yet on Windows";
  * keywords `path`, `c:/`, `msys`.
* `README.md` (D6): the Windows bullet says the same.
* `docs/architecture.md`: the canonical form, the saved-path rewrite, case-insensitive
  comparison, and `MSYS_NO_PATHCONV`.
* **Step not applicable:** "the help-book label anchors gain the new strings". This plan added no
  UI label (the error texts it touches already existed), so there was nothing new to anchor.
* `help_book_json_test`, `docs_records_test`, `no_real_identifiers_scan_test`: `+45: All tests
  passed!`; records check 0 findings.

### Phase 7 (2026-09-25), device gate

The installed build of `73b6257` (1.9.4.11), driven on this Mac against the maintainer's Windows 11
host. The scratch repository was created over SSH under `%TEMP%` (`mg-gate-0070`, with a second
worktree `mg-gate-0070-wt` holding branch `wt-held`, a staged change, and the F16 sample hook), with
the maintainer's consent, and removed afterwards together with its entry in the saved connection.

| Check | Result | Evidence |
|---|---|---|
| Connect with the saved entry | **PASS** | Title `magic-cli-remote (master)`, the tab and the sidebar name the folder; the live path is `C:/Users/<user>/gitrepos/magic-cli-remote` (the watcher line); Workspaces lists the folder names, and its hover shows `C:/…`. The saved entry was already all `C:/…`: an earlier connect had rewritten it, so this connect had nothing left to rewrite. |
| Add the scratch repository as `/c/…` | **PASS** | Browsed to `/c/Users/<user>/AppData/Local/Temp/mg-gate-0070`; the live path became `C:/Users/<user>/AppData/Local/Temp/mg-gate-0070` and the saved connection stored that spelling (D7, on the device). |
| Branches with a second worktree | **PASS** | `wt-held` carries the worktree chip; its menu offers "Switch to its worktree", and Delete branch is dimmed with "Checked out in the worktree "mg-gate-0070-wt" — remove that worktree first". |
| Commit with message `/usr/bin broken` | **PASS** | `git log -1 --format=%s` on the host: `/usr/bin broken`. |
| History filter `/usr` | **PASS** | "1 matching commit", `/usr/bin broken`. |
| Add worktree, open when done | **PASS** | Recorded under D8 (2026-09-25), on a build of this same code. |
| F16 sample hook | recorded | The `pre-commit` hook passes `/usr/bin` to `git.exe` and logs what it received. Run by the app: `MSYS_NO_PATHCONV=1 arg= '/usr/bin'`. Run from a plain SSH shell: `MSYS_NO_PATHCONV=unset arg= 'C:/Program Files/Git/usr/bin'`. That is Amendment 0070.3's trade-off, as documented. |

### Phase 8 (2026-09-25), with D10

* The catalogue, `scripts/tools/mutations/0070-host-paths.json`, holds the seven mutations listed
  plus two (D10): connect split into its path lists and its repository path, and the gitfile
  target on its own.
* **First run** (baseline green, 9 test files; compile canary recognised): 8 killed, 1 survived —
  `connect without canonicalization (repo path)`. That is D10.
* `test/connection_provisioning_test.dart` gained two cases: a scoped repository typed `C:\Users\u`
  is kept as `C:/Users/u`, and a repository git does not report keeps the typed case in canonical
  form. The Windows executor fake answers the layout probe and can report no top level.
* **Second run:** `9 killed, 0 survived, 0 did not apply, 0 did not compile, 0 observed by no
  test`. The survivor is now killed by both new cases.
* `mutate.py --check` on the catalogue: `9 sound`, with the analyzer canary recognised.
* `flutter analyze`: No issues found. `dart format` reflowed the test file once. Full suite:
  `03:18 +4455 ~3: All tests passed!`, 0 `[E]`.
