# Evolve the Branches tab into a base-relative branch workspace

- Status: **accepted for implementation sequencing** (companion plan Phases
  0–5 landed; lifecycle actions and forge/history handoffs in place;
  Checkpoint C/D/E maintainer review still recommended before wide rollout)
- Date: 2026-08-03
- Deciders: Mac Smith
- Tags: branches, git, github, gitlab, forge, worktrees, comparison, ui, ux, accessibility
- Companion plan: `docs/0003-PLAN-base-relative-branches-workspace.md`
- Authority: this MADR owns the decision and normative semantics. The companion
  plan implements it with executable contracts and file-level delivery. If the
  two diverge, update the plan to match this MADR or amend this decision
  explicitly; the plan does not silently supersede the decision.

Technical Story: Magic Git needs a Branches screen that remains fast and calm
for everyday branch switching, but also answers the questions that make branch
management difficult: what this branch introduces, whether it is safe to merge
or delete, whether it is published and reviewed, and what action should happen
next. The screen must provide those answers for local and SSH-hosted repositories
without duplicating the History, Forge, or Worktrees tabs.

## Context and Problem Statement

The current Branches tab is not a primitive branch list. It is a recently
redesigned, well-tested, resizable master-detail workspace with a substantial
feature set. The remaining problem is less about missing buttons than about the
screen's organizing model.

Today, several important judgments are relative to the checked-out `HEAD`:

- `mergedBranchesProvider` calls `git branch --merged`, so the `merged` badge
  and bulk cleanup mean "merged into the branch checked out in this worktree."
- Ahead/behind counts mean divergence from each branch's configured upstream.
- The selected branch's `RECENT COMMITS` preview is `git log <branch>`, so it
  includes inherited history and does not isolate the work introduced by the
  branch.

These are all valid Git facts, but they answer different questions. A user
reviewing `feature/payments` usually wants comparison with `main` or another
explicit integration base, not whichever branch happens to be checked out and
not necessarily `origin/feature/payments`. The screen currently presents these
facts together without making the comparison frame sufficiently explicit.

The resulting risks are:

1. A branch can be labeled merged and offered for cleanup because it is merged
   into the current feature branch, even when it is not integrated into the
   repository's default branch.
2. "Recent commits" looks like a branch-specific review but contains all
   reachable ancestors; it cannot explain what the branch adds.
3. There is no in-app changeset comparison or local merge-conflict preview, so
   the detail pane stops just before the information needed to decide whether
   to merge, rebase, create a PR/MR, or delete.
4. A fixed substring filter and refname ordering do not scale into branch
   review: there is no sort by activity and no facets for stale, merged,
   conflicted, unpublished, open-request, failing-CI, or broken-upstream state.
5. The action surface is broad but flat. Selecting a non-current local branch
   can produce on the order of eight equal-looking capsule buttons (Open
   request, Check out, New worktree, Merge into current, Set upstream, Rename,
   Pin, Delete), including destructive Delete, while high-value flows such as
   Publish and Create PR/MR are absent or discoverable only by dragging a branch
   to the Forge navigation item.

The architectural question is whether to keep polishing the current
HEAD-relative navigator, replace it with a commit graph, or retain its strong
master-detail foundation and add an explicit base-relative review model.

## Current Codebase Assessment

### What is already strong

| Area | Current capability |
| --- | --- |
| Structure | `BranchesView` uses the shared persisted `ResizableMasterDetail`; the navigator is virtualized with `ListView.builder`. |
| Organization | Pinned, local, remote, and tag sections; independent collapse; optional `/`-folder grouping; stale local collapse; capped remote and tag lists. |
| Selection | Mouse selection, immediate select-on-drag, double-click checkout, arrow-key navigation across visible refs, Esc/empty-space deselection, and scroll-to-selection. |
| Branch state | Current branch, upstream, ahead/behind, upstream-gone, merged-into-HEAD, worktree ownership, last subject/date, and remote tag synchronization. |
| Forge fusion | Open PR/MR number, draft state, latest CI status, and request URL are fused lazily from existing Forge providers without blocking the Git list. |
| Actions | Create, checkout, explicit remote tracking checkout, rename, set/unset upstream, pin, four merge modes, rebase by drag/drop, local/remote delete, fetch/prune, create/push/delete tags, and worktree creation/switching. |
| Safety | Dirty-tree branch-switch guard, busy/re-entry guard, confirmation and force-delete escalation, worktree-held branch handling, dirty-worktree warning, and undo-journal integration for supported Git mutations. |
| Scale and resilience | Machine-format ref parsing, combined repo snapshot, off-isolate parsing, provider invalidation on ref movement, graceful optional forge data, and extensive widget/unit coverage across **15** branch-focused test files plus `refs_parse` / undo / integration. |

This foundation should be preserved. In particular, the existing executor seam,
shared providers, mutation guardrails, and worktree-aware checkout behavior are
more capable than the basic branch pickers in many clients.

### Product and UX gaps

#### 1. Comparison semantics are implicit and mixed

- `merged` means merged into current `HEAD`, while divergence means relative
  to upstream. Neither is the explicit integration base a reviewer expects.
- The dashboard calls already-merged branches "safe to clean up" without first
  choosing a stable review base. Plain `git branch -d` retains Git's own
  mergedness guard (against the configured upstream, or `HEAD` when there is
  none), but it does not make the organizational judgment that work landed in
  the canonical branch.
- The detail commit preview has no base label, unique-commit count, changed-file
  list, patch, additions/deletions, merge base, or conflict prediction.
- The current branch's green background takes precedence over the selected-row
  tint, so selecting `HEAD` does not receive the same visible selection state
  as every other row.

#### 2. Discovery and prioritization are weak

- Local refs arrive in Git's default refname order. Users cannot sort by recent
  activity, name, ahead/behind, or attention.
- Search matches only `shortName`; it cannot search commit subject, author,
  request title/number, or status tokens.
- The dashboard's stat cards are passive. They look like filters but do not
  navigate to the branches they summarize.
