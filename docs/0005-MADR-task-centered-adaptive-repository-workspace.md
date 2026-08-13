---
status: accepted
date: 2026-08-13
---

# Evolve the repository screens into a task-centered adaptive workspace

## Context and Problem Statement

Magic Git has grown into a capable macOS Git environment rather than a simple
working-copy viewer. A repository session now spans status and staging, history,
branch review, stashes, GitHub/GitLab issues and change requests, CI, recovery,
worktrees, file viewing, output, drag-and-drop workflows, command-palette
actions, and native pop-out windows. It supports local repositories and remote
POSIX repositories without a local clone through the same service layer.

The feature set is strong, but the interaction model still reads as a set of
independently evolved panels. Each panel makes its own choices about headers,
filters, primary actions, empty states, master/detail behavior, selection,
progress, and disclosure. The Repository screen is the clearest example:

* The branch and network actions are in an icon-heavy header.
* Changed files are divided into status sections in the main list.
* A selected file opens a fixed-ratio diff beside that list.
* The optional full file tree opens as another pane on the far right.
* Commit composition opens in a modal sheet after the user presses `Commit…`.
* Multi-selection replaces the diff with a count while bulk actions remain in
  the context menu.
* Long or remote operations generally expose a busy state and detailed output,
  but there is no unified, persistent activity surface that explains what is
  running, where it is running, or what completed.

This arrangement exposes capability, but it interrupts the core loop of
**orient → choose changes → review → stage → describe → commit → publish**. It
also asks users to learn a different micro-layout in History, Branches, Stashes,
Forge, and Worktrees. At the 1080×720 default window the layout is workable; at
the supported 640×480 minimum, the sidebar, status list, diff, optional file
tree, output pane, and commit bar compete for limited space.

MADR 0004 fixed correctness, incomplete wiring, accessibility basics, and
misleading chrome. This decision does not reopen those findings. It addresses
the next layer: the product-wide workspace model, interaction hierarchy, visual
system, and ergonomic flow of the repository screens.

The decision to make is:

> Should Magic Git continue polishing each panel independently, emulate one
> competitor's layout, or adopt a shared task-centered workspace architecture
> that preserves its remote-first strengths while making common Git workflows
> continuous, adaptable, and progressively disclosed?

### Scope

This record covers the six repository-session screens selected from the main
sidebar: Repository, History, Branches, Stashes, Forge, and Worktrees. It also
covers the shared tab strip, repository context, command palette, activity and
recovery affordances, pane behavior, visual hierarchy, keyboard/VoiceOver
behavior, and handoffs between those screens.

It does not choose a new Git transport, replace Riverpod, replace `macos_ui`, or
move Git/forge behavior out of the existing service and executor seams. It does
not require copying the visual identity of Tower, Fork, GitKraken, GitHub
Desktop, or GitLab.

### Audit method and evidence limits

The assessment used:

* Static inspection of the app shell, tabs, Repository, History, Branches,
  Stashes, Forge, Worktrees, shared diff widgets, pane persistence, keymap,
  command palette, undo/recovery, theme, and relevant widget tests.
* Review of MADR 0004 and its implemented remediation plan to avoid reporting
  already-fixed problems as new gaps.
* DDG MCP web and image search for current product pages, documentation, release
  notes, and interface screenshots for Tower, Fork, GitKraken Desktop, GitHub
  Desktop, GitLab, and Apple's macOS design guidance.
* Direct review of the first-party pages discovered through DDG when search
  result snippets were insufficient.

The competitor material shows shipped features and visible interaction
patterns; it is not a controlled usability benchmark. Vendor claims are treated
as evidence of product direction, not proof that a pattern will work for Magic
Git. Screenshots span product versions, so this record relies on stable layout
patterns and current documentation rather than pixel-level imitation. No live
Magic Git usability study or instrumented task benchmark was run for this
record; those are part of confirmation.

### Current strengths to preserve

Magic Git already has several differentiators that should shape the redesign:

* **Remote-first operation without a clone.** No researched competitor centers
  a full desktop Git workflow on an arbitrary POSIX host over SSH while keeping
  the same UI for local repositories.
* **Strong branch review.** Browse/Review modes, comparison-base resolution,
  ahead/behind state, merged/stale/conflict filters, pinned branches, batch
  cleanup, per-branch commits/changes, and forge readiness are more purposeful
  than a generic branch list.
* **Integrated forge and CI.** GitHub and GitLab change requests, issues,
  comments, releases, jobs, and traces live beside repository operations.
* **First-class worktrees.** Worktree creation, locking, moving, pruning,
  repair, nested repository workspaces, tabs, and detached windows are already
  substantial.
