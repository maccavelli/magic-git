---
status: "proposed"
date: 2026-09-18
decision-makers: [Maintainer]
consulted: []
informed: [Magic Git contributors]
verified: 2026-09-18
---

# The sidebar info card shows the repository's own label and a new "Location" row, and the connections-manager button becomes a fixed "Connections" label

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

On review (2026-09-18) the maintainer added a third change to scope:
- the **Repository** row shows the repository's label when the user has set one, and the last
  directory of the repo path otherwise. Today it always shows the directory (F7).

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
measurement. The main window's minimum size is 640×480 (`app_providers.dart:97-98`). The sidebar's nav
rail is built with the sidebar's scroll controller (`app_shell.dart:1059-1066`), so the extra height
should shorten the rail's viewport rather than overflow. That is an expectation to verify, not an
observed fact.

### F7 — Repository labels exist, and the Repository row ignores them

Users can give a repository a label in two places, and both are persisted:

- **A repo on a saved SSH connection.** `SavedConnection.repoLabels` maps repo path to label
  (`lib/core/storage/saved_connection.dart`). It is edited in `EditRemoteRepoSheet`'s "Label" field
  (`lib/features/switcher/edit_entry_sheets.dart:368`). The helper `repoDisplayName(path)` already
  returns the label, or the basename when unset (`saved_connection.dart:136-141`).
- **A saved local repo.** `SavedLocalRepo.label`, edited in the local repo sheet
  (`edit_entry_sheets.dart:507`). The getter `displayName` returns it, or the basename when unset
  (`lib/core/storage/saved_local_repo.dart:138`).

"Label" and "friendly name" are the same field in each case; the UI calls it "Label" and the code
comments call it a friendly name.

The connections manager's tiles use both helpers (`connection_switcher.dart:522,694`). The Repository
row does not: it renders `basename(repoPath)` unconditionally (`current_repo_indicator.dart:54`). So a
repo labelled "Website" is "Website" in the manager and `www-src` in the sidebar.

Three facts decide how the row can find the label:

- **`ConnectionState` has no repo label.** For SSH, `connectionLabel` is the *connection's* display
  name (F3), so reading it for the repo would be wrong. For local, it is the repo label, but only as a
  snapshot taken at connect time: renaming the repo mid-session would not reach it.
- **`connectionId` identifies the saved entry.** For SSH it is the `SavedConnection.id`
  (`app_providers.dart:2170`). For a saved local repo it is the `SavedLocalRepo.id`: every saved-local
  open passes `id: repo.id` (`connection_switcher.dart:1097,1131`, `connection_landing.dart:302`,
  `saved_workspace_actions.dart:196`, `workspace_open_in_tab.dart:95`, `workspace_flow.dart:180`). An
  unsaved local open passes `id: null` but may still pass a typed label (`local_repo_form.dart:679-684`).
- **A session can change repo without reconnecting.** `setRepoPath` switches the active repo and
  appends to `repoPaths` (`app_providers.dart:2477-2481`), from the manager, the command palette and
  the clone/create flow. A local session starts with `repoPaths: [repoPath]` (`app_providers.dart:2087`),
  so its saved label names `repoPaths.first` and nothing else.

Both saved stores are already loaded providers (`savedConnectionsProvider`,
`savedLocalReposProvider`), read by the manager and by `ConnectionSwitcher` itself, so looking a label
up costs no command.

## Decision Drivers

* A control's label should name what it does; state belongs in the passive card.
* One place to read "where am I": repo and location together.
* No new data fetches: read what `connectionProvider` and `savedConnectionsProvider` already hold.
* Consistency with the Repository row: same caption/value/glyph/tooltip idiom.
* Show the connection itself, meaning the machine, and use the app's existing "this Mac" wording.
* Show a repository the way the user named it, everywhere the card names it.
* A renamed label shows immediately, without reconnecting.
* Hold at the 640×480 minimum window without overflow.

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

The Repository row's label is part of the decision under every option; it is described below, with the
ways of resolving it that were considered.

### What the Repository row shows

The value is the repository's label when the user has set one, and the last directory of the repo path
otherwise. The glyph, status cluster and tooltip (the full path, plus the status summary) are unchanged,
so the path stays one hover away when a label hides it.

| session | value |
|---|---|
| saved SSH connection | that connection's `repoDisplayName(repoPath)`: the repo's label, else the basename |
| ad-hoc SSH connection | the basename; there is no saved entry to hold a label |
| saved local repo, on the repo it opened | that `SavedLocalRepo`'s `displayName`: the label, else the basename |
| unsaved local open with a typed label | `connectionLabel`, the label typed for this session |
| any other case | the basename |

