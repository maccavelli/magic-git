# Expand forge change-request (PR/MR) models and merge UX

- Status: proposed
- Date: 2026-08-02
- Deciders: Mac Smith
- Tags: forge, github, gitlab, merge, pull-request, merge-request, models, ui

Technical Story: Users need a trustworthy, feature-rich way to merge pull
requests and merge requests from Magic Git's UI — not only a thin "fire the CLI"
button. That requires richer PR/MR domain objects (mergeability, reviews, policy,
auto-merge, SHA identity) and a merge surface that matches real forge behavior
and industry desktop clients, without breaking the CLI-over-executor architecture.

## Context and Problem Statement

Magic Git is a macOS Git client that drives `git` / `gh` / `glab` on a host
(local or remote over SSH) and surfaces GitHub/GitLab forge data in the Forge
tab. Users expect to complete the full change-request lifecycle in-app: review
state, checks, merge strategy, delete-source, auto-merge, and clear failure
reasons — the same mental model as the forge web UI.

### What already exists (inventory)

Merge is **not absent** from the codebase. A basic path is wired end-to-end:

| Layer | GitHub | GitLab |
| --- | --- | --- |
| Service | `GhService.mergePullRequest` → `gh pr merge` (`--merge` / `--squash` / `--rebase`, optional `--delete-branch`) | `GlabService.mergeMergeRequest` → REST `PUT …/merge_requests/:iid/merge` (`squash`, `should_remove_source_branch`) — deliberately **not** `glab mr merge`, because that subcommand defaults `--auto-merge` to true |
| UI (detail) | Merge primary + squash/rebase pulldown; confirm chooses delete head branch | Merge primary + squash pulldown; confirm chooses delete source branch |
| UI (context menu) | Merge / Squash and merge / Rebase and merge | Merge / Squash and merge |
| Guards | Draft disables merge client-side | Draft disables merge client-side |
| Related actions | Approve, request changes, comment, edit, draft toggle, close, checkout | Approve, comment, edit, draft toggle, close, checkout |
| Create forms | Title/body/head/base, draft, reviewers, assignees, labels, milestone | Same + squash-before-merge and remove-source-on-create |
| Tests | Unit tests for merge flags on `GhService`; panel/menu wiring tests | Unit tests for REST merge fields; panel/menu wiring tests |

Models today are **list DTOs only**:

- `PullRequest` (`lib/core/github/models.dart`): `number`, `title`, `state`,
  `merged`, `draft`, `authorLogin`, `headRefName`, `baseRefName`, `url`.
- `MergeRequest` (`lib/core/gitlab/models.dart`): `iid`, `title`, `state`,
  `authorUsername`, `sourceBranch`, `targetBranch`, `webUrl`, `draft`.

List queries match that thin shape:

- GitHub: `gh pr list --json number,title,state,isDraft,headRefName,baseRefName,author,url`
- GitLab: `glab mr list --output json` (parsed into the fields above)

Detail panes show head/base (or source/target), author, coarse state, and
**associated CI jobs** (workflow run / pipeline matched by branch or MR ref).
They do **not** show forge mergeability, review decision, required approvals,
conflicts, allowed merge methods, auto-merge status, labels/assignees on the
open request, commit counts, or head SHA.

### The real gap

The product problem is not "there is no merge button." It is that merge is
**optimistic and under-informed**:

1. **No policy-aware enablement.** Only draft is gated. Conflicts, failing
   required checks, missing approvals, blocked review, or repo-disallowed merge
   methods still present a clickable Merge and fail at the forge.
2. **No SHA identity / race safety.** Neither merge path pins
   `--match-head-commit` / `sha=`. A push between view and merge can land
   unreviewed commits (forges support SHA-match precisely for this).
3. **No auto-merge / merge-when-ready.** GitHub `gh pr merge --auto` and
   GitLab merge-when-pipeline-succeeds / auto-merge are first-class web flows;
   Magic Git only does immediate merge (GitLab path intentionally).