* **Safety and recovery.** Dirty-state guards, undo records, snapshots, reflog
  browsing, destructive confirmations, and recovery actions are meaningful
  trust features.
* **Power-user ergonomics.** Remappable shortcuts, a command palette,
  multi-selection, direct-manipulation drag/drop, persistent pane widths,
  split/unified diffs, blame, history search, a minimap, and pop-outs provide a
  strong foundation.
* **Performance-aware rendering.** Lazy page mounting, diff prefetching,
  background parsing, virtualized lists, bounded output, and concurrent read
  lanes support a responsive workspace even when the repository is remote.

### Competitive findings

| Product | High-value interaction pattern | Lesson for Magic Git | Pattern not to copy blindly |
| --- | --- | --- | --- |
| Tower for Mac | Working Copy keeps changes, diff, staging, and commit intent together; Quick Actions search views, branches, commits, files, submodules, and remotes and then offer contextual actions; undo, drag/drop, workflows, worktrees, single-line staging, branch cleanup, and pull requests are explicit product concepts. | Make the palette entity-aware, keep the commit loop continuous, make recovery visible, and let workflow context determine the next action. | Tower's breadth and workflow terminology can overwhelm users if everything is always visible. |
| Fork | Dense but legible three-region layout; branches and refs stay visible beside the graph; working changes use tree structure, a persistent composer, advanced diffs, line staging, file history, blame, conflict resolution, image diffs, and reflog. | Preserve spatial context while moving between graph, selected item, and detail; add finer staging and non-text review where valuable. | A permanently dense, expert-first surface is a poor fit for a remote session or a 640px-wide window. |
| GitKraken Desktop | Left Panel, graph, and Commit Panel form a consistent workspace; WIP is a first-class graph node; panels and sections resize/collapse; columns, labels, zoom, tabs, and themes are customizable; Focus/Solo reduce graph noise; a status bar and command palette support orientation and keyboard flow. | Treat layout, density, focus, and visible fields as user preferences; connect working state to history; offer a repository-wide focus lens. | A graph-dominant canvas and many global hubs would dilute Magic Git's simpler panel model and remote-first identity. |
| GitHub Desktop | The top repository/branch/sync bar is exceptionally clear; Changes and History are simple peer modes; file and line inclusion is direct; the commit composer remains in the working-copy flow; branch protection, checks, and PR creation appear at the moment they matter. | Prefer one contextual primary action, inline composition, direct selection, and just-in-time forge guidance over static toolbars. | GitHub-only assumptions and deliberate feature minimalism would discard Magic Git's GitLab, SSH, recovery, worktree, and advanced-history strengths. |
| GitLab repository UI | Revision-aware file browsing, compare, branch/merge-request links, repository graph, file history, blame age, Code Owners, Web IDE, pipelines, and protected-branch rules connect source navigation to collaboration policy. | Bring ownership, policy, CI, and change-request context into the file/branch review flow when the forge can provide it. | A web-project information architecture is too broad and page-oriented for a focused native Git workspace. |

### Gap assessment

The primary gaps are interaction-system gaps, not missing Git commands.

| Gap | Evidence in the current product | User cost |
| --- | --- | --- |
| The commit loop is modal and discontinuous. | `RepoStatusView` ends in a compact stage/commit bar; `CommitDialog` owns message generation, review, validation, signing disclosure, and submission in a sheet. | Users lose visual continuity between the chosen diff and the message that describes it; repeated small commits require repeated modal transitions. |
| Repository selection is weaker than the diff engine. | Status has file multi-select, but the detail pane only reports `N files selected`; partial application is hunk-level, not arbitrary line/range-level. | Reviewing or composing a coherent multi-file commit requires serial navigation and context-menu knowledge. |
| The Repository screen has no fast change-set filter. | History, Branches, and Forge expose search/filter models; Repository status and Stashes do not have equivalent filtering/grouping controls. | Large working copies become scan-heavy precisely where users need to form focused commits. |
| Pane behavior is only partially adaptable. | Shared master/detail panes and the Files pane persist width, but the Repository status/diff ratio is fixed. The main navigation sidebar can be dragged closed, but its inherited 556px auto-hide breakpoint leaves the 240px-minimum sidebar open at the supported 640px window width; the file tree can then create a fourth simultaneous region. | Narrow windows truncate the primary task; wide windows cannot be tuned to a user's review style. |
| Actions are discoverable by implementation, not by intent. | The command palette combines static panel actions with live local-branch, worktree, and saved-remote-repository targets. It does not search commits, changed/repository files, stashes, issues, change requests, or pipelines, and selecting a live entity cannot open a second step containing all actions valid for that entity. | Users still need to know which screen owns most objects before they can find or act on them. |
| Operation state is fragmented. | Panels expose `busy`, spinners, banners, undo toast, Output, and health/status rows independently. | Remote latency can look like inactivity; users cannot answer “what is running, where, for how long, and can I safely continue?” at a glance. |
| Context is lost at screen boundaries. | Branches can seed History and drag/drop can trigger cross-panel work, but there is no general back/forward selection history or shared repository focus scope. | Investigating a branch, commit, file, CI failure, and change request becomes a sequence of manual re-finding steps. |
| Visual grammar is decentralized. | The theme defines a canvas and selection tint, while individual features own many paddings, typography choices, status colors, header forms, empty states, and action arrangements. | The product feels assembled rather than composed, and systematic density/accessibility changes are expensive. |
| Accessibility and visual QA are uneven. | Keyboard behavior is tested extensively and branch rows have dedicated semantics; full-screen semantics, focus order, contrast states, motion, and golden/visual regression coverage are not systematic. | Mouse and sighted keyboard users receive the most polished experience; regressions can appear only in live macOS QA. |
| Advanced repository context is available but not surfaced at the point of work. | Forge, CI, worktrees, recovery, file view, and dashboard are separate destinations or overlays. | Users miss checks, PR/MR state, ownership, recovery, and remote-host context until they deliberately open another surface. |

