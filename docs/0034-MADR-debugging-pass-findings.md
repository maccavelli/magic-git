---
status: "proposed"
date: 2026-09-07
decision-makers: [Maintainer]
consulted: []
informed: [Magic Git contributors]
verified: 2026-09-07
---

# A debugging pass finds nine defects, and one pattern that makes failures invisible

## Context and Problem Statement

A sweep across `lib/` (277 files, 103,530 lines) for bugs, gaps and incomplete
wiring. The codebase resists the usual cheap signals: `flutter analyze` is
clean, the full suite is green at 3,602 tests, and there is **one** `TODO`-class
marker in 103K lines — and it is a false positive (`mktemp` template
`MAGICGIT_MSG_PREVIEW.XXXXXX`, `git_service.dart:3346`). Anything found had to
come from targeted hunting.

Nine findings follow, ordered by severity. Each names the file and line, and
says whether it was **confirmed by execution**, **traced by reading**, or
**pattern-matched**. Several scans produced candidates that turned out to be
false positives; those are reported too, because "this class is clean" is a
result and the next person should not have to re-derive it.

**One disclosure up front:** F4 is a latent defect this session's own work made
more reachable. See its entry.

## Findings

### F1 — A failed provider is invisible: no retry, no log, no UI *(highest)*

Three individually-defensible mechanisms compose into a blind spot.

1. **Retry is off by design.** Every async provider declares
   `retry: noProviderRetry`, and both scope constructions pass it —
   `main.dart:107` and `tabs_controller.dart:95`. A failed provider emits
   `AsyncError` immediately and stays there. This is correct and enforced by
   `provider_retry_policy_test.dart`.
2. **Nothing observes the failure.** `ProviderObserver` is used **exactly
   once** in the app: `secondary_window_main.dart:159` passes
   `_ProviderFailureLogObserver`, which logs `providerDidFail` to the native
   debug log. **The main window passes no observers** (`main.dart:107` is a
   bare `const ProviderScope(retry: noProviderRetry, …)`), and neither does any
   tab container (`tabs_controller.dart:95` —
   `ProviderContainer(retry: noProviderRetry, overrides: overrides)`).
3. **The UI collapses error into empty.** `grep` finds **49** sites of
   `.value ?? const []` / `.value ?? const <…>` in `lib/features/`, including
   the connections panel (`connection_switcher.dart:41,42,197,198`), the clone
   and create sheets, and the recovery sheet.

So a store read that throws renders as "you have no saved connections",
indistinguishable from actually having none, with no retry, no log line, and no
error surface anywhere. **The pop-out window — the least-used surface — is the
only place a provider failure leaves a trace.**

Confidence: **confirmed by reading all three sites**; not reproduced against a
forced failure. Note that the individual `?? const []` choice is often right
(the wizard must not block on a store), so the fix is the missing observer, not
49 call sites.

### F2 — `branches_view.dart:_batchHide` uses `ref` and `setState` after an await, unguarded

`_batchHide` (`branches_view.dart:710`):

```
756   await _updateWorkspacePrefs((prefs) { … });   // three awaits inside
760   ref.invalidate(hiddenBranchesProvider(repoPath));
774   setState(() { … });
778   if (skipped.isNotEmpty && mounted) {           // <- guard, four lines too late
```

`_updateWorkspacePrefs` (`:986`) awaits three things: the
`repositoryUiIdentityProvider` future, `loadLegacyBranchCollapsedSections()`,
and `updateBranchWorkspacePrefs(…)` — real disk I/O, not a microtask. If the
panel is disposed in that window (tab closed, repo switched), `ref.invalidate`
throws *"Cannot use ref after the widget was disposed"* and `setState` throws
after dispose.

The tell is line 778: the author checked `mounted` for the *next* statement.
The guard is on the wrong side of the work.

Confidence: **traced by reading**; not reproduced.

### F3 — `branches_view.dart:_bulkDeleteSelected` guards before the await, not after

`_bulkDeleteSelected` (`branches_view.dart:799`):

```
924   if (!mounted) return;                          // <- guard BEFORE
925   final results = await showBranchBulkDeleteSheet(…);   // a modal: unbounded
934     _refresh();
935     setState(() { … });                          // <- no re-check
```

The await is a modal sheet, so the window is "as long as the user takes". The
`mounted` check at 924 says nothing about the state at 934.

Confidence: **traced by reading**; not reproduced.

### F4 — `_onDestChanged` in both workspace sheets — *and this session widened it*

`create_repo_sheet.dart:430` and `clone_sheet.dart:262` (both
`_onDestChanged`), byte-identical:

```dart
await resetProvisioning();
setState(() { … });                 // <- unguarded
if (_target == WorkspaceTarget.sshProvision) {
  await ensureProvisioned();
}
```

`resetProvisioning` (`workspace_provisioning.dart:98`) returns immediately when
`provisionToken == null`, and otherwise awaits `abortProvisioning(token)` — a
network hangup. So the window opens only after a dial has already succeeded:
dial host A, switch the destination to host B, dismiss the sheet while the
hangup is in flight.

