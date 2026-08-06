# Treat the 2026-08 UI/UX deep-debug audit as the prioritized remediation backlog

- Status: proposed
- Date: 2026-08-06
- Deciders: Mac Smith
- Tags: ui, ux, flutter, macos, debugging, accessibility, shortcuts, multi-window, forge, wiring

Technical Story: After multiple feature initiatives (base-relative branches,
forge merge models, multi-window, DnD, viewer engine), Magic Git's Flutter/macOS
UI surface is large and mostly mature — but residual bugs, incomplete wiring, and
product gaps remain. This record captures a full-codebase deep-debug pass focused
on UI/UX, incomplete handlers, and macOS chrome, and decides how those findings
should be ordered for remediation.

## Context and Problem Statement

Magic Git is a macOS-only Flutter client (macos_ui + Riverpod) that drives
`git` / `gh` / `glab` on a local or remote host and surfaces status, history,
branches, stashes, forge data, worktrees, viewers, and multi-window pop-outs.

Prior audits fixed transport races, viewer encoding/window clamps, memory
multipliers, and several panel bugs (see `docs/ACTION_PLAN.md`,
`docs/viewer_engine_findings.md`, `docs/memory_audit.md`,
`docs/window_sizing_proposal.md`). Those documents are partially historical:
many items are marked done, but they are not a current end-to-end UI wiring map.

The open questions for this pass:

1. What **correctness / silent-failure bugs** still exist in the UI layer?
2. What **incomplete wiring** (keymap, palette, menus, secondary windows, DnD)
   misleads users or does nothing when invoked?
3. What **product gaps** are intentional deferrals versus accidental half-builds?
4. How should remediation be **prioritized** without restarting unrelated
   architecture work?

This MADR is the decision record for prioritization. The findings themselves are
evidence, not optional design alternatives — they were verified against source
on 2026-08-06.

### Audit method

- Parallel read-only exploration of shell/tabs/keymap/menus and feature panels
  (repository, history, branches, forge, viewer, worktrees, workspace, DnD).
- Cross-checks of `kKeymapActions` vs panel `handlers` vs command palette
  `_panelActions` vs native View menu.
- Page-index / `IndexedStack` / `DropZoneId` consistency.
- Secondary-window proxy capabilities vs UI actions exposed there.
- Spot-checks of known docs (`viewer_engine_findings.md`, DnD, ACTION_PLAN).

Tests and live UI were **not** re-run as part of this audit; findings are
static-analysis-backed. HIGH items should get regression tests when fixed.

## Decision Drivers

* **User-visible correctness** — silent no-ops and wrong navigation beat polish.
* **Data-loss / surprise risk** — remote edit, disconnect with dirty tree, GPG.
* **Discoverability consistency** — keymap, palette, native menu, and buttons
  should agree on what exists.
* **macOS desktop expectations** — sheets, Escape, menus, VoiceOver, shortcuts.
* **Root-cause fixes** — no symptom guards; align constants and single sources
  of truth (page indices, displayError, keymap handlers).
* **Scope control** — product expansions (comment timelines, live GH logs) are
  backlog, not blockers for wiring bugs.

## Considered Options

* **A. Record findings only; fix ad hoc as users report** — no ordered backlog.
* **B. Accept this audit as the authoritative prioritized backlog** — fix HIGH
  correctness/wiring first, then MED discoverability, then LOW polish and
  documented product gaps; track residuals in this MADR (or a companion PLAN
  when implementation is scheduled).
* **C. Freeze feature work and clear the entire list in one pass** — including
  forge comment threads, GH live logs, and a11y everywhere.

## Decision Outcome

Chosen option: **"B. Accept this audit as the authoritative prioritized backlog"**, because the highest-severity issues are concentrated, cheap relative to product expansions, and already violate stated code contracts (e.g. keymap actions "must have a real handler"; `displayError` as the single user-facing error mapper; page index == sidebar order). Option A leaves active navigation bugs (worktrees index) and silent failures untracked. Option C over-scopes into multi-week forge/product work and blocks unrelated delivery without proportional safety gain.

### Consequences

* Good, because HIGH bugs get a clear ownership order and file-level evidence.
* Good, because intentional deferrals (preview network isolation, no reword,
  submodule UI) stay labeled as product choices, not accidental bugs.
* Good, because page-index / keymap / palette alignment can be enforced with
  small regression tests.