## Decision Drivers

* **Workflow continuity** — the default path from changed file to published
  commit should not require modal context switches or repeated re-selection.
* **Progressive disclosure** — a new user must see the next safe action while an
  expert can reach line staging, rebase, worktrees, recovery, and forge actions
  without leaving the keyboard.
* **Remote-operation trust** — the UI must immediately acknowledge work and
  distinguish local UI state from remote command progress and completion.
* **Information scent** — users should know where they are, what is selected,
  which branch/base/host is in scope, and what an action will affect.
* **Adaptability** — the same architecture must work at 640×480, the 1080×720
  default, wide displays, pop-outs, local repositories, and SSH repositories.
* **Cross-screen consistency** — filters, selection, detail, actions, status,
  errors, empty states, and pane persistence should follow one contract.
* **Recoverability** — destructive and history-changing operations should stay
  explainable and recoverable; undo/recovery must be visible without making the
  interface alarming.
* **Native macOS ergonomics** — sidebars, toolbars, split views, focus,
  keyboard navigation, context menus, VoiceOver, and window restoration should
  behave like a high-quality macOS application.
* **Performance** — visual richness must not cause extra remote fetches, block
  the UI isolate, or keep hidden panels active.
* **Distinct product value** — investment should amplify remote/no-clone,
  branch review, forge/CI, worktree, and recovery advantages before chasing
  checklist parity in submodules, LFS, or stacked branches.

## Considered Options

* **A. Continue panel-by-panel polish** — preserve the current information
  architecture and improve individual controls, spacing, and features as needs
  arise.
* **B. Adopt a competitor-style fixed layout** — select Tower/Fork's working
  copy or GitKraken's graph/commit panel as the primary model and reshape every
  screen around it.
* **C. Adopt a shared task-centered adaptive repository workspace** — define a
  common workspace scaffold, contextual repository bar, adaptable panes,
  persistent commit/review flow, entity-aware palette, and unified activity
  model while allowing each screen to retain its domain-specific content.
* **D. Make the commit graph the single primary canvas** — represent working
  state, commits, branches, stashes, worktrees, and forge objects around a
  universal graph and demote the current screens to inspectors.

## Decision Outcome

Chosen option: **“C. Adopt a shared task-centered adaptive repository
workspace”**, because it fixes the discontinuity and inconsistency that users
experience today without sacrificing Magic Git's remote-first architecture or
forcing every task into one competitor's visual metaphor. It creates reusable
UI infrastructure for polish, accessibility, responsiveness, and future
features; it also permits incremental delivery behind the existing service and
provider seams.

The decision establishes the following product architecture.

### 1. A shared repository workspace scaffold

Create one conceptual `RepositoryWorkspaceScaffold` contract for Repository,
History, Branches, Stashes, Forge, and Worktrees. The implementation may be a
widget family rather than one monolithic widget, but every screen must declare
the same roles:

* **Repository context:** repository name, host/backend, current branch or
  revision, divergence, dirty/pending-operation state, forge/check state, and a
  contextual primary sync/publish action.
* **Navigator:** a filterable, keyboard-navigable collection of the objects in
  that screen—changes/files, commits, branches/tags, stashes, forge items, or
  worktrees.
* **Canvas:** the selected object's primary review surface, optimized for diff,
  graph, log, conflict, file, or form content.
