---
status: proposed
date: 2026-08-20
decision-makers: [Maintainer]
consulted: []
informed: [Magic Git contributors]
---

# Treat the 2026-08 SSH engine and UI/UX unit-test gap assessment as the coverage backlog

## Context and Problem Statement

Magic Git now has **348** `*_test.dart` files against **264** library Dart
files. The SSH engine (dartssh2 **3.3.0**, dual-then-triple `SSHClient`,
busy-pause, activity deadlines, native sockets) shipped as
[0014](./0014-MADR-ssh-engine-next-wave-hardening.md) /
[0014-PLAN](./0014-PLAN-ssh-engine-next-wave-hardening.md). The UI chrome
went through [0004](./0004-MADR-ui-ux-deep-debug-audit.md),
[0008](./0008-MADR-unified-repository-chrome.md), and
[0009](./0009-MADR-ui-ux-debug-pass-backlog.md). A connect-time forge-login
race that painted “not logged in” into the Repository panel and file-view
pane was fixed in the same cycle as this record.

The remaining question is not “are there tests.” It is: **given the current
tree, which SSH-engine and UI/UX behaviors that users can actually hit still
have no unit (or widget) proof — so a regression would only show up on a
live Mac against a real host?**

[TEST_COVERAGE_PLAN.md](./TEST_COVERAGE_PLAN.md) is **stale as a count
source** (it still says ~250 test files / ~48 untested sources; `auth_probe_service_test.dart`,
`saved_local_repo_test.dart`, `app_providers_test.dart`, and many chrome
contracts now exist). This record does not execute that plan. It replaces
its SSH/UI slice with evidence from 2026-08-20.

This MADR does **not** reopen 0011 (busy-pause), 0013 (dartssh2 pin), or
0014’s product choices. It does not authorise implementation; a paired PLAN
is required before any further source or test file is added. (One slice —
the connect-time auth fix and U1's local half — shipped alongside this
record in `e4c1c25`; see “Tranche status” under Decision Outcome.)

### Audit method

* Inventory `lib/core/ssh/`, `lib/core/exec/`, and `lib/features/` against
  `test/*.dart` (name match plus `rg` of types, getters, and UI strings).
* Cross-check 0014 PLAN acceptance criteria (triple handshake, allowlist
  reconnect, `ActivityDeadline`, adaptive error floor, env cache) against
  the tests that actually assert them.
* Cross-check UI error surfaces (`RepoStatusView`, `FileView`, `PaneError`,
  Dashboard latency section, reconnect chrome) against widget tests.
* Search tools used `rg -a` on `lib/core/providers/app_providers.dart`
  (classified as binary). `.flutter-sdk/`, `build/`, and `.dart_tool/` were
  excluded.

The full `flutter test` suite and a live `.app` were **not** re-run for this
pass. Numbers below are from source. Targeted files related to 0014 and the
forge-auth-pending fix were already green in the preceding work cycle.

### What is already true (do not re-solve)

**SSH / exec — covered**

* `ActivityDeadline` idle vs ceiling as a pure timer
  (`test/activity_deadline_test.dart`, three cases).
* `ActivityDeadline` **through `LocalCommandExecutor.execute`**: stdout and
  stderr pulses both beat the idle budget, silence throws
  `SSHCommandTimeout`, and the ceiling still kills a pulsing command
  (`test/local_command_executor_test.dart` ~215–270). Landed in `e4c1c25`,
  the same commit as this record — see U1.
* Reconnect allowlist vs `SSHAuthFailError` pause
  (`test/ssh_error_messages_test.dart`, `test/auto_reconnect_test.dart`
  `'an auth failure pauses auto-reconnect immediately'`).
* Three parallel connect sockets before auth
  (`test/ssh_transport_hardening_test.dart` `'connect opens three
  handshakes in parallel…'`).
* Adaptive cap: RTT bands, hysteresis, channel-open error floor
  (`test/adaptive_read_concurrency_test.dart`).
* Same-host env-probe cache and disconnect invalidation
  (`test/connection_env_reset_test.dart`
  `'same-host auto-reconnect reuses the env cache; disconnect invalidates'`).
* Native socket `tcpNoDelay` round-trip
  (`test/native_ssh_socket_test.dart`).
