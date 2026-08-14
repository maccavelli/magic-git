# Implement the docs completion audit remediation

Associated MADR: [0007-MADR-docs-completion-audit.md](0007-MADR-docs-completion-audit.md)

- Status: **Phases 0–6 executed** (2026-08-14). Phase 7 is open by nature —
  it needs a new MADR or the maintainer, not an engineer. Two deliberate
  deviations and one newly-surfaced finding are recorded in the MADR's
  Remediation log rather than edited into the steps below.

## Goal

Close every gap the 2026-08-14 audit verified as open, in an order that fixes
real defects first, makes the decision records truthful, and only then spends
effort on deferred feature work. Every step below names the exact file, the
exact anchor, the change, the test, and the acceptance check, so it can be
executed without re-deriving the analysis.

All anchors were verified against commit `54d8444` (clean tree). Line numbers
drift as edits land; treat the quoted code as authoritative and the line number
as a hint.

## Scope

**In scope.** All 25 backlog items from the MADR, re-scoped against
implementation dossiers, plus ten defects the dossiers surfaced that the status
audit did not look for (MADR §Addendum).

**Out of scope.** Phase 12 work (submodules, LFS, Code Owners, stacked
branches) and commit signing — each needs its own MADR before a plan.
Maintainer-gated items (Checkpoint E, golden acceptance, the observational
Phase 9 studies) are listed in Phase 7 but cannot be executed by an engineer.

**Standing constraints** (from `AGENTS.md`, apply to every step):

* `flutter analyze` and `flutter test` must be clean **before** staging.
  New code must be analyzer-clean on the first pass — `prefer_final_locals`,
  `prefer_const_constructors`, `unawaited_futures`, `avoid_dynamic_calls`,
  strict-casts/inference/raw-types are all on.
* Never run `live-forge`-tagged tests unprompted. They mutate real projects.
* Do not commit or push unless asked; never author commit message text.
* `lib/core/providers/app_providers.dart` is misclassified as binary — use
  `grep -a` / `rg -a`.

## Scoping assessment

The MADR sized these by judgment; the dossiers resized them by evidence. Three
moved materially.

| Tier | Meaning | Items |
| --- | --- | --- |
| **A — trivial** | One file, no design decision, under ~30 lines | 2.1, 2.2, 2.4, 0.1–0.5 |
| **B — small** | One or two files, one decision, tests included | 1.1, 1.2, 1.3, 1.4, 2.3, 2.5, 3.1, 3.2, 3.3 |
| **C — medium** | Multi-file, needs a prerequisite or a design call | 4.1, 4.2, 4.3, 5.1, 5.2, 5.3, 5.5, 5.6 |
| **D — large** | New subsystem or gated on live verification | 4.4, 5.4, 6.1 |
| **E — not executable here** | Needs a MADR or the maintainer | 7.1–7.5 |

Re-scoped from the MADR's estimate:

* **Detached-window title (was small, now trivial)** — the mechanism already
  works; only a prefix constant is wrong. See 2.4.
* **Inbox "Ready to merge" (was medium, now small)** — `mergePlanFor*`
  already answers this on a list-tier row at zero command cost. See 3.4.
* **Branches Phase-4 wiring (was medium, now large)** — has an unbuildable
  prerequisite (`forgeKnown` has no source) plus a latent compile error. It
  is decomposed into 4.1–4.4.

## Implementation Steps

### Phase 0 — Documentation truth corrections

No code. Each step makes a document agree with verified reality. Do these
first: they are what stops the next planning cycle from re-deriving this audit.

