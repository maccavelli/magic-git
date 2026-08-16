---
status: accepted
date: 2026-08-16
decision-makers: maccavelli (maintainer)
consulted: 21593a0 and 9a385da (the two commits that produced the defect), live NSUserDefaults records from com.example.remoteMagicGit, git state of magic-git and magic-cli-remote on wonder.lallygag.net, 0008-MADR unified repository chrome
informed: implementers of RepositoryWorkspacePrefs and the repository context bar
---

# Version the workspace-preferences schema and migrate v1 toolbar-slot sets instead of decoding them literally

## Context and Problem Statement

The repository context bar rendered inconsistently across repositories.
On the same saved SSH connection to the `wonder` bastion,
`/data/gitrepos/magic-git` drew the full bar — repository identity,
status summary, host/latency link strip, View Options, Activity, Stash,
Refresh, and the grouped Fetch · Pull · Push · Sync control with its
overflow — while `/data/gitrepos/magic-cli-remote` drew a Back/Forward
pair, the repository identity, and a single button labelled **Fetch**.
Nothing else. The reported expectation is the correct one: *the only
input that should change how much of the bar is populated is the
available width.*

The symptom looked like an SSH/remote-backend problem because the two
worst-affected repositories were remote. It is not.

### What the evidence shows

**The repositories are not meaningfully different.** Both were inspected
live over SSH. Both are non-bare, on `master`, tracking
`origin/master`, with a clean working tree (`git status --porcelain=v2
-z` produced zero bytes for each) and an HTTPS GitHub remote. There is
no repository-state input that could distinguish them.

**The persisted per-repository preferences *are* different.** Workspace
preferences are stored per repository identity under
`repositoryWorkspacePrefs_v1_<base64url(scopeKey NUL gitCommonDir)>`.
Decoding the live records from
`~/Library/Preferences/com.example.remoteMagicGit.plist`:

| Identity | `visibleToolbarSlots` |
| --- | --- |
| `ssh:1786755957310113` · `/data/gitrepos/magic-git/.git` | all 9 slots |
| `ssh:1786755957310113` · `/data/gitrepos/magic-cli-remote/.git` | `back`, `forward` |
| `ssh:1786755957310113` · `/data/gitrepos/mcp-server-magictools/.git` | all 9 slots |
| `ssh:1784478990700927` · `/home/mac/gitrepos/magic-git/.git` | all 9 slots |
| `ssh:1784478990700927` · `/home/mac/gitrepos/magic-cli-remote/.git` | `back`, `forward` |
| `local:1786830353850083` · `/Users/saxsmith/gitrepos/magic-git/.git` | all 9 slots |
| `local:1784307006484082` · `/Users/saxsmith/gitrepos/magic-git/.git` | `back`, `forward` |
| `local:1784554734225500` · `.../go/magic-cli-remote/.git` | `back`, `forward` |

Two-slot records exist for **local** identities as well. Remote-versus-
local was a coincidence of which bookmarks the maintainer currently
uses, not a cause.

### Why the bar collapses to exactly that shape

`RepositoryContextBar` gates each item on
`preferences.visibleToolbarSlots`. With only `back` and `forward`
present:

* `statusSummary` is hidden → no `Clean` / `N changed` / `↑↓`.
* `linkStatus` is hidden → no hostname, latency, or connection state.
* `stash`, `refresh`, `activity`, `viewOptions` are hidden → no tools.
* `syncGroup` is hidden → the bar takes its documented fallback, the
  single emphasized primary action, so that hiding the group cannot
  leave the bar with no action at all.

`resolvePrimaryRepositoryAction` walks a ladder whose terminal case is
`(fetch, 'Fetch')`. A clean, in-sync repository with an upstream — which
is exactly `magic-cli-remote` — falls all the way through. **"Only the
Fetch button" is not a partially-drawn toolbar; it is the fully-drawn
toolbar of a workspace whose preferences say seven of nine slots are
hidden.**

### How those records were written

`WorkspaceToolbarSlot` was introduced by `21593a0` (2026-08-13) with
exactly two members:

```dart
enum WorkspaceToolbarSlot { back, forward }
```

At that point the constructor default and the decode fallback were both
`{back, forward}`, and both were correct and complete. Every record
written by that build therefore contains
`"visibleToolbarSlots":["back","forward"]` — a *complete, valid* record
for the schema it was written against.

`9a385da` (2026-08-14) grew the enum to nine members and updated the
constructor default to all nine. It did **not** update the hardcoded
literal inside `_decodeToolbarSlots`, and it did **not** bump
`currentVersion`, which stayed at `1`.

That leaves three defects compounding:

1. **A stale duplicate default.** `_decodeToolbarSlots` returned
   `{back, forward}` for a missing or malformed value — the old complete
   set, now a seven-slot amputation.
