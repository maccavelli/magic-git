---
status: "executed"
date: 2026-08-14
verified: 2026-08-20
---
# Implement the unified repository chrome

Associated MADR: [0008-MADR-unified-repository-chrome.md](0008-MADR-unified-repository-chrome.md)

- Status: **executed.** `menu_bar_spec.dart` / `menu_bar_bridge.dart` ship the Dart-declared native menu bar, `chrome_budget_test.dart`, `chrome_correctness_test.dart`, `chrome_reachability_test.dart` and `menu_bar_spec_test.dart` pin it, and `repository_workspace_prefs.dart` cites "MADR 0008, Phase 1" in production source.

  *Status corrected 2026-08-20:* this line read "proposed, for review. No code written," which was false against the tree.
- Date: 2026-08-14
- Owner: implementation agent + maintainer review
- Delivery: six independently shippable phases, each analyzer-clean and
  revertible on its own. Phase 0 ships value immediately and depends on nothing.

## Assessment of MADR 0008

Every load-bearing claim in the MADR was re-verified first-hand against the tree
at `24ce0f7` before this plan was written. Results:

**Confirmed.** `stashPush` defaults `includeUntracked = false`
(`git_service.dart:5154`) with two call sites omitting it
(`stash_view.dart:450`, `:526`). `WorkspaceToolbarSlot` is exactly
`{back, forward}` (`repository_workspace_prefs.dart:15`). Back/Forward are
passed only to `RepoStatusView` (`app_shell.dart:1078-1080`). Three screens pass
`kind: RepositoryPrimaryActionKind.fetch` for non-fetch verbs
(`worktrees_view.dart:660`, `stash_view.dart:443`, `history_view.dart:1491`).
`ActivityCenterButton` is constructed twice (`repo_status_view.dart:2228`,
`repository_context_bar.dart:127`). Chrome constants: tab strip 36
(`tab_strip.dart:58`), context bar 52/46/40 (`repository_context_bar.dart:56-59`),
`_header` padding `symmetric(h:16, v:12)` = 24 (`repo_status_view.dart:2096`),
window floor 640×480 (`app_providers.dart:86-87`).

**Corrected.** The MADR's relocation table said the palette's "Amend last
commit" *mis-targets* History. It does not mis-target anything — `history.amend`
(`keymap.dart:539`, palette `command_palette.dart:205`) is a legitimate History
action. The real defect is narrower and still worth fixing: **two different
commands share the label "Amend last commit"** — that one, and the Repository
overflow item calling `RepoStatusView._amend` — with no way to tell them apart
in the palette. Treated below as a labeling bug, not a routing bug.

**Resolved (the MADR left these open).**
* *Back/Forward: wire or remove?* **Wire.** All five non-repository screens
  already publish workspace focus (`stash_view.dart`, `forge_workspace.dart`,
  `worktrees_view.dart`, `history_view.dart`, `branches_view.dart` all
  reference `WorkspaceFocus`/`workspaceNavigationProvider`), so the history is
  real and only the callbacks are missing.
* *What widget is the "grouped sync control"?* The codebase already ships this
  composite — `AppPushButton` + adjacent `MacosPulldownButton` — for the forge
  merge button (`gitlab_panel.dart:908`, `:988`, `:1000`). No new widget
  vocabulary is needed, and `macos_ui`'s `ToolBar` is irrelevant here because
  the context bar is a hand-rolled `Container`, not a `macos_ui` toolbar
  (repo-wide `ToolBar(` → zero hits).

**Weaknesses I am carrying forward rather than hiding.**
1. The `_header` intrinsic height of 54 px is a derivation (padding 24 + a
   `ToolIconButton` clamped to 30 by `MacosIconButton`'s `maxHeight`), not a
   measured value. Step 6.1 measures it instead of asserting it.
2. The MADR proposes a large surface. If only part ships, the ordering below is
   the part that matters: **Phase 1 must precede Phase 4**, because the menu bar
   is what makes deleting a band non-lossy.
3. Apple has no citable rule against cross-band duplication (the MADR says so).
   The case rests on overcrowding, the three-group maximum, and the
   `.unified`/`.expanded` API choice.

## Goal

Collapse the repository workspace to one action-bearing band, with **no action
losing a route** and several gaining one, and fix the correctness defects the
inventory surfaced along the way.

## Scope

**In scope.** The MADR's design (one band, static grouped sync control,
populated menu bar, transient status evicted, honest shared contract, real slot
customization) **plus the 14 verified bugs below**, which the maintainer asked
to fold in.

