---
status: accepted
date: 2026-08-14
decision-makers: maccavelli (maintainer)
consulted: Apple HIG (toolbars, pull-down buttons, segmented controls, menus, sidebars, windows); GitHub Desktop, Tower, Fork, Sublime Merge, GitKraken, Sourcetree, Xcode
---

# Collapse the repository workspace to one customizable toolbar backed by a real menu bar

## Context and Problem Statement

The repository screens stack multiple action-bearing horizontal bands, and the
same verb appears in more than one of them at the same time. On a clean,
in-sync repository the Repository screen shows a **Fetch** push-button in the
context bar and a **Fetch** icon in the toolbar row directly beneath it — the
same handler, roughly 40 px apart.

This is not one stray button. A full inventory of all six workspace screens
found:

* **Up to five fixed bands** above content on the Repository screen (tab strip,
  context bar, session-warning banner, toolbar row, pending-operation banner).
* **136 px of chrome — 28.3 % of the window's height** — at the enforced
  640×480 minimum with two or more tabs. The entire responsive design recovers
  6 px (52 → 46) while the duplicated toolbar row costs 54 px unconditionally.
* **25 verbs reachable from two or more visual locations**, of which the
  contextual primary action is *always* a duplicate of a visible toolbar icon
  by construction.
* **The `ActivityCenterButton` rendered twice on one page**, ~300 px apart.
* **Three verbs whose duplicate copies have diverged in behavior** (below).
* **41 single-route actions** — reachable exactly one way, so no band can be
  deleted without relocating them first.
* **A nearly empty macOS menu bar**: six view toggles, About, and Help. **Not
  one git or forge operation is reachable from the menu bar.**

The duplication has already caused a real defect. `stashPush` defaults
`includeUntracked = false` (`git_service.dart:5154`). The Stash screen's primary
"Stash Changes" button (`stash_view.dart:450`) and its hamburger "Stash current
changes" (`:526`) omit the flag; the Repository toolbar's Stash, ⇧⌘S, the
palette, drag-to-stash, and auto-stash-on-branch-switch all pass `true`. The
codebase documents why this matters, at `branch_switch.dart:66-69`: `git stash
push` "ignores untracked files, which would then 'succeed' with an empty 'No
local changes to save' no-op, create no stash, and let the checkout carry the
changes across." On a tree whose only changes are untracked, the Stash screen's
own primary button reports success, creates nothing, and silently leaves the
work behind. Two other verbs have diverged the same way: the Stash hamburger's
Apply/Pop act on the *latest* stash while the row buttons and ⌥⌘A/⌥⌘P act on
the *selection*; the Worktrees hamburger's Repair takes no operand while the row
button, context menu, and detail button each take one worktree.

Duplicated entry points are therefore not a cosmetic problem. They are an
un-checked invariant that has already drifted into two contradictory behaviors
behind one label.

### Why this was not caught earlier

MADR 0005 §3 already decided against this shape, in terms:

> The primary control is contextual — Fetch, Pull, Push, Publish, Continue,
> Resolve, or Create/Preview Request — **not a permanently equal row of
> unrelated icons**. Less frequent and dangerous variants remain in a menu and
> the command palette. Users may opt into labeled toolbar controls and
> customize which secondary controls remain visible.

Two further records restated it. MADR 0006 names "the permanently equal
Fetch+Pull+Push+Stash icon row" as the thing not to build, and makes "the title
bar does not grow a permanent Fetch+Pull+Push icon row" a confirmation
criterion. `ACTION_PLAN.md:20-22` explicitly fences off its own deferred
`ToolBar` bullet.

What shipped was the addition without the subtraction, plus two stubs that made
the subtraction impossible:

* No menu on the primary action, so the non-primary verbs had nowhere to go.
* `WorkspaceToolbarSlot` contains exactly `{back, forward}`
  (`repository_workspace_prefs.dart:15`) — the "customize which secondary
  controls remain visible" promise covers two navigation chevrons and nothing
  else.

So 0005's chrome decision was not wrong; it was **unfinished, and unfinishable
as specified**, because the design had no home for the ~20 verbs the icon row
was carrying. This record supersedes that part of 0005 with a design that does.

### The shared bar is also being falsified