* Neutral, because severity is static-analysis judgment; live macOS QA may
  re-rank a few MED items.
* Bad, because without a companion PLAN and scheduled work, the backlog can
  still rot (mitigate by opening a PLAN when the first remediation cycle starts).
* Bad, because some MED "gaps" require product decisions (comment threads,
  GPG signing) not just code fixes.

### Confirmation

* HIGH fixes land with analyzer-clean `flutter analyze` and targeted tests
  (page-index constant, keymap↔handler coverage, rebase error surface,
  proxy/disable remote-edit in secondary windows).
* This MADR's HIGH section is empty or marked fixed after a remediation cycle
  (prefer updating status/date and a short "Remediation log" rather than
  rewriting historical findings silently).
* Companion PLAN: [0004-PLAN-ui-ux-deep-debug-audit.md](0004-PLAN-ui-ux-deep-debug-audit.md)
  owns phased delivery, file-level steps, tests, and exit criteria. It must not
  invent new architecture without amending this decision.

## Pros and Cons of the Options

### A. Record findings only; fix ad hoc

* Good, because zero process overhead.
* Bad, because the worktrees page-index bug and silent rebase/remote-edit
  failures are easy to rediscover later and hard to prioritize without a list.
* Bad, because partial docs (`DRAG_AND_DROP_ENGINE.md` header, ACTION_PLAN
  deferred claims) already show how ad-hoc tracking drifts.

### B. Authoritative prioritized backlog (chosen)

* Good, because separates correctness from product expansion.
* Good, because maps to existing house rules (root-cause, displayError,
  keymap contract).
* Neutral, because still needs maintainer time to schedule fixes.
* Bad, because a long findings appendix can be mistaken for a commitment to
  ship every LOW item (it is not).

### C. Freeze features; clear everything

* Good, because maximum polish.
* Bad, because comment timelines, GH live logs, and full a11y are multi-week
  efforts orthogonal to broken navigation constants.
* Bad, because blocks forge/branches product work already in flight.

## More Information

### Severity legend

| Sev | Meaning |
| --- | --- |
| **HIGH** | Incorrect behavior, silent failure, or active broken path users can hit |
| **MED** | Incomplete wiring, misleading UI, or discoverability inconsistency |
| **LOW** | Polish, intentional residual, or documented deferral |

---

### HIGH — fix first

#### H1. Worktrees page index is off-by-one after Project tab removal

* **Where:** `lib/features/worktrees/worktree_tabs.dart` —
  `kWorktreesPageIndex = 6`
* **Evidence:** Sidebar / `IndexedStack` order is 0 Repository … 5 Worktrees
  (`app_shell.dart` `_pages`). `DropZoneId.worktrees.pageIndex` is **5**
  (asserted in `test/drop_registry_test.dart`). DnD and ⌘6 use 5;
  `switchToWorktree` / palette-adjacent paths that call
  `pageIndexProvider.select(kWorktreesPageIndex)` select **6**, which is
  outside the stack (assert in debug; blank/wrong content in release).
* **Also:** `app_shell.dart` still maps `'global.panel7' → _selectPage(6)`
  though no `global.panel7` keymap action exists (dead code that would re-break
  if ever bound).
* **Fix:** Set `kWorktreesPageIndex = 5` (or derive from
  `DropZoneId.worktrees.pageIndex`); delete `global.panel7`; add a unit test
  that page-index constants match `DropZoneId` / panel count.

#### H2. Keymap actions with no panel handlers (bindable no-ops)

* **Where:** `lib/core/settings/keymap.dart` — `branches.publish`,
  `branches.createRequest`, `branches.openCi`, `branches.compare` (empty
  default bindings); `branch_navigator.dart` handlers only wire
  `newBranch` / `createTag` / `merge` / `delete`.
* **Evidence:** Keymap file comment requires every action to have a real
  handler. UI implements Publish / Create PR·MR / Open CI on
  `branch_detail.dart` buttons, but not via keymap or palette
  (`command_palette.dart` `_panelActions` omits them). Users can assign keys
  in Keyboard Mappings; keys do nothing.
* **Fix:** Wire handlers (selection-gated) to the same callbacks as detail
  actions; add palette specs; **or** remove from `kKeymapActions` until ready.
  Prefer wiring — the product already has the buttons.

#### H3. Interactive rebase swallows range-fetch errors

