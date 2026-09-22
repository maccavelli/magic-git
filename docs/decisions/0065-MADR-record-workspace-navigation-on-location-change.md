---
status: "proposed"
date: 2026-09-22
decision-makers: [Maintainer]
consulted: [0064-PLAN-workspace-reachability-feedback-and-log-fidelity.md (deviation D5), 0009-MADR-ui-ux-debug-pass-backlog.md (H3), a release-mode diagnostic build of 718a354 with a frame-spin probe, the same minimal reproduction on 21d32bc]
informed: [Magic Git contributors]
verified: 2026-09-22
---

# Record workspace navigation once per location change, from the active panel only

## Context and Problem Statement

The on-device gate for [0064-PLAN](0064-PLAN-workspace-reachability-feedback-and-log-fidelity.md)
found the app at **~90–120% of one core, indefinitely**, after an ordinary sequence of clicks
(its execution record, deviation D5). The maintainer chose a diagnostic build over guesswork,
and it named the cause. This record decides how to remove it.

### The defect, as reproduced

The sequence is three user actions and is deterministic:

1. On Branches (Browse tab), select `master`.
2. Switch to History (⌘2 or the sidebar).
3. Select a commit.

Measured with `ps -o %cpu` three times, 1.5 s apart, on the same fixture and a 900 pt window:

| Build | After step 3 | 5 s later |
|---|---|---|
| `718a354` (0064 complete) | 120.1 / 115.8 / 118.3 | 115.9 / 116.1 / 115.5 |
| `21d32bc` (before 0064) | 117.5 / 114.7 / 117.3 | 115.6 / 114.7 / 116.7 |

It drops to 0% when the window is minimised and resumes when it is shown again. It is
**pre-existing**: every line involved dates from the 2026-08-13 commits that implemented
[0009-MADR](0009-MADR-ui-ux-debug-pass-backlog.md) item H3 (`e5631c5`, `85d0cd3`, `dbc77b8`).
0064's F1 only made the state easy to reach in the compact layout, which is how its gate found it.

### The mechanism, as observed

A release build of `718a354` carrying a scratch probe (installed from `main()`, never in the
repository) logged, during the spin: 120 frames per second, three transient frame callbacks, one
live route, and **a rebuild scheduled on every frame**. Every captured rebuild had the same
stack, with the app's frames at:

* `_HistoryViewState.build.<closure>` — the post-frame callback that History's `build` registers
  (`lib/features/history/history_view.dart:1532`), calling
* `WorkspaceNavigationHistory.visit` (`lib/features/common/workspace_navigation.dart:86`), which
  writes the provider's `state`, which notifies
* a `ConsumerStatefulElement.watch` listener that calls `Element.markNeedsBuild`.

The code explains the rest:

* **The watcher is the shell.** `AppShell._pages` watches the whole navigation state
  (`lib/features/app_shell.dart:1157`) while using only `locations.isEmpty` (`:1158`). Every
  write rebuilds the shell, and the shell rebuilds every page in its `IndexedStack`, hidden pages
  included.
* **Every panel re-records its selection from `build`.** Four panels register a post-frame
  callback during `build` that publishes the panel's chrome supplement and then `visit`s the
  current selection: History (`history_view.dart:1531-1573`), Branches
  (`lib/features/branches/branches_view.dart:443-462`), Stashes
  (`lib/features/stash/stash_view.dart:372-388`) and Worktrees
  (`lib/features/worktrees/worktrees_view.dart:639-655`). None is gated on `widget.isActive`, so
  a hidden panel reports too. (The forge panels record from their selection handler instead,
  `lib/features/gitlab/gitlab_panel.dart:233` and `lib/features/github/github_panel.dart:200`,
  and are not part of the loop.)
* **The notifier dedupes only against the current entry.** `visit` returns early when
  `state.current == location` (`workspace_navigation.dart:78`). Two mounted panels with
  selections therefore alternate: History records its commit, Branches records `master`, and
  each write is "new" against the other. One lap per frame, for as long as frames are produced.
* **The supplement publish is not a second driver.** `RepositoryContextSupplementCache.publish`
  compares content and writes nothing for an equal supplement
  (`lib/features/common/repository_context.dart:96`).

The Branches half of the alternation is inferred from the code and from the reproduction's
preconditions (a selection on each of two mounted panels): the probe's hook logs only the first
element dirtied per frame, and that was always History's.

### Why it was written this way

