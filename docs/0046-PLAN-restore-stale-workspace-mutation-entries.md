---
status: "proposed"
date: 2026-09-10
associated-madr: "none"
---

# Restore the stale workspace mutation entries in the 0032 and 0036 catalogues

Associated MADR: none. This is maintenance of two existing sabotage catalogues. The contracts
it restores belong to
[0032-MADR-recent-and-searchable-forge-namespaces.md](0032-MADR-recent-and-searchable-forge-namespaces.md) and [0036-MADR-choosing-a-create-destination-while-connected.md](0036-MADR-choosing-a-create-destination-while-connected.md);
nothing here changes a decision. It was opened by
[0045-PLAN-one-owner-per-watcher-concern.md](0045-PLAN-one-owner-per-watcher-concern.md),
deviation (c).

## Goal

Every entry in `tool/mutations/0032-namespaces.json` and `tool/mutations/0036-destination.json`
applies, compiles, and is killed by a named test again. Fifteen entries currently apply to
nothing, so those catalogues no longer exercise the contracts they were written for.

## Scope

### In

* `tool/mutations/0032-namespaces.json`: re-anchor 1 entry, retire 1.
* `tool/mutations/0036-destination.json`: re-anchor 13 entries.
* Record annotations in the 0032 and 0036 plans, and a `docs/README.md` row for this plan.

### Out, and why

* **No `lib/` or `test/` change.** Every contract still holds and every named test still exists
  (grounding below). If a re-anchored entry SURVIVES, that is a question for a deviation, not a
  test to write inside this plan.
* **Uncovered siblings** seen during research — the `_browseRemoteFolder` guard in
  `create_repo_sheet.dart`, the clone sheet's `_browseRemote` and target switch — have no entries
  today. Adding coverage is new sabotage work, not restoration.
* **Merging the identical anchors of entries 7 and 14.** They name different sheets' tests;
  merging would change two historical labels into one.

## Grounding

* `tool/mutate.py --check` over every catalogue (0045 plan, deviation (c)):
  `215 entries in 10 catalogue(s): 199 sound, 15 did not apply, 1 do not compile`. The 15
  `DID NOT APPLY [0 matches]` are exactly the entries below plus entry 1.
* Each anchor matched exactly once at its catalogue's last commit (`56c767d` for 0032,
  `5af35c7` for 0036). Stepping every later commit that touched each target file, the first
  where it stopped matching was, all on 2026-09-08: `dc78436` (entries 1, 2), `fdd0d7b`
  (3, 8, 10, 11), `6117172` (4, 5, 6, 13), `2e1f841` (7, 12, 14, 15), `c818bb0` (9).
* A read-only research pass located each contract in the current code and proposed a
  replacement anchor. Every proposal below was then checked by script against the working tree
  at `4e4a854`: the old anchor matches 0 times, the new anchor exactly once, and the named
  killing test exists by title in its file (`15 of 15 verified`).
* Every proposal was compiled with `tool/mutate.py --check`. The first pass found two that
  did not compile — entries 3 and 8 used `|| true`, and a constant condition makes the code
  after the `if` unreachable, which removes null promotion
  (`ARGUMENT_TYPE_NOT_ASSIGNABLE: The argument type 'SavedConnection?' can't be assigned…`,
  `…'RepoTab?'…`). Both were rewritten with an opaque condition
  (`identical(x, x)`), and the second pass reported
  `14 entries in 1 catalogue(s): 14 sound, 0 did not apply, 0 do not compile`.
* **Nothing has been run against a test yet.** Every "killed by" below is read from the test's
  assertions, not observed.

## Implementation Steps

### Phase 1 — the catalogue edits

1. **Retire entry 1**, `0032` `sheet: active connection not resolved for history`: delete it
   from `tool/mutations/0032-namespaces.json`. Its helper `_effectiveConnectionId` was deleted in
   `dc78436` after `docs/0038-PLAN-workspace-entry-points-debugging-pass.md` showed it always
   equalled `_destConnectionId`, and the faithful re-anchor — `_destConnectionId` → `null` at the
   create sheet's history write — is already the live `0038` entry
   `residual: the namespace of a saved-host create goes to the This-Mac store`, whose anchor
   matches once today.
2. **Re-anchor entries 2–15**: in each catalogue, replace the entry with the same label by the
   JSON below — `file`, `find` and `replace` change; `label` and `tests` are kept. Each
   catalogue keeps its committed JSON style (both are two-space, ASCII-escaped), and the content
   of every other entry is asserted unchanged by the editing script.

#### 2. `0032` — clone: active connection not resolved for history

