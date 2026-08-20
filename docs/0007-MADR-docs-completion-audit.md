---
status: accepted
date: 2026-08-14
decision-makers: maccavelli (maintainer)
verified: 2026-08-20
---

# Correct decision-record status claims against verified codebase state and adopt a verified remediation backlog

## Context and Problem Statement

The repository carries six numbered decision records (0001–0006), four with
companion implementation plans, plus the living `ACTION_PLAN.md`. Several of
these documents carry blanket status lines ("implemented", "completed
(Phases 0–11)", "implementation complete (Phases 0–7)") written at delivery
time. On 2026-08-14 every phase, task, and residual in these documents was
audited against the codebase at commit `54d8444` (clean working tree):
each claimed-complete item was verified against code with file:line evidence,
and each deferred/pending/optional item was checked for current status and
feasibility.

The audit found the record set is largely truthful — the safety-critical and
architectural cores of every initiative are genuinely implemented with the
promised guardrails and tests — but the blanket status lines overstate
completion in specific, identifiable places, and a handful of "deferred"
entries are stale in the opposite direction (the work actually shipped). Left
uncorrected, these discrepancies mislead future planning: unshipped work hides
behind "implemented" labels, and shipped work is re-planned as pending.

How should the status claims be reconciled with reality, and what should
happen to the genuinely open work the audit surfaced?

## Decision Drivers

* Decision records are only useful if their status claims can be trusted;
  MADR history must not be silently rewritten.
* The repository's working style demands root-cause, evidence-grounded
  conclusions — the same standard should apply to documentation status.
* Open work discovered by the audit varies from one-line fixes to items that
  need their own MADR; it needs a home that distinguishes those tiers.
* The maintainer commits each cycle himself and signs off on product-facing
  checkpoints; the audit cannot close human-gated items (Checkpoint E,
  golden acceptance, observational studies) on its own.

## Considered Options

* Leave all documents as they are and rely on this audit informally
* Silently edit the historical status lines and phase logs in place
* Record the audit in a dedicated MADR (this document) as the corrected
  status of record, make targeted factual amendments to the affected
  documents, and adopt the verified backlog below as the source for future
  work selection

## Decision Outcome

Chosen option: "Record the audit in a dedicated MADR with targeted amendments
and a verified backlog", because it preserves the historical records (per MADR
practice a later record states the correction rather than rewriting rationale),
gives every discrepancy a cited, checkable correction, and turns the audit's
feasibility analysis into an actionable, prioritized backlog instead of leaving
it in conversation history.

### Consequences

* Good, because future planning can trust one document (this one) for the
  true completion state of initiatives 0001–0006 and `ACTION_PLAN.md` as of
  commit `54d8444`.
* Good, because stale residuals (work listed pending that already shipped) are
  struck, preventing duplicate re-implementation.
* Bad, because the corrected status lines in the older documents will need
  small follow-up edits (listed in the backlog) — until those land, the older
  documents and this one disagree and this one wins.
* Neutral, because human-gated items (sign-offs, observational studies) remain
  open by nature; this record only makes their open state explicit.

### Confirmation

* Each "claimed complete but missing" finding below cites the file:line that
  demonstrates the gap; a finding is closed when that citation no longer
  demonstrates it (feature present, or the claiming document amended).
* The doc-correction items in the backlog are confirmed by re-reading the
  amended documents against §Per-document findings.
* `flutter analyze` was run during the audit and is clean; no code was
  modified by the audit itself.

## Pros and Cons of the Options

### Leave all documents as they are

* Good, because zero effort.
* Bad, because "implemented" labels continue to hide unshipped work
  (e.g. plan 0003 Phase 4's discovery layer, plan 0004's M7/M13).
* Bad, because stale "deferred" entries invite re-implementing shipped work
  (e.g. the dual SSH stream client, the E1 disambiguation menu).

### Silently edit the historical status lines in place

* Good, because each document becomes self-consistent.
* Bad, because it rewrites decision history without an audit trail,
  contrary to MADR practice and this repository's evidence-led style.
* Bad, because the cross-document findings (the same pattern of blanket
  status lines) would have no single home.

### Dedicated audit MADR + targeted amendments + verified backlog (chosen)

* Good, because corrections are themselves evidence-cited and reviewable.
* Good, because the backlog separates one-line gap closures from
  MADR-worthy new work.
* Neutral, because it adds one more document to maintain — acceptable since
  it is a point-in-time record and does not need continuous updating.

## More Information

