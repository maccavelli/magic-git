---
status: "proposed"
date: 2026-09-04
decision-makers: [Maintainer]
consulted: []
informed: [Magic Git contributors]
verified: 2026-09-04
---

# Treat unaccounted host-side work as one workstream: leaked watchers and refresh amplification

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

In scope: the lifetime of host-side processes the app starts, and the volume of
commands one user gesture causes.

Out of scope: transport correctness (0024 closed that), the perceived-freeze
work (0023 shipped it), and anything requiring a change to how the forge CLIs
themselves behave.

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

No code changes accompany this record. Implementation waits on
`0025-PLAN-unaccounted-host-side-work.md` and explicit approval.

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

## Confirmation

This record is confirmed when `0025-PLAN-unaccounted-host-side-work.md` exists
that, for each finding:

1. names the files and lines it touches;
2. names the negative test and records its **observed** failure text against
   the unfixed tree;
3. states the live-host confirmation, since **neither finding may be closed on
   a unit test** — A needs a real dropped TCP, B needs the real provider graph;
4. and, for B, completes attribution **before** proposing a behavioural change.

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
