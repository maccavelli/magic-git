---
status: "complete"
date: 2026-09-17
verified: 2026-09-17
associated-madr: "0047-MADR-a-detached-window-on-a-linked-worktree-runs-no-command.md"
---

# Implement: a repo-bound window's own pinned path routes to its pinned tab

Associated MADR: [0047-MADR-a-detached-window-on-a-linked-worktree-runs-no-command.md](0047-MADR-a-detached-window-on-a-linked-worktree-runs-no-command.md)

## Goal

Implement the MADR's chosen option A, stated precisely there: for a **non-singleton** (repo-bound)
window, a proxied request whose `repoPath` equals that window's own `handle.repoPath` runs on the
window's pinned tab, provided that tab's container still exists and its connection is still connected.
Every other request — every request from the History window, and any request from a repo-bound window
for a path other than its own pin — keeps today's ownership rule and its `RELAY_DOWN` ending.

## Scope

### In

| File | Change |
| --- | --- |
| `lib/core/providers/window_manager_bridge.dart` | `_execContainerFor` gains a `handle` parameter and the own-pin exception; both call sites (`execute`, `uploadBytes` in `_onHubCall`) pass `handle` |
| `test/window_bridge_follow_active_test.dart` | extended — the four cases the MADR's Confirmation section names |

### Out

* **No change to `ConnectionState`, saved connections, `repoPaths`, or the tab model** — the MADR's own
  framing of what option A costs, and the reason it was chosen over B/C/D.
* **No change to `_sessionOwns`, `containerForRepo`, or History's routing** — `WindowKind.isSingleton`
  already excludes History from the new branch; `test/window_bridge_follow_active_test.dart`'s four
  existing tests must pass unchanged, which is itself part of the proof this stays true.
* **The "Not established" item** (whether a non-worktree path can reach the same refusal) — F8 argues
  the mechanism is general, but confirming that needs a second UI path the app doesn't offer today.
  Nothing in this plan depends on it either way: the fix is keyed on `handle.repoPath`, not on what kind
  of path it is.

## Rules for every phase

1. **Deviations stop the work.** A wrong step, a file not listed, or a pre-existing defect this plan
   does not cover is reported with evidence and real resolutions, and waits for the maintainer. Docs are
   amended before work continues.
2. **Commits** use exactly `git commit --no-edit`. Code and docs are never in one commit. Nothing is
   pushed unless the maintainer asks in that same turn.
3. **The gate before every code commit:** `flutter analyze` clean; `dart format --output=none
   --set-exit-if-changed` on each staged `.dart` file; the phase's targeted tests; then `flutter test` in
   full. Exit statuses are captured in variables, never piped into a filter.
4. **Every new guard is seen to fail** against a deliberately broken copy in a detached scratch worktree
   (`git worktree add --detach`), never by dirtying the tree, and the failure output goes in the
   execution record.

## Grounding

Current code (verified against HEAD; the file has not changed since the MADR was written — last commit
touching it, `9e32bd1`, predates the MADR by over a week):

`WindowHandle` (`window_manager_bridge.dart:25-40`):

```dart
class WindowHandle {
  final String id;
  final WindowKind kind;
  final String? repoPath;
  final String? tabId;

  const WindowHandle({
    required this.id,
    required this.kind,
    this.repoPath,
    this.tabId,
  });

  WindowHandle withRepoPath(String? path) =>
      WindowHandle(id: id, kind: kind, repoPath: path, tabId: tabId);
}
```

`WindowKind` (`lib/core/window/window_kind.dart`, full file):

```dart
enum WindowKind {
  history,
  detachedRepo;

  static WindowKind fromName(String? name) =>
      WindowKind.values.asNameMap()[name] ?? WindowKind.history;

  bool get isSingleton => this == WindowKind.history;
}
```

`_onHubCall`'s `execute` case (`window_manager_bridge.dart:569-587`) already has `handle` in scope
before calling `_execContainerFor`:

```dart
    final handle = _handle(id);
    final container = handle == null ? null : sessionContainerFor(handle.tabId);
    switch (call.method) {
      case 'execute':
        final request = decodeExecuteRequest(
          call.arguments as Map<Object?, Object?>,
        );
        // [routing comment, unchanged by this plan except its final paragraph]
        final execContainer = _execContainerFor(container, request.repoPath);
        if (execContainer == null) throw _relayDown();
```