* Unencrypted PEM `decodeIdentities` isolate round-trip
  (`test/ssh_key_decode_isolate_test.dart`; skips if `/usr/bin/ssh-keygen`
  is missing).
* Gunzip offload threshold
  (`test/ssh_command_executor_test.dart` `'decodes a payload over the
  offload threshold off-isolate'`).
* `activityIdleMs` codec round-trip for pop-out exec
  (`test/exec_proxy_codec_test.dart`).
* Lanes, drain budgets, formatter, escaper, local executor, proxy
  executor, scoped forge executor, health-monitor busy-pause, generation
  pinning, stream redial *schedule* (the `Duration` helper, not a live
  redial).
* Live loopback sshd suite (`test/ssh_live_transport_test.dart`,
  `integration` tag) — self-skips without `/usr/sbin/sshd`. Includes
  `transportBusy` while a command runs; does **not** assert
  `attachedClientCount == 3` or reads-during-sync.

**UI — covered**

* Repository status mutations, commit bar size/order, conflict pane
  (`test/repo_status_view_test.dart`).
* File-view structure, overlay recolor, context menus
  (`test/file_view_test.dart`).
* Settled “not logged in” dump still shows after forge login completes
  (`repo_status_view_test` / `file_view_test` `'…once forge login has
  settled'`).
* Provider-level retry of pre-login auth failures
  (`test/connection_race_test.dart`).
* `looksLikeAuthFailure` phrasing table including GitException stderr and
  `terminal prompts disabled` (`test/forge_list_error_test.dart`).
* Chrome contracts: one band, keymap/menu reachability, repository
  context bar (`test/chrome_*.dart`, `test/repository_chrome_contract_test.dart`,
  `test/menu_bar_spec_test.dart`).
* Link-status chip “Reconnecting” (`test/link_status_chip_test.dart`).
* Landing “Connection lost” (`test/connection_landing_test.dart`).
* Activity center list/button (`test/activity_center_test.dart`).
* Dashboard session sections exist, including the latency heading
  (`test/dashboard_sheet_test.dart`) — **not** the 0014 client-count / cap /
  channel-open stats.

## Decision Drivers

* **Behavioral proof, not file-count.** A source file with a matching
  `*_test.dart` can still miss the load-bearing branch (degrade-to-dual,
  stderr pulse, spinner-not-dump).
* **0014 claimed verification that only exists at the leaf.** The PLAN’s
  gate listed `ActivityDeadline` unit tests and a 3-socket handshake.
  Wiring those primitives through `SSHCommandExecutor.execute` /
  `GitService.fetch` and through the Dashboard is unproven.
* **User-visible races first.** Connect-time “not logged in” already
  escaped into two panes; the retry is provider-tested, the loading
  substitution in the widgets is not.
* **No live-forge, no sshd requirement for the first tranche.** Gaps that
  need `/usr/sbin/sshd` stay on the live suite; unit tests must use fakes
  and loopback `ServerSocket`s the way 0014’s handshake test already does.
* **Do not restart TEST_COVERAGE_PLAN.** Many of its Phase 1–2 items have
  landed. A new coverage pass should cite this record’s IDs.
* **Root-cause tests.** Assert the client object, the idle pulse, or the
  widget branch — not a sleep-and-hope that the pane “looks fine.”

## Considered Options

* **A. Record findings only; add tests ad hoc when the next bug lands.**
* **B. Accept this assessment as the authoritative SSH/UI unit-test
  coverage backlog**, with a recommended first tranche that closes 0014’s
  unverified wiring and the connect-time auth/UI race, and explicitly defer
  goldens, Help-book prose, and live-sshd topology checks.
* **C. Mandate one widget test per `lib/features/**` file** (including
  `field_styles.dart`, `sheet_chrome.dart`, `tool_icon_button.dart`).
* **D. Treat 0014 PLAN Phase 10 live sshd checks as the next commit**
  (`attachedClientCount == 3`, reads during a long sync) before any unit
  gap.

## Decision Outcome

Chosen option: **"B. Accept this assessment as the authoritative SSH/UI
unit-test coverage backlog"**, because the highest-leverage holes are
concentrated in behaviors 0014 and the forge-login race already declared
done, and because file-count mandates (C) and live-sshd-first (D) either
drown the suite in chrome widgets or skip machines without sshd.

