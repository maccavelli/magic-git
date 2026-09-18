---
status: "accepted"
date: 2026-09-18
decision-makers: [Maintainer]
consulted: []
informed: [Magic Git contributors]
verified: 2026-09-18
---

# The sidebar info card gains a "Location" row, the connections-manager button becomes a fixed "Connections" label, and every surface names the repository the same way

## Context and Problem Statement

The bottom of the sidebar is a stack of three blocks, mounted only while a session is connected
(`lib/features/app_shell.dart:1049-1058`):

1. `CurrentRepoIndicator` (`lib/features/switcher/current_repo_indicator.dart`) is a passive info row.
   It has a grey "Repository" caption over the active repo's basename, a folder glyph, a trailing
   dirty/ahead/behind cluster, and the full path in a tooltip.
2. `ConnectionSwitcher` (`lib/features/switcher/connection_switcher.dart:31-94`) is a large secondary
   push button that opens `ConnectionsPanel`, the connections manager.
3. `LogoutButton` (`connection_switcher.dart:100-157`), styled identically to the button above.

The connections button does two jobs. Its **action** is fixed: open the manager. Its **label** is state:
it reports where the session is (`connection_switcher.dart:47-53`):

| session | button label today |
|---|---|
| SSH, saved or ad-hoc | `host` (e.g. `build01.example.com`) |
| local | the literal `Local` |
| not connected | `Connections` |

The maintainer asked to split those jobs:
- add a **Location** row under Repository in the info card, showing the current connection the way
  Repository shows the current repo;
- make the button always read **Connections**, opening the manager as it does now.

On review (2026-09-18) the maintainer briefly added repository labels to the Repository row, then
withdrew them (F7), and set a requirement in their place:
- the **tab title, the Repository row and the status bar show the same name** for the repository (F8).

Asked how a tab alias fits that requirement, the maintainer chose (2026-09-18) that the Repository row
and the status bar **follow the tab alias**: every surface shows the alias when the tab has one, and
the last directory of the repo path otherwise.

This record evaluates that request against the code and proposes how to do it.

### F1 — The request is coherent with how the card already works

The Repository row is purely informational and the buttons below it are purely actions, except for this
one button, whose label is information. The same label also says different kinds of things depending
on the session: a hostname for SSH, a category word (`Local`) for a local repo. A user reading
`build01.example.com` on a button has no text telling them the button manages connections; the
glyph (`rectangle_stack`) is the only cue. Moving the state into the card makes the card the single
place to read "where am I", and makes the button's label name what it opens.

### F2 — The button label has no information of its own to lose

Every value the button shows can be computed from `connectionProvider`, which the Repository row
already watches (`current_repo_indicator.dart:21`). There is no state the button holds that a new row
could not read. The `Connections` branch of the label (`!isConnected`) is already unreachable in the
shell, because the whole bottom stack is `null` when not connected (`app_shell.dart:1049`). It is
reachable only from `test/connection_switcher_test.dart`, which pumps the widget bare.

### F3 — What "location" can say, per session kind

`ConnectionState` (`lib/core/providers/app_providers.dart:775-826`) carries `backend`, `host`,
`connectionId` and `connectionLabel`, but no username or port.

- **Saved SSH connection.** `connectionLabel` is `SavedConnection.displayName`
  (`app_providers.dart:2171`), which is the user's label if set, else `username@host`
  (`lib/core/storage/saved_connection.dart:324`). `host` is the bare hostname. **Today's button
  ignores the label and shows `host`**, so a connection the user named "Build box" appears as its
  hostname.
- **Ad-hoc SSH connection.** `connectionLabel` is `connectionLabel ?? profile.host`
  (`app_providers.dart:1416`), normally equal to `host`.
- **Local session.** `connectionLabel` is the saved local repo's label, or `null` when it has none
  (`app_providers.dart:1981,2089`; every caller passes `repo.label.isEmpty ? null : repo.label`). The
  button shows `Local` rather than this, because a label names the *repo*, not the place. The comment
  at `connection_switcher.dart:47-50` calls it "the repo name"; that is true only when the label happens
  to be the directory name. The house wording for this place
  elsewhere is "this Mac": `On this Mac` in the repository context bar
  (`lib/features/repository/repo_status_view.dart:1653`), `Local (this Mac)` in the Add Existing
  Repository sheet, and `This Mac` as a create-repo target.

