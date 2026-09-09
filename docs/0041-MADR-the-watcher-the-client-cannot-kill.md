---
status: "proposed"
date: 2026-09-09
decision-makers: [Maintainer]
consulted: []
informed: [Magic Git contributors]
verified: 2026-09-09
---

# The client cannot kill the watcher it started, so the ceiling of two was never a policy — it was the only bound on a teardown that never reaches the host

## Context and Problem Statement

[MADR 0040](0040-MADR-the-watcher-ceiling-is-the-wrong-limit.md) established
that `maxConcurrentWatchers = 2` is four times tighter than the transport budget
it stands in front of, and shipped three phases to correct it. Phase 1 (a
structural slot release) held. Phases 2 and 3 were reverted the same day, on
`370b2b8` and `22270f4`, after a rebuilt session appeared to show the host
accumulating watchers per repository — recorded as amendment 0040.2, which
closes with "the remaining candidate, unproven, is more than one *engine* per
repository in one container".

The maintainer's questions, in their words:

> why did they have to revert? what is the real robust, hardened solution? how
> can we optimize this functionality? what is idiomatic best practice?

This record answers all four from runtime measurement on the reporting host and
from the code as it stands after the revert. Every number below was measured
during this session; nothing is inferred from the earlier reports.

**The short answer, ahead of the evidence.** The revert was necessary, but not
for the reason amendment 0040.2 gives. The number that triggered it overstates
live watchers by about three times (F3) and the per-repository counts were
registry files, not concurrent watchers (F4) — so the app was very likely
behaving correctly. What phase 2 actually did, and what genuinely justifies the
revert, is remove the only *host-wide* bound in the system (F5) at a moment when
its intended replacement — the lease — has a reclaim latency of up to six
minutes (F2). And the reason the lease is the only reclaim mechanism at all is
the finding underneath everything else: **a teardown on the client does not
reach the process on the host** (F1). It is proven here, on the same bastion,
with the same shell.

## Findings

### F1 — Nothing the client does at teardown reaches the watcher process. Proven on the host.

`WatchArmed`'s teardown closes the SSH channel and nothing else:

```dart
// lib/core/git/remote_watch_service.dart:620
return WatchArmed(() async {
  releaseSlot();
  heartbeatTimer?.cancel();
  …
  await handle.cancel();          // -> killAndCloseSession
});
```

`killAndCloseSession` (`lib/core/ssh/ssh_command_executor.dart:1159`) sends
`session.kill(SSHSignal.TERM)` then `session.close()`. In dartssh2 3.3.0
`kill()` is `_channel.sendSignal(...)` — the RFC 4254 §6.9 `"signal"` channel
request — and the package's own doc comment is explicit: *"Deliver signal to the
remote process. Some implementations may not support this."* OpenSSH's `sshd` is
one of those implementations; it has never implemented receipt of `"signal"`.
The channel close that follows closes the remote end's pipes, which a process
blocked in `select()` never notices, because it never writes and so never takes
`EPIPE`. That is 0025 A's finding, and it is why the lease loop exists at all.

There is no host-side cleanup on the teardown path: no `kill` by recorded pid,
no `rm` of the pid or heartbeat file. Grep the file — the only writer of those
paths at teardown is nobody.

**Measured, not deduced.** A probe reproducing the exact lease-loop shape
(`{ payload; } & c=$!; wait "$c"` under a `trap` and a `while :`) was started
over SSH; the client was then killed with `SIGKILL`. Five seconds later, on the
host:

```text
428148 sh -c c=; trap "…" TERM INT HUP; while :; do { <payload> ; } & c=$!; wait "$c"; done
432382 sh -c c=; trap "…" TERM INT HUP; while :; do { <payload> ; } & c=$!; wait "$c"; done
432383 <payload>
```

