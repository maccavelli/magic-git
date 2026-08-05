# Implementation plan: base-relative branches workspace

- Status: **implementation in progress** (codebase re-grounded 2026-08-04;
  Phases 0 and 1 complete. Identity-keyed preferences, the extracted pure
  Browse model, and the 500-ref baseline are landed in the worktree. Review now
  has NUL-framed attributed refs with warnings, forge-aware deterministic base
  resolution with visible provenance and explicit unavailable/unborn states,
  grouped full-ref base choices, batched base-relative summaries, clickable
  Merged/Stale facets, Activity/Name sorting, and no legacy HEAD-relative bulk
  cleanup action or universal safety copy. Checkpoint B's HEAD-different-base,
  passive-cache Browse, and zero-comparison-command tests pass. Phase 2 is next;
  the trust gate remains Phases 1–3 before bulk.)
- Date: 2026-08-04
- MADR: `docs/0003-MADR-base-relative-branches-workspace.md` (Option C)
- Owner: implementation agent + maintainer review
- Delivery model: incremental, analyzer-clean phases; maintainer creates commits
- Sequencing rules in force:
  1. This plan is the executable authority for delivery order.
  2. Work starts at **Phase 0** (foundation only).
  3. **No Phase 4 bulk delete** until Checkpoint C (trust after Phase 3).
  4. Unit tests land **in parallel** with each seam (§5.0).
- SDK: Dart `^3.12.2` / Flutter 3.44.x — match existing strict analyzer
  (`strict-casts` / `strict-inference` / `strict-raw-types`,
  `prefer_final_locals`, `prefer_const_constructors`, `unawaited_futures`,
  `avoid_dynamic_calls`)
- Authority: MADR 0003 owns the decision and normative semantics. This plan
  owns executable contracts, phases, and file-level delivery. A discovered
  conflict requires an explicit MADR amendment or a plan correction; this plan
  does not silently supersede its MADR.

This plan turns MADR 0003 into an executable sequence grounded in the current
tree. It preserves the existing Branches navigator and its safety behavior,
introduces an explicit comparison base, and adds Review functionality without
making normal Browse pay for comparison or forge work.

**Socratic verdict (2026-08-04):** Accept Option C. No architectural reversal.
Amendments in §0.5 close single-owner, identity, session-generation, batch,
and History-intent contracts found under adversarial review.

**Unit tests are written in parallel with implementation in every phase**,
not as a follow-on after features land. For each new pure function, parser,
provider key, service method, or view-model behavior: add or extend the
matching unit test **in the same work slice** as the production code (same
agent turn / same local edit cycle). Each phase’s **Required tests** table is
the minimum; the phase is incomplete until those tests exist, pass, and
`flutter analyze` + ordinary `flutter test` are green. Do not run
`live-forge` tests unless the maintainer explicitly asks.

---

## 0. MADR assessment and implementation verdict

### Verdict

**Accept Option C with the implementation refinements and corrections below.**
Architecture fits the executor/service/provider seams and reuses substantial
existing functionality. **Trust milestone = Phases 1–3** (base semantics +
comparison inspector + merge preview). Bulk cleanup and "safe" recommendation
copy must not ship before that gate: Phase 1 removes the existing HEAD-relative
dashboard bulk action, and Phase 4 reintroduces reviewed base-safe bulk delete.
Phase 0 is prerequisite scaffolding only.

### 0.1 Claims confirmed against the codebase (2026-08-04 re-ground)

| MADR / plan claim | Codebase fact | Planning consequence |
| --- | --- | --- |
| Strong master/detail base | `lib/features/branches/` has **only** `branches_view.dart` (2,655 lines), `create_tag_sheet.dart`, `pinned_branches.dart`. `ResizableMasterDetail(paneId: PaneId.branchesList)`; pane `380/300/680`. | Evolve in place; extract files as behavior lands; no new top-level tab/graph. |
| No Browse/Review **mode** yet | UI is single navigator + empty-state dashboard. Private `_ReviewSummary` is **dashboard counts only** (pinned/stale/mergedDeletable), not a mode switch. Comment likens it to Tower Review but there is no mode control. | Phase 1 **introduces** Browse/Review segmented control; rename extracted dashboard model so it does not collide with mode language. |
| "Merged" is HEAD-relative | `mergedBranchNames` → `git branch --merged --format=%(refname:short)` (no commit-ish). Provider watches `refsProvider`, **catch → `{}`**. | Keep for optional "merged into current" badge if retained; Review uses separate base-relative summary. Never treat empty as "none merged" on failure. |
| Dangerous cleanup copy | Dashboard: *safe to clean up*; detail merged: *safe to delete*; ahead callout: *ready to merge into the current branch*; upstream-gone callout: *Safe to delete once…*. `_deleteMergedBranches` **swallows** per-branch exceptions. | Phase 1 strips universal "safe"/HEAD-as-integration wording before any new bulk path. |
| Upstream ≠ base | `GitRef.ahead`/`behind`/`upstream`/`upstreamGone` from `%(upstream:track)`. | Relabel To push / To pull; never reuse for base comparison. |
| Recent commits not unique | `branchCommitsProvider` → `log(revision:, maxCount: 15)`; **catch → empty list**; re-fetches on `refsProvider`. `log` already accepts ranges after `--end-of-options`. | Unique commits via `revision: '$baseOid..$branchOid'`. New providers must not swallow truth-bearing errors into empty. |
| Diff reusable | `diffRange` + `DiffView`/`SplitDiffView` + `_commitRangeDiffLru` / `commitRangeDiffProvider` + `clearHashKeyedRepoCaches` (9 LRUs today). | Three-dot OID-keyed branch diff; register any new LRU. |
| Forge create chain (real) | Seed: `({repoPath, branch})?` only. Drop: `_createRequestFromBranch` → `forgeCreateSeedProvider.set` → `DropZoneId.forge` (index **4**). Panels: seed path must match panel `repoPath`; `_select(ForgeCreatingChangeRequest(seedSource: seed.branch))`. Forms: `CreatePrForm.initialHead` / `CreateMrForm.initialSource` only; **`_base`/`_target` hardcoded `'main'`** — no `initialBase`/`initialTarget`. | Coordinator + extend seed **and** `ForgeCreatingChangeRequest` **and** form initial base fields. `forgeMountRepoPath` = `ConnectionState.repoPath`. |
| Publish primitives | `push({remote, branch, setUpstream, force: PushForce, followTags})` on **`ExecLane.sync`**. `PushForce { none, withLease, force }`. Top-level `defaultRemote` = `origin` else `remotes.first` (throws if empty list). | Publish UI only; default `PushForce.none` + `setUpstream: true`; guard empty remotes. |
| Layout / identity | `RepoLayout` + `detectRepoLayout` exist. **No `repoLayoutProvider`.** Current layout reads require `rev-parse --path-format=absolute`, which is not available on every Git 2.24-compatible host. `ConnectionController._attempt` is private; `ConnectionState` exposes no generation. Pins: `pinnedBranches_<repoPath>`. Collapse: global `branches.pinned/local/remote/tags`. | Add a 2.24-compatible canonical-layout fallback, publish read-only `ConnectionState.sessionEpoch`, then add identity + versioned prefs (§0.5.B). If canonical layout still cannot resolve, use session-only prefs. |
| Shared refs invalidation | `repoMutationFamilies` whole-family for refs/log/remotes/stashes/worktrees; `statusProvider(repoPath)` per-worktree; `refreshAfterMutation`. | Register review families; watch `refsProvider` or mutation list. |
| Git floor / version | Catalog min Git **2.24**. `binaryEnvironmentProvider` exposes found binaries and parsed versions but no loading/error state for the background version probe. **No merge-tree usage anywhere.** | Capability provider uses the landed version when present and performs one on-demand Git-only version probe when absent; `AsyncValue` distinguishes loading/failure. Gate merge-tree at ≥2.38 and never parse legacy output. |
| Policy DTOs | `repoMergePolicyProvider` already fetches via `GhService`/`GlabService.repoMergePolicy`. DTOs lack `defaultBranch`; API JSON already has `default_branch`. **No protected-branches listing methods.** | Add `defaultBranch` to DTOs + fromJson; new protected-rules methods + tri-state provider. |
| Forge branch knowledge | `branchForgeProvider` intentionally catches all errors and returns `{}` for resilient Browse badges. That makes failure indistinguishable from known no-request/no-CI. | Keep the compatibility facade for Browse; add typed known/unavailable knowledge over the same underlying cached providers for Review facets/counts. |
| New Branch today | `_createBranchPrompt`: `promptText` + `git.createBranch` at **HEAD only**. `branchFrom(name, startPoint)` exists unused by this prompt. `refNameProblem` in `lib/features/common/ref_name_validation.dart`. | New sheet: start-at + `branchFrom` / worktree sheet params. |
| Worktree sheet | `AddWorktreeSheet(initialCommitish, initialBranchName)` already wired for branch "checkout in new worktree". | Reuse; no ctor changes. |
| Worktree embed | IndexedStack: Status / History / Branches / Stash only (**no Forge**). `BranchesView(repoPath: worktreePath)`. Main shell Forge uses `connection.repoPath`. | Main-shell navigation + seed path discipline. |
| Detail actions (noncurrent local, not elsewhere) | Flat wrap: Open request (if forge), Check out, New worktree, Merge into current, Set upstream, Rename, Pin/Unpin, Delete — **~7–8 capsules**, Delete exposed. **No Publish, no Create PR/MR, no Open CI** (only `requestUrl` open; `ciUrl` collected but unused in detail). | Primary/More hierarchy; visible Publish/Create/Open CI. |
| Selection | Single `_selectedRef` (`String?` full name). **No multi-select.** | Phase 4 adds ordered multi-select. |
| Undo delete | `deleteBranch` → `_runCaptured` + `UndoOpKind.deleteBranch` + pre-delete OID via `rev-parse`. Undo does **not** restore upstream config. | Base-safe delete journals same kind with **preflight** OID. |
| Palette IDs today | `branches.newBranch`, `branches.createTag`, `branches.merge`, `branches.delete` in `command_palette.dart`; handlers in `branches_view`. | Extend IDs for Publish/Create/Compare; keep existing IDs stable. |
| Shell navigation API | `pageIndexProvider.notifier.select(i)`; `visitedPagesProvider.notifier.visit(i)`. Not a method on the provider state itself. | Use notifiers; Drop keeps `DropContext.selectPage`. |
| History seed | `HistoryView(repoPath, isActive, onPopOut?)` has no revision intent; `LogQuery` has no revision field and `LogSearchNotifier._walk` therefore uses the default `HEAD` unless `--all`. | Add intent plus a visible/clearable History revision scope, extend `LogQuery`, and pass `revision` to `GitService.log`. One-shot consumption alone would not change the walk. |
| Missing Git seams | No `remoteHead` / `symbolic-ref` remote HEAD helper for base; no review summary batch; no comparison metadata service; no base-safe delete; no `merge-tree`. | All new under `GitService` + pure parsers module. |
| Accessibility debt | `Tappable` = MouseRegion+GestureDetector. Context menu `Color(0xFF2C2C2E)`. HEAD row green bg **masks** selection tint. | Semantic row; selection owns background; menu parity. |
| Tests | **15** branch-focused files + `refs_parse_test` + undo suite; `branch_ops_integration_test` `@Tags(['integration'])`. | Characterization first; unit tests parallel per phase. |
| Exec lanes | `ExecLane.read` / `sync` / `exclusive`. Mutations via `_runCaptured` exclusive; push/fetch sync. | Summary/preview on read; base-safe delete exclusive; publish sync. |

### 0.2 Corrections / inaccuracies fixed by this audit

1. **Trust milestone is Phases 1–3, not 1–2.** Merge preview is part of the
   trust gate (aligned with MADR).

2. **`GitService.log` already accepts a range as `revision`** after
   `--end-of-options`. Prefer `log(..., revision: '$baseOid..$branchOid')` over
   a new multi-revision API. Optional thin `logRange` name only if call sites
   need it.

3. **`AddWorktreeSheet` already has `initialCommitish` + `initialBranchName`.**
   Wire them; do not invent params.

4. **Worktree-embedded Branches has no Forge tab.** Navigate main shell:
   `pageIndexProvider.notifier.select(4)` + `visitedPagesProvider.notifier.visit(4)`.

5. **Action surface is flat ~7–8 capsules** including Delete; Publish / Create
   PR/MR / Open CI are missing from detail (CI URL is collected but unused).

6. **Stale uses `creatorDate`** (`%(creatordate:unix)`), not author date.
   Attribution/Mine need author atoms, but author name/email are
   commit-controlled too: inserting them into the current unit-separator shape
   can shift columns. Migrate this subformat/parser to fixed `%00` NUL fields
   first. Activity sorting remains on `creatorDate`.

7. **Error swallowing is intentional for list badges, wrong for Review truth.**
   Do not copy empty-on-error into base/summary/comparison/merge-preview
   providers.

