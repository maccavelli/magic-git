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
| 3 | The backfill scan (1D half) | new `lib/core/forge/namespace_backfill.dart`, new `test/namespace_backfill_test.dart` |
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
Future<void> backfillNamespacesFromRecents(Ref ref, {ScopedAccess? access});
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
   `unawaited(backfillNamespacesFromRecents(ref))` — never awaited, so the
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
