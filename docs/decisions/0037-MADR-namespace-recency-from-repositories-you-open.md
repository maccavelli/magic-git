---
status: "accepted"
date: 2026-09-08
decision-makers: [Maintainer]
consulted: []
informed: [Magic Git contributors]
verified: 2026-09-08
---

# Learn create-namespace recency from the repositories you open

## Context and Problem Statement

MADR 0032 gave the create sheet a recency-ranked namespace list from two
sources: **local history** (namespaces this app created or cloned into) and the
**forge events feed** (`events?after=<7d>`). Both shipped and are live-verified.

Assessing the clone gap during 0032's follow-up produced a third candidate,
recorded then as *"option C"* and deferred:

> Derive recency from the origins of already-registered repositories, projected
> onto namespaces — retroactive from day one, catching repositories added
> before any of this existed, and needing no write-time hook.

It was deferred on a cost estimate: *"origins are cached nowhere, so it is one
`git remote get-url origin` per repo and needs its own cache."* **That estimate
was made without reading the recency machinery, and it is wrong in both
directions.** This record establishes what is actually there and decides what,
if anything, to build.

### What the two shipped sources leave uncovered

`namespaceSuggestionsProvider` composes local history, then the forge feed,
then filters against the creatable list. The gap is the intersection of their
blind spots:

* **Local history** (`NamespaceHistory`) records only what *this app* created
  or cloned. A user who joined an existing project and only ever **opens** it
  has an empty history forever — opening is not a write, so nothing records.
* **The forge feed** covers the last **7 days** and caps at one 100-event page
  — a cap MADR 0032 measured being *reached in one week* on a real account. Work
  older than the window, or pushed past the cap, is invisible.

So the uncovered case is concrete: **a namespace you work in regularly, opened
rather than created, whose activity falls outside the events window.** Its
repositories are sitting in the app's own recents list, and the create sheet
cannot see them.

### What is actually in the tree

Four facts, each checked, that reshape the option:

**1. There is already a per-repo, timestamped recency store.**
`RecentRepoRef` (`recent_repos_store.dart`) carries `isLocal`, the owning
`SavedConnection`/`SavedLocalRepo` `id`, the exact `repoPath`, and
**`openedAt`** — its own doc calls it *"the authoritative per-repo recency
source"*, explicitly because `SavedConnection.lastConnectedAt` *"can't tell
which of a connection's repos was actually used"*. It is MRU-ordered,
de-duplicated by identity, capped at **`_maxEntries = 30`**, and persisted.

The deferral described option C as a sweep over *all registered* repositories.
It never needed to be: the app already keeps the ranked, timestamped, bounded
list. And MADR 0032 Phase 8 already carries per-namespace timestamps through to
the UI, so this source would arrive **timed**, not as an untimed tail.

**2. Reading N origins is one round trip, not N.**
`GitService.setFsmonitorMany` is the established shape: one `sh -c`, a subshell
per repo, `ShellEscaper` on every path, per-subshell scope env, `|| printf …`
to keep the sweep going, `; true` to pin exit 0. The "one call per repo" figure
in the deferral was simply wrong.

**3. A local repository can be read offline, with no session and no prompt.**
Local repos live behind security-scoped bookmarks
(`SavedLocalRepo.bookmarkData`, acquired through the refcounted
`ScopedAccess`). `SecurityScopedBookmark.startAccessing` **resolves silently** —
no Finder panel, returning null if the bookmark went stale — and
`localExecutorProvider` is a bare `LocalCommandExecutor()` needing **no
session at all**. So reading a saved local repo's origin costs an acquire, one
fast local `git`, and a release. The bookmark is a persistent grant the user
already gave *for that folder*; using it to read that folder's own origin is
squarely inside what it is for.

**4. An SSH repository cannot be read without a live session to its host.**
`activeExecutorProvider` resolves to `executorProvider` — the *connected*
session's client. A saved connection with no session has no executor, so
reading its repos' origins means **dialling it**. Dialling every saved host to
populate a dropdown is the cost this record will not pay; a host that already
has an open tab is free.

**This is the reverse of the earlier assessment.** The follow-up discussion
that deferred option C called the *local* half disqualifying (sandbox grants)
and treated the SSH half as merely expensive. It is the other way round: local
is cheap and offline, and SSH is the half that needs a network handshake.