0009 H3 needed each panel to record a **data-complete** location — Branches includes its
comparison base (`secondaryIdentity: base?.refName`), History its range end or path filter —
and those values land asynchronously after the click. Recording from `build`, where the landed
data is at hand, achieved that. The re-recording it caused was known: the notifier's
`_staleEcho` guard exists precisely because "the destination screen still re-reports its
pre-restore selection from post-frame callbacks it scheduled with build-time values"
(`workspace_navigation.dart:55-62`). What was not seen is that two such reporters, plus a shell
that rebuilds them all on every write, form a cycle.

### What was ruled out on the way

* **A held ⌘ key.** `HardwareKeyboard.logicalKeysPressed` was empty at every stuck point.
* **A ticker.** The three transient callbacks are a by-product of the rebuilds; the frame driver
  is the rebuild itself.
* **A 0064 regression.** See the table above.
* **The input-eating seen during the gate** was macos_ui's Filter pulldown: on the fixture's
  Review tab the replay's row coordinate lands on that pulldown, whose transparent
  `ModalBarrier` swallows shortcuts and the next click. Not an app defect, and not this record.

## Decision Drivers

* **Fix the cause, not the symptom.** A visit must never be re-issued for an unchanged location,
  and a hidden panel must never record where the user "is". Anything that leaves the cycle in
  place and interrupts it elsewhere is a guard.
* **Keep 0009 H3 whole.** Back and Forward, palette reveals, the pending/unavailable protocol and
  the six location adapters keep their behaviour and their tests.
* **Data-complete locations.** The recorded entry must still carry the base, range end or path
  that only landed data can supply.
* **Bounded work when idle.** A navigation write must not rebuild every page.
* **A test that fails on the current code**, and an on-device reproduction that reads 0% after.
* **Small blast radius** for a defect that has shipped since August.

## Considered Options

* **Option 1 — Change-keyed, active-only recording through one shared recorder; narrow the
  shell's watch; retire the stale-echo guard.**
* **Option 2 — Structural minimum: gate each panel's build-time visit on `isActive` and narrow
  the shell's watch.**
* **Option 3 — Reject visits inside the notifier from any panel that is not the active page.**
* **Option 4 — Record only from selection handlers, never from `build`.**

## Decision Outcome

Chosen option: **"Option 1"**, because it removes both halves of the cycle at their source — an
unchanged location is never re-recorded, and a hidden panel never records — while keeping the
data-complete locations that H3 depends on and shrinking the notifier rather than growing it.

### What changes

1. **One recorder, four panels.** A mixin `WorkspaceLocationRecorder` on `ConsumerState`
   (`lib/features/common/workspace_location_recorder.dart`) owns a `_recordedLocation` memo and
   exposes `recordWorkspaceLocation(WorkspaceFocus? location, {required bool active})`:
   * called from `build` with the location the panel's **landed data** resolves to, or null when
     nothing is selected — the same expression each panel builds today;
   * when `active` is false it clears the memo and returns, so a panel records nothing while
     hidden and records **once** when it becomes the active page with a selection (today's
     behaviour on activation, minus the repetition);
   * when `location` is null it clears the memo and returns, so re-selecting after a deselection
     records again;
   * otherwise, if `location == _recordedLocation` it returns; else it sets the memo **before**
     scheduling a post-frame `visit`, so two builds in one frame cannot double-record.
   History, Branches, Stashes and Worktrees replace their in-callback `visit` with one call to
   it; their supplement publish stays where it is.
2. **The shell watches what it uses.** `AppShell._pages` watches
   `workspaceNavigationProvider(key).select((s) => s.locations.isEmpty)`. A navigation write no
   longer rebuilds the shell or its pages. The context bar keeps watching the whole state — it
   renders Back/Forward from it.
3. **The stale-echo guard goes.** With no panel re-reporting an unchanged location, no caller can
   emit the echo the guard was written for: after a restore the panel's `build` resolves the
   *old* selection, which equals its memo, so nothing is recorded; when the adapter applies the
   restored location the panel records it, and `visit` coalesces it against `state.current`.
   `_staleEcho`, its branches in `visit` and `reveal`, and the unit test that exercises it are
   removed; the unit test "coalesces equal visits and restores without adding entries" already
   pins the surviving behaviour.

### Consequences

* Good, because the cycle cannot form: neither of its two writers exists any more.
* Good, because idle cost is zero — a navigation write touches the context bar and nothing else.
* Good, because the notifier gets simpler (a guard and two branches removed), not more clever.
* Good, because every recorded entry is still data-complete, so Back/Forward land where they do
  today.