**Disclosure.** MADR 0033 Phase 0b (commit `71d386e`, this session) added the
eager `ensureProvisioned()` to the create sheet's `_onDestChanged`. Before it,
the create sheet never dialed from the destination control, so `provisionToken`
was usually null there and `resetProvisioning` returned synchronously — the
window barely existed. **That change made this defect materially more reachable
in the create sheet.** It was not introduced by that change (the clone sheet
has always had both), but the honest statement is that this session widened it.

Confidence: **traced by reading**; not reproduced.

### F5 — `WorkspaceCiState` and `AppTheme.ciColor` are orphaned

`app_theme.dart:18` declares `enum WorkspaceCiState`, and `app_theme.dart:166`
declares `static Color ciColor(WorkspaceCiState)`. A repo-wide search for
`WorkspaceCiState` returns **only those two declarations and the switch arms
inside `ciColor`** — nothing constructs the enum, nothing calls the function,
in `lib/` or `test/`. A closed loop of dead code.

The app does colour CI status, elsewhere and correctly:
`features/gitlab/status_color.dart:9` (`ciStatusColor(CiStatus)`) and
`features/github/status_color.dart:10` (`ghRunStateColor(GhRunState)`).

**Explicitly not a duplication finding.** Those two look like copies and are
not: they switch over genuinely different enums with different state sets
(GitLab has `waitingForResource`/`preparing`/`scheduled`/`manual`; GitHub has
`actionRequired`/`neutral`), and both are deliberately exhaustive with no
`default` so a new state is a compile error rather than a silent mis-colour.
That is good design, not drift. Only the `core/theme` pair is dead.

Confidence: **confirmed by exhaustive search**.

### F6 — The legacy watcher filenames are defined twice, and the named definition is dead

`remote_watch_service.dart:182-184` declares `legacyWatchPidFile` and
`legacyWatchHeartbeatFile`, documented as "The pre-0027 single-file scheme …
Phase 4 reclaims what it left". **Neither is called anywhere in `lib/` or
`test/`.**

The reclamation does happen — `bounded_watch.dart:303,313` builds the same two
paths from **hardcoded literals** (`'$d/mg-watch.pid'`, `'$d/mg-watch.hb'`)
rather than calling the helpers named for them.

So this is not missing functionality; it is the same filename knowledge in two
places, where the one carrying the documentation is the one nothing uses.
Exactly the class MADR 0033 Phase 2 addressed for path helpers.

Confidence: **confirmed by exhaustive search**.

### F7 — `gh api user/orgs` truncates silently at 100

`gh_service.dart:390` requests `user/orgs` with `per_page=100` and **no page
walk**. An account in more than 100 organisations loses the tail with no
indication, which is the same defect
[0032](0032-MADR-recent-and-searchable-forge-namespaces.md) records for
`glab_service.dart:563` (`groups?min_access_level=30&per_page=100`).

The codebase already knows this failure mode: `gh_service.dart:532` carries a
comment about "a single `per_page=100` page silently truncated a matrix run
wider than 100" — a bug that was found and fixed in a different call. These two
were missed.

Confidence: **confirmed by reading**; unreachable on the maintainer's account
(0 orgs), which is precisely why it survives.

### F8 — `api(paginate: true)` is a live trap with no current victim