* **Inspector/actions:** contextual metadata and secondary actions, shown
  inline, as a collapsible trailing inspector, or in the palette/context menu
  according to width and frequency.
* **Task dock:** the persistent or collapsible place for commit composition,
  operation activity/output, and other task completion controls.

Each role must have shared loading, empty, partial-error, stale-data, selection,
focus, and refresh semantics. Screens keep their domain-specific models and
providers; the scaffold standardizes presentation and handoff behavior.

### 2. A continuous Repository cockpit

The Repository screen becomes the reference implementation of the scaffold.

* Replace the modal-by-default commit path with a persistent, collapsible
  composer docked to the change navigator or bottom task area. Keep a larger
  sheet/pop-out as an optional focused editor for generated or long messages.
* Offer **Changes** and **Files** as navigator modes. On normal widths, this
  avoids showing both a status list and full file tree at opposite sides of the
  diff. On wide widths, users may pin Files as an additional pane.
* Add status, path, and text filters; directory/status grouping; visible result
  counts; and a one-keystroke clear action. Filtering changes only presentation,
  never staging state.
* Make navigator/canvas and optional inspector dividers resizable, collapsible,
  double-click-resettable, keyboard adjustable, and persisted by repository UI
  identity where appropriate.
* Extend partial-change interaction from hunk actions toward selectable lines
  or ranges. Preserve an explicit whole-hunk fallback where a selected range
  cannot form a safe patch.
* Render an aggregate diff/review queue for multi-selection, with per-file
  anchors, previous/next change navigation, reviewed markers, and bulk actions
  in the visible pane—not only in a context menu.
* Keep split/unified, whitespace, context, blame, and pop-out controls, but group
  them under a single diff-view menu plus the one or two most frequently used
  direct toggles. Active state must be textual or semantic as well as colored.
* Replace the large clean-tree decoration with a useful calm state: “Working
  tree clean,” last sync time, ahead/behind, current PR/MR and checks, recent
  commit, and contextually relevant actions such as Push, Pull, Preview/Create
  Request, Open on Forge, or Open Terminal. The state remains uncluttered when
  those signals are absent.

### 3. One contextual repository bar, not six unrelated headers

The top of every repository screen uses the same compact context bar. It should
answer, without opening another panel:

* Which repository, backend/host, worktree, branch/revision, and comparison base
  am I acting on?
* Is the tree clean, dirty, conflicted, or in the middle of merge/rebase?
* Is the branch ahead, behind, unpublished, protected, or detached?
* Is there an open PR/MR, and are checks passing, pending, or failing?
* What is the safest high-frequency next action?

The primary control is contextual—Fetch, Pull, Push, Publish, Continue,
Resolve, or Create/Preview Request—not a permanently equal row of unrelated
icons. Less frequent and dangerous variants remain in a menu and the command
palette. Users may opt into labeled toolbar controls and customize which
secondary controls remain visible.

### 4. An entity-aware “Go to / Do” palette

Evolve the command palette from a static action list into a repository-aware
omnibox, inspired by Tower Quick Actions and GitKraken's keyboard workflow.

* Search actions and live entities: panels, branches, tags, commits, changed
  files, repository files, stashes, worktrees, issues, PRs/MRs, pipelines, and
  saved/recent repositories.
* Rank exact identifiers, current-scope matches, recency, and valid actions
  above fuzzy matches.
* Selecting an entity reveals only valid actions—open, compare, checkout,
  history, blame, stage, create worktree, open request, copy identifier, or open
  on forge—with destructive actions separated and confirmation-preserving.
* Keep explicit prefixes for expert filtering and make result kind, repository,
  host, shortcut, and consequence visible.
* Reuse existing provider caches and capped result sets; do not issue an
  unbounded remote search on each keystroke.

### 5. A repository focus lens and navigation history

Introduce a lightweight shared focus scope that can carry a branch, base,
revision range, path, worktree, or forge object across screens. Examples:

* “Focus current branch” scopes History, Branch Review, changed files, CI, and
  the open request without hiding how to return to the full repository.
* Opening a failing CI job can lead to its commit, files, and branch while
  keeping a visible trail back to the job.
* Selecting a branch comparison can open History or Forge with the same base and
  head rather than re-resolving intent from scratch.

Add back/forward navigation for these semantic selections. This is navigation
history, not Git history, and it must not mutate the repository.

### 6. A unified activity, undo, and recovery surface

Keep the detailed Output view, undo toast, and Recovery sheet, but connect them
through a compact Activity Center.

* Show queued/running/completed/failed operations with repository, host,
  command category, elapsed time, and plain-language status.