2. **No schema version boundary.** `decode` gated on
   `json['version'] != currentVersion`, and the version had not moved, so
   pre-expansion records sailed through and were interpreted under the
   new nine-member meaning.
3. **The loss is self-propagating.** `updateRepositoryWorkspacePrefs`
   loads, applies, and writes back the *whole* record. Any later
   change — resizing the navigator, collapsing a pane, switching preset,
   toggling a diff option — re-persisted the two-slot set, converting a
   misread into durable data.

A repository is affected if and only if its preference record was first
written during that window. Nothing about the transport, the host, or
the repository is involved, which is why the behaviour looked arbitrary.

### Why tests did not catch it

`repository_workspace_prefs_test.dart`, `toolbar_slots_test.dart`, and
`repository_context_bar_test.dart` all either construct
`RepositoryWorkspacePrefs` in memory or round-trip a record produced by
the *current* `encode()`. No test presents a payload written by an
earlier schema. The defect lives entirely in the gap between two schema
generations, so a suite that only ever round-trips itself cannot see it.

## Decision Drivers

* The context bar's population must depend on width and on explicit user
  choice — nothing else.
* Existing user data must be repaired, not merely stopped from getting
  worse; the maintainer's records already contain the bad set.
* Pane widths, diff options, grouping, and preset in those same records
  are legitimate and must survive the repair.
* "Everything visible unless deliberately hidden" is the stated
  invariant of the class and must have exactly one definition.
* A future slot addition must not be able to reintroduce this.

## Considered Options

* **A — Fix the fallback only.** Point `_decodeToolbarSlots` at the
  constructor default.
* **B — Bump the schema version and discard non-conforming records.**
  Use the existing `version != currentVersion` branch, which returns
  `const RepositoryWorkspacePrefs()`.
* **C — Bump the schema version and migrate v1 forward, restoring the
  full slot set while preserving every other field.**
* **D — Rename the storage key to `_v2_`.** Leave old records orphaned
  on disk and seed fresh ones.

## Decision Outcome

Chosen option: **"C — Bump the schema version and migrate v1 forward,
restoring the full slot set while preserving every other field"**,
because it is the only option that repairs the records already on disk
without throwing away the unrelated settings stored beside the corrupted
field.

Option A is necessary but not sufficient: it addresses the missing-key
path, while the maintainer's actual records carry an *explicit*
`["back","forward"]` list that a fallback never consults. `magic-cli-remote`
would still have rendered a lone Fetch button.

Option B repairs the toolbar but discards navigator width, diff layout,
context lines, grouping, and preset for every affected repository — a
disproportionate amount of collateral loss for one untrustworthy field.

Option D is the most destructive of the four and leaves permanent
garbage in `NSUserDefaults`.

### Accepted trade-off

A v1 slot set is discarded rather than decoded. Three things are
indistinguishable in that data: the complete two-member set of the
Aug-13 build, the stale fallback that same literal became, and a genuine
decision to hide seven slots made during the roughly one-day window when
the nine-slot UI existed under version 1. The first two dominate
overwhelmingly. A user who really had hidden slots in that window gets a
one-time reset to the full bar and can re-hide from View Options, which
is a recoverable and discoverable outcome. The reverse error — leaving a
stripped bar in place — is neither, because the control that restores
the bar (View Options) is itself one of the hidden slots.

### Implementation

Implemented in `lib/core/settings/repository_workspace_prefs.dart`:

* `defaultVisibleToolbarSlots` is a single top-level constant. The
  constructor default, the decode fallback, and the migration all read
  it; the duplicated literal that went stale is gone.
* `currentVersion` is `2`, with `minReadableVersion = 1`. `decode` now
  accepts any version in `[minReadableVersion, currentVersion]` and
  parses it field-by-field; only an absent, non-integer, or
  future version falls back wholesale.
* Records at version `< 2` keep every other field and take
  `defaultVisibleToolbarSlots`.
* `_decodeToolbarSlots` honours any *present* list verbatim, including an
  empty one — an explicit "hide everything" remains a supported choice —
  and treats only a missing or malformed value as "never configured".

The storage key deliberately keeps its `_v1_` infix. It is key material,
not a payload version; changing it would orphan exactly the records this
decision exists to preserve.

No change was needed in `RepositoryContextBar`. Its slot gating was
correct throughout; it was faithfully rendering bad input.

## Consequences

* Good, because affected repositories repair themselves on next load —
  `decode` runs on every read, so the full bar returns immediately rather
  than waiting for a write.
* Good, because pane widths, diff preferences, grouping, and presets in
  migrated records survive untouched.
* Good, because the "everything visible by default" invariant now has
  one definition instead of two that could drift.
