---
status: proposed
date: 2026-08-20
verified: 2026-08-20
decision-makers: [Maintainer]
consulted: []
informed: [Magic Git contributors]
---

# Model "the transport is not ready yet" as a state, not as a failed command

## Context and Problem Statement

Reported by the maintainer against a freshly built `.app`: **on a cold connect
to a remote SSH repo, from a newly started app**, the Repository panel shows
`SSH connection not established.` and the file-view pane shows an exception —
both for a split second, then they resolve on their own.

The text is not a message anyone wrote for a user. It is
`Exception('SSH connection not established.')`, thrown by
`SSHCommandExecutor` when it is asked to run a command before a client is
attached (`ssh_command_executor.dart` ~680 in `execute`, ~1015 in
`executeStream`).

Two things are wrong, and they are independent. One is why the string is
*visible*; the other is why a command runs *at all* before the transport is
up.

### What is confirmed (2026-08-20, tree at `c755518`)

**1. The condition is untyped, so nothing can reason about it.**
Every sibling transport failure is a class — `SSHCommandTimeout`,
`SSHCommandSuperseded`, `SSHOutputExceeded`, `SSHChannelOpenError` — and
`humanizeSshError` (`ssh_error_messages.dart` ~64) maps each to copy written
for a user. A bare `Exception` matches no branch, so `displayError` falls
through to its last resort, strips the `Exception: ` prefix, and hands the
raw developer string to the pane. That is the literal text the maintainer
saw.

**2. Four lifecycle paths invalidate repo providers *before* they tell the UI
the session is gone.** `_invalidateRepoState()`
(`app_providers.dart` ~1042) invalidates every entry in
`repoScopedFetchFamilies`, which includes `statusProvider` (~2675) and
`repoStructureProvider` (~2697) — precisely the two providers the Repository
panel and the file view watch. `ref.invalidate` on a family with live
listeners refetches immediately. Where it runs relative to the state flip:

| call site | order | client alive at invalidate? |
|---|---|---|
| `connect()` ~1281 | invalidate, then `phase: connecting` ~1308 (27 lines later) | **no** on a reconnect |
| backend switch ~1764 | `disconnect()` the manager, *then* invalidate | **no** |
| provisioning ~2331 | invalidate, then flip | **no** |
| `disconnect()` ~2580 | invalidate, then `state = const ConnectionState()` | **no** |
| `openRepo()` ~2515 | invalidate, then flip | yes — wasteful, not an error |

In the four "no" rows the panes are still mounted (the shell gates on
`isConnected && repoPath != null`, `app_shell.dart` ~725/~1122) and still
listening, so the refetch lands on an executor with no client and throws.
A frame later the state flips, the panel unmounts, and the error disappears.
That is a "split second" by construction.

**3. [0017](./0017-MADR-provider-retry-policy-on-providers.md) did not cause
this, but it is why it is newly visible.** Until 0017 every provider inherited
Riverpod's default retry: a throw was followed by a silent retry ~200 ms
later, which succeeded once the client attached, and the error never reached a
frame. Turning retry off made an always-present race observable. The correct
reading is that 0017 removed the thing that was *hiding* a real bug — so the
one fix that must never be adopted here is re-enabling retry.

### What Phase 1 found (2026-08-20) — the trigger, and it is neither of the above

The reproduction (`test/transport_readiness_race_test.dart`) records every
command attempt with the phase the UI believed it was in and whether a client
was attached. On a cold connect it captures **two** attempts of the combined
status/refs snapshot, both with **no client**:

| # | phase when attempted | when |
|---|---|---|
| 1 | `disconnected` | the instant a listener subscribed — **before `connect()` was called at all** |
| 2 | `connecting` | after `_invalidateRepoState()`, before the client attached |

Attempt #1 is the answer, and it invalidates the reasoning in this record's
first draft. `statusProvider` (`app_providers.dart` ~2941) — like
`repoStructureProvider` — has **no readiness precondition whatsoever**. It
runs `git status` the moment anything listens, regardless of whether a
transport exists. The shell's `isConnected` gate governs when the *panel
mounts*; it does not govern the provider, which any listener can start,
including the tab-title watcher (`tabs_host.dart` ~39).

So the cold-connect sequence is:

1. Something subscribes to `statusProvider(repo)` with a repoPath in hand.
2. The provider immediately issues a command; no client exists; the executor
   throws; **the failure is cached as the provider's state.**