`uploadBytes` (`window_manager_bridge.dart:637-644`) calls the same method identically:
`_execContainerFor(container, upload.routingRepo)`.

`_execContainerFor`/`_sessionOwns` (`window_manager_bridge.dart:778-795`):

```dart
  ProviderContainer? _execContainerFor(
    ProviderContainer? pinned,
    String repoPath,
  ) {
    if (pinned != null && _sessionOwns(pinned, repoPath)) return pinned;
    return containerForRepo(repoPath);
  }

  bool _sessionOwns(ProviderContainer container, String repoPath) {
    final conn = container.read(connectionProvider);
    return conn.repoPath == repoPath || conn.repoPaths.contains(repoPath);
  }
```

`_onWindowConnectionChanged` (`window_manager_bridge.dart:485-510`) already closes any window, of any
kind, whose pinned tab disconnects (`if (disconnected) close(id);`) — the fact F7/the Decision Outcome
rely on to say the new branch "cannot outlive the session it names."

`ConnectionState.isConnected` is already used elsewhere in this file (`_onWindowConnectionChanged`'s
`next.isConnected`), so the "provided ... its connection is still connected" clause has a ready-made
check.

`test/window_bridge_follow_active_test.dart`'s existing harness (reused verbatim, not rebuilt):
`_MutableConnection` (a settable `ConnectionController`), `_FakeExecutor` (records which `repoPath`s it
was asked to run against), `_connected(repo)`, `_req(repo)`, and `deliverHubCall(method, args)` (drives
a method call through the mocked hub channel and decodes the reply — a thrown `RELAY_DOWN` "surfaces as
a decode error on the reply", per the existing test that already asserts this shape). Its four existing
tests open only `history`-kind windows; none opens a `detachedRepo` window and points it at a path no
tab owns — exactly this plan's gap. `container.read(windowManagerBridgeProvider.notifier)
.openDetachedRepo([repoPath])` is the public entry point the app itself uses
(`WorktreesView._openInWindow`), confirmed at `window_manager_bridge.dart:153`.

## Execution Record

Approved and executed starting 2026-09-17.

### Phase 0, executed

`Flutter 3.47.2` matched `FLUTTER_VERSION`; `flutter pub get --enforce-lockfile` resolved clean;
`lib/`, `test/` were clean. Baseline `flutter test`: 4119 tests, 0 failures.

### Phase 1, executed

**Modified.** `_execContainerFor` gains a nullable `WindowHandle? handle` parameter and a second
short-circuit — `pinned` when `_isOwnPin(handle, repoPath)` (a repo-bound, non-singleton window whose
own pin is the requested path) and `pinned`'s connection is still connected — between the existing
ownership check and the `containerForRepo` fallback. A new one-line predicate, `_isOwnPin`, names the
condition. Both call sites in `_onHubCall` (`execute`, `uploadBytes`) now pass `handle`, which was
already in scope at both. The routing comment above the `execute` call gained the MADR's own third
bullet, quoted rather than re-derived.

**Created.** Three tests in `test/window_bridge_follow_active_test.dart`, reusing the existing harness
(`_MutableConnection`, `_FakeExecutor`, `_connected`, `_req`, `deliverHubCall`) verbatim — no new
harness needed, matching the plan's Grounding section: `'a detachedRepo window routes to its own
pinned tab for a path no tab owns (MADR 0047)'`, `"a detachedRepo window's own pin still wins with a
second, unrelated tab open"`, `'a detachedRepo window asking for a path that is not its own pin still
gets RELAY_DOWN'`. The file's four pre-existing tests run unmodified alongside them.

**Seen to fail**, in a detached scratch worktree with only the fix reverted (copying just the modified
test file onto the unmodified `HEAD`): the new "routes to its own pinned tab" test failed with the
exact predicted shape —

```text
PlatformException(RELAY_DOWN, the window's tab has closed, null, null)
```

**Gate.** One compile fix along the way: `WindowKind` needed its own import in the test file (not
re-exported by `window_manager_bridge.dart`), caught by the first test run and fixed before formatting.
`dart format` clean (one import-ordering lint from `flutter analyze` fixed by re-sorting). `flutter
analyze` No issues. Targeted tests — `window_bridge_follow_active_test.dart`,
`window_manager_bridge_test.dart`, `tabs_host_test.dart` — 42/42 green. Full suite: 4122 tests (+3), all
green, no regressions. **Commit** `6234f76`.

**Incidental cleanup.** Removed an orphaned scratch worktree at
`/private/var/folders/.../T/mutate-37rrpqcx`, left behind by an earlier `tool/mutate.py` run for the
0050 plan that was stopped mid-check (via `TaskStop`) before it reached its own cleanup step — unrelated
to this plan's own two scratch worktrees, which were each removed immediately after their seen-to-fail
check as usual.

### Phase 2, executed

**Manual, on the maintainer's machine, 2026-09-17.** Repeated MADR 0045's step 7.5 on a remote linked
worktree: opened it as a detached window from the Worktrees page. Observed: the window populated with
real repository data (where before this plan it showed `RELAY_DOWN` for every provider), and the host
still showed exactly one watcher under the worktree's resolved git dir — unchanged from 7.5, confirming
this plan did not touch the watcher stack.

### Phase 3, executed

MADR 0047 → `status: accepted`, `verified: 2026-09-17` (flipped at the start of implementation, when the
maintainer approved proceeding). This plan → `status: complete`, `verified: 2026-09-17`, now that
Phase 2 is done. `docs/README.md` row updated.

## Implementation Steps

### Phase 0 — preconditions

0.1 `flutter --version | head -1` matches `FLUTTER_VERSION` in `build_macos.sh` (**3.47.2**), and
`flutter pub get --enforce-lockfile` says `Got dependencies!`.

0.2 Baseline, recorded in the execution record: `flutter test` in full, and `git status --short` empty.

### Phase 1 — the routing fix

1.1 `window_manager_bridge.dart`: give `_execContainerFor` a third, nullable parameter and the own-pin
exception, and extract the predicate so its one job has a name:

```dart
  ProviderContainer? _execContainerFor(
    ProviderContainer? pinned,
    String repoPath,
    WindowHandle? handle,
  ) {
    if (pinned != null && _sessionOwns(pinned, repoPath)) return pinned;
    if (pinned != null &&
        handle != null &&
        _isOwnPin(handle, repoPath) &&
        pinned.read(connectionProvider).isConnected) {
      return pinned;
    }
    return containerForRepo(repoPath);
  }

  /// Whether [repoPath] is [handle]'s own pinned path on a repo-bound
  /// (non-singleton) window (MADR 0047, option A). History is excluded by
  /// `isSingleton`: its lagging-request behaviour during a repo switch is
  /// `_sessionOwns`/`containerForRepo` only, and this plan leaves it untouched.
  bool _isOwnPin(WindowHandle handle, String repoPath) =>
      !handle.kind.isSingleton && handle.repoPath == repoPath;
```

`handle` stays nullable to match `_handle(id)`'s own return type — a null handle already routes through
`containerForRepo` today via the existing branch, and this plan does not change that path.

1.2 Both call sites in `_onHubCall` pass `handle`:

* `execute` (~line 583): `_execContainerFor(container, request.repoPath, handle)`.
* `uploadBytes` (~line 641): `_execContainerFor(container, upload.routingRepo, handle)`.

1.3 Extend the routing comment above the `execute` case's `_execContainerFor` call with the third
bullet the Decision Outcome already states precisely (quoted, not paraphrased), so a future reader sees
the rule beside the code exactly as recorded in the MADR — matching the existing comment's own style of
stating each branch as a bullet.

1.4 Extend `test/window_bridge_follow_active_test.dart` with the four cases the MADR's Confirmation
section names, using the existing harness:

* `'a detachedRepo window routes to its own pinned tab for a path no tab owns'` — open a
  `detachedRepo` window via `openDetachedRepo('/repo/wt')` on a tab connected to a different active
  repo (so `_sessionOwns` is false and `/repo/wt` is in no tab's `repoPaths`); assert
  `deliverHubCall('execute', ...)` for `/repo/wt` reaches that tab's `_FakeExecutor`, where today it
  throws `RELAY_DOWN`.
* `'a detachedRepo window's own pin still wins with a second, unrelated tab open'` — two tabs, two
  distinct `_FakeExecutor`s, only one pinned; assert the window's command reaches the pinned tab's
  executor and never the other one's.
* `'a detachedRepo window asking for a path that is not its own pin still gets RELAY_DOWN'` — same
  window, a request for a *different* path neither tab owns; assert the existing refusal is unchanged.
* Run the file's four pre-existing tests unmodified — the acceptance criterion that History's routing
  and the mid-switch lagging-request behaviour are untouched.

1.5 **Seen to fail**, in a detached scratch worktree with only 1.1-1.2 reverted: the new
"routes to its own pinned tab for a path no tab owns" test fails with `RELAY_DOWN`, the exact shape
described in F1/F4.

1.6 Gate (rule 3), then **commit (code)**.

### Phase 2 — live verification

2.1 **Manual, on the maintainer's machine** (MADR Confirmation's last bullet): repeat MADR 0045's step
7.5 on a remote linked worktree — open it as a detached window from the Worktrees page, confirm the
window populates (where before it showed `RELAY_DOWN` for everything), and confirm the host still shows
a single watcher under the worktree's resolved git dir (unchanged from 7.5, since this plan does not
touch the watcher stack).

