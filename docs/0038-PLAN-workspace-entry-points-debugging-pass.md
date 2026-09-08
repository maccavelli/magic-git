---
status: "in-progress"
date: 2026-09-08
associated-madr: "0038-MADR-workspace-entry-points-debugging-pass.md"
---
# Implement the workspace entry-point findings

Associated MADR: [0038-MADR-workspace-entry-points-debugging-pass.md](0038-MADR-workspace-entry-points-debugging-pass.md)

Line numbers are as of `f5ea21d`. Re-run the proof table before starting; if a
line has moved, update this plan before the phase, not after.

## Goal

Close the nine findings in MADR 0038, in an order where the mechanical work
protects the behavioural work rather than colliding with it. Three sheets share
one lifecycle implementation that a unit test can drive, ad-hoc SSH sessions are
targetable again, and every remote create/clone/open lands in Recents.

## Scope

### In scope

| Phase | What | Files |
| --- | --- | --- |
| 1 | F1 — record per-repo recency in `finalizeProvisioned` | `lib/core/providers/app_providers.dart`, `test/connection_provisioning_test.dart`, `docs/0037-PLAN-*` (amendment) |
| 2 | F7/F8 — the flow object; port all 8 registration tests | new `lib/features/workspace/workspace_flow.dart`, `workspace_provisioning.dart`, all three sheets, new `test/workspace_flow_test.dart`, `test/workspace_registration_test.dart` |
| 3 | F3, F9 — container capture and namespace symmetry, on the single copy | `lib/features/workspace/workspace_flow.dart`, `create_repo_sheet.dart`, `clone_sheet.dart`, `test/workspace_flow_test.dart` |
| 4 | F2, F6 — restore ad-hoc targeting; delete the dead matrix | `workspace_targets.dart`, `workspace_destination.dart`, `workspace_registration.dart`, both sheets, `test/workspace_flow_test.dart`, `test/create_repo_sheet_test.dart`, `test/clone_sheet_test.dart` |
| 5 | F4, F5 — add-existing seeding and path dedupe | `lib/features/connection/local_repo_form.dart`, `lib/core/storage/local_repo_store.dart`, `test/add_existing_repo_sheet_test.dart`, `test/local_repo_store_test.dart` |
| 6 | Record | `docs/README.md`, `tool/mutations/0038-*.json`, this plan, the MADR's `verified:` date |

### Out of scope

* **Unifying the three sheets' presentation.** Create is a 5-step wizard, clone
  a 4-step one, add-existing a single-page form with dotfiles support the others
  do not have. The MADR's assessment settles this: the flow object owns the
  lifecycle, not the UI.
* **`create_repo_pipeline.dart` and `clone_controller.dart`.** The work half is
  already canonical and directly tested (15 and 14 tests). Nothing here touches
  it.
* **The 30-entry recents cap, the namespace creatable rule, the 8-tab cap.**
  Settled by 0032, 0037 and 0036 respectively.
* **`registerAndActivateLocal`'s behaviour.** It moves; it does not change.

### Preconditions

```sh
flutter --version | head -1          # Flutter 3.47.2
flutter pub get --enforce-lockfile   # "Got dependencies!"
git status --short                   # only docs/0038-*
git rev-parse --short HEAD           # f5ea21d, or update the line numbers
```

### Baselines — capture before Phase 1

```sh
flutter test 2>&1 | tail -1
printf 'expect=%s testWidgets=%s\n' \
  "$(grep -rho 'expect(' test/ | wc -l | tr -d ' ')" \
  "$(grep -rho 'testWidgets(' test/ | wc -l | tr -d ' ')"
```

## Proof of the MADR's assertions

Read-only. Run all before Phase 1 and paste the output into the execution
record. Each must still hold, or the finding it supports has moved.