**Out of scope.** Native `NSToolbar` migration (MADR option E); the MADR 0006
title-bar flip, which proceeds independently; per-screen navigator toolbars,
which live inside panes rather than window-width bands; the five mode-switch
idioms and four banner implementations, which need their own consistency pass.

**Standing constraints** (`AGENTS.md`): `flutter analyze` + `flutter test` clean
before staging; never run `live-forge` unprompted; `grep -a` for
`app_providers.dart`; no agent-authored commit messages.

## Bug inventory (all verified first-hand)

| # | Bug | Evidence | Severity |
| --- | --- | --- | --- |
| B1 | **Stash omits untracked files from two entry points.** On a tree whose only changes are untracked, the Stash screen's primary button reports success and creates no stash. | `git_service.dart:5154` default `false`; `stash_view.dart:450`, `:526` omit it; hazard documented at `branch_switch.dart:66-69` | **High — silent no-op on user data** |
| B2 | **Stash Apply/Pop operand diverges by entry point.** Hamburger acts on the *latest* stash; row buttons and ⌥⌘A/⌥⌘P act on the *selection*. | `stash_view.dart:559`, `:566` (`_actOnLatest`) vs `:724`, `:730` | **High — wrong-object action** |
| B3 | **Worktree Repair operand diverges.** Hamburger repairs all links with no operand; row button, context menu and detail button each take one worktree. | `worktrees_view.dart:815` vs `:939`, `:461`, `:1035` | Medium |
| B4 | **`ActivityCenterButton` rendered twice on the Repository page**, ~300 px apart. | `repo_status_view.dart:2228` + `repository_context_bar.dart:127` | Medium |
| B5 | **Back/Forward permanently dead on 5 of 6 screens** despite real history. | `app_shell.dart:1078-1080` passes them only to `RepoStatusView` | Medium |
| B6 | **Status summary reads "Clean" on 5 of 6 screens** because they never populate `changedCount`/`conflictCount`. | defaults at `repository_context.dart:157-158` | Medium — actively misleading |
| B7 | **`RepositoryPrimaryActionKind` falsified on 4 screens** (`kind: fetch` for "Add Worktree", "Stash Changes", "Refresh"). | `worktrees_view.dart:660`, `stash_view.dart:443`, `history_view.dart:1491`, `branches_view.dart:579` | Medium |
| B8 | **`_CompactMetadata` is an inert menu** — every item is `onTap: () {}`. | `repository_context_bar.dart:335` | Low — fake affordance |
| B9 | **⌘G can be a silent no-op.** `_expandCommitComposer` sets `_composerExpanded`, but the task dock is hidden entirely when `taskDockCollapsed`, which the Review/Investigate/Minimal presets all set. | `repo_status_view.dart` expand path; `adaptive_workspace_layout.dart:56-58`; `repository_workspace_prefs.dart:45`, `:59`, `:66` | Medium |
| B10 | **Default preset contradicts default prefs.** `preset` defaults to `review` but `taskDockCollapsed` defaults `false`, while `applyWorkspacePreset(review)` sets it `true`. | `repository_workspace_prefs.dart:114` vs `:120` vs `:45` | Low |
| B11 | **Three diff prefs are dead.** `diffLayout` and `diffContextLines` have zero readers outside the prefs file; `ignoreWhitespace` likewise (RSV uses session-local `_diffIgnoreWs`). Diff view mode resets on every remount. | verified by grep; `repo_status_view.dart:1850` | Medium — silent pref loss |
| B12 | **`filesPinned` has no writer.** Read once, settable by nothing. | `repo_status_view.dart:1494`; prefs plumbing only | Low |
| B13 | **Inspector slot never populated on any screen**, so `inspectorWidth`/`inspectorPinned`/`inspectorCollapsed` and the Investigate preset are inert. | zero `inspector:` args across all six screens | Low |
| B14 | **Two commands share the label "Amend last commit"** with no disambiguation in the palette. | `keymap.dart:540` (History) vs Repository overflow item | Low |

## Implementation Steps

### Phase 0 — Correctness fixes (ships now, independent of all chrome work)

None of this depends on the MADR being accepted. Do it first regardless.

