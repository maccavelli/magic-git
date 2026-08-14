# Implement UI/UX deep-debug audit remediation

Associated MADR: [0004-MADR-ui-ux-deep-debug-audit.md](0004-MADR-ui-ux-deep-debug-audit.md)

- Status: **implemented** (Phases 0–10 landed 2026-08-06; Phase 10 LOW L1–L5
  closed 2026-08-14; L9 chrome now planned in
  [0006-PLAN-hybrid-native-title-bar-context-bar.md](0006-PLAN-hybrid-native-title-bar-context-bar.md))
- Date: 2026-08-06
- MADR decision: Option B — treat the audit as the prioritized remediation backlog
- Owner: implementation agent + maintainer review
- Delivery model: incremental, analyzer-clean phases; maintainer creates commits
  (`git commit --no-edit` only; no agent-written commit messages)
- Sequencing rules:
  1. This plan is the executable authority for delivery order.
  2. Work starts at **Phase 0**. Do not skip ahead to product polish (Phase 8+)
     while HIGH items remain open.
  3. Unit tests land **in the same work slice** as production code for each
     phase’s Required tests table.
  4. Do **not** run `live-forge` tests unless the maintainer explicitly asks.
  5. Rationale stays in the MADR; this plan owns steps, files, tests, and exit
     criteria. A conflict requires an explicit MADR amendment or plan
     correction — the plan does not silently supersede the MADR.
- **Product gates (locked 2026-08-06 by maintainer):**

  | Gate | Choice | Meaning |
  | --- | --- | --- |
  | **G-H5** | **B** | Proxy `uploadBytes` so secondary windows support remote-edit |
  | **G-M1** | **A** | Promote View toggles to remappable `global.*` keymap actions |
  | **G-M5** | **A** | Implement DnD E1 (`git branch -f`) + E2 (cherry-pick onto branch) |
  | **G-M6** | **A** | Releases: selection + detail pane |
  | **G-M8** | **A** | Fetch and render issue/PR/MR comment timelines in-app |
- SDK / quality bar: match repo strict analyzer (`strict-casts` /
  `strict-inference` / `strict-raw-types`, `prefer_final_locals`,
  `prefer_const_constructors`, `unawaited_futures`, `avoid_dynamic_calls`);
  `flutter analyze` + ordinary `flutter test` green before staging.

This plan turns MADR 0004 into an executable sequence grounded in the tree as of
2026-08-06. Finding IDs (H1…H8, M1…M16, L1…L10) are stable cross-references to
the MADR’s More Information section.

---

## Goal

1. **Eliminate active UI correctness bugs** — wrong navigation, silent no-ops,
   swallowed errors, remote-edit silent abort, secondary-window crash paths.
2. **Restore declared contracts** — every `kKeymapActions` id has a real
   handler path; user-facing errors go through `displayError`; page indices
   match sidebar / `DropZoneId` / `IndexedStack`.
3. **Align discoverability** — keymap, command palette, native View menu, and
   visible buttons agree on what exists.
4. **Reduce surprise on exit** — logout / close tab respect dirty trees and
   pending ops the same way branch-switch already does.
5. **Ship locked MED product choices** — comment timelines (G-M8=A), release
   detail (G-M6=A), History DnD E1/E2 (G-M5=A), remappable View shortcuts
   (G-M1=A), and secondary `uploadBytes` proxy (G-H5=B) are **in scope**, not
   optional. Still optional: GH live logs (M10), preview network (M11), full
   GPG signing, full a11y beyond chrome, review *threads* (inline code review).

---

## Scope

### In scope (this plan)

| Track | Finding IDs | Outcome |
| --- | --- | --- |
| Navigation invariants | H1 | Worktrees navigation correct; no dead `panel7` |
| Silent failures | H3, H4 | User-visible errors for rebase fetch + remote-edit |
| Secondary windows | H5 (**B**) | Proxy `uploadBytes`; remote-edit works in pop-outs |
| Keymap completeness | H2 | Publish / Create request / Open CI / Compare wired or removed |
| Error text | H6 | Panel/sheet errors use `displayError` |
| Session exit | H8 | Dirty / pending-op confirm on logout + tab close |
| GPG honesty | H7 | Disclosure when signing would have applied (not full signing) |
| Discoverability | M1(**A**), M2, M4, M5(**A**) | Remappable View keys; palette/tabs; DnD E1/E2 |
| Misleading chrome | M3, M6(**A**), M7, M8(**A**), M9, M15 | CTAs; release detail; comment timeline; conflict copy |
| Secondary polish | M12 | Refresh in pop-out; honest detached chrome |
| Selection / a11y | M13, M14 | Shared selection seam; chrome Semantics |
| Docs | M16 | DnD header + audit log updates |
| Capacity polish | L1–L5, L8 as listed | Only after HIGH/MED gates or when adjacent |

### Explicit non-goals (entire initiative unless MADR amended)

* Full GPG/SSH commit signing over the executor (H7 disclosure only here;
  architecture context: `0001-MADR-native-git-libgit2.md`).
* Inline **code-review threads** / suggestions / CODEOWNERS graph / merge queue
  UI (`0002-MADR`). **Issue and PR/MR conversation comments are in scope**
  (G-M8=A); review-thread graphs are not.
* GitHub Actions live log streaming parity with GitLab `ci trace` (M10 remains
  optional Phase 9 product work).
* Network-enabled markdown image fetch by default (M11 optional opt-in only).
* Native `WindowKind.diff` for multi-monitor diff pop-outs (L6).
* Submodule management UI (L4).
* Interactive rebase reword (L3 — intentional with `GIT_EDITOR=true`).
* Viewer residual L7 items already deferred in `viewer_engine_findings.md`
  (phantom trailing newline, itemExtent, whole-file highlight kill).
* `live-forge` mutating tests.
* Rewriting `ACTION_PLAN.md` history; only point at this plan for open UI work.

### Product gates — locked (2026-08-06)

| Gate | Phase | Locked choice | Implementation summary |
| --- | --- | --- | --- |
| **G-H5** | 3 | **B** | Codec + hub + `ProxyCommandExecutor.uploadBytes` relay |
| **G-M1** | 7 | **A** | New `global.toggle*` / `openHistoryWindow` keymap ids + shell handlers |
| **G-M5** | 7 | **A** | E1 move-pointer (`git branch -f`) + E2 cherry-pick onto branch; confirm + undo |
| **G-M6** | 8 | **A** | `ForgeReleaseSel` + detail body/assets/open URL |
| **G-M8** | 8 | **A** | List + render comments; invalidate on post; both forges |

Remaining open (not gates): dirty-logout Recovery affordance copy (Phase 5);
whether Checkpoint G alone ships before Phases 7–10 (maintainer release call).

---

## Current architecture (grounding map)

