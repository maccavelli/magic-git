---
status: "accepted"
date: 2026-09-04
decision-makers: [Maintainer]
consulted: []
informed: [Magic Git contributors]
verified: 2026-09-04
---

# Diagnose the degraded-poll path before fixing it: instrument the watcher's mode transitions

## Context and Problem Statement

A live re-measurement on 2026-09-04 (recorded as **MADR 0025 C4**, and in
`0025-PLAN-unaccounted-host-side-work.md`) found that **53 % of all git
processes observed on the host arrived with no user action at all**. Across a
21-minute window with the app connected to one repository, `trace2` logged 156
git process starts in three regimes that do not overlap:

| regime | duration | git processes | character |
|---|---|---|---|
| A | 0–92 s | **83** | exactly 4 processes every 5 s |
| B | 92 s–1240 s | **0** | connected, idle, event-driven |
| C | last 42 s | **76** | one one-file commit+push |

Regime B settles that an armed event-driven watcher is free. Regime A is the
problem: a five-second metronome, each tick one snapshot (3 git processes) plus
one `rev-parse`. Five seconds is `pollInterval` in
`lib/core/git/watch_lifecycle.dart:149`, a timer that by construction runs
**only** in degraded mode — `start()` cancels it on a successful arm (`:228`),
deliberately, to fix an earlier bug where recovery left it running forever.

The rate is what makes this the largest remaining cost in the system: **48 git
processes per minute** while degraded, against a `recoveryInterval` of three
minutes. A single degradation can therefore cost ~140 host processes before the
engine even retries — more than the 123 that motivated MADR 0025 in the first
place, from one unlucky arm.

**The observation that does not fit any intended behaviour.** A `/proc` census
taken *during* regime A showed **two live `inotifywait` processes** (ages 86 s
and 69 s), both on the same repository the app was polling. Host watchers were
running while the app behaved as though it had none. The connection is
therefore paying twice: the watcher processes exist and are billed against it,
and the poll runs anyway.

Host-side data cannot say why. `trace2` logs git invocations, not the app's
internal state, and `/proc` shows processes, not which of them the app believes
it owns. **The question is not "what does the host look like" — that is
answered — but "what did the engine think its mode was, and why".** Nothing in
the app records that today.

## Decision Drivers

* **A fix built on an unproven cause is a guess.** Three distinct mechanisms
  below could each produce the observed symptom, and they need opposite fixes.
  Choosing wrong leaves a 48-process-per-minute path in place while appearing
  to have addressed it.
* **The symptom is intermittent and self-clearing.** Regime A ended on its own
  at 92 s. A diagnosis that depends on catching it live by hand will mostly
  catch nothing.
* **Root-cause fixes only** (`AGENTS.md`): no symptom guards, no retries as
  bandaids, no special-casing around a mechanism not yet understood.
* **The instrument must be cheap enough to leave on.** A diagnosis that
  measurably changes what it measures — extra commands, extra processes — is
  worthless on precisely this finding.
* **This is an app-side question.** MADR 0025's instruments (`trace2`, `/proc`)
  are exhausted; they produced the symptom and cannot produce the cause.

## The mechanisms that could produce this

Three, grounded in the code rather than supposed. They are not mutually
exclusive, and they need different fixes.

### H1 — A re-entrancy race in `start()` leaks a watcher slot *(leading)*

`watchLifecycle`'s `start()` (`watch_lifecycle.dart:218`) is `async`, has **no
re-entrancy guard**, and is called from **four independent places**:

| caller | line | trigger |
|---|---|---|
| `onListen` | `:273` | first subscription |
| restart timer | `:191` | source died, after backoff |
| `rearm` | `:213` | the watched path set changed |
| recovery timer | `:159` | periodic retry while polling |

`start()` awaits `teardownWatcher()` (`:230`), which reads and nulls
`armedTeardown` (`:167-168`), and only assigns a new one at `:247` — **after**
`await arm(hooks)` returns. A second `start()` entering that await window sees
`armedTeardown == null`, so it tears down nothing and releases nothing.

In `RemoteWatchService.arm` each call then reserves a watcher slot
(`remote_watch_service.dart:282`, `_liveWatchers++`), which is released only by
`releaseSlot()` — and on the armed path that lives inside the `WatchArmed`
teardown (`:441-442`). Two overlapping arms therefore both reserve, both spawn
a host watcher, and both return `WatchArmed`; the second assignment to
`armedTeardown` at `:247` **overwrites the first**. The consequence is exactly
the census: one `inotifywait` orphaned with no teardown holding it, one
watcher slot leaked permanently, and — once the leak plus one live watcher
reaches `maxConcurrentWatchers = 2` — every subsequent arm refused.

This explains all three observations at once, which no other mechanism does:
two live watchers on **one** repository, a connection stuck polling, and the
condition clearing on its own once something released the survivors.

### H2 — The ceiling is doing exactly what it was told, and that is the bug

`maxConcurrentWatchers = 2` (`remote_watch_service.dart:142`) refuses an arm
past the ceiling by returning `WatchUnavailable` (`:275`). The engine cannot
distinguish that from *"this host has no `inotifywait` at all"*: both land in
`startPolling()`. So a transient, self-inflicted, instantly-recoverable
condition is answered with the same three-minute recovery interval as a
permanent host capability gap.

Two further facts sharpen this. The constant is documented as "live watcher
processes **one connection** may hold" (`:137`), but `_liveWatchers` is
`static` (`:192`) — **process-global**. A second connection inherits whatever
the first is holding. And this ceiling is new: it was added by MADR 0025 Phase
3 to stop 19 orphaned watchers accumulating. If H2 is the cause, that phase
traded a slow leak for a fast poll, and the trade was never measured.