**0.1 — One stash call site, one behavior (B1).**
Route every "stash everything" entry point through a single method with
`includeUntracked: true`. Change `stash_view.dart:450` and `:526`. Keep "Stash
including untracked" as a distinct menu item **only if** it still differs from
the default after the fix — it does not, so **delete it** and rename the
remaining item to plain "Stash changes".
*Test:* new `test/stash_semantics_test.dart` — assert every stash entry point
produces argv containing `--include-untracked`, driven by a fake executor; and
a regression case that an untracked-only tree produces a real stash.

**0.2 — Name the operand (B2, B3).**
Relabel the divergent items so the object is unambiguous, rather than silently
unifying them: `stash_view.dart:559/566` → "Apply latest stash" / "Pop latest
stash" (already correct) but move them under a separate menu section headed by
the selection-scoped items, so the two operands are visually distinct.
`worktrees_view.dart:815` → "Repair all worktree links".
*Test:* widget assertions on the labels; a unit assertion that `_actOnLatest`
and the row handler take different operands by construction.

**0.3 — Delete the duplicate Activity button (B4).**
Remove `repo_status_view.dart:2228-2236`. The context-bar instance is
unconditional and therefore never leaves a gap.
*Test:* `expect(find.byType(ActivityCenterButton), findsOneWidget)` on the
Repository page at ≥900 px width, which is the only size where both rendered.

**0.4 — Make ⌘G always do something (B9, B10).**
`_expandCommitComposer` must un-collapse the task dock when it is collapsed,
not just set `_composerExpanded`. Also align the default preset with the
default prefs (`repository_workspace_prefs.dart:114` vs `:120`) — pick one and
make the other follow.
*Test:* pump with `taskDockCollapsed: true`, invoke the expand path, assert the
composer is visible.

**0.5 — Retire or wire the dead prefs (B11, B12, B13).**
Decide per field and record the decision in code comments:
* `diffLayout` / `ignoreWhitespace` / `diffContextLines` → **wire** (read them
  as the initial value for `_diffSplit`/`_diffIgnoreWs`/`_diffExpandContext`,
  and write on toggle). This is a real user-facing improvement: diff mode stops
  resetting on remount.
* `filesPinned` → **wire** a toggle in the file-tree header, or delete the
  field. Prefer wiring; the read site already exists.
* Inspector prefs → **leave inert, documented**. Populating an inspector is
  product work outside this plan; add a comment at the pref so the next reader
  does not re-derive this.
*Test:* prefs round-trip plus a widget assertion that a toggled diff mode
survives a remount.

**0.6 — Disambiguate the amend labels (B14).**
Rename the Repository overflow item to "Amend last commit (this repository)" or
give the History one a panel-qualified palette label. One-line change; the point
is that two identically-labelled palette rows must not do different things.

**0.7 — Stop the inert compact menu (B8).**
`_CompactMetadata` items are `onTap: () {}`. Either make the pulldown
non-interactive presentation (a tooltip-backed label) or give each row a real
action. Prefer the former — it is metadata, not commands.

*Phase 0 acceptance:* every bug row above has a test that fails before and
passes after. No chrome geometry changes.

---

### Phase 1 — Populate the macOS menu bar (the enabler; must precede Phase 4)

This is what converts "delete a band" from lossy to safe, and it is the
HIG-required safety net the app currently lacks.

**1.1 — Reuse the existing dispatch bus, do not fork handlers.**
`PaletteIntent` + `PanelShortcuts` already routes an `actionId` to the owning
panel's real handler, switching panels first when needed
(`palette_intents.dart`, `panel_shortcuts.dart:55-80`). Its own doc comment
explains why duplicating handlers at the shell is wrong: it "would fork every
guard those handlers carry (busy gates, selection requirements, dirty-tree
prompts)". The menu bar dispatches the same way.

**1.2 — Swift: add the menus.** Follow the existing `installViewMenuItems`
pattern in `macos/Runner/MainFlutterWindow.swift` (helper `addToggleItem` at
`:338`; channel `magicgit/menu` at `:86`). Add a plain-action helper alongside
it (no checkmark, caller-supplied modifier mask), then install:

| Menu | Items (each = one existing keymap `actionId`) |
| --- | --- |
| Repository | Fetch · Pull ▸ (default / rebase / merge) · Push ▸ (default / set upstream / tags / force with lease / force) · Sync · — · Stash changes · Stash with message… · — · Amend last commit · — · Refresh |
| Branch | New branch… · New tag… · Publish · Create pull/merge request · Compare with base · Open CI · — · Merge into current · Delete branch |
| Stash | Apply · Pop · Drop · — · Apply latest · Pop latest · — · Clear all stashes… |
| Forge | New issue · New pull/merge request · Approve · Merge · Re-run / Retry CI · — · Enable auto-merge · Cancel auto-merge |
| Worktree | Add worktree… · Open worktree · — · Lock / Unlock · Move… · Repair… · Repair all links · Prune stale · — · Remove worktree… |

Destructive items (force push, delete, clear all, remove) get the standard
destructive treatment; unavailable items **dim rather than disappear**, per HIG:
"If all of a menu's items are unavailable, the menu itself needs to remain
available so people can open it and learn about the commands it contains."

**1.3 — Dart: extend `_handleMenuCall`** (`tabs_host.dart:212`) with a single
generic case that takes an `actionId` and dispatches a `PaletteIntent`, rather
than one case per command. Existing view-toggle cases stay as they are.

**1.4 — Give the menu-less commands keymap ids.** Several verbs in 1.2 have no
`actionId` today (worktree verbs have none at all; `Unstage All`, `Abort
pending`, `Force push` plain, `Stash with message`). Add ids to
`keymap.dart` with `defaultBindings: []` so they are addressable by menu and
palette without stealing chords.

*Test:* a completeness test asserting **every menu item's `actionId` exists in
`kKeymapActions` and resolves to a handler in its owning panel** — the
menu-bar analogue of the existing `branches_keymap_handlers_test.dart`.

*Acceptance:* the reachability matrix is re-derived; **no action has fewer
routes than before, and the 41 single-route actions are now ≥2.**

---

### Phase 2 — Make the shared contract honest

**2.1 — Real primary-action kinds (B7).** Extend
`RepositoryPrimaryActionKind` with the verbs the five screens actually need
(`stash`, `addWorktree`, `refresh`, `fetchAndPrune`, `createRequest`) and
delete the `kind: fetch` placeholders at `worktrees_view.dart:660`,
`stash_view.dart:443`, `history_view.dart:1491`, `branches_view.dart:579`.

**2.2 — Wire Back/Forward everywhere (B5).** Pass `onBack`/`onForward` from
`app_shell.dart` to all six panels, not only `RepoStatusView` (`:1078-1080`).
The history already exists on every screen.

**2.3 — Populate or omit the status summary (B6).** Each screen either supplies
real `changedCount`/`conflictCount` or the summary renders nothing. Never
"Clean" by omission.

**2.4 — Stop dropping the bar.** Forge loses the context bar on four of six
router outcomes (`forge_panel.dart:48-57`); Worktrees loses it in tab mode
(`worktrees_view.dart:606-615`) and *nests a second one* when a worktree tab
mounts a `RepoStatusView`. Wrap the Forge non-happy paths in the scaffold, and
suppress the inner bar when a workspace screen is mounted inside a worktree tab.

*Test:* a shared "context bar contract" test run against all six screens —
bar present in every state, no falsified kind, Back/Forward enabled when
history exists.

---

### Phase 3 — The grouped sync control