Username and port are available only through the saved connection, by looking up `connectionId` in
`savedConnectionsProvider`, which `ConnectionSwitcher` already watches (`connection_switcher.dart:42`).

### F4 — Other routes to the manager are unaffected

`ConnectionsPanel` is also opened by the command palette's **Manage Connections** entry
(`lib/features/common/command_palette.dart:476-480` → `app_shell.dart:365-370`) and by the landing
screen's **Connections Manager** button (`lib/features/connection/connection_landing.dart:29,178`).
Neither reads the sidebar button's label.

### F5 — Tests pin today's label, and nothing else depends on it

`test/connection_switcher_test.dart` has two tests on the label:
- "switcher button shows the server host for an SSH session" (line 348);
- "switcher button shows "Local" for a local session, not the repo name" (line 365).

`test/current_repo_indicator_test.dart` has four tests on the Repository row's status cluster. No golden
covers the sidebar bottom stack (the 48 goldens in `test/workspace_golden_test.dart` render workspace
panes).

### F6 — The card grows by one row

The card gains one row of the Repository row's shape, about 40 pt: 8 pt vertical padding each side,
plus a caption line and a body line. This is an estimate from the padding and type styles, not a
measurement. The main window's minimum size is 640×480 (`app_providers.dart:97-98`), but the sidebar
is hidden at that width: it declares `windowBreakpoint: 760` (`app_shell.dart:1043`), and macos_ui hides
it while `width <= windowBreakpoint` (`macos_ui-2.2.2/lib/src/layout/window.dart:232`). The shortest
window that shows the sidebar is therefore **761×480**, and that is where the extra height matters.
The sidebar's nav rail is built with the sidebar's scroll controller (`app_shell.dart:1059-1066`), so
the extra height should shorten the rail's viewport rather than overflow. That is an expectation to
verify, not an observed fact.

### F7 — Repository labels exist, and are out of scope

Users can label a repository in two places: a repo on a saved SSH connection
(`SavedConnection.repoLabels`, `lib/core/storage/saved_connection.dart`) and a saved local repo
(`SavedLocalRepo.label`, `lib/core/storage/saved_local_repo.dart:138`). The connections manager's tiles
show those labels (`connection_switcher.dart:522,694`). The Repository row does not: it renders
`basename(repoPath)` (`current_repo_indicator.dart:54`).

A revision of this record, on 2026-09-18, put labels into the Repository row. The maintainer withdrew
that the same day, in favour of the requirement in F8: the row keeps the directory name, and
user-provided repository labels are out of scope for this record.

### F8 — Three surfaces name the repository, and one of them can diverge

The maintainer's requirement is that **the tab title, the Repository row and the status bar show the
same name**. The status bar is the repository context bar at the top of each workspace pane
(`lib/features/common/repository_context_bar.dart:319`, `snapshot.repositoryName`). Today:

| surface | how the name is derived |
|---|---|
| Repository row | `basename(repoPath)` (`current_repo_indicator.dart:54`) |
| status bar | the last non-empty path segment, hand-written in seven places: `repo_status_view.dart:1648-1651`, `history_view.dart:1590`, `branches_view.dart:605`, `stash_view.dart:373`, `worktrees_view.dart:791`, `forge_workspace.dart:84`, and `worktrees_view.dart:747` for a selected worktree. Every pane but Status prefixes it with `Repository: `. |
| tab title | the **tab alias** if one is set, else `basename(tab.repoPath)` (`lib/features/tabs/tab_strip.dart:136-139`) |
| window title | the tab alias if set, else the last path segment (`lib/features/tabs/tabs_host.dart:30-42`) |

- **The Repository row and the status bar agree today**, because `basename`
  (`lib/core/utils/posix_path.dart:31-34`) and the inline expressions compute the same thing: drop
  empty segments, take the last, fall back to the whole path. They agree by duplication, not by
  construction. Nothing in the test suite would notice one of the seven copies drifting.
