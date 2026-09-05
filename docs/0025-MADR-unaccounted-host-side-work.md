---
status: "accepted"
date: 2026-09-04
decision-makers: [Maintainer]
consulted: []
informed: [Magic Git contributors]
verified: 2026-09-04
---

# Bound the host process economy: leaked watchers, refresh amplification, and a process-per-command stack

## Context and Problem Statement

Magic Git's whole design is that the user never sees the host. Every git
invocation, every watcher, every forge call runs over there, and the app is the
only thing that knows any of it happened. That is the point of the product —
and it means the app is solely responsible for accounting for what it starts.

Two measurements taken on 2026-09-04, against the real host this app runs
against (`admdevops`) rather than a fixture, show that it does not:

* **It leaves processes behind.** Nineteen `inotifywait` processes were found
  orphaned to init, the oldest running for **16.9 days**, four of them
  predating a version of the app — they survived an upgrade. Nothing in the
  app knew they existed, and nothing would ever have reclaimed them.
* **It does far more work than it believes.** One one-file commit+push spawned
  **123 git processes**. [0023](0023-MADR-commit-and-push-perceived-freeze.md)
  reasoned throughout against a baseline of **≈22–40**. The four commands that
  make up the post-mutation refresh appear **fifteen times over**, not once.

These are different defects with different fixes, and this record does not
pretend otherwise. They are filed together because they are the same *class*:
work the app causes on the host and then loses track of. Neither was visible
from the source, from a unit test, or from a loopback fixture. Both required
looking at the machine — and both had been reasoned about incorrectly from the
code alone, in records that shipped.

## How this was measured

Stated because the method mattered more than usual here, and because two
earlier attempts produced numbers that were wrong.

**Finding A** — enumerated by reading `/proc/<pid>/comm` and
`/proc/<pid>/status` directly, on the live host.

> An earlier pass used `ps -u "$USER" -C inotifywait` and reported *22 orphaned
> / 18 parented / 7 old-format*. Those figures were wrong and are retracted:
> `ps` **ORs** its selectors rather than ANDing them, so it returned every
> process owned by the user regardless of command. The tell was a dry run
> reporting an identical orphan count for `fswatch`, `git`, `gh`, `glab` *and*
> `sleep`. The dry run is why nothing was signalled on bad data.

**Finding B** — measured with git's own `trace2.eventTarget`, which emits one
structured event per git process. Exact, not sampled.

> An earlier attempt sampled `/proc` in a tight loop. A control — seventeen
> known `git` invocations — was detected as **one**. Git commands complete in
> 1–5 ms, faster than a `/proc` scan can cycle. The sampler was discarded
> rather than used, and no number from it appears anywhere.
>
> `trace2.*` is read **only** from system and global config; repository-local
> config and `-c` are ignored by design, because trace2 initialises before repo
> discovery. A per-repo attempt logged nothing, which its control caught.

Every instrument here was checked against a known input before its output was
believed. That is not ceremony: three of the four instruments tried were
broken, and two of them failed *silently*, returning zero rather than an error.

## Relationship to earlier records

* **Finding A is [0022](0022-MADR-git-gh-glab-engine-debug-audit.md)'s M5,
  confirmed.** 0022 recorded it as "suspicion, not reproduced", requiring a
  live host. It then guessed the mechanism — that OpenSSH ignores the RFC 4254
  `signal` request — and that guess is **false**: sshd honours it (OpenSSH
  ≥ 7.9), and a loopback test proves the clean teardown path works. The
  suspicion was right and its stated cause was wrong, which is why it took a
  real host to settle. During execution of 0024 it was briefly marked
  *refuted* on the strength of that loopback test alone; that was corrected the
  same day.
* **Finding B contradicts a premise of
  [0023](0023-MADR-commit-and-push-perceived-freeze.md).** It does not undo
  0023: the modal is gone, the sheet closes on the commit, and the reported
  symptom is fixed. But 0023's Phase 3 reasoned about "four full-set fan-outs
  (≈22–40 git processes)" and the real figure is 123. Its open item **B9** (the
  Review-mode forge call on the post-commit path) is directly implicated.
* Finding B's leading mechanism is an asymmetry introduced by
  [0012](0012-MADR-commit-composer-focused-sheet.md)'s focused commit sheet and
  carried through 0023.

## Scope

In scope: the lifetime of host-side processes the app starts, the volume of
commands one user gesture causes, and — added 2026-09-04 — the **process
economy** as a whole: how many long-lived processes a connection should hold,
what enforces that, and where the concurrency primitives (host processes, SSH
channels, Dart isolates) are each accounted for. See *Extended scope* below.

Out of scope: transport correctness (0024 closed that), the perceived-freeze
work (0023 shipped it), anything requiring a change to how the forge CLIs
themselves behave, and any redesign of the Riverpod provider graph — the
proposals here change *what is asked for and how often*, not how the app is
wired.

## Decision Drivers

* **The user cannot see the host.** A leak they cannot observe and an
  amplification they cannot count are both, from where they sit, "the app got
  slow" or "the watcher stopped working" — with nothing to chase. This is the
  same silent-degradation class 0024 H3 was about.
* **Neither defect self-heals.** The orphan count only rises. The refresh
  volume is paid on every commit.
* **Both were wrong in the record before they were measured.** That is the
  strongest argument for holding the remediation to live confirmation rather
  than to a passing unit test.
* **Fix causes, not symptoms** (`AGENTS.md`). For A in particular, the entire
  teardown path is already correct; a fix that touches it would be fixing the
  half that works.
