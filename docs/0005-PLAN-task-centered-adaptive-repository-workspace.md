# Implement the task-centered adaptive repository workspace

Associated MADR:
[0005-MADR-task-centered-adaptive-repository-workspace.md](0005-MADR-task-centered-adaptive-repository-workspace.md)

- Plan status: **completed** (Phases 0–11; Phase 12 remains separately decided)
- Codebase assessment date: 2026-08-13
- Delivery completion date: 2026-08-13
- Decision prerequisite: MADR 0005 was accepted when the maintainer explicitly
  authorized implementation of all phases on 2026-08-13.
- Delivery model: incremental, analyzer-clean work slices with tests in the
  same slice as production code. The maintainer owns commits; an agent must not
  commit or push unless asked, and any requested commit uses
  `git commit --no-edit`.
- Safety: ordinary local/integration tests are allowed. Never run
  `live-forge` tests unless the maintainer explicitly requests them.

This is the executable companion to MADR 0005. The MADR owns the product and
architecture rationale; this plan owns delivery order, concrete interfaces,
state boundaries, migration behavior, tests, gates, and rollback.

## Goal

Deliver a coherent repository workspace in which a user can orient, select,
review, stage, describe, commit, publish, investigate, and recover without
losing context or having to learn a different interaction grammar on every
screen.

The completed implementation must:

1. Give Repository, History, Branches, Stashes, Forge, and Worktrees a shared
   context/header, adaptive pane, state, focus, and activity contract.
2. Make the normal stage-review-commit flow continuous and non-modal while
   retaining the existing hook-aware focused editor as an optional expansion.
3. Make remote work visibly queued/running/completed/failed through typed
   operation data, without parsing command output or exposing secret-bearing
   command strings.
4. Preserve all current local/SSH, scoped-repository, worktree, multi-tab,
   secondary-window, mutation-refresh, undo, and safety behavior.
5. Improve discoverability through an entity-aware Go to / Do palette and
   semantic back/forward navigation.
6. Meet the MADR's compact, standard, wide, keyboard, VoiceOver, performance,
   and usability confirmation criteria.

## MADR Assessment

### Assessment result

MADR 0005 is internally consistent and implementable on the existing
architecture. It does not require a transport, Riverpod, or service-layer
rewrite. Its central decision fits the codebase because the app already has
several of the required seams: per-tab root `ProviderContainer`s, repository UI
identity, persisted pane widths, shared async/error widgets, a common keymap,
panel intent dispatch, a unified diff parser, lane-aware executors, output
logging, and an undo/recovery journal.

The decision is broad enough that it must be delivered as a sequence of
independently releasable vertical slices. A single large visual rewrite would
place selection, mutation safety, remote refresh, focus, secondary windows, and
stored layout state at unnecessary risk.

### Factual corrections applied during assessment

The associated MADR was corrected without changing its decision:

* `CommandPalette` already includes live local branches, worktrees, and saved
  remote repositories. The real gap is commits, files, stashes, forge entities,
  typed result ranking, and entity-to-valid-action drill-down.
* The `macos_ui` sidebar is resizable and draggable closed. It is not literally
  permanent, but its inherited 556px auto-hide breakpoint leaves its 240px
  minimum width open at Magic Git's supported 640px window width.

### Clarifications that govern implementation

These interpretations make ambiguous MADR language deterministic without
changing the chosen architecture:

* Repository “text filtering” initially means local matching over path, prior
  rename path, directory, and status labels. It does not grep file contents or
  add remote commands per keystroke.
* The shared context bar may show forge, worktree, and recent-commit enrichment
  only when those values are already cached. Merely painting the bar must not
  start new forge/API or Git reads.
* The Activity Center represents user-meaningful operations. Background status,
  diff, blame, and polling reads stay out of the activity list unless they fail
  in a way that needs user action.
* “Cancel” is absent unless the underlying operation exposes a real safe cancel
  handle. Dismissing UI never pretends to cancel a command.
* Initial workspace presets are fixed built-in arrangements. Arbitrary preset
  authoring is a later enhancement after pane restoration proves stable.
* Line/range staging, image diffs, redo, workspace sets, ownership, submodules,
  LFS, and stacked branches are gated extensions. They must not delay the core
  workspace, and the last four require their own product/architecture approval
  before implementation.

## Scope

### Core delivery scope

| Track | Required outcome |
| --- | --- |
| Workspace contracts | Shared context, navigator, canvas, inspector, task dock, async/error, selection, and focus primitives |
| Adaptive layout | Compact/standard/wide arrangements, resizable and collapsible panes, sidebar auto-collapse, durable safe restoration |
| Repository cockpit | Changes/Files modes, local filtering/grouping, visible bulk actions, aggregate review queue, useful clean state |
| Commit flow | Persistent collapsible composer, existing hook preview, Accept and Accept + Push, optional focused editor |
| Context | Repository/backend/host/worktree/branch/base/dirty/pending/divergence plus cached forge/CI state and one resolved primary action |
| Activity | Typed lifecycle, safe labels, output linkage, undo/recovery linkage, per-repository presentation |
| Navigation | Entity-aware palette, valid-action drill-down, shared focus lens, semantic back/forward history |
| Visual system | Semantic tokens, density, high contrast, reduced motion, standard controls and state treatments |
| Screen migration | History, Branches, Stashes, Forge, and Worktrees adopt the shared shell without losing domain capability |
| Quality | Keyboard and VoiceOver contract, compact/standard/wide fixtures, golden coverage, performance budgets, usability measurement |

### Gated follow-on scope

The following are planned after the core delivery gate:

* Line/range staging and discard.
* Image comparison for working-copy and commit diffs.
* Commit templates, recent-message assistance, co-author trailers, and policy
  preflight.
* Customizable labeled toolbar, comfortable/compact density, high contrast,
  and reduced-motion polish beyond the core token work.
* Saved multi-repository workspace sets and tab aliases.
* A safe redo feasibility spike followed by implementation only if state
  preconditions can be proven.

### Explicit non-goals

* No transport replacement and no local clones for SSH repositories.
* No parsing of human-facing Git, `gh`, or `glab` output to derive UI state.
* No eager forge/API fetch solely for workspace chrome.
* No unbounded palette search on each keystroke.
* No fake cancellation, retry-as-a-bandaid, or optimistic success state.
* No full light theme in this initiative.
* No submodule, LFS, Code Owners, or stacked-branch implementation in this
  plan. Each needs a scoped follow-on decision because each adds domain and
  service behavior, not merely presentation.
* No live-forge test execution as part of ordinary verification.

## Codebase Grounding Map