* **Contract:** a clone to a saved host records its namespace against that connection, not the This-Mac store.
* **Broken by:** `dc78436`.
* **Killed by (expected):** `test/clone_sheet_test.dart` — `a nested GitLab clone records its namespace`.

```json
{
  "label": "clone: active connection not resolved for history",
  "file": "lib/features/workspace/clone_sheet.dart",
  "find": "          connection: await connectionById(_destConnectionId),",
  "replace": "          connection: await connectionById(null),",
  "tests": [
    "test/clone_sheet_test.dart"
  ]
}
```

#### 3. `0036` — phase1: registration's sshProvision branch always fails

* **Contract:** a provisioned SSH result with a connection and token is finalized.
* **Broken by:** `fdd0d7b`.
* **Killed by (expected):** `test/create_repo_sheet_test.dart` — `creates on the chosen host and finalizes…`.

```json
{
  "label": "phase1: registration's sshProvision branch always fails",
  "file": "lib/features/workspace/workspace_flow.dart",
  "find": "    if (conn == null || token == null) return false;",
  "replace": "    if (conn == null || token == null) return false;\n    if (identical(conn, conn)) return false;",
  "tests": [
    "test/create_repo_sheet_test.dart"
  ]
}
```

#### 4. `0036` — phase3: the current session resolves to sshActive again

* **Contract:** choosing the saved session already connected still provisions in its own tab (MADR 0036, 3B).
* **Broken by:** `6117172`.
* **Killed by (expected):** `test/create_repo_sheet_test.dart` — `a connected SSH create provisions in its own tab…`.

```json
{
  "label": "phase3: the current session resolves to sshActive again",
  "file": "lib/features/workspace/create_repo_sheet.dart",
  "find": "      SavedConnectionDestination() => WorkspaceTarget.sshProvision,",
  "replace": "      SavedConnectionDestination(:final id) => id == conn.connectionId\n          ? WorkspaceTarget.sshActive\n          : WorkspaceTarget.sshProvision,",
  "tests": [
    "test/create_repo_sheet_test.dart"
  ]
}
```

#### 5. `0036` — phase3: the wizard does not open on the current session

* **Contract:** the create wizard opens on the current SSH session (MADR 0036, 2A).
* **Broken by:** `6117172`.
* **Killed by (expected):** `test/create_repo_sheet_test.dart` — `it opens on the current SSH session`.

```json
{
  "label": "phase3: the wizard does not open on the current session",
  "file": "lib/features/workspace/create_repo_sheet.dart",
  "find": "      _dest = switch (conn) {",
  "replace": "      _dest = const LocalMacDestination();\n      if (false) _dest = switch (conn) {",
  "tests": [
    "test/create_repo_sheet_test.dart"
  ]
}
```

#### 6. `0036` — phase3: an unsaved local create is gated by the cap too

* **Contract:** an unsaved local create opens no tab, so the tab cap does not refuse it (MADR 0036, 7A/5B).
* **Broken by:** `6117172`.
* **Killed by (expected):** `test/create_repo_sheet_test.dart` — `an unsaved local create is not gated by the cap`.

```json
{
  "label": "phase3: an unsaved local create is gated by the cap too",
  "file": "lib/features/workspace/create_repo_sheet.dart",
  "find": "      _target != WorkspaceTarget.sshActive && (!_isLocalTarget || _saveLocal);",
  "replace": "      _target != WorkspaceTarget.sshActive;",
  "tests": [
    "test/create_repo_sheet_test.dart"
  ]
}
```

#### 7. `0036` — phase4: the mixin dials in the sheet's own container

* **Contract:** the dial runs in the newly claimed tab, never the user's current one (MADR 0036, 1C).
* **Broken by:** `2e1f841`.
* **Killed by (expected):** `test/create_repo_sheet_test.dart` — `a connected SSH create provisions in its own tab…`.

```json
{
  "label": "phase4: the mixin dials in the sheet's own container",
  "file": "lib/features/workspace/workspace_provisioning.dart",
  "find": "  ProviderContainer get _dialContainer => flow.container;",
  "replace": "  ProviderContainer get _dialContainer => flow.origin;",
  "tests": [
    "test/create_repo_sheet_test.dart"
  ]
}
```

#### 8. `0036` — phase4: finalize runs in the sheet's own container

* **Contract:** a provisioned result is finalized in the tab that dialled it.
* **Broken by:** `fdd0d7b`.
* **Killed by (expected):** `test/create_repo_sheet_test.dart` — `a connected SSH create provisions in its own tab…`.

