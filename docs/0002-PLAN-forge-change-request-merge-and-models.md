# Implementation plan: forge change-request models and merge UX

- Status: implemented **for Phases 0–5**. Phase 6 (labelled "opportunistic")
  is partial — admin bypass, the merge keyboard shortcut and the post-merge
  refs refresh shipped, but list-row chips, the Inbox ready filter and the
  description preview did not. Verified 2026-08-14 by
  [0007-MADR-docs-completion-audit.md](0007-MADR-docs-completion-audit.md);
  remediation in its companion plan, steps 3.1–3.4.
- Date: 2026-08-02
- MADR: `docs/0002-MADR-forge-change-request-merge-and-models.md` (Option C)
- Owner: implementation agent + maintainer review

This plan turns MADR 0002 into executable work. It is grounded in the tree as of
2026-08-02 (master). Numbers in parentheses are approximate order-of-work
sizing for one implementer familiar with the forge panels.

---

## 0. MADR assessment (review findings)

### What the MADR gets right

| Claim | Codebase fact |
| --- | --- |
| Merge is already wired, not missing | `GhService.mergePullRequest` → `gh pr merge`; `GlabService.mergeMergeRequest` → REST `PUT …/merge`; UI in `github_panel.dart` / `gitlab_panel.dart` (detail Merge + strategy pulldown + context menu + `chooseAction` delete-source confirm). Covered by `github_panel_test`, `gitlab_panel_test`, `forge_context_menu_test`, `gh_service_test`, `glab_service_test`, `mutations_test`. |
| Models are list DTOs | `PullRequest` / `MergeRequest` carry identity + draft + branches + author + url only (`lib/core/github/models.dart`, `lib/core/gitlab/models.dart`). |
| List queries match thin models | `gh pr list --json number,title,state,isDraft,headRefName,baseRefName,author,url`; `glab mr list --output json` parsed into the same thin shape. |
| Only draft gates merge client-side | `_mergeButton` / menus: `enabled: !pr.draft` / `!mr.draft`. |
| No SHA pin | Merge call sites pass method + delete/remove only. |
| GitLab avoids `glab mr merge` for good reason | Comment on `mergeMergeRequest`: subcommand defaults auto-merge true. |
| Architecture must stay CLI-over-executor | Same as MADR 0001; services already ride `CommandExecutor` + `ExecLane.sync` for mutations. |
| Shared detail chrome exists | `ForgeDetailScaffold`, `InFlightPushButton`, `DetailLine` in `lib/features/forge/forge_widgets.dart`. |
| Lazy detail pattern already exists for issues | `issueDetailProvider` + `GhService.issueDetail` / `GlabService.issueDetail` — the correct template for PR/MR detail. |

### Corrections / refinements to the MADR sketch

1. **Do not invent a parallel “fields” vs “detail” stack.**  
   Today edit uses `pullRequestFields` / `mergeRequestFields` (`gh pr view --json title,body` / `glab mr view --output json`). Expand these into full **detail** methods (or have fields call detail) so selection and Edit share one fetch.

2. **GitHub wire names from `gh --json` are GraphQL-flavored**, not pure REST:  
   `mergeStateStatus`, `headRefOid`, `autoMergeRequest`, `isDraft`, `reviewDecision`, `statusCheckRollup` — not REST’s `mergeable_state` / `head.sha`. The MADR’s REST vocabulary is fine for GitLab; GitHub parsers must use `gh` field names.

3. **`mergeable` on list is unreliable.** Treat full mergeability as **detail-tier only**. List may add cheap signals (`reviewDecision`, labels, assignees) without `mergeable`.

4. **`chooseAction` is too narrow for phase-3 commit-message editing.**  
   It supports primary + secondary label pairs only (`lib/features/common/actions.dart`). Keep it for phase-2 delete-source; introduce a dedicated **merge options sheet** when adding subject/body/squash-message.

5. **Optional named params keep fakes compiling**, but widget tests that assert exact merge call tuples must be updated when signatures grow (`matchHeadCommit`, `auto`, etc.).

6. **New providers must join `repoScopedFetchFamilies`** in `app_providers.dart` (and any mutation-refresh lists that should drop stale detail after merge/close).

7. **Const model constructors** are used widely in tests (`const PullRequest(...)`). New fields need defaults so existing `const` call sites keep compiling.

8. **Branch forge fusion** (`branch_forge_status.dart`) only needs list identity; list enrichment is additive and must not change `headRefName` / `sourceBranch` matching.

### Gaps the MADR under-specifies (this plan fills)

