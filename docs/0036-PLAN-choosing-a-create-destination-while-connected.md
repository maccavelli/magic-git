---
status: "in-progress"
date: 2026-09-08
associated-madr: "0036-MADR-choosing-a-create-destination-while-connected.md"
---
# Implement the destination choice, and open every created repository in its own tab

Associated MADR: [0036-MADR-choosing-a-create-destination-while-connected.md](0036-MADR-choosing-a-create-destination-while-connected.md)

Line numbers below are as of `24d1e4f`. Re-run the proof table before
starting; if a line has moved, update the plan before the phase, not after.

## Goal

Show the wizard's **Destination** step when a session is already open, and
open **every** successfully created repository — This Mac, the current host,
or any saved host with no session anywhere — in **its own new tab**, leaving
the tab the wizard was opened from untouched.

Executes the MADR's chosen options: **1C** (work runs in another tab), **2A**
(This Mac + every saved connection, defaulting to the current session),
**3B** (every result opens in a new tab), **4A** (clone follows, sequenced
last), **5B** (an unsaved local repo opens in the current tab and says so),
**6B** (dial at submit), **7A** (refuse at the tab cap).

Reduced to one rule: *a create runs where it can and opens where it lands,
and the tab the wizard was opened from is never touched.*

## Proof of the MADR's assertions

Each is read-only. Run all of them before Phase 1 and paste the output into
the execution record.

| # | Assertion | Proof |
| --- | --- | --- |
| P1 | The Destination step is landing-only, in both sheets, and is the **only** conditional step in either | `grep -n "applicable: () => widget.landing," lib/features/workspace/{create_repo_sheet,clone_sheet}.dart` → `create_repo_sheet.dart:188`, `clone_sheet.dart:114`; `grep -c "applicable:"` → **1** in each |
| P2 | The variant is chosen purely on whether a session exists | `sed -n '409,416p' lib/features/app_shell.dart` → `isConnected ? .connected() : .landing()`; same at `connection_switcher.dart:1057-1066` |
| P3 | When connected, `_destConnectionId` is **unreachable** | `grep -n "_destinationSection\|_onDestChanged" create_repo_sheet.dart` → `_onDestChanged` (430) used only at 779 inside `_destinationSection` (776), used only at 190 as `body:` of the step gated at 188 |
| P3b | …and the connected branch would ignore it anyway | `sed -n '386,406p' create_repo_sheet.dart` → connected branch reads `conn.isLocal`; the only `_destConnectionId` read (400) is in the landing `else` |
| P4 | Dialling **claims the tab's session** | `awk 'NR>=2415 && NR<=2448' lib/core/providers/app_providers.dart \| tr -d '\000' \| grep -nE "release\|_lastRepoPath\|_invalidateRepoState\|clear\(\)\|resetEnvironment"` → 8 lines |
| P5 | `openOrFocus` runs `connect` in the **target** tab's container | `tabs_controller.dart:258-300`: `connect(act.container)` (285), `connect(tab.container)` (300) |
| P6 | SSH-target create **works today** and is covered | `flutter test test/create_repo_sheet_test.dart --plain-name "plain create: git init -b main in the parent, then activates"` → passes; the harness session is `host: 'h'`, `connectionId: 'c1'` (`create_repo_harness.dart:182-188`) |
| P7 | No test completes an `sshProvision` create | Only landing tests: `create_repo_sheet_test.dart:1339`, `:1376`. The one `createButton()` past 1300 (`:1318`) is in the connected test at `:1304` |
| P8 | The registration matrix already handles `sshProvision` | `workspace_registration.dart:146-157` → `finalizeProvisioned(...)` |
| P9 | The tab cap is a **silent no-op** | `tabs_controller.dart:289-292`: `if (!canOpenTab) return act ?? ensureInitialTab();` — before `connect` |
| P10 | Every tab is its own session | `tabs_controller.dart:105-107` doc; `_defaultContainerFactory` builds a fresh `ProviderContainer` per tab (`:95-101`) |
| P11 | `ScopedAccess.instance` is **not** injectable | `scoped_access.dart:29`: `static final ScopedAccess instance` — but the constructor takes `startAccessing:` (`:21-24`), so a test double is constructible |
| P12 | `TabsController.current` is a settable static | `tabs_host.dart:126` assigns it, `:166-167` nulls it; `TabsController extends ChangeNotifier` (`tabs_controller.dart:44`) and accepts a `containerFactory` — a recording subclass is possible |