The whole tree survived. Repeated **without** the `HUP` trap, to test whether the
trap was what kept it alive: it survived that too (three processes after the
client died). So the survival is not the trap's doing — `sshd` simply does not
kill the remote process group when the connection ends. Both probes were cleaned
up; the host was verified back to zero afterwards.

The consequence is the one that matters for everything below: **the client's
slot counter tracks intent, and the host tracks reality, and after every
teardown the two disagree for as long as it takes the lease to expire.**

### F2 — The only reclaim mechanism is heartbeat staleness, bounded at about six minutes, and each cycle re-walks the whole tree

`_leaseLoop` (`lib/core/git/bounded_watch.dart:165`) checks the lease once per
iteration, and an iteration ends only when the watcher process exits:

```sh
while :; do
  [ -f $hb ] || exit 0;
  [ -n "$(find $hb -mmin -5)" ] || exit 0;
  { inotifywait -t 120 … ; } & c=$!; wait "$c";
done
```

With `wakeInterval` 2 min and `leaseStaleAfter` 5 min (the defaults, and what
`remoteWatcherArgs` passes), an abandoned watcher wakes at t+2 (lease 2 min old,
fresh — re-arm), t+4 (4 min old, fresh — re-arm), t+6 (6 min old, stale — exit).
**Up to six minutes of residue, and two full recursive re-walks paid on the way
out.**

The re-walk is not free and not silent. Live process tree on the host, one
watcher per repository:

```text
  PID    PPID  ELAPSED  COMMAND
420382  419240    13:56  sh -c … mg-watch.<tokenA>.pid …   <- lease loop
426512  420382     01:55  sh -c … mg-watch.<tokenA>.pid …   <- backgrounded subshell
426513  426512     01:55  inotifywait -t 120 -m -r …        <- the actual watcher
```

A lease loop 13 minutes 56 seconds old whose `inotifywait` child is 1 minute 55
seconds old: this watcher has re-established its entire watch set roughly seven
times in fourteen minutes. Each re-walk emits `Setting up watches. Beware: since
-r was given, this may take a while!` on stderr — the line the maintainer
pasted — and during it, changes are not observed at all.

`-t` in monitor mode means "exit after N seconds with no events", so the wake is
not even periodic: on a busy repository the loop may not iterate for a long time
(a second live watcher was observed at 3 min 57 s against a 120 s timeout), and
the lease is therefore checked at unpredictable intervals rather than every two
minutes.

### F3 — The count that triggered the revert overstates live watchers by about three times

Amendment 0040.2 records `watchers=7 → 8` over 40 seconds, measured with
`pgrep -af mg-watch | wc -l`. That command was run again during this session
against a host in a known state:

```text
422909 sh -c … <repo-B>/.git/mg-watch.<tokenB>.pid …
437683 sh -c … <repo-A>/.git/mg-watch.<tokenC>.pid …
444306 sh -c … <repo-B>/.git/mg-watch.<tokenB>.pid …
444540 sh -c … <repo-A>/.git/mg-watch.<tokenC>.pid …
444708 bash -c pgrep -af mg-watch | …

count as run: 6          distinct pid files: 2
```

**Six matches, two watchers.** Each live watcher is two matching shells — the
lease loop and the backgrounded subshell that runs `inotifywait`, which carries
an identical `argv` because `{ …; } &` forks before it execs — and the invoking
command line matches itself because it contains the string it is searching for.
`inotifywait` itself does *not* match; its `argv` has no `mg-watch` in it.

Applying that calibration, `7 → 8` is approximately `2 → 3` live watchers. With
four repositories open and a per-session cap of six, three live watchers is
under the cap and unremarkable.

This does not prove the maintainer's session was healthy — that session is gone
and cannot be re-measured. It proves the instrument reads about three times
high, so the observation it produced cannot carry the weight amendment 0040.2
put on it.

### F4 — The per-repository counts were registry files, and a re-armed repository shows two "fresh" heartbeats for five minutes by design