The recommended **first tranche** (implement only after a paired PLAN is
approved) is **U1–U8** below. Everything else is recorded so it is not
re-discovered, not so it is built in the same cycle.

**Tranche status at the time of writing.** `e4c1c25` — the commit that
carried this record and its PLAN into the tree — also landed the
forge-auth-pending production fix (`display_error.dart`,
`repo_status_view.dart` ~1671, `file_view.dart` ~722,
`forge_widgets.dart` ~183), its provider-level tests
(`connection_race_test.dart`), the *settled*-auth widget tests, and
**U1's local half**. So U1 is partly closed before this record was
accepted; U2–U8 are untouched. The PLAN's phase list reflects that.

This record does not change product architecture. Filling a gap may
require a `@visibleForTesting` hook (for example, which `SSHClient` a
lane used); that is a test seam, not a new transport.

---

## Current coverage: SSH engine (fact)

| Area | Proof today | Hole |
|---|---|---|
| Triple handshake scheduling | 3 TCP accepts on a mute `ServerSocket` | No proof the **third** client is the sync one after a successful auth (mute server never authenticates) |
| Degrade-to-dual / sync redial | Getters null when disconnected | No test that a failed sync handshake still connects, sets `syncClientDegraded`, routes `ExecLane.sync` onto `client`, or redials |
| `ExecLane.sync` → `syncClient` | `ssh_command_executor.dart` ~676–678 | No test spies which client object `execute` used |
| Busy-pause split | `commandBusy` / `syncBusy` / stream window in source; live test only `transportBusy` | No unit test that a sync fetch pauses the **sync** monitor and leaves the command monitor probing |
| `ActivityDeadline` class | 3 pure-timer tests, plus 4 end-to-end cases through `LocalCommandExecutor.execute` | **Not** exercised through `SSHCommandExecutor.execute` — `rg activityIdle test/ssh_command_executor_test.dart` is empty, and the SSH path is the one 0014 shipped for |
| GitService network ops | `activityIdle: networkTimeout` at 7 call sites (`git_service.dart` fetch/pull/push/…) | Fakes accept `activityIdle` and never assert it was the settings duration |
| Channel-open → adaptive cap | Adaptive unit tests | Executor records `SSHChannelOpenError` into telemetry (`ssh_command_executor_test`); Dashboard does not read the number |
| Native socket | `tcpNoDelay` round-trip | Darwin `SO_KEEPALIVE` `setRawOption` path is unasserted (best-effort `catch` in `native_ssh_socket.dart` ~30–40) |
| PEM offload | Unencrypted ed25519 only | Encrypted bcrypt PEM, and “decode once, reuse on three clients,” untested |
| Sideload stdin | `uploadTimeoutFor` scaling | `addStream` + `flush` in `ssh_command_executor.dart` ~793–795 has **zero** tests (`rg addStream test/` is empty) |
| Env cache | Same-host reconnect reuses; disconnect invalidates; a superseded probe cannot reconfigure the shared executor (`connection_env_reset_test.dart`) | The key is `'${host}\|${port}\|${username}'` (`app_providers.dart` ~867), but every test varies only the **host** (`'mac'` vs `'bastion'`). A same-host / different-username or different-port profile has no cache-**miss** proof — see U16 |
| Live topology | Skips without sshd | 0014 Phase 10 `attachedClientCount == 3` and “echo on read during long sync” are not in `ssh_live_transport_test.dart` |
| Stale names | `ssh_command_executor_test.dart` group `'SSHClientManager generation + dual-client surface'` | Comments still say dual; getters already include `syncClient` |

`ActivityCommandExecutor` (`lib/core/exec/activity_command_executor.dart`)
has no dedicated test file. It is a pass-through decorator; `operation_activity_test.dart`
covers the records, not the wiring of `onOperationEvent` through the
decorator.

`HostKeyPrompt` is a data class; behavior lives in
`host_key_dialog_test.dart` / `host_key_verification_test.dart`. That is
enough. Do not add a constructor-only test file.

---

## Current coverage: UI/UX (fact)