| Concern | Current fact | Reuse or required change |
| --- | --- | --- |
| Main shell | `AppShell` renders six lazy pages in an `IndexedStack` inside `MacosWindow`; the sidebar is 240–380px. | Retain lazy mounting and page order. Add a context layer and raise the sidebar breakpoint; do not replace tab containers. |
| Tab isolation | Each `RepoTab` owns a fresh root `ProviderContainer`; switching tabs unmounts the inactive `AppShell` but retains provider state. | Workspace focus, drafts, review state, and activity must live in the tab container, not process-global widget state. |
| Repository UI identity | `repositoryUiIdentityProvider` combines saved connection/local IDs with canonical `gitCommonDir`; ad-hoc sessions are memory-only. | Use this identity for durable layout preferences. Do not persist ad-hoc layout records. |
| Existing pane persistence | `PaneId`, `PaneSpec`, `AppSettings.paneWidths`, and `ResizableMasterDetail` persist global master widths and display-clamp narrow layouts without overwriting stored values. | Generalize interaction behavior and seed repository-specific workspace preferences from existing widths without deleting old keys. |
| Repository state | `RepoStatusView` watches `statusProvider`, `pendingOpProvider`, `refsProvider`, watcher state, output visibility, and Files visibility. | Extract view models incrementally; keep provider invalidation and watch suppression semantics intact. |
| Repository selection | Private `_SectionKind` plus `_selectedPaths` supports section-scoped Finder-like selection and bulk mutations. | Promote to a testable selection model before adding filters or multi-file review. Never allow ambiguous cross-section mutation. |
| Diff | `HunkDiffView`, `DiffView`, `SplitDiffView`, `DiffParser`, and `unified_diff.dart` provide shared parsing, rendering, off-isolate handling, and hunk patching. | Reuse them in the aggregate queue; add selection patching as a pure extension only after core delivery. |
| Commit | `CommitDialog` owns hook preview, GPG disclosure, editing, commit, push handoff, shortcuts, and refresh. | Extract one controller/body used by both dock and focused sheet. Preserve existing command and refresh paths. |
| Mutation refresh | `refreshAfterMutation`, `repoMutationFamilies`, `ownMutationTrackerProvider`, and `worktreeEditsProvider` are the authoritative post-mutation path. | Every new mutation endpoint must call the same path; no local invalidation lists. |
| Activity evidence | `CommandTelemetry` records completed aggregate samples; `OutputLog` records transcripts; panels own unrelated `busy` flags. | Add typed operation lifecycle. Do not reinterpret telemetry samples or transcript text as operations. |
| Command scheduling | `CommandLaneScheduler` knows queued/running state for read, sync, exclusive, and isolated lanes. | Add optional lifecycle callbacks without changing ordering, concurrency, or watchdog behavior. |
| Executor seam | `CommandExecutor` has SSH, local, proxy, and scoped implementations. Proxy requests cross platform channels. | Any operation metadata added to `execute` must be optional, transport-neutral, codec-tested, and forwarded unchanged by scoped/proxy executors. |
| Palette | `CommandPalette` has static actions plus dynamic branches, worktrees, and saved SSH repositories; panel actions use `PaletteIntent`. | Replace the private flat row model with typed entities/results while retaining the same guarded action handlers. |
| Forge context | `branchForgeProvider` maps branches to an open PR/MR and recent CI by reusing forge providers. | Publish landed values to a passive context cache; the workspace bar must not watch this provider eagerly. |
| Undo/recovery | `UndoJournal`, `UndoController`, `UndoToast`, and `RecoverySheet` already validate post-state and expose durable recovery. | Link activity records to existing undo/recovery; do not duplicate undo semantics. |
| Theme | `AppTheme` centralizes only terminal background and list selection tint; feature widgets own most state colors and spacing. | Add semantic tokens and migrate shared primitives first. Keep dark-only behavior. |
| Multi-window | Secondary Flutter engines use `ProxyCommandExecutor`; detached repo windows render `RepoStatusView`, History has its own window path. | Keep proxy payloads byte-safe and ensure workspace prefs/activity/focus either synchronize explicitly or degrade honestly. |
| Tests | There is broad unit/widget/integration coverage for status, diffs, panes, palette, tabs, branches, stashes, output, undo, and worktrees, but no checked-in golden suite. | Extend current tests, add deterministic macOS goldens, and keep live-forge tests skipped. |

## Delivery Invariants

Every phase must preserve these rules:

1. `CommandExecutor` remains the only transport seam; feature widgets never
   branch on SSH versus local behavior to implement Git/forge capability.
2. Repository/provider state remains isolated by tab and repository. A path
   collision across two hosts must not share drafts, focus, layout, activity,
   reviewed markers, or palette results.
3. User selections use stable domain identities: path plus staged section,
   commit OID, full ref name, stash OID, worktree path, forge kind plus numeric
   ID. List indices are never durable identity.
4. A filter changes presentation only. It never stages, unstages, discards,
   clears selection silently, or changes the action payload.
5. Stored widths are clamped for display but are not rewritten because a
   window temporarily became narrow.
6. Background/hidden panels do not begin new network work merely because the
   shared scaffold exists.
7. All destructive operations retain confirmation, stale-state checks,
   snapshots, and undo behavior already present at their service call sites.
8. Activity labels are curated text and typed metadata. Raw command strings
   stay in Output and never become default Activity Center titles.
9. A visual state is conveyed by text, icon/shape, or semantics as well as
   color.
10. New async flows have explicit loading, success, empty, stale, failure, and
    supersession behavior. No permanent spinner is an accepted fallback.
11. The main page order and `DropZoneId.pageIndex` contract remain Repository,
    History, Branches, Stashes, Forge, Worktrees at indices 0–5.
12. The standard validation command set is run before staging any phase:
    `dart format`, `flutter analyze`, targeted tests, then ordinary
    `flutter test` at each release checkpoint.
13. Tests are written in the same work slice as behavior. Refactors first gain
    characterization coverage; deterministic new behavior starts with a
    failing test; a reproducible bug fix starts with a regression test that
    fails for the reported reason.
14. Tests assert public behavior and safety boundaries rather than private
    widget structure. A test may use a narrow implementation hook only when
    rendering, platform, or isolate behavior cannot otherwise be observed
    deterministically, and that hook must be documented as test-only.

## Implementation Steps

### Phase 0 — Acceptance, baselines, and characterization

**Intent:** lock evidence and current behavior before structural UI work.

#### Steps

1. Maintainer reviews MADR 0005. If accepted, update only its metadata to
   `status: accepted` and its decision date. If rejected or revised, update this
   plan before implementation.
2. Add `docs/0005-UX-BASELINE-task-centered-adaptive-repository-workspace.md`
   using the six tasks from the MADR Confirmation section. For each task record:
   backend, repository size/status shape, window size, completion time,
   clicks/keystrokes, wrong turns, errors, and observer notes.
3. Capture at least one local and one SSH run at 640×480, 1080×720, and a wide
   size. Record unavailable scenarios honestly; do not substitute invented
   numbers.
4. Add characterization tests for existing behavior before extraction:
   section-scoped multi-selection, partially staged path handling, diff toggle
   behavior, commit dialog hook states, output visibility, pane display clamps,
   palette branches/worktrees, and page retention across sidebar changes.
5. Record performance baselines using existing `CommandTelemetry`: command
   count and p95 duration for initial Repository paint, selecting eight
   prefetched files, and opening Branches/Forge. Add frame timing for a 2,000-
   file status list and a 20,000-line diff test fixture.

#### Files

| File | Change |
| --- | --- |
| `docs/0005-MADR-task-centered-adaptive-repository-workspace.md` | Status/date only after acceptance |
| `docs/0005-UX-BASELINE-task-centered-adaptive-repository-workspace.md` | New measured baseline artifact |
| `test/repo_status_view_test.dart` | Existing-flow characterization |
| `test/commit_dialog_test.dart` | Hook/manual/commit-and-push characterization |
| `test/command_palette_test.dart` | Existing dynamic target characterization |
| `test/resizable_master_detail_test.dart` | Extend narrow display/persistence coverage |
| `test/workspace_performance_baseline_test.dart` | Deterministic large-list/diff benchmark fixtures |

#### Exit criteria

* MADR status is explicit.
* Every baseline result is measured or marked unavailable, never estimated.
* Characterization tests pass without production behavior changes.
* Baseline command counts and frame timings are saved for later comparison.

### Phase 1 — Shared models, repository-scoped preferences, and design tokens

**Intent:** establish stable contracts before moving visible UI.

#### Steps

1. Add immutable workspace role models:
   `WorkspacePaneRole`, `WorkspaceSizeClass`, `WorkspacePreset`,
   `WorkspaceSelection`, `WorkspaceAsyncState`, and `WorkspaceAction`.
   `WorkspaceAction` contains a stable action ID, label, semantic intent,
   enabled/disabled reason, destructive flag, shortcut hint, and callback at
   the widget boundary; it never stores a `BuildContext`.
2. Define size classes from the content area's available width:
   compact `< 720`, standard `720–1199`, and wide `>= 1200` logical pixels.
   Centralize these constants and test exact boundary values.
3. Add `RepositoryWorkspacePrefs` version 1 containing:
   navigator mode, preset, navigator/inspector/task-dock widths or heights,
   pane collapsed/pinned bits, diff view preferences, grouping choice, and
   toolbar-label preference. Do not persist current selection, query text,
   command output, activity, or commit-message drafts.
4. Store preferences by `RepositoryUiIdentity`. Durable identities use a
   `repositoryWorkspacePrefs_v1_<preferenceKey>` key; ad-hoc identities use an
   in-memory map keyed by `memoryKey`. Serialize writes per identity using the
   same load-update-save mutex pattern as `branch_workspace_prefs.dart`.