* **A ceiling that is not enforced is not a ceiling.** 0024 M2 found the
  `MaxSessions` budget existed only as a comment, and that the comment had
  forgotten streams. Host processes today have no budget at all, in any form.
* **Prefer what is already in the tree.** Three of the proposals below are
  extensions of patterns this codebase already contains — `setFsmonitorMany`'s
  bundled `sh -c`, `GitCatFileBatch`'s fail-open batching, and
  `highlight_worker.dart`'s long-lived isolate. That is a much shorter path
  than importing an architecture.

## Considered Options

* **Option A — one record covering both, remediated in a paired PLAN.**
  Matches the house form (0022, 0024 are both multi-finding backlogs) and
  keeps `docs/README.md` legible.
* **Option B — two records, one per finding.** Cleaner by the "one decision per
  MADR" rule, since the two share no fix. Costs a second record for a backlog
  that will be executed as one piece of work.
* **Option C — reopen 0022 and amend 0023 in place.** Keeps each finding beside
  its origin, and buries two live defects inside records both already marked
  `accepted`/`executed`, where nobody looks for open work.
* **Option D — fix A now, defer B.** A is understood and bounded; B is not
  diagnosed. Tempting, and it strands the larger number.

## Decision Outcome

Chosen option: **"Option A — one record, remediated in a paired PLAN"**, at the
maintainer's direction and consistent with how 0022 and 0024 are structured.
The two findings share a root property — *the app causes work on the host that
it does not account for* — and that framing is what makes the remediation
coherent even though the two fixes are unrelated.

Adopted with it:

1. **Finding A is fixed host-side or not at all.** Every teardown-path
   mechanism is already working; the leak occurs precisely when there is no
   channel left to act through. A fix must make the remote process
   self-sufficient, or sweep for it after the fact.
2. **Finding B is not remediated until it is attributed.** The 123 is measured;
   *what causes it* is one grounded hypothesis and one open question. Changing
   refresh behaviour on a hypothesis is how a fan-out becomes a stale pane.
3. **Both confirmations are live-host.** Neither may be closed on a unit test.
4. **Every long-lived host process gets a named ceiling, enforced by a counter
   and asserted by a test** — the treatment 0024 M2 gave SSH channels. A budget
   that lives only in a comment is how this record's two findings both escaped
   notice.
5. **Reduce demand before adding machinery.** F1/F2/F3 remove work; D1/D3 make
   the remaining work cheaper. The former are smaller, are testable without a
   host, and make the latter's payoff easier to measure — so they go first.
   *(Borne out further than intended: putting demand-reduction first is what
   established that D3 had no demand to reduce — see amendment D3.1 — and that
   F1 and C2 rested on witnesses that do not exist. Three of the nine findings
   were withdrawn on evidence gathered by doing the cheap ones first.)*

No code changes accompanied this record as written. Implementation is tracked
in `0025-PLAN-unaccounted-host-side-work.md`, which carries the execution
record, the per-phase evidence, and every deviation. As of 2026-09-04 phases
1-5, 7 and 9 have shipped; C2, D2, D3 and F1 are settled without code (see
their amendments).

### Consequences

* Good, because A's fix space is now genuinely narrow: four of five candidate
  paths were eliminated by measurement, not by argument.
* Good, because B arrives with a reusable, exact instrument (`trace2`) and a
  named first suspect in the code, rather than as an impression that commits
  feel heavy.
* Bad, because B's remediation cannot be scoped until attribution work is done,
  so this record cannot say what it will cost.
* Bad, because A's most robust fix (host-side self-termination) changes the
  watcher arming contract, which 0022 H5 and 0024 A1/H3 all touch — a busy
  seam.
* Neutral, because nothing here changes a persisted format or a public API.

## Findings

### A — Watcher processes leak whenever the channel dies without a clean close

**Evidence: measured on the live host.**

```
orphaned (PPid=1): 19     parented: 0
oldest orphan:     16.9 days
4 of 19 carry the pre---exclude command line (predating an app upgrade)
inotify instances: 29 -> 9 after cleanup (the orphans held 20)
```

Each was individually verified as `comm=inotifywait`, owned by the connecting
uid, `PPid=1` before being counted or signalled.

**What is *not* broken.** Four candidate paths were eliminated by direct
observation, which is what makes the remaining one actionable:

| path | leaks? | how established |
|---|---|---|
| explicit stream cancel | no | loopback sshd: process dies inside the 400 ms `killGrace` |
| command timeout | no | loopback sshd, same teardown path |
| clean app quit | no | orphan count held at 0 across a real quit → rebuild → restart |
| re-arm (0022 H5) | no | none observed across a session |
| **channel lost without a clean close** | **yes** | 19 orphans accumulated over ~17 days |

A mechanism probe isolating the two halves of `killAndCloseSession`
(`ssh_command_executor.dart`) recorded `died from signal=true, died after
close=true` on OpenSSH 10.3p1 — so the signal request *is* honoured, and
channel close is an independent second kill. Both halves work.

**Mechanism.** The leak is the absence of either. When the stream client's TCP
dies without a clean close — a NAT/firewall idle-drop, which
`ssh_client_manager.dart` explicitly documents as the fate the *idle-by-design*
stream connection is most exposed to, plus laptop sleep, VPN drop, crash, or
force-quit — there is no channel left to carry TERM, and sshd's session
teardown never runs. The child reparents to init. The redial then arms a
**new** watcher beside the old one, which is why the count grows rather than
churns.

This is exactly what 0022's own text named and never closed: *"There is no
trap, no PID file, no reconnect-time sweep."*

