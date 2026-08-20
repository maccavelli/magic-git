---
status: executed
date: 2026-08-15
associated-madr: "0010-MADR-in-app-help-book-rewrite.md"
owner: [implementation agent + maintainer review]
target-milestone: after MADR 0010 acceptance (Option B)
verified: 2026-08-20
---

> **Status note (2026-08-20).** Executed through **Phase 6**: the shipped
> `macos/Runner/help_book.json` is version `2.0` with the plan's six
> categories and 24 topics, and `test/help_book_json_test.dart` enforces the
> Phase 6 contract (version pin, `actionId` binding to `kKeymapActionsById`).
> **Phase 7 — maintainer verification — is open by nature**: it needs Mac in
> front of a running `.app`, not an engineer. `status: executed` above refers
> to the engineering phases.

# Plan: Rewrite the in-app Help Book against the current workspace

## Executive Summary & Goal

* **Associated Decision Record**: [0010-MADR-in-app-help-book-rewrite.md](./0010-MADR-in-app-help-book-rewrite.md)
* **Goal**: Replace Help Book v1.1 with an authored v2.0 book that
  describes the shipped 0005/0008 workspace, bind every taught shortcut
  to a `kKeymapActions` id, and lock that contract in
  `test/help_book_json_test.dart` so the book cannot silently drift
  again.
* **Success Criteria**:
  * [ ] Findings **H1–H10** are gone (forbidden-phrase tests fail if
        they return).
  * [ ] Information architecture matches the locked category/topic
        table (G6).
  * [ ] Every Help `shortcuts[]` entry has an `actionId`; keys parse-
        equal that action’s factory default; label contains the
        locked verb (G3).
  * [ ] Topic `menus_and_keymap` catalogs every default-bound
        keymap action (G4).
  * [ ] X1–X5 are not taught as working.
  * [ ] `help_book.json` `version` is `2.0`.
  * [ ] `flutter analyze` and
        `flutter test test/help_book_json_test.dart` are green.
        Maintainer confirms Help ▸ Support & Help on a Mac (Phase 7).

---

## Prerequisites & Dependencies

* **Infrastructure / Credentials**: none. This is JSON + Dart tests +
  a one-line Swift Codable field. No network, no `live-forge`, no
  `.app` build required until Phase 7.
* **Dependencies / Upgrades**: none. Do not add packages. Do not
  generate the book from code (MADR G2).
* **Pre-Flight Checks**:
  * [ ] MADR 0010 Option B is the accepted decision (this plan).
  * [ ] Re-read `macos/Runner/help_book.json` and
        `lib/core/settings/keymap.dart` `kKeymapActions` before
        Phase 0 — if a default binding changed after 2026-08-15,
        the catalog in Phase 5 follows **the live keymap**, not
        this plan’s snapshot.
  * [ ] Do not start this plan’s content work while a parallel
        change is rewriting Help JSON for another reason.

### Standing constraints (`AGENTS.md`)

* `flutter analyze` + the Help test file green before `git add`.
* Never run `live-forge` unprompted.
* Do not commit or push unless asked. No agent-authored commit
  messages (`git commit --no-edit` only).
* Exclude `.flutter-sdk/`, `build/`, `.dart_tool/` from searches.

### Sequencing rules

1. This plan is the executable authority for delivery order.
   Rationale stays in the MADR. A conflict requires a MADR
   amendment or a plan correction — the plan does not silently
   supersede the MADR.
2. Finding IDs (`H1`…`H10`, `M1`…`M14`, `W1`…`W9`, `S1`…`S6`,
   `P1`…`P6`, `F1`…`F8`, `X1`…`X5`, `G1`…`G7`) are stable
   cross-references to
   [0010-MADR-in-app-help-book-rewrite.md](./0010-MADR-in-app-help-book-rewrite.md).
3. Work starts at **Phase 0**. Do not start Phase N+1 while Phase N
   is open.
4. Each phase leaves `flutter test test/help_book_json_test.dart`
   **green**. Never land a contract test that the current book
   cannot pass in the same slice as the content that satisfies it.
5. Unit tests land **in the same work slice** as the JSON/Swift
   they constrain.
6. Do not edit `HelpView.swift` layout, search, or the Help window
   chrome (G1). The only permitted Swift change is an optional
   `actionId` on `KeyboardShortcutRef` (Phase 1).
7. Do not invent chords. Unbound actions are taught as
   “Repository menu” / “command palette” / “Stash ▸ …”.
8. Do not document X1–X5 as working.

---

## Architecture & Technical Design Summary

Help stays a static JSON document decoded by Swift. Dart tests are
the contract. The Flutter keymap remains the source of factory
defaults; Help does not read it at runtime (G2).

```text
kKeymapActions          lib/core/settings/keymap.dart
        │  (defaults only; remaps stay in ⌘/ + Settings)
        ▼
help_book.json          macos/Runner/help_book.json
        │  bundled as a resource (project.pbxproj already lists it)
        ▼
HelpDataLoader          macos/Runner/HelpDataModel.swift
        ▼
HelpView / Legacy       macos/Runner/HelpView.swift
        ▲
Help ▸ Support & Help   MainFlutterWindow.installHelpMenuItems (⌘?)

Contract:
test/help_book_json_test.dart
  • JSON shape + required ids
  • forbidden phrases (H1–H10)
  • must-contain facts per topic
  • shortcuts[].actionId ↔ kKeymapActions default binding
  • menus_and_keymap catalogs every default-bound id (G4)
  • X1–X5 absence
macos/RunnerTests/HelpDataModelTests.swift
  • decode still works; panels category replaces tabs
```

### Locked schema (Phase 1 onward)

`KeyboardShortcutRef` gains an optional field. Existing books
without it still decode.

```swift
public struct KeyboardShortcutRef: Codable, Identifiable {
    public var id: String { label }
    public let label: String
    public let keys: String
    public let actionId: String?   // NEW, optional
}
```

JSON chip:

```json
{ "label": "Sync", "keys": "⌘⇧Y", "actionId": "repository.sync" }
```

* `actionId` is optional in Phase 1 so v1.1 still decodes.
* Phase 6 makes `actionId` **required** on every chip and turns
  G4 on.
* HelpView does **not** display `actionId`.
* Modifier order in `keys` may be `⌘⇧Y` or `⇧⌘Y`. Tests parse
  both with the existing `_parseChord` helper and compare flags +
  key to `KeyBinding`. Do **not** require string equality with
  `KeyBinding.label`.

### Locked information architecture

Category order and ids are the contract. Titles are locked. Icons
are SF Symbols already valid for `Label(..., systemImage:)`.