5. On first load, seed applicable widths from existing global `PaneId` values.
   Do not delete or rewrite the existing `paneWidth_*` keys; they are the
   rollback source and remain in use by unmigrated screens.
6. Add global `WorkspaceDensity {compact, comfortable}` and high-contrast
   preferences to `AppSettings`. Respect `MediaQuery.disableAnimations` for
   reduced motion instead of inventing a conflicting animation setting.
7. Expand `AppTheme` into semantic design tokens for surfaces, type roles,
   spacing, radii, row heights, focus, hover, selection, drop target, success,
   warning, danger, conflict, CI state, and minimum target size. Existing
   terminal/diff colors remain the source for code surfaces.
8. Create shared state widgets for loading, empty, partial error, stale data,
   and unavailable enrichment. Adapt `SectionError` and existing async helpers
   rather than creating parallel error grammar.

#### Files

| File | Change |
| --- | --- |
| `lib/features/common/repository_workspace_models.dart` | New role, size, preset, selection, and action contracts |
| `lib/core/settings/repository_workspace_prefs.dart` | New versioned identity-keyed preference model/store |
| `lib/core/settings/app_settings.dart` | Density/high-contrast fields, load/save/equality/setters |
| `lib/core/settings/pane_layout.dart` | Compatibility mapping from existing `PaneId` widths |
| `lib/core/providers/app_providers.dart` | `repositoryWorkspacePrefsProvider` and reset registration |
| `lib/core/theme/app_theme.dart` | Semantic token definitions and density resolution |
| `lib/features/common/async_views.dart` | Shared workspace state presentation |
| `test/repository_workspace_prefs_test.dart` | Versioning, identity, ad-hoc, migration, races, clamps |
| `test/app_settings_test.dart` | New global settings persistence/equality |
| `test/workspace_models_test.dart` | Breakpoint and action contract tests |

#### Exit criteria

* Two repositories with the same path on different saved hosts cannot share
  preferences.
* Linked worktrees sharing `gitCommonDir` get the documented shared/default
  behavior; worktree-specific pane state is represented explicitly where
  required rather than accidentally colliding.
* A compact render never overwrites a stored wide layout.
* Existing settings and pane tests remain green with old keys intact.

### Phase 2 — Typed operation lifecycle and Activity Center foundation

**Intent:** make remote work observable before relocating high-frequency
mutations into new controls.

#### Steps

1. Introduce `OperationId`, `OperationDescriptor`, `OperationRecord`,
   `OperationPhase`, `OperationKind`, and `OperationVisibility` in
   `core/exec`. A descriptor contains only safe data: repository path,
   user-facing label, operation kind, lane, optional affected-object summary,
   and whether cancellation is supported.
2. Add a per-tab `OperationActivityNotifier` with these transitions:
   `queued → running → succeeded|failed|canceled`. Updates are monotonic;
   terminal records cannot return to running. Retain at most 50 terminal
   records and evict records older than 30 minutes, while never evicting a
   queued/running item.
3. Add optional operation metadata and lifecycle callbacks to
   `CommandExecutor.execute`. Defaults preserve every existing call site.
   Forward the fields through `SSHCommandExecutor`, `LocalCommandExecutor`,
   `ScopedCommandExecutor`, `ProxyCommandExecutor`, request codecs, and the
   main-window hub.
4. Extend `CommandLaneScheduler.run` with optional `onStarted`; emit `queued`
   before enqueue, `running` exactly when the body receives a lane, and a
   terminal phase from the executor's actual result/error. Do not alter FIFO,
   concurrency caps, retries, timeout, watchdog, or generation semantics.
5. Give user-triggered Git and forge mutations curated descriptors at their
   service boundary. Add an explicit `background`/hidden visibility argument
   where one service method serves both toolbar and automatic work—for example,
   `fetchInBackground` must not create a normal activity row. Inject the
   per-tab operation reporter when `gitServiceProvider`, `ghServiceProvider`,
   and `glabServiceProvider` construct their services; the services remain
   unaware of Riverpod.
6. Add optional `operationId` to `OutputLine`; update `OutputLogNotifier`
   logging methods to attach it without changing transcript text. Activity can
   request Output reveal at the first line carrying that ID; it never searches
   displayed strings.
7. Link successful records to Undo when `_runCaptured` produces an
   `UndoRecord`: push it through the existing `onUndoRecord` callback, then mark
   the same `OperationId` undoable in the activity registry. Do not add
   operation data to persisted snapshot refs or parse the journal afterward.
   Link failures to Output and recovery where applicable. Do not create a
   second undo journal.
8. Implement `ActivityCenterButton`, compact active-operation summary, and
   popover/sheet list. Show repository, host label, phase, elapsed time,
   user-facing result, Output link, Undo link, and Recovery link.
9. Cancellation remains hidden for request/response commands. Initially expose
   it only for stream handles or controllers that already provide an awaited,
   idempotent `cancel`; a canceled stream must settle its activity record.
10. Reset active-tab activity on disconnect only after in-flight records are
    marked superseded/failed. Do not let a late completion from an earlier
    session epoch mutate the new session's activity.

#### Files

| File | Change |
| --- | --- |
| `lib/core/exec/operation_activity.dart` | New typed lifecycle models and notifier |
| `lib/core/exec/command_lanes.dart` | Optional start callback; unchanged scheduling |
| `lib/core/ssh/ssh_command_executor.dart` | Optional metadata and lifecycle emission |
| `lib/core/exec/local_command_executor.dart` | Matching lifecycle emission |
| `lib/core/exec/proxy_command_executor.dart` | Metadata forwarding and supersession behavior |
| `lib/core/exec/scoped_command_executor.dart` | Transparent forwarding |
| `lib/core/exec/exec_proxy_codec.dart` | Versioned optional operation fields |
| `lib/core/providers/window_manager_bridge.dart` | Route activity to owning tab/session |
| `lib/core/output/output_log.dart` | Operation IDs and direct reveal anchors |
| `lib/core/git/git_service.dart` | Curated descriptors for user mutations; background distinction |
| `lib/core/github/gh_service.dart` | Curated forge operation descriptors |
| `lib/core/gitlab/glab_service.dart` | Curated forge operation descriptors |
| `lib/features/common/activity_center.dart` | Compact summary and detail surface |
| `lib/features/repository/output_view.dart` | Reveal/focus by operation ID |
| `test/operation_activity_test.dart` | State machine, retention, epoch isolation |
| `test/command_lanes_test.dart` | Exactly-once lifecycle ordering |
| `test/exec_proxy_codec_test.dart` | Optional metadata round trip/backward defaults |
| `test/command_telemetry_test.dart` | Prove aggregate telemetry remains unchanged |
| `test/output_log_test.dart` | Operation anchors survive capped/interleaved output |

#### Exit criteria

* A queued SSH mutation produces immediate visible acknowledgement before the
  lane starts it.
* Every lifecycle has exactly one terminal state, including timeout,
  supersession, proxy loss, and cancellation.
* Background reads do not flood Activity.
* Activity titles contain no raw argv, tokens, stdin, or environment values.
* Existing executor scheduling and telemetry tests remain unchanged in meaning.

### Phase 3 — Shared scaffold, adaptive pane engine, and repository context bar

**Intent:** land the common frame with Repository as the first consumer.

#### Steps

1. Implement `RepositoryWorkspaceScaffold` as composable primitives, not a
   feature-aware monolith. It accepts repository context, navigator, canvas,
   optional inspector, optional task dock, loading/error state, active-page
   state, and pane preferences.
2. Implement `AdaptiveWorkspaceLayout` with these exact defaults:
   * compact: one of navigator/canvas at a time, inspector as overlay, task dock
     collapsed unless focused;
   * standard: navigator + canvas, inspector as overlay or mutually exclusive
     with Files, compact task dock visible;
   * wide: navigator + canvas + optional pinned inspector/Files, full task dock.
3. Generalize divider behavior from `ResizableMasterDetail`: drag updates local
   state, persist once on end, cancel reverts, double-click resets, keyboard
   adjustment moves 16px, collapse preserves prior width, and display clamping
   never writes. Add semantics for role, value, increase/decrease, and reset.
4. Set `Sidebar.windowBreakpoint` to 760 in `AppShell` so the main sidebar is
   automatically absent at the 640px minimum. Add a visible sidebar toggle in
   compact context and a `global.toggleSidebar` action with no default binding;
   route it through `MacosWindowScope.toggleSidebar` and the native View menu.