4. **Models cannot power a rich UI.** Labels, assignees, reviewers, milestone,
   description, stats, head SHA, mergeable state, and review decision are
   missing from the open-list objects; create forms already collect richer
   metadata than list/detail can display.
5. **Asymmetric forge semantics are half-documented in code comments** but not
   modeled: GitHub offers per-PR merge methods (merge/squash/rebase); GitLab's
   project *merge method* (merge commit / semi-linear / FF) is separate from the
   per-MR squash flag; rebase on GitLab is project-level or a different action.
6. **Admin bypass, merge queues, stacked PR async merge** exist on forges and
   in newer APIs (`gh pr merge --admin`, GitHub merge-async / merge queue) but
   are out of scope of current code.

User-facing complaint ("no way to merge through the UI") may also reflect
discoverability (primary actions only on detail selection / context menu) or
a build lagging the panel wiring — but the architectural debt is clearly the
thin model and unguarded merge.

## Decision Drivers

- **Trust.** Merging must not surprise the user: show why merge is blocked, what
  strategy is allowed, and what will happen to the source branch.
- **Correctness under concurrency.** Pin head SHA; revalidate before mutate;
  surface forge errors without data loss.
- **Feature parity with forge web + mature desktop clients** (GitHub Desktop,
  JetBrains, Magit/Forge, GitKraken, Tower) for the *merge decision surface*,
  not a full code-review clone.
- **Architecture fit.** Keep `CommandExecutor` + `GhService` / `GlabService`;
  parse machine formats only (`gh --json`, `glab --output json` / `glab api`);
  no tokens in argv; work on remote hosts the same as local.
- **List vs detail cost.** Open-list stays snappy; expensive mergeability and
  review graphs load on selection (or via a bounded enrich pass).
- **Forge asymmetry.** Prefer shared *concepts* (change request, merge plan)
  with forge-specific *fields and commands*, not a lowest-common-denominator
  that erases GitLab/GitHub differences.
- **Safety of mutations.** Confirm dialogs already exist; expand them with
  strategy, message options, delete-source, auto-merge — never silent defaults
  that enable auto-merge without intent (the reason GitLab avoids `glab mr merge`).

## Industry use cases and patterns (external)

Synthesized from GitHub/GitLab docs and common client practice:

### Merge strategies

- **GitHub:** three user-selectable methods when the repo allows them — merge
  commit, squash, rebase. Repo settings (`allow_merge_commit`,
  `allow_squash_merge`, `allow_rebase_merge`) and branch protection constrain
  the UI. Clients disable methods the API/repo forbid rather than offering all
  three always.
- **GitLab:** project-level merge method (merge commit, merge commit with
  semi-linear history, fast-forward) plus independent squash policy (do not
  allow / allow / encourage / require). Per-merge knobs are primarily
  squash + delete source branch; rebase is not the same control as GitHub's
  "Rebase and merge" menu item.

### Mergeability and checks

- **GitHub REST get-PR:** `mergeable` (bool|null while computing),
  `mergeable_state` (`clean` / `dirty` / `blocked` / `unstable` / `behind` /
  `has_hooks` / `unknown` / …), `rebaseable`, `draft`, `auto_merge`, head/base
  SHAs. GraphQL/`gh pr view --json` adds `reviewDecision`, status check rollups,
  `statusCheckRollup`, etc.
- **GitLab:** prefer `detailed_merge_status` over deprecated `merge_status`
  (values such as `mergeable`, `conflict`, `discussions_not_resolved`,
  `not_approved`, `ci_must_pass`, `ci_still_running`, `draft_status`,
  `need_rebase`, …). `has_conflicts`, `merge_when_pipeline_succeeds`, head
  `sha`. List endpoints may not eagerly recompute mergeability — single-MR
  GET is the reliable source after selection.

### Safety and automation

- **SHA pin:** GitHub merge body `sha` / `gh pr merge --match-head-commit`;
  GitLab merge `sha` / `glab mr merge --sha`. Industry best practice: merge
  only the commit the user reviewed.