| # | category `id` | title | icon | topic `id`s (order) |
| --- | --- | --- | --- | --- |
| 1 | `getting_started` | Getting Started | `sparkles` | `overview`, `quickstart`, `clone_create`, `tabs_workspaces` |
| 2 | `workspace` | The Workspace | `rectangle.3.offgrid` | `workspace_chrome`, `file_view_and_output`, `dashboard_recovery_activity`, `settings` |
| 3 | `panels` | Panels | `square.stack` | `tab_repository`, `tab_history`, `tab_branches`, `tab_stashes`, `tab_forge`, `tab_worktrees` |
| 4 | `files` | Files, Diffs & Windows | `doc.text` | `viewer_and_remote_edit`, `diffs_blame_history`, `drag_and_drop`, `secondary_windows` |
| 5 | `commands` | Commands & Shortcuts | `command` | `feature_palette`, `menus_and_keymap` |
| 6 | `safety` | Safety & Diagnostics | `exclamationmark.triangle` | `feature_ssh`, `undo_recovery`, `tool_health`, `output_log` |

**Delete** categories `tabs`, `features`, `troubleshooting`. Move
their surviving topics as listed. Do not leave empty categories.

First-open topic remains `overview` (first topic of first category;
`HelpView` already selects that).

### Locked voice

* Name controls as they appear: **Settings**, **Stash Changes**,
  **Host Key Changed**, **Inbox**, **Fetch & Prune**, **Commit…**,
  **Recent Repositories**, **Connection interrupted**.
* One callout, on `overview` **and** `menus_and_keymap` only:
  “Help lists factory-default shortcuts. Your remaps are in
  Keyboard Shortcuts (⌘/) and Settings → Keyboard Mappings.”
* Native Help is ⌘? (not in `kKeymapActions`). Flutter shortcuts
  sheet is ⌘/ (`global.showShortcuts`). Never conflate them (G7).
* Commits are unsigned (`--no-gpg-sign`). Stash Changes always
  uses `--include-untracked`. Force push with lease ≠ force push.

### Locked OUT list (must not appear as working)

Scan the whole book (Phase 6 test). Fail if any of these appear
as a taught capability:

| ID | Forbidden as a working claim | Allowed mention |
| --- | --- | --- |
| X1 | Inspector pane does something / Focus Inspector is a working pane | Investigate preset may be named; say the inspector slot is unused |
| X2 | Native title bar / hybrid title bar | — |
| X3 | `issue:`, `request:`, `ci:` as palette scopes that return results | Must not appear in the prefix list |
| X4 | Drop a folder on the window to open a repo | — |
| X5 | Prompt on first connection to a new SSH host | Silent TOFU + **Host Key Changed** |

---

## Phased Implementation Plan

### Phase 0 — Stop the lying (H1–H10, M4, M7)

* **Objective**: v1.1 must no longer teach a wrong verb. Same
  four categories. No IA reshape yet, so existing tests stay valid.
* **Files**: `macos/Runner/help_book.json`,
  `test/help_book_json_test.dart` only.

#### 0.1 — Surgical JSON edits (exact)

In `tab_repository` “Diff Inspection & Committing” paragraph,
**delete** “Toggle 'Amend last commit' or press ⌘↩ to rewrite HEAD.”
Replace with:

> Enter a commit message in the composer (⌘G focuses it; it lives
> in the task dock, not a permanent bottom subject/description
> pair). ⌘↩ confirms a new commit. To rewrite HEAD, choose
> Repository ▸ Amend Last Commit… or, on the History panel with
> HEAD selected, Amend last commit.

Retitle the shortcut `Discard Unstaged Changes` →
`Discard Changes to Selected File` (M4). Keep keys `⌘⇧⌫`.

In `tab_stashes` “Creating & Inspecting Stashes”, **delete**
“optionally include untracked files” and the implication that
Stash Changes prompts. Replace with:

> Stash Changes (context bar, ⇧⌘S) immediately runs
> `git stash push --include-untracked` with no prompt. Untracked
> files are always included. To set a message, use Stash ▸
> Stash with Message….

In `tab_forge` items, **delete** “Filter PRs/MRs by status (Open,
Merged, Closed, Mine).” Replace with:

> Switch Inbox and Browse. Inbox chips filter All / PRs or MRs /
> CI / Issues. Lists show open items plus a text filter; merged
> and closed work is not a status chip.

In `tab_branches` shortcuts, **delete** the chip
`{"label": "Sync / Fetch Remotes", "keys": "⌘⇧Y"}` (H4). Do not
replace it with another Branches chord. Retitle
`Create New Branch` → `Focus New Branch Field` (M7).

In `tab_branches` “Branch Operations”, replace “Press ⌘B to create
a new branch from current HEAD” with:

> Press ⌘B to open the New branch sheet (name + start-at, default
> selected ref or HEAD). After Create, choose Here or New worktree.

**Delete** “Use the context menu to Rebase active branch onto
target branch or Delete (⌘⌫).” Replace with:

> Delete the selected branch with ⌘⌫ (unmerged branches confirm).
> Rebase the current branch onto another by dragging that branch
> onto HEAD — there is no Rebase item on the context menu.

In `tab_worktrees` “Tab Integration” callout, **delete** “loads it
as a tab in your multi-tab workspace.” Replace with:

> Opening a worktree adds a checkout tab on the Worktrees strip
> (Overview \| that checkout). It is not a File tab. Each checkout
> tab has Changes, History, Branches, and Stashes. Forge stays on
> the repository, not the checkout.

In `quickstart` Local Repositories paragraph, **delete** “or drop
the folder onto the window.” Keep Connections Manager + Recents +
Finder panel.

In `feature_ssh` Host Key paragraph, **delete** “new remote host
or”. Replace with:

> The first time Magic Git sees a host it records the key silently
> (TOFU). If a known host presents a different fingerprint, a
> Host Key Changed dialog offers Cancel Connection or Refresh Key
> and Continue. Settings ▸ Known Hosts can Forget a recorded key.

In `feature_palette` Global Undo Engine, **delete** “staging,” from
the list of undoable actions. Change shortcut label
`Undo Last Action` → `Undo Git Operation`.

Do **not** bump `version` yet (stays `1.1` until Phase 6).

#### 0.2 — Forbidden-phrase tests (same slice)

In `test/help_book_json_test.dart` add:

```dart
test('Help does not teach the 0010 HIGH lies', () {
  final book = File('macos/Runner/help_book.json').readAsStringSync();
  const forbidden = [
    'rewrite HEAD',
    'optionally include untracked',
    'Open, Merged, Closed, Mine',
    'Sync / Fetch Remotes',
    'drop the folder',
    "new remote host or if a server's fingerprint",
  ];
  for (final phrase in forbidden) {
    expect(book, isNot(contains(phrase)), reason: phrase);
  }
  final worktrees = /* topic tab_worktrees encoded json */;
  expect(worktrees, isNot(contains('multi-tab workspace')));
});
```