- **The tab title can disagree.** A tab alias is a user-set name: "Rename Tab" in the Saved Workspaces
  sheet (`lib/features/tabs/saved_workspaces_sheet.dart:225-244`), persisted per saved repository by
  `SavedWorkspaceStore.setAlias` (`lib/core/storage/saved_workspace_store.dart:90`). With an alias set,
  the tab and the window title show the alias while the Repository row and status bar show the
  directory. The maintainer resolved this by having the row and status bar follow the alias (see
  Context). The alias is a *tab* name, set deliberately for that tab; it is not the repository labels
  that F7 leaves out of scope.
- **The Worktrees pane's `Worktree: <name>` is not a mismatch.** It names the worktree selected in that
  pane, a different checkout, by the same last-segment rule.

## Decision Drivers

* A control's label should name what it does; state belongs in the passive card.
* One place to read "where am I": repo and location together.
* No new data fetches: read what `connectionProvider` and `savedConnectionsProvider` already hold.
* Consistency with the Repository row: same caption/value/glyph/tooltip idiom.
* Show the connection itself, meaning the machine, and use the app's existing "this Mac" wording.
* The tab title, window title, Repository row and status bar name the repository identically, by
  construction rather than by duplicated code (F8).
* Hold at 761×480, the smallest window that shows the sidebar, without overflow (F6).

## Considered Options

* **A.** Add a Location row to the info card, and make the button a fixed "Connections" label (the
  request).
* **B.** Keep one control, but make the button two-line: a "Connections" caption over the location
  value.
* **C.** Keep the button as it is and add a tooltip explaining it opens the manager.
* **D.** Add the Location row, make that row itself open the manager, and delete the button.

## Decision Outcome

Chosen option: **A**, because it is the only option that separates state from action completely. The
card then carries both "where" facts, and the button's label becomes a stable noun naming what it opens,
at the cost of one row of height and a small, contained code change.

### What the Repository row shows

The tab alias when the tab has one, else the last directory of the repo path, from the shared provider
below. The glyph, status cluster and tooltip are unchanged; the tooltip's full path keeps the directory
one hover away when an alias hides it. The row's layout moves into the shared card row (see Card
structure).

### One repository name, from one provider

Every surface that names the active repository takes the name from a single derived provider in
`lib/features/tabs/tab_ui_providers.dart`, beside `tabAliasProvider`:

- `repositoryDisplayName(repoPath, {alias})`, a pure function: the trimmed alias when non-empty, else
  `basename(repoPath)`;
- `repositoryDisplayNameProvider`, a `Provider.family<String, String>` keyed by repo path: it watches
  `tabAliasProvider` and the session's `repoPath`, and applies the alias **only when the key equals
  the session's `repoPath`**. A pane naming any other path gets its basename.

The consumers:

| surface | change |
|---|---|
| Repository row | `ref.watch(repositoryDisplayNameProvider(repoPath))` in place of `basename(repoPath)` |
| status bar, six panes | Status, History, Branches, Stashes, Worktrees and Forge build `repositoryName` from the provider, each keeping its existing `Repository: ` prefix, or none for Status. The seven hand-written segment expressions (F8) go. |
| status bar, Worktrees selected worktree | unchanged: `Worktree: <basename>` names a different checkout |
| tab title | `tab.container.read(repositoryDisplayNameProvider(tab.repoPath!))` in place of `aliasFor(tab) ?? basename(tab.repoPath!)`. `New Tab` and `Connecting…` are unchanged. |
| window title | `windowTitleProvider` watches the provider in place of its inline alias-or-segment logic |

Why this source is correct: `tabAliasProvider` is per tab, lives in the tab's own container (the
same container that mounts that tab's `AppShell`), and is already re-synced on every connection change
and every alias edit (`tabs_controller.dart:203-247,404-424`). After an SSH tab switches repo, the
alias identity follows the new repo (`tabs_controller.dart:409-415`). So the provider is exactly as
current as the tab title already is.

### What the Location row shows

The row uses the Repository row's exact layout: glyph, grey `Location` caption, bold single-line
value, trailing slot, and a tooltip.

| session | value | glyph | tooltip |
|---|---|---|---|
| saved SSH | `host` | `CupertinoIcons.globe` | `username@host:port` from the saved connection |
| ad-hoc SSH | `host` | `CupertinoIcons.globe` | `host` |
| local | `This Mac` | ~~`CupertinoIcons.desktopcomputer`~~ `CupertinoIcons.folder` (Amendment 0052.1) | `On this Mac` |

