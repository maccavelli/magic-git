---
status: "accepted"
date: 2026-09-09
decision-makers: [Maintainer]
consulted: []
informed: [Magic Git contributors]
verified: 2026-09-09
---

# Six process-global singletons outlived the single-session assumption they were written under, three control heuristics measure the wrong signal, and three hot paths are running the wrong algorithm

## Context and Problem Statement

This is an audit of the machinery underneath the features: the executor seam and
its schedulers, the SSH session lifecycle, the caches, the state that crosses
tabs and windows, and the closed-loop controllers that decide how much work the
app is willing to do at once. It was asked for as a hunt for defects, gaps,
missing wiring, stability hardening, and — specifically — for places where a
*heuristic* is doing a job an *algorithm* should be doing.

The cheap signals say nothing is wrong, and that is the point of writing this
down. `flutter analyze` is clean, 403 test files pass, there is not a single
`TODO` or `FIXME` in `lib/`, and almost every construct examined here carries a
doc comment explaining precisely why it is the way it is. The findings below are
not sloppiness. They are of three kinds, and each kind has its own smell:

* **A precondition that was true when it was written and is not true now.**
  Six pieces of process-global state were designed under "the app holds one
  session at a time". Multi-tab (`11689cc`, 2026-07-12) made that false —
  every tab is its own root `ProviderContainer` with its own live connection
  (`tabs_controller.dart:96`) — and six globals did not follow. One of them
  (`ScopedAccess`, `scoped_access.dart:20-33`) *did* follow, and is refcounted
  per path precisely for this reason. That contrast is the evidence that this
  is drift, not design.
* **A controller that cannot observe the thing it controls.** Two of the three
  heuristics below fail the same way MADR 0024 A2 described when it replaced
  the RTT-banded read cap: the signal being measured is not the signal the
  control law needs, so the loop is stable and confident and wrong.
* **A shape that costs more than the operation it implements.** Three hot paths
  do work proportional to something they do not need to be proportional to.

Each finding names file and line and says how it was established: **traced by
reading** (the control flow is followed and the conclusion is forced by it),
**proven by search** (a claim about what does or does not call something,
verified exhaustively), or **measured**. Where a defect needs a condition to
bite, that condition is stated, and where something mitigates it, that is stated
too — several of these are narrower than they first look, and a finding that
overstates its blast radius is worse than no finding.

Line numbers are as of `dc78436`.

Note on method: `lib/core/providers/app_providers.dart` contains bytes that make
`grep`/`rg` classify it as binary and silently return zero matches. Every search
claim below about that file was re-run with `grep -a`. Two claims in this
document changed after that re-run — `CommandTelemetry.reset()` appeared to have
no production caller at all until the binary-safe search found three
(F5) — so the caveat in `AGENTS.md` is load-bearing for audit work, not just
for feature work.

## Part A — Defects and gaps

### F1 — The eleven diff/blame/log caches are process-global, so any tab's connect empties every other tab's cache *(highest)*

**Traced by reading.** The eleven `KeepAliveLru` instances
(`app_providers.dart:4948-5010`) are top-level `final` variables: one set for the
whole process. `clearHashKeyedRepoCaches()` (`app_providers.dart:3131`) closes
every held `KeepAliveLink` in all eleven, and it is called from
`ConnectionController._invalidateRepoState()` (`app_providers.dart:1090`), which
runs in the tab's *own* container on **every connect attempt**
(`app_providers.dart:1356`), every backend switch (`:1876`), every repo switch
(`:2392`), provisioning (`:2604`), finalize (`:2825`) and disconnect (`:2914`).

Within one tab this is correct and costs nothing: the same method has just
`ref.invalidate`d every one of those families, so the cached values are gone
anyway and closing their links is bookkeeping hygiene. Across tabs it is neither.
`ref.invalidate` reaches only the calling tab's container; `clearHashKeyedRepoCaches`
reaches all of them. So a reconnect in tab A unpins tab B's and tab C's entire
browsing cache — up to 256 MiB of commit patches the tier comment
(`app_providers.dart:4938-4944`) explicitly describes as "cached hard: browsing
history stays instant for the whole session". On a flaky link, auto-reconnect
does this repeatedly.