**5. Nothing persists an origin, but the origin is already read when a repo is
open.** `grep origin lib/core/storage/*.dart` finds nothing. Meanwhile
`forgeProvider` runs `git remote get-url origin` for the active repo to
classify its forge, and `GitService._remoteUrlByRepo` caches it for the
session. So at the moment a repository is opened, its origin is either known or
one cheap call away — **on a session that already exists, with grants already
held.**

**6. The recording hook already exists.**
`ConnectionController._recordRecentOpen` runs on every repo open, already
writes to a store, and is already best-effort by contract: *"a persistence
failure must never block or fail an open."* That is the same contract
`NamespaceHistory.record` carries.

### The reframing

Facts 5 and 6 together change the question. The deferred option assumed
recency had to be **recovered later** by inspecting repositories at rest. It
does not: the app is *present at every open*, with a live session and grants
already held, and it already records that the open happened. The namespace can
be learned **at that moment**, for free.

And facts 3 and 4 say what retroactivity actually costs: **most of it is
free** — every saved local repo, plus every SSH repo on a host already open —
and the remainder needs a dial nobody should pay for a dropdown.

## Decision Drivers

* **Do not spend sandbox permissions on a convenience.** Acquiring a grant for
  a folder the user has not opened, to rank a dropdown, is disproportionate —
  and it fails only in signed builds, which is the worst failure shape.
* **No new I/O on the wizard's path.** MADR 0032 established that nothing on
  the create sheet's critical path may wait on the forge; the same reasoning
  forbids a git sweep when the sheet opens.
* **Reuse the stores that exist.** `NamespaceHistory` is already the one
  reader/writer, already two-store-aware, already timestamped (Phase 8), and
  already filtered against the creatable list. A second source that writes into
  it costs nothing downstream.
* **A suggestion must never be wrong in the harmful direction.** Offering a
  namespace the account cannot create in is worse than offering none — already
  handled, because the composer filters `recent` against `all`.
* **Prefer a decision that stays true.** Retroactive coverage is a one-time
  benefit at upgrade; a recording hook is a permanent one.

## Considered Options

**Decision 1 — where namespace recency comes from for opened repositories.**

* **1A. Do nothing.** Keep the two shipped sources.
* **1B. Sweep the recents list only, no recording hook.** Read the origins of
  the ≤30 `RecentRepoRef` entries whenever the namespace field opens.
* **1C. Record the namespace at open time only.** Extend `_recordRecentOpen` to
  resolve the opened repo's origin and record its namespace into
  `NamespaceHistory`. Prospective; nothing appears until the user opens
  something.
* **1D. Both: record at open, and backfill what can be read for free.** 1C,
  plus a background scan of the recents list covering every **local** repo
  (offline, via its bookmark) and every **SSH** repo whose host already has a
  live session. A host with no session is skipped and covered by 1C when it is
  next opened.

**Decision 4 — how the backfill is scheduled (1B/1D only).**

* **4A. A one-time migration**, guarded by a persisted "already backfilled"
  flag.
* **4B. Idempotent, every time the create sheet opens**, in the background.
* **4C. At app start.**

**Decision 2 — what is stored.**

* **2A. The namespace**, into the existing `NamespaceHistory`.
* **2B. The origin URL**, in a new persistent cache keyed by repo, with the
  namespace derived on read.

**Decision 3 — where the origin comes from at open time.**

* **3A. The session's `GitService`**, whose `_remoteUrlByRepo` already caches
  `git remote get-url origin` per repo.
* **3B. A fresh `git remote get-url origin`** in the record path.
* **3C. `forgeProvider`'s** existing classification work, extended to expose
  the URL it already fetches.

## Decision Outcome

Chosen options: **1D**, **2A**, **3A**, **4B**.

**1D over 1C**, reversing this record's first draft. That draft chose 1C and
accepted losing retroactivity, on the reasoning that a backfill was one-shot
machinery whose value expired at the first open. The maintainer's response —
*"dropping retroactivity is not a worthwhile trade"* — sent me back to the
constraint, and **the constraint was recorded backwards** (see facts 3 and 4).
Retroactivity is not a special mechanism bought at a price: for every saved
**local** repo it is an offline bookmark resolve and a fast local `git`, and
for every **SSH** repo on an already-open host it is free. Only hosts with no
session need a dial, and those are simply skipped.