* Acknowledge a remote action immediately even when completion is network-bound.
* Expose cancellation only for operations whose executor/service contract can
  cancel safely; do not fake cancellation by hiding progress.
* Link a completed undoable operation to Undo and durable Recovery details.
* Link failure to the relevant output excerpt and a valid corrective action.
  Retry is offered only when repeating the exact operation is safe and useful.
* Do not expose raw command strings containing sensitive or distracting
  implementation detail in the default activity summary.

This turns Magic Git's remote transport and safety architecture into visible
product confidence rather than background machinery.

### 7. A tokenized visual and interaction grammar

Retain the dark-first visual identity, but move feature-level styling toward a
small, semantic design system:

* Surface levels for sidebar, navigator, canvas, inspector, task dock, overlay,
  and terminal/diff content.
* Separate tokens for selection, focus, hover, drop target, active toggle,
  success, warning, destructive action, conflict, and forge/CI status. No state
  may rely on color alone.
* A documented type scale for workspace title, object title, body, metadata,
  monospace code, and status captions.
* A 4/8-point spacing and radius scale, standard row heights, minimum pointer
  targets, dividers, empty states, skeleton/progress states, and badge shapes.
* Compact and comfortable density modes; an optional high-contrast mode;
  reduced-motion support; text/icon scaling that does not break layouts.
* Motion only for orientation—pane changes, selection handoff, activity entry,
  and disclosure—with no decorative animation on high-frequency operations.

A light theme is not required by this decision. Tokenization must make one
possible later without another feature-by-feature color rewrite.

### 8. Adaptive disclosure and workspace presets

Use available width and explicit user preference, not one fixed arrangement.

| Width/context | Default behavior |
| --- | --- |
| Compact/main-window minimum | Collapsible main sidebar; one navigator or canvas at a time when necessary; task dock overlays or collapses; no four-pane layout. |
| Standard/1080×720 | Sidebar + navigator + canvas; inspector and Files are mutually switchable or overlayable; composer remains visible in compact form. |
| Wide display | Sidebar + navigator + canvas + optional pinned inspector/Files; independent persisted widths. |
| Pop-out/secondary window | Purpose-specific subset with the same context bar and shortcuts; no controls that the proxy cannot execute. |

Provide named presets such as **Review**, **Commit**, **Investigate**, and
**Minimal**, implemented as pane arrangements and focus choices rather than
separate feature modes. Users can customize and restore defaults. Avoid saving
transient secrets, command output, or stale object selections as layout state.

### 9. Accessibility and quality are part of the scaffold contract

Every shared surface must define:

* Logical full-keyboard traversal and pane switching, visible focus, Home/End
  and range-selection behavior, Escape layering, and shortcuts that yield to
  text selection/editing.
* VoiceOver labels, values, selected/expanded/busy states, action names, row
  position/count where useful, and announcements for operation completion or
  failure.
* Contrast and non-color indicators for status, diff, graph, and selection.
* Target-size and hover/focus parity for icon controls.
* Visual regression fixtures at compact, standard, and wide widths, plus
  interaction tests for selection persistence, resizing, palette dispatch,
  and async/partial-error states.

### 10. Automated tests are part of the workspace contract

The workspace architecture is not complete when its widgets render; its state,
interaction, safety, transport, and accessibility contracts must be executable
as automated tests. Every implementation slice must add or update the tests
that prove its behavior in the same change.

* Pure state and transformation logic—breakpoints, action resolution, filters,
  selection reconciliation, palette ranking, patch generation, and preference
  migration—must be covered by deterministic unit tests.
* Riverpod controllers and providers must be tested for repository/session
  isolation, loading/value/error transitions, stale-result supersession,
  invalidation, and disposal.
* Shared widgets and migrated screens must have interaction tests covering
  pointer and keyboard paths, focus order, semantics, compact/standard/wide
  behavior, disabled reasons, and partial failures.
* Executor metadata, queue transitions, proxy codecs, activity/output linkage,
  and reconnect/session-generation behavior must have contract tests across
  SSH, local, scoped, and proxy implementations without contacting a real
  network service.
* Patch application, staging, discard, undo, and other behavior whose
  correctness depends on Git must have integration tests against temporary
  local repositories and real Git behavior.
* Stable visual states must have reviewed macOS golden fixtures. Goldens
  supplement behavioral assertions; they do not replace them.
* Refactors begin with characterization tests. New behavior begins with a
  failing test when the behavior is observable at a deterministic test seam,
  followed by the smallest implementation that makes it pass.
* Tests must not depend on wall-clock sleeps, unordered set/map iteration,
  ambient credentials, external network availability, or a user's repository.
  Time, executors, provider results, window dimensions, and repository fixtures
  must be controlled explicitly.