8. **Drop uses `DropContext.selectPage`; shell uses notifier `select`/`visit`.**
   Coordinator accepts a navigation callback so DnD and Branches share one
   implementation without Branches depending on `DropContext`.

9. **`push` takes `PushForce`, not `bool force`.** Publish uses
   `PushForce.none` + `setUpstream: true` on `ExecLane.sync`.

10. **`_ReviewSummary` ≠ Review mode.** Extract dashboard stats under a
    non-mode name (e.g. `BranchDashboardStats`); Browse/Review is a new UI
    mode introduced in Phase 1.

11. **Create-base seeding is a multi-hop change:**
    `forgeCreateSeedProvider` → panels → `ForgeCreatingChangeRequest` →
    `CreatePrForm`/`CreateMrForm`. Extending only the seed record is
    insufficient without panel + form `initialBase`/`initialTarget`.

12. **`defaultRemote` on empty list throws** (`remotes.first`). Publish and
    base remote-HEAD resolution must require non-empty remotes explicitly.

13. **No multi-select, no remote-HEAD helper, no merge-tree, no protected-branch
    API, no History revision intent** in tree today — all are net-new.

14. **Detached bases have no ref name.** `BranchBase.refName` must be nullable;
    its OID and source remain mandatory. Base resolution must watch the existing
    `statusProvider` for `GitStatus.headOid` / unborn state, and reuse
    `GitService.revParse('$ref^{commit}')` for stored/tag candidates.

15. **Partial summary failure needs a type.** A
    `Future<List<BranchReviewSummary>>` cannot represent one failed row without
    inventing zero counts. The batch result must contain successes and failures
    keyed back to captured full ref names.

16. **The proposed `--merged` hybrid is invalid for this model.** It identifies
    merged tips but does not calculate `behindBase`; the UI/domain require both
    counts. Use framed `rev-list --left-right --count` for every captured tip
    and tune only batch size or bounded host concurrency from measurements.

17. **Forge and History seeds need mount-path discipline.** Both main panels
    are mounted at `ConnectionState.repoPath`; a worktree-embedded Branches
    view must not seed its `worktreePath`. A Git remote-tracking base must also
    be normalized to a forge branch name (`main`, not `origin/main`).

### 0.3 Required refinements to the MADR sketch (still in force)

1. **Split selected comparison data by cost.** Separate immutable providers for
   metadata, unique commits, patch, and merge preview. Changes tab is lazy.

2. **No conflict state in the initial all-branch summary.** Batched
   divergence only (`rev-list --left-right --count` — §0.5.E / §3.3).
   `merge-tree` on-demand;
   Conflicts facet = visible cancellable concurrency-one scan; unknown ≠ clean.

3. **Base-relative deletion = new atomic mutation.** Not plain `git branch -d`
   against Review base. Script: tip == expected OID; refuse if checked out in
   any worktree; `merge-base --is-ancestor expectedBranchOid baseOid`;
   `update-ref -d refs/heads/<name> expectedBranchOid`; journal
   `UndoOpKind.deleteBranch`.

4. **Repository identity ephemeral policy.** Stable only for
   `SavedConnection.id` / `SavedLocalRepo.id` + `RepoLayout.gitCommonDir`.
   Ad-hoc sessions: in-memory only; never collide two hosts on the same path.

5. **Forge default branch additive.** Git-first resolution offline; UI shows
   resolving/provenance; never silently call fallback "default."

6. **Protection knowledge tri-state.** Known / unavailable / unsupported.
   Unknown must not read as safe.

7. **No derived field assignment in `build`.** Extract immutable view model;
   stop writing `_locals`, `_navigable`, `_forge`, `_merged`, `_pinned` during
   build.

### 0.4 Completeness gaps this plan now closes

| Gap | Closure |
| --- | --- |
| Unit tests optional-looking | §5.0 parallel rule + §6 + per-phase **Required tests** blocks with exit gates; tests land with each seam, not after the phase. |
| Batched remote script safety | OID-only args; `ShellEscaper` if any name appears; fake-executor argv tests. |
| `parseRefs` field-shift risk | `%00` NUL-field migration plus fixed-count fixtures, including the former separator inside author/subject data. |
| Worktree Create PR/MR navigation | Coordinator + dual-context widget tests. |
| Preference race after user interaction | Migration tests: late prefs load must not clobber user mode/base. |
| Performance without measurement | Phase 7 command-count unit tests + 500-ref integration fixture. |
| Dart/analyzer idioms | Records for seeds; sealed `ProtectionKnowledge`; const models with defaults; exhaustive switches; final locals; no ad-hoc `dynamic` JSON. |

### 0.5 Socratic dialectic amendments (must implement)

These are **normative plan contracts**, not optional polish. They came from
adversarial review against live code owners (`app_shell`, `ForgePanel` seed
equality, `ConnectionState.connectionId`, `worktrees_view` embed paths,
`_invalidateRepoState` pure-`repoPath` traps).

#### A. Forge create seed — single owner for `repoPath`

`ForgePanel` only applies `forgeCreateSeedProvider` when
`seed.repoPath == panel.repoPath`, and `app_shell` mounts Forge with
`ConnectionState.repoPath` (`DropZoneId.forge.pageIndex == 4`).

Worktree-embedded `BranchesView` is constructed with **`worktreePath`**, which
can differ from the main connection repo path. The shared coordinator **must**:

1. Accept explicit `forgeMountRepoPath` (always `connectionProvider.repoPath`
   / the path ForgePanel mounts) separate from the Branches widget's
   `repoPath` (which may be a linked worktree).
2. Seed `(repoPath: forgeMountRepoPath, branch: shortName, baseRef: …)`.
   `baseRef` is a forge branch name: strip `refs/heads/`, or strip
   `refs/remotes/<forge remote>/`. Omit it for tags, detached bases, and a
   remote-tracking base owned by another remote; never seed `origin/main`.
3. Never seed the worktree embed path when it differs from the forge mount
   path (silent no-op: panel ignores mismatched seed).
4. Navigate main shell: `pageIndexProvider` → 4 and
   `visitedPagesProvider.visit(4)`.

#### B. Ad-hoc repository UI identity

- **Durable** prefs only when `ConnectionState.connectionId != null`:
  - SSH: `ssh:<SavedConnection.id>`
  - Local saved: `local:<SavedLocalRepo.id>`
  - Plus `NUL + canonical gitCommonDir`, then UTF-8 base64url key.
- **Ad-hoc** (`connectionId == null`): **in-memory only**. Key =
  `adhoc:<backend>:<sessionEpoch> + NUL + gitCommonDir` where `sessionEpoch`
  is a new read-only field on `ConnectionState`, set from the controller's
  connection attempt/generation. Preference code cannot read private
  `ConnectionController._attempt`. Never write SharedPreferences.
- Wipe ad-hoc workspace prefs on disconnect / `_invalidateRepoState`.
- Two hosts or two sessions reusing the same filesystem path must never share
  durable or in-memory prefs.
- Worktree views share only within the same saved connection/session scope.
  Independently saved local entries intentionally retain separate durable
  records even when Git reports the same common dir.
- Canonical common-dir discovery must have a Git 2.24-compatible fallback.
  If it still fails, return a session-only identity; never persist by raw
  `repoPath`.

#### C. Connection-generation / pure-`repoPath` safety (black swan)

New review families and byte LRUs are pure-`repoPath`/OID keyed today like
other caches. After SSH reconnect, the same path string can refer to a new
session. **Hard requirement:**

1. Register every new family in `repoScopedFetchFamilies`.
2. Register only mutable-ref-derived base/summary families with
   `repoMutationFamilies`, or make them watch `refsProvider`. Immutable
   OID-keyed comparison/diff/merge-preview providers do **not** refresh after
   every mutation; the selected ref rekeys them when its OID moves.
3. Register every new `KeepAliveLru` in `clearHashKeyedRepoCaches`.
4. Structural unit test: every `KeepAliveLru` field used by providers appears
   in `clearHashKeyedRepoCaches` (extend the known stuck-loading failure
   mode into an assertion).
5. In-flight summary/merge-tree results must drop on generation change
   (ignore superseded provider results; full family dispose on
   `_invalidateRepoState` is sufficient if registration is complete).

#### D. Browse must not initiate forge for base resolution

Key base resolution by `(repoPath, allowForgeFetch)`. Ordinary Browse passes
`false` and reads only a passive `repoMergePolicyCacheProvider` populated by a
previous policy fetch; it must not read/watch `repoMergePolicyProvider`, because
either operation instantiates its fetch. Review and explicit base refresh pass
`true`, watch `repoMergePolicyProvider`, and publish successful data into the
passive cache. This makes the no-fetch promise testable rather than relying on
an undefined Riverpod "peek."

#### E. Review summary batch contracts

- `ExecLane.read`; full hex OIDs only in the script body. Emit one NUL-terminated
  record per input with `ordinal`, OID, command exit status, behind, and ahead
  separated by a fixed control separator. Ref names never enter the script;
  join the ordinal/OID back to the captured input and reject mismatches.
- Start with `batchSize = 100` and the existing 60-second read timeout; declare
  both named constants beside the service method and tune them only with Phase
  7 evidence.
- Generation / dispose: ignore superseded results; do not auto-retry loops.
- Run batches sequentially inside one provider invocation;
  optional host worker pool max 2 only after measurement.
- Do not use `for-each-ref --merged` as a shortcut: it cannot produce
  `behindBase` for merged tips. Every captured tip gets the same `rev-list
  --left-right --count` semantic contract.

#### F. History navigation intent (named seam)

There is no existing History seed provider. Add:

```dart
// Parallel to forgeCreateSeedProvider
historyNavigationIntentProvider // ({String repoPath, String revision})?
```

Branches sets `repoPath` to the main History mount
(`ConnectionState.repoPath`, never an embedded `worktreePath`), then selects
History (`DropZoneId.history.pageIndex == 1`) and marks it visited. HistoryView
matches its mount path, consumes/clears the intent once, retains the revision in
widget state as a visible clearable `History of <ref>` scope, adds `revision` to
`LogQuery`, and passes it through `LogSearchNotifier._walk` to
`GitService.log`. Clearing the scope returns to HEAD/`--all`. Do **not** clone
History UI into Branches.

#### G. Domain model contract

- Plan §2.2 implements the MADR's normative provider split: **no conflict state
  on the all-branch summary**; merge preview is a separate on-demand provider.
- The MADR and this plan both prohibit embedding `mergePreview` on every
  summary row; do not introduce an N+1 eager preview.

#### H. MADR bulk-delete text

MADR and plan both require an OID-pinned `update-ref -d` plus ancestor check;
ordinary HEAD-relative `git branch -d` is not the Review bulk mutation.

#### I. Checkpoint D default

Unknown forge protection: **permit explicitly checked deletion with a
warning** (recommended default). Disabling bulk until forge resolves is a
maintainer override only. Unknown must never render as protected-or-safe.

#### J. Phase 0 discipline

Characterization tests land **before** extraction. Do not weaken existing
branch widget tests to make extractions pass. No intended UX change until
Phase 1.

### 0.6 Current code inventory (exists vs invent)

**Reuse as-is (wire / call):**

| Seam | Location |
| --- | --- |
| Master-detail + pane widths | `ResizableMasterDetail`, `PaneId.branchesList` |
| Refs snapshot + `GitRef` | `refsProvider`, `_refsFormat` / `parseRefs`; migrate its ref section to NUL fields before adding author atoms |
| HEAD-merged set (badge only) | `mergedBranchNames` / `mergedBranchesProvider` |
| Log / range log | `GitService.log` |
| Quiet revision resolution | `GitService.revParse`; use `<fullRef>^{commit}` for stored/tag bases |
| Diff range + viewers | `diffRange`, `DiffView`, `SplitDiffView`, `commitRangeDiffProvider` |
| Branch create at HEAD / from start | `createBranch`, `branchFrom` |
| Delete + undo | `deleteBranch`, `UndoOpKind.deleteBranch` |
| Push / publish primitive | `push` + `PushForce` + `ExecLane.sync` |
| Worktree sheet seeds | `AddWorktreeSheet.initialCommitish` / `initialBranchName` |
| Ref name validation | `refNameProblem` (`ref_name_validation.dart`) |
| Forge fusion | `BranchForge` (`requestUrl`, `ciUrl`, draft, CI status) |
| Merge policy fetch | `repoMergePolicyProvider` + Gh/Gl `repoMergePolicy` |
| Mutation refresh | `refreshAfterMutation` / `repoMutationFamilies` |
| Fetch toolbar | existing `_fetchPrune` / `git.fetch` |
| Merge modes | `MergeMode` + existing merge UI (keep; re-home under More) |
| Palette stub IDs | `branches.newBranch` / `createTag` / `merge` / `delete` |
| Shell page indices | 0 status, 1 history, 2 branches, 3 stashes, 4 forge, 5 worktrees |