- Exact field lists and wire mapping tables.
- Provider family keys and invalidation rules.
- MergePlan pure-function location and unit-test matrix.
- How detail handles `mergeable == null` (GitHub still computing).
- GitLab squash *policy* vs per-merge squash boolean.
- Test file checklist and fake override churn.
- Explicit non-goals per phase and exit criteria.
- Suggested PR/commit boundaries (maintainer commits; agents do not).

### Verdict on MADR Option C

**Accept and implement.** Feasibility remains high. The plan below is Option C
decomposed into six phases. **Ship criteria for “merge is trustworthy” = end of
Phase 2.** Phases 3–5 are the feature-rich bar; Phase 6 is polish.

---

## 1. Goals and non-goals

### Goals

1. **Trustworthy merge:** user sees *why* merge is allowed or blocked; merge pins the reviewed head SHA when known.
2. **Richer PR/MR objects:** list shows collaboration metadata; detail shows mergeability, review, auto-merge, SHA, body summary.
3. **Policy-aware strategy UI:** only offer methods the forge/repo allows (when policy is known; degrade gracefully when unknown).
4. **Explicit auto-merge** as a separate action from immediate merge (both forges).
5. **Parity of UX chrome** across GitHub/GitLab panels without erasing forge vocabulary.
6. **Analyzer-clean + unit-tested** on every phase; no `live-forge` runs unless maintainer asks.

### Non-goals (entire initiative)

- Full inline code review (threads, suggestions, CODEOWNERS graph).
- GitHub merge queue / stacked PR async merge UI (leave model hooks only if free).
- Direct HTTPS forge SDKs from the Mac process (tokens stay on host via `gh`/`glab`).
- Unifying `PullRequest` and `MergeRequest` into one wire class.
- Using bare `glab mr merge` without neutralizing its auto-merge default.
- Changing local `git merge` branch operations in Branches/History tabs.

---

## 2. Current architecture (grounding map)

```text
UI
  lib/features/github/github_panel.dart
  lib/features/gitlab/gitlab_panel.dart
  lib/features/forge/forge_widgets.dart   # ForgeDetailScaffold, actions
  lib/features/forge/forge_inbox.dart
  lib/core/forge/branch_forge_status.dart # list fusion → Branches tab

Providers (app_providers.dart)
  pullRequestsProvider(repoPath)  → GhService.pullRequests
  mergeRequestsProvider(repoPath) → GlabService.mergeRequests
  issueDetailProvider((repo, id)) → template for CR detail
  repoScopedFetchFamilies         → must list new families

Services
  lib/core/github/gh_service.dart
  lib/core/gitlab/glab_service.dart

Models
  lib/core/github/models.dart  # PullRequest, WorkflowRun, GhJob
  lib/core/gitlab/models.dart  # MergeRequest, Pipeline, Job

Shared JSON
  lib/core/forge/forge_json.dart

Actions
  lib/features/common/actions.dart  # runAction, confirmAction, chooseAction
```

### Existing merge UX contract (preserve unless phase says otherwise)

| Step | Behavior |
| --- | --- |
| Entry | Detail Merge button, strategy pulldown, context-menu merge variants |
| Guard today | Draft → disabled + tooltip |
| Confirm | `chooseAction`: primary = merge keep branch; secondary = merge & delete source/head |
| In-flight | `_mergingPrs` / `_mergingMrs` + ProgressCircle; guard after dialog resolves |
| Success | Clear selection; invalidate list provider |
| Failure | `runAction` → error dialog |

---

## 3. Target design (normative)

### 3.1 Domain types

#### Keep forge-specific list/detail models

**Do not** merge PR/MR into one class. Add optional fields with safe defaults.

#### List-tier fields (cheap)

**GitHub `PullRequest`** — expand `gh pr list --json` to:

```text
number,title,state,isDraft,headRefName,baseRefName,author,url,
labels,assignees,reviewDecision,milestone
```

Parse into (new/optional):

| Field | Type | Notes |
| --- | --- | --- |
| `labels` | `List<ForgeLabel>` or small `{name,color}` | Reuse dashboard label shape if cheap |
| `assigneeLogins` | `List<String>` | |
| `reviewDecision` | `String?` | `APPROVED` / `CHANGES_REQUESTED` / `REVIEW_REQUIRED` / empty |
| `milestoneTitle` | `String?` | |

**GitLab `MergeRequest`** — `glab mr list --output json` already returns a fat
REST object; **parse more of what is already there** (verify with a fixture from
a real list payload in tests):

| Field | Wire keys (typical) | Notes |
| --- | --- | --- |
| `labels` | `labels` (strings or objects) | Normalize to names |
| `assigneeUsernames` | `assignees[]` / `assignee` | |
| `detailedMergeStatus` | `detailed_merge_status` | May be stale/empty on list |
| `hasConflicts` | `has_conflicts` | |
| `sha` | `sha` | Often present on list |
| `mergeWhenPipelineSucceeds` | `merge_when_pipeline_succeeds` | |
| `userNotesCount` etc. | optional later | |

