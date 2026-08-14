---
status: accepted
date: 2026-08-13
---

# Use a hybrid native title bar with the existing repository context bar

## Context and Problem Statement

Magic Git hides the AppKit title bar (`TitleBarStyle.hidden`) and paints
window chrome in Flutter: sidebar branding, a custom tab strip, and the 0005
`RepositoryContextBar` (one contextual primary action, Back/Forward, Activity,
view options). The 2026-07 ACTION_PLAN deferred a native `ToolBar` /
`MacosScaffold` because it restructures window chrome and is unverifiable
without a live macOS preview. 0004 residual L9 still points at that deferral.

The original ACTION_PLAN sketch assumed an equal-weight fetch/pull/push/stash
icon row. That header no longer exists. Blindly wrapping today’s context bar
in macos_ui `ToolBar` would either restore a toolbar of permanently equal
icons (rejected by 0005) or leave traffic lights, drag region, and the tab
strip fighting a hidden title bar.

The decision to make is:

> Should Magic Git keep all chrome in Flutter, move repository actions into a
> native unified title-and-toolbar, or show a native title bar while keeping
> the 0005 context bar as the first content row?

### Scope

This record chooses the main-window and secondary-window chrome model. It
does not implement the title-bar change, replace Riverpod or `macos_ui`, or
reopen 0005’s contextual primary-action rule.

0004 residuals L1 (empty-undo toast) and L2 (tab middle-click close and dirty
badge) are independent polish and may ship before the chrome work.

## Decision Drivers

* **Native macOS window grammar** — traffic lights, title-bar drag, and
  Mission Control should look like a desktop app, not a borderless Flutter
  surface.
* **0005 continuity** — one contextual primary action; no return to a
  permanently equal Fetch+Pull+Push+Stash icon row.
* **Adaptability** — compact 640×480, standard, wide, and secondary windows
  must keep the primary action reachable.
* **Honesty in pop-outs** — secondary windows expose only actions their
  proxy/session can run.
* **Verifiability** — title-bar integration needs a live macOS look; the
  chosen model must be implementable as one vertical slice.

## Considered Options

* **A. Keep Flutter-only chrome** — leave `TitleBarStyle.hidden` and the
  in-content context bar; only polish traffic-light insets if needed.
* **B. Unified AppKit title-and-toolbar** — show the native title bar, put
  repository actions in macos_ui `ToolBar`, and retire or shrink
  `RepositoryContextBar`.
* **C. Hybrid native title bar + context bar** — show the native title bar
  and traffic lights; keep `RepositoryContextBar` as the first content row;
  keep the tab strip below the title bar.

## Decision Outcome

Chosen option: **“C. Hybrid native title bar + context bar”**, because it
gives native window chrome without undoing the 0005 action model. Window-level
controls (traffic lights, drag region, optional sidebar / overflow) belong in
the title bar. Repository task controls stay in the context bar, where
compact/standard/wide disclosure and the single primary action already work.

### Consequences

* Good, because traffic lights and window drag stop living under Flutter
  branding.
* Good, because Fetch/Pull/Push remain one resolved primary action, not a
  static icon row.
* Good, because the tab strip and context bar keep their current roles and
  tests.
* Neutral, because a live macOS preview is still required before enabling
  the visible title bar.
* Bad, because title bar + tab strip + context bar is three stacked chrome
  bands and must be checked at 640×480.
* Bad, because secondary windows and the hidden-title-bar assumption in
  `main.dart` / Swift must change together.

### Confirmation

* `TitleBarStyle` is visible (or unified) and traffic lights are not covered
  by branding or the tab strip.
* `RepositoryContextBar` remains the repository action surface; the title bar
  does not grow a permanent Fetch+Pull+Push icon row.
* Compact, standard, and wide fixtures still reach the primary action.
* Secondary History / detached Status windows use the same title-bar subset
  and do not offer proxy-unsupported actions.
* L1 and L2 residuals can land independently of the chrome slice.

## Pros and Cons of the Options

### A. Keep Flutter-only chrome

* Good, because it is the lowest implementation risk.
* Neutral, because the context bar already works.
* Bad, because the window still does not behave like a native Mac app.

### B. Unified AppKit title-and-toolbar

* Good, because it is the most conventional macOS toolbar.
* Bad, because it fights 0005’s contextual primary and compact disclosure.
* Bad, because it is the largest rewrite of tabs, context, and pop-outs.

### C. Hybrid native title bar + context bar

* Good, because native window chrome and the 0005 action model coexist.
* Good, because chrome work is a bounded title-bar/inset slice.
* Bad, because stacked chrome needs a live Mac check at the minimum size.

## More Information

* Predecessor residual: L9 in
  [0004-MADR-ui-ux-deep-debug-audit.md](0004-MADR-ui-ux-deep-debug-audit.md)
  and the deferred `ToolBar`/`MacosScaffold` bullet in
  [ACTION_PLAN.md](ACTION_PLAN.md).
* Action-model constraint:
  [0005-MADR-task-centered-adaptive-repository-workspace.md](0005-MADR-task-centered-adaptive-repository-workspace.md)
  §3.
* Current seams: `lib/main.dart` (`TitleBarStyle.hidden`),
  `lib/features/tabs/tabs_host.dart` (tab strip + window title),
  `lib/features/common/repository_context_bar.dart`,
  `lib/features/app_shell.dart` (`MacosWindow`).