* Live-forge tests remain separately tagged, skipped by default, and never run
  without explicit maintainer authorization.

### Prioritized value portfolio

The following ranking guides sequencing after this MADR is accepted. It is not
an implementation plan. Benefit estimates combine task frequency, time saved,
error avoidance, discoverability, and strategic differentiation; effort is
relative and must be re-estimated from an implementation spike.

| Priority | Improvement | Projected benefit | Relative effort | Why now |
| --- | --- | --- | --- | --- |
| P0 | Shared workspace scaffold, context model, semantic design tokens, and state contracts | Very high | Large | Prevents another round of divergent panel-specific polish and makes all later work cheaper. |
| P0 | Activity Center backed by executor/service telemetry and undo/recovery links | Very high | Medium–large | Remote latency and mutation trust affect every workflow and uniquely differentiate Magic Git. |
| P1 | Persistent collapsible commit composer with visible staged scope | Very high | Medium | Removes a modal transition from the highest-frequency end-to-end task. |
| P1 | Repository Changes/Files navigator modes with filter, grouping, and counts | High | Small–medium | Delivers immediate value for large working copies using existing status/tree data. |
| P1 | Resizable/collapsible Repository panes and adaptive sidebar behavior | High | Medium | Improves both 640px survival and wide-screen productivity. |
| P1 | Aggregate multi-file review queue with visible bulk actions and reviewed state | Very high | Medium–large | Turns multi-selection into a review workflow instead of a count-only state. |
| P1 | Entity-aware Go to / Do palette | Very high | Large | Makes existing features dramatically easier to discover and links the six screens by intent. |
| P1 | Shared focus lens plus back/forward semantic navigation | High | Medium–large | Removes repeated search and strengthens Branches→History→Forge→CI workflows. |
| P1 | Contextual repository bar and single next-safe-action model | High | Medium | Reduces toolbar ambiguity and surfaces branch/forge/host state where decisions occur. |
| P2 | Line/range staging and discard with patch-validity feedback | High | Large | Matches leading clients for precise commits; hunk staging remains a useful baseline. |
| P2 | Customizable labeled toolbar, compact/comfortable density, high contrast | Medium–high | Medium | Broad polish and accessibility value after shared tokens/scaffold exist. |
| P2 | Image/binary diff adapters and richer file-type review | Medium | Medium | Valuable to design/product repos and closes a visible Tower/Fork gap. |
| P2 | Commit assistance: recent/templates, co-authors, policy/check preflight | Medium–high | Medium–large | Improves commit quality and aligns forge rules with the point of action without requiring generative AI. |
| P2 | Safe Redo model layered on the existing undo journal | Medium | Large | Improves experimentation, but only if repository-state preconditions can prevent replay onto changed state. |
| P2 | Saved multi-repository workspace sets and tab aliases | Medium | Medium–large | Helps users managing fleets of repositories; secondary to making one repository excellent. |
| P3 | Code-owner/ownership lens in files, diffs, branches, and requests | Medium | Large | Strong collaboration value where forge metadata exists; avoid blocking core Git usability. |
| P3 | Submodule and Git LFS management UI | Medium for specialist users | Large | Competitive parity, but less frequent and less differentiating than remote/worktree/review flow. |
| P3 | Stacked-branch workflow orchestration | Potentially high for advanced teams | Extra large | Strategically interesting but requires a separate workflow/domain decision and should not be smuggled into UI polish. |

### Consequences

* Good, because high-frequency staging and committing become one continuous,
  reviewable workflow.
* Good, because the six repository screens gain a consistent visual and
  interaction contract without erasing domain-specific functionality.
* Good, because remote progress, host context, undo, and recovery become a
  visible trust advantage.
* Good, because entity-aware navigation increases the value of features that
  already exist but are hard to discover.
* Good, because adaptive panes and density modes support both laptop and
  wide-display workflows while preserving macOS expectations.
* Good, because design tokens, semantics, and visual fixtures make polish and
  accessibility systematic rather than opportunistic.
* Good, because executable unit, provider, widget, integration, semantics, and
  visual contracts make cross-screen refactoring safer and regressions easier
  to localize.
* Neutral, because users who prefer the current layout will need a migration
  preset that closely matches it.
* Neutral, because the scaffold standardizes roles and states, not the exact
  internal widget tree of every feature.
* Bad, because the foundation is a meaningful cross-feature investment before
  all visible benefits land.
* Bad, because an entity-aware palette and focus lens require careful cache,
  identity, stale-result, and repository-switch semantics.
* Bad, because configurable layouts increase state-restoration and test
  complexity.