If list omits `detailed_merge_status` on older GitLab, leave null — detail fills in.

#### Detail-tier types

Prefer **one expanded model instance** rather than a second class, with nullable
detail-only fields left null on list rows:

**GitHub detail** (`gh pr view N --json …`):

```text
# identity + list fields, plus:
body, headRefOid, baseRefOid, mergeable, mergeStateStatus,
autoMergeRequest, reviewDecision, reviewRequests, latestReviews,
statusCheckRollup, additions, deletions, changedFiles, commits,
maintainerCanModify, isCrossRepository
```

Map:

| Model field | `gh` JSON |
| --- | --- |
| `body` | `body` |
| `headOid` | `headRefOid` |
| `baseOid` | `baseRefOid` |
| `mergeable` | `mergeable` (`MERGEABLE` / `CONFLICTING` / `UNKNOWN` string from gh GraphQL — normalize) |
| `mergeStateStatus` | `mergeStateStatus` |
| `autoMergeEnabled` | `autoMergeRequest != null` |
| `autoMergeMethod` | from `autoMergeRequest` if present |
| stats | `additions`, `deletions`, `changedFiles` |

**Important:** `gh`’s `mergeable` enum differs from REST bool. Normalize in
`fromJson` to a small app enum, e.g.:

```dart
enum GhMergeable { mergeable, conflicting, unknown }
```

**GitLab detail** — expand use of `glab mr view IID --output json` (already used
for edit). Confirm fields (fixture-driven):

```text
description, sha, detailed_merge_status, has_conflicts,
merge_when_pipeline_succeeds, squash, squash_on_merge,
should_remove_source_branch, user.can_merge (if present),
pipeline / head_pipeline summary if embedded,
approvals if present in view payload OR separate approvals API if not
```

If approvals are not on `mr view`, add optional:

```text
GET projects/:id/merge_requests/:iid/approvals
```

via existing `GlabService.api` (second hop on detail only).

#### Repo policy cache

New types (forge-specific or one sealed class):

```dart
class GhRepoMergePolicy {
  final bool allowMergeCommit;
  final bool allowSquashMerge;
  final bool allowRebaseMerge;
  final bool allowAutoMerge;
  final bool deleteBranchOnMerge; // default preference
}

class GlRepoMergePolicy {
  final String mergeMethod; // merge | rebase_merge | ff
  final String squashOption; // never | allowed | encouraged | always
  final bool removeSourceBranchAfterMerge; // project default if available
  final bool autoMergeEnabled; // project feature if exposed
}
```

Fetch:

- GitHub: `gh api repos/{owner}/{repo}` fields  
  `allow_merge_commit,allow_squash_merge,allow_rebase_merge,allow_auto_merge,delete_branch_on_merge`
- GitLab: `glab api projects/:id` fields  
  `merge_method,squash_option,remove_source_branch_after_merge,…`

Provider: `repoMergePolicyProvider(repoPath)` — `FutureProvider.autoDispose.family`,
long-lived enough for session (autoDispose with panel is fine; cheap on remount).

#### MergePlan (shared pure logic)

**New file:** `lib/core/forge/merge_plan.dart`

```dart
enum MergeMethod { mergeCommit, squash, rebase }

class MergeBlockedReason {
  final String code;    // stable: draft, conflicts, review, ci, behind, …
  final String message; // human
}

class MergePlan {
  final bool canMergeNow;
  final bool canEnableAutoMerge;
  final List<MergeBlockedReason> blockedReasons;
  final List<MergeMethod> allowedMethods;
  final MergeMethod defaultMethod;
  final bool defaultDeleteSource;
  final String? headSha;
  final bool pinHeadSha; // true when headSha non-null/non-empty
  final bool supportsAdminBypass; // GitHub only
  final bool autoMergeAlreadyEnabled;
}
```

**Builders (pure, unit-tested):**

- `MergePlan forGitHub({required PullRequest pr, GhRepoMergePolicy? policy})`
- `MergePlan forGitLab({required MergeRequest mr, GlRepoMergePolicy? policy})`

Rules (initial, adjustable with fixtures):