5. Add immutable `RepositoryContextSnapshot` derived from existing connection,
   status, pending-op, refs/remotes, and active focus state. Optional worktree,
   recent-commit, and forge fields come only from passive landed-value caches.
6. Add a pure `resolvePrimaryRepositoryAction` with this precedence:
   * pending operation with conflicts → Resolve;
   * pending operation without conflicts → Continue;
   * conflicted tree → Resolve;
   * ahead and behind → Sync;
   * behind only → Pull;
   * ahead only with upstream → Push;
   * no upstream with a configured remote → Publish;
   * otherwise → Fetch.
   The resolver returns disabled reasons for busy, disconnected, or incomplete
   state. It never executes a mutation itself.
7. Build `RepositoryContextBar` from that snapshot. Collapse low-priority
   metadata into a disclosure menu at compact widths and preserve accessible
   full labels/tooltips for icon-only compact controls.
8. Add a passive `RepositoryContextSupplementCache` keyed by repository UI
   identity and session epoch. Branches/Forge/Worktrees/History publish already
   landed values; the bar watches the cache. Disconnect and repo switch clear
   it. This is how context enrichment avoids new reads.
9. Put Activity Center access and semantic back/forward placeholders in the
   shared bar, but do not enable navigation until Phase 7.

#### Files

| File | Change |
| --- | --- |
| `lib/features/common/repository_workspace_scaffold.dart` | Shared frame and role slots |
| `lib/features/common/adaptive_workspace_layout.dart` | Size-class layouts and dividers |
| `lib/features/common/repository_context.dart` | Snapshot, supplement cache, primary-action resolver |
| `lib/features/common/repository_context_bar.dart` | Shared visible context/action bar |
| `lib/features/common/resizable_master_detail.dart` | Reuse generalized divider primitive |
| `lib/features/app_shell.dart` | Sidebar breakpoint/toggle and scaffold placement |
| `lib/core/settings/keymap.dart` | Unbound remappable sidebar action |
| `macos/Runner/MainFlutterWindow.swift` | Native View-menu sidebar command routing |
| `lib/features/repository/repo_status_view.dart` | First scaffold consumer; existing body retained |
| `test/adaptive_workspace_layout_test.dart` | Breakpoints, clamps, collapse, keyboard divider |
| `test/repository_context_test.dart` | Pure state/action precedence table |
| `test/repository_context_bar_test.dart` | Compact/standard disclosure and semantics |
| `test/app_shell_test.dart` | 640px sidebar behavior and page preservation |

#### Exit criteria

* Repository renders inside the new scaffold with no staging/diff/commit
  regression.
* No context-bar-only remote command appears in command-count tests.
* The primary action always dispatches to the existing guarded handler.
* At 640×480 the navigator, canvas, and primary action are reachable without
  horizontal overflow.

### Phase 4 — Repository change navigator, filtering, and adaptive panes

**Intent:** make large working copies easy to shape without changing mutation
semantics.

#### Steps

1. Extract `_SectionKind`, row flattening, selection anchor/range rules, and
   selected-path reconciliation from `RepoStatusView` into an immutable
   `RepoChangeSelection` plus notifier/controller. Preserve the rule that one
   selection never spans staged, unstaged, untracked, or conflict sections.
2. Add `RepoChangeFilter` with free-text query, status set, path scope, grouping
   (`status` or `directory`), and include-reviewed flag. Matching is pure,
   case-insensitive by default, and operates only on landed `GitStatus` data.
3. Apply filtering after deriving the canonical row model and before rendering.
   Preserve hidden selected paths in the selection payload; display a banner
   such as “3 selected items are hidden by filters” with Reveal and Clear
   Selection actions. Never silently mutate the selection.
4. Implement Changes and Files navigator modes. Changes reuses status sections;
   Files embeds the current `FileView` tree behavior as a navigator body. At
   standard width only one navigator mode is visible. Wide mode may pin Files
   as an inspector using the same tree controller rather than mounting a second
   provider graph.
5. Add filter field, status chips, grouping menu, result count, clear button,
   and empty-filter result state. `Escape` first clears filter text, then yields
   to normal selection/pane dismissal.
6. Replace the fixed `Expanded(flex: 2)` / `Expanded(flex: 3|5)` Repository
   split with the adaptive divider and repository-scoped width preferences.
7. Move split/unified, whitespace, expanded context, blame, and pop-out into a
   `DiffViewControls` component. Keep split/unified and previous/next change as
   direct controls; put the rest in a labeled menu. Disabled state explains
   why hunk mutation is unavailable in split or whitespace-ignore mode.
8. Replace the clean-tree artwork block with `RepositoryCleanState`. Render
   local facts immediately and only cached enrichment; absent enrichment leaves
   no empty placeholders.
9. Keep current prefetch limits—eight files, five-second throttle, read lane—and
   add command-count tests proving filters and grouping cause zero executor
   calls.

#### Files

| File | Change |
| --- | --- |
| `lib/features/repository/repo_change_model.dart` | Public section/row/selection models |
| `lib/features/repository/repo_change_filter.dart` | Pure filter/group implementation |
| `lib/features/repository/repo_change_navigator.dart` | Changes/Files UI and keyboard behavior |
| `lib/features/repository/diff_view_controls.dart` | Consolidated diff controls |
| `lib/features/repository/repository_clean_state.dart` | Calm useful clean state |
| `lib/features/repository/repo_status_view.dart` | Orchestration and mutation callbacks |
| `lib/features/repository/file_view.dart` | Embeddable body/controller; no duplicate pane chrome |
| `lib/core/settings/repository_workspace_prefs.dart` | Repository navigator/layout fields |
| `test/repo_change_model_test.dart` | Partially staged, refresh, hidden selection invariants |
| `test/repo_change_filter_test.dart` | Query/status/path/group deterministic cases |
| `test/repo_change_navigator_test.dart` | Focus, range selection, filter escape, visible bulk actions |
| `test/repo_status_view_test.dart` | Adaptive pane and clean-state integration |

#### Exit criteria

* Filtering/grouping never changes Git state or performs a command.
* A partially staged path remains independently selectable in both relevant
  sections.
* Selection reconciliation after stage/unstage/external refresh matches current
  behavior and never points the diff at the wrong side.
* Stored pane width and navigator mode survive restart for durable identities.

### Phase 5 — Persistent hook-aware commit composer

**Intent:** remove the modal requirement from the highest-frequency workflow
without duplicating commit behavior.

#### Steps

1. Extract commit state from `CommitDialog` into a repo-family
   `CommitComposerController`: message, generation state, generated/editable
   state, GPG disclosure state, error, committing state, and the current staged
   count/signature.
2. Keep drafts in memory only inside the tab container. Clear a draft after a
   successful commit or explicit Clear; retain it through staging changes,
   sidebar navigation, and layout changes. Clear it on repository/session
   change so host/path collisions cannot inherit text.
3. Do not run `prepare-commit-msg` merely because files become staged. Run it
   when the user first expands/focuses the composer or explicitly requests
   Generate. Cache one preview per staged signature until the user edits the
   draft or the staged signature changes; a changed signature marks the preview
   stale and offers Regenerate without erasing text.
4. Build `CommitComposer` with collapsed, compact, and expanded forms. Always
   show staged count and current branch. Expanded form includes the existing
   80-column monospace message field, generated-message review/Edit state, GPG
   disclosure, Accept, and Accept + Push.
5. Preserve the existing entry guard against duplicate keyboard submission,
   `runAction`, `GitService.commit`, `refreshAfterMutation`, and background
   fetch behavior. Register Commit and subsequent Push as linked activity
   records; a successful commit followed by failed push remains a successful
   local commit plus failed push, never a failed commit.
6. Refactor `CommitDialog` into an optional focused wrapper around the same
   controller/body. Closing the focused editor does not discard the dock draft.
7. Route `repository.focusCommit`, Return shortcuts, and the context primary
   action to focus/expand the dock. Keep focused-sheet shortcuts working when
   that editor is open.
8. In compact layout, expanding the composer overlays or replaces the navigator
   rather than shrinking the code canvas below its floor. Escape collapses it
   unless a commit is running.