**Invent (not in tree today):**

| Seam | Notes |
| --- | --- |
| Browse/Review mode control | New UI state; not `_ReviewSummary` |
| `remoteHead` / base resolution providers | `symbolic-ref --quiet refs/remotes/<r>/HEAD` (full-ref output) |
| Batched base-relative summary | framed host-side `rev-list --left-right --count` batches |
| Comparison metadata + branch diff LRU | three-dot; register in `clearHashKeyedRepoCaches` |
| Merge-tree preview + capability | Git ≥2.38; tri-state version |
| Base-safe OID-pinned delete | `update-ref -d` + ancestor + worktree guard |
| Multi-select + bulk preflight sheet | replace swallow-exceptions bulk |
| New Branch sheet (start-at) | replaces HEAD-only `promptText` |
| Publish / Create PR / Open CI actions | create chain includes form base seed |
| History revision handoff | intent + `LogQuery.revision` + visible/clearable History scope |
| Layout/identity foundation | Git-2.24-compatible canonical layout fallback, `ConnectionState.sessionEpoch`, `repoLayoutProvider`, durable/session prefs |
| Passive forge policy cache | Browse reads without instantiating a forge request |
| Author atoms on `GitRef` | field-shift-safe `parseRefs` |
| Protected-branch forge listing | new Gh/Gl API walks; tri-state knowledge |
| Semantic `BranchRow` + menu a11y | shared primitives |
| Coordinator + seed/base form fields | multi-hop forge create |

### Trust milestone

**Base-relative and trustworthy** only after Phases **1–3**:

- visible base with deterministic provenance and fallback;
- base-relative merged/ahead/behind independent of current `HEAD`;
- branch-unique commits and three-dot changes keyed by immutable OIDs;
- working-tree-free conflict preview with honest version/error fallback;
- no comparison N+1 in ordinary Browse;
- all Phase 0–3 required tests green.

---

## 1. Scope, goals, and non-goals

### Goals

1. Keep Browse fast and familiar for checkout, remotes, tags, and worktrees.
2. Make every comparison name its base and method.
3. Distinguish checked-out, upstream-sync, base-comparison, and forge-readiness
   facts in both models and copy.
4. Provide Overview, Changes, and unique Commits without a local clone.
5. Add useful review facets, sorting, multi-selection, and review-safe cleanup.
6. Surface Publish, Create PR/MR, Open request, and Open CI without requiring
   drag/drop or a context menu.
7. Share organization preferences across linked worktrees without sharing
   per-worktree selection or scroll position.
8. Reach full keyboard, VoiceOver, light/dark, contrast, and narrow-window
   parity.
9. Keep all normal tests and analysis clean; never run `live-forge` tests
   unless the maintainer explicitly requests them. **Write unit tests in
   parallel with implementation** every phase (see §5.0, §6, and per-phase
   Required tests) — not as a trailing test-only phase or follow-on.
10. Match repo Dart idioms: `final` locals, const constructors with defaults for
    new model fields, sealed types for knowledge tri-states, records for seeds
    where the codebase already uses them, exhaustive switches, no untyped
    JSON maps outside existing `forge_json` helpers.

### Non-goals

- A second commit graph or replacement for History.
- Inline PR/MR review threads, comments, or suggestions.
- Making a forge account or network connection mandatory.
- Automatically deleting or hiding a branch without explicit review.
- Lowering the repository-wide Git minimum from 2.24 or parsing legacy
  human-oriented `merge-tree` output.
- Duplicating GitHub/GitLab create or merge forms inside Branches.
- Changing the executor seam or adding a direct forge SDK.
- Sharing active selection, scroll offset, or in-flight UI state between
  linked worktrees.

---

## 2. Target architecture and ownership

### 2.1 Proposed file map

| File | Responsibility |
| --- | --- |
| `lib/core/git/branch_comparison.dart` | Pure domain types, enums, output parsers, ref/OID validation, comparison fingerprint helpers. |
| `lib/core/git/git_service.dart` | Git-2.24-compatible canonical layout fallback; remote HEAD; framed review batches; diff metadata; merge preview; OID-pinned base-safe deletion. Reuse existing `revParse` and `log`. |
| `lib/core/storage/repository_ui_identity.dart` | Stable storage identity value object and collision-safe preference-key encoding. No Riverpod/UI dependency. |
| `lib/core/forge/merge_plan.dart` | Add nullable `defaultBranch` to existing `GhRepoMergePolicy` / `GlRepoMergePolicy` (const defaults). |
| `lib/core/forge/branch_forge_status.dart` | Preserve empty-on-error Browse facade; add typed Review knowledge that distinguishes known empty from unavailable without duplicating network fetches. |
| `lib/core/github/gh_service.dart` | Parse `default_branch` in existing `repoMergePolicy`; add bounded protected-branch page walk via `api` (no `--paginate`). |
| `lib/core/gitlab/glab_service.dart` | Parse `default_branch` in existing `repoMergePolicy`; add protected-branch rules via paginated API. |
| `lib/core/providers/app_providers.dart` | Expose read-only `ConnectionState.sessionEpoch`; add layout/identity, passive forge-policy cache, base, summary, comparison, diff, merge-preview, and protection families; register in reset/mutation/LRU registries. |
| `lib/features/forge/forge_selection.dart` | Extend `ForgeCreatingChangeRequest` with optional `seedBase` (parallel to `seedSource`). |
| `lib/features/github/create_pr_form.dart` / `create_mr_form.dart` | Add optional `initialBase` / `initialTarget`; seed from panel; keep `'main'` only as no-seed fallback. |
| `lib/features/common/command_palette.dart` | Register new action IDs; do not renumber existing `branches.*` entries. |
| `lib/features/branches/branch_workspace_prefs.dart` | Versioned SharedPreferences record, migration from path-keyed pins/global Branch collapse, and session-only fallback. |
| `lib/features/branches/branch_view_model.dart` | Pure Browse/Review row shaping, search tokens, filters, natural sort, attention ranking, dashboard counts, primary-action choice. |
| `lib/features/branches/branch_navigator.dart` | Toolbar, sections, virtualized rows, selection mechanics, and Review table/list. |
| `lib/features/branches/branch_detail.dart` | Stable header, Overview/Changes/Commits tabs, explicit loading/error/empty/truncated states, primary/More actions. |
| `lib/features/branches/branch_row.dart` | Focusable semantic branch/ref row and status-region layout. |
| `lib/features/branches/new_branch_sheet.dart` | Name, Start at, checkout, and new-worktree creation choices. |
| `lib/features/branches/bulk_branch_sheet.dart` | Preflight review and per-branch deleted/skipped/failed result report. |
| `lib/features/branches/branches_view.dart` | Thin coordinator: owns ephemeral selection/scroll/mode interaction, composes navigator/detail, invokes mutations. Target < 900 lines after extraction. |
| `lib/features/forge/forge_create_coordinator.dart` | Shared resolve-seed-navigate orchestration for drag/drop and visible actions; requires `forgeMountRepoPath` (§0.5.A). |
| `lib/features/forge/forge_prefs.dart` | Extend create seed to include optional base ref. |
| `lib/features/history/history_navigation.dart` + `history_view.dart` | One-shot intent, visible/clearable revision scope, `LogQuery.revision`, and main-mount path matching (§0.5.F). |
| `lib/features/common/context_menu.dart` | Keyboard/focus/semantics/appearance parity or adapter to a native menu surface. |
| `lib/features/common/tappable.dart` | Remain low-level; branch rows must not rely on it alone for semantics/focus. |

File boundaries are targets, not a requirement to create empty abstractions.
Extract a file only when its first cohesive behavior lands.

### 2.2 Domain model

Use full ref names internally and short names only for display. Use full OIDs in
all provider keys and destructive preconditions.

```dart
enum BranchBaseSource {
  user,
  remoteHead,
  forgeDefault,
  localMain,
  localMaster,
  currentFallback,
  detachedFallback,
}

class BranchBase {
  final String? refName;      // null only for detached-HEAD fallback
  final String displayName;   // main or origin/main
  final String oid;           // full immutable OID
  final BranchBaseSource source;
  final bool isFallback;
}

class BranchReviewSummary {
  final String refName;
  final String shortName;
  final String branchOid;
  final String baseOid;
  final int aheadOfBase;
  final int behindBase;
  final bool mergedIntoBase;  // equivalent to aheadOfBase == 0
  final DateTime? lastCommitAt;
  final String? lastAuthorName;
  final String? lastAuthorEmail;
}

class BranchReviewBatchResult {
  final Map<String, BranchReviewSummary> summariesByRefName;
  final Map<String, BranchReviewFailure> failuresByRefName;
}

class BranchReviewFailure {
  final String refName;
  final String branchOid;
  final String reasonCode; // stable machine code; diagnostics stay in log/UI
}

class BranchComparisonMetadata {
  final String baseOid;
  final String branchOid;
  final String? mergeBaseOid; // null only when histories are unrelated
  final ComparisonAncestry ancestry;
  final List<BranchChangedFile> files;
  final int additions;
  final int deletions;
  final bool truncated;
}

enum ComparisonAncestry { connected, unrelated }

enum MergePreviewCapability { unknown, supported, unsupported }
enum MergePreviewState { clean, conflicts, unrelated, unsupported }

class BranchMergePreview {
  final MergePreviewState state;
  final List<String> conflictPaths;
}

sealed class BranchForgeKnowledge {}
class KnownBranchForge extends BranchForgeKnowledge {
  final Map<String, BranchForge> byBranch;
}
class UnavailableBranchForge extends BranchForgeKnowledge {
  final String reasonCode;
}
```

Whole-request loading/failure belongs to Riverpod `AsyncValue`; the batch result
retains per-ref failures so a partial host result remains inspectable. Worktree,
upstream, and forge fields remain independent inputs combined only in
`BranchRowViewModel`.

### 2.3 Provider split and keys

| Provider | Key | Starts when | Cost/caching |
| --- | --- | --- | --- |
| `repoLayoutProvider` | `repoPath` | Branch workspace preference/base first needed | One cached discovery per mount/reset cycle: modern path-format probe, then bounded 2.24 fallback when needed; keep alive until repo-scoped reset. |
| `repositoryUiIdentityProvider` | `(repoPath, sessionEpoch)` | Preferences first needed | Composes connection scope + `gitCommonDir`; session-only if canonical layout is unavailable. |
| `repoMergePolicyCacheProvider` | `repoPath` | A policy fetch succeeds | Passive in-memory cache only; reading it never starts forge work. |
| `remoteHeadProvider` | `(repoPath, remote)` | Base resolution needs it | Local Git read; missing symref returns null. |
| `branchBaseProvider` | `(repoPath, allowForgeFetch)` | Branches detail/Review needs it | Watches prefs/refs/remotes/status and passive policy cache; only the `true` key may instantiate policy fetch. |
| `branchReviewProvider` | `(repoPath, baseOid, refsFingerprint)` | Review is visible | One host invocation per 100-ref batch, sequential batches; not watched in Browse. |
| `branchUniqueCommitsProvider` | `(repoPath, baseOid, branchOid)` | Commits tab visible | AutoDispose AsyncNotifier; initial/page size 50; append with `log(skip:, maxCount:)` like History so Show More never refetches the prefix. |
| `branchComparisonMetadataProvider` | `(repoPath, baseOid, branchOid)` | Overview/Changes needs stats | Immutable OID key; parse off-isolate above existing threshold. |
| `branchDiffProvider` | `(repoPath, baseOid, branchOid, context, ignoreWhitespace)` | Changes tab visible | Immutable three-dot patch; byte-accounted LRU parallel to `commitRangeDiffProvider`. |
| `mergePreviewCapabilityProvider` | `(repoPath, sessionEpoch)` | Detail asks for preview | Uses background version when present; otherwise one on-demand Git version probe. `AsyncValue` distinguishes loading/error. |
| `branchMergePreviewProvider` | `(repoPath, baseOid, branchOid)` | Selected detail or explicit conflict scan | Immutable result; concurrency one per repository; no eager all-ref run. |
| `protectedBranchRulesProvider` | `repoPath` | Review cleanup/preflight | Optional forge read; sealed known/notApplicable/unavailable/unsupported result, never empty-on-error. |
| `branchForgeKnowledgeProvider` | `repoPath` | Review facets/details | Reuses PR/MR + CI providers; typed known-empty vs unavailable. Existing `branchForgeProvider` remains Browse facade. |

Add every repo-scoped family to `repoScopedFetchFamilies` for connection/repo
reset. Add only mutable-ref summary/base providers to
`repoMutationFamilies` as whole families, or make them watch `refsProvider` so
they self-refresh exactly as `mergedBranchesProvider` does. Do not invalidate
immutable OID-keyed comparison providers on ordinary mutations; ref refresh
selects a new key when needed. Add all new byte-sized immutable caches to
`clearHashKeyedRepoCaches`; an omission recreates the known stale KeepAliveLink
failure after repo retargeting.