### Audit method

Six parallel verification passes (one per document set) at commit `54d8444`,
2026-08-14. Every phase/task/residual status claim was extracted and checked
against code by direct file reads and repo-wide searches (with `grep -a` for
`lib/core/providers/app_providers.dart`, which search tools misclassify as
binary). Verdicts: VERIFIED, PARTIAL, or NOT FOUND. Headline NOT FOUND
findings were independently re-confirmed. `flutter analyze` is clean; the
full test suite was not re-run as part of the audit (static verification
only). Live-forge tests were not touched.

### Per-document findings

#### 0001 — native git / libgit2 (rejected 2026-07-07): faithful

The rejection is fully honored: no libgit2/git2dart dependency in
`pubspec.yaml`; the `CommandExecutor`/`GitService` seam is intact
(`lib/core/providers/app_providers.dart:140`, `:226`). None of the reopen
triggers named in the record have fired. Defects are limited to stale
evidence citations after `git_service.dart` grew ~3×: `git_log_parser.dart`
no longer exists (`_stripSeps` folded into `lib/core/git/git_service.dart:494`),
the stash free-text regex moved to `git_service.dart:5452-5461`, and the glab
HTTP-status parse moved to `lib/core/gitlab/glab_service.dart:466` — where it
is now documented in-code as intentional hardening rather than a liability.
The deferred enterprise items (commit signing — still forced `--no-gpg-sign`
at `git_service.dart:3219`; submodules — detection only, no `git submodule`
invocations; LFS — assessment exists, zero code) remain genuinely undone.

#### 0002 — forge change-request merge and models ("implemented"): phases 0–5 true, Phase 6 overstated

Phases 0–5 are fully and faithfully implemented with the exact seams the plan
prescribed: fixtures with CLI-version headers, list/detail model tiers,
`MergePlan` builders (`lib/core/forge/merge_plan.dart`), SHA-pinned merges
(`--match-head-commit` at `lib/core/github/gh_service.dart:963`; `sha=` at
`glab_service.dart:1369`), REST-only GitLab auto-merge, update-branch/rebase,
and detail providers registered in `repoScopedFetchFamilies`.

Claimed complete but missing (all Phase 6 "opportunistic" polish, uncarved
by the top-level "implemented" status):

* List-row chips (review decision, label colors) — absent from `_prRow`
  (`lib/features/forge/github_panel.dart:455-491`) and `_mrRow`
  (`gitlab_panel.dart:509`), although `labelColors` is already parsed
  (`lib/core/github/models.dart:107`) and `ForgeListRow` already has a
  `chips` slot (`forge_widgets.dart:209`). Cheapest remaining item.
* Inbox "Ready to merge" filter — `forge_inbox.dart:101` still offers only
  All / MRs|PRs / CI / Issues.
* Description/body preview in detail — `body`/`description` are fetched but
  never displayed.

Spec deviations worth recording:

* GitLab `squash_option: always` is not enforced — it only flips the default
  method (`merge_plan.dart:449-453`); plain merge remains selectable
  (`gitlab_panel.dart:939-950`), so a squash-required project can be sent
  `squash=false`.
* The plan's normative GitHub detail fields `reviewRequests`,
  `latestReviews`, `statusCheckRollup`, `commits` were never added to
  `_prDetailJsonFields` (`gh_service.dart:389-393`); approval data is the
  single `reviewDecision` string. The optional GitLab approvals API hop was
  skipped; approval gating rides `detailed_merge_status` instead.
* `MergeRequest.userCanMerge` is parsed (`lib/core/gitlab/models.dart:86`)
  but unused by `mergePlanForGitLab`.

#### 0003 — base-relative branches workspace ("complete Phases 0–7"): Phase 4 materially overstated

Phases 0–3 (trust milestone), 5 (lifecycle), 6 (accessibility), and 7
(performance gates) are genuinely implemented with the promised guardrails:
NUL-framed refs parsing with observable warnings, the full base-resolution
fallback chain (`lib/core/git/branch_comparison.dart:63-175`), merge-tree
preview with capability tri-state and cancellable conflict scan, OID-pinned
base-safe bulk delete (`git_service.dart:3953-4046`), command-budget tests,
and documented tuning constants.

Phase 4's discovery layer, however, exists only below the UI:

* Search grammar (`parseBranchSearchQuery`), the full facet set, smart/
  ahead/behind sorts, and `shapeReviewBranches` are complete, unit-tested
  **dead code** in `lib/core/git/branch_review_query.dart` — the UI still
  uses the plain substring filter (`branch_view_model.dart:221`), the
  four-value quick filter (`branch_view_model.dart:8`), and
  `shapePhase1ReviewBranches` with Activity/Name only
  (`branch_navigator.dart:436,647`, sort popup `:898-911`).
* Hide is write-only: `_batchHide` writes `hiddenBranchNames`
  (`branches_view.dart:647-648`) but nothing reads it for display — no row
  filtering, no Show Hidden toggle, no Unhide.
* The typed forge-knowledge provider and the entire §3.7 protection
  enrichment (Gh/Gl protected-branch fetches, `ProtectionKnowledge`) are
  absent; only the pure GitLab wildcard matcher exists, unfed.
* The bulk-delete sheet is a simple list, not the §4.8 preflight table
  (Protection/Request columns are impossible without the two items above).

Additional deviations: `_openHistory` seeds `widget.repoPath` instead of the
§0.5.F-mandated main mount (`branches_view.dart:1017-1022`), so the History
handoff silently no-ops from a worktree-embedded Branches view, and the
plan's history-intent navigation tests don't exist. `branches_view.dart` is
1452 lines against the plan's <900 target (the "materially smaller" exit
criterion is nonetheless met). MADR Confirmation criterion 4 (Review offers
Merged/Stale/Request/CI/Upstream filters) is unmet in the UI. Checkpoint E
maintainer sign-off remains outstanding, as the docs correctly state.

#### 0004 — UI/UX deep debug audit ("implemented"; LOW close-out 2026-08-14): mostly true, six gaps, one stale residual

Of ~30 claimed-complete items, 24 verified — including the entire HIGH track
(H1–H8) with tests, and all landed LOW items (L1/L2/L3/L5/L10).

Claimed complete but missing:

* **M7** — the Labels "(view only)" caption does not exist; the header is
  plain `'Labels'` (`lib/features/forge/project_sections.dart:146`).
* **M13** — the shared file-selection seam does not exist; `FileView` keeps
  a private `_selectedPath` (`file_view.dart:79`) and `RepoStatusView` its
  own `_selectedPaths`; no `repoFileSelectionProvider` anywhere.

Partial:

* **M2** — `history.zoomReset` still uses `CupertinoIcons.zoom_out`,
  identical to zoomOut, while the in-code comment
  (`lib/features/common/command_palette.dart:344`) falsely claims a distinct
  glyph.
* **M12** — *corrected 2026-08-14 after a second verification pass; the
  original finding below was wrong.* The detached window **does** push
  `Status — <repo> (<label>)` over the bootstrap channel
  (`secondary_window_main.dart:594-604`), on boot and on every connection
  change. The first pass mistook the Swift default and the Flutter-level
  `MacosApp.title` fallback for the mechanism. Two real but smaller defects
  remain: the open-time title is built with prefix `'Repo'`
  (`window_manager_bridge.dart:522`), so the window reads "Repo — x" until
  the session lands and permanently if it never does; and
  `window_manager_bridge.dart:325-328` invokes `setWindowTitle` on the
  `magicgit/windows` control channel, which has no such case
  (`MainFlutterWindow.swift:129-157` ends in `FlutterMethodNotImplemented`),
  so every call throws `MissingPluginException` swallowed by
  `.catchError((_) {})`.
* **M14** — command-palette rows got no `Semantics` (nav rail and tab strip
  did).
* **M15** — no reject-on-unexpected-dismiss for the host-key dialog; the
  `.then` at `app_shell.dart:658-661` clears state without calling
  `rejectHostKeyChange` (safety rests on the non-dismissible barrier).
* **H8** — implementation verified, but the plan's required
  `confirmSessionExit` tests were never written.

Stale in the favorable direction: the "in-panel E1 disambiguation menu"
residual carried by both 0004 documents (MADR :425,:427; PLAN :981,:1144-1145)
is actually **shipped** — `history_view.dart:2201-2260` implements exactly the
specified menu — and should be struck. Doc hygiene: PLAN exit-criteria
checkboxes for Phases 2–9 are still unchecked despite the "implemented"
status; open question 2 (ship bar) is moot.

#### 0005 — task-centered adaptive workspace ("completed Phases 0–11"): code true, Phase 9 gate overstated

All code artifacts of Phases 0–11 verified, including the 48 workspace
goldens (16 states × 3 sizes), line/range staging with real-git integration
tests, image diff modes, saved workspace sets, and redo gated to tag refs
exactly as decided.