The severity is bounded by what the link actually pins: those providers
autoDispose once unwatched, so the loss is realised the next time the user
returns to a pane they had already visited, as a re-fetch over SSH rather than
as wrong data. Nothing is *corrupted* by this. It is a performance cliff
triggered by an unrelated tab.

### F2 — A key collision between two tabs orphans a `KeepAliveLink` that is never closed and never accounted for

**Traced by reading.** `KeepAliveLru.touch` (`keep_alive_lru.dart:67`) *drops*
the link it replaces rather than closing it, and its doc comment justifies that
at length: a second `touch` for the same key means that provider rebuilt, the
old link is already void, and closing it tears down the freshly-built element —
the permanent-spinner bug described at `keep_alive_lru.dart:44-64`. That
reasoning is exactly right **within one container**, and the choice must not be
reverted.

It does not hold across containers. Tab dedupe is on
`(connectionId, repoPath, savedKind)` (`tabs_controller.dart`, `_find`), so two
tabs on *different saved connections* that resolve the same `repoPath` — two
saved entries for the same server, or two hosts that both mount a repo at the
same conventional path, the collision `_invalidateRepoState`'s own comment
(`app_providers.dart:1094-1099`) calls out for the mutation tracker — produce
identical LRU keys. Then:

* tab B's `touch` drops tab A's link without closing it. That element stays
  keep-alive-pinned in tab A's container for the life of the tab, holding its
  payload, invisible to both the count cap and the byte budget;
* tab A's `reportSize` (`keep_alive_lru.dart:83`) charges A's payload size
  against B's entry, and if A's payload exceeds `maxEntryBytes` it calls
  `_evict` — closing **B's** link;
* tab A's *failed* fetch runs `onError: (_) => lru.evict(key)`
  (e.g. `app_providers.dart:5100-5116`), closing B's *successful* entry.

No wrong content is ever served — Riverpod caches values per container — so this
is a leak and a mis-accounting, not a correctness bug. But it is unbounded in
the number of orphans over a long session, and the byte budget that exists to
stop these caches growing without limit cannot see them.

### F3 — Ad-hoc session workspace preferences are stored in one global map that any tab's connect clears

**Proven by search.** `clearSessionRepositoryWorkspacePrefs()`
(`repository_workspace_prefs.dart:406`) and `clearSessionBranchWorkspacePrefs()`
(`branch_workspace_prefs.dart:151`) are unconditional `.clear()` calls on
process-global maps (`:403` and `:148`). Both are called from
`_invalidateRepoState` (`app_providers.dart:1091-1092`), i.e. on every connect
attempt in any tab.

For an ad-hoc (unsaved) connection these maps *are* the storage — nothing is
written to `SharedPreferences` (`repository_workspace_prefs.dart:424-447`). So a
reconnect in tab A discards tab B's navigator width, toolbar slots, pinned
branches and collapsed sections, and tab B's layout visibly resets under the
user with no action of theirs.

The fix is unusually cheap because the keys are already scoped correctly:
`RepositoryUiIdentity.memoryKey` is `scopeKey + NUL + gitCommonDir` with
`scopeKey` of the form `adhoc:<backend>:<sessionEpoch>`
(`repository_ui_identity.dart:121-122`, `:88-105`). A prefix-scoped removal for
the departing session is a strictly correct replacement for the global clear.

### F4 — The watcher ceiling is one budget for the whole process, and the test that was supposed to notice cannot

**Proven by search, and traced by reading.** `RemoteWatchService._liveWatchers`
(`remote_watch_service.dart:223`) is `static`, and `maxConcurrentWatchers = 2`
(`:151`) is checked against it at `:351`. The doc comment at `:143-150` states
the precondition plainly:

> This reads as "per connection" too, but only because the app holds **one
> connection at a time** (`connectionProvider` is a plain notifier, not a
> family). […] If simultaneous connections to different hosts ever land, the
> counter must be keyed by host or one host's watchers will starve another's;
> `watch_ceiling_recovery_test.dart` pins the assumption so that change cannot
> pass unnoticed.

That comment was written on 2026-09-04 (`854d7a0`). Multi-tab landed on
2026-07-12 (`11689cc`). The precondition was already false when the comment was
written: `connectionProvider` is indeed not a family, but there are up to eight
of it, one per tab container (`tabs_controller.dart:107`, `:96`).

The named guard does not detect this. `watch_ceiling_recovery_test.dart:110-140`
asserts only that *two service instances share one ceiling* — which is the
property the static counter exists to provide, and which stays true. Nothing in
it fails when two **hosts** share one ceiling. This is a check that has only
ever been observed passing in the configuration it was not written for.

Two things bound the severity, and both should be stated. Only the active tab's
`AppShell` is mounted (`tabs_host.dart`, `KeyedSubtree(key: ValueKey(activeId))`),
so an inactive tab's `repoWatchProvider` autoDisposes and gives its slot back.
But a pop-out window holds its pinned tab's watcher open regardless of which tab
is active — `WindowManagerBridge` subscribes on that tab's container
(`window_manager_bridge.dart:354`) — so concurrent cross-tab watchers are
reachable, not hypothetical. When the ceiling binds, the losing repo degrades to
polling, which MADR 0026 measured at **48 git processes per minute** for a
single polling repo (`watch_diagnostics.dart:4-10`). The budget protects a
*host* from process accumulation; keyed globally it also lets one host's watchers
starve a second host that has spent nothing.

### F5 — Session telemetry is a process-global singleton reset by whichever tab connects last

**Proven by search** (with `grep -a`; the plain search missed all three call
sites). `CommandTelemetry.instance` (`command_telemetry.dart:73`) is recorded
into by both executors in every container, and `reset()` (`:250`) — documented
as "called when a new session connects, so the dashboard describes the current
connection" — is called from `ConnectionController` at
`app_providers.dart:1324`, `:1822` and `:2611`.

With tabs, the Dashboard's "this session" figures are the *union* of every tab's
commands, truncated at whichever tab connected most recently. Latency
percentiles mix hosts; `countsByLabel` — the counter MADR 0025 Finding B added
specifically to answer "which commands did that gesture cause" — attributes one
tab's refresh storm to another tab's session; `_peakOpenStreams` counts streams
across hosts. This is a diagnostic instrument giving a confidently wrong reading,
which is worse than not having it, because the next audit will trust it.

### F6 — Own-mutation suppression is held for the entire duration of a background fetch, and suppressed ticks are dropped rather than deferred

**Traced by reading.** `OwnMutationTracker.isRecent`
(`app_providers.dart:2995-2999`) returns `true` unconditionally while an
operation is in flight, and `withOwnMutation` (`:3011-3025`) wraps the whole
`git fetch` — both the 5-minute auto-fetch timer (`:3514-3517`, default
`autoFetchMinutes = 5`, `app_settings.dart:115`) and `fetchInBackground`
(`:1238`). Its three consumers — the Repository view
(`repo_status_view.dart:1487`), History (`history_view.dart:1276`) and the
secondary window (`secondary_window_main.dart:809`) — respond by `return`ing
from the watch listener: the tick is discarded.

So for as long as a fetch runs — a large pack over SSH can occupy tens of
seconds, and the ceiling is minutes — **every** watcher tick for that repo is
dropped, including genuinely external ones: a teammate's push landing on the
host, or the user's own `git commit` in a terminal. The code's defence is at
`repo_status_view.dart:1482-1484`: "A genuinely external change either lands
outside this window or is caught by the very next real tick." The first half is
what fails during a long fetch, and the second half assumes another tick is
coming. If the external change was the last event in the burst, none is: the app
shows stale state until the user presses ⌘R.