#### Files

| File | Change |
| --- | --- |
| `lib/features/repository/commit_composer.dart` | New shared body and UI states |
| `lib/features/repository/commit_composer_controller.dart` | Repo-scoped draft/hook/commit state |
| `lib/features/repository/commit_dialog.dart` | Thin focused-editor wrapper |
| `lib/features/repository/repo_status_view.dart` | Task-dock integration and action routing |
| `lib/core/settings/keymap.dart` | Labels/handlers updated from modal wording where needed |
| `test/commit_composer_controller_test.dart` | Draft, stale preview, session isolation, duplicate guard |
| `test/commit_composer_test.dart` | Collapsed/compact/expanded, keyboard, GPG, push outcome |
| `test/commit_dialog_test.dart` | Shared-controller focused wrapper regression |

#### Exit criteria

* A standard commit completes without opening a modal route.
* The hook preview is never invoked speculatively and never more than once for
  the same user-requested staged signature.
* Commit success clears the draft; failure leaves it editable.
* Existing commit, undo, watcher suppression, History refresh, and push behavior
  remain green in integration tests.

### Phase 6 — Aggregate multi-file review queue and visible bulk actions

**Intent:** turn multi-selection into an actual review workflow.

#### Steps

1. Add `ReviewItemId(section, path, worktreeRevision)` and an in-memory
   `RepoReviewState` containing ordered items, active item, reviewed markers,
   and collapsed file sections. Reviewed state is session-only and resets for a
   file when its status/worktree edit identity changes.
2. Convert the selected paths to deterministic on-screen order using the
   canonical row model, not `Set` iteration order.
3. Implement `MultiFileReviewView` as a virtualized list of per-file headers and
   lazily mounted diffs. Fetch the active item and prefetch at most the next two;
   do not watch a `fileDiffProvider` for every selected path simultaneously.
4. Add per-file anchors, a visible file index, previous/next file and change
   controls, reviewed toggle, staged/status badge, and failure isolation. One
   failed diff shows an error in that file while the rest remain usable.
5. Put applicable Stage/Unstage/Discard/Delete/Ignore actions in the review
   header. Derive them from the single section kind and route them to existing
   `_stageMany`, `_unstageMany`, and guarded destructive handlers. Keep context
   menus as redundant expert access.
6. Preserve selection after a bulk stage/unstage by moving or dropping paths
   according to the current single-file semantics; if the action makes the
   selection span two destination sections, clear with an explicit announcement
   rather than inventing an ambiguous mixed selection.
7. Add “Review selected” and “Review all visible” entry points. “All visible”
   snapshots the filtered path IDs at invocation; later filter changes do not
   silently alter the active queue.

#### Files

| File | Change |
| --- | --- |
| `lib/features/repository/repo_review_state.dart` | Stable review identity/state |
| `lib/features/repository/multi_file_review.dart` | Virtualized aggregate diff and controls |
| `lib/features/repository/repo_status_view.dart` | Selection-to-review orchestration |
| `lib/features/repository/repo_change_navigator.dart` | Review entry points and reviewed markers |
| `test/repo_review_state_test.dart` | Ordering, invalidation, refresh, reviewed reset |
| `test/multi_file_review_test.dart` | Lazy fetch budget, navigation, partial error, bulk actions |
| `test/repo_status_view_test.dart` | Multi-selection end-to-end regression |

#### Exit criteria

* Multi-selection never resolves to a count-only pane.
* Selecting 100 files does not start 100 diff reads.
* Bulk mutation payloads exactly match the visible snapshot the user invoked.
* A diff failure does not discard reviewed state or block other files.

### Phase 7 — Entity-aware Go to / Do palette and semantic navigation

**Intent:** connect existing capabilities by object and user intent.

#### Steps

1. Replace private `_PaletteCommand` with typed `PaletteEntry` variants:
   action, panel, repository, branch/tag, commit, changed file, repository file,
   stash, worktree, issue, change request, and pipeline. Each carries stable
   identity, kind, primary label, context label, search tokens, recency, and
   allowed action IDs.
2. Split query handling into a pure parser/ranker. Support prefixes
   `go:`, `git:`, `forge:`, `app:`, plus entity prefixes `branch:`, `commit:`,
   `file:`, `stash:`, `worktree:`, `issue:`, `request:`, and `ci:`. Rank exact
   ID/name, prefix, current focus, recency, then fuzzy subsequence.
3. Build results only from landed provider values for an empty/general query.
   Do not start History, tree, forge, or stash loads merely by opening the
   palette. An explicit entity prefix may start one bounded provider read after
   150ms debounce; cancel/supersede stale queries and cap each entity kind at 50
   results and the combined list at 100.
4. Selecting an entity opens an action step containing only valid operations.
   Reuse `PaletteIntent`, guarded branch switching, existing context-menu action
   builders, and current mutation confirmations. Destructive actions appear
   last and retain confirmation.
5. Add `WorkspaceFocus` variants for repository, branch/base, revision/range,
   path, stash, worktree, issue, request, and pipeline. Keep focus in the tab
   container and key it by session epoch.
6. Add a bounded `WorkspaceNavigationHistory` of 50 semantic locations.
   Consecutive equal locations coalesce; programmatic restoration does not push
   another entry; invalid/deleted objects produce an unavailable state with
   Back rather than silently selecting a neighbor.
7. Define page adapters that can apply a location after their lazy page mounts.
   `AppShell` selects/visits the page, stores a typed pending location, and the
   destination consumes it once its provider data can resolve the identity.
8. Wire context-bar Back/Forward, palette open/compare/history/blame actions,
   Branches→History/Forge, CI→commit/request, and file→History/Blame handoffs.
9. Keep the existing active-panel shortcut rule: a hidden panel never executes
   an action merely because a pending intent exists for another repository.

#### Files

| File | Change |
| --- | --- |
| `lib/features/common/palette_models.dart` | Typed entities, actions, query, ranking |
| `lib/features/common/command_palette.dart` | Two-step UI and bounded async sources |
| `lib/features/common/workspace_focus.dart` | Focus and location identities |
| `lib/features/common/workspace_navigation.dart` | Back/forward controller and page adapters |
| `lib/features/common/palette_intents.dart` | Typed payload support with legacy action compatibility |
| `lib/features/app_shell.dart` | Page activation/location routing |
| `lib/features/history/history_view.dart` | Commit/path/range adapter |
| `lib/features/branches/branches_view.dart` | Branch/base adapter |
| `lib/features/stash/stash_view.dart` | Stash OID adapter |
| `lib/features/forge/forge_selection.dart` | Forge object adapter |
| `lib/features/worktrees/worktrees_view.dart` | Worktree path adapter |
| `test/palette_models_test.dart` | Parser, ranking, caps, deterministic ties |
| `test/command_palette_test.dart` | Landed-only open, debounce, second step, guards |
| `test/workspace_navigation_test.dart` | Coalescing, restoration, stale entity, repo isolation |
| `test/palette_repo_switch_test.dart` | Host/repository supersession |

#### Exit criteria

* Opening the palette with an empty query produces no new remote command.
* Explicit searches are debounced, bounded, supersedable, and repository-safe.
* Every entity action routes through an existing guarded action or a separately
  tested new service action.
* Back/Forward restores semantic selection without mutating Git state.

### Phase 8 — Migrate History, Branches, Stashes, Forge, and Worktrees

**Intent:** complete the shared interaction grammar without flattening domain
differences.

Migrate one screen per work slice in the following order. Run its full targeted
suite and ordinary `flutter test` before starting the next screen.

#### 8A — Branches

1. Keep `BranchesView`'s existing `ResizableMasterDetail` content, Browse/Review
   modes, base resolution, filtering, bulk deletion, and provider budget.
2. Move its header facts into `RepositoryContextBar`, its navigator into the
   shared role, detail into canvas/inspector, and publish selected base/branch
   plus landed `BranchForge` to the focus/supplement cache.
3. Preserve `branchWorkspacePrefs.dart`; map its mode/base/group/sort settings
   into the shared workspace without changing the existing version-1 payload.
4. Required suites: every `branches_*`, `branch_*`, pinned-branch, and
   branch-forge test, including the 500-ref and command-budget baselines.