* Neutral, because the recorder is still *driven* from `build`: the location is computed there
  because that is where landed data is. The effect is idempotent and post-frame, which is the
  accepted shape for a build-derived side effect; it is not a `setState`-in-build.
* Bad, because four panels and the shell change at once (six production files), and a defect in
  the memo logic would surface as a missing or duplicated history entry — hence the per-panel
  tests below.
* Bad, because a location whose qualifiers change without a user action (a comparison base that
  lands late) records a second entry, as it does today; the memo does not change that.

### Confirmation

* **The regression test is seen to fail first.** In History's existing harness (`test/history_actions_test.dart`,
  `connected: true`): select a commit, then push an unrelated visit into the notifier, then
  `pump()` five frames. Expected: `locations` is exactly `[commit, unrelated]`. On the current
  code History re-records the commit on the next frame, and the assertion fails. A second case
  mounts the panel with `isActive: false` and asserts no entry at all.
* The same two cases for Branches, Stashes and Worktrees in their harnesses.
* The notifier's unit tests pass with the stale-echo test removed.
* `flutter analyze` clean; `flutter test` green, with 0 `[E]`.
* **On the device**, the three-step reproduction on the fixed build reads ≤ 5% CPU in every sample
  over 10 s, where the unfixed build reads > 100%. The scratch driver from D5 (`spin_min.py`,
  in the 0064 scratch directory) runs it unattended.

## Pros and Cons of the Options

### Option 1 — Change-keyed, active-only recording; narrow the watch; retire the guard

* Good, because it removes the re-recording and the hidden-panel recording, the two facts the
  cycle needs.
* Good, because the fix is one mixin and one-line call sites; the panels' location expressions
  are untouched.
* Good, because it deletes code (the echo guard) whose reason for existing goes away.
* Neutral, because the recorder is called from `build`; see Consequences.
* Bad, because it touches six production files and four test files.

### Option 2 — Structural minimum

Gate each build-time `visit` on `widget.isActive` and narrow the shell's watch.

* Good, because ~12 lines across six files.
* Good, because the `isActive` gate alone makes the alternation impossible — only one panel can
  be active.
* Bad, because the active panel still re-records its selection on every rebuild, relying on the
  notifier's `current` check; the pattern that produced this defect stays in the code, and the
  stale-echo guard stays necessary.
* Bad, because the next reporter added without the gate reintroduces the cycle.

### Option 3 — Reject in the notifier

`visit` reads `pageIndexProvider` and ignores a location whose `panelIndex` is not the active
page.

* Good, because one change in one file.
* Bad, because it couples the session's history model to UI page state, and the notifier must
  then be built inside a container that has that provider — every unit test grows a dependency.
* Bad, because the re-recording from `build` continues; the notifier merely discards more of it.

### Option 4 — Record only from selection handlers

Call `visit` from `_handleRowTap`, `_select` and their keyboard equivalents, never from `build`.

* Good, because the record is unambiguously a user action.
* Bad, because the qualifiers H3 records — Branches' comparison base, History's range end and
  path — are not all known in the handler; entries would be incomplete or need a second write
  when data lands, which is the re-recording again by another route.
* Bad, because every keyboard and drag selection path in four panels must be found and wired;
  a missed one is a silent gap in Back/Forward.

## More Information

* **Evidence trail.** The diagnosis, the false leads and their disproof are recorded in
  [0064-PLAN](0064-PLAN-workspace-reachability-feedback-and-log-fidelity.md), execution record,
  deviation D5. Two are worth carrying: a first route census in the probe used `ModalRoute.of()`
  on every element, registered inherited dependencies from non-descendants, and itself produced
  a 103% assertion storm — a diagnostic can manufacture the symptom it hunts; and the fixture's
  Branches page persists its Review tab (`lastMode`), which silently changed what a fixed click
  coordinate hit between runs.
* **Related work.** [0009-MADR](0009-MADR-ui-ux-debug-pass-backlog.md) H3 introduced the
  navigation history, the adapters, `reveal()` and the stale-echo guard this record retires.
  Its Back/Forward semantics are unchanged.
* **Out of scope, noted for the maintainer.** With a pulldown menu open, a synthetic Esc did not
  close it (4 of 4, release build); a real-keyboard check would say whether that is real. The
  shell's `IndexedStack` rebuilds every visited page whenever the shell rebuilds for any reason;
  this record removes one reason, not the pattern.
* **Implementation:** [0065-PLAN](0065-PLAN-record-workspace-navigation-on-location-change.md).