The suppression itself is right — the redundant second `git status` it prevents
is real. What is wrong is that it *drops* rather than *defers*, and that
in-flight suppression is unbounded by the window it is nominally scoped to.

## Part B — Three heuristics to improve

### H1 — The adaptive read-concurrency gradient is confounded by command heterogeneity, not queueing

**Traced by reading.** `AdaptiveReadConcurrency` estimates queueing as
`gradient = minRtt / currentRtt` over completed read-lane durations
(`adaptive_read_concurrency.dart:110-176`), stepping the cap down below `0.70`
and up above `0.90`, with an EWMA of `alpha = 0.2` (~14 samples of memory). The
samples are fed from `ssh_command_executor.dart:831`, timed by the stopwatch
started in `_runBody` — service time, correctly excluding queue time.

The problem is the population, not the law. Everything on the read lane is fed
into one distribution, and that lane spans at least three orders of magnitude of
legitimate work:

* `git rev-parse` / `cat-file` — roughly one RTT;
* `glab api` / `gh api` calls, with 20 s timeouts (`glab_service.dart:63`, `:119`,
  `:188`, `:1092`);
* `_branchReviewBatch` — up to 100 `git rev-list` walks in one command, with a
  60 s timeout (`git_service.dart:3484`, `:3546-3561`), on `ExecLane.read`.