```sh
# F1 — finalizeProvisioned (2672-2833) contains no recency write
awk 'NR>=2672 && NR<=2833 && /_recordRecentOpen|_recordOpenedNamespace/' \
  lib/core/providers/app_providers.dart          # expect: no output

# F6 — the matrix dispatcher has no callers anywhere.
# `grep -v '//'` is load-bearing: create_repo_sheet_test.dart:1733 MENTIONS
# `registerAndActivate` in a comment, and a proof that counts prose as a
# caller proves nothing.
grep -rn "registerAndActivate(" lib/ test/ --include=*.dart \
  | grep -v workspace_registration.dart | grep -v '//'
                                                 # expect: no output

# F7 — the provision-tab block is byte-identical in two of three sheets
diff <(sed -n '671,698p' lib/features/workspace/create_repo_sheet.dart | grep -v '^\s*//') \
     <(sed -n '286,313p' lib/features/connection/local_repo_form.dart | grep -v '^\s*//')

# Shared lifecycle units have no direct test callers
grep -rl "openLocalRepoInTab\|openSshRepoInTab\|finalizeProvisionedInTab\|ensureProvisioned" test/
                                                 # expect: no output
```

## Implementation Steps

### Phase 1 — F1: a provisioned open is an open

`finalizeProvisioned` (`app_providers.dart:2672-2833`) ends by publishing
`state` and calling `_watchForDrop(token)`. Add the per-repo recency write
immediately after the state publish, matching the three existing call sites:

```dart
await _recordRecentOpen(
  isLocal: false,
  id: conn.id,
  repoPath: repoPath,
);
```

Placed **after** `state = ConnectionState(…)` so `_recordOpenedNamespace`'s
`originUrl` read runs against a session that is already published (the
credential-helper cache and scope registry are both live by then), and
**before** `_watchForDrop`, which does not depend on it.

Awaited rather than fire-and-forget, matching `connect()`
(`app_providers.dart:1529`) — `_recordRecentOpen` is best-effort internally and
cannot fail the finalize.

**Amend MADR 0037.** Its Phase 2 record claims all three opens are covered "by
construction". Add a dated amendment naming the fourth path and this fix, and
strike the "three" claim rather than rewriting it.

**Tests** (`connection_provisioning_test.dart`, which already has 10):

* a finalized provisioned session records the repo into `RecentReposStore`;
* it records the namespace when the origin is a creatable forge path;
* a finalize that is superseded (`token != _attempt`) records nothing.

**Commit.**

### Phase 2 — F7/F8: the flow object, and the 8 ported tests

New `lib/features/workspace/workspace_flow.dart` — a **plain class**, no
`ConsumerState`, no `BuildContext`, no `WidgetRef`:

```dart
/// The lifecycle every workspace entry point runs, minus the work itself.
///
/// Plain and widget-free ON PURPOSE. `WorkspaceProvisioning` was extracted as
/// `mixin … on ConsumerState<T>`, which is why it has no direct test and why
/// its lifecycle was hand-copied into all three sheets anyway (MADR 0038 F7).
class WorkspaceFlow {
  WorkspaceFlow({
    required ProviderContainer origin,
    TabsController? tabs,
    ScopedAccess? scopedAccess,
  });

  /// The container the flow reads and writes through — captured once, never
  /// re-resolved. F3 is unrepresentable here: there is no ambient `ref`.
  ProviderContainer get container;

  Future<bool> ensureTab();              // was _ensureProvisionTab  ×3
  Future<bool> ensureProvisioned(SavedConnection conn);
  Future<bool> openResult(WorkspaceOpenRequest request);  // was _openResult ×2
  Future<void> abandon();                // was _abandonProvisionTab ×3
  bool get refusedAtTabCap;              // was _refusedAtTabCap     ×3
}
```

Moves, with **no behaviour change**:

* `_provisionTab`, `_originTabId`, `_ensureProvisionTab`, `_abandonProvisionTab`
  from `create_repo_sheet.dart:661-697`, `clone_sheet.dart:309-344`,
  `local_repo_form.dart:283-309` (byte-identical in two; clone adds three lines
  of routed-job teardown, which becomes an `onAbandon` callback);
* `_opensNewTab` / `_refusedAtTabCap` from all three;
* `_openResult` from `create_repo_sheet.dart:703-770` and
  `clone_sheet.dart:521-588`, parameterised by the two values that differ
  (`scopedAccess`, and the label/fsmonitor fields, carried in
  `WorkspaceOpenRequest`);
* `registerAndActivateLocal` and `saveLocalRepo` from
  `workspace_registration.dart` become methods on the flow, taking the captured
  container instead of a `WidgetRef`.

`WorkspaceProvisioning` shrinks to a thin adapter: it keeps `provisioning`,
`onProvisioningError` and the `setState` plumbing sheets need, and delegates
everything else to a `WorkspaceFlow` it owns. **It does not grow.** A bigger
mixin would consolidate the duplication and keep the untestability that caused
it.

**Port all 8 registration tests** (maintainer's decision, 2026-09-08) into
`test/workspace_flow_test.dart`, driving `WorkspaceFlow` directly over a bare
`ProviderContainer`:

| Ported test | Covers |
| --- | --- |
| `save:false calls connectLocal without persisting` | live |
| `a failed connect reports false and persists nothing` | live |
| `save:true persists SavedLocalRepo with bookmark data` | live |
| `save:true with empty label passes null to connectLocal` | live |
| `updates connection metadata and sets repoPath` | the F2 contract |
| `with fsmonitor calls setFsmonitor on git service` | the F2 contract |
| `with label saves it in connection metadata` | the F2 contract |
| `without connectionId (ad-hoc) skips metadata mutation` | **the F2 contract, exactly** |

The four `registerAndActivateSshActive` tests are ported against the flow's
active-session path, which Phase 4 restores. Until then they target the
still-present function; Phase 4 repoints them and Phase 4 deletes the function.
`test/workspace_registration_test.dart` is deleted only once every one of its
tests has a green counterpart in `workspace_flow_test.dart` — never before.

**New tests the flow makes possible for the first time** — these are the reason
for the phase, and each must be seen to fail against a deliberately broken flow:

* every grant acquired is released when no session starts;
* a dialled tab is closed, and the origin tab re-activated, on abandon;
* the container captured at construction is the one the result opens in;
* a flow refused at the tab cap dials nothing.

**Acceptance:** the 73 existing sheet tests pass **unchanged**. Any sheet test
that needs editing means the move was not pure — stop and prompt.

**Commit.**

### Phase 3 — F3 and F9 on the single copy

* **F3.** With `_openResult` inside the flow, `registerAndActivateLocal` and
  `saveLocalRepo` read `flow.container`, not `ref`. Delete the now-unused
  `WidgetRef` parameters. The comment at `create_repo_sheet.dart:499-501`
  explaining why `own` is captured moves onto `WorkspaceFlow.container`, where
  it is now enforced rather than advisory.
* **F9.1.** The flow records the namespace at one point — after the work
  succeeds, **before** `openResult` — matching create's current order
  (`create_repo_sheet.dart:562`) and changing clone's
  (`clone_sheet.dart:437`). Justification for choosing create's order: the
  repository exists on disk either way, and a clone that fails to open is
  exactly when the record is most useful.
* **F9.2.** An unsaved local create/clone records the **namespace** even though
  it records no MRU entry. `_recordRecentOpen` stays guarded on a non-null id;
  `_recordOpenedNamespace` is called independently for the unsaved case.
* **F9.3.** `_rememberNamespace` reads through the flow's container.
* Fix the stale doc-comment on `_effectiveConnectionId`
  (`create_repo_sheet.dart:1019-1024`, `clone_sheet.dart:507-512`), which still
  describes the pre-0036 `sshActive` default.

**Tests.** A tab switch between submit and open leaves the result in the
original tab (F3, in `workspace_flow_test.dart`, no widget needed). A clone
whose open fails still records its namespace (F9.1). An unsaved local create
records a namespace and no MRU entry (F9.2).

**Commit.**

### Phase 4 — F2 and F6: ad-hoc sessions are targetable again

**The destination model gets a third state.** `String? destConnectionId` cannot
express it: `null` already means This Mac. A sentinel id would re-create exactly
the "one value, two meanings" ambiguity that produced F2. In
`workspace_targets.dart`:

```dart
sealed class WorkspaceDestination {
  const WorkspaceDestination();
}

/// This machine's own filesystem.
final class LocalMacDestination extends WorkspaceDestination { … }

/// The session in this tab, which may be ad-hoc and have no saved id at all.
/// Restored 2026-09-08 (MADR 0038 F2): before MADR 0036 this was
/// `WorkspaceTarget.sshActive`, and removing it left an ad-hoc SSH session with
/// no way to target the host it is already on.
final class ActiveSessionDestination extends WorkspaceDestination { … }

/// A saved connection, dialled in its own tab.
final class SavedConnectionDestination extends WorkspaceDestination {
  final String id;
}
```

Each overrides `==`/`hashCode`, because `MacosPopupButton` selects by equality.

Changes:

1. `WorkspaceDestinationSection` becomes `MacosPopupButton<WorkspaceDestination>`
   (`workspace_destination.dart:63-81`). It offers `ActiveSessionDestination`
   **only when the live session is a connected SSH session with a null
   `connectionId`** — a saved session is already in the list by id, and offering
   both would be two rows for one host. Labelled from `ConnectionState.host`,
   which is populated for ad-hoc sessions (`app_providers.dart:1348`).
2. Both sheets seed from the session (MADR 0036, 2A), now correctly for all
   three shapes — replacing `conn.isLocal ? null : conn.connectionId`
   (`create_repo_sheet.dart:363`, `clone_sheet.dart:213`).
3. `_recomputeTarget` maps the destination to a `WorkspaceTarget`, and
   `WorkspaceTarget.sshActive` is produced again.
4. The flow's `openResult` gains the active-session branch: the ported
   `registerAndActivateSshActive` body, which registers into the saved
   connection when there is one and **only calls `setRepoPath` when there is
   not**. No dial, no new tab: the session is already here.
5. `needsProvisioning` is false for `ActiveSessionDestination`, so no tab is
   claimed and the tab cap does not apply — an ad-hoc create can run at 8 tabs.
6. **Delete** `registerAndActivate` and `registerAndActivateSshActive`
   (`workspace_registration.dart:77-171`), and with them the dispatcher's
   `gitDir`-dropping `sshProvision` branch (`:158-166`). Delete
   `test/workspace_registration_test.dart`, now fully superseded.

**Tests.** A connected ad-hoc session opens both sheets on the active session,
not This Mac. Creating there registers nothing and switches the repo path. A
connected *saved* session still shows exactly one row for its host. An
active-session target dials nothing and opens no tab.

**Commit.**

### Phase 5 — F4 and F5: the add-existing sheet

* **F4.** `AddExistingRepoSheet` gains an `initState` seeding `_connectionId`
  from the live session, through the same helper both wizards use — the
  three-shape mapping from Phase 4, so an ad-hoc session seeds correctly here
  too.
* **F5.** `LocalRepoStore.save` (`local_repo_store.dart:61-64`) de-duplicates by
  `id` only. Add path-based reuse **at the sheet**, not the store: before
  minting an id (`local_repo_form.dart:550`), look for a saved repo whose
  `repoPath` matches and reuse its id, mirroring `connection_form.dart:182-194`
  ("so re-connecting never piles up duplicates"). At the sheet because the store
  must stay a dumb persister — two rows for one path is a legitimate state for a
  caller that means it, and silently collapsing them in `save` would change
  `updateMetadata`'s meaning too.
  Reusing the id also makes `TabsController._find` match
  (`tabs_controller.dart:432-438`), so a second open focuses the existing tab
  instead of opening a duplicate.
* **F5 follow-on.** `openLocalRepoInTab` returning null now has two causes — the
  tab cap and the dedupe-focus. `_openLocal` currently reports the cap message
  for both (`local_repo_form.dart:608-611`). Distinguish them: on a focus,
  close the sheet, because the user got what they asked for.

**Tests.** The sheet opens on the current session's host. Opening one folder
twice yields one saved repo and one tab, and the second open closes the sheet
rather than reporting the cap.

**Commit.**

### Phase 6 — Record

`tool/mutations/0038-*.json`, the `docs/README.md` row, this plan's execution
record, the MADR's `verified:` date.

## Verification

Per phase:

```sh
dart format --output=none --set-exit-if-changed <staged dart files>
flutter analyze
flutter test
python3 tool/mutate.py tool/mutations/0038-workspace-entry-points.json
```

### Sabotage

| Mutation | Must be caught by |
| --- | --- |
| `finalizeProvisioned` records no recency | Phase 1 "a finalized session appears in Recents" |
| The recency write runs before the state publish | Phase 1 namespace test (origin read would be unscoped) |
| A superseded finalize records anyway | Phase 1 superseded test |
| The flow re-resolves its container instead of using the captured one | Phase 3 tab-switch test |
| A grant is not released when no session starts | Phase 2 grant test |
| Abandon does not close the dialled tab | Phase 2 abandon test |
| Abandon does not re-activate the origin tab | Phase 2 abandon test |
| The namespace is recorded after the open rather than before | Phase 3 "a failed open still records" |
| An unsaved local create records no namespace | Phase 3 F9.2 test |
| `ActiveSessionDestination` is offered for a saved session too | Phase 4 "one row per host" |
| An active-session target dials a new tab | Phase 4 "dials nothing" |
| An active-session create persists into a connection it has none of | Phase 4 ad-hoc test |
| The tab cap is applied to an active-session target | Phase 4 cap test |
| The add-existing sheet seeds This Mac regardless | Phase 5 seeding test |
| A repeated open mints a new id | Phase 5 dedupe test |

### Acceptance criteria

1. A create, clone or open on a remote host appears in Recents and records its
   namespace.
2. The 73 existing sheet tests pass unchanged across Phase 2 — a phase that
   needs to edit them is not the pure move it claims to be.
3. All 8 registration tests have green counterparts against `WorkspaceFlow`
   before `workspace_registration_test.dart` is deleted.
4. Four lifecycle invariants (grant release, tab close, origin re-activate,
   captured container) are asserted in a `test()` with no `pumpWidget`.
5. An ad-hoc SSH session can target the host it is on, from all three sheets;
   doing so dials nothing, opens no tab, and persists nothing.
6. A connected saved session shows exactly one destination row for its host.
7. Opening one local folder twice yields one saved repo and one tab.
8. No production caller of `registerAndActivate*` remains, and the functions are
   gone.
9. `flutter analyze` clean; suite green each phase; every mutation killed.

## Execution record

### Preconditions and baselines — 2026-09-08, at `f5ea21d`

```
Flutter 3.47.2 • channel stable
flutter pub get --enforce-lockfile   Got dependencies!
git status --short                   only docs/0038-*
flutter test                         03:33 +3768 ~3: All tests passed!
expect=9471 testWidgets=1072
```

All four proof-table commands returned empty, as the MADR asserts: no recency
write inside `finalizeProvisioned`; no caller of `registerAndActivate(`; the
provision-tab block byte-identical between create and add-existing; and no test
anywhere calling `openLocalRepoInTab`, `openSshRepoInTab`,
`finalizeProvisionedInTab` or `ensureProvisioned`.

**One proof command was wrong as written and was fixed before the baseline
run.** The F6 check grepped `registerAndActivate\b`, which matched a *comment*
at `create_repo_sheet_test.dart:1733` — a proof that counts prose as a caller
proves nothing. Narrowed to `registerAndActivate(` with comments excluded; it
then returns empty, and the plan says why the filter is load-bearing.

### Phase 1 — 2026-09-08 — *complete*

**`finalizeProvisioned` now records the open.** One call, after the state
publish and before `_watchForDrop`:

```dart
await _recordRecentOpen(isLocal: false, id: conn.id, repoPath: repoPath);
```

Placed after the publish because `_recordOpenedNamespace` reads the origin
through `originUrl`, which needs this session's scope registry and credential
cache live; before `_watchForDrop`, which does not depend on it. Awaited like
the other three call sites — the writer swallows its own failures, so a finalize
can never fail because remembering it did not work.

**MADR 0037's coverage claim is amended, not quietly patched.** Its Phase 2
record said all three opens were covered "by construction"; there are four, and
the fourth is the one every remote create, clone and open-existing takes. The
amendment names what went wrong in the reasoning: "by construction" was claimed
from the shape of the fix without enumerating every writer of a connected
`ConnectionState`. The correct search was for state publishes, not for readers
of `_recordRecentOpen`.

**A test that was wrong, not code that was.** The namespace arm first failed
with an empty history. `_recordOpenedNamespace` resolves the `SavedConnection`
to choose which of `NamespaceHistory`'s two stores to write to, and
`savedConnectionsProvider` was not overridden — so the lookup fell through to
the real store, whose `SharedPreferences` call throws under a plain `test()`,
and the namespace went to the This-Mac store instead of the connection. Fixed by
overriding it, with the reason in the harness so the next reader does not
rediscover it.

**A catalogue that would not load.** The first `0038-*.json` was written as
`{"mutations": [...]}`; `tool/mutate.py:120` expects a bare array and died with
`TypeError: string indices must be integers`. Flattened. Worth noting because a
catalogue that crashes is indistinguishable from one that passes if the output
is not read.

**Sabotage — 4 mutations, all killed:**

```
phase1: finalizeProvisioned records no per-repo recency
      -> the repo lands in the per-repo MRU, not just the connection
phase1: a provisioned open is recorded as a LOCAL open
      -> the repo lands in the per-repo MRU, not just the connection
phase1: the recency write runs BEFORE the state publish
      -> the repo lands in the per-repo MRU (the write duplicates)
phase1: a superseded finalize records anyway
      -> a superseded finalize records nothing
```

**Verification:**

```
flutter analyze (whole project)   No issues found!
dart format                       0 changed
flutter test (full suite)         03:28 +3772 ~3: All tests passed!
tool/mutate.py (4 mutations)      4 killed, 0 survived, 0 did not apply
expect=9482 testWidgets=1072
```

## Rollout and Rollback

**Rollout.** Six commits, one per phase. Phase 1 stands alone and delivers the
highest-value fix independently of everything else — if the rest is abandoned,
it should still ship. Phases 2–3 are internal: no user-visible behaviour changes
except F9's recording order. Phase 4 is the only user-visible feature change.
Phase 5 is independent of 2–4 and could be reordered if Phase 2 stalls.

**Rollback.** Each phase reverts cleanly on its own commit. Phase 2 is the
riskiest to revert late, because 3 and 4 build on the flow object — revert 4, 3,
2 in that order. Phase 1 has no dependants.

**The one thing to watch.** Phase 2 touches all three sheets for no behaviour
change, which is the highest-risk shape of edit. The 48 workspace goldens are
**not** exposed (`workspace_golden_test.dart:311-334` renders the workspace
shell; none of the three sheets appears in it), so the check is the sheet tests,
and acceptance criterion 2 is what makes it meaningful.