Only `RepoStatusView` calls `resolvePrimaryRepositoryAction`. The other five
screens hardcode a `RepositoryPrimaryAction`, three of them abusing
`kind: fetch` as a placeholder because the enum has no slot for their verb:
Stash → "Stash Changes", Worktrees → "Add Worktree", History → "Refresh",
Branches → "Fetch & Prune", Forge → `kind: publish` "New Pull/Merge Request".
Forge fabricates the whole snapshot, setting `branchLabel` to the literal
string "GitHub". Meanwhile Back/Forward are wired only on Repository
(`app_shell.dart:1077-1080`) so they are permanently dead on the other five,
and the status summary reads "Clean" on all five because none populate
`changedCount`.

A shared contract that five of six screens have to lie to satisfy is the wrong
contract.

## Decision Drivers

* **No functionality may be lost.** 41 actions have exactly one route today;
  every one needs a home before its current home can change.
* **One label, one behavior.** The stash divergence must become structurally
  impossible, not merely fixed once.
* **Vertical space is the scarcest resource** at the 640×480 floor, where
  chrome currently takes 28 %.
* **Native macOS expectations.** Apple's guidance and every native-NSToolbar
  competitor point the same way.
* **Discoverability without hiding.** Advanced and dangerous variants must be
  present and findable, not suppressed by state.
* **Consistency across the six screens**, which today use four toolbar
  placements, five mode-switch idioms, and two section-header conventions.

## Considered Options

* **A. Status quo** — keep both bands.
* **B. Finish 0005 literally** — delete the toolbar row, keep the single
  contextual primary action as the only sync affordance.
* **C. Invert 0005** — delete the contextual primary action, keep the static
  icon row.
* **D. One unified toolbar: a static, grouped sync control with contextual
  *emphasis*, a populated macOS menu bar as the guaranteed second route, and
  transient status evicted from the band.**
* **E. Option D on a real `NSToolbar`** with Apple's native "Customize
  Toolbar…" palette.

## Decision Outcome

Chosen option: **"D. One unified toolbar with a static grouped sync control and
a populated menu bar"**, because it is the only option that removes the
duplication *and* increases reachability, and because the evidence against
option B — the design 0005 actually specified — turned out to be strong and
specific.

Option E is the right long-term shape and is explicitly the follow-on, but it
is blocked today: `macos_ui: ^2.2.2`'s `ToolBar` exposes no customization
surface (no `allowsUserCustomization`, no `autosavesConfiguration`, no
customization palette), so shipping Apple's native affordance requires a real
`NSToolbar` behind a platform channel. `ToolBarPullDownButton` *does* exist, so
the pull-down half of this design is available now.

### The design

**1. One band.** The context bar becomes *the* toolbar and the per-screen
toolbar row is deleted. Apple ships this as a first-class choice —
`NSWindow.ToolbarStyle.expanded` is "the toolbar appears **below** the window
title" (two bands), `.unified` is "next to the window title" (one). Tower made
exactly this change in v6 and published the reasoning: it removed "the
'Navigation Bar' (below the toolbar)… This results in a much cleaner, much
clearer UI," relocating that bar's icons "into the main toolbar." Of the seven
clients surveyed, **none runs three action-bearing bands**; where a second band
exists it is a repo tab strip, not a second action bar.

**2. The sync group becomes static and grouped, not contextual and singular.**
Fetch / Pull / Push / Sync render as one grouped control with a pull-down for
variants, always present, always meaning the same thing. Contextual
intelligence moves from *identity* to *emphasis*: the recommended next action
is highlighted and carries the ahead/behind badge, but no button ever changes
what it does.

This reverses 0005 §3's "one contextual primary action", and the evidence is
the reason:

* **6 of 7 surveyed clients did not adopt a contextual sync button.** Tower,
  Fork, Sourcetree, Xcode use separate static verbs; Sublime Merge and
  GitKraken use static verbs with split-button disclosure.
* **The one that did has spent four years walking it back.** GitHub Desktop's
  own issue #7805 (2019): "I can't seem to tell it to fetch, because the pull
  button replaces the fetch button… my only option was to pull." PR #15494
  (2022) added a menu command "useful if you're in a state where the `Fetch`
  button has been replaced by the `Pull` or `Push` button but you still need to
  fetch." PR #15907 (2023) then bolted on a dropdown because the menu was not
  enough. Issue #17094 reports the predicted mode error in the wild: "I just
  spammed the Pull button, but accidentally pushed."