Amendment 0040.2's per-repository tallies (`4 · 3 · 2 · 2 · 2`) are counts of
`mg-watch.*` files, and the record reads them as concurrent watchers, adding
"every one had a fresh heartbeat — the app was actively refreshing all of them".

Captured live during this session, under the **reverted** build with the cap
back at 2:

```text
14:13:39  <repo-A>/.git/mg-watch.<tokenA>.pid     <- no live process
14:29:39  <repo-A>/.git/mg-watch.<tokenA>.hb      <- last beat, 46 s before the re-arm
14:30:25  <repo-A>/.git/mg-watch.<tokenD>.pid     <- live
14:36:25  <repo-A>/.git/mg-watch.<tokenD>.hb      <- live, beating

live tokens (from running shells): <tokenB>, <tokenD>
```

One repository, **two token pairs, one live watcher**. The dead token's
heartbeat was last touched at 14:29:39, so any staleness test of the form the
sweep and the lease both use (`find … -mmin -5`) called it *fresh* until
14:34:39 — four and a half minutes after its watcher was gone.

So "N per repo, all heartbeated" is the expected signature of N arms over a
session with litter left behind, not of N concurrent watchers. Registry files
are removed only by `sweepStaleWatchers`, which runs **at connect**, and only
once their heartbeat has gone stale. Nothing removes them during a session.

Combined with F3, the evidence that forced the revert is consistent with an app
that was working, on a host accumulating litter and residue from a defect that
predates all of MADR 0040.

### F5 — What phase 2 actually changed was not the number; it removed the only host-wide bound. This is why the revert was necessary.

Read as a number, phase 2 was 2 → `max(1, maxConcurrentStreams - 2)` = 6. Read
as a diff, it did something else as well:

```dart
-  static final Map<String, int> _liveByHost = {};
+  static final Map<(Object, String), int> _liveByHost = {};
```

The ceiling stopped being one budget for a host and became one budget **per tab,
per host**. `TabsController.maxTabs` is 8, so the host-wide bound went from
2 to as much as 8 × 6 = **48**, and — more to the point — there was no longer
any quantity in the system that bounded a host at all.

Phase 2's own doc comment named the trade and made it deliberately:

> The orphan accumulation this cap was originally introduced for … is now the
> lease's job … the host-level concern the old key served is the lease's now.

Given F1 and F2, that hand-off is to a mechanism whose reclaim latency is up to
six minutes and whose wake interval is not even periodic. Per-session keying is
right for the resource phase 2 derived from — channels do belong to a
connection — but watchers consume host resources too, and phase 2 left those
unbounded.

**That is the honest justification for the revert**, and it stands independently
of whether the multiplication was real: the change removed the only host-wide
bound while its replacement cannot bound anything on a timescale a user
notices. The cap of 2 was never much of a policy. It was the throttle on F1.

### F6 — Phase 3 reconciled in the wrong direction, at the wrong time

Phase 3 taught `watcherSweepScript` to print `LIVE <token>` for each fresh
lease, and `_reconcileSlots` to drop slots this session holds that the host did
not report:

```dart
final orphaned = held.difference(reportedLive);   // client-side over-count
```

Three limits, all structural:

* **Direction.** It corrects the client believing it holds *more* than the host
  has. The failure being chased is the opposite — host processes and registry
  files the client has already forgotten (F1, F4). Nothing in phase 3 can see
  those.
* **Timing.** `_reconcileSlots` is called only from `sweepStaleWatchers`, which
  runs at connect. Residue is produced continuously *during* a session.
* **Scope.** It is deliberately restricted to `key.$1 != _scope` — this
  session's own tokens — so it cannot observe another tab's, which is correct
  for a slot ledger and useless for a host census.

Phase 3 is a reasonable belt for phase 1's braces. It is not a bound, and it was
never going to compensate for F5.