The rules are implemented once, as a pure function that takes the connection state and the two saved
lists and returns the name. For example `repoDisplayNameFor(connection, savedConnections,
savedLocalRepos)`, beside the storage helpers in `lib/core/storage/`. The row watches both saved
providers and calls it. Two rules are deliberate:

- **SSH never falls back to `connectionLabel`**: that is the connection's name, not the repo's (F3).
- **A local label applies only to `repoPaths.first`**, the path the session opened. If the session later
  switches repo, the saved local repo's label no longer describes it, and the row shows that repo's
  basename (F7).

#### Resolving the label: options considered

* **Resolve from the saved stores by `connectionId` (chosen).** Good, because a label edited in the
  manager shows at once, since the row watches the same providers the manager's tiles do. Good,
  because it touches no connect path. Bad, because the lookup needs the two rules above to avoid
  showing the wrong name.
* **Read `ConnectionState.connectionLabel`.** Rejected: for SSH it is the connection's name, so a repo
  would be shown as "Build box"; for local it goes stale when the label is edited.
* **Add a `repoLabel` field to `ConnectionState`.** Rejected: every connect path (eight call sites of
  `connectLocal`, plus `connectToSaved`, `setRepoPath` and reconnect) would have to thread it through.
  It would still go stale on an edit unless every edit path also wrote to the live state.

#### Scope boundary

This changes the **Repository row only**. Tab titles (`tab_strip.dart:139`), window titles and the
command palette still derive names from the basename, for local and remote alike. That was a
deliberate boundary when remote labels were added. The shared function makes extending it a small
follow-up, but whether to is a separate decision: a tab title is also a disambiguator between tabs,
and two tabs on the same labelled repo would share a title.

### What the Location row shows

The row uses the Repository row's exact layout: glyph, grey `Location` caption, bold single-line
value, trailing slot, and a tooltip.

| session | value | glyph | tooltip |
|---|---|---|---|
| saved SSH | `host` | `CupertinoIcons.globe` | `username@host:port` from the saved connection |
| ad-hoc SSH | `host` | `CupertinoIcons.globe` | `host` |
| local | `This Mac` | `CupertinoIcons.desktopcomputer` | `On this Mac` |

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
* Good, because a repository reads the same in the sidebar as in the connections manager, under the
  name the user gave it.
* Good, because it needs no new provider, fetch or command: it costs zero round trips.
* Neutral, because the tests change: the two label tests in `connection_switcher_test.dart` move to
  the Location row's tests and are rewritten for the new values (the host, unchanged, and `This Mac`), and a
  fixed-label test replaces them on the button.
* Bad, because the sidebar's bottom stack grows by about 40 pt, taking that height from the nav rail's
  viewport at small window sizes (F6).
* Bad, because two saved connections to the same host as different users show the same value; only
  the tooltip's `username@` tells them apart.
* Bad, because the sidebar and the tab strip can now name the same repo differently: the row shows the
  label, while the tab keeps the basename (see the scope boundary above).

### Confirmation

* Widget tests for the Location row: one per session kind in the table above, asserting value,
  glyph and tooltip, including a labelled saved connection showing its host and not its label.
* A widget test that the button reads `Connections` for both an SSH and a local session, and that
  tapping it still opens `ConnectionsPanel`.
* A layout test that the sidebar bottom stack, pumped at the 640×480 minimum, reports no overflow.
* The existing `current_repo_indicator_test.dart` cases pass unchanged.
* Unit tests for the name function, one per row of the Repository table, plus the two edge cases:
  an SSH session whose connection has a label but whose repo has none shows the basename, not the
  connection's name; and a local session switched off `repoPaths.first` shows the new repo's basename,
  not the saved label.
* A widget test that editing a label in the saved store updates the Repository row without a reconnect.
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
* **Included on review:** repository labels in the Repository row. A first draft of this record
  excluded them, citing the boundary under which tab titles, window titles and this row all used the
  basename. The maintainer moved the row across that boundary on 2026-09-18. Tab and window titles stay
  on the basename (see the scope boundary above).
* **Multi-tab:** the Location row reads `connectionProvider` in the same scope as the Repository row,
  so it follows the active tab exactly as that row already does.
* Related: [0008-MADR-unified-repository-chrome.md](../0008-MADR-unified-repository-chrome.md) for the app's chrome.
* The implementation plan, `0052-PLAN-sidebar-info-card-location-and-repository-labels.md`, is written
  once this record is accepted.
