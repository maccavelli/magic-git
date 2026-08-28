# Remote Magic Git — Architecture & Feature-Parity Plan

> Actionable, standards-based plan for turning the current scaffold into a robust,
> comprehensive Flutter/macOS GUI that manages and visualizes **remote** GitLab
> repositories over SSH — driving remote `git` (2.48) and `glab` (1.103) without
> cloning locally.
>
> Status: historical plan + living transport notes. Many items below shipped;
> **§0.1** is the current transport truth (refreshed 2026-07-17). Older sections
> may still say “serialized `_tail`” or “shell probe” — treat §0.1 as
> authoritative. The app's scope has also outgrown this document's title: it now
> speaks **GitHub via `gh`** as a first-class forge alongside GitLab, manages
> **local repos on this Mac** (`LocalCommandExecutor`, sandbox-bookmarked)
> through the same service layer, and opens **native secondary windows** whose
> exec calls relay to the main isolate. The historical sections below are
> GitLab/SSH-only because that's what was being planned at the time.

---

## 0.1 Current SSH transport (authoritative, 2026-08-20)

- **Library:** `dartssh2` **3.3.0** (exact pin). Stay on the `dartssh2`
  package — the `dartssh3` pub package is a stale fork and is not a
  dependency. See `docs/0013-MADR-prefer-dartssh2-v3-over-dartssh3.md`.
- **POSIX remotes only** — no Windows shell dialect; `ShellEscaper` is POSIX-only.
  Every script sent via `sh -c` must additionally be **dash-clean** (Debian-family
  remotes run `sh` as dash): no `read -d ''`, and `set -o pipefail` only via the
  subshell probe `(set -o pipefail) 2>/dev/null && set -o pipefail` — `set` is a
  POSIX special builtin whose failure *aborts* a non-interactive shell.
- **The executor seam:** `abstract class CommandExecutor` with three
  implementations, so every service works unchanged against any backend —
  `SSHCommandExecutor` (remote over dartssh2), `LocalCommandExecutor` (this Mac,
  `Process.start` with native argv/cwd/env — no shell string exists to escape),
  and `ProxyCommandExecutor` (pop-out windows: relays `execute` to the main
  isolate's real executor over the per-window channel, so mutations stay
  globally serialized and telemetry stays unified; payloads cross as `Uint8List`
  because the native codec truncates strings at NUL; a liveness probe abandons
  calls with a readable error if the main window stops answering, instead of
  letting a pane spin forever; `executeStream` is deliberately not proxied —
  watcher ticks are *pushed* to child windows as events).
- **Triple `SSHClient` when possible** (`SSHClientManager`): command client for
  reads / exclusive / isolated / sideload / health pings, stream client for
  `executeStream` (watcher, CI trace), sync client for `ExecLane.sync`
  (`fetch`/`push`) so pack transfer does not share a TCP connection with
  interactive reads. Shared generation pinning so a reconnect never runs work
  against the wrong host: commands pin the generation at enqueue time and
  re-check both the attempt counter and the *attached-client* generation at run
  time (`SSHCommandSuperseded` on mismatch — never retried). The three
  handshakes open **in parallel** (connect pays max(cmd, stream, sync), not
  their sum), with host-key verification **serialized** across them
  (`serializeHostKeyVerifier`) so a TOFU first contact can't double-write the
  store and a changed key can't stack two prompts on the single decision slot.
  Stream and sync each **fail-open** onto the command client rather than
  failing connect, and each is **re-dialed in the background** with backoff
  (15s→120s, 5 consecutive failures then give up for the session). Command-
  client death still tears the session down. Stream death does not close sync,
  and vice versa. OpenSSH `MaxSessions` is per TCP connection (default 10):
  command ≤4 reads + ≤2 isolated; sync 1; stream 1 watcher + 1 CI. Read cap
  stays **4**. See `docs/0014-MADR-ssh-engine-next-wave-hardening.md`.
- **Auth:** password and/or PEM private key (file load or paste). No ssh-agent
  client auth in dartssh2; `agentHandler` is agent *forwarding* only and is not
  used for login. Empty password is never attempted for key-only profiles.
  Library `handshakeTimeout` matches the 15 s socket timeout; auth stays on
  the pausable wrapper so a host-key prompt does not trip it. Peer
  `SSH_MSG_DISCONNECT` is `SSHDisconnectError` on `SSHClient.done` (wrapped
  as `SSHAuthAbortError.reason` if it lands before auth).
- **Host keys:** app-scoped TOFU (`KnownHostsStore`) + mismatch prompt; pausable
  auth timeout while the user decides; a superseding connect resolves an
  orphaned prompt safely (reject) so nothing awaits a completer nobody holds.
- **Dead peer:** `ConnectionHealthMonitor` owns keepalive pings (reply-checked,
  never stacked; 15 s interval, 3 consecutive failures) on **each** attached
  client. Library `keepAliveInterval` is off. Sockets are `NativeSshSocket`
  (`TCP_NODELAY` on, Darwin `SO_KEEPALIVE` best-effort). **Busy-pause is
  split:** command monitor sees non-sync in-flight work; sync monitor sees
  fetch/push; stream monitor sees bytes in the last 30 s. Idle dead-peer
  detection stays ~45–60 s. Unexpected drops record `TransportDropCause`
  (`monitor` / `transportError` / `remoteClosed`) plus optional peer
  `SSHDisconnectError` reason; user disconnect records nothing. Command
  monitor RTTs feed the dashboard sparkline **and** `AdaptiveReadConcurrency`.
  Command `onDead` closes all three clients but leaves `_client` set so the
  drop path can observe `done`. dartssh2's `_rekeyPendingPackets` is still
  unbounded (bypass only IDs 20–49 and ≤ 4); busy-pause remains the
  mitigation.