- Current, default, protected, pinned, worktree-held, merged, PR/MR, CI, and
  divergence signals compete in a narrow trailing row cluster. Lazy forge
  badges can also change row geometry after the list appears.
- Remote rows show only a cloud and name even though the shared `GitRef` already
  has subject/date data and forge status can often be matched by branch name.
- Tags are useful but can dominate the same navigation hierarchy during a task
  focused solely on branch review.

#### 3. Important lifecycle actions are missing or indirect

- New Branch always starts at current `HEAD`; it cannot visibly start from the
  selected branch, remote, tag, or commit even though `GitService.branchFrom`
  already exists.
- An unpublished local branch cannot be published from its detail pane.
- Create PR/MR is implemented and can be seeded by drag-to-Forge, but there is
  no visible branch action that invokes the same `forgeCreateSeedProvider`
  workflow.
- `BranchForge.ciUrl` is collected but the Branches detail has no Open CI action.
- There is no Compare with Base / Compare with… flow, no changed-files view,
  and no way to open the selected branch or comparison on its forge.
- Bulk cleanup is all-or-nothing selection assembled by the app. It swallows
  per-branch delete failures, provides no result summary, and offers no general
  multi-selection for pin, hide, or reviewed deletion.
- There is no non-destructive hide/archive mechanism for reference branches a
  user wants out of the navigator but does not want to delete.

#### 4. Accessibility and macOS polish need a dedicated pass

- Branch rows and custom context-menu entries are built from
  `GestureDetector`/`Tappable`, without explicit button/menu semantics, labels,
  selected state, or per-item keyboard activation.
- The list-level Focus supports arrows and local checkout, but remote/tag
  actions and context menus are not fully keyboard navigable.
- Several states lean on red/green/orange/blue color. Text, icons, and tooltips
  sometimes reinforce the color, but the nine-pixel CI dot is still primarily
  color-coded.
- The custom context menu has fixed dark chrome even in light appearance and
  does not behave like a native menu for keyboard navigation or VoiceOver.
- Dragging a branch onto current `HEAD` is a good power gesture, and context
  menus provide an alternative, but the merge-vs-rebase meaning is invisible
  until the user already knows to drag.
- Loading and failure are often collapsed to absence (`.value ?? {}` or an
  empty commit list). This keeps the list resilient but makes "none," "still
  loading," and "failed" indistinguishable in the detail experience.

### Maintainability finding

`lib/features/branches/branches_view.dart` is **2,655** lines and combines data
shaping, view-state persistence, keyboard navigation, all row and detail
rendering, context menus, and every branch/tag mutation. It also assigns several
derived fields (`_locals`, `_navigable`, `_forge`, `_merged`, `_pinned`) during
`build`. A private `_ReviewSummary` type already exists at the bottom of the
file for dashboard counts and HEAD-relative `mergedDeletable`. The tests are
strong (**15** branch-focused test files plus `refs_parse_test`, undo suite, and
`branch_ops_integration_test`), but continuing to add comparison, filters,
multi-selection, and accessibility directly to this State object would make
behavior harder to reason about and reuse.

### Codebase audit notes (2026-08-04)

Grounding pass against master; full action list lives in
`docs/0003-PLAN-base-relative-branches-workspace.md` §0.

| Topic | Fact |
| --- | --- |
| Pane layout | `PaneId.branchesList` → default 380 / min 300 / max 680 (`pane_layout.dart`). |
| Merged badge source | `git branch --merged --format=%(refname:short)` (no commit-ish) via `mergedBranchNames`; provider swallows errors to `{}`. |
| "Safe" copy today | Dashboard and detail still say *safe to clean up / safe to delete* for HEAD-merged branches; bulk delete swallows per-branch failures. |
| Commits preview | `branchCommitsProvider` → `log(..., maxCount: 15)`; empty on error. Range unique commits can reuse `log(revision: '$baseOid..$branchOid')` (already after `--end-of-options`). |
| Diff | `diffRange` + Diff/Split views + `commitRangeDiffProvider` / `KeepAliveLru` / `clearHashKeyedRepoCaches`. |
| Forge create | Seed is `({repoPath, branch})?` only; panels use `ForgeCreatingChangeRequest(seedSource:)`; forms have `initialHead`/`initialSource` but base/target hardcoded `'main'`; DnD uses `DropContext.selectPage(forge)` (index 4). |
| Forge list truth | `branchForgeProvider` catches forge/auth/data errors and returns `{}` so Browse badges never break. Review must not use that empty compatibility value for `No request`/CI truth; it needs typed known vs unavailable knowledge over the same cached sources. |
| Worktree embed | Worktrees IndexedStack is Status / History / Branches / Stash — **no Forge**. Create PR/MR must navigate the main shell with `forgeMountRepoPath == connection.repoPath`. |
| Worktree sheet | `AddWorktreeSheet` already has `initialCommitish` and `initialBranchName`. |
| New branch | UI is HEAD-only `promptText` + `createBranch`; `branchFrom` exists unused by that prompt. |
| Publish | `GitService.push` with `PushForce` enum + `setUpstream`; no Branches Publish action today. |
| Open CI | `BranchForge.ciUrl` is fused but Branches detail does not open it (request URL only). |
| Policy DTOs | `repoMergePolicyProvider` exists; DTOs lack `defaultBranch`; API payloads include `default_branch`; no protected-branch listing helpers yet. |
| Git floor | Tool catalog minimum Git **2.24**; merge-tree write-tree needs **≥ 2.38** (unused in tree today). |
| Accessibility | HEAD green background masks selection tint; context menu hard-coded dark `0xFF2C2C2E`; rows lack Semantics/Focus. |
| Flat actions | Typical non-current local detail: Open request, Check out, New worktree, Merge into current, Set upstream, Rename, Pin, Delete — no multi-select, no Browse/Review mode. |
| Private `_ReviewSummary` | Dashboard counts only — not a Browse/Review mode switch. |
| Detached/unborn input | `GitStatus` already exposes `headOid`, full `branch`, and `isUnborn`; base resolution must watch `statusProvider` as well as refs/remotes. |
| Revision resolution | `GitService.revParse` already provides a quiet, argv-safe revision probe; stored/tag bases should reuse it with `^{commit}` rather than add another resolver. |
| Session identity | `ConnectionController._attempt` is private and `ConnectionState` exposes no generation. Phase 0 must publish a read-only `sessionEpoch` before ad-hoc preference keys can be implemented. |
| Layout compatibility | `RepoLayout` exists, but its current `--path-format=absolute` command is not available on every host allowed by the Git 2.24 floor. Phase 0 must add a 2.24-compatible canonical-layout fallback or treat workspace preferences as session-only when canonical identity is unavailable. |
| History scope | `HistoryView` keys `LogQuery` without a revision and therefore walks HEAD/`--all`. A one-shot intent alone is insufficient; History must retain a visible, clearable revision scope and pass it to `GitService.log`. |

