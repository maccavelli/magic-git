---
status: "accepted"
date: 2026-09-22
decision-makers: [Maintainer]
consulted: [0005-MADR-task-centered-adaptive-repository-workspace.md, 0008-MADR-unified-window-chrome.md, 0064-MADR-workspace-reachability-feedback-and-log-fidelity.md (F1), the app's stored preferences for /Users/<user>/gitrepos/go/ocp-login]
informed: [Magic Git contributors]
verified: 2026-09-22
---

# Give a collapsed navigator a visible way back: a reveal rail and a View-menu command

## Context and Problem Statement

The maintainer reported a repository tab where **History showed nothing — no commit list, and
Refresh changed nothing**. The page was not broken and the log was not empty. That repository's
workspace preferences hold:

```
local:… · /Users/<user>/gitrepos/go/ocp-login/.git
    {'navigatorCollapsed': true, 'inspectorCollapsed': true, 'taskDockCollapsed': true,
     'preset': 'minimal', 'navigatorWidth': 347.35}
```

The **Minimal** preset sets `navigatorCollapsed: true`
(`lib/core/settings/repository_workspace_prefs.dart:115-120`). The navigator is the left pane,
which on History *is* the commit list, on Branches the branch tree, and on Stashes the stash list.
Five pages pass one — History, Branches, Stashes, Forge and Worktrees. The Repository page passes
none (its list and diff both live inside its `canvas:`), which is why that page looked normal on
the same tab while History looked broken.

### Why it looks like a defect in the page

* **The pane is not rendered at all.** `ResizableMasterDetail` gives the leading pane
  `SizedBox(width: 0, child: null)` while `collapsed` is set
  (`lib/features/common/resizable_master_detail.dart:134`, `:154`, and `:185` for the vertical
  axis). What is left is the canvas, showing its empty-selection placeholder — "Select a commit"
  centred across the whole page.
* **Refresh cannot help.** It re-runs the log; the rows have nowhere to go.
* **The state is per repository** (`repositoryWorkspacePrefs_v1_<identity>`), so other tabs look
  normal and the tab that is wrong looks like a bug in that repository.

### Why there is no way back

* **No handle.** While `collapsed` is set, the divider's drag callbacks are null
  (`resizable_master_detail.dart:230-247`) and its keyboard adjust actions are null (`:216-217`).
  The divider is a 1 px line with a 9 px hit area that does nothing.
* **No command.** There is no keymap action for the navigator: `keymap.dart` has
  `global.toggleOutput`, `toggleSidebar`, `toggleFileView`, `toggleDashboard`, `toggleRecovery`
  — nothing for a workspace pane. A repository-wide `grep` for `toggleNavigator` finds nothing.
* **One route, and it is not labelled as such.** The only way back is the view-options popover in
  the repository context bar (`WorkspaceViewOptionsButton`,
  `lib/features/common/repository_context_bar.dart:174`), choosing a preset whose side effect is
  `navigatorCollapsed: false` (`workspace_view_options.dart:94-100`). Nothing in that menu says
  the navigator is hidden, and nothing on the page points at the menu.
* **Compact width already solved this.** 0064 F1 gave the compact layout a back bar because a
  hidden navigator with no way back was judged a defect there
  (`adaptive_workspace_layout.dart`, `_CompactBackBar`). The wide and standard layouts never got
  the equivalent.

### Scope of the same hole

`inspectorCollapsed` and `taskDockCollapsed` have the same shape. The inspector is inert today
(no screen passes one — see the note at `repository_workspace_prefs.dart:187-193`), and the task
dock's `hidden` presentation is reached the same way. Only the navigator is user-visibly broken
right now, and only it is fixed here; the mechanism is written so the task dock can adopt it.

## Decision Drivers

* **A pane the user cannot see must still be reachable** — the rule 0064 F1 applied at compact
  width, applied at every width.
* **Recovery without prior knowledge.** The affordance must be on the page, not only in a menu
  the user would have to already know about.
* **Recovery without the mouse**, and visible in the menu bar, which is where macOS users look
  for view state.
* **No change to what "collapsed" means.** The preference, the presets and the persisted layout
  stay exactly as they are; a collapsed navigator is still collapsed.
* **No layout surprise.** The fix must not shift the canvas by more than the rail it adds, and
  must not disturb the 48 workspace goldens beyond what is stated.

## Considered Options

* **Option 1 — A reveal rail plus a View-menu command** (both).
* **Option 2 — The rail alone.**
* **Option 3 — The command alone.**
* **Option 4 — Refuse to collapse the navigator: drop it from the Minimal preset.**

## Decision Outcome

Chosen option: **"Option 1"**, because the rail makes the state legible exactly where it is
confusing — on the page — and the command makes it reachable from the keyboard and the menu bar,
which is also where its checkmark tells the truth. Neither alone covers both failures the report
showed: the maintainer could not see *what* was wrong, and had no way to undo it.

### What changes

1. **A reveal rail.** When `AdaptiveWorkspaceLayout` renders a wide or standard arrangement with
   `preferences.navigatorCollapsed` **and a `navigator` is supplied**, the navigator pane is
   replaced by a **28 pt** vertical rail at the leading edge, not by nothing: a chevron pointing
   into the canvas over the pane's rotated name. The name comes from a new
   `navigatorLabel` argument on the scaffold and the layout, which each page fills with the value
   it already passes as `compactNavigation.navigatorLabel`. The whole rail is one
   `Tappable` with `SystemMouseCursors.click` and a `Semantics(button: true, label: 'Show
   <name>')`; tapping it clears `navigatorCollapsed` through the existing
   `onPreferencesChanged`, which persists it like any other pane change.
2. **A command.** `global.toggleNavigator` ("Toggle Navigator") joins `keymap.dart` with the
   default binding **⇧⌘N**, unbound elsewhere today. `AppShell` maps it to the active page's
   preferences, and `MainFlutterWindow.swift` gets a "Show Navigator" item in the View menu,
   beside the existing Output/File View/Dashboard/Recovery toggles, with its checkmark synced
   from `tabs_host.dart` like theirs.
3. **The preference is unchanged.** `navigatorCollapsed` keeps its meaning and its storage; the
   Minimal preset still sets it. What changes is only that a collapsed navigator is visible and
   reversible.

### Consequences

* Good, because the state that produced "History shows nothing" now shows its own name and a way
  back, on the page.
* Good, because the recovery is also a menu item with a checkmark, so the menu bar stops lying
  about a pane the user cannot find.
* Good, because the rail costs 28 pt against a canvas that had the whole width, and returns the
  pane to the width the preferences already remember (`navigatorWidth`).
* Neutral, because the Minimal preset keeps collapsing the navigator: that is what it is for.
* Bad, because every page that supplies a navigator must now supply a name for it. All five that
  do already pass one as `compactNavigation.navigatorLabel` (History "Commits", Branches
  "Branches", Stashes "Stashes", Forge "Items", Worktrees "Worktrees"), so this is a lift of an
  existing value into its own scaffold argument, enforced by the scan test below.
* Bad, because ⇧⌘N is one more reserved chord. It is free today in this app, and a user can
  rebind it in Settings ▸ Keyboard like any other action.
* Neutral, because **no golden changes**: the 48 workspace goldens never set
  `navigatorCollapsed` (`workspace_golden_test.dart:137-142` sets only `inspectorPinned` and
  `taskDockCollapsed`), so none of them renders a collapsed navigator. A new golden for the rail
  is deliberately not added — the widget test asserts its geometry and its label directly.

### Confirmation

* A widget test at wide and standard widths: with `navigatorCollapsed`, the navigator's content
  is absent, the rail is present with the page's name, and a tap restores the pane and writes
  `navigatorCollapsed: false` through `onPreferencesChanged`. **It must fail on the current
  tree** (there is no rail, and nothing to tap).
* A test that ⇧⌘N toggles it on a connected `AppShell`, both directions, asserting the rendered
  navigator rather than the flag.
* A scan test that a page passing `navigator:` to `RepositoryWorkspaceScaffold` also passes a
  label, so a new page cannot reintroduce an unnamed, unreachable pane.
* `flutter analyze` clean, the full suite green, and the goldens regenerated deliberately.
* On the device: on the `ocp-login` tab, History shows the rail, the rail restores the commit
  list, ⇧⌘N toggles it, and the View menu's checkmark follows.

## Pros and Cons of the Options

### Option 1 — rail plus command

* Good, because it fixes both halves of the report: seeing the state, and undoing it.
* Good, because it matches what 0064 F1 already decided for compact width.
* Bad, because it touches the layout, the keymap, the Swift menu and the goldens in one change.

### Option 2 — the rail alone

* Good, because it is the smaller change and needs no Swift or keymap work.
* Good, because it puts the affordance where the confusion is.
* Bad, because the pane stays keyboard-unreachable, and the View menu still says nothing about a
  pane that is hidden — the menu-bar half of the complaint is untouched.

### Option 3 — the command alone

* Good, because it is the smallest change: a keymap entry, a handler and a menu item.
* Bad, because it only helps a user who already knows the command exists. The page still shows an
  empty canvas with no explanation, which is exactly how this was reported as "History is broken".

### Option 4 — drop the collapse from the Minimal preset

* Good, because the reported state becomes unreachable.
* Bad, because it deletes a feature rather than fixing it: a user who wants only the canvas can no
  longer have it, and the preference stays settable from a saved workspace
  (`saved_workspace_actions.dart:303`), so the trap remains reachable by another route.
* Bad, because it leaves the inspector and task dock with the same one-way door.

## More Information

* **How it was diagnosed.** The app's `com.example.remoteMagicGit.plist` was read directly (a
  scratch script, read-only) and the repository's entry showed `preset: minimal`,
  `navigatorCollapsed: true`. The screenshot showed the canvas placeholder across the full page
  width with no filter bar and no rows, which is what a zero-width leading pane renders.
