---
status: "accepted"
date: 2026-09-22
decision-makers: [Maintainer]
consulted: [0063-PLAN-adopt-impeller-renderer-on-macos.md (deviations D2 and D3), 0063-GATES-impeller-on-device.md, 0005-MADR-task-centered-adaptive-repository-workspace.md, 0005-PLAN-task-centered-adaptive-repository-workspace.md, 0060-REPORT-drag-and-drop-engine-feasibility.md, widget-test probes at 600/1000 px, on-device runs on Impeller and a Skia testbed, cli/cli source and issues, gh 2.99.0]
informed: [Magic Git contributors]
verified: 2026-09-22
---

# Make compact panes reachable, keep drop targets visible under the drag image, show the Output view on every page, strip escape codes from CI logs, and fix the two defects behind the suite's flaky tests

## Context and Problem Statement

The on-device gate for Impeller
([0063-GATES](../reports/0063-GATES-impeller-on-device.md)) surfaced four user-visible defects.
A Skia testbed built from the same commit reproduced every one of them identically, so none is a
renderer effect. They were recorded as deviation D3 of
[0063-PLAN](0063-PLAN-adopt-impeller-renderer-on-macos.md), and the maintainer asked for **one**
decision record covering all four.

The four share a theme, **what the user can reach and see**, but each has its own root cause.
They are written up as one decision with several parts (§"Decision Outcome"). That departs from
MADR's usual one-choice-per-record, deliberately, at the maintainer's request.

**Two parts were added later (F5 and F6).** While this record was being planned, two existing
tests failed intermittently under full-suite load, on the untouched tree as well. The maintainer
asked for them to be investigated and brought into this record's scope. The investigation found
one real product defect (F5) and one test that measured the wrong thing (F6). Both are fixed
here, and they land first, because every other part's full-suite gate depends on a suite that
doesn't flake.

### F1: Compact-width panes trap the user

* **The width classes.** `WorkspaceSizeClass.fromWidth` gives compact below 720, standard below
  1200, and wide otherwise. The width measured is the panel's content width
  (`lib/features/common/repository_workspace_models.dart:15-28`).
* **Compact shows one pane.** `AdaptiveWorkspaceLayout` shows either the navigator or the canvas
  and unmounts the other (`lib/features/common/adaptive_workspace_layout.dart:210-218`).
* **Each page derives the active pane from its selection**, so a selection always means the
  canvas:
  * History: `lib/features/history/history_view.dart:1666-1671`
  * Stashes: `lib/features/stash/stash_view.dart:458-463`
  * Branches: `lib/features/branches/branches_view.dart:630-636`
  * Forge: `lib/features/forge/forge_workspace.dart:118-124`
  * Worktrees passes nothing, so the scaffold's default applies:
    `lib/features/worktrees/worktrees_view.dart:817-847` and
    `lib/features/common/repository_workspace_scaffold.dart:78-82`.
* **Focus then falls outside the panel.** Tapping a row requests focus on the list's focus node
  (`history_view.dart:326-331`). That node lives in the navigator (`history_view.dart:2113-2118`)
  and is unmounted on the next build, so primary focus falls to the route's `FocusScope`.
  `PanelShortcuts` sees key events only from focused descendants
  (`lib/features/common/panel_shortcuts.dart:131-147`), so every panel shortcut goes dead: ⌘F, ⌘=,
  Esc, and the arrow keys.
* **Measured.** Widget-test probes at 600 px, each with a passing control at 1000 px, found the
  trap on four of the five navigator pages:

  | Page | What happened at 600 px |
  |---|---|
  | History | Zoom stayed at 1.0 after ⌘=, and Esc did nothing |
  | Stashes | Esc did nothing, and ↓ went into the canvas |
  | Branches | The page's only `PanelShortcuts` lives inside the navigator (`lib/features/branches/branch_navigator.dart:817-828`) and unmounts with it, so every Branch shortcut and menu item goes dead |
  | Forge | Esc did nothing; the only way out was leaving the page |
  | Worktrees | The list never appears at all: the page shows "Select a worktree…" with nothing to select from |

  On device (0063-GATES G5), a 900 pt window gave the same result on Impeller and on Skia.
* **This contradicts the design.** The adaptive-workspace MADR set compact to "one navigator or
  canvas at a time when necessary"
  ([0005-MADR](0005-MADR-task-centered-adaptive-repository-workspace.md), line 355). Its plan's
  exit criterion requires that "the navigator, canvas, and primary action are reachable"
  ([0005-PLAN](0005-PLAN-task-centered-adaptive-repository-workspace.md), lines 489-490). No
  mechanism for getting back to the navigator was ever specified or built. The trap arrived with
  `e5631c5` (2026-08-13), on top of the adaptive engine from `20f893b`.

### F2: The drag image hides the drop target under the pointer

* **The drag image.** Since `f8b4a9d` (2026-07-16) the in-app drag image is a snapshot of the
  source row:
  * up to 420 px wide (`lib/features/dnd/drag_cell.dart:19`);
  * the full height of the source row;
  * anchored at the grab point, so the pointer is always inside it (`_anchor`,
    `lib/features/dnd/drag_item.dart:192-201`);
  * about 89% opaque: a `0xF2` fill (`drag_cell.dart:41`) times `Opacity(0.94)`
    (`drag_cell.dart:177`).