**3.1 — Build it from the in-house composite.** `AppPushButton` +
adjacent `MacosPulldownButton`, exactly as `gitlab_panel.dart:908/988/1000`
already does. Group = Fetch · Pull · Push · Sync, always present, each with a
stable meaning. The recommended verb (from
`resolvePrimaryRepositoryAction`'s existing ladder) gets visual emphasis and
the ahead/behind badge; **no button changes what it does.**

**3.2 — The pull-down carries the variants**, so nothing is state-hidden:
Pull ▸ rebase / merge; Push ▸ set upstream / tags / force with lease / force
(destructive styling). Note Apple's constraint — "If you need to list only one
or two items, consider using alternative components" — so a variant menu with
fewer than three entries becomes a plain button instead.

**3.3 — Compact behavior.** At the compact size class the group collapses to
the emphasized verb plus an overflow pull-down rather than wrapping.

*Test:* every verb reachable at every size class; the emphasized verb tracks
the ladder; no button's handler changes with repo state.

---

### Phase 4 — Delete the second band and relocate the orphans

**Do not start until Phase 1 is green.** Each row is a precondition, not a
description.

| Orphan | Current sole home | Destination |
| --- | --- | --- |
| Pull rebase/merge, Push upstream/tags/force ×2 | `_header` overflow | sync pull-down (3.2) + Repository menu |
| Stash | `_header` icon | sync group neighbour + Stash menu |
| Amend last commit | `_header` overflow | Repository menu (relabelled, 0.6) |
| Refresh | `_header` icon | ⌘R + View menu (button optional) |
| Settings gear | `_header` icon | app menu (⌘, exists) |
| SSH latency strip | `_header` | bottom status area or identity subtitle — precedent: Tower's sidebar Remote Activity, GitHub Desktop's "Last fetched…" subtitle |
| "No remote detected" / "No branches yet" | `_header` captions | context-bar identity area / inline empty state |
| Watcher status dot | `_header` | context-bar identity area |
| Branch name, ahead/behind | `_header` (duplicates the bar) | delete — the bar already shows both |

Then delete `_header` (`repo_status_view.dart:2053-2305`) and its call site
(`:1473`).

*Test:* the reachability matrix re-derived a second time, post-deletion, with
the same no-regression gate.

---

### Phase 5 — Real slot customization

Replace the two-entry `WorkspaceToolbarSlot` (`repository_workspace_prefs.dart:15`)
with the full set of optional bar items (sync group, stash, refresh, activity,
view options, back, forward), persisted per repository UI identity. Keep the
identity block and the emphasized primary permanently visible — HIG: "items on
the toolbar's leading edge aren't customizable" and "Only specify one primary
action".

**Precondition:** Phase 1 must be complete, because customization is only safe
once every item also exists as a menu command — "it can't be the only place
that presents a command."

---

### Phase 6 — Measure and clean up

**6.1 — Measure the chrome budget** at 640 / standard / wide, one tab and two,
before and after. Record real numbers in the MADR, replacing the derived 54 px
`_header` estimate.

**6.2 — Dead token.** `paneHeaderHeight` appears exactly four times
(`app_theme.dart:41` field, `:47` constructor, `:56` compact = 36, `:62`
comfortable = 42) — all declaration and construction, **zero consumers**.
Either apply it to the pane headers whose heights are currently hardcoded, or
delete it.

**6.3 — Zero-route focus actions.** `global.focusNavigator` / `focusCanvas` /
`focusInspector` / `focusTaskDock` / `focusActivity` ship unbound with no menu,
palette row, or chrome affordance. Give them menu items (View ▸ Focus) or
delete them.

**6.4 — The palette has no menu item.** ⌘K is its only route; add View ▸
Command Palette.

## Verification

Run per phase, and before staging anything:

```sh
flutter analyze
flutter test
```

**The gate that matters** is the reachability matrix, re-derived twice — after
Phase 1 and again after Phase 4. A single action with fewer routes than it had
at `24ce0f7` blocks the phase. This is the executable form of "I do not accept
losing functionality."

Also required:
* Per-bug tests from Phase 0, each failing before its fix.
* The menu-completeness test from 1.4 (every menu item resolves to a real
  handler).
* The context-bar contract test from Phase 2, across all six screens.
* `test/workspace_responsive_test.dart` — the guard for bar-height changes
  (3 sizes × 3 text scales, no overflow, `Resolve` tappable).
* The 48 workspace goldens are **not** a guard here: they render a synthetic
  fixture with a hardcoded 52 px bar and never mount real chrome.
* Live verification on `./build_macos.sh --unsigned`, because nothing above
  measures whether the result reads as one coherent bar.

## Rollout and Rollback

**Sequencing.** Phase 0 is independent — ship it first whatever happens to the
rest. Phase 1 is independent and additive (a menu bar that duplicates existing
routes harms nothing). Phase 2 is independent. **Phase 4 depends on Phase 1 and
Phase 3.** Phase 5 depends on Phase 1. Phase 6 is independent.

**Rollback.** Phases 0, 1, 2 and 6 are additive or corrective and revert
cleanly in isolation. Phase 3 replaces one control and reverts to the previous
primary button. **Phase 4 is the only destructive step** — it deletes
`_header` — so it lands alone, in its own commit, after its reachability gate
is green, and reverting it restores the row intact because nothing else depends
on its absence.

**No migrations.** `WorkspaceToolbarSlot` gains values in Phase 5; the decoder
already falls back to both-on for unknown/legacy payloads
(`repository_workspace_prefs.dart:279-291`), so older stored prefs load
unchanged.