**P6 + P7 fix the ordering:** the capability exists and is covered for
`sshActive`; the `sshProvision` path is not covered at all. Coverage lands
first (Phase 1) and nothing in `lib/` changes until it has.

## Scope

### In scope

| Phase | What | Files |
| --- | --- | --- |
| 1 | Cover the provisioned create end to end — tests only | `test/helpers/create_repo_harness.dart`, `test/create_repo_sheet_test.dart` |
| 2 | Pin today's connected behaviour, and the test doubles later phases need — tests only | `test/helpers/create_repo_harness.dart`, `test/create_repo_sheet_test.dart`, `test/clone_sheet_test.dart` |
| 3 | Show the step; one SSH path; refuse at the cap | `lib/features/workspace/create_repo_sheet.dart` |
| 4 | Open the result in its own tab | new `lib/features/workspace/workspace_open_in_tab.dart`; `create_repo_sheet.dart`; `workspace_provisioning.dart`; `connection_switcher.dart` (its local-open block moves, not copied) |
| 5 | Clone: same routing, progress watched in the target container | `lib/features/workspace/clone_sheet.dart`, `workspace_open_in_tab.dart` |
| 6 | Docs, mutation catalogue, index | `docs/README.md`, `tool/mutations/0036-destination.json`, this plan |

### Out of scope

* **A `live-forge` SSH create.** Mutating, host-dependent, never done before;
  its own decision.
* **Changing `beginProvisioning`.** Its takeover is correct for a blank tab;
  this plan only ever hands it one.
* **`registerAndActivateSshActive`.** Stays as-is for clone's current-session
  case and `AddExistingRepoSheet`; the create sheet stops calling it.
* **The forge side** (MADR 0031/0032). Untouched.
* **`AddExistingRepoSheet`.** Different gating; not in the report.

### Preconditions

```sh
flutter --version | head -1          # Flutter 3.47.2
flutter pub get --enforce-lockfile   # "Got dependencies!"
git status --short                   # empty
git rev-parse --short HEAD           # 24d1e4f, or update the line numbers above
```

### Baselines — capture before Phase 1

```sh
flutter test 2>&1 | tail -1
printf 'expect=%s testWidgets=%s\n' \
  "$(grep -rho 'expect(' test/ | wc -l | tr -d ' ')" \
  "$(grep -rho 'testWidgets(' test/ | wc -l | tr -d ' ')"
```

## Implementation Steps

### Phase 1 — Cover the provisioned create end to end

**`lib/` does not change.** Verified at commit with
`git diff --cached --stat -- lib/` printing nothing.

**1.1 — `test/helpers/create_repo_harness.dart`**, alongside `pumpConnected`:

```dart
/// The landing twin of [pumpConnected]: no session, a Destination step, and a
/// connection controller whose dial resolves to [dialResult] (a token, or
/// null for a failed dial). Same executor and store doubles, so the two
/// helpers cannot drift.
Future<(ProvisionStub, FakeCreateExecutor, FakeConnectionStore)> pumpLanding(
  WidgetTester tester, {
  List<SavedConnection> connections = const [testConn],
  int? dialResult = 7,
  List<Override> extraOverrides = const [],
});
```

`ProvisionStub extends ConnectionController` records `beginProvisioning`
calls (`dialed: List<SavedConnection>`), returns `dialResult`, and records
`finalizeProvisioned` calls (`finalized: List<({int token, String repoPath,
String label})>`), returning true. It transitions its state to
`ConnectionPhase.connected` with `connectionId: conn.id` on a successful dial,
because `registerAndActivate`'s `sshProvision` branch reads it.

Also `Finder destinationPopup() => find.byType(MacosPopupButton<String?>)` and
`Future<void> chooseDestination(WidgetTester, String displayName)`.

**1.2 — `test/create_repo_sheet_test.dart`**, new group
`'landing: a create on a chosen saved host (MADR 0036 Phase 1)'`:

| Test name | Drives | Asserts |
| --- | --- | --- |
| `creates on the chosen host and finalizes the provisioned session` | `pumpLanding` → choose `Prod` → Source → Remote (none) → Details (`new-proj`) → Review → Create | `stub.dialed.single.id == 'c1'`; `exec.calls` contains `['git','init','-b','main','--','new-proj']`; `stub.finalized.single.repoPath == '/srv/new-proj'` and `.token == 7`; `find.byType(CreateRepositorySheet)` → `findsNothing` (popped) |
| `a failed dial keeps the sheet open, shows the error, and runs nothing` | same, `dialResult: null` | error text visible (`find.textContaining('Could not connect')` or the controller's `error`); `exec.calls` is **empty**; `stub.finalized` is empty; sheet still present |
| `the parent path comes from the chosen host, not This Mac` | choose `Prod`, read the Location step | the SSH parent field is shown, not the local picker (`find.byType(...)` per the existing `_sshParentField` / `_localParentPicker` widgets) |

**1.3 — Sabotage** (scratch worktree, `tool/mutate.py`):

| Mutation | Killed by |
| --- | --- |
| `workspace_registration.dart:149` `if (conn == null \|\| provisionToken == null) return false;` → `return false;` unconditionally | test 1 |
| `workspace_provisioning.dart:90-92` `if (token == null) { onProvisioningError(...) }` → body removed, and `return token != null;` → `return true;` | test 2 |

**Verify + commit.** `flutter analyze`; `dart format --output=none
--set-exit-if-changed` on both files; `flutter test`; both mutations killed;
`git diff --cached --stat -- lib/` empty.

### Phase 2 — Pin today's behaviour, and build the doubles

Tests only. These are the invariants Phase 3/4 must not disturb by accident,
plus the two doubles those phases' tests need.

**2.1 — `test/helpers/create_repo_harness.dart`:**

```dart
/// A TabsController that records instead of building sessions. Every tab it
/// "opens" gets a fresh container from [containerFactory]; tests read
/// `opened`, `closed`, `connectRan` and set `capReached`.
class RecordingTabs extends TabsController {
  final opened = <({String? connectionId, String? repoPath})>[];
  final closed = <String>[];
  var connectRan = 0;
  bool capReached = false;
  @override bool get canOpenTab => !capReached;
  @override RepoTab openOrFocus({...}) { ... records; if (capReached) return active tab WITHOUT running connect (mirrors :289-292); else super }
  @override RepoTab newTab() { ... }
  @override Future<void> close(String id) async { closed.add(id); await super.close(id); }
}
```

Installed per test with `TabsController.current = tabs;` and cleared in
`addTearDown` (mirrors `tabs_host.dart:126,166-167`).

```dart
/// Counts acquire/release so a leaked grant is a failing assertion, not a
/// lifetime leak. Injected through the open function's parameter (P11).
class CountingScopedAccess extends ScopedAccess {
  CountingScopedAccess() : super(startAccessing: (_) async => '/resolved');
  final acquired = <String>[]; final released = <String>[];
  ...
}
```

**2.2 — `test/create_repo_sheet_test.dart`**, group
`'connected: today's behaviour, pinned (MADR 0036 Phase 2)'`:

| Test name | Asserts (all pass **now**, unedited `lib/`) |
| --- | --- |
| `a connected SSH create runs on the current session and switches the current tab` | `stub.repoPathsSet == ['/srv/new-proj']`; `tabs.opened` is **empty**. *(Phase 3 changes this on purpose — see 3.5.)* |
| `a connected local create opens in the current tab` | local variant of the harness; `tabs.opened` empty |
| `a connected sheet shows no Destination step` | `destinationPopup()` → `findsNothing`. *(Inverted in Phase 3.)* |

**2.3 — `test/clone_sheet_test.dart`:** the same three, clone-shaped, so
Phase 5 has its own baseline.

**Verify + commit.** As Phase 1; `git diff --cached --stat -- lib/` empty.

### Phase 3 — Show the step; one SSH path; refuse at the cap

All edits in `create_repo_sheet.dart`.

**3.1** `:188` — `applicable: () => widget.landing,` → `applicable: () => true,`.
The step's `intro` gains one sentence for the connected case: *"You're
currently in <session label>; it's selected below."* (the label from
`ref.read(connectionProvider).connectionLabel`).

**3.2** `_recomputeTarget` (`:386-404`) — replace both branches with one rule:

```dart
_target = _destConnectionId == null
    ? WorkspaceTarget.localMac
    : WorkspaceTarget.sshProvision;
```

Keep the SSH-parent prefill that followed it, now keyed on the **chosen**
connection: when `_destConnectionId` equals the current session's id and
`_parent.text.isEmpty`, prefill `dirname(conn.repoPath!)` as today; otherwise
leave it empty. `sshActive` is no longer produced by this sheet.