```text
Page indices (must stay aligned)
  app_shell.dart IndexedStack:
    0 RepoStatusView
    1 HistoryView
    2 BranchesView
    3 StashView
    4 ForgePanel
    5 WorktreesView
  DropZoneId.index == pageIndex (drop_registry.dart; tested)
  kWorktreesPageIndex  ← fixed: 5 (Phase 0)
  global.panel1…panel6 → select(0…5); panel7 removed (Phase 0)

Keymap / palette / panels
  kKeymapActions          lib/core/settings/keymap.dart
  resolveShortcuts        same file
  PanelShortcuts          lib/features/common/panel_shortcuts.dart
  paletteIntentProvider   lib/features/common/palette_intents.dart
  CommandPalette          lib/features/common/command_palette.dart
  Branch handlers         branch_navigator.dart (only 4 of 8 branch ids)
  Branch detail actions   branch_detail.dart + branches_view.dart
    _publishBranch, _createRequest, onOpenUrl(ciUrl), _openOnForge

Native View menu (fixed ⇧⌘ chords, not in keymap)
  macos/Runner/MainFlutterWindow.swift
  TabsHost magicgit/menu bridge

Secondary windows
  ProxyCommandExecutor.execute  ← proxied
  ProxyCommandExecutor.uploadBytes  ← throws UnsupportedError
  WindowManagerBridge hub case 'execute'
  RemoteEditManager.openRemoteFile / _syncFile
  Detached body = full RepoStatusView

Session exit
  LogoutButton → connectionProvider.disconnect()  (no guard)
  TabsController.close → disconnect()             (no guard)
  guardedBranchSwitch                             (dirty guard pattern to reuse)

Errors
  displayError / SectionError   core/utils + common/async_views
  DiffFailure / many panel error: still '$err'
```

### Confirmed facts (do not re-litigate)

| Claim | Codebase fact |
| --- | --- |
| Worktrees is page 5 | `app_shell.dart` `_pages` last child; `DropZoneId.worktrees.pageIndex == 5` in `test/drop_registry_test.dart` |
| `kWorktreesPageIndex == 5` | Fixed Phase 0; used by `switchToWorktree` |
| Publish/Create already implemented | `branches_view.dart` `_publishBranch` / `_createRequest`; wired to detail, not navigator handlers |
| Open CI is `onOpenUrl(bf.ciUrl)` | `branch_detail.dart` secondary button; needs selection + forge status |
| Compare primary is dead CTA | `branch_detail.dart` `onTap: null` with inspector-always-visible comment |
| Rebase swallows log errors | `history_view.dart` `_actRebaseFrom` `catch (_) { return; }` |
| Remote-edit conflict → log only | `remote_edit_service.dart` `_syncFile` |
| `uploadBytes` not on hub | `proxy_command_executor.dart:231–232`; hub only handles `execute` / `requestState` / `undoRecord` / … |
| GPG always off | `git_service.dart` commit args include `--no-gpg-sign` |
| Dirty switch pattern exists | `guardedBranchSwitch` + `GitStatus.isClean` + `chooseAction` |
| History drop empty | `drop_registry.dart` `case DropZoneId.history: return const []` |
| DnD doc header stale | `DRAG_AND_DROP_ENGINE.md` still says “not yet implemented” while A–D shipped |
| View menu chords | ⇧⌘O/E/D/U/H in `MainFlutterWindow.swift` |

---

## Implementation Steps

### Phase 0 — Navigation invariants (H1)

**Intent:** One source of truth for sidebar page indices; fix the active
Worktrees off-by-one; delete the landmine `panel7` mapping.

#### Steps

1. **Single constant source for Worktrees index**
   - Prefer:
     ```dart
     // worktree_tabs.dart
     const int kWorktreesPageIndex = 5; // DropZoneId.worktrees.index
     ```
   - Or import `DropZoneId` and set
     `kWorktreesPageIndex = DropZoneId.worktrees.pageIndex` if that does not
     create a circular import. If it does, keep a documented literal `5` and
     assert equality in tests.
   - Callers already use `kWorktreesPageIndex` via `switchToWorktree` — no
     call-site churn expected.

2. **Remove dead `global.panel7`**
   - In `app_shell.dart` shortcut map, delete:
     ```dart
     'global.panel7': connected ? () => _selectPage(6) : null,
     ```
   - Do **not** add `global.panel7` to `kKeymapActions`.

3. **Document the six-panel contract** once, next to either `DropZoneId` or
   `pageIndexProvider`:
   - Order: Repository, History, Branches, Stashes, Forge, Worktrees.
   - Panel count = 6; valid indices `0..5`.

4. **Audit other hard-coded `select(6)` / `visit(6)` / page index `6`**
   - `rg 'select\(6\)|visit\(6\)|pageIndex.*6|panel7' lib test`
   - Fix any remaining hits (expect zero after step 1–2).

#### Files

| File | Change |
| --- | --- |
| `lib/features/worktrees/worktree_tabs.dart` | `kWorktreesPageIndex = 5` |
| `lib/features/app_shell.dart` | Drop `global.panel7` |
| `test/…` (new or extend `drop_registry_test.dart`) | Invariant test |

#### Required tests

| Test | Assert |
| --- | --- |
| Page index invariants | `kWorktreesPageIndex == DropZoneId.worktrees.pageIndex`; equals `5`; `DropZoneId.values.length == 6` |
| Existing | `drop_registry_test` worktrees `pageIndex == 5` still green |

#### Exit criteria

* [x] `switchToWorktree` selects Worktrees panel content (index 5).
* [x] No `panel7` / index-6 navigation in production code.
* [x] `flutter analyze` + targeted tests green.

**Checkpoint A (maintainer):** Navigation constants accepted — **implemented 2026-08-06**
(`kWorktreesPageIndex = 5`, `global.panel7` removed, invariant in
`test/drop_registry_test.dart`).

---

### Phase 1 — Silent failure: interactive rebase (H3)

**Intent:** Never swallow a failed range fetch on “Rebase from here”.

#### Steps

1. In `history_view.dart` `_actRebaseFrom`, replace:
   ```dart
   } catch (_) {
     return;
   }
   ```
   with typed handling:
   ```dart
   } catch (e) {
     if (!mounted) return;
     await showErrorDialog(context, displayError(e));
     return;
   }
   ```
2. Import `displayError` if not already imported in that file.
3. Keep the existing “commit isn’t on current branch” dialog path unchanged
   (`idx < 0`).

#### Files

| File | Change |
| --- | --- |
| `lib/features/history/history_view.dart` | Error surface in `_actRebaseFrom` |
| `test/history_*` or new unit/widget test | Failure path if fakes allow |

#### Required tests

| Test | Assert |
| --- | --- |
| Prefer widget/unit with fake `GitService.log` throwing | `showErrorDialog` path / error text via `displayError` (or at minimum no silent return — if dialog hard to assert, unit-test a extracted helper) |

If widget dialog assertion is impractical in this suite, extract a small pure
“rebase range load” helper that rethrows / returns `Result` and unit-test it;
UI calls `displayError` on failure. Prefer root-cause structure over
untestable `catch` in the State class.