- **Auto-merge:** GitHub `--auto` (enable merge when requirements met);
  GitLab MWPS / auto-merge. Distinct from immediate merge; UI must label them
  differently.
- **Admin / bypass:** GitHub `--admin` for privileged override of requirements;
  rare, destructive, should be secondary and clearly labeled.
- **Merge queues / stacked PRs:** GitHub merge queue and async merge APIs;
  out of scope for a first robust slice, but model fields should not preclude
  later enqueue state.
- **Delete source branch:** Universal web checkbox; Magic Git already offers
  this as the confirm dialog's secondary action — keep and prefer defaults
  from project settings when known.
- **Commit message control:** squash/merge commit title and body customization
  is a frequent power-user need (`gh pr merge -t/-b`, GitLab squash/merge
  message fields).

### Client UX patterns worth adopting

1. **Merge readiness panel** on detail: green path vs blocked reasons (checks,
   reviews, conflicts, draft, behind base).
2. **Strategy chooser constrained by repo policy** (not a static three-way menu).
3. **Primary = smart default** (often squash if encouraged; else last-used;
   else forge default), with explicit variants in a split button.
4. **Auto-merge as a separate primary when checks are still running**, not
   hidden behind the same button as immediate merge.
5. **Update branch / rebase onto target** when behind or need_rebase, before
   merge is offered.
6. **Post-merge cleanup** (local branch delete, fetch, invalidate lists) —
   partial today via invalidate + clear selection; no local ref cleanup beyond
   `gh pr merge --delete-branch` when chosen.

## Considered Options

### A. Status quo — thin list DTO + immediate merge only

Keep current models and merge wiring. Document discoverability only.

- Pros: zero work; path already tested.
- Cons: fails trust and parity goals; merge remains a remote roulette; models
  stay too thin for any serious forge work.

### B. UI-only harden — gate Merge on locally fused CI + draft

Disable merge when the panel's associated workflow run / pipeline is failing or
running; still no forge mergeability, reviews, SHA pin, or auto-merge.

- Pros: small change.
- Cons: wrong for repos without CI, wrong for required reviews without CI, and
  wrong when CI is green but approvals or discussions block merge. Symptom fix.

### C. Enrich models + policy-aware merge plan (recommended)

Expand PR/MR domain objects (list enrichment + detail payload), introduce a
forge-agnostic **merge plan** value type computed from those fields, and drive
the merge button, confirm dialog, and auto-merge from that plan. Extend service
methods for SHA pin, auto-merge, optional admin, commit messages, and
update-branch / need-rebase actions. Keep dual forge services behind the
executor seam.

- Pros: root-cause model; matches forge truth; scales to future features;
  preserves architecture.
- Cons: more design work; careful list/detail split to protect latency.

### D. Full in-app code review product

Inline diff review threads, suggestion commits, CODEOWNERS visualization, merge
queue management UI.

- Pros: maximum richness.
- Cons: multi-release scope; orthogonal to making merge safe and model-complete.
  Defer.

## Decision Outcome

**Chosen direction: Option C** — expand change-request models and implement a
policy-aware merge surface on top of existing `GhService` / `GlabService`
mutation paths.

Status remains **proposed** until implementation of plan phases 1–2 lands.
The companion plan locks field lists, providers, tests, and phase exits:

- `docs/0002-PLAN-forge-change-request-merge-and-models.md`

This MADR records feasibility and the preferred architecture so implementation
does not re-litigate "wire a button" vs "model the forge."

### Feasibility assessment

