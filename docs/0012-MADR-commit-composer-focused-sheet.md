---
status: accepted
date: 2026-08-16
decision-makers: maccavelli (maintainer)
consulted: 0005-MADR decision P1 and 0005-PLAN §Commit, commit 7bc3802, 0008-PLAN finding B9, 0009-MADR finding H8 and 0009-PLAN G-H8, docs/window_sizing_proposal.md, live code in commit_dialog.dart / commit_composer.dart / repo_status_view.dart
informed: implementers of the Repository workspace and the commit loop
---

# Restore the focused commit sheet as the primary commit surface, keeping the docked composer as the secondary one

## Context and Problem Statement

Committing today happens in a panel docked to the bottom of the Repository
screen. The maintainer reports that the previous design — a self-contained
window/card holding the message and its action buttons — "worked perfectly"
and wants it back.

This record establishes what the original design was, exactly when and why it
changed, what that change cost, and what restoring it should look like.

### What the surface is today

`RepoStatusView` renders a collapsed **Commit…** bar
(`repo_status_view.dart:1888`). Activating it — or `repository.focusCommit`,
bound to **⌘G** (`keymap.dart:427-432`) — calls `_expandCommitComposer`, which
sets `_composerExpanded` and hands a `CommitComposer` to
`RepositoryWorkspaceScaffold`'s `taskDock:` slot
(`repo_status_view.dart:1723-1736`). Accepting collapses it again.

### What it was, and what happened to it

The original surface was `CommitDialog`: a `SizedSheet` pushed over the
workspace, opened by `_openCommitDialog(stagedCount)` from three call sites —
the commit bar, the staged-section action, and a keyboard path.

Commit **`7bc3802`** (*feat(repository): Implement Commit Composer UI*,
2026-08-13 14:36:37) deleted `_openCommitDialog` and all three call sites and
introduced `_composerExpanded` + `taskDock:` in their place.

That commit's own message says it provides "Integration into `CommitDialog` to
provide a focused commit editing experience." It kept the class and removed
every route to it. **`CommitDialog` still exists, still compiles, and is still
covered by `test/commit_dialog_test.dart` and `test/keyboard_shortcuts_test.dart`
— it simply cannot be reached from the running app.** 0009-MADR (finding H8)
already recorded the resulting state in as many words: "`CommitDialog` is
test-only in production."

### Why it changed — and why that is not the whole story

The dock was a deliberate decision, not an accident.
[0005-MADR](0005-MADR-task-centered-adaptive-repository-workspace.md) named the
sheet as a problem: "The commit loop is modal and discontinuous… Users lose
visual continuity between the chosen diff and the message that describes it;
repeated small commits require repeated modal transitions." Its decision **P1**
was "Persistent collapsible commit composer with visible staged scope — Very
high [value] … Removes a modal transition from the highest-frequency end-to-end
task", and it defined the **task dock** as "the persistent or collapsible place
for commit composition."

What is easy to miss is that **0005-PLAN never asked for the sheet to be
removed.** It specified the opposite:

* "Extract one controller/body used by both **dock and focused sheet**."
  (§Commit)
* "Refactor `CommitDialog` into an optional **focused wrapper** around the
  same [controller]."
* "`CommitDialog` remains a wrapper **until the inline composer passes its
  gate**."
* "A composer failure **falls back to the focused `CommitDialog` wrapper**."

The plan described two surfaces over one controller. `7bc3802` built the shared
controller correctly and then shipped only one of the two surfaces. So the
present state is not 0005 fully realised — it is 0005 with its fallback surface
orphaned.

### What the dock siting has cost

Two independent defects trace directly to putting the composer in the task
dock, both found by later audits:

* **0008-PLAN B9 — ⌘G could be a silent no-op.** `AdaptiveWorkspaceLayout`
  hides the dock entirely when `taskDockCollapsed`, which the **Review,
  Investigate and Minimal** presets all set — three of the four. The composer
  was unreachable by its own shortcut under most presets. The fix still stands
  in the code today: `_expandCommitComposer` writes
  `repositoryWorkspacePrefs` and invalidates the provider just to make a
  keystroke visible (`repo_status_view.dart:717-739`). A surface whose
  visibility depends on a persisted layout preference that three presets turn
  off is structurally fragile; the workaround treats the symptom.