Overstatements and deviations:

* "Completed" covers code only: the plan's own Product Acceptance Criteria
  (measured 25% interaction reduction, keyboard/VoiceOver task completion,
  SSH runs, profile frame timings) were never run — the UX baseline honestly
  marks every observational number `unavailable`, and golden acceptance is
  "pending review". The observational release gate has not been exercised.
* The Phase 2 file table claims curated forge operation descriptors in
  `gh_service.dart`/`glab_service.dart`; neither contains any. The shipped
  mechanism is a generic `ActivityCommandExecutor` wrapper labeling every
  forge mutation 'Update forge' (`app_providers.dart:314-322`).
* `test/repo_change_filter_test.dart:23-37` contains a vacuous assertion
  (`commandCount += 0`); the real zero-command telemetry test lives in
  `workspace_performance_baseline_test.dart:111`.
* The MADR's "Source-code grounding" section is now historical (Forge routes
  through `forge_workspace.dart`, not the cited `forge_panel.dart` pattern).

#### 0006 — hybrid native title bar (accepted 2026-08-13, decision-only): consistent, one inaccuracy

Correctly decision-only: `lib/main.dart:54` still `TitleBarStyle.hidden`, no
macos_ui `ToolBar` anywhere, no `0006-PLAN-*` exists. Its predicted residuals
L1/L2 shipped in the same commit (`a1297d8`) as stated. One inaccuracy: the
consequence "secondary windows … must change together" overstates coupling —
pop-outs already use native titled windows
(`macos/Runner/SecondaryWindowController.swift:165`); only the main window
hides its title bar. The unaccounted wrinkle for implementation: the app is
dark-only, so the native title bar must match darkAqua as the secondary
windows already do.

#### ACTION_PLAN.md: 46 of ~51 verified, several stale claims

The transport/safety core (generation pinning, stdin-only token handling,
timeouts, session cleanup, reconnect lifecycle, watcher backoff) is verified
end to end. Stale or wrong claims:

* The dual SSH stream client is listed as deferred/speculative but is fully
  implemented (`lib/core/ssh/ssh_client_manager.dart:132-331`, with
  degrade-to-single) — the stalest entry in the doc.
* `GlabService.graphql` is claimed deleted as dead code but exists and is
  live (`glab_service.dart:622`, called by `projectDashboard` at `:698`);
  separately, the doc's "(graphql)" phrasing for mutations is wrong —
  mutations go through REST `glab api -i`.
* Pagination "fixed" covers issues/milestones only; labels and releases
  still use fixed GraphQL `first:` caps with truncation merely surfaced
  (`glab_service.dart:564-570`).
* One real code gap found: `lib/features/common/busy_action.dart:53-54`
  calls `setState` after an awaited confirm dialog with no `mounted` check
  (reached from `_discard`/`_discardUntracked`,
  `repo_status_view.dart:882-911`).
* `docs/ARCHITECTURE_PLAN.md:229-230, :539, :607` still describe env-var
  token injection that was removed; `workspace_registration.dart:55`
  references a relocated `_addRepo`; various cited filenames have moved;
  "75 tests green" is now ~324 test files.

### Verified remediation backlog

Items the audit confirmed are open and feasible, grouped by size. Small items
close gaps in work already claimed complete; medium/large items are the
genuinely deferred work worth scheduling.

**Small — close false "complete" claims (each ≤ ~1 file):**

1. Fix `history.zoomReset` glyph and its false comment
   (`command_palette.dart:338-344`). [0004 M2]
2. Add the Labels "(view only)" caption (`project_sections.dart:146`).
   [0004 M7]
3. Add `mounted` guard in `busy_action.dart:53` (real late-`setState` bug).
   [ACTION_PLAN]
4. Reject host-key change on unexpected dialog dismissal
   (`app_shell.dart:658`). [0004 M15]
5. Align the detached window's open-time title prefix (`'Repo'` → `'Status'`)
   with the title the child already pushes, and either implement or delete
   the dead `setWindowTitle` control-channel call. [0004 M12, corrected]
6. Add `Semantics` to command-palette rows. [0004 M14]
7. Write the missing `confirmSessionExit` tests. [0004 H8]
8. Fix `_openHistory` to seed the main mount (`branches_view.dart:1017`,
   mirror `forge_create_coordinator.dart`) + the promised intent tests.
   [0003 §0.5.F]