#### Exit criteria

* [x] Failed `git.log` for rebase range shows a user-facing error.
* [x] Analyzer + tests green.

**Checkpoint B:** Silent rebase failure closed — **implemented**.

---

### Phase 2 — Complete branch keymap + palette (H2)

**Intent:** Every branch keymap id either has a selection-gated handler matching
detail buttons, or is removed from `kKeymapActions`. Prefer **wiring**.

#### Semantics (match detail UI)

| Action id | When enabled | Behavior (existing implementations) |
| --- | --- | --- |
| `branches.publish` | Local non-HEAD branch, no upstream, remotes non-empty, not busy | `BranchesView._publishBranch` |
| `branches.createRequest` | Local, not unpublished (has upstream), no open request, forge available | `BranchesView._createRequest` |
| `branches.openCi` | Selected branch has `branchForge` `ciUrl` | `onOpenUrl(ciUrl)` |
| `branches.compare` | Local selection in Browse/Review with base | Scroll/focus comparison inspector **or** switch to Review mode + select branch (see step 3) — **not** a no-op primary button |

#### Steps

1. **Lift / plumb callbacks into `BranchNavigator`**
   - Today handlers live only for create/merge/delete; detail owns publish /
     create-request.
   - Add optional callbacks on `BranchNavigator` (same pattern as `onMerge`):
     - `onPublish`, `onCreateRequest`, `onOpenCi`, `onCompare`
   - Wire from `BranchesView` to existing methods / thin wrappers.
   - Gate handlers with the **same** preconditions as `branch_detail.dart`
     primary/secondary buttons (read remotes, forge status, unpublished).

2. **Extend handler map** in `branch_navigator.dart`:
   ```dart
   'branches.publish': canPublish ? () => onPublish!(...) : null,
   'branches.createRequest': canCreateRequest ? () => ... : null,
   'branches.openCi': ciUrl != null ? () => onOpenUrl(ciUrl) : null,
   'branches.compare': canCompare ? () => onCompare!(...) : null,
   ```
   Null handlers = palette/keymap no-ops that land on panel only (existing
   contract).

3. **`branches.compare` behavior**
   - Preferred: if inspector already visible in detail, **scroll detail to
     comparison section** (GlobalKey) — gives the keymap a real effect.
   - Alternate (if scroll is hard): switch `BranchWorkspaceMode.review` + keep
     selection (mode already exists).
   - Do **not** leave keymap bound to `onTap: null`.

4. **Command palette** — add to `_panelActions` in `command_palette.dart`:
   ```dart
   _ActionSpec('branches.publish', PaletteCategory.git, 2, …),
   _ActionSpec('branches.createRequest', PaletteCategory.forge, 2, …),
   _ActionSpec('branches.openCi', PaletteCategory.forge, 2, …),
   _ActionSpec('branches.compare', PaletteCategory.git, 2, …),
   ```
   Icons: mirror detail (`cloud_upload`, `plus_rectangle_on_rectangle`,
   `gauge` / CI, `doc_text`).

5. **Optional defaults:** leave default bindings empty (current) unless product
   wants chords; remapping must work once handlers exist.

6. **Regression guard:** add a pure test that every `KeymapCategory.branches`
   id in `kKeymapActions` is listed in a single expected-handler id set
   (navigator + documented exclusions). Prevents reintroducing orphan ids.

#### Files

| File | Change |
| --- | --- |
| `lib/features/branches/branch_navigator.dart` | Callbacks + handlers |
| `lib/features/branches/branches_view.dart` | Wire callbacks |
| `lib/features/branches/branch_detail.dart` | Optional: share canPublish/canCreate predicates; fix compare CTA (see Phase 8 M3 — may land early if cheap) |
| `lib/features/common/command_palette.dart` | `_panelActions` |
| `lib/core/settings/keymap.dart` | Comment only unless removing ids |
| `test/…` | Handler-id coverage; existing branch widget tests still green |

#### Required tests

| Test | Assert |
| --- | --- |
| Keymap completeness | Every `kKeymapActions` where `category == branches` is in the expected handler id set |
| Widget (if fixtures allow) | Publish handler invokes same path as button when selection valid |

#### Exit criteria

* [x] Binding any of the four ids in Keyboard Mappings runs the detail-equivalent action when preconditions hold.
* [x] Palette lists the four actions under Branches panel index 2.
* [x] No orphan branch keymap ids remain.

**Checkpoint C:** Keymap contract restored for Branches.

---

### Phase 3 — Remote edit visibility + secondary-window policy (H4, H5)

**Intent:** Remote-edit failures are visible; secondary windows never throw
unsupported upload mid-save.

#### 3.A H4 — Surface remote-edit failures (main window)

1. **User-visible channel**
   - Prefer reusing `undoToastProvider` / a dedicated short toast for
     non-blocking sync failure, **and** keep `outputLogProvider.logError`.
   - For **conflict** (remote hash changed): use `showErrorDialog` or
     `chooseAction` with:
     - **Cancel** (default) — keep local temp file; no upload
     - **Overwrite remote** — force upload + update `lastKnownHash`
     - optional **Discard local edits** — re-download / close session
   - Requires a `BuildContext` or a shell-level error bus. Practical options:
     - **(Recommended)** Add `RemoteEditUserMessage` notifier watched by
       `AppShell` (like undo toast) that shows dialogs/toasts; service stays
       context-free.
     - Or pass an optional `void Function(RemoteEditEvent)` callback registered
       from shell.

2. **Service changes** (`remote_edit_service.dart`)
   - On conflict: emit user message; do not only log.
   - On catch: emit user message with `displayError(e)` text, not raw `$e` only
     in log.
   - Keep hash integrity check; do not silently overwrite without choice.

3. **Tests**
   - Unit-test manager conflict path with fake executor + hash mismatch emits
     message / does not upload.
   - Sync failure path emits message.

#### 3.B H5 — Secondary windows (**locked G-H5 = B**: proxy `uploadBytes`)

Remote-edit must work in History/detached pop-outs the same way as the main
window: download via `execute` (already proxied), sync via `uploadBytes`
(today throws). Do **not** ship a “disabled in this window” gate as the end
state; implement the proxy.

##### Wire protocol

1. **`exec_proxy_codec.dart`**
   - Add `UploadBytesRequest { remotePath, Uint8List bytes }` encode/decode.
   - Payload: `remotePath` as `String`; `bytes` as `Uint8List` (never base64
     String — large files; StandardMethodCodec already supports typed data;
     same reason execute stdout uses bytes).
   - Add `encodeUploadBytesError` / success sentinel consistent with execute
     error shaping (typed executor exceptions keep identity; others message).

2. **`ProxyCommandExecutor.uploadBytes`**
   - Replace throw with hub `invokeMethod('uploadBytes', encode(...))`.
   - Reuse outstanding-call + liveness probe machinery from `execute` so a dead
     main window cannot hang forever (same `ConnectionHealthMonitor` pattern).
   - Map decoded errors to the same exception types `execute` uses.