Keep the existing H18 and word-overlap tests — they must still pass
after the label fixes (`Focus New Branch Field` intersects
`Focus new branch field`; `Discard Changes to Selected File`
intersects `Discard changes to selected file`; `Undo Git Operation`
intersects `Undo Git Operation`).

*Required tests:* `flutter test test/help_book_json_test.dart`

*Exit:* H1–H10 sentences gone; existing structural tests still
green; book still v1.1 / four categories.

---

### Phase 1 — Schema and test helpers

* **Objective**: Teach the decoder `actionId` and add helpers the
  later phases will use. Do **not** require `actionId` on every
  chip yet (v1.1 chips stay valid).
* **Files**: `macos/Runner/HelpDataModel.swift`,
  `macos/RunnerTests/HelpDataModelTests.swift` (optional field
  still decodes the existing sample),
  `test/help_book_json_test.dart`.

#### 1.1 — Swift

Add `public let actionId: String?` to `KeyboardShortcutRef`.
Codable synthesis handles absence. Do not change `id`.

Add one decode assertion in `HelpDataModelTests` that a chip
**with** `"actionId": "global.commandPalette"` round-trips.

#### 1.2 — Dart helpers in `help_book_json_test.dart`

Extract (keep `_parseChord`):

* `Map<String, dynamic> topicById(String id)`
* `Iterable<Map<String, dynamic>> allShortcuts()`
* `bool chordEquals(({...}) parsed, KeyBinding b)` — compare
  meta/shift/alt/control + case-insensitive key character. Map
  Help `↩` ↔ enter, `⌫` ↔ backspace, `Space` ↔ space, `,` ↔ comma,
  `=` ↔ equal, `−`/`-` ↔ minus, `⎋` ↔ escape.

Add a **non-fatal** test:

```
when a chip has actionId, it must exist in kKeymapActionsById
and chordEquals(parsed keys, action.defaultBindings.first)
```

Chips without `actionId` are ignored by this test. Do not fail
the suite if some chips omit it.

Do **not** turn on G4 or required-new-topic-id tests yet.

*Required tests:* `flutter test test/help_book_json_test.dart`

*Exit:* Swift still decodes the bundled book; optional `actionId`
works; no content rewrite required.

---

### Phase 2 — Information architecture + Getting Started + Workspace

* **Objective**: Reshape the book to the six categories. Write
  Getting Started and The Workspace for real (not stubs). Panel
  and other surviving topics **move** with their Phase 0 text;
  they are rewritten in later phases.
* **Files**: `macos/Runner/help_book.json`,
  `test/help_book_json_test.dart`,
  `macos/RunnerTests/HelpDataModelTests.swift`.

#### 2.1 — Reshape

1. Rename category `tabs` → `panels`, title **Panels**, icon
   `square.stack`. Keep the six `tab_*` topics in the same order.
2. Create categories `workspace`, `files`, `commands`, `safety`
   with the topic lists above.
3. Move `feature_palette` into `commands`.
4. Move `feature_ssh`, `tool_health`, `output_log` into `safety`.
5. Delete empty `features` and `troubleshooting`.
6. Update `test/help_book_json_test.dart`:
   * required category ids become the six in the IA table
     (exact order: `getting_started`, `workspace`, `panels`,
     `files`, `commands`, `safety`);
   * required topic ids become the **full** IA list;
   * the old `'tabs'` / `'features'` / `'troubleshooting'`
     expects are deleted;
   * add `expect(categoryIds, isNot(contains('tabs')))`;
   * add `expect(book, isNot(contains('Main Application Tabs')))`.
7. Update `HelpDataModelTests.testLoadBookFromBundleOrFile` to
   look up `panels` instead of `tabs`.

New topics in this phase must have non-empty `summary`,
`keywords` (≥ 3), and `sections`. Empty `sections: []` fails the
existing structural test — that is intended.

#### 2.2 — Locked facts (must appear as substrings)

Add a `mustContain` map test. Every string is required exactly
(case-sensitive as written, except where noted).

**`overview` (rewrite, M13, S6, G2, G7)**

Must contain:

* `six sidebar panels`
* `File tabs`
* `⌘?`
* `⌘/`
* `factory-default`
* `Keyboard Mappings`

Must not contain: `Main Application Tabs`.

Shortcuts (with `actionId` from this phase on for chips you
touch): `global.commandPalette` ⌘K, `global.refresh` ⌘R,
`global.openSettings` ⌘, .

Prose must still say Magic Git is a native macOS Git client that
drives `git` / `gh` / `glab` on a local Mac or a remote POSIX host
over SSH without cloning locally. Keep the sandbox callout for
local repos (security-scoped bookmarks).

**`quickstart` (rewrite, H6 already, M9)**

Must contain:

* `Connections Manager`
* `Recent Repositories`
* `Add existing repository`
* `password`
* `Connection interrupted`
* `Stop Retrying`
* `Connection lost`
* `Start Fresh`

Must not contain: `drop the folder`, `Drop the folder`.

Do not mention folder-drop on the window (X4).

**`clone_create` (new, S4)**

Must contain:

* `Clone repository`
* `Create repository`
* `Destination`
* `Review`
* `partial folder`

Describe the two wizards from Connections and the command
palette, in this order:

* Clone: Destination → Source (GitHub/GitLab browse or URL) →
  Location → Review. A failed or cancelled clone deletes the
  partial folder.
* Create: Destination → Source (empty vs existing folder) →
  Remote (GitHub/GitLab create, custom URL, or none) → Details
  (name, initial branch, first commit) → Review.

**`tabs_workspaces` (new, S1–S3)**

Must contain:

* `⌘T`
* `Close Tab`
* `⌘W`
* `8`
* `Saved Workspaces`
* `uncommitted`
* `conflicts`

Facts: File ▸ New Tab is ⌘T; Close Tab is File-menu only (⌘W
closes a **viewer** window, not a tab); cap 8; strip hides with
one tab; orange = uncommitted, red = conflicts; middle-click
closes; quit / close tab / log out / disconnect confirm when the
tree is dirty or a merge/rebase/cherry-pick/revert is in progress.

Shortcuts: `global.newTab` only. Do not invent a Close Tab chord.

**`workspace_chrome` (new, W1–W3, W8, W9)**

Must contain:

* `720`
* `1200`
* `Fetch`
* `Pull`
* `Push`
* `Sync`
* `Review`
* `Commit`
* `Investigate`
* `Minimal`

Facts: compact &lt; 720 (navigator XOR canvas; sync group
collapses; sidebar toggle on the bar); standard 720–1199; wide
≥ 1200. Context bar: identity, watch-health dot, status summary,
SSH link chips, Back/Forward, Fetch · Pull · Push · Sync with
overflow variants, Stash, Refresh, Activity, view options.
Presets Review / Commit / Investigate / Minimal; default Review;
labels off. Native menus File / Repository / Branch / Stash /
Forge / Worktree; dimmed items stay visible. View ▸ Focus
Navigator/Canvas/Task Dock/Activity exist and are **unbound**.
Do **not** say Focus Inspector does anything (X1). Do **not**
say there is a native title bar (X2).

**`file_view_and_output` (new, W4, M12 partial)**

Must contain:

* `⇧⌘E` or `⌘⇧E` (either modifier order)
* `1200`
* `Pin`
* `⇧⌘O` or `⌘⇧O`
* `Output`

Facts: File View is View ▸ Show File View / ⇧⌘E; on by default
but **hidden until width ≥ 1200 unless pinned**; pin / hide /
collapse all. There is no Changes \| Files switch. Output is a
docked command log under the Repository canvas, visible by
default, ⇧⌘O.

Shortcuts: `global.toggleFileView`, `global.toggleOutput`.

**`dashboard_recovery_activity` (new, W5, W6)**

Must contain:

* `Dashboard`
* `⇧⌘D` or `⌘⇧D`
* `Recovery`
* `reflog`
* `Activity`

Facts: Dashboard (⇧⌘D) is session telemetry, not the Forge tab;
heatmap is the last 200 commits. Recovery (⇧⌘U) is a sheet over
HEAD’s reflog plus `refs/magic-git/snapshots/`. Activity is the
context-bar bell → live sheet (running/failed ops, reveal in
Output, undo newest).

Shortcuts: `global.toggleDashboard`, `global.toggleRecovery`.

**`settings` (new, S5, W7)**

Must contain:

* `Command timeouts`
* `--no-gpg-sign`
* `Fast-forward only`
* `Auto-fetch`
* `Known Hosts`
* `Keyboard Mappings`
* `Comfortable`

Facts: network timeout default 3 min, commit 5 min, floor 5 s;
committer identity blank → host git config; always
`--no-gpg-sign`; Pull/Sync default fast-forward only; push tags
off by default; auto-fetch default every 5 min; density default
Comfortable; High contrast; Reduce Motion follows macOS; Known
Hosts Forget saves immediately; Keyboard Mappings save
immediately; External tools + Scan.

Shortcut: `global.openSettings`. Label **Open Settings** (not
Preferences).

*Required tests:* update category/topic id test; `mustContain` for
the eight topics above; `flutter test test/help_book_json_test.dart`.

*Exit:* six categories in the locked order; every IA topic id
exists; Getting Started + Workspace teach W1–W9 and S1–S6;
panels still have Phase 0 text.

---

### Phase 3 — Rewrite the six panel topics (M1–M8, P1–P6)

* **Objective**: Each `tab_*` topic describes the live panel:
  context-bar primary, default chords, menu-only verbs, and the
  M/P facts. Keep topic ids.
* **Files**: `macos/Runner/help_book.json`,
  `test/help_book_json_test.dart` (`mustContain` / `mustNotContain`
  for these six).

Every panel topic starts with one sentence: “The N panel (⌘n) is
a sidebar page, not a File tab.” (M1)

#### 3.1 — `tab_repository` (H1/H8 already, M2–M4, P1)

Shortcuts (all with `actionId`):

| label (must include first significant keymap word) | keys | actionId |
| --- | --- | --- |
| Toggle Stage for Selected File | Space | `repository.toggleStage` |
| Stage All Changes | ⌘⇧A | `repository.stageAll` |
| Discard Changes to Selected File | ⌘⇧⌫ | `repository.discard` |
| Toggle Side-by-Side Diff | ⌥⌘S | `repository.toggleSplitDiff` |
| Toggle Ignore Whitespace in Diff | ⌥⌘W | `repository.toggleIgnoreWhitespace` |
| Toggle Expanded Diff Context | ⌥⌘X | `repository.toggleExpandContext` |
| Focus Commit Composer | ⌘G | `repository.focusCommit` |
| Confirm Commit | ⌘↩ | `commit.confirm` |
| Commit and Push | ⌘⇧↩ | `commit.confirmAndPush` |
| Fetch | ⌘⇧F | `repository.fetch` |
| Pull | ⌘⇧L | `repository.pull` |
| Push | ⌘⇧P | `repository.push` |
| Sync | ⌘⇧Y | `repository.sync` |
| Stash Changes | ⌘⇧S | `repository.stash` |
| Force Push with Lease | ⌃⌘U | `repository.forcePush` |
| Switch to Repository | ⌘1 | `global.panel1` |

Must contain: `Conflicts`, `Staged`, `Untracked`, `Hide reviewed`,
`Mark Resolved`, `task dock`, `Amend Last Commit`, `Abort`.

Must not contain: `rewrite HEAD`, `bottom pane` as the home of
subject+description (say task dock / Commit… bar).

Required facts (P1, M2, M3):

* Sections: Conflicts / Staged / Changes / Untracked; filter
  chips; hide reviewed; group by status or directory; Review
  selected / Review all visible; multi-file review.
* Line staging: unified + whitespace-exact + blame-off only;
  then Stage / Unstage / Discard Selection. Split and ignore-
  whitespace diffs are read-only. Per-hunk buttons exist. Do
  **not** list ⌥↑/↓ or ⌘⇧K as keymap shortcuts (they are not in
  `kKeymapActions`).
* Conflicts: Ours / Theirs / Mark Resolved; pending banner
  Continue / Abort.
* Composer: collapsed Commit… bar; ⌘G expands the task dock;
  Accept / Accept + Push (⌘⇧↩); assistance (recent subjects,
  template); policy advisory; no amend checkbox. Amend is
  Repository ▸ Amend Last Commit… (unbound).
* Menu-only (name the menu, no chord): Pull with Rebase, Pull
  with Merge, Push and Set Upstream, Push Tags, Force Push (no
  lease), Unstage All, Abort Pending Operation.
* Drag-to-stage banner on the change list.

#### 3.2 — `tab_history` (M5, M6, P2)

Keep the H18 sentence: All Branches is a filter-bar icon with
**no** shortcut; ⌘⇧B is Checkout Selected Commit.

Shortcuts:

| label | keys | actionId |
| --- | --- | --- |
| Checkout Selected Commit | ⌘⇧B | `history.checkout` |
| Branch from Selected Commit | ⌘⇧N | `history.branchFrom` |
| Cherry-pick Selected Commit | ⌥⌘C | `history.cherryPick` |
| Interactive Rebase from Selected Commit | ⌘⇧R | `history.rebaseFrom` |
| Amend Last Commit | ⌘⇧↩ | `history.amend` |
| Copy Commit SHA | ⌘C | `history.copySha` |
| Filter Commits | ⌘F | `history.filter` |
| Zoom Commit List In | ⌘= | `history.zoomIn` |
| Zoom Commit List Out | ⌘- | `history.zoomOut` |
| Reset Commit List Zoom | ⌘0 | `history.zoomReset` |
| Open History in New Window | ⌘⇧H | `global.openHistoryWindow` |
| Switch to History | ⌘2 | `global.panel2` |

Must contain: `author:`, `file:`, `Hide merges`, `Reset`,
`minimap`, `filter bar`.

Facts: context-bar primary is Refresh; All Branches is a filter-
bar icon (not a labeled toolbar button); pop-out is the
`macwindow` icon when the main window offers it; single-commit
menu includes Checkout, Branch from…, Branch from… in a new
worktree…, Tag…, Cherry-pick, Revert, Interactive rebase, Reset
soft/mixed/hard, Amend (HEAD only), Copy SHA; two-commit
compare; drop a branch onto a commit for merge / rebase / move;
pinch and ⌘-scroll also zoom (unremappable).

#### 3.3 — `tab_branches` (H4/H10 already, M7, P3)

Shortcuts:

| label | keys | actionId |
| --- | --- | --- |
| Focus New Branch Field | ⌘B | `branches.newBranch` |
| Create Tag | ⌘⇧T | `branches.createTag` |
| Merge Selected Branch | ⌘⇧M | `branches.merge` |
| Delete Selected Branch | ⌘⌫ | `branches.delete` |
| Switch to Branches | ⌘3 | `global.panel3` |

Must contain: `Browse`, `Review`, `Fetch & Prune`, `New worktree`,
`Publish`.

Must not contain: `Sync / Fetch Remotes`, `⌘⇧Y` as a Branches
chord, context-menu Rebase.

Facts: master–detail; Browse \| Review; pin / hide / folder
grouping; Fetch & Prune is the context-bar primary (no default
chord); Review offers compare, publish, Create PR/MR, Open CI;
bulk pin/hide/delete-if-merged; checkout in a new worktree;
empty selection shows dashboard stats; rebase is a drop onto
HEAD (`DropOp.rebase`). Menu-only: Publish Branch, Create Pull
or Merge Request, Compare with Base, Open CI.

#### 3.4 — `tab_stashes` (H2 already, P4)

Shortcuts:

| label | keys | actionId |
| --- | --- | --- |
| Stash Changes | ⌘⇧S | `repository.stash` |
| Apply Selected Stash | ⌥⌘A | `stashes.apply` |
| Pop Selected Stash | ⌥⌘P | `stashes.pop` |
| Drop Selected Stash | ⌘⌫ | `stashes.drop` |
| Switch to Stashes | ⌘4 | `global.panel4` |

Must contain: `--include-untracked`, `Stash with Message`,
`--index`, `Clear all`.

Facts: Stash Changes is immediate and always includes untracked;
message is Stash ▸ Stash with Message…; Apply keeps the stash,
Pop removes it, Drop deletes (confirm); apply/pop can use
`--index`; Create branch from stash; Apply/Pop latest and Clear
all are menu-only; filter field on the list.

#### 3.5 — `tab_forge` (H3 already, P5)

Shortcuts:

| label | keys | actionId |
| --- | --- | --- |
| New Pull Request | ⌘N | `github.newPr` |
| New Merge Request | ⌘N | `gitlab.newMr` |
| Approve Selected Pull Request | ⌥⌘A | `github.approve` |
| Approve Selected Merge Request | ⌥⌘A | `gitlab.approve` |
| Merge Selected Pull Request | ⌘⇧M | `github.merge` |
| Merge Selected Merge Request | ⌘⇧M | `gitlab.merge` |
| Re-run Selected Workflow Run | ⌥⌘R | `github.rerun` |
| Retry Selected Pipeline | ⌥⌘R | `gitlab.retry` |
| Switch to Forge | ⌘5 | `global.panel5` |

Two chips may share a chord when `actionId`s are in different
scopes (GitHub vs GitLab). That is required, not a conflict.

Must contain: `Inbox`, `Browse`, `merge readiness`, `New Issue`,
`auto-merge`.

Must not contain: `Open, Merged, Closed, Mine`.

Facts: `gh` / `glab`; Inbox \| Browse; Inbox chips All / PRs|MRs /
CI / Issues; Browse sections Issues, PRs/MRs, Labels, Milestones,
Releases, Workflow Runs/Pipelines; checkout button label is
**Check out**; merge-readiness strip; Enable/Cancel auto-merge
(cancel is also on the Forge menu); Update branch / Rebase onto
target; New Issue is menu-only (`forge.newIssue`); context-bar
primary is New Pull Request or New Merge Request. Do not call
Dashboard the Forge tab.

#### 3.6 — `tab_worktrees` (H5 already, M8, P6)

Shortcuts:

| label | keys | actionId |
| --- | --- | --- |
| Switch to Worktrees | ⌘6 | `global.panel6` |

No other default-bound worktree chords exist. List verbs as
Worktree menu / palette: Add, Open, Lock, Unlock, Move, Repair,
Repair All, Prune, Remove.

Must contain: `Overview`, `Changes`, `nested`, `Lock`, `Prune`,
`security-scoped`.

Must not contain: `multi-tab workspace`.

Facts: Overview table (main / detached / locked / missing);
checkout tabs are **not** File tabs; sub-panels Changes /
History / Branches / Stashes; Forge omitted on purpose; Add
sheet: new / existing / detached, copy ignored files, post-create
command; security-scoped bookmark on **local** add only; SSH has
no sandbox bookmark; a worktree created in the terminal prompts
once on first open.

*Required tests:* `mustContain` / `mustNotContain` for the six
topics; H18 still green; every new chip has `actionId`.

*Exit:* P1–P6 and M1–M8 closed in prose; no HIGH phrase regresses.

---

### Phase 4 — Files, diffs, windows, drag-and-drop (F1–F7)

* **Objective**: Write the four `files` topics from the locked
  facts. No new renderer features.
* **Files**: `macos/Runner/help_book.json`,
  `test/help_book_json_test.dart`.