* **The hover cue.** A nav-rail row's hover state changes only its background, from green at 16%
  alpha (eligible) to 32% (hovered) (`lib/features/dnd/nav_rail.dart:100-104, 144-149`).
* **Measured on device (0063-GATES G8, identical on both renderers).**
  * The hovered row renders correctly: mean RGB about (59, 90, 64), against about (50, 66, 55) for
    eligible rows.
  * With a left-edge grab, the drag image covers the hovered row, which then measures
    (62, 89, 123), the drag image's own colour.
  * A widget probe measured the drag image covering 54.7% of the hovered row, or 100% when the
    grab is at x = 300.
* **The design claims otherwise.** The code comments say the translucency keeps "drop targets
  readable" (`drag_cell.dart:38-41`). At 89% opacity the 16%-vs-32% difference comes through at
  about 1.7%.
* **Other targets are hidden the same way.** Branch rows (`branch_navigator.dart:1482-1486`) and
  the staging banner (`lib/features/dnd/staging_drop_banner.dart:52-56`) use the same pattern.

### F3: The Output view exists on one page, but everything behaves as if it were global

* **Where it's built.** The only `OutputView` is inside the Repository page
  (`lib/features/repository/repo_status_view.dart:1896-1900`, reading `outputLogProvider` at
  `:1576-1580`). Pages sit in an `IndexedStack` (`lib/features/app_shell.dart:1164-1168`), so from
  any other page the view is offstage or has never been built.
* **What treats it as global.**
  * The command: the keymap handler (`app_shell.dart:910-914`), the native menu
    (`lib/features/tabs/tabs_host.dart:307-311`) and the palette
    (`lib/features/common/command_palette.dart:440-447`). The native menu item is always enabled.
  * Callers that "reveal the transcript" with `setVisible(true)`:
    * Clone: `lib/core/workspace/clone_controller.dart:236-242`
    * The environment-health installs:
      `lib/features/settings/environment_health_sheet.dart:105-109`
  * The add-worktree sheet's own copy says "Output appears in the Output view"
    (`lib/features/worktrees/add_worktree_sheet.dart:673-677`).
  * History, Branches, Stashes and Worktrees all write to the log.
* **Measured on device (0063-GATES G6).** Toggling from History flipped "Show Output View" in the
  View menu, and nothing appeared.
* **This was never a decision.** The Repository-only mount dates from the initial commit
  (`2d8a357`). The help book already describes the view as a "docked command log under the
  Repository canvas" (`macos/Runner/help_book.json`).

### F4: GitHub job logs show raw escape codes

* **How the log is fetched and shown.** `GhService.runJobLog` runs `gh run view --job <id> --log`
  and returns its stdout unchanged (`lib/core/github/gh_service.dart:746-757`). The view shows it
  as one `SelectableText` (`lib/features/github/run_jobs_view.dart:156-160`).
* **What arrives.** A byte-level capture of job 104212484924 (gh 2.99.0) contains no ESC (0x1B)
  bytes. Instead it has the **literal caret text** `^[[36;1m … ^[[0m`.