Base resolution must not initiate a new forge request in ordinary Browse.
Browse uses `allowForgeFetch: false` and the passive cache only; Review or an
explicit refresh uses `true` and may populate that cache. The preferred-remote
symref path remains Git-only. A late automatic source may replace an automatic
fallback, visibly and with a new OID provider key, but never an explicit user
base.

All new families must satisfy §0.5.C's repo-reset registration; mutable-ref
families additionally satisfy mutation refresh, while immutable OID families
rekey from refreshed refs. Every new LRU must appear in
`clearHashKeyedRepoCaches` and the structural membership test.

### 2.4 Repository UI identity and preferences

Define storage identity as:

```text
stable connection scope + NUL + canonical gitCommonDir
```

- Saved SSH (`ConnectionState.connectionId != null`): `ssh:<SavedConnection.id>`.
- Saved local: `local:<SavedLocalRepo.id>`.
- Ad-hoc (`connectionId == null`): **in-memory only** — key
  `adhoc:<backend>:<sessionEpoch>` where `sessionEpoch` is the connection
  attempt/generation published on `ConnectionState` (see §0.5.B); **no disk
  write**; wipe on disconnect / `_invalidateRepoState`.
- `gitCommonDir` comes from `RepoLayout`, including scoped/separate layouts.
- Encode durable composites with UTF-8 + base64url (no padding) before using
  them in a SharedPreferences key. Do not expose hostnames/paths in new
  preference keys.

The identity/layout discovery runs concurrently with the current refs load and
must not gate first useful Browse paint. Reuse a layout already discovered
during connection when practical; otherwise permit one cached discovery per
mounted repo reset cycle; that discovery may use the modern probe and a bounded
compatibility fallback. An explicit ⌘R may start a new cycle because
`repoScopedFetchFamilies` is shared by manual refresh and connection reset.
Keep the current `--path-format=absolute` fast
path, but add a Git-2.24 fallback based on `--show-toplevel`,
`--absolute-git-dir`, and `--git-common-dir`; resolve a relative common dir on
the host with a quoted POSIX `cd` + `pwd -P`. Cover ordinary, linked-worktree,
scoped, separate-git-dir, symlink, and failure shapes. If neither path yields a
canonical common dir, use the ad-hoc/session store even for a saved connection
and surface persistence as unavailable rather than writing a raw-path key.

"Linked worktrees share" is scoped to views mounted under one saved
connection/session. Because a separately saved local worktree has its own
`SavedLocalRepo.id`, independently saved local entries intentionally retain
separate durable preference records.

The version-1 `BranchWorkspacePrefs` record contains:

```text
version
pinnedBranchNames
hiddenBranchNames
grouped
collapsedSections
collapsedFolderPrefixes
lastMode (browse/review)
browseSort
reviewSort
selectedBaseRefName
showHidden
```

Do not persist free-text search, active facets, selection, selected detail tab,
scroll offset, temporary “show all tags/remotes,” or in-flight scans.

Migration rules:

1. If the new identity-keyed record exists, use it.
2. Otherwise import `pinnedBranches_<repoPath>`.
3. Import the current Branch section bits (`branches.pinned/local/remote/tags`)
   from global `collapsedSections`; leave the legacy global values untouched so
   old versions and Forge keys remain safe.
4. Initialize all new fields to Browse/current defaults.
5. Write the new record once only for stable identities. Do not delete legacy
   keys in this initiative.
6. If preferences resolve after the user has interacted, merge only untouched
   fields; never snap mode/filter/selection backward underneath them.

---

## 3. Git and forge contracts

### 3.1 Base discovery

Add `GitService.remoteHead(repoPath, remote)`:

```text
git symbolic-ref --quiet refs/remotes/<remote>/HEAD
```

Pass the ref as argv. Exit 0 with a non-empty `refs/remotes/<remote>/…` target
returns that target; exit 1 with empty output means no symref and returns null;
other non-zero exits remain errors. Do not reintroduce `origin/HEAD` into
`parseRefs`.

Resolve a base in this order:

1. Stored full ref name, if
   `revParse(repoPath, '$refName^{commit}')` returns a full OID.
2. Preferred remote symbolic HEAD — only if `remotes` is non-empty; use
   `defaultRemote(remotes)` then `remoteHead(repoPath, remote)`
   (`git symbolic-ref --quiet refs/remotes/<remote>/HEAD`). Skip if
   no remotes (do not call `defaultRemote` on `[]`).
3. Forge policy `defaultBranch` (from extended `repoMergePolicy` DTOs), mapped
   to an existing local branch first and then `<preferredRemote>/<name>` when
   a remote exists.
4. Existing local `refs/heads/main`.
5. Existing local `refs/heads/master`.
6. Current local branch from `GitStatus.branch` / matching `GitRef`, labeled
   `Current fallback`.
7. Detached `HEAD` commit, labeled `Detached HEAD fallback`
   (`GitStatus.headOid`; `BranchBaseSource.detachedFallback`; `refName == null`).
8. `GitStatus.isUnborn` / no HEAD OID: no base; render a setup empty state.

Never persist an automatically resolved candidate. Persist only a user's base
selection. If a stored base disappears, retain it in preferences, show
`Saved base <x> is unavailable; using <y>`, and offer Reset/Choose—do not
silently overwrite the decision.

Step 3 (forge) is **Git-first offline-safe**: ordinary Browse reads only
`repoMergePolicyCacheProvider`; Review or an explicit base-selector refresh may
instantiate `repoMergePolicyProvider` and populate that cache (§0.5.D). A late
automatic source may replace an automatic fallback (visible, new OID key) but
never an explicit user base.

Extend `GhRepoMergePolicy`/`GlRepoMergePolicy` with nullable
`defaultBranch`, parsing `default_branch` from the already-fetched API object.
Update const constructors and fixtures with a default so existing call sites
remain source-compatible.

### 3.2 Ref metadata

First change the ref section emitted by `_fetchSnapshot` / separate fallback to
use `%00` between every fixed field and after the final field. Git appends one
newline per formatted ref; split records on that newline. NUL is forbidden in
ref names and parsed author identity headers, unlike the current unit separator,
so those fixed columns cannot shift. Keep the surrounding snapshot section
marker/fallback unchanged.

Then extend `_refsFormat` before the final subject field with:

```text
%(authordate:unix)
%(authorname)
%(authoremail)
```

Update `GitRef` with nullable/defaulted values. Require the 12 fixed fields that
precede the subject, then reconstruct the final subject from all remaining NUL
fragments (discarding the expected trailing empty field). This preserves the
current "unconstrained field last" defense even for a deliberately malformed
commit object. Treat literal unsupported atoms and invalid epochs as null. Strip angle
brackets from `%(authoremail)` for display/search and retain normalized email.
If a record has fewer than the fixed fields, drop it with a parse warning; do not
guess shifted positions. Make that warning observable without adding a second
Git fetch: add `parseRefsDetailed` returning
`RefsResult(refs, parseWarnings)`, retain `parseRefs` as the pure compatibility
facade, carry `refParseWarnings` on the existing combined `RepoSnapshot`, and
add `GitService.refsWithWarnings` over the same `_snapshot` future while
keeping `GitService.refs` source-compatible. `refsProvider` consumes the
detailed result and writes warnings to `outputLogProvider` before returning
the valid rows. One malformed row must not shift or discard valid siblings.

Do not rename `creatorDate` in this initiative: for branch tips it is the commit
committer date and remains the activity/stale-sort timestamp; for tags it keeps
the current tagger/committer semantics. `authorDate` is attribution/display
metadata only. This distinction is required for rebased/cherry-picked commits,
whose author date may be old even though the branch tip moved recently.

### 3.3 Batched Review summary

Add:

```dart
Future<BranchReviewBatchResult> branchReviewSummaries(
  String repoPath, {
  required String baseOid,
  required List<({String refName, String oid})> branches,
})
```

Contract:

- Validate `baseOid` and every branch OID as full hex object IDs obtained from
  the snapshot; reject malformed input before building a script.
- One `sh -c` host invocation per batch. For each supplied OID run
  `git rev-list --left-right --count <baseOid>...<branchOid>`. Capture its exit
  status and emit a NUL-terminated record containing input ordinal, OID,
  status, behind, and ahead separated by a fixed control separator. Set
  `LC_ALL=C`; validate field counts, integers, ordinals, and echoed OIDs.
- Expected per-tip Git failures are encoded in that row while the wrapper exits
  0 after emitting all rows; shell/transport failure and timeout fail the whole
  batch. This is how one bad object remains a typed per-row failure without
  hiding other valid rows.
- Prefer OIDs over branch names in the script so a concurrent rename cannot
  compare the wrong object and no ref text needs interpolation.
- The app joins each ordinal/OID back to the captured ref snapshot. Ordinals
  preserve two branch names pointing at the same OID; an OID mismatch is a row
  failure, never a join to whichever ref happens to share the object.
- Missing/corrupt one-branch output becomes a per-row unknown/error entry; it
  must not discard the other rows.
- Start with 100 branches per batch and the existing 60-second read timeout;
  declare named constants next to the method. Execute batches sequentially so a
  pathological repository cannot spawn unbounded Git walks. On timeout surface
  a Retry error for the affected summary load, not a partial silent empty list.
- Cancel/supersede: if baseOid, fingerprint, repoPath, or connection generation
  changes, ignore the in-flight result (see §0.5.C).
- Cache by `(baseOid, refsFingerprint)`. Implement `refsFingerprint` as a value
  object over a sorted, NUL-delimited canonical serialization of local
  `(fullRefName, commitOid)` pairs. Do not use a bare `Object.hash`/integer whose
  collision could serve stale truth; a digest is acceptable only if equality
  also verifies the canonical value. Activity/author changes only with the tip
  OID and need not enter separately.
- `mergedIntoBase` is `aheadOfBase == 0` (equivalent to
  `merge-base --is-ancestor branchOid baseOid` for a connected history); test
  merged, ahead-only, behind-only, diverged, identical, unrelated histories,
  and a branch moving while a request is in flight.

Measure this against real repositories before changing the initial constants.
If sequential batches exceed the performance gate, first reduce batch size for
timeout isolation, then consider a bounded host worker pool (maximum 2). Do not
replace the count contract with `for-each-ref --merged`: it lacks behind counts,
and do not introduce client-side SSH N+1 calls.

### 3.4 Unique commits and comparison metadata

**Preferred:** call existing `GitService.log` with
`revision: '$baseOid..$branchOid'` (already passed after `--end-of-options`).
Do not concatenate user ref names — OIDs only. Add a thin named wrapper
(`logRange`) only if call sites benefit; it is not a new Git transport.

Page unique commits with an AsyncNotifier patterned on `LogSearchNotifier`:
key only by immutable repo/base/branch OIDs, request 50 rows initially, then
`skip: current.length, maxCount: 50` and append/dedupe by hash. Preserve landed
rows on a page error and expose Retry at the sentinel. Do not put a growing
`limit` in the provider key and retransmit the prefix on every Show More.

Unit-test: argv contains the range as a single revision token; commit subjects
match a real temp-repo fixture for ahead/behind/identical tips.

Add `GitService.branchComparisonMetadata` using one diff invocation over
`$baseOid...$branchOid` and NUL-safe output. Required fields:

- merge base OID;
- file status and old/new paths (including rename/copy);
- binary marker;
- per-file additions/deletions where Git provides them;
- aggregate additions/deletions;
- explicit truncation if a configured file cap is exceeded.

Use `git merge-base <baseOid> <branchOid>` plus `git diff --numstat -z` and
`--name-status -z` in one shell invocation with section markers, or one
`--raw --numstat -z` format only if fixtures prove unambiguous parsing for
renames and unusual paths. Paths may contain tabs/newlines; line splitting is
not acceptable. A path can contain any non-NUL marker bytes, so the combined
form must validate its exact section structure and fall back to three separate
marker-free read invocations on collision/malformed framing, following the
existing `_fetchSnapshotSeparately` pattern. Parse large output in an isolate.

`git merge-base` exit 1 with empty output is the typed `unrelated` ancestry
outcome, not an exception and not an empty diff. In that case do not execute a
three-dot diff; return nullable `mergeBaseOid` + `ComparisonAncestry.unrelated`
and render `No common ancestor`. Other non-zero exits remain errors. A future
direct tree comparison may be offered only under an explicit `Direct two-dot`
label.

The patch provider calls existing `diffRange` with
`$baseOid...$branchOid`. Add an explicit comparison-method enum before adding
the optional direct two-dot UI; never let a toggle silently change semantics.

### 3.5 Merge preview

Capability logic:

- Parse `binaryEnvironmentProvider.versionOf('git')` with `ToolVersion.parse`
  when present. Because that provider has no version-probe loading/error state,
  an absent version triggers one Git-only on-demand probe in
  `mergePreviewCapabilityProvider`: construct `EnvironmentResolver` with
  `activeExecutorProvider`, call `probeVersions` with only the resolved `git`
  path, and treat a missing/unparseable returned Git version as an error. Do
  not probe gh/glab or leave the UI checking forever.
- Provider `AsyncLoading` => `Checking Git capability…`; `AsyncError` =>
  explicit failure + Retry (invalidate the capability provider).
- >= 2.38 => supported.
- < 2.38 => unsupported with `Requires Git 2.38+`.
- Do not execute legacy `merge-tree` speculatively.

For supported versions add:

```text
git merge-tree --write-tree --name-only -z --no-messages <baseOid> <branchOid>
```

- Run on `ExecLane.read`; it touches no refs/index/worktree, but document that
  it writes unreachable objects.
- Reuse/preflight the comparison ancestry. With no merge base, return
  `MergePreviewState.unrelated` without invoking merge-tree; do not silently
  opt into `--allow-unrelated-histories`.
- Limit to one concurrent preview per repository in the provider/controller.
- Exit 0 = clean; exit 1 = conflicts; all other exits = error.
- Parse the first record/tree OID separately from NUL-delimited conflict paths
  using fixtures captured from Git 2.38 and current Git.
- Cache by immutable OIDs and never auto-retry an error loop.
- Show local prediction separately from forge readiness.

### 3.6 Base-safe cleanup mutation

Add a service result and method, for example:

```dart
enum BaseDeleteStatus { deleted, moved, notMerged, checkedOut, missing }

Future<BaseDeleteResult> deleteBranchMergedIntoBase(
  String repoPath, {
  required String branchName,
  required String expectedBranchOid,
  required String baseOid,
})
```

The exclusive-lane captured script must:

1. Resolve `refs/heads/<branch>` and compare it to `expectedBranchOid`.
2. Refuse if `git for-each-ref --format=%(worktreepath) --count=1` for that
   exact full ref is non-empty. This atom exists at the 2.24 floor and avoids
   depending on `git worktree list -z` (which this codebase correctly gates at
   Git 2.36). Keep worktree removal an individual action, not a bulk side
   effect.
3. Run `git merge-base --is-ancestor <expectedBranchOid> <baseOid>`.
4. Delete atomically with
   `git update-ref -d refs/heads/<branch> <expectedBranchOid>`.
5. Produce a stable stdout status token for moved/not-merged/held/missing and
   exit 0 for those expected decisions; transport/shell/unexpected Git failure
   throws and the bulk coordinator records it under Failed. Do not parse
   localized stderr for expected decisions.
6. Reuse `_runCaptured` with pre-ref and post-ref captures. Create
   `UndoOpKind.deleteBranch` only when the pre-ref equals the expected OID and
   the post-ref is absent, proving this invocation deleted it; a skipped result
   must not create an undo record.

Construct `refs/heads/<branch>` once after `refNameProblem` validation and
`ShellEscaper.escape` every value embedded in `mutationScript`; OIDs must also
pass the full 40/64-hex validator. The expected-OID argument to `update-ref`
is the atomic tip-movement guard.

Do not force-delete a non-ancestor in bulk. An individual force delete remains
available behind the current explicit escalation.

### 3.7 Protection enrichment

Implement after base-safe cleanup works:

- Always exclude the selected comparison base (whether default or fallback),
  current branch, rows not explicitly confirmed, and all
  `worktreePath != null` branches where applicable.
- GitHub: fetch protected branch names with a bounded manual page walk because
  `GhService.api` deliberately does not concatenate `--paginate` JSON arrays.
- GitLab: fetch `projects/:id/protected_branches` with existing paginated API;
  retain wildcard rule names and match them with a tested GitLab-style `*`
  matcher rather than treating patterns as literal branches.
- Return a sealed `ProtectionKnowledge` (`known(rules)`, `notApplicable` when
  `Forge.none`, `unavailable(reason)`, or `unsupported(reason)`), not an empty
  set on errors. Likewise, `branchForgeKnowledgeProvider` returns known empty
  for `Forge.none` and unavailable for detection/auth/data failure.
- Branch rules/rulesets that the current API cannot represent remain unknown;
  UI copy says `Forge protection could not be verified`.

---

## 4. UX specification

### 4.1 Layout and responsive behavior

Keep `ResizableMasterDetail` and `PaneId.branchesList`. Do not create a second
pane-width setting.

- >= 980 px: Review rows may use aligned adaptive columns for Activity, vs
  Base, Request/CI, and Upstream.
- 760–979 px: collapse Activity to a second line; keep branch name and base
  state stable.
- 640–759 px: compact status glyphs with accessible labels/tooltips; detail
  remains usable at the existing 280 px floor.
- Reserve trailing status width so lazy Forge badges do not move branch text.
- Current state is a check badge/glyph; selected state owns the row background.
  This fixes the current HEAD-green background masking selection.

### 4.2 Toolbar

Top-to-bottom/tab order:

1. Browse/Review segmented control.
2. Search field, always visible.
3. In Review, a `Compared with <base>` selector with source tooltip.
4. Filter button showing active facet count.
5. Sort menu.
6. Fetch.
7. View menu: group by folder, show hidden, show all remotes/tags, lower-frequency
   controls.

Search token grammar (pure parser, chips optional in first iteration):

```text
plain text        branch name, subject, author, request title/number
author:<text>     author name/email
status:<token>    current, pinned, stale, merged, conflict, unpublished,
                  upstream-gone, worktree, ci-failing, request, no-request
```

Unknown `key:value` terms fall back to plain text and are never silently
dropped. Filtering is local over already-loaded data; optional forge/preview
states render “checking” and update deterministically when data lands.

`Mine` is derived from `appSettingsProvider`'s configured committer identity:
match normalized email case-insensitively when present, otherwise normalized
name. With neither configured, the facet is disabled with `Set a committer
identity in Settings`; it does not issue a `git config` read during Browse.

### 4.3 Browse mode

- Preserve Pinned, Local, Remotes, Tags and existing row virtualization.
- Preserve filter-force-expands behavior.
- Keep current branch at the top of Local after pinned branches without
  automatically pinning it.
- Natural-sort numeric path segments (`release/9` before `release/10`).
- Group remote branches by remote only when grouping is enabled.
- Show subject/date in remote detail and adaptive row metadata using existing
  `GitRef` values.
- Tags remain collapsed by default and absent from Review.
- Existing double-click checkout, dirty-tree guard, worktree switch, drag/drop,
  context actions, and keyboard shortcuts remain available.

### 4.4 Review mode

Review lists local branches only. Default order:

1. known conflicts/failing CI/upstream gone;
2. open request needing attention;
3. unpublished/ahead branches;
4. merged into base;
5. remaining branches by last activity descending;
6. natural name tiebreaker.

Explicit sorts: Smart, Recently updated, Name, Ahead of base, Behind base.

Required facets at first Review release:

- Merged into base / Not merged;
- Active / Stale (90-day policy, clearly labeled);
- Open request / No request;
- Failing CI;
- Unpublished;
- Upstream gone;
- Worktree;
- Conflict (known conflicts only; activating starts the visible scan).

Dashboard cards are buttons with selected state and counts. Clicking one
applies/removes its facet. Unknown optional-data counts display `—` or a
spinner, never zero.

### 4.5 Selection

Model selection as ordered full ref names plus an anchor:

- Click/arrow: replace selection.
- Command-click/Command-Space: toggle without losing other items.
- Shift-click/Shift-arrow: contiguous range over currently visible rows.
- Space: toggle focused row in Review.
- Escape: clear multi-selection after menu/drag dismissal precedence.
- Switching to Browse keeps the primary selected ref if visible and collapses
  multi-selection to it; switching back does not resurrect hidden selection.
- A ref refresh preserves selected names that still exist and removes vanished
  refs; anchor falls back to the nearest surviving visible row.

One selection shows normal detail. Multiple selections show count, aggregate
known statuses, and only safe batch actions (Pin/Unpin, Hide/Unhide, Delete
review). Never show Merge as a batch action.

### 4.6 Detail inspector

Stable header:

- branch name + Copy;
- Current/default/protected/worktree/request badges;
- explicit `Compared with <base>` line;
- one context-aware primary button, at most two secondary buttons, More menu.

Overview:

- Upstream card: tracking ref, To push, To pull, gone/unpublished.
- Base card: ahead, behind, merge base, changed files/lines, merged state.
- Readiness card: local merge prediction, request/draft/review/checks, and
  protection as separate rows.
- Last activity: author/date/subject.
- Every loading/error/unsupported state has its own text and retry where useful.

Changes:

- Label `Incoming changes from merge base (<base>...<branch>)`.
- File list with status, per-file stats, binary marker, rename source/dest.
- Unified/Split control reusing `DiffView`/`SplitDiffView`.
- Context and ignore-whitespace options enter the provider key.
- Explicit no-changes, truncated, byte-budget-exceeded, and error states.
- Do not fetch the patch until this tab is selected.

Commits:

- Label `Commits only on <branch> (<base>..<branch>)`.
- Load an initial 50, then explicit Show More; no all-history masquerade.
- `Open all reachable history` navigates to main History via
  `historyNavigationIntentProvider` (`({repoPath, revision})?`, parallel to
  forge create seed — §0.5.F). Seed the main History mount path, select
  `DropZoneId.history.pageIndex` (1), and mark visited. `HistoryView` consumes
  and clears the intent once into a visible `History of <ref>` scope;
  `LogQuery.revision` drives the walk until the user clears it. Do not clone
  History UI into Branches.

Primary-action precedence:

1. branch held elsewhere => Switch to Worktree;
2. noncurrent Browse branch => Check Out;
3. open request in Review => Open PR/MR (even if no upstream is configured);
4. unpublished Review branch => Publish Branch;
5. published branch with known forge and no request => Create PR/MR;
6. otherwise => Compare Changes.

Every dynamic primary action appears with an explicit label in More and the
command palette. Delete is always the last destructive menu group and never a
primary action.

### 4.7 Lifecycle flows

New Branch sheet:

- Name with `refNameProblem` validation.
- Start at: Current HEAD, current selection, base, or searchable local/remote/tag
  ref; show both name and type.
- Check out now (default true).
- Create in new worktree (mutually exclusive with checking out here).
- Current-HEAD start: call `createBranch(checkout: checkoutNow)`. Any other
  start: call `branchFrom(name, startRef, checkout: checkoutNow)`. When
  `checkoutNow` is true, wrap that single create-and-checkout call in existing
  `guardedBranchSwitch`; do not create first and perform a second checkout.
- New worktree: do not create the branch first. Open
  `AddWorktreeSheet(initialCommitish: startRef, initialBranchName: name)`; the
  sheet already passes both values to one `git worktree add -b` operation.

Publish:

- Available when **no upstream** (`GitRef.upstream == null`) and
  `remotesProvider` is non-empty (never call `defaultRemote` on `[]`).
- Confirm remote (default via `defaultRemote` when list non-empty) and branch
  name.
- Call real API:
  `push(repoPath, remote: remote, branch: name, setUpstream: true,
  force: PushForce.none)` — **not** a bool force flag; rides `ExecLane.sync`.
- Surface stdout/stderr via existing output log; on success
  `refreshAfterMutation`. Publishing a branch does not change tags, so do not
  invalidate `remoteTagsProvider`. Do not mark mutation only half-way.
- “Unpublished” means no upstream, not “no open PR/MR.”

Create PR/MR (full hop chain — all required):

1. **Coordinator** (extracted from `drop_registry._createRequestFromBranch`):
   resolve `forgeProvider(forgeMountRepoPath)`; on none/unknown show existing
   error dialog; else set seed and navigate.
2. **Seed** `forgeCreateSeedProvider`: extend record to
   `({String repoPath, String branch, String? baseRef})?` with
   compatible `set(...)` signature.
3. **`forgeMountRepoPath` (§0.5.A):** always `connectionProvider`’s
   `repoPath` (what `app_shell` mounts into `ForgePanel`). Worktree embed
   must not pass `worktreePath` when different.
   Normalize `baseRef` to a forge branch name for that remote (`main`, not
   `origin/main`); omit it for tag/detached/other-remote bases.
4. **Navigate:** Drop → `ctx.selectPage(DropZoneId.forge.pageIndex)`;
   Branches → `pageIndexProvider.notifier.select(4)` +
   `visitedPagesProvider.notifier.visit(4)`.
5. **Panels** (`github_panel` / `gitlab_panel`): when consuming seed, pass
   base through selection:
   `ForgeCreatingChangeRequest(seedSource: seed.branch, seedBase: seed.baseRef)`.
6. **Forms:** add `CreatePrForm.initialBase` / `CreateMrForm.initialTarget` and
   initialize the base/target controller once in `initState` from the non-empty
   seed, otherwise `'main'`. The existing late HEAD prefill touches only the
   source/head controller; keep it independent. Never rewrite base/target from
   a later provider rebuild after the user can edit it.