* **Where:** `lib/features/history/history_view.dart` `_actRebaseFrom`
* **Evidence:** `git.log(... '${parent}..HEAD' ...)` is wrapped in
  `catch (_) { return; }` with no dialog. Other failures in the same method
  correctly call `showErrorDialog`.
* **Fix:** Surface via `showErrorDialog(context, displayError(e))` when
  mounted.

#### H4. Remote-edit conflict / sync failure only logs to Output

* **Where:** `lib/features/viewer/remote_edit_service.dart` `_syncFile`
* **Evidence:** Out-of-band remote hash change and catch paths call
  `outputLogProvider.logError` only. Output pane is off by default. Local
  editor save appears to succeed; remote never updates.
* **Fix:** User-visible dialog or undo-style toast on conflict/failure; keep
  log as secondary. On conflict, offer overwrite / discard / cancel.

#### H5. Secondary windows expose remote-edit but cannot `uploadBytes`

* **Where:** `ProxyCommandExecutor.uploadBytes` throws
  `UnsupportedError('uploadBytes is not proxied…')`; detached repo mounts full
  `RepoStatusView` (`secondary_window_main.dart`); status/file tree "Open file"
  calls `remoteEditServiceProvider.openRemoteFile`.
* **Evidence:** Mutations via `execute()` are proxied; uploads are not. Stale
  comment on the proxy claims pop-outs are "read-only viewers that never
  push/pull/fetch" — false for detached `RepoStatusView`.
* **Fix:** Either proxy `uploadBytes` over the hub, or disable remote-edit /
  rewrite the open action on secondary engines with a clear message.

#### H6. Widespread raw `'$err'` bypasses `displayError`

* **Where (examples):** `repo_status_view.dart` status `error:`;
  `file_view.dart`; `history_view.dart`; `file_history_sheet.dart`;
  `blame_sheet.dart`; `diff_view.dart` `DiffFailure`; `dashboard_sheet.dart`;
  `recovery_sheet.dart`; clone/create sheets.
* **Evidence:** `displayError` is documented as the single user-facing mapper
  (`lib/core/utils/display_error.dart`). Dialogs and forge `SectionError` use
  it; many panel/sheet states dump `GitException: … (exit 128)`.
* **Fix:** Route through `displayError` / `SectionError`; fix `DiffFailure`
  once for all diff surfaces.

#### H7. Forced `--no-gpg-sign` with no UI disclosure

* **Where:** `lib/core/git/git_service.dart` commit / amend paths always pass
  `--no-gpg-sign` (needed so `commit.gpgsign=true` does not hang/fail over SSH
  without a GPG agent).
* **Evidence:** No Settings notice, commit-dialog hint, or tool-health banner.
  Policy-sensitive for teams that require signed commits.
* **Fix:** Detect `commit.gpgsign` / signing config and show a permanent
  notice; longer-term: optional signing path when an agent is available.
  Architecture already rejected full libgit2 for signing (`0001-MADR`).

#### H8. Logout / close tab: no dirty or pending-op guard

* **Where:** `connection_switcher.dart` Logout → `disconnect()`;
  `tabs_controller.dart` close tears down the session.
* **Evidence:** Branch switch and pre-push use `chooseAction` / dirty prompts;
  disconnect does not. Uncommitted work and mid-merge/rebase can be abandoned
  without confirmation (especially painful on remote hosts).
* **Fix:** If status is dirty or `pendingOp != none`, confirm (offer Recovery
  when relevant) before disconnect/close-active-tab.

---

### MED — wiring, discoverability, misleading chrome

#### M1. Dual shortcut systems: native View menu vs remappable keymap

* Native fixed chords in `MainFlutterWindow.swift` (⇧⌘O Output, ⇧⌘E File View,
  ⇧⌘D Dashboard, ⇧⌘U Recovery, ⇧⌘H History window) are **not** in
  `kKeymapActions`. Keyboard Shortcuts sheet and remapping never cover them;
  remapping to the same chords can fight AppKit menu equivalents.
* Command palette has File/Output/Recovery toggles **without** shortcut hints
  and **omits Dashboard** entirely.
* **Fix:** Register as `global.*` keymap actions and drive menu equivalents
  from the same source, **or** document as non-remappable system chords and
  list them in the shortcuts sheet.

#### M2. Command palette gaps vs shell