9. Wire Hide presentation: thread `hiddenBranchNames` into
   `BranchViewModel.fromRefs` + a Show Hidden toggle and Unhide action.
   [0003 Phase 4]
10. Enforce GitLab `squash_option: always` (drop plain merge from
    `allowedMethods` in `merge_plan.dart:442-453`). [0002]
11. Forge list-row chips — data and `chips` slot already exist; wire into
    `_prRow`/`_mrRow`. [0002 Phase 6, cheapest]
12. Description/body preview section in PR/MR detail. [0002 Phase 6]
13. Doc corrections: strike the shipped E1 residual from 0004 MADR/PLAN and
    tick its phase checkboxes; mark the dual SSH stream client done and fix
    the graphql/pagination claims in ACTION_PLAN.md; scrub the residual
    env-token framing from ARCHITECTURE_PLAN.md; soften 0002/0003/0005
    status lines per this audit.

**Medium — deferred work with the substrate already built:**

14. Wire the Phase-4 review-query layer into the Branches UI
    (`shapeReviewBranches`, facets, search grammar, smart/ahead/behind
    sorts) — requires the typed forge-knowledge provider so `No request` /
    `Failing CI` stay truthful. [0003]
15. §3.7 protection enrichment (Gh/Gl protected-branch fetches, sealed
    `ProtectionKnowledge`, provider) and then the full §4.8 preflight table
    in the bulk-delete sheet. [0003]
16. GitHub detail-field expansion (`reviewRequests`, `latestReviews`,
    `statusCheckRollup`) and/or the GitLab approvals hop for approval counts
    in the readiness strip. [0002]
17. Shared file-selection seam between `RepoStatusView` and `FileView`.
    [0004 M13]
18. Curated per-operation forge activity labels (replace the generic
    'Update forge' at the `ActivityCommandExecutor` seam or per call site).
    [0005 Phase 2]
19. Inbox "Ready to merge" filter (needs a list-tier heuristic or cached
    detail to avoid N+1 fetches). [0002 Phase 6]
20. Labels/releases pagination in `GlabService` (page-walk like
    issues/milestones). [ACTION_PLAN]
21. Write `0006-PLAN-hybrid-native-title-bar-context-bar.md` and implement
    the bounded title-bar slice — gated on live macOS preview verification;
    note the secondary windows are already titled (less work than 0006
    implies) and the darkAqua constraint. [0006 / 0004 L9]
22. Disposable-sshd `integration_test/` smoke to cover the transport paths
    the unit suite admits it cannot reach. [ACTION_PLAN]

**Large or human-gated — need their own MADR or the maintainer:**

23. Phase 12 items, each explicitly requiring its own MADR: submodules,
    Git LFS (assessment exists; transport fork decision is the blocker),
    Code Owners, stacked branches. [0005 / 0001]
24. Commit signing support (local backend feasible today; SSH backend needs
    agent forwarding or `gpg.format=ssh`). [0001]
25. Maintainer actions: Checkpoint E sign-off [0003], acceptance of the 48
    workspace goldens [0005], and the observational Phase 9 studies
    (human/SSH/VoiceOver/profile measurements) whose protocol is fully
    specified in the 0005 UX baseline. [0005]

### Addendum — defects found while scoping the remediation (2026-08-14)

A second pass gathering implementation detail for
[0007-PLAN-docs-completion-audit.md](0007-PLAN-docs-completion-audit.md)
corrected the M12 finding above and surfaced defects the status audit did not
look for. They are recorded here because they change the priority of the
backlog, not merely its detail:

* **Host-key dialog dismissal hangs the connect permanently.**
  `rejectHostKeyChange` completes a `Completer` that `_verifyHostKey` awaits
  at `app_providers.dart:968`. If the dialog is popped without a button
  press, neither decision fires, that future never resolves, and because
  `hostKeyPrompt` stays non-null the listener's `previous == null` guard
  prevents the dialog ever re-showing. Silent, unrecoverable.
* **`busy_action.dart` has three unguarded entry points, not one.**
  `runGuarded:54`, `holdBusyWhile:72`, and `runLogged:98` all `setState`
  before any `mounted` check; 13 call sites await a dialog immediately
  before calling them.
* **`_openHistory` leaves a stale intent that later misfires.** From a
  worktree-embedded Branches view the intent is seeded with the worktree
  path; the main History mount rejects it on the mount check and never
  clears it, so an unrelated worktree History view silently consumes it
  later.