For SSH the value is the hostname, as the button shows today; the saved connection's label is not
used. The maintainer decided this on review (2026-09-18): the row exists to show the *connection*,
meaning the machine the session is on, not the name given to it. A draft of this record proposed the
label, with the hostname in the tooltip; that proposal was rejected.

One thing changes from today's button label:
- **`Local` becomes `This Mac`**, matching the wording the rest of the app uses (F3). The maintainer
  confirmed this wording on review (2026-09-18).

Both glyph names exist in the pinned SDK's `CupertinoIcons`.

### Card structure (both rows)

The Repository and Location rows form one card: one top border, two rows, no separator between them.
The card is built from a shared private row widget, so the two rows cannot drift apart in padding or
type. This replaces `CurrentRepoIndicator`'s bespoke layout, not its behaviour: the Repository row's
status cluster and tooltip are unchanged. The Location row has no trailing cluster in this decision.

### The button

`ConnectionSwitcher` renders the fixed label `Connections` with its current glyph, style, `HoverPop`
and `onPressed`, and stops watching `connectionProvider` for its label. Its early return, which hides it
when disconnected with nothing saved, is kept: it is harmless and keeps the widget safe to mount on
its own. `LogoutButton` is untouched.

### Consequences

* Good, because the button's label names the action, identically in every session.
* Good, because the card answers "which repo, where" in one glance, and the tooltip carries the full
  `user@host:port` that no surface shows today.
* Good, because it needs no new fetch or command: the one new provider derives from state already in
  memory, so it costs zero round trips.
* Good, because the four names agree by construction, and seven duplicated expressions collapse into
  one function.
* Neutral, because the tests change: the two label tests in `connection_switcher_test.dart` move to
  the Location row's tests and are rewritten for the new values (the host, unchanged, and `This Mac`), and a
  fixed-label test replaces them on the button.
* Bad, because the sidebar's bottom stack grows by about 40 pt, taking that height from the nav rail's
  viewport at small window sizes (F6).
* Bad, because two saved connections to the same host as different users show the same value; only
  the tooltip's `username@` tells them apart.
* Bad, because once a tab has an alias, the directory name appears only in tooltips (the Repository
  row's and the status bar's). That follows directly from the maintainer's choice.

### Confirmation

* Widget tests for the Location row: one per session kind in the table above, asserting value,
  glyph and tooltip, including a labelled saved connection showing its host and not its label.
* A widget test that the button reads `Connections` for both an SSH and a local session, and that
  tapping it still opens `ConnectionsPanel`.
* A layout test that the connected shell, pumped at 761×480, shows the whole bottom stack with no
  overflow (F6).
* The existing `current_repo_indicator_test.dart` cases pass unchanged.
* Unit tests for `repositoryDisplayName` and `repositoryDisplayNameProvider`: no alias gives the
  basename, including for a trailing-slash path; an alias wins; a blank alias falls back; and the alias
  does not apply to a path other than the session's.
* A parity test in one tab container: with no alias, then with an alias, the Repository row, a pane's
  status bar `repositoryName` (less its `Repository: ` prefix), the tab title and the window title's
  name all show the same text. A saved repository label must not change any of them.
* The new tests are seen to fail before the change (the button test against today's host label; the
  Location tests against a tree where the row does not exist).

## Pros and Cons of the Options

### A — Location row in the card, fixed "Connections" button

* Good, because state and action are fully separated (F1).
* Good, because it reuses the Repository row's idiom and data source (F2).
* Neutral, because it adds one row of height (F6).
* Bad, because it is a slightly larger change than B or C: one widget reshaped, one new row, and
  tests moved.

### B — Two-line button: "Connections" caption over the location

* Good, because it adds no height beyond a second text line inside the button.
* Bad, because the button still carries state, and its tappable area now contains information text,
  the conflation the request exists to remove.
* Bad, because a two-line `ControlSize.large` push button departs from the Logout button beneath it,
  which the code deliberately keeps identical (`connection_switcher.dart:97-100`).

### C — Keep the button, add a tooltip

* Good, because it is the smallest change.
* Bad, because the discoverability problem it addresses is visible only on hover, and the label still
  switches between a hostname and a category word.
* Bad, because it does not do what was asked.

### D — Location row opens the manager; button removed