7. DnD and visible Create action **must** share the coordinator (single
   implementation).

Open request/CI:

- Request: existing `_open(bf.requestUrl)` path; keep.
- **Open CI is new in detail:** use `BranchForge.ciUrl` (already populated by
  forge fusion, currently unused in Branches detail) with the same
  `launchUrl` error handling as request open.
- Badges become semantic buttons with glyph + text/tooltip; no-URL state
  distinct.

Open on Forge:

- Add a pure `forgeBranchWebUrl(remoteUrl, forge, shortBranchName)` beside the
  existing helpers in `core/forge/forge_urls.dart`, using the authoritative
  `originRemoteUrlProvider` and URI-encoding the branch as one path component.
  GitHub uses `/tree/<branch>` and GitLab `/-/tree/<branch>`; return null for
  unknown forge/remote and hide or disable the action. Do not run `gh browse`
  or `glab` browser commands on the remote host.
- Because the app's Forge panel and URL provider are explicitly `origin`-based,
  expose this action only for `refs/remotes/origin/<branch>` or a local branch
  known to exist on `origin` (an `origin/<branch>` snapshot row, an
  `origin/*` upstream, or a known PR/MR URL). A branch that exists only on a
  different remote must not be sent to the `origin` forge URL.

### 4.8 Bulk cleanup

The review sheet contains a table:

```text
Branch | Tip | vs <base> | Worktree | Protection | Request | Decision
```

Preflight snapshots full branch/base OIDs. Default checked rows must be merged
into base, noncurrent, not held by a worktree, not the selected base/default,
known unprotected (when protection applies), and have no open request. Unknown,
unavailable, or unsupported protection/request knowledge defaults unchecked but
may be checked explicitly with a warning under Checkpoint D. `Forge.none` is
known not-applicable/known-empty and does not block the default. Stale alone
never checks a row.

Execution is sequential on the exclusive mutation lane. After each result,
refresh refs for the next precondition or rely on the atomic expected-OID guard.
Final summary groups:

- Deleted (undo available for the last journaled operation; Recovery/reflog for
  deeper recovery).
- Skipped: current, worktree, protected/default, not merged, deselected.
- Changed since review: OID moved or missing.
- Failed: command/transport error with first useful diagnostic and Copy Details.

Never swallow an exception. Never remove a worktree, close a request, or delete
a remote branch as an implicit bulk side effect.

---

## 5. Delivery phases

### 5.0 Per-phase working rule (normative)

1. **Implement and unit-test together.** Do not finish a phase’s feature work
   and “add tests later.” Prefer: characterization or failing unit test (when
   practical) → production change → green unit test for that seam, then the
   next seam. Widget/integration tests may follow the pure unit tests within
   the same phase, but pure unit coverage of new logic must not lag the
   implementation of that logic.
2. **Required tests table = phase exit gate.** Every phase below lists
   **Required tests**. A phase is not done until those files exist/update and
   pass under ordinary `flutter test`, plus `flutter analyze` clean.
3. **No phase may defer its unit tests to a later phase.** Widget polish or
   golden work may be refined in Phase 6, but parsers, identity, argv
   assembly, base resolution, batch parse, delete guards, and view-model
   rules ship with unit tests in the phase that introduces them.
4. Do not stage or commit; the maintainer owns commits and the repository
   hook owns messages.

| Phase | Dependency | Relative size | Review gate | MADR product outcome |
| --- | --- | --- | --- | --- |
| 0. Foundation | none | L | identity/migration/extraction review | No intended UX change; prefs identity shared across worktrees |
| 1. Base semantics | 0 | L | semantic correctness demo | Named base; no "safe" HEAD cleanup; Browse/Review + summary |
| 2. Inspector | 1 | XL | range/diff correctness review | Unique commits + three-dot changes tabs |
| 3. Merge preview | 1–2 | M | **trust milestone** (with 1–2) | On-demand conflict prediction; Conflicts scan |
| 4. Review/bulk | 1–3 | XL | destructive-flow review | Facets, sorts, multi-select, hide, base-safe bulk delete |
| 5. Lifecycle | 0–2 | L | action/navigation review | Publish, Create PR/MR (`forgeMountRepoPath`), History intent |
| 6. Accessibility/polish | all UI phases | L | keyboard/VoiceOver review | Semantics, keyboard, appearance, non-color status |
| 7. Performance/release | all | M | release evidence | Command budgets, 500-ref evidence, batch/concurrency and cache-cap decisions |

### Phase 0 — Characterization, extraction, and storage foundation

**Purpose:** make feature growth safe without changing visible behavior.

Tasks:

1. Add characterization tests for:
   - HEAD selected tint vs current tint;
   - Browse first paint issuing only current providers;
   - remote/tag keyboard selection and current Enter behavior;
   - repo switch clearing selection/scroll/folder expansion;
   - current delete/worktree/force escalation and undo record.
2. Extract pure dashboard stats (today’s private `_ReviewSummary` —
   counts + `mergedDeletable`; **not** a UI mode), row shaping, filtering,
   relative-time, folder grouping, and selection stepping into tested
   non-widget units. Prefer a name like `BranchDashboardStats` so it does not
   collide with the Phase 1 Browse/Review mode.
3. Extract navigator/detail widgets while keeping existing keys and semantics
   stable enough for current tests.
4. Stop assigning derived provider values to mutable fields in `build`; construct
   an immutable `BranchViewModel` and pass it down.
5. Add `repoLayoutProvider`, `RepositoryUiIdentity`, and preference-key tests for
   same-worktree, linked-worktree, same-path/different-connection, scoped repo,
   and ad-hoc session cases.
6. Add the Git-2.24 canonical-layout fallback and expose
   `ConnectionState.sessionEpoch`; identity code must not reach private
   controller state.
7. Add versioned `BranchWorkspacePrefs`; migrate pins and branch collapse state.
8. Keep `pinnedBranchesProvider` as a compatibility facade temporarily or
   update all callers/tests in the same phase; there must be one writer after
   migration.
9. Capture the 500-ref Browse fake-executor command count and local CPU baseline
   before feature providers land; wall-clock numbers are evidence, not flaky CI
   assertions.

Exit criteria:

- No intended visual/behavior change.
- Existing branch tests pass.
- Linked worktrees under the same connection scope resolve the same persistent
  identity; independently saved local entries remain separate.
- Two saved connections with the same repo path do not share preferences.
- Ad-hoc sessions do not write durable keys.
- `branches_view.dart` is materially smaller and has no build-time derived-field
  assignments.

**Required tests (unit unless noted):**

| File | Must cover |
| --- | --- |
| `test/repository_ui_identity_test.dart` | `ssh:<id>` / `local:<id>` + `gitCommonDir`; base64url key; linked worktrees in one scope match; independently saved local IDs differ; same path/different SSH IDs differ; ad-hoc never durable and includes published session epoch; wipe semantics; canonical-layout failure becomes session-only. |
| Repo layout unit/integration tests | Modern fast path and Git-2.24 fallback; ordinary, linked, scoped/separate, symlink, and failure shapes. |
| `test/branch_workspace_prefs_test.dart` | v1 JSON round-trip; migrate `pinnedBranches_<path>`; import `branches.*` collapse bits without deleting global legacy; late load does not clobber user-touched mode/base; session-only store. |
| Existing `pinned_branches_test.dart`, `branches_collapse_test.dart`, `branches_view_test.dart`, characterization additions | Behavior unchanged after extraction; facade or single writer for pins. |
| Pure view-model unit tests (even if file lands as `branch_view_model_test.dart` stub) | Filter/folder/relative-time helpers moved out of the State class. |

### Phase 1 — Explicit base and semantic correctness

**Purpose:** replace ambiguous HEAD-relative review claims.

Tasks:

1. Migrate ref snapshot fields to `%00` framing + observable parse warnings,
   then add author/date atoms and parser tests.
2. Add default-branch fields to forge policy models/services and fixtures;
   populate the passive policy cache only on successful fetch.
3. Implement remote HEAD read and base resolution model/provider.
4. Add base selector with grouped candidates: Recommended, Local, Remotes, and
   Tags. Persist only an explicit full ref name. Do not accept arbitrary
   revision expressions/SHA input as a durable workspace base in this phase.
5. Implement framed batched Review summaries, partial-result model, canonical
   fingerprint, and parser tests.
6. Introduce Browse/Review control; Review reads summary provider, Browse does
   not.
7. Replace dangerous copy:
   - old badge/callout => `Merged into current <name>` where retained;
   - Review => `Merged into <base>`;
   - upstream divergence => `To push` / `To pull`;
   - stale => inactivity only.
   - update `GitService.mergedBranchNames` documentation so it no longer calls
     HEAD-merged branches “safe to delete.”
8. Remove “safe to delete” from the current HEAD dashboard/callout until
   base-safe cleanup exists.
9. Remove the legacy dashboard `_deleteMergedBranches` bulk action in this
   phase; keep individual guarded delete. The Merged card becomes a
   base-relative filter only until Phase 4 ships reviewed atomic bulk delete.
10. Make Review dashboard counts clickable for Merged/Stale and add Activity/Name
   sort as the first vertical slice.

Exit criteria:

- Tests prove changing current `HEAD` does not change base-relative results when
  base/ref OIDs are unchanged.
- Every base has visible provenance; missing/unborn cases are explicit.
- Review's merged result matches `merge-base --is-ancestor` fixtures.
- Browse emits no `rev-list`, `merge-tree`, diff, or new forge command.
- No UI text calls stale, upstream-gone, or merged-into-current universally safe.
- Strings "safe to clean up" / "safe to delete" are gone from Branches UI (or
  gated behind base-safe cleanup which does not exist until Phase 4).
- No legacy HEAD-relative bulk-delete entry point remains; destructive batch
  deletion returns only with the Phase 4 preflight/result flow.

**Required tests:**

| File | Must cover |
| --- | --- |
| `test/refs_parse_test.dart` (update) | `%00` framing (12 fixed values before trailing subject); former unit separator in identity; NUL fragments rejoined only for final subject; new atoms; unsupported atoms → null; email normalization; short record warns/drops. |
| `test/branch_base_resolution_test.dart` | Full fallback order; `revParse(ref^{commit})`; missing persisted ref warning; remote-HEAD exit 1 vs error; passive-cache Browse vs fetch-enabled Review; status-backed current/detached/unborn; never persist automatic base. |
| `test/branch_review_parse_test.dart` | Framed `rev-list` records; duplicate tips joined by ordinal/ref; per-row nonzero/malformed/OID mismatch; OID validation; collision-free fingerprint equality/reorder; timeout whole-batch error; `mergedIntoBase == ahead==0`. |
| `test/gh_service_test.dart` / `glab_service_test.dart` / `merge_plan_test.dart` (update) | `defaultBranch` parse from existing repo/project fixtures; const constructors still work; `repoMergePolicyProvider` fixtures updated. |
| `test/branches_review_view_test.dart` (start) | Browse/Review control; base label; dashboard no longer says safe-to-clean for HEAD-only merge. |
| Fake-executor command budget (seed for Phase 7) | Browse path does not invoke summary/`rev-list` batch. |
| Integration (`@Tags(['integration'])` temp repo) | HEAD ≠ base; base-relative merged vs `git merge-base --is-ancestor`. |

### Phase 2 — Lazy comparison inspector

**Purpose:** show what the branch introduces without loading a patch eagerly.

Tasks:

1. Add paged unique-commits AsyncNotifier using existing `GitService.log` with
   `revision: '$baseOid..$branchOid'`, `skip`, and 50-row pages (optional thin
   `logRange` alias).
2. Add NUL-safe comparison metadata service/parser/provider.
3. Add three-dot branch diff provider and LRU byte accounting.
4. Build stable detail header and Overview/Changes/Commits tabs.
5. Reuse diff widgets; add unified/split, whitespace, context controls.
6. Add explicit loading/empty/error/truncation/byte-budget states.
7. Preserve tab/selection across provider refresh when ref still exists.

Exit criteria:

- Commits are exactly `<baseOid>..<branchOid>`.
- Changes are exactly `<baseOid>...<branchOid>` and labeled three-dot.
- Opening Overview or Commits does not fetch the patch.
- Moving either ref changes the OID key; old immutable cache remains valid but
  is not served to the moved selection.
- Rename, binary, Unicode, tabs/newlines in paths, empty diff, and output-budget
  errors have fixtures/tests; unrelated histories show no-common-ancestor, not
  no changes.

**Required tests:**