`minRtt` is therefore anchored by the cheapest command the session has issued,
and `currentRtt` by whatever mix is running now. Opening the Branches tab on a
500-ref repo produces samples one to two orders of magnitude above `minRtt`;
the gradient collapses far below `shrinkBelow`, and after
`consecutiveRequired = 3` such samples the controller sheds read concurrency —
precisely during the one gesture in the app that most needs parallel reads. A
link that is perfectly healthy is throttled because the user asked an expensive
question. This is MADR 0024's own diagnosis of the RTT-banded predecessor
("the controller was structurally unable to observe the load it existed to
shed") in a new form: it now observes *something*, but not congestion.

**Improvement.** Keep the gradient law; fix the population. `CommandTelemetry`
already normalises commands into buckets (`bucketLabel`,
`command_telemetry.dart:102-111`), and the raw label is already computed on the
hot path (`ssh_command_executor.dart:887`). Hold `minRtt` per bucket and compute
the gradient as the sample's ratio to *its own bucket's* best, so a slow
`rev-list` batch is compared against other `rev-list` batches. A bucket with too
few samples contributes nothing rather than noise. This is a strictly smaller
change than it sounds — one map keyed by an existing function — and it is the
difference between measuring the link and measuring the user's last click.

### H2 — Suppressed watcher ticks should be deferred and re-evaluated, not discarded

**Follows from F6.** The current heuristic answers "is this tick probably mine?"
with a time window and a boolean, and acts on `true` by throwing information
away. Two changes make it lossless without giving up what it buys:

* **Defer instead of drop.** When a tick is suppressed, set a pending flag and
  arm a single one-shot timer for the remainder of the window; on expiry, run
  exactly one refresh. Cost: at most one extra `git status` per suppression
  window, which is the same order as what the suppression saves. Benefit: an
  external change can no longer be lost, only delayed by at most the window.
* **Bound in-flight suppression.** Suppress for `min(window, remaining
  operation time)` rather than for the whole operation, so a multi-minute fetch
  cannot blind the app for multiple minutes. A fetch mutates refs, not the work
  tree, so an external work-tree change during one is not plausibly the fetch's
  own echo anyway.

A stronger form is available later and worth naming: the app knows the HEAD OID
it produced, so a suppressed tick can be *verified* rather than timed — if the
post-tick status differs from the state this app's own mutation produced, it was
external by construction. That removes the heuristic entirely; the two changes
above are the cheap correct version of it.

### H3 — The channel-open error floor recovers on a fixed success count, with no memory of repeated failures

**Traced by reading.** `onChannelOpenError()`
(`adaptive_read_concurrency.dart:180-189`) drops an independent error floor by
one — correct, `MaxSessions` is a cliff, not a gradient. Recovery is
`onSuccess()` (`:191-203`): after `consecutiveRequired = 3` successes the floor
rises one step. But `onSuccess()` is called for **every** lane's success
(`ssh_command_executor.dart:827`, outside the `lane == ExecLane.read` guard on
the very next line), and reads complete constantly, so on a busy session the
floor is restored within a fraction of a second of being lowered.

Against a host with a genuinely hard limit — `MaxSessions 1..2`, an SSH gateway,
a rate limiter — this oscillates indefinitely: three successes, floor up, open
error, floor down, three successes. Each cycle costs a failed channel open,
which the executor also counts as a transport error and surfaces on the
Dashboard (`command_telemetry.dart`, `recordChannelOpenError`). The controller
has no memory that it has been burned here before.

**Improvement.** Make the floor a circuit breaker rather than a counter: after
each channel-open error, require the floor to *hold* for a dwell time that
increases with the number of recent errors (e.g. 30 s, 2 min, 8 min, capped),
resetting the dwell after a long clean period. Additionally, count only
read-lane successes toward recovery — an exclusive commit says nothing about how
many parallel channels the host will grant, which is the same argument
`ssh_command_executor.dart:828-831` already makes for the *sample* path and
which the *success* path does not follow.

## Part C — Three algorithms to implement or improve

### A1 — Branch divergence is O(branches × history) and git offers a single-walk primitive

**Measured by reading the emitted script.** `branchReviewSummaries`
(`git_service.dart:3489`) batches 100 branches per host command, which bounds
*round trips* well. But the script it sends (`:3546-3561`) loops in shell and
runs one `git rev-list --left-right --count "$base...$oid"` **per branch**. For
the 500-ref fixture that is 500 process spawns and 500 independent revision
walks; the SSH round trips were the cheap part.

Git ≥ 2.41 computes exactly this for every ref in one walk:
`git for-each-ref --format='%(refname)%(ahead-behind:<base>)'`, which shares a
single traversal across all refs and uses generation numbers from the
commit-graph file when present. The app already parses `for-each-ref` formats
everywhere (`AGENTS.md`, "Parse only machine formats"), so the output side is
existing shape.

~~The capability signal is already collected and, at present, only ever
*displayed*. `EnvironmentProbe` records per-binary versions off the connect
critical path (`environment_probe.dart:149-187`) and `RemoteEnvironment.versionOf`
exposes them, but the only three consumers are `tool_health.dart:44`,
`environment_health_sheet.dart:82` and `dashboard_sheet.dart:663` — all of them
rendering a version string to a human. **No code path in the app selects a faster
implementation based on the host's git version.** That is the missing wiring; A1
is its first customer, and `mergeTreePreview`'s "Requires Git ≥ 2.38 — callers
must gate capability first" (`git_service.dart:3836`) shows the pattern already
exists as prose waiting for a mechanism.~~ — **wrong; see amendment 0039.2.**

#### Amendment 0039.2 — 2026-09-09: the capability gate already exists, and A1 should follow it rather than invent one

Recorded while writing the plan, before any approval or code change.

The struck paragraph above claims `versionOf` has three consumers, all cosmetic,
and that nothing gates a code path on the host's git version. There is a fourth
consumer and it is not cosmetic: `mergePreviewCapabilityProvider`
(`app_providers.dart:4181-4204`) reads `env.versionOf('git')` through the pure
mapping `mergePreviewCapabilityForVersion` (`:4165`) against
`const ToolVersion kMergeTreeMinGit = ToolVersion(2, 38)` (`:4160`), falls back to
one on-demand git-only probe when no version has landed, and is what decides
whether `merge-tree --write-tree` runs at all. The prose at `git_service.dart:3836`
is not waiting for a mechanism — it is describing one that shipped.

**How the error was made is worth keeping.** The claim rested on
`grep -rn 'versionOf(' lib`, which returned three hits. `app_providers.dart` is
the file this record's own method note says `grep` classifies as binary and
silently skips; the binary-safe `grep -ran` returns five. The record warned about
exactly this trap and then fell into it one section later. Re-run every negative
search claim in this document with `-a` before relying on it.

This makes A1 **smaller and lower-risk**, not larger. The plan no longer
introduces a `GitCapabilities` class, a `gitCapabilitiesProvider`, or a capability
closure threaded through `GitService`'s constructor — all of which would have been
a second, parallel mechanism for a question the codebase already answers. It adds
one `ToolVersion` constant and one pure mapping function beside the existing pair,
and passes a plain `bool` into `branchReviewSummaries`. `gitServiceProvider` is not
touched at all, which also removes the rebuild-storm hazard that design carried.

The decision to do A1 is unchanged.

Keep the existing batch script as the fallback for older hosts; it is correct
and should not be deleted.

### A2 — Commit-graph lane layout is recomputed from scratch on every page of history

**Traced by reading.** `CommitGraph.build` (`commit_graph.dart:67-276`) is
linear in commits and correct. `_graphFor` (`history_view.dart:509-526`)
memoises on list *identity*, and above 2,000 commits
(`_graphIsolateThreshold`, `:494`) moves the build to `Isolate.run`
(`:529-542`) so the frame never blocks — all good.

But paging appends: each new page produces a new list instance, so every page
re-lays-out the entire loaded history and pays a full `Isolate.run` copy of *N*
commits in and *N* rows (each with one `GraphEdge` per occupied lane) back. Ten
pages of 2,000 is ten builds of a growing prefix — quadratic in total work and
in copied bytes, for a result whose first *N* rows are bit-identical every time.

The lane algorithm is append-friendly by construction: the only state carried
between rows is `lanes`, `waiting` and `freeLanes` (`:90-96`). Snapshotting that
at the end of a build and resuming from it makes an appended page cost O(page)
instead of O(total), and lets the isolate hop carry only the new page. Two
constraints must be respected and are worth stating so an implementer does not
discover them late: `primaryChain` is derived from the whole list up front
(`:81-89`) and would need extending rather than recomputing, and `laneCount` is
a running maximum (`:270`) that only ever grows — which is also why one messy
region of history permanently widens the gutter for the whole view, a smaller
issue worth fixing in the same pass.

#### Amendment 0039.1 — 2026-09-09: A2's carried state is larger than this record claimed

Recorded while writing the plan, before any approval or code change.

The paragraph above states that "the only state carried between rows is `lanes`,
`waiting` and `freeLanes`". That is wrong, and the omission is the one that
matters. `CommitGraph.build` also consults `allHashes` — the set of *every*
commit in the list — at `commit_graph.dart:186`, to decide whether a parent is
inside the loaded history (reserve a waiting lane) or beyond its boundary (draw
a stub edge without reserving, the case the same comment says "previously leaked
O(N) lanes").

`allHashes` is not append-invariant. A parent that is beyond the boundary while
only page 1 is loaded is *inside* the history once page 2 arrives, so the rows
near a page boundary legitimately change when the next page lands. A naive
resume-from-saved-state would freeze those rows as stubs and diverge from the
from-scratch layout — silently, and only on the rows a user is looking at when
they page.

This does not change the decision to do A2, and it does not affect any other
finding. It does change A2's design and its risk: the plan carries a
recompute-from-index alongside the lane state so the affected tail is rebuilt,
and a differential test against the from-scratch layout is a precondition for
the phase rather than a nicety. A2 is correspondingly the last and the most
droppable phase of the plan.

### A3 — Cache eviction is recency-only, over entries whose refetch costs differ by three orders of magnitude

**Traced by reading.** `KeepAliveLru` evicts strictly least-recently-used, under
a count cap and a byte budget (`keep_alive_lru.dart:67-105`). Both bounds are
about *size*. Neither is about *cost*, and over SSH those are very different
questions: a 2 KB `diffFile` is one round trip, while a 12 MiB commit patch on a
high-latency link is seconds of transfer the user watches. Recency-only eviction
will happily discard the expensive entry to keep a cheap one that was touched
more recently, which is the opposite of what a cache on a slow link is for.

The missing input is already being measured. Every command's duration and byte
count is recorded on the executor hot path
(`ssh_command_executor.dart:889-903`, `command_telemetry.dart`), so the cost of
having fetched each entry is known at the moment `reportSize` is called.

**Improvement.** Replace pure LRU with a cost-aware policy of the
Greedy-Dual-Size-Frequency family: give each entry a value
`recency + hits × (fetchCost / size)` and evict the minimum. It degenerates to
LRU when costs are uniform (so nothing regresses on a local repo, where
`LocalCommandExecutor` makes every fetch cheap and the policy correctly stops
caring), and it is bounded work per eviction with a heap. The tiering comment
at `app_providers.dart:4936-4947` already reasons in exactly these terms
informally — "immutable tier … cached hard", "worktree tier … still worth real
capacity" — so this is making an existing intuition into a measured quantity
rather than introducing a new idea.

## Considered Options

* **Do nothing.** Record the findings and leave the code as it is.
* **Fix each finding where it sits, individually and independently.** Six
  point-fixes, three heuristic tweaks, three algorithm swaps, no shared
  structure.
* **Adopt a session-scope seam for process-global state, then take the
  heuristic and algorithm work as a phased backlog on top of it.** Give the
  process-global singletons an explicit owning-session key (the concept
  `RepositoryUiIdentity` and `ScopedAccess` already implement in two places),
  make "clear my session's entries" a first-class operation distinct from
  "clear everything", and enforce the distinction with a test rather than a
  comment.
* **Serialise the app back down to one session.** Remove or disable multi-tab so
  the original preconditions become true again.

## Decision Outcome

Chosen option: **"Adopt a session-scope seam for process-global state, then take
the heuristic and algorithm work as a phased backlog on top of it."**

F1 through F5 are one defect wearing five costumes: a global whose contract says
"the current session" in a process that now holds up to eight. Fixing them
individually would produce five different ad-hoc scoping schemes and no way to
stop the sixth from being written next month — and F4 is proof that a comment
naming the precondition is not sufficient protection, because that comment was
written *after* the precondition had already been broken and its named guard
could not see it. This repo's own standing rule applies: a convention needs a
failing test, not a paragraph. The seam is what a test can be written against.

F6, H1, H2 and H3 are deliberately kept in the same record rather than split out,
because they share a root: a signal is being used as a proxy for the thing it is
correlated with rather than the thing itself — elapsed time as a proxy for "this
event is mine", one lane's mixed durations as a proxy for congestion, a success
count as a proxy for a host's capacity. Each fix replaces the proxy with either
the real quantity or a properly-conditioned estimate of it, and the second and
third of those are cheap because the conditioning data is already being
collected.

A1, A2 and A3 are independent of the above and of each other, and are ordered by
expected benefit per unit of risk: A1 is the largest measurable win and the
lowest risk (a capability-gated fast path with the existing implementation
retained as fallback); A2 is contained within one widget's memoisation; A3
changes a policy that is currently invisible to correctness.

"Do nothing" is rejected on F3 and F6, which are user-visible today. "Fix each
finding individually" is rejected for the reason above. "Serialise back to one
session" is rejected outright: multi-tab is a shipped, load-bearing feature and
the globals are the thing that is wrong, not the tabs.

### Consequences

* Good, because the five scoping defects get one mechanism and one enforcement
  point instead of five, and a seventh global written next month fails a test
  instead of shipping.
* Good, because H1 and H3 make the adaptive read controller respond to the host
  rather than to the user's last gesture, which is the only way its cap can be
  raised with confidence later.
* Good, because A1's capability gate gives the app its first consumer of the
  version data it has been probing and discarding, which unlocks the same
  pattern for `merge-tree` and anything else that has a modern fast path.
* Neutral, because none of this changes any user-facing surface. Every fix here
  is behavioural correctness or throughput; nothing new appears in the UI.
* Bad, because scoping the caches per session reduces sharing: two tabs on the
  same host genuinely could have shared a cached commit patch, and after this
  they will not. This is the right trade — the sharing was accidental, the
  interference was not — but it should be recorded as a real cost, and the byte
  budget should be reviewed as a *per-session* budget rather than silently
  becoming eight times larger in aggregate.
* Bad, because A2 introduces incremental state into a function that is currently
  pure and trivially testable, and incremental layout is exactly where
  off-by-one lane bugs live. It should carry a differential test that asserts an
  incrementally-built graph is identical to a from-scratch one over a corpus of
  real histories, and that test should be seen to fail before it is trusted.
* Bad, because H2's defer-instead-of-drop adds one timer per suppressed tick and
  therefore a small, bounded increase in `git status` traffic — the exact cost
  the suppression was added to avoid. The bound (one refresh per window) is what
  makes it acceptable, and it should be stated as an acceptance criterion, not
  assumed.

### Confirmation

This MADR is confirmed by the plan that follows it
(`0039-PLAN-process-global-state-and-control-heuristics-audit.md`, not yet
written), and specifically by these being demonstrable rather than argued:

* **F1–F5** — a test that builds two `ProviderContainer`s, drives a connect in
  the first, and asserts the second's cache entries, session prefs, watcher slot
  and telemetry are untouched. Each of these must be seen to fail against the
  current tree before the fix lands; F4's must fail in the *two-hosts*
  configuration specifically, since the existing
  `watch_ceiling_recovery_test.dart` already passes in the two-instances one and
  is not evidence.
* **F6/H2** — a test that holds an operation in flight, delivers an external
  tick, and asserts a refresh happens within the window rather than never.
* **H1** — a test that feeds a realistic mixed workload (many cheap reads, a
  burst of `rev-list`-batch-sized reads) and asserts the cap does **not** drop,
  paired with one that feeds uniformly inflated durations and asserts it does.
  The second is what proves the controller still works at all.
* **H3** — a test that alternates channel-open errors with success bursts and
  asserts the floor does not oscillate.
* **A1** — a command-count assertion in the style of
  `branches_phase7_command_budget_test.dart`, plus a wall-clock comparison on
  the 500-ref fixture. The fallback path must retain its existing coverage.
* **A2** — the differential test described under Consequences.
* **A3** — a policy test over synthetic cost/size distributions asserting the
  expensive entry survives, and asserting the policy reduces to LRU when costs
  are uniform.

Nothing above should be reported as verified on the strength of a passing run
alone; per this repo's standing rule, each new check is trusted only once it has
been observed failing against a deliberately broken input, in a scratch copy.

### More Information

* MADR 0024 (`0024-MADR-ssh-and-remote-repo-engine-debug-audit.md`) — A2 replaced
  the RTT-banded read cap with the gradient controller H1 corrects; its
  reasoning about a controller that cannot observe its own load is the direct
  ancestor of H1.
* MADR 0025 (`0025-MADR-unaccounted-host-side-work.md`) — Finding B introduced
  `countsByLabel`, the telemetry F5 shows is now cross-contaminated; C3 is the
  19-orphaned-watchers measurement the F4 ceiling exists to prevent.
* MADR 0026 (`0026-MADR-degraded-watch-poll-diagnosis.md`) — the 48-git-processes-
  per-minute measurement that sets the cost of the polling fallback F4 forces.
* MADR 0028 (`0028-MADR-ceiling-refusal-and-teardown-residue.md`), amendment
  0028.1 — where the "one connection at a time" wording F4 refutes was recorded.
* `11689cc` (2026-07-12) — multi-tab with per-tab provider containers, the change
  that invalidated the preconditions behind F1–F5.
* `lib/core/local/scoped_access.dart` — the one process-global that *was* made
  multi-session-safe, and the model for the seam this record proposes.