* **The closest controlled study agrees.** Findlater & McGrenere, CHI 2004
  (DOI 10.1145/985692.985704): "The static menu was found to be significantly
  faster than the adaptive menu… The majority of users preferred the adaptable
  menu overall." Their own caveat applies and is worth carrying: this is menus,
  not toolbar buttons, and the authors flag that generalization is unproven.
  It remains the only rigorous number in the neighborhood, and it points the
  same way as the field evidence.
* **Apple's own precedent for grouping sibling verbs is a segmented control,
  not a contextual button:** "a segmented control can function as a set of
  buttons that perform actions without showing a selection state. For example,
  the Reply, Reply all, and Forward buttons in macOS Mail." Reply / Reply All /
  Forward is structurally what Fetch / Pull / Push is — related verbs on one
  object, one destination-choosing, one riskier.

The failure mode of a contextual-only button is not confusion about what is
visible; it is **the absence of an affordance for what is suppressed**. That is
precisely the complaint that opened this record, arriving from the opposite
direction.

**3. Populate the macOS menu bar.** This is the load-bearing move, and Apple
states it as a requirement rather than a suggestion:

> **Make every toolbar item available as a command in the menu bar.** Because
> people can customize the toolbar or hide it, it can't be the only place that
> presents a command. In contrast, it doesn't make sense to provide a toolbar
> item for every menu item.

We currently satisfy the inverse of this rule: the menu bar holds only view
toggles, and 41 actions have exactly one route. A Repository / Branch / Stash /
Forge / Worktree menu set gives every one of them a guaranteed second route,
costs zero vertical pixels, makes the app legible to macOS conventions and
accessibility tooling, and is what makes deleting a band safe rather than lossy.

**4. Evict transient status from the band.** The SSH latency strip moves out.
No surveyed client spends a horizontal band on transient status: Tower puts
Remote Activity at the bottom of the sidebar, Fork and GitKraken use a bottom
status bar, GitHub Desktop folds "Last fetched…" into the sync button's
subtitle, Xcode routes SCM status into the window-title toolbar item. Apple
sanctions both the bottom-bar and subtitle options while warning that bottom
bars get hidden when windows are repositioned.

**5. Make the shared contract honest.** `RepositoryPrimaryActionKind` gains real
per-screen kinds so no screen has to pass `kind: fetch` for "Add Worktree";
Back/Forward get wired on all six screens or removed from the five where they
are dead; the status summary is populated or omitted rather than silently
reading "Clean".

**6. Real slot customization**, replacing the two-entry `WorkspaceToolbarSlot`.
Apple recommends customization for precisely this kind of app — "apps that
provide a lot of items — or that include advanced functionality that not
everyone needs — and… apps that people tend to use for long periods of time" —
and the survey shows customization and static buttons travel together: the
three native-NSToolbar clients (Tower, Sourcetree, Fork) have both; the three
with contextual or split sync controls have neither. You can only let a user
place a button that reliably means one thing, which is another reason §2
precedes §6.

### Consequences

* Good, because the duplicate disappears by construction: one verb, one
  control, one behavior — the stash divergence becomes unrepresentable.
* Good, because reachability *increases*. Today 41 actions have one route and
  the menu bar has none of them; afterwards every toolbar verb has at least a
  menu-bar command, and the suppressed variants (force push, pull-rebase,
  push-tags, stash-with-message) become permanently visible instead of
  state-dependent.
* Good, because ~54 px comes back at every window size, and the 640×480 floor
  stops spending 28 % of its height on chrome.
* Good, because it removes the "Push while behind" class of dead end that
  GitHub Desktop spent four years patching.
* Good, because a static toolbar is a prerequisite for the customization Apple
  recommends and option E delivers.
* Bad, because a static grouped control is wider than one contextual button;
  at the compact size class the group must collapse into the system overflow
  behavior rather than wrapping.
* Bad, because populating the menu bar is real work in Swift
  (`MainFlutterWindow.swift`) plus a channel per command, and it is the largest
  single piece of this record.
* Bad, because it reverses a decision (0005 §3) that the maintainer accepted,
  and anyone reading only 0005 will find the opposite instruction. Mitigated by
  superseding it explicitly here rather than editing it.
* Neutral, because the contextual *emphasis* retains most of 0005's stated
  benefit — the bar still answers "what is the safest next action?" — without
  the identity swap that causes mode errors.

### Confirmation

* **The reachability matrix is re-derived and no action has fewer routes than
  before.** This is the acceptance gate for "no functionality lost"; a single
  regression blocks the change.
