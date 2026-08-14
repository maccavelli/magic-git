# Remote Magic Git — Action Plan (post code-review)

Comprehensive plan addressing the 10 verified findings from the high-effort
review, plus hardening/enhancement work. **For review before implementation.**

**Key decision:** Windows/cross-shell support is being **removed** — a native
Windows port will live in a separate codebase. This app targets **POSIX remotes
only** (Linux/macOS/BSD hosts). That deletes findings #3 and #4 outright and
simplifies the transport layer.

Priority tiers: **P0** (correctness/security, ship first) → **P1** (lifecycle) →
**P2** (UI/UX) → **P3** (hardening/enhancements).

---

## Implementation status

Open UI/UX work after this document lives in
[0004-PLAN-ui-ux-deep-debug-audit.md](0004-PLAN-ui-ux-deep-debug-audit.md)
(HIGH + locked MED + Phase 10 LOW L1–L5 closed). Window chrome is decided in
[0006-MADR-hybrid-native-title-bar-context-bar.md](0006-MADR-hybrid-native-title-bar-context-bar.md);
do not implement it from the deferred `ToolBar` bullet below.

**Done (analyze-clean; 75 tests green when written — the suite is now 321 files
under `test/`):**
- **Phase 0** — POSIX collapse across escaper/formatter/executor/client-manager;
  `ShellType`/shell-probe removed.
- **Phase 1** — #1 wrong-host race (generation token in `SSHClientManager`);
  #2 token leak (env injection removed → one-time `glab auth login --stdin`);
  #5 cancel-during-connect (generation token in `ConnectionController`);
  #4a per-command timeout (`SSHCommandExecutor`, `SSHCommandTimeout`, kill-on-
  expiry, generous commit/network overrides in `GitService`); #6 stale status
  (`statusProvider` autoDispose + connect/disconnect invalidation).
- **Phase 2** — #7 watcher & trace cancel-vs-start guards; #8 dead watcher now
  auto-restarts (bounded) then degrades to polling instead of dying silently.
- **Phase 3** — #9 live-log stick-to-bottom + incremental capped buffer (no more
  O(n²)); #10 commit-graph `ClipRect`; graph/refs memoized out of `build`.
- **Phase 4 (done)** — reconnect-on-drop (`lost` phase + one-click reconnect);
  ⌘R refresh; dark-only theme made explicit (dead light theme removed); dead
  code removed (GPG scaffolding, `GitStatusType` — but **not** `graphql`, which
  was later reintroduced and is live at `glab_service.dart:622`, called by
  `projectDashboard`); `stashApply` wired
  (Apply button); DRY (`_mapList`, `Section*`/`asyncListSection`,
  `LabeledTextField`, `ConnectionState.copyWith`, `ConnectionStore._writeMetadata`,
  `SavedConnection.dedupePaths`); error-swallowing routed through `runAction`;
  `connectToSaved` Keychain reads via `Future.wait`; `GitStatus` partitions
  memoized (`late final`); stale docs updated (`app_shell`, ARCHITECTURE §4.3).

**Deferred (P3 — need on-Mac verification or are speculative):**
- **Native `ToolBar`/`MacosScaffold`** — superseded as a product choice by
  0006 (hybrid native title bar + existing context bar). Implementation still
  needs a live macOS preview; the plan now exists
  ([0006-PLAN-hybrid-native-title-bar-context-bar.md](0006-PLAN-hybrid-native-title-bar-context-bar.md)).
  Do not revive a permanent
  Fetch/Pull/Push icon toolbar.
- **`core.fsmonitor` opt-in** — ✅ done as a **per-repo** toggle in the connections
  management panel (`SavedConnection.fsmonitorPaths`, default off). Applied on
  connect for every opted-in repo and live when toggled on the active host; the
  git-config mutation itself still wants verification against a real large remote.
- ~~**Second dedicated SSH stream client (MaxSessions)**~~ — **shipped since
  this was written** (0007 audit). `SSHClientManager` runs a dual handshake with
  a dedicated `_streamClient` and degrades to a single shared client on failure
  (`ssh_client_manager.dart:132-331`); CLAUDE.md documents it as current
  architecture.
