---
status: "in-progress"
date: 2026-09-24
verified: 2026-09-24
associated-madr: "0036-MADR-choosing-a-create-destination-while-connected.md"
---
# Let a clone to a saved host browse that host's GitHub and GitLab repositories

Associated MADR: [0036-MADR-choosing-a-create-destination-while-connected.md](0036-MADR-choosing-a-create-destination-while-connected.md),
Amendment 0036.1. Reported as [issue #5](https://github.com/maccavelli/magic-git/issues/5).

## Goal

A clone to a saved SSH host from the GitHub or GitLab tab lists the repositories that the host's
own `gh`/`glab` can see. A repository can then be picked and the clone completed, from either the
landing page or a connected tab. Every forge read the clone makes goes to the target host.

## Scope

In scope:

* `lib/features/workspace/clone_sheet.dart`:
  * dial on the Source step for a saved-connection target;
  * a Connect action in the list placeholder, to retry a failed dial;
  * the browse list, the host prefill and the submit's host, all read from `_flow.container`.
* `test/clone_sheet_test.dart`:
  * five tests (T1–T5 below);
  * `_FakeExecutor` records each stream call's environment;
  * `_pumpConnected` installs the test's tabs before the pump;
  * two existing tests are re-pointed to the new first commitment (Phase 2, step 6).
* `test/helpers/create_repo_harness.dart`: `RecordingTabs` takes `tabOverrides`, so a test can
  give spawned tabs their own providers.
* `scripts/tools/mutations/0036-destination.json`: six entries labelled `0036.1:`.
* Records:
  * this plan;
  * Amendment 0036.1 (already written);
  * the 0036 row in `docs/README.md`.

Out of scope:

* The create sheet. Its forge data is optional, and no step of it is blocked by a missing dial
  (Amendment 0036.1, Consequences).
* Add Existing Repository, which has no forge list.
* The uncommitted 0070 D8/D9 work in the tree. It is not staged with this plan's commits, and the
  commit's own tree is tested separately (Phase 3).

## Facts this plan is built on

Established on 2026-09-24 in scratch clones, with the working tree untouched (Amendment 0036.1,
Evidence):

1. At `b7857ea`, a landing clone to saved connection "Prod" on the GitHub tab never shows the
   stubbed repository: `Found 0 widgets with text "me/app"`.
2. At `ee0c4a6`, the parent of `bc0b92c`, the same test passes. The regression is `bc0b92c`'s
   removal of the dial from `_onDestChanged`.
3. At `b7857ea`, a target dialled through Browse… in a spawned tab then lists from the *origin*
   container: `Found 1 widget with text "origin/wrong"`. The dial itself was confirmed in the
   spawned tab (`tabs.spawned.single.dialed.single.id == 'c1'` passed first).
4. No existing clone test drives a forge list against a saved connection. Every such test taps
   URL first (`test/clone_sheet_test.dart:674-841`).

## Implementation Steps

### Phase 1 — Tests first, seen red

1. Harness (`test/helpers/create_repo_harness.dart`):
   * add `RecordingTabs({…, this.tabOverrides = const []})`;
   * add a static `_tabOverrides`, set in `installTabs` and appended in `_factory` before
     `...overrides`.
2. In `test/clone_sheet_test.dart`, make `_FakeExecutor.executeStream` record `extraEnv` in a
   `streamEnvs` list.
3. Add these tests. Each must fail on the Phase 1 tree, before any `lib/` change, and the
   failure must be the assertion named, not a build error:
   * **T1 — a saved target dials on the Source step and lists its repositories.**
     * Setup: landing, "Prod" chosen, then Continue.
     * `stub.dialed == ['c1']`.
     * `me/app` is shown; tapping it enables Continue.
   * **T2 — the list, the host and the clone all use the dialled tab.**
     * Setup, in a connected sheet with `RecordingTabs`:
       * spawned tabs list `me/app` and resolve the GitHub host to `ghe.example.com`;
       * the origin lists `origin/wrong` and resolves to `wrong.example.com`.
     * On Source, `me/app` is shown and `origin/wrong` is not.
     * The host field reads `ghe.example.com`.
     * After picking, Location, Review and Clone, the clone's stream environment carries
       `ghe.example.com`.
   * **T3 — switching to GitLab dials.**
     * Setup: reach Source on the URL tab for "Prod" with no dial (This Mac, Continue, URL,
       Back, choose "Prod", Continue).
     * `stub.dialed` is empty.
     * Tapping GitLab makes it `['c1']`.
   * **T4 — a failed dial offers Connect again.**
     * The first dial resolves `null`, and the error is shown.
     * With the dial then succeeding, tapping Connect lists `me/app`.
   * **T5 — closing after a Source-step dial hangs it up.**
     * Close after T1's dial.
     * `stub.aborted == [1]`.

Verification:

```sh
flutter test test/clone_sheet_test.dart > "$LOG" 2>&1; echo "exit=$?"
```

* Expected: exit 1, with T1–T5 each failing on its own assertion.
* Every existing test still passes.

### Phase 2 — The fix (`clone_sheet.dart`)

1. `ProviderContainer get _browseContainer => _flow.container;`
2. `Future<void> _connectForBrowse()`: for `sshProvision` with no token and no dial in flight, run
   the same steps as `_browseRemote`: `_flow.ensureTab()` (the cap refuses with `capMessage`),
   then `ensureProvisioned()`. It calls:
   * `_goNext` when the step it moves to is `source` and `_forge != null`;
   * `_tabButton`, when switching to GitHub or GitLab;
   * a **Connect** button in the not-ready placeholder, which also shows "Connecting…" while
     `provisioning`.
3. `_forgeBrowse` renders under `UncontrolledProviderScope(container: _browseContainer)` through
   a `Consumer`, whose `ref` watches `forgeAuthHostProvider` and `forgeRepoListProvider` and
   invalidates for Reload. (`TabsHost` already swaps a scope's container in place, at
   `tabs_host.dart:543-553`.)
4. The host prefill `listen` moves from the sheet's `build` into a zero-size `Consumer` under the
   same scope. It is mounted only while `_forgeBrowseReady`, so it never probes a host that has
   not been dialled.
5. `_submit` reads `forgeAuthHostProvider` from `_browseContainer`.
6. Existing tests that the new dial point changes, updated without weakening any assertion:
   * Tests that reach Source for a saved target now dial there, because GitHub is the default
     tab. `_pumpConnected` takes the test's `RecordingTabs` and installs it **before** the pump,
     as production always has a `TabsController`. Otherwise the Source-step dial would land in
     the origin container, which no production path does.
   * The 0022 H4 test (`the destination cannot be switched while a host is dialing`) moves its
     first commitment from Browse… to entering Source on the GitHub tab. Its gated dial, its
     inert-control assertion and its recovery assertion are unchanged.
   * The MADR 0034 F4 test's comment and reason, which name Browse… as the adopting step, are
     corrected to entering Source.

Verification:

* `flutter analyze` clean.
* `flutter test test/clone_sheet_test.dart`: exit 0.

### Phase 3 — Proof, suite, records, commit

1. Add six catalogue entries (`0036.1: …`) to `scripts/tools/mutations/0036-destination.json`.
   Each names the tests that must kill it:
   * entering Source does not dial → T1, T2, T5;
   * the tab switch does not dial → T3;
   * Connect does nothing → T4;
   * the list reads the sheet's own container → T2;
   * the prefill listens in the sheet's own container → T2;
   * the submit reads the host from the sheet's `ref` → T2.
2. Run:
   * `python3 scripts/tools/mutate.py scripts/tools/mutations/0036-destination.json --only 0036.1`,
     which must report 6 killed, 0 survived, and no DID NOT APPLY / DOES NOT COMPILE /
     OBSERVED BY NO TEST;
   * `--check` on the same catalogue.
3. Run `flutter analyze`, the full `flutter test`, and `dart run scripts/tools/records.dart check`.
4. **The commit's own tree:**
   * stage only this plan's files;
   * create a detached worktree at `HEAD` in the scratchpad and copy the staged files in;
   * run `flutter analyze` and the full suite there, since the working tree also holds unrelated
     uncommitted work;
   * commit only if both pass, gated on exit status, with `git commit --no-edit`.

### Phase 4 — Device check (read-only on the host)

In the installed build, open Workspaces → Clone repository. Choose a saved SSH host, then Continue.

* **GitHub:** the host's repositories are listed.
* **GitLab:** the host's repositories are listed.
* **Close:** the claimed tab goes away, and no session is left at "Connecting…".

No clone is run. A full clone to a host is the maintainer's check.

## Verification

Acceptance criteria:

* T1–T5 fail before Phase 2 and pass after.
* All six `0036.1` mutations are killed by the named tests.
* `flutter analyze` is clean, and the full suite passes in the working tree and in the commit's
  own tree.
* The records check is clean.
* Phase 4 is observed on the device.
* Issue #5 is closed by the maintainer once satisfied.

## Rollout and Rollback

This is a single commit touching one sheet and its tests. To roll back, revert the commit: the
clone goes back to URL-only for saved hosts, which is the current behaviour.

## Execution record

### Phase 1 (2026-09-24), tests first

* The harness change, `streamEnvs`, and T1–T5 landed with no `clone_sheet.dart` change.
* `flutter test test/clone_sheet_test.dart`: exit 1 — the 15 existing tests passed and T1–T5
  failed. Each failure was read, not just counted:
  * T1, T3, T4 and T5 failed at their dial assertion: `Expected: ['c1']  Actual: []`.
  * T2 first failed through a `StateError` from `.single`. An explicit
    `expect(tabs.spawned, hasLength(1))` was added so the failure is the assertion itself:
    `Expected: an object with length of <1>  Actual: []`.
* T4's Connect and T5's hang-up both sit behind the dial precondition, so on this tree they
  cannot fail for their own reason. Phase 3's mutations prove those parts separately.

### Phase 2 (2026-09-24), the fix

* Steps 1–5 as planned. Afterwards T1, T3, T4 and T5 passed, and the three existing tests
  predicted in step 6 failed:
  * the routed clone test, with no spawned tab;
  * the tab-cap test: `Expected: empty  Actual: ['c1']`;
  * the 0022 H4 test: `pumpAndSettle timed out` behind its gated dial.
* T2 passed every assertion, including `GH_HOST == ghe.example.com`, then timed out after the
  clone finished. Diagnosed before any change:
  * the job was `succeeded`, but nothing was finalized;
  * the finished forge clone records its namespace in the dialled tab
    (`_flow.container.read(namespaceHistoryProvider)`), and that test tab had no
    `connectionStoreProvider` stub;
  * the origin has had `_FakeStore` all along, and the URL tests never record, because a
    non-forge URL returns early.

  This was a harness gap, not a product defect. Stubbing the store in T2's `tabOverrides` let
  the clone finalize into the dialled tab (`/srv/app`, token 7), and T2 now asserts that, that
  the origin did not switch, and that the sheet popped.
* Step 6 as planned: `_pumpConnected(exec:)` with tabs installed before the pump; the 0022 H4
  test's commitment moved to entering Source; the F4 test's comment and reason corrected. No
  assertion was removed or loosened.
* `flutter test test/clone_sheet_test.dart`: 23 passed. `flutter analyze`: clean.

### Phase 3 (2026-09-24), proof

* `mutate.py --check scripts/tools/mutations/0036-destination.json`: 35 entries, 35 sound, 0 did
  not apply, 0 do not compile. The catalogue was rewritten with the file's own `\u` escaping,
  so its diff is the six additions only.
* `mutate.py … --only 0036.1`: the baseline was green, the compile canary was recognised, and
  the result was 6 killed, 0 survived, 0 did not apply, 0 did not compile, 0 observed by no test:

  | Mutation | Killed by |
  |---|---|
  | entering Source does not dial | T1, T2, T4, T5 |
  | the tab switch does not dial | T3 |
  | Connect does nothing | T4 |
  | the list reads the sheet's own container | T2 |
  | the prefill listens in the sheet's own container | T2 |
  | the submit reads the host through the sheet's `ref` | T2 |

* Working tree: `flutter analyze` clean; `flutter test` `+4453 ~3: All tests passed!`;
  `records.dart check` 0 findings.