| Concern | Verdict |
| --- | --- |
| Immediate merge via CLI/API | **Already done** and unit-tested |
| Richer list/detail JSON from `gh` / `glab` | **High** — field lists are the main work; parsers already use shared forge JSON helpers |
| GitHub mergeability + reviewDecision | **High** via `gh pr view --json` / list field expansion; mergeable may be null until computed (poll/retry on detail) |
| GitLab `detailed_merge_status` | **High** via `glab mr view` or REST GET single MR; list may be stale — detail fetch required |
| SHA-pinned merge | **High** — flags exist on both CLIs/APIs; thread head SHA from model into merge call |
| Auto-merge | **Medium-High** — GitHub `gh pr merge --auto` / `--disable-auto`; GitLab needs careful API (avoid accidental auto-merge default of `glab mr merge`; prefer explicit REST/GraphQL fields already used for immediate merge) |
| Repo allowed merge methods | **Medium** — extra repo settings fetch (GitHub repo fields / GitLab project merge method + squash option); cache per repo |
| Admin bypass | **High** plumbing, **product** caution — secondary action only |
| Merge queue / stacked async merge | **Defer** — API exists; model optional `enqueueState` later |
| Shared UI across forges | **High** — panels already parallel (`github_panel` / `gitlab_panel` + shared forge widgets); extract merge readiness + confirm into shared widgets fed by a merge plan |
| Remote SSH host | **No extra risk** — all calls already go through `CommandExecutor` |
| Performance | **Manageable** — keep list light; enrich on select; optional batch GraphQL later |

**Overall: technically feasible at high confidence.** The architecture already
chose the right seams (executor, forge services, panel actions). The missing
piece is domain richness and a merge decision model, not a new transport.

### Target model shape (normative sketch)

Keep forge-specific classes (vocabulary differs: number vs iid, head/base vs
source/target). Add fields in layers:

**List-tier (cheap, every open PR/MR row):**

- Existing identity + draft + branches + author + url
- Labels (names/colors), assignees (logins), optional milestone title
- Coarse pipeline/CI association remains UI fusion (already done)
- Optional: `reviewDecision` / approval summary if available without N+1

**Detail-tier (on selection, single GET/view):**

- Description/body
- Head SHA (required for pin)
- Mergeability: GitHub `mergeable` + `mergeable_state`; GitLab
  `detailed_merge_status` + `has_conflicts`
- Review/approval summary (counts, decision, whether viewer has approved)
- Auto-merge enabled + method
- Commit/file stats when cheap
- User permissions if exposed (can merge / can update)

**Repo policy cache (per connection+repo, longer TTL):**

- Allowed merge methods / squash policy / default delete-source / auto-merge
  allowed

**Merge plan (computed, UI-facing, forge-agnostic):**

```text
MergePlan {
  canMergeNow: bool
  canEnableAutoMerge: bool
  blockedReasons: List<String>   // human, stable codes optional
  allowedMethods: List<MergeMethod>
  defaultMethod: MergeMethod
  defaultDeleteSource: bool
  headSha: String?
  requiresShaPin: true           // always pin when headSha known
  supportsAdminBypass: bool      // GitHub
}
```

UI rules: primary button enabled only if `canMergeNow` or `canEnableAutoMerge`;
tooltip/banner lists `blockedReasons`; method pulldown only shows
`allowedMethods`.

### Service API extensions (sketch)

- `mergePullRequest(..., { method, deleteBranch, matchHeadCommit, auto, admin,
  subject, body })`
- `mergeMergeRequest(..., { squash, removeSourceBranch, sha, mergeWhenPipelineSucceeds,
  squashMessage, mergeCommitMessage })` — keep REST immediate-merge path; add
  explicit auto-merge endpoint/fields separately so defaults never surprise
- `pullRequestDetail` / `mergeRequestDetail` (or expand list JSON + detail
  provider)
- `updatePullRequestBranch` / GitLab rebase-or-update equivalent when behind
- Optional later: `disableAutoMerge`, merge-queue enqueue

### Phased delivery (for the companion PLAN)

1. **Model expansion + detail provider** — fields, parsers, tests; detail
   lines show merge status / review / SHA.
2. **SHA-pinned merge + blocked reasons** — wire `MergePlan`; disable with
   explanations; pin SHA always when known.
3. **Strategy + policy** — repo allowed methods; commit message fields for
   squash/merge; smarter confirm dialog.