3. **`WindowManagerBridge` hub (`case 'uploadBytes'`)**
   - Decode request; resolve session container with the **same repo ownership
     rules as `execute`** (`_execContainerFor` — no blind pinned-tab fallback).
   - Call `activeExecutorProvider.uploadBytes(remotePath, bytes)`.
   - Return success/error encoding; never let an uncaught throw become an opaque
     `PlatformException` without a message.

4. **Native relay**
   - Confirm `SecondaryWindowController` hub is method-name agnostic
     (pass-through). If any allowlist exists, add `uploadBytes`.
   - No new bootstrap APIs.

5. **Comments / docs in code**
   - Fix stale `ProxyCommandExecutor` comment claiming pop-outs never mutate
     and never push — they mutate via `execute` and now upload via proxy.
   - `onMutationCompleted`: decide whether a successful upload should fire it
     (recommended **yes** if remote-edit dirties the worktree — status refresh
     in child already invalidates `statusProvider`; main window should hear
     about it for History follower consistency). Prefer calling
     `onMutationCompleted` with the repo path derived from `remotePath` parent
     or an explicit repo argument if the upload API stays path-only.

6. **Fallback UX** (only if hub returns RELAY_DOWN mid-edit)
   - Surface via H4 user-message path: “Main window unavailable; upload
     aborted.” Do not corrupt remote.

##### Files (H4 + H5=B)

| File | Change |
| --- | --- |
| `lib/features/viewer/remote_edit_service.dart` | User-visible conflict/fail events (H4) |
| `lib/features/app_shell.dart` or toast host | Consume events (main); secondary shell equivalent |
| `lib/core/exec/exec_proxy_codec.dart` | Upload encode/decode |
| `lib/core/exec/proxy_command_executor.dart` | Implement `uploadBytes` |
| `lib/core/providers/window_manager_bridge.dart` | Hub `uploadBytes` case |
| `macos/Runner/SecondaryWindowController.swift` | Allowlist only if needed |
| `test/exec_proxy_codec_test.dart` | Round-trip + empty/large-ish bytes |
| `test/…` | Proxy upload success/error with fake channel if pattern exists |

#### Required tests

| Test | Assert |
| --- | --- |
| Remote-edit conflict (H4) | No upload; user message emitted |
| Codec uploadBytes | Path + bytes round-trip; error payload shape |
| Proxy upload (fake hub) | Success completes; error maps; RELAY_DOWN does not hang forever |
| Integration-style (optional) | Detached/`RepoStatusView` open remote-edit path no longer hits UnsupportedError |

#### Exit criteria

* [x] Conflict or sync failure is visible without opening Output (H4).
* [x] Secondary-window remote-edit sync succeeds against main isolate executor (H5=B).
* [x] No production path throws `UnsupportedError('uploadBytes is not proxied…')`.
* [x] Analyzer + tests green.

**Checkpoint D:** Remote-edit honesty + secondary upload proxy.

---

### Phase 4 — `displayError` sweep (H6)

**Intent:** One user-facing error mapper everywhere panels/sheets show failures.

#### Steps

1. **Fix shared widgets first**
   - `lib/features/common/diff_view.dart` `DiffFailure` → `displayError(error)`.
   - Confirm `SectionError` already uses `displayError` (it does); prefer
     `SectionError` / `SectionMessage` over ad-hoc `Text('$err')`.

2. **Replace known call sites** (from audit grep):

   | File | Pattern |
   | --- | --- |
   | `repo_status_view.dart` | status `error: (err, _) => … '$err'` |
   | `file_view.dart` | `'$err'` |
   | `history_view.dart` | `'$err'` |
   | `file_history_sheet.dart` | `'$err'` |
   | `blame_sheet.dart` | `'$err'` |
   | `dashboard_sheet.dart` | raw err if present |
   | `recovery_sheet.dart` | `_errorText('$err')` → `displayError` |
   | `viewer_window.dart` | `detail: '$err'` |
   | `clone_sheet.dart` / `create_repo_sheet.dart` | `_error = '$e'` → `displayError(e)` |

3. **Guardrail test (optional but valuable)**
   - Document in test or a simple `rg`-backed script is **not** required in CI;
     prefer a short comment in `display_error.dart` listing the policy.
   - Spot-check: `rg "\\\$err"|Text\\('\\\$" lib/features` after the sweep.

4. Do **not** change output-log raw detail — log may keep `toString()` for
   debugging (`display_error.dart` already states this split).

#### Required tests

| Test | Assert |
| --- | --- |
| Existing `display_error` unit tests | Still cover GitException / Gh / Glab shaping |
| DiffFailure widget if any | Shows humanized text |

#### Exit criteria

* [x] Grep for `'$err'` / `'$e'` in user-visible `Text`/`_error` assignments under `lib/features` is empty or justified (non-UI).
* [x] Analyzer + tests green.

**Checkpoint E:** Error-text contract restored.

---

### Phase 5 — Dirty / pending-op session exit (H8)

**Intent:** Logout and tab close confirm when work would be abandoned.

#### Semantics

Reuse concepts from `guardedBranchSwitch` / `GitStatus`:

* **Dirty:** `!status.isClean` (includes untracked).
* **Pending op:** `status.pendingOp` (or equivalent field on `GitStatus` —
  confirm name in porcelain parser: merge/rebase/cherry-pick/revert in progress).

**Not** required: force-stash on logout (too aggressive). Confirm is enough.

#### Steps

1. **Extract shared helper** (e.g. `lib/features/common/session_exit_guard.dart`):
   ```dart
   Future<bool> confirmSessionExit(
     BuildContext context,
     WidgetRef ref, {
     required String repoPath,
     required String title, // 'Log out?' / 'Close tab?'
   }) async
   ```
   - Read `statusProvider(repoPath).value`; if null, optionally
     `await statusProvider(repoPath).future` (same unknown→fetch pattern as
     branch switch).
   - If clean and no pending op → `true`.
   - If dirty and/or pending → `confirmAction` destructive-style message:
     - Dirty only: uncommitted changes may be left on the host.
     - Pending: merge/rebase in progress; offer “Open Recovery” secondary if
       easy (set `recoveryVisibleProvider` + cancel exit), else message only.
   - Returns whether to proceed with disconnect.

2. **LogoutButton** (`connection_switcher.dart`)
   - `onPressed`: async confirm then `disconnect()`.

3. **TabsController.close**
   - Needs `BuildContext` for dialogs — controller currently has none.
   - **Preferred:** move confirm to call site (`tab_strip.dart` close handlers
     + any programmatic close that is user-initiated). Pass
     `confirm: true` default for UI closes.
   - Programmatic closes on app quit (`prepareToTerminate`) should **not**
     block on dialogs — use `confirm: false` / force path.
   - Document the flag carefully.

