---
status: "complete"
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
| 2 | F7/F8 — the flow object; port the 4 live registration tests | new `lib/features/workspace/workspace_flow.dart`, `workspace_provisioning.dart`, all three sheets, new `test/workspace_flow_test.dart` |
| 3 | F8, F3, F9 — move `_openResult` and the local registration into the flow (deviation 1); port the 4 live registration tests; container capture; namespace symmetry | `lib/features/workspace/workspace_flow.dart`, `workspace_registration.dart`, `create_repo_sheet.dart`, `clone_sheet.dart`, `test/workspace_flow_test.dart` |
| 4 | F2, F6 — restore ad-hoc targeting; port the 4 remaining registration tests; delete the dead matrix | `workspace_targets.dart`, `workspace_destination.dart`, `workspace_registration.dart`, `workspace_flow.dart`, both sheets, `test/workspace_flow_test.dart`, **delete `test/workspace_registration_test.dart`**, `test/create_repo_sheet_test.dart`, `test/clone_sheet_test.dart` |
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

### Phase 2 — F7/F8: the flow object, and the ported registration tests

**Re-analysed 2026-09-08 before execution; five assertions in the first draft
were wrong. See "Phase 2 re-analysis" below for the evidence — this section is
the corrected version.**

#### 2.1 What moves, and what provably does not

New `lib/features/workspace/workspace_flow.dart` — a **plain class**: no
`ConsumerState`, no `BuildContext`, no `WidgetRef`.

```dart
/// The tab half of the lifecycle every workspace entry point runs.
///
/// Plain and widget-free ON PURPOSE. `WorkspaceProvisioning` was extracted as
/// `mixin … on ConsumerState<T>`, which is why it has no direct test and why
/// the tab lifecycle beside it was hand-copied into all three sheets anyway
/// (MADR 0038 F7).
class WorkspaceFlow {
  WorkspaceFlow({
    required ProviderContainer origin,
    TabsController? tabs,
    ScopedAccess? scopedAccess,
  });

  /// The container the flow reads and writes through — the sheet's own at
  /// construction, or the dialled tab's once [ensureTab] has run. Captured,
  /// never re-resolved: MADR 0038 F3 is unrepresentable here because there is
  /// no ambient `ref` to reach for.
  ProviderContainer get container;

  RepoTab? get tab;
  bool refusedAtTabCap({required bool opensNewTab});
  Future<bool> ensureTab();
  Future<void> abandon({required Future<void> Function() releaseSession});
  // openResult arrives in Phase 3 — deviation 1.
}
```

`tabs` and `scopedAccess` are resolved **lazily** — `tabs ?? TabsController.current`,
`scopedAccess ?? <the sheet's static>` — read at each use, not at construction.