* **0009-MADR H8 — the live composer ignored ⌘↩ / ⇧⌘↩.** `commit.confirm` and
  `commit.confirmAndPush` were implemented and tested *on the sheet*
  (`commit_dialog.dart:96-101`). When the sheet stopped being the live surface,
  Keyboard Mappings went on advertising two chords that did nothing. 0009-PLAN
  G-H8 resolved it by binding the handlers on the docked composer and keeping
  "`CommitDialog` as a test/sheet artifact."

Neither defect is an argument that a dock cannot work. Together they are
evidence that this dock, sited in a preference-driven layout slot, has been
paying rent ever since — and that the sheet kept working the whole time.

### What the sheet still has going for it

* It is **written, wired to the shared controller, and tested**. Restoring it
  is a routing change plus polish, not a rewrite.
* It already does the things the dock had to relearn: `commit.*` shortcuts
  bound locally, Escape suppressed while a commit is in flight, and a draft
  that survives dismissal because the controller is keyed by repository and
  session epoch, not by the widget.
* `docs/window_sizing_proposal.md` audited every sheet in the app and marked
  the commit dialog's sizing — "intrinsic, clamped 420–680" — as the single
  **"exemplary"** entry in the table.

## Decision Drivers

* The maintainer's direct report: the focused surface worked; the dock does
  not.
* Composing a commit message is the one moment in the loop that deserves
  undivided attention, and it ends in an irreversible action.
* Both surfaces already share `CommitComposerController`, so carrying both is
  cheap and is what 0005-PLAN specified.
* A primary surface must not depend on a layout preference that three of four
  presets disable.
* 0005's genuine wins — continuity with the diff, no modal churn during a run
  of small commits — must remain available to anyone who prefers them.

## Considered Options

* **A — Restore the focused sheet as the primary surface; keep the docked
  composer available as the secondary one.**
* **B — Restore the sheet and delete the docked composer.**
* **C — Keep the dock, but re-site it as a floating overlay card** over the
  canvas instead of a scaffold slot.
* **D — Keep the status quo and polish the dock** (bigger field, better
  buttons).

## Decision Outcome

Chosen option: **"A — Restore the focused sheet as the primary surface; keep
the docked composer available as the secondary one"**, because it returns the
surface the maintainer reports worked while completing — rather than
contradicting — what 0005-PLAN specified, and because the shared controller
makes the second surface nearly free.

Option B is tempting for simplicity but throws away 0005's reasoning wholesale
on one report. The continuity argument is real for a reviewer making a run of
small commits, and the dock is already built and working; deleting it converts
a preference into a removal.

Option C keeps the fragility the audits found — it is still a surface competing
with the canvas for space and still governed by workspace layout — while
costing a new layer to build and test.

Option D leaves the surface the maintainer specifically asked to move.

### Relationship to 0005

This record **supersedes 0005-MADR decision P1 in its ranking only**: the
persistent composer stops being the default commit surface and becomes the
alternative. It does not supersede 0005's workspace model, its task-dock
primitive, or any other decision in that record, and it **completes** the
0005-PLAN requirement that one controller serve "both dock and focused sheet."

### Accepted trade-off

Committing becomes a modal transition again, which is precisely what 0005-MADR
set out to remove. For a run of many small commits that is real friction. It is
accepted because the draft survives dismissal, because the dock remains one
preference away for anyone who wants the continuous loop, and because the
report from actual daily use is that the focused surface was better.

## The redesigned sheet

Restoring the route alone is not the deliverable; the sheet needs the polish
the request asks for. The following is what "updated, ergonomic, intuitive and
polished" resolves to in this codebase.