**3.3** `initState` — after the existing setup, for `!widget.landing`:
`_destConnectionId = ref.read(connectionProvider).isLocal ? null :
ref.read(connectionProvider).connectionId;`. The wizard opens on the
destination the user is in (decision 2A's default).

**3.4** `_canSubmit` — add the cap gate, after the existing checks:

```dart
// A create that opens a tab cannot run at the cap: openOrFocus would
// silently never run `connect` (tabs_controller.dart:289-292). An unsaved
// local create opens in the current tab and is exempt (MADR 0036, 5B/7A).
if (_opensNewTab && !(TabsController.current?.canOpenTab ?? true)) return false;
```

with `bool get _opensNewTab => !_isLocalTarget || _saveLocal;`. The Review
step shows, in its warning slot, exactly: **`All 8 tabs are open — close one
to create a repository.`** when that gate is what disabled Create, and for
an unsaved local create the summary line **`Opens in this tab (not saved to
Local Repositories)`**.

**3.5** Update the Phase 2 pin `a connected SSH create runs on the current
session and switches the current tab` → rename to `a connected SSH create
provisions in its own tab and leaves the current tab alone`; its assertion
becomes `stub.repoPathsSet` **empty** and `tabs.opened.single.connectionId ==
'c1'`. The test carries a comment: *"Deliberately inverted from the Phase 2
pin: MADR 0036 decision 3B."* This is the only pre-existing test this phase
edits, and the commit message names it.

**3.6** New tests, group `'connected: the destination choice (MADR 0036 Phase 3)'`:

| Test name | Asserts |
| --- | --- |
| `a connected sheet shows the Destination step` | `destinationPopup()` → `findsOneWidget` (inverts the Phase 2 pin, same comment convention) |
| `it opens on the current session` | popup value == `'c1'` for the SSH harness; `null` for the local harness |
| `every SSH destination resolves to sshProvision` | choose `Prod` (the current session) → `_target` observed via the SSH-parent prefill being `/srv` and, at submit, `stub.dialed` non-empty |
| `it refuses at the tab cap and runs nothing` | `tabs.capReached = true` → Create disabled; the exact cap message visible; `exec.calls` empty; `tabs.connectRan == 0` |
| `an unsaved local create is not gated by the cap` | local harness, `_saveLocal` off, `capReached = true` → Create enabled; summary shows the "Opens in this tab" line |

**3.7 — Sabotage:**

| Mutation | Killed by |
| --- | --- |
| `applicable: () => true` → `widget.landing` | "shows the Destination step" |
| `_recomputeTarget` → `conn.isLocal ? localMac : sshActive` | "every SSH destination resolves to sshProvision" |
| initState default removed | "it opens on the current session" |
| cap gate removed | "refuses at the tab cap" |
| `_opensNewTab` → `true` | "unsaved local create is not gated" |

**Verify. Do NOT commit alone** — see Rollout. After this phase a routed
create still dials in the current tab; Phase 4 must be in the same commit.

### Phase 4 — Open the result in its own tab

**4.1 — new `lib/features/workspace/workspace_open_in_tab.dart`.** One
function, the three existing open paths behind it, and a doc comment that
names where each came from:

```dart
/// Where a created repository goes once it exists: its own tab.
///
/// Nothing here is new. Each branch is a production path moved from the
/// place that used to be its only caller — the SSH open from
/// `connection_switcher.dart`, the local open (with its grant-release guard)
/// from the same file, and the provisioned finalize from
/// `workspace_registration.dart` — so the create and clone sheets call one
/// thing and the switcher keeps calling the same code (MADR 0036, 1C/3B).
Future<RepoTab?> openCreatedRepoInTab({
  required TabsController tabs,
  required WorkspaceTarget target,          // localMac | sshProvision
  required String dest,
  SavedLocalRepo? savedLocal,               // localMac: null = unsaved (5B)
  SavedConnection? connection,              // sshProvision
  ProviderContainer? provisionedContainer,  // sshProvision: where the dial ran
  int? provisionToken,
  String label = '',
  bool fsmonitor = false,
  ScopedAccess? scopedAccess,               // test seam (P11); default .instance
  BuildContext? context,                    // for resolveSavedLocalRepo's dialog
})
```

Branches:

* **`localMac`, `savedLocal != null`** — `resolveSavedLocalRepo(context,
  savedLocal)` → `tabs.openOrFocus(connectionId: savedLocal.id, repoPath:
  grants.repoPath, savedKind: local, connect: (c) =>
  c.read(connectionProvider.notifier).connectLocal(...))`. **If `connect`
  did not run, release every grant** (`repoPath`, and `mainRepoPath` if
  non-null) through `scopedAccess` — this is `connection_switcher.dart:1160-
  1170`, moved. The switcher's `_openLocalRepo` is then changed to call this
  function, so the guard has one home.
* **`localMac`, `savedLocal == null`** — returns null; the caller has already
  opened it in the current tab via `registerAndActivateLocal(save: false)`
  (5B). No tab work.
* **`sshProvision`** — `provisionedContainer.read(connectionProvider.notifier)
  .finalizeProvisioned(token:, conn:, repoPath: dest, enableFsmonitor:,
  label:)`; on `false`, `tabs.close(<that tab's id>)` and return null.

**4.2 — `workspace_provisioning.dart`.** The mixin gains
`ProviderContainer? provisionTarget;` — the container it dials in. Its three
`ref.read`s (`:66`, `:87`, `:112`) become `(provisionTarget ?? <own
container>).read(...)`, where "own container" is obtained once via
`ProviderScope.containerOf(context, listen: false)` in `ensureProvisioned`.
`resetProvisioning` (`:98`) uses the captured `_notifier`, which is unchanged
— it already avoids `ref` for the dispose path (its doc explains why).

**4.3 — `create_repo_sheet.dart` `_submit()`** (`:457-520`):

```
if (_isLocalTarget) {
  runCreateRepo(executor: local, ...)                       // as today
  if (_saveLocal) {
    saved = await registerLocalOnly(dest, label)            // bookmark + SavedLocalRepo, NO connectLocal
    tab   = await openCreatedRepoInTab(target: localMac, savedLocal: saved, ...)
  } else {
    await registerAndActivateLocal(save: false)             // current tab, as today (5B)
  }
} else {
  if (!tabs.canOpenTab) return                              // 7A backstop; _canSubmit already refused
  tab = tabs.newTab(); provisionTarget = tab.container
  if (!await ensureProvisioned()) { await tabs.close(tab.id); return }
  runCreateRepo(
    executor: tab.container.read(activeExecutorProvider),
    log: _OutputLogSink(tab.container.read(outputLogProvider.notifier)),
    deps: CreateRepoDeps(ensureForgeLogin: () => tab.container.read(connectionProvider.notifier).ensureForgeHostLogin(...), isActive: () => mounted),
  )
  on error/abort: await resetProvisioning(); await tabs.close(tab.id); return
  await openCreatedRepoInTab(target: sshProvision, provisionedContainer: tab.container, provisionToken:, connection:, ...)
}
```

`registerLocalOnly` is `registerAndActivateLocal` with the `connectLocal`
call removed: the bookmark/save half, extracted into
`workspace_registration.dart` so the two do not drift. `registerAndActivateLocal`
becomes `registerLocalOnly` + `connectLocal`, so clone and
`AddExistingRepoSheet` keep their existing behaviour.

**4.4 — `connection_switcher.dart` `_openLocalRepo`** (`:1122-1170`): replace
its inline open + release-guard block with a call to `openCreatedRepoInTab`.
Behaviour-neutral, proven by the switcher's existing tests passing unedited.

**4.5 — Tests**, `test/create_repo_sheet_test.dart`, group
`'the result opens in its own tab (MADR 0036 Phase 4)'`:

| Test name | Asserts |
| --- | --- |
| `an SSH create dials in a new tab and the current session is untouched` | `tabs.opened.single.connectionId == 'c1'`; the **current** stub's `phase` still `connected`, `repoPath` still `/srv/repo`, `repoPathsSet` empty; the current container's `outputLogProvider` not cleared (seed one entry before, assert it after) |
| `a saved local create opens in a new tab` | `tabs.opened.single.repoPath == '/resolved'`; `scoped.acquired.length == 1`; `scoped.released` empty |
| `no grant leaks when openOrFocus declines` | `tabs.capReached` flipped **after** `_canSubmit` (simulate the racing double-open) → `scoped.released == scoped.acquired` |
| `an unsaved local create opens in the current tab and opens no tab` | `_saveLocal` off → `tabs.opened` empty; `stub.repoPathsSet == ['/srv/new-proj']`-shaped local equivalent |
| `a failed dial closes the tab it opened` | `dialResult: null` → `tabs.closed.length == 1`; no session left at `connecting` (`ProvisionStub` records abort) |
| `a failed create after the dial closes the tab and aborts the session` | exec returns exit 1 on `git init` → `tabs.closed.length == 1`; `stub.aborted == 1` |
| `dismissing mid-dial hangs up, from the new path` | re-point the existing F4 test (`:1376`) at `provisionTarget`; it must still pass |
| `switching destination mid-dial aborts, from the new path` | re-point the existing H4 test likewise |

**4.6 — Sabotage:**

| Mutation | Killed by |
| --- | --- |
| `provisionTarget` ignored (mixin reads own container) | "current session is untouched" |
| `finalizeProvisioned` called on the sheet's own container | same |
| grant-release guard removed from `openCreatedRepoInTab` | "no grant leaks" |
| `registerLocalOnly` calls `connectLocal` again | "saved local create opens in a new tab" (current tab would switch) |
| unsaved local routed to `openCreatedRepoInTab` | "unsaved … opens no tab" |
| `tabs.close` removed after a failed dial | "failed dial closes the tab" |
| `tabs.close` removed after a failed create | "failed create … closes the tab" |
| mid-dial abort guard removed | re-pointed H4 |
| mid-hang-up `mounted` guard removed | re-pointed F4 |

**Verify + commit Phases 3 and 4 together.** Full suite; every mutation from
3.7 and 4.6 killed; the switcher's tests unedited and green.

### Phase 5 — Clone follows

**5.1** `clone_sheet.dart:114` → `applicable: () => true`; `_recomputeTarget`,
`initState` default, `_canSubmit` cap gate and Review copy as Phase 3, with
"cloned" wording. The Phase 2 clone pins are inverted with the same comment
convention.

**5.2** `_submit()` routes as 4.3, with one difference: the job runs through
`targetContainer.read(cloneJobProvider.notifier).run(request)`.

**5.3** Progress. The sheet keeps `ref.watch(cloneJobProvider)` (`:480`) for
the current-tab case and adds, for a routed clone:

```dart
ProviderSubscription<CloneJobState>? _routedJob;
_routedJob = tab.container.listen(cloneJobProvider, (_, __) => setState(() {}));
// closed in dispose() and when the job ends
```

Cancel (`:443`, `:1005`) and reset (`:193`, `:445`) read the controller from
`_jobContainer ?? <own>`.

**5.4** Tests, `test/clone_sheet_test.dart`: the Phase 4 table clone-shaped,
plus `progress for a routed clone reflects the target container's job`
(drive the target container's `cloneJobProvider` and assert the sheet's bar
moves) and `cancel reaches the container running the job`.

**5.5** Diff the two sheets' destination/target/routing code; differences
must be intro strings and hint verbs only (MADR 0033).

**Verify + commit.**

### Phase 6 — Record

* `tool/mutations/0036-destination.json`: every mutation from 1.3, 3.7, 4.6
  and Phase 5, run once more from the committed catalogue.
* `docs/README.md`: 0036 row.
* This plan's execution record: per-phase what/why/verification output,
  counts, every survivor and every `DID NOT APPLY`.
* MADR `verified:` date.

**Commit.**

## Verification

At the end of every phase:

```sh
flutter analyze
dart format --output=none --set-exit-if-changed <each staged file>
flutter test
printf 'expect=%s testWidgets=%s\n' \
  "$(grep -rho 'expect(' test/ | wc -l | tr -d ' ')" \
  "$(grep -rho 'testWidgets(' test/ | wc -l | tr -d ' ')"
python3 tool/mutate.py tool/mutations/0036-destination.json   # from Phase 1 on
```

Standing rules: `dart format` in place, never chained with `&&` before
`git commit`, never globally; sabotage only in the harness's scratch worktree;
**read the whole failure list**; a `DID NOT APPLY` is a broken experiment and
fails the phase.

### Acceptance criteria

1. A connected sheet — local **and** SSH — shows the Destination step listing
   This Mac and every saved connection, defaulting to the current session.
2. **Every** successful create opens the new repository in its own tab; the
   tab the wizard was opened from is unchanged — same session, same repo,
   output log intact. Asserted, not inferred.
3. A host with no session anywhere is created on and opened, with no prior
   connection.
4. An unsaved local create opens in the current tab, and the Review step says
   so before submit.
5. At the tab cap the wizard refuses with the exact message and runs nothing.
6. A create that fails after its tab was opened leaves no extra tab and no
   session at `phase: connecting`.
7. The `sshProvision` create is covered end to end (Phase 1), committed
   **before** any `lib/` change.
8. Clone behaves identically for 1–6, with progress shown for a routed job.
9. MADR 0022 H4 and MADR 0034 F4 guards hold, re-pointed at the new path.
10. The switcher's local-open tests pass **unedited** after its block moves.
11. `flutter analyze` clean; full suite green at every phase; every mutation
    in the catalogue killed; no `DID NOT APPLY`.

## Execution record

### Preconditions and baselines — 2026-09-08, at `24d1e4f`

```
Flutter 3.47.2 • channel stable
flutter pub get --enforce-lockfile      Got dependencies!
git status --short                      (empty)
flutter test                            03:21 +3707 ~3: All tests passed!
expect=9316 testWidgets=1041
```

All twelve proofs re-run and holding; outputs recorded in the plan's proof
table as written (no line had moved).

### Phase 1 — 2026-09-08 — *complete*

**Tests only; `git diff --cached --stat -- lib/` empty at commit.**

* `test/helpers/create_repo_harness.dart`: `ProvisionStub` (records dials,
  finalizes, aborts; state transitions on a successful dial), `pumpLanding`,
  `destinationPopup`, `chooseDestination`, `parentField`.
* `test/create_repo_sheet_test.dart`: group *"landing: a create on a chosen
  saved host (MADR 0036 Phase 1)"*, three tests as planned.

**Two things the first run taught, both in the tests rather than the code:**

* *"Runs nothing" was trivially true as first written.* The failed-dial test
  originally stopped after the error appeared — but the wizard's steps stay
  navigable after a failed dial, so a user can press on to Create. The test
  now drives all the way there and asserts a second (failing) dial, an empty
  executor, nothing finalized, and the sheet still open. Without that, the
  mutation `return token != null → return true` would have survived.
* *`contains([...])` on a `List<List<String>>` compares by identity.* The
  argv assertion failed on a run whose output was exactly right. Rewritten
  as `exec.calls.last == [...]` (the connected test's form), plus an assertion
  on the existence probe's path — `p='/srv/git/new-proj'` — which is the real
  proof that the parent came from the field and not from This Mac.

**Sabotage — `tool/mutations/0036-destination.json`, scratch worktree:**

```
phase1: registration's sshProvision branch always fails  -> creates on the chosen host and finalizes…
phase1: a failed dial reports no error                   -> a failed dial keeps the sheet open…
phase1: a failed dial is treated as provisioned          -> a failed dial keeps the sheet open…
3 killed, 0 survived, 0 did not apply
```

A first harness pass, run while the matcher bug above was still in, reported
two KILLEDs that meant nothing — a test failing on unmutated code kills every
mutation. Discarded; the run above is against three passing tests.

**Verification:**

```
flutter analyze (both files)      No issues found!
dart format                       0 changed
flutter test (full suite)         03:25 +3710 ~3: All tests passed!
expect=9330 testWidgets=1044
```

> **Deviation 1 (2026-09-08) — Phase 2's local pins need a dependency.**
> `_pickedParent` is set only by the native folder panel
> (`workspace_pickers.dart:24-30`, `file_selector`'s `getDirectoryPath`), with
> no override hook, and **no existing test drives a local create through the
> sheet**. The standard fake — `FileSelectorPlatform.instance` — needs
> `file_selector_platform_interface`, present in the lockfile at **2.7.0** as
> *transitive*; `depend_on_referenced_packages` (`lints/core.yaml:19`, via
> `flutter_lints`) makes a `test/` import of a transitive package an analyze
> error. **Decision: option 1** — add it as a direct dev dependency pinned to
> the locked version (`flutter pub add --dev
> file_selector_platform_interface:2.7.0`). Rejected: a `@visibleForTesting`
> hook in `lib/` (a bespoke seam where a standard one exists, and a `lib/`
> edit in a tests-only phase); dropping the sheet-level pins (the local
> `_submit` branch, which Phase 4 changes, would ship unverified end to end).
> **Scope added to Phase 2:** `pubspec.yaml`, `pubspec.lock`.

### Phase 2 — 2026-09-08 — *complete*

**Tests only; `git diff --cached --stat -- lib/` empty at commit.** Plus the
two dev dependencies Deviation 1 approved, both pinned to their locked
versions so `--enforce-lockfile` stays satisfied — the lock diff is exactly
two lines, `transitive` → `direct dev`: `file_selector_platform_interface`
2.7.0 and `plugin_platform_interface` 2.1.8 (the second supplies
`MockPlatformInterfaceMixin`, without which a fake platform cannot be
installed; same class of change, recorded here rather than re-prompted).

**Doubles, in `test/helpers/create_repo_harness.dart`:** `RecordingTabs`
(records opens/closes, counts `connect`, mirrors the cap's silent no-op),
`installTabs`, `CountingScopedAccess`, `FakeFolderPicker` + `installFolderPicker`
(via `FileSelectorPlatform.instance`), `FakeLocalExecutor` with a request
router, `localCreateOk`, `chooseFolderButton`, `pumpConnectedLocal`.
`StubConnection` gained a recording `connectLocal` so a local create never
runs the real controller.

**Pins.** Create: *a connected SSH create runs on the current session and
switches the current tab*; *a connected local create opens in the current
tab*; *a connected sheet shows no Destination step*. Clone: the SSH and
no-Destination-step twins. All pass against unedited `lib/`. Phase 3 and 5
invert the SSH and Destination pins **on purpose** and must say so in the
test.

**Deliberately not written: the clone local pin.** A local clone runs its
job through a *streaming* local executor (`exec.handle.finish(0)` in the
clone tests), which `FakeLocalExecutor` does not model. Building a streaming
local double for a pin that Phase 5 would invert anyway is deferred to Phase
5, where clone's local routing is actually touched. Named here so it is not
mistaken for coverage.

**Three fixture facts, each learned by a failing run:**

* **On the local path the environment probe runs first.** `localEnvironmentProvider.ensure()`
  goes through the local executor *before* the create's existence probe, so
  a positional queue hands `absent` to the wrong command and the create stops
  before `git init`. `FakeLocalExecutor` got a request router (`respond`) —
  the same lesson `FakeCreateExecutor` learned in MADR 0032.
* **`SecurityScopedBookmark.create` never settles under `testWidgets`.** A
  platform channel with no handler does not throw here; it hangs (the reply
  needs `runAsync`) — the same mechanism that hung `SharedPreferences` in
  MADR 0032. The footer's `Creating…` spinner then animates forever and
  `pumpAndSettle` times out. `pumpConnectedLocal` answers the
  `magicgit/bookmarks` channel, as `add_existing_repo_sheet_test.dart:80`
  does for its own channel.
* **`exec.calls.last` is not the init on the local path** — the router's
  trailing calls follow it. Asserted as `containsAllInOrder` on joined argv,
  the form the file's identity test already uses; no weaker.

**Sabotage.** These are baselines, not new contracts: their "seen to fail"
is Phase 3 inverting them, which is the point of pinning them first.

**Verification:**

```
flutter analyze (3 files)         No issues found!
dart format                       0 changed
flutter test (full suite)         03:39 +3715 ~3: All tests passed!
expect=9316 -> 9340   testWidgets=1041 -> 1049
git diff --cached --stat -- lib/  (empty)
```

## Rollout and Rollback

**Rollout.** Six commits: Phase 1, Phase 2, **Phases 3+4 together**, Phase 5,
Phase 6. Phase 3 alone exposes a destination choice that still dials in the
current tab — the hazard the MADR disqualifies — so it is never committed
without Phase 4. Phases 1–2 are tests only and stand on their own.

**Rollback.** `git revert` per commit, newest first. The 3+4 commit reverts
as one. Phases 1–2 are safe to keep regardless.

## Open questions — resolved 2026-09-08

| # | Question | Resolution |
| --- | --- | --- |
| 1 | Mark the current session's row? | **No marker.** Under 3B every SSH create takes one path; the current session is the **default selection** only. |
| 2 | A destination open in another tab? | **Dissolved** — the new repo's path is new, so a fresh tab is always opened. What remains is the **tab cap** (decision 7A, Phase 3.4). |
| 3 | Blank-tab reuse? | **`openOrFocus`'s existing rule**: a blank active tab is reused (the landing page — today's result); a connected tab gets a new one. |

Three decisions the revision added, recorded in the MADR: **5B** (unsaved local
opens in the current tab), **6B** (dial at submit), **7A** (refuse at the cap).
