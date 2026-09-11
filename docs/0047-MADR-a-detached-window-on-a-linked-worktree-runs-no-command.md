---
status: "proposed"
date: 2026-09-11
decision-makers: [Maintainer]
consulted: []
informed: [Magic Git contributors]
verified: 2026-09-11
---

# A detached window on a linked worktree runs no command: exec routes by repo ownership, and a worktree is not a repo the session owns

## Context and Problem Statement

Opening a remote linked worktree as a detached window produces a window that can run nothing. Every
provider in it fails at once with `RELAY_DOWN` — surfaced to the log as *"The main window could not
run this command: the window's tab has closed"* — while the tab it was opened from is open,
connected, and watching that very worktree.

This was found during MADR 0045's phase 7 step 7.5, whose watcher checks passed: the host showed the
lock under the worktree's resolved git dir and a live watcher whose working directory was the
worktree. Only the window's commands failed. It is recorded as that plan's deviation (v) and
deliberately left out of MADR 0045, because the fault is in window routing rather than in the watcher
stack.

### F1 — What was observed

Two detached windows, opened from the Worktrees page on a remote linked worktree and pinned to the
same tab, logged the `RELAY_DOWN` message for every provider they tried to populate
(`~/hw-debug.log`, 21:34:15 and 21:34:48 UTC). Neither showed any repository data.

### F2 — How the window is pinned

`WorktreesView._openInWindow` calls `WindowManagerBridge.openDetachedRepo(wt.path)`
(`lib/features/worktrees/worktrees_view.dart:469-475`), which opens a `detachedRepo` window pinned to
that path on the active tab (`window_manager_bridge.dart:153`). `_open` records both facts on the
handle — `repoPath: target` (the worktree) and `tabId` (the opening tab) — and registers it
(`window_manager_bridge.dart:157-217`).

### F3 — The child asks for its own path

The session snapshot the child receives carries `handle.repoPath`, commented as *"The window's OWN
repo — a detached window stays pinned regardless of which repo is active in its tab"*
(`window_manager_bridge.dart:522-528`). So every proxied `execute` the child sends carries the
worktree path as `request.repoPath`.

### F4 — Why routing refuses it

`_onHubCall` resolves the pinned tab's container from `handle.tabId`, then asks
`_execContainerFor(pinned, request.repoPath)` (`window_manager_bridge.dart:586, 781-795`):

* the pinned tab is used **only** when `_sessionOwns` holds — `conn.repoPath == repoPath ||
  conn.repoPaths.contains(repoPath)`. `repoPaths` is "known repos on the connected host"
  (`app_providers.dart:776`), sourced from the saved connection; a linked worktree is not in it unless
  the user has separately opened that worktree as a repository;
* otherwise `TabsController.containerForRepo` scans open tabs for `t.repoPath == repoPath`
  (`tabs_controller.dart:137-144`) — no tab is on the worktree;
* otherwise `null`, and the bridge throws `RELAY_DOWN` with the message *"the window's tab has
  closed"*.

Both tests fail for a worktree, so every command from the window ends in the third branch. The tab has
not closed; the message describes the only case the branch was written for.

### F5 — What the child does with it

At bootstrap the child treats `RELAY_DOWN` as "the pinned tab is already gone" and closes itself
(`secondary_window_main.dart:581-585`); later calls surface the message instead. That is why the
window appears to open and then refuse to work.

### F6 — The same session already serves that path