### F7 — The ceiling is denominated in a unit that matches no scarce resource, and the resource that *is* scarce is already enforced one layer down

Measured on the host:

```text
/proc/sys/fs/inotify/max_user_watches    524288
/proc/sys/fs/inotify/max_user_instances    1024
/proc/sys/fs/inotify/max_queued_events    16384
sshd MaxSessions                          not configured (default 10)
git                                       2.48.1
```

Watch descriptors actually held by the two live watchers: **192** and **701**.
Across the 14 repositories in the working directory the total directory count is
**860** (largest 439 non-git directories; smallest 8), which matches amendment
0040.1's 858 to within the exclusions each measurement used.

So watching **every repository on this host at once** would cost about 900 of
524,288 watch descriptors (**0.17 %**) and 14 of 1,024 instances (**1.4 %**).
A cap expressed as a count of watcher *processes* is three orders of magnitude
away from the resource it is nominally protecting.

The resource that genuinely runs out is SSH channels: `sshd`'s default
`MaxSessions` of 10 per connection, which the executor already models as
`maxConcurrentStreams` (8, or 2 when the stream client has degraded) and
already enforces by refusing with the typed `SSHStreamBudgetExhausted` that the
arm handles and degrades on. **The watcher ceiling is a second, cruder guard in
front of a guard that already works.**

### F8 — Three of the four inotify excludes have never been in force, and the tool has been saying so on a channel the app reads

The recursive arm passes four flags
(`lib/core/git/remote_watch_service.dart:18`):

```text
--exclude '/\.git/objects/' --exclude '/\.git/logs/' --exclude '\.lock$' --exclude '/\.git/fsmonitor--daemon/'
```

`inotifywait --help` on the host:

> `--exclude <pattern>` … **Only the last --exclude option will be taken into
> consideration.**

Verified by experiment on the host, in a scratch directory, with two excludes
and three files:

```text
stderr:  --exclude: only the last option will be taken into consideration.
events:  ./a/one        <- FIRST --exclude '/a/'  ignored
         ./c_three
         (./b/two correctly suppressed by the LAST --exclude '/b/')
```

Only `/\.git/fsmonitor--daemon/` is in effect. The three that were added because
they matter — loose objects, reflogs, and lock files during fetch and gc — do
nothing on the inotify arm. (`fswatch` accepts repeated `--exclude` correctly,
so the fswatch arm is unaffected; the bounded scripts pass no excludes at all.)

Nothing user-visible is wrong today, because `shouldTriggerWatch` filters the
same three classes client-side. What is paid is the wire and the UI isolate: a
`git gc` or a large fetch pushes thousands of events across the SSH channel and
through the parser to be discarded on arrival — the exact burst class 0024 A1
measured at 522 ms of UI-isolate time.

And inotify-tools prints that warning on **stderr**, which
`RemoteWatchService` reads and forwards to `onDiagnostic`. The app has been
receiving a message saying its own filters are being discarded, once per arm,
immediately before the `Setting up watches. Beware…` line the maintainer
quoted.

### F9 — `--exclude` never prevents a watch being established; 37 % of this host's descriptors are spent on `.git/objects`

Even correctly combined into one pattern, `--exclude` filters **events after the
kernel has delivered them**. It does not reduce the watch set. The directory
census of the largest repository confirms it exactly:

```text
total directories        701      <- watch descriptors held by its inotifywait: 701
.git/objects              259
.git/logs                   5
work tree                 427
```

**701 directories, 701 descriptors.** `inotifywait` supports `@<path>` —
*"Exclude the specified file from being watched"* — which is a different
mechanism and the correct one. `@.git/objects @.git/logs
@.git/fsmonitor--daemon` would take this repository from 701 descriptors to
about 437 (**−37.7 %**) and remove every kernel wakeup for loose-object writes
during fetch and gc, rather than paying for them and discarding the result
twice.

### F10 — Git's own filesystem monitor is not available on Linux hosts, so the obvious "use the platform's thing" route is closed

