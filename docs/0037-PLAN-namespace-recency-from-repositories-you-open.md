---
status: "in-progress"
date: 2026-09-08
associated-madr: "0037-MADR-namespace-recency-from-repositories-you-open.md"
---
# Implement namespace recency from the repositories you open

Associated MADR: [0037-MADR-namespace-recency-from-repositories-you-open.md](0037-MADR-namespace-recency-from-repositories-you-open.md)

Line numbers are as of `5af35c7`. Re-run the proof table before starting; if a
line has moved, update the plan before the phase, not after.

## Goal

Make the create sheet's recency list learn from repositories the user **opens**,
not only from those this app creates or clones — covering the gap between local
history (writes only) and the forge feed (7 days, one 100-event page).

Executes **1D** (record at open **and** backfill what is readable for free),
**2A** (into `NamespaceHistory`), **3A** (from the session's cached origin),
**4B** (the backfill is idempotent and runs in the background when the create
sheet opens — no migration flag).

## Proof of the MADR's assertions

Read-only. Run all before Phase 1 and paste the output into the record.

| # | Assertion | Proof |
| --- | --- | --- |
| P1 | A per-repo, timestamped MRU already exists, capped at 30 | `recent_repos_store.dart` — `RecentRepoRef{isLocal, id, repoPath, openedAt}`, `static const _maxEntries = 30`, doc: *"the authoritative per-repo recency source"* |
| P2 | The open is already recorded, best-effort | `ConnectionController._recordRecentOpen` (`app_providers.dart:2208`), three call sites: `:1513` (SSH connect), `:2001` (local connect), `:2262` (repo switch). Doc: *"a persistence failure must never block or fail an open"* |
| P3 | Origin is already fetched and cached per session | `GitService._forgeAuthArgs` (`git_service.dart:4979-4997`) runs `git remote get-url <remote>` and memoises into `_remoteUrlByRepo`, with `extraEnv: _scopeEnvFor(repoPath)` |
| P4 | Nothing persists an origin | `grep origin lib/core/storage/*.dart` → no matches |
| P5 | A local repo reads offline, with no session and no prompt | `SecurityScopedBookmark.startAccessing` invokes a channel and returns null on failure — no picker; `localExecutorProvider` is a bare `LocalCommandExecutor()` (`app_providers.dart:154-156`) |
| P6 | An SSH repo needs a live session | `activeExecutorProvider` (`app_providers.dart:233-243`) resolves `ConnectionBackend.ssh` → `executorProvider`, the connected client |
| P7 | Live sessions are reachable per tab | `TabsController.tabs` (`:119`), `containerFor` (`:122`), `containerForRepo` (`:129`) |
| P8 | The composer already filters and already carries times | `namespaceSuggestionsProvider` drops a recent namespace absent from `all` **when `all` is non-empty**; `NamespaceSuggestions.times` (MADR 0032 Phase 8) |
| P9 | The namespace split is a last-slash split, not `dirname` | MADR 0036 Phase 7: `dirname` answers `/` for a bare name; the clone recorder uses `remotePathFromUrl` + `lastIndexOf('/')` |

## Scope

### In scope

| Phase | What | Files |
| --- | --- | --- |
| 1 | `GitService.originUrl` — public, cached, scope-aware | `lib/core/git/git_service.dart`, `test/git_service_*_test.dart` (new group) |
| 2 | Record the namespace at open (1C half) | `lib/core/providers/app_providers.dart`, `test/namespace_history_test.dart` or a new `test/namespace_open_recording_test.dart` |
| 3 | The backfill scan (1D half) | new `lib/core/forge/namespace_backfill.dart`, new `test/namespace_backfill_test.dart`, **+ `lib/core/providers/app_providers.dart`, `test/namespace_open_recording_test.dart` (deviation 1, 2026-09-08)** |
| 4 | Run it when the create sheet opens (4B) | `lib/features/workspace/create_repo_steps/namespace_field.dart`, `test/create_repo_namespace_search_test.dart` |
| 5 | Docs, catalogue, index | `docs/README.md`, `tool/mutations/0037-open-recency.json`, this plan |

### Out of scope

* **Dialling a saved connection to read it.** The scan skips a host with no
  live session; 1C covers it at next open. This is the MADR's central limit.
* **A persistent origin cache** (decision 2B). The namespace is what is
  consumed; `NamespaceHistory` already stores, bounds, de-duplicates and times.
* **A persistent creatable cache.** The memo is session-scoped, like the two
  caches it mirrors; nothing new is written to disk.
* **The 7-day window, the events feed, the creatable list.** Settled by 0032.

### Preconditions

```sh
flutter --version | head -1          # Flutter 3.47.2
flutter pub get --enforce-lockfile   # "Got dependencies!"
git status --short                   # empty
git rev-parse --short HEAD           # 5af35c7, or update the line numbers
```

### Baselines — capture before Phase 1

```sh
flutter test 2>&1 | tail -1
printf 'expect=%s testWidgets=%s\n' \
  "$(grep -rho 'expect(' test/ | wc -l | tr -d ' ')" \
  "$(grep -rho 'testWidgets(' test/ | wc -l | tr -d ' ')"
```

## Implementation Steps

### Phase 1 — `GitService.originUrl`

Decision 3A needs a public reader for what `_forgeAuthArgs` already caches.

1. Extract the fetch-and-memoise half of `_forgeAuthArgs` into:

   ```dart
   /// The URL of [remote] for [repoPath], or null when the repo has none.
   ///
   /// Memoised per (repo, remote) for the session — the same cache
   /// `_forgeAuthArgs` fills, so a repo whose credential helper was already
   /// chosen costs nothing here. Scope-aware: a bare/dotfiles repo needs its
   /// GIT_DIR or the command fails outright (MADR 0022 H2).
   Future<String?> originUrl(String repoPath, {String remote = 'origin'});
   ```

   `_forgeAuthArgs` then calls it, so there is one fetch path, not two.
2. Invalidation is unchanged — `_invalidateRemoteCaches` already clears
   `_remoteUrlByRepo` on checkout, and its comment explains why that matters.

**Tests.** A repo with an origin returns it and the **second call issues no
command**; a repo with none returns null; a scoped repo's call carries its
`GIT_DIR`/`GIT_WORK_TREE`; a failure returns null rather than throwing.

**Commit.**

### Phase 2 — Record the namespace at open

All in `ConnectionController`, beside `_recordRecentOpen` (`:2208`).

1. Add:

   ```dart
   /// Records the namespace of a just-opened repo, so the create sheet's
   /// recency list learns from opens as well as creates and clones
   /// (MADR 0037). Best-effort, exactly like [_recordRecentOpen] beside it:
   /// a failure here must never affect an open.
   Future<void> _recordOpenedNamespace({
     required bool isLocal,
     required String? connectionId,
     required String? repoPath,
     DateTime? at,
   }) async
   ```

   * `originUrl(repoPath)` on the session's `GitService` (Phase 1).
   * `forgeFromRemoteUrl` / `forgeHostFromRemoteUrl` — return early unless the
     result is `Forge.github` or `Forge.gitlab` and the host is non-empty.
   * `remotePathFromUrl`, then **`lastIndexOf('/')`, not `dirname`** (P9);
     `slash <= 0` returns.
   * **Creatable check (decision 1).** `_creatableFor(forge, host)` — a
     session memo (`Map<String, List<String>>` keyed `<forge>@<host>`, cleared
     wherever `_remoteUrlByRepo` is) wrapping `listCreatableNamespaces`.
     Return early when the lookup fails (unknown ≠ creatable) or when the
     namespace is not in the list.
   * `NamespaceHistory(ref.read(connectionStoreProvider)).record(...)` with the
     `SavedConnection` for an SSH open and null for a local one — the two-store
     split, unchanged.
2. Call it from `_recordRecentOpen`, after the MRU write, wrapped in the same
   `try`. One call site, so all three opens (SSH connect, local connect, repo
   switch) are covered by construction.

**Tests.** An SSH open records `<forge>@<host>` → namespace onto the
connection; a local open records into the prefs store; a repo with no origin, a
non-forge origin, or `host/repo` (no namespace above it) records nothing; a
throwing store does not fail the open; the recorded time is the open's.
**Decision 1:** a namespace **absent** from the creatable list records nothing;
a **failed** creatable lookup records nothing; and two opens on the same host
issue **one** creatable lookup, not two.

**Commit.**

### Phase 3 — The backfill scan

New `lib/core/forge/namespace_backfill.dart`, one entry point:

```dart
/// Learns namespaces from the repositories already in the recents list, for
/// everything readable **without a handshake** (MADR 0037, 1D):
///
///  * a saved **local** repo — its bookmark resolves silently and
///    `LocalCommandExecutor` needs no session;
///  * an **SSH** repo whose host already has a live session in some tab.
///
/// A host with no session is SKIPPED, never dialled: this runs while the
/// create sheet is opening, and must not make it wait on a handshake.
///
/// Idempotent by construction — `NamespaceHistory` de-duplicates and bounds —
/// so it needs no "already backfilled" flag and self-heals a changed origin.
Future<void> backfillNamespacesFromRecents(
  ProviderContainer container, {  // was `Ref ref` — see deviation 2
  ScopedAccess? access,
});
```

Steps per `RecentRepoRef`, over at most `_maxEntries` (30):

* **local** → `SavedLocalRepo` by id; `access.acquire(bookmarkData)` (skip if
  it returns null — stale bookmark); `GitService(localExecutor).originUrl(path)`;
  **`finally` release**, including when the read throws.
* **ssh** → find a tab whose `connectionProvider` reports `isConnected` with
  the matching `connectionId`; use *that container's* `gitServiceProvider`. No
  tab, no read.
* Check the namespace against the creatable list for its (forge, host) —
  the same memo, so a host already checked at open time costs nothing — and
  record via `NamespaceHistory` with the ref's `openedAt` as the time.

**Tests** (`namespace_backfill_test.dart`, a `ProviderContainer`, no widgets):
records a local repo's namespace offline; records an SSH repo's when a tab has
a live session; **skips and does not dial** when it does not (a controller
whose `beginProvisioning` fails the test); releases every grant, including on a
throwing read (`CountingScopedAccess`); a stale bookmark is skipped, not fatal;
running twice changes nothing; one unreadable repo does not stop the rest.

**Commit.**

### Phase 4 — Run it when the create sheet opens

1. `NamespaceField.initState` fires it once per mount:
   `unawaited(backfillNamespacesFromRecents(ProviderScope.containerOf(
   context, listen: false)))` (deviation 2) — never awaited, so the
   field renders immediately (MADR 0032: nothing on the wizard's path waits).
2. On completion, invalidate `namespaceSuggestionsProvider` so a namespace the
   scan learned appears without reopening the sheet.

**Tests.** The field renders before the scan completes; a namespace the scan
finds appears once it does; a scan that throws leaves the field working.

**Commit.**

### Phase 5 — Record

`tool/mutations/0037-open-recency.json`, the `docs/README.md` row, this plan's
execution record, the MADR's `verified:` date.

## Verification

At the end of every phase:

```sh
flutter analyze
dart format --output=none --set-exit-if-changed <each staged file>
flutter test
python3 tool/mutate.py tool/mutations/0037-open-recency.json
```

Standing rules: `dart format` in place, never chained with `&&` before
`git commit`, never globally; sabotage only in the harness's scratch worktree;
read the whole failure list; a `DID NOT APPLY` is a broken experiment and fails
the phase — as is a mutation that kills only via a compile error (MADR 0036
Phase 7).

### Sabotage

| Mutation | Must be caught by |
| --- | --- |
| `originUrl` ignores its cache (refetches) | Phase 1 "second call issues no command" |
| `originUrl` drops the scope env | Phase 1 scoped-repo test |
| `_recordOpenedNamespace` not called from `_recordRecentOpen` | Phase 2 SSH-open test |
| `dirname` used instead of the last-slash split | Phase 2 "`host/repo` records nothing" |
| ~~A non-forge origin recorded anyway~~ **dropped 2026-09-08** | Unfalsifiable: redundant with `_creatableFor`'s switch default, so no single edit exposes it. See the Phase 2 record. |
| A non-creatable namespace recorded anyway | Phase 2 "absent from creatable records nothing" |
| A failed creatable lookup treated as creatable | Phase 2 failed-lookup test |
| The creatable memo ignored (refetches per open) | Phase 2 "one lookup for two opens" |
| The local half of the scan skipped | Phase 3 local test |
| The SSH half dials when no session exists | Phase 3 "skips and does not dial" |
| A grant is not released when the read throws | Phase 3 leak test |
| The scan awaited in `initState` | Phase 4 "renders before the scan completes" |
| `namespaceSuggestionsProvider` not invalidated after the scan | Phase 4 "appears once it does" |

### Acceptance criteria

1. Opening a repo with a forge origin records its namespace, timed by the open.
2. No origin, non-forge origin, no namespace above the repo, a namespace the
   account cannot create in, or a failed creatable lookup → nothing recorded.
3. Recording never fails, delays or blocks an open — proven with a throwing
   store.
4. The scan reads every saved local repo offline, and every SSH repo whose host
   has a live session, and **dials nothing**.
5. The scan releases every grant it acquires, including on a throwing read.
6. The scan is idempotent; a stale bookmark or unreadable repo is skipped.
7. The create sheet renders without waiting for the scan, and updates when it
   lands.
8. A namespace learned this way is dropped by the composer when the account
   cannot create in it, and kept when the creatable lookup failed.
9. `flutter analyze` clean; suite green each phase; every mutation killed.

## Execution record

### Preconditions and baselines — 2026-09-08, at `5af35c7`

```
Flutter 3.47.2 • channel stable
git status --short                      (only 0037's own docs)
expect=9413 testWidgets=1066
```

> **The first baseline run was discarded as worthless.** It was started in the
> same step that read `_forgeAuthArgs`, and `git_service.dart` was then edited
> while it was still compiling test files — so it picked up the change midway
> and reported five failures that looked pre-existing. A baseline is only a
> baseline if nothing moves under it. This is the second time in this session's
> work that an overlapping run produced a misleading result; the rule is to let
> a measuring run finish before touching the thing it measures.

### Phase 1 — 2026-09-08 — *complete*

**`GitService.originUrl`** is the public reader for the origin the session
already fetches; `_forgeAuthArgs` now calls it, so there is one fetch path
rather than two. Memoised in the same `_remoteUrlByRepo` the credential-helper
lookup fills, scope-aware (a bare/dotfiles repo needs its GIT_DIR — 0022 H2),
and null for "no origin, or the command failed" since a caller can act on
neither.

**A real regression in the extraction, caught by an existing test.**
`mutations_test.dart`'s *"pull/push reuse cached upstream and get-url"* failed
with `at location [3] is 'git remote get-url origin' instead of 'git push
--progress'`. The original cached the URL whenever the command **succeeded,
including when it was empty**; the first extraction returned early on empty
*before* caching, so a repo with no origin re-issued `git remote get-url` on
every push and pull for the rest of the session — a silent per-operation round
trip on a hot path. Restored: cache on success even when empty, report
emptiness to the caller as null. The comment names the test, so the next edit
that "tidies" that early return knows its cost.

**The mutation catalogue did not catch it, and could not have.** Every Phase 1
entry is scoped to `git_service_test.dart`, so the whole catalogue was green
while the shared path was broken. A hand-written catalogue checks *what you
claimed*, not *what you disturbed*; the full suite is what caught this, after
the maintainer asked whether the baseline's failures were real.

**A survivor that was a genuine gap.** *"a failed command yields '' rather than
null"* survived the first run: the "repo with no origin" test used **empty**
stdout, so the `isEmpty` guard masked the exit-code check entirely — a failing
`git` that printed a diagnostic would have returned `fatal: No such remote` as
a URL, and Phase 2 would have recorded it as a namespace. A second test with
non-empty stdout on failure closes it.

**Sabotage — 5 mutations, all killed.** Two needed repointing after the fix
re-indented their targets (`DID NOT APPLY` is a broken experiment, not a pass).

```
originUrl ignores its cache          -> a second call issues no command
originUrl drops the scope env        -> a scoped repo carries its GIT_DIR
originUrl returns an empty URL       -> empty output is null, not an empty URL
a failed command yields ''           -> a FAILED command is null even when it printed
the memo survives a checkout         -> a checkout drops the memo, so the next read refetches
```

**Verification:**

```
flutter analyze (whole project)   No issues found!
dart format                       0 changed
flutter test (full suite)         03:38 +3739 ~3: All tests passed!
tool/mutate.py (5 mutations)      5 killed, 0 survived, 0 did not apply
expect=9424 testWidgets=1066
```

### Phase 2 — 2026-09-08 — *complete*

**`_recordOpenedNamespace`** hangs off `_recordRecentOpen` in
`app_providers.dart`, so all three ways a repository is opened — an SSH
connect, a local connect, a repo switch within a tab — are covered by
construction rather than by three call sites kept in step by hand. It resolves
the origin through Phase 1's `originUrl`, maps the host to a forge, splits the
namespace off the project path, checks the namespace against the account's
creatable list, and records it through `NamespaceHistory` — the same store the
create sheet already writes on success, so open and create feed one history.

**Decision 1 — "only ones you can create in" — is `_creatableFor`,** a
`Map<(Forge, String), List<String>?>` memo beside `_hostLogins` and cleared
wherever that is. One lookup per (forge, host) per session; an open whose
namespace is absent records nothing, and a lookup that *failed* records nothing
either. Decision 2 — "every open" — is what hanging off `_recordRecentOpen`
buys: no filtering on repo age, forge, or whether the namespace is already
known.

**The bare-path guard uses `lastIndexOf('/')`, never `dirname`.** `dirname`
returns `/` for a bare name, which is how the clone recorder shipped a bug in
0036; the same shape recurs here and is guarded the same way.

**Code deleted as dead that was not, caught by the harness.** I judged
`if (result != null && result.isEmpty) result = null;` behaviourally inert —
both `null` and `[]` fail the subsequent `.contains`, so no open is recorded
either way — and removed it. The mutation *"a failed creatable lookup is
treated as creatable"* then **survived**. It is not inert: both forge services
swallow a failed lookup and return `[]`, so that collapse is the only thing
that makes "the forge did not answer" a state distinct from "the account can
create nowhere". Without it the failed-lookup test still passes, but through
the `.contains` branch while claiming to exercise the `null` one — a test that
proves something other than what it says. Restored, with the story in the
comment so the next reader does not re-derive "dead code" and delete it again.

**Two mutations that were broken experiments, not passes.** The first draft of
*"a bare path records itself as a namespace"* used `dirname`, which is not
imported in `app_providers.dart` — it killed on a **compile error** and
therefore proved nothing about the tests. Rewritten to compile. The test it
targets was then found to be passing for the wrong reason as well: `app` is
absent from the harness's creatable list, so the creatable check masked the
slash guard entirely. Fixed by putting `app` **into** that list, so only the
guard can make the test pass.

**One mutation discarded as unfalsifiable.** The non-forge-origin guard is
redundant with `_creatableFor`'s switch default — an origin on neither forge
yields no creatable list whichever guard runs first — so no single edit can
expose it. That is defence in depth, not a test gap; a mutation that cannot
fail is worse than no mutation, so it was dropped rather than kept green.

**Sabotage — 10 mutations (5 from Phase 1, 5 new), all killed:**

```
phase2: the namespace is not recorded on open at all
      -> an SSH open records its namespace onto the connection
phase2: a bare path records itself as a namespace
      -> a path with no namespace above it records nothing
phase2: the creatable check is skipped
      -> a namespace the account cannot create in records nothing
phase2: a failed creatable lookup is treated as creatable
      -> a failed creatable lookup records nothing
phase2: the creatable memo is ignored (one lookup per open)
      -> two opens on one host issue a single creatable lookup
```

**Two info-level analyzer lints cleared** in files this work introduced or
touched (`_isGetUrl` renamed in `git_service_test.dart`; import order in
`add_existing_repo_sheet_test.dart`). No behaviour change.

**Verification:**

```
flutter analyze (whole project)   No issues found!
dart format                       0 changed
flutter test (full suite)         03:31 +3747 ~3: All tests passed!
tool/mutate.py (10 mutations)     10 killed, 0 survived, 0 did not apply
expect=9432 testWidgets=1066
```

### Phase 3 — 2026-09-08 — *complete*

**`backfillNamespacesFromRecents`** walks the recents log (30 entries) and
records the namespace of every repository reachable **without a handshake**: a
saved local repo, read offline under its own security-scoped bookmark; and an
SSH repo whose host a tab already holds a live session on, read through *that
tab's* `GitService`. A host with no session is skipped and never dialled — the
MADR's central limit, and the reason the scan can run while the sheet is
opening. It records through Phase 2's `recordNamespaceFromOrigin`, so decision
1 and the per-(forge, host) memo apply to the scan exactly as they do to an
open, with no second copy of either.

Each namespace is timed by the ref's `openedAt`, not by when the scan ran —
otherwise the first backfill would stamp thirty stale repositories with the
current time and rank them all above a repository genuinely opened yesterday.

**Both sandbox details the local half needs are handled.** A linked worktree
acquires its main repository's grant as well as its own, because `git remote
get-url` in a worktree reads the main repo's `.git`; and a scoped work tree
(the dotfiles pattern) gets `registerRepoScope`, without which it has no `.git`
to discover and the read fails as "not a git repository". Grants are released
in a `finally`, including when a later acquire throws.

**Three survivors, all three test defects.** The first run was 15 killed / 3
survived, and not one survivor was a hole in the production code:

* *the SSH half dials a host with no live session* — the disconnected tab in
  the test had `connectionId: null`, so the **connection-id guard rejected it
  first** and the `isConnected` check was never reached. The same masking
  Phase 2 hit with the bare-path test. Fixed by giving the dropped tab the
  connection identity a real dropped tab keeps.
* *a held grant is not released when the read throws* — and *one unreadable
  repo abandons the whole scan*. Both rested on `localExec.throwOnRead`, and
  **neither throw ever escaped**: `GitService.originUrl` swallows every failure
  and answers null (Phase 1), so a failing `git remote get-url` is not an
  exception anywhere in this file's control flow. Two tests that named a throw
  were exercising the null path. Fixed by throwing from `ScopedAccess.acquire`,
  which is upstream of the swallow, and by splitting out a separate test that
  asserts the *ordinary* failed-read case honestly: it records nothing.

**A mutation that was itself inert.** The first *"grants are not released"*
edit was `if (held.isEmpty) return null;` inside the `finally` — `held` is
never empty on that path, so it changed nothing and would have read as a pass.
Replaced with `held.skip(held.length)`, which compiles and actually skips every
release.

**Sabotage — 18 mutations (5 Phase 1, 5 Phase 2, 8 Phase 3), all killed.**
Phase 2's five were re-run because deviation 1 moved a guard behind a new call
boundary, which is exactly where a previously-killed mutation starts surviving;
they still kill.

```
phase3: the SSH half dials a host with no live session
      -> a host with no live session is skipped, and never dialled
phase3: any connected tab answers for any connection
      -> a tab on a different connection is not read
phase3: a held grant is not released when a later step throws
      -> a grant already held is released when a later one throws
phase3: the linked worktree's main-repo grant is skipped
      -> a linked worktree acquires and releases both grants
phase3: the scoped work tree's GIT_DIR is not registered
      -> a scoped work tree carries its GIT_DIR into the read
phase3: the scan is timed by when it ran, not by the open
      -> a saved local repo is read offline and its namespace recorded
phase3: one unreadable repo abandons the whole scan
      -> a repo that will not read does not stop the rest
phase3: the local half is skipped entirely
      -> a saved local repo is read offline and its namespace recorded
```

**Verification:**

```
flutter analyze (whole project)   No issues found!
dart format                       0 changed
flutter test (full suite)         03:30 +3762 ~3: All tests passed!
tool/mutate.py (18 mutations)     18 killed, 0 survived, 0 did not apply
expect=9461 testWidgets=1066
```

### Phase 4 — 2026-09-08 — *complete*

**`NamespaceField.initState` fires the scan once per mount**, never awaited,
and invalidates `namespaceSuggestionsProvider` when it settles. The container
comes from `ProviderScope.containerOf(context, listen: false)` — which is the
*active tab's* container, because `TabsHost` provides it above the root
Navigator the sheet is pushed on (`tabs_host.dart:500-505`).

**The invalidate is load-bearing for exactly one of the two stores, and the
sabotage is what established which.** The mutation *"the suggestions are not
invalidated when the scan finishes"* **survived** its first run, and the reason
is a real asymmetry:

* an **SSH** namespace is written onto a `SavedConnection`; the real
  `ConnectionStore` fires `StoreBus` on every write
  (`connection_store.dart:121`), `TabsController` turns that into a
  `savedConnectionsProvider` invalidate in each tab
  (`tabs_controller.dart:54`), and `namespaceSuggestionsProvider` **watches**
  that provider — so it recomputes with no help from the field;
* a **This-Mac** namespace goes straight to SharedPreferences, which the
  suggestion provider reads inside its own body with nothing to watch. Without
  the field's invalidate it would not appear until the sheet was reopened.

The first test file used the SSH half throughout — deliberately, to stay off
the bookmark platform channel — and so could not see the difference. A
This-Mac arm was added, driving the local half with a mock handler on
`magicgit/bookmarks`, and it kills the mutation.

**A fake that was not faithful.** The SSH arm failed at first because
`FakeConnectionStore` does not fire `StoreBus`, unlike the store it stands in
for. Fixed in the test by a subclass that notifies, plus an
`UncontrolledProviderScope` over an explicit container subscribed the way
`TabsController` subscribes — reproducing the app's wiring rather than
asserting against wiring the app does not have.

**Two seams, not one.** The recording failed silently until both
`activeExecutorProvider` **and** `executorProvider` were overridden:
`ConnectionController._activeExecutor` reads `executorProvider` directly
(`app_providers.dart:1127-1130`) while the suggestion providers read
`activeExecutorProvider`, so stubbing only the latter left the creatable check
talking to a real, session-less SSH executor and answering "unknown" — which
decision 1 correctly treats as not creatable.

**Sabotage — 21 mutations (5 Phase 1, 5 Phase 2, 8 Phase 3, 3 Phase 4), all
killed:**

```
phase4: the scan is never started on mount
      -> the scan runs once on mount
phase4: the suggestions are not invalidated when the scan finishes
      -> a This-Mac namespace appears, which needs the invalidate
phase4: the scan is awaited, so the field waits on it
      -> the scan runs once on mount
```

**Verification:**

```
flutter analyze (whole project)   No issues found!
dart format                       0 changed
flutter test (full suite)         03:29 +3768 ~3: All tests passed!
tool/mutate.py (21 mutations)     21 killed, 0 survived, 0 did not apply
expect=9471 testWidgets=1072
```

#### Deviation 1 — 2026-09-08 — the creatable check is unreachable from a new file

**Found.** Phase 3's file list named only the two new files, but its body
requires the scan to check each namespace "against the creatable list for its
(forge, host) — the same memo". Every part of that is private to
`ConnectionController`: `_creatableByHost` (`app_providers.dart:910`),
`_creatableFor` (`:2316`), and the back half of `_recordOpenedNamespace`
(`:2262`) that splits the namespace, checks it and records it. A top-level
`backfillNamespacesFromRecents(Ref)` in `lib/core/forge/` can reach none of
them.

**Decision — extract a public method.** `_recordOpenedNamespace` keeps the
`originUrl` fetch and delegates the rest to a new public
`ConnectionController.recordNamespaceFromOrigin({url, isLocal, connectionId,
at})`; the backfill reads its own origins and calls the same method through
`ref.read(connectionProvider.notifier)`. One implementation of decision 1
serves both halves, and the memo the open path already warmed is the memo the
scan uses.

**Rejected.** *Lifting the memo into its own provider* would share it across
tabs (strictly better caching) but moves ownership of a session cache the
controller currently clears on connection-identity change, for a benefit the
per-tab memo already mostly delivers. *Duplicating the lookup in the new file*
would keep the file list intact at the price of a second implementation of the
same rule and a second forge round trip per host — the drift 0036 Phase 7
existed to remove.

**Scope added to Phase 3.** `lib/core/providers/app_providers.dart` and
`test/namespace_open_recording_test.dart`. Phase 2's five mutations are
re-run after the split: an extraction that moves a guard behind a new call
boundary is exactly where a previously-killed mutation can start surviving.

#### Deviation 2 — 2026-09-08 — the scan cannot take a `Ref`

**Found.** Phase 3 specified `backfillNamespacesFromRecents(Ref ref, …)` and
Phase 4 called it from `NamespaceField.initState` as
`unawaited(backfillNamespacesFromRecents(ref))`. That does not compile:
`NamespaceField` is a `ConsumerStatefulWidget`, so its `ref` is a `WidgetRef`,
and `Ref` is `sealed` (`riverpod-3.4.2/lib/src/core/ref.dart:43`) — `WidgetRef`
is not a subtype and cannot be made one. The plan step is wrong as written,
and it fixes Phase 3's signature, so it was settled at Phase 3 rather than
deferred.

**Decision — take a `ProviderContainer`.** ~~`backfillNamespacesFromRecents(Ref
ref, {ScopedAccess? access})`~~ → `backfillNamespacesFromRecents(ProviderContainer
container, {ScopedAccess? access})`. Every call the scan makes (`read`,
`read(…future)`) is on `ProviderContainer` already. Phase 4 reaches it with
`ProviderScope.containerOf(context, listen: false)`, a seam this codebase
already uses, and Phase 3's tests drive a bare container with no widgets,
exactly as planned.

**The liveness guard needed a second correction.** `!container.disposed` was
the obvious replacement for `ref.mounted`, but `disposed` is declared inside an
`@internal` extension (`provider_container.dart:1340-1342`) and is not part of
the public API. Reading a disposed container throws `StateError` instead, so
the scan's per-repository handler catches `on StateError` and **returns** —
abandoning the scan when the tab closes rather than grinding through the
remaining refs throwing on each. Safe because the scan is idempotent: the next
mount starts over.

**Rejected.** *Wrapping the scan in a `FutureProvider`* would keep a real
`Ref` and is the more idiomatic Riverpod shape, but adds a provider to
`app_providers.dart` and rewrites Phase 4 from a fire-and-forget call into a
`watch` — including how "renders before the scan completes" is proven. A
larger change to buy back a parameter type.

**No behaviour changes.** Phase 4 still fires once per mount, still never
awaits, still invalidates `namespaceSuggestionsProvider` on completion; only
the step's wording changes.

## Rollout and Rollback

**Rollout.** Five commits, one per phase. Phases 1–2 stand alone and deliver
the permanent half (learning at open); 3–4 add the retroactive half. Reverting
3–4 leaves a working feature.

**Rollback.** `git revert` per phase, newest first. Phase 4 must revert before
3; 2 before 1.

## Decisions — resolved 2026-09-08 by the maintainer

| # | Question | Decision |
| --- | --- | --- |
| 1 | Record only creatable namespaces, or filter at read time? | **Only creatable, checked at record time.** The store stays clean rather than filtered. Reverses the plan's assumption |
| 2 | Scan cadence | **Every create-sheet open** — bounded at 30, mostly cache hits, self-heals a changed origin |

**Decision 1's cost, and how it is contained.** A creatable check per open
would be a forge round trip on a path that previously made none. It is
memoised **per (forge, host) per session** — the shape `_remoteUrlByRepo` and
`_hostLogins` already use — so it costs one call per host per session.
**A failed lookup records nothing**: "creatable" is then unknown, and only what
is known is written. An offline session learns no namespaces.