`_open` subscribes the new window's watcher through the pinned tab's container, keyed by the
**window's** path: `_subscribeWindow(id, container, target)` → `container.listen(repoWatchProvider(
worktree))` (`window_manager_bridge.dart:201, 347-362`). Step 7.5 confirmed this end to end on a live
host. The bridge therefore already treats the pinned tab's session as able to serve the worktree for
watching, and refuses the identical pairing for execution.

### F7 — Why the guard exists, and what it must keep

The ownership rule came from `a4c03d7` (2026-07-12), *"route execute requests strictly to sessions
owning the target repo, preventing command execution against incorrect hosts"*. Its routing comment is
explicit that there is deliberately **no** "fall back to the pinned tab regardless" branch, because
`git -C <repo>` against a session that does not own the repo would reach the wrong host, or silently
the wrong repository. `test/window_bridge_follow_active_test.dart` pins the behaviour that motivated
it: the History pop-out follows the active tab, and a lagging request for the *previous* repo must
route to whichever tab still holds it. Any fix here keeps that intact.

### F8 — The scope of the defect

Nothing in the mechanism is specific to worktrees: any repo-bound window pinned to a path its
session does not list is refused the same way. The worktree is simply the path the UI actually offers
— `detachedRepo` is otherwise opened for the tab's own active repo, which `_sessionOwns` accepts.

## Decision Drivers

* A command must never reach a host that does not own the path it names (F7), which is the property
  `a4c03d7` bought and this record must not sell back.
* The window's pinning is already an explicit, recorded fact — `(tabId, repoPath)` on the handle (F2)
  — and the watcher already trusts it (F6).
* History's follow-active routing must keep working exactly as it does, including mid-switch lag (F7).
* The fix should not require a host round trip on a path the user is waiting on.
* The failure should not be silent or mislabelled: "the window's tab has closed" is untrue in this
  case, and an honest error beats a confusing one wherever a route genuinely cannot be resolved.

## Considered Options

* **A — Route a repo-bound window's own pinned path to its pinned tab.**
* **B — Ask git whether the path belongs to a repository the session owns.**
* **C — Add the worktree to the connection's `repoPaths` when the window opens.**
* **D — Teach the session about its repositories' worktrees, and widen `_sessionOwns`.**

## Decision Outcome

Chosen option: **"A — Route a repo-bound window's own pinned path to its pinned tab"**, because the
window's pin is the fact the bridge already records and already trusts for watching (F2, F6), it
resolves without a host round trip, and it can be stated narrowly enough to leave History's ownership
rule untouched.

The rule, precisely: for a **non-singleton** (repo-bound) window, a proxied request whose
`repoPath` equals that window's own `handle.repoPath` runs on the window's pinned tab, provided that
tab's container still exists and its connection is still connected. Every other request — including
every request from the History window, and any request from a repo-bound window for a path other than
its own pin — keeps today's ownership rule and its `RELAY_DOWN` ending.

This is safe against the defect `a4c03d7` fixed, for reasons that are structural rather than
incidental:

* a repo-bound window never retargets: its pin is fixed at open and `_snapshotFor` keeps the child on
  it (F3), so there is no mid-switch window in which its own path could belong to another session;
* the pin names the tab whose Worktrees page opened the window, which is by construction the session
  that host the path lives on;
* a window whose pinned tab disconnects is already closed by the per-window connection subscription
  (`_onWindowConnectionChanged` → `close(id)`, `window_manager_bridge.dart:499-510`), so the branch
  cannot outlive the session it names;
* History is excluded by the singleton test, so the lagging-request behaviour its test pins is
  untouched.

### Consequences

* Good, because a detached window on a linked worktree works — the case the Worktrees page already
  offers, and the case MADR 0045's 7.5 found broken.
* Good, because watching and executing stop disagreeing about the same `(tab, path)` pairing (F6).
* Good, because the fix is confined to `_execContainerFor` and its caller, with no change to
  `ConnectionState`, saved connections, or the tab model.
* Neutral, because a window pinned to a path its session can no longer serve (the worktree was removed
  on the host) will now fail at git level with a real message rather than at the relay with
  `RELAY_DOWN` — a better error, but a different one.
* Bad, because the routing rule grows a third case, and "repo-bound window, own pin" has to be
  understood by anyone reading `_onHubCall` later. The routing comment must carry it.

### Confirmation

* A bridge test in which a `detachedRepo` window pinned to `(tab A, /repo/wt)` — a path **no** tab
  holds and `repoPaths` does not list — routes its `execute` to tab A's executor, where today it
  throws `RELAY_DOWN`. Run against the unmodified tree first, so the test is seen to fail.
* A bridge test that two tabs on different hosts, one of them the pinned tab, still send the window's
  commands to the pinned tab's executor.
* `test/window_bridge_follow_active_test.dart` unchanged and passing: History still routes by repo
  ownership, and a lagging request for the previous repo still reaches the tab that holds it.
* A test that a repo-bound window asking for a path that is *not* its pin still ends in `RELAY_DOWN`.
* Live: repeat MADR 0045's step 7.5 on a remote linked worktree — the window populates, and the host
  shows the same single watcher under the worktree's resolved git dir.

## Pros and Cons of the Options

### A — Route a repo-bound window's own pinned path to its pinned tab

* Good, because it uses a fact already recorded at open time and already trusted by the watcher path.
* Good, because it costs nothing at request time: one field comparison.
* Good, because the exclusion of singletons keeps History's contract literally unchanged.
* Neutral, because it asserts ownership from provenance ("this tab opened this window on this path")
  rather than from the repository's structure.
* Bad, because provenance is not proof: a path that was the tab's to serve at open time is assumed to
  remain so for the window's life. The window's forced close on disconnect bounds that, but does not
  make it a proof.

### B — Ask git whether the path belongs to a repository the session owns

* Good, because it answers the real question — resolve the path's common git dir on the host and
  compare it with the session's owned repositories — and so covers worktrees, submodules and any
  future nested case in one rule.
* Good, because it establishes ownership rather than inferring it.
* Bad, because it costs a host round trip before the first command of a window the user is waiting
  on, and needs a cache with its own invalidation to avoid paying it repeatedly.
* Bad, because it fails closed when the host is momentarily unreachable, turning a transient error
  into a window that refuses to work — the symptom this record exists to remove.

### C — Add the worktree to the connection's `repoPaths` when the window opens

* Good, because it is the smallest diff: one list gains an entry and `_sessionOwns` passes unchanged.
* Bad, because `repoPaths` means "repositories you can switch this connection to" and is persisted in
  the saved connection; a transient window's pin would appear in the switcher and outlive the window.
* Bad, because it fixes routing by editing session state, so a bug in window lifetime becomes a bug in
  the user's saved connections.

### D — Teach the session about its repositories' worktrees, and widen `_sessionOwns`

* Good, because it matches the domain: a repository and its linked worktrees share objects, refs and
  the worktree list, and the app already fetches that list.
* Good, because it would fix every path that reaches a worktree, not only the windowed one.
* Neutral, because it makes ownership depend on a fetched list's freshness — a worktree added seconds
  ago is not owned until the list refreshes.
* Bad, because it puts worktree knowledge in the connection layer for a window-routing problem, and
  the same question would return for submodules.

## More Information

* **Origin.** [0045-PLAN-one-owner-per-watcher-concern.md](0045-PLAN-one-owner-per-watcher-concern.md),
  deviation (v), and its step 7.5 — whose watcher checks passed on the same live worktree that could
  not run a command.
* **Code this record reads.** `lib/core/providers/window_manager_bridge.dart` (`_open`,
  `_snapshotFor`, `_onHubCall`, `_execContainerFor`, `_sessionOwns`, `_subscribeTick`,
  `_onWindowConnectionChanged`); `lib/features/tabs/tabs_controller.dart` (`containerForRepo`);
  `lib/features/worktrees/worktrees_view.dart` (`_openInWindow`);
  `lib/features/window/secondary_window_main.dart` (the `RELAY_DOWN` close);
  `lib/core/window/window_kind.dart` (`isSingleton`).
* **The guard's history.** `a4c03d7` (2026-07-12) and `test/window_bridge_follow_active_test.dart`,
  which is the contract any fix must leave intact.
* **Not established.** Whether any non-worktree path can reach the same refusal in practice — F8
  argues the mechanism is general, but the only path the UI offers today is the worktree one. No
  implementation exists; this record proposes a decision, and a plan follows only on approval.
