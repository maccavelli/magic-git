---
status: "executed"
date: 2026-08-14
verified: 2026-08-20
---
# Implement the hybrid native title bar + context bar

Associated MADR: [0006-MADR-hybrid-native-title-bar-context-bar.md](0006-MADR-hybrid-native-title-bar-context-bar.md)

- Status: **executed.** `RepositoryContextBar` (`lib/features/common/repository_context_bar.dart`) ships and is mounted by `repo_status_view.dart`; the work landed as [0007-PLAN](0007-PLAN-docs-completion-audit.md) Phase 6. The original line below said "ready to execute, gated on live macOS verification" — true when written, stale since. Every step
  below is grounded in the current tree, but the acceptance criteria include
  three things only a running `.app` can answer (§Verification). Do not mark
  this plan done from a green test suite.
- Date: 2026-08-14
- Owner: implementation agent + maintainer visual review
- Written by: [0007-PLAN-docs-completion-audit.md](0007-PLAN-docs-completion-audit.md)
  step 6.1, which is where the codebase findings below were established.

## Goal

Restore the native macOS title bar on the **main** window while keeping the
0005 `RepositoryContextBar` as the first content row, per MADR 0006's chosen
option C.

## Scope

**In scope.** The main window's chrome: the `TitleBarStyle` flip and the two
companion changes it cannot ship without, plus the minimum-size decision that
falls out of adding a third band.

**Out of scope, explicitly.**

* **Secondary windows.** They already use `.titled` with `window.title` and a
  darkAqua appearance (`macos/Runner/SecondaryWindowController.swift:162-197`).
  MADR 0006's consequence that "secondary windows and the hidden-title-bar
  assumption must change together" **overstates the coupling** — only the main
  window hides its title bar. Nothing here touches pop-outs.
* **Native `NSWindow` tabbing.** Foreclosed: each tab owns its own
  `ProviderContainer` inside ONE engine (`tabs_host.dart:337-343`), so native
  tabs would mean one window per tab — a different architecture, not a chrome
  change. The tab strip stays a Flutter row below the title bar, which is what
  the MADR's Decision Outcome already says.
* Giving the title bar its own toolbar controls. The MADR mentions optional
  sidebar/overflow controls; they are a follow-up once the bar exists.

## Findings that shape the work

Established against the tree at the time of writing; re-verify if it has moved.

1. **The main window is ALREADY `.titled`.** The style mask comes from
   `macos/Runner/Base.lproj/MainMenu.xib:334`
   (`titled="YES" closable="YES" miniaturizable="YES" resizable="YES"`).
   `MainFlutterWindow.swift` never touches `styleMask`. Only three properties
   differ, and all three are set from Dart by window_manager's
   `setTitleBarStyle`: `titleVisibility`, `titlebarAppearsTransparent`, and
   `.fullSizeContentView`.
2. **So the flip is one line** — `lib/main.dart:54`. Removing
   `.fullSizeContentView` makes AppKit reserve the bar and drop the content
   origin automatically; no Flutter-side top padding is needed.
3. **The title text is already wired.** `windowTitleProvider`
   (`tabs_host.dart:20-38`) produces `repo (branch) — Magic Git` and pushes it
   through `windowManager.setTitle` on every active-tab change. The bar has
   real content from the first frame.
4. **There is no drag region to build.** A repo-wide search for
   `DragToMoveArea` / `startDragging` returns nothing. Dragging currently works
   only because `.fullSizeContentView` leaves AppKit's transparent title-bar
   view live *over* the tab strip. After the flip, dragging is fully native —
   a fix, not a regression.

## Implementation Steps

### Step 1 — Flip the flag

`lib/main.dart:54`: `titleBarStyle: TitleBarStyle.hidden` →
`TitleBarStyle.normal`.

Alone, this is not shippable. Steps 2 and 3 are not polish.

### Step 2 — Give the window a dark appearance (blocker)

`macos/Runner/MainFlutterWindow.swift`, in `awakeFromNib()` beside the existing
`alphaValue`/`isRestorable` setup:

```swift
// The app is dark-only (AppTheme pins ThemeMode.dark for all three MacosApp
// slots), and the window's appearance has never been set — which did not
// matter while the title bar was hidden. Visible, a user in Light Mode gets a
// light-gray title bar bolted onto a #191A1F app.
self.appearance = NSAppearance(named: .darkAqua)
```

Exact precedent, comment included: `SecondaryWindowController.swift:170-173`.

### Step 3 — Stop double-counting the traffic-light inset (blocker)

`lib/features/app_shell.dart:949`, the `Sidebar`: pass `topOffset: 0`.