| Condition | Effect |
| --- | --- |
| draft | block now; no auto-merge |
| GitHub `mergeable == conflicting` / GitLab conflicts / `detailed_merge_status == conflict` | block now |
| GitHub `mergeStateStatus` dirty/blocked/behind (map carefully) | block or “update branch” path |
| GitLab `not_approved`, `discussions_not_resolved`, `ci_must_pass`, `ci_still_running`, `need_rebase`, `draft_status`, … | map each to blocked reason; `ci_still_running` may allow **auto-merge only** |
| GitHub `reviewDecision == CHANGES_REQUESTED` | block now |
| GitHub `reviewDecision == REVIEW_REQUIRED` | block now (unless policy unknown and we choose soft-fail — prefer block when signal present) |
| `mergeable == unknown` / status checking | block now with “mergeability still computing” + UI retry |
| policy forbids method | omit from `allowedMethods` |
| policy null | allow forge defaults (GH: all three; GL: merge + squash if not never) |
| auto-merge already on | `canMergeNow` false for duplicate enable; show cancel-auto if phase 4 |

**Default method:**

- GitHub: prefer squash if allowed and team norm unknown; else merge commit; never pick disallowed.
- GitLab: if `squash_option` is `always`/`encourage` → squash true as default *flag*; method is project merge method (not user rebase menu).

### 3.2 Service API

#### GitHub (`gh_service.dart`)

```dart
// List: expand --json field list (see above)

Future<PullRequest> pullRequestDetail(String repoPath, int number);

// Replace or implement pullRequestFields via detail:
Future<({String title, String body})> pullRequestFields(...) async {
  final d = await pullRequestDetail(...);
  return (title: d.title, body: d.body ?? '');
}

Future<GhRepoMergePolicy> repoMergePolicy(String repoPath);

Future<void> mergePullRequest(
  String repoPath,
  int number, {
  String method = 'merge',
  bool deleteBranch = false,
  String? matchHeadCommit, // --match-head-commit
  bool auto = false,       // --auto
  bool disableAuto = false,// --disable-auto
  bool admin = false,      // --admin (phase 6)
  String? subject,         // -t
  String? body,            // -b
});

Future<void> updatePullRequestBranch(String repoPath, int number); // gh api / update-branch
```

`mergePullRequest` must remain non-interactive: always pass a method flag
(already does). When `auto: true`, still pass method if `gh` requires it.

#### GitLab (`glab_service.dart`)

```dart
// List: parse more fields from existing JSON

Future<MergeRequest> mergeRequestDetail(String repoPath, int iid);
// Prefer glab mr view --output json; fall back/enrich with
// GET projects/:id/merge_requests/:iid if view lacks detailed_merge_status.

Future<GlRepoMergePolicy> repoMergePolicy(String repoPath);

Future<void> mergeMergeRequest(
  String repoPath,
  int iid, {
  bool squash = false,
  bool removeSourceBranch = false,
  String? sha, // fields: sha=
  String? squashMessage,
  String? mergeCommitMessage,
});

/// Explicit auto-merge enable — NEVER silent.
/// Implementation: REST/GraphQL path that sets merge_when_pipeline_succeeds
/// or modern auto_merge without using glab mr merge's true default blindly.
/// Preferred: PUT merge with merge_when_pipeline_succeeds=true when pipeline
/// running; or documented glab flags with --auto-merge=true AND --yes only
/// after product intent is clear. Record chosen path in code comment + tests.
Future<void> enableMergeRequestAutoMerge(
  String repoPath,
  int iid, {
  String? sha,
  bool squash = false,
  bool removeSourceBranch = false,
});

Future<void> cancelMergeRequestAutoMerge(...); // if API available

Future<void> rebaseMergeRequest(String repoPath, int iid); // when need_rebase
```

### 3.3 Providers

| Provider | Key | Implementation |
| --- | --- | --- |
| `pullRequestsProvider` | `repoPath` | unchanged shape; richer list |
| `mergeRequestsProvider` | `repoPath` | unchanged shape; richer list |
| `pullRequestDetailProvider` | `(repoPath, number)` | `gh.pullRequestDetail` + `_forgeAuthReady` |
| `mergeRequestDetailProvider` | `(repoPath, iid)` | `glab.mergeRequestDetail` + auth |
| `repoMergePolicyProvider` | `repoPath` | switch on `forgeProvider` |

Add both detail providers + policy to **`repoScopedFetchFamilies`**.

Invalidation after successful merge/close/draft/edit:

```dart
ref.invalidate(pullRequestsProvider(repoPath));
ref.invalidate(pullRequestDetailProvider((repoPath, number)));
// same pattern for GitLab
```

Optional: invalidate `repoMergePolicyProvider` only on rare settings changes (not every merge).

### 3.4 UI

#### Detail header lines (both panels)

Keep existing Head/Base (Source/Target), Author, State; add when detail loaded:

- Merge status (human from MergePlan / detailed status)
- Review decision / approvals
- Head SHA (short)
- Auto-merge badge if enabled
- Labels + assignees chips (list or detail)

