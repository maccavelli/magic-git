---
status: "accepted"
date: 2026-09-09
decision-makers: [Maintainer]
consulted: []
informed: [Magic Git contributors]
verified: 2026-09-09
---

# The watcher ceiling is not leaking slots — it is a two-watcher cap standing in front of an eight-stream budget, and it is what forces a fifteen-repository host onto a poll that costs forty-eight times more

## Context and Problem Statement

A maintainer reported every repository in one directory on a remote bastion
falling back to polling, with this diagnostic:

```text
watcher: polling <repo> — arm unavailable: ceiling; watchers held 2, restarts spent 0
  after: armed(arm succeeded) -> stopped(stream cancelled) -> armed(arm succeeded) -> armFailed(ceiling 2/2)
```

My first reading was a **leaked slot** — MADR 0026's H1, refusals persisting
with no watcher process alive — because the arm reserves its slot before opening
the stream and catches only one of the five exceptions that open can throw. That
reading was wrong about production, and this record exists mostly to say why,
because the wrong reading is the plausible one and it would have led to a fix
that changed nothing the maintainer can see.

Everything below was measured on the host, not inferred. Method: an SSH session
to the bastion as the maintainer's account, reading `/proc`, the inotify sysctls,
the sshd configuration and the watcher registry files; a 60-second sampler for
process spawns; and one timed probe that armed a recursive watch on the largest
repository and tore it down again. Nothing was left running — verified after the
fact (four registry files, both belonging to live watchers; no probe artefacts).

Identifiers are redacted per the standing convention: `<bastion>` for the host,
`<user>` for the account, `/home/<user>/…` for its home. Repository names are
given by shape rather than by name.

Line numbers are as of `a397434`.

## Findings

### F1 — The two held slots are real watchers doing their job, not leaked bookkeeping *(the correction)*

**Measured.** The host runs six watcher-related processes, which are **two**
logical watchers, not six and not four:

```text
  PID       PPID      ELAPSED   COMMAND
  2843683   2840330   14:08:27  sh          <- watcher A, parent shell
  3053291   2843683      00:49  sh          <-   its backgrounded subshell
  3053292   3053291      00:49  inotifywait <-     the actual watch
  2942155   2838444      57:34  sh          <- watcher B, parent shell
  3053295   2942155      00:48  sh
  3053296   3053295      00:48  inotifywait
```

The duplicate-looking rows are an artefact of `sh` reporting a backgrounded
`{ … } &` group under the parent's command line; `ppid` settles it. The inner
pair rotates roughly every two minutes because the arm script runs
`inotifywait -t 120` in a `while` loop, re-checking the lease each iteration —
which is exactly the design.

Both watchers are **alive and leased**: their heartbeat files were touched 16 and
22 seconds before the sample. `watchers held 2` is an accurate statement about
the world. There is no leaked slot on this host.

### F2 — There are no orphaned watchers anywhere, so the ceiling's original justification is spent

**Measured.** Across all fifteen repositories in the directory there are exactly
**four** `mg-watch.*` registry files — a `.pid` and a `.hb` for each of the two
live watchers. No stale pairs, no orphaned processes, after fourteen hours of
uptime on one of them and many arm/teardown cycles.

That matters because the ceiling exists for one reason. MADR 0025 C3 introduced
`maxConcurrentWatchers = 2` after finding **19 orphaned `inotifywait` processes,
the oldest 16.9 days**, on this same host. Since then the lease was built
(0025 A/C1, 0027): every watcher script begins `[ -f <hb> ] || exit 0` and
re-checks `find <hb> -mmin -5` on every loop, so a watcher whose client is gone
terminates itself within five minutes, and `sweepStaleWatchers` reclaims anything
that somehow survives at the next connect.

The lease is doing the job the ceiling was hired for, and it is doing it well
enough that the failure mode which motivated the ceiling cannot currently be
found on the machine it was found on.

### F3 — The ceiling is four times tighter than the transport budget it was meant to respect, and that budget is already enforced separately

**Traced by reading.** `RemoteWatchService.maxConcurrentWatchers` is `2`
(`remote_watch_service.dart:151`). The resource a watcher actually holds is one
long-lived SSH channel, and the executor's own limit on those is
`maxConcurrentStreams` — **8**, or 2 when the dedicated stream client has
degraded onto the command client (`ssh_command_executor.dart:385`).