* **Related.** 0064 F1 (compact back bar), 0005 (the adaptive workspace and its panes), 0008
  (the unified menu bar, whose View menu this extends).
* **Out of scope, stated rather than silently skipped.** The inspector (inert) and the task dock
  reuse nothing here beyond the rail widget, which is written so they can adopt it; the Minimal
  preset is unchanged; nothing migrates existing preferences, so the `ocp-login` tab stays
  collapsed until the user reveals it — which is now possible.
* **Implementation:** [0066-PLAN](0066-PLAN-reveal-a-collapsed-workspace-navigator.md).

## Amendment 0066.1 (2026-09-22): the command binds ⌥⌘N, not ⇧⌘N

The decision above states that ⇧⌘N "is free today in this app". **It is not.**
`lib/core/settings/keymap.dart` binds it to `history.branchFrom` ("Branch from selected
commit"), and has since before this record. A sweep of every default binding was run when the
collision surfaced during execution (0066-PLAN, deviation D1); it also shows ⌥⌘ carrying this
app's other view toggles — `⌥⌘S` split diff, `⌥⌘W` ignore whitespace, `⌥⌘X` expanded context —
with ⌥⌘N free.

**Amended decision.** `global.toggleNavigator` binds **⌥⌘N**. Everything else in F-the-command
stands: the same id, the same View-menu item, the same checkmark. `addToggleItem` in
`MainFlutterWindow.swift` grows a `modifiers` parameter (defaulting to the ⇧⌘ every other
toggle uses) so the native item carries ⌥⌘ before the first keymap sync.

The alternatives were considered and rejected at the same time: shipping unbound (the
"recovery without the mouse" driver would be unmet until a user bound it) and moving
`history.branchFrom` (retunes an existing shortcut nobody asked to change).