While detail loading: show list-tier data immediately; skeleton or “Checking mergeability…” for status line.

#### Merge readiness strip

Shared widget: `lib/features/forge/merge_readiness.dart`

- Green check + “Ready to merge” when `canMergeNow`
- Amber list of `blockedReasons` when not
- If `canEnableAutoMerge`: secondary button “Enable auto-merge”

#### Merge button behavior

| Plan state | Primary control |
| --- | --- |
| `canMergeNow` | Merge (default method) + method pulldown of `allowedMethods` |
| `canEnableAutoMerge` only | “Enable auto-merge” (or dual) |
| blocked | Disabled Merge + tooltip = first reasons; strip shows all |
| draft | Keep current draft tooltip (also in blockedReasons) |

#### Confirm dialog

- **Phase 2:** keep `chooseAction` delete-source pattern; include method verb + short SHA in message (`Merge #7 (abc1234) into main?`).
- **Phase 3:** custom sheet: method, delete source checkbox (default from plan), optional commit subject/body.

#### Context menus

Mirror enablement: disabled merge items when plan says blocked (need detail for full accuracy).  
**Problem:** context menu on list row may not have detail yet.

**Resolution:**

- **Phase 2a:** context menu keeps draft-only disable; detail pane is policy-aware (best effort).
- **Phase 2b (preferred same phase):** on menu open or on row select, ensure detail is warming (`ref.read(detailProvider.future)`); menu actions that merge `await` detail first and re-check plan before confirm. Slight latency on first merge-from-menu; correct.

#### Post-merge

- Clear selection (existing).
- Invalidate list + detail.
- If deleteBranch: `gh` already deletes local+remote head; invalidate `refsProvider` / call existing refresh helpers if panel has access (`refreshAfterMutation` only for git mutations — check whether forge merges should also refresh refs). **Yes when deleteBranch/removeSource:** invalidate `refsProvider(repoPath)` and `mergedBranchesProvider` so Branches tab updates.

### 3.5 Discoverability (addresses “no merge in UI” perception)

- Ensure Merge remains in the pinned action bar (already).
- When plan is ready, use stronger primary styling (already primary button).
- Inbox: optional “Ready to merge” filter in phase 6 using list signals + detail cache.
- Keyboard: if forge panel has action map hooks, add `forge.merge` only if keymap pattern already exists for approve (check `panel_shortcuts` / keymap — only add if low-cost).

---

## 4. Phased implementation

Each phase is independently reviewable: **analyze + test green**, behavior
demoable. Do not start phase N+1 until phase N exit criteria pass.

---

### Phase 0 — Fixtures and inventory (0.5 day)

**Purpose:** lock wire shapes before parsers invent fiction.

Tasks:

1. Capture anonymized JSON fixtures (committed under `test/fixtures/forge/`):
   - `gh_pr_list_item.json`, `gh_pr_view_mergeable.json`, `gh_pr_view_blocked.json`
   - `glab_mr_list_item.json`, `glab_mr_view_mergeable.json`, `glab_mr_view_conflict.json`
   - `gh_repo_merge_policy.json`, `glab_project_merge_policy.json`
2. Document in fixture headers which CLI version produced them.
3. Note GitLab self-hosted skew: if `detailed_merge_status` missing, parser falls back to `merge_status` / `has_conflicts`.

**Exit:** fixtures reviewed; no product code required.

---

### Phase 1 — Model + service list/detail expansion (1.5–2.5 days)

**Purpose:** data plane only; UI may still use old lines.

#### 1.1 Models

Files:

- `lib/core/github/models.dart`
- `lib/core/gitlab/models.dart`
- Optionally small shared label/assignee helpers in `lib/core/forge/` if duplication hurts

Requirements:

- All new fields optional with defaults → existing `const` test constructors compile.
- `fromJson` remains tolerant (missing → null/empty), matching current style.
- Normalize GitHub `mergeable` string enums and GitLab draft legacy fields.

#### 1.2 Services

- Expand `pullRequests` JSON field list.
- Expand `MergeRequest.fromJson` to read extra list keys (list command may already emit them).
- Add `pullRequestDetail` / `mergeRequestDetail`.
- Route `pullRequestFields` / `mergeRequestFields` through detail (or shared private parse).
- Unit tests: argv/field lists, parsing fixtures, empty/malformed.

#### 1.3 Providers

- Add `pullRequestDetailProvider`, `mergeRequestDetailProvider`.
- Register in `repoScopedFetchFamilies`.
- No panel UI required yet (or minimal: watch detail when selected and ignore).

#### 1.4 Tests