### Phase 3 — close the records

3.1 MADR 0047 → `status: "accepted"`, `verified:` today. This plan → `status: complete` with its
execution record (once 2.1 is done — until then, `in-progress`, matching this repo's convention for a
plan with an outstanding manual step). `docs/README.md` row for 0047. **Commit (docs).**

## Verification

The whole-plan gate:

```sh
flutter --version | head -1                       # Flutter 3.47.2
flutter analyze                                   # No issues found
flutter test                                      # all pass
flutter test test/window_bridge_follow_active_test.dart test/window_manager_bridge_test.dart
```

Exit statuses are captured, never piped into a filter. Manually: Phase 2.1, recorded either way.

## Acceptance Criteria

1. **Met.** A `detachedRepo` window pinned to a path no tab owns and `repoPaths` does not list routes
   its `execute`/`uploadBytes` calls to its own pinned tab, where it previously `RELAY_DOWN`ed — seen
   to fail against the unmodified tree with the exact `RELAY_DOWN` shape, then passing after the fix.
2. **Met.** Two tabs open, only one pinned: the window's commands reach the pinned tab's session, never
   the other one's.
3. **Met.** A repo-bound window asking for a path that is **not** its own pin still ends in
   `RELAY_DOWN` — the fix is scoped to the window's own pin, not a general relaxation.
