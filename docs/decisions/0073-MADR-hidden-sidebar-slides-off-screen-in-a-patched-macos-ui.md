---
status: "accepted"
date: 2026-09-26
decision-makers: [Maintainer]
consulted: [the 0068-PLAN Phase 5 device gate (2026-09-25), a build of dbd6d1b for comparison, macos_ui source at tag 2.2.2 and at upstream dev dec19cf (unreleased 2.2.3), macos_window_utils 1.9.0 and 1.9.1 source, widget-test reproductions and a prototype in scratch worktrees, the macos_ui contribution guide, CI workflows and merged-PR history]
informed: [Magic Git contributors]
verified: 2026-09-26
---

# Hide macos_ui's sidebar by sliding it off-screen and out of input, fixed upstream and used by Magic Git as a vendored patched copy until released

> **Revision (2026-09-26, before acceptance).** A first draft of this record chose to make
> `AppShell`'s content opaque (option A below). The maintainer then chose to fix the defect in
> macos_ui itself, propose the fix upstream, and use a patched copy in Magic Git until a release
> contains it. The draft was never accepted or committed. Its analysis is kept below as the
> context; its choice became option A.

## Context and Problem Statement

At the 0068-PLAN Phase 5 device gate
([0068-PLAN-commit-wait-legibility-and-inline-button-alignment.md](0068-PLAN-commit-wait-legibility-and-inline-button-alignment.md)),
narrowing the window to its 640 pt minimum left the sidebar's items (Repository, History, …, the
session card) painted **underneath** the full-width content, on the sidebar's translucent native
material. The ghost follows the live selection, so it is not a stale frame. A screen capture shows
the same as a window capture, and clicks on the ghost reach the content. At that width the
toolbar's "Toggle sidebar" raised its tooltip and changed nothing.

It predates the current work: a build of `dbd6d1b`, from before any 0068 code, shows it too. The
window's minimum width (`WindowBoundsStore.minWidth`, 640, `lib/core/providers/app_providers.dart:100`)
is below the sidebar's `windowBreakpoint` (760, `lib/features/app_shell.dart:1097`), so every user
who narrows the window far enough sees it.

**Mechanism.** macos_ui's `MacosWindow` lays out a `Stack`, painted in this order: the window
background at `left: visibleSidebarWidth`, then the start sidebar, then the content at
`left: visibleSidebarWidth` (tag 2.2.2, `lib/src/layout/window.dart:244-386`; `dev`, `:241-389`).
When the sidebar is hidden, `visibleSidebarWidth` becomes 0 and the content slides to the left
edge, but **the start sidebar has no `left` and stays at 0**. It is still painted, hit-testable,
focusable and in the semantics tree, beneath the content. The **end** sidebar does not have this
defect: it sits at `left: width - visibleEndSidebarWidth` (`dev`, `window.dart:482`), so hiding it
slides it off the right edge. The start sidebar lacks the same treatment.

The ghost shows through wherever the content leaves pixels unpainted. macos_ui's own
`MacosScaffold` happens to hide it, because it paints an opaque background (`scaffold.dart:99`).
`AppShell` uses a bare `ContentArea` (`app_shell.dart:1162`, a `ConstrainedBox` only), as it has
since the first commit (`2d8a357`).

A start sidebar is hidden three ways, and each leaves it in place:
* the window at or below `Sidebar.windowBreakpoint`;
* `MacosWindowScope.toggleSidebar()`;
* dragging it narrower than its `minWidth`, which closes it (`window.dart:445-447`).

**Measured** (a widget test with the app's sidebar geometry, a solid red sidebar, reading the
pixel at (100, 300)):

| Window | Content | Sidebar | Pixel |
|---|---|---|---|
| 1200 pt | `ContentArea` | shown | red (beside the content) |
| 640 pt | `ContentArea` | hidden by the breakpoint, still laid out at (0, 51)–(240, 600) | **red** |
| 900 pt | `ContentArea` | hidden by `toggleSidebar()` (`isSidebarShown == false`) | **red** |
| 640 pt | an opaque `ColoredBox` | hidden by the breakpoint | `#1E1E1E` (covered) |

**The native material.** On macOS, `TransparentMacOSSidebar` places an `NSVisualEffectView` behind
the sidebar through macos_window_utils 1.9.1. It repositions that view only when its widget
rebuilds, or when a resize relay fires
(`visual_effect_subview_container_with_global_key.dart:149-193`). Moving the sidebar's Flutter
widget does not by itself move the native view, so a fix that only moves the widget could leave
the grey material behind at x = 0.