| Surface | Proof today | Hole |
|---|---|---|
| Repo status pane error | Settled auth dump is shown | **No** widget test that `forgeAuthPending && looksLikeAuthFailure` renders `ProgressCircle` and **hides** the dump. A spinner test was attempted and withdrawn: `ProgressCircle` plus Riverpod retry timers fail `!timersPending` at teardown |
| File-view pane error | Same settled dump | Same pending-spinner hole; structure retry is provider-only (`connection_race_test`) |
| `PaneError` (forge lists) | `ForgeListError` sign-in callout | `PaneError` itself never pumped with `forgeAuthPending: true` |
| Dashboard latency row | Heading `'Link latency (SSH keepalive)'` | No expect for `'triple'` / `'dual'` / `'ssh clients'` / `'read cap'` / `'channel opens'` (`dashboard_sheet.dart` ~353–391) |
| Reconnect chrome | Chip + landing “Connection lost” | In-session lost popup (`app_shell.dart`) is not widget-tested; `app_shell_test.dart` is one sidebar-collapse case |
| Settings Network field | Persistence of `networkTimeoutSecs` | Stall-budget copy (“silence”, 30 min ceiling) unasserted |
| History panel | Filter, drag-merge, paging, search, rebase sheet | `history_view.dart` has no dedicated widget file; contracts only via `repository_chrome_contract_test` / `menu_bar_spec_test` |
| Connection form | Landing + edit + switcher | `connection_form.dart` / `local_repo_form.dart` unmatched by name; covered only where landing pumps them |
| Forge sheet chrome | Panel, issues, merge readiness | `forge_create_sheet_widgets.dart`, `merge_options_sheet.dart`, `forge_workspace.dart` unmatched |
| GitHub run jobs | — | `run_jobs_view.dart` unmatched; GitLab `pipeline_jobs_view_test.dart` exists |
| Secondary window | `secondary_window_app_test.dart` | `secondary_window_main.dart` / `secondary_window_binding.dart` unmatched |
| Chrome atoms | Cursor/button canons, goldens | `field_styles`, `sheet_chrome`, `show_more_row`, `sidebar_branding`, `tool_icon_button` are style, not behavior |

Name-match found **56** feature files without an obvious `*_test.dart`.
Many are intentional (pure styling, or covered under a sibling test). The
table above is the **behavior** subset, not a mandate to test every
`StatelessWidget`.

---

## Findings (prioritized)

IDs are for a future PLAN. Severity is “what a silent regress costs,” not
test-file size.

### HIGH — first tranche (U1–U8)

**U1. Activity deadline through the executors.**
`ActivityDeadline` can pass while `execute(..., activityIdle: …)` still
uses a flat wall clock.

*Local half — **closed** in `e4c1c25`.* Four cases drive real `sh` through
`LocalCommandExecutor.execute` (`local_command_executor.dart` ~199, pulses
at ~272/~284): stdout pulses, stderr pulses, silence throws
`SSHCommandTimeout`, ceiling still kills a pulser.

*SSH half — **open**, and it is the half 0014 shipped for.* No test in
`test/ssh_command_executor_test.dart` passes `activityIdle` at all. The
production pulses sit inside the drain (`ssh_command_executor.dart` ~818
on stdout, ~847 on stderr) behind `client.execute`, so this needs the
fake session from U2's infrastructure: a session whose `stderr` emits a
byte every 100 ms past the idle budget must **complete**; a silent
session must throw `SSHCommandTimeout`. Until then 0014 T2 is a class
plus a parameter nobody checks on the transport that uses it.

**U2. Sync-lane client routing and degrade-to-dual.**
A fake `SSHClientManager` with distinct command/sync client objects (or a
loopback handshake that fails only the third socket) must prove:
`ExecLane.sync` talks to `syncClient` when attached; when
`syncClientDegraded`, sync shares `client`; `attachedClientCount` is 2
not 3; command-client death still tears the session down. Today the only
triple proof never authenticates.

**U3. Busy-pause split.**
Unit-level: with `commandBusy == true` and `syncBusy == false`, the
command monitor skips probes and the sync monitor still counts failures
(or the reverse). 0014 T3’s point was that a fetch must not pause *all*
pings. `connection_health_monitor_test.dart` already takes an `isBusy`
closure — wire the executor’s two probes.

**U4. GitService passes `activityIdle: networkTimeout` on fetch/pull/push.**
Extend the recording executor in `mutations_test.dart` (it already has
the parameter) to assert the duration equals `GitService.networkTimeout`
for those labels, and is null for `status`. A future settings change to
the stall budget otherwise never reaches git.