Corrections relative to earlier drafts of this decision:

1. Trust milestone includes **merge preview** (companion plan Phases 1–3), not
   only base + commits.
2. Unique commits do not require a new multi-revision log API first-class; the
   existing `revision` parameter accepts a Git range.
3. Worktree-embedded Branches cannot host Forge create UI; navigation must leave
   the worktree stack for the main Forge page.
4. Unit tests are part of the decision's confirmation criteria, not optional
   polish: they are **written in parallel with implementation each phase**
   (companion plan §5.0, §6, and per-phase Required tests tables) — not as a
   trailing pass after features land.
5. Socratic review (2026-08-04) accepted Option C and required implementable
   contracts in companion plan §0.5 (forge seed `forgeMountRepoPath` =
   `ConnectionState.repoPath`, ad-hoc identity with session epoch, connection
   invalidate registration for all new families/LRUs, Browse passive forge
   cache only, framed summary batches with timeouts, named History navigation
   intent).
6. Final grounding removed the proposed summary hybrid: `for-each-ref
   --merged` classifies ancestry but cannot supply `behindBase`, so it cannot
   satisfy the list-tier summary contract without still walking each merged
   tip. The shipped contract is one framed `rev-list --left-right --count`
   result per captured tip inside bounded host-side batches.

## External Product Research

Research was performed against official product documentation and release
notes on 2026-08-03 and revalidated on 2026-08-04.

| Product | Useful pattern | Implication for Magic Git |
| --- | --- | --- |
| Tower | Branches Review compares local branches to an explicit base and classifies them as merged, cleanly mergeable, or conflicting; it sorts by name/date and filters by activity, mergeability, PR presence, and tracking errors. Selecting a conflict shows affected paths. | Make the comparison base and merge state first-class; do not infer review readiness from upstream divergence. |
| Tower | Pinned branches, `/` folders, stale/merged badges, and automatic archiving keep the ordinary sidebar calm. | Keep Magic Git's existing navigator; add non-destructive hiding/review rather than replacing it. |
| Fork | Multi-branch/tag removal, stale-branch selection, worktree badges/actions, ahead/behind, and remote-branch-as-worktree flows emphasize direct manipulation and bulk work. | Add standard multi-selection and visible alternatives to existing drag gestures; keep worktrees integrated in branch identity. |
| GitHub Desktop | A focused Current Branch picker uses search and recent branches; branch creation asks for the base; Publish Branch is prominent; dirty-tree switching explicitly offers leave-vs-bring changes; branch history can be filtered to commits ahead of a selected base. | Promote the likely next action and ask "from what?" when creating; Magic Git's existing dirty-tree guard is a strong base to retain. |
| GitHub web | Branches are scoped into Yours, Active, Stale, and All. Active/stale uses a three-month threshold and ordering is activity-first. | Turn the existing 90-day rule into a visible, filterable view and add recent/activity ordering; add Yours when author identity is available. |
| GitLab web | New branches can start from a branch, tag, or SHA. Compare distinguishes merge-base (`A...B`) incoming changes from direct (`A B`) differences. Bulk delete applies to branches merged into the default branch and excludes protected branches. | Support explicit start points, label comparison method, and make default/protected branch semantics part of cleanup. |
| GitKraken / GitLens | Hide/Solo reduces graph clutter without changing refs; comparisons use the common base and open a multi-file diff; PR indicators and worktree state live beside branch identity. | Add hide/focus and reuse Magic Git's existing diff renderer and forge fusion instead of building another graph. |
| Apple HIG | Search scopes/tokens refine broad search; drag/drop needs non-drag alternatives and continuous feedback; interfaces should not communicate with color alone; Mac productivity apps should support keyboard workflows, resizable layouts, and menu commands. | Use faceted filters, redundant status glyphs/text, complete keyboard/VoiceOver semantics, and menu parity for every power gesture. |

### Sources