4. **Auto-merge** — distinct action when checks/approvals pending but otherwise
   eligible.
5. **Branch update / need_rebase flows** — unstick "behind" and GitLab
   need_rebase before merge.
6. **Polish** — admin bypass (hidden), post-merge local cleanup, inbox
   "ready to merge" filter, keyboard shortcut parity.

Phase 1–2 alone close the trust gap. Phases 3–5 are the feature-rich bar.

### What we will not do in this initiative

- Replace `gh`/`glab` with direct HTTPS forge SDKs from the Mac app (would
  break remote-host auth and the executor thesis).
- Build full review-thread editing as a prerequisite for merge.
- Force a single shared `ChangeRequest` class that erases forge field names
  (shared *widgets* and *MergePlan* yes; shared wire model no — same pattern as
  issues after the forge_dashboard extraction).
- Call `glab mr merge` without disabling its auto-merge default.

## Consequences

### Positive

- Merge becomes a first-class, explainable action aligned with forge policy.
- PR/MR objects grow into a foundation for filters, inbox rules, branch
  annotations, and future review features.
- SHA pinning removes a real class of "merged the wrong tip" incidents.
- Auto-merge stops being a footgun only because it was omitted; it becomes an
  intentional, labeled path.
- Architecture stays CLI-over-executor; remote and local backends keep working
  unchanged.

### Negative / costs

- More JSON fields and parsers to keep green across `gh`/`glab` versions and
  self-hosted GitLab skew (`detailed_merge_status` age, draft field aliases
  already handled).
- Detail selection incurs an extra forge round-trip (acceptable; document and
  cache).
- UI complexity: blocked-state copy must stay accurate or trust erodes worse
  than a dumb button.
- Tests grow: model fixtures, merge-plan matrix, service flag assembly; live
  forge tests remain opt-in (`live-forge` tag) only when explicitly requested.

### Neutral

- Dual panels remain; shared extraction is opportunistic (merge readiness
  widget, confirm content) rather than a forced panel rewrite.
- Create forms already collect richer metadata — detail display will finally
  match create.

## Confirmation

This decision is confirmed when:

1. A companion `0002-PLAN-forge-change-request-merge-and-models.md` (same number)
   sequences the phases above with concrete field lists and provider names.
2. Implementation lands model fields + `MergePlan`-driven enablement + SHA pin
   before any new "feature" merge variants (admin, queue).
3. `flutter analyze` / `flutter test` stay green; new unit tests cover parsers
   and merge argv/REST field assembly for both forges.
4. Manual smoke on GitHub and GitLab (including a blocked MR/PR and a clean one)
   shows correct disable reasons and successful pinned merge.

## Links

### Internal

- `lib/core/github/models.dart` — `PullRequest`
- `lib/core/gitlab/models.dart` — `MergeRequest`
- `lib/core/github/gh_service.dart` — `pullRequests`, `mergePullRequest`, reviews
- `lib/core/gitlab/glab_service.dart` — `mergeRequests`, `mergeMergeRequest`
- `lib/features/github/github_panel.dart` — merge UI + confirm
- `lib/features/gitlab/gitlab_panel.dart` — merge UI + confirm
- `lib/features/forge/` — shared list/detail chrome, inbox
- `docs/0001-MADR-native-git-libgit2.md` — CLI/executor architecture retained
- `docs/ACTION_PLAN.md` — historical note on Approve/Merge double-submit safety

### External (API / product references)

- GitHub REST: pull requests, merge, merge-async / merge queue parameters
- GitHub CLI: `gh pr merge` (`--auto`, `--admin`, `--match-head-commit`,
  method flags, delete-branch, subject/body)
- GitLab REST: merge requests, `detailed_merge_status`, merge action fields
  (`sha`, `squash`, `should_remove_source_branch`, merge-when-pipeline-succeeds)
- GitLab merge methods and squash project settings
- GitLab CLI: `glab mr merge` (auto-merge default true — avoid as sole path)
)