**The toggle.** Magic Git's `RepositoryContextBar` shows "Toggle sidebar" only at its compact size
class (`repository_context_bar.dart:115`). macos_ui never shows the sidebar at or below the
breakpoint (`canShowSidebar = _showSidebar && !isAtBreakpoint`), so below 760 pt the button can
never act.

**Upstream state.** macos_ui 2.2.2 (2025-10-19) is the latest release, and it is byte-identical to
tag `2.2.2`. `dev` carries an unreleased 2.2.3 (#587/#588) that rewrites the sidebar's background
painting in the same block. No upstream issue or pull request covers this defect. Contributions
target `dev`, use conventional commits, bump the version, update `CHANGELOG.md`, and pass
`flutter analyze --fatal-infos`, `dcm analyze` and `flutter test` on the stable channel
(`CONTRIBUTING.md`, `.github/workflows/`).

**The question:** where and how is the hidden sidebar fixed, so that it is invisible and inert by
every route, and how does Magic Git get the fix before macos_ui releases it?

## Decision Drivers

* **A hidden sidebar is invisible and inert** (no paint, hit test, focus or semantics), by every
  hiding route, native material included.
* **Fix the defect where it lives.** The start sidebar lacks the positioning the end sidebar has;
  every macos_ui app with non-opaque content is exposed.
* **Upstream-acceptable:** it follows the project's standards, targets `dev`, and changes no
  public API.
* **Magic Git ships exactly what it tested.** A patch on the 2.2.2 we already use, and nothing
  else, until an upstream release contains the fix.
* **Reproducible builds** on any machine, offline, and independent of the fork staying up.
* **Controls tell the truth:** "Toggle sidebar" is not offered where it cannot act.

## Considered Options

* A. Make `AppShell`'s content area opaque (the first draft's choice).
* B. Patch macos_ui so a hidden start sidebar slides off-screen and out of input like the end
  sidebar, propose it upstream against `dev`, and vendor a 2.2.2 backport into Magic Git until a
  release contains it.
* C. Patch macos_ui only to stop painting the hidden sidebar (`Offstage`/`Visibility`), without
  the slide.
* D. Consume a git dependency on the fork, instead of a vendored copy.
* E. Never hide the sidebar (breakpoint below the window minimum, no toggle).

## Decision Outcome

Chosen option: **"B. Patch macos_ui so a hidden start sidebar slides off-screen and out of input,
propose it upstream, and vendor a 2.2.2 backport into Magic Git"**, because it fixes the defect in
the component that has it, for every hiding route and every app, matches the behaviour macos_ui
already gives the end sidebar, and lets Magic Git ship 2.2.2 plus exactly this change,
reproducibly, until upstream releases it. The toggle rule is kept from the first draft.

### What B means

1. **In macos_ui (the upstream patch, against `dev`):**
   * the start sidebar is positioned like the end sidebar: at `left: visibleSidebarWidth -
     _sidebarWidth`, animated with the content, so hiding slides it off the left edge;
   * while it is not shown, its subtree is excluded from hit testing, focus traversal and
     semantics (`IgnorePointer`, `ExcludeFocus`, `ExcludeSemantics`);
   * the native visual-effect view follows the sidebar. `MacosWindow` gives its
     `TransparentMacOSSidebar` a `VisualEffectSubviewContainerResizeEventRelay`, and calls the
     relay's `onResize()` from the sidebar's `AnimatedPositioned.onEnd`. The relay's own
     documentation names this case: position changes "without triggering a rebuild". The result
     is confirmed on a device;
   * tests in `test/layout/window_test.dart` cover all three hiding routes, reading semantics from
     the live tree (`find.semantics.byLabel`). `CHANGELOG.md` gets a `[2.2.4]` section and
     `pubspec.yaml` goes to 2.2.4, as every merged pull request in the project's history has done;
   * no public API changes.
2. **In Magic Git (until a release contains it):**
   * the same change, backported onto tag `2.2.2`, is vendored as `third_party/macos_ui` with
     macos_ui's MIT `LICENSE`, and used through `dependency_overrides` with a `path`;
   * `analysis_options.yaml` excludes `third_party/**`, so the vendored package is held to its own
     standards, not Magic Git's stricter ones;
   * when macos_ui releases the fix, the override and the directory are removed and the
     dependency moves to that release.
3. **In Magic Git's shell, independent of the patch:** "Toggle sidebar" is offered only while the
   window is wider than the sidebar's breakpoint. At or below it, the compact context bar does not
   show the button, and the menu item is disabled through MADR 0008's derived availability.