```json
{
  "label": "phase4: finalize runs in the sheet's own container",
  "file": "lib/features/workspace/workspace_flow.dart",
  "find": "    if (claimed == null) {\n      // No tab host: the sheet's own container dialled (landing behaviour).\n      return container",
  "replace": "    if (claimed == null || identical(claimed, claimed)) {\n      // No tab host: the sheet's own container dialled (landing behaviour).\n      return origin",
  "tests": [
    "test/create_repo_sheet_test.dart"
  ]
}
```

#### 9. `0036` — phase4: grant-release guard removed from the local open

* **Contract:** when `openOrFocus` runs no connect (cap or dedupe), the acquired grants are released.
* **Broken by:** `c818bb0`.
* **Killed by (expected):** `test/create_repo_sheet_test.dart` — `no grant leaks when openOrFocus declines`.

```json
{
  "label": "phase4: grant-release guard removed from the local open",
  "file": "lib/features/workspace/workspace_open_in_tab.dart",
  "find": "  if (connected) {\n    await opening;\n    return (tab: tab, outcome: LocalOpenOutcome.opened);\n  }",
  "replace": "  await opening;\n  return (tab: tab, outcome: LocalOpenOutcome.opened);",
  "tests": [
    "test/create_repo_sheet_test.dart"
  ]
}
```

#### 10. `0036` — phase4: a saved local create opens in place anyway

* **Contract:** a saved local create bookmarks and opens in its own tab (MADR 0036, 3B).
* **Broken by:** `fdd0d7b`.
* **Killed by (expected):** `test/create_repo_sheet_test.dart` — `a saved local create opens in its own tab`.

```json
{
  "label": "phase4: a saved local create opens in place anyway",
  "file": "lib/features/workspace/workspace_flow.dart",
  "find": "      if (!request.saveLocal) {\n        return registerAndActivateLocal(",
  "replace": "      if (!request.saveLocal || true) {\n        return registerAndActivateLocal(",
  "tests": [
    "test/create_repo_sheet_test.dart"
  ]
}
```

#### 11. `0036` — phase4: an unsaved local create is routed to a tab

* **Contract:** an unsaved local create opens in the current tab (MADR 0036, 5B).
* **Broken by:** `fdd0d7b`.
* **Killed by (expected):** `test/create_repo_sheet_test.dart` — `an unsaved local create opens in the current tab…`.

```json
{
  "label": "phase4: an unsaved local create is routed to a tab",
  "file": "lib/features/workspace/workspace_flow.dart",
  "find": "      if (!request.saveLocal) {\n        return registerAndActivateLocal(",
  "replace": "      if (false) {\n        return registerAndActivateLocal(",
  "tests": [
    "test/create_repo_sheet_test.dart"
  ]
}
```

#### 12. `0036` — phase4: Browse… dials in the current tab

* **Contract:** the create sheet's host Browse… claims a new tab before dialling (MADR 0036, 1C/6B).
* **Broken by:** `2e1f841`.
* **Killed by (expected):** `test/create_repo_sheet_test.dart` — `the destination control is dead while Browse… is dialling`.

```json
{
  "label": "phase4: Browse… dials in the current tab",
  "file": "lib/features/workspace/create_repo_sheet.dart",
  "find": "  Future<void> _browseRemote() async {\n    if (!await _flow.ensureTab()) {",
  "replace": "  Future<void> _browseRemote() async {\n    if (false) {",
  "tests": [
    "test/create_repo_sheet_test.dart"
  ]
}
```

#### 13. `0036` — phase4: mid-hang-up mounted guard removed (0034 F4)

* **Contract:** after awaiting the hang-up, `_onDestChanged` checks `mounted` before `setState` (MADR 0034 F4).
* **Broken by:** `6117172`.
* **Killed by (expected):** `test/create_repo_sheet_test.dart` — `switching destination mid-hang-up does not setState on a disposed sheet`.

```json
{
  "label": "phase4: mid-hang-up mounted guard removed (0034 F4)",
  "file": "lib/features/workspace/create_repo_sheet.dart",
  "find": "    if (!mounted) return;\n    setState(() {\n      _dest = dest;",
  "replace": "    setState(() {\n      _dest = dest;",
  "tests": [
    "test/create_repo_sheet_test.dart"
  ]
}
```

#### 14. `0036` — phase7: add-existing dials in the current tab (the hand-rolled copy's behaviour)

* **Contract:** the add-existing sheet's dial runs in the newly claimed tab (MADR 0036, 1C).
* **Broken by:** `2e1f841`.
* **Killed by (expected):** `test/add_existing_repo_sheet_test.dart` — `Browse… dials in a new tab, leaving this one alone`.