**U5. Connect-time auth error is loading, not a red pane.**
Provider retry is covered. The widget branch in
`repo_status_view.dart` and `file_view.dart` (`forgeAuthPending &&
looksLikeAuthFailure` → `ProgressCircle`) is not. The withdrawn spinner
test failed on teardown timers, not on the assertion. A PLAN should
dispose the `ProviderContainer` and `pumpWidget(SizedBox.shrink())`
**before** the test ends, or assert via a test-only flag rather than
leaving `ProgressCircle` mounted. Also pump `PaneError` with a stub
`ConnectionState(forgeAuthPending: true)`.

**U6. Dashboard transport stats.**
`dashboard_sheet_test.dart` already pumps an SSH session. Assert the
latency row contains `ssh clients` and `read cap`. Orange-when-`< 3` is
optional if the stub manager reports `attachedClientCount == 0`.

**U7. Sideload `addStream` + `flush`.**
A fake dartssh2 session whose `stdin` records `addStream` / `flush` /
`close` order. 0014 T7 is a three-line change with no regression net.

**U8. Encrypted PEM decode-once.**
`decodeIdentities` with a passphrase-protected key (ssh-keygen `-N`)
must return keys; a second call with the same PEM must not be required
for a second fake client. Skip when `ssh-keygen` is missing, same as
the unencrypted test.

### MEDIUM — after U1–U8

**U9. Live sshd topology** (0014 Phase 10). Only when `/usr/sbin/sshd` is
present: `attachedClientCount == 3`; a short `ExecLane.read` succeeds
while a long `ExecLane.sync` is draining. Do not block the unit tranche
on this.

**U10. `SO_KEEPALIVE` best-effort.** Assert `tcpNoDelay` remains set if
`setRawOption` throws (inject a Socket subclass if needed). Low value
on macOS where the call usually succeeds.

**U11. Stream *and* sync redial.** `streamRedialDelay` is tested; a
redial that actually replaces `_syncClient` after a mid-session drop is
not. Needs a manager-level fake `done` on the sync client only.

**U12. `ActivityCommandExecutor` forwards `activityIdle` and default
descriptors.** Small decorator test; blocks a future “forgot to thread
the new execute() field” bug (already paid once for `activityIdle` on
~42 fakes).

**U13. History / connection-form / forge-sheet widget smoke.** Not
full-panel suites: one pump that the screen builds under a connected
stub, plus one error/empty path. `history_view.dart` is the largest
unmatched panel.

**U14. In-session lost popup.** `app_shell` reconnecting/lost overlay
vs the landing card. `link_status_chip_test` is not that overlay.

**U15. Settings stall-budget string.** One widget or golden-free
`find.textContaining` on the Network field help, so a copy revert cannot
silently restore “command timeout” language.

**U16. Env-cache key misses on username and port.**
`_envKey` is `'${host}|${port}|${username}'` (`app_providers.dart` ~867),
but `connection_env_reset_test.dart` only ever varies the host. Two
profiles on the same host with different usernames (a bastion `root` vs
`deploy`) or a non-22 port would share a cached `RemoteEnvironment` if
the key ever degraded to host-only, and nothing would fail. One test:
connect as `u@mac`, reconnect as `admin@mac`, assert the probe re-ran.

### LOW — polish / do not prioritize

* Per-atom tests for `field_styles`, `sheet_chrome`, `sidebar_branding`.
* Renaming the `'dual-client surface'` test group (docs-only unless a
  PLAN is open).
* Goldens for Dashboard stats (the widget expect in U6 is enough).
* `HostKeyPrompt` value equality.
* Re-executing TEST_COVERAGE_PLAN Phase 2 leftovers that already have
  files (`auth_probe_service_test.dart` exists).

### Out of scope (already decided elsewhere)

* dartssh3, raising the read cap, SFTP, library `keepAliveInterval`
  (0013 / 0014 halt conditions).
* 0006 native title bar live preview.
* `live-forge` mutating tests.
* Product work (GPG signing UI, GH live logs, comment threads).

---

## Pros and Cons of the Options

### A. Ad hoc tests when the next bug lands