- **Sealed `ConnectionState` union** — revisited during the second review cycle
  below: the generation token alone wasn't sufficient (it structurally allowed
  the reconnect popup to lose its own host and the fsmonitor-enable loop to
  race a superseding connect), so "pure churn, no behaviour change" was too
  confident. Both were fixed with targeted, smaller patches instead of the
  full union — deferring the union again is still the right call *now* (no
  currently-open bug needs it), but if another `ConnectionState` bug surfaces
  from a reachable-but-nonsensical field combination, convert it then rather
  than patching around it a third time.

---

## Second review cycle (2026-07)

A fresh, independent audit (six parallel subagents across the transport,
GitLab, state-management, repository-view, history/branches, and app-shell
layers) run *after* the phases above had already shipped, followed by six
fix phases. Phase numbers below are this cycle's own — they don't correspond
to "Phase 0–4" above, which is the *first* cycle's numbering, already done.

**Reality check on this document going in:** several claims above didn't hold
up under direct verification, corrected in place rather than left stale:
interactive rebase was marked deferred but was actually built; the
`asyncListSection` DRY-up claim was accurate for its one real adopter
(`gitlab_panel.dart`) but overstated everywhere else (8+ sites still hand-roll
loading/error/empty, and — checked again this cycle — mostly for a good
reason: they're lazy `ListView.builder` lists or non-list async values, not
the shape `asyncListSection` was built for, so further migration was correctly
left alone rather than forced); and the System Appearance bullet kept
recommending the opposite of a decision already shipped.

**Phase 0 — SSH/transport correctness:** a queued command executing against
whatever host happened to be current by the time its turn came up (added a
connection-generation check inside `SSHCommandExecutor`, not just in the
manager); non-UTF-8/binary output crashing the decode (`Utf8Decoder
(allowMalformed: true)`); a stalled channel-open (not just a stalled drain)
able to wedge the whole serialized queue forever; session leaks on any
non-timeout exception; a timeout's kill signal targeting a shell wrapper
instead of the real process (`CommandFormatter` now execs the real command,
no wrapper left to leak); no timeout on the auth handshake, and `disconnect()`
unable to reach an in-flight one.

**Phase 1 — connection lifecycle:** the reconnect popup losing its own host/
label on every retry (was replacing `ConnectionState` wholesale instead of
`copyWith`); the same generation-token gap reappearing in the fsmonitor-enable
loop and in `_autoReconnect`'s failure-repair branch (found while fixing the
first one); `stopReconnect()` existing but never wired to any button;
`_invalidateRepoState` covering 5 of ~20 repo-scoped providers; a connection
switch closing the working client before the new one succeeded (deferred
retirement instead).

**Phase 2 — git core correctness:** rebase-from-here silently dropping
commits when a log filter was active (range now resolved from an unfiltered
fetch); the commit graph able to render wrong topology for merges/multi-branch
views (missing `--topo-order`); the file-tree cache signature colliding on
ordinary partially-staged files (XOR self-cancellation, fixed by deduping);
five smaller `git_service.dart` gaps (missing `--no-color`, missing identity
args on two commit-creating calls, a dead/drifted `sync()` removed, retry
policy normalized across reads).

**Phase 3 — GitLab safety:** Approve/Merge/Retry allowing double-submit and
missing a `mounted` check after the actual network call (only after the
confirm dialog); catalog-style lists (issues/milestones — **labels and releases
were not fixed and still use fixed GraphQL `first:` caps with truncation merely
surfaced; see 0007-PLAN step 5.3**, and the same defect exists on the GitHub
side at `gh_service.dart:1140-1146`) silently truncating past one page; three
mutation paths trusting glab's exit code where `-i` + HTTP-status checking was
available (mutations go through REST `glab api -i`, **not** `graphql`, which is
a read helper) or, where it genuinely isn't (CLI subcommands with no
REST equivalent), now documented as such instead of silently inconsistent; a
blank token hanging in an interactive OAuth flow instead of being rejected;
ambient `GITLAB_TOKEN`-family env vars able to silently override the stored
login.

**Phase 4 — UI guards:** a dead watcher never actually surfacing as dead (the
mode was set but never emitted); a branch switch able to skip the
uncommitted-work prompt when status hadn't loaded yet; a trace-log eviction
loop reintroducing the same quadratic-shift pattern it had just fixed
elsewhere. The Coalescer's `minInterval`-over-`maxWait` precedence was
re-flagged as a bug here but turned out to be intentional, deliberately
tested behavior — reverted the planned fix, documented the real precedence
instead.