* Missing: Open/Toggle Dashboard; branch publish / create-request / open-CI
  (blocked on H2); optional tab actions (see M4).
* Zoom-reset icon reuses zoom-out glyph (`command_palette.dart`).

#### M3. "Compare Changes" primary CTA is intentionally inert

* `branch_detail.dart` sets primary `onTap: null` with comment that the
  comparison inspector is always visible — renders as a disabled primary
  button.
* **Fix:** Non-interactive section header, or scroll-to-inspector on tap;
  never a disabled-looking primary CTA.

#### M4. No keyboard shortcuts for workspace tabs

* Tab strip only: `+` / close. No ⌘T / ⌘W (or cycle). Cap of 8 only on tooltip.
* **Fix:** `global.newTab` / `global.closeTab` (+ optional previous/next).

#### M5. History nav-rail drop zone is empty

* `drop_registry.dart` `DropZoneId.history` → `const []`. Rail still presents
  History as a zone; DnD doc header still says engine "not yet implemented"
  while A–D are shipped (`docs/DRAG_AND_DROP_ENGINE.md`). Remaining product
  drops: E1 branch→commit move, E2 commit→branch cherry-pick.
* **Fix:** Wire E1/E2 or stop advertising History as a drop target; refresh
  the DnD doc status line.

#### M6. Forge Releases rows look list-like but do nothing

* `project_sections.dart` `_releaseRow` has no `onTap` / selection /
  detail pane (issues and milestones do).
* **Fix:** Detail + open-on-forge, or explicitly non-tappable row styling.

#### M7. Labels are view-only chips (no CRUD / detail)

* Acceptable if intentional; inconsistent with issues. Document or extend.

#### M8. Issue / PR comments are write-only in-app

* Code comments note comments are not rendered in the detail body; no timeline
  invalidation. Users can post but not read threads. Review threads remain out
  of scope per `0002-MADR` / PLAN.
* **Fix:** Fetch timeline/notes, or reword UI to "Comment on website…" with
  deep link emphasis.

#### M9. Binary conflict copy contradicts working Ours/Theirs

* `conflict_view.dart`: "Binary file conflict — resolve via the command line"
  while `repo_status_view` still offers Use Ours / Use Theirs (whole-file
  `checkout --ours/--theirs` + add).
* **Fix:** Copy: preview unavailable; use whole-file Ours/Theirs above.

#### M10. GitHub Actions: no live job logs

* `run_jobs_view.dart` — in-progress jobs are a static placeholder; logs after
  completion only. GitLab has live `glab ci trace`. Documented platform limit;
  still a cross-forge UX cliff.
* **Fix:** Poll partial logs if API allows; always surface "Open on GitHub".

#### M11. Markdown/HTML preview: links and images inert by design

* `preview_view.dart` — no network, image placeholders. Safe; poor for READMEs.
* **Fix:** Optional "open link in browser"; relative image bytes with caps.

#### M12. Secondary History window shortcut surface is thin

* Only `global.undo` bound in-window; main shell ⌘R does invalidate open
  windows. No local refresh when focus is in the pop-out.
* Detached repo is **status only** (no forge/branches/stashes) — fine if
  chrome says so; "full repo window" can over-promise.

#### M13. File tree vs status list selection not shared

* Independent `_selectedPath` / `_selectedPaths`; multi-select and tree can
  diverge.
* **Fix:** Shared selection notifier or pass selection into `FileView`.

#### M14. Accessibility almost only on branch rows

* `Semantics` concentrated in `branch_navigator` / `branch_row_semantics`.
  Nav rail, tab strip, palette rows, many toolbars rely on tooltips only.
* **Fix:** Extend the branch-row pattern to chrome (selected, button, label).

#### M15. Host-key dialog dismiss edge cases

* Intentionally not `EscapeDismissible`. Ensure barrier dismiss (if any)
  always calls `rejectHostKeyChange` so connect cannot hang with prompt set
  and no UI.

#### M16. Stale process docs

* `docs/DRAG_AND_DROP_ENGINE.md` header outdated; `ACTION_PLAN.md` deferred
  claims partially historical; transport known-gaps in ARCHITECTURE are
  separate from UI but still open.

---

### LOW — polish and known residuals