* Every verb in the toolbar resolves to exactly one call site with one set of
  flags — asserted by test for the three known-divergent verbs (stash
  include-untracked, stash apply/pop operand, worktree repair operand).
* No page renders two controls bound to the same handler simultaneously;
  asserted for `ActivityCenterButton` specifically.
* Chrome height above content is measured at 640/standard/wide and recorded.
  **Measured** (`test/chrome_budget_test.dart`, one context bar, no second
  band): compact density 40 / 46 / 46 px at 640 / 900 / 1400; comfortable
  density 46 / 52 / 52 px. The deleted band's 54 px estimate above was derived
  from its padding and content; whatever its exact value, it came back in full
  at every width, because it was a fixed-height row that never adapted.
* `flutter analyze` and `flutter test` clean; the 48 workspace goldens are
  unaffected (they are synthetic fixtures that never mount real chrome), and
  `test/workspace_responsive_test.dart` is the guard for bar-height changes.
* Live verification on a real build, since none of the above measures whether
  the result *reads* as one coherent bar.

## Pros and Cons of the Options

### A. Status quo

* Good, because zero work and zero regression risk.
* Bad, because the duplication has already produced a silent data-behavior
  divergence, and nothing prevents the next one.
* Bad, because it spends 28 % of the minimum window height on chrome.
* Bad, because three accepted records already say not to do this.

### B. Finish 0005 literally (contextual primary only)

* Good, because it is the smallest change and matches an accepted decision.
* Good, because it is maximally compact — one button for the whole sync group.
* Bad, because it is the pattern 6 of 7 clients rejected and the seventh has
  been retreating from since 2019, with a documented mode error.
* Bad, because it *removes* reachability: Fetch becomes unavailable whenever
  the ladder resolves to Pull or Push, which is the exact complaint GitHub
  Desktop patched twice.
* Bad, because it cannot host the ~20 chrome-only verbs the icon row carries
  without a menu that does not exist.

### C. Invert 0005 (static row only)

* Good, because it is honest and static, and preserves every verb.
* Good, because it needs no new infrastructure.
* Bad, because it discards the genuinely useful "what should I do next?"
  signal that the context bar provides.
* Bad, because it leaves the identity/status/navigation slots homeless, since
  the icon row never carried them.
* Bad, because it still leaves 41 actions single-routed and the menu bar empty.

### D. One unified toolbar + menu bar (chosen)

* Good, because duplication is removed while reachability rises.
* Good, because it satisfies Apple's explicit menu-bar requirement, which the
  app currently fails.
* Good, because static verbs unlock customization (Apple's recommendation for
  this app class) and option E.
* Good, because it keeps contextual emphasis, so 0005's core insight survives.
* Neutral, because it is more work than B or C.
* Bad, because the menu-bar population is a substantial Swift + channel slice.

### E. D on a native `NSToolbar` with Customize Toolbar…

* Good, because it is what Apple actually recommends, with a real customization
  palette, automatic overflow, and correct `.unified` styling.
* Good, because Tower and Sourcetree demonstrate it working in this exact
  product category.
* Bad, because `macos_ui`'s `ToolBar` has no customization surface, so it needs
  a platform-channel `NSToolbar` — a materially larger change that would also
  interact with MADR 0006's title-bar work.
* Neutral, because D is a strict subset: doing D first loses nothing and makes
  E incremental.

## More Information

### Relationship to other records

* **Supersedes MADR 0005 §2 (Repository cockpit chrome) and §3 (one contextual
  repository bar).** The rest of 0005 — the scaffold role contract, navigator
  modes, filters, line staging, the review queue, the palette — stands
  unchanged. 0005 is not obsolete as a whole; its chrome section is.
* **Compatible with, and strengthened by, MADR 0006.** 0006 restores the native
  title bar and keeps the context bar as the first content row; under this
  record that row *is* the single toolbar, which is exactly the `.unified`
  shape Apple documents. 0006's confirmation criterion — that the title bar
  must not grow a permanent Fetch+Pull+Push icon row — is honored: the grouped
  sync control lives in the content-side toolbar, not the title bar.
* **Closes the last open item from 0007's audit**, which found the
  `WorkspaceToolbarSlot` stub but not its consequence.

### The relocation table — the "no functionality lost" contract

Nothing may be deleted until its row here is satisfied. Grouped by current home.