The idiomatic answer to "watch a repository for changes" in 2026 is
`core.fsmonitor` with `git fsmonitor--daemon`: one host-managed daemon per
repository, an IPC socket, self-termination when idle, and `git status`
consuming it natively. The app already knows it exists — it excludes
`.git/fsmonitor--daemon/` from its own watches.

On the reporting host:

```text
$ git --version
git version 2.48.1
$ git fsmonitor--daemon status
fatal: fsmonitor--daemon not supported on this platform
```

Upstream still ships the daemon backend for Windows and macOS only. For a
POSIX/Linux bastion — this app's primary remote target — it is not an option,
and the bespoke watcher has to stay. Recorded so this is not re-proposed.

### F11 — Stdin EOF is the one signal that does reach the process, and it works. Verified on the same host.

The client cannot signal the remote process (F1), but it can close its standard
input, and *that* the kernel delivers unconditionally: when the channel goes —
cleanly, or because the connection dropped — the remote end of the pipe closes
and any reader gets EOF immediately.

Probe, same host, same `sh`, corrected form:

```sh
exec 3<&0                                        # save the channel's stdin
<payload> &
w=$!
( cat <&3 >/dev/null 2>&1; kill -TERM "$w" ) &   # watchdog on the SAVED fd
wait "$w"
```

* client attached → payload running;
* client killed → **whole tree gone within 5 seconds**, verified by `ps`.

Against the F1 control, where the identical tree survived indefinitely. This
turns a six-minute reclaim into a sub-second one, with no timers, no lease
polling, and no re-walk.

**The trap that must be recorded, because it cost two failed probes and would
have shipped as a mysterious instant-death bug.** POSIX requires that, with job
control disabled, the standard input of an asynchronous list is assigned to
`/dev/null` *before* any explicit redirection. So the natural spelling —
`( cat >/dev/null; kill "$w" ) &` — reads `/dev/null`, sees EOF immediately, and
kills the watcher milliseconds after it arms. That is indistinguishable from
0027 deviation (b)'s failure, where every arm died in ~5 ms and the repository
polled forever. The watchdog must read a **saved** descriptor.

dartssh2 supports this without any change: the app never writes the stream's
stdin, `_stdinController` pipes into the channel sink, and `close()` closes the
channel — so stdin stays open for the channel's life and EOFs exactly when it
ends.

### F12 — Nothing prevents two sessions from watching one repository, and per-tab keying removed the accidental brake

`TabsController.openOrFocus` dedupes on `(connectionId, repoPath)`
(`tabs_controller.dart:432`). Two tabs on the same saved connection cannot both
watch a repository. Two *different* saved connections pointing at the same host
and path can, as can a saved connection and an ad-hoc destination — and each has
its own container, its own service instance and, after phase 2, its own budget.

There is no host-side mutual exclusion. The registry is tokenised per instance
by design (0027), so it records duplicates rather than preventing them. An
atomic `mkdir` lock in the git dir — POSIX, works on macOS hosts too, unlike
`flock(1)` — would make "one watcher per repository per host" an invariant the
host enforces, rather than a property the client is trusted to maintain.

### Open question, not answered here

The live capture in F4 shows a repository re-arming at 14:30:25 with its
heartbeat only 46 seconds old — so the lease did not expire and the loop did not
exit on staleness. Something else ended that stream: a channel death, a restart,
or a provider rebuild. `watchDiagnostics` already records the transition and its
cause per repository, and the Dashboard's watcher section already reads it; the
answer is one look at that record during a re-arm, and it belongs in whichever
plan executes this. Amendment 0040.2's "more than one engine per repository"
hypothesis is neither confirmed nor refuted by anything measured here — but F3
and F4 remove the observation that motivated it.

## Considered Options