#### 8B — History

1. Keep graph/minimap/paging/search/filter/rebase/pop-out behavior unchanged.
2. Use the shared navigator/canvas/inspector roles and publish current revision,
   range, and selected path to workspace focus.
3. Store History-specific zoom/wrap/all-branches in existing `AppSettings`; do
   not duplicate them in workspace preferences.
4. Ensure the native History secondary window uses the same context bar subset
   and pane tokens but does not show actions unsupported by its proxy/session.
5. Required suites: all `history_*`, commit graph/patch, diff, and pop-out tests.

#### 8C — Stashes

1. Preserve OID-based stable selection and stale-index guards.
2. Add local list filtering over subject/branch/OID and use the shared
   navigator/canvas state widgets.
3. Publish selected stash OID into semantic navigation and keep Apply/Pop/Drop/
   Branch confirmations and undo behavior unchanged.
4. Required suites: `stash_*`, undo stash variants, and DnD stash tests.

#### 8D — Worktrees

1. Preserve horizontal nested-workspace tabs and avoid adding a second sidebar.
2. Put the worktree collection in navigator, selected worktree actions/detail
   in canvas/inspector, and publish landed current worktree context.
3. Preserve sandbox grant behavior, main-worktree protection, lock/move/prune/
   repair, post-create hooks, and page index 5.
4. Required suites: all `worktree_*`, `worktrees_view_test`, scoped access, and
   tabs-switcher tests.

#### 8E — Forge

1. Preserve the forge-neutral entry panel and GitHub/GitLab-specific detail,
   comments, releases, CI jobs, readiness, and mutation guards.
2. Map its collection and detail into shared roles; publish only landed current
   request/CI state to the supplement cache.
3. Keep forge-specific providers lazy. A user who never opens Forge and never
   previously loaded branch forge state pays no API request for workspace
   chrome.
4. Required suites: all forge/GitHub/GitLab unit/widget tests. Live-forge tests
   remain skipped unless separately requested.

#### Shared migration exit criteria

* No screen introduces a new local header, divider implementation, loading
  grammar, or empty-state grammar where a scaffold primitive applies.
* Each screen keeps its existing provider fetch budget while hidden.
* Cross-screen focus works in both directions and remains scoped to one tab.
* Secondary windows expose only executable proxy-supported actions.

### Phase 9 — Accessibility, visual regression, responsive, and performance gate

**Intent:** make quality measurable before enabling the workspace by default.

#### Steps

1. Define explicit focus order: context bar → navigator controls → navigator
   list → canvas controls/content → inspector → task dock → activity. Add direct
   pane-focus actions to the keymap, unbound by default unless a conflict-free
   macOS convention is confirmed.
2. Add VoiceOver semantics to context values, result counts, selected and
   reviewed rows, collapsed panes, primary action consequences, operation
   phases, progress, errors, and completion announcements. Use live-region
   announcements sparingly and coalesce repeated progress updates.
3. Enforce minimum target size from tokens, visible focus independent of row
   selection, text/icon active indicators, high-contrast status glyphs, and
   reduced-motion duration zero when system animation disabling is active.
4. Add checked-in golden fixtures under `test/goldens/workspace/` at 640×480,
   1080×720, and 1600×1000 for: clean, dirty, conflict, loading, partial error,
   multi-file review, composer expanded, active operation, each migrated
   screen, compact overlay, and high contrast. Use device pixel ratio 1.0 and
   deterministic fake data/time.
5. Add overflow tests at text scale 1.0, 1.3, and 1.6. Primary actions may move
   into disclosure but may not become unreachable.
6. Compare Phase 0 command counts and frame timings. Fail the gate if initial
   Repository paint adds a command, palette open adds a command, hidden screens
   fetch, a 2,000-file filter rebuild exceeds the recorded regression budget by
   more than 10%, or a 20,000-line diff regresses off-isolate behavior.
7. Repeat the Phase 0 user tasks on local and SSH repositories. Record results
   in the baseline artifact. The core release gate requires standard committing
   without a modal, immediate mutation acknowledgement, keyboard completion,
   no error-rate increase, and at least 25% median fewer interactions for the
   stage-review-commit task.

#### Files

| File | Change |
| --- | --- |
| `test/workspace_accessibility_test.dart` | Semantics, focus order, announcements |
| `test/workspace_responsive_test.dart` | Width/text-scale/overflow fixtures |
| `test/workspace_golden_test.dart` | Deterministic golden matrix |
| `test/goldens/workspace/` | Reviewed macOS golden images |
| `test/workspace_performance_baseline_test.dart` | Before/after comparison and budgets |
| `docs/0005-UX-BASELINE-task-centered-adaptive-repository-workspace.md` | Measured follow-up and comparison |

#### Core release gate

The adaptive workspace becomes the default only when all Phase 9 checks pass,
`flutter analyze` is clean, ordinary `flutter test` is green, and the
maintainer accepts the reviewed golden changes and measured task results.

### Phase 10 — Line/range staging and discard

**Intent:** add precise commit formation after the continuous commit/review flow
is stable.

#### Steps

1. Extend `unified_diff.dart` with a pure selection-patch builder. Selection is
   limited to changed `+`/`-` rows within one hunk for the first release;
   context and no-newline marker rows are not selectable, and cross-hunk drag
   is rejected explicitly.
2. Build a selected patch by preserving selected changes, omitting unselected
   additions, converting unselected removals to context, retaining required
   context, and recomputing hunk ranges. Return a typed unsupported reason for
   binary/mode-only/combined/malformed hunks instead of producing a guess.
3. Add `GitService.applySelectionPatch` and
   `GitService.discardSelectionPatch`. Use stdin, exclusive lane, no retries,
   literal header paths from the original Git patch, `--recount`, and the
   existing snapshot capture for destructive discard.
4. Let Git application be the final validity authority. A structurally valid
   preview may still fail because external state changed; surface that failure,
   refresh the file/status, retain the user's selection if identities still
   resolve, and offer whole-hunk fallback.
5. Add mouse drag, Shift-click, and keyboard range selection inside
   `HunkDiffView`. Show selected-line count and Stage/Unstage/Discard Selection;
   preserve current whole-hunk controls.
6. Disable line mutation in split, ignored-whitespace, binary, mode-only, and
   blame modes when patch correspondence is not exact; explain why.
7. Verify with real temporary Git repositories: mixed add/remove, adjacent
   edits, new/deleted files, rename, no trailing newline, Unicode, leading-dash,
   glob metacharacters, partially staged files, reverse unstage, discard undo,
   and external-edit race.

#### Files

| File | Change |
| --- | --- |
| `lib/core/git/unified_diff.dart` | Pure selection patch construction |
| `lib/core/git/git_service.dart` | Safe apply/discard endpoints |
| `lib/features/repository/hunk_diff_view.dart` | Line selection and actions |
| `lib/features/repository/repo_status_view.dart` | Mutation/refresh wiring |
| `test/unified_diff_selection_test.dart` | Exhaustive pure patch cases |
| `test/line_staging_integration_test.dart` | Real Git apply/unstage/discard/undo cases |
| `test/hunk_diff_view_test.dart` | Pointer, keyboard, disabled-reason UI |

#### Exit criteria

* A selection can never apply outside its displayed file/hunk.
* Failed application does not partially mutate the index/worktree.
* Destructive selected-line discard remains undoable through the existing
  journal.
* Whole-hunk behavior and tests remain unchanged.

### Phase 11 — Gated polish extensions

These work slices may proceed independently after the core release gate, in the
order shown. Each has a stop condition; failing it defers the feature without
blocking the workspace.

#### 11A — Image and binary review

1. Add `GitService.showBlobBase64(revision, path)` and bounded byte providers
   for HEAD/index/worktree sides. Reuse viewer error mapping and `ImagePreview`.
2. Detect supported image types with `file_type.dart`; render side-by-side,
   overlay, and difference-slider modes with dimensions and byte sizes.
3. Deleted/added images show the available side; decode/size failure degrades to
   the current binary notice and Open Externally.
4. Stop if byte budgets cannot safely bound both SSH transfer and decoded image
   memory without a transport change.

#### 11B — Commit assistance

1. Add recent subjects from already landed History data; an explicit “Load
   recent” may issue one bounded log read.