4. **Reconnect Cancel** (`app_shell` overlay `onCancel → disconnect`)
   - Decide: confirm if dirty? Prefer yes if status available; skip if session
     already half-dead and status unreadable.

#### Files

| File | Change |
| --- | --- |
| `lib/features/common/session_exit_guard.dart` | New helper |
| `lib/features/switcher/connection_switcher.dart` | Logout |
| `lib/features/tabs/tab_strip.dart` (+ host) | Close with confirm |
| `lib/features/tabs/tabs_controller.dart` | Optional `force` parameter |
| `lib/features/app_shell.dart` | Reconnect cancel policy |

#### Required tests

| Test | Assert |
| --- | --- |
| Helper pure/logic | Clean → true without dialog (inject status) |
| Dirty → confirm required | Fake dialog / callback |

#### Exit criteria

* [x] Logout with dirty tree prompts; cancel leaves session.
* [x] User close of dirty tab prompts; quit path still terminates (3s backstop unchanged).
* [x] Analyzer + tests green — but the phase's own "Required tests" were never
  written; no test exercises `confirmSessionExit`. Closed by 0007-PLAN step 2.5.

**Checkpoint F:** Session exit safety.

---

### Phase 6 — GPG / signing disclosure (H7)

**Intent:** Honest UI that commits from Magic Git never GPG-sign; no full
signing stack in this plan.

#### Steps

1. **Detect intent** (best-effort, non-blocking):
   - On connect or before first commit dialog, read
     `git config --get commit.gpgsign` (and optionally `tag.gpgsign`) via
     existing executor/`GitService` helper if present; add thin
     `bool? commitGpgSignEnabled(repoPath)` returning null on failure.
2. **Surfaces** (pick at least two):
   - Commit dialog caption when `true`: “Commits from Magic Git are not
     GPG-signed (`--no-gpg-sign`).”
   - Settings sheet short note under identity.
   - Optional tool-health / dashboard one-liner when enabled.
3. **Do not** remove `--no-gpg-sign` without a signing design (MADR 0001 /
   SSH agent constraints).
4. Full signing = future MADR, not this phase.

#### Files

| File | Change |
| --- | --- |
| `lib/core/git/git_service.dart` | Optional config read helper |
| `lib/features/repository/commit_dialog.dart` | Notice |
| `lib/features/settings/settings_sheet.dart` | Notice |
| providers if cached | `commitGpgSignProvider` family, autoDispose |

#### Required tests

| Test | Assert |
| --- | --- |
| Parser/helper | `true`/`false`/missing config mapping |

#### Exit criteria

* [x] User with `commit.gpgsign=true` sees disclosure before/at commit.
* [x] Still no signed commits from the app (unchanged args).

**Checkpoint G:** Policy honesty without signing project.

---

### Phase 7 — Discoverability alignment (M1, M2, M4, M5 + palette gaps)

**Intent:** Menus, keymap, palette, and DnD tell one story.

#### 7.1 View toggles (M1) — **locked G-M1 = A**

1. Add to `kKeymapActions` (category `global`), defaults matching native
   (`MainFlutterWindow.swift` ⇧⌘ chords):
   - `global.toggleOutput` — ⇧⌘O
   - `global.toggleFileView` — ⇧⌘E
   - `global.toggleDashboard` — ⇧⌘D
   - `global.toggleRecovery` — ⇧⌘U
   - `global.openHistoryWindow` — ⇧⌘H
2. Wire handlers in `AppShell` / `TabsHost` to existing notifiers
   (`outputLogProvider`, `fileViewVisibleProvider`, `dashboardVisibleProvider`,
   `recoveryVisibleProvider`, `WindowManagerBridge.openHistory`). Reuse the
   same toggle methods the menu channel already invokes.
3. **Native menu:** keep AppKit key equivalents equal to **factory defaults**.
   Keyboard Mappings caption: remapping a chord that the native View menu still
   owns may lose to AppKit until menu equivalents are driven from Dart (out of
   scope unless cheap). Shortcuts sheet + palette always show the *current*
   keymap binding via `_shortcutFor`.
4. Do **not** add a document-only “System menu” section as a substitute — keys
   are remappable per this gate.

#### 7.2 Command palette (M2)

1. Add **Toggle Dashboard** (and ensure File/Output/Recovery show shortcut
   hints via `_shortcutFor` once M1 ids exist).
2. Fix `history.zoomReset` icon (not `zoom_out`).
3. Branch actions already added in Phase 2.
4. Optional: palette rows for open History window using
   `global.openHistoryWindow` shortcut hint.

#### 7.3 Workspace tabs (M4)