macos_ui defaults `Sidebar.topOffset` to `51.0` and spends it as a bare spacer
at the top of the sidebar, explicitly to clear the traffic lights under a
hidden title bar. With a real title bar providing that clearance, the default
inserts 51pt of dead space, pushes `SidebarBranding` down, and desyncs the
sidebar's first item from `ContentArea`'s first row.

### Step 4 — Decide the minimum window size

Three stacked bands at the 640×480 floor: title bar (~28) + tab strip (36, only
at ≥2 tabs) + context bar (46 compact) = 110pt of 480. The content area also
loses the 28pt it previously underlapped.

Preferred mitigation: raise `WindowBoundsStore.minHeight` from 480 to **508**
so *content* keeps its 480. Constraint to respect: it must stay above the
viewer (420×260) and diff pop-out (420×280) floors, which it does. `kMinWindowSize`
in `lib/main.dart:31` derives from those constants, so one edit covers both the
`WindowOptions` and the live `setMinimumSize` call.

Alternative if the maintainer prefers no size change: leave it, and accept the
MADR's own stated "Bad" consequence at the floor. Do not shrink the context bar
to buy the space back without re-running `test/workspace_responsive_test.dart`,
which is the guard for that.

### Step 5 — Correct the now-false comment

`tabs_host.dart:20-24` documents the title as mattering because "the in-window
titlebar is hidden". After this change it is visible; the mechanism is
unchanged but the reason is not.

## Verification

### Automated (necessary, not sufficient)

```sh
flutter analyze
flutter test
```

**Expect zero breakage**, and treat any as a surprise worth understanding:

* The 48 workspace goldens in `test/goldens/workspace/` are **synthetic** —
  `workspace_golden_test.dart` renders a fixture with a hardcoded 52pt bar and
  never mounts `AppShell`, `MacosWindow`, or `TabStrip`. Window chrome cannot
  move those pixels.
* `test/app_shell_test.dart` (the 640×480 sidebar-breakpoint test) and
  `test/adaptive_workspace_layout_test.dart` mount into fixed `SizedBox`es;
  widget tests have no NSWindow, so `TitleBarStyle` is invisible to them.
* `test/workspace_responsive_test.dart` is the guard IF step 4 changes any bar
  height: 3 sizes × 3 text scales, asserting no overflow and a tappable
  `Resolve`.

### Live (the actual gate)

```sh
./build_macos.sh --unsigned --install
```

Then confirm by inspection:

1. The title bar renders **dark**, showing `repo (branch) — Magic Git`.
2. Traffic lights sit in the title bar, clear of Flutter content — not over
   the first tab chip, and not clipped by `SidebarBranding`.
3. The sidebar's first item lines up with the content area's first row (i.e.
   step 3 landed and the 51pt spacer is not doubled).
4. **The Files pane still renders correctly.** This is the highest-risk
   unknown and the reason this plan cannot be signed off from CI:
   `FileView`'s `TransparentMacOSSidebar` + `BlendMode.clear` hole-punch
   (`file_view.dart:460-471`) depends on the `WindowManipulator` vibrancy view,
   and removing `.fullSizeContentView` moves the content-view origin. Whether
   they still align is not statically determinable — screenshot the Files pane
   specifically.
5. Window dragging works from the title bar, and there is no dead strip over
   the tab row.
6. No translucent or unpainted band behind the title bar.
   (`setTitleBarStyle` sets `isOpaque = false` on both branches, and
   `WindowOptions.backgroundColor` is transparent — almost certainly benign
   because Flutter paints an opaque canvas, but it is exactly the class of
   thing only a screenshot settles.)
7. At the minimum window size, the three bands leave a usable content area.

### Confirmation against MADR 0006

The MADR's own criteria: `TitleBarStyle` is visible; traffic lights are
uncovered; the 640×480 case is checked; the title bar does **not** grow a
permanent Fetch/Pull/Push icon row (this plan adds no toolbar at all, so that
holds by construction).

## Rollout and Rollback

**Land this alone**, in its own commit, on a branch — it is the one change in
the 0007 backlog that the test suite cannot validate.

**Rollback is asymmetric, and that is deliberate:**

* Step 1 (`main.dart:54`) is the revert point. Flipping it back restores the
  previous chrome exactly.
* Step 2 (darkAqua) is a **strict improvement** and should stay either way: an
  unset appearance is a latent Light-Mode bug regardless of which title-bar
  style is in force.
* Step 3 (`topOffset: 0`) must revert **with** step 1 — it is only correct
  while a real title bar provides the clearance.
* Step 4 (minHeight), if taken, is independent and safe to keep.

Keep steps 1 and 3 in one commit so that pairing cannot be half-reverted.

**No migrations.** Nothing here changes persisted data. Note one user-visible
consequence with no code change: every previously-saved window frame loses
~28pt of *content* height on first launch after this ships, because
`windowManager` bounds are frame rects.