* Bad, because writing and maintaining deterministic multi-size, multi-window,
  async, and golden coverage adds material implementation and review cost.
* Bad, because a persistent composer can consume scarce vertical space unless
  its compact/collapsed behavior is excellent.
* Bad, because line staging, Redo, and cross-object navigation can create false
  confidence if safety preconditions are underspecified.

### Confirmation

Acceptance of this decision is confirmed architecturally when:

* A written workspace contract defines the context, navigator, canvas,
  inspector/actions, and task-dock roles plus their loading/error/selection
  behavior.
* New repository screens use shared scaffold primitives instead of introducing
  another independent header, splitter, empty-state system, or action grammar.
* Repository identity and focus state remain family-keyed and cannot leak
  between tabs, worktrees, hosts, or secondary Flutter engines.
* Activity UI consumes typed command/operation telemetry rather than parsing
  human-facing output.
* Every shipped work slice includes tests at the lowest sufficient layer plus
  cross-layer coverage for behavior that spans providers, executors, or Git.
* Test names and fixtures identify the repository/session, width, input, async,
  and safety conditions they prove; regressions receive a failing test before
  the fix whenever the failure is reproducible.

Acceptance is confirmed ergonomically with baseline and follow-up macOS task
studies on both local and SSH repositories. At minimum, measure:

* Time, clicks/keystrokes, errors, and backtracking for: form a partial commit
  from mixed changes; inspect a branch and its request/checks; recover a
  destructive action; diagnose a failed remote operation; create/open a
  worktree; find the history and blame of a file.
* At least a 25% median reduction in interaction steps for the stage-review-
  commit task relative to the current UI, without increasing error rate.
* Immediate visible acknowledgement of every user-started remote mutation; no
  user should interpret expected network time as a lost click.
* Standard committing without a required modal transition.
* Full task completion by keyboard alone and meaningful VoiceOver output for
  context, selection, progress, and actions.
* No overflow or unreachable primary action at 640×480, 1080×720, and a wide
  desktop fixture; stored pane widths must degrade without destructive rewrite.
* Analyzer-clean code, ordinary tests green, and visual regression coverage for
  compact/standard/wide workspace states. Live-forge tests remain opt-in under
  repository safety rules.
* The ordinary suite contains deterministic unit, provider/controller, widget,
  semantics, proxy-contract, and temporary-real-Git integration coverage for
  the delivered workspace behavior; passing only manual task studies or
  goldens is insufficient.

Revisit this decision if task studies show that the shared context bar or task
dock increases cognitive load, if remote provider traffic rises materially, or
if the scaffold prevents a domain screen from presenting its primary task.

## Pros and Cons of the Options

### A. Continue panel-by-panel polish

* Good, because it has the lowest immediate implementation risk.
* Good, because each feature team can optimize its screen independently.
* Neutral, because existing shared widgets can still reduce some duplication.
* Bad, because headers, filters, progress, selection, and empty states continue
  to drift.
* Bad, because it does not solve the modal commit loop or cross-screen context
  loss.
* Bad, because every accessibility, density, and responsive improvement must be
  repeated across features.

### B. Adopt a competitor-style fixed layout

* Good, because Tower/Fork and GitKraken provide understandable reference
  models with proven feature density.
* Good, because a fixed layout is easier to explain and test than an adaptive
  workspace.
* Neutral, because it could accelerate visual redesign of the Repository
  screen alone.
* Bad, because no competitor model accounts for Magic Git's SSH/no-clone,
  dual-forge, worktree-subworkspace, recovery, and multi-window combination.
* Bad, because copying a graph-first or permanently dense layout would transfer
  that product's compromises as well as its strengths.
* Bad, because it optimizes resemblance rather than the user's task and Magic
  Git's strategic value.

### C. Adopt a shared task-centered adaptive repository workspace

* Good, because it addresses the root interaction architecture while retaining
  the current service/provider seams.
* Good, because it supports both simple and expert workflows through progressive
  disclosure and user-controlled density.
* Good, because it makes remote activity, forge context, and recovery part of
  the everyday workflow.
* Good, because it can land incrementally, beginning with shared contracts and
  the Repository reference screen.
* Neutral, because some screens will use only a subset of scaffold roles.
* Bad, because shared state and adaptable layout introduce migration and testing
  complexity.
* Bad, because benefits will be uneven until the principal screens migrate.

### D. Make the commit graph the single primary canvas

* Good, because commits, branches, refs, stashes, WIP, and worktrees have a
  natural graph relationship.
* Good, because expert users can reason about complex history spatially.
* Neutral, because the existing History graph could support an optional focused
  workspace without becoming the whole app.