* Good, because zero process overhead.
* Bad, because 0014’s activity deadline and triple-client routing can
  regress without a red pane — the last user-visible miss was exactly
  that shape (git/forge auth racing `connected`).
* Bad, because TEST_COVERAGE_PLAN already drifted this way.

### B. Authoritative SSH/UI coverage backlog (chosen)

* Good, because it maps 0014 PLAN acceptance criteria to tests that do
  not yet exist, instead of re-listing files that already have suites.
* Good, because U1–U8 stay inside fakes and loopback sockets; no sshd,
  no forge network.
* Neutral, because some U2/U11 seams need a testable manager fake, not
  just more `expect`s on getters.
* Bad, because without a paired PLAN the list can rot like 0004’s
  residuals.

### C. One widget test per feature file

* Good, because the 56 unmatched names disappear from audits.
* Bad, because most are styling or already covered by chrome contracts;
  the suite would grow by minutes for no SSH/auth race coverage.
* Bad, because `ProgressCircle` teardown already showed that naïve
  widget tests of loading states fight the binding.

### D. Live sshd topology first

* Good, because it is the only way to see three authenticated clients.
* Bad, because the suite skips on machines without sshd; the 0014
  handshake test already proved scheduling without auth.
* Bad, because it does not catch `activityIdle` never being passed.

## Consequences

* Good, because 0014’s “flutter test clean” bar is no longer mistaken
  for “triple-client and activity deadline are behavior-proven.”
* Good, because the connect-time auth UI hole has an explicit widget
  follow-up instead of hoping the provider retry is enough.
* Neutral, because this record is proposed until the maintainer accepts
  it; no tests are added by accepting the MADR.
* Neutral, because the `SSHClient` fake U2/U3/U7 need is smaller than it
  looks. `implements SSHClient` would mean stubbing ~45 public members
  (22 final fields including `socket`, `algorithms` and the handler
  callbacks, 6 getters, and 17 methods — `handlePacket` and the
  `sessionId` setter among them). `extends SSHClient` over a stub
  `SSHSocket` (a 5-member abstract class:
  `stream`/`sink`/`done`/`close`/`destroy`) inherits all of them and
  needs `execute` overridden and little else — dartssh2 3.3.0's
  constructor only calls `SSHTransport(...)`, which listens on the
  socket stream and writes a version banner. It schedules **no** timers,
  so nothing is left pending at teardown.

### Confirmation

* Each HIGH ID is closed when a test **fails if the production branch is
  deleted** (not when a file named like the source exists). U1's local
  half is already closed on that standard; its SSH half is not.
* `flutter analyze` and ordinary `flutter test` stay green. Do not run
  `live-forge`. Do not require sshd for U1–U8.
* A companion PLAN (`0015-PLAN-ssh-engine-and-ui-unit-test-gaps.md`)
  owns file-level steps. It must not invent transport architecture.
* Stale TEST_COVERAGE_PLAN counts are not updated by this MADR; a later
  docs pass may point that file here.

## More Information

* SSH engine product work: [0014-MADR-ssh-engine-next-wave-hardening.md](./0014-MADR-ssh-engine-next-wave-hardening.md),
  [0014-PLAN-ssh-engine-next-wave-hardening.md](./0014-PLAN-ssh-engine-next-wave-hardening.md),
  [ARCHITECTURE_PLAN.md](./ARCHITECTURE_PLAN.md) §0.1.
* Prior UI audits: [0004](./0004-MADR-ui-ux-deep-debug-audit.md),
  [0009](./0009-MADR-ui-ux-debug-pass-backlog.md).
* Historical coverage list (stale counts): [TEST_COVERAGE_PLAN.md](./TEST_COVERAGE_PLAN.md).
* Key production sites: `lib/core/ssh/ssh_client_manager.dart` (triple
  getters ~269–290), `lib/core/ssh/ssh_command_executor.dart` (lane
  routing ~676, `ActivityDeadline` ~781, `addStream` ~793),
  `lib/core/git/git_service.dart` (`activityIdle: networkTimeout`),
  `lib/features/dashboard/dashboard_sheet.dart` (~353–391),
  `lib/features/repository/repo_status_view.dart` and `file_view.dart`
  (pending auth → spinner), `lib/features/forge/forge_widgets.dart`
  (`PaneError`).