### H3 — Teardown does not kill the remote process (0022 M5, again)

0022 M5 established that abnormal channel loss orphans host watchers, while a
clean teardown is honoured. If a watch's stream dies in a way that leaves the
host process running, the engine sees `onDone`/`onError` → `scheduleRestart`
(`remote_watch_service.dart:387-388`), spends its restart budget, and degrades
to polling — with the host process still alive. This produces the same census
as H1 without any race.

H3 is distinguishable from H1 by the *slot count*: H3 leaves a live process the
engine has already released the slot for, so arms are refused only while the
ceiling is genuinely occupied; H1 leaks the slot itself, so refusals persist
after every process is gone.

## Considered Options

* **Instrument the mode transitions and capture the next occurrence.**
* **Reason from the code and fix the leading hypothesis directly.**
* **Reproduce it in a test harness first.**
* **Raise `maxConcurrentWatchers` and see whether the symptom stops.**

## Decision Outcome

Chosen option: **"Instrument the mode transitions and capture the next
occurrence"**, because the symptom is intermittent, self-clearing, and has
three plausible causes that demand different fixes — and because the one
observation that discriminates between them (whether a *slot* or a *process*
was leaked) is app-side state that nothing currently records.

The instrument is a bounded, in-memory transition log per watch: every mode
change with its cause, the live watcher count at that moment, and the arm
outcome. It answers all three hypotheses from a single capture:

| observation in the log | implicates |
|---|---|
| two overlapping `start()` entries for one repo | **H1** |
| `WatchUnavailable` from the ceiling while `_liveWatchers` ≥ 2 | **H2** |
| repeated `scheduleRestart` from `onDone` before degradation | **H3** |
| refusals persisting after every watcher process is gone | **H1** (slot leak) |

### Consequences

* Good, because the fix that follows is chosen on evidence rather than on the
  most plausible-looking of three candidates.
* Good, because the log is useful past this investigation: "why is this repo
  polling" is currently unanswerable from inside the app, and the watch
  indicator already has a "stopped" affordance with nothing behind it.
* Good, because it costs no host processes and no commands — it records
  transitions the engine already performs.
* Bad, because it defers the fix by one capture cycle, during which the poll
  path keeps costing 48 processes per minute whenever it triggers.
* Neutral, because the instrument is small and stays whether or not the
  hypothesis it confirms is the one fixed.

### Confirmation

This record is confirmed when a capture from a real session either identifies
one of H1/H2/H3 as the cause, or shows a transition sequence none of them
predicts — which is itself a result, and would mean the mechanism is a fourth
one and this record needs a successor rather than a fix.

The instrument itself is not trusted until it has been **seen to fail**: a test
must drive a synthetic degradation and observe the log record it, and a test
must drive the H1 race directly (two `start()` calls overlapping one `arm`) and
observe the double reservation. A transition log that has only ever been
watched recording healthy transitions proves nothing about the unhealthy ones
it exists for.

#### Amendment 0026.1 — 2026-09-04: H1 confirmed, and the fix taken into this record

The instrument was built and, before any live capture was needed, **H1 was
proven deterministically**. `test/watch_transition_wiring_test.dart` drives two
overlapping `start()` calls and asserts every armed source is torn down:

```
Expected: <2>
  Actual: <1>
```

Two sources armed, one teardown ran. The mechanism is as reasoned above, and
the consequence is precisely the census that opened this record: a live watcher
process with nothing holding it, and a watcher slot leaked so every later arm is
refused and the repo drops to the 5-second poll.

**H2 and H3 are neither confirmed nor refuted.** H1 accounts for every
observation, but the other two were never tested and must not be written up as
eliminated. They remain open contributors that this fix does not address.

**The decision below is amended in one respect** (maintainer, same day): the fix
is implemented under this record rather than a successor. The "does not fix
anything" boundary existed to stop a remedy being chosen before a cause was
known. The cause is now known and pinned by a failing-then-passing test, so the
boundary's reason has expired. The rest of the section stands — in particular,
the ceiling was **not** raised and the intervals were **not** touched.

## What this record deliberately does not do

* **It does not fix anything.** No change to `maxConcurrentWatchers`, no
  re-entrancy guard, no change to `recoveryInterval`. Each is a candidate fix
  for a different hypothesis, and adopting one now is the guess this record
  exists to avoid.
* **It does not raise the ceiling to make the symptom go away.** That is the
  workaround shape `AGENTS.md` forbids: it would hide a slot leak (H1) behind a
  larger budget, leaving the leak to exhaust the new ceiling later.
* **It does not touch the poll interval.** A cheaper poll is a cheaper symptom.

## More Information

* [`0025-MADR-unaccounted-host-side-work.md`](0025-MADR-unaccounted-host-side-work.md) — finding **C4**, the measurement this record starts from, and **C3**, which introduced the ceiling H2 implicates.
* [`0022-MADR-git-gh-glab-engine-debug-audit.md`](0022-MADR-git-gh-glab-engine-debug-audit.md) — **M5**, the orphaned-watcher mechanism behind H3.
* `lib/core/git/watch_lifecycle.dart` — the engine: `start()` `:218`, `startPolling()` `:145`, `scheduleRestart` `:174`, `teardownWatcher()` `:163`.
* `lib/core/git/remote_watch_service.dart` — the remote arm: ceiling `:270`, slot reservation `:282`, armed teardown `:441`.
