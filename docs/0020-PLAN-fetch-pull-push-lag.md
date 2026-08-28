---
status: proposed
date: 2026-08-28
associated-madr: 0020-MADR-fetch-pull-push-lag.md
owner: [Maintainer]
target-milestone: Next work cycle (post-review)
verified: 2026-08-28
---

# Implement fetch, pull, and push responsiveness

Associated MADR:
[0020-MADR-fetch-pull-push-lag.md](0020-MADR-fetch-pull-push-lag.md)

This plan is the **single execution vehicle** for that decision. A second
engineer following only this file, against the tree that contains that MADR,
must produce the same diff. Do not invent a different architecture here —
amend the MADR first.

No source changes until the maintainer explicitly approves this PLAN.
Each phase is one commit (`git commit --no-edit` after analyze + tests;
no `-m`). Never `git push` unless asked in the same turn. Never run
`live-forge` tests.

Deviation rule (global): if a step is wrong, a listed file is insufficient,
or a pre-existing test fails on an untouched file, **stop and prompt**.
Do not skip assertions, mark tests skipped, or redraw scope so the
failure falls outside the phase.

## Goal

Make fetch, pull, and push feel live: pack transfer must not freeze
interactive git or the Repository busy gate; git must emit progress so
the stall detector and the output log can see it; `--all` must only run
where the product means every remote; a fetch that does not move HEAD
must not re-walk History.

**Acceptance criteria** (end of Phase 6)

1. Default `GitService.fetch` argv is
   `git <both forge helpers> fetch --progress --prune --recurse-submodules=no --jobs=4 --all`.
   `FetchScope.defaultRemote` (post-commit only) omits `--all` and
   `--jobs`. Proven in `test/mutations_test.dart`.
2. `git fetch` / `git push` / pull's **fetch half** run on `ExecLane.sync`
   (sync SSH client when attached). Pull's **integrate half** is
   `ExecLane.exclusive` (`git merge` / `git rebase`, never `git pull`).
   Network commands keep `activityIdle: networkTimeout` and
   `timeout: _networkCeiling`.