- **Remote host recommendations:** `ClientAliveInterval` ≤ 60 s with
  `ClientAliveCountMax` ≥ 3 (OpenSSH 10.5 fixed ClientAlive math — do not
  require 10.5). Leave `RekeyLimit` without a time component unless you
  understand idle rekey vs our ping. Do not set a short `ChannelTimeout` on
  `session` if `fswatch` should live. `MaxSessions` 10 is enough for triple-
  client at read cap 4; do not lower it to 1. `PerSourcePenalties`: the
  client pauses auto-reconnect on auth/host-key failure so a laptop is not
  hammered. NAT/LB idle timeouts (AWS NLB 350 s, many corporate firewalls
  60–300 s) are covered by 15 s client probes when the session is idle.
- **Reconnect:** `ConnectionController` watches the command client's `done`
  (normal *or* error completion) → `lost` phase → auto-reconnect with bounded
  backoff (1/2/4/8/15 s, then 15 s repeated), pausing after 20 **retryable**
  attempts (~4 min) or immediately on an allowlist-miss (auth / host-key /
  key-decode — `isRetryableReconnectError`). Every step is guarded by the
  controller's `_attempt` counter, kept in lockstep with the manager's
  generation (`stopReconnect` bumps both and force-closes in-flight
  handshakes). Same-host auto-reconnect reuses the last `RemoteEnvironment`;
  a user `disconnect()` or a different profile invalidates that cache.