| Affordance | Today | Proposed home |
| --- | --- | --- |
| Fetch / Pull / Push / Sync | toolbar icons **and** context-bar primary | one grouped sync control (emphasis on the recommended verb) + menu bar |
| Pull (rebase) / Pull (merge) | toolbar hamburger only | sync pull-down + Repository menu |
| Push (set upstream) / Push tags | toolbar hamburger only | sync pull-down + Repository menu |
| Force push (with lease) / Force push | hamburger; lease has ⌃⌘U | sync pull-down (destructive styling) + Repository menu |
| Amend last commit | hamburger only (palette's row targets History) | Repository menu + fix the palette mis-target |
| Unstage All | commit bar only | stays (commit bar is not a chrome band) + Repository menu |
| Stash / incl. untracked / with message | 7 entry points, 2 semantics | one Stash control + pull-down; **single call site, `includeUntracked: true`** |
| Abort pending operation | pending banner only | banner stays + Repository menu |
| SSH latency strip | toolbar row | bottom status area or identity subtitle |
| "No remote detected" / "No branches yet" | toolbar row captions | context-bar identity area / inline empty state |
| Settings gear | toolbar row | app menu (⌘, already exists) |
| Refresh | toolbar row + 5 other places | toolbar + ⌘R + View menu; per-section refresh stays |
| Activity Center (2nd copy) | toolbar row, ≥900 px | delete; the context-bar copy is unconditional |
| Review selected / Review all visible | navigator only, zero keyboard | keep + new keymap ids + palette |
| Diff blame / pop-out / prev / next / close | `DiffViewControls` only | keep + keymap ids for blame and pop-out |
| Branches: Fetch & Prune ×2 | context-bar primary **and** navigator icon | one control + Branches menu |
| Worktrees: Add ×3, Prune, Repair | chrome only, zero keymap | Worktree menu (the screen has no keymap actions at all) |
| Forge: auto-merge, update-branch, rebase-MR, admin merge, new issue | detail chrome only | keep + Forge menu |
| Back / Forward | context bar only, **user-hideable** | wire on all six screens; add menu items so hiding the slot cannot orphan them |

### Evidence appendix

**Codebase measurements** (commit `52f7596`): bands and heights per screen;
25-row same-verb-two-locations table; 41 single-route actions; chrome budget of
100/136 px (compact, 1 tab / 2+ tabs) and 106/142 px (standard and wide).
Worktrees is the worst case at 89 px in its context slot, and mounting a
worktree tab nests a second full `RepositoryContextBar` beneath it.

**Apple HIG**, current (pages carry Dec 16 2025 "Liquid Glass" revisions):
"aim for a maximum of three [groups]"; "Only specify one primary action, and
put it on the trailing side"; "Choose items deliberately to avoid overcrowding";
"Make every toolbar item available as a command in the menu bar"; "If you need
to list only one or two items, consider using alternative components" (the
reason a two-item Push▾ menu is the wrong tool); segmented controls as action
groups, citing macOS Mail's Reply/Reply All/Forward.

**Honest limits of the research.** Apple has **no** rule against duplicating a
control across two bands — it sanctions and requires toolbar↔menu-bar
duplication and is silent on toolbar↔second-bar. The case against our duplicate
therefore rests on overcrowding, the three-group maximum, the single-primary-
action rule, and the `.unified`/`.expanded` API choice, not on a citable
prohibition. Two premises in the original research brief were also wrong and
are corrected here: **Sublime Merge has no Fetch button** (its split trio is
Stash/Pull/Push; fetch is a command plus an `auto_fetch` preference), and
**GitKraken's Pull dropdown is a sticky mode selector** (ff-if-possible /
ff-only / rebase) that also contains Fetch All, not a plain command menu.

**Client survey** (bands above content · sync form · primary action):
GitHub Desktop 2 · one contextual slot · fully contextual — retreating.
Tower **1** (second band deleted in v6) · 3 static + dialog, ⌥ bypass · static.
Fork 2 (toolbar, then tab strip) · 3 static, no chevrons · static, badged.
Sublime Merge 3 (title, tabs, header) · paired split buttons · static.
GitKraken 2 + bottom status bar · Pull = mode split button · static.
Sourcetree **1** native NSToolbar · 3 static → sheets · static + count badges.
Xcode 1 · menu commands only · no source-control chrome at all.

### Deliberately out of scope

Native `NSToolbar` migration (option E); the MADR 0006 title-bar flip, which
proceeds independently; per-screen navigator toolbars, which are inside panes
rather than window-width bands and are not the subject of this record; and the
five mode-switch idioms, which deserve their own consistency pass.