* **A — Keep the cap at 2 and change nothing else.**
* **B — Re-land phase 2 with host-wide keying only.**
* **C — Fix teardown first, then re-derive the ceiling host-wide, then fix the
  watch surface.**
* **D — Replace the bespoke watcher with a host-side agent.**

## Decision Outcome

Chosen option: **C — fix teardown first, then re-derive the ceiling host-wide,
then fix the watch surface**, because every other option either preserves the
defect (A), re-lands on top of it (B), or is a rewrite whose premise (F10) does
not hold on the target platform (D).

The ordering is the decision. The cap cannot be raised safely while a teardown
leaves up to six minutes of residue, because the cap is currently the only thing
bounding that residue (F5). Once teardown is deterministic, the cap has nothing
left to protect that is not already protected one layer down (F7), and can be
derived honestly.

Proposed as four phases, each independently revertable, in this order:

**Phase A — make teardown reach the host.** Three changes, all in
`bounded_watch.dart` and `remote_watch_service.dart`:

1. Add the stdin-EOF watchdog on a saved descriptor to `_leaseLoop`, per F11,
   so channel close kills the tree in under a second. Shared by both the
   recursive and bounded arms, and by fswatch and inotifywait alike.
2. Have the `WatchArmed` teardown remove the token's heartbeat file — one
   best-effort `rm` on the isolated lane — so the lease's own backstop collapses
   from six minutes to one wake, and no litter is left for the next connect's
   sweep to find (F4).