4. **Met.** `test/window_bridge_follow_active_test.dart`'s four pre-existing tests pass unmodified:
   History's ownership-based routing and its mid-switch lagging-request behaviour are untouched.
5. **Met.** `flutter analyze` clean, full suite green (4122 tests), every staged Dart file formatted.
6. **Met, 2026-09-17.** Live: MADR 0045 step 7.5 repeated on a remote linked worktree on the
   maintainer's machine — the detached window populated with real repository data, and the host showed
   exactly one watcher under the worktree's resolved git dir, unchanged from 7.5.

## Rollout and Rollback

One commit for the fix, one for docs. The change is additive to `_execContainerFor` (an extra
short-circuit before the existing fallback), so rollback is safe at any point:
`git revert --no-edit <sha>`, never a reset or a rewrite. Nothing is pushed unless the maintainer asks
in that same turn. Nothing persisted changes — the fix is purely in-memory routing logic — so rollback
returns exactly to today's `RELAY_DOWN` behaviour for a detached window on a linked worktree.

## Risks

* **`handle` can be null** at `_onHubCall`'s call sites (`_handle(id)` returns `WindowHandle?`) — the
  new parameter and predicate are written null-safe from the start (1.1), not patched in after a crash,
  since a null handle already falls through to `containerForRepo` today and must keep doing so.
* **`pinned.read(connectionProvider).isConnected`** assumes `pinned`'s container is still live enough to
  read from safely. Per F7/`_onWindowConnectionChanged`, a disconnected pinned tab's window is already
  closed by the time any further command could arrive, so this should never observe a torn-down
  container — but if Phase 1.4's tests find a window it can, resolving that is exactly what rule 1
  ("deviations stop the work") is for.
* **The routing comment grows a third case.** The MADR's own Consequences section already names this
  cost ("the routing rule grows a third case... has to be understood by anyone reading `_onHubCall`
  later") — 1.3 pays it down by quoting the MADR's own precise wording rather than re-deriving it.