2. Add a service method to resolve `commit.template` and read it through the
   active executor. Never read a local template path for an SSH repository.
3. Add co-author trailer rows with validated name/email and deterministic
   trailer insertion at the end of the message.
4. Show cached branch/request/check policy as advisory preflight. Unknown data
   stays “Not checked,” never “Passing.” Do not block a commit on forge
   availability.

#### 11C — Toolbar, density, contrast, and preset polish

1. Add labeled/icon toolbar preference and customize only the secondary action
   slots; the contextual primary action remains present.
2. Apply compact/comfortable density tokens across every migrated screen.
3. Validate high contrast and reduced motion with the Phase 9 matrix.
4. Add the built-in Review, Commit, Investigate, and Minimal presets. A preset
   changes pane arrangement/focus only; it never changes Git filters or state.

#### 11D — Saved workspace sets and tab aliases

1. Define a versioned `SavedWorkspaceSet` containing display name, ordered
   repository references, optional tab aliases, active index, and non-sensitive
   layout preset names. Store saved connection/local IDs plus repo paths; never
   credentials or security-scoped bookmark bytes.
2. Open sets through `TabsController.openOrFocus`, honoring `maxTabs == 8`,
   dedupe, sandbox grants, and partial failures. Report each failed member and
   keep successfully opened tabs.
3. Persist aliases outside `RepoTab` runtime IDs and show them in `TabStrip`,
   palette, and window titles without changing repository identity.

#### 11E — Safe redo feasibility and gate

1. Prototype a `RedoRecord` generated only after successful undo. It must carry
   the exact repository post-undo precondition needed to prove replay is safe.
2. Test every existing `UndoOpKind`, including branch/ref deletion, stash
   operations, commit, snapshots, and file removals, against intervening HEAD,
   ref, index, worktree, stash-list, and external-process changes.
3. **Go condition:** every supported record has an atomic validate-then-replay
   script and stale/dirty classification equivalent to Undo. Unsupported kinds
   are explicitly excluded in the UI.
4. **No-go condition:** if replay requires reconstructing user intent from
   reflog/output, cannot atomically validate state, or can overwrite unrelated
   work, stop and write a separate MADR. Do not ship a best-effort Redo button.

**Gate outcome (2026-08-13): qualified go for tag refs only.** The prototype
found that `createTag` and `deleteTag` have a complete post-undo precondition
expressible as one tag ref's exact OID (or required absence). Redo uses
`git update-ref` with that expected old value, so validation and replay are one
compare-and-swap ref transaction. Intervening HEAD, branch, index, worktree,
stash-list, and unrelated-ref changes remain untouched; an external change to
the target tag makes the record stale without modifying it.

Every other current `UndoOpKind` is explicitly excluded from Redo:

| Undo kinds | Failed gate |
| --- | --- |
| `commit`, `amend`, `resetSoft`, `resetMixed`, `resetHard` | HEAD, index, and worktree are independently mutable; Git has no atomic precondition spanning them. `resetHard` also collapses reset, merge, cherry-pick, revert, and rebase intent into one undo shape. |
| `checkout`, `createBranch`, `deleteBranch` | Branch refs and per-worktree HEADs cannot be validated and changed in one compare-and-swap; an external checkout can race branch deletion. |
| `stashDrop`, `stashPop`, `stashClear`, `stashBranch` | The stash ref and positional reflog have no expected-list transaction; replay would depend on mutable list position or reconstructed intent. |
| `discardPaths`, `discardStagedPaths`, `removeFilePaths` | Snapshot replay writes the index/worktree; an external process can change a guarded path between shell validation and restore/removal. |

Unsupported kinds generate no `RedoRecord` and expose no Redo toast or
shortcut affordance. A fresh mutation clears the per-repository redo chain;
stale replay clears it without restoring an undo entry. Supported replay is
available through remappable `⇧⌘Z` in the main and secondary windows, and a
successful replay returns the original record to the undo journal.

Evidence is pinned by exhaustive enum classification, journal/controller/widget
tests, and real-Git integration tests in `test/redo_scripts_test.dart`. The
integration fixture changes HEAD, a branch ref, index, worktree, and stash list
after undo, then verifies tag redo leaves all of them byte-for-byte/state-for-
state intact; separate external-process tests move/create the target tag and
verify atomic stale refusal.

### Phase 12 — Separately decided specialist capabilities

Before implementing any item below, write or approve a separate MADR and paired
plan. The workspace may expose an extension point, but no placeholder action or
disabled marketing chrome is added in advance.

* Code Owners/ownership lens: decide forge-neutral ownership model, ref/version
  selection, nested rule semantics, caching, and unavailable states.
* Submodules: decide recursive status/update/init/deinit safety across SSH and
  local executors.
* Git LFS: decide tool health, lock workflow, pointer/binary presentation, and
  credential behavior.
* Stacked branches: decide stack domain model, reordering/restacking safety,
  forge relationships, force-push policy, and recovery.

## Verification

### Test-writing workflow

Testing is implementation work in every phase, not a final verification pass.
For each independently reviewable behavior change, use this sequence:

1. **Classify the contract.** Identify the observable rule being added or
   preserved and select the lowest sufficient test layer from the matrix below.
2. **Establish red.** For new deterministic behavior or a reproducible defect,
   write a focused failing test and run it to confirm that it fails for the
   intended assertion—not because the fixture cannot build. For a structural
   refactor with no behavior change, add missing characterization tests and
   confirm they pass before moving code.
3. **Implement green.** Make the smallest production change that satisfies the
   test while preserving existing contracts. Run the focused test after each
   meaningful state or interface change.
4. **Cover boundaries.** Add the applicable error, empty, stale,
   superseded/disposed, alternate input, identity, and width cases. A happy-path
   widget test alone is insufficient for async or mutating behavior.
5. **Refactor under green.** Consolidate production and test helpers only after
   the focused suite passes. Do not weaken assertions, replace behavior checks
   with `findsOneWidget`, or increase arbitrary timeouts to obtain green.
6. **Run adjacent suites.** Run tests for every touched shared seam—for example,
   an executor signature change requires scheduler, SSH/local/proxy/scoped,
   codec, telemetry, Output, and consuming-service tests.
7. **Run the phase gate.** Format, analyze, run all targeted tests, run the
   ordinary full suite, and check the diff before staging.

If a test cannot be written first because its initial artifact is a reviewed
golden, a platform-channel fixture, or an exploratory performance baseline,
write the deterministic harness and record the baseline before production code,
then add explicit behavioral thresholds or assertions in the same slice. State
the exception in the review description; “the UI is hard to test” is not an
exception.

### Minimum tests by change type

| Change type | Tests that must be written |
| --- | --- |
| Pure model/parser/ranker | Unit tests for normal, boundary, malformed, empty, deterministic ordering, and value equality/serialization cases |
| Riverpod notifier/provider | Provider-container tests for initial state, transition sequence, error, supersession, disposal, invalidation, and same-path/different-session isolation |
| Shared widget | Widget tests for mouse and keyboard action, focus, semantics, loading/empty/error, disabled reason, and compact/standard/wide layout |
| Screen migration | Characterization before refactor, shared-scaffold contract test, existing feature suite, and one end-to-end interaction through the migrated screen |
| Persisted preference | Encode/decode, unknown/corrupt fields, version migration, clamp, ad-hoc non-persistence, concurrent update serialization, and old-key rollback |
| Executor or scheduler | Queue/start/terminal ordering, error/timeout, retry, generation supersession, lane invariants, and all implementation forwarding/codec tests |
| Activity or Output | Monotonic lifecycle, cap/eviction, operation linkage, safe labels, interleaving, reconnect, undo/recovery link, and no raw secret data |
| Palette or navigation | Query parsing/ranking/caps, debounce/supersession, landed-only no-command case, valid actions, stale entity, Back/Forward, and repository isolation |
| Git mutation | Unit tests for command construction plus temporary-real-Git integration for success, refusal, stale/external state, refresh, undo, and literal-path edge cases |
| Accessibility | Semantics-tree assertions, focus traversal, keyboard-only task path, non-color state labels, progress/completion announcements, and text scaling |
| Visual change | Behavioral widget assertions plus reviewed macOS goldens at affected sizes/densities; goldens never stand alone |
| Performance-sensitive path | Deterministic large fixture, command-count assertion, bounded concurrency/fetch assertion, and comparison to the recorded frame/memory budget |