- [Tower: Branches Review](https://www.git-tower.com/help/guides/branches-and-tags/branches-review/mac)
- [Tower: Branches and Tags](https://www.git-tower.com/help/guides/branches-and-tags/overview/mac)
- [Tower: Comparing Branches and Revisions](https://www.git-tower.com/help/guides/commit-history/compare-branches-revisions/mac)
- [Tower: Automatic Branch Management](https://www.git-tower.com/help/guides/branches-and-tags/automatic-branch-management/mac)
- [Fork release notes](https://git-fork.com/releasenotes)
- [GitHub Desktop: Managing branches](https://docs.github.com/en/desktop/making-changes-in-a-branch/managing-branches-in-github-desktop?platform=mac)
- [GitHub Desktop: Viewing a pull request](https://docs.github.com/en/desktop/working-with-your-remote-repository-on-github-or-github-enterprise/viewing-a-pull-request-in-github-desktop)
- [GitHub Desktop: Syncing a branch](https://docs.github.com/en/desktop/working-with-your-remote-repository-on-github-or-github-enterprise/syncing-your-branch-in-github-desktop)
- [GitHub: Viewing branches](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-branches-in-your-repository/viewing-branches-in-your-repository)
- [GitHub: Protected branches](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches)
- [GitLab: Branches](https://docs.gitlab.com/user/project/repository/branches/)
- [GitLab: Compare revisions](https://docs.gitlab.com/user/project/repository/compare_revisions/)
- [GitLab: Protection rules](https://docs.gitlab.com/user/project/repository/branches/protection_rules/)
- [GitKraken: Hide and Solo branches](https://help.gitkraken.com/gitkraken-desktop/hiding-and-soloing/)
- [GitKraken: Worktrees](https://help.gitkraken.com/gitkraken-desktop/worktrees/)
- [GitLens: Commit Graph and comparison features](https://help.gitkraken.com/gitlens/gitlens-features/)
- [Apple HIG: Search fields](https://developer.apple.com/design/human-interface-guidelines/search-fields)
- [Apple HIG: Drag and drop](https://developer.apple.com/design/human-interface-guidelines/drag-and-drop)
- [Apple HIG: Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)
- [Apple HIG: Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos)
- [Git: `git diff`](https://git-scm.com/docs/git-diff)
- [Git: `git rev-list`](https://git-scm.com/docs/git-rev-list)
- [Git: `git merge-tree`](https://git-scm.com/docs/git-merge-tree)
- [Git: `git for-each-ref`](https://git-scm.com/docs/git-for-each-ref)

## Decision Drivers

- **Correct mental model.** Always name the base and distinguish base-relative
  comparison, upstream synchronization, forge readiness, and worktree state.
- **Everyday calm, expert depth.** Branch switching must remain quick; review
  data and bulk tools should appear progressively, not overload every row.
- **Trustworthy cleanup.** Never call stale "safe"; only call a branch merged
  relative to an explicit base, respect known protected/default branches, and
  report every bulk result.
- **Remote-first performance.** Avoid N+1 SSH round trips and eager forge calls;
  cache immutable comparisons by OID and load expensive data on selection or
  explicit Review mode.
- **Architecture fit.** Keep `CommandExecutor` and `GitService`; parse machine
  formats; keep GitHub/GitLab calls in their existing services/providers.
- **Forge degradation.** Core branch browsing and comparison must work offline
  and without `gh`/`glab`; forge policy enriches rather than owns the model.
- **Worktree correctness.** Preserve branch/worktree identity and avoid hidden
  checkout or working-tree mutation during review.
- **Native interaction.** Full keyboard, menu, VoiceOver, appearance, contrast,
  and non-drag alternatives are release criteria, not later decoration.
- **Reuse.** Reuse `diffRange`, `DiffView`/split diff primitives, Forge create
  seeding, output log, mutation refresh, and undo infrastructure.
- **Test-as-you-go.** Unit tests land in parallel with each phase’s
  implementation; coverage is not a post-feature cleanup step.

## Considered Options

### A. Continue incremental polish on the HEAD-relative screen

Add sorting, nicer rows, and more action buttons without a comparison model.

- Good: smallest implementation and no new Git reads.
- Good: preserves all existing behavior.
- Bad: leaves the central ambiguity between HEAD, upstream, and default base.
- Bad: cannot provide a truthful changeset, merge review, or cleanup dashboard.
- Bad: more buttons worsen the current flat action hierarchy.

### B. Replace Branches with a full commit graph

Make a graph the primary Branches experience, similar to graph-centric clients.

- Good: branch topology becomes visible.
- Good: direct manipulation on graph labels is powerful.
- Bad: duplicates the existing History graph and diff surface.
- Bad: a graph is poor at scanning hundreds of stale/remote refs or performing
  base-relative hygiene.
- Bad: large engineering scope distracts from the actual comparison-semantic
  gap and would make the common checkout task heavier.

### C. Keep Browse and add a base-relative Review workspace (chosen)

Retain the current navigator as the default Browse experience. Add a distinct
Review mode and a comparison-aware detail inspector, backed by explicit base,
summary, and selected-comparison domain models.

- Good: preserves the strongest current code and familiar daily flow.
- Good: separates navigation from repository hygiene without splitting them
  into unrelated screens.
- Good: makes comparison and cleanup trustworthy and supports progressive data
  loading over SSH.
- Good: enables sorting, facets, multi-select, diffs, unique commits, and
  conflict detail from one coherent model.
- Bad: adds UI mode/state and new providers that require careful cache and
  invalidation design.
- Bad: local mergeability needs Git-version-aware degradation.

### D. Make the Forge tab the branch-management center

Drive branches from PR/MR and CI state, delegating review to GitHub/GitLab.

- Good: forge policy, authorship, review, checks, and default branch are rich.
- Bad: fails offline, non-forge, unauthenticated, and local-only workflows.
- Bad: remote branches without requests and local unpublished work disappear.
- Bad: violates the product's Git-first, forge-optional architecture.

## Decision Outcome

Choose **Option C**: retain the existing master-detail Branches navigator and
evolve it into two progressively disclosed tasks:

1. **Browse** (default): fast ref navigation, checkout, worktree switching,
   pinning, remotes, and tags.
2. **Review**: local branches compared with an explicit integration base,
   sorted and filtered by attention, with multi-select cleanup and a richer
   changes/commits inspector.

This is an additive evolution, not a visual rewrite. Existing actions and
guardrails remain, but their hierarchy and labels change to reflect the new
model.

### Normative semantic rules

The UI must keep these four relationships distinct:

| Relationship | Meaning | Example UI |
| --- | --- | --- |
| Checked out | Branch is `HEAD` here or is held by another worktree. | `Current` or worktree-name badge. |
| Upstream sync | Local branch versus its configured upstream. | `2 to push · 1 to pull`, `Upstream gone`, Publish/Push/Pull. |
| Base comparison | Selected/reviewed branch versus explicit integration base. | `3 commits ahead · 8 files changed vs main`, merged/clean/conflict. |
| Forge readiness | PR/MR policy, reviews, checks, draft, and protection. | Open request, failing checks, approvals required, protected/default. |

No label may collapse one relationship into another. In particular:

- `Merged` always renders as `Merged into <base>` in Review and cleanup.
- `Stale` means only inactivity; it never implies safe deletion.
- `Clean merge` is a local Git prediction, not forge permission or readiness.
- `Passing CI` is not equivalent to mergeable.
- An unknown/loading state is not rendered as a known empty state.

### Base resolution and persistence

Introduce `branchBaseProvider` (visible base selector with provenance). Resolve
the first usable value in this order (full contract: plan §3.1):

1. User-selected base persisted for this repository (full ref name), if it still
   resolves to a commit.
2. Symbolic default of the preferred remote (`refs/remotes/<remote>/HEAD` via a
   separate `symbolic-ref` read — not by reintroducing `*/HEAD` into `parseRefs`).
3. Forge-reported `defaultBranch` when already available, mapped to an existing
   local branch first then `<preferredRemote>/<name>`.
4. Existing local `refs/heads/main`, then `refs/heads/master`.
5. Current local branch, labeled `Current fallback` (never silently called
   default).
6. Detached `HEAD` commit, labeled `Detached HEAD fallback`.
7. No base for an unborn/empty repository — setup empty state.

Rules:

- Persist **only** an explicit user base selection. Never persist an automatic
  candidate. If a stored base disappears, keep it in prefs, show
  `Saved base <x> is unavailable; using <y>`, and offer Reset/Choose.
- Ordinary **Browse** must not initiate a new forge request for base resolution;
  it may read only the passive policy cache populated by an earlier forge
  fetch. Request missing forge default branch only in Review or an explicit
  base-selector refresh (plan §0.5.D).
- A late automatic source may replace an automatic fallback (visible, new OID
  key) but must never replace an explicit user base.

Repository UI identity for shared prefs (plan §2.4 / §0.5.B):

- Durable only when `ConnectionState.connectionId != null`:
  `ssh:<SavedConnection.id>` or `local:<SavedLocalRepo.id>` + `gitCommonDir`
  (base64url-encoded key). Not raw worktree path.
- Ad-hoc (`connectionId == null`): in-memory only, keyed with backend + a new
  public read-only connection `sessionEpoch` + `gitCommonDir`; wipe on
  disconnect / connection invalidate.
- Linked worktrees mounted under the same saved connection/session share
  organization prefs because their common dir and connection scope match;
  independently saved local entries remain separate by design. Selection and
  scroll stay per-widget / per-worktree path.
- Canonical layout identity must work at the Git 2.24 floor. If the common dir
  cannot be resolved, degrade to session-only preferences and show no
  persistence claim; never fall back to a durable raw `repoPath` key.

### Target domain and provider shape

Keep `GitRef` as the cheap snapshot identity. Add comparison-specific types
rather than growing it into a forge-and-review aggregate.

**Normative shape:** use the provider split below, detailed by companion plan
§2.2 / §2.3, rather than a single fat aggregate. In particular:

- List-tier `BranchReviewSummary` carries base ahead/behind/merged and activity
  metadata only — **no per-row merge-preview or conflict paths**.
- Merge preview, unique commits, comparison metadata, and patch are **separate
  OID-keyed providers**, started only when the selected detail (or an explicit
  Conflicts scan) needs them.
- An earlier sketch that embedded `mergePreview` / `conflictCount` on every
  summary row is **non-normative** (it would force N+1 or eager host work).

Recommended provider split (see plan for full keys and cache rules):

- `branchReviewProvider((repoPath, baseOid, refsFingerprint))`: local-branch
  list-tier summary, created only while Review is visible. Its result carries
  successes and per-ref failures separately so one malformed/missing row never
  masquerades as zero divergence.
- Selected comparison split: unique commits, metadata, three-dot patch, and
  merge preview as separate families keyed by immutable OIDs.
- Existing branch-forge fusion: remains optional list-tier; selected details can
  reuse richer PR/MR detail and merge-plan providers from
  `0002-MADR-forge-change-request-merge-and-models.md`.
- Review forge facets consume a typed known/unavailable provider over the same
  PR/MR and CI sources. The existing empty-on-error map remains a Browse
  compatibility facade only; an outage never satisfies `No request`.

Do not make every normal `refsProvider` refresh compute comparisons or call the
forge. Review summaries should be a framed, batched host operation within
bounded SSH work, cached by
`(baseOid, refs fingerprint)`. All new families/LRUs must register for
connection invalidate / `clearHashKeyedRepoCaches` (plan §0.5.C).

### Git implementation strategy

Use plumbing/machine-oriented outputs through `GitService` (executable detail
in plan §3):

- Before adding commit-controlled author fields, migrate the `for-each-ref`
  subformat from its current unit-separator columns to fixed `%00` NUL-framed
  fields (one Git-added newline per record). Then add
  `%(authordate:unix)`, `%(authorname)`, and `%(authoremail)` before the final
  subject for attribution, search, and Mine filtering. Git ref names and parsed
  identity headers cannot contain NUL, so an adversarial author cannot shift the
  fixed columns. Keep the subject last and rejoin any trailing NUL fragments
  defensively rather than assuming arbitrary message bytes are clean. Keep
  `creatorDate` as branch/tag activity and stale-sort timestamp.
- Review summary (batched, Review-visible only): one
  `rev-list --left-right --count <baseOid>...<branchOid>` per captured tip,
  framed with input ordinal, OID, command status, behind, and ahead inside a
  bounded host-side script. This remains one executor/SSH invocation per batch,
  not one client round trip per branch.
  `mergedIntoBase` ≡ `aheadOfBase == 0` (equivalent to
  `merge-base --is-ancestor branchOid baseOid` on connected histories).
- Unique commits: existing `GitService.log` with
  `revision: '<baseOid>..<branchOid>'` (already after `--end-of-options`).
- Incoming changes: `GitService.diffRange('<baseOid>...<branchOid>')` and
  existing diff widgets. Optional direct two-dot comparison only as an
  explicitly labeled secondary method. If `git merge-base` reports no common
  ancestor, render `Unrelated histories`; three-dot Changes is unavailable and
  must not appear as an empty changeset.
- On Git 2.38+, `git merge-tree --write-tree --name-only -z --no-messages
  <baseOid> <branchOid>` on demand (not for every ref). Exit 0 clean, exit 1
  conflicts, other exits error. Capability tri-state while version probe is
  unknown. Writes an unreachable tree; does not touch refs/index/worktree.
- On older Git: `Merge preview unavailable (requires Git 2.38+)`; never parse
  legacy human-facing `merge-tree` output.
- With no common ancestor: `Merge preview unavailable — unrelated histories`;
  do not add `--allow-unrelated-histories` silently.
- Base-safe bulk delete: OID-pinned script (tip match, worktree check,
  `merge-base --is-ancestor`, `update-ref -d` with expected tip, undo journal) —
  plan §3.6. Not plain `git branch -d` against HEAD.

All OIDs/ref arguments: argv for local execution, or `ShellEscaper` in any
batched remote script. Large patches remain under existing byte budgets and
off-isolate parsing. New providers/LRUs must register for connection invalidate
and `clearHashKeyedRepoCaches` (plan §0.5.C).

### Target layout and interaction

#### Master toolbar

- Provide a compact Browse / Review switch. Search remains persistently visible.
- Replace the lone substring contract with suggestions/tokens and a filter menu:
  Current, Pinned, Mine, Active, Stale, Merged, Conflicts, Open request, No
  request, Failing CI, Unpublished, Upstream gone, and Worktree.
- Add sort: Smart/Attention, Recently updated, Name (natural), Ahead of base,
  and Behind base. Browse defaults to current/pinned then existing organization;
  Review defaults to attention/recent activity.
- `Mine` uses the app's configured committer email (case-insensitive), falling
  back to configured committer name only when no email exists. If neither is
  configured, disable the facet with an explanation; do not add an eager Git
  config read to Browse.
- Keep Fetch visible. Move folder grouping, hidden refs, and lower-frequency
  view controls into a labeled View menu rather than relying on unlabeled icons.
- In Review, show `Compared with <base>` prominently and make it selectable.

#### Browse rows

- Preserve Pinned / Local / Remotes / Tags and virtualization.
- Keep the current branch visible near the top even if it is not pinned; use a
  check/current badge, not a special background that masks selection.
- Give the branch name the stable primary column. Reserve a predictable status
  region or reveal secondary actions on hover so async badges do not cause
  distracting layout shifts.
- Use a restrained second line or adaptive columns for last subject/date and
  upstream state when width permits. Collapse secondary metadata before the
  branch name truncates.
- Group remote branches by remote in grouped mode and show date/subject in the
  detail even when the row remains compact.
- Keep Tags collapsed by default in Review; tag comparison remains available
  from Browse without mixing tags into branch hygiene.

#### Review rows and multi-selection

- Show local branches only, with columns/adaptive fields for branch, last
  activity, base divergence, merge state, request/CI, and upstream health.
- Support Shift/Command multi-selection and keyboard equivalents. The detail
  pane becomes a batch summary when multiple branches are selected.
- Stat cards on the empty Review dashboard become live filters with counts.
- Add app-local Hide/Archive and Show Hidden. This changes presentation only;
  it never deletes a Git ref. Current, pinned, protected/default, and
  worktree-held branches cannot be hidden; a batch request reports them skipped.
- Bulk Delete operates only on an explicit selection, preflights each branch,
  defaults to branches merged into the selected base, and uses an
  **OID-pinned base-safe mutation** (tip matches expected OID; not checked out
  in any worktree; `merge-base --is-ancestor` into the review base;
  `update-ref -d` with the expected tip; journal `UndoOpKind.deleteBranch`) —
  **not** plain `git branch -d` against HEAD and not force-delete in bulk. It
  reports deleted/skipped/failed/moved results individually and must not
  swallow exceptions. Stale branches require independent review. Unknown forge
  protection permits checked deletion with a warning by default (plan
  Checkpoint D).

#### Detail pane

Use a stable header and three tabs/sections:

1. **Overview**: branch identity; current/default/protected/worktree/request
   badges; explicit upstream and base comparison; last activity and author;
   merge/conflict/readiness callout.
2. **Changes**: files changed and unified/split patch for
   `<base>...<branch>`, reusing current diff infrastructure; loading, empty,
   truncated, and failure states are explicit.
3. **Commits**: only `<base>..<branch>` unique commits by default, with a
   deliberate "All reachable history" option that navigates to History via
   `historyNavigationIntentProvider` (plan §0.5.F).

Replace the flat action wrap with:

- One context-aware primary action: Check Out, Switch to Worktree, Publish,
  Open PR/MR, or Create PR/MR as appropriate.
- At most two visible secondary actions, typically Compare/Open Changes and New
  Worktree or Merge into Current.
- A native-style More menu for Set/Unset Upstream, Rename, Pin/Hide, Copy Name,
  Open on Forge when the branch is known on the app's `origin`-backed forge,
  Open CI, merge variants, and Delete at the end.

Do not let a smart primary action obscure fundamentals: Browse should still
favor checkout for a noncurrent local branch, while Review can favor comparison
or the open request. Every primary action must also exist in a menu and command
palette with an explicit label.

#### Creation and lifecycle polish

- New Branch opens a small sheet with Name, Start at (current/selected/ref),
  Check out now, and optionally Create in new worktree (reuse
  `AddWorktreeSheet`'s existing `initialCommitish` / `initialBranchName`).
- Add visible Publish Branch (`push` + `PushForce.none` + `setUpstream: true`
  when remotes non-empty) and Create Pull/Merge Request. Create reuses an
  extracted coordinator and the full seed hop:
  `forgeCreateSeedProvider` (optional `baseRef`) →
  `ForgeCreatingChangeRequest(seedSource, seedBase)` →
  `CreatePrForm.initialBase` / `CreateMrForm.initialTarget` (today only head/
  source is seedable; base/target default to `'main'`). Navigate the **main**
  shell to Forge (`pageIndex` 4 + visit). Worktree-embedded Branches has no
  Forge page. **Seed `repoPath` must equal `ConnectionState.repoPath`**
  (`forgeMountRepoPath`), never the embed `worktreePath` when they differ
  (plan §0.5.A).
- Convert the selected Git base to a forge branch name before seeding: strip
  `refs/heads/`, or strip `refs/remotes/<forge remote>/`; do not pass
  `origin/main` as a PR/MR base and omit the seed for a tag, detached OID, or
  remote that is not the forge remote.
- "Open all reachable history" uses `historyNavigationIntentProvider`
  (`({repoPath, revision})?`) then selects History page index 1. The intent
  `repoPath` is the main History mount (`ConnectionState.repoPath`), not an
  embedded worktree path. HistoryView consumes it once into a visible,
  clearable revision scope that becomes part of `LogQuery` and is passed to
  `GitService.log` (plan §0.5.F). Do not clone History UI into Branches.
- Make the request and CI badges clickable and keyboard-focusable, with text/icon
  shapes in addition to color.
- Offer Compare with Base and Compare with… on local, remote, and tag refs.
- Preserve the current dirty-tree checkout decision and worktree-safe delete
  escalation exactly; these are product strengths.

### Accessibility and visual quality bar

- Introduce a semantic/focusable branch-row primitive exposing label, selected,
  current, expanded, and disabled state to VoiceOver.
- Support arrows, Home/End, Page Up/Down, Space/Command-click selection,
  Return default action, Shift+F10/context-menu key equivalent, and type-to-find
  without stealing keystrokes from the search field.
- Prefer system/native menu components or bring the shared context menu to
  parity for keyboard navigation, VoiceOver roles, focus return, light/dark,
  increased contrast, and destructive placement.
- Never rely on color alone: CI uses distinct check/spinner/x/pause glyphs;
  merge state uses check/warning/merged shapes and text; ahead/behind retains
  arrows and numbers.
- Audit light, dark, Increased Contrast, Reduce Motion, text scaling, narrow
  640-pixel windows, long Unicode/ref names, hundreds of refs, and slow SSH.
- Animate only small state changes and respect Reduce Motion. Preserve row
  position and selection across fetch/ref refresh whenever the ref still exists.
- Use skeletons or stable reserved regions for lazy enrichment; surface a small
  retry affordance when forge/comparison data fails instead of silently erasing
  it.

### Delivery sequence

**Normative packing matches the companion plan §5** (earlier drafts that put
"organization polish" and "a11y+perf" in different buckets are superseded):

| Phase | Plan name | Product outcome |
| --- | --- | --- |
| 0 | Foundation | Characterization tests; extract view model / navigator / detail; repository UI identity + preference migration; no intended UX change. |
| 1 | Base semantics | Explicit base provider/selector; base-relative merged/ahead/behind; relabel HEAD/upstream/base; remove "safe" copy and the legacy HEAD-relative bulk-delete action; Browse/Review switch + first summary. |
| 2 | Inspector | OID-keyed unique commits + metadata + lazy three-dot patch; Overview / Changes / Commits; explicit loading/error/truncation. |
| 3 | Merge preview | Git-version-aware `merge-tree --write-tree`; on-demand conflict paths; Conflicts facet as explicit scan only. **Trust gate with 1–2.** |
| 4 | Review/bulk | Facets, Smart/activity sorts, natural sort, multi-selection, hide/unhide, protection knowledge, OID-pinned base-safe bulk delete with per-branch results. |
| 5 | Lifecycle | Create-from selection, Publish, visible Create PR/MR (`forgeMountRepoPath`), Open CI/Forge/comparison, History intent, primary/More hierarchy. |
| 6 | Accessibility/polish | Semantic rows, keyboard/menu parity, light/dark/contrast, non-color status. |
| 7 | Performance/release | Command-budget tests, 500-ref evidence, tune batch size/concurrency and cache caps, release checklist. |

**Phases 1–3 are the trust milestone** (phase 0 required first). Do not build
bulk deletion or callout recommendations on the old HEAD-relative model.

**Unit tests in parallel with implementation (normative):** every phase writes
its unit tests **alongside** the production code for that phase — not as a
follow-on after the feature work is finished. Prefer pure unit tests for new
parsers, identity, base resolution, batch/argv contracts, view models, and
delete guards in the same work slice as the code under test; widget and
`@Tags(['integration'])` temp-repo tests complete the phase’s Required tests
table in the companion plan. A phase is incomplete until those tests pass under
ordinary `flutter test` (and `flutter analyze` is clean). Do not defer a
phase’s unit coverage to a later phase.

### What this decision does not include

- Replacing History with another full commit graph.
- Building a full in-app PR/MR review-thread editor in Branches.
- Making forge connectivity mandatory for branch management.
- Automatically deleting stale or merged refs without an explicit reviewed
  selection.
- Parsing human-facing Git output or lowering the project's Git compatibility
  floor solely to obtain merge preview.
- Duplicating GitHub and GitLab create/merge forms inside Branches.
- Adding AI review as a prerequisite for a polished branch workspace.

## Consequences

### Positive

- The screen answers a coherent question: "what does this branch add relative
  to this base, and what should I do next?"
- Cleanup becomes safer and explainable, especially when the current worktree
  is not on the default branch.
- Everyday checkout remains fast and uncluttered while review gains deep data.
- Existing diff, forge, worktree, executor, and mutation infrastructure is
  reused rather than forked.
- Magic Git differentiates itself for remote-over-SSH workflows: rich branch
  review without requiring a local clone.
- OID-keyed providers create reusable primitives for History, Forge create
  previews, branch comparison URLs, and future stacked-branch work.
- Accessibility work improves the shared row/menu primitives beyond this tab.

### Negative / costs

- Comparison summaries and merge previews consume CPU/object traversal on the
  host; large repositories require caching, bounded concurrency, and explicit
  Review activation.
- Base resolution across offline Git, multiple remotes, and forge defaults adds
  domain and persistence complexity.
- Browse/Review is another mode to teach and test; selection behavior must stay
  predictable when switching modes.
- Forge protection/readiness remains eventually consistent and optional; copy
  must be precise about unknown data.
- The current monolithic view needs extraction before feature growth, creating
  a meaningful refactor even though the visible design evolves incrementally.

### Neutral

- Tags remain part of Browse but not the primary Review dataset.
- Upstream ahead/behind remains valuable; it is relabeled, not removed.
- Local merge preview can create unreachable tree objects; normal Git object
  maintenance eventually prunes them. The feature is on-demand and cached.
- Existing collapse and pin preferences require migration, not deletion.
- Organization preferences are shared by worktree views in one connection
  scope, not across independently saved local-repository records.

## Confirmation

This decision is confirmed when all of the following are true:

1. Selecting or reviewing a branch always names its comparison base, and tests
   prove merged cleanup is based on that base rather than current `HEAD`.
2. The Commits and Changes views show `<base>..<branch>` and
   `<base>...<branch>` semantics respectively, with the method labeled; an
   unrelated history is explicit rather than empty.
3. Normal Browse does not issue comparison or forge N+1 work; an SSH benchmark
   with hundreds of refs keeps first useful list paint within the current
   performance envelope.
4. Review mode provides activity sort, at least Merged/Stale/Request/CI/Upstream
   filters, multi-selection, and a per-branch bulk result summary. Negative
   forge facets such as `No request` operate only on known data, never outages.
5. Create from selected ref, Publish, Create PR/MR, Open request, Open CI, and,
   when the branch is known on the `origin`-backed forge, Open on Forge are
   visibly reachable without drag or right-click.
6. VoiceOver announces branch name/type/current/selected/status; the full screen
   is operable by keyboard alone; CI/merge status remains understandable in
   grayscale and Increased Contrast.
7. Targeted **unit**, widget, and integration tests cover at least: base
   fallback order and provenance (including detached/unborn and unavailable
   stored base); repository UI identity + preference migration (durable vs
   ad-hoc session epoch; linked worktrees in one connection scope share;
   independently saved local entries and same path / different connections do
   not); `parseRefs` author-field shift safety; review-summary batch
   parse/fingerprint/timeout/supersede; unique-commit and three-dot
   argv/semantics; comparison metadata NUL/rename/binary/truncation;
   merge-preview version tri-state and exit mapping; OID-key cache invalidation
   / no stale serve; structural `clearHashKeyedRepoCaches` membership; Git
   <2.38 degradation; worktree-held refs; protected/default cleanup exclusions;
   bulk partial failures with **no swallowed exceptions**; Browse command
   budget (no comparison N+1; no forge fetch for base); Create PR/MR
   coordinator from main and worktree-embedded Branches with
   `forgeMountRepoPath == connection.repoPath`; normalized forge base; History
   navigation intent consumed once into a revision-scoped log and cleared.
   Full file list is the companion plan §6. **These tests are
   produced phase-by-phase in parallel with implementation**, not batched at
   the end of the initiative.
8. `flutter analyze` and the ordinary `flutter test` suite pass (including
   `integration`-tagged temp-repo tests) at the end of **each** phase before
   the next phase starts. Live-forge tests remain skipped unless explicitly
   requested under the repository's safety policy.

## Internal References

- Companion plan: `docs/0003-PLAN-base-relative-branches-workspace.md`
  (§0 audit, §0.5 contracts, §2–5 architecture/phases, §6 tests)
- `lib/features/branches/branches_view.dart` (2,655 lines; `_ReviewSummary`)
- `lib/features/branches/pinned_branches.dart` (`pinnedBranches_<repoPath>`)
- `lib/features/branches/create_tag_sheet.dart`
- `lib/core/git/git_service.dart` (`GitRef`, `RepoLayout`, `_refsFormat`,
  `parseRefs`, `mergedBranchNames`, `log`, `diffRange`, `push`, `branchFrom`,
  `deleteBranch` / `UndoOpKind.deleteBranch`)
- `lib/core/forge/branch_forge_status.dart` (`BranchForge.requestUrl` / `ciUrl`)
- `lib/core/forge/merge_plan.dart` (`GhRepoMergePolicy` / `GlRepoMergePolicy`)
- `lib/core/providers/app_providers.dart` (`refsProvider`,
  `mergedBranchesProvider`, `branchCommitsProvider`, `repoMutationFamilies`,
  `repoScopedFetchFamilies`, `clearHashKeyedRepoCaches`,
  `binaryEnvironmentProvider`, `ConnectionState.connectionId` / `_attempt`)
- `lib/core/settings/pane_layout.dart` (`PaneId.branchesList`)
- `lib/core/settings/tool_catalog.dart` (Git min 2.24)
- `lib/core/storage/saved_connection.dart` / `saved_local_repo.dart` (stable IDs)
- `lib/features/common/resizable_master_detail.dart`
- `lib/features/common/diff_view.dart` / `split_diff_view.dart`
- `lib/features/common/context_menu.dart` / `tappable.dart`
- `lib/features/dnd/drop_registry.dart` (`_createRequestFromBranch`,
  `DropZoneId` page indices: history=1, forge=4)
- `lib/features/forge/forge_prefs.dart` (`forgeCreateSeedProvider`)
- `lib/features/github/create_pr_form.dart` / `lib/features/gitlab/create_mr_form.dart`
- `lib/features/app_shell.dart` (main `IndexedStack` + `ForgePanel` mount path)
- `lib/features/tabs/tab_ui_providers.dart` (`pageIndexProvider`,
  `visitedPagesProvider`)
- `lib/features/worktrees/worktrees_view.dart` (embedded Branches, no Forge)
- `lib/features/worktrees/add_worktree_sheet.dart` (`initialCommitish`,
  `initialBranchName`)
- `docs/0002-MADR-forge-change-request-merge-and-models.md`