**1D over 1B** because a scan alone leaves a permanent dependency on
re-scanning, and still cannot see a host that is never open at wizard time.
Recording at open makes each opened repo's namespace *stick* — after which the
scan is only catching up, never load-bearing. The two together degrade
gracefully in both directions: no scan result, and the hook still learns; no
open yet, and the scan still knows.

**1D over 1A** because the uncovered case is real and specific — a namespace
you open in rather than create in, older than the 7-day events window — and the
hook, the store and the composer all already exist.

**4B over 4A** — and this removes the objection the first draft raised against
1D. A backfill scheduled as *"idempotent, in the background, whenever the
create sheet opens"* needs **no migration flag and no one-shot machinery**:
`NamespaceHistory` already de-duplicates and bounds, so re-running is a no-op,
and a repository whose origin changed is picked up next time rather than being
frozen by a flag that says the work is done. **Over 4C** because app start is
where latency is most visible and the result is least likely to be needed.

**A host is skipped, not dialled.** The scan reads only what is already
reachable: `localExecutorProvider` for local repos (no session), and a live
session's executor for SSH. It never dials, so it can never make opening the
create sheet wait on a handshake.

**2A over 2B** because `NamespaceHistory` is already the single reader/writer
across two stores, already carries Phase 8's timestamps, and is already what
the composer reads. A second cache would need its own persistence, its own
invalidation, and its own place in the composition — for a value that is
derived, not authoritative.

**3A over 3B** because the session already resolves and caches origin;
re-running it in the record path would pay for what is in hand. **Over 3C**
because `forgeProvider` is `autoDispose` and keyed to the *rendered* repo panel
— it may not have run when an open is recorded, and making the record path
depend on a UI provider's lifecycle inverts the dependency.

### Consequences

* Good, because the uncovered case closes with no new store, no new provider in
  the composition, and no new I/O on the wizard's path.
* Good, because it arrives timed: `openedAt` is already recorded, and Phase 8
  already renders per-namespace times.
* Good, because it costs no sandbox permission — the grant is already held for
  the repo being opened.
* Good, because every failure is already survivable: `_recordRecentOpen` is
  best-effort by contract, `NamespaceHistory.record` swallows its own failures,
  and a namespace the account cannot create in is filtered by the composer.
* Neutral, because a repo with no origin, or a non-forge origin, records
  nothing — the same shape as the clone recorder.
* Good, because it **is** retroactive for everything reachable without a
  handshake: every saved local repo, and every SSH repo on a host already open.
* Bad, because retroactivity is **partial**. A saved connection with no live
  session contributes nothing until it is next opened — the scan will not dial
  to find out, so on upgrade a user whose work is entirely on hosts they are
  not currently connected to sees no change until they open one.
* Bad, because the scan touches saved local repos the user has not opened this
  session — resolving a bookmark they granted, to read that folder's own
  origin. Silent and promptless, but it is filesystem access nobody asked for
  at that moment.
* Good, because the store stays **clean rather than filtered**: only namespaces
  the account can actually create in are written, so the composer's
  failed-lookup arm — which deliberately keeps history when `all` is empty —
  can no longer surface a namespace the create would reject.
* Bad, because that costs a creatable lookup per (forge, host) per session, on
  a path that previously made no forge call at all, and an open on an
  unreachable forge records nothing.
* Bad, because it adds a third writer to `NamespaceHistory`, so "why is this
  namespace suggested?" now has three answers instead of two.

### Confirmation

1. Opening a repository whose origin is a forge URL records its namespace, with
   the open's timestamp.
2. Opening one with no origin, a non-forge origin, or a path with no namespace
   above it (`host/repo`) records nothing — the `dirname` trap MADR 0036 hit is
   not repeated.
3. A failed record never fails or delays the open, proven by a store that
   throws.
4. The namespace is read from the session's cached origin, not by a second
   `git remote get-url` — asserted on the executor's call list.
5. A namespace recorded this way is dropped by the composer when the account
   cannot create in it, and kept when the creatable lookup failed — the two
   arms MADR 0032 Phase 4 already tests, now reached from this source.
6. Local and SSH opens both record, into the correct half of the two-store
   split.
7. The background scan reads every saved local repo offline — no Finder
   prompt, no session — and every SSH repo whose host has a live session, and
   **dials nothing**: asserted on a connection controller that fails the test
   if `beginProvisioning` is called.
8. Running the scan twice changes nothing (idempotent), and a stale bookmark
   or a repo whose origin has gone is skipped rather than failing the scan.
