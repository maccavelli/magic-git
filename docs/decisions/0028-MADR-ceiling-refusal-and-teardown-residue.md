---
status: "accepted"
date: 2026-09-04
decision-makers: [Maintainer]
consulted: []
informed: [Magic Git contributors]
verified: 2026-09-04
---

# Close out the watcher hypotheses: make a ceiling refusal recoverable, and verify teardown rather than rebuild it

## Context and Problem Statement

[MADR 0026](0026-MADR-degraded-watch-poll-diagnosis.md) enumerated three
mechanisms that could put a watcher into its expensive 5-second poll. **H1** was
confirmed by test and fixed. **H2** and **H3** were never tested — H1 explained
every observed symptom, so neither was pursued, and both were deliberately
recorded as *open, not eliminated*. This record closes them.

> **A note on numbering.** These are 0026's hypotheses, not 0025's. 0025 owns
> the findings they touch (C1 the lease, C3 the ceiling), which is where the
> confusion comes from; cite them as **0026 H2** and **0026 H3**.

The cost of the state they can cause is now measured rather than assumed. From
the 0025 re-measurement: a degraded watcher issues **4 git processes every 5
seconds — 48 per minute** — indefinitely, where a healthy one issues **zero**.

## H2 — A ceiling refusal is indistinguishable from a permanent host limitation

`RemoteWatchService.arm` refuses past the ceiling by returning
`WatchUnavailable` (`remote_watch_service.dart:345`), which is the same value it
returns when the host has **no `inotifywait`/`fswatch` at all** (`:318`), when
the SSH stream budget is exhausted (`:381`), and when a bounded spec matches no
paths (`:405`). `watchLifecycle` collapses all four into `startPolling()`
(`watch_lifecycle.dart:312-313`).

They are not the same kind of condition:

| refusal | nature | correct response |
|---|---|---|
| no watcher tool on the host | permanent until the host changes | poll, retry rarely |
| stream budget exhausted | semi-persistent | poll, retry rarely |
| bounded spec matched no paths | transient, resolves as files appear | retry soon |
| **ceiling reached** | **transient, and resolves the instant another watcher stops** | **retry when a slot frees** |

All four get `recoveryInterval` = **3 minutes** (`:275`, the `watch()` default). So a repo refused
because two other repos happen to hold the slots polls for up to three minutes
after a slot frees, and — if the slots stay occupied, which is the normal
steady state — **polls forever at 48 processes per minute**.

This is reachable in ordinary use. `repoWatchProvider` is a `family`, and a
watcher is armed per watched repo: the main window's active repo, plus each
pop-out window's repo through `providers/window_manager_bridge.dart:354`. Two pop-outs on
different repositories exhaust the ceiling, and the third watched repo degrades
permanently.

**Nothing tells a waiting repo that a slot freed.** `releaseSlot()` decrements a
counter; no one is listening. Recovery is a timer that re-probes on a fixed
interval, which is the right shape for "has the host changed" and the wrong one
for "is there room now".

**And the ceiling is not scoped as documented.** `_liveWatchers` is `static`
(`:217`) — process-global — while the constant above it reads *"live watcher
processes **one connection** may hold at once"* (`:138`). With two connections
open, the first to arm consumes the whole budget and every repo on the second
connection polls. The comment and the code disagree; one of them is a defect.

## H3 — Teardown residue, which 0026 and 0027 have probably already removed

0022 M5 established that a clean teardown is honoured but **abnormal channel
loss orphans a host watcher**, because `inotifywait` blocks in `select()` and
never discovers its reader is gone.

Two changes since have altered this materially, and neither was made with H3 in
mind:

* **0026** fixed a race in which two overlapping arms both armed a source while
  only one teardown was retained — the second silently orphaned the first. That
  was a *manufacturing* route for orphans that had nothing to do with channel
  loss.
* **0027** made the heartbeat lease **per watcher instance**. An orphan's own
  lease file is refreshed only by that instance's `beat()` timer, which dies
  with its arm — so an orphan's lease now goes stale on schedule and the
  watcher exits, where previously a live successor refreshed the shared file and
  held it open forever.

Together these mean an orphaned watcher should now self-terminate within
`leaseStaleAfter` (5 min) plus one `inotifywait -t` wake (≤ 2 min). **H3's
symptom may already be gone as a side effect.** That is a claim about behaviour
nobody has checked, and it is exactly the sort of claim this project has been
burned by: 0027 exists because a reclamation path shipped, passed its tests, and
had never once worked.

## Decision Drivers

* **Measured cost.** 48 processes/minute for a degraded repo, against zero for a
  healthy one. H2 is not a latency nicety.
* **Do not rebuild what may already work.** H3's remedy, if one is needed at
  all, cannot be chosen before someone observes whether an orphan still survives.
* **A check is not trusted until seen to fail.** Applies with force here: the
  last two records in this series both found mechanisms that had never worked.
* **Root cause only.** Raising the ceiling to make H2 less visible is the
  forbidden shape; it trades a poll for the orphan accumulation 0025 C3 added
  the ceiling to stop.