* **`GlRepoMergePolicy` tests for squash values GitLab never sends.** The
  real enum is `never | always | default_on | default_off`;
  `merge_plan.dart:135-137` matches `'encourage'`/`'encouraged'` and defaults
  to `'allowed'`, so `squashEncouraged` is dead against any real instance —
  and `test/fixtures/forge/glab_project_merge_policy.json` encodes the same
  wrong value, so no test can catch it.
* **Hidden branches are unrecoverable from within the app.** Beyond Hide
  being display-inert, there is no Unhide or Show Hidden affordance at all,
  and `mergeLateLoadedPrefs` can clobber a session-local hide because only
  pins, mode and base are protected.
* **A latent ambiguous-import error blocks the 0003 Phase 4 wiring.**
  `kBranchStaleDays` and a byte-identical stale predicate exist in both
  `branch_dashboard_stats.dart:34` and `branch_review_query.dart:12`;
  nothing imports both today, so it compiles until the wiring adds that
  import.
* **`FileView` is constructed twice** in `RepoStatusView` (`:1490`, `:2449`),
  so M13's missing seam costs three independent selections, not two.
* **A dead platform-channel call**: `window_manager_bridge.dart:325-328`
  (see the corrected M12 above).
* **`gitlabProtectedBranchMatches` contradicts its own doc comment** —
  it maps `*` to `.*`, which crosses `/`, while the comment claims
  segment-scoped matching (`branch_review_query.dart:521-529`).
* **The labels/releases fixed-cap defect is not GitLab-only** — the GitHub
  dashboard query has the identical `labels(first: 100)` /
  `releases(first: 20)` caps at `gh_service.dart:1140-1146`.

### Remediation log

| Date | Change |
| --- | --- |
| 2026-08-14 | Audit recorded; companion [0007-PLAN-docs-completion-audit.md](0007-PLAN-docs-completion-audit.md) written from six verification passes plus per-item implementation dossiers. |
| 2026-08-14 | **Backlog executed, Phases 0–6.** Phase 0 corrected every document listed above. Phase 1 fixed the four correctness defects, each with a test that fails without the fix. Phase 2 closed the false-complete claims (zoomReset glyph, Labels caption, palette semantics, detached title prefix, the missing `confirmSessionExit` tests). Phase 3 fixed the squash-policy enum and enforcement, added list-row chips and a description preview, and shipped the Inbox "No blockers" filter. Phase 4 completed the 0003 discovery layer: duplicate stale helpers collapsed, Hide made reversible, a typed forge-knowledge provider built, and the review-query layer wired into the UI. Phase 5 delivered protection enrichment + the §4.8 preflight table, labels/releases pagination, curated forge activity labels, the shared file-selection seam, live-sshd transport tests, and the GitHub detail-field expansion. Phase 6 produced [0006-PLAN-hybrid-native-title-bar-context-bar.md](0006-PLAN-hybrid-native-title-bar-context-bar.md). Suite grew 2836 → 2955 tests, analyzer clean throughout. Phase 7 remains open by nature (see below). |

Two deviations from the plan, both deliberate and recorded here rather than
silently absorbed:

* **Curated forge activity labels (5.4)** were implemented as one tested argv
  mapper (`lib/core/forge/forge_operation_labels.dart`) instead of curating at
  each of ~41 service call sites. Forge argv is rigidly structured, so a single
  table covers the CLI and REST paths alike — including the ten mutations that
  route through `api()` and would otherwise need a label threaded through two
  more layers. Unrecognized commands still fall back to 'Update forge'.
* **The typed forge-knowledge and protection providers are not in
  `repoScopedFetchFamilies`**, which the plan called for. `branch_forge_status.dart`
  imports `app_providers.dart`, so registering there would be a circular import
  — and it is unnecessary: every upstream is registered and both providers are
  `autoDispose`, so they recompute when those are invalidated.

One finding surfaced during execution and is worth carrying forward: sharing
the file selection (5.5) required distinguishing a *tree-origin* selection from
a stale Changes-list entry, because a clean file legitimately appears in no
status section. `RepoChangeSelection.fromTree` now carries that origin, and
`reconcile` spares tree-origin selections.

### Cross-cutting observation

The recurring failure mode is not fabrication but **blanket status lines**:
every initiative's core shipped as designed, while "opportunistic",
"discovery-layer", or "observational" tails were absorbed into
"implemented"/"completed" wording. Future plans should either carve those
tails out of the status line explicitly (as 0005's Phase 9 UX baseline does,
correctly) or keep per-item checkboxes authoritative over the header.