| File | Must cover |
| --- | --- |
| `test/branch_comparison_metadata_test.dart` | NUL paths; rename/copy; binary; marker-collision fallback; per-file + aggregate stats; truncation; unrelated merge-base exit 1 skips three-dot diff; other errors; isolate path if used. |
| Service/notifier log-range tests | `log` argv uses `$baseOid..$branchOid` after `--end-of-options`; initial 50; next page uses `skip=50` rather than max-count=100; append dedupe; page failure keeps rows + Retry. |
| Diff provider / LRU registration test | New branch-diff LRU appears in `clearHashKeyedRepoCaches`; key includes OIDs + context + ignoreWhitespace. |
| Structural `clearHashKeyedRepoCaches` membership test (§0.5.C) | Every `KeepAliveLru` used by providers is cleared; fails if a new LRU is omitted (prevents pure-`repoPath` stuck-loading / cross-session serve). |
| Widget: detail tabs | Overview/Commits do not request patch; Changes does once; explicit empty/error/truncated UI. |
| `test/branch_commits_refresh_test.dart` (update) | Unique-commit OID invalidation; no inherited history in the Branches list. |

### Phase 3 — Merge preview and trust gate

**Purpose:** add local conflict prediction without mutating a worktree.

Tasks:

1. Implement capability tri-state from landed background version data plus the
   one-shot on-demand fallback and retryable error state.
2. Add `merge-tree` service method, parser, OID cache, and concurrency-one gate.
3. Show prediction in Overview with separate forge-readiness rows.
4. Add conflict paths and file selection/open-changes behavior.
5. Implement Conflict facet as an explicit scan controller with progress,
   cancellation on mode/base/repo change, and cached-result reuse.
6. Instrument command count, elapsed time, output bytes, and cache hit/miss via
   existing command telemetry/logging without logging ref secrets beyond names
   already visible in UI.

Exit criteria — **trust milestone:**

- Git <2.38, unknown-version, clean, conflict, unrelated, malformed output,
  exit >1, and superseded-session paths are tested.
- Preview never changes HEAD, refs, index, or worktree in integration tests.
- Base/OID movement cannot land a stale preview into current detail.
- Conflict facet never presents unknown branches as clean.
- Maintainer review signs off on terminology and failure states.

**Required tests:**

| File | Must cover |
| --- | --- |
| `test/branch_merge_preview_test.dart` | Landed version vs absent-version on-demand probe; loading/error/retry/unsupported; unrelated skips merge-tree; exit 0/1/>1; tree-OID first NUL record; conflict paths; concurrency gate; stale OID key ignored after supersede. |
| Integration temp repo | Clean merge vs conflicting merge; `git status`/`rev-parse HEAD` unchanged after preview; object count may grow (unreachable tree) — document, do not treat as failure. |
| Widget readiness | Overview shows prediction separately from forge readiness; Retry on probe failure. |

### Phase 4 — Review workflow, facets, and multi-selection

**Purpose:** make repository-scale branch review efficient.

Tasks:

1. Implement pure search token parser and all required facets.
2. Add Smart/Recent/Name/Ahead/Behind sorts with deterministic natural-name
   tiebreaks.
3. Implement Command/Shift/keyboard multi-selection and batch summary.
4. Add Review-only typed forge branch knowledge (known empty vs unavailable)
   for request/CI facets, plus optional protection knowledge with explicit
   unavailable/unsupported states.
5. Implement atomic base-safe delete + undo capture.
6. Build preflight/result sheet; execute and report every branch.
7. Add Pin/Unpin and Hide/Unhide batch operations; Hide reports
   current/default/protected/pinned/worktree-held refs as skipped rather than
   removing them from the navigator.
8. Preserve focus and nearest-row selection after rows vanish.

Exit criteria:

- Facets compose by AND and search tokens compose predictably.
- `No request` and missing-CI states match only known forge data; forge failure
  produces unavailable counts/status and never enters a negative facet.
- Bulk tests cover mixed deleted/skipped/moved/failed outcomes and no swallowed
  errors.
- A branch merged into base but not current HEAD deletes safely through the
  OID-pinned method and is undoable.
- A branch that moves after preflight is never deleted.
- Current/default/known-protected/worktree-held exclusions are tested.
- No stale-only default selection.

**Required tests:**

| File | Must cover |
| --- | --- |
| `test/branch_view_model_test.dart` | Search grammar (plain + `author:` + `status:`); Mine email/name/disabled rules; unknown `key:value` → plain text; facet AND; natural sort (`release/9` < `release/10`); Smart attention order deterministic. |
| `test/branch_base_delete_test.dart` | Ancestor ok → deleted + `UndoOpKind.deleteBranch` record with OID; tip moved → `moved`; not ancestor → `notMerged`; `%(worktreepath)` held → `checkedOut`; missing → `missing`; skipped cases create no undo record; unexpected failure throws; never force in bulk. |
| `test/branches_multi_select_test.dart` | Click / Shift / Command / keyboard ranges; refresh drops vanished refs; batch summary never offers Merge. |
| Forge/protection knowledge tests | Browse facade remains resilient; Review known-empty ≠ unavailable; `No request` never matches failure; GitLab `*` matcher; protection error ≠ known-empty rules; copy never says protected when unknown. |
| Bulk sheet widget tests | Mixed result groups; exceptions not swallowed (contrast with current `_deleteMergedBranches`). |
| `test/undo_capture_test.dart` / `undo_scripts_test.dart` (update) | Base-safe delete undo recreates tip. |

### Phase 5 — Lifecycle actions and action hierarchy

**Purpose:** make the next action visible and remove drag-only discovery.

Tasks:

1. Replace HEAD-only `_createBranchPrompt` with New Branch sheet: name
   (`refNameProblem`), start-at, checkout-now, create-in-worktree. Use the
   exact §4.7 matrix (`createBranch` for HEAD, `branchFrom` otherwise,
   `guardedBranchSwitch` for checkout, and only `AddWorktreeSheet` for the
   worktree path).
2. Publish: non-empty remotes; confirm remote via `defaultRemote` when safe;
   `push(..., setUpstream: true, force: PushForce.none)`; log +
   `refreshAfterMutation`.
3. Extract forge create coordinator; extend seed +
   `ForgeCreatingChangeRequest.seedBase` + form `initialBase`/`initialTarget`
   (full hop chain in §4.7).
4. Visible Create/Open PR/MR, Open CI (`ciUrl`), Open on Forge, Compare with
   Base / Compare with… .
5. Replace flat detail action wrap with primary + max two secondary + More
   (existing merge variants / rename / upstream move under More; Delete last).
6. Command palette: **keep** `branches.newBranch` / `createTag` / `merge` /
   `delete`; add stable IDs for publish/create/compare/open-CI; wire handlers
   in Branches panel shortcuts.
7. Remote/tag detail: comparison entry points without Review hygiene membership.
8. Implement the complete History handoff (§0.5.F): main-mount seed, one-shot
   consumption, `LogQuery.revision`, visible scope chip, and Clear.

Exit criteria:

- Create from local/remote/tag/base/current is tested.
- Publish uses chosen remote, `-u`, and `PushForce.none`; empty remotes hidden;
  failure surfaces log output without half-applied UI state.
- DnD and visible Create share one coordinator; seed base reaches forms.
- Forms: seeded base/target; no overwrite of user edits; fallback `main` only
  without seed base.
- Worktree-embedded Create uses `forgeMountRepoPath == connection.repoPath`
  and main shell page 4 + visit(4).
- Seeded base is a forge branch name, never `origin/main`; invalid/tag/detached/
  other-remote bases omit the seed.
- Open CI works when `ciUrl` non-null; disabled otherwise.
- Open on Forge uses the local app launcher and encoded GitHub/GitLab branch URL,
  is disabled for branches not known on the `origin`-backed forge, and never
  executes a browser command on the remote host.
- History handoff from main and worktree-embedded Branches uses the main mount,
  scopes the real paged log to the revision, consumes once, and clears back to
  ordinary HEAD/`--all` behavior.
- All dynamic primaries exist in More/palette with explicit labels.

**Required tests:**

| File | Must cover |
| --- | --- |
| `test/branches_lifecycle_test.dart` | New Branch HEAD/other/worktree matrix and dirty guard; Publish argv (`-u`, remote, branch, no force); empty remotes hides Publish; no tag-cache invalidation; Open request/CI/branch URL launch or disabled. |
| Coordinator unit/widget tests | DnD + visible path one function; resolve/seed against `forgeMountRepoPath`; base normalization/omission. |
| Navigation tests | Main + worktree-embedded Branches → seed + `select(4)` + `visit(4)`. |
| History intent/log tests | Main + embedded seed the main mount; page 1; mismatched mount ignored; consumed once; `LogQuery.revision` reaches paged `GitService.log`; visible scope + Clear. |
| `create_pr_form` / `create_mr_form` tests | `initialBase`/`initialTarget`; fallback `main`; no clobber after edit. |
| `forge_selection` / panel seed tests | `seedBase` flows into form. |
| Command palette / keymap | Existing IDs preserved; new IDs registered; no search-field steal. |

### Phase 6 — Accessibility, native interaction, and visual polish

**Purpose:** meet the MADR's release-quality bar.

Tasks:

1. Implement semantic `BranchRow`: label, ref type, selected, current,
   expanded, position/count, statuses, enabled/default action.
2. Add Home/End/Page Up/Page Down, Space/Command-Space, Shift range, Return,
   context-menu key/Shift+F10, and type-to-find without stealing search input.
3. Upgrade `ContextMenuOverlay` or replace its use with a native/system menu:
   focus loop, arrows, Return/Space, Escape, disabled explanations, menu roles,
   focus restoration, light/dark, increased contrast, screen-edge placement.
4. Make CI/merge/request states non-color-only using stable glyphs and text.
5. Reserve lazy badge space and add skeletons/retry affordances.
6. Respect Reduce Motion; animate only small changes.
7. Audit 640 px width, text scaling, long Unicode refs, RTL text inside commit
   subjects, 500+ refs, slow SSH, disconnected forge, light/dark, Increased
   Contrast, grayscale, and keyboard-only flow.
8. Add Help/tooltip text explaining two-dot vs three-dot and the four distinct
   relationships.

Exit criteria:

- VoiceOver reads name/type/current/selected/base/request/CI meaningfully.
- Every operation is possible without a pointer and every drag action has a
  visible/menu alternative.
- Focus returns to the invoking row after menu/sheet close.
- No hard-coded dark context surface remains in light appearance.
- Golden/screenshot tests cover representative light/dark/narrow/large-text
  states where stable; behavior tests cover semantics and keyboard actions.

**Required tests:**

| File | Must cover |
| --- | --- |
| `test/branch_row_accessibility_test.dart` | Semantics label includes name/type/current/selected; focus traversal; Return default action; context-menu key. |
| Context menu tests | Light appearance not forced dark; keyboard navigation; focus restore. |
| Selection tint regression | Current HEAD row shows selection tint when selected (no green-mask-only). |
| `keyboard_shortcuts_test.dart` / mappings (update) | New shortcuts do not steal search field input. |

### Phase 7 — Performance hardening and release review

**Purpose:** prove remote-first behavior at realistic scale.

Tasks:

1. Add deterministic fake-executor command-count tests for Browse, entering
   Review, selecting a branch, opening each detail tab, and conflict scan.
2. Add an ordinary (non-live-forge) integration benchmark fixture with at least
   500 local refs and meaningful divergent histories.
3. Measure local and a controlled-latency executor/fake SSH profile:
   first list paint, Review summary, selected metadata, first patch render,
   conflict preview, memory/cache size.
4. Tune batch size, optional host concurrency (never above 2), and LRU byte caps
   from measurements; document final values beside constants.
5. Run full analyze/test and manual QA checklist.
6. Update MADR status only after maintainer accepts confirmation evidence.

Performance gates:

- Browse first useful paint: no additional comparison/forge round trip versus
  the current provider set; the one permitted lazy repository-layout identity
  read does not gate paint. Compare the median of at least five warm runs against
  the Phase 0 baseline; <= 10% local CPU regression. Wall-clock/CPU is release
  evidence, not a timing assertion in ordinary CI.
- Enter Review: base discovery is bounded to cached snapshot data plus at most
  one stored-ref verification and one remote-HEAD read when uncached, followed
  by one summary host invocation per configured batch; zero client-side
  per-branch SSH calls.
- Select branch/Overview: no patch fetch.
- Changes: one patch fetch for one OID key; repeat tab visit is a cache hit.
- Merge preview: maximum one active process per repository.
- Preference/layout identity: maximum one successful layout discovery per
  mount or explicit refresh/reset cycle. An ordinary repository on Git
  2.24–2.30 may use two Git invocations when the modern path-format probe fails
  and the compatibility fallback runs; the existing gitfile/scoped-layout
  detection may add its bounded `cat` and scoped-probe path. Count and test
  those shapes separately rather than asserting one universal invocation.
- Cache limits remain byte-bounded and are cleared on connection/repo retarget.

---

## 6. Test plan

**Parallel unit-test rule (same as §5.0):** write unit tests **alongside**
implementation for every phase — not after the phase’s product work is
“done.” Prefer pure unit tests (parsers, view models, identity, argv
assembly) over widget tests when logic can be extracted; add widget tests in
the same phase when UI contracts are specified. Use `@Tags(['integration'])`
temp repos for multi-ref git truth (same pattern as
`branch_ops_integration_test.dart`). **Never** enable `live-forge` for this
initiative unless the maintainer asks.