3. `connect()` runs, and `_invalidateRepoState()` refetches — still no
   client (attempt #2), caching the failure again.
4. `connected` publishes, the panel mounts, and it renders **the already-cached
   error** on its first frame.
5. A later invalidation or watcher tick refetches successfully and the error
   disappears — the "split second".

This also confirms the invalidate-before-flip inversion is real (attempt #2),
but demotes it: it is an aggravating factor, not the cause. Fixing only the
ordering would leave attempt #1 — and therefore the symptom — untouched.

### What was NOT confirmed in the first draft

The first draft of this record reasoned that a cold start could not reach the
inverted paths, because the shell only mounts the panel at `connected`. The
maintainer said it happened anyway. **The maintainer was right and the
deduction was wrong** — it confused "when the panel mounts" with "when the
provider runs". Phase 1 was written to settle that by measurement rather than
argument, and did; the result is the section above.

The lesson is recorded deliberately: a gate on *rendering* is not a gate on
*fetching*, and this codebase has no gate on the latter.

## Decision Drivers

* **A user must never read a developer string.** Whatever the trigger, the
  raw `SSH connection not established.` reaching a pane is a defect on its
  own.
* **"Not ready yet" is not "your command failed".** The two demand different
  UI (a spinner vs a red error) and different handling. Today they are the
  same untyped throw, so no layer can tell them apart.
* **Fix the ordering, do not sleep on it.** A delay, a retry, or a "wait for
  the client" loop inside the executor would hide the race rather than remove
  it — and would also hide a genuine mid-session drop, which is the same
  condition.
* **Do not re-enable provider retry.** It is what masked this for weeks.
* **Reproduce before fixing.** The repo's standing rule is root-cause fixes
  verified against real behaviour, not symptom guards. An unreproduced
  trigger is not understood.

## Considered Options

* **A. Humanize the message only.** Add a `humanizeSshError` branch so the
  pane shows friendly copy.
* **B. Make the executor wait for a client** (poll or await an attach
  future) instead of throwing.
* **C. Type the condition, render it as a loading state, and fix the
  invalidate/flip ordering** — after reproducing the cold-connect trigger.
* **D. Re-enable Riverpod retry for repo providers.**
* **E. A readiness precondition on every command, at the executor seam**,
  with an explicit timeout/short-circuit contract.

## Decision Outcome

Chosen option: **"C"**, extended after Phase 1 with the finding above.

The primary fix is **E: a transport-readiness precondition on every command**,
because Phase 1 showed the failure begins before any lifecycle path runs — a
provider issues a command with no session at all. The rest are defense in
depth for the window the gate cannot cover (a drop mid-command) and for any
future caller that reaches the executor another way.

0. **Gate the command, not the render.** A command that cannot run must not
   be issued and must not cache a failure. See *The readiness contract*
   below — this is the substance of the fix.
1. **Type it.** `SSHTransportNotReady implements Exception`, carrying the
   command, thrown at both sites. `humanizeSshError` gains a branch.
2. **Render it as a state.** The Repository panel and file view already have
   the precedent from
   [0015](./0015-MADR-ssh-engine-and-ui-unit-test-gaps.md) U5: when a forge
   login is still in flight, an auth-looking failure renders a
   `ProgressCircle` instead of a dump. A not-ready transport takes the same
   branch — it is the same category of "in progress, not broken".
3. **Flip, then invalidate.** In all four inverted paths, publish the new
   connection state *first*, so the panes unmount before their providers are
   refetched and nothing is listening to observe the throw.
4. **Pin it.** Regression tests that fail on the current behaviour.

### The readiness contract

A gate that merely blocks would trade a visible bug for an invisible stall.
The contract is therefore explicit about all four states, and about cost:

| session state | behaviour | why |
|---|---|---|
| **ready** — live client (SSH) or a connected local session | proceed immediately; **no await, no timer, no allocation** | the overwhelmingly common case; the gate must be free |
| **connect in flight** | await that attempt, bounded by `transportGrace`, then re-check | converts a guaranteed failure into a success without a second refetch round trip |
| **nothing in flight** — disconnected, never connected, or a reconnect that gave up | throw `SSHTransportNotReady` **at once** | there is nothing to wait for; waiting would stall forever |
| **grace elapsed** | throw `SSHTransportNotReady` | a wedged connect must never pin providers |

Three properties make the short-circuit safe rather than lossy:

* **Refetch is already guaranteed.** `_invalidateRepoState()` runs on every
  connect and disconnect, so a provider that short-circuits is re-run when the
  session changes. The gate does not need to wait for correctness — only to
  avoid an avoidable round trip.
* **Failing fast preserves drop detection.** A mid-session drop leaves nothing
  in flight, so commands fail immediately instead of hanging — which is what
  a dead host should do, and what option B would have broken.
* **Readiness consults both the state and the transport.** `phase == connected`
  alone is not enough: Phase 1 caught a command at `phase: connecting` with no
  client, and a drop produces the inverse for a frame. Ready means the app
  believes a session is live **and** a client is actually attached.

### Where the gate lives, and why not per provider

`repoScopedFetchFamilies` has ~30 members. Gating each one is ~30 edits, each
of which can be forgotten, and would need its own scan to stay honest.

The gate goes in a **`CommandExecutor` decorator** instead —
`ActivityCommandExecutor` is the existing precedent for exactly this shape —
composed into `gitServiceProvider` alongside it. Every command any provider
issues passes through one place, by construction. Nothing to miss, nothing to
enforce with a scan.

One constraint is load-bearing and easy to break: `activeExecutorProvider`
deliberately watches a leaf `backendProvider` and **not** `connectionProvider`,
because `ConnectionController` itself reads `gitServiceProvider` and the
resulting cycle crashed every connect in debug builds (`app_providers.dart`
~207–215). The decorator therefore takes a **callback** that reads
`connectionProvider.notifier` at *call* time, never a build-time `watch` — the
same discipline `_forgeAuthReady` already uses.

### Confirmation

* The reproduction from the plan's Phase 1 fails before the fix and passes
  after; it is kept as the regression test.
* `SSH connection not established.` appears in no user-facing string —
  asserted, not assumed.
* Each inverted call site publishes its state before invalidating, pinned by
  a test that fails if the order is restored.
* Riverpod retry stays off: `provider_retry_policy_test.dart` continues to
  pass unchanged.

## Pros and Cons of the Options

### A. Humanize only

* Good, because it is one branch and removes the developer string.
* Bad, because the command still runs against a dead transport and still
  fails; the user reads nicer words for a thing that should not have
  happened.
* Bad, because it leaves "not ready" and "failed" the same category.

### B. Executor waits for a client

* Good, because the symptom disappears everywhere at once.
* Bad, because it hides a real mid-session drop behind the same wait — the
  executor cannot tell "connecting" from "the host went away", and the second
  must fail fast.
* Bad, because it makes command latency depend on connection state in a way
  no caller can see, and every timeout becomes ambiguous.

### C. Type + state + ordering (chosen)

* Good, because it removes the cause (a command issued while unmounted state
  said otherwise) rather than the evidence.
* Good, because the typed error makes the condition legible to the
  humanizer, the panes, and any future caller.
* Good, because "not ready ⇒ spinner" reuses a pattern already shipped and
  tested (0015 U5), rather than inventing a second convention.
* Neutral, because it touches four call sites in the connection lifecycle,
  which is load-bearing code.
* Bad, because it cannot be written until the cold-connect trigger is
  reproduced — deliberately, as a gate.

### E. Readiness precondition at the executor seam (chosen as primary)

* Good, because it stops the doomed command being issued at all — the actual
  cause Phase 1 measured, rather than the places it becomes visible.
* Good, because one decorator covers every current and future repo provider;
  there is no list to keep in sync.
* Good, because the contract is explicit about not waiting when there is
  nothing to wait for, so it cannot stall a disconnected app.
* Good, because the ready path costs one boolean check.
* Neutral, because it adds a layer to the executor chain — one the codebase
  already has a precedent and a shape for.
* Bad, because a careless implementation could reintroduce the
  `CircularDependencyError` the chain was built to avoid. The callback
  discipline above is the mitigation, and it is testable.

### D. Re-enable retry

* Good, because it would make the symptom vanish immediately.
* Bad, because it is the exact mechanism that hid this bug until 0017. It
  would also re-break every error branch in the widget suite
  ([0017](./0017-MADR-provider-retry-policy-on-providers.md) G-series).
* Rejected outright.

## Consequences

* Good, because a whole class of "transport briefly absent" flashes stops
  being renderable as failure.
* Good, because the connection lifecycle gains one consistent rule — publish
  state, then invalidate — instead of four sites each choosing.
* Neutral, because the typed exception is a new public name in
  `ssh_command_executor.dart`; callers that caught the bare `Exception` keep
  working, since it still implements `Exception`.
* Good, because "can this command run at all" becomes a question with one
  answer in one place, instead of an assumption made independently by ~30
  providers.
* Neutral, because the grace window is a latency optimization, not a
  correctness mechanism — it can be tuned or removed without changing what
  the app does, only how many refetches it takes to get there.
* Bad, because a decorator on every command is on the hot path; it must stay
  allocation-free when ready, and that has to be asserted rather than
  assumed.
* Bad, because Phase 1's finding arrived after this record's first draft, so
  the ordering fix is now secondary to a cause it does not address. Kept
  anyway: it is a real inversion, and it is what makes the second refetch in
  the measured sequence fail.

## More Information

* Throw sites: `lib/core/ssh/ssh_command_executor.dart` ~680, ~1015.
* Humanizer: `lib/core/ssh/ssh_error_messages.dart` ~64; renderer:
  `lib/core/utils/display_error.dart`.
* Lifecycle: `lib/core/providers/app_providers.dart` `_invalidateRepoState`
  ~1042 and its five call sites; `repoScopedFetchFamilies` ~2670.
* Panes: `lib/features/repository/repo_status_view.dart` ~1671,
  `lib/features/repository/file_view.dart` ~722,
  `lib/features/forge/forge_widgets.dart` ~183 — the existing
  `forgeAuthPending` spinner branch this decision extends.
* Shell gate: `lib/features/app_shell.dart` ~725, ~1122.