3. `--progress` is on every network git invocation listed in Phase 1
   (fetch, push, push --delete, push tags, pull's fetch half). A
   non-TTY executor therefore emits stderr during pack transfer;
   `ActivityDeadline.pulse` already runs on those chunks.
4. Manual Fetch and Push do not set `BusyActionState.busy`. Pull still
   does. Dock indeterminate bar (`dock: true`) stays on all three.
5. Fetch / auto-fetch / post-commit fetch invalidate
   `repoFetchFamilies` (status, refs, remotes, branch base/review) and
   **not** `logProvider` / `logSearchProvider` / stashes / reflog /
   snapshots / worktrees. Pull's integrate still uses
   `repoMutationFamilies`.
6. `OwnMutationTracker` has a begin/end refcount; `isRecent` is true
   for the whole in-flight span **and** for 3 s after `end`. Watcher
   ticks during a fetch do not re-walk History.
7. Fetch/pull/push tail stderr through `OutputLogNotifier.startStream`
   on the **scheduler** path (`execute`, not `executeStream`). Clone's
   streaming helper is reused, not copied.
8. Auto-fetch and generic Fetch do not `refreshRemoteTags`. Tag
   push/delete still do.
9. `inotifywait` argv excludes `.git/objects/`, `.git/logs/`, `*.lock`,
   and `.git/fsmonitor--daemon/` — parity with fswatch.
10. `flutter analyze` exit 0, `dart format --output=none --set-exit-if-changed`
    clean on staged Dart, full `flutter test` green. No `live-forge`.

## Scope

**In scope** — MADR HIGH H1–H6, MED M1–M6, LOW L1–L2, in the phase
order the MADR already set.

| Phase | MADR IDs | One-line outcome |
|---|---|---|
| 1 | H2 argv, H4, M4 | `--progress`, `--recurse-submodules=no`, `--jobs=4` on `--all`, post-commit default-remote fetch |
| 2 | H5, H6 | `repoFetchFamilies` + in-flight own-mutation |
| 3 | H3 | Fetch/Push do not hold `_busy` |
| 4 | H1 | `git pull` → fetch (sync) + merge/rebase (exclusive) |
| 5 | H2 stream, M1, M2, M3, M6 | on-queue stderr tail; cache auth probes; stop auto `ls-remote`; name-status off the busy span |
| 6 | M5, L1, L2 | inotifywait excludes; Activity Center ticker; background sync visible while running |
| 7 | docs | `ARCHITECTURE_PLAN.md` §0.1, this PLAN `executed`, MADR `accepted` |

**Out of scope** (MADR residuals — do not implement)

* Submodule fetch UI; we only pin `--recurse-submodules=no`.
* Determinate Dock bar for fetch (clone already parses `%`; fetch stays
  indeterminate).
* Separate "Fetch All" vs "Fetch Upstream" buttons. Manual Fetch stays
  `--all`.
* Routing fetch through `executeStream` (off-queue). Forbidden.
* libgit2 / git2dart (0001).
* Raising default `networkTimeout`.
* Cancelling an in-flight fetch/push (L1 names it as later). Kill-on-
  timeout already exists.
* Streaming progress across the secondary-window proxy channel. Pop-out
  `execute()` still returns one buffered result (today's behaviour).
* Changing `git pull`'s prune policy. Pull's fetch half does **not**
  pass `--prune` (today's `git pull` doesn't). Manual Fetch keeps
  `--prune`.

## Frozen API and argv

These literals are the spec. A phase that emits different flags, a
different enum, or a different helper name is a deviation.

### `FetchScope` (new, next to `PullMode` in `lib/core/git/git_service.dart`)

```dart
enum FetchScope { allRemotes, defaultRemote }
```

### `GitService.fetch`

```dart
Future<SSHCommandResult> fetch(
  String repoPath, {
  bool background = false,
  FetchScope scope = FetchScope.allRemotes,
})
```

Argv, both scopes, after the existing `forgeGitAuthConfigArgsAll(...)`
block (Phase 1 still installs both helpers; Phase 5 M6 narrows
`defaultRemote`):

```
# FetchScope.allRemotes (manual Fetch, auto-fetch, default)
git <both helpers> fetch --progress --prune --recurse-submodules=no --jobs=4 --all

# FetchScope.defaultRemote (fetchInBackground only)
git <both helpers> fetch --progress --prune --recurse-submodules=no
```

No remote positional. `git fetch` without `--all` uses git's default
remote (current branch's remote, else `origin`). That is the
ahead/behind path.

Lane, timeout, activityIdle, visibility: unchanged (`ExecLane.sync`,
`_networkCeiling`, `networkTimeout`, `background` →
`OperationVisibility.background`).

### `GitService.push` / `deleteRemoteBranch` / `pushTags` / `deleteRemoteTag`

Insert `--progress` immediately after the `push` token, before force /
`-u` / `--follow-tags` / `--delete` / `--end-of-options`.

### `GitService.pull` — Phase 1 (still one process)

Insert `--progress --recurse-submodules=no` immediately after the `pull`
token, before the mode flag:

```
git <auth> pull --progress --recurse-submodules=no --ff-only|--rebase|--no-rebase …
```

Lane stays exclusive until Phase 4.

### `GitService.pull` — Phase 4 (split)

Do **not** call `GitService.merge` / `rebaseInteractive` (those are
journaled). Integrate through `_run` (no undo record), exclusive,
`commitTimeout` is wrong here — use the default exclusive timeout
(`SSHCommandExecutor.defaultTimeout` via `_run` with no timeout) for
the merge/rebase; they are local. Fetch half keeps `_networkCeiling` +
`activityIdle: networkTimeout`.

Target ref:

* no `remote`: fetch as `FetchScope.defaultRemote` (but **without**
  `--prune`, and with the **matching** forge helper from the existing
  `_forgeAuthArgs` / `_upstreamRemote` probes — not `forgeGitAuthConfigArgsAll`).
  Integrate against `@{upstream}`.
* `remote` set: `git <auth> fetch --progress --recurse-submodules=no --end-of-options <remote> [branch]`
  then integrate against `FETCH_HEAD`.

Integrate argv (`_idArgs` immediately after `git`, same as `merge`):

| `PullMode` | exclusive argv after fetch |
|---|---|
| `ffOnly` | `git <id> merge --no-edit --ff-only --end-of-options <target>` |
| `rebase` | `git <id> rebase --end-of-options <target>` |
| `merge` | `git <id> merge --no-edit --end-of-options <target>` |

If fetch throws, do not integrate. Return the integrate `SSHCommandResult`
on success (callers `logResult` the pull). Fetch's result is also logged
(Phase 4 `runLogged` body logs both).

### `CommandOutputCallback` (Phase 5)

```dart
typedef CommandOutputCallback =
    void Function(String chunk, {required bool stderr});
```

Add as optional named `onOutput` on `CommandExecutor.execute` (default
`null`), forwarded by every implementation. SSH and Local invoke it on
each **decoded** stdout/stderr chunk inside the existing drain (next to
`deadline?.pulse()`). Compressed stdout: one callback after gunzip, not
per wire chunk. Proxy **ignores** it (pop-out stays buffered).

Do not add `onOutput` to `ExecuteRequest` / the proxy codec.

### `OwnMutationTracker` (Phase 2)

Add `_inFlight: Map<String, int>`.

```
void begin(String repoPath)  // increment, never negative
void end(String repoPath)    // decrement; at 0, remove and mark()
bool isRecent(...)           // true if in-flight > 0 OR existing 3 s window
void clear()                 // clears both maps
```

`end` in a `finally`. Nested begin/end is refcounted (auto-fetch +
manual fetch).

Helper in `app_providers.dart`:

```dart
Future<T> withOwnMutation<T>(
  OwnMutationTracker tracker,
  String repoPath,
  Future<T> Function() body,
) async {
  tracker.begin(repoPath);
  try {
    return await body();
  } finally {
    tracker.end(repoPath);
  }
}
```

### `repoFetchFamilies` (Phase 2)

In `app_providers.dart`, next to `repoMutationFamilies`:

```dart
List<ProviderOrFamily> repoFetchFamilies(String repoPath) => [
  statusProvider(repoPath),
  refsProvider,
  remotesProvider,
  branchBaseProvider,
  branchReviewProvider,
];

void refreshAfterFetch(dynamic ref, String repoPath) {
  // ref is WidgetRef or Ref — match refreshAfterMutation's WidgetRef
  // and also provide a Ref overload used by ConnectionController /
  // autoFetchProvider (those have Ref, not WidgetRef).
  for (final p in repoFetchFamilies(repoPath)) {
    ref.invalidate(p);
  }
}
```

Two overloads if the analyzer requires it: `WidgetRef` and `Ref`.
Do **not** call `mark` here — `withOwnMutation`'s `end` already does.

`repoMutationFamilies` stays the commit-mutation set. Do not add fetch
call sites to `test/repo_mutation_refresh_test.dart`'s "must use
repoMutationFamilies" scan; add a sibling test that fetch/auto-fetch/
fetchInBackground **do not** name `logProvider` / `logSearchProvider` /
`stashesProvider` / `reflogProvider` / `magicSnapshotsProvider` /
`gitWorktreesProvider`.

## Implementation Steps

### Phase 0 — baseline (no commit)

```sh
flutter analyze
flutter test test/mutations_test.dart test/auto_fetch_test.dart \
  test/busy_action_test.dart test/repo_mutation_refresh_test.dart \
  test/activity_deadline_test.dart
```

Record the mutations_test argv expectations you will rewrite in Phase 1.
If analyze or those files fail on HEAD, stop — that is a pre-existing
defect, not this plan.

---

### Phase 1 — argv: `--progress`, recurse pin, fetch scope (H2 argv, H4, M4)

**Files**

* `lib/core/git/git_service.dart` — `FetchScope`; `fetch` signature and
  argv; `--progress --recurse-submodules=no` on `pull`; `--progress` on
  `push`, `deleteRemoteBranch`, `pushTags`, `deleteRemoteTag`.
* `lib/core/providers/app_providers.dart` — `fetchInBackground` calls
  `fetch(repoPath, background: true, scope: FetchScope.defaultRemote)`.
  Auto-fetch stays default (`allRemotes`).
* `test/mutations_test.dart` — rewrite the pinned argv lists (see below).
* `test/auto_fetch_test.dart`, `test/commit_dialog_test.dart`,
  `test/repo_status_view_test.dart`, `test/branches_view_guards_test.dart`
  — add `FetchScope scope = FetchScope.allRemotes` to any `fetch`
  override so they still compile. `commit_dialog_test` keeps asserting
  `fetchCalls == 1`; optionally assert the stub saw
  `FetchScope.defaultRemote` if the stub records scope.

**Exact `mutations_test.dart` `'fetch / pull / push'` after this phase**

```
calls[0] == [
  'git',
  '-c', 'credential.helper=',
  '-c', 'credential.helper=!gh auth git-credential',
  '-c', 'credential.helper=!glab auth git-credential',
  'fetch',
  '--progress',
  '--prune',
  '--recurse-submodules=no',
  '--jobs=4',
  '--all',
]
# pull/push probes unchanged
calls[3] contains 'pull', '--progress', '--recurse-submodules=no', '--ff-only'
calls[6] contains 'push', '--progress'
```

Add a new test `'defaultRemote fetch omits --all and --jobs'`:

```
await git.fetch('/repo', scope: FetchScope.defaultRemote);
expect(exec.calls.single, [
  'git', …both helpers…, 'fetch',
  '--progress', '--prune', '--recurse-submodules=no',
]);
expect(exec.calls.single, isNot(contains('--all')));
expect(exec.calls.single, isNot(contains('--jobs=4')));
```

`'a resolved environment pins fetch/push auth…'` — insert the new flags
in the expected fetch argv the same way.

`'network ops pass activityIdle'` — still maps by verb (`fetch` / `pull`
/ `push` / `ls-remote`). Count stays 7. `--progress` does not add calls.

`'pull mode maps to the right flag'` — each pull argv gains
`--progress --recurse-submodules=no` before the mode flag.

**Also** add `--progress` to the push-helper tests' expected `push` argv
(the github HTTPS helper test, the non-origin remote test).

**Verify**

```sh
dart format --output=none --set-exit-if-changed \
  lib/core/git/git_service.dart \
  lib/core/providers/app_providers.dart \
  test/mutations_test.dart \
  test/auto_fetch_test.dart \
  test/commit_dialog_test.dart \
  test/repo_status_view_test.dart \
  test/branches_view_guards_test.dart
flutter analyze
flutter test test/mutations_test.dart test/auto_fetch_test.dart \
  test/commit_dialog_test.dart
```

Then full `flutter test`. Commit.

**Phase 1 does not** stream output, change lanes, or change refresh.

---

### Phase 2 — refresh scope and in-flight own-mutation (H5, H6)

**Files**

* `lib/core/providers/app_providers.dart` — `OwnMutationTracker.begin` /
  `end`; `withOwnMutation`; `repoFetchFamilies`; `refreshAfterFetch`
  (`WidgetRef` + `Ref` if needed).
* `lib/core/providers/app_providers.dart` — `fetchInBackground` and
  `autoFetchProvider`: wrap the `fetch` in `withOwnMutation`, invalidate
  `repoFetchFamilies` instead of `repoMutationFamilies`. Auto-fetch:
  **remove** `ref.invalidate(remoteTagsProvider(repoPath))` (M2 starts
  here; completing it is Phase 5 — doing it now is required so H5 is
  not a lie. Tag listing after auto-fetch is Phase 5's leftover
  assertion).
* `lib/features/repository/repo_status_view.dart` — `_fetch` wraps the
  `git.fetch` in `withOwnMutation`. After `runLogged`, do **not** rely
  on `_refresh` (full mutation set). Add `runLogged` parameter in
  Phase 2: `{void Function()? refresh}` — when non-null, `finally`
  calls `refresh` instead of `refreshAfterAction`. `_fetch` passes
  `refresh: () => refreshAfterFetch(ref, repoPath)`.
* `lib/features/common/busy_action.dart` — the optional `refresh`
  parameter above. Default `null` → existing `refreshAfterAction()`.
* `lib/features/branches/branches_view.dart` — `_fetchPrune` same as
  `_fetch` (`withOwnMutation` + `refresh: () => refreshAfterFetch(...)`).
  **Keep** `refreshRemoteTags` here until Phase 5 (Branches Fetch Prune
  is an explicit "talk to the remote about tags too" gesture — actually
  no: MADR M2 says generic Fetch must not invalidate tags. Apply M2 to
  `_fetchPrune` as well in Phase 5; Phase 2 may leave that call).
* `test/busy_action_test.dart` — new case: `runLogged(..., refresh: ()
  { custom++; })` increments `custom` and does **not** increment
  `refreshAfterAction`.
* New `test/own_mutation_tracker_test.dart` (unit, no Flutter):
  * `begin` makes `isRecent(..., 3s)` true at t+10s (fake clock via
    injectable `now` **or** just call isRecent with `at: DateTime.now()`
    while in-flight — in-flight does not use the timestamp).
  * `end` then `isRecent` is true at `end+1s` and false at `end+4s`
    with an injected clock. Prefer adding `DateTime Function() now` to
    the tracker (default `DateTime.now`) so this is deterministic.
  * Nested begin/end: inner end does not `mark` while outer still
    in-flight.
  * `clear` drops in-flight so a reconnect cannot suppress.
* `test/repo_mutation_refresh_test.dart` — add the sibling scan
  described under Frozen API. Do not weaken the existing
  `repoMutationFamilies` scan.

**`OwnMutationTracker.now`:** add `final DateTime Function() _now;`
default `DateTime.now`. `mark` and `isRecent` use `_now()`. Tests pass
a fake. Production constructor stays zero-arg via
`OwnMutationTracker({DateTime Function()? now})`.

**Verify**

```sh
flutter analyze
flutter test test/own_mutation_tracker_test.dart \
  test/busy_action_test.dart \
  test/repo_mutation_refresh_test.dart \
  test/auto_fetch_test.dart \
  test/repo_status_watch_refresh_test.dart
flutter test
```

Commit.

---

### Phase 3 — busy gate (H3)

**Files**

* `lib/features/common/busy_action.dart` — `runLogged(..., {bool holdBusy
  = true, bool dock = false, void Function()? refresh})`. When
  `holdBusy` is false: do **not** set `_busy`, do **not** early-out on
  `_busy` (a mutation in flight still blocks via the caller's other
  path; a fetch must be allowed during a non-busy panel). Still
  `if (!mounted) return false`. Still `dock`. Still `refresh` /
  `refreshAfterAction` in `finally` (mounted-guarded).
* `lib/features/repository/repo_status_view.dart` —
  `_fetch` and `_push`: `holdBusy: false, dock: true`. `_sync` and
  `_pull`: `holdBusy: true` (default). `_syncUnavailability`: `busy`
  still blankets every verb (covers pull/commit). **Additionally**, if
  `operationActivityProvider` has a non-terminal record for this
  `repoPath` with `kind == OperationKind.synchronization`, set Fetch /
  Push / Sync (not Pull) to `'A fetch or push is already running'`.
  Pull stays clickable; exclusive will wait behind the sync. That is
  intentional: the user can pull, and Phase 4 then overlaps the fetch
  half… wait. If a fetch is running, pull's exclusive **waits for the
  sync to finish** (scheduler). Dim Pull too when a synchronization is
  running, same string. Stage/commit stay enabled (`busy` is false).
* `lib/features/branches/branches_view.dart` — `_fetchPrune`:
  `holdBusy: false, dock: true`. Other branch runLogged calls unchanged.
* `lib/features/common/repository_context.dart` / snapshot: `busy` on
  `RepositoryContextSnapshot` still means "a mutation is in flight".
  Do not overload it for fetch. The unavailability map is the fetch
  signal.
* `test/busy_action_test.dart` — `holdBusy: false` does not set
  `host.busy`; a concurrent `runGuarded` is still allowed (busy starts
  false). A `holdBusy: false` runLogged during an in-flight
  `runGuarded` (`busy == true`) **is allowed** (early-out is only
  `!mounted` and, when `holdBusy`, `_busy`). Spec: `if ((holdBusy &&
  _busy) || !mounted) return false;` — a fetch may start while a
  mutation is busy; the scheduler will order them (exclusive vs sync).
  Prefer **not** starting a fetch while `_busy` is true (index
  mutation in flight; fetch is safe by lane, but the UI is already in
  a mutation). Frozen rule:

  ```
  if (!mounted) return false;
  if (holdBusy) {
    if (_busy) return false;
    setState(() => _busy = true);
  }
  ```

  Fetch (`holdBusy: false`) during a commit (`_busy`) **is allowed**.
  Commit during a fetch is allowed (exclusive waits for in-flight
  reads, not for sync — wait: exclusive waits for `_activeSyncs == 0`.
  A commit during fetch **waits for the fetch**. That is correct.

* `test/repo_status_view_test.dart` — the test that taps Fetch and
  asserts `git.fetchCalls` still passes. Add: while a fetch Completer
  is outstanding, Stash / stage controls are **not** using the
  "Another repository operation is running" blanket. If that is hard
  to reach in the existing harness, assert `_syncUnavailability` via
  the Fetch button tooltip/reason instead: Fetch is dimmed with
  `'A fetch or push is already running'`, and the Stash button's
  `onStash` is still non-null (`onStash: busy ? null : _stashPush`
  today — after this phase `busy` is false during fetch, so Stash is
  enabled). Pin that: during in-flight fetch, `onStash` is non-null.

**Verify**

```sh
flutter analyze
flutter test test/busy_action_test.dart test/repo_status_view_test.dart
flutter test
```

Commit.

---

### Phase 4 — split `git pull` (H1)

**Files**

* `lib/core/git/git_service.dart` — replace the single `_run` of `git
  pull` with fetch-half + integrate-half as specified under Frozen
  API. Keep `_upstreamRemote` + `_forgeAuthArgs` on the fetch half
  (M1 has not landed). Do not pass `--all`, `--jobs`, or `--prune` on
  this fetch. Lane: fetch `ExecLane.sync`; integrate default exclusive.
* `test/mutations_test.dart` — `'fetch / pull / push'`: after the two
  probes, expect a `fetch` call **without** `--all` and a `merge
  --ff-only --no-edit` against `@{upstream}` (`--end-of-options`
  `@{upstream}`). The activityIdle loop must key off argv: the
  **fetch** and **push** git calls have `activityIdle ==
  networkTimeout`; the **merge** does not; the probes do not.
  `'network ops pass activityIdle'` currently counts `pull` as a
  network verb. After this phase there is no `pull` token. Change the
  network-verb set to `{'fetch', 'push', 'ls-remote'}`. Recalculate
  `networkCalls`: one `--all` fetch + one pull-fetch + one push +
  deleteRemoteBranch + pushTags + deleteRemoteTag + ls-remote = **7
  still** (the extra fetch replaces `pull`). The integrate merge is a
  `localCalls` entry with `activityIdle == null`.
* `'pull mode maps to the right flag'` — rebase → `git rebase
  --end-of-options @{upstream}`; merge → `git merge --no-edit
  --end-of-options @{upstream}`; explicit remote+branch → no upstream
  probe, `get-url origin`, fetch with `--end-of-options origin main`,
  merge `FETCH_HEAD`.
* `'pull omits the branch when no remote is given'` — fetch without
  positional remote, merge `@{upstream}`.
* New test `'pull fetch is sync; integrate is exclusive'`: inspect
  `exec.lanes` (add `List<ExecLane> lanes` on the mutations_test
  executor if it does not already record `lane` — `test/helpers/mock_executor.dart`
  already has `lane` on each recorded call; use that). Map by argv:
  the fetch that is not `--all` is `ExecLane.sync`; the following
  merge/rebase is `ExecLane.exclusive`.
* `test/repo_status_view_test.dart` — any stub `pull` override still
  compiles; no argv assertion required there.

**Do not** journal the integrate. **Do not** call `GitService.merge`.

**Verify**

```sh
flutter analyze
flutter test test/mutations_test.dart
flutter test
```

Commit.

**ARCHITECTURE_PLAN.md** is Phase 7, not this commit.

---

### Phase 5 — stream progress, cache probes, stop auto ls-remote, name-status (H2 stream, M1, M2, M3, M6)

**5a. `onOutput` on `execute`**

* `lib/core/ssh/ssh_command_executor.dart` — typedef + parameter on
  the interface and `SSHCommandExecutor.execute` / `_run` / `_runBody`.
  After decoding each chunk (the `Utf8Decoder` path), if `onOutput !=
  null` call `onOutput(chunk, stderr: false|true)`. Compressed path:
  one call on the gunzipped stdout string, `stderr: false`.
* `lib/core/exec/local_command_executor.dart` — same, on the decoded
  stream map (today it already maps chunks for `pulse`).
* `lib/core/exec/activity_command_executor.dart`,
  `scoped_command_executor.dart`, `proxy_command_executor.dart` —
  forward the parameter. Proxy does not invoke it.
* `lib/core/git/git_service.dart` `_run` — pass `onOutput` through.
  `fetch` / `pull` (both halves: only the fetch half) / `push` /
  `deleteRemoteBranch` / `pushTags` / `deleteRemoteTag` gain
  `CommandOutputCallback? onOutput`.
* Every test fake that overrides `execute` with the full named
  signature must add `CommandOutputCallback? onOutput` (or
  `void Function(String chunk, {required bool stderr})? onOutput`).
  This is mechanical. `rg -l 'Duration\? activityIdle' test lib` is
  the file list (the 50-odd overrides from Phase 0). Analyzer fails
  until they all match.
* `test/helpers/mock_executor.dart` — record `onOutput != null` if
  useful; default ignore.
* New `test/execute_on_output_test.dart` (local executor, real
  `Process.start`): run `sh -c 'echo out; echo err >&2'` with
  `onOutput` recording chunks; assert stdout and stderr were delivered
  **before** `execute` completed (Completer flipped inside the
  callback). Skip if writing a local-process test is too heavy: a unit
  test with a fake inner executor used by `ActivityCommandExecutor` is
  **not** enough (that only proves forwarding). Minimum: a
  `LocalCommandExecutor` test in `test/local_command_executor_test.dart`
  if that file exists; otherwise add one case next to
  `test/activity_deadline_test.dart` that uses `LocalCommandExecutor`
  against `['/bin/echo', 'hello']` (Darwin). `onOutput` must see
  `'hello\n'` (or `'hello\n'`-containing) with `stderr: false` before
  the future completes.

**5b. UI streaming**

* `lib/features/common/busy_action.dart` — `runLogged` does not start
  the stream (it does not know the command argv). Callers that pass
  `onOutput` own the session.
* `lib/features/repository/repo_status_view.dart` `_fetch` / `_push` /
  `_pull` / `_sync`:

  ```
  await runLogged(label, (log) async {
    final session = log.startStream(label);
    try {
      final result = await git.fetch/pull/push(..., onOutput: (chunk, {required stderr}) {
        session.append(chunk, stderr ? OutputLineKind.stderr : OutputLineKind.stdout);
      });
      session.close(exitCode: result.exitCode);
      // do NOT logResult the same stdout/stderr again
    } catch (e) {
      if (e is GitException) {
        session.close(exitCode: e.result.exitCode);
      } else {
        session.fail(e.toString());
      }
      rethrow;
    }
  }, ...);
  ```

  `_logPulled` / `_logPushed` stay **after** `session.close`, still
  inside `runLogged` for now — M3: move them **after** `runLogged`
  returns (so they are not on the Dock/`holdBusy` span). If they
  throw, swallow into `log.logError` — they are reporting, not the
  op. `_sync` logs two streamed commands (pull then push) as two
  `startStream` sessions in one `runLogged`.
* `lib/features/branches/branches_view.dart` — same for `_fetchPrune`,
  `_pushTag`, `_pushAllLocalOnly`, remote deletes that already
  `runLogged` a push.
* `test/push_logs_output_test.dart` — currently asserts `logResult`
  shape (`$ git push`, stderr lines, `✓ completed`). After streaming,
  the `$` header still exists (`startStream`), stderr still appears,
  `✓ completed` still appears. Update assertions to that, not to
  `logResult`'s exact ordering if it differed. Do not require the
  files-moved block to be inside the same `runLogged`.
* `test/output_log_stream_test.dart` — already covers `\r` frames;
  no change unless a regression shows up.

**5c. M1 probe cache**

* `GitService`: instance maps

  ```
  final _upstreamRemoteByRepo = <String, String>{};
  final _remoteUrlByRepo = <String, Map<String, String>>{};
  ```

  `_upstreamRemote`: return cached if present; else probe and cache
  (including the `'origin'` fallback). `_forgeAuthArgs`: cache the
  URL string per `(repoPath, remote)`; still compute helper argv
  each time from the URL (cheap, and honors later
  `configureEnvironment` path pins). No public flush. A new
  `GitService` per connection is the invalidation (existing
  `gitServiceProvider` lifetime).
* `test/mutations_test.dart` — new `'pull/push reuse cached upstream
  and get-url'`: two `push` calls; probes only on the first
  (`calls.where((c) => c == upstreamProbe).length == 1`, one
  `get-url`). Second push is just `git … push --progress`.

**5d. M2 / M6**

* Remove `refreshRemoteTags` from `RepoStatusView._fetch` and from
  `BranchesView._fetchPrune`. Keep it on tag push, remote tag delete,
  follow-tags push, `create_tag_sheet.dart`. Auto-fetch already
  dropped it in Phase 2.
* `FetchScope.defaultRemote` (and pull's fetch half): use
  `forgeGitAuthConfigArgs` for the probed URL, **not**
  `forgeGitAuthConfigArgsAll`. `--all` fetch still uses both helpers.
* Test: `'defaultRemote fetch uses the matching helper'` — stub
  upstream + `get-url` → GitHub HTTPS; defaultRemote fetch argv
  contains only the gh helper, not glab.

**5e. M3**

* `_logPulled` / `_logPushed` invoked after `runLogged` returns, still
  `if (mounted)`. Failures do not reopen the error dialog.

**Verify**

```sh
flutter analyze
flutter test test/mutations_test.dart test/push_logs_output_test.dart \
  test/output_log_stream_test.dart test/output_log_test.dart \
  test/busy_action_test.dart
flutter test
```

Commit. If the execute-signature fan-out is huge, it still belongs in
**this** commit (one interface change). Do not split 5a into its own
phase after the fact.

---

### Phase 6 — watcher excludes, Activity Center, background visibility (M5, L1, L2)

**M5**

* `lib/core/git/remote_watch_service.dart` `_watcherArgs`
  inotifywait arm (both `stdbuf` and fallback): add

  ```
  --exclude '/\.git/objects/'
  --exclude '/\.git/logs/'
  --exclude '\.lock$'
  --exclude '/\.git/fsmonitor--daemon/'
  ```

  immediately after `-e modify,create,delete,move` and before
  `--format`. Same flags on both sides of the `stdbuf` if.
* `test/remote_watch_service_test.dart` — the service currently does
  not assert argv of `executeStream`. Add a fake that records
  `executeStream` `gitArgs`; arm with a stub `inotifywait` probe
  (`stdout: 'inotifywait\n'`); expect the recorded argv's `sh -c`
  script contains all four `--exclude` patterns. If arming in unit
  tests is too involved, extract `_watcherArgs` to `@visibleForTesting`
  (it is already a private instance method — make it a top-level
  `remoteWatcherArgs(tool, bounded)` next to the class, as
  `boundedFswatchArgs` already is). Prefer the extract: call it from
  the class; unit-test the function with `tool == inotifywait`,
  `bounded == null`.

**L1**

* `lib/features/common/activity_center.dart` —
  `ActivityCenterList` with any non-terminal record: wrap in a
  `TickerMode` + `StatefulWidget` that `setState`s once per second
  (`Timer.periodic`). `_ActivityRow` elapsed text then updates.
  `ActivityCenterButton`: when `active > 0`, use
  `RotationTransition` (1 turn / 2 s, `repeat`) around the
  `arrow_2_circlepath` icon; stop the controller when `active == 0`.
* `test/activity_center_test.dart` — pump a running record, `tester.pump(
  Duration(seconds: 2))`, expect elapsed text to change from `0s` to
  containing `2s`. Button: `find.byType(RotationTransition)` when a
  running record exists.

**L2**

* `lib/core/exec/operation_activity.dart`
  `OperationActivityNotifier.report`:
  * `visibility == background` **and** phase is `queued` or `running`:
    **do** apply (show in-flight auto-fetch).
  * `visibility == background` **and** phase is terminal: apply so the
    running row leaves `running`, then **drop** that record from the
    store (do not keep a Completed/Failed auto-fetch row). Implement
    as: `apply`, then if terminal && background, remove that id from
    `_records`.
* `test/operation_activity_test.dart` — background queued→running
  appears; background succeeded leaves the list empty.

**Verify**

```sh
flutter analyze
flutter test test/remote_watch_service_test.dart \
  test/activity_center_test.dart \
  test/operation_activity_test.dart
flutter test
```

Commit.

---

### Phase 7 — docs (no behaviour)

**Files**

* `docs/ARCHITECTURE_PLAN.md` §0.1 Scheduling bullet: pull is fetch
  (sync, `--progress`) + merge/rebase (exclusive); fetch `--all` uses
  `--jobs=4`; post-commit fetch is default-remote; `--progress` is
  required so `ActivityDeadline` sees bytes.
* `docs/0020-MADR-fetch-pull-push-lag.md` — `status: accepted`,
  `verified:` today, one-line Remediation log pointing at the six
  phase commits. Do not rewrite historical findings.
* `docs/0020-PLAN-fetch-pull-push-lag.md` — `status: executed`,
  `executed:` today, list the commit SHAs.
* `docs/README.md` — 0020 MADR `accepted`, PLAN `executed`.

```sh
# no Dart; no tests required
```

Commit.

## Verification

Per phase, as listed. Full-suite gate:

```sh
flutter analyze
dart format --output=none --set-exit-if-changed $(git diff --name-only --cached -- '*.dart')
flutter test
```

Do not add `--run-skipped`. Do not run
`test/create_repo_wire_live_test.dart`.

**Manual (maintainer, not this plan):** on a real remote repo with more
than one remote, Fetch shows live `Receiving objects` in the Output
view; History does not flash; Pull still fast-forwards or refuses with
the existing error dialog; a post-commit ahead/behind update does not
contact extra remotes (observe argv in Output: no `--all`).

## Rollout and Rollback

* Each phase is one commit on the working branch. Rollback is
  `git revert` of that commit (or `git reset` if unpushed, maintainer
  only).
* Phase 4 is the only behaviour change vs stock `git pull` (two
  processes, integrate not journaled — same as today). If a
  ff-only refusal or rebase conflict is mis-handled, revert Phase 4
  only; Phases 1–3 stay.
* Phase 5's `onOutput` is optional; a proxy pop-out that ignores it
  is still correct.
* No settings migration. No entitlements change. Unsigned
  `build_macos.sh` is not required for this work.

## What this plan will not do

* `executeStream` for fetch/pull/push.
* `git merge` via `GitService.merge` (would journal a pull).
* `--prune` on pull's fetch half.
* `--jobs` on a single-remote fetch.
* Raising `GitService.defaultNetworkTimeout`.
* Fetch-All vs Fetch-Upstream as two toolbar buttons.
* Determinate Dock percentages for fetch.
* Cancellation of fetch/push.
* Submodule UI.
* Streaming `onOutput` over the secondary-window codec.