```json
{
  "label": "phase7: add-existing dials in the current tab (the hand-rolled copy's behaviour)",
  "file": "lib/features/workspace/workspace_provisioning.dart",
  "find": "  ProviderContainer get _dialContainer => flow.container;",
  "replace": "  ProviderContainer get _dialContainer => flow.origin;",
  "tests": [
    "test/add_existing_repo_sheet_test.dart"
  ]
}
```

#### 15. `0036` — phase7: Browse… dials without opening a tab

* **Contract:** the add-existing sheet's saved-host Browse… claims a tab (or shows the cap message) before dialling.
* **Broken by:** `2e1f841`.
* **Killed by (expected):** `test/add_existing_repo_sheet_test.dart` — `Browse… dials in a new tab, leaving this one alone`.

```json
{
  "label": "phase7: Browse… dials without opening a tab",
  "file": "lib/features/connection/local_repo_form.dart",
  "find": "        if (!await _flow.ensureTab()) {\n          setState(() => _saveWarning = AddExistingRepoSheet.capMessage);\n          return;\n        }\n        if (!await ensureProvisioned() || !mounted) return;\n      }\n      final picked = await showMacosSheet<String>(",
  "replace": "        if (!await ensureProvisioned() || !mounted) return;\n      }\n      final picked = await showMacosSheet<String>(",
  "tests": [
    "test/add_existing_repo_sheet_test.dart"
  ]
}
```

### Phase 2 — verification

Per the 0045 plan's rule 4, one at a time, with no other test run in progress:

```sh
tool/mutate.py --check tool/mutations/0032-namespaces.json tool/mutations/0036-destination.json
tool/mutate.py tool/mutations/0032-namespaces.json
tool/mutate.py tool/mutations/0036-destination.json
```

* `--check` must report every entry sound.
* Each run must pass its baseline and compile canary and report
  `0 survived, 0 did not apply, 0 did not compile, 0 observed by no test`.
* Each re-anchored entry must be KILLED by the test named above. A different killer is
  recorded, not silently accepted.
* A **SURVIVED** is reproduced by hand in a scratch worktree before it is believed, and is a
  deviation: the research inferred kills it could not run (see Risks).

### Phase 3 — records

* Annotate the catalogue results in `docs/0032-PLAN-recent-and-searchable-forge-namespaces.md` and
  `docs/0036-PLAN-choosing-a-create-destination-while-connected.md` — annotations, not rewrites —
  naming the retired entry and the 14 re-anchors.
* Add this plan's row to `docs/README.md`.
* Set this plan's `status` to `complete` with its execution record.

## Verification

The three commands in phase 2, with their summary lines and exit codes recorded verbatim in the
execution record, plus `flutter analyze` (no issues) and the identifier scan
`flutter test test/no_real_identifiers_scan_test.dart` before the docs commit.

## Acceptance Criteria

* `tool/mutate.py --check` on both catalogues: every entry sound.
* Both runs: `0 survived, 0 did not apply, 0 did not compile, 0 observed by no test`.
* `tool/mutate.py --check` over every catalogue reports no `DID NOT APPLY` from 0032 or 0036.
* Entry 1 is absent from `0032-namespaces.json`; its 0038 twin still applies.
* No file under `lib/` or `test/` is changed.

## Rollout and Rollback

Tooling data only; nothing ships. Code (the two catalogues) and docs are separate commits, made
with `git commit --no-edit`, and nothing is pushed unless the maintainer asks. Rollback is
reverting the catalogue commit, which returns the 15 entries to DID NOT APPLY.

## Risks

* **Inferred kills.** Entry 12's kill assumes the create-sheet harness's stub dial completes
  immediately, which the research did not read in `test/helpers/create_repo_harness.dart`.
  Entry 2's saved-session seeding is inferred from the create sheet's identical switch.
* **Overlapping anchors.** Entry 6 overlaps a `0038` `_opensNewTab` entry, and entry 11 overlaps
  a `0038` `registerAndActivateLocal(` entry. The harness applies one mutation at a time to
  unmutated source, so both still apply; a later refactor of either line breaks both catalogues
  at once.
* **The "sheet's own container" trap.** `WorkspaceFlow.container` resolves to the claimed tab
  whenever one exists (`container => _tab?.container ?? origin`), so a mutation that tries to
  force the sheet's own container through it changes nothing. Entries 7, 8 and 14 name `origin`
  for that reason; entry 8's first form would have been a silent survivor.
* **Run time.** The 0036 catalogue runs `create_repo_sheet_test.dart` once per entry, 30 times.