* Bad, because staging, issues, CI logs, file browsing, recovery, and remote
  health do not all benefit from a graph-first metaphor.
* Bad, because novice users face more concepts before completing a basic
  commit.
* Bad, because it is the most disruptive option and would invalidate mature
  panel-specific work.

## More Information

### Source-code grounding

* `lib/features/app_shell.dart` — six-screen sidebar, lazy `IndexedStack`,
  global shortcuts, health banner, dashboard/recovery routing, and repository
  context boundaries.
* `lib/features/repository/repo_status_view.dart` — status sections, network
  header, fixed status/diff split, multi-selection summary, diff controls,
  commit bar, mutation feedback, and pop-out behavior.
* `lib/features/repository/commit_dialog.dart` — hook-aware modal commit flow
  and signing disclosure.
* `lib/features/repository/file_view.dart` — independent trailing file-tree pane
  and persisted resizing.
* `lib/features/history/history_view.dart` — graph, filters, minimap,
  multi-selection, comparison, keyboard behavior, and History pop-out.
* `lib/features/branches/branches_view.dart`, `branch_navigator.dart`, and
  `branch_detail.dart` — Browse/Review modes, focus base, filtering, cleanup,
  comparison, and forge/worktree actions.
* `lib/features/stash/stash_view.dart`, `lib/features/forge/forge_panel.dart`,
  and `lib/features/worktrees/worktrees_view.dart` — current master/detail and
  task-specific patterns.
* `lib/features/common/resizable_master_detail.dart` and
  `lib/core/settings/pane_layout.dart` — the existing persisted-pane seam.
* `lib/features/common/command_palette.dart` and
  `lib/core/settings/keymap.dart` — current action discovery and remapping.
* `lib/core/undo/` and `lib/features/recovery/recovery_sheet.dart` — undo,
  snapshots, and reflog recovery.
* `lib/core/theme/app_theme.dart` — current dark-only theme and limited shared
  visual tokens.
* [0004-MADR-ui-ux-deep-debug-audit.md](0004-MADR-ui-ux-deep-debug-audit.md)
  — predecessor correctness and wiring audit.

### External research snapshot

Research was captured on 2026-08-13.

* [Tower product overview](https://www.git-tower.com/) — undo, drag/drop,
  single-line staging, worktrees, workflows, branch cleanup, and pull requests.
* [Tower Quick Actions for Mac](https://www.git-tower.com/help/guides/manage-repositories/quick-actions/mac)
  — searchable views and live repository entities with contextual actions.
* [Tower release notes](https://www.git-tower.com/release-notes) — current
  product direction and worktree/branch-management evolution.
* [Fork feature overview](https://git-fork.com/) — persistent commit view,
  line staging, history/blame, interactive rebase, conflicts, image diff, and
  reflog.
* [GitKraken Desktop interface guide](https://help.gitkraken.com/gitkraken-desktop/interface/)
  — configurable panels, WIP/commit panel, status bar, graph, columns, tabs,
  density/zoom, and repository integrations.
* [GitKraken command palette](https://help.gitkraken.com/gitkraken-desktop/command-palette/)
  and [commit graph](https://www.gitkraken.com/features/commit-graph) —
  keyboard-first navigation and focus-oriented visual history.
* [GitHub Desktop commit and review flow](https://docs.github.com/en/desktop/making-changes-in-a-branch/committing-and-reviewing-changes-to-your-project-in-github-desktop)
  — direct file/line inclusion, inline composition, diff preferences, checks,
  protected-branch feedback, and contextual PR creation.
* [GitHub Desktop branch history](https://docs.github.com/en/desktop/making-changes-in-a-branch/viewing-the-branch-history-in-github-desktop)
  — simple Changes/History relationship and multi-commit inspection.
* [GitLab repository UI](https://docs.gitlab.com/user/project/repository/) and
  [branches](https://docs.gitlab.com/user/project/repository/branches/) —
  revision browsing, comparison, history graph, policy, and forge linkage.
* [GitLab blame](https://docs.gitlab.com/user/project/repository/files/git_blame/),
  [Code Owners](https://docs.gitlab.com/user/project/codeowners/), and
  [Web IDE](https://docs.gitlab.com/user/project/web_ide/) — ownership, age,
  editing, staging, and collaborative repository context.
* Apple's Human Interface Guidelines for
  [sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars),
  [split views](https://developer.apple.com/design/human-interface-guidelines/split-views),
  [toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars),
  and [disclosure controls](https://developer.apple.com/design/human-interface-guidelines/disclosure-controls)
  — native navigation, adjacent panes, contextual actions, personalization, and
  progressive disclosure.