That limit is not advisory. `executeStream` refuses past it
(`ssh_command_executor.dart:1236-1241`) by throwing `SSHStreamBudgetExhausted` —
and the watcher arm **already handles exactly that**, releasing its slot and
degrading to polling with a legible diagnostic
(`remote_watch_service.dart:469-475`, added by 0024 M2).

So the connection-level constraint has a correct, purpose-built enforcement point
with a budget of 8, and in front of it sits a second, cruder cap of 2 whose
host-level justification F2 shows has been taken over by the lease. The two
watchers this host is allowed are a quarter of what the transport would grant and
a fraction of what the host could carry.

### F4 — The budget is keyed to the host, but three independent sessions are sharing it

**Measured.** The bastion shows three groups of three `sshd-session … [priv]`
processes for this account, plus the interactive session used for this
investigation — ten established connections. Three groups of three is the
app's triple client (command, stream, sync) times **three tabs**, all connected
to the same host.

Each of those tabs has its own `SSHCommandExecutor` and therefore its own
`_activeStreams` budget of 8. The host-keyed ceiling shipped today (MADR 0039 F4)
gives all three of them **two watchers between them**. The pre-0039 counter was
process-global, which for a single host is the same number — so this is not a
regression, but neither does 0039 help here: it fixed cross-*host* starvation,
and this maintainer's problem is a single host with many repositories.

### F5 — The fallback costs about forty-eight times what the thing it replaces costs