This is **behaviour preservation, not a test requirement**, and the distinction
matters because the obvious justification is false. The code being moved reads
both statics at each use (`_ensureProvisionTab` and `_abandonProvisionTab` each
read `TabsController.current`; `_openResult` reads the sheet's `scopedAccess`),
so a sheet mounted before a `TabsHost` exists currently picks the controller up
later — constructor capture would silently change that. The existing tests do
**not** force it: all three sites that swap the static
(`create_repo_sheet_test.dart:1468, 1630`, `add_existing_repo_sheet_test.dart:343`)
assign it *before* the pump, so a constructor capture would pass them too. A
pure move must preserve the read timing regardless of what the tests happen to
exercise.

**Moves into the flow (proven identical):**

| Member | From | Evidence |
| --- | --- | --- |
| `_provisionTab`, `_originTabId`, `_ensureProvisionTab`, `_abandonProvisionTab` | all three sheets | `diff` of the block, comments stripped: **byte-identical** create vs. add-existing; clone adds 3 lines of routed-job teardown |
| `_refusedAtTabCap` | all three sheets | textually identical in all three |
| ~~`_openResult`~~ | ~~create, clone~~ | **Deferred to Phase 3 — deviation 1, 2026-09-08.** The `diff` finding stands (the exact method bodies differ by **one line**, the `scopedAccess` static), but the move cannot be pure: see below. |

**Does NOT move — and the first draft was wrong to say it would:**

* **`ensureProvisioned` stays in `WorkspaceProvisioning`.** It is already a
  single implementation, so it is not part of F7's duplication, and it is not
  cleanly splittable: across 42 lines it makes three `mounted` checks and three
  `setState` calls, and its mid-dial guard (`destConnectionId != conn.id`,
  `workspace_provisioning.dart:79`) re-reads **live sheet state after an
  await** — that guard is the 0022 H4 fix. Moving it would either lose the
  guard or force the flow to call back into widget state through a callback
  whose contract is subtler than the duplication it removes. Nothing is gained:
  there is one copy today.
* **`_opensNewTab` does not move.** It reads as identical but is not: create
  and clone spell it `!_isLocalTarget || _saveLocal`, add-existing
  `!_isLocal || _save`. Same meaning, different sheet fields, so it stays a
  sheet getter and is passed to `refusedAtTabCap(opensNewTab:)` as an argument.
* **`workspace_open_in_tab.dart` stays as it is.** The flow *calls* it. It has
  a caller outside these sheets — `connection_switcher.dart:1143` — so
  absorbing it into the flow would break the switcher.
* **`registerAndActivateLocal` / `saveLocalRepo` move as-is**, taking the
  flow's captured `ProviderContainer` instead of a `WidgetRef`. Their bodies do
  not change; `ProviderContainer` exposes the `read` and `invalidate` they use.

**Each sheet takes a different amount of the flow, and that is expected:**

| Sheet | Uses |
| --- | --- |
| create | tab lifecycle (+ `openResult` from Phase 3) |
| clone | tab lifecycle, with its routed-job teardown via `abandon`'s callback (+ `openResult` from Phase 3) |
| add-existing | tab lifecycle **only** — it has no `_openResult`; `_openRemote`/`_openLocal` are differently shaped (fsmonitor and persistence are separate steps, and it carries the scoped git-dir) |

Unifying add-existing's open path is **explicitly out of scope for this phase**.
It is not proven identical to anything, and Phase 5 touches that sheet anyway.

#### 2.2 The registration tests port later, not here

New `test/workspace_flow_test.dart`, driving `WorkspaceFlow` over a bare
`ProviderContainer` with no `pumpWidget`.

**No registration test ports in this phase** — a second consequence of
deviation 1 that its first write-up missed. Deviation 1 moved
`workspace_registration.dart` onto Phase 3's file list, so
`registerAndActivateLocal` still takes a `WidgetRef` here. "Porting" its four
tests now would leave them driving the unchanged function through `_pumpWork` —
copying a file, not porting a test. They move with the function.

**Ported in Phase 3 — the four `registerAndActivateLocal` tests**
(`workspace_registration_test.dart:176-286`), which cover **live** behaviour
called from `create_repo_sheet.dart:712` and `clone_sheet.dart:530`:

* `save:false calls connectLocal without persisting`
* `a failed connect reports false and persists nothing`
* `save:true persists SavedLocalRepo with bookmark data`
* `save:true with empty label passes null to connectLocal`

**Ported in Phase 4 — the four `registerAndActivateSshActive` tests**
(`:287-407`). The first draft said they would be ported here "against the
still-present function"; that contradicts the phase's own premise of driving
`WorkspaceFlow`, and the flow has no active-session path until Phase 4 restores
it (F2). Porting them here would mean either testing the old function from the
new file — which is not a port — or writing tests against a method that does not
exist.

`test/workspace_registration_test.dart` therefore **survives Phase 2
untouched** and is deleted in Phase 4, once all 8 have green counterparts. The
MADR's rule stands and is unchanged: never delete before that. What Phase 2
delivers instead is §2.3 — new coverage rather than moved coverage.

#### 2.3 The four invariants that have never been asserted

Each must be **seen to fail** against its mutation before the phase is called
done (they are the first four Phase-2 rows of the sabotage table):

1. every grant acquired is released when no session starts;
2. an abandoned flow closes the dialled tab;
3. …and re-activates the origin tab;
4. the container captured at construction is the one the result opens in;
5. a flow refused at the tab cap dials nothing.

#### 2.4 Acceptance

**120 offline tests across 7 files must pass unchanged** — not the 73 the first
draft claimed, which counted only the three files named after the sheets and
missed `create_repo_namespace_search_test.dart` (24),
`create_repo_namespace_test.dart` (9), `connection_edit_test.dart` (8) and
`namespace_backfill_wiring_test.dart` (6):

```sh
flutter test test/add_existing_repo_sheet_test.dart test/clone_sheet_test.dart \
  test/connection_edit_test.dart test/create_repo_namespace_test.dart \
  test/create_repo_namespace_search_test.dart test/create_repo_sheet_test.dart \
  test/namespace_backfill_wiring_test.dart
# expect: +120
```

`test/create_repo_wire_live_test.dart` (4 tests) also drives the create sheet
and is **excluded deliberately**: it is `live-forge` tagged, hits real
GitHub/GitLab and is mutating. It is never run for this plan.

A sheet test that needs editing means the move was not pure — **stop and
prompt**, do not adjust the test.

**Commit.**

### Phase 3 — F3 and F9 on the single copy

* **F3 — and the `_openResult` move itself, deferred here by deviation 1.**
  `_openResult` moves out of both sheets into `WorkspaceFlow.openResult`; the
  two copies differ by exactly one line (the `scopedAccess` static), which
  becomes a flow input. Because the flow has no `ref`, `registerAndActivateLocal`
  and `saveLocalRepo` necessarily read `flow.container` — that *is* F3's fix,
  and it is why this move belongs in a behavioural phase rather than a pure
  one. Delete the now-unused `WidgetRef` parameters. The comment at `create_repo_sheet.dart:499-501`
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
6. **Port the four remaining registration tests** —
   `updates connection metadata and sets repoPath`, `with fsmonitor calls
   setFsmonitor on git service`, `with label saves it in connection metadata`
   and `without connectionId (ad-hoc) skips metadata mutation`
   (`workspace_registration_test.dart:287-407`) — onto the flow's new
   active-session path. The last of these **is** this phase's specification.
7. **Only then delete** `registerAndActivate` and
   `registerAndActivateSshActive` (`workspace_registration.dart:77-171`), and
   with them the dispatcher's `gitDir`-dropping `sshProvision` branch
   (`:158-166`), and `test/workspace_registration_test.dart`, now fully
   superseded. The order is load-bearing: all 8 have green counterparts before
   anything is removed.

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
2. The **120** offline sheet tests across 7 files pass unchanged across
   Phase 2 — a phase that needs to edit them is not the pure move it claims to
   be. (`create_repo_wire_live_test.dart`'s 4 are excluded: `live-forge`,
   mutating, never run for this plan.)
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


### Phase 2 — 2026-09-08 — *complete*

**`WorkspaceFlow`** (`lib/features/workspace/workspace_flow.dart`) is a plain,
widget-free object owning the tab half of the lifecycle: claim a tab, hand it
over on success, give it back on abandon, refuse at the cap. All three sheets
delegate to it; `WorkspaceProvisioning` is now an adapter whose
`_dialContainer` is `flow.container`.

**What did not move, and why it matters.** `ensureProvisioned` stayed in the
mixin. It is one implementation already — not F7 duplication — and its mid-dial
guard re-reads live sheet state after an await (the 0022 H4 fix), so moving it
would have traded a real guard for a callback contract subtler than the
duplication it removes. `workspace_open_in_tab.dart` also stayed: the flow
calls it, because `connection_switcher.dart:1143` is a caller outside these
sheets.

**A `late final` that reintroduced the exact bug the mixin warns about.** The
flow was first written as `late final _flow = WorkspaceFlow(origin:
ProviderScope.containerOf(context, …))`. `dispose()` calls
`_abandonProvisionTab`, so on a sheet that never touched `_flow` the
initialiser ran *from dispose*, looking up an inherited widget on a deactivated
element:

```
Looking up a deactivated widget's ancestor is unsafe.
#3  ProviderScope.containerOf
#6  _CloneRepositorySheetState._abandonProvisionTab
#7  _CloneRepositorySheetState.dispose
```

**42 of the 120 acceptance tests failed**, which is exactly what acceptance
criterion 2 is for — the failure said "not a pure move" and it was right.
Fixed by building the flow in `initState`, which is what
`WorkspaceProvisioning._notifier` already exists to do for the same reason.
`AddExistingRepoSheet` gained its first `initState` for this.

**Deviation 1 — `_openResult` could not move here.** The flow has no
`WidgetRef`, so moving `_openResult` would have forced
`registerAndActivateLocal`/`saveLocalRepo` onto the captured container — which
*is* F3's fix. Deferred to Phase 3 so this phase stays a pure move and its
acceptance criterion keeps its meaning. A follow-on the deviation's first
write-up missed: the four `registerAndActivateLocal` tests move with their
function, so **no registration test ported in this phase**; §2.2 is corrected.

**Three test defects, all the same two traps.** The flow's own tests found them
because `tabs_controller.dart:248-255` reuses a **blank active tab** rather
than stacking a second one:

* a test that filled tabs with `newTab()` to reach the cap **spun forever** —
  every blank tab was the same tab. (First symptom: a 3m51s run.)
* "abandon closes the claimed tab" and "the captured container never follows
  the active tab" both silently got the landing case, where the flow correctly
  reuses the blank tab and closes nothing. An `occupied()` helper now makes the
  distinction explicit, and the second test occupies the *claimed* tab too,
  since it is blank until a dial fills it in.

And the self-activation trap twice: `occupied()` activates the tab it makes, so
`expect(tabs.activated, contains(home.id))` passed on the setup's own
activation. Both assertions now measure only what `abandon` adds.

**Two survivors, both test defects, neither a hole in the code.** *"the flow
re-resolves its container"* and *"abandon does not return to the origin tab"*
survived the first run for exactly the two reasons above.

**Sabotage — 12 mutations (4 Phase 1, 8 Phase 2), all killed:**

```
phase2: the flow re-resolves its container instead of keeping the captured one
      -> the captured container never follows the active tab
phase2: abandon does not close the dialled tab
      -> abandon closes the claimed tab and returns to the origin
phase2: abandon does not return to the origin tab
      -> abandon closes the claimed tab and returns to the origin
phase2: abandon closes a reused blank tab too
      -> a reused blank tab is left alone
phase2: the session is released AFTER the tab is closed
      -> the session is released before the tab is closed
phase2: the tab cap is ignored, so a ninth session is spun up
      -> a flow refused at the cap claims nothing
phase2: refusedAtTabCap ignores a tab already held
      -> a flow already holding a tab is not refused again
phase2: keep() closes the tab instead of handing it over
      -> keep() hands the tab over, so a later abandon closes nothing
```

**Verification:**

```
120 offline sheet tests             +120, UNEDITED (acceptance criterion 2)
flutter analyze (whole project)     No issues found!
dart format                         0 changed
flutter test (full suite)           03:32 +3787 ~3: All tests passed!
tool/mutate.py (12 mutations)       12 killed, 0 survived, 0 did not apply
expect=9513 testWidgets=1072
```

The 257 lines of shared workspace lifecycle that had **zero** direct test
callers now have 15, none of which pumps a widget.

### Phase 3 — 2026-09-08 — *complete*

**`_openResult` is one implementation.** Both copies moved into
`WorkspaceFlow.openResult`, parameterised by `WorkspaceOpenRequest`. The two
differed by exactly one line — which sheet's `scopedAccess` static they read —
and 221 lines came out of the three files for 84 put back.

**F3 is now unrepresentable rather than fixed.** `registerAndActivateLocal` and
`saveLocalRepo` take a `ProviderContainer`, not a `WidgetRef`. There is no
ambient ref in the flow to drift onto whichever tab is active
(`tabs_host.dart:500-505`), so the "finished repository connects into the wrong
tab" defect cannot be written.

**F9, all three parts.** Clone now records its namespace **before** the open,
matching create — the repository is on disk either way, and a clone that fails
to open is exactly when remembering where it came from is most useful. An
**unsaved** local open records its namespace while still writing no MRU entry:
it had been dropped only because it shared a guard with the MRU write, not for
any reason of its own. And `_rememberNamespace` reads through the flow's
captured container.

**The stale `_effectiveConnectionId` comment** in both sheets described the
pre-0036 world ("the destination defaults to *this* session (`sshActive`) and
the picker never sets an id"). It does set one now; the comment was a fossil
pointing at exactly the gap F2 reports, and now says so.

**Two scope corrections, both recorded rather than absorbed silently:**

1. **`registerAndActivate` (the dead dispatcher) was deleted here, not in
   Phase 4.** Changing `registerAndActivateLocal`'s signature broke its only
   remaining reference, and the alternative was inventing a container for a
   function with zero callers. It has **no tests at all** — unlike
   `registerAndActivateSshActive`, whose four tests are what actually gate
   deleting `workspace_registration_test.dart` — so nothing was deleted ahead
   of its replacement. F6 already sanctioned the removal.
2. **`app_providers.dart` was touched, though Phase 3's file list omits it.**
   F9.2's step text says "`_recordOpenedNamespace` is called independently for
   the unsaved case", which can only happen there. The column was incomplete,
   not the scope.

**An observation recorded, not acted on.** `registerAndActivateLocal`'s single
production caller always passes `save: false`, and did so before this refactor
too — a saved local result goes through `saveLocalRepo` + `openLocalRepoInTab`
instead. Its `save: true` branch is therefore unreachable in production, and
three of the four ported tests exercise a dead parameter. Pre-existing, adjacent
to F6, out of scope here; noted in `workspace_flow_test.dart` beside the tests.

**The four ported tests are a port, not a copy.** They previously needed a
pumped `_RefHarness` widget to obtain a `WidgetRef`; they now drive a bare
`ProviderContainer`. `test/workspace_registration_test.dart` keeps only the
`registerAndActivateSshActive` group, which ports in Phase 4 with the capability
it specifies — and remains the only thing gating that file's deletion.

**One test-harness gap the port exposed.** `workspace_flow_test.dart` has no
`testWidgets` at all, so nothing initialised the binding and the ported tests'
mock method-channel handler threw "Binding has not yet been initialized".
`TestWidgetsFlutterBinding.ensureInitialized()` at the top of `main()` is the
fix, and the comment says why the file has no widget test to do it implicitly.

**Sabotage — 16 mutations (4 Phase 1, 8 Phase 2, 4 Phase 3), all killed.** One
Phase 3 mutation was **broken on first run** — `if (!ref.read(connectionProvider).isConnected) return false;`
matched twice in `workspace_registration.dart`, so the experiment never
happened; re-anchored on the preceding `connectLocal` call.

```
phase3: openResult places the result in the active tab, not the captured one
      -> a local result opens in the captured container, not the active tab
phase3: a clone records its namespace AFTER the open, not before
      -> a clone that lands but fails to open still records
phase3: an unsaved local open records no namespace
      -> an unsaved local open records its namespace but no MRU entry
phase3: a failed local connect is reported as success
      -> a failed connect reports false and persists nothing
```

**Verification:**

```
flutter analyze (whole project)   No issues found!
dart format                       0 changed
flutter test (full suite)         03:33 +3791 ~3: All tests passed!
tool/mutate.py (16 mutations)     16 killed, 0 survived, 0 did not apply
expect=9519 testWidgets=1069
sheets + registration              84 insertions, 221 deletions
```

### Phase 4 — 2026-09-08 — *complete*

**Ad-hoc SSH sessions are targetable again**, and the dead registration branch
is gone.

**The destination is a type, not a nullable id.** `WorkspaceDestination` is
sealed with `LocalMacDestination` / `ActiveSessionDestination` /
`SavedConnectionDestination`, each with value equality because
`MacosPopupButton` selects by `==`. A sentinel id would have restored the
capability and re-created its cause — one value meaning two things — which is
exactly how F2 arose: `null` meant both "This Mac" and "an ad-hoc session has
no id to give you".

**The active-session row is offered only when the session is ad-hoc.** A saved
session is already in the list by id, and two rows for one host is two ways to
say one thing. Labelled from `ConnectionState.host`, which is populated for
ad-hoc sessions (`app_providers.dart:1348`).

**It dials nothing and claims no tab**, so `_opensNewTab` excludes it and the
tab cap does not apply. Without that a user at 8 tabs on an unsaved session
could not create at all — the cap exists to protect `openOrFocus`, which this
path never reaches.

**The last four registration tests are ported**, onto
`WorkspaceFlow._placeOnActiveSession`. `registerAndActivateSshActive` and
`test/workspace_registration_test.dart` are deleted — after, not before, all
eight had green counterparts. `workspace_registration.dart` is now one pair of
functions for the local half, and its header records why it stopped being a
"matrix".

**Two survivors, and they were different kinds of wrong:**

* *"an active-session target claims a tab and is capped"* — a genuine **test
  gap**. `workspace_flow_test.dart` proved `openResult` claims no tab, but
  nothing proved the *sheet* exempts the target from the cap. Closed with a
  create-sheet test at `capReached`.
* *"an ad-hoc result persists into a connection it has none of"* — a mutation
  of mine that was **inert**. It flipped `if (connectionId != null)` to
  `if (true)`, but with a null id the lookup inside matches nothing anyway, so
  behaviour was unchanged and the green read as proof. Replaced with the
  plausible wrong implementation the guard actually prevents: falling back to
  the only saved connection.

**Test-type churn, expected and confined.** `MacosPopupButton<String?>` became
`MacosPopupButton<WorkspaceDestination>` in the two wizards, so
`destinationPopup()` and three assertions were retyped. The add-existing
sheet's own popup is still `String?` and was deliberately left alone — Phase 5
touches that sheet.

**Sabotage — 21 mutations (4/8/4/5 across the phases), all killed:**

```
phase4: an ad-hoc session is treated as This Mac again
      -> an ad-hoc SSH session opens on itself, not This Mac
phase4: the active-session row is offered for a saved session too
      -> a saved session is NOT offered twice
phase4: an active-session target claims a tab and is capped
      -> an ad-hoc create is NOT refused at the tab cap
phase4: an ad-hoc active-session result persists into a connection it has none of
      -> without connectionId (ad-hoc) skips metadata mutation
phase4: an active-session result never becomes live
      -> updates connection metadata and sets repoPath
```

**Verification:**

```
flutter analyze (whole project)   No issues found!
dart format                       0 changed
flutter test (full suite)         03:26 +3796 ~3: All tests passed!
tool/mutate.py (21 mutations)     21 killed, 0 survived, 0 did not apply
expect=9527 testWidgets=1069
F6 proof                          no `registerAndActivate*` outside the local pair
```


#### Deviation 2 — 2026-09-08 — the add-existing sheet cannot seed a target it cannot open

**Found while starting Phase 5.** F4's step says the sheet should seed from the
live session "through the same helper both wizards use — the three-shape
mapping from Phase 4, so an ad-hoc session seeds correctly here too". It
cannot, as written: `_openRemote` resolves a `SavedConnection` and a
provisioning token before it can finalize (`local_repo_form.dart:492-494`), and
an ad-hoc session has neither. Seeding `ActiveSessionDestination` without an
open path would leave `_canOpen` false forever
(`local_repo_form.dart:725`) — a selection the user can make and nothing can
service.

**Decision — full ad-hoc support in this sheet too.** It seeds the third shape,
browses on the session it already holds, and opens through
`WorkspaceFlow.openResult(activeSession: true)` — the path Phase 4 built. All
three entry points then honour the F2 decision the same way, and the machinery
is already written.

**Rejected — seeding only the two shapes it can service.** Smaller, and it
would still fix the "always opens on This Mac" half of F4. But it leaves "open
an existing repository on the unsaved host I am already on" with no route,
which is F2 in the one sheet F2 was not originally reported against.

**Scope added to Phase 5.** `_isLocal` (14 call sites) becomes a three-way
target, and the sheet's own popup moves from `MacosPopupButton<String?>` to
`MacosPopupButton<WorkspaceDestination>` as the wizards' did in Phase 4.
### Phase 5 — 2026-09-08 — *complete*

**F4 — the sheet opens on the location the user is in.** It never did: MADR
0036 decision 2A had been applied to both wizards, and `AddExistingRepoSheet`
had no `initState` at all, so a user connected to a host re-picked it every
time.

**F5 — one folder keeps one identity.** `_openLocal` now reuses the id of a
saved local repo already pointing at the picked path. `LocalRepoStore.save`
de-duplicates by id alone (`local_repo_store.dart:61-64`) and this sheet minted
a fresh id every open, so the same folder became **two** saved records — two
rows in Local Repositories, two of the 30 recents slots, and a second tab,
because `TabsController._find` matches on (connectionId, repoPath) together and
the new id never matched. Reused at the **sheet**, not in the store: two
records for one path is a legitimate state for a caller that means it, and
collapsing them inside `save` would silently change `updateMetadata` too.
`connection_form.dart:182-194` has solved the same problem for SSH profiles all
along.

**Deviation 2 — full ad-hoc support, per the maintainer.** The sheet takes the
third target properly: it seeds it, browses on the session it already holds
(no dial, no tab), and opens through `WorkspaceFlow.openResult(activeSession:
true)`. All three entry points now honour the F2 decision identically.

**A bug I introduced, caught by the existing tests.** The first seeding read
`conn.isLocal` alone — but a **disconnected** session still reports the default
`ssh` backend, so a sheet with no session at all seeded
`ActiveSessionDestination`, which the control only offers while a session is
live. `MacosPopupButton` asserts its value is among its items, and four tests
failed on that assertion. `isConnected` is now part of the guard in **all
three** sheets, and its own test ("no session at all stays on This Mac")
distinguishes it from the local case, which is not the same assertion.

**A second one, same cause, different symptom.** Seeding a saved connection
made this sheet's popup assert on the first frame: `savedConnectionsProvider`
is async, so the matching item does not exist yet. The wizards' shared control
has always carried a fallback row for exactly this; this sheet needed one only
once it started seeding. Added, with a mutation pinning it.

**Two tests that would have passed for the wrong reason.** The F5 test asserted
an empty store while the open never reached the save — first because there was
no session (`connectLocal` reported not-connected), then because
`SecurityScopedBookmark.create` is a method channel that throws unhandled under
`testWidgets`. Both are now supplied, and the assertion fails when the id reuse
is removed.

**Two broken mutations, both re-anchored.** `an ad-hoc session is treated as
This Mac again` stopped matching when the seeding became a `switch`, and the
popup-row mutation never matched because `dart format` reflows the pattern
across three lines. `DID NOT APPLY` is a broken experiment, not a pass.

**Sabotage — 26 mutations (4/8/4/5/5), all killed:**

```
phase5: the add-existing sheet always opens on This Mac again
      -> a saved SSH session seeds that connection
phase5: an ad-hoc session is seeded as This Mac
      -> an ad-hoc SSH session seeds itself
phase5: a disconnected session seeds a live-only target
      -> no session at all stays on This Mac
phase5: re-opening a saved folder mints a fresh id
      -> re-opening a saved folder reuses its record, not a new one
phase5: the unresolved-selection row is dropped from the popup
      -> a saved SSH session seeds that connection
```

**Verification:**

```
flutter analyze (whole project)   No issues found!
dart format                       0 changed
flutter test (full suite)         03:28 +3800 ~3: All tests passed!
tool/mutate.py (26 mutations)     26 killed, 0 survived, 0 did not apply
expect=9532 testWidgets=1073
```

**The F5 follow-on, done in the same phase.** `openLocalRepoInTab` returned a
bare `null` for two different things — refused at the tab cap, and focused a tab
already on this repository — so the sheet reported the louder one. It now
returns `LocalOpenOutcome`, and a focus closes the sheet instead of claiming
"too many tabs". Reachable only since the id reuse above, which is what lets
`TabsController._find` match at all.

**The discriminator is not `canOpenTab`.** A dedupe can happen *at* the cap, and
`openOrFocus` checks for a match first, so the cap being full says nothing about
which branch ran. What separates them is whether the tab handed back is actually
on the repository that was asked for: `openOrFocus` adopts those fields on every
path that takes the request, and at the cap it returns the active tab untouched.

**One assertion that could not be written.** "The sheet closes" is not
observable in this harness for *any* outcome: `_pump` mounts the sheet as
`MacosApp.home`, where `Navigator.canPop()` is false. Asserting it would have
pinned the harness rather than the behaviour, so the test asserts what actually
distinguishes the outcomes — the right tab is active, no second tab exists, and
no second session ran.

### Phase 6 — 2026-09-08 — *complete*

Catalogue, index row, plan status and the MADR's `verified:` date.

**Acceptance criteria, each against the evidence that establishes it:**

| # | Criterion | Established by |
| --- | --- | --- |
| 1 | A remote create, clone or open appears in Recents and records its namespace | `connection_provisioning_test.dart` — 4 tests on `finalizeProvisioned`, including a superseded finalize recording nothing |
| 2 | The 120 offline sheet tests pass **unchanged** across Phase 2 | Ran as its own gate; 42 failed first and correctly said "not a pure move" |
| 3 | All 8 registration tests have green counterparts before the file is deleted | 8 in `workspace_flow_test.dart`; `workspace_registration_test.dart` deleted in Phase 4, after |
| 4 | Four lifecycle invariants asserted with no `pumpWidget` | `workspace_flow_test.dart` — **26 `test()`, 0 `testWidgets()`** |
| 5 | An ad-hoc session can target the host it is on, from all three sheets; it dials nothing, opens no tab, persists nothing | Phase 4's five mutations + Phase 5's five |
| 6 | A connected saved session shows exactly one destination row | "a saved session is NOT offered twice" |
| 7 | Opening one local folder twice yields one saved repo and one tab | "re-opening a saved folder reuses its record" + "…focuses it, not the cap" |
| 8 | No production caller of `registerAndActivate*` remains, and the functions are gone | `grep` returns nothing beyond the local pair |
| 9 | Analyze clean, suite green each phase, every mutation killed | the per-phase blocks above |

**Findings, all nine:**

| # | Outcome |
| --- | --- |
| F1 | Fixed in Phase 1; MADR 0037's coverage claim amended |
| F2 | Fixed in Phase 4 (wizards) and Phase 5 (add-existing) — ad-hoc sessions targetable again |
| F3 | Made **unrepresentable** in Phase 3: the flow holds a container, so there is no ambient `ref` to drift |
| F4 | Fixed in Phase 5 |
| F5 | Fixed in Phase 5, with its follow-on |
| F6 | Dispatcher deleted in Phase 3, `registerAndActivateSshActive` in Phase 4 |
| F7 | Fixed in Phase 2 — one `WorkspaceFlow`, three sheets |
| F8 | Fixed in Phase 3 — one `openResult` |
| F9 | Fixed in Phase 3, all three parts |

**What the sabotage was actually worth.** 27 mutations, all killed. Across six
phases it surfaced **six survivors and four broken experiments**, and of the six
survivors exactly **one** was a hole in the production code (Phase 4's tab-cap
exemption, which no test covered). The other five were tests proving something
other than what they claimed, and the four `DID NOT APPLY` were catalogue
entries that had silently stopped matching — the failure mode where a green run
means nothing at all.

**Final verification:**

```
flutter analyze (whole project)   No issues found!
dart format                       0 changed
flutter test (full suite)         03:32 +3801 ~3: All tests passed!   (baseline 3768)
tool/mutate.py (27 mutations)     27 killed, 0 survived, 0 did not apply
expect=9536 testWidgets=1074      (baseline 9471 / 1072)
```

**Two observations recorded, and since closed** — see "Residuals" below:

* `registerAndActivateLocal`'s only production caller always passes
  `save: false`, so its `save: true` branch is unreachable — pre-existing,
  adjacent to F6, noted beside the tests that cover it.
* `_effectiveConnectionId`'s fallback (`_destConnectionId ?? activeId`) is now
  load-bearing only for the ad-hoc case, which Phase 4 gave a real target. It is
  correct as written; whether it should collapse now that the destination is a
  type is a question for a later pass.

### Residuals — 2026-09-08 — *closed*

The two items Phase 6 recorded as "observed, not acted on". Both resolved at
the maintainer's request; neither changes behaviour.

**1. `registerAndActivateLocal`'s unreachable `save: true`.** Its only
production caller has always passed `save: false` — a result the user *does*
want saved goes through `saveLocalRepo` + `openLocalRepoInTab` instead, so it
lands in its own tab (MADR 0036, 3B). The flag is gone, and with it the second
call to `saveLocalRepo`: two ways to persist one thing, one of them dead. The
function is now three lines.

**Coverage moved rather than dropped.** Two of the four ported tests exercised
that dead flag. What they were really about — bookmark, then persist — is
`saveLocalRepo`, which is live and had **no direct test at all**; its coverage
came only from sheet-level tests of the saved-local path. It now has three
(bookmark stored, unsigned build degrades to an empty bookmark, a throwing
store yields null while the repository still exists), which is strictly more
than was there before.

**2. `_effectiveConnectionId` collapses — the question is answered "yes".** It
read `_isLocalTarget ? null : (_destConnectionId ?? activeId)`. The `?? activeId`
fallback was written for the pre-0036 world where connected mode never set a
destination id. Case by case against the sealed type:

* `LocalMacDestination` → `_isLocalTarget` is true → null; `_destConnectionId`
  is also null.
* `ActiveSessionDestination` → `_destConnectionId` is null, so it falls back to
  `activeId` — which is **null in every producible state**, because that row is
  offered and seeded only when `session.connectionId == null`
  (`workspace_destination.dart:64`, `local_repo_form.dart:942`, and the three
  seeders), and an ad-hoc session cannot acquire an id: a drop-triggered
  reconnect reuses `_lastProfile`, which carries the same null.
* `SavedConnectionDestination(id)` → the id.

So the helper was exactly `_destConnectionId` in all three cases, and is
deleted. The `?? activeId` was a fossil of the model deficiency that produced
F2; with the deficiency fixed, the workaround has nothing left to do. Removing
it also drops a `connectionProvider.select` watch from the create sheet's build
path that existed only to feed it.

**Sabotage — 31 mutations, all killed.** Four new, and one existing entry
re-anchored: *"a failed local connect is reported as success"* stopped matching
when `registerAndActivateLocal` collapsed to a single `return`, which the
harness reported as `DID NOT APPLY` rather than a pass.

```
residual: a local open persists a record it was told not to
      -> opens the folder and persists nothing
residual: saveLocalRepo drops the bookmark it just minted
      -> persists the repo with its bookmark data
residual: a failed store write is reported as a save
      -> a store that throws yields null, and the repo still exists
residual: the namespace of a saved-host create goes to the This-Mac store
      -> a successful forge create records it
```

**Verification:**

```
flutter analyze (whole project)   No issues found!
dart format                       0 changed
flutter test (full suite)         03:34 +3804 ~3: All tests passed!
tool/mutate.py (31 mutations)     31 killed, 0 survived, 0 did not apply
expect=9540 testWidgets=1074
```

Nothing from MADR 0038 is now outstanding.

#### Deviation 1 — 2026-09-08 — Phase 2 cannot move `_openResult` and stay pure

**Found while writing Phase 2.** `WorkspaceFlow` is widget-free by design, so it
has no `WidgetRef`. But `_openResult`'s local branches call
`registerAndActivateLocal(ref, …)` and `saveLocalRepo(ref, …)`
(`create_repo_sheet.dart:712, 719`; `clone_sheet.dart:530, 537`). Moving the
method into the flow therefore *forces* those onto the captured container —
which is exactly F3's fix. There is no way to move it and preserve the defect
short of passing a `WidgetRef` into the flow purely to keep a bug alive.

**Decision — move `_openResult` in Phase 3 instead.** Phase 2 moves only the tab
lifecycle, which is provably pure, so its acceptance criterion keeps its
meaning: if any of the 120 offline sheet tests fails, the move was not pure.
That inference is the whole reason the criterion exists, and it does not survive
a phase that is also allowed to change behaviour — even a change the current
tests cannot observe (none of them switches tabs mid-flight, so F3's fix is
invisible to all 120).

**Rejected — accepting the fix in Phase 2.** One fewer step, and 120-unchanged
would still have held in practice. But a failure would then have two candidate
causes, and the criterion could no longer distinguish them.

**Scope moved,** not added: `_openResult` and `workspace_registration.dart` come
off Phase 2's file list and onto Phase 3's. Phase 2 gets smaller; nothing new
enters the plan.

**Follow-on, found during execution:** the four `registerAndActivateLocal`
tests move with their function, so they port in Phase 3 too — Phase 2 ports no
registration test at all. §2.2 originally said otherwise; corrected there.
### Phase 2 re-analysis — 2026-09-08, before execution

A multi-pass check of Phase 2 against the tree, at the maintainer's request.
Every assertion the phase rested on was re-derived from the code rather than
carried forward. **Five were wrong**, three of them in a direction that would
have made execution non-deterministic. The phase is rewritten above; the
evidence is here.

**Pass 1 — the code-shape claims.** Two held, two were wrong.

* *Held:* the four provision-tab members are byte-identical between create and
  add-existing, and differ from clone by three lines of routed-job teardown.
* *Held:* `_refusedAtTabCap` is textually identical in all three sheets.
* **Wrong — `_openResult` differs by less than claimed.** The plan said the two
  copies differ in "`scopedAccess`, and the label/fsmonitor fields". Diffing the
  exact method bodies (create 703-773, clone 521-589, comments stripped) gives
  **exactly one differing line**: the `scopedAccess` static. The label and
  fsmonitor fields are spelled identically in both sheets, so they are inputs,
  not a source of divergence. The move is simpler than planned.
* **Wrong — `_opensNewTab` is not identical.** Create and clone spell it
  `!_isLocalTarget || _saveLocal`; add-existing `!_isLocal || _save`. Same
  meaning, different sheet fields. It cannot move; it becomes an argument.

**Pass 2 — the test-surface claim. Wrong, and materially.** "The 73 existing
sheet tests" counted only the three files named after the sheets. Seven offline
files drive these sheets — adding `create_repo_namespace_search_test.dart` (24),
`create_repo_namespace_test.dart` (9), `connection_edit_test.dart` (8) and
`namespace_backfill_wiring_test.dart` (6) — for **120**. An acceptance criterion
that names the wrong number is not a check; it would have passed while 47 tests
went unexercised. An eighth file, `create_repo_wire_live_test.dart` (4), also
drives the create sheet and is excluded on purpose: `live-forge`, mutating,
never run.

**Pass 3 — internal contradictions. Two found.**

* The phase claimed to port all 8 registration tests "driving `WorkspaceFlow`
  directly", then said four of them "target the still-present function" until
  Phase 4. Both cannot be true. Resolved: the four live
  `registerAndActivateLocal` tests port here; the four
  `registerAndActivateSshActive` tests port in Phase 4, where the capability
  they specify exists. `workspace_registration_test.dart` survives Phase 2 and
  is deleted in Phase 4.
* The phase implied all three sheets consume the flow uniformly. Add-existing
  has no `_openResult` at all — `_openRemote`/`_openLocal` are differently
  shaped (separate fsmonitor and persistence steps, plus the scoped git-dir).
  Resolved: add-existing takes the tab lifecycle only, and unifying its open
  path is explicitly out of scope.

**Pass 4 — determinism gaps. Three closed.**

* **`ensureProvisioned` must not move**, though the sketch put it on the flow.
  It is already a single implementation, so it is not F7 duplication, and it is
  not cleanly splittable: three `mounted` checks and three `setState` calls in 42
  lines, with a mid-dial guard (`workspace_provisioning.dart:79`) that re-reads
  live sheet state after an await — that guard *is* the 0022 H4 fix. Moving it
  would trade a real guard for a callback contract subtler than the duplication
  it removes, and remove no duplication at all.
* **`workspace_open_in_tab.dart` must survive.** The flow calls it, it is not
  absorbed: `connection_switcher.dart:1143` is a caller outside these sheets.
  The plan had not said either way.
* **`tabs` and `scopedAccess` must resolve lazily, not at construction** — and
  the first justification written for this was itself wrong, which is why it is
  recorded. The draft claimed the tests assign the statics *after* the pump, so
  a constructor capture would miss them. They do not: all three sites
  (`create_repo_sheet_test.dart:1468, 1630`,
  `add_existing_repo_sheet_test.dart:343`) assign *before* the pump, and a
  constructor capture would pass every one of them. The real reason is
  behaviour preservation — the code being moved reads both statics at each use,
  so a sheet mounted before a `TabsHost` exists currently picks the controller
  up later. A justification that only holds because of how the tests happen to
  be written is not a justification.

**What this changes about the phase.** It gets smaller and better specified:
one line of genuine divergence in `_openResult` instead of three values to
parameterise, one fewer member to move, `ensureProvisioned` left alone, four
tests ported instead of eight, and an acceptance check that names 120 tests
instead of 73. Nothing found here changes the MADR's findings or the phase
order.

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
shell; none of the three sheets appears in it), so the check is the 120 offline
sheet tests, and acceptance criterion 2 is what makes it meaningful.