#### 4.1 — `viewer_and_remote_edit` (F1, F2)

Shortcuts:

| label | keys | actionId |
| --- | --- | --- |
| Close Viewer Window | ⌘W | `viewer.close` |
| Copy File Contents | ⌘⇧C | `viewer.copyContents` |
| Toggle Word Wrap | ⌥Z | `viewer.wordWrap` |
| Find in File | ⌘F | `viewer.find` |

Must contain: `Code`, `Preview`, `Open in Default App`,
`temp`.

Facts: floating viewer windows (not File View); Code vs Preview;
Markdown preview links open in the browser; local Open uses the
macOS opener; remote Open copies to a temp file, watches the
**parent directory**, uploads on save, conflict overwrite.

#### 4.2 — `diffs_blame_history` (F3, F4, F5, M3 remainder)

Must contain: `blame`, `--follow`, `LFS`, `gitignore`.

Facts: blame gutter off by default + Blame sheet; file history
(`git log --follow`) from the **file tree**, not the Changes
list; image before/after; LFS pointers are pointers (`git lfs
pull`), not “binary image”; tree extras: View file, Open, Mark
Resolved, staged/unstaged halves, Add to .gitignore, Delete
(undoable).

No invented hunk-nav chords.

#### 4.3 — `drag_and_drop` (F7, H10 restated)

Must contain: `Esc`, `cherry-pick`, `Stage`, `Unstage`.

Facts (and only these routes):

* Unstaged files → staging banner = Stage; staged → Unstage.
* Files → Stashes = path-scoped stash (`--include-untracked`).
* Commit → Repository = cherry-pick (confirm).
* Local branch → Forge = create PR/MR.
* Commit or branch → Worktrees = Add Worktree sheet.
* History row: drop a branch = merge / no-ff / squash / rebase /
  move branch here.
* Branch row: drop a commit = cherry-pick onto that branch; drop
  a branch on HEAD = merge or rebase.
* Esc cancels a drag.

#### 4.4 — `secondary_windows` (F6)

Must contain: `⇧⌘H` or `⌘⇧H`, `detached`, `pop-out`,
`key equivalent`.

Facts: native History window is a singleton (⇧⌘H / View /
palette); detached repo window is full Status for that path;
diff pop-out is an **in-window** float, not a native window;
while a pop-out is key, native menu key-equivalents are stripped
so they do not steal from the detached session (0009 H16).

Shortcut: `global.openHistoryWindow`.

*Required tests:* `mustContain` for the four topics.

*Exit:* F1–F7 closed.

---

### Phase 5 — Commands catalog (G4) + Safety (F8, M10–M14)

* **Objective**: Rewrite palette and SSH/tool/output topics.
  Add `undo_recovery` and the complete factory-default catalog
  that makes G4 implementable in Phase 6.
* **Files**: `macos/Runner/help_book.json`,
  `test/help_book_json_test.dart`.

#### 5.1 — `feature_palette` (M10, X3)

Must contain: `go:`, `git:`, `forge:`, `app:`, `branch:`,
`commit:`, `file:`, `stash:`, `worktree:`.

Must not contain: `issue:`, `request:`, `ci:`.

Facts: ⌘K; prefixes as above; `file:` is **changed** paths only
(not the whole tree); Open Settings is a command, not a
settings-key search; clone/create/saved workspaces/manage
connections live under `app:`; `commit.*` and `viewer.*` are
intentionally absent from the palette catalog. Do not promise
entity search of Settings keys.

Shortcuts: `global.commandPalette`, `global.showShortcuts`.

#### 5.2 — `menus_and_keymap` (W8, G2, G4, G7)

Must contain: `factory-default`, `⌘?`, `⌘/`, `File`,
`Repository`, `Branch`, `Stash`, `Forge`, `Worktree`.

This topic is the **G4 catalog**. Its `shortcuts` array must
include **one chip per default-bound keymap action**,
`actionId` = that action’s id, `keys` parse-equal its first
default binding, `label` containing the first significant word
of `KeymapAction.label` (see Phase 6 verb rule).

Duplicate chips already added on other topics are fine. This
topic must still be complete on its own so G4 has one
authoritative list.

**Default-bound ids to catalog** (62). If `kKeymapActions`
gains or loses a default binding after this plan is written,
**the live list wins** — implement G4 as “every action whose
`defaultBindings` is non-empty”, not as a frozen copy of this
table.

| id | default (Help `keys` may reorder modifiers) |
| --- | --- |
| `global.refresh` | ⌘R |
| `global.openSettings` | ⌘, |
| `global.showShortcuts` | ⌘/ |
| `global.commandPalette` | ⌘K |
| `global.undo` | ⌘Z |
| `global.redo` | ⌘⇧Z |
| `global.panel1` | ⌘1 |
| `global.panel2` | ⌘2 |
| `global.panel3` | ⌘3 |
| `global.panel4` | ⌘4 |
| `global.panel5` | ⌘5 |
| `global.panel6` | ⌘6 |
| `global.toggleOutput` | ⌘⇧O |
| `global.toggleFileView` | ⌘⇧E |
| `global.toggleDashboard` | ⌘⇧D |
| `global.toggleRecovery` | ⌘⇧U |
| `global.openHistoryWindow` | ⌘⇧H |
| `global.newTab` | ⌘T |
| `repository.fetch` | ⌘⇧F |
| `repository.push` | ⌘⇧P |
| `repository.pull` | ⌘⇧L |
| `repository.stash` | ⌘⇧S |
| `repository.sync` | ⌘⇧Y |
| `repository.stageAll` | ⌘⇧A |
| `repository.forcePush` | ⌃⌘U |
| `repository.toggleSplitDiff` | ⌥⌘S |
| `repository.toggleIgnoreWhitespace` | ⌥⌘W |
| `repository.toggleExpandContext` | ⌥⌘X |
| `repository.toggleStage` | Space |
| `repository.discard` | ⌘⇧⌫ |
| `repository.focusCommit` | ⌘G |
| `branches.newBranch` | ⌘B |
| `branches.createTag` | ⌘⇧T |
| `branches.merge` | ⌘⇧M |
| `branches.delete` | ⌘⌫ |
| `commit.confirm` | ⌘↩ |
| `commit.confirmAndPush` | ⌘⇧↩ |
| `history.copySha` | ⌘C |
| `history.checkout` | ⌘⇧B |
| `history.branchFrom` | ⌘⇧N |
| `history.cherryPick` | ⌥⌘C |
| `history.rebaseFrom` | ⌘⇧R |
| `history.amend` | ⌘⇧↩ |
| `history.filter` | ⌘F |
| `history.zoomIn` | ⌘= |
| `history.zoomOut` | ⌘- |
| `history.zoomReset` | ⌘0 |
| `stashes.apply` | ⌥⌘A |
| `stashes.pop` | ⌥⌘P |
| `stashes.drop` | ⌘⌫ |
| `gitlab.newMr` | ⌘N |
| `gitlab.approve` | ⌥⌘A |
| `gitlab.merge` | ⌘⇧M |
| `gitlab.retry` | ⌥⌘R |
| `github.newPr` | ⌘N |
| `github.approve` | ⌥⌘A |
| `github.merge` | ⌘⇧M |
| `github.rerun` | ⌥⌘R |
| `viewer.close` | ⌘W |
| `viewer.copyContents` | ⌘⇧C |
| `viewer.wordWrap` | ⌥Z |
| `viewer.find` | ⌘F |