**Traced by reading, and consistent with MADR 0026's measurement.** One polling
tick invalidates the repo snapshot, and `GitService._snapshot` sends a single
`sh -c` that runs `git status --porcelain=v2 --branch -z`, `git for-each-ref` over
heads/remotes/tags, `git remote`, and the pending-op probe — four-plus `git`
processes per tick. The poll interval is 5 s (`repoWatchProvider`'s default), so
each polling repository costs roughly **48 git processes and 12 SSH exec channels
per minute**, indefinitely, whether or not anything changed.

A *watched* repository costs one long-lived channel and one `touch` per 60 s.

The ceiling therefore does not reduce load on this host. Past two repositories it
multiplies it, and it does so precisely in proportion to how much the maintainer
is working.

### F6 — The host is nowhere near any resource limit

**Measured.**

| | measured | limit | share |
|---|---|---|---|
| inotify watch descriptors (2 watchers) | 959 | 524,288 | 0.18 % |
| inotify instances (2 watchers) | 2 | 1,024 | 0.20 % |
| watcher RSS (all six processes) | ~10 MB | — | — |
| load average | 0.22 | 8 cores | 3 % |

Projected to **all fifteen** repositories watched at once: 37,598 directories →
**7.2 %** of the watch budget and **1.5 %** of the instance budget. `sshd` is
9.9p1 with `MaxSessions` unset anywhere in `sshd_config` or its includes, so the
OpenSSH default of 10 applies — and the app's own budget of 8 streams per
connection already sits inside it.

### F7 — One repository is an outlier, and it is the only real argument for keeping any ceiling at all

**Measured.** Directory counts across the fifteen repositories are 8–98 for
thirteen of them, 439 for one, and **36,749** for a single personal context
repository — 98 % of the total. A timed probe armed a recursive watch on it and
tore it down again:

```text
time to "Watches established":  2.52 s
resident memory:                17 MB
watch descriptors:              ~36,749 (one per directory)
```

Two and a half seconds of arm latency and 7 % of the host's watch budget, from
one repository. That is the shape a ceiling should be defending against — and
note that it is a *size* problem, not a *count* problem, which a cap on the
number of watchers addresses only by accident. The bounded-watch machinery
(`bounded_watch.dart`, MADR 0022) exists for exactly this shape and engages only
for repositories flagged as scoped.

### F8 — The slot leak I first suspected is real and reproducible, but it is not what the maintainer is seeing

**Reproduced, twice.** A slot is reserved before the stream is opened
(`remote_watch_service.dart:405`) and released on every path that does not end
armed. `executeStream` can throw five ways, and the arm catches one:

```text
ssh_command_executor.dart:1238  SSHStreamBudgetExhausted   <- caught (0024 M2)
ssh_command_executor.dart:1223  SSHTransportNotReady
ssh_command_executor.dart:1230  SSHCommandSuperseded  (also :1261)
ssh_command_executor.dart:1278  SSHCommandTimeout
ssh_command_executor.dart:1279  SSHChannelOpenError
```

The other four propagate out of `arm` with the slot still held. A new test
(`test/watch_slot_leak_test.dart`, uncommitted) fails on the current tree —
one slot lost per failure, two failures exhausting the host budget — and fails
identically in a scratch worktree at `dc78436`, the commit before any of this
week's audit work. `git log -S` puts the reservation in `7735f13` and the
single-exception catch in `d10a334`, both 2026-09-04. **Pre-existing, and not
caused by MADR 0039.**

It is not the reported failure: F1 shows both slots backed by live watchers. But
it is a live hazard, and it is *worse* the tighter the ceiling is — at a budget
of 2, one leak halves the host's capacity permanently, which is why it reads so
convincingly as the cause.

### F9 — The build in front of the maintainer predates this week's work

**Measured.** The running bundle was built 2026-09-08 13:56 and launched
14:32; every commit in the MADR 0039 series is dated 2026-09-09. The behaviour
reported is from the pre-audit build with the process-global counter. Nothing
shipped this week caused it, and nothing shipped this week fixes it.

#### Amendment 0040.1 — 2026-09-09: the outlier left the working set, and F7 no longer carries the weight it was given

Recorded the same day, before any code was written.

F7 rested on a single repository holding 36,749 of the 37,598 directories on the
host. On reading that finding the maintainer identified it as **archival** and
had its `.git` renamed to `_git`, so git — and therefore the app — no longer sees
a repository there. That is a data change on the host, not a code change, and it
was made deliberately rather than as a workaround: the repository is not being
worked in, and 29 GB with 488 tracked files in 170 directories is not a working
tree.

Re-measured afterwards:

| | before | after |
|---|---|---|
| repositories git recognises in the directory | 15 | **14** |
| directories across all of them | 37,598 | **858** |
| share of the 524,288-watch budget if every one were watched | 7.2 % | **0.16 %** |

Every remaining repository is 8–439 directories. Watching all fourteen at once
would cost less than the two watchers running today.

**What this changes.** F7 was the only argument in this record for keeping a
count-based cap, and it is now hypothetical rather than present. The decision is
unchanged but better supported: the ceiling change is safer than it looked, and
the "consult the host's remaining inotify budget before arming" follow-up named
under Consequences is now speculative work rather than a response to anything
measurable. It should not be built until a repository of that shape is actually
in a working set again.

**What this does not change.** Two things stand on their own evidence and are
untouched by it: the slot leak (F8), which is reproducible, pre-existing, and
worse the tighter the cap; and the reconciliation, which exists for bookkeeping
that is wrong for reasons nobody has thought of yet.

**One general point is worth keeping even though its instance is gone.** The
investigation found that a recursive watch on that repository armed 36,749 watch
points to observe changes in the 170 directories git tracks from — a bounded
watch would have armed roughly 176, some 208× fewer, and `bounded_watch.dart`
already implements exactly that. It engages only for repositories flagged as
scoped, and that one was an ordinary repository that happened to be enormous.
Selecting the watch *surface* by measured disproportion rather than by a flag is
a real improvement and a real change of shape; it is deliberately **not** part of
this decision, and belongs in its own record if a working set ever needs it.

#### Amendment 0040.2 — 2026-09-09: raising the cap unmasked a watcher-multiplication defect, and phases 2 and 3 are reverted

Recorded within the hour, from the maintainer's first rebuilt session.

With the derived cap live (6 per session, per host), four repositories were
opened and the host began **accumulating watchers per repository**, measured over
40 seconds:

```text
12:46:21  watchers=7   registry files=22
12:46:42  watchers=7   files=22
12:47:03  watchers=8   files=24

per repo:  systems-workspace 4 · percona-postgres 3 · lkq-apache-spark 2
           eck-logstash-prod 2 · eck-logstash-non-prod 2
```

Every duplicate came from the **same** sshd session, so this is not two tabs
legitimately watching one repository, and **every one had a fresh heartbeat** —
the app was actively refreshing all of them. It genuinely held several armed
watchers per repository. That is the MADR 0025 C3 shape, growing.

**Ruled out by reading:** overlapping `start()` calls inside one engine.
`watch_lifecycle.dart` serialises `start()` through `startChain` with
`queued >= 1` coalescing — MADR 0026 H1's fix — and it is intact. The
slot-release listener is guarded on `mode == polling && degradedReason ==
ceiling`. The remaining candidate, unproven, is more than one *engine* per
repository in one container: a provider element rebuilt while the previous
engine's `stop()` teardown was still in flight.

**On causation, plainly.** The multiplication mechanism lives in
`watch_lifecycle.dart`, which neither this record nor MADR 0039 touched. What
raising the cap did was remove what had been hiding it: at a cap of 2, a
repository that armed twice consumed the whole budget and every other repository
was refused — **which is exactly the symptom originally reported**. F1 of this
record established that both held slots were backed by live watchers and stopped
there. It never asked why one session needed two for two repositories, and that
was the thread to pull.

F1 is not wrong as written. It is incomplete, and the incompleteness pointed the
whole investigation away from the actual defect.

**Action taken.** Phases 2 and 3 reverted (`370b2b8`, `22270f4`); phase 1 — the
structural slot release — kept, since it is independent and its regression test
still passes. The cap is back to the constant 2 with host-only keying, which
bounds the accumulation to two processes per host while the mechanism is found.

**What this record's decision now rests on.** The reasoning in F2, F3, F5 and F6
is unaffected — the cap really is four times tighter than the budget it stands in
front of, the lease really has taken over the orphan problem, and polling really
does cost ~48 git processes per minute per repository. The cap is still the wrong
limit. But it cannot be raised until the multiplication defect is understood,
because the cap is currently the only thing bounding it. That is a new decision
needing its own record and its own evidence, not a resumption of this one.

## Considered Options

* **Fix the leak only** (the original Option 1). Release the slot on every arm
  failure.
* **Fix the leak and make the ceiling self-correcting** (the requested Option 2).
  As above, plus reconcile the counter against the host's live watchers so any
  future leak heals within a session.
* **Fix the leak, make the ceiling self-correcting, and raise the ceiling to the
  transport's own stream budget**, keeping it per session-and-host and leaving
  headroom for the other two stream consumers.
* **Remove the ceiling entirely** and let `SSHStreamBudgetExhausted` be the only
  limit.
* **Raise `pollInterval`** so the fallback is cheaper, and leave the ceiling
  alone.

## Decision Outcome

Chosen option: **"Fix the leak, make the ceiling self-correcting, and raise the
ceiling to the transport's own stream budget."**

This is the requested Option 2 **plus the ceiling change**, and the addition is
not scope creep — it is the only part of the work that changes what the
maintainer sees. Option 2 as requested fixes a hazard that is real (F8) and
repairs bookkeeping that is, on this host today, already correct (F1). Shipped
alone it would close the ticket without altering the symptom, because the
symptom is not a bookkeeping error: it is a cap of 2 doing exactly what it was
told to do, in front of a budget of 8 (F3), on a host using 0.2 % of its watch
capacity (F6), forcing thirteen repositories onto a fallback that costs 48× more
than what it replaces (F5).

The three parts, in the order they should land:

1. **Release the slot on any arm failure.** Structural rather than
   per-exception: the reservation and every exit from the arm belong in one
   `try`/`finally`-shaped region, so no future exception type can reintroduce
   this. The `SSHStreamBudgetExhausted` branch keeps its distinct diagnostic
   because it is the one failure that is *deterministic* and should not be
   retried (0024 M2).
2. **Derive the ceiling from the stream budget** rather than hardcoding 2:
   `maxConcurrentStreams` minus headroom for the two other long-lived stream
   consumers — the CI job trace (`glab_service.dart:1226`) and clone progress
   (`clone_controller.dart:239`) — with a floor of 1 so a degraded single-client
   session still watches its active repository. On a healthy triple-client
   session that is 6; degraded, 1. Key it per session **and** host, since the
   channel budget is per connection while the process budget is per host.
3. **Reconcile the counter at the connect-time sweep.** `sweepStaleWatchers`
   already runs a host-side script per repository; have it report the live
   watcher count and reset the in-process counter to it. A slot leaked by any
   path — including one nobody has thought of — then heals at the next connect
   instead of persisting for the session.

"Remove the ceiling entirely" is rejected on F7: the 36,749-directory repository
shows that watchers are not interchangeable units, and something should still
refuse rather than spend seven percent of a host's watch budget without a word.
"Raise `pollInterval`" is rejected because it makes the degraded state cheaper
rather than rarer, and the degraded state is also *worse* — a poll cannot see a
change that happens and is reverted between ticks, which is the whole reason the
watcher exists.

### Consequences

* Good, because the reported symptom goes away for the case that produced it: on
  a healthy session this host would watch six repositories instead of two, and
  the four that move off the poll stop costing ~48 git processes per minute each.
* Good, because the limit becomes one number derived from the transport instead
  of two numbers that disagree, and the disagreement was invisible — nothing
  connected `maxConcurrentWatchers = 2` to `maxConcurrentStreams = 8`.
* Good, because after (3) the ceiling is self-healing, so a future leak is a
  transient degradation rather than a permanent one.
* Neutral, because host load barely moves. Six watchers on this host is ~3,000
  watch descriptors against a 524,288 budget, and the processes are idle between
  events.
* Bad, because raising the ceiling makes the outlier repository (F7) reachable:
  six watchers *including* that one is ~40,000 descriptors and a 2.5-second arm.
  That is affordable here but it is the case to watch, and it argues for a
  follow-up that consults the host's remaining inotify budget before arming a
  large recursive watch — deliberately **not** in this decision, because it needs
  its own measurement and would hold up a fix that is otherwise ready.
* Bad, because the per-session-and-host key means two tabs on one host can now
  hold twelve watchers between them where the current rule holds two. The host
  can carry it (F6), but the number is no longer bounded by the host alone, and
  (3) is what keeps that honest.

### Confirmation

* **F8's leak** is already pinned by `test/watch_slot_leak_test.dart`, which
  fails on the current tree and at `dc78436`. It becomes the regression guard.
* **The ceiling derivation** needs a test that the watcher cap tracks
  `maxConcurrentStreams` — including the degraded case, where the budget drops
  to 2 and the cap must floor at 1 rather than 0.
* **The reconciliation** needs a test that a counter deliberately inflated above
  the host's live count is corrected by the sweep, and one that a *correct*
  counter is left alone.
* **The per-session-and-host key** extends `watch_ceiling_per_host_test.dart`:
  two sessions on one host each get their own budget, and two hosts still do.
* Every check must be seen to fail before it is trusted, through
  `tool/mutations/`, as with MADR 0039.
* **On the host**, after the change: open more than two repositories in the
  collections directory and confirm from `pgrep -af inotifywait` that each has a
  live watcher and that `mg-watch.*` file pairs match the live set exactly.

## More Information

* MADR 0025 (`0025-MADR-unaccounted-host-side-work.md`) — C3 is the
  19-orphaned-watchers measurement that introduced the cap of 2; A/C1 is the
  lease that has since taken over its job (F2).
* MADR 0026 (`0026-MADR-degraded-watch-poll-diagnosis.md`) — the
  48-git-processes-per-minute cost of the polling fallback (F5), and the H1/H3
  distinction between a leaked slot and a leaked process that F1 turns on.
* MADR 0027 (`0027-MADR-watcher-reclamation-cannot-reclaim.md`) — per-instance
  lease tokens, which is why the registry files in F2 are countable at all.
* MADR 0024 (`0024-MADR-ssh-and-remote-repo-engine-debug-audit.md`) — M2 is the
  stream budget and the one exception the arm handles (F3, F8).
* MADR 0039 (`0039-MADR-process-global-state-and-control-heuristics-audit.md`) —
  F4 keyed this counter by host; F9 records that the reported build predates it.
* `bounded_watch.dart` and MADR 0022 — the machinery for the outlier shape in F7.