**Consequence.** Monotonic accumulation bounded by
`fs.inotify.max_user_instances` (1024 on this host). Past that no watcher can
arm at all and every repo silently falls back to polling — invisible, and
indistinguishable from the app simply being stale. At 29 instances after weeks
of use this was not urgent; it also never stops.

**Resolution candidates** (none chosen; the plan picks one):

1. **Host-side self-termination.** Arm the watcher so it dies on its own when
   nobody is reading it — `inotifywait --timeout` on a heartbeat loop, or a
   wrapper that exits when its stdout closes. Most robust: it needs nothing
   from the client, which is precisely what is missing at the moment of
   failure. Touches the arming contract (`bounded_watch.dart`,
   `remote_watch_service.dart`), a seam 0022 H5 and 0024 A1/H3 all sit on.
2. **Reconnect-time sweep.** Write a PID file per arm; on connect, kill any
   PID recorded for this repo that is still alive and not ours. Small and
   contained, but it only cleans up *after* the next connect, and needs care
   not to kill a second live session's watcher.
3. **Process-group supervision.** Arm under `setsid` with a supervisor holding
   the channel. Most machinery for the least additional guarantee.

**Confirmation.** Orphan count read from `/proc` on the real host after a week
of ordinary use, including at least one sleep/VPN-drop cycle. Must be **0**.
A unit test cannot establish this — the failure requires a real dropped TCP.

### B — One commit+push causes 123 git processes, against a believed ≈22–40

> **Superseded as a current figure — re-measured 2026-09-04.** The 123 below is
> the pre-remediation baseline and stands as the record of what was found. After
> phases 1-5, 7 and 9 the same gesture costs **76** processes, and a connected
> idle app costs **0** (see the success table and **C4**). The paragraphs below
> are not updated in place, so that the baseline this record argued from stays
> legible.

**Evidence: measured with `trace2`, exact.** One one-file commit+push in the
running `.app`, on a real repo:

| count | command |
|---:|---|
| 22 | `rev-parse --git-dir` |
| 15 | `--no-optional-locks status --porcelain=v2 …` |
| 15 | `for-each-ref --format=… refs/heads` |
| 15 | `remote` |
| 9 | `branch --merged --format=…` |
| 6 | `remote -v` |
| 6 | `config --get-regexp ^remote\..*\.glab-resolved…` |
| 4 | `log --topo-order` · 4 `check-ignore -z --stdin` |
| 1 each | `add -A`, `commit --no-gpg-sign`, `push --progress --follow-tags`, `maintenance run --auto`, assorted `diff`/`ls-files`/`rev-parse` |

**What is attributable, and what is not.** Said explicitly, because the total
is the least useful number here:

* **Attributable to the app.** `status --porcelain=v2 -uall --branch -z`,
  `for-each-ref … refs/heads`, bare `remote`, and `branch --merged` match
  `git_service.dart` call sites exactly. The first three are the post-mutation
  refresh triple, and they fired **fifteen times**.
* **Attributable to `glab`.** The `glab-resolved` config reads and `remote -v`
  (6 each) are the forge CLI resolving its repo — 0023's open **B9**.
* **Not attributable.** The bare `rev-parse --git-dir` ×22 has **no call site
  in `lib/`**. The app's own layout probe is a different, longer command —
  `rev-parse --path-format=absolute --show-toplevel --git-dir --git-common-dir`
  (two call sites, `git_service.dart:1290` and `:1455`, both the same shape) —
  and that one appears exactly *once* in the trace. So the 22 come from `glab`
  or from git internals; the trace carried no usable `cwd` or ppid to settle
  which, and it is not guessed at here.
* **Git's own children.** `remote-https`, `send-pack`, `pack-objects`,
  `maintenance run --auto` — roughly seven — are not app commands. Removing
  them still leaves ~116.

**No timing is claimed.** This git build emitted no usable `t_abs`, so the
per-phase split and wall-clock duration could not be recovered. Whether the
workspace stays interactive during the push was not assessed either. Both
remain open.

**Leading mechanism, grounded but not yet proven to account for the
magnitude.** There are two commit surfaces and they suppress their own watcher
echo differently:

* `repo_status_view.dart` (the inline composer) wraps its mutations in
  `withOwnMutation` — **four call sites**. That *brackets* the operation:
  `begin()` before, `end()` after, so suppression covers the whole duration,
  including the index and ref writes the mutation makes while it runs.
* `commit_dialog.dart` (the focused sheet from 0012, and the primary path after
  0023) contains **zero** `withOwnMutation` calls. It commits through a raw
  `git.commit(...)` and relies on `refreshAfterMutation`, which only
  `mark()`s **after the fact**.

A point-in-time stamp cannot suppress an echo that already arrived. `git add
-A` writes the index, `git commit` writes index, refs and logs, `git push`
moves refs — every one of those is a watcher event generated *during* the
gesture, before the mark exists. Each surviving event triggers a refresh wave,
and each wave is the triple above. Fifteen waves is the shape that predicts.

This is a fact about the code, and a hypothesis about the magnitude. It is not
established that it accounts for all fifteen.

**Open question the measurement raises independently.** During instrument
validation, a *single* index write produced **two** four-command bursts, not
one. If one filesystem event costs two refresh waves, that is a second
multiplier sitting underneath this one, and it is unexplained.

**Resolution candidates** (attribution first, then a fix):

1. **Attribute before changing anything.** Re-run the `trace2` capture with
   per-command correlation (the app already mints an `OperationId`;
   `CommandTelemetry` already records every sample) so each of the 123 is tied
   to the provider that asked for it. Nothing should be changed until the
   fifteen waves have names.
