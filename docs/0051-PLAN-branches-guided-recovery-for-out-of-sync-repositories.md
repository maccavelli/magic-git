---
status: "proposed"
date: 2026-09-17
associated-madr: "0051-MADR-branches-guided-recovery-for-out-of-sync-repositories.md"
---

# Implement: Branches gains named sync states and guided reconciliation for out-of-sync repositories

Associated MADR: [0051-MADR-branches-guided-recovery-for-out-of-sync-repositories.md](0051-MADR-branches-guided-recovery-for-out-of-sync-repositories.md)
(read Amendment 0051.1 first — it corrects three scope claims this plan is built against the corrected
version of, not the original)

## Goal

Implement MADR 0051's chosen option (C), corrected by Amendment 0051.1: fix the confirmed
`_setUpstream` validation bug; bring the "More" menu (renamed **Advanced**) to parity with the
right-click context menu; add a per-branch `BranchSyncState` computed almost entirely from data already
fetched; replace the bare ahead/behind count with a named, explained state in both the navigator row and
the detail pane; add one small new `GitService` primitive (a lightweight common-ancestor check, extracted
from existing merge-preview logic, not a new `mergeBase()` OID-returning method); a "Reconcile…" action
for a diverged or unrelated-histories **current** branch, following the existing `chooseAction<T>`
guardrail-dialog pattern already used by `_dropOnCurrent`; an `allowUnrelatedHistories` merge option; a
bulk stale-branch cleanup after Fetch & Prune; and a cross-tab link from Branches to the Status tab's
existing interrupted-operation banner.

## Scope

### In

| File | Change |
| --- | --- |
| `lib/core/git/git_service.dart` | `merge()` gains `allowUnrelatedHistories`; a new lightweight `haveCommonAncestor` primitive extracted from `_mergeTreePreviewUnlocked` (behaviour-preserving refactor) |
| `lib/core/git/branch_sync_state.dart` | **new** — `BranchSyncState` enum and its pure classifier function |
| `lib/features/branches/branches_view.dart` | `_setUpstream` validation fix; `_reconcile`/`_runResetToCurrentUpstream`; bulk stale-branch cleanup after `_fetchPrune`; wiring for the new menu items |
| `lib/features/branches/branch_navigator.dart` | context menu gains Reconcile (head branch only) and parity items already covered by Phase 2; `_divergenceCluster` renders the new state labels |
| `lib/features/branches/branch_detail.dart` | "More" → **Advanced**; menu parity; new callout-chain entries for diverged/no-upstream/unrelated-histories/stale; Reconcile wiring |
| `lib/features/common/pending_op_banner.dart` | **new** — `PendingOpBanner` extracted from `repo_status_view.dart`'s private `_pendingBanner`/`_abortPending`/`_continuePending` |
| `lib/features/repository/repo_status_view.dart` | its inline pending-op banner code replaced by the extracted widget (behaviour-preserving) |
| `test/branches_actions_test.dart` | the existing divergence-badge assertion updated for the new label; new tests for every item above |
| `test/pending_op_banner_test.dart` | **new** — the extracted widget's own tests, migrated from whatever covers it today in `repo_status_view_test.dart` |

### Out

* **Proactive background conflict scanning** (MADR option D) — explicitly deferred to its own future
  record.
* **`git fsck --lost-found` dangling-commit recovery** — a single-clone scenario the existing Recovery
  sheet doesn't cover, noted in the MADR as a separate, smaller question this record does not decide.
* **Any change to the Recovery sheet, the undo journal, or `UndoOpKind`** — the Reconcile "Reset" action
  reuses the existing instrumented `reset()`, which already journals `UndoOpKind.resetHard`; nothing
  about the journal itself changes.
* **Any change to `_dropOnCurrent`, `DropOp`, or drag-and-drop "combine branches."** Amendment 0051.1
  said Reconcile "extends this existing mechanism" — on closer reading (Grounding, below) that mechanism
  is the `chooseAction<T>` **dialog primitive**, not the `DropOp` enum itself: `DropOp`'s two operations
  are framed as "bring branch A and branch B together," while Reconcile is "this branch versus its own
  upstream," a different relationship with a third, destructive option neither drag-and-drop nor `DropOp`
  needs. A sibling enum and method reusing the same dialog primitive is more correct than overloading
  `DropOp` with a case it wasn't designed for. `_dropOnCurrent` is not touched.