**Phase 5 — P2 UX:** interactive rebase missing a confirm dialog (added) and
offering a dead Reword option (removed from the enum — see the correction
above); branch delete dead-ending on "not fully merged" instead of offering
force-delete; a handful of `repo_status_view.dart` mounted-guard/setState
gaps; the blame gutter's "show metadata" grouping depending on
`ListView.builder`'s visit order instead of being a precomputed pure
function; the file tree silently no-op'ing on a clean-file click and having
no way to view the staged half of a mixed file (added a context-menu toggle —
which surfaced a real, adjacent bug: the menu could clip off the actual
window since the tree pane is docked at the right edge, now clamped);
the porcelain parser discarding the rename/copy similarity score and the
submodule flag it already parsed, and silently dropping a malformed record
with zero trace; four pipeline pre-run statuses sharing the "unknown status"
orange; the MR-creation diff preview going stale when branches changed while
open.

**Phase 6 — hardening (this pass):** deduplicated `git_service.dart`'s
hand-rolled shell-quoting (`ShellEscaper.escape` already existed); consolidated
the add/remove/context diff-line classification that `diffLineColor` and
`diffLineKind` each implemented independently (`diffLineColor` now delegates
to `diffLineKind` for that overlap, keeping its own header-line handling,
which `DiffLineKind` intentionally doesn't cover); this doc reconciliation.
Reassessed and **declined** two more P3 items after investigation: a sealed
`GitException` hierarchy (only one call site anywhere string-matches stderr,
and it's one this cycle added itself — not enough real usage to justify the
abstraction yet) and the `asyncListSection` migration noted above.

Every phase: `flutter analyze` clean, `flutter test` green, and a new
regression test per fixed bug wherever a fake/seam existed to write one. Where
one didn't (a few SSH-transport race/timeout paths with no mockable seam below
`SSHCommandExecutor.execute()`, and `repo_status_view.dart`'s
interleaving-dependent mounted-guard fix), that's called out at the relevant
commit rather than silently left untested.

**Still open after this cycle:** `repo_status_view.dart` (1091 lines, the
central connected-repo view) remains the largest test-coverage gap — only one
narrow path (Push → output log) is covered. `ssh_client_manager.dart`'s
generation/timeout logic and `ssh_command_executor.dart`'s per-command timeout
are covered only where a fake-executor seam made it possible; the harder
paths (malformed UTF-8, the unified open+drain timeout, auth-timeout/
pending-close) would need a fake transport layer or a disposable local sshd to
close properly.

---

## Phase 0 — Collapse to POSIX-only  _(resolves #3, #4)_