* Good, because it saves a block of height instead of adding one.
* Bad, because the card's rows would behave differently: Repository is passive and Location is a
  button, so the user cannot tell from the card which parts are clickable.
* Bad, because it removes the only labelled sidebar entry point to the manager, leaving the command
  palette as the named route.

## More Information

* **Not included:** showing connection health on the Location row, such as a reconnecting dot like
  the Repository row's status dot. `ConnectionState.reconnecting` exists, but a dropped connection
  already replaces the content area with `_ReconnectingOverlay` (`app_shell.dart:1112-1120`), so a
  second indicator would duplicate it. Revisit only if the overlay changes.
* **Withdrawn on review:** repository labels in the Repository row (F7). The rejected design resolved
  the label live from the saved stores by `connectionId`. It is recorded in this file's history
  (`626f64b`) if labels are taken up later, together with its two traps: for SSH, `connectionLabel` is
  the connection's name, not the repo's, and a local repo's label applies only to `repoPaths.first`.
* **Tab alias: the options put to the maintainer (2026-09-18).**
  - *Match only un-aliased tabs.* Rejected: it leaves the requirement unmet exactly when the user has
    named a tab.
  - *The row and status bar follow the alias.* **Chosen.**
  - *Retire tab aliases.* Rejected: it removes a feature, and existing aliases would silently stop
    showing.
* **Multi-tab:** the Location row reads `connectionProvider` in the same scope as the Repository row,
  so it follows the active tab exactly as that row already does.
* Related: [0008-MADR-unified-repository-chrome.md](../0008-MADR-unified-repository-chrome.md) for the app's chrome.
* The implementation plan, `0052-PLAN-sidebar-info-card-location-row-and-plain-connections-button.md`, is its
  implementation plan.

## Amendment 0052.1 (2026-09-18): one location glyph on the tab, status bar and Location row

**What the maintainer observed.** With a remote repo open, three surfaces showed three different
glyphs for the same place:
- the tab chip showed `desktopcomputer` for remote and `folder` for local
  (`lib/features/tabs/tab_strip.dart`);
- the status bar showed `folder` always, since the snapshot it renders carried no local/remote fact
  (`repository_context_bar.dart`);
- the Location row showed `globe` for remote and `desktopcomputer` for local, as this record specified.

**Decision.** The three surfaces show one glyph: **`CupertinoIcons.globe` for a remote repo and
`CupertinoIcons.folder` for a local one.** The local Location glyph changes from `desktopcomputer`
(struck through in the table above); remote is unchanged.

**How it is built.**
- `sessionLocationIcon({required bool isLocal})` in `lib/features/common/session_location.dart` is the
  one source for all three surfaces.
- `RepositoryContextSnapshot` gains `isLocal` (default `false`), and all seven constructions pass
  `connection.isLocal`.
- A source scan (`test/repository_name_source_test.dart`) fails if a construction omits it: the
  default would silently draw a globe for a local repo.

**Not changed.** ~~The connections manager's SSH tiles (`connection_switcher.dart:417,581`) and the
landing page's recent list (`connection_landing.dart:337`) still use `desktopcomputer` for remote.
They are outside the three surfaces the maintainer named.~~ Superseded by Amendment 0052.2. The
Repository row keeps `folder_fill`: it is the repository's glyph, not the location's.

## Amendment 0052.2 (2026-09-18): the manager and landing rows use the location glyph too

**Decision.** The maintainer extended 0052.1 to the two remaining places that show a location. They
now use `sessionLocationIcon`: a **globe for remote** and a **folder for local**. No
`desktopcomputer` glyph remains in `lib/`.

- **Connections manager** (`connection_switcher.dart`): the saved SSH connection row and the unsaved
  SSH session row now show the globe. The saved local repo row and the unsaved local session row now
  show the plain folder. The active local row used to switch to `folder_fill`; it now keeps the
  folder, and is marked by its accent colour and row highlight, as the SSH connection row already
  was.
- **Landing page** Recent Repositories (`connection_landing.dart`): the globe for a remote repo; local
  already used the folder and now takes it from the same function.

**Still not changed, deliberately.** The repo rows nested *under* an SSH connection in the manager keep
`folder` / `folder_fill`. They name a repository within a location, not the location, and the fill
marks the active repo. The same reasoning keeps the sidebar Repository row on `folder_fill`.