3. Fix `cleanup()` to signal the process group rather than `$c`, which is the
   intermediate subshell and not the watcher (F1's process tree).

The lease stays exactly as it is. It is the right mechanism for the case stdin
EOF cannot cover — a client that vanishes without the connection closing — and
it becomes a backstop instead of the primary path.

**Phase B — one watcher per repository, enforced by the host.** An atomic
`mkdir` lock in the git dir, released by the same trap, reclaimed by the same
staleness rule the sweep already applies (F12). This is what makes a raised
ceiling safe regardless of how many sessions, tabs or app instances point at one
host.

**Phase C — re-derive the ceiling, host-wide.** Re-land phase 2's derivation
(`max(1, maxConcurrentStreams - reservedStreams)`) but **keyed by host, not by
(session, host)** — that is the one substantive correction to the reverted work.
A host-wide budget derived from a per-connection resource is conservative, which
is the correct direction to be wrong in, and it keeps a bound that F5 shows must
exist. Phase 3's reconciliation is not re-landed: F6 shows it corrects the wrong
direction at the wrong time. If a reconciliation is wanted later, the useful one
is host → client (adopt or reclaim processes the client has forgotten), not
client → host.

**Phase D — fix the watch surface.** Collapse the four `--exclude` flags into
one alternation so the objects, logs and lock filters actually apply (F8), and
add `@`-path exclusions so those directories are never watched at all (F9). Then
raise the diagnostic-line handling so a warning like *"only the last option will
be taken into consideration"* is surfaced rather than buried among twenty lines
of `Setting up watches`.

Phase A alone is worth shipping if nothing else does. It is the fix for the
defect that has been present since the lease was introduced, and it is what the
maintainer's original complaint — every repository on a host polling — was
downstream of.

### On idiomatic best practice

Three principles, each of which this system currently violates and each of which
was tested here rather than asserted:

1. **A remote process must detect its client's death itself, and the portable
   way is a descriptor, not a timer.** Signals do not cross an SSH channel to
   OpenSSH (F1); timers turn a hang-up into a multi-minute leak (F2). Reading
   stdin to EOF is how every well-behaved SSH-launched helper — remote IDE
   backends, `git` over SSH, a shell pipeline — learns its peer has gone, and it
   costs nothing while the peer is alive (F11).
2. **Admission control belongs at the resource, once.** The transport already
   refuses past `maxConcurrentStreams` with a typed error the arm handles. A
   second ceiling in a different unit, several layers up, cannot be kept
   consistent with it and was three orders of magnitude off the resource it
   named (F7).
3. **Mutual exclusion for a host resource belongs on the host.** Client-side
   bookkeeping is correct only while exactly one client exists; this app has had
   up to eight since `11689cc` (F12).

### Consequences

* Good, because after Phase A the client's ledger and the host's reality agree
  within a second instead of within six minutes, which makes every count in
  every future investigation trustworthy — including the ones that produced F3
  and F4's misreading.
* Good, because Phase D removes roughly 38 % of the watch descriptors and all
  the loose-object wakeups on the largest repository measured, and stops a
  fetch's event burst crossing the wire to be discarded on arrival.
* Good, because the ordering means the cap is raised only after the thing it was
  accidentally bounding is bounded properly.
* Bad, because Phase A changes the host-side script for every watcher on every
  platform the app supports, and MADR 0029's rule applies in full: the script is
  load-bearing and must be proven by executing it, not by asserting on its text.
* Bad, because the stdin-EOF watchdog has a failure mode that presents exactly
  like 0027 deviation (b) — an arm that dies in milliseconds and polls forever —
  if the saved-descriptor detail is got wrong. It needs a test that arms a real
  watcher and observes it *survive*, not only one that observes it die.
* Neutral, because nothing here changes what the user sees until Phase C, which
  is the only phase that alters how many repositories watch rather than poll.

### Confirmation

Each phase has an observable, host-side check that can be run on the reporting
host:

* **Phase A** — arm a watcher, kill the app, and census the host after 10
  seconds: zero `mg-watch` processes and zero registry files for that repository.
  Today the same census returns a live tree for up to six minutes. The negative
  control is the F1 probe, which is already recorded above and already fails in
  the required direction.
* **Phase B** — point two sessions at one repository and confirm exactly one
  pid file and one live tree, with the loser degrading to polling and saying so.
* **Phase C** — with N repositories open on a healthy connection, confirm
  `min(N, maxConcurrentStreams - reservedStreams)` event-driven and the rest
  polling, and confirm the host-wide total does not scale with the number of
  tabs.
* **Phase D** — compare `find <repo> -type d | wc -l` against the watch
  descriptors held by the arm's `inotifywait`; before, they are equal (701/701),
  after, the second should be the first minus the `@`-excluded subtrees. And a
  fetch should no longer put `.git/objects/**` events on the wire.

Any correct-looking count must be calibrated the way F3 calibrates
`pgrep -af mg-watch`: two shells per watcher plus the query itself.

## More Information

* [0040-MADR-the-watcher-ceiling-is-the-wrong-limit.md](0040-MADR-the-watcher-ceiling-is-the-wrong-limit.md)
  — the record this one continues. Its F2, F3, F5 and F6 stand; F1 is
  incomplete as its own amendment 0040.2 says; **amendment 0040.2's reading of
  the multiplication evidence is corrected by F3 and F4 here**, and its
  conclusion (revert) is upheld for the different reason given in F5.
* [0027-MADR-watcher-reclamation-cannot-reclaim.md](0027-MADR-watcher-reclamation-cannot-reclaim.md)-era
  work introduced the per-instance token and the lease; deviation (b) there is
  the precedent for the failure mode F11 warns about.
* MADR 0025 established the orphan problem and the lease's design; its
  observation that a watcher blocked in `select()` never learns its reader is
  gone is F1 stated three records earlier, and this record supplies the proof
  and the remedy.
* MADR 0029 governs how the host scripts changed by Phases A and D must be
  tested: executed, not asserted on as text.
* Measurement environment: the reporting host, `git 2.48.1`,
  `inotify-tools 3.22.1.0`, OpenSSH with `MaxSessions` unset (default 10),
  `max_user_watches` 524288, `max_user_instances` 1024. All probes ran in
  scratch directories under `/tmp` and were removed; the app's own watchers were
  observed read-only and never signalled.