- **Scheduling:** `CommandLaneScheduler` — concurrent reads (hard ceiling **4**;
  starts at the no-sample cap **3** until RTT arrives, then RTT-banded by
  `AdaptiveReadConcurrency`: <80 ms→4, 80–200 ms→3, >200 ms→2, with 3-sample
  hysteresis; a `SSHChannelOpenError` drops an error floor, a clean streak
  raises it). One sync (on the sync client when attached), exclusive mutations
  as a FIFO barrier, isolated long-running side work (hooks, sideloads; cap 2)
  exempt from the barrier in both directions. A **watchdog** (command timeout
  + 30 s margin) reclaims the slot of any body that never settles. Network ops
  (`fetch`/`push`, pull's fetch half, and the other `networkTimeout` sites)
  use an **activity deadline**: settings Network seconds is the stall budget
  (default 3 min); a slow transfer that still emits stdout/stderr may run up
  to `max(that, 30 min)`. `--progress` is required on those git invocations so
  a non-TTY executor emits stderr during pack transfer and `ActivityDeadline`
  sees bytes. Pull is `git fetch` (`ExecLane.sync`, `--progress`) then
  `git merge` / `git rebase` (`ExecLane.exclusive`); it is not a single
  `git pull`. `git fetch --all` passes `--jobs=4`; post-commit fetch is
  default-remote (no `--all`). Retries are transient-transport-only
  (allowlist), and each attempt is a separate enqueue with the 400 ms backoff
  taken *between* enqueues, so a retry wait never head-of-line-blocks the
  lane.
- **Compression:** dartssh2 has no transport compression; large git text reads
  *and* forge-CLI JSON reads (`glab`/`gh` GETs) use application `gzip -c -1`
  (absolute path, honored only when discovery found gzip) + an in-band
  `\x01EXIT=n\x01` trailer carrying the real exit code. A missing trailer
  (killed/truncated stream) never reads as success, and a prelude failure
  (e.g. `cd` into a deleted repo) degrades to a clean non-zero exit — Dart's
  gzip decoder tolerates the resulting empty stream.
- **Environment:** one connect-time probe resolves the remote OS and an
  augmented PATH (settings overrides → per-user dirs → OS package-manager dirs →
  the login shell's PATH, captured in the background and killed after ~3 s if a
  shellrc hangs → system dirs; per-user ahead of `/usr/local/bin` is
  load-bearing — a system shim must not shadow the user's real CLI) and
  `command -v`s the whole tool catalog. Encrypted PEM bcrypt runs **once per
  connect, off the UI isolate**; identities are reused by all three clients.
  Compressed stdout larger than 256 KiB is gunzipped off the UI isolate.
  Sideload stdin uses `addStream` + `flush()`. `argv[0]` is rewritten to the
  resolved absolute path; tool versions are probed in a separate background
  pass off the connect critical path. Forge-token env vars are neutralized per
  connection (`unset` prelude over SSH, empty env entries locally) so Magic
  Git's managed identity beats ambient tokens. Same-host auto-reconnect
  reuses this probe result.
- **Streams:** `executeStream` off-queue (they never return; queuing one would
  wedge the lane), generation-guarded at open and re-checked after, bounded by
  an open-timeout; prefers the stream client when dual mode is active. Watcher
  streams (`fswatch`/`inotifywait`, two-stage coalescing) restart via
  `watchLifecycle`: 2 s·n backoff, 3 restarts, then 5 s polling with an
  event-driven recovery retry every 3 min. CI trace and clone streams are
  cancel-driven.
- **Object multi-read:** `git cat-file --batch` one-shot batching
  (`GitService.showBlobsBatch` / `GitCatFileBatch`) for multi-blob revision
  content; worktree files still use `cat` / `readFile`.
- **Telemetry:** `CommandTelemetry` (process-wide, reset per session) — a
  200-sample ring of per-command lane/duration/bytes/wire-bytes plus totals,
  gzip wire savings, channel-open errors (MaxSessions evidence), and open/peak
  stream counts (epoch-guarded so a reconnect can't misattribute a closing
  handle). The dashboard surfaces commands/avg/p95, gzip savings, the keepalive
  latency sparkline, single/dual/triple client count, the adaptive read cap,
  and channel-open errors.
- **Safety:** `exec` so TERM/KILL hit the real process (compressed reads forgo
  `exec` for the trailer shell — acceptable because they're read-only and die
  on SIGPIPE); TERM→KILL escalation with a 400 ms grace; a combined
  stdout+stderr **byte budget** (50 MB, charged pre-decode; compressed reads
  are budgeted post-gunzip so a gzip bomb can't OOM) with the remote process
  *killed* — not just closed — on overrun; sideload upload (exec-channel `cat`,
  generation-pinned, isolated lane) with a timeout that **scales with payload
  size** (`uploadTimeoutFor`: flat default + 64 KiB/s floor).
- **Known gaps:** after a stream-client redial, already-running long-lived
  streams stay on the command client until their next restart (T12); dartssh2
  `_rekeyPendingPackets` is still unbounded (D3); RTT-adaptive ping timeout
  (T9), compression admission (T10), and `waitForExit(timeout:)` (T11) are
  deferred; the login-shell PATH capture mis-parses under fish (D8).

---

## 0. Where the scaffold is today

Already built and hardened (keep these — they are the right foundation):

- `lib/core/ssh/ssh_client_manager.dart` — `dartssh2` wrapper, generation tokens,
  health monitor, `SSHConnectionProfile`.
- `lib/core/ssh/ssh_command_executor.dart` — lane-aware scheduler, gzip, stream
  handles, result type `CommandResult` (`SSHCommandResult` typedef).
- `lib/core/ssh/command_formatter.dart` — env prelude (`GIT_TERMINAL_PROMPT=0`,
  `GIT_EDITOR=true`, `GIT_OPTIONAL_LOCKS=0`) + `cd` + injection-safe arg vector.
- `lib/core/ssh/shell_escaper.dart` — POSIX quoting (the injection defense).
- `lib/core/utils/git_porcelain_parser.dart` — parses porcelain status.

Missing from the *original* plan (many since shipped): glab/GitLab integration,
state management, domain models, real-time watching, full UI.

---

## 1. Guiding principle

**Build a thin, reactive Flutter shell over two remote command primitives, invoked
through the existing serialized SSH executor:**

1. **`git` plumbing** for repo/worktree state (status, refs, log, diff, blame).
2. **`glab api`** for GitLab data (MRs, pipelines, issues, releases, …).

Everything the GUI shows is a projection of structured output (JSON/ndjson/NUL-
delimited records) parsed **off the UI isolate** and pushed into Riverpod
providers. Real-time updates come from a watcher running **on the remote**, not
locally. No local clone, ever.

Two research-refuted cautions shape this:

- ⚠ `git status --porcelain=v1` is **not** guaranteed stable/config-independent
  across versions [R1]. → Migrate the parser to **`--porcelain=v2`** (stable,
  extensible, richer) and validate against the actual remote git 2.48.
- The "always drive plumbing, never parse porcelain" framing was refuted [R2] —
  porcelain formats designed for scripts (`--porcelain=v2`, `-z`) are fine; the
  real rule is "use the machine format + NUL delimiters," which we do.

---

## 2. Layer 1 — SSH transport (extend the existing executor)

### 2.1 One persistent, multiplexed connection

Reuse a single long-lived connection for all git/glab calls. Multiplexing reuses
the completed TCP handshake + key exchange and measurably cuts per-command
connection time — a multiplexed link even beat a non-multiplexed direct one in a
peer-reviewed benchmark [10] (medium confidence on the exact numbers, sound
mechanism).

- `dartssh2` opens multiple `session`/exec channels over one `SSHClient` — hold
  the client open and open a fresh channel per command instead of reconnecting.
- **RESOLVED (source-verified against dartssh2 2.21.1, the caret-resolved version):**
  a **single `SSHClient` is sufficient**. Each `execute()` allocates an
  independent channel + `SSHSession` with its own **2 MB per-channel flow-control
  window**; inbound packets are demultiplexed per-channel with no cross-channel
  serialization, and the socket is never paused — so a long-lived **streaming**
  channel (fswatch, `ci trace`, `log --follow`) coexists with short
  request/response commands **without blocking them**. Rules that follow:
  - Use `execute()` (streaming `SSHSession`) for long-lived processes; **never
    `run()`/`runWithResult()`** for them — those buffer the whole output into an
    unbounded `BytesBuilder` and never complete on an endless stream. `run()` is
    for one-shot commands only.
  - Leave `keepAliveInterval` enabled (default 10 s `ping()`) so hours-long
    channels don't drop.
  - **Watch the remote sshd `MaxSessions` ceiling (OpenSSH default 10).** Opening
    more concurrent channels than that yields `SSHChannelOpenError`. Since we hold
    several long-lived streams *plus* bursty request/response traffic, this is the
    real constraint — **use a second dedicated `SSHClient` split** (one for
    long-lived watchers/traces, one for short commands) *only* if concurrent
    channels approach `MaxSessions`; otherwise one client is correct.
  - One `SSHClient` is a single failure/reconnect domain (transport close destroys
    all channels together) — the split also buys independent reconnect for
    watchers, a secondary reason to consider it at scale.

### 2.2 Two channel classes

| Class | Shape | Executor path |
|---|---|---|
| **Request/response** | run → collect stdout/stderr → exit code | existing serialized `_tail` chain |
| **Streaming** | long-lived stdout stream (NUL/line delimited) | **new** `SSHCommandStreamer` — do **not** put these on the serialized chain (they never return; they'd deadlock it) |

Add an `execStream({repoPath, argv}) → Stream<List<int>>` alongside the existing
`execute()`. Keep serialization only for mutating/index-touching commands.

### 2.3 Safety carried forward

- Keep `ShellEscaper` on every interpolated value.
- Add `GIT_OPTIONAL_LOCKS=0` (or `git --no-optional-locks`) to the env prelude for
  **all read/status refreshes**, so background polling can't corrupt the user's
  concurrent remote git work via `index.lock` contention [8].
- Pipe the GitLab token through **stdin** (`glab auth login --stdin`), once, at
  sign-in — **never** as a positional arg and **never** via env (avoids leaking
  into remote `ps`/shell history, and env vars are readable from
  `/proc/<pid>/environ`). Afterwards glab uses the host's own credential store.
  Ambient forge-token env vars are actively neutralized per connection (§0.1).
  See §4.3.

---

## 3. Layer 2 — Remote git via plumbing

Machine-readable, NUL-delimited, parsed in an isolate. Command catalog:

| View | Command | Notes |
|---|---|---|
| Working-tree status | `git --no-optional-locks status --porcelain=v2 --branch -z` | v2 adds branch/ahead-behind/rename detail [7]. **Migrate the existing v1 parser to v2.** |
| Branches / refs | `git for-each-ref --format=… refs/heads refs/remotes` | one call, all refs + upstream + subject |
| Commit graph / log | `git log --pretty=format:… -z` (+ `--graph` topology or compute lanes client-side) | paginate with `--max-count`/`--skip` |
| Diffs | `git diff --numstat -z` (summary) + `git diff -z <path>` (hunks) | numstat for the file list, full diff on selection |
| Blame | `git blame --porcelain <path>` | porcelain blame is stable & parseable |
| Object content | `git cat-file --batch` / `--batch-check` | **one persistent channel** to stream many blobs without per-object round-trips — big latency win |
| Large repos | enable `core.fsmonitor` (`git-fsmonitor--daemon`) on the remote | lets `git status` return a *summary* instead of scanning disk [9]; complements §5 watching, doesn't replace it |

Latency rule: **prefer one call returning many records over N calls.** Every
command is a network round-trip; batch aggressively (`for-each-ref`, `cat-file
--batch`, `--numstat`).

---

## 4. Layer 3 — GitLab via `glab` (the high-leverage layer)

### 4.1 Primary interface: `glab api`

Drive GitLab data primarily through the generic **`glab api`** command, not a
patchwork of subcommands [1]:

- Hits **REST v4** (`glab api projects/:id/merge_requests`) **and GraphQL**
  (`glab api graphql -f query=…`) [1].
- **Host pin is explicit; CWD is a backstop.** Magic Git always derives the
  origin host from `git remote get-url origin` and passes `GITLAB_HOST` /
  `GITLAB_URI` on `glab` subcommands (`mr`, `issue`, `ci`) and `--hostname`
  on `glab api` / GraphQL (see
  [0019-MADR-pin-glab-origin-host-on-every-call.md](0019-MADR-pin-glab-origin-host-on-every-call.md)).
  CWD auto-resolution remains if a call is unpinned, but repo-scoped
  `GlabService` methods do not rely on it. Stdin login
  (`glab auth login --hostname <host> --stdin`) is unchanged.
- Machine-readable by design: `--output json` (default, pretty array) or
  `--output ndjson` (newline-delimited, memory-efficient, streams line-by-line —
  **prefer for large paginated collections over SSH**) [2].
- `--paginate` walks all pages in one invocation (REST link headers; GraphQL
  cursor with `$endCursor`/`pageInfo`) — no manual page loops [3].
- `--jq` filters JSON **in-process** (embedded Go jq, no external binary) — field-
  select server-side-of-the-SSH-hop to shrink payloads [5].

### 4.2 When to use what

| Need | Use |
|---|---|
| Simple single-resource list (open MRs, my issues) | subcommand + `-F json --jq` [5] — ergonomic |
| **Dashboard / overview** (repo meta + open MRs + pipelines + issue counts) | **one `glab api graphql` query** — request exactly the fields, batch multiple queries into one HTTP request (GraphQL multiplexing) to minimize high-latency SSH round-trips [6] |
| Bulk collection | `glab api … --paginate --output ndjson` [2][3] |
| Mutations (create MR, approve, retry job) | subcommand for ergonomics, or `glab api --method POST`. Note: GraphQL mutations are **not** batched — they run in series [6] |

**Design implication:** model each screen as *one* query where possible. The SSH
hop makes chatty REST expensive; GraphQL field-selection + batching is the
antidote.

### 4.3 Auth model (non-interactive, SSH-friendly)

- glab honors `GITLAB_TOKEN` / `GITLAB_ACCESS_TOKEN` / `OAUTH_TOKEN` env vars,
  which **take precedence over stored credentials** [4].
- **Injection mechanism — IMPLEMENTED (stdin login, leak-free):** the primary
  auth is the **remote's own `glab auth` credential store**. When the user
  supplies a token for a connection, `GlabService.loginWithToken` pipes it **once
  over stdin** to `glab auth login --hostname <host> --stdin` (host resolved from
  the repo's `origin` remote), so it never touches argv, the command string, an
  env prelude, or remote shell history. Every later `glab` call authenticates
  from glab's store — no per-command secret plumbing.
  - The earlier plan considered an **inline `VAR=$X cmd` env prelude** as a
    fallback; that was rejected and removed because the prelude is part of the
    `sh -c '…'` command string and is therefore visible in the remote's
    `ps`/`/proc/<pid>/cmdline` while the command runs. The stdin login has none
    of that exposure.
  - **Never** pass the token as a positional argv. Don't run remote shells with
    `set -x`. Scope the PAT minimally (`api`, `write_repository`). The token is
    stored locally (Keychain, or the 0600 dotfile fallback) only to drive the
    one-time stdin login.
- ⚠ **Version guard:** target is glab 1.103 (canonical names above). glab **2.0.0+
  renames these to `GLAB_`-prefixed** and deprecates the old ones. Abstract env
  injection behind one function so a future remote glab upgrade is a one-line
  change; ideally detect `glab --version` and pick the var set.

### 4.4 Feature surface (from the installed `glab 1.103.0`)

The binary exposes the full GitLab surface — target these in priority tiers:

- **Tier 1 (core parity):** `mr`, `issue`, `ci` (pipelines/jobs/`trace`),
  `repo`, `release`, `label`, `milestone`.
- **Tier 2:** `variable`, `snippet`, `todo`, `search`, `schedule`, `user`,
  `changelog`.
- **Tier 3 (power/experimental):** `container-registry`, `packages`, `cluster`,
  `deploy-key`, `gpg-key`, `ssh-key`, `token`, `stack` (stacked diffs), `duo`.

`ci trace` streams a **live job log** — a natural §2.2 streaming channel + §6
`StreamProvider`.

---

## 5. Layer 4 — Real-time remote state (watch ON the remote)

**Hard architectural constraint from the research:** local kernel watchers
(inotify, kqueue, FSEvents, fanotify) and even an **SSHFS mount cannot observe
remotely-originated changes** — SSHFS is an SFTP client view that doesn't export
remote FS events [R-inotify]. So:

- **Run the watcher on the remote host** where the files are local, and use each
  FS event as a trigger to send a notification back over the SSH channel [11].
- **Recommended watcher: `fswatch`** — OS-native backends (FSEvents/macOS,
  kqueue/BSD, inotify+fanotify/Linux, ReadDirectoryChangesW/Windows) **plus a
  universal stat-polling fallback**, and a NUL-delimited stdout stream built for
  piping: `fswatch -0 <repo> | while read -d "" ev` [12]. Fall back to
  `inotifywait -m` if fswatch isn't installed on the remote.
- Stream those NUL records back over a §2.2 streaming channel.

### Debounce / coalesce (don't hammer the remote) — RESOLVED with concrete values

A single editor save fires 3–5 FS events (write-temp → atomic rename → metadata
flush) within milliseconds; a codegen run can emit hundreds. Two-stage coalescing:

**Stage 1 — coalesce on the remote, before the SSH hop:**
```
fswatch -0 --latency 0.5 --batch-marker \
  --exclude '/\.git/.*\.lock$' --exclude '/\.git/objects/' \
  --exclude '/\.git/logs/' --exclude '/\.git/fsmonitor--daemon/' \
  --exclude '\.sw[nop]$' --exclude '~$' --exclude '/4913$' \
  --exclude '\.goutputstream-' \
  /path/to/worktree
```
`--latency 0.5` (default is 1.0 s; 0.3–0.5 s is a good interactive floor)
groups a burst; `--batch-marker` prints a delimiter per batch so the client acts
once per batch. Fallback: `inotifywait -m -r` wrapped in a settle loop.

**Stage 2 — client side (Dart):** trailing debounce **~150 ms** with a **maxWait
ceiling ~1 s** (so a continuous writer can't starve the timer forever), a **hard
floor of ~1–2 s between actual round-trips**, and **drop intermediate batches** —
you only ever need the latest state. On any inotify `IN_Q_OVERFLOW` signal, force
a **full** status resync rather than trusting the event log.

**What to watch vs ignore inside `.git/`** (git's own daemon ignores *all* of
`.git/`; your status viewer has the opposite need — watch a curated subset):
- **WATCH:** `HEAD` (branch switch), `index` (staging), `refs/**` **and**
  `packed-refs` (a ref can live in either), `MERGE_HEAD`/`CHERRY_PICK_HEAD`
  (in-progress ops).
- **IGNORE:** `*.lock` (created/deleted every operation — a self-trigger storm
  source), `objects/**`, `logs/**`, `fsmonitor--daemon/**`, `FETCH_HEAD`,
  `ORIG_HEAD`, `COMMIT_EDITMSG`/`*_MSG`, `rebase-*/**`, plus editor temps
  (`*.sw[nop]`, `.#*`, `*~`, vim's `4913`, `.goutputstream-*`, `.DS_Store`).
  Note: `.gitignore`/`.gitattributes`/`.gitmodules` are real worktree files — do
  **not** sweep them into the `.git`-internal ignore.

Status command for the poller: `git --no-optional-locks status --porcelain=v2`
(add `-uno` when you can tolerate hiding untracked files — fastest).

### Large-repo status performance — RESOLVED

The external watcher (tells the client *when* to refresh) and git's fsmonitor
(makes each refresh cheap) are **complementary — enable both.** On the remote repo:
```
git config core.fsmonitor true        # O(changed) not O(total) status
git config core.untrackedCache true   # caches the untracked dir walk; ~10x with fsmonitor
git config feature.manyFiles true     # index v4 (smaller/faster) + untrackedCache
git config core.splitIndex true       # optional: cheaper index writes on huge repos
```
- **`fsmonitor.allowRemote` is NOT needed** (verified): the daemon's "remote"
  refusal is a `statfs()` on the worktree checking the *filesystem type*, not
  whether *you* reached the host over SSH. The repo sits on the remote's **local
  disk** and git runs **on that host**, so it reads as local (ext4/xfs/btrfs) →
  allowed. The default `.git`-dir socket location is fine.
- Reported fsmonitor+untracked-cache speedups: Chromium (393K files) 17.6 s →
  0.83 s; 1M-file synthetic 41 s → 0.59 s.
- `--no-optional-locks` matters doubly for the poller: default `status` refreshes
  and *writes back* the index (taking `index.lock`), which can make the user's
  foreground `git add`/`commit` fail; the flag skips that write entirely.

---

## 6. Layer 5 — Dart / Flutter / Riverpod architecture

### 6.1 State management (Riverpod)

- **`StreamProvider`** for every long-lived stream — fswatch events, `ci trace`,
  `log --follow` — it's the Stream analog of `FutureProvider`, purpose-built for
  real-time/continuously-updating data with `AsyncValue` loading/error/data [13].
- **`AsyncNotifier`** for command-driven, mutable state (run command → update →
  optimistic UI → refresh).
- **`family`** providers keyed by `(connectionId, repoPath)`, `pipelineId`,
  `branch`, etc., so multiple repos/pipelines coexist.
- Derive view state from a `connectionProvider`; on disconnect, all families
  invalidate.

### 6.2 Keep the UI thread free

Parse large git/glab output (porcelain status, `log -z`, diffs, ndjson pages)
**off the UI isolate** via `compute()` / `Isolate.run`. The existing
`GitPorcelainParser` should run inside the isolate boundary. ⚠ Exact isolate
plumbing (streaming vs one-shot `compute`) needs a small spike — general guidance
only from the research.

### 6.3 Domain models to add (`lib/core/models/`)

Currently only `GitFileStatus` exists. Add: `Repository`, `Branch`/`Ref`,
`Commit`, `DiffFile`/`DiffHunk`, `RemoteConnection`, and GitLab entities
`MergeRequest`, `Pipeline`, `Job`, `Issue`, `Release`, `Label`, `Milestone`.
Prefer immutable models (freezed/json_serializable) generated from the JSON/GraphQL
shapes so `glab api` output deserializes directly.

### 6.4 Secure credential storage (macOS) — RESOLVED

- **Secrets** (SSH password/passphrase, GitLab PAT) → **`flutter_secure_storage`**,
  which wraps macOS Keychain Services with OS-native encryption. **Non-secret
  metadata** (host, port, username, profile label) → `shared_preferences`
  (already declared), keyed to a stable `secretKey` id. Never put secrets in
  `shared_preferences` — on macOS it's a **plaintext `.plist`**.
- **Required setup (the #1 gotcha):** add the Keychain Sharing entitlement to
  **both** `macos/Runner/DebugProfile.entitlements` **and** `Release.entitlements`,
  alongside the Flutter-default `com.apple.security.app-sandbox`:
  ```xml
  <key>keychain-access-groups</key>
  <array/>   <!-- empty array = no cross-app sharing; this is what you want -->
  ```
  Omit it and writes silently no-op / reads return `null`.
- **Options:** `accessibility: unlocked` (`kSecAttrAccessibleWhenUnlocked`, the
  default — correct for an interactive foreground app); `synchronizable: false`
  (keep SSH/PAT secrets out of iCloud Keychain).
- **Sign with a stable identity** across debug/release/notarized — a changing
  signing cert orphans Keychain items (`-34018 errSecMissingEntitlement`,
  `-25300 errSecItemNotFound`, "works in debug, null when notarized").
- Never write tokens to the remote disk; inject at exec time (§4.3).

### 6.5 UI shell (already `macos_ui`)

Reuse declared deps: `flutter_fancy_tree_view` (repo/file tree),
`pretty_diff_text` + `diff_match_patch` (diff viewer). Structure:
sidebar (connections/repos) → repo workspace (status tree · commit graph · diff)
→ GitLab panels (MRs · pipelines+live trace · issues).

---

## 7. Prior-art / feature-parity benchmark — RESOLVED

A dedicated follow-up pass produced a cited feature matrix and hard evidence on
CLI-vs-API pitfalls.

**Comprehensive parity = general-git-GUI table stakes + GitLab-API features.** The
Tier list in §4.4 maps onto what established clients ship:
- **Tier 1 (table stakes, every serious client):** commit graph, hunk/line
  staging, side-by-side diff, branch/push/pull/fetch, stash, 3-way conflict
  resolution, blame — **plus** current-branch MR + pipeline status (the GitLab
  Workflow "For current branch" pattern).
- **Tier 2 (differentiators):** interactive rebase (drag-drop — a gap in Sublime
  Merge, so genuine differentiation), cherry-pick, deep undo/redo (Tower/GitKraken's
  signature), submodules, **and the API-backed set that makes it a *GitLab* client
  rather than a generic git GUI:** inline MR review (create/resolve discussion
  threads, comment on diffs, approve), pipeline controls (job logs, retry/cancel,
  artifacts), issue browse/create/link.
- **Tier 3 (power):** worktrees (Sublime lacks a UI — opportunity), reflog view +
  restore (Tower-class safety), Git LFS, and thin API panels (releases, labels,
  milestones, CI/CD variables, snippets, schedules, incidents, semantic search,
  to-do).

Reference scopes: GitLab's official **GitLab Workflow** VS Code extension is the
full API-backed target (MR review + pipelines + issues); **GitLens is NOT a
GitLab review/CI client** (only lightweight, largely Pro-gated context
enrichment) — don't benchmark GitLab features against it.

**CLI-vs-API pitfalls (evidence-backed) → confirms the §4 "prefer `glab api`"
call:**
- **Human CLI text is not a stable contract.** git itself maintains two surfaces
  (default porcelain "subject to change" vs `--porcelain` "stable across versions
  and regardless of config"); `gh` switches to tab-delimited when piped; glab
  policy permits output breaks across major versions. → parse plumbing/`--porcelain`
  and `glab api` JSON, never human output.
- **Exit codes are the weakest link** — three confirmed bugs where the code
  disagreed with reality, incl. **`glab auth status` returning exit 0 on a 401**
  (glab #911) and a real incident where a 5 s `gh auth status` *timeout* was
  misclassified as "auth expired." A subprocess gives only an unreliable exit code
  + unstable stderr; REST/GraphQL give a numeric HTTP status (401 vs 404 vs
  5xx/timeout) + structured JSON error, cleanly separating no-results / auth-fail /
  network-error. When you *must* call a subcommand, request long-form
  `--output json` (glab's short flags are inconsistent: `-F` means `--field` under
  `glab api` but `--output-format` under `glab issue list`) and treat exit codes
  as advisory — default ambiguous cases to failure, never guess "auth expired."
- **Rate limits:** gitlab.com allows **2,000 req/min per authenticated user**;
  `--paginate` *multiplies* requests against that budget. Read `RateLimit-*` /
  `Retry-After` headers (`glab api -i`); use **keyset pagination / GraphQL
  cursors** for large lists and `--output ndjson` to stream. GraphQL collapses
  N+1 (MR + pipeline + discussions in one query) — doubly valuable when each
  round-trip is also an SSH hop.
- **Why wrap the CLI anyway:** `glab` inherits the remote host's stored
  credentials + host/enterprise-endpoint resolution for free (zero token plumbing
  in the Flutter app) — the exact reason this design SSHes in and shells out
  rather than opening its own HTTPS client. The cost (external-binary dependency +
  version/output drift) is mitigated by JSON contracts, GraphQL batching, and
  connection multiplexing.

---

## 8. Phased roadmap

1. **Transport spike (do first).** Validate `dartssh2` concurrent + streaming
   channels (§2.1); add `execStream`; add multiplexed persistent connection;
   add `GIT_OPTIONAL_LOCKS=0` to the prelude. ✅
2. **Read-only git core.** Migrate parser to `--porcelain=v2`; wire status +
   `for-each-ref` + `log` into Riverpod providers with isolate parsing; build
   the status tree + commit list + diff viewer. ✅
3. **Real-time.** Remote `fswatch -0` streaming channel → debounce → status
   refresh via `StreamProvider`. ✅
4. **GitLab read.** `glab api` service; MR/pipeline/jobs panels; live `ci trace`
   stream. ✅ (The GraphQL dashboard query shipped —
   `GlabService.projectDashboard`. The `GITLAB_TOKEN` injection helper was
   deliberately never built: tokens go over stdin at sign-in instead, and
   ambient token env vars are neutralized.)
5. **Mutations.** Stage/unstage/discard/commit; branch create/checkout/delete;
   fetch/pull/push; stash push/pop/apply/drop; MR create/approve/merge; pipeline
   retry — with confirm dialogs on outward actions + refresh. ✅
6. **Secure storage + polish.** `flutter_secure_storage` profiles + Keychain
   entitlements ✅; commit-graph DAG + ref decorations ✅.

### Implementation status (as of 2026-07-17)

**Done & tested (229 test files / ~1,860 tests, analyze-clean under strict
casts/inference/raw-types):** SSH transport as described in §0.1; porcelain v2
status + isolate parsing; remote `fswatch`/`inotifywait` watcher with the tuned
coalescer (local backend uses `Directory.watch` into the same pipeline);
multi-lane commit graph + branch/tag decorations; file & commit diffs; blame;
branches/remotes/stashes panes; git mutations (stage/unstage/discard/commit/
checkout/branch±/fetch/pull/push/stash±); conflict resolution (ours/theirs/
abort with a marker-shaded viewer); interactive rebase (reorder/squash/fixup/
drop); recovery/reflog tools + undo journal; **GitLab** MR list + create/
approve/merge, pipelines + retry, jobs + live trace; **GitHub** as a peer forge
via `gh` (PRs, workflow runs/jobs, checks); forge-neutral **Project tab**
(issues create/view, labels, milestones view-only, paginated) over a shared
GraphQL dashboard query per forge — the §4.2 "one query per screen" design is
built, not deferred; **create-repo wiring** on both forges with injected
credential helpers; **Worktrees tab** (add/move/remove/prune, per-worktree
workspace reusing the status/history/branches/stash views, sandbox grant
management); **local backend** ("This Mac": `Process.start`, security-scoped
bookmarks, Keychain with a 0600 dotfile fallback for unsigned builds);
**multi-window** (native pop-outs on a second `FlutterEngine`, exec relayed to
the main isolate — §0.1); session **dashboard** (command telemetry, gzip
savings, keepalive latency, dual/single client); **guided install** with
air-gapped sideload; per-repo `core.fsmonitor` toggle (default off).

**Deferred (not yet built):** a submodules management UI (submodules are
*recognized* — opening one explains that its git data lives in the parent —
but not managed); the §0.1 "known gaps" list. Interactive rebase deliberately
omits **reword**: the headless `GIT_EDITOR=true` invocation would silently
no-op the prompt, so the action was removed from the enum rather than left
reachable-but-broken.

**Live verification:** `integration`-tagged tests run real git against temp
repos in every `flutter test` run; the `live-forge`-tagged suites (skipped by
default — they create/delete real projects) exercise the create-repo and
issue wiring against real GitHub/GitLab when run explicitly. See
`dart_test.yaml` and CLAUDE.md.

---

## 9. Resolved decisions (formerly open questions)

All four blocking questions are now resolved (source-verified / cited); details in
the referenced sections.

1. **dartssh2 concurrency (§2.1).** ✅ A single `SSHClient` handles concurrent
   streaming + request/response channels without blocking (verified against
   dartssh2 2.21.1 source — independent 2 MB per-channel windows). Use `execute()`
   not `run()` for streams; keep keepalive on. Only split to a second `SSHClient`
   if concurrent channels approach remote sshd `MaxSessions` (default 10) or you
   want independent reconnect for watchers. **No ControlMaster equivalent** —
   "persistence" is just holding one client open.
2. **Feature parity + CLI-vs-API (§7).** ✅ Tiered feature matrix defined against
   GitKraken/Tower/Sublime Merge + GitLab Workflow. Evidence confirms
   `glab api`/JSON over subcommand-scraping (unstable text, exit-code bugs like
   glab #911 exit-0-on-401); GraphQL batching + rate-limit header handling +
   keyset/ndjson pagination specified.
3. **macOS Keychain + token injection (§6.4 / §4.3).** ✅ `flutter_secure_storage`
   (Keychain) for secrets, `shared_preferences` for metadata; `keychain-access-groups`
   entitlement in **both** entitlement files; stable signing identity. Inject the
   PAT via **stdin** (`glab auth login --stdin`) — never argv, and never env
   (the inline `VAR=$X cmd` fallback sketched here was not built; ambient forge
   token vars are neutralized instead); don't rely on `AcceptEnv`.
4. **Debounce + fsmonitor (§5).** ✅ Two-stage coalescing: remote
   `fswatch -0 --latency 0.5 --batch-marker` + curated `.git` ignore set; client
   trailing debounce ~150 ms / maxWait ~1 s / hard floor 1–2 s / drop
   intermediates / full resync on overflow. Enable `core.fsmonitor` +
   `core.untrackedCache` + `feature.manyFiles` on the remote repo;
   `fsmonitor.allowRemote` **not** needed (repo is on the remote's local disk).
   External watcher and fsmonitor are complementary.

Remaining lower-priority validations — since settled in the build: isolate
parsing landed as one-shot `compute`-style parses of complete command output
(streams are line/NUL-delimited and cheap to parse inline); MR/PR *approve* is
in-editor; GraphQL rate-limit behavior has not been hit in practice (single-user
desktop traffic sits far under the 2,000 req/min budget).

---

## Sources

Verified primary/strong (3-0 unless noted):

- [1] `glab api` REST+GraphQL passthrough, host/auth auto-resolution — https://docs.gitlab.com/cli/api/ ; https://gitlab.com/gitlab-org/cli/-/tree/main/docs/source/api
- [2] `--output json|ndjson` machine-readable — https://docs.gitlab.com/cli/api/
- [3] `--paginate` (REST + GraphQL cursor) — https://docs.gitlab.com/cli/api/
- [4] Non-interactive auth via `GITLAB_TOKEN`/`GITLAB_ACCESS_TOKEN`/`OAUTH_TOKEN` (precede stored creds) — https://docs.gitlab.com/cli/auth/login/
- [5] Subcommand `-F json` + in-process `--jq` — https://docs.gitlab.com/cli/mr/list/
- [6] GraphQL field-selection + query batching/multiplexing — https://docs.gitlab.com/api/graphql/
- [7] `git status --porcelain=v2` richer/extensible — https://git-scm.com/docs/git-status
- [8] `--no-optional-locks` avoids index.lock contention — https://git-scm.com/docs/git-status
- [9] `git-fsmonitor--daemon` fast large-repo status — https://git-scm.com/docs/git-fsmonitor--daemon
- [10] SSH multiplexing cuts connection time (medium conf., 2-1) — ICDT 2021, https://www.thinkmind.org/articles/icdt_2021_1_50_18005.pdf
- [11] Watch on the remote; FS event triggers command over SSH — ICDT 2021 (same)
- [12] `fswatch` cross-platform backends + NUL-delimited stream — https://github.com/emcrisostomo/fswatch
- [13] Riverpod `StreamProvider` for real-time data — https://docs-v2.riverpod.dev/docs/providers/stream_provider
- [R-inotify] Local watchers + SSHFS cannot see remote FS events — ICDT 2021 (same)
- [fetch-8] One save → 4–12 FS events / ~20 ms (debounce rationale) — file-watcher debounce/coalesce analysis

Refuted (do **not** rely on):

- [R1] `--porcelain=v1` guaranteed stable/config-independent — **refuted 1-2**. Use v2, validate on git 2.48.
- [R2] "always drive plumbing, never parse porcelain" — **refuted 1-2**. Machine porcelain (v2, `-z`) is fine.

Under-evidenced / needs spike: dartssh2 channel-multiplexing behavior; macOS
Keychain via flutter_secure_storage; isolate/compute parsing specifics; prior-art
feature-parity benchmark (§7).