**0.1 — Strike the shipped E1 residual from the 0004 documents.**
The "in-panel E1 disambiguation menu" is implemented at
`lib/features/history/history_view.dart:2201-2260` (merge ×3, rebase, and a
`canMove`-gated "Move `<name>` here" with confirm and undo).
Edit `docs/0004-MADR-ui-ux-deep-debug-audit.md:409-410` (the
`DRAG_AND_DROP_ENGINE.md` bullet — drop "remaining residual is the in-panel E1
disambiguation menu on commit rows") and add a new dated row to the
Remediation log recording that 0007 verified it shipped. Edit
`docs/0004-PLAN-ui-ux-deep-debug-audit.md:981` (Checkpoint K) to remove
"in-panel E1 disambiguation menu" from capacity residuals.
Do **not** rewrite the historical 2026-08-06 log entry at MADR:425 — it was
accurate when written.

**0.2 — Correct the 0004 status claims for the items that did not ship.**
In `docs/0004-PLAN-ui-ux-deep-debug-audit.md`, tick the Phase 2–9 exit-criteria
checkboxes that genuinely passed and leave M7/M13 unticked with a pointer to
this plan's 2.2 and 5.5. Close open question 2 (ship bar) as moot. Add a
remediation-log row in the MADR noting M7 and M13 were recorded complete but
were not implemented, per 0007.

**0.3 — Correct `docs/ACTION_PLAN.md`.** Four edits:
* `:24` — "75 tests green" is stale; the suite is 321 files in `test/`.
* `:39` and `:404` — remove `GlabService.graphql` from the removed-dead-code
  claim; it exists and is live at `glab_service.dart:622`, called by
  `projectDashboard` at `:698`. Note the second-cycle "(graphql)" phrasing for
  mutations is also wrong — mutations use REST `glab api -i`.
* `:55-57` and `:375-378` — the second dedicated SSH stream client is **not**
  deferred; it is implemented at `ssh_client_manager.dart:132-331` with
  degrade-to-single. Mark done.
* `:120-121` — the pagination claim covers issues/labels/milestones/releases,
  but labels and releases still use fixed GraphQL caps. Narrow the claim to
  issues/milestones and point at this plan's 5.2.

**0.4 — Scrub residual env-token framing from `docs/ARCHITECTURE_PLAN.md`.**
`:229-230` ("Inject the GitLab token via env (`GITLAB_TOKEN`) … or pipe through
`--stdin`") and `:607` ("fallback inline `VAR=$X cmd`") contradict both the
shipped design and the same document's `:97`. Tokens go over stdin once via
`glab auth login --stdin` and never touch argv or env. At `:539`, the
"GraphQL dashboard query deferred" note is stale — it shipped.

**0.5 — Soften the overstated status lines.** Add one sentence to each,
pointing at this MADR rather than rewriting history:
* `docs/0002-PLAN-…:3` — carve Phase 6 out of "implemented" (three polish
  items unshipped; see 3.2, 3.3, 3.4).
* `docs/0003-PLAN-…:3` and `docs/0003-MADR-…` Confirmation criterion 4 —
  Phase 4's discovery layer is unwired; see Phase 4.
* `docs/0005-PLAN-…:3` — "completed" covers code artifacts only; the
  observational Phase 9 gate has never been run (see 7.3).

*Acceptance for Phase 0:* re-reading each document against MADR 0007
§Per-document findings surfaces no remaining contradiction.

---

### Phase 1 — Correctness fixes

Real defects, each with a user-visible failure mode. Highest priority in the
plan; none depends on another.

**1.1 — Fail closed when the host-key dialog is dismissed without a decision.**
*Severity: silent permanent hang.*

`rejectHostKeyChange` / `acceptHostKeyChange` (`app_providers.dart:983-1001`)
complete the `Completer` that `_verifyHostKey` awaits at `:968`. The dialog's
`.then` block (`lib/features/app_shell.dart:658-661`) clears
`_hostKeyDialogOpen` and `_hostKeyDialogRoute` but calls neither. Any pop that
is not a button press — the listener's own `Navigator.pop` at `:808`, a route
teardown, a future disconnect path — leaves that future unresolved forever:
the connect neither completes nor fails, and because `hostKeyPrompt` stays
non-null the listener's `next != null && previous == null` guard prevents the
dialog from ever re-showing.

Change `app_shell.dart:658-661` to call
`ref.read(connectionProvider.notifier).rejectHostKeyChange();` before clearing
the flags. This is safe unconditionally: both methods guard on
`isCompleted`, so a redundant call after a button press is a no-op. Also pass
`barrierDismissible: false` explicitly at the `showMacosAlertDialog` call
(`:624`) so the intent is local rather than inherited from the macos_ui
default.

*Tests:* add to `test/host_key_verification_test.dart` (which already has the
accept/reject/auto-reconnect cases at `:138`, `:181`, `:222`) a case asserting
`rejectHostKeyChange` twice is a no-op and the connect future resolves `false`.
Add a widget case — new `test/host_key_dialog_test.dart` or a group in the
29-line `test/app_shell_test.dart` — that pops the dialog route out from under
the shell and asserts the verify future resolves `false` rather than hanging.

*Acceptance:* no code path can leave `_hostKeyDecision` uncompleted once the
dialog has been shown.

**1.2 — Guard the three `BusyActionState` entry points.**
*Severity: late `setState` after disposal.*

`lib/features/common/busy_action.dart` guards every `finally` block but no
entry: `runGuarded:54`, `holdBusyWhile:72`, and `runLogged:98` each
`setState(() => _busy = true)` with no `mounted` check, and `runGuarded`
immediately uses `context` (`:56`) while `runLogged` reads `ref` (`:99`).
Thirteen call sites await a confirm dialog immediately before calling in —
`repo_status_view.dart` `_discard` (dialog `:873` → `:884`),
`_discardUntracked` (`:897` → `:908`), `_discardStaged`, `_discardMany`,
`_discardUntrackedMany`, `_discardStagedMany`; `branches_view.dart` `_runMerge`
(`:1162` → `:1180`); `worktrees_view.dart` (`:333` → `:343`);
`history_view.dart` `_actRevert` (`:800` → `:810`), multi cherry-pick
(`:832` → `:841`), multi revert (`:858` → `:867`), rebase sheet
(`:1139` → `:1152`); `stash_view.dart` `_dropStash` (`:755` → `:765`).
Roughly 40% of call sites add their own `if (!mounted) return;` — which is the
argument for fixing it once in the mixin.

Add `if (!mounted) return false;` to `runGuarded` and `runLogged` (folding into
the existing `if (_busy) return false;`, which already means "did not run", so
no caller changes), and `if (!mounted)` handling to `holdBusyWhile`.

*Design decision required:* `holdBusyWhile<R>` has no sentinel to return when
disposed. Take the option that does not invent a value: keep it running
`body()` but skip both `setState` calls when unmounted. Record the choice in a
comment; do not silently return null via a nullable widening.

*Tests:* `test/busy_action_test.dart` already has the mirror case
`'disposal mid-op: no refresh, no setState, no throw'` at `:82`. Add
disposal-**before**-call cases for all three methods, asserting the op never
ran and `tester.takeException()` is null.

**1.3 — Seed the History intent against the main mount.**
*Severity: click appears inert, then an unrelated view is silently filtered.*

`lib/features/branches/branches_view.dart:1017-1023` seeds
`historyNavigationIntentProvider` with `widget.repoPath`, then navigates the
main shell with the literal page index `1`. `BranchesView` is mounted with a
worktree path inside the Worktrees page (`worktrees_view.dart:1170-1175`), so
from that mount the main `HistoryView` rejects the intent on
`next.repoPath != widget.repoPath` (`history_view.dart:1225`) **and never
clears it**. The stale intent then sits until the user next opens that
worktree's own History sub-page, which consumes it — a delayed, misattributed
revision scope.

Mirror `lib/features/forge/forge_create_coordinator.dart` (the correct pattern,
already called from this same class at `branches_view.dart:1003-1013`): resolve
`ref.read(connectionProvider).repoPath`, guard null/empty with
`showErrorDialog`, and replace the literal `1` with
`DropZoneId.history.pageIndex`. The DnD twin at `drop_registry.dart:284-289`
already does this correctly.

*Tests:* `test/branches_phase0_characterization_test.dart:164` already pumps
`BranchesView(repoPath: '/other')` — a deliberate mount mismatch, the natural
home. Add: seeding uses the connection mount, not `widget.repoPath`; and a
mismatched-mount intent is not left dangling. Model the pure-notifier assertions
on `test/forge_create_seed_test.dart:29-37`.

**1.4 — Resolve the dead `setWindowTitle` control-channel call.**
`lib/core/providers/window_manager_bridge.dart:325-328` invokes
`setWindowTitle` on `magicgit/windows`, which has no such case —
`MainFlutterWindow.swift:129-157` ends in `default: result(FlutterMethodNotImplemented)`.
Every call throws `MissingPluginException`, swallowed by `.catchError((_) {})`.
Either implement the case in Swift (forwarding to
`secondaryWindows[id]?.window?.title`, mirroring
`SecondaryWindowController.swift:346-350`) or delete the call. Prefer deleting:
the child already pushes its own title over the bootstrap channel
(`secondary_window_main.dart:594-604`), so the control-channel path is
redundant. If deleted, remove `_repinHistory`'s now-unused title argument.

*Tests:* `test/window_manager_bridge_test.dart` has no title assertions today.
Add one asserting no `setWindowTitle` is sent on the control channel (or, if
implemented, that it reaches the window).

---

### Phase 2 — Close the false "complete" claims

Items the 0004 documents recorded as done that are not. Each is small and
independent.

**2.1 — Give `history.zoomReset` a distinct glyph.** *(Tier A)*
`lib/features/common/command_palette.dart:341-345` uses
`CupertinoIcons.zoom_out`, identical to `history.zoomOut` at `:334-339`, under
a trailing comment at `:344` that falsely claims otherwise. The action is an
absolute reset to `1.0` (`history_view.dart:1454-1455`), bound to ⌘0
(`keymap.dart:566-573`), and the palette row is its only visual affordance.
Use `CupertinoIcons.fullscreen_exit` — verified to exist and to have zero uses
anywhere in `lib/`, and it reads as "actual size" rather than another
magnifier. Fix or delete the comment.

*Tests:* `test/command_palette_test.dart` asserts no icons today. Add a case
filtering to "zoom" and asserting the reset row's icon differs from the zoom-out
row's.

**2.2 — Add the Labels "(view only)" caption.** *(Tier A)*
`lib/features/forge/project_sections.dart:145-151` renders a plain `'Labels'`
header. Labels is uniquely inert among the forge sections: chips are not
tappable, there is no selection, no detail pane, and no create/edit
(`_LabelsWrap` → `ForgeLabelChip`, tooltip only).

The only secondary-text slot on the header today is `count` (grey `caption1`,
`section_collapse.dart:128-137`). Add a dedicated `caption` field to
`CollapsibleSectionHeader` rendered identically after `count`, and pass it
through `ForgeSectionHeader` (`forge_widgets.dart:61-117`). Do **not** fold the
text into `count` — that abuses a documented count field and breaks
`test/forge_project_sections_test.dart:347-361`, which asserts `find.text('1 of 250')`.

*Explicitly not in scope:* Milestones and Releases. They are read-only but do
open a detail pane with an Open-in-Browser action, so "(view only)" would
mislead. If they should carry a caption it needs different wording and its own
decision.

*Tests:* add a `caption` case to `test/section_collapse_test.dart:95-128`
(which already groups `renders title` / `shows count` / `shows trailing`), and
assert the Labels header caption in `test/forge_project_sections_test.dart`.

**2.3 — Add Semantics to command-palette rows.** *(Tier B)*
`_row` (`command_palette.dart:1074-1113`) wraps a `Tappable`, which adds no
semantics of its own (`tappable.dart:25-79`). A row currently exposes three
unrelated leaf text nodes — label, shortcut, and a bare category word like
"app" — with no button or selected role.

Follow the house pattern, which puts `Semantics` outside the tappable with
`button: true` and `selected:` — `nav_rail.dart:89-107` and
`tab_strip.dart:187-197`. Extract a pure
`String paletteRowSemanticsLabel({required String label, required PaletteCategory category, String? shortcut, required bool highlighted, int? position, int? count})`
into `lib/features/common/palette_models.dart` (already this file's pure-logic
sibling), mirroring `branch_row_semantics.dart`, so it is unit-testable without
pumping a widget. Thread `i` and `commands.length` from the `itemBuilder`
(`:1062-1063`) — `_row` does not receive the index today.

*Tests:* pure cases in `test/palette_models_test.dart`; one widget assertion in
`test/command_palette_test.dart` using the
`tester.ensureSemantics()` / `getSemantics(...).label` idiom from
`test/tabs_host_test.dart:173,206-210`.

**2.4 — Align the detached window's open-time title prefix.** *(Tier A)*
Per the corrected M12 finding: the child already pushes
`Status — <repo> (<label>)` (`secondary_window_main.dart:594-604`). Change
`_titleFor` in `lib/core/providers/window_manager_bridge.dart:522` from prefix
`'Repo'` to `'Status'` so the open-time title matches, and
`SecondaryWindowController.swift:46` from `"Repository"` to `"Status"` for the
(unreachable) fallback.

*Not in scope:* using a repo alias in the title. `tabAliasProvider` lives in the
main isolate's tab container and `repoLabels` on the persisted `SavedConnection`;
neither reaches the child. Doing so means widening `WindowDescriptor` /
`ConnectionEventPayload` (`exec_proxy_codec.dart:49-73`) — new wire surface,
separate decision.

*Tests:* `test/secondary_window_app_test.dart:258` already asserts the pushed
title exactly, with `_descriptor` at `:34` as `kind: 'history'`. Add a
`detachedRepo` variant asserting `'Status — repo (Prod)'`. `_titleFor` has no
coverage at all today — add a unit case in
`test/window_manager_bridge_test.dart`.

**2.5 — Write the missing `confirmSessionExit` tests.** *(Tier B)*
`lib/features/common/session_exit_guard.dart` (59 lines) has three call sites
and zero test coverage; plan 0004's Phase 5 required tests in the same slice.
Cover its actual branches:

1. clean + no pending → returns `true`, no dialog (early return at `:33`);
2. dirty → dialog names uncommitted changes; confirm → `true`;
3. dirty → Cancel → `false`; and Escape → `false`;
4. clean but `pending != none` → dialog fires, message interpolates
   `pending.name` and the Recovery prose (`:41-45`);
5. dirty **and** pending → both paragraphs plus the trailing "does not delete
   files on the host" sentence, joined by `\n\n`, in that order;
6. confirm-label derivation (`:56`) — `'Close tab?'` → button `Close Tab`,
   `'Log out?'` → `Log Out`. This is a case-sensitive substring match on
   `'Close'` and is what a caller rename would silently break;
7. cold-status path (`:20-26`) — no `statusProvider` override, fake service
   returns dirty → fetch then dialog; and fetch **throws** → `runAction`
   returns false → **the guard returns `false`, blocking logout**. Pin this
   contract explicitly; it is debatable and currently undocumented;
8. foreign-container contract — build the tree under container A, pass
   container B (the tab-strip case, `tab_strip.dart:35-40`), assert the dialog
   reflects B.

*Harness:* use the captured-context host from
`test/escape_dialogs_test.dart:24-48` plus its `_escape` helper, with
`statusProvider`/`pendingOpProvider` overridden in the family form
(`test/current_repo_indicator_test.dart:32`). Use a bare `MacosApp` + `Builder`
host so `pumpAndSettle` is safe; do not mount a repo view.

---

### Phase 3 — Forge truthfulness and polish

**3.1 — Fix the squash policy enum and enforce `squash_option: always`.**
*(Tier B — two defects, one change)*

*Defect A (new).* `GlRepoMergePolicy` (`lib/core/forge/merge_plan.dart:103-137`)
tests `squashOption == 'encourage' || == 'encouraged'` and defaults to
`'allowed'`. GitLab's REST enum is `never | always | default_on | default_off`,
so `squashEncouraged` never fires against a real instance, and
`test/fixtures/forge/glab_project_merge_policy.json` encodes the same wrong
value — the fixture cannot catch it. Correct the mapping: `default_on` →
encouraged, `default_off` → allowed, and fix the fixture.

*Defect B (audited).* `squashAlways` only flips `defaultMethod`
(`:449-453`); `mergeCommit` stays in `allowedMethods`, so the UI still offers a
plain merge at `gitlab_panel.dart:939-950` (the pulldown) and `:606-619` (the
row context menu). The wire call is already correct — the options sheet clamps
to `allowedMethods` (`gitlab_panel.dart:1139-1142`) — so today's behavior is a
**lying UI**: the user picks "Merge" and the app silently squashes.

Build the method list from the policy at `merge_plan.dart:442-447`:

```dart
final methods = <MergeMethod>[
  if (!squashAlways) MergeMethod.mergeCommit,
  if (!squashNever) MergeMethod.squash,
];
```

Target behavior: `never` → `[mergeCommit]`; `always` → `[squash]`;
`default_on` → `[mergeCommit, squash]` defaulting squash; `default_off`/null →
`[mergeCommit, squash]` defaulting mergeCommit.

*Tests:* `test/merge_plan_test.dart:219-225` (`squash never hides squash
method`) is the exact template for a `squashAlways` twin; the parser already
has a case at `:245-256`. Add a widget case mirroring
`test/gitlab_panel_test.dart:362-386`, overriding `repoMergePolicyProvider` to
`squashOption: 'always'` — note `_pump` hardcodes `const GlRepoMergePolicy()`
at `:174-176`, so it needs a `policy` parameter (precedent for an inlined
container at `:305-360`).

**3.2 — Forge list-row chips.** *(Tier B — the cheapest remaining 0002 item)*
Every input already exists: `PullRequest.labels` / `labelColors` /
`reviewDecision` are parsed and list-tier (`gh pr list --json` already requests
`reviewDecision` at `gh_service.dart:379-380`), `ForgeListRow.chips` is a
working slot (`forge_widgets.dart:194-300`), `MiniLabelChip(name, label)` is a
positional-arg widget (`:610-639`), and `parseLabelColor` tolerates gh's bare
hex (`label_colors.dart`). Copy the wiring verbatim from `forgeIssueRow`
(`project_sections.dart:259-286`), including the palette map built at
`github_panel.dart:390-394`.

Add chips to `_prRow` (`github_panel.dart:455-491`) and `_mrRow`
(`gitlab_panel.dart:509-545`). Both are called from two places each (Browse
list and Inbox), so a signature change touches both.

Review-state chip: GitHub maps `APPROVED` / `CHANGES_REQUESTED` /
`REVIEW_REQUIRED` (verified spellings, raw passthrough at `models.dart:197`).
**GitLab has no list-tier approval signal** — `MergeRequest` carries no
approvals field and `glab mr list` takes no field selector — so GitLab gets a
narrower "Approvals outstanding" chip driven by
`detailedMergeStatus == 'not_approved'`, with no approved counterpart.

*Related gap to fix in the same change:* `_prMatches`
(`github_panel.dart:250-256`) and `_mrMatches` do not include labels in the
filter fields, while `_issueMatches` does (`:264-269`). Once labels are visible
on rows, the filter should match them.

*Tests:* assert through rendered text / `find.byType(MiniLabelChip)` in
`test/github_panel_test.dart` and `test/gitlab_panel_test.dart` —
`forge_widgets.dart` has no direct unit tests.

**3.3 — Description/body preview in PR/MR detail.** *(Tier B)*
`PullRequest.body` and `MergeRequest.description` are already fetched by the
existing detail providers — no new request. Neither detail scaffold renders
them (`github_panel.dart:731-758`, `gitlab_panel.dart:778-805`).

*Prerequisite:* `_detailBody` (`project_sections.dart:554-559`) is private with
three call sites (issue body, release notes, milestone description). Promote it
to `forge_widgets.dart` as a public `ForgeBodyText`. This is also the single
swap point if markdown rendering is ever wanted across all five surfaces at
once.

Render plain selectable text, matching the issue-detail precedent
(`project_sections.dart:487-497`, with `CenteredHint('No description')` when
empty). **Do not** wire markdown in this step: a hardened renderer exists
(`MarkdownPreview`, `preview_view.dart:95-109`, links inert and images never
fetched), but adopting it changes five surfaces at once and deserves its own
decision.

*Layout note:* both bodies are a fixed three-part `Column` with exactly one
`Expanded` (the checks pane). Adding a description means either a second sized
region or making checks collapsible. `ForgeCommentsSection`'s fixed-height band
(`forge_widgets.dart:655-731`, height 160) is the in-house precedent.

**3.4 — Inbox "No blockers" filter.** *(Tier B — re-scoped from medium)*
`forge_inbox.dart:205-234` offers All / MRs|PRs / CI / Issues. The N+1 blocker
recorded in 0002 does not apply: `mergePlanForGitHub(pr: pr).canMergeNow` and
`mergePlanForGitLab(mr: mr).canMergeNow` already evaluate correctly on a
list-tier row at zero command cost, and are the app's own canonical answer.

Two structural facts constrain the shape:
* `typeFilter` is a single nullable `ForgeInboxKind?` — a radio, not a set.
  "Ready" is orthogonal (it only applies to change requests), so add a separate
  `bool` + its own visually-separated chip rather than a fifth kind.
* `ForgeInboxEntry` (`:22-32`) is opaque — key, kind, and a builder closure.
  The predicate must be computed in each panel's `_inboxChildren` where the
  domain object is in scope, either pre-filtering or adding a `ready` field.

Label it **"No blockers"**, not "Ready to merge": conflicts and branch
protection are invisible at list tier, and on GitLab a list row's
`detailed_merge_status` is frequently `unchecked`. Honest wording is the whole
point of the 0003/0002 known-vs-unknown discipline.

*Rejected alternative:* fetching details for visible rows only is not
implementable as described — the Inbox is a plain `ListView(children: [...])`
(`github_panel.dart:287`), not `.builder`, so every row is built eagerly and
"visible only" would be fiction.

*Tests:* extend `test/forge_inbox_test.dart:108-120` (the existing chip-filter
case). Note that harness has no `repoMergePolicyProvider` override — add one.

---

### Phase 4 — Complete the 0003 Phase 4 discovery layer

The largest item. `lib/core/git/branch_review_query.dart` (529 lines) is
complete, unit-tested, and entirely unreferenced by `lib/` except
`BranchMultiSelection`. Steps are strictly ordered: 4.1 unblocks compilation,
4.2 is independently shippable, 4.3 unblocks the facets, 4.4 consumes all three.

**4.1 — Collapse the duplicated stale helpers.** *(prerequisite, mechanical)*
`kBranchStaleDays` is declared at both `branch_dashboard_stats.dart:34` and
`branch_review_query.dart:12`, and `isBranchStale` / `isBranchStaleForReview`
are behaviorally identical. Nothing imports both today, so it compiles — the
moment 4.4 adds `branch_review_query.dart` to `branch_view_model.dart` or
`branch_detail.dart` it becomes an ambiguous import error at first use.

Keep one definition (prefer `branch_dashboard_stats.dart`, which already threads
`DateTime? now`), delete the other, and re-point `matchesBranchReviewFacets:247`
at it. **Thread `now:` while doing so** — `isBranchStaleForReview` currently
ignores clock injection, so facet tests cannot pin time.

**4.2 — Make Hide reversible and visible.** *(Tier C — independently shippable)*
`hiddenBranchNames` and `showHidden` round-trip through prefs
(`branch_workspace_prefs.dart:17,25`) and `_batchHide` writes them
(`branches_view.dart:621-655`), but **nothing reads either for display** and
there is no Unhide or Show Hidden affordance — a hidden branch is currently
unrecoverable from within the app. Ship this before 4.4; it stands alone and
closes a data-visibility hole.

* Add `hiddenBranchesProvider` as an exact twin of `pinnedBranchesProvider`
  (`pinned_branches.dart:24-37` — reads `branchWorkspacePrefsProvider`, returns
  a `Set<String>` of short names, empty on error).
* Filter at the single correct seam: `BranchViewModel.fromRefs`
  (`branch_view_model.dart:220-222`), where `filteredLocals` is derived.
  Everything downstream — the pinned/active/stale partition, `localsOnScreen`,
  `navigable`, both Browse and Review row builders, and range-select
  visibility — flows from it, so one insertion fixes all of them and keeps
  `_visibleLocalFullRefs()` in sync with `_buildRows()` for free.
  Leave `allLocalBranches` unfiltered: `_batchHide`, `_bulkDeleteSelected`, the
  conflict-scan list, and the base selector all depend on it.
* Pass the hidden set to `buildBranchDashboardStats` too (`:283-289`), or the
  Local/Active/Stale counts keep counting hidden branches.
* Add a Show Hidden toggle as a third `ToolIconButton` in the navigator filter
  row after the grouped toggle (`branch_navigator.dart:945-955` is the exact
  pattern) — `eye` / `eye_slash`, blue when active. Placement in the filter row
  rather than the Review-only sort area matters: hidden branches must be
  revealable from Browse too. Add an Unhide action for hidden rows when shown.
* Report skips. `_batchHide` silently omits current/worktree/pinned/base
  branches despite its own comment saying "report as skipped".

*Also fix:* `mergeLateLoadedPrefs` (`:269-293`) passes `hiddenBranchNames` and
`showHidden` straight through from `incoming`, so a late prefs load clobbers a
session-local hide. Only pins, `lastMode`, and `selectedBaseRefName` are
protected today; extend that protection.

*Tests:* prefs round-trip already covered (`test/branch_workspace_prefs_test.dart:16,24`).
Add: hidden branches leave the navigator; Show Hidden reveals them; Unhide
restores; guards are reported not silently dropped.

**4.3 — Build a typed forge-knowledge provider.** *(Tier C — hard prerequisite)*
`BranchReviewFacets` documents that `noRequest` "only matches known-empty forge
data", and `matchesBranchReviewFacets` enforces it via `ctx.forgeKnown`
(`:237-277`). **That flag has no possible source today.**
`branchForgeProvider` (`branch_forge_status.dart:158-179`) collapses five
distinct outcomes into the identical `const {}` — forge detection threw,
`Forge.none`, `Forge.unknown`, an upstream list threw (network, auth, rate
limit), and a genuinely empty repo — and never surfaces an error
(`hasError` is always false). Passing `forgeKnown: true` (the constructor
default) or `forgeAsync.hasValue` both read `true` in every error case, which
would list every branch in the repo as "No request" on a network blip.

Add a provider that does **not** swallow: await the same upstream providers
without the blanket `catch`, returning at minimum
`({Map<String, BranchForge> byShortName, bool known, Forge forge})`, where
`known` is true only when `forgeProvider` resolved to `github`/`gitlab` **and**
both the request-list and CI-list futures completed. Decide `Forge.none`
explicitly — either "no forge, so unknown" or "no forge, so no requests exist";
both are defensible, an accident of `{}` is not. Keep it
`autoDispose.family<..., String>` on `repoPath`, register it in
`repoScopedFetchFamilies` (`app_providers.dart:2589-2648`), and add the
registration assertion (template: `test/reflog_parse_test.dart:78-83`).

*Budget constraint:* it must **not** be watched in Browse mode. Note that
`branchForgeProvider` already is (`branches_view.dart:210`).

**4.4 — Wire the review-query layer into the UI.** *(Tier D)*
Depends on 4.1 and 4.3. `shapeReviewBranches` is **not** a drop-in for
`shapePhase1ReviewBranches`; the two share only `branches` and `summaries`.
Resolve each incompatibility deliberately:

* **Filter model changes shape.** `BranchReviewQuickFilter` is a 4-value
  exclusive enum; `BranchReviewFacets` is 9 composable fields. Mapping is
  one-way, so the detail-pane chips (`branch_detail.dart:233-301`), which
  toggle between a value and `.all`, must become per-facet toggles.
  `BranchDetail.reviewFilter` / `onReviewFilterChanged` change type, and
  `branches_view.dart:470-472` with them.
* **Sort grows 2 → 5** (`branch_navigator.dart:898-909`). The default flips to
  `smart`, changing the first visible row of every Review list;
  `test/branches_review_view_test.dart:129` asserts `find.text('Activity')` and
  must be updated. Note `BranchWorkspacePrefs.reviewSort` already defaults to
  `'smart'` and is never read.
* **`smart` makes ordering forge-dependent.** `smartAttentionRank` reads
  `ctx.forge`/`forgeKnown`, so rows visibly re-shuffle when forge data lands
  async. Either accept it, or gate `smart` on forge knowledge being resolved.
* **Search needs its own input path.** `filteredLocals` substring-filters on
  branch name inside `fromRefs:220-222` *before* any shaper runs, so
  `status:stale` typed into the existing box would first be matched against
  names and eliminate everything. Either pass `allLocalBranches` to the shaper
  in Review mode, or make `fromRefs` mode-aware. The former is cleaner but
  changes what the Review header count means (`branch_navigator.dart:656`).
* **Hoist the shaped list.** `_visibleLocalFullRefs()` (`:434-446`) and
  `_buildRows()` (`:645-661`) independently re-derive the same list; migrate
  both or ⇧-range selection will select offscreen rows. Prefer computing once.
* **"Mine" has no reliable identity.** `_matchesMine` uses
  `AppSettings.committerEmail`/`committerName`, both defaulting to `''` on the
  common setup where the user relies on the host's git config — so the facet
  would silently show nothing. Choose one: disable the facet when identity is
  unset, or add a `git config --get user.email` read (Review-only, to protect
  the Browse budget).
* **Adopt `preserveAfterRefresh`.** `BranchMultiSelection.preserveAfterRefresh`
  (`:488`) exists and is never called; richer filtering will drop selected rows
  more often. Replace the hard resets at `branches_view.dart:652` and `:759`.
* **Key spaces differ** and are easy to get wrong: `summaries` and
  `conflictRefNames` are keyed by full ref name, `forge` and `pinnedNames` by
  short name.

*Budget guard:* extend `_CountingGit` in
`test/branches_phase7_command_budget_test.dart:35-127` with any new override.
It currently tags only five methods, so a new command (a forge-knowledge call,
or `git config --get user.email`) would slip through the Browse gate at
`:202-211` unnoticed.

*Harness cost:* a new provider must be added to ~14 widget-test harnesses, or
default to a value that is safe when unwatched.

---

### Phase 5 — Deferred infrastructure

**5.1 — Branch-protection enrichment (0003 §3.7).** *(Tier C)*
Entirely absent. The `defaultBranch` half of §3.7 has since shipped
(`merge_plan.dart:76,94,105,125`); only protection remains.

* GitHub: page-walk `repos/{owner}/{repo}/branches` with
  `protected=true&per_page&page`, following `listMilestones`
  (`gh_service.dart:706-727`). **Not** the per-branch `/protection` endpoint —
  it is N round trips and 403s for non-admins, which would report "unknown" for
  ordinary collaborators. Never add `--paginate`: gh emits one array per page,
  which is invalid JSON (`api()` doc, `:330-340`). GitHub returns literal
  names, so no matcher is needed on this side.
* GitLab: page-walk `projects/:id/protected_branches` manually rather than
  passing `paginate: true` — `--paginate` is mutually exclusive with the `-i`
  HTTP-status cross-check (`glab_service.dart:414-454`), and dropping `-i`
  loses 4xx detection given glab's advisory exit codes. Names are wildcard
  patterns, so feed `gitlabProtectedBranchMatches`.
* Model it as a sealed tri-state `ProtectionKnowledge`
  (known-protected / known-unprotected / unknown), following the sealed idiom
  at `branch_review_query.dart:43`. Repo *rulesets* the branches API cannot
  represent must stay `unknown` — that is the Checkpoint-D warning case.
* *Fix while here:* `gitlabProtectedBranchMatches` (`:521-529`) maps `*` to
  `.*`, which crosses `/`, contradicting its own doc comment. Fix the comment
  or the regex, and add the `release/*` vs `release/a/b` case its tests lack.
* Insert protection as a new skip arm in `_bulkDeleteSelected`
  (`branches_view.dart:657-763`), which already has `repoPath` in scope.

**5.2 — Full §4.8 bulk-delete preflight table.** *(Tier C — depends on 4.3, 5.1)*
`branch_bulk_delete_sheet.dart` (235 lines, **zero test coverage**) shows a flat
"Will delete (n)" list. Replace with the specified
`Branch | Tip | vs base | Worktree | Protection | Request | Decision` table plus
per-row checkboxes and the unknown-protection warning above the list. Add
`protection` and `request` fields to `BulkDeleteCandidate` (`:13-25`), widen the
sheet (`:29-51` is `width: 520`, too narrow for seven columns), add a third
partition for eligible-but-unchecked (`:72-85` partitions only on
`skipReason == null`), and group results into Deleted / Skipped / Changed since
review / Failed (`:178-201`).

*Tests:* `git` is a constructor parameter, not a provider read, so a widget test
needs no Riverpod override. Copy the launcher-button pump from
`test/create_tag_sheet_test.dart:56-104` (a self-popping sheet needs a poppable
route beneath it).

**5.3 — GitLab labels/releases pagination.** *(Tier C)*
`glab_service.dart:556-573` caps `labels(first: 100)` and `releases(first: 20)`
with no cursor paging; truncation is merely surfaced via `forgeCountLabel`.
**The identical defect exists on the GitHub side** (`gh_service.dart:1140-1146`)
— scope the change to both or state explicitly that it is GitLab-only.

Migrate to REST page-walks (`projects/:id/labels`, `projects/:id/releases`,
both `per_page` max 100) following `listMilestones`. Add `fromGlabRest`
factories rather than editing the GQL ones (`forge_dashboard.dart:131,260`) —
REST uses `name` where GraphQL uses `title`, and snake_case `tag_name` /
`released_at`. Leave `with_counts` off; it is a per-label aggregation that
slows large projects and the dashboard does not use counts.

*Consequence to decide:* `_runJson` discards response headers
(`bodyAfterHeaders`), so REST cannot supply `X-Total` — termination must use the
short-page rule, and `labelsTotal`/`releasesTotal` become null, losing the
"N of M" header. Either keep a GraphQL `count` fetch for the total and use REST
for rows, or accept a bare count. Labels and Releases also lack the
`ShowMoreRow` + scope-provider machinery that Issues and Milestones have
(`project_sections.dart:120-137`), so paging means adding it.

*Call sites that break:* `create_mr_form.dart:238` and
`create_pr_form.dart:228` both read `dashboard?.labels`.

**5.4 — Curated forge activity labels.** *(Tier D — 41 call sites)*
Plan 0005 claimed curated descriptors in gh/glab; there are none
(`grep -n "operation:"` → zero hits in both). Every non-read forge command is
labeled `'Update forge'` (`app_providers.dart:307-338`).

`ActivityCommandExecutor` needs **no change**: it already resolves
`operation ?? resolveDescriptor(...)`, so a service-supplied descriptor wins.
Mirror the GitService pattern instead of threading a label through the executor
— `GitService._run` (`git_service.dart:6026-6071`) takes `label` as a required
positional and builds the descriptor at one chokepoint.

Three edits per service: add `onOperationEvent` to the `GhService`/`GlabService`
constructors (plan 0005 called for this and it was never done) and inject it in
the providers; add a private `_runMutation(repoPath, argv, label, {lane, kind,
visibility})` that builds the descriptor and collapses the 31 duplicated
`if (!result.isSuccess) throw` blocks; add an optional label to `api()` /
`_runJson()` for the 10 REST-routed mutations. The generic resolver stays as the
safety net, exactly as on the git side.

41 mutating methods need labels (21 in `gh_service.dart`, 20 in
`glab_service.dart`); the dossier enumerated them with suggested wording.

*Test note:* `MockExecCall` (`test/helpers/mock_executor.dart`) accepts and
discards `operation` — adding descriptor assertions means extending that shared
record, which touches every service test file. `ActivityCommandExecutor` has
zero coverage; model a new test on `test/scoped_forge_executor_test.dart`
(the sibling decorator's test) and preserve the "wire descriptor excludes argv,
stdin, environment, and tokens" invariant at
`test/operation_activity_test.dart:114-120`.

*Also fix:* `executeStream` forwards `operation` but never calls
`resolveDescriptor` — an asymmetry with `execute`.

**5.5 — Shared file-selection seam (0004 M13).** *(Tier C)*
Worse than recorded: `FileView` is constructed **twice** in `RepoStatusView`
(docked pane `:1490`, navigator Files tab `:2449`), each with its own
`_selectedPath`, plus `RepoStatusView`'s own `_selectedPaths` — three
independent selections, mutually exclusive by the `navigatorMode != files`
guard at `:1488`, which is exactly what loses the highlight on a mode flip.

Use `RepoChangeSelection` (`repo_change_model.dart:79-215`) as the payload — it
is already immutable, tested, and carries the `section` field plus the
reconcile/rehome logic every caller depends on. **Do not** use
`WorkspaceSelection` (`repository_workspace_models.dart:31-54`): minted by plan
0005, referenced nowhere in `lib/`, and lacks `section`.

Shape: `NotifierProvider.family<RepoFileSelection, RepoChangeSelection, String>`
keyed by bare `repoPath`, matching `worktreeSubPageProvider`
(`worktree_tabs.dart:123-163`). Do **not** register it in
`repoScopedFetchFamilies` — that list is fetch-only; add one explicit line to
`_invalidateRepoState()` near `app_providers.dart:1040`.

Highest-leverage edit: repoint the three getter/setter pairs at
`repo_status_view.dart:111-138` at the provider. All 13 writes and 14 reads go
through them and stay untouched. Both surfaces then need a `ref.watch` for
rebuilds that `setState` used to provide free. In `FileView`, delete
`_selectedPath` (`:79`) and its five sites; keep `onOpenFile` as the carrier of
the staged/untracked derivation so exactly one place decides the section.
Do not add a constructor param — its 7 test call sites all use the 3-arg form.

*Regression to decide explicitly:* a **clean** file selected in the tree maps to
`unstaged` with no matching row in the Changes list, so the next
`_syncSelectionToStatus` reconcile (`:581`) will clear it — a regression that
does not exist today, since the tree keeps its own highlight. Either exempt
tree-originated selections from reconcile, or accept the drop and say so.

*Bonus:* a multi-selection in Changes will light up N rows in the tree, and the
hidden-selection banner (which already renders in Files mode,
`repo_change_navigator.dart:208`) becomes coherent rather than misleading.

**5.6 — Disposable-sshd transport tests.** *(Tier C)*
Verified feasible on this machine, non-root: two ed25519 keypairs, a config with
`StrictModes no` (load-bearing under `/private/tmp`), `ListenAddress 127.0.0.1`,
`UsePAM no`, and `/usr/sbin/sshd -f <config> -D -e`. A full round trip
succeeded.

Place it in `test/` with the existing `integration` tag — **not**
`integration_test/`. dartssh2 is pure Dart and `SSHCommandExecutor` /
`SSHClientManager` need no Flutter engine, so it runs under plain
`flutter test` in seconds and avoids the code-signing/entitlements wall
documented at `integration_test/history_search_test.dart:9-14`. Precedent:
`test/ssh_transport_hardening_test.dart:106-144` already binds a real
`ServerSocket`. Wiring is `SSHCommandExecutor(managerPointedAtLocalhost)`;
`privateKey` is PEM **text**, not a path.

Honest coverage of the four paths ACTION_PLAN calls untestable:
* malformed UTF-8 decode (`ssh_command_executor.dart:697,705`) — **fully
  covered**, the strongest win;
* open+drain timeout (`:757-775`) — **drain half only**; the open-still-pending
  branch needs a stalling shim, since real sshd opens channels instantly;
* auth-handshake timeout (`:576-584`) — **not covered**; real sshd answers
  promptly, and the existing stalled-socket fake is the better tool;
* pending-close — already covered for the stalled case; sshd adds the
  authenticated variant.

State that honestly in the test file rather than implying the gate is closed.
Bonus coverage worth listing: end-to-end `GitService` over SSH against a temp
repo (proving `ShellEscaper` + the `CommandFormatter` prelude against a real
POSIX shell), gzip reads, `OutputByteBudget` overflow, `executeStream`, and the
dual-client degraded path via `MaxSessions 1`.

*Teardown discipline:* OpenSSH ≥ 9.8 re-execs `/usr/libexec/sshd-session`, so
kill via the `PidFile`/process group, not a single PID, or `flutter test` hangs.

**5.7 — GitHub detail-field expansion.** *(Tier C, optional)*
`_prDetailJsonFields` (`gh_service.dart:387-393`) omits `reviewRequests`,
`latestReviews`, `statusCheckRollup`, `commits` from plan 0002 §3.1. Note there
is no `_prListJsonFields` constant — the list fields are an inline literal at
`:379-380` — and no detail-merge step (`detail ?? pr` is whole-object
substitution), so a new field is parsed once in `fromJson` and is simply null on
list rows.

Add `reviewRequests`, `latestReviews`, `statusCheckRollup`. **Omit `commits`** —
it returns the full commit list (megabytes on a large PR) and buys little over
the existing `additions`/`deletions`/`changedFiles`; fetch it lazily behind a
disclosure if ever wanted. The 50 MiB budget (`command_drain.dart:21-25`) is not
the constraint; latency on the UI path is.

Payoff: the readiness strip can name *who* is blocking and *which* check failed
instead of the generic "Required reviews are still outstanding" and "Merge is
blocked by branch protection or required checks"
(`merge_plan.dart:197-247`). Extend both fixtures. `merge_readiness.dart` has
zero test references — a new `test/merge_readiness_test.dart` is greenfield.

---

### Phase 6 — Hybrid native title bar (MADR 0006)

**6.1 — Write `0006-PLAN-hybrid-native-title-bar-context-bar.md` and execute
the bounded slice.** *(Tier D — gated on live verification)*

This belongs in its own plan file paired to MADR 0006, per the repo's numbering
rule. Record these findings in it so it does not start from scratch:

*Smaller than the MADR implies.* The main window is **already `.titled`** —
from `macos/Runner/Base.lproj/MainMenu.xib:333-334`. Only `titleVisibility`,
`titlebarAppearsTransparent`, and `.fullSizeContentView` differ, and all three
are set from Dart. The flip is one line: `lib/main.dart:54`,
`TitleBarStyle.hidden` → `normal`. Removing `.fullSizeContentView` makes AppKit
reserve the bar and drop the content origin automatically — no Flutter-side top
padding needed. Secondary windows need **no** work: they are already `.titled`
with `window.title` and `.darkAqua` (`SecondaryWindowController.swift:162-197`),
so the MADR's "must change together" consequence overstates the coupling.

*Two hard blockers, not polish.*
1. `MainFlutterWindow.swift` never sets `appearance`. The app is dark-only, so
   a user in Light Mode gets a light title bar bolted to a `#191A1F` app. Add
   `self.appearance = NSAppearance(named: .darkAqua)`, exactly as
   `SecondaryWindowController.swift:170-173` already does.
2. `Sidebar` must pass `topOffset: 0` (`app_shell.dart:932-936`). macos_ui
   defaults it to 51.0 and spends it as a bare spacer, which would double the
   clearance a real title bar already provides.

*Highest-risk unknown.* `FileView`'s `TransparentMacOSSidebar` + `BlendMode.clear`
hole-punch (`file_view.dart:460-471`) depends on the `WindowManipulator`
vibrancy view, and removing `.fullSizeContentView` moves the content-view
origin. Whether they still align is not statically determinable — build with
`./build_macos.sh --unsigned` and screenshot the Files pane specifically.

*No drag-region work.* There is no `DragToMoveArea` anywhere in the repo
(repo-wide search returns exactly one hit, `main.dart:54`). Dragging currently
relies on AppKit's transparent title-bar strip overlaying the tab row; after
the flip it becomes fully native. That is a fix, not a regression.

*Decide before building:* three stacked bands at the 640×480 floor — title bar
(~28) + tab strip (36, only at ≥2 tabs) + context bar (46 compact) = 110pt of
480. The cleanest mitigation is raising `WindowBoundsStore.minHeight` from 480
to ~508 so content keeps its 480, which must stay above the viewer (420×260)
and diff pop-out (420×280) floors. Also foreclose native `NSWindow` tabbing
explicitly: each tab owns its own `ProviderContainer` inside one engine
(`tabs_host.dart:337-343`), so native tabs would require one window per tab.

*Test impact: expected zero.* The 48 workspace goldens are synthetic — the
fixture hardcodes a 52pt bar and never mounts `AppShell`, `MacosWindow`, or
`TabStrip`. `test/workspace_responsive_test.dart` is the guard if context-bar
heights change; `test/app_shell_test.dart` guards the 760 sidebar breakpoint.

---

### Phase 7 — Requires a MADR or the maintainer

Not executable within this plan. Listed so the backlog is complete.

**7.1** Phase 12 items, each needing its own MADR: submodules, Git LFS (a 2026-07
assessment exists; the transport fork — host-curl vs Mac-HTTP, forced by the
50 MiB no-streaming constraint — is the blocking decision), Code Owners,
stacked branches.

**7.2** Commit signing. Currently forced off via `--no-gpg-sign`
(`git_service.dart:3219`, `:4485`) with user-facing copy saying "always"
(`settings_sheet.dart:199`). The local backend could sign today; the SSH backend
needs agent forwarding or `gpg.format=ssh`. Needs a MADR.

**7.3** The observational Phase 9 gate from plan 0005: the measured 25%
interaction reduction, keyboard and VoiceOver task completion, SSH runs, and
profile frame timings. The protocol and fixtures are fully specified in
`docs/0005-UX-BASELINE-…`; the blocker is operational, not code.

**7.4** Maintainer acceptance of the 48 workspace goldens in
`test/goldens/workspace/` (currently "pending review").

**7.5** Checkpoint E sign-off for 0003.

## Verification

Run after every step, and before staging anything:

```sh
flutter analyze                      # must be clean, first pass
flutter test                         # full suite; minutes, includes `integration`
flutter test test/<file>_test.dart   # the step's own tests, while iterating
```

Never run `live-forge` tests as part of this plan.

Per-phase acceptance:

* **Phase 0** — every corrected document agrees with MADR 0007
  §Per-document findings; no claim in `docs/` asserts an unimplemented item as
  complete.
* **Phase 1** — each defect has a test that fails before the fix and passes
  after. For 1.1 specifically, assert the connect future *resolves* (the bug is
  a hang, so a naive test would time out rather than fail informatively).
* **Phase 2** — each item the 0004 documents claimed complete is now either
  implemented with a test, or explicitly re-scoped in Phase 0.
* **Phase 3** — `allowedMethods` never contains a method the forge policy
  forbids; no UI offers an action the plan would silently rewrite.
* **Phase 4** — the Browse command-budget gate
  (`branches_phase7_command_budget_test.dart:202-211`) still passes with
  `_CountingGit` extended to cover every newly added command; no facet claims
  knowledge it does not have.
* **Phase 5** — new forge reads follow the manual page-walk idiom with `-i`
  retained; no new `--paginate` usage.
* **Phase 6** — the confirmation criteria in MADR 0006, plus a screenshot of the
  Files pane proving the vibrancy hole-punch survives.

## Rollout and Rollback

**Sequencing.** Phase 0 and Phase 1 are independent of everything else and
should land first — Phase 0 because stale docs actively mislead the next cycle,
Phase 1 because those are live defects. Phases 2 and 3 are independent of each
other and of Phase 4. Within Phase 4 the order is strict: 4.1 → (4.2 | 4.3) →
4.4. Phase 5 items are mutually independent except 5.2, which needs 4.3 and 5.1.
Phase 6 is gated on a live macOS preview and should not be attempted in the same
work cycle as Phase 4.

**Rollback.** Every step is confined to its own files, so `git revert` of a
single step's changes is sufficient — with three exceptions worth staging
separately so they can be reverted alone:

* **4.4** changes visible Review ordering (the `smart` default) and the shape of
  the filter chips. If it regresses, reverting restores
  `shapePhase1ReviewBranches` intact, since 4.1–4.3 leave it in place.
* **5.5** changes selection behavior across two surfaces; the reconcile decision
  is the risky part. Revert restores three independent selections — the current
  behavior — with no data loss.
* **6.1** changes native window chrome and cannot be validated by the test
  suite. Land it alone, verify by build and screenshot, and keep the one-line
  `main.dart:54` flip revertible independently of the Swift appearance change
  (which is a strict improvement and can stay either way).

**No migrations.** Nothing in this plan changes a persisted schema.
`BranchWorkspacePrefs` already carries `hiddenBranchNames` and `showHidden` at
v1 (4.2 only starts reading them), and 5.3's REST migration changes wire parsing
only, not stored data.