2. **Give the focused sheet the same bracketing** the inline composer has —
   the smallest change consistent with the evidence, and correct regardless of
   whether it explains the whole magnitude.
3. **Decide B9.** The forge call on the post-commit path is 12 of the 123 by
   itself, and 0023 deliberately left it to the maintainer.

**Confirmation.** The same `trace2` capture, same gesture, same repo. A fix
that does not move the number down has not worked, regardless of what a unit
test says.


---

# Extended scope, 2026-09-04: process economy

Added at the maintainer's direction. The two findings above are symptoms of a
structural question this record now also has to answer: **how many host
processes should one repository cost, and what keeps that number bounded?**

Today, measured rather than estimated: one commit+push costs **123 git
processes**, and a session accumulates orphaned watchers indefinitely. The
target is a small, *named*, monitored set of long-lived processes with hard
ceilings — not a smaller number of short-lived ones.

## Prior art

Researched because every problem here is solved somewhere, and two of the
solutions are already half-present in this codebase.

### Git already ships the daemon we are duplicating

`git fsmonitor--daemon` is a built-in filesystem monitor: **one long-lived
daemon per working directory**, using inotify on Linux, which git commands
query over a **Unix domain socket** instead of scanning the disk. It exists
precisely so `git status` need not walk the tree, and it requires no
third-party tools.

**This app already turns it on.** `_applyFsmonitorTuning`
(`app_providers.dart:1606`) calls `setFsmonitorMany(paths, enabled: true)`
(`git_service.dart:2319`) at connect, and the host confirms it:

```
systems-workspace:  core.fsmonitor=true
lkq-apache-spark:   core.fsmonitor=true
```

So for every repo the app opens, there are **two independent inotify watch
trees over the same working directory**: git's daemon, and the app's own
`inotifywait -m -r`. The app pays twice for the same information, and only one
of the two leaks. `bounded_watch.dart` and `remote_watch_service.dart` even
exclude `.git/fsmonitor--daemon/` from their own watch — the app is filtering
out the noise of the daemon it started.

### A single host-side server is the standard answer

VS Code's remote architecture runs **one long-lived server process on the
host** which owns sessions and remains active across many client connections,
speaking JSON-RPC over a single transport, rather than spawning per command.
The 2026 Agent Host work generalised this further: a dedicated host process
that outlives the editor connected to it.

That is the shape this app does not have. Every `execute()` opens a channel,
forks `sh`, `exec`s one command, and tears the whole thing down.

### The per-command round trip is the known cost

Published measurements for OpenSSH connection reuse put a fresh handshake at
roughly **300–500 ms through a bastion at ~100 ms RTT**, against **~8 ms** for
a reused session, with automation that opens a connection per task cited as
where multiplexing recovers most of its wall clock. Magic Git already keeps
its TCP connections alive, so it does not pay the handshake — but
[0024 P2](0024-MADR-ssh-and-remote-repo-engine-debug-audit.md) measured the
analogous per-**channel** cost from the dartssh2 source: `CHANNEL_OPEN` +
confirmation, then `exec` with `wantReply`, i.e. **two round trips before the
command starts**, every time.

At 123 processes, that is 246 round trips of pure protocol for one commit.