* **Where that comes from.** gh has done this since v2.92.0 as a security fix: PR #13272,
  "Fix log terminal injection", which uses go-gh's `asciisanitizer`. The upstream issue about
  unreadable logs (cli/cli#13434) is open, and all three fix PRs were closed unmerged.
* **Two forms to handle.** A host with an older gh sends real ESC bytes, and the app runs whatever
  gh the connected host has.
* **Two more kinds of noise.** Every line carries gh's `<job>\t<step>\t` prefix; in both logs
  sampled the step was always `UNKNOWN STEP`. The first line also carries a UTF-8 BOM (U+FEFF).
* **A naive fix corrupts real content.** Applying the full ECMA-48 pattern to the caret form eats
  legitimate script text: `grep -E '^[[:digit:]]+$'` becomes `grep -E 'igit:]]+$'`.
* **No reusable code.** There is no escape handling anywhere in `lib/` or `test/`.

### F5: Every SSH connection uses the slowest cipher dartssh2 has

* **The symptom.** `test/ssh_live_transport_test.dart`, "bulk transfer completes with the health
  monitor armed", sometimes timed out at 2 minutes under full-suite load, followed by "SSH
  transport is not ready yet: echo ok". On its own it passed, but took 1:25–1:59 of its 2:00.
* **Where the time goes.** The test streams 100 MiB (`dd … count=100`) from a real loopback
  `sshd` through the product's `SSHClientManager` and `SSHCommandExecutor`. A probe measured a
  flat **1.16 MiB/s** throughout, 86 s in all, with 0 health-monitor kills.
* **Why.** dartssh2 3.1.0 made AES-GCM its first-choice cipher, and the app passes no
  `SSHAlgorithms`, so every client negotiates `aes256-gcm@openssh.com`. Supporting facts:
  * the app's single `SSHClient(` construction is at `lib/core/ssh/ssh_client_manager.dart:886`;
  * [0013-MADR](0013-MADR-prefer-dartssh2-v3-over-dartssh3.md) chose the library defaults
    explicitly (line 205: "Leave algorithm defaults alone … 3.1.0 defaults become AES-GCM-first
    automatically");
  * dartssh2 runs AES-GCM on pointycastle's pure-Dart GCM, whose GHASH is bit-serial (128
    shift/xor rounds per 16-byte block), and it builds a new GCM cipher for every packet.
* **Measured on the same machine and library, 16 MiB each:**

  | Cipher | Rate |
  |---|---|
  | aes256-gcm | 1.16 MiB/s |
  | chacha20-poly1305 | 29.9 MiB/s |
  | aes128-ctr | 21.4 MiB/s |

* **The slow cipher also starves timers.** Decryption is slower than the socket, and `dart:io`
  keeps re-reading a socket that still has bytes available in a single microtask chain. So during
  a bulk read **no timer fires**: the probe saw a gap of 18.7 s idle and 91 s under load. That
  covers the health monitor's pings, command timeouts, and the test's own `Timeout`, which is why
  the failure was reported late.
* **In the app (inferred, not measured).** The app decrypts on the isolate that owns the socket,
  which is the UI isolate. Any large read, such as a big diff, log or clone transcript, would stall
  timers, and probably frames, for its duration.
* **"Not ready yet" is a consequence, not a cause.** When the test times out, `tearDown`
  disconnects the manager (`_client = null`) while the test body is still running, so its final
  `echo` finds no client.
* **Reproduced on demand** on the unmodified tree by running the test at background priority:
  exit 1, timeout.

### F6: A coalescer test measures machine load, not the coalescer

* **The symptom.** `test/coalescer_test.dart`, "a tight burst does not rebuild the timer per
  event", sometimes failed under full-suite load with `Expected: a value less than <50> /
  Actual: <68>`.
* **What the test measured.** It checks that `signal()` doesn't rebuild a Timer per event, but it
  measures that with a real `Stopwatch` against a 50 ms wall-clock budget for a 20,000-event
  burst. How long that loop takes depends on how busy the machine is.
* **Reproduced.** With 40 busy processes the old test failed **5 of 8** runs, with `Actual` values
  of 50–291.
* **The product is correct.** `Coalescer.signal()` reads time only through its injected clock,
  and rebuilds a timer only when the target moves by more than `rescheduleTolerance`
  (`lib/core/git/coalescer.dart:93-98`).

## Decision Drivers

* **Reachability.** Every pane and every primary action must stay reachable at every width, by
  mouse and by keyboard (0005-PLAN Phase 3 exit; MADR §9 "pane switching" and "Escape
  layering").
* **Honest feedback.** A drop target under the pointer must visibly say "this one", and a command
  that reports success must have a visible effect.
* **Fidelity.** Log text must read as the author wrote it: no terminal control debris, and no
  mangling of legitimate `^[` text.
* **Root causes, one owner each.** Fix each defect at the layer that owns it, as the house rule
  requires: the scaffold owns compact navigation, the drag system owns drag feedback, the shell
  owns global chrome, and the service layer owns parsing.
* **Tests that reproduce the failure.** Each fix is pinned by a test that fails on today's tree
  through real input: real key events, real drag gestures, real widget trees. That rules out
  provider-state tests and shortcut tests that call the binding directly. The shortcut suite, for
  example, calls bindings directly (`test/keyboard_shortcuts_test.dart:37-64`), which is exactly
  why it never caught F1.
* **Blast radius.** Prefer mechanical, contained changes, and keep existing designs where they
  are sound: grab-point anchoring at pickup, and the adaptive width classes.

## Considered Options

**F5: SSH cipher**

* **F5-A.** Prefer `chacha20-poly1305@openssh.com` in the product's algorithm list, keeping
  AES-GCM next for servers that don't offer it.
* **F5-B.** Fix AES-GCM upstream: a table-driven GHASH in pointycastle, and a cipher cached per key
  in dartssh2.
* **F5-C.** Restructure the bulk test so it paces its data and asserts the health monitor's probes.
* **F5-D.** Move SSH decryption off the UI isolate.

**F6: coalescer test**

* **F6-A.** Count Timer constructions on simulated time instead of timing the loop.
* **F6-B.** Inject a timer factory into `Coalescer` and count calls to it.
* **F6-C.** Default `Coalescer`'s clock to `clock.now` from `package:clock`.

**F1: compact navigation**

* **F1-A.** The scaffold owns compact page state, shows a visible back bar, handles Esc and ⌘[, and
  hands focus off when panes switch.
* **F1-B.** A scaffold back bar and an Esc handler that clears the page's selection, with the
  active pane still derived from the selection.
* **F1-C.** Keep the navigator mounted but hidden (`Offstage` / `IndexedStack`), so its focus
  node survives.

**F2: drag feedback**

* **F2-A.** A hover-aware drag image: over an accepting target it becomes a compact chip offset
  from the pointer, and the hovered target also gets a stronger cue.
* **F2-B.** Anchor the drag image at the pointer, as before `f8b4a9d`.
* **F2-C.** Fade the drag image while it's over a target.
* **F2-D.** Targets draw a highlight ring above the drag image, through their own overlay entry.

**F3: Output view scope**

* **F3-A.** One Output view, mounted by the shell below every page.
* **F3-B.** Keep it on Repository, and make the command and every `setVisible(true)` caller
  switch to the Repository page first.
* **F3-C.** Make the command Repository-only (menu item disabled elsewhere), and give other pages
  a separate transcript surface.

**F4: CI log text**

* **F4-A.** A pure sanitizer in the service layer: strip real ESC sequences, a *narrow* caret SGR
  and EL form, a prefix identical on every line, and the BOM.
* **F4-B.** F4-A, plus parse SGR into coloured `TextSpan`s.
* **F4-C.** Fetch raw bytes with `gh api --allow-escape-sequences`, then parse.

## Decision Outcome

Chosen: **F1-A, F2-A, F3-A, F4-A, F5-A and F6-A.** Each fixes its defect at the layer that owns
it, is pinned by a test that fails on today's tree, and leaves the sound parts of the existing
designs in place.

### F5: Prefer ChaCha20-Poly1305 (F5-A)

* **The change.** `SSHClientManager` passes one `static const SSHAlgorithms`, with this cipher
  order:

  `chacha20-poly1305@openssh.com`, `aes256-gcm`, `aes128-gcm`, `aes256-ctr`, `aes128-ctr`,
  `aes256-cbc`, `aes128-cbc`.

  That is the same set dartssh2 offers by default, reordered. Nothing else changes: kex, host key
  and MAC stay at the library defaults.
* **Why it is safe.**
  * Both ChaCha20-Poly1305 and AES-GCM are AEAD, and strict kex (the Terrapin mitigation) applies
    to both.
  * ChaCha20-Poly1305 is OpenSSH's own first choice.
  * AES-GCM remains second, for servers that don't offer ChaCha20, such as FIPS-mode hosts.
* **This supersedes one clause of
  [0013-MADR](0013-MADR-prefer-dartssh2-v3-over-dartssh3.md):** the "Leave algorithm defaults
  alone" row, for the cipher order only. The rest of that row stands: no legacy
  `dh-group1-sha1`, `hmac-md5` or truncated HMAC, and CTR and CBC are not pinned ahead of the AEAD
  ciphers. 0013 is annotated to point here; its decision is not rewritten.
* **The test.** A new test, `test/ssh_cipher_negotiation_live_test.dart`, reads the cipher that
  `sshd` actually negotiated from its own DEBUG1 log. Every client must show
  `chacha20-poly1305@openssh.com`. It asserts no timing, so it can't flake, and it refuses to pass
  on an empty log.

### F6: Count timers, not milliseconds (F6-A)

* **The rewrite.** The flaky test runs under `fakeAsync` with an injected clock and a Zone
  `createTimer` hook. It asserts the exact number of Timers built for 20,000 events one
  microsecond apart, which is **3**, and the exact moment the single fire lands, including the
  "never late, at most the tolerance early" bounds.
* **Why it's stricter.** The old test checked only a time budget. The new one pins the rebuild
  count, which it derives from `rescheduleTolerance`, plus the fire time. The product code does not
  change.

### F1: Compact navigation owned by the scaffold (F1-A)

* **API.** `RepositoryWorkspaceScaffold` gains an optional `compactNavigation` parameter, a value
  type with five fields:
  * `navigatorLabel`: a string such as "Commits", "Stashes", "Branches", "Items" or "Worktrees";
  * `hasSelection`: a bool;
  * `showCanvas`: a bool, owned by the page;
  * `onShowNavigator`: a callback. It is deliberately not named `onBack`:
    `test/repository_chrome_contract_test.dart:230-241` forbids screens from passing `onBack:`,
    because Back and Forward belong to the context bar's history. Returning to the list is a
    different action;
  * `navigatorFocusNode`: the list's focus node, optional.

  Pages stop deriving the compact pane from the selection alone. The effective pane is the
  **canvas when `hasSelection && showCanvas`, otherwise the navigator.**
* **Which inputs move between panes:**
  * a row tap sets `showCanvas = true`, and so does plain Enter wherever Enter isn't already
    bound. Branches keeps Enter = check out at every width, so there its canvas opens on a row
    click or a palette/Back restore;
  * Back clears it and **keeps the selection**, as a collapsed split view does;
  * arrow keys inside the list change the selection without switching panes, which fixes list
    navigation destroying itself on the first ↓ in compact.
* **The back bar.** In compact, with the canvas showing, the layout adds a single back bar above
  the canvas: "‹ \<navigatorLabel\>". It is built from the house's standard `InlineActionButton`.
* **The keyboard.** The canvas region is wrapped in a layout-owned `Focus` whose `onKeyEvent`
  treats **Esc** and **⌘[** as Back, but only when no descendant handled the key first (MADR §9
  Escape layering).
* **Focus handoff.**
  * When the canvas appears, the layout moves focus to its own canvas focus node, after the frame.
    That node sits below the page's `PanelShortcuts`, so panel shortcuts keep working.
  * On Back, it requests `navigatorFocusNode`.
* **Per-page changes.**
  * **Branches:** move `PanelShortcuts` out of the navigator and above the scaffold, which is
    where the other pages already have it.
  * **Worktrees:** start supplying `compactNavigation`, so its list is reachable.
  * **The Minimal preset** (navigator collapsed) still opens compact on the canvas. The back bar
    makes the navigator reachable anyway, which the 0005-PLAN Phase 3 exit requires.

### F2: Hover-aware drag image, plus a hover cue that can't be hidden (F2-A)

* **The hover signal.** `DragStateNotifier` (`lib/features/dnd/drag_state.dart`) gains a
  synchronous `overTarget` flag, exposed as a `ValueNotifier<bool>` because the drag image is built
  once, and set through `setOverTarget(bool)`.
  * **Who sets it.** All four `DragTarget<DragItem>` sites call `setOverTarget(true)` from `onMove`
    and `setOverTarget(false)` from `onLeave` and on accept:
    * `drop_zone.dart`
    * `branch_navigator.dart`
    * `history_view.dart`
    * `staging_drop_banner.dart`
  * **The guard.** Flutter calls `onMove` on every target the pointer enters, **including targets
    that reject the payload** (SDK `drag_target.dart`, `_enteredTargets` / `didMove`). So
    `setOverTarget(true)` is guarded by the same acceptance test the target uses for
    `onWillAccept`.
  * **Clearing.** The flag is cleared on Esc and in `DragItemDraggable.end`, and
    `setOverTarget(true)` is ignored while no drag is live, so moving after Esc cannot re-arm it.
  * **A target that unmounts mid-drag also clears it.** Flutter's `didLeave` returns early for an
    unmounted target, so its `onLeave` never fires (SDK `drag_target.dart`), and History rows do
    rebuild on watcher refresh. So a target that last reported hover clears it in `dispose()`.
    Ownership keeps one target's dispose from clearing another target's live hover.
    * **The mechanism.** Each target reports through its own handle, `DragHoverReport` (in
      `drag_state.dart`), bound by a new `DragHoverScope` widget (`lib/features/dnd/drag_hover_scope.dart`)
      that wraps each `DragTarget<DragItem>`. That gives every History row and branch row its own
      owner, since their `State` is shared across rows.
    * **The API.** `setOverTarget(bool, {Object? owner})`. A `false` from a non-owner is ignored;
      a `false` with no owner, as in Esc and `end()`, clears unconditionally.
    * **Timing.** The disposal clear lands one frame after the removal. A target is disposed while
      the widget tree is locked, and clearing synchronously throws "markNeedsBuild() called when
      widget tree was locked" (tested).
* **The drag image's two states.**
  * While `overTarget` is set, the lifted cell renders in a compact mode: at most 220 px wide
    (`kDragChipMaxWidth`), with the label fallback and the count badge. It is the same
    `LiftedDragCell` in its compact mode, not a second widget, and only one `DragCellChrome` is
    ever built.
  * **Where the chip sits.** Its top-left is at pointer + `kDragChipPointerOffset` =
    **(12, 18)**. So the pointer is never covered, and neither is the hovered row whenever the
    pointer is at or above the row's vertical centre. Nav rows are 32 px tall, so a vertical
    offset above 16 px clears the row from its centre.
  * No fixed offset can uncover a row when the pointer is near its bottom edge. The border cue
    below does not depend on that.
  * Once `overTarget` clears, it returns to the full lifted snapshot.
* **What doesn't change:** the grab-point anchoring at pickup, which is `f8b4a9d`'s intent;
  hit-testing, which Flutter does at the pointer; and the snap-back flight's origin.
* **The hovered nav-rail row** also gains a 2 px green border (`activeDrop`), so the cue no longer
  depends on a 16-point alpha difference. The row stays the same size: while the border is shown,
  its padding shrinks by exactly the border width (10/7 → 8/5). Otherwise the hovered row would
  grow 4 px and push every row below it during the drag.

### F3: One Output view, owned by the shell (F3-A)

* **Where it moves.** Move `output_view.dart` to `lib/features/common/`, and add an
  `OutputViewHost` widget beside it. The host lays out its child with the `OutputView` docked
  below it, shown while `outputLogProvider.visible` is set.
  * `AppShell` wraps its page stack in one, inside the connected layout's `Expanded` (`app_shell.dart`,
    the `Column` that already holds `ToolHealthBanner` and the pages).
  * The Repository page stops mounting its own.
* **The detached repository window** (`lib/features/window/secondary_window_main.dart:1099-1103`)
  wraps its `RepoStatusView` in a host, because it doesn't run inside `AppShell`.
* **The History pop-out window** gets no Output view, since it never had one.
* **Effect.** Every existing `setVisible(true)` caller and all three command paths now have a
  visible effect on every page, with no change to those callers.
* **The Activity Center's "Output" link.** The host publishes its reveal action through an
  inherited widget (`OutputViewHost.revealerOf`). `RepositoryContextBar` uses
  `onRevealOutput ?? OutputViewHost.revealerOf(context)`, so every page offers the link wherever
  an Output view is hosted, and never as a dead link: the History pop-out, with no host, offers
  none.
* **The help book entry** is reworded from "under the Repository canvas" to "below every page".

### F4: A pure sanitizer at the service layer (F4-A)

A new pure function, `sanitizeGhJobLog(String) → String` in `lib/core/forge/ci_log_text.dart`,
applied in `GhService.runJobLog`. It:

1. removes real escape sequences:
   * ECMA-48 CSI: ``\x1B\[[\x30-\x3F]*[\x20-\x2F]*[\x40-\x7E]``
   * OSC: ``\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)``
   * two-byte Fe: ``\x1B[\x40-\x5A\x5C-\x5F]``
2. removes **only** the caret SGR and EL form ``\^\[\[[0-9;]*[mK]``, so literal `^[` text such as
   `'^[[:digit:]]+$'` survives;
3. removes the `<a>\t<b>\t` prefix **only when every non-empty line carries the identical pair**;
4. removes U+FEFF at the start of a line's content, after any prefix removal.

The view is unchanged.

### Out of scope

Each item below is recorded here and needs its own decision.

* **SSH, beyond the cipher order (F5):**
  * F5-B, the upstream AES-GCM speed-up, which still matters for GCM-only hosts;
  * F5-D, decrypting off the UI isolate;
  * F5-C, making the bulk test a real test of the health monitor. After F5 the transfer takes
    about 3 s, shorter than the monitor's 15 s probe interval, so the test no longer exercises the
    monitor. It barely did before either, because timers were starved;
  * moving the two copies of the loopback-`sshd` test harness into `test/helpers/`.
* **F6-C:** defaulting `Coalescer`'s clock to `clock.now`, which would remove a harmless mixed-clock
  case in the "cancel stops a pending fire" test.

* **The same defect on another command.** Toggle File View (⇧⌘E) mounts only on Repository at
  1200 px or wider (`repo_status_view.dart`); it would need its own placement decision, since the
  file tree is repository-specific.
* **Forge shortcuts after a mouse click.** They are unreachable at every width, because the page
  has no focus node.
* **Context-bar Back** cannot return from detail to list: repository-kind locations are ignored.
* **The compact sidebar toggle** is wired only on the Repository page.
* **Drag-and-drop:**
  * dragging a commit onto a branch row (cherry-pick) appears unreachable in the app, because
    History and Branches never share a window;
  * when a drop is accepted with no repository path, the drag image vanishes instead of flying
    home.
* **Revealing an operation while the view is hidden** may never scroll to it. `OutputView` starts
  listening to `outputRevealProvider` in `build`, after the reveal id has already been set. This
  predates this decision, is not yet verified, and needs a test before anyone relies on it.
* **CI log rendering:**
  * collapsing `##[group]` blocks: the `GITHUB_TOKEN Permissions` banner users misread as an error
    lives inside one;
  * SGR colour (F4-B);
  * GitLab trace content, which could not be captured without GitLab authentication.

### Consequences

* Good, because bulk SSH reads go about 25× faster, and the timer stalls they cause drop from
  18–91 s to under 0.7 s (measured: 100 MiB in 3.2 s, longest timer gap 686 ms). This is a
  product-wide fix, not just a test fix.
* Good, because the full suite stops flaking on two tests, so every phase's gate can require
  exit 0 with no exceptions.
* Bad, because F5 reverses a clause of 0013-MADR. That is recorded in both records.
* Neutral, because servers that offer only AES-GCM still get the slow path, until F5-B.

* Good, because every pane is reachable at every width, by mouse and keyboard. That meets the
  0005-PLAN Phase 3 exit, which the tree has missed since `e5631c5`.
* Good, because one scaffold-level mechanism serves all five navigator pages; each page supplies
  data, not behaviour.
* Good, because keeping the selection on Back, and letting arrow keys work in a compact list,
  matches how a collapsed macOS split view behaves.
* Good, because the drop target under the pointer is always visible, and its cue no longer
  depends on a faint alpha difference.
* Good, because every transcript the app writes can be seen from the page where it was written.
  Callers already assumed this.
* Good, because CI logs read cleanly from both old and new gh without corrupting legitimate caret
  text. The transform is a pure function, so exhaustive tests are cheap.
* Bad, because F1 changes the scaffold's API and touches five pages, plus the Branches
  `PanelShortcuts` move, which shifts when that page publishes menu availability.
* Bad, because F2 adds cross-widget drag state. Every `DragTarget` must report hover, and a future
  target that forgets to won't shrink the drag image. A test enumerates the known sites (see the
  plan).
* Bad, because F3 changes the Repository layout. The Output pane now spans the full width, under
  the File view's right-hand pane, which the comment at `repo_status_view.dart` about panes never
  extending under the right pane must be updated to say. The help book entry changes too.
  The workspace goldens do not change, because their fixture never builds `AppShell`: a prototype
  ran all 48 golden cases unchanged.
* Bad, because F1's back bar changes the compact workspace goldens wherever a fixture supplies
  `compactNavigation`, and it conflicts with `adaptive_workspace_layout_test.dart:97-117`, whose
  name says it switches panes but which never does. The plan says which assertions change and
  why.
* Neutral, because F4 drops colour. The coloured lines seen so far are echoed script lines, and
  F4-B remains available.
* Neutral, because none of this touches rendering. The fixes are renderer-independent, like the
  defects.

### Confirmation

The implementation plan
(0064-PLAN-workspace-reachability-feedback-and-log-fidelity.md) must deliver every item below.
Each automated check must be seen to fail on the unmodified tree before it is trusted.

1. **F1, at 600 px, for History, Stashes, Branches, Forge and Worktrees,** using real key events
   and real taps:
   * tapping a row shows the canvas, and primary focus is inside the page's `PanelShortcuts`;
   * Esc, ⌘[ and a tap on the back bar each show the navigator again, with focus on the list;
   * History's zoom changes with ⌘= in the canvas;
   * Branches has exactly one `PanelShortcuts` in the canvas;
   * Worktrees shows its list with no selection;
   * each check also passes at 1000 px as a control.
2. **F2:** with a drag held over the "New branch" rail row after a grab at x = 300:
   * the drag image does not contain the pointer, and does not overlap the hovered row;
   * the hovered row has a border;
   * moving off the target restores the full image;
   * Esc while hovering restores it, and the snap-back still runs;
   * every `DragTarget<DragItem>` in `lib/` reports hover. A scan test enumerates them.
3. **F3:** in a connected `AppShell`, for each of pages 0–5, ⇧⌘O toggles `find.byType(OutputView)`
   between one and none. There is also a case at 640 × 480.
4. **F4:** unit tests on real fixtures:
   * caret lines and real-ESC lines come out clean;
   * the POSIX-class guard strings survive unchanged;
   * the prefix and BOM are stripped only under the stated rule;
   * a `GhService` test returns clean text from caret stdout;
   * the view shows no `^[`.
5. **F5:** the negotiated-cipher test fails on today's tree, showing `aes256-gcm@openssh.com` for
   every client, and passes with the fix. The bulk-transfer test then passes in seconds, in
   isolation and in the full suite.
6. **F6:** the rewritten test passes on the unmodified product, and fails when the reschedule guard
   is removed in a scratch copy (`Expected: <3> … Actual: <20000>`).
7. **On device** (Impeller, driven as in 0063-GATES): at a 900 pt window, History, Branches and
   Worktrees each go there and back; the hover tint measures as visible under the chip; ⇧⌘O shows
   the Output view on History; and the Dependabot job log shows no `^[`.

## Pros and Cons of the Options

### F1-A: the scaffold owns compact state, with a back bar, Esc/⌘[ and a focus handoff

* Good, because it fixes mouse and keyboard reachability on all five pages with one mechanism.
* Good, because it keeps the selection on Back and fixes arrow-key navigation in compact lists.
* Good, because focus lands under `PanelShortcuts`, so every panel shortcut works in the canvas.
* Neutral, because it adds a visible back bar only in compact.
* Bad, because it changes the scaffold's API, and each page must own a `showCanvas` flag.

### F1-B: a back bar plus Esc that clears the selection

* Good, because the API stays smaller, and Esc keeps its wide-width meaning (deselect).
* Bad, because Back loses the selection.
* Bad, because the first ↓ in a compact list still selects, switches to the canvas and unmounts
  the list.
* Bad, because Branches and Worktrees still need the same page changes.

### F1-C: keep the navigator mounted but hidden

* Good, because it touches one file.
* Bad, because a mouse user still has no visible way back.
* Bad, because it doesn't fix Forge (no focus node) or Worktrees (never shown).
* Bad, because focus can sit in an invisible pane, which breaks MADR §9's "visible focus" and
  confuses VoiceOver, and the hidden list still lays out.

### F2-A: a hover-aware drag image plus a stronger cue

* Good, because the pointer is never covered, and neither is the hovered target whenever the
  pointer is at or above its vertical centre. A border cue that doesn't depend on alpha covers the
  rest.
* Good, because it keeps the lifted snapshot while the item is in flight, which is `f8b4a9d`'s
  intent.
* Bad, because every `DragTarget` must report hover, which means five to six files and a
  cross-widget flag.

### F2-B: anchor at the pointer

* Good, because it's a one-file change and restores the pre-`f8b4a9d` placement.
* Bad, because it drops the grab-point intent and makes the image jump at pickup.
* Bad, because a 420 × 52 image still covers the rail rows below and to the right of the
  pointer.

### F2-C: fade the drag image over targets

* Good, because the geometry doesn't change.
* Bad, because the image and the target's text overlap and look cluttered, and the cue stays weak
  unless it is also strengthened.

### F2-D: targets draw a ring above the drag image

* Bad, because an `OverlayPortal` child paints below later overlay entries, and the drag image is
  a later entry. The only route is for each target to add its own root overlay entry and manage its
  lifecycle, which is fragile, and the ring would then paint over the lifted item.

### F3-A: one Output view in the shell

* Good, because it fixes the command and every `setVisible(true)` caller, with no changes to those
  callers.
* Good, because a single instance keeps its height across pages.
* Bad, because the Repository layout changes, as described above, and the detached window needs
  its own mount.

### F3-B: navigate to Repository to show the Output view

* Good, because the layout doesn't change.
* Bad, because it pulls the user off the page they're working on.
* Bad, because `clone_controller.dart` is in the core layer and can't navigate.
* Bad, because transcripts from other pages still aren't visible while the user is there.

### F3-C: scope the command to Repository

* Bad, because the native menu item needs Swift changes (it isn't governed by
  `availableActionsProvider`), and every `setVisible(true)` caller still needs rerouting.
* Bad, because it duplicates a transcript surface the app already has.

### F4-A: a pure sanitizer in the service layer

* Good, because it handles gh's caret form, real ESC from older gh, and a future gh that strips
  them entirely.
* Good, because it runs once, in time proportional to the log's size, where every consumer gets
  clean text.
* Neutral, because colour is lost.

### F4-B: F4-A plus SGR colour

* Good, because it restores colour.
* Bad, because a log can produce tens of thousands of spans in one paragraph, which needs
  per-line virtualisation and a new performance gate. Deferred.

### F4-C: fetch raw bytes with `gh api --allow-escape-sequences`

* Good, because real ESC bytes are unambiguous, and the prefix columns disappear.
* Bad, because it opts out of gh's defence against terminal injection, which makes the stripper
  security-critical, and it depends on a gh flag.

### F5-A: prefer ChaCha20-Poly1305

* Good, because it gives about 25× throughput and ends the timer starvation, with a one-file
  change.
* Good, because it offers the same cipher set, and both leading choices are AEAD.
* Bad, because it reverses a clause of 0013-MADR, which needs recording in both records.

### F5-B: fix AES-GCM upstream

* Good, because it helps GCM-only hosts too.
* Bad, because it means forking or overriding transitive crypto packages, with a large scope and
  higher risk. Deferred, and complementary to F5-A.

### F5-C: restructure the bulk test around the health monitor

* Good, because it would make the test's claim about the monitor real.
* Bad, because it doesn't fix the slow product path. It complements F5-A rather than replacing it,
  and is deferred.

### F5-D: decrypt off the UI isolate

* Good, because it removes timer and frame starvation in general.
* Bad, because it is an architectural change that needs its own record.

### F6-A: count timers on simulated time

* Good, because it asserts the property itself, deterministically, and more strictly than
  before.
* Good, because only the test changes.

### F6-B: inject a timer factory

* Neutral, because it would work, but a Zone hook already counts Timers without changing the
  product's API.

### F6-C: default the clock to `clock.now`

* Neutral, because it is sound hardening, but not needed for this flake. Deferred.

## More Information

### Evidence

* **0063-GATES:** G5, G6, G7 and G8, plus the renderer A/B table.
* **The 0063 plan's execution record:** entries D2, D2 outcome and D3.
* **The widget-test probes** ran only in scratch clones at `21d32bc`, never in this tree:
  * compact navigation: per-page probes at 600 px with 1000 px controls, including a positive
    control that proves the probe detects working shortcuts;
  * drag: geometry of the drag image against the hovered row;
  * Output view: six existing test files, 63/63 green, and none asserts that an `OutputView` is
    present on a page;
  * CI logs: a byte census of three captures, with the regexes checked on each.
* **Upstream, for F4:**
  * cli/cli PR #13272 ("Fix log terminal injection", merged 2026-04-23, advisory
    GHSA-crc3-h8v6-qh57), first shipped in v2.92.0;
  * cli/cli issue #13434 ("Run logs with color escapes are unreadable"), open; fix PRs #13480,
    #13561 and #13964 were all closed unmerged.

* **F5 and F6 evidence** (scratch clones of `21d32bc`):
  * the cipher sweep and throughput and timer-gap probes;
  * F5 red: `Actual: ['aes256-gcm@openssh.com' ×6]`, and its empty-log guard failed on demand;
  * F5 green: the bulk test passed in 3.0–5.7 s across isolated and full-suite runs;
  * F6 under contention: the old test failed 5 of 8 runs and the new test passed 8 of 8;
  * F6 mutants: guard removed → `Expected: <3> Actual: <20000>`; fire 1 ms late →
    `Expected: [0:00:00.166002] Actual: [0:00:00.167002]`.

### Revisit when

* dartssh2 or pointycastle speed up AES-GCM (F5-B). Re-measure, and reconsider the cipher order.

* gh changes how `run view --log` handles escapes. F4's tests pin all three forms, so either
  change is safe.
* A new drop target is added. The scan test in the F2 confirmation will require it to report
  hover.
* The width classes change. F1's tests run at 600 and 1000 px against the constants in
  `repository_workspace_models.dart`.

## Amendment 0064.1 (2026-09-22): the File view keeps the full height on Repository

F3 above accepted, as a stated Bad consequence, that the shell-owned Output pane would span the
full width of the Repository page, under the File view's right-hand pane. On the device that
consequence reads as a regression: with the File view open, the Output pane cuts the bottom off
the file tree, which breaks the rule the Repository layout has kept since the initial commit —
the File view is the page's full-height third panel, and every horizontal pane lives in the centre
column, clamped to its width. The maintainer rejected the consequence on 2026-09-22.

**Amended decision.** The Output view stays one command with one visible effect on every page
(F3's intent is unchanged), but **where it docks** depends on the page:

* **Repository** (in the shell, and in the detached repository window) docks it at the bottom of
  its centre column, beside the File view, as it did before 0064. `RepoStatusView` gains
  `hostsOutputView` (default false); the two places that own a Repository page pass true, and it
  mounts the view only while it is the active page. The nested Repository inside a worktree tab
  keeps the default, so the Worktrees page never shows two.
* **Every other page** keeps the shell's full-width dock. `OutputViewHost` gains `dock`
  (default true); `AppShell` passes `pageIndex != 0`, and the detached window passes false.
  The host still publishes `revealerOf` either way, so the Activity Center link is unchanged.
* **The height is shared.** The user-dragged height moves from `_OutputViewState` into
  `outputViewHeightProvider`, so the two mount points show the same height; F3's "one instance
  keeps its height across pages" still holds in effect.
* **The help book** says "below every page, and on Repository below the changes list, beside the
  File view".

**Confirmation added.** `test/output_view_placement_test.dart` gains geometry tests on a
connected `AppShell`: on Repository with the File view open, the File view's bottom edge is the
page's bottom edge and the Output view ends at or left of the File view's left edge; on History
the Output view spans the page's full width; a height dragged on History is the height on
Repository. They were seen to fail on the unamended tree (0064-PLAN, deviation D6). The F3
section above is not rewritten; this amendment supersedes its layout clause only.