### Consequences

* Good, because a hidden start sidebar is gone from the screen and from input by every route, in
  every macos_ui app, once released.
* Good, because the start sidebar now behaves like the end sidebar, and hiding it slides it away,
  as a macOS sidebar does.
* Good, because Magic Git ships the tested 2.2.2 plus one reviewed change, with no network
  dependency on the fork.
* Good, because the one control that could never act is no longer offered.
* Neutral, because Magic Git's pages still leave pixels unpainted. That is harmless once nothing
  lies beneath them.
* Bad, because Magic Git carries a vendored package until upstream releases the fix, and has to
  re-apply the patch if it moves to another macos_ui version first.
* Bad, because the change is visible in motion: the sidebar now slides out instead of staying
  put. Maintainers may prefer other animation choices, and the pull request should show both.
* Bad, because the native-view behaviour is not settled by reading the code. It needs a device
  check, and possibly a second change in the patch.

### Confirmation

* **Upstream, in the fork:** new widget tests for the breakpoint, toggle and drag-close routes.
  Each asserts that after the animation the hidden sidebar lies wholly off-screen, cannot be hit,
  holds no focusable node, and contributes no semantics, and that a shown sidebar is unchanged.
  Each is seen to fail on unpatched `dev`, and each fails again under a mutation that removes the
  `left` or the exclusions. `flutter analyze --fatal-infos`, `dart format` and `flutter test` are
  clean, and `dcm analyze` is clean where it can be run.
* **Magic Git:** the pixel reproduction, run against the real shell with the vendored package,
  fails on unpatched 2.2.2 and passes with the patch, at 640 pt and at 900 pt toggled off. The
  toggle-availability rule has its own test. The full suite and the 48 goldens stay unchanged.
* **Device:** at 640 pt the sidebar region shows the page and no native material; at 900 pt,
  toggling off slides the sidebar away cleanly; a drag-close does the same.
* **Upstream acceptance** is not claimed until the maintainers merge it. The PR is opened only
  after the maintainer of Magic Git reviews it.

## Pros and Cons of the Options

### A. Make `AppShell`'s content area opaque

* Good, because it is one app-side change, and it measurably hides the ghost.
* Bad, because the hidden sidebar stays hit-testable, focusable and in the semantics tree beneath
  the content, and its native material stays behind.
* Bad, because it fixes one app, while every macos_ui app with non-opaque content keeps the
  defect.

### B. Slide off-screen and out of input, upstream plus vendored backport

* Good, because it covers every hiding route, input as well as paint, and matches the end
  sidebar.
* Good, because it is proposed to the project that owns the code.
* Neutral, because it changes the hide animation.
* Bad, because of the vendoring cost until release, and the device check on the native view.

### C. Stop painting the hidden sidebar without the slide

* Good, because it is a smaller diff.
* Bad, because the sidebar vanishes abruptly while the content slides over its place.
* Bad, because it treats the start sidebar differently from the end sidebar.

### D. A git dependency on the fork

* Good, because nothing is copied into Magic Git.
* Bad, because every build fetches from GitHub, and depends on the fork and the pinned commit
  staying reachable.

### E. Never hide the sidebar

* Good, because nothing is ever beneath the content.
* Bad, because at 640 pt the content gets only 400 pt, and MADR 0064's compact layout loses its
  width.

## More Information

### Evidence

* Device, 2026-09-25: the installed build of `73b6257` at 640 pt, on the Repository and History
  pages, captured by window and by screen. The same on a build of `dbd6d1b` (1.9.2.6).
* Reproduction: the table above, a widget test in a scratch worktree of `a31bbb9`. Two harness
  failures were fixed before any result was read: the accent-colour channel (stubbed as
  `add_existing_repo_sheet_test.dart` does) and a pending zero-length timer from
  macos_window_utils.
* Source: tag `2.2.2` equals the published package byte for byte (`lib/` and `pubspec.yaml`
  compared). `dev` differs from it by two commits.
* Not established: at compact width during the gate, ⌘2 did not switch to History. It was seen
  once, with the ghost present, and is checked on the device before any claim is made.

### Upstream state and proof of the design (review of 2026-09-26)

* **Branches.** `upstream/dev` is `dec19cf` (2026-08-22); `upstream/stable` is the 2.2.2 release
  merge (2025-10-19). Tag `2.2.2` is an ancestor of both, and `dev` is two commits ahead of
  `stable`. No pull request is open.