Also list, **without chips**, the unbound verbs (menu/palette
only). Do not invent chords for: `global.toggleSidebar`,
`global.closeTab`, `global.focusNavigator`,
`global.focusCanvas`, `global.focusInspector`,
`global.focusTaskDock`, `global.focusActivity`,
`repository.pullRebase`, `repository.pullMerge`,
`repository.pushSetUpstream`, `repository.pushTags`,
`repository.forcePushHard`, `repository.unstageAll`,
`repository.amend`, `repository.abortPending`,
`branches.publish`, `branches.createRequest`,
`branches.openCi`, `branches.compare`,
`stashes.stashWithMessage`, `stashes.applyLatest`,
`stashes.popLatest`, `stashes.clearAll`,
`worktrees.add` … `worktrees.remove`,
`forge.newIssue`, `forge.cancelAutoMerge`.

For `global.focusInspector`, one sentence: the menu item exists
and is unbound; the inspector slot is not populated (X1).

Note shared chords across scopes (⌘⇧M, ⌥⌘A, ⌘N, ⌘⇧↩, ⌘⌫) and
that only one scope is active at a time.

#### 5.3 — `feature_ssh` (H7 already, M14)

Must contain: `TOFU`, `Host Key Changed`, `local`, `password`.

Facts: same UI for local (`Process.start`) and remote (SSH);
PEM + passphrase + password + custom port; silent TOFU; Host
Key Changed only on mismatch; reconnect overlay **Connection
interrupted** with attempt + elapsed; Stop Retrying →
Connection lost; Cancel fully disconnects and confirms if the
session is at risk.

#### 5.4 — `undo_recovery` (H9 already, F8)

Must contain: `Undo Git Operation`, `Nothing to redo`,
`staging`.

Facts: ⌘Z undoes the last **git** operation (toast ~5 s, hover
pauses); journal kinds = commit, amend, reset, checkout,
create/delete branch or tag, stash drop/pop/clear/branch,
discard, remove files, and hard-reset-shaped
merge/rebase/cherry-pick/revert; **staging is not undoable**;
⌘⇧Z redo is only atomic tag create/delete; empty journal toasts
“Nothing to undo” / “Nothing to redo”; Edit ▸ Undo is text
undo; Recovery sheet is for state ⌘Z cannot reach.

Shortcuts: `global.undo`, `global.redo`,
`global.toggleRecovery`.

The word `staging` must appear in a sentence that says it is
**not** undoable (the Phase 6 X/H scan allows this).

#### 5.5 — `tool_health` (M11)

Must contain: `live connection`, `Scan environment`,
`sideload`, `essential`.

Must not contain: `on startup` as the moment the check runs.

Facts: probe runs on a live connection, not the landing page;
banner + Settings ▸ External tools ▸ Scan; essential vs
feature vs outdated; OS-filtered (Linux not blamed for
`fswatch`); one-click install when safe; sideload drop zone
for binaries (this is **not** X4).

#### 5.6 — `output_log` (M12)

Trim Recovery into a one-line pointer to
`dashboard_recovery_activity` / `undo_recovery`. Keep Output:
docked log of git/ssh invocations, stdout/stderr, exit codes;
⇧⌘O; also receives install output from the doctor.

Shortcuts: `global.toggleOutput` only (Recovery chip moves
out).

*Required tests:* `mustContain` / `mustNotContain` for these
topics; a **preview** G4 test may be added as `skip: true` or
omitted until Phase 6.

*Exit:* catalog chips exist for all 62 default-bound ids;
palette prefixes honest; undo does not claim staging.

---

### Phase 6 — Contract lock (G3, G4, G6, version 2.0)

* **Objective**: Turn the preview rules into failing-if-regressed
  tests and stamp the book 2.0. No new prose except fixes the
  new tests demand.
* **Files**: `macos/Runner/help_book.json` (`version`: `"2.0"`),
  `test/help_book_json_test.dart`,
  `macos/RunnerTests/HelpDataModelTests.swift` (still decodes).

#### 6.1 — Replace the M27 word-overlap test

Keep H18 (⌘⇧B ⇒ label contains `checkout`).

Replace `every Help chord agrees with the keymap action that
owns it` (word-overlap with *any* owner) with:

1. **Every chip has a non-empty `actionId`.**
2. `kKeymapActionsById[actionId]` exists.
3. If that action has a default binding, `chordEquals` the
   chip’s keys to `defaultBindings.first`. (Unbound actions
   must not have chips — catalog them in prose only.)
4. **Verb rule:** lowercased Help `label` contains the first
   significant word of `KeymapAction.label`, after stripping
   the stop-word set already in the file (`the`, `a`, `an`,
   `to`, `of`, `in`, `on`, `for`, `and`, `or`, `view`,
   `sheet`, `panel`, `selected`, `all`, `with`, `file`,
   `files`, `log`, `state`, `last`, `working`).
5. Allowed **overrides** (Help label may use the override
   instead of the first significant word). Do not add more
   without amending this plan:

   | actionId | Help label must contain |
   | --- | --- |
   | `global.openSettings` | `settings` |
   | `global.showShortcuts` | `shortcut` |
   | `global.toggleOutput` | `output` |
   | `global.toggleFileView` | `file view` |
   | `global.toggleDashboard` | `dashboard` |
   | `global.toggleRecovery` | `recovery` |
   | `commit.confirm` | `commit` |
   | `repository.forcePush` | `lease` |

#### 6.2 — G4 completeness

```
final bound = kKeymapActions.where((a) => a.defaultBindings.isNotEmpty);
final catalog = topicById('menus_and_keymap')['shortcuts'] as List;
final ids = { for (final s in catalog) s['actionId'] as String };
for (final action in bound) {
  expect(ids, contains(action.id),
    reason: '${action.id} missing from menus_and_keymap');
}
```

#### 6.3 — Version and IA