## Considered Options

**For H2**

* **H2-a — Distinguish the refusals and wake a waiting repo when a slot frees.**
* **H2-b — Distinguish the refusals only, shortening recovery for transient ones.**
* **H2-c — Raise or remove the ceiling.**
* **H2-d — Queue refused repos and admit them in order as slots free.**

**For H3**

* **H3-a — Measure first: try to produce an orphan under the current build.**
* **H3-b — Add explicit remote-side teardown (a kill by recorded pid at cancel).**
* **H3-c — Declare it closed by inference from 0026 + 0027.**

## Decision Outcome

**H2: "H2-a — distinguish the refusals and wake a waiting repo when a slot
frees."** The ceiling is a *local* condition this process controls, so a repo
refused by it should not be waiting on a timer at all. `releaseSlot()` already
knows the moment a slot frees; the missing piece is that nothing is listening.
Distinguishing the four refusal causes is required anyway — they are already
recorded distinctly in the 0026 transition log, so the information exists and is
simply discarded at the `WatchUnavailable` boundary.

H2-c is rejected as the workaround shape. H2-b is a strict subset of H2-a and
leaves a repo polling for a fixed interval after room appears. H2-d is H2-a plus
ordering machinery, which is not justified at a ceiling of two.

**The `static` scope is treated as a defect to resolve, not a detail**: either
the counter becomes per-connection to match its documentation, or the
documentation is corrected and the global budget justified. It cannot stay as
two statements that contradict each other.

#### Amendment 0028.1 — 2026-09-04: the scope contradiction is documentary, and the floated remedy was a regression

Found while executing the plan. `connectionProvider` and
`remoteWatchServiceProvider` are both plain providers, not families — **the app
holds one connection at a time** — so "process-global" and "per connection"
denote the same watchers and both comments are accurate as written. There is no
behavioural defect today.

And the remedy suggested above is backwards: moving the counter onto the service
instance would give **each** service its own budget, because several providers
construct their own service against one host, multiplying the ceiling rather
than enforcing it. The paragraph above should be read as superseded — what the
pairing actually lacks is a statement of the assumption it rests on, and a test
that fails if that assumption stops holding.

**H3: "H3-a — measure first."** No remedy is chosen, because whether one is
needed is unknown. If an orphan can still be produced under the current build,
this record gains an amendment and a successor decides the fix; if it cannot,
H3 closes as resolved-by-consequence with the evidence attached. H3-c is
rejected outright: inference is how 0027's dead sweep survived for months.

### Consequences

* Good, because the largest measured remaining cost in the watcher path
  (48 processes/minute, indefinitely) becomes bounded by how long a slot stays
  occupied rather than by a fixed 3-minute timer.
* Good, because the four refusal causes stop being indistinguishable at the one
  boundary where the difference decides behaviour.
* Good, because H3 is settled by observation either way, and a "no remedy
  needed" outcome is recorded with its evidence rather than assumed.
* Bad, because slot-release wakeups add a notification path to a component whose
  last two defects were both concurrency-shaped. It must be serialised through
  the same arming path 0026 fixed, not a second one.
* Neutral, because no interval, ceiling or budget is retuned.

### Confirmation

* **H2** is confirmed when a repo refused by the ceiling arms **as soon as** a
  slot frees, proven by a test that fails on today's code (where it waits for
  the recovery timer), and when the four refusal causes are distinguishable at
  the point of decision.

  > **Confirmed 2026-09-04.** Red observed at
  > `Expected: eventDriven / Actual: polling` with no time advanced, so the
  > green cannot be the recovery timer firing. The reason guard was separately
  > seen to fail. Commits `af8ea52`, `dd62a36`.
* **H3** is confirmed when a deliberate abnormal channel loss under the current
  build either leaves an orphan — which reopens it with evidence — or does not,
  observed on the real host rather than reasoned from the lease's design.

  > **Resolved by consequence, 2026-09-04.** An abandoned watcher self-terminated
  > at **lease age 371 s**, inside the predicted window, with the `-t 120` wake
  > and lease re-check visible in the samples. No remedy was needed and none was
  > built. The first run of this experiment was invalid — it fed its own events,
  > writing 1.78 GB — and had to be discarded; that is recorded in the plan
  > rather than quietly replaced.

Both must be seen to fail before being trusted.

## More Information

* [`0026-MADR-degraded-watch-poll-diagnosis.md`](0026-MADR-degraded-watch-poll-diagnosis.md) — where H1/H2/H3 are defined; H1 confirmed and fixed.
* [`0027-MADR-watcher-reclamation-cannot-reclaim.md`](0027-MADR-watcher-reclamation-cannot-reclaim.md) — the per-instance lease that may already have resolved H3.
* [`0025-MADR-unaccounted-host-side-work.md`](0025-MADR-unaccounted-host-side-work.md) — **C3** (the ceiling), **C4** (the 48/minute measurement).
* [`0022-MADR-git-gh-glab-engine-debug-audit.md`](0022-MADR-git-gh-glab-engine-debug-audit.md) — **M5**, the original teardown finding.