1. Add keymap:
   - `global.newTab` → ⌘T → `TabsController` new blank / connect flow (match `+`)
   - `global.closeTab` → ⌘W → close active with Phase 5 confirm
   - Optional: `global.nextTab` / `global.prevTab` ⌘⇧] / ⌘⇧[
2. Wire in `TabsHost` (controller is process-level, not per-AppShell session).
3. Respect tab cap (8): disabled handler or toast at cap.

#### 7.4 History DnD E1/E2 (M5) — **locked G-M5 = A**

Grounded in `docs/DRAG_AND_DROP_ENGINE.md` remaining E-tier (not the empty
History *nav-rail* case alone). Ship both mechanics with confirm + undo.

##### E1 — branch label → commit = move pointer ⚠

| Piece | Detail |
| --- | --- |
| Gesture | Drag `DragRef` (local branch) onto a History commit row |
| Meaning | `git branch -f <branch> <commit>` — move branch tip |
| Service | New `GitService.moveBranch(repoPath, branch, targetOid)` (or equivalent name) on exclusive/captured lane; journal via `_runCaptured` / undo = move back to pre-move OID |
| Guards | Confirm destructive (“Move branch X to abc1234?”); refuse HEAD if policy requires checkout semantics; refuse if branch held by another worktree (reuse existing worktree-held messaging) |
| UI | Extend commit-row `DragTarget` disambiguation menu: today branch→commit is merge/rebase-vs-current; **add “Move branch here”** (E1). Do not replace merge/rebase. |
| Tests | Unit: argv / undo journal shape; widget: menu offers move; integration tag optional |

##### E2 — commit → a specific branch = cherry-pick onto that branch

| Piece | Detail |
| --- | --- |
| Gesture | Drag `DragCommit` onto a **branch row** (Branches panel) or branch target that identifies a non-current branch |
| Meaning | Checkout target (guarded) then `cherryPick`, **or** cherry-pick without checkout if service already supports onto-ref — prefer **guarded checkout + cherry-pick + optional return** matching existing History cherry-pick semantics |
| Service | Reuse `GitService.cherryPick`; wrap with `guardedBranchSwitch` when checkout required |
| Guards | Confirm if working tree dirty; refuse merge commits without mainline prompt (match History multi-cherry-pick rules) |
| UI | Branch rows as `DragTarget<DragCommit>` (or unified `DragItem`); verb “Cherry-pick onto …” |
| Tests | Registry actions for (commit, branch row); confirm path; failure surfaces `displayError` |

##### History nav-rail zone

With E1/E2 in-panel, also fill **nav** History if still empty so the rail is not
a dead drop target:

* **Commit → History:** select History + set `historyNavigationIntent` to that
  SHA/revision (reuse Branches→History intent pattern if present).
* **Branch → History:** select History + revision scope to that branch.

Register in `drop_registry.dart` under `DropZoneId.history` (currently
`const []`).

##### Docs

* Update `DRAG_AND_DROP_ENGINE.md` header: A–D + **E1/E2 shipped** (when done);
  remove “not yet implemented” stale status.

#### Files

| File | Change |
| --- | --- |
| `lib/core/settings/keymap.dart` | New global actions (M1, M4) |
| `lib/features/app_shell.dart` / `tabs_host.dart` | Handlers |
| `lib/features/common/command_palette.dart` | Dashboard + icons + shortcuts |
| `lib/features/settings/keyboard_mappings_sheet.dart` | Caption re AppKit menu |
| `lib/core/git/git_service.dart` | `moveBranch` / force-update ref + undo |
| `lib/features/history/…` | Commit-row disambiguation for E1 |
| `lib/features/branches/…` | Branch-row drop target for E2 |
| `lib/features/dnd/drop_registry.dart` | History nav actions; any E registry entries |
| `lib/features/dnd/drag_item.dart` | Types if needed |
| `docs/DRAG_AND_DROP_ENGINE.md` | Status + E1/E2 done |
| `test/drop_registry_test.dart` + new moveBranch / DnD tests | Coverage |

#### Required tests

| Test | Assert |
| --- | --- |
| Keymap defaults | New globals present with expected default bindings |
| Tab cap | newTab no-ops or messages at 8 |
| E1 | `moveBranch` argv / undo; confirm required |
| E2 | Cherry-pick onto branch path; dirty guard |
| History nav | `canDrop` true for commit/branch → History; verb non-null |

#### Exit criteria

* [x] Palette can open Dashboard; shortcuts sheet lists View chords as remappable.
      (The paired `history.zoomReset` icon fix in step 2 of this phase did *not*
      land — it still uses `zoom_out`. Closed by 0007-PLAN step 2.1.)
* [~] ⌘T works. `global.closeTab` ships **unbound** by design — ⌘W is owned by
      `viewer.close` (`keymap.dart:294-297`) — a deliberate deviation from the
      ⌘W specified above, not recorded here until the 0007 audit.
* [x] E1 move-pointer and E2 cherry-pick-onto-branch ship with confirm + undo.
* [x] History nav zone accepts at least navigational drops.
* [x] DnD doc status matches code.
* [x] Analyzer + tests green.

**Checkpoint H:** Discoverability + DnD E-tier coherent.

---

### Phase 8 — Misleading chrome and forge honesty (M3, M6–M9, M15)

#### M3 — Compare Changes CTA

1. Remove disabled primary button pattern.
2. Replace with non-button section label (“Comparison”) **or** primary that
   scrolls to inspector (`Scrollable.ensureVisible`).
3. Align with Phase 2 `branches.compare` handler.

#### M9 — Binary conflict copy

1. In `conflict_view.dart`, replace CLI-only message with:
   *Binary conflict — text preview unavailable. Use **Use Ours** / **Use Theirs**
   above to take one whole side.*
2. No behavior change to `_resolve`.

#### M6 — Releases — **locked G-M6 = A** (detail pane)

1. **Selection model** (`forge_selection.dart`):
   - Add `ForgeReleaseSel` (stable id: tag name and/or release id from
     `ForgeRelease` — use whatever the list DTO already carries).
2. **Row** (`project_sections.dart` `_releaseRow`):
   - `onTap` → `onSelect(ForgeReleaseSel(...))` like milestones.
3. **Detail pane** (github/gitlab panels or shared project detail builder):
   - Title (name or tag), published date, author if present, body/notes
     (markdown as plain/selectable text or existing preview helper — **no**
     network images required), asset list if in model, primary **Open on
     forge** via existing URL open helper.
4. **Data:** Prefer list payload first. If body/assets missing from list DTO,
   add `GhService`/`GlabService` release detail fetch (`gh release view`,
   GitLab releases API via `glab api`) +
   `releaseDetailProvider((repoPath, key))` registered in
   `repoScopedFetchFamilies` if fetched.
5. **Empty/error:** `SectionError` / loading via existing pane patterns.
6. **Non-goal:** create/edit/delete release in this phase.

#### M7 — Labels

1. Document view-only in section caption: “Labels (view only)”.
2. CRUD is non-goal unless product requests.

#### M8 — Comments — **locked G-M8 = A** (in-app timeline)

Scope: **issue and PR/MR conversation comments** (not inline review threads /
diff comments — those remain `0002` non-goals).

##### Service layer

| Forge | List comments | Already have post |
| --- | --- | --- |
| GitHub | `gh api repos/.../issues/{n}/comments` and/or `gh pr view --json comments` / `gh api …/pulls/{n}/comments` for conversation vs review — **prefer issue-timeline conversation comments** shared by issues and PRs (`/issues/{n}/comments`) | `commentOnIssue`, `commentOnPullRequest` |
| GitLab | `glab api projects/:id/issues/:iid/notes` and `…/merge_requests/:iid/notes` (filter system notes if noisy) | `commentOnIssue`, `commentOnMergeRequest` |

1. Add pure models: `ForgeComment { id, author, body, createdAt, url? }`.
2. Add service methods: `listIssueComments`, `listPullRequestComments` /
   `listMergeRequestNotes` (names match existing style).
3. Providers: `issueCommentsProvider((repoPath, id))`,
   `changeRequestCommentsProvider((repoPath, id))` — autoDispose, join
   mutation invalidation when a comment is posted (today post paths skip
   invalidation because nothing rendered — **fix that**).

##### UI

1. Issue detail (`project_sections` / issue detail): **Comments** section —
   chronological list (author, relative time, body); empty state; error via
   `SectionError`.
2. PR/MR detail (`github_panel` / `gitlab_panel`): same section above or below
   existing actions.
3. After successful comment post: invalidate the list provider; optionally
   clear the compose field (already sheet-based).
4. Cap display (e.g. last 50) + “Open on forge” for full thread if truncated.
5. Body rendering: selectable plain text first; optional lightweight markdown
   later — do not block on full markdown engine.

##### Tests

* Parser unit tests for GH/GL JSON fixtures.
* Post → invalidate: provider/family invalidation called (mock).
* Widget: empty / N comments / error states if practical.

#### M15 — Host-key dialog

1. After `showMacosAlertDialog`, attach `.whenComplete` / route future:
   if prompt still set and user dismissed without Accept/Reject, call
   `rejectHostKeyChange()`.
2. Confirm barrier is non-dismissible; if macos_ui allows barrier tap, close
   that hole.

#### Required tests

| Test | Assert |
| --- | --- |
| Conflict copy | String contains Ours/Theirs guidance |
| Host-key | Reject called on unexpected dismiss if testable |
| Release selection | Row selects `ForgeReleaseSel`; detail shows tag/name |
| Comment list parsers | GH + GL fixtures → `ForgeComment` |
| Comment post | Invalidates list provider |

#### Exit criteria

* [x] No disabled-looking primary “Compare Changes”.
* [x] Binary conflict text matches available actions.
* [x] Releases selectable with a real detail pane (G-M6=A).
* [x] Issue and PR/MR details show fetched comments; post refreshes list (G-M8=A).
* [ ] **M7 — Labels “(view only)” caption never landed.** It had no exit
      criterion of its own, which is how it passed unnoticed. Closed by
      0007-PLAN step 2.2.
* [~] **M15 — host-key reject** ships as an explicit Cancel button, not the
      specified reject-on-unexpected-dismiss. The gap is a silent permanent
      hang; closed by 0007-PLAN step 1.1.

**Checkpoint I:** Chrome honesty.

---

### Phase 9 — Secondary window, selection, a11y (M12–M14)

#### M12 — Secondary shortcuts + chrome

1. Bind `global.refresh` in secondary shell to the same family invalidation
   path already used for hub `invalidateAll` / main ⌘R relay.
2. Title chrome: History → “History — …”; detached → “Status — …” (not
   “full repo”) unless product wants full shell later.
3. Optional: Recovery affordance already present — document; Dashboard remains
   main-window-only unless cheap.

#### M13 — Shared file selection

1. Introduce a small per-repo (or per-tab) notifier, e.g.
   `repoFileSelectionProvider` holding
   `({Set<String> paths, section?})` **or** pass selection down from
   `RepoStatusView` into `FileView` as controlled state.
2. Prefer **minimal**: when status selects a single path, file tree highlights
   it; when tree opens a file, status selection updates if that path is dirty.
3. Multi-select in status need not fully mirror tree (tree is single-path);
   document that asymmetry.

#### M14 — Accessibility pass (chrome only)

1. Extend pattern from `branch_row_semantics.dart`:
   - `NavRail` items: `Semantics(button: true, selected: …, label: …)`
   - `TabStrip` chips + close
   - Command palette rows
2. Do not attempt full VoiceOver audit of every panel in this phase.

#### Optional product (only if capacity; not phase exit)

* **M10** GH logs: prominent “Open on GitHub” + completed log only (no full
  live stream unless API research done).
* **M11** Preview: clickable links → `url_launcher` / existing open URL helper
  with confirm; images remain placeholders unless relative bytes path is easy.

#### Exit criteria

* [x] ⌘R works with focus in History pop-out.
* [x] Detached title does not claim full workspace — the child pushes
      `Status — <repo>` (`secondary_window_main.dart:594-604`). The *open-time*
      title still says “Repo”; closed by 0007-PLAN step 2.4.
* [x] Nav rail + tabs have Semantics labels. (Command-palette rows, also listed
      under M14, did not get them — closed by 0007-PLAN step 2.3.)
* [ ] **M13 — shared file-selection seam never landed.** Like M7 it had no exit
      criterion. `FileView` keeps a private `_selectedPath` and is in fact
      constructed twice, so there are three independent selections. Closed by
      0007-PLAN step 5.5.
* [x] Analyzer + tests green.

**Checkpoint J:** Secondary + a11y baseline.

---

### Phase 10 — Docs, LOW polish, MADR close-out (M16, L*)

#### Docs

1. Update MADR 0004 remediation log as phases complete; set status
   `accepted` when Checkpoints A–G done (HIGH track).
2. `DRAG_AND_DROP_ENGINE.md` status (if not done in Phase 7).
3. Point `ACTION_PLAN.md` “open UI work” at this plan (short pointer only).

#### LOW (pick opportunistically when touching adjacent code)

| ID | Action |
| --- | --- |
| L1 | Soft toast “Nothing to undo” on empty journal — **done** |
| L2 | Middle-click close tab; dirty badge optional — **done** |
| L3 | Rebase sheet footnote: reword unavailable — **done** |
| L5 | Banner when hunk staging unavailable (split/`-w`/parse fail) — **done** (inline + pop-out; `HunkDiffView` parse-fail notice) |
| L8 | Optional `worktrees.new` keymap later — not required |

Skip L4, L6, L7, L9 unless product demands. L9’s chrome *model* is locked in
0006; its implementation plan is a separate later slice.

#### Exit criteria

* [x] MADR HIGH section marked fixed or linked to residual issues.
* [x] Docs consistent with shipped behavior.

**Checkpoint K (maintainer):** Residual backlog accepted. Closed: L1–L5.
Skipped per plan: L4, L6, L7, L8. L9 now planned in
[0006-PLAN-hybrid-native-title-bar-context-bar.md](0006-PLAN-hybrid-native-title-bar-context-bar.md).
Capacity residuals: optional M10/M11.

> **2026-08-14 correction (0007 audit).** The in-panel E1 disambiguation menu
> was listed here as a capacity residual but is implemented
> (`history_view.dart:2201-2260`) — struck above. Conversely **M7** and **M13**
> were folded into the "Phases 1–10 done" changelog entry and were never
> implemented; **M2**, **M12**, **M14**, **M15** landed partially, and **H8**
> shipped without its required tests. See
> [0007-MADR-docs-completion-audit.md](0007-MADR-docs-completion-audit.md) and
> its companion plan for the remediation.

---

## Verification

### Per-phase (mandatory)

```sh
flutter analyze
flutter test   # or targeted files listed in the phase
```

Never: `flutter test --run-skipped -t live-forge …` unless maintainer asks.

### Cross-cutting regression suite (run at Checkpoints C, F, H, K)

| Area | Suggested tests / commands |
| --- | --- |
| Page indices | New invariant test + `drop_registry_test` |
| Keymap | Completeness test for branches (+ globals after Phase 7) |
| History | Rebase error / existing history tests |
| Branches | Existing branch widget/integration suite |
| Tabs | Tab controller tests if present; manual ⌘T/⌘W |
| Remote edit | New unit tests Phase 3 |
| Display error | `display_error` tests + spot grep |
| DnD | `drop_registry_test` |
| Proxy | `exec_proxy_codec_test` if Phase 3B |

### Manual macOS QA checklist (maintainer; not CI)

| # | Scenario | Expect |
| --- | --- | --- |
| 1 | Open worktree from Branches / palette | Lands on Worktrees panel |
| 2 | ⌘6 | Worktrees |
| 3 | Rebase from commit with network down | Error dialog |
| 4 | Bind Publish in mappings; select unpublished branch | Publish confirm |
| 5 | Remote edit conflict (edit host file while session open) | Visible dialog/toast |
| 6 | Detached window → Open file on SSH repo | Clear unavailable (A) or works (B) |
| 7 | Force git failure in status | Humanized error, not `GitException:` |
| 8 | Dirty tree → Logout cancel | Still connected |
| 9 | Dirty tab close cancel | Tab remains |
| 10 | `commit.gpgsign=true` | Notice at commit |
| 11 | Palette “Dashboard” | Opens dashboard |
| 12 | Binary conflict | Copy mentions Ours/Theirs |

### Definition of done (HIGH track)

Phases **0–6** complete, Checkpoints **A–G** signed, analyzer + full
`flutter test` green, MADR remediation log updated for H1–H8.

### Definition of done (full initiative)

Phases **0–10** as scheduled; MED defaults landed; LOW optional residuals
listed in MADR log as deferred with reason.

---

## Rollout and Rollback

### Rollout

* Ship phase-by-phase on `master` (maintainer commits). No feature flags
  required for H1–H3, H6.
* **H5=B:** do not half-ship — either proxy works end-to-end or keep the old
  throw only behind an unreleased branch; a mid-proxy that still throws is
  worse than disable-A (not chosen). Prefer landing codec + hub + proxy in
  one slice.
* **M5=A / M6=A / M8=A:** larger MED slices; can trail HIGH track (after
  Checkpoint G) but are committed scope, not “if capacity”.
* H8 may surprise power users who log out casually — message must stress
  **work remains on disk/host**, not deleted by logout.
* Keymap additions (Phase 7) use new ids; existing user overrides in
  SharedPreferences remain valid (unknown ids ignored already).

### Rollback

| Phase | Rollback |
| --- | --- |
| 0 | Revert constant / panel7 deletion (panel7 delete is safe to keep) |
| 1–2 | Revert file(s); keymap ids without handlers worse than missing — prefer keep handlers |
| 3A | Revert toast/dialog; log-only behavior returns |
| 3B (H5=B) | Revert proxy to throw **only** with matching UI gate, or full revert of slice |
| 5 | Revert guard; direct disconnect returns |
| 7 menu/keymap | Remove new ids; native menu unchanged if left alone |
| 7 E1/E2 | Revert registry + `moveBranch`; leave A–D DnD intact |
| 8 M6/M8 | Revert selection/detail/providers; list-only releases + write-only comments return |

### Risk notes

* **TabsController + dialogs:** avoid blocking quit; keep force path.
* **uploadBytes proxy (H5=B):** large payloads must use `Uint8List` on wire
  (same NUL lesson as execute stdout) — never String; exercise liveness probe
  so a dead main window cannot hang remote-edit forever.
* **E1 `git branch -f`:** destructive; confirm + undo OID mandatory; never
  force-move without journal.
* **Comment timelines (M8=A):** page/cap notes; filter GitLab system notes;
  do not pull review-diff threads into v1.
* **Page index:** any future 7th panel must update `DropZoneId`,
  `IndexedStack`, keymap `panelN`, palette panels, and
  `kWorktreesPageIndex` together — extend the Phase 0 invariant test.

---

## Suggested work slices (PR / commit boundaries)

Maintainer commits; agents implement. Suggested slices:

1. Phase 0 alone (tiny, high leverage)
2. Phase 1 alone
3. Phase 2 (branches keymap + palette)
4. Phase 3A (remote-edit UX) then **3B uploadBytes proxy** (single coherent slice preferred)
5. Phase 4 (mechanical sweep; one commit OK)
6. Phase 5 (exit guard)
7. Phase 6 (GPG notice)
8. Phase 7.1–7.3 (keymap/palette/tabs) then **7.4 E1/E2** (separate if large)
9. Phase 8 M3/M9/M15 (small) then **M6 release detail** then **M8 comment timeline**
10. Phase 9–10 (polish + docs)

---

## Open questions (remaining)

Gates G-H5/M1/M5/M6/M8 are **locked**. Still open:

1. Dirty logout (Phase 5): mention Recovery for **pending ops only**, or also
   when merely dirty?
2. Release ship bar: is **Checkpoint G** (Phases 0–6 / HIGH) enough for the
   next cut, with Phases 7–10 (including locked MED product work) following,
   or hold the release until Checkpoint H/I?

---

## Traceability matrix

| MADR ID | Phase | Primary files |
| --- | --- | --- |
| H1 | 0 | `worktree_tabs.dart`, `app_shell.dart` |
| H3 | 1 | `history_view.dart` |
| H2 | 2 | `branch_navigator.dart`, `branches_view.dart`, `command_palette.dart` |
| H4 | 3A | `remote_edit_service.dart`, shell toast host |
| H5 (**B**) | 3B | `exec_proxy_codec.dart`, `proxy_command_executor.dart`, `window_manager_bridge.dart` |
| H6 | 4 | `diff_view.dart` + panel/sheet error sites |
| H8 | 5 | `session_exit_guard.dart`, logout, tab close |
| H7 | 6 | `git_service.dart`, commit dialog, settings |
| M1 (**A**) M2 M4 | 7.1–7.3 | keymap, shell, palette, tabs |
| M5 (**A**) | 7.4 | `git_service` moveBranch, history/branch DnD, `drop_registry`, DnD doc |
| M3 M9 M15 | 8 | branch_detail, conflict_view, host-key |
| M6 (**A**) | 8 | `forge_selection`, `project_sections`, release detail providers |
| M7 | 8 | labels caption only |
| M8 (**A**) | 8 | `gh_service`/`glab_service` list comments, panels, providers |
| M12–M14 | 9 | secondary_window_main, selection, nav_rail, tab_strip |
| M16 L* | 10 | docs + opportunistic polish |

---

## Change log

| Date | Note |
| --- | --- |
| 2026-08-06 | Initial plan for review; grounded in MADR 0004 + tree facts. |
| 2026-08-06 | Product gates locked: **G-H5=B**, **G-M1=A**, **G-M5=A**, **G-M6=A**, **G-M8=A**. Phases 3/7/8 expanded for full paths; non-goals clarify review-threads vs conversation comments. |
| 2026-08-06 | **Phase 0 done:** `kWorktreesPageIndex = 5`, remove `global.panel7`, six-panel contract docs, `drop_registry_test` invariants. |
| 2026-08-06 | **Phases 1–10 done** (per-phase commits, not pushed): H3 rebase errors; H2 branch keymap; H4/H5 remote-edit + uploadBytes proxy; H6 displayError; H8 session exit; H7 GPG disclosure; M1/M4/M5 View keys + History nav DnD + moveBranch; M6/M8/M9 releases/comments/binary conflict; M12–M14 secondary refresh + Semantics; docs. Residual: in-panel E1 menu on commit rows, PR/MR comment lists, optional M10/M11. |
| 2026-08-14 | **Phase 10 LOW close-out:** L1/L2 already on master; L3 RebaseSheet reword footnote; L5 pop-out banners (inline banners and parse-fail notice already existed). PR/MR conversation comments already shipped (M8). Residual accepted: L4/L6/L7/L8 skipped; L9 waits for a 0006 plan; in-panel E1 menu and optional M10/M11 remain capacity items. |