* `expect(jsonBook['version'], '2.0');`
* Category ids equal the locked six **in order**.
* Topic ids per category equal the locked lists **in order**.
* Title remains `Magic Git User Guide`.

#### 6.4 — X1–X5 absence

Whole-book scan:

* must not contain `issue:` / `request:` / `ci:`
* must not contain `drop the folder` / `Drop the folder`
* must not contain `hybrid title bar` / `native title bar`
* `tab_worktrees` must not contain `multi-tab workspace`
* must not claim a prompt on first contact with a new host
  (reuse the H7 forbidden phrase)
* if the book contains `Focus Inspector` or `inspector pane`,
  the same topic must also contain `not populated` or `unused`

#### 6.5 — Forbidden HIGH phrases stay

Keep the Phase 0 list.

*Required tests:*
`flutter test test/help_book_json_test.dart`
`flutter analyze`

*Exit:* G3, G4, G6, G7 locked; version 2.0; no X1–X5 lies.

---

### Phase 7 — Maintainer verification (Mac)

* **Objective**: Confirm the native window still opens and a
  human can complete the MADR Confirmation checklist. This
  phase is **human-gated**. The implementation agent on Linux
  cannot do it.
* **Tasks**:
  * [ ] `./build_macos.sh --unsigned` (or `--unsigned --install`).
  * [ ] Help ▸ Support & Help (⌘?) opens “Magic Git Support &
        Help”, search finds **Inbox**, **File View**, **TOFU**,
        **Stash with Message**.
  * [ ] Walk the MADR Confirmation item 7: connect local + SSH
        (read-only — do not mutate a real forge), find File View /
        Dashboard / Settings, stash with and without a message,
        amend without using ⌘↩, open a worktree inside Worktrees
        (not as a File tab).
  * [ ] Confirm ⌘/ still opens the **live** Keyboard Shortcuts
        sheet, not this book.
  * [ ] macOS 12 is not re-tested unless the maintainer still
        ships it; `HelpViewLegacy` is unchanged and has no
        search (known limit, not a defect).

---

## Verification & Testing Strategy

| Test level | Scope | How | Pass |
| --- | --- | --- | --- |
| **JSON contract** | `test/help_book_json_test.dart` | `flutter test test/help_book_json_test.dart` | 100% of tests in that file |
| **Analyzer** | Dart test file only (no production Dart) | `flutter analyze` | clean |
| **Swift decode** | `HelpDataModelTests` | Xcode / `macos/RunnerTests` when a Mac is available | decode + `panels` category |
| **Manual** | Help window | Phase 7 | MADR Confirmation item 7 |

Do **not** run the full `flutter test` suite as a gate for a
JSON-only change, but do run it before a commit that also
touches Swift if the maintainer asks. Never `live-forge`.

Hunk-nav chords ⌥↑/↓ and ⌘⇧K are **out of the catalog** —
they are not in `kKeymapActions`. If someone adds them to the
keymap later, G4 will demand a Help chip; that is correct.

---

## Rollback & Mitigation Procedures

* **Trigger**: Help window blank, JSON decode failure, or CI
  `help_book_json_test` red after a merge.
* **Rollback steps**:
  1. Revert the `help_book.json` (and any
     `HelpDataModel.swift` / test) commit(s) for the failing
     phase. The previous phase’s book remains valid JSON.
  2. If Swift `actionId` is the problem, the field is optional —
     a v1.1 book still decodes. Revert only the test that
     requires it, or revert the Swift field and the chips.
  3. `HelpDataLoader` fallback on decode failure is an empty
     book titled version 1.0 — treat a blank Help window as a
     decode error and restore the last known-good JSON.
  4. There is no data migration and no feature flag.

Phase 0 alone is a safe hotfix if v2.0 is abandoned: it stops
the lies without the IA reshape.

---

## Task Progress Checklist

- [x] **Phase 0: Stop the lying**
  - [x] 0.1 Surgical JSON (H1–H10, M4, M7)
  - [x] 0.2 Forbidden-phrase tests
- [x] **Phase 1: Schema and helpers**
  - [x] 1.1 Optional `actionId` on `KeyboardShortcutRef`
  - [x] 1.2 Dart helpers + optional-actionId test
- [x] **Phase 2: IA + Getting Started + Workspace**
  - [x] 2.1 Six categories; required-id tests; Swift `panels`
  - [x] 2.2 Topics `overview`, `quickstart`, `clone_create`,
        `tabs_workspaces`, `workspace_chrome`,
        `file_view_and_output`,
        `dashboard_recovery_activity`, `settings`
- [x] **Phase 3: Six panel rewrites**
  - [x] 3.1 `tab_repository` (P1, M2–M4)
  - [x] 3.2 `tab_history` (P2, M5, M6)
  - [x] 3.3 `tab_branches` (P3, M7)
  - [x] 3.4 `tab_stashes` (P4)
  - [x] 3.5 `tab_forge` (P5)
  - [x] 3.6 `tab_worktrees` (P6, M8)
- [x] **Phase 4: Files, diffs, windows, DnD**
  - [x] 4.1 `viewer_and_remote_edit` (F1, F2)
  - [x] 4.2 `diffs_blame_history` (F3–F5)
  - [x] 4.3 `drag_and_drop` (F7)
  - [x] 4.4 `secondary_windows` (F6)
- [x] **Phase 5: Commands + Safety**
  - [x] 5.1 `feature_palette` (M10, X3)
  - [x] 5.2 `menus_and_keymap` catalog (G4 content)
  - [x] 5.3 `feature_ssh` (M14)
  - [x] 5.4 `undo_recovery` (F8)
  - [x] 5.5 `tool_health` (M11)
  - [x] 5.6 `output_log` trim (M12)
- [x] **Phase 6: Contract lock**
  - [x] 6.1 G3 (`actionId` required + verb rule)
  - [x] 6.2 G4 completeness
  - [x] 6.3 Version `2.0` + ordered IA
  - [x] 6.4 X1–X5 absence
  - [x] 6.5 HIGH forbidden phrases still asserted
- [ ] **Phase 7: Maintainer Mac verification**
  - [ ] Build unsigned app and walk Confirmation item 7

---

## More Information

* Decision: [0010-MADR-in-app-help-book-rewrite.md](./0010-MADR-in-app-help-book-rewrite.md)
* Prior Help work: 0009 H18, 0009 M27 / Phase 10 (v1.1)
* Workspace/chrome described here: 0005, 0008
* Book path: `macos/Runner/help_book.json` (already in
  `macos/Runner.xcodeproj/project.pbxproj` Resources)
* Do not edit `HelpView.swift` search or layout in this plan