9. Every grant the scan acquires is released, including when the read throws —
   proven with a counting `ScopedAccess`, the seam MADR 0036 Phase 7 added.

## Pros and Cons of the Options

### 1A. Do nothing

* Good, because the two shipped sources already cover creates, clones and the
  last 7 days of forge activity.
* Bad, because the uncovered case is a regular working namespace that is simply
  never suggested, while its repositories sit in the app's own recents list.

### 1B. Sweep only, no recording hook

* Good, because it is retroactive immediately and needs no write-time hook.
* Good, because the SSH half is one round trip per connection, not one per repo.
* Bad, because it never *learns*: a host that is never connected at wizard time
  is never covered, however often its repos are opened.
* Bad, because the answer depends on re-scanning, so it is only ever as fresh
  as the last time the sheet happened to be opened.

### 1C. Record at open time only

* Good, because the hook, the store, the timestamps and the filtering all exist.
* Good, because the grant and the session are already there, so it costs
  nothing.
* Bad, because it is prospective only — the list is unchanged on upgrade, and a
  namespace you have worked in for months stays invisible until you next open
  something in it.

### 1D. Both

* Good, because retroactive coverage is immediate for everything reachable
  without a handshake, and permanent for everything else once opened.
* Good, because the two halves cover each other's failure: no scan result and
  the hook still learns; nothing opened yet and the scan still knows.
* Bad, because it is two mechanisms writing to one store, so a suggestion now
  has three possible origins.

### 4A / 4B / 4C

* **4A** is the smallest single run, but needs a persisted flag, and freezes:
  a repository whose origin changed after the flag was set is never revisited.
* **4B** needs no flag at all — `NamespaceHistory` de-duplicates and bounds, so
  re-running is a no-op — and self-heals a changed origin. It pays a small
  background cost each time the sheet opens.
* **4C** puts the work where startup latency is most visible and the result is
  least likely to be wanted.

### 2A / 2B

* **2A** reuses one reader/writer and one composition; the stored value is what
  is consumed.
* **2B** is more reusable if the derivation ever changes, but adds a store, an
  invalidation policy and a second thing that can disagree with the first.

### 3A / 3B / 3C

* **3A** uses what the session already resolved and cached.
* **3B** is simplest to write and pays a round trip that is already paid.
* **3C** couples a persistence path to an `autoDispose` UI provider's lifecycle.

## More Information

* **This record supersedes the "option C" sketch** in MADR 0032's follow-up
  discussion, whose cost estimate — *"one `git remote get-url origin` per repo,
  needs its own cache"* — was wrong in both directions. The batch is one call
  per connection, and the sandbox concern it raised was aimed at the wrong
  half: local reads are offline and promptless, while SSH reads are the ones
  needing a handshake.
* **This record's own first draft chose 1C and gave up retroactivity**, on the
  same mis-stated constraint. It was revised after the maintainer rejected the
  trade. The reasoning is kept above rather than deleted, because the error was
  in the *facts*, and a reader should see which fact moved the decision.
* **The namespace split is a last-slash split, not `dirname`.** MADR 0036
  Phase 7 records why: `dirname` is filesystem-shaped and answers `/` for a bare
  name, which would record `/` as a namespace. `remotePathFromUrl` plus an
  explicit `lastIndexOf('/')` is the shape already used by the clone recorder.
* **Not in scope:** changing what the events feed does, the 7-day window
  (settled by MADR 0032 decision 1), or the creatable-list filtering.
* **Decided 2026-09-08: record only namespaces the account can create in**,
  checked at **record** time, rather than relying on the composer's read-time
  filter. This record's draft assumed the opposite, on the cost of a forge
  round trip per open; the maintainer chose the clean store. The cost is
  contained by memoising the creatable list **per (forge, host) per session**,
  the same shape as `_remoteUrlByRepo` and `_hostLogins` — so it is one call
  per host per session, not one per open, and it is best-effort like everything
  else on this path.
  **When the lookup fails, nothing is recorded.** "Creatable" is then unknown,
  and the decision is to record only what is known; the next open on a
  reachable forge records it. An offline session therefore learns nothing,
  which is a deliberate consequence of a clean store rather than an oversight.
* Related records: **MADR 0032** (the two shipped sources, the composer, and
  Phase 8's timestamps), **MADR 0036** (the `dirname` trap and the clone/create
  recorders this would sit beside).