| ID | Item | Notes |
| --- | --- | --- |
| L1 | Undo empty journal silent | Optional soft toast "Nothing to undo" |
| L2 | Tab strip: no middle-click close, no dirty badge | Polish |
| L3 | Interactive rebase: no reword | Intentional (`GIT_EDITOR=true`); optional menu hint |
| L4 | Submodule open rejected; no management UI | Documented deferral |
| L5 | Split / `-w` diffs drop hunk staging | Documented; banner if missing |
| L6 | Diff pop-out is in-window float, not native window | OK unless multi-monitor demand |
| L7 | Viewer residuals | Trailing-newline phantom line; fixed itemExtent clips tall glyphs; one overlong line disables whole-file highlight; SelectionArea only realized lines — see `viewer_engine_findings.md` |
| L8 | No worktrees panel-scoped keymap category | Create/open via UI + palette targets only |
| L9 | Native `ToolBar` / `MacosScaffold` chrome | ACTION_PLAN deferred; needs live Mac preview |
| L10 | Window default size already 1080×720 | `window_sizing_proposal` default applied; min 640×480 applied |

---

### What looks solid (do not re-open as bugs)

* **Palette → `PaletteIntent` → `PanelShortcuts`**: age-gated consume, same
  handlers as keyboard shortcuts, text-focus yield for panel bindings.
* **BusyActionState** shared busy/refresh contract across major panels.
* **TabsHost** menu bridge, window title, container above Navigator for sheets.
* **Reconnect overlay** with Stop Retrying vs Cancel; host-key messaging.
* **Hunk staging**, multi-select stage/discard, conflict multi-resolve, mixed
  staged/unstaged file toggle in the file tree.
* **DnD A1–D1** + staging banner + ESC cancel (History zone excepted — M5).
* **EscapeDismissRegistry** LIFO vs panel deselect.
* **Secondary History** watch ticks, settings-sync signature, undo relay via
  proxied `execute()`.
* **Viewer Phase 1–4** encoding / clamp / highlight worker fixes largely done.
* **Forge merge readiness** strips and update-branch / rebase actions present
  on both forges (remaining out-of-scope items tracked under `0002-MADR`).

---

### Suggested remediation order (when scheduled)

1. **H1** page index + dead `panel7` (one-line constant + test).
2. **H3** rebase error surface (tiny).
3. **H2** keymap handlers / remove orphans + palette specs.
4. **H4 / H5** remote-edit visibility + secondary-window policy.
5. **H6** `displayError` sweep (`DiffFailure` first).
6. **H8** dirty disconnect/close guards.
7. **H7** GPG disclosure (product copy; signing is larger).
8. **M1–M5** menu/keymap/palette/DnD/History zone alignment.
9. **M6–M14** forge polish, a11y, selection sync as capacity allows.
10. **LOW / residuals** only when user reports or adjacent work touches them.

### Related documents

* `docs/ACTION_PLAN.md` — prior multi-cycle review (mostly done; some deferred).
* `docs/viewer_engine_findings.md` — viewer residuals (L7).
* `docs/window_sizing_proposal.md` — min/default sizes largely implemented.
* `docs/memory_audit.md` — Tier 1–2 memory fixes done.
* `docs/DRAG_AND_DROP_ENGINE.md` — A–D shipped; E1/E2 and status header stale (M5).
* `docs/0001-MADR-native-git-libgit2.md` — GPG/signing architecture context (H7).
* `docs/0002-MADR-forge-change-request-merge-and-models.md` — forge merge depth;
  comment/review threads still product-scoped (M8).
* `docs/0003-MADR-base-relative-branches-workspace.md` — branches workspace;
  inert Compare CTA (M3) lives in that surface.

### Remediation log

| Date | Change |
| --- | --- |
| 2026-08-06 | Initial audit recorded; status `proposed` pending maintainer scheduling. |
| 2026-08-06 | Companion [0004-PLAN-ui-ux-deep-debug-audit.md](0004-PLAN-ui-ux-deep-debug-audit.md) written for review (phased HIGH→MED→LOW delivery). |
| 2026-08-06 | Product gates locked for the companion PLAN: **H5=B** (proxy `uploadBytes`), **M1=A** (remappable View globals), **M5=A** (DnD E1/E2), **M6=A** (release detail), **M8=A** (in-app comment timelines). |
| 2026-08-06 | **H1 fixed (Phase 0):** `kWorktreesPageIndex = 5`; dead `global.panel7` removed; page-index invariant tests. |