| File | Changes |
| --- | --- |
| `test/github_models_test.dart` | new fields, mergeable enum, labels |
| `test/gitlab_models_test.dart` | detailed_merge_status, sha, conflicts |
| `test/gh_service_test.dart` | list fields string; detail method |
| `test/glab_service_test.dart` | detail method; list parse |
| Fakes in panel tests | still compile |

**Exit criteria:**

- [ ] `flutter analyze` clean
- [ ] `flutter test test/github_models_test.dart test/gitlab_models_test.dart test/gh_service_test.dart test/glab_service_test.dart` green
- [ ] List providers still return open items only
- [ ] Detail method returns head SHA on fixture

---

### Phase 2 — MergePlan + SHA pin + policy-aware enablement (2–3 days)

**Purpose:** trustworthy merge. **This is the minimum shippable “done” for the original product complaint.**

#### 2.1 MergePlan

- New: `lib/core/forge/merge_plan.dart`
- New: `test/merge_plan_test.dart` — matrix of draft/conflict/review/ci/unknown/ready for both forges

#### 2.2 Service merge flags

- `mergePullRequest`: add `matchHeadCommit`, wire `--match-head-commit` when non-null.
- `mergeMergeRequest`: add `sha`, wire `sha=` field when non-null.
- Tests assert argv / `-f` fields.

#### 2.3 Panel integration

Both panels:

1. When selection is change-request, `ref.watch(detailProvider((repo, id)))`.
2. Build `MergePlan` from detail (fallback: list row + draft-only plan if detail error).
3. `_mergeButton` / menus use plan for enablement + method list.
4. `_merge(...)` always passes `matchHeadCommit` / `sha` from plan when `pinHeadSha`.
5. Confirm message includes short SHA when present.
6. Readiness strip above checks or under DetailLines.
7. On detail `mergeable == unknown` / checking: show retry control that invalidates detail provider.

#### 2.4 Context menu

- Before merge action runs: await detail; recompute plan; if blocked, show error dialog with reasons (do not open confirm).

#### 2.5 Invalidation

- After merge success: invalidate list + detail + if delete source then `refsProvider` (+ `mergedBranchesProvider` if cheap).

#### 2.6 Tests

| File | Changes |
| --- | --- |
| `test/merge_plan_test.dart` | new |
| `test/gh_service_test.dart` | match-head-commit flag |
| `test/glab_service_test.dart` / `mutations_test.dart` | sha field |
| `test/github_panel_test.dart` | override detail provider; draft still disabled; ready enables; assert merge called with sha |
| `test/gitlab_panel_test.dart` | same |
| `test/forge_context_menu_test.dart` | update fakes’ merge signatures; assert pin when provided |

**Fake signature pattern:** add optional named params with defaults so old overrides that only implement old params still work **if** they use the same signature — in Dart, overriding methods must match. **All test fakes that override `mergePullRequest` / `mergeMergeRequest` must be updated** in phase 2.

**Exit criteria:**

- [ ] Merge disabled with visible reasons for conflict/draft/review-required fixtures
- [ ] Successful merge path sends SHA pin when detail has head SHA
- [ ] Existing squash pulldown tests still pass (methods filtered only when policy present — without policy, keep current methods)
- [ ] analyze + full unit suite green (or at least all forge-related tests)

---

### Phase 3 — Repo policy + strategy + merge options sheet (1.5–2.5 days)

**Purpose:** feature-rich strategy UX.

#### 3.1 Policy fetch

- `repoMergePolicy` on both services + `repoMergePolicyProvider`
- MergePlan consumes policy for `allowedMethods` and `defaultDeleteSource`

#### 3.2 UI

- Method pulldown only lists allowed methods.
- GitLab: if squash `never`, hide squash entry; if `always`, force squash on merge calls and hide toggle.
- Replace phase-2 confirm for merge with **`MergeOptionsSheet`** (`lib/features/forge/merge_options_sheet.dart`):
  - Method (segmented or radio)
  - Delete source checkbox (default from plan)
  - Optional subject/body (GitHub `-t/-b`; GitLab messages when using REST fields)
  - Summary of blocked? (sheet only opens when canMergeNow)

#### 3.3 Service

- Pass subject/body / squashMessage through merge methods.

#### 3.4 Tests

- Policy parser tests
- MergePlan + policy matrix
- Panel: with policy allowing only squash, pulldown/options only squash
- Service argv for `-t`/`-b`

**Exit criteria:**

- [ ] Disallowed methods never sent
- [ ] Default delete-source matches policy when known
- [ ] Custom subject reaches `gh pr merge`

---

### Phase 4 — Auto-merge (1–2 days)

**Purpose:** first-class “merge when ready” without footguns.

#### 4.1 GitHub