Carried forward from 0032, re-verified today: `glab api --paginate` emits **one
JSON array per page, concatenated**, so any multi-page call raises
`GlabException: … returned non-JSON output`. The comment at
`glab_service.dart:511-514` asserts the opposite ("the merged pages then come
back as one clean JSON document").

`grep -rn "paginate: true" lib/` still returns **no call sites** — only the
comment at `:1383` explaining why `mergeRequests` hand-walks instead. Harmless
today; the fix is to correct the comment before someone trusts it.

Confidence: **confirmed by execution** (2026-09-06, 171-group fetch produced two
documents with a `][` seam).

### F9 — Forge pin/snooze state is applied optimistically and may never persist

`forge_prefs.dart` swallows four persistence failures with bare `catch (_) {}`
(`:72, :80, :120, :146`). `set()` (`:76-81`) assigns `state = inbox` **before**
the write and discards the write's failure, so a `SharedPreferences` failure
leaves the UI showing a setting that will not survive a restart, with nothing
told to anyone.

Confidence: **confirmed by reading**. Low severity — it is prefs, not data —
but it is silent, which is the property F1 is also about.

## What was checked and found clean

Reported so the next pass does not repeat it:

* **Resource disposal.** A scan for `Timer` / `StreamSubscription` /
  `TextEditingController` / `FocusNode` fields not torn down produced 8
  candidates; **all 8 were false positives** — my scanner matched the first
  `dispose()` in the file rather than the one in the same class. Verified
  individually: `edit_entry_sheets.dart:315-316`, `activity_center.dart:217`,
  `undo_toast.dart:42` (`ref.onDispose`), `coalescer.dart:113`,
  `ssh_client_manager.dart:289-292,537-540`. **Teardown discipline is good.**
* **Dead code in `core/`.** 12 methods have no `lib/` reference; 9 are
  test-only helpers with names that say so (`debugKillWorker`,
  `bindTestClients`, `debugLookupOriginHost`, `resetWatcherCount`, …). Only F5
  and F6 are genuinely dead.
* **The sequencer `*Continue` family.** `rebaseContinue`, `mergeContinue`,
  `cherryPickContinue`, `revertContinue`, `amContinue` first appeared as
  unwired. They are wired, as **tear-offs** at
  `repo_status_view.dart:1410-1419` — a blind spot in the first scan, which
  only counted `name(` call syntax.
* **`setState` after `await`.** 9 candidates; 6 were false positives
  (`stash_view.dart:538,677,841` are synchronous callbacks in build methods;
  `add_worktree_sheet.dart:270` and `history_view.dart:1161` are guarded by an
  earlier `mounted` check with no un-returned await after it). The 3 survivors
  are F2, F3, F4.
* `flutter analyze` clean; 3,602 tests passing; provider retry policy enforced
  by test.

## Decision Drivers

* **Silence is the theme.** F1, F7 and F9 are all "a failure happens and
  nothing says so". That is worth more than the individual line fixes.
* **Fix the observer, not the 49 call sites.** Collapsing a loading store to an
  empty list is usually right; the defect is that nothing anywhere notices the
  error case.
* **The crash trio (F2-F4) is one pattern, three instances** — a `mounted`
  guard on the wrong side of an await. They should be fixed together, with a
  test each, not opportunistically.
* **Do not manufacture duplication findings.** The two `status_color.dart`
  files look like copies and are not; saying so is part of the result.

## Considered Options

* **A. Fix everything in one change.** One plan covering all nine.
* **B. Fix by severity, in three tranches** — the silence class (F1, F9, and
  F7's user-visible half), the crash trio (F2-F4), then the hygiene items
  (F5, F6, F8).
* **C. Record only; fix opportunistically** when each file is next touched.
* **D. Fix only the crash trio**, since those are the only ones that can throw.

## Decision Outcome

Chosen option: **B — three tranches, severity first** — because the nine
findings are not one problem, and bundling them would produce a single
unreviewable diff across `core/`, `features/branches`, `features/workspace`,
`features/forge` and `core/theme`.

Suggested order, each its own change with its own test:

1. **The silence class.** Add a `ProviderFailureObserver` to the main scope and
   to tab containers, routing to the existing output log (the child window's
   `_ProviderFailureLogObserver` is the model, and this is the rare case where
   the pop-out is ahead of the main window). Then F9 and F7.
2. **The crash trio (F2, F3, F4).** One `mounted` guard each, moved to the
   correct side of the await, each with a test that disposes the host mid-await
   and is seen to fail first. F4 must be fixed in both sheets — they are
   byte-identical after MADR 0033 Phase 3, so this is one fix applied twice, not
   two bugs.
3. **Hygiene (F5, F6, F8).** Delete the orphaned CI enum and colour function;
   point `bounded_watch.dart` at the named legacy-filename helpers or delete
   them; correct the `--paginate` comment.

### Consequences

* Good, because the highest-value fix (F1) is small — an observer class and two
  wiring points — and turns a whole class of invisible failure into a log line.
* Good, because F2-F4 are one-line guards with clear tests.
* Good, because F5/F6/F8 remove or correct claims the code makes about itself
  that are not true, which is what made F6 and F8 hard to see.
* Bad, because none of F2-F4 has been **reproduced**; they are traced from the
  code. A fix should start by making each one fail on demand, or the guard is
  being added on faith.
* Bad, because three tranches is three review cycles for what a maintainer may
  reasonably want as one.
* Neutral, because F7 cannot be exercised on the maintainer's account (0 GitHub
  orgs) — a fixture test is the only way to prove it.

### Confirmation

* F1: force a store provider to throw and assert a log line reaches the output
  log from the **main** window, not just a pop-out.
* F2-F4: a widget test that starts the awaited work, disposes the host, and
  lets the future resolve — **seen to fail** against the current guard before
  the fix.
* F5, F6: `grep` shows zero references before deletion; the full suite stays
  green.
* F7: a fake executor returning a 100-entry first page and asserting the walk
  continues.
* F8: correcting a comment needs no test; the behaviour it describes was
  already demonstrated on 2026-09-06.

## More Information

* Scans were run on 2026-09-07 against `lib/` at commit `9b1b719`. Every
  scanner in this pass produced false positives — the disposal scan was 8/8
  wrong, the dead-code scan missed tear-offs, the `setState` scan was 6/9 wrong.
  **Each candidate here was read individually before being reported**, and the
  discarded ones are listed above so the noise is on record with the signal.
* [0032-MADR-recent-and-searchable-forge-namespaces.md](0032-MADR-recent-and-searchable-forge-namespaces.md)
  — records F8 and the GitLab half of F7.
* [0033-MADR-decompose-the-create-repository-sheet.md](0033-MADR-decompose-the-create-repository-sheet.md)
  — Phase 0b is the change named in F4's disclosure; Phase 2 is the precedent
  F6 follows.
* [0027-MADR-watcher-reclamation-cannot-reclaim.md](0027-MADR-watcher-reclamation-cannot-reclaim.md)
  — the scheme F6's dead helpers document.