**Sizing.** Today `CommitDialog` hardcodes `SizedSheet(width: 760)` around a
`SizedBox(height: 390)`. That fixed height is what the sizing audit did *not*
praise — the "exemplary" entry describes the earlier intrinsic-and-clamped
behaviour. The restored sheet should take an intrinsic height with a sane
clamp, so a one-line subject does not float in a half-empty card and a long
generated body is not scrolled inside a short box.

**Header.** State the commit's scope: repository, branch, and staged count —
"3 staged files on `master`". Today the sheet passes the literal string
`'current branch'` as `branchLabel` (`commit_dialog.dart:110`), which is a
placeholder that ships.

**Body.** The message field, monospace, focused on open, with the
generated-vs-edited state the composer already models.

**Disclosures.** Assistance (recent subjects, template, co-authors) and the GPG
notice stay collapsed by default, as they are now.

**Actions.** `Cancel` · `Accept` · `Accept + Push`. Per the same polish pass
that produced this record, **both accepting verbs are accented** — each is a
complete, correct way to finish — while **Cancel is never accented**. `Accept`
remains the default that ⌘↩ takes; ⇧⌘↩ takes `Accept + Push`.

**Dismissal.** Escape closes and keeps the draft; Escape is suppressed while a
commit is in flight. Both already hold.

**Errors.** A failed commit or push reports inside the sheet and leaves it open
with the message intact, rather than closing onto a toast.

## Consequences

* Good, because the commit message gets a surface sized for it instead of a
  strip competing with the canvas.
* Good, because the primary commit path stops depending on `taskDockCollapsed`,
  retiring the preference-writing workaround in `_expandCommitComposer`.
* Good, because `commit.*` shortcuts return to the surface that has always
  implemented them, and `test/commit_dialog_test.dart` stops testing dead code.
* Good, because 0005-PLAN's two-surface design is finally what ships.
* Neutral, because both surfaces already share one controller; drafts, staged
  signatures, and GPG state are unaffected by which one is open.
* Bad, because committing is modal again — 0005's stated objection, accepted
  above.
* Bad, because two live surfaces is more to keep working than one; mitigated by
  the shared controller and by testing both against it.

## Confirmation

Accepted on review, with the maintainer's direction to keep the docked composer
and route between the two by preference — option A as written. The paired
[0012-PLAN](0012-PLAN-commit-composer-focused-sheet.md) carries the steps. The
gate is:

* `⌘G`, the **Commit…** bar, and the staged-section action all open the sheet,
  under **every** workspace preset — the case 0008-PLAN B9 could not satisfy.
* `⌘↩` and `⇧⌘↩` commit and commit-and-push from the sheet, including while the
  message field holds focus.
* Escape closes with the draft intact; reopening restores it.
* Escape does nothing while a commit is in flight.
* Both accepting buttons are accented, `Cancel` is not.
* A failed commit keeps the sheet open with its message.
* The docked composer still works when chosen, against the same controller.

## More Information

* `7bc3802` — the commit that removed `_openCommitDialog` and its three call
  sites in favour of `taskDock:`.
* [0005-MADR](0005-MADR-task-centered-adaptive-repository-workspace.md) §"The
  commit loop is modal and discontinuous", decision **P1**, and the task-dock
  definition.
* [0005-PLAN](0005-PLAN-task-centered-adaptive-repository-workspace.md) §Commit
  — "one controller/body used by both dock and focused sheet", and the fallback
  clauses.
* [0008-PLAN](0008-PLAN-unified-repository-chrome.md) finding **B9** — ⌘G as a
  silent no-op under three presets.
* [0009-MADR](0009-MADR-ui-ux-debug-pass-backlog.md) finding **H8** and
  [0009-PLAN](0009-PLAN-ui-ux-debug-pass-backlog.md) **G-H8** — dead `commit.*`
  chords, and the decision to keep `CommitDialog` as an artifact.
* `docs/window_sizing_proposal.md` — the sheet-sizing audit that rates the
  commit dialog "exemplary".
* Live code: `lib/features/repository/commit_dialog.dart`,
  `commit_composer.dart`, `commit_composer_controller.dart`,
  `repo_status_view.dart:717-762` and `:1723-1736`.