**Exit gate:** no phase is complete without its **Required tests** table
green under ordinary `flutter test`, plus clean `flutter analyze`.

### 6.0 Minimum unit-test matrix (must all exist by trust milestone)

| Concern | Unit test obligation |
| --- | --- |
| Identity + prefs | encoding, migration, public session epoch, ad-hoc non-persistence, scoped worktree share, Git-2.24 layout fallback |
| `parseRefs` + author fields | NUL fixed framing, adversarial former separator, malformed count warning, null atoms |
| Base resolution | ordered fallbacks, provenance flags, unavailable user base |
| Review summary batch | framed parser, ordinal/OID validation, canonical fingerprint, timeout, duplicate-tip join, per-row failure isolation |
| Unique commits argv | `$base..$branch` after `--end-of-options` |
| Comparison metadata | NUL paths, rename, binary, truncation |
| Merge preview | version tri-state, exit codes, conflict paths, concurrency gate |
| MergePlan/policy `defaultBranch` | parse + defaults for existing const call sites |
| Command budget (Browse) | zero summary/diff/merge-tree/new forge calls |

Phases 4–7 add multi-select, bulk delete, lifecycle, a11y, and scale tests on
top of this matrix.

### 6.1 New focused test files

| Test file | Coverage |
| --- | --- |
| `test/repository_ui_identity_test.dart` | connection/common-dir keying, base64 key, public session epoch, ad-hoc/session fallback, saved-local scope boundary. |
| `test/branch_workspace_prefs_test.dart` | v1 JSON, legacy pin/collapse migration, async-load interaction race, worktree sharing. |
| `test/branch_base_resolution_test.dart` | full fallback order, missing persisted ref, preferred remote, forge late/error, detached/unborn. |
| `test/branch_review_parse_test.dart` | framed counts, ordinal/duplicate-tip join, partial failures, OID validation, canonical fingerprint. |
| `test/branch_comparison_metadata_test.dart` | NUL paths, rename/copy/binary/stats/truncation. |
| `test/branch_merge_preview_test.dart` | version tri-state, exit mapping, NUL conflict paths, stale-key/cancellation. |
| `test/branch_base_delete_test.dart` | ancestor guard, OID race, worktree/current/missing, undo record. |
| `test/branch_view_model_test.dart` | search grammar, facets including unknown forge exclusion, natural sorts, attention order, primary-action precedence. |
| `test/branches_review_view_test.dart` | mode/base toolbar, dashboard filters, rows, explicit async states, detail tabs. |
| `test/branches_multi_select_test.dart` | pointer/keyboard ranges, refresh survival, batch summary. |
| `test/branches_lifecycle_test.dart` | create matrix/dirty guard, publish, forge navigation/base normalization, request/CI/branch URL actions. |
| History navigation tests | main-mount intent, one-shot consumption, revision-scoped paging, clear behavior. |
| `test/branch_row_accessibility_test.dart` | semantics, focus, keyboard/default/context actions. |
| `test/branch_review_command_budget_test.dart` | no Browse comparison calls, bounded Review/tab/scan invocations. |

### 6.2 Existing tests to update, not replace

- `refs_parse_test.dart`: NUL field count, old/literal atoms, former separator
  in author/subject, malformed-record warning, author/email/date.
- `gh_service_test.dart`, `glab_service_test.dart`, `merge_plan_test.dart`:
  default branch and protection fixtures.
- `branches_view_test.dart`, `branches_actions_test.dart`,
  `branches_view_guards_test.dart`: new hierarchy while preserving mutation
  safety.
- `branches_filter_test.dart`, `branches_navigator_test.dart`,
  `branches_collapse_test.dart`, `pinned_branches_test.dart`: pure view model and
  migrated preference ownership.
- `branches_forge_test.dart`, `branch_forge_status_test.dart`: clickable request
  and CI without changing branch-name fusion.
- `branches_worktree_badge_test.dart`, `branches_phase3_test.dart`: worktree
  primary action and embedded navigation.
- `branch_commits_refresh_test.dart`: new unique-commit OID invalidation; full
  reachable history is tested through the Phase 5 History revision scope.
- `undo_capture_test.dart`, `undo_scripts_test.dart`,
  `branch_ops_integration_test.dart`: atomic base delete and undo.
- `keyboard_shortcuts_test.dart`, `button_cursor_canon_test.dart`: new semantic
  row/menu behavior and no raw gesture regression.

### 6.3 Integration fixtures

Use temporary local repositories only:

1. main + feature ahead, behind, diverged, and merged.
2. current branch intentionally different from selected Review base.
3. linked worktrees holding two branches.
4. rename, binary file, tab/newline/Unicode paths.
5. clean and conflicting synthetic merges.
6. branch moved between preflight and delete.
7. detached and unborn repositories.
8. 500 branches sharing history plus a smaller divergent subset.

Do not tag any of these `live-forge`; forge responses use fake service/provider
fixtures. Never run the repository's skipped `live-forge` tests as part of this
plan unless explicitly authorized.

### 6.4 Verification commands per phase

While implementing a seam, run the **smallest targeted unit file** for that
seam frequently. Before leaving a phase (and before treating a work slice as
done), run:

```sh
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
```

If implementation changes only docs, no Flutter run is required. Before any
future staging, the repository agreement still requires clean `flutter analyze`
and ordinary `flutter test`.

---

## 7. Observability, failure handling, and privacy

- Use existing command telemetry for count/duration/byte size; add operation
  labels (`branch review summary`, `branch comparison metadata`, `branch merge
  preview`) without logging patch contents.
- Provider errors remain visible in the relevant pane with Retry. Do not convert
  errors to empty lists/maps for selected detail or Review truth.
- Optional Forge fusion may continue not to block Browse, but Review must show
  `Forge status unavailable` when a forge-specific facet/action needs it.
- Cancellation means ignore a superseded result keyed to old repo/base/OIDs;
  underlying one-shot Git processes need not be killed unless executor support
  already exists.
- Do not persist author search text, ref tips/OIDs, patch data, conflict paths,
  hostnames, or raw repository paths in the new workspace preference record.
- Repository identity keys are encoded, not displayed. They are not secrets;
  encoding prevents unsafe/oversized SharedPreferences key material and casual
  path exposure.

---

## 8. Rollout, compatibility, and rollback

- Keep Browse as the first-run mode. If persisted last mode is enabled, honor it
  only after a successful base can be resolved; otherwise land in Browse with a
  non-blocking explanation.
- No database/schema migration exists beyond additive SharedPreferences keys.
  Old versions ignore the new key; new versions leave legacy keys intact.
- All new Git features degrade on Git 2.24–2.37 except merge preview, which is
  explicitly unsupported.
- Forge-offline and no-remote repos retain local Browse/Review comparisons;
  Publish/Create request/protection are absent or unavailable with reasons.
- If Review causes a release regression, it can be feature-disabled at the
  toolbar/provider composition boundary while Browse and migrated preferences
  remain valid. Do not revert Git parser fields independently from the model.
- Do not ship partial bulk cleanup before atomic deletion and result reporting
  are both complete.

---

## 9. Review checkpoints and open decisions

### Checkpoint A — before Phase 1 implementation

Maintainer reviews:

- repository identity and ad-hoc persistence policy;
- preference fields/migration;
- extracted file boundaries;
- exact base selector terminology.

### Checkpoint B — after Phase 1

Status: **passed in automated coverage on 2026-08-04**. The temp-repository
integration fixture keeps `HEAD != base`; provider/widget tests pin passive
forge-cache behavior and a zero-command 500-ref Browse path; base and review
parser suites cover fallback, partial-result, and moved-tip behavior.

Demonstrate with one repository where current `HEAD != base`:

- old HEAD-relative and new base-relative facts differ as expected;
- switching HEAD leaves Review facts stable;
- Browse comparison/forge command count is unchanged; any identity layout read
  is one-shot and does not gate the branch list.

### Checkpoint C — trust milestone after Phase 3

Demonstrate:

- unique commit and three-dot change semantics;
- clean/conflicting previews without worktree mutation;
- Git <2.38 and failure UI;
- slow executor behavior and OID-stale result rejection.

Approve or revise readiness terminology before any cleanup recommendations.

### Checkpoint D — before bulk deletion

Review the exact preflight table and wording. **Default (normative unless
maintainer overrides):** unknown forge protection **permits** explicitly
checked deletion **with a warning** in the preflight sheet. Alternative:
disable bulk deletion until forge policy resolves. Either choice must remain
explicit and tested; unknown must not appear safe or protected.

### Checkpoint E — release candidate

Review performance evidence, keyboard/VoiceOver audit, screenshots in all
appearances/widths, full test output, and every MADR confirmation criterion.

---

## 10. Definition of done and MADR traceability

Maps MADR **Confirmation** criteria (and §0.5 contracts) to plan evidence:

| MADR confirmation | Completion evidence |
| --- | --- |
| Base always named; cleanup base-relative | Phase 1 base tests (incl. detached/unborn/unavailable stored) + Phase 4 atomic delete tests/demo. |
| Two-dot commits / three-dot changes | Phase 2 provider/parser/widget tests and visible method labels. |
| Browse remains within performance envelope; no comparison/forge N+1 | Phase 0 baseline + Phase 1/7 command-count tests; base reads passive forge cache only (§0.5.D). |
| Review filters, sorting, multi-select, partial results | Phase 4 view-model/widget/bulk tests (hide/unhide included here, not a separate phase). |
| Lifecycle actions visibly reachable | Phase 5 UI + coordinator tests; `forgeMountRepoPath`; History intent; palette IDs. |
| VoiceOver/keyboard/non-color status | Phase 6 semantics/keyboard tests and manual audit checklist. |
| Edge/error/worktree/version/identity/cache coverage | §6 matrix + §0.5.B/C tests (session epoch, LRU membership, supersede). |
| Unit tests written per phase in parallel with implementation | §5.0 + each phase’s Required tests; no deferred test-only trailing work. |
| Analyze and ordinary tests pass | Per-phase + final `flutter analyze` / `flutter test` output; no live-forge run. |

The implementation is done only when:

1. All phases 0–7 exit criteria are satisfied or a documented maintainer
   decision explicitly defers a non-trust feature.
2. Phases 1–3 are never deferred; they are the architectural decision's core.
3. Every phase’s unit tests were written **in parallel with** that phase’s
   production code (no deferred “test pass” after feature-complete phases).
4. No `safe` claim is based solely on age, upstream disappearance, CI, or
   HEAD-relative mergedness.
5. Browse has no new comparison N+1 behavior.
6. Every destructive batch result is explicit and OID guarded.
7. The ordinary analyzer/test suite is clean.
8. The maintainer approves updating MADR 0003 from `proposed` to `accepted`.

---

## 11. Internal implementation references

- `docs/0003-MADR-base-relative-branches-workspace.md` (authoritative product
  decision and confirmation criteria; this plan supplies its executable
  provider, bulk-delete, and phase contracts)
- `docs/0002-MADR-forge-change-request-merge-and-models.md`
- `docs/0002-PLAN-forge-change-request-merge-and-models.md`
- `lib/features/branches/branches_view.dart`
- `lib/features/branches/pinned_branches.dart`
- `lib/features/common/resizable_master_detail.dart`
- `lib/features/common/diff_view.dart`
- `lib/features/common/split_diff_view.dart`
- `lib/features/common/context_menu.dart`
- `lib/features/common/tappable.dart`
- `lib/features/dnd/drop_registry.dart`
- `lib/features/forge/forge_prefs.dart`
- `lib/features/forge/forge_create_sheet_widgets.dart`
- `lib/features/github/create_pr_form.dart`
- `lib/features/gitlab/create_mr_form.dart`
- `lib/features/tabs/tab_ui_providers.dart`
- `lib/features/worktrees/worktrees_view.dart`
- `lib/core/git/git_service.dart`
- `lib/core/forge/branch_forge_status.dart`
- `lib/core/forge/merge_plan.dart`
- `lib/core/providers/app_providers.dart`
- `lib/core/settings/tool_catalog.dart`
- `lib/core/ssh/environment_probe.dart`
- `lib/core/undo/undo_types.dart`
- `lib/core/undo/undo_journal.dart`
- `lib/core/settings/pane_layout.dart` / `tool_catalog.dart`
- `lib/core/storage/saved_connection.dart` / `saved_local_repo.dart`
- `lib/features/worktrees/worktrees_view.dart` / `add_worktree_sheet.dart`
- `lib/core/providers/keep_alive_lru.dart`
- Existing branch tests under `test/branches_*.dart`, `test/branch_*.dart`,
  `test/pinned_branches_test.dart`, `test/refs_parse_test.dart`,
  `test/branch_ops_integration_test.dart`