- `mergePullRequest(..., auto: true)` → `--auto`
- `disableAuto: true` → `--disable-auto` when canceling
- UI: when `canEnableAutoMerge`, primary or secondary “Enable auto-merge”
- When `autoMergeAlreadyEnabled`, show badge + “Cancel auto-merge”

#### 4.2 GitLab

- Implement `enableMergeRequestAutoMerge` with **explicit** intent:
  - Prefer REST that sets auto-merge / MWPS without relying on `glab mr merge` default.
  - If CLI is used: pass `--auto-merge=true` **and** document; never call merge subcommand without flags in tests.
- Cancel if API supports it.

#### 4.3 MergePlan

- `ci_still_running` / GitHub blocked only on pending checks → `canEnableAutoMerge: true`, `canMergeNow: false`

#### 4.4 Tests

- Service flags
- Plan matrix for auto-only cases
- Panel widget: button label switches; confirm copy says “will merge when requirements are met”

**Exit criteria:**

- [ ] Immediate merge never sets auto-merge as a side effect
- [ ] Auto-merge action is labeled differently in UI and tests
- [ ] GitLab path unit-tested so default-true footgun cannot regress

---

### Phase 5 — Update branch / rebase flows (1–1.5 days)

**Purpose:** unstick “behind” / `need_rebase`.

#### 5.1 GitHub

- `updatePullRequestBranch` via `gh api`  
  `PUT repos/{owner}/{repo}/pulls/{pull_number}/update-branch`  
  with optional `expected_head_sha`

#### 5.2 GitLab

- Rebase API: `POST projects/:id/merge_requests/:iid/rebase` (via `glab api`)
- Or `glab mr rebase` if machine-stable — prefer REST for exit-code honesty (`-i` path)

#### 5.3 UI

- When plan blocked with `behind` / `need_rebase`: show “Update branch” / “Rebase onto target” button instead of (or above) disabled Merge.
- After success: invalidate detail (mergeability recomputes).

#### 5.4 Tests

- Service endpoint/argv
- Panel shows update action for fixture status

**Exit criteria:**

- [ ] User can recover from behind/need_rebase without browser
- [ ] Merge remains disabled until plan says ready

---

### Phase 6 — Polish and expansion (1–2 days, opportunistic)

- Admin bypass (GitHub `--admin`): More menu, destructive confirm, only if `supportsAdminBypass`.
- List row chips: review decision, label colors.
- Inbox filter “Ready to merge” (best-effort from list + cached detail).
- Keyboard shortcut if keymap already has forge actions.
- Description preview in detail body (markdown plain text first).
- After merge with delete: ensure Branches tab refs refresh.
- Soften MADR status to **accepted** once phases 1–2 land; note phases 3–6 as follow-ons.

**Out of scope still:** merge queue UI, stacked PR merge-async, review threads.

---

## 5. File-level checklist (implementation map)

| Area | Create | Modify |
| --- | --- | --- |
| Models | — | `lib/core/github/models.dart`, `lib/core/gitlab/models.dart` |
| Merge plan | `lib/core/forge/merge_plan.dart` | — |
| Services | — | `gh_service.dart`, `glab_service.dart` |
| Providers | — | `app_providers.dart` (`rg -a` / binary-safe edits) |
| UI shared | `merge_readiness.dart`, `merge_options_sheet.dart` (phase 3) | `forge_widgets.dart` if needed |
| Panels | — | `github_panel.dart`, `gitlab_panel.dart` |
| Branch fusion | — | only if new list fields used for chips (optional) |
| Fixtures | `test/fixtures/forge/*` | — |
| Tests | `merge_plan_test.dart` | `github_models_test`, `gitlab_models_test`, `gh_service_test`, `glab_service_test`, `mutations_test`, `github_panel_test`, `gitlab_panel_test`, `forge_context_menu_test`, any fakes overriding merge |

**Gotcha:** `app_providers.dart` is treated as binary by some search tools — use `rg -a` when editing/searching.

---

## 6. Testing strategy

### Unit (required every phase)

- Parser tolerance + fixture golden-ish expectations
- MergePlan exhaustive table
- Service command assembly (args / `-f` fields), including “flag absent when null”

### Widget (phases 2+)

- Ready PR: Merge enabled; confirm then service called with sha + method
- Draft: Merge disabled
- Conflict detail: Merge disabled; readiness shows conflict
- Squash path still works
- Double-submit guard preserved (spinner / set membership) — especially GitLab approve pattern already tested; mirror for merge

### Integration / live

- **Do not** run `live-forge` tagged tests unless maintainer explicitly requests.
- Manual smoke (maintainer): one GH + one GL project, ready + blocked + auto-merge.

### Analyze