### Test construction rules

* Reuse the repository's fake/mock executors and provider overrides so unit and
  widget tests never contact SSH hosts, GitHub, or GitLab.
* Use temporary repositories and the installed `git` binary only for tests
  tagged `integration`; create all commits, refs, worktrees, stashes, and files
  inside the test-owned temporary directory and clean them through test teardown.
* Use fake clocks or injected time for debounce, activity elapsed time,
  retention, coalescing, and animation tests. Do not use a sleep to wait for UI
  state.
* Set surface size, device-pixel ratio, text scale, theme/density, fake data,
  and time explicitly in responsive and golden tests. Restore mutated test
  binding state in teardown.
* Use stable identifiers and ordered fixtures. Do not make assertions depend on
  `Set`/`Map` iteration order, generated temporary paths, locale-specific text,
  ambient Git configuration, credentials, or the user's global repositories.
* Test failure paths with typed exceptions/results at the same seam production
  code consumes. Do not synthesize human-readable output and then test a parser
  that production is forbidden to use.
* Every regression test name states the condition and expected behavior. Keep
  the test after the fix; it is part of the contract, not disposable proof.
* A golden update requires an accompanying review note naming the intentional
  visual difference. Blanket golden regeneration without inspection fails the
  phase gate.

### Per-work-slice commands

Run formatting only on touched Dart files, then:

```sh
dart format <touched-dart-files>
flutter analyze
flutter test <targeted-test-files>
```

At the end of every numbered phase:

```sh
flutter analyze
flutter test
git diff --check
```

Do not add `--run-skipped` and do not run tests tagged `live-forge` unless the
maintainer separately authorizes that exact execution.

### Required acceptance matrix

| Area | Required cases |
| --- | --- |
| Backend | Local, SSH, SSH reconnect/supersession, scoped work tree |
| Repository | Clean, dirty, partially staged, untracked, conflicted, unborn branch, detached HEAD, pending merge/rebase/cherry-pick/revert |
| Identity | Saved local, saved SSH, ad-hoc local/SSH, same path on two hosts, linked worktrees |
| Window | 640×480, 1080×720, 1600×1000, main tab switch, detached Repository, native History window |
| Input | Mouse, trackpad, keyboard-only, remapped shortcut, VoiceOver semantics |
| Async | Initial loading, stale value + refresh, partial failure, timeout, queued mutation, reconnect, provider supersession |
| Scale | 2,000 changed paths, 500 refs, 100 selected files, 20,000-line diff, capped output/activity |
| Safety | Confirmation, stale selection, external edit, undo, recovery, no fake cancel, no duplicate commit |

### Product acceptance criteria

The initiative is complete only when:

* Repository, History, Branches, Stashes, Forge, and Worktrees use the shared
  scaffold roles and context bar.
* Standard commit flow is inline and needs no modal.
* Multi-file selection renders reviewable content and visible bulk actions.
* Activity immediately acknowledges user mutations and accurately terminates.
* Palette and semantic navigation span every in-scope entity with bounded work.
* No workspace chrome causes additional initial/hidden-provider network calls.
* Keyboard-only and VoiceOver users can complete the six baseline tasks.
* No primary action overflows or becomes unreachable at supported fixtures.
* The measured stage-review-commit interaction count improves by at least 25%
  without an increased error rate.
* `flutter analyze`, ordinary `flutter test`, golden review, and
  `git diff --check` are clean.

## Rollout and Rollback

### Rollout

1. Deliver each phase as a reviewable vertical slice. Do not combine service
   lifecycle changes, Repository selection extraction, and all screen
   migrations in one change.
2. Keep old widgets callable while extracting shared bodies—for example,
   `CommitDialog` remains a wrapper until the inline composer passes its gate.
3. Migrate one screen at a time in Phase 8. The active screen can use the shared
   scaffold while unmigrated screens keep existing `ResizableMasterDetail` and
   `PaneId` behavior.
4. Preserve old SharedPreferences keys. New versioned records are additive and
   ignored by old code.
5. Enable the adaptive workspace as the default only at the Phase 9 core release
   gate. Remove obsolete wrappers and compatibility mapping in a later cleanup,
   not in the enabling change.

### Rollback

* A visual/scaffold phase rolls back by restoring the prior screen body while
  leaving additive preference records ignored. No Git data migration is
  involved.
* A pane-preference failure falls back to `PaneSpec.defaultWidth` or the old
  global `paneWidth_*` value. Corrupt JSON is treated as defaults and is not
  rewritten until a user gesture saves a valid record.
* An Activity Center failure can hide the presentation while typed lifecycle
  remains diagnostic; executor metadata defaults are optional, so callers
  without it retain old behavior.
* A palette/focus failure falls back to the current flat command palette and
  page selection. No stored Git state depends on navigation history.
* A composer failure falls back to the focused `CommitDialog` wrapper using the
  same controller. A draft is memory-only and may be copied before fallback.
* Line staging, image diff, workspace sets, and redo are independently
  removable. Whole-file/hunk staging, normal binary notice, ordinary tabs, and
  Undo remain the supported fallback paths.
* Never roll back by deleting user repositories, Git refs, undo journals,
  credentials, or all SharedPreferences. New UI preference keys may remain
  harmlessly unused.

## Risks and Controls

| Risk | Control |
| --- | --- |
| Cross-repository state leakage | Repository UI identity + session epoch keys; same-path/different-host tests |
| New chrome triggers remote traffic | Passive supplement cache; command-count assertions; landed-only palette default |
| Large selected set exhausts SSH lanes | Lazy active diff + two-item prefetch; aggregate cap and supersession |
| Refactor breaks mutation refresh | All paths retain `refreshAfterMutation`, shared family registry, edit stamps, and watcher suppression tests |
| Activity duplicates or lies about commands | Scheduler/executor lifecycle source, monotonic terminal state, no output parsing |
| Proxy metadata breaks secondary windows | Optional versioned codec fields and old-default round-trip tests |
| Persistent composer runs expensive hooks repeatedly | Explicit first-focus generation and staged-signature cache |
| Compact layout overwrites preferred widths | Display-only clamp and persist-on-user-gesture invariant |
| Golden tests become noisy | macOS-only deterministic fixtures, fixed DPR/data/time, reviewed intentional updates |
| Line patches apply unintended changes | Single-hunk scope, pure patch tests, stdin, no retries, Git validation, safe fallback |
| Redo overwrites intervening work | Atomic precondition gate or no-go; separate MADR if proof fails |

## Dependency and Sequencing Summary

```text
Phase 0 baseline
  → Phase 1 contracts / prefs / tokens
    → Phase 2 typed activity
      → Phase 3 scaffold / context
        → Phase 4 Repository navigator / panes
          → Phase 5 composer
            → Phase 6 multi-file review
              → Phase 7 palette / focus
                → Phase 8 screen-by-screen migration
                  → Phase 9 accessibility / goldens / measured core gate
                    → Phase 10 line staging
                    → Phase 11A–E independent gated polish
                      → Phase 12 separately decided specialist work
```

Phase 2 and Phase 1 implementation can be developed in parallel only after
their shared repository/session identity and provider-lifetime interfaces are
reviewed. All visible Repository work depends on Phase 1; operation-bearing
controls must not ship without Phase 2 acknowledgement. Screen migrations must
remain sequential to keep regressions attributable and rollback small.

## Review Checklist

Before approving this plan, confirm:

* [x] MADR 0005's task-centered adaptive workspace decision is accepted.
* [x] The clarified no-eager-fetch context/palette policy matches product
      expectations.
* [x] Repository-specific layout persistence, with old global widths as a
      migration seed, is the desired behavior.
* [x] The inline composer should generate hook previews on first user focus,
      not automatically when staging occurs.
* [x] The Activity Center should list user-meaningful operations only, with
      background work surfaced only when actionable.
* [x] Built-in presets are sufficient for the first release.
* [x] Phase 10 and Phase 11 remain post-core gates rather than blockers.
* [x] Code Owners, submodules, LFS, and stacked branches remain separate
      decisions.