* **Review-mode's `aheadOfBase`/`behindBase` and `ComparisonAncestry`** — `BranchSyncState` is a
  deliberately separate axis (vs the branch's own upstream), computed from `GitRef` fields, never from
  `BranchReviewSummary`. Conflating the two would silently answer the wrong question for a branch whose
  review-mode comparison base differs from its upstream (the common case: base is `main`, upstream is
  `origin/<branch>`).

## Rules for every phase

1. **Deviations stop the work.** A wrong step, a file not listed, or a pre-existing defect this plan
   does not cover is reported with evidence and real resolutions, and waits for the maintainer. Docs are
   amended before work continues.
2. **Commits** use exactly `git commit --no-edit`. Code and docs are never in one commit. Nothing is
   pushed unless the maintainer asks in that same turn.
3. **The gate before every code commit:** `flutter analyze` clean; `dart format --output=none
   --set-exit-if-changed` on each staged `.dart` file; the phase's targeted tests; then `flutter test` in
   full. Exit statuses are captured in variables, never piped into a filter.
4. **Every new guard is seen to fail** against a deliberately broken copy in a detached scratch worktree
   (`git worktree add --detach`), never by dirtying the tree, and the failure output goes in the
   execution record.
5. **Widget tests follow `test/branches_actions_test.dart`'s established harness** — a `_FakeGit extends
   GitService` overriding only the methods under test, a `ProviderContainer` overriding
   `gitServiceProvider`/`refsProvider`/`remotesProvider`/`remoteTagsProvider`/`branchForgeProvider`/
   `mergedBranchesProvider`, `UncontrolledProviderScope` + `MacosApp` + `pumpAndSettle()`. No new harness
   is built where this one already fits.

## Grounding

Verified against HEAD (`e5e2eea`) during plan drafting; this supersedes the MADR's own F-numbered
grounding wherever the two disagree (Amendment 0051.1 records why).

**`GitRef`** (`git_service.dart:156-`) already carries `ahead`, `behind` (both `int`, from
`%(upstream:track)` in the *same* `for-each-ref` call that builds the whole `refs` list — zero new git
calls for these), `upstream` (nullable short name, e.g. `origin/main`), `upstreamGone` (`bool`),
`commitOid`, `isHead`, `isLocalBranch`, `isRemote`, `shortName`. No field precomputes "does a matching
remote-tracking ref exist" — that's `refs.any((r) => r.isRemote && r.shortName == '<remote>/<name>')`
against the already-fetched list, same pattern `hasConfiguredRemote` already uses
(`branches_view.dart:602`).

**The upstream bug, precisely.** `_publishBranch`'s menu gate is already `b.upstream == null`
(`branch_detail.dart:614-615`, `branch_navigator.dart:773`) — already correct, nothing to hide.
`_setUpstream` (`branches_view.dart:1650-1666`) is a free-text `promptText` defaulting to
`origin/$name` but accepting *any* typed target, then calling `git.setUpstream(repoPath, name, target)`
— `git branch --set-upstream-to=$target` — with **no check that `target` resolves to a real ref**.
That's the whole bug: not a menu-visibility problem, a missing validation.

**`_mergeTreePreviewUnlocked`** (`git_service.dart:3918-3936`) already runs exactly the check this plan
needs, just embedded in a larger, more expensive method:

```dart
Future<BranchMergePreview> _mergeTreePreviewUnlocked(
  String repoPath, {
  required String baseOid,
  required String branchOid,
}) async {
  final mb = await _executor.execute(
    repoPath: repoPath,
    extraEnv: _scopeEnvFor(repoPath),
    gitArgs: ['git', 'merge-base', '--end-of-options', baseOid, branchOid],
    retries: _readRetries,
    lane: ExecLane.read,
  );
  final mbOut = mb.stdout.trim();
  if (mb.exitCode == 1 && mbOut.isEmpty) {
    return BranchMergePreview.unrelated();
  }
  if (!mb.isSuccess || !isFullGitOid(mbOut)) {
    throw GitException('git merge-base failed', mb);
  }
  // ...then runs `git merge-tree --write-tree`, which this plan's classifier must NOT pay for.
```

Its own doc comment confirms `baseOid`/`branchOid` are **any two full OIDs**, not tied to review-mode
semantics — `mergeTreePreview` is already reusable in principle. It is not reused *as-is* here because
calling it would also run the (comparatively expensive) `merge-tree --write-tree` step for every
ordinarily-diverged branch, when classification only needs the merge-base answer. **The correct move is
extracting the merge-base sub-check into its own small method**, used by both the existing
`_mergeTreePreviewUnlocked` (refactored to call it, behaviour-preserving) and the new classifier (Phase
1). This is the one genuinely new (if small) GitService primitive Amendment 0051.1 refers to.

**Divergence rendering, exact insertion points.** `_divergenceCluster`
(`branch_navigator.dart:1747-1812`): Browse-mode branches (`:1775-1811`) render identically whether only
one side of ahead/behind is nonzero (fast-forward) or both are (diverged) — the `if` chain to extend.
`branch_detail.dart:510-610` (`_localDetail`) already has a priority-ordered "next action" callout chain
via `_calloutBox(context, color, icon, message)`, ending with `ahead>0 && behind==0`; it falls through to
nothing for diverged/unrelated/unpublished. The insertion point is exact: after line 609's closing `}`,
before line 611's `// Phase 5 primary-action precedence (§4.6).` comment — a precedented mechanism to
extend, not a new one to invent.

**The Reconcile dialog's shape, precisely modeled on an existing one.** `_dropOnCurrent`
(`branches_view.dart:1405-1428`) already does exactly the "named-strategy guardrail dialog" pattern MADR
option C calls for, via the generic `chooseAction<T>` primitive (`lib/features/common/actions.dart:61-`,
full signature: `chooseAction<T>(context, {title, message, primaryLabel, primaryValue, secondary:
List<(String, T)>})`, one primary button plus stacked secondary buttons, `null` on dismiss):

```dart
final op = await chooseAction<DropOp>(
  context,
  title: 'Combine with ${current.shortName}',
  message: 'Bring "${source.shortName}" and the current branch together.',
  primaryLabel: 'Merge "${source.shortName}" into "${current.shortName}"',
  primaryValue: DropOp.merge,
  secondary: [
    ('Rebase "${current.shortName}" onto "${source.shortName}"', DropOp.rebase),
    ('Cancel', DropOp.cancel),
  ],
);
```

**Both `_runMerge` and `_runRebaseOnto` already exist and operate on the current branch** — `rebaseOnto`
and `reset` both, per their own doc comments and git's own model, act on **HEAD**. Merge's target is also
always current HEAD (a branch is merged *into* current, never into an arbitrary other branch). This
means Reconcile — a branch's own relationship to its own upstream — is only directly actionable while
that branch **is** the checked-out one (`b.isHead`), the opposite gating from the existing "Merge into
current" items (`if (!b.isHead)`, offered for *other* branches to bring into the current one).

**Menu items, exact current lists** (unchanged from the MADR's F4/F5, re-verified): context menu
(`branch_navigator.dart:1936-2020`) has Merge into current / Merge (no fast-forward) / Merge (fast-forward
only) / Squash merge / Set upstream… / [Unset upstream, if set] that "More" (`branch_detail.dart:691-753`)
lacks.

**Pending-op banner, exact extraction boundary.** `_pendingBanner` (`repo_status_view.dart:1535-1567`) is
a private method on `_RepoStatusViewState`, not a standalone widget, needing `_abortPending`/
`_continuePending`/`_pendingVerb` (`:1470-1522`) — all closures over `git`/`repoPath`/`ref`, none over
Status-view-only state, **except** `_clearSelection` (conflict-selection-specific, called after abort —
does not travel with the extraction; the extracted widget's `onAborted` callback lets each caller decide
what to clear, defaulting to nothing). `pendingOpProvider(repoPath)` (`:1632`) is already a repo-keyed
family, trivially watchable from Branches.

**Undo surfacing has no menu — say the right thing.** There is no "Undo" menu item; `UndoToastOverlay`
(`lib/features/common/undo_toast.dart`) shows a bottom-center toast ("`<operation>` — ⌘Z to undo") for
5 seconds after any journaled operation. The Reconcile "Reset" dialog's copy says "reversible with ⌘Z or
the toast that appears," never "check the Undo menu."

**Test that will break, and must be updated as part of the same change.**
`test/branches_actions_test.dart` (~line 119-125) — `'divergence badges: ↑/↓ for a diverged branch,
"gone" for a deleted upstream'` — asserts `find.text('↑2 ↓1')` against a fixture with `ahead: 2, behind:
1`, i.e. an already-diverged fixture. Once diverged renders as a named state instead of a raw count, this
assertion must change to match — Phase 3 does this in the same commit as the rendering change, never
leaving it red.

## Implementation Steps

### Phase 0 — preconditions

0.1 `flutter --version | head -1` matches `FLUTTER_VERSION` in `build_macos.sh` (**3.47.2**), and
`flutter pub get --enforce-lockfile` says `Got dependencies!`.

0.2 Baseline, recorded in the execution record: `flutter test` in full, and `git status --short` empty.

### Phase 1 — the upstream validation fix (smallest, self-contained, no new git capability)

1.1 `branches_view.dart`'s `_setUpstream` validates the typed target against the already-fetched refs
before calling `git.setUpstream`:

```dart
Future<void> _setUpstream(GitService git, GitRef branch) async {
  if (busy) return;
  final name = branch.shortName;
  final target = await promptText(
    context,
    'Set upstream',
    placeholder: 'origin/$name',
    initial: branch.upstream ?? 'origin/$name',
    description:
        'The remote-tracking branch (remote/branch) that pull, push, and '
        'the ahead/behind badges follow.',
    confirmLabel: 'Set Upstream',
    validate: (value) {
      final problem = refNameProblem(value);
      if (problem != null) return problem;
      final refs = ref.read(refsProvider(repoPath)).value ?? const [];
      final exists = refs.any(
        (r) => r.isRemote && r.shortName == value.trim(),
      );
      if (!exists) {
        return 'No remote-tracking branch "$value" exists yet. If this '
            'branch has never been pushed, use Publish instead.';
      }
      return null;
    },
  );
  if (target == null || !mounted) return;
  await runGuarded(() => git.setUpstream(repoPath, name, target));
}
```

`validate`'s existing signature (used by `refNameProblem` today) already returns `String?` (an error
message or `null`), confirmed against `promptText`'s call in this same method — no new dialog plumbing.

1.2 **Seen to fail**, in a detached scratch worktree with only the `validate` addition reverted: typing a
target with no matching remote-tracking ref and confirming reaches `git.setUpstream`, which fails with
git's raw `--set-upstream-to` error rather than the new, actionable message.

1.3 New test in `test/branches_actions_test.dart`: `'Set upstream refuses a target with no matching
remote-tracking branch, naming Publish instead'` — types a nonexistent target, asserts the dialog does
not close and the message is shown; `'Set upstream accepts a target that matches a real remote-tracking
branch'` — positive case, unchanged behaviour.

1.4 Gate (rule 3), then **commit (code)**.

### Phase 2 — rename "More" to "Advanced" and close the menu-parity gap

2.1 `branch_detail.dart:750`: `MacosPulldownButton(title: 'More', items: moreItems)` →
`MacosPulldownButton(title: 'Advanced', items: moreItems)`.

2.2 `moreItems` (`branch_detail.dart:692-748`) gains, in the same relative position the context menu
uses (after "Merge into current", before "Set upstream…"):

```dart
if (!b.isHead) ...[
  MacosPulldownMenuItem(
    title: const Text('Merge (no fast-forward)'),
    onTap: busy ? null : () => onMerge(git, b.shortName, MergeMode.noFf),
  ),
  MacosPulldownMenuItem(
    title: const Text('Merge (fast-forward only)'),
    onTap: busy ? null : () => onMerge(git, b.shortName, MergeMode.ffOnly),
  ),
  MacosPulldownMenuItem(
    title: const Text('Squash merge'),
    onTap: busy ? null : () => onMerge(git, b.shortName, MergeMode.squash),
  ),
],
```

and, immediately after "Set upstream…":

```dart
if (b.upstream != null)
  MacosPulldownMenuItem(
    title: const Text('Unset upstream'),
    onTap: busy ? null : () => onUnsetUpstream(git, b.shortName),
  ),
```

`onUnsetUpstream` is already a parameter `BranchDetail` receives from `branches_view.dart` (used by the
context menu's equivalent item) — confirm its exact parameter name in `branch_detail.dart`'s constructor
before wiring; if it is not already threaded to `BranchDetail`, that is a deviation (a missing
constructor parameter this plan's file list did not anticipate), reported before proceeding.

2.3 New/updated tests in `test/branches_actions_test.dart`: `'the Advanced menu offers every action the
context menu does, for the same branch'` — opens both for one non-head, upstream-set branch fixture and
asserts the item-label sets are equal (a set-equality assertion, not a fixed list, so it also fails if
either menu gains a *new* item the other lacks in the future — a standing regression guard, not just a
one-time fix). Any existing test asserting the literal string `'More'` (grep before editing) is updated
to `'Advanced'`.

2.4 Gate, then **commit (code)**.

### Phase 3 — `BranchSyncState`

3.1 **New** `lib/core/git/git_service.dart` method, extracted from `_mergeTreePreviewUnlocked`'s first
step (behaviour-preserving refactor — `_mergeTreePreviewUnlocked` calls this instead of inlining the
same `_executor.execute` call):

```dart
/// Whether [a] and [b] share a common ancestor (`git merge-base`) — the
/// cheap half of merge-tree conflict prediction, without paying for
/// `merge-tree --write-tree`. Used by [mergeTreePreview]'s unrelated-history
/// short-circuit and by branch-vs-upstream sync classification
/// ([BranchSyncState]), which needs the same answer for a fraction of the
/// branches mergeTreePreview would otherwise be asked about.
Future<bool> haveCommonAncestor(String repoPath, String a, String b) async {
  final mb = await _executor.execute(
    repoPath: repoPath,
    extraEnv: _scopeEnvFor(repoPath),
    gitArgs: ['git', 'merge-base', '--end-of-options', a, b],
    retries: _readRetries,
    lane: ExecLane.read,
  );
  if (mb.exitCode == 1 && mb.stdout.trim().isEmpty) return false;
  if (!mb.isSuccess) throw GitException('git merge-base failed', mb);
  return true;
}
```

`_mergeTreePreviewUnlocked` becomes:

```dart
Future<BranchMergePreview> _mergeTreePreviewUnlocked(
  String repoPath, {
  required String baseOid,
  required String branchOid,
}) async {
  if (!await haveCommonAncestor(repoPath, baseOid, branchOid)) {
    return BranchMergePreview.unrelated();
  }
  // ...unchanged merge-tree step below.
```

3.2 **New** `lib/core/git/branch_sync_state.dart`:

```dart
/// A branch's sync state relative to its OWN upstream — deliberately a
/// separate axis from [BranchReviewSummary]'s ahead/behind-vs-review-base,
/// which compares against the review workspace's chosen base (often `main`),
/// not the branch's tracking remote. Conflating the two answers the wrong
/// question whenever they differ, which is the common case.
enum BranchSyncState {
  /// No upstream configured at all.
  noUpstream,

  /// Upstream was deleted on the remote (`GitRef.upstreamGone`).
  staleTracking,

  /// Ahead and behind both zero.
  upToDate,

  /// Ahead only — a fast-forward push would resolve it.
  aheadOnly,

  /// Behind only — a fast-forward pull/merge would resolve it.
  behindOnly,

  /// Both ahead and behind, with a common ancestor — the ordinary "have
  /// diverged" case: rebase, merge, or reset are all meaningful.
  diverged,

  /// Both ahead and behind, with NO common ancestor — same-name branches
  /// with genuinely unrelated content (a re-initialized repo, most often).
  unrelatedHistories,
}

/// The coarse (synchronous) classification — every value except the
/// diverged/unrelated-histories distinction, which needs an async
/// merge-base check. Callers needing that distinction call
/// [classifyBranchSyncStateAsync].
BranchSyncState classifyBranchSyncStateCoarse(GitRef branch) {
  if (branch.upstream == null) return BranchSyncState.noUpstream;
  if (branch.upstreamGone) return BranchSyncState.staleTracking;
  if (branch.ahead == 0 && branch.behind == 0) return BranchSyncState.upToDate;
  if (branch.ahead > 0 && branch.behind == 0) return BranchSyncState.aheadOnly;
  if (branch.ahead == 0 && branch.behind > 0) return BranchSyncState.behindOnly;
  // ahead > 0 && behind > 0 — provisionally diverged; the caller resolves the
  // unrelated-histories possibility asynchronously and may replace this.
  return BranchSyncState.diverged;
}

/// Resolves the diverged/unrelatedHistories distinction for a branch whose
/// coarse state is [BranchSyncState.diverged]. [refs] is the already-fetched
/// full ref list (local + remote-tracking) — the upstream's OID is looked up
/// there, costing no additional git call; only the ancestor check itself
/// (one `git merge-base`) is a new round trip, and only for branches that
/// are ahead-and-behind in the first place.
Future<BranchSyncState> classifyBranchSyncStateAsync(
  GitService git,
  String repoPath,
  GitRef branch,
  List<GitRef> refs,
) async {
  final coarse = classifyBranchSyncStateCoarse(branch);
  if (coarse != BranchSyncState.diverged) return coarse;
  final upstreamRef = refs
      .where((r) => r.isRemote && r.shortName == branch.upstream)
      .firstOrNull;
  if (upstreamRef == null) return coarse; // shouldn't happen: ahead/behind implies a resolvable upstream
  final related = await git.haveCommonAncestor(
    repoPath,
    branch.commitOid,
    upstreamRef.commitOid,
  );
  return related ? BranchSyncState.diverged : BranchSyncState.unrelatedHistories;
}
```

3.3 A new Riverpod provider in `app_providers.dart`, family-keyed by `(repoPath, branchName)`, wrapping
`classifyBranchSyncStateAsync` — `autoDispose`, `retry: noProviderRetry` (MADR 0017's enforced
convention; `test/provider_retry_policy_test.dart` fails the build otherwise). Watches `refsProvider`
so it recomputes when refs change (a fetch, a push, a new commit). Exact name and family-key shape
finalized against the codebase's existing family-provider conventions (e.g. `branchMergePreviewProvider`)
during execution — deviation-report if the existing pattern doesn't fit cleanly.

3.4 `_divergenceCluster` (`branch_navigator.dart:1775-1811`) renders `classifyBranchSyncStateCoarse`
immediately (no async wait) for every branch, and upgrades a `diverged` row to the async provider's
answer once it resolves (so the row never blocks on a merge-base round trip to paint at all — it shows
"Diverged" provisionally, and relabels to "Unrelated histories" only if that turns out to be true).
Labels: `noUpstream` → "Not published" (matches existing `_publishBranch` framing), `staleTracking` →
existing "gone" badge (unchanged), `upToDate` → nothing (unchanged), `aheadOnly`/`behindOnly` → the
existing `↑n`/`↓n` (unchanged — these are not the gap), `diverged` → "Diverged" with the existing `↑n ↓n`
kept alongside it, `unrelatedHistories` → "Unrelated histories" (no counts — they're not meaningful
without a common ancestor).

3.5 `branch_detail.dart`'s callout chain (insert after line 609, before line 611) gains, in priority
order after the existing chain: `noUpstream` → "This branch hasn't been published. Use Publish to push it
and start tracking a remote branch." (informational, blue) · `diverged` → "This branch and
`<upstream>` have diverged — N commits here, M there. Reconcile to merge, rebase, or reset." (orange,
actionable — see Phase 5) · `unrelatedHistories` → "This branch and `<upstream>` share no common
history." (orange, actionable — see Phase 4) · `staleTracking` → "`<upstream>` no longer exists on the
remote." (orange, links to delete, already possible via existing Delete item).

3.6 **Seen to fail**: a widget test asserting the diverged fixture (ahead: 2, behind: 1, sharing a
common ancestor with its upstream fixture) shows "Diverged" fails against a reverted 3.4/3.5, showing the
old raw `↑2 ↓1` instead.

3.7 Update the breaking test named in Grounding (`test/branches_actions_test.dart`'s divergence-badge
test) to assert the new label instead of the raw count, in this same commit.

3.8 New tests: one fixture per `BranchSyncState` value (seven total, including the async-resolved
`unrelatedHistories` case using a `_FakeGit` whose `haveCommonAncestor` returns `false`) asserting the
navigator row and detail-pane callout each show the right label/message.

3.9 Gate, then **commit (code)**.

### Phase 4 — `allowUnrelatedHistories` and wiring an action to the existing display

4.1 `git_service.dart`'s `merge()` gains a parameter:

```dart
Future<SSHCommandResult> merge(
  String repoPath,
  String branch, {
  MergeMode mode = MergeMode.normal,
  bool allowUnrelatedHistories = false,
}) {
  final args = [
    'git', ..._idArgs, 'merge', '--no-edit',
    if (mode == MergeMode.noFf) '--no-ff',
    if (mode == MergeMode.ffOnly) '--ff-only',
    if (mode == MergeMode.squash) '--squash',
    if (allowUnrelatedHistories) '--allow-unrelated-histories',
    '--end-of-options', branch,
  ];
  // ...unchanged below.
```

4.2 `branches_view.dart` gets `_runMergeAllowUnrelated(GitService git, String branch)`, following
`_runMerge`'s exact shape (`runLogged`, the same label-building convention) but calling
`git.merge(repoPath, branch, allowUnrelatedHistories: true)`.

4.3 The `unrelatedHistories` callout added in Phase 3.5 gains an action button (matching however
`_calloutBox`'s existing entries with an action are built — e.g. the `upstreamGone` case likely already
has one; follow that exact pattern) labeled **"Merge (allow unrelated histories)…"**, which opens a
`confirmAction` dialog (the same primitive merge already uses for its own confirmations — check
`_mergeBranch`, `branches_view.dart:1354-1379`, for its exact shape) stating explicitly that this
combines two histories with no shared commit and may produce extensive file-level conflicts, before
calling `_runMergeAllowUnrelated`. Never offered as a default/pre-confirmed action — always this
explicit extra step, per MADR Decision Outcome part 3.

4.4 **Seen to fail**: a widget test builds an `unrelatedHistories`-state branch and confirms no merge
action is reachable without the explicit confirmation dialog appearing first (i.e. tapping "Merge (allow
unrelated histories)…" alone must not call `git.merge`).

4.5 New tests: `_FakeGit.merge` records whether `allowUnrelatedHistories` was passed; the confirmation
dialog's text is asserted to state the risk; a cancelled confirmation never calls `git.merge`.

4.6 Gate, then **commit (code)**.

### Phase 5 — the Reconcile action for a diverged or unrelated-histories current branch

5.1 `branches_view.dart` gains a sibling to `_dropOnCurrent` (not an extension of it — see Scope Out):

```dart
enum ReconcileOp { merge, rebase, reset, cancel }

Future<void> _reconcile(GitService git, GitRef branch) async {
  if (busy || !branch.isHead || branch.upstream == null) return;
  final upstream = branch.upstream!;
  final op = await chooseAction<ReconcileOp>(
    context,
    title: 'Reconcile with $upstream',
    message:
        '"${branch.shortName}" and "$upstream" have diverged '
        '(${branch.ahead} here, ${branch.behind} there).',
    primaryLabel: 'Merge "$upstream" into "${branch.shortName}"',
    primaryValue: ReconcileOp.merge,
    secondary: [
      ('Rebase "${branch.shortName}" onto "$upstream"', ReconcileOp.rebase),
      ('Reset "${branch.shortName}" to "$upstream"', ReconcileOp.reset),
      ('Cancel', ReconcileOp.cancel),
    ],
  );
  if (op == null || op == ReconcileOp.cancel || !mounted) return;
  switch (op) {
    case ReconcileOp.merge:
      await _runMerge(git, upstream, MergeMode.normal);
    case ReconcileOp.rebase:
      await _runRebaseOnto(git, upstream);
    case ReconcileOp.reset:
      await _runResetToUpstream(git, branch, upstream);
    case ReconcileOp.cancel:
      break;
  }
}

Future<void> _runResetToUpstream(
  GitService git,
  GitRef branch,
  String upstream,
) async {
  final ok = await confirmAction(
    context,
    title: 'Reset to $upstream?',
    message:
        'This discards ${branch.ahead} commit(s) only on '
        '"${branch.shortName}". Reversible with ⌘Z or the toast that '
        'appears after.',
    confirmLabel: 'Reset',
    isDestructive: true,
  );
  if (!ok || !mounted) return;
  await runGuarded(
    () => git.reset(repoPath, upstream, mode: ResetMode.hard),
  );
}
```

Primary is Merge (safest — preserves both histories, matches research's risk ranking); Rebase and Reset
are secondary, ordered by increasing risk. `confirmAction`'s exact signature (`title`, `message`,
`confirmLabel`, `isDestructive`, or whatever it's actually called) is confirmed against
`_mergeBranch`'s or another existing destructive-action call site before writing this — a deviation if
the primitive's shape differs from this sketch.

5.2 Wiring: the context menu (`branch_navigator.dart`) and Advanced menu (`branch_detail.dart`) each
gain a **Reconcile…** item, shown only when `b.isHead && (state == diverged || state ==
unrelatedHistories)` — the opposite gating from "Merge into current" (`!b.isHead`), per Grounding.
`unrelatedHistories` routes to the Phase 4 confirmation flow instead of `_reconcile` (Reset/Rebase are
not offered for unrelated histories — there is nothing to fast-forward or cleanly rebase onto when
there's no shared commit; only the explicit allow-unrelated-histories merge applies).

5.3 **Seen to fail**, in a detached scratch worktree with the head-branch gate inverted: Reconcile
appears for a non-head diverged branch, where rebase/reset would silently operate on the wrong branch
(the actual checked-out one) — proving the gate matters, not just that the menu item exists.

5.4 New tests: Reconcile is offered for a diverged head branch and absent for (a) a diverged non-head
branch, (b) an up-to-date head branch; each of Merge/Rebase/Reset calls the right `GitService` method
with the right arguments (via `_FakeGit`'s recorded calls); Reset's confirmation dialog blocks the call
until confirmed.

5.5 Gate, then **commit (code)**.

### Phase 6 — bulk stale-branch cleanup after Fetch & Prune

6.1 `_fetchPrune` (`branches_view.dart:1674-1706`) snapshots which local branches are `upstreamGone`
**before** fetching, diffs against the post-refresh `refs` list, and — if the set of gone branches grew
— offers a bulk cleanup:

```dart
Future<void> _fetchPrune(GitService git) async {
  final beforeGone = {
    for (final r in ref.read(refsProvider(repoPath)).value ?? const [])
      if (r.isLocalBranch && r.upstreamGone) r.shortName,
  };
  await runLogged('git fetch --all --prune', (log) async {
    // ...unchanged fetch call...
  });
  if (!mounted) return;
  final afterGone = {
    for (final r in ref.read(refsProvider(repoPath)).value ?? const [])
      if (r.isLocalBranch && r.upstreamGone) r.shortName,
  };
  final newlyGone = afterGone.difference(beforeGone);
  if (newlyGone.isEmpty) return;
  final confirmed = await confirmAction(
    context,
    title: 'Clean up stale branches?',
    message:
        '${newlyGone.length} branch(es) no longer exist on the remote: '
        '${newlyGone.join(', ')}.',
    confirmLabel: 'Delete',
    isDestructive: true,
  );
  if (!confirmed || !mounted) return;
  for (final name in newlyGone) {
    await runGuarded(() => git.deleteBranch(repoPath, name));
  }
}
```

`refresh: () => refreshAfterFetch(ref, repoPath)` (the existing completion callback) must have actually
resolved and `refsProvider` re-read by the time `afterGone` is computed — confirm the existing
`_fetchPrune`/`runLogged` sequencing already awaits that (it should, since the log session closes only
after the fetch completes) before assuming the diff is accurate; a deviation if it does not.

6.2 **Seen to fail**: with the before/after diff reverted to "always empty," fetching a repo where a
branch was deleted upstream shows no cleanup offer even though the `gone` badge now appears on that
branch.

6.3 New tests: a `_FakeGit` whose `refsProvider` override changes between two reads (simulating a fetch
that reveals a newly-gone branch) triggers the cleanup dialog with the right branch name; confirming
calls `deleteBranch` for each; cancelling calls it for none; no branches newly gone → no dialog at all.

6.4 Gate, then **commit (code)**.

### Phase 7 — extract `PendingOpBanner` and surface it in Branches

7.1 **New** `lib/features/common/pending_op_banner.dart`: `PendingOpBanner extends ConsumerWidget`
(or `StatefulWidget`, matching whatever `_pendingBanner`'s state needs — it currently needs none beyond
what `pendingOpProvider` supplies), taking `repoPath` and an optional `onAborted` callback (defaulting to
a no-op, replacing `repo_status_view.dart`'s `_clearSelection` call, which stays local to that view's own
`onAborted` argument). Body is `_pendingBanner`/`_abortPending`/`_continuePending`/`_pendingVerb`
(`repo_status_view.dart:1470-1567`), moved verbatim except for the `_clearSelection` call becoming
`onAborted?.call()`.

7.2 `repo_status_view.dart`'s call site (`:1958-1959`) becomes `if (pending != null && pending !=
PendingOp.none) PendingOpBanner(repoPath: repoPath, onAborted: _clearSelection)` — behaviour-preserving.

7.3 `branch_navigator.dart` (row-level, small inline indicator, not the full banner — "Rebase in
progress" text with a tap target) and `branch_detail.dart` (the full `PendingOpBanner`, matching Status's
own treatment, inserted at the top of the callout chain — a mid-operation branch's state is more urgent
than any sync-state callout) both watch `pendingOpProvider(repoPath)` and show/link to it when not
`PendingOp.none`. The row-level indicator opens the same dialog the full banner offers rather than
duplicating Continue/Abort inline in the row.

7.4 **New** `test/pending_op_banner_test.dart`: migrate whatever `repo_status_view_test.dart` tests
today assert on `_pendingBanner`'s behaviour (Continue/Abort call the right GitService methods, the
confirm-before-abort dialog) — grep for them before writing to confirm what's already covered and what's
net-new. `repo_status_view_test.dart` itself is updated only if the extraction changes any
publicly-observable behaviour (it should not).

7.5 New tests in `test/branches_actions_test.dart`: a mid-rebase fixture shows the row-level indicator
and the detail-pane banner; tapping either reaches the same Continue/Abort dialog Status already has.

7.6 **Seen to fail**: with the extraction's `onAborted` wiring reverted to always-no-op, aborting from
the Status tab's own banner no longer clears its conflict selection — proving the extraction didn't
silently drop that behaviour.

7.7 Gate, then **commit (code)**.

### Phase 8 — close the records

8.1 MADR 0051 → `status: "accepted"`, `verified:` today. This plan → `status: complete` with its
execution record. `docs/README.md` row for 0051. **Commit (docs).**

## Verification

The whole-plan gate, run at the end and after every phase:

```sh
flutter --version | head -1                       # Flutter 3.47.2
flutter analyze                                   # No issues found
flutter test                                      # all pass
flutter test test/branches_actions_test.dart test/pending_op_banner_test.dart \
  test/repo_status_view_test.dart test/branch_navigator_test.dart
```

Exit statuses are captured, never piped into a filter. Manually, on the maintainer's machine: a real
repo with a diverged branch (create it by committing on two clones/worktrees of the same remote without
syncing between) shows "Diverged" and Reconcile resolves it via each of the three paths in turn (on
throwaway copies, not the same branch three times); a branch published for the first time via the fixed
Set-upstream/Publish distinction actually tracks correctly afterward; Fetch & Prune against a repo with a
remote-deleted branch offers the bulk cleanup and it removes exactly that branch.

## Acceptance Criteria

1. `_setUpstream` refuses (with an actionable message) a target with no matching remote-tracking branch,
   and accepts one that has a match; `_publishBranch`'s existing gate is confirmed unchanged.
2. The Advanced menu (renamed from More) and the context menu offer the identical action set for the
   same branch, verified by set-equality, not a fixed list.
3. Every `BranchSyncState` value renders a distinct, correctly-labeled state in both the navigator row
   and the detail pane, replacing the bare ahead/behind count for the diverged/unrelated cases while
   leaving the ahead-only/behind-only display unchanged.
4. `haveCommonAncestor` correctly distinguishes diverged from unrelated-histories, and
   `_mergeTreePreviewUnlocked`'s existing behaviour (including its own test coverage) is unchanged by the
   extraction.
5. `allowUnrelatedHistories` merge only ever runs after its own explicit confirmation, never as a default
   or pre-selected choice.
6. Reconcile appears only for a diverged or unrelated-histories **current** branch, never for a non-head
   branch in the same state; each of Merge/Rebase/Reset calls the correct, already-existing GitService
   method with the correct arguments.
7. Fetch & Prune offers a bulk cleanup only when branches are newly (not previously) marked gone, and
   deletes exactly the offered set on confirmation, none on cancellation.
8. `PendingOpBanner`'s extraction changes no observable behaviour in `repo_status_view.dart` (its own
   existing tests pass unmodified beyond the file being what's tested), and the same banner/dialog is
   reachable from Branches.
9. `flutter analyze` clean, full suite green, every staged Dart file formatted, at every phase.

## Rollout and Rollback

Eight code/test commits (one per phase) plus one docs-closing commit, code and docs never mixed.
Rollback is safe at any commit boundary: `git revert --no-edit <sha>`, never a reset or a rewrite. Later
phases depend on earlier ones (3 needs 1's validated GitRef reasoning only incidentally, but 5 needs 3's
`BranchSyncState` and 4's confirmation pattern; 7 is independent of 3-6 and could be reordered earlier if
a deviation delays the sync-state work). Nothing persisted changes — no new preference keys, no schema
change — so a partial revert leaves the app exactly as capable as it was before whichever phase is
reverted, never in a broken intermediate state, since each phase's UI only appears once its own commit
lands. Nothing is pushed unless the maintainer asks in that same turn.

## Risks

* **`classifyBranchSyncStateAsync`'s provider shape is sketched, not confirmed** (3.3) — the exact
  family-keying convention is decided against the codebase's real patterns during execution; a mismatch
  is a deviation, not a silent judgment call.
* **`confirmAction`'s exact signature is assumed** (5.1, 6.1) from context, not quoted verbatim the way
  `chooseAction<T>` was — confirmed against a real call site before Phase 4/5/6 write code, and a
  deviation if it doesn't match.
* **`onUnsetUpstream`'s threading to `BranchDetail`** (2.2) is assumed already present (the context menu
  has the equivalent); if `BranchDetail`'s constructor doesn't already accept it, adding a new required
  callback parameter touches every call site that constructs `BranchDetail` — a deviation naming the
  actual blast radius before proceeding.
* **The `_calloutBox` action-button pattern** (4.3) is assumed to already exist for at least one
  callout (`upstreamGone`); if no existing callout has an attached action, this phase is building new UI
  pattern, not reusing one, which changes its own risk/review profile — worth confirming early in Phase
  3, not discovered mid-Phase-4.
* **Seven new `BranchSyncState` fixtures (3.8) plus the Reconcile/allow-unrelated/bulk-cleanup tests
  (Phases 4-6) are a lot of new widget-test surface** in files already covering a lot of ground
  (`branches_actions_test.dart`) — if the file grows unwieldy, splitting sync-state tests into their own
  file is a reasonable mid-plan adjustment, recorded as such rather than silently done.