```sh
flutter analyze
flutter test test/merge_plan_test.dart \
  test/github_models_test.dart test/gitlab_models_test.dart \
  test/gh_service_test.dart test/glab_service_test.dart \
  test/github_panel_test.dart test/gitlab_panel_test.dart \
  test/forge_context_menu_test.dart test/mutations_test.dart
# before staging a cycle: full flutter test
```

---

## 7. Risk register

| Risk | Mitigation |
| --- | --- |
| `gh mergeable` still UNKNOWN after view | Retry with backoff (2–3×) on detail provider or explicit Retry; never claim ready |
| List parse breaks on label shape variance | Tolerant parser; fixtures for string vs object labels (GitLab) |
| Self-hosted GitLab without `detailed_merge_status` | Fallback mapping; soft-block only on strong signals; still pin sha |
| Auto-merge API differs by GitLab version | Feature-detect fields; hide auto-merge if unsupported |
| Policy fetch fails | Treat policy as null → open method set (current behavior) + log |
| Context menu without detail | Await detail before merge; show reasons if blocked |
| Signature churn in tests | Update all merge overrides in one commit/phase |
| Latency on select | Show list data first; detail async; no full-panel spinner |
| Accidental auto-merge on GitLab | Separate method; unit test forbids unflagged `glab mr merge` |
| Delete-source leaves stale Branches UI | Invalidate refs after successful delete-source merge |

---

## 8. Suggested delivery slices (reviewable units)

Maintainer commits; agents prepare trees. Suggested logical slices:

1. **Phase 0–1:** fixtures + models + detail services + providers (no UX change beyond invisible watch optional)
2. **Phase 2:** MergePlan + SHA pin + readiness + enablement (product milestone)
3. **Phase 3:** policy + options sheet
4. **Phase 4:** auto-merge
5. **Phase 5:** update/rebase
6. **Phase 6:** polish

Do not combine phase 2 with 4 in one unreviewable blob.

---

## 9. Acceptance criteria (initiative-level)

### Must (phases 1–2)

1. Open PR/MR list still loads and filters as today.
2. Selecting a PR/MR loads detail mergeability without leaving the app.
3. Merge is disabled with human reasons when draft, conflicting, or review-blocked (when forge reports it).
4. Merge when ready sends **SHA pin** when head SHA is known.
5. Squash (and GitHub rebase) still available when allowed.
6. Delete-source confirm still works.
7. `flutter analyze` + unit tests green.
8. No secrets in argv; still `gh`/`glab` on executor host.

### Should (phases 3–4)

9. Method list respects repo policy when fetch succeeds.
10. Auto-merge is explicit, labeled, and cancelable when API allows.
11. Commit message overrides for squash/merge when provided.

### Could (phases 5–6)

12. Update branch / rebase from detail.
13. Admin bypass behind More + warning.
14. Inbox/list ready signals.

---

## 10. Open questions for maintainer review

Resolve before or during phase 2–3:

1. **Default merge method** when policy allows all three on GitHub: squash vs merge commit? (Plan default: squash if allowed, else merge commit.)
2. **Soft vs hard block** when `reviewDecision` is empty/unknown but branch protection may still require reviews: hard-block only on positive signals, or attempt merge and show forge error? (Plan: hard-block on known bad signals; allow attempt when signals absent — document in MergePlan.)
3. **Auto-merge on GitLab:** acceptable to use GraphQL `mergeRequestAccept` / MWPS if REST is inconsistent on self-hosted?
4. **Commit message sheet in phase 3:** required for v1 of options sheet, or delete-source-only confirm until users ask?
5. **Scope of list enrichment:** labels+assignees+reviewDecision all in phase 1, or labels only first?

---

## 11. Implementation order cheat-sheet (agent)

```text
Phase 0  fixtures
Phase 1  models.fromJson → service list/detail → providers → unit tests
Phase 2  merge_plan.dart → service sha flags → panels readiness/enable/pin → widget tests
Phase 3  policy provider → MergeOptionsSheet → service messages → tests
Phase 4  auto-merge service+UI → tests
Phase 5  update/rebase service+UI → tests
Phase 6  polish
```

After phase 2, update MADR status line to `accepted` (phases 1–2) with pointer to this plan for remaining work.

---

## 12. Traceability

| MADR item | Plan phase |
| --- | --- |
| Expand list/detail models | 1 |
| MergePlan | 2 |
| SHA pin | 2 |
| Policy-aware methods | 3 |
| Auto-merge | 4 |
| Update branch / need_rebase | 5 |
| Admin / polish | 6 |
| No glab mr merge footgun | 2 (preserve REST) + 4 (explicit enable) |
| issueDetail-style lazy load | 1 providers |
| Shared UI | 2 readiness; 3 options sheet |
)