*(Re-measured 2026-09-04: the gesture is now 76 processes from ≈42 app-level
`execute()` calls — the snapshot's three gits are siblings under one `sh -c`, so
processes overcount commands. ≈84 round trips, ≈3.7 s at the measured 51 ms RTT,
and ≈1-2 s of wall clock once the read lane's 4-way concurrency is applied. That
smaller figure, not the 246 above, is what D1's approval turns on.)*

### The watcher leak is a documented upstream limitation

`inotifywait` blocks in `select()` on its inotify fd. On a quiet repository it
never returns, never writes to stdout, and therefore **never discovers that the
reader of its pipe is gone** — there is no `SIGPIPE` without a write. The
inotify-tools project discusses exactly this: a watcher that can no longer
receive events "will never know that it should exit."

0022's M5 text guessed at this (*"cleanup rests on channel close causing SIGPIPE
at the watcher's next write, which on a quiet repo may be far away or never"*)
and was right about the consequence while wrong about the signal path. It is an
upstream property of the tool, not a defect in this app's teardown — which is
why no teardown fix can address it, and why `-t/--timeout` is the documented
lever.

### Linux gives a primitive for exactly this

`prctl(PR_SET_PDEATHSIG)` delivers a signal to a child when its parent dies,
and `PR_SET_CHILD_SUBREAPER` stops orphans reparenting to init. Both are
per-process Linux calls, not shell features, so reaching them from an arming
script means a wrapper — but they bound the problem at the kernel rather than
by convention.

### Dart's own guidance argues against what the client does

Flutter's concurrency documentation is explicit that `Isolate.run` **spawns and
tears down an isolate per call**, that this carries real overhead, and that
repeated identical work should use a long-lived `Isolate.spawn` worker with
ports instead. Each isolate costs its own heap and an OS thread. This app has **13 `Isolate.run` call sites** — status and refs parsing, log,
file history, reflog, blame, NUL-path splitting, gunzip offload, key decode,
forge JSON, diff parsing, the commit graph — each spawning and tearing down an
isolate per invocation. The same "spawn per unit of work" shape as the
host-side problem, one layer up.

**And this codebase has already solved it once.**
`lib/features/viewer/highlight_worker.dart` is *"a single long-lived isolate
that syntax-highlights large files, shared by every open CodeView"*, written
precisely because the per-file `Isolate.run` it replaced re-registered ~39
grammars on every spawn. Its docstring even records the trade-off that a
general worker has to make — serial processing, superseded results dropped by
the caller's token. The pattern is proven in-tree; it simply was not applied to
the other twelve.

## C — Process and watchdog management (4)

### C1 — Make the watcher self-terminating, and stop relying on the client

**Grounded in:** the inotify-tools `select()` limitation above; Finding A's
narrowing table, which shows every client-side teardown path already works.

Arm with a bounded wait and a lease the watcher re-checks, so a watcher whose
client is gone dies on its own:

* `inotifywait -t <interval>` instead of an unbounded `-m`, in a re-arm loop —
  the timeout is what forces `select()` to return, which is what lets the
  process ever notice anything.
* On each wake, verify a **lease file** under the git-dir whose mtime the app
  refreshes over the live channel. Stale lease ⇒ exit. This is the part that
  survives a dropped TCP, because it needs nothing from the client *at the
  moment of failure* — only its earlier absence.
* Wrap the arm so the process is also `PR_SET_PDEATHSIG`-guarded where
  available, as a second, kernel-level backstop.

The client-side teardown stays exactly as it is; it is correct and it is fast.
This adds the path that covers its absence.

### C2 — Consume git's daemon instead of running a second watch tree

**Grounded in:** `core.fsmonitor=true` already being set by this app, confirmed
live on both host repos.

Where the fsmonitor daemon is available and enabled, the app's own recursive
`inotifywait` is redundant surveillance of a tree already under surveillance.
Options, in increasing order of ambition:

1. **Stop double-watching.** For a repo with `core.fsmonitor=true`, the app's
   watch can shrink to the git-dir signal points alone (index, HEAD,
   `refs/heads`, `refs/tags`) — the bounded-watch surface that
   `bounded_watch.dart` already computes — and let `git status` be fast because
   the daemon makes it so. Work-tree events stop being the app's problem.
2. **Query the daemon.** It speaks over a Unix domain socket; a host-side
   shim could subscribe and forward, giving one watcher process per host
   instead of per repo.

Option 1 is a scope reduction of existing code, not new machinery, and it
removes the leaking surface for the repos most exposed to it — large work
trees, which is exactly where `$HOME`-scoped dotfiles repos live.

#### Amendment C2.1 — 2026-09-04: declined on evidence — the daemon is a query accelerator, not a notification source

**C2 is withdrawn.** Both of its options rest on a premise git's own
documentation contradicts, found before writing any Phase 8 code.

`git fsmonitor--daemon` exposes exactly four verbs — `start`, `run`, `stop`,
`status` (git 2.55.0, verified against the installed binary and
`git help fsmonitor--daemon`). There is no subscribe, no event stream, and no
third-party client interface. The manual is explicit that the daemon
"communicates directly with commands like `git status` using the simple IPC
interface": it makes *git's own* scan cheap by answering "what changed since
token X" to a **polling** caller. It does not tell anyone when something
changed.

So the sentence above — "Work-tree events stop being the app's problem" — is
false. The app's watcher and the daemon are not two systems watching the same
tree redundantly; they do different jobs. The daemon accelerates the `git
status` the app runs, and the app's watcher is what tells the app to run it.
There is no double-watching to stop, and option 2's "shim could subscribe and
forward" has no interface to subscribe through.

Two further facts settle it:

* **There is no poll to fall back on.** `watch_lifecycle.dart:149` starts the
  5 s poll **only** in degraded mode, and `start()` cancels `pollTimer` on a
  successful arm (`:227`) — deliberately, to fix a bug where a recovered
  watcher left the poll running forever. A healthy event-driven watcher polls
  not at all. Dropping the work-tree watch would therefore leave a tracked-file
  edit with no path to the UI whatsoever, indefinitely — the status pane, this
  app's primary view, silently stale.
* **The two code paths are mutually exclusive by design.** fsmonitor is
  refused for scoped repos (`local_repo_form.dart:414-416`, "The fsmonitor
  daemon is never valid on a scoped repo"), and `computeBoundedWatchSpec` — the
  surface C2 proposed reusing — exists only for scoped repos.

**What survives.** The daemon is still a long-lived host process this app
causes, never counts, and never reclaims, which is squarely this record's
thesis. That belongs to **C3**'s registry and ceilings, not to a watch-surface
reduction; it is recorded there rather than pursued here.

### C3 — A registry with determinate ceilings, enforced not assumed

**Grounded in:** 0024 M2, which turned the `MaxSessions` budget from a comment
into a counter and found the comment had omitted streams entirely.

The same treatment for host processes:

* **A lease/PID registry** per repo under the git-dir, written at arm time.
* **A sweep at connect** that reclaims any recorded PID still alive and not
  ours — the "no reconnect-time sweep" 0022 named and never built.
* **A hard, named ceiling per connection**, refused rather than exceeded, with
  the refusal surfaced (0024 H3's `onDiagnostic` already carries watcher
  diagnostics to the output log, so the channel exists).

Proposed ceilings, to be pinned as constants and asserted by a test the way
`maxConcurrentStreams` now is:

| resource | ceiling | why |
|---|---|---|
| watcher processes per connection | **2** | one active repo + one background; beyond that, poll and say so |
| `cat-file --batch` per connection | **1** | it is a multiplexer by design |
| command-session shells (C-D1) | **1** | plus the existing read-lane bound |
| total host processes attributable to one connection | **≤ 6** | against ~40 observed watchers alone |
| inotify instances held | **≤ 8** | against `max_user_instances = 1024` measured on this host |

The point is not the specific numbers. It is that today **there is no number at
all**, which is how 19 orphans and 123 processes both went unnoticed.

### C4 — The degraded-poll path costs more than everything else combined

**Grounded in:** the 2026-09-04 post-phase re-measurement (`trace2` on the live
host, method as in Phase 0, control passed 7 ≥ 5). Found by measuring rather
than predicted — this finding did not exist when the record was written.

Across a 21-minute window with the app connected to `percona-postgres`, 156 git
processes were logged. They separate into three regimes with no overlap:

| regime | duration | git processes | character |
|---|---|---|---|
| A | 0–92 s | **83** | exactly 4 processes every 5 s |
| B | 92 s–1240 s | **0** | connected, idle, event-driven |
| C | last 42 s | **76** | one one-file commit+push |

**Regime B is the good news and it is unambiguous:** nineteen minutes connected
and idle cost *zero* git processes. An armed event-driven watcher is free, so
none of this record's remaining proposals can be justified by steady-state cost.

**Regime A is the finding.** 83 of 156 processes — **53 % of everything
observed** — arrived with no user action, on a 5-second metronome, each tick
being one snapshot (3 gits) plus one `rev-parse`. Five seconds is
`pollInterval` in `watch_lifecycle.dart:149`, which by construction runs **only
in degraded mode**: `start()` cancels `pollTimer` on a successful arm (`:227`).
The metronome stopped abruptly at 92 s, consistent with a recovery attempt
finally arming.

The rate is the problem: **48 git processes per minute** while degraded, and
`recoveryInterval` is 3 minutes, so a single degradation can cost ~140
processes before it is even retried — more than the 123 that motivated this
entire record, from one unlucky arm.

**What is observed but not yet explained.** The census taken during regime A
showed **two live `inotifywait` processes** (ages 86 s and 69 s) on the host at
the same time the app was polling as though it had no watcher. Host watchers
running while the app polls means the cost is paid twice: the watch processes
exist and are billed to the connection, and the poll runs anyway. Whether the
stream broke while the process survived (the 0022 M5 signature), whether two
arms raced, or whether the app misclassified a healthy watch, cannot be settled
from host-side data — it needs app-side instrumentation of `watchLifecycle`'s
mode transitions.

**Why this outranks D1.** D1 makes each command cheaper; C4 is about commands
that should not be issued at all. It is bug-shaped rather than architectural,
carries no single point of failure, and a persistent session would merely make
the same 4-per-5-second poll cheaper. On the measured evidence the ordering in
decision driver 5 — reduce demand before adding machinery — applies to C4
ahead of D1.

## D — The process stack (3)

### D1 — One persistent command session per connection

**Grounded in:** the VS Code host-server precedent; 0024 P2's measured two
round trips per `execute()`.

Replace channel-per-command with a single long-lived `sh` on one channel,
reading length-prefixed requests and writing length-prefixed framed responses.
Every command then costs a write and a read rather than `CHANNEL_OPEN` +
`exec` + teardown, and the host forks one process per *command* rather than one
shell *plus* one command.

This subsumes 0024's Phase 8 (P2), which proposed batching within a window;
a session is the same idea with the window removed. Its constraints carry over
unchanged and are non-negotiable: reads only at first, one deadline per
request, per-request byte budgets, and a fail-open path to the current
per-command executor. It also needs an answer for a wedged session that the
batching proposal did not: a session is a single point of failure in a way that
N independent channels are not.

### D2 — Bundle the refresh triple into one invocation

> **Already implemented — corrected 2026-09-04 during execution.**
> `git_service.dart:1366-1391` routes `status()`, `refs()` and `pendingOp()`
> through `_snapshot(repoPath)`, a single `sh -c` running all three with framed
> output, and `_snapshot` (`:1958-1970`) deduplicates concurrent callers via
> `_snapshotInFlight`. This proposal describes work that was done before this
> record was written.
>
> It also corrects how the measurement should be read: the 15×`status` /
> 15×`for-each-ref` / 15×`remote` are **15 invocations of one bundled
> command**, each spawning three git processes — not three reads repeated
> fifteen times. The defect is the *number of waves*, and bundling cannot
> reduce it.

**Grounded in:** the measurement — `status`, `for-each-ref` and `remote` appear
15 times *each*, always together; and on existing precedent in this codebase.

`setFsmonitorMany` (`git_service.dart:2319`) already composes a multi-command
`sh -c` script with per-part isolation and framed error reporting. The refresh
triple is the same shape with a simpler failure mode. One process, one channel,
one round trip, three answers — turning 45 processes into 15 before any
deduplication work is done.

### D3 — Promote `cat-file --batch` from one-shot to session

**Grounded in:** `git_cat_file_batch.dart` already exists and already
fails open to per-key `showOne`.

`git cat-file --batch` is git's own long-lived query interface. The app spawns
it per batch and discards it. Holding one per repo over the persistent session
(D1) makes blob reads a write/read on an existing process — the same move git
itself made for `fsmonitor`.

#### Amendment D3.1 — 2026-09-04: declined on evidence — no caller to optimise, and the transport cannot carry it

**D3 is withdrawn**, on two independent grounds established before writing any
Phase 11 code.

**1. The app never spawns it.** `GitService.showBlobsBatch`
(`git_service.dart:2989`) has no caller anywhere in `lib/features/`; the only
invocations in the tree are its own tests. The method's own doc comment already
records this as deliberate — *"Deliberately unconsumed by the UI today
(evaluated, not an oversight): every current blob reader requests exactly one
blob at a time"*. The sentence above, "the app spawns it per batch and discards
it", describes a cost of **zero invocations per session**. There is nothing to
promote from one-shot to session.

**2. The transport cannot carry a session, and making it could reintroduce a
fixed corruption bug.** A persistent `cat-file --batch` needs two things the
executor seam does not have:

* **Raw bytes out.** `CommandStreamHandle.stdout` is `Stream<String>`,
  UTF-8-decoded with `allowMalformed: true`
  (`ssh_command_executor.dart:133-137`; the decode is at `:185`). That is
  exactly the lossy path 0022 M10 fixed: the batch parser frames objects by
  git's own byte **count**, so one replaced byte desyncs every later object and
  returns the wrong content for the wrong key. It is why the surviving one-shot
  path base64s its output through a temp file.
* **Incremental stdin.** `executeStream` takes no stdin at all, and the
  one-shot path closes stdin immediately and on purpose (`:920-929`): "a
  command that unexpectedly reads stdin blocks on it forever: it never exits,
  its channel stays open". A `cat-file --batch` session is precisely a process
  that reads stdin forever.

Supplying both means a new byte-level bidirectional stream across all three
`CommandExecutor` implementations plus the pop-out relay — where
`ProxyCommandExecutor.executeStream` today throws `UnsupportedError`
outright. That is transport work, not the local change D3 describes.

**If a burst caller ever lands** — an "expand all", a multi-file prefetch, a
bulk export — reopen this with those prerequisites stated, and note that the
existing one-shot batch already collapses a burst into **one** process. The
session form saves the second and subsequent bursts only.

## E — Threads, channels, routines

The three concurrency layers here are distinct and only one of them is
currently accounted for.

| layer | unit | bounded today? |
|---|---|---|
| host | OS processes | **no** — this record exists because of that |
| transport | SSH channels | partly — reads capped at 4, isolated at 2, streams at 8 since 0024 M2; **no unified total** |
| client | Dart isolates | **no** — spawned per call site |

**Transport.** Channels are the real concurrency primitive: dartssh2
multiplexes them over one TCP with independent flow-control windows, which is
why reads can overlap a fetch at all. What is missing is a single accounting
across lanes *and* streams *and* the sideload path, checked against the host's
actual `MaxSessions` — 0024 M2 proved the host's ceiling binds first when it is
lower, so the app can discover the real limit rather than assume 10.

**Client.** Per Flutter's own guidance, repeated `Isolate.run` should be a
long-lived `Isolate.spawn` worker — and `highlight_worker.dart` is the in-tree
proof, with its rationale already written down. Extending that one worker (or
adding a second, for parsing) to cover the hot repeated parses — status, refs,
log, blame, diff — replaces per-call spawn cost with a message round trip on a
warm isolate.

The documented constraints apply and are worth stating so the plan does not
trip on them: no Flutter APIs or `rootBundle` in a spawned isolate, closures
and sockets are not sendable, and every isolate costs its own heap plus an OS
thread — so this is **one or two named workers**, never a pool sized to cores.
`highlight_worker` also records the cost honestly: serial processing means a
very large payload briefly delays another view's, which is the right trade for
one warm isolate over N cold ones but must be a deliberate choice per worker.

## F — Algorithms and heuristics (3)

### F1 — Fingerprint the repo and short-circuit the refresh

**Grounded in:** 15 identical refresh triples for one gesture.

Most of those 15 waves observed a repository that had not changed since the
previous wave. Compute a cheap fingerprint in **one** command — `HEAD` oid,
`.git/index` size+mtime, `packed-refs` mtime, and the count of loose refs —
and short-circuit the whole triple when it is unchanged since the last
completed refresh.

This is content-addressing applied to a refresh: the expensive work is keyed on
a cheap, exact witness of the state it derives from. It converts 15 waves into
15 one-command probes plus one real refresh, and it degrades safely — a
fingerprint collision costs a missed refresh only if the index changes with
identical size *and* mtime, which the watcher tick would catch anyway.

> **Corrected 2026-09-04 during execution — the safety argument above is wrong,
> and F1 is narrowed.** A git-dir fingerprint cannot gate `status`: a work-tree
> edit changes nothing in the git-dir at all. Measured on the host:
>
> ```
> before edit:  46434f4c…|384:1788548717|0:0   status: 0 lines
> after  edit:  46434f4c…|384:1788548717|0:0   status: 1 lines
> ```
>
> HEAD, index size/mtime and `packed-refs` are identical across an edit that
> `status` reports. This is not a collision risk — the witness is blind to the
> work tree. And `GIT_OPTIONAL_LOCKS=0`, which `CommandFormatter.defaultEnv`
> sets on every command, ensures `git status` will not rewrite the index
> either, so nothing incidental repairs it.
>
> **F1 therefore gates refs-derived reads only** — `for-each-ref`, `remote`,
> `log` — which depend on nothing but git-dir state. `status` is never gated.
> The win is smaller than claimed above, and the staleness class it would
> otherwise have introduced is the one 0022 and 0023 spent phases removing.

### F2 — Invalidate by path, not by family set

**Grounded in:** `RepoWatchEvent.paths`, `isScoped` and `touchesGitState`
already exist and are already documented as the mechanism for answering a
change "in proportion to it".

`refreshAfterMutation` invalidates all 12 families unconditionally. But the
watcher already knows what moved. A change under `refs/` need not re-run
`status`; a work-tree file edit need not re-run `for-each-ref` or `remote`.
The classification helpers are written; nothing consumes them for invalidation
scope. This is the largest available reduction that requires no new host-side
machinery at all.

### F3 — Suppress echoes by bracketing, and collapse superseded waves

**Grounded in:** the `withOwnMutation` / `refreshAfterMutation` asymmetry
established in Finding B — 4 bracketing call sites in `repo_status_view.dart`,
**0** in `commit_dialog.dart`.

Two parts:

* **Bracket every mutation surface**, so writes made *during* a gesture are
  suppressed rather than stamped after the fact. A point-in-time `mark()`
  cannot suppress an echo that has already arrived.
* **Give refreshes a generation counter.** When wave *n+1* is requested while
  wave *n* is still in flight and nothing has changed between them, wave *n*
  should be superseded rather than both completing. The lane scheduler already
  proves this pattern is workable here; `CommandLaneScheduler` reclaims and
  supersedes work by design.

## What "success" means for the extended scope

Deliberately expressed as measurements, all of which are now cheap to take
because the instruments exist and have been validated:

| measure | baseline | target | **re-measured 2026-09-04** |
|---|---|---|---|
| git processes, one one-file commit+push | **123** | **≤ 15** | **76** — target missed |
| refresh triples per commit+push | **15** | **1–2** | **7** — target missed |
| long-lived host processes per connection | unbounded (≈40 observed) | **≤ 6, enforced** | **3 at rest** — met |
| orphaned watchers after a week incl. sleep/VPN drop | 19 over ~17 days | **0** | **0** — met (single window, not a week) |
| round trips per command | 2 (`CHANNEL_OPEN` + `exec`) | ~0 amortised (D1) | unchanged; D1 not built |
| repeated `Isolate.run` call sites | **13** | hot parses on 1–2 warm workers | **4 hot parses on 1 worker** — met |
| *(new)* git processes while connected and idle | not measured | — | **0 over 19 minutes** |
| *(new)* git processes while the watcher is degraded | not measured | — | **48 per minute** (C4) |

Each is measurable with a method already used in this record: `trace2` for
command counts, `/proc` enumeration for host processes, dartssh2 source for
round trips.

**Two targets were missed and are recorded as missed.** The commit+push count
fell 123 → 76 (38 %) and the refresh triples 15 → 7, both short of target. The
re-measurement also reframes what is left: with idle cost at zero (regime B),
the remaining count is concentrated in gestures and in the degraded-poll path
**C4**, not in steady state. Measured RTT to the host is **51 ms** (median TCP
connect to :22), so the ~36 read commands in a gesture carry ≈3.7 s of protocol
overhead, or roughly 1–2 s of wall clock at the read lane's 4-way concurrency —
D1's actual remaining value, and the number its approval should be decided on.

## Sources

* [git-fsmonitor--daemon documentation](https://git-scm.com/docs/git-fsmonitor--daemon)
* [git-fsmonitor--daemon(1), man7](https://www.man7.org/linux/man-pages/man1/git-fsmonitor--daemon.1.html)
* [VS Code Agent Host architecture](https://code.visualstudio.com/docs/agents/concepts/agent-host)
* [Introducing the Agent Host for persistent, portable agent sessions](https://code.visualstudio.com/blogs/2026/08/26/agent-host-architecture)
* [Flutter — Concurrency and isolates](https://docs.flutter.dev/perf/isolates)
* [Dart — Isolates](https://github.com/dart-lang/site-www/blob/main/src/content/language/isolates.md)
* [inotify-tools #117 — inotifywait and a closed reader](https://github.com/inotify-tools/inotify-tools/issues/117)
* [inotifywait(1) manual](https://man.archlinux.org/man/inotifywait.1)
* [PR_SET_PDEATHSIG(2const), man7](https://man7.org/linux/man-pages/man2/pr_set_pdeathsig.2const.html)
* [Using PR_SET_PDEATHSIG to reap child processes](http://smackerelofopinion.blogspot.com/2015/11/using-prsetpdeathsig-to-reap-child.html)
* [SSH connection multiplexing with ControlMaster](https://stackharbor.com/en/knowledge-base/ssh-connection-multiplexing-controlmaster/)
* [How to reuse SSH connections with multiplexing](https://www.cyberciti.biz/faq/linux-unix-reuse-openssh-connection/)

## Confirmation

This record is confirmed when `0025-PLAN-unaccounted-host-side-work.md` exists
that, for each finding:

1. names the files and lines it touches;
2. names the negative test and records its **observed** failure text against
   the unfixed tree;
3. states the live-host confirmation, since **neither finding may be closed on
   a unit test** — A needs a real dropped TCP, B needs the real provider graph;
4. and, for B, completes attribution **before** proposing a behavioural change.

For the extended scope, additionally:

5. every ceiling in C3 is a named constant with a test that fails when it is
   exceeded — not a comment;
6. the success table under *What "success" means for the extended scope* is
   re-measured with the same instruments and recorded, including any target
   that was **not** reached;
7. D1 (persistent command session) is gated behind a flag, defaults off, and
   retains the per-command path verbatim — it is the one proposal here that
   introduces a new single point of failure.

Baseline at the time of writing: `flutter analyze` clean,
`flutter test` **3430 passing / 2 skipped / 0 failing** under the pinned
Flutter 3.47.2.

## More Information

* Origins: [0022](0022-MADR-git-gh-glab-engine-debug-audit.md) M5 (Finding A,
  including the corrections in its own text) and
  [0023](0023-MADR-commit-and-push-perceived-freeze.md) Phase 7 item 1 plus its
  open B9 (Finding B).
* [0024](0024-MADR-ssh-and-remote-repo-engine-debug-audit.md) established that
  the transport itself is sound, which is what makes both of these
  application-level rather than transport-level problems.
* Host measured: `admdevops`, Linux, OpenSSH 10.3p1,
  `fs.inotify.max_user_instances = 1024`.
* The 19 orphans found during this work were terminated at the maintainer's
  request on 2026-09-04 — housekeeping, not a fix. The leak resumes until
  Finding A is remediated.