The `ShellType` enum and per-shell branching exist only for Windows. Removing it
eliminates the PowerShell-misdetection bug (#3) and makes the POSIX-only git
commands (#4) correct-by-construction.

- **`shell_escaper.dart`** — drop the `ShellType` enum + cmd/powershell branches;
  keep a single POSIX single-quote `escape(String)`.
- **`command_formatter.dart`** — remove `shellType` param and the cmd/powershell
  env/`cd`/separator branches; always `export … ; cd '<path>' && <argv>`.
- **`ssh_client_manager.dart`** — delete `_probeShellType`/`_runProbe`/`ShellType`
  usage and the `detectedShell` field. **This removes finding #3 entirely** and
  cuts 3 SSH round-trips from every connect.
- **`ssh_command_executor.dart`** — drop `shellType` threading.
- **`git_service.dart`** — the `cat`/`sh -c`/`/dev/null` invocations (#4) are now
  simply correct (POSIX assumed); no change needed beyond removing the shell
  param. Keep them.
- **Tests** — collapse `shell_escaper`/`command_formatter` tests to POSIX cases.

_Risk:_ low (pure deletion). _Payoff:_ simpler, faster connect, two bugs gone.

---

## Phase 1 — Correctness & security  (P0)

### 1. Wrong-host attach race  _(#1 — `ssh_client_manager.dart:48`)_
`connect()` memoizes the in-flight future regardless of profile, so connecting to
B while A is still resolving silently binds to A.

**Fix:** attempt-token (generation) model.
- `SSHClientManager` gets an `int _generation`. Each `connect(profile)` bumps it,
  captures `gen`, and `await disconnect()` of any prior client first.
- After every `await` inside `_connect` (socket connect, auth), if
  `_generation != gen` → the attempt was superseded → **close the just-created
  socket/client and return without setting `_client`** (fixes the leaked-client
  half of #5 too).
- Drop the shared `_connecting` future dedup (superseding replaces it).

### 2. GitLab token exposed in remote argv  _(#2 — `glab_service.dart:41`)_
The `export GITLAB_TOKEN='…'` prelude is part of the command string → visible in
`ps`/`/proc/<pid>/cmdline`/shell audit logs on shared hosts.

**Fix (recommended): stop per-command env injection; rely on the remote's stored
`glab auth`.**
- Remove `_tokenEnv` and the `extraEnv` token plumbing from `GlabService`.
- The remote host already has `glab auth login` configured (confirmed in use), so
  glab reads its own credential store — no secret ever touches a command line.
- **Optional token field behavior:** if a token *is* provided, authenticate the
  remote **once at connect** via `glab auth login --stdin` (token piped over the
  channel's stdin — never argv, never the command string). This is glab's own
  designed mechanism.
- **Plumbing required (found on re-review):** there is currently **no executor
  method that runs a one-shot command with stdin and awaits its result** —
  `writeStdin`/`closeStdin` exist only on the never-cancelled `SSHStreamHandle`.
  Add `execute(..., {String? stdin})` (or a small `runWithStdin` helper) that
  writes stdin, closes it, drains, and returns `SSHCommandResult`. The stdin
  login depends on this.
- Keep secure storage of the token locally (Keychain/dotfile) for that stdin
  login only.
- Update the token-injection unit tests accordingly; update
  `ARCHITECTURE_PLAN.md`'s §4.3 which currently documents the (flawed) env
  approach.

### 3. Cancel-during-connect overwrites disconnect  _(#5 — `app_providers.dart:116`)_
A `disconnect()`/"New connection" issued mid-connect is clobbered when the slow
connect resolves and forces `connected`.

**Fix:** mirror the generation model in `ConnectionController`.
- Add `int _attempt`; each `connect()`/`connectToSaved()`/`disconnect()` bumps it
  and captures the value; before writing the terminal `connected`/`error` state,
  bail if `_attempt` changed. Pairs with the manager-side token from #1 so the
  superseded SSH client is also closed.

### 4a. NEW — no per-command timeout wedges the whole queue  (P0/P1)
_(`ssh_command_executor.dart` — not in the capped 10, found on re-review)_
`execute()` awaits `session.waitForExit()` with **no timeout**, and every command
is serialized on the `_tail` chain. A single hung remote command (an auth prompt
that slips past `GIT_TERMINAL_PROMPT=0`, a stalled network git op, a wedged
`glab`) **blocks every subsequent command for the app's lifetime** — the UI just
spins forever. The 15s timeout only guards the initial socket connect, not
commands.

**Fix:**
- Add a **caller-overridable** per-command timeout to `execute()`; on expiry
  `session.kill(SSHSignal.TERM)`, drain, and return/raise a distinct
  `SSHCommandTimeout` so the UI shows a real error instead of hanging.
- **Right-size the defaults** — legitimately slow commands must not be killed:
  the **hook-driven commit** invokes an AI generator (`git commit` with no `-m`)
  and can take many seconds; `fetch`/`pull`/`push`/`clone` and `glab api` cross a
  network. Use a generous default (~60s) and pass a longer/looser timeout for
  commit and remote-sync ops; keep short reads (`status`, `for-each-ref`, hook
  detection) on the tighter default.
- Ensure the `_tail` chain advances on timeout (it already tolerates errors) so
  one stuck command can't wedge the queue.
- Streaming commands (`executeStream`) are intentionally exempt (they never exit)
  — timeout applies only to request/response `execute()`.

### 4. Stale status across sessions  _(#6 — `app_providers.dart:193`)_
`statusProvider` is non-autoDispose, keyed only by `repoPath`, never invalidated
on connect/disconnect → reconnect (or a same-path different host) serves the
previous session's branch/files; `CreateMrSheet` can prefill the wrong source
branch.

**Fix:**
- Make `statusProvider` (and any other non-autoDispose repo-scoped provider)
  **`autoDispose`** so it's discarded when `RepoStatusView` unmounts on
  disconnect.
- Belt-and-suspenders: in `ConnectionController.connect`/`disconnect`,
  `ref.invalidate(statusProvider)` / `logProvider` / `refsProvider` /
  `stashesProvider` / `prepareCommitMsgHookProvider` so a fresh session never
  reads carry-over cache even if a key collides.

---

## Phase 2 — Watcher & stream lifecycle  (P1)

### 5. Watcher cancel-vs-start race leaks remote processes  _(#7 — `remote_watch_service.dart:92`, `glab_service.dart:224`)_
If the autoDispose provider is cancelled while `start()` is mid-`await`
(detect/executeStream), `stop()` finds nothing to cancel and the spawned
`fswatch`/`inotifywait`/`glab ci trace` process leaks.

**Fix:** a `var cancelled = false;` captured in `watch()`/`traceStream()`.
- `onCancel` sets `cancelled = true` **and** still runs `stop()`.
- After each `await` in `start()` (and after `executeStream` returns), if
  `cancelled` → immediately `handle.cancel()` and bail.
- Apply the same guard to `GlabService.traceStream`.

### 6. Silently dead watcher + stale green dot  _(#8 — `remote_watch_service.dart:70`)_
Stream close (SSH blip / watcher killed) closes the controller silently; the UI's
green "watching" dot stays lit while auto-refresh has stopped.

**Fix (two parts):**
- **Surface it:** on `onDone`/`onError`, emit an error (or a sentinel) so
  `repoWatchProvider` goes to `AsyncError`; `RepoStatusView` shows the dot **grey
  + a "watcher stopped" affordance** (and one status refresh), instead of a lit
  green dot.
- **Auto-recover (optional):** a bounded restart — re-arm the watcher after a
  short backoff while the view is still mounted; fall back to periodic polling if
  restarts keep failing.

---

## Phase 3 — UI / UX  (P2)

### 7. Live CI log force-scrolls to tail  _(#9 — `pipeline_jobs_sheet.dart:174`)_
`jumpTo(maxScrollExtent)` on every build snaps a running log to the bottom, so you
can't scroll back.

**Fix:** "stick to bottom unless scrolled away." Track whether the user is within
~a line of the bottom before the update; only auto-jump if they were. Add a small
"Jump to latest" affordance when not stuck.

### 8. Commit graph paints over text  _(#10 — `history_view.dart:68`)_
Band clamped to 8 lanes but `CommitRowPainter` isn't clipped → lanes >8 draw over
ref chips / subject / author.

**Fix:** clip the painter to its size (`clipBehavior` / `ClipRect`), and compute
the drawn band from `min(laneCount, cap)` while **either** horizontally scrolling
wide graphs **or** collapsing overflow lanes into an indicator — never overpaint
text.

### 9. NEW — O(n²) live-log growth  (P2)
_(`glab_service.dart:192` — capped out)_
`traceStream` emits `buffer.toString()` (the entire accumulated log) on **every**
chunk, and `_TraceLog` rebuilds a single `SelectableText.rich` over the whole
buffer each time — quadratic string copying + full re-layout, several times/sec
on a chatty job.

**Fix:** emit incremental chunks (or a capped tail) and append to a
`ListView`/lazily-laid-out log rather than re-rendering the whole buffer; cap
retained scrollback. Combine with the stick-to-bottom fix (#7).

### 10. NEW — graph/refs recomputed on every setState  (P2)
_(`history_view.dart:42`)_
`CommitGraph.build(commits)` and `refsByCommit(...)` run inside `build()`, so
merely selecting a commit re-lays-out the full (up to 200-commit) lane graph and
re-groups/sorts all refs.

**Fix:** memoize — compute once when `commits`/`refs` change (cache keyed by
identity, or compute in the async data callback / a derived provider) instead of
per `build`.

---

## Phase 4 — Hardening & enhancements  (P3)

Robustness, idioms, and macOS fit-and-finish beyond the capped findings:

**Transport / robustness**
- **Reconnect on drop:** detect `SSHClient.done`/channel close; surface a
  "connection lost" state with a one-click reconnect (reusing the active
  profile), instead of silent failures on the next command.
- ~~**`MaxSessions` awareness**~~ — **done.** The second dedicated `SSHClient`
  for streams shipped (`ssh_client_manager.dart:132-331`, with
  `streamClientDegraded` when the second handshake fails).
- **`core.fsmonitor` opt-in** on large remote repos (research §5) to keep status
  fast; expose as a per-connection toggle.

**State / idioms (Riverpod 3 / Dart 3)**
- Model `ConnectionState` as a **sealed union** (`Disconnected`/`Connecting`/
  `Connected`/`Failed`) for exhaustive `switch` and to make illegal states
  unrepresentable — this structurally prevents the #5 class of bug.
- Audit remaining non-autoDispose family providers for the #6 pattern.

**macOS look-and-feel**
- Move the repo toolbar (fetch/pull/push/sync/stash/refresh/disconnect) into a
  native **`ToolBar`** via `MacosScaffold`, with `ToolBarIconButton`s, for proper
  window-integrated chrome instead of an ad-hoc header `Row`.
- **System appearance — resolved, dark-only.** `themeMode` is hardcoded
  `ThemeMode.dark` and `AppTheme` exposes only a dark theme (the light theme
  was deleted, not just unused) — this bullet previously still recommended the
  opposite ("honor system appearance") after that decision had already shipped;
  corrected here. Revisit only if system-appearance support becomes a real
  ask — as of the second review cycle, dark-only literals throughout the diff/
  log/graph views assume this and would need auditing too.
- Keyboard shortcuts: ⌘R refresh, ⌘K command palette, ⌘, settings. (⌘⇧P was
  listed here as a palette chord; it is bound to Push — `keymap.dart:344`.)
- Consistent empty/loading/error states; subtle hover/press affordances.

**Cleanup, DRY & dead code**  _(from the capped-out review findings)_
- **Dead code:** GPG-forwarding scaffolding in `SSHConnectionProfile`/`connect()`/
  `_forwardGpgSocket` (no code path sets `enableGpgForwarding`), `GlabService.graphql`
  (uncalled *at the time*; it was subsequently wired and is live —
  `glab_service.dart:622`, called by `projectDashboard`), `GitStatusType` enum
  (unreferenced). Either wire or delete — delete is recommended.
- **Unwired feature:** `GitService.stashApply` exists but `BranchesView` wires
  only `stashPop`/`stashDrop` — add an "Apply" affordance or drop the method.
- **DRY:** extract a shared `AsyncValue` loading/error/empty widget (currently
  re-implemented as `_Loading`/`_Error`/`_Empty`, `_async`/`_message`,
  `_error`/`_Pad` across gitlab_panel/project_panel/branches_view/history_view/
  pipeline_jobs_sheet); reuse `GlabService._mapList` in `mergeRequests`/`pipelines`/
  `jobs`; add `ConnectionState.copyWith` (hand-copied in `setRepoPath`); add a
  `_writeMetadata` helper in `ConnectionStore` (save/updateMetadata/delete
  duplicate it); reuse `SavedConnection.allRepoPaths` instead of re-implementing
  the dedupe in `connect`/`connection_form`; share the `_field` labeled-textfield
  helper between `connection_form` and `create_mr_sheet`.
- **Error-swallowing:** `connection_switcher` `_deleteConnection`/`_deleteRepo`/
  `_addRepo` use bare `catch (_) {}`; route through the existing `runAction`/
  `showErrorDialog` so storage failures are surfaced.
- **Micro-perf:** `connectToSaved` awaits four Keychain reads sequentially →
  `Future.wait`; `GitStatus` getters re-filter the file list on every access and
  are called repeatedly per build → compute once.
- **Stale doc:** `app_shell.dart:15` "navigation stub" comment is obsolete;
  `ARCHITECTURE_PLAN.md` §4.3 documents the now-removed env token approach — update
  both.

**Security / storage**
- After #2, document the credential model clearly (remote `glab auth` primary;
  local Keychain only for the optional stdin login).
- Confirm the unsigned-build dotfile fallback path is only used when Keychain is
  genuinely unavailable, and consider `xattr`-based hardening notes.

**Testing**
- New tests: connection generation/supersede race; session invalidation of
  status on reconnect; watcher cancel-during-start (fake executor); commit-graph
  clip / >8-lane handling.
- Consider an `integration_test/` smoke against a disposable local sshd + git
  repo to exercise the live paths that currently only get manual coverage.

---

## Sequencing

1. **Phase 0** (POSIX collapse) — unblocks and simplifies everything; kills #3/#4.
2. **Phase 1** (#1, #2, #5, #6) — one focused correctness/security pass.
3. **Phase 2** (#7, #8) — watcher lifecycle.
4. **Phase 3** (#9, #10) — UI fixes.
5. **Phase 4** — incremental hardening/enhancements, prioritized as desired.

Each phase: `flutter analyze` + `flutter test` green, new tests for the fixed
behavior, and a Mac build verification for the runtime paths. A re-review after
Phases 0–2 is recommended before calling the correctness work done.