* **How changes land.** Each merged pull request bumps the version and adds its own
  `CHANGELOG.md` section: #579 → 2.2.1 and #585 → 2.2.2, both merged 2025-10-13 before the
  single 2.2.2 release, and #588 → 2.2.3. #588 touched exactly the files this patch will
  (`CHANGELOG.md`, `lib/src/layout/window.dart`, `pubspec.yaml`, `test/layout/window_test.dart`).
  It came with an issue (#587), was approved by a contributor, reviewed by Copilot, and merged by
  the owner, **nine months after it was opened** (2025-11-20 → 2026-08-22). The vendored copy
  may therefore be needed for months.
* **CI.** The analysis, test and pana workflows run on `pull_request`, on `ubuntu-latest`. No
  pull-request run from a fork has happened since 2025-10 (#588 has none), so fork pull
  requests appear to wait for a maintainer's approval to run. Every gate is therefore proven
  locally, and the tests must pass on Linux: they cannot rely on macOS.
* **Baseline** (Flutter 3.47.2 stable, the version Magic Git pins): `flutter analyze
  --fatal-infos .` clean. `flutter test`: 10 pre-existing failures, all "lerps from … to …" in
  five `test/theme/` files (`MacosColor` expected, `Color` produced). Tag 2.2.2 fails the same 10.
  `dart format` would change two files already on `dev`. Running the tools under 3.47.2 rewrites
  `pubspec.lock`, `example/pubspec.lock` and `analysis_options.yaml`, so commits stage only the
  intended files.
* **macos_window_utils.** 1.9.0 (macos_ui's lock file) and 1.9.1 (Magic Git's) have identical
  Dart `lib/`. The only difference is an `NSToolbar` identifier in Swift. The relay exists in both.
* **Measured on unpatched `dev`** with a sidebar probe (an opaque `ColoredBox` that is labelled
  and focusable) and content that paints nothing. A shown sidebar is the control, and it is
  hit-testable, focusable and present in semantics:

  | Route | Probe rect | Hit-testable | Focusable | In the live semantics tree |
  |---|---|---|---|---|
  | shown (control) | (0, 51)–(150, 600) | yes | yes | yes |
  | breakpoint | (0, 51)–(150, 600) | **yes** | **yes** | **yes** |
  | `toggleSidebar()` | (0, 51)–(150, 600) | **yes** | **yes** | **yes** |
  | drag-close | (0, 51)–(100, 600) | **yes** | **yes** | **yes** |

* **With a prototype of the design** (in a scratch worktree, never committed), on `dev` and again
  on tag 2.2.2: every hidden route gives a rect ending at x = 0 (−150…0, or −100…0), not
  hit-testable, not focusable, and absent from the live tree. The control is unchanged.
  `window_test.dart` passes (+16), and the full suite fails exactly the 10 baseline tests. The
  analyzer is clean. One instrument trap was found: `find.bySemanticsLabel` still reports the
  label after an exclusion changes (it reads a render object's last node). The live-tree walk and
  `find.semantics.byLabel` both report it absent, so the tests use the latter.
* **In Magic Git** (a scratch worktree): with the 2.2.2 backport vendored and overridden, the
  pixel reproduction passes (the probe is at −240…0, and the pixel is the window background
  `#F6F6F6`). The lock file changes only macos_ui's source. Without a `third_party/**` exclude
  the analyzer reports 82 issues, all in the vendored copy. The vendored `README.md` fails
  `docs_records_test` on two anchors upstream never fixed (`#dialogs`, `#slider`), so it is not
  vendored: a path dependency does not need it.

### Plans

* `0073-PLAN-macos-ui-hidden-sidebar-upstream-patch.md`: the patch, in the fork, against `dev`.
* `0073-PLAN-vendor-patched-macos-ui-and-toggle-rule.md`: the 2.2.2 backport, vendoring and the
  toggle rule in Magic Git.

### Relation to other records

* [0064-MADR-workspace-reachability-feedback-and-log-fidelity.md](0064-MADR-workspace-reachability-feedback-and-log-fidelity.md):
  the compact navigation this defect sits under.
* [0068-MADR-commit-wait-legibility-and-inline-button-alignment.md](0068-MADR-commit-wait-legibility-and-inline-button-alignment.md):
  the gate where it was found; 0068 does not grow.
* [0008-MADR-unified-repository-chrome.md](0008-MADR-unified-repository-chrome.md): the derived
  menu-item availability the toggle rule uses.