* Good, because the fix is transport-agnostic: SSH, local, and pop-out
  workspaces all read the same store.
* Neutral, because migrated records are repaired in memory on each load
  and only rewritten to disk when something else changes them. This is
  correct but means the stale v1 payload can linger harmlessly.
* Bad, because a deliberate v1-era hide choice is reset. Accepted above.
* Bad, because a genuinely corrupt record is now parsed field-by-field
  rather than rejected outright, so an individually malformed field falls
  back on its own instead of resetting the record. This is the intended
  trade for not discarding good data.

## Confirmation

`flutter analyze` is clean and the full suite passes (3117 tests).
New coverage in `test/repository_workspace_prefs_test.dart`:

* `the default slot set covers every slot` — asserts
  `defaultVisibleToolbarSlots` equals `WorkspaceToolbarSlot.values`, so a
  slot added to the enum but not the default fails here rather than
  shipping hidden-by-default. This is the guard against a recurrence.
* `legacy v1 records`:
  * `a complete two-slot v1 record is restored to the full bar` —
    reproduces the exact payload found on the maintainer's disk.
  * `a v1 record with no slot key is restored to the full bar` — the
    missing-key path.
  * `migrating preserves every other v1 field` — preset, widths,
    collapse flags, diff layout, whitespace, context lines, grouping,
    labels.
  * `a v2 record still honours an explicit partial choice` and
    `a v2 record honours hiding every slot` — the migration does not
    override real user intent going forward.
  * `an unknown future version falls back to defaults`.

Field confirmation: relaunch against the `wonder` bastion and open
`/data/gitrepos/magic-cli-remote`. The bar should render identically to
`/data/gitrepos/magic-git` at the same window width, and narrowing the
window should be the only thing that reduces it.

## More Information

* `21593a0` *feat(forge): Implement E2 drag-and-drop cherry-pick and
  other UX improvements* — introduced `WorkspaceToolbarSlot { back,
  forward }`, `_decodeToolbarSlots`, and the then-correct two-slot
  fallback.
* `9a385da` *feat(context-bar): Add customizable toolbar slots* —
  expanded the enum to nine and updated the constructor default only.
* `lib/features/common/repository_context_bar.dart` — slot gating and the
  documented single-primary-action fallback when `syncGroup` is hidden.
* `lib/features/common/repository_context.dart` —
  `resolvePrimaryRepositoryAction`, whose terminal `Fetch` case explains
  the specific button that survived.
* [0008-MADR](0008-MADR-unified-repository-chrome.md) — establishes the
  single context bar and the rule that a hideable toolbar item must also
  exist as a menu command, which is what makes hiding safe at all.

## Addendum — a hidden slot must remove information, not relocate it

Reviewing the bar for the defect above surfaced a second, independent
problem in the same file, since fixed here.

Two places re-printed a slot's content while that slot was switched off:

* `_SupplementSummary` ends its label chain with
  `snapshot.hostLabel ?? snapshot.connectionLabel`. The widget was
  ungated, so turning off **Connection status** removed
  `SshLinkStatusRow` while the supplement quietly went on printing the
  same host.
* `_CompactMetadata` — the compact size class's disclosure tooltip —
  listed working-tree counts, ahead/behind, upstream, connection and host
  unconditionally. Narrowing the window therefore resurrected precisely
  the detail the user had hidden.

Both make hiding cosmetic: the control disappears, the information does
not. The governing rule is now explicit — **a slot governs its
information everywhere in the bar, at every size class**:

* `WorkspaceToolbarSlot.linkStatus` governs connection identity:
  `SshLinkStatusRow`, the supplement's host/connection fallback, and the
  compact disclosure's connection lines.
* `WorkspaceToolbarSlot.statusSummary` governs working-tree and
  divergence detail: `_StatusSummary` and the compact disclosure's
  changed/conflict/ahead/behind/upstream lines.

Two details worth recording:

* The supplement's *screen-scope* labels — worktree, selection, branch,
  revision, base, forge, recent commit — stay ungated. Like the
  repository identity block they state what you are looking at, and
  0008's non-customizable leading edge covers them. Only the connection
  tail moved under a slot.
* The connection fallback is gated on the **slot**, not on the bar's
  `showLinkStatus` flag. `showLinkStatus` is false for local sessions,
  which have no SSH strip but whose connection label is still meaningful
  in the supplement; gating on it would have removed working behaviour
  from every local repository.

`_CompactMetadata` now renders nothing when every line it would carry is
hidden, rather than leaving a hoverable glyph with an empty tooltip.

Covered by `a hidden slot does not leak its information elsewhere` in
`test/repository_context_bar_test.dart`: the supplement prints the
connection while the slot is on, is silent when it is off, and the
compact disclosure both carries and omits the corresponding lines.
