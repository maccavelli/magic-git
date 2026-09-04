---
status: in-progress
date: 2026-09-03
associated-madr: "0022-MADR-git-gh-glab-engine-debug-audit.md"
---
# Implement the 2026-09-03 git/gh/glab engine-layer remediation backlog

Associated MADR: [0022-MADR-git-gh-glab-engine-debug-audit.md](0022-MADR-git-gh-glab-engine-debug-audit.md)

## Goal

Close every finding in 0022 — 5 HIGH, 11 MEDIUM, 6 LOW, 3 new (N1–N3), plus
H1' which replaces the refuted H1 — so that the git/gh/glab engine layer has
no known silent-failure path, no known data-integrity race, and no known
feature that is wired but unreachable.

"Closed" means one of three things, stated per item: **fixed with a
regression test that has been seen to fail**, **fixed without a test because
no seam exists** (justified in place), or **deliberately not fixed** with the
reason recorded. A finding that is merely "understood" is not closed.

## Scope

**In scope:** every finding in 0022, including its Corrections section, which
supersedes the original finding text wherever the two disagree.

**Out of scope, deliberately:**

* 0019 Phase 8 (maintainer-only live check on `admdevops`) — unchanged.
* 0010 Phase 7, and the 0007 Phase-12 items (submodules, LFS, Code Owners,
  stacked branches, commit signing) — each needs its own MADR.
* UI/UX presentation work not named by a 0022 finding.
* Any change to the `-uall` gating, porcelain parsing, scope injection in
  `GitService`, or cross-host invalidation — all verified correct; see the
  MADR's "Confirmed fixed / non-issues" list. **Do not re-open these.**

## Conventions that bind every phase

These come from `AGENTS.md` and the global agent rules. They are not optional
and are not restated inside each phase.

1. **Analyzer-clean on the first pass.** New code must satisfy
   `strict-casts`/`strict-inference`/`strict-raw-types`, `unawaited_futures`,
   `avoid_dynamic_calls`, `prefer_final_locals`, `prefer_const_constructors`.
   Write to those idioms rather than fixing lints afterwards.
2. **Never run `dart format` globally.** This repo is on the old dartfmt
   style and this environment's Dart uses the new "tall" style — a global
   format churns ~292 files. Format **only** the specific files edited.
3. **Never write commit message text.** A global `prepare-commit-msg` hook
   generates it from the staged diff. Commit with exactly
   `git commit --no-edit`. No `-m`, no `-F`, no heredoc, no trailers.
4. **Never `git push`** unless the maintainer asks in that same turn.
5. **Never run `live-forge`-tagged tests** unprompted — they create and
   delete real projects on real forges.
6. **A check is not trusted until it has been seen to fail.** Every new test
   below names the deliberate breakage that must make it fail. Run that
   breakage **against a scratch copy** (`/private/tmp/.../scratchpad`), never
   by dirtying the tree — reverting the tree afterwards is exactly the
   destructive-command-as-diagnostic the rules forbid. Read the whole failure
   output, not a `grep`/`head` slice.
7. **Deviations stop execution.** Anything this plan does not cover — a
   pre-existing defect surfaced by a new test, a step that is wrong as
   written, a file that must be touched but isn't listed — is a deviation:
   stop, present evidence and real resolutions (never workarounds), get a
   decision, record it as a dated entry in this plan's Execution Record, then
   proceed.
8. **Per-phase commit.** Each phase ends with one commit, gated on **no new
   analyzer issues and no new test failures relative to the Phase 0 baseline**
   — not on absolute cleanliness. This wording is deliberate and was forced by
   what Phase 0 actually found (see the Execution Record): the tree at HEAD
   carries 2 analyzer warnings from the maintainer's in-flight dependency
   bump, and the suite's true pass/fail set had to be established on a
   pristine clone before any phase gate could mean anything. "Green" is
   defined against that recorded baseline, and any *new* failure is a
   deviation. Phases are ordered so each is independently revertable.
9. **Baseline comparison is per-phase, not just at the end.** Compare the
   failing-test set, not the pass count: a phase that fixes one flaky test and
   breaks another nets to zero on the count and must not slip through.
9. **Searching:** `lib/core/providers/app_providers.dart`,
   `lib/core/git/git_service.dart`, and
   `lib/core/utils/git_porcelain_parser.dart` are misdetected as binary — use
   `grep -a` / `rg -a`. Exclude `.flutter-sdk/`, `build/`, `.dart_tool/`.

## Implementation Steps

### Phase 0 — Baseline

**Objective.** Establish exactly what fails *before* any change, so every
later failure is attributable. Not "prove the tree is green" — prove what its
actual state is.

**Method — take the baseline on a pristine clone, not the working tree.** Two
reasons, both learned the hard way in the first attempt (Execution Record):
the working tree carries the maintainer's uncommitted `analysis_options.yaml`
and `pubspec.lock` changes, so a working-tree baseline measures their work as
well as HEAD; and a baseline run must not overlap any editing, or it reads a
half-modified tree and is void.

1. `git clone --local <repo> <scratch>/baseline && cd <scratch>/baseline` —
   confirm `git log -1` is HEAD and `git status --short` is empty.
2. `flutter pub get`, then `flutter analyze`, then `flutter test`, writing full
   output to a file. **Nothing in the working tree may be edited while this
   runs.**
3. Record verbatim: the analyzer issue count and each issue; the final suite
   summary line; and **the complete list of failing test names** — the list,
   not the count.
4. In the working tree, `git status --short` — record pre-existing
   modifications and **leave them alone**. They are not this plan's to tidy.

**Acceptance.** The baseline analyzer issues and the baseline failing-test set
are both recorded verbatim. A non-green baseline does **not** block the plan —
it becomes the comparison set. What blocks the plan is an *unexplained*
baseline: if failures cannot be attributed (to the in-flight dependency bump,
to environment-sensitive goldens, or to a genuine pre-existing defect), stop
and report, because an unattributed failure set cannot serve as a gate.

---

### Phase 1 — H3: `SSHTransportNotReady` survives the pop-out relay

**Objective.** A detached-repo window shows the "still connecting" spinner,
not a raw developer string, exactly as the main window does (0018).

**Files.** `lib/core/exec/exec_proxy_codec.dart`,
`test/exec_proxy_codec_test.dart`, `test/window_manager_bridge_test.dart`.

**Steps.**

1. In `encodeExecuteError` (`exec_proxy_codec.dart:171-188`), add a fourth
   arm before the `_` default:
   ```dart
   SSHTransportNotReady(:final command) => {
     'ok': false,
     'error': 'transportNotReady',
     'command': command,
     // Also carry the text so a version-skewed OLD decoder, which falls to
     // its `default:` arm, degrades to today's behavior instead of
     // 'unknown proxy error'.
     'message': error.toString(),
   },
   ```
2. In `decodeExecuteResponse` (`:208-219`), add
   `case 'transportNotReady': throw SSHTransportNotReady(command);` alongside
   the other three.
3. Correct the two doc comments that now assert a false count: `:167-170`
   ("The three typed executor exceptions") and `:190-194` (which enumerates
   them). Say four, and name `SSHTransportNotReady`.
4. No change to `ProxyCommandExecutor`, `display_error.dart`, or
   `ssh_error_messages.dart` — verified unnecessary: `decodeExecuteResponse`
   is called outside the `try` at `proxy_command_executor.dart:170`, so the
   typed throw propagates untouched, and `isTransportNotReady` is an exact
   `is` test that the restored type satisfies. `uploadBytes` inherits the fix
   free via `encodeUploadBytesError` → `encodeExecuteError` (`:273-274`).

**Tests.**

* Extend `test/exec_proxy_codec_test.dart:200-237` ("each typed executor
  exception survives with its command") with a fourth `expect` in the
  identical idiom. `SSHTransportNotReady` is already in scope via the
  existing `ssh_command_executor.dart` import — no new import.
* Extend `test/window_manager_bridge_test.dart:197` ("serves execute calls:
  success and each typed error as envelopes") with the new envelope.

**Negative test (must be seen to fail).** In a scratch copy, delete the new
`case 'transportNotReady'` from the decoder and run the codec test; it must
fail with a `ProxyExecuteException` where `SSHTransportNotReady` was
expected. Record the failure text.

**Acceptance.** Both tests pass; both fail with the fix reverted; analyzer
clean; suite green. Commit.

---

### Phase 2 — H4: a mid-dial host switch can no longer finalize the wrong host

**Objective.** Make "finalize host A's live session into host B's saved
connection" unrepresentable, and stop the UI from allowing the switch that
triggers it.

**Files.** `lib/core/providers/app_providers.dart`,
`lib/features/workspace/clone_sheet.dart`,
`lib/features/workspace/create_repo_sheet.dart`, a new shared file under
`lib/features/workspace/`, `test/connection_provisioning_test.dart`,
`test/clone_sheet_test.dart`, `test/create_repo_sheet_test.dart`,
`test/add_existing_repo_sheet_test.dart`.

**Steps.**

1. **Controller guard (the load-bearing half).** In `finalizeProvisioned`
   (`app_providers.dart:2422+`), extend the existing token check at `:2430`
   to also require identity:
   ```dart
   if (token != _attempt || conn.id != _lastConnectionId || !ref.mounted) {
     return false;
   }
   ```
   This is sound because `beginProvisioning` sets `_lastConnectionId = conn.id`
   (`:2335`) and the only other writer, `connect()` (`:1270`), bumps
   `_attempt` — so whenever `token == _attempt` holds, `_lastConnectionId` is
   necessarily the id that minted the token.
2. Amend `finalizeProvisioned`'s doc comment at `:2417-2418`, which currently
   says it returns false *only* when superseded. It now also returns false on
   identity mismatch. **This is required, not cosmetic** — both sheets render
   a "cloned/created but could not be opened" message on `false`, which would
   otherwise be misleading for the new cause.
3. **Extract the shared sheet logic.** Create
   `lib/features/workspace/workspace_provisioning.dart` holding a mixin on
   `ConsumerState` with `provisionToken`, `provisioning`,
   `ensureProvisioned()`, `resetProvisioning()`, and `connectionById()`,
   parameterised by abstract `String? get destConnectionId` and
   `WorkspaceTarget get target`. Rationale, recorded here because the
   alternative is defensible: `_ensureProvisioned`, `_resetProvisioning`,
   `_connectionById`, and `_register`'s `sshProvision` case are **byte-for-byte
   identical** between the two sheets today, and
   `lib/features/workspace/workspace_registration.dart:1-4` already exists to
   de-duplicate the sibling concern with a header stating that doctrine.
   Patching twice would leave four copies of a guard to keep in sync.
4. In the mixin's `ensureProvisioned()`, adopt the **already-reviewed
   in-repo pattern** from `lib/features/connection/local_repo_form.dart:295-325`
   verbatim in shape — all three refinements, not just the identity check:
   * capture the notifier **before** the await (`ref` is unusable after
     dispose; the controller outlives the sheet);
   * guard `if (!mounted || destConnectionId != conn.id)`, and **await** the
     abort rather than `.ignore()`ing it;
   * clear `provisioning` on that early return. **This is load-bearing:**
     both sheets' wizard-step predicate is `valid: () => !_provisioning`
     (`clone_sheet.dart:115`, `create_repo_sheet.dart:188`), so returning
     with it still true permanently disables Continue and bricks the sheet.
5. Gate both Destination dropdowns on `_provisioning` as well as
   `_submitting`: `clone_sheet.dart:573` and `create_repo_sheet.dart:1353`
   become `onChanged: (_submitting || _provisioning) ? null : _onDestChanged`,
   matching `local_repo_form.dart:669-671`.
6. Leave the two sheets' genuine divergence alone — `clone_sheet`'s
   `_onDestChanged` eagerly re-dials, `create_repo_sheet`'s does not.

**Tests.**

* **Controller (primary).** Add to `test/connection_provisioning_test.dart`,
  modelled on the existing "a disconnect mid-provision makes finalize a no-op"
  test at `:239-262`: add a `_conn2()` fixture with `id: 'c2'`, `begin()` with
  `_conn()`, then call `finalizeProvisioned(token: token, conn: _conn2(), …)`
  and assert it returns `false`, `store.updated` is empty, and the phase did
  not become `connected`.
* **Sheet (secondary).** In `clone_sheet_test.dart` and
  `create_repo_sheet_test.dart`, extend `_StubConnection` with a gated
  `beginProvisioning` (returns a `Completer` the test releases) plus
  recording `finalizeProvisioned`/`abortProvisioning`. Assert that switching
  destination mid-dial aborts the first session and does not adopt its token.
  Use `appProviderScope` (`test/helpers/app_scope.dart`) — note
  `clone_sheet_test.dart:134` currently uses a bare `ProviderScope`; the new
  test uses the house standard.
* **Backfill.** `local_repo_form.dart`'s existing fix has **no test at all**.
  Add the equivalent mid-dial-switch test to
  `test/add_existing_repo_sheet_test.dart` — the pattern being propagated
  should itself be pinned.

**Negative test (must be seen to fail).** In a scratch copy, invert the
controller guard to `conn.id == _lastConnectionId` and confirm the new
controller test fails. Separately confirm the sheet test fails with the
dropdown gate reverted.

**Acceptance.** All four tests pass and fail when reverted; analyzer clean;
suite green. Commit.

---

### Phase 3 — H2 + L6 + N3(b): forge calls are scope-aware for bare/dotfiles repos

**Objective.** A scoped (dotfiles) repo with a real forge remote gets a
working Forge tab, browsable URLs, resolvable auth status, and an actually
successful token login.

**Files.** `lib/core/providers/app_providers.dart`, one new test file.

**Steps.**

1. **`finalizeProvisioned` token login** (`:2478-2496`). Do **not** substitute
   `ref.read(glabServiceProvider)` — verified wrong: the resolver behind
   `scopedForgeExecutorProvider` reads `connectionProvider.scopedGitDirs`,
   which is not published until `:2544`, *after* these logins run, so the
   substitution would silently no-op. Instead build an ad-hoc wrapper from the
   method's own parameters:
   ```dart
   final forgeExec = gitDir.isEmpty
       ? _activeExecutor
       : ScopedCommandExecutor(
           _activeExecutor,
           (p) => p == repoPath
               ? {'GIT_DIR': gitDir, 'GIT_WORK_TREE': repoPath}
               : null,
         );
   ```
   then `GlabService(forgeExec)` / `GhService(forgeExec)`. Add the
   `scoped_command_executor.dart` import if absent.
2. **Three read-lane providers** — one-line executor swap each, from
   `activeExecutorProvider` to `scopedForgeExecutorProvider`:
   * `originRemoteUrlProvider` `:4951`
   * `forgeProvider` `:4973`
   * `sessionAuthStatusProvider` `:5162` →
     `AuthProbeService(ref.read(scopedForgeExecutorProvider))`. No signature
     change to `AuthProbeService`: it already passes its `cwd` straight
     through as `execute(repoPath: cwd, …)` (`auth_probe_service.dart:107`),
     which is the same key `ScopedCommandExecutor` matches on.
   **No cycle risk** — verified. These are leaf providers, and
   `scopedForgeExecutorProvider` depends only on `activeExecutorProvider` →
   `backendProvider`. The hard constraint to respect (documented at
   `app_providers.dart:202-218` and `:1100-1104`): never `ref.watch`
   `connectionProvider` anywhere on the path from `activeExecutorProvider` to
   a service, or every `ref.read(gitServiceProvider)` inside
   `ConnectionController` becomes `CircularDependencyError`. The existing
   `ref.read`-inside-the-closure idiom is what keeps that edge absent — keep it.
   `ExecLane.read` work resolves no descriptor
   (`scopedForgeExecutorProvider:323`), so this adds no Activity Center noise.
3. **L6 alignment.** `forgeRepoListProvider:5050` → `scopedForgeExecutorProvider`
   for the non-local branch. Keep the `local` branch on
   `localExecutorProvider` — it deliberately targets this Mac regardless of
   session backend. Latent today (`listRepos(host:)` takes no `repoPath`);
   aligned so a future edit that threads a `repoPath` through cannot silently
   reintroduce this bug class.
4. **N3(b) stale comment.** Correct `app_providers.dart:2205-2209`, which
   claims `activeExecutorProvider` watches `connectionProvider` and would
   trip the cycle guard. That is false (`:230-239`, `:202-218`), and
   `_connectForgeLogins` ships against the opposite. Replace the rationale
   with the true one: *`state.scopedGitDirs` is not published until `:2544`,
   after these logins run.* Also update the pointer at `:2476-2477`, which
   inherits the false premise.
5. **Do not touch** `connect()`'s logins (`:1652-1664`) — already correctly
   scoped and correctly ordered — or `connectLocal()`, which performs no
   token login at all.

**Tests.** New file `test/scoped_forge_providers_test.dart`, using
`appProviderContainer` with `connectionProvider.overrideWith(() => stub)`
(a `_StubConnection` carrying
`scopedGitDirs: {'/home/user': '/home/user/.home.git'}`) and
`activeExecutorProvider.overrideWithValue(recordingExecutor)`. Assert the
recorded `extraEnv` on the `git remote get-url origin` issued by
`originRemoteUrlProvider` and `forgeProvider`, and on the probe issued by
`sessionAuthStatusProvider`. For `finalizeProvisioned`, follow
`connection_provisioning_test.dart`'s idiom, overriding `executorProvider`
(the notifier reads that directly via `_activeExecutor`, **not**
`activeExecutorProvider`) and asserting `GIT_DIR` reaches the login's
`get-url`.

**Negative test (must be seen to fail).** Revert one provider to
`activeExecutorProvider` in a scratch copy; the corresponding assertion must
fail with a null/absent `GIT_DIR`.

**Live verification (flagged unverified in the MADR).** Ask the maintainer to
confirm on a real bare/dotfiles repo with a forge remote that the Forge tab
populates. Static tests prove the env reaches the command; only a live host
proves the end-to-end claim.

**Acceptance.** Tests pass and fail when reverted; analyzer clean; suite
green. Commit.

---

### Phase 4 — M7: the live scope registry no longer leaks across delete/repoint/switch

**Objective.** A stale `GIT_DIR`/`GIT_WORK_TREE` overlay can never be
inherited by an unscoped repo opened at a path a scoped repo just vacated.

**Files.** `lib/core/providers/app_providers.dart`,
`lib/features/switcher/connection_switcher.dart`, `test/git_service_test.dart`,
one container-level test.

**Steps.**

1. **`setRepoPath`** (`app_providers.dart:2156-2161`) currently only *adds*
   scope. Add the negative branch:
   ```dart
   } else {
     ref.read(gitServiceProvider).unregisterRepoScope(path);
   }
   ```
   `ConnectionState.scopedGitDirs` is the documented durable source of truth,
   so a path absent from it must not be scoped in the registry. Note this also
   restores correct `-uall` behavior, since `isRepoScoped` gates untracked-file
   semantics at `git_service.dart:1976` and `:2050` — a stale registration
   changes more than env.
2. **`_deleteRepo`** (`connection_switcher.dart:821-858`). After
   `if (!saved) return;` (`:851`), and guarded on the live connection being
   this one (`current.connectionId == conn.id`), call
   `unregisterRepoScope(repo)` **before** `notifier.setRepoPath(newDefault)`.
   It must run whether or not `current.repoPath == repo`, because connect
   registers *every* scope the connection carries (`:1428-1431`), not just the
   active repo. Check `_deleteConnection` (the `remaining.isEmpty` early
   return at `:828-831`) for the same leak.
3. **`_editRepo`** (`:896-968`). After `if (!saved) return;` (`:949`), when
   `pathChanged` and the live connection matches, `unregisterRepoScope(repo)`
   for the **old** path only. Do **not** register the new path live —
   consistent with the existing `setFsmonitor` contract at `:950-954` ("across
   a repoint it applies on the next connect").
4. **Record a known limitation rather than silently widening scope.**
   `ConnectionState.scopedGitDirs` is written only by `connect()`,
   `connectLocal()`, and `finalizeProvisioned()` — it is *not* updated when
   the switcher edits the saved connection mid-session, and no
   `copyWith(scopedGitDirs:)` mutator exists on the controller. So these
   unregisters make the registry consistent with the **live session state**,
   which itself can lag the saved connection until reconnect. Making switcher
   edits take effect live is a **deviation** if it turns out to be needed —
   stop and ask rather than adding a mutator on the fly.

**Tests.** Extend `test/git_service_test.dart`'s registry group for the
primitive. Add a container test asserting `setRepoPath` to an unscoped path
clears a previously registered scope (assert via `isRepoScoped`).

**Negative test.** Remove the `else` branch in a scratch copy; the
`setRepoPath` test must fail.

**Acceptance.** Tests pass and fail when reverted; analyzer clean; suite
green. Commit.

---

### Phase 5 — M6 + N1: bounded watch arming stops failing silently

**Objective.** Arming a bounded watch never dies on a directory that doesn't
exist yet, and a failed tracked-file fetch degrades to polling instead of
killing the watcher.

**Files.** `lib/core/git/bounded_watch.dart`,
`lib/core/providers/app_providers.dart`, `test/bounded_watch_test.dart`,
`test/remote_watch_service_test.dart`.

**Steps.**

1. **M6(a) — fswatch has no existence guard and fswatch errors on a missing
   path.** `boundedFswatchArgs` (`bounded_watch.dart:148-154`) is argv-direct
   with no shell, so the guard cannot live in the argv. Two options; **choose
   (i)** unless the maintainer prefers otherwise:
   * (i) Filter at the caller: have the arming path drop non-existent
     directories before building argv. On the remote backend existence must be
     probed on the host, so wrap in the same `sh -c` shape
     `boundedInotifyScript` already uses (`set -- …; for d; do [ -e "$d" ] …`)
     and `exec fswatch "$@"`. Keeps the guard where the paths are.
   * (ii) Leave argv alone and accept that a tagless repo on a macOS remote
     host cannot use bounded fswatch. Not recommended — silent.
   The local backend needs no guard: a live reproduction confirmed macOS
   `Directory.watch()` self-heals on a path created later (FSEvents watches by
   path, not inode). Record that in the code comment so it is not "fixed"
   later by someone assuming symmetry.
2. **M6(b) — `exit 0` on an empty filtered list.**
   `boundedInotifyScript:138` exits 0 when every path is missing, which
   `RemoteWatchService` reads as a clean death → `scheduleRestart` → three
   restarts → polling, with no diagnostic. Make the empty case explicit: exit
   with a distinct non-zero status and have the service map it to
   `WatchUnavailable` (which is the honest state, and already degrades to
   polling *with* periodic recovery) rather than burning the restart budget.
3. **N1 — `Stream.fromFuture` kills the provider on a failed
   `listTrackedFiles`.** In `repoWatchProvider`
   (`app_providers.dart:3339-3349`), catch the failure and fall back to
   arming **unbounded-but-degraded** rather than erroring the stream. Prefer:
   on failure, arm with a spec containing only the git-dir points (which
   `computeBoundedWatchSpec` already produces for an empty tracked list,
   `bounded_watch.dart:71-72`) so git-state changes are still seen, and log
   it. Erroring the whole provider is never acceptable here — it silently
   stops all refresh for the repo.

**Tests.** `test/bounded_watch_test.dart` for the new script/argv shapes
(pure unit, no async, matches the existing idiom).
`test/remote_watch_service_test.dart` (fake executor + `fakeAsync`) for the
empty-list → `WatchUnavailable` mapping. A container test for N1's fallback.

**Negative test.** Point a bounded spec at a directory that does not exist in
a scratch fixture and confirm the pre-fix code fails to arm while the fixed
code arms the surviving paths.

**Acceptance.** Tests pass and fail when reverted; analyzer clean; suite
green. Commit.

---

### Phase 6 — H5: the bounded watch re-arms when the tracked set changes

**Objective.** A scoped repo keeps seeing real changes after `git add` in a
directory that was not tracked when the watcher armed.

**Files.** `lib/core/git/watch_lifecycle.dart`,
`lib/core/git/remote_watch_service.dart`,
`lib/core/git/local_watch_service.dart`,
`lib/core/providers/app_providers.dart`, `test/watch_lifecycle_test.dart`,
`test/local_watch_bounded_test.dart`.

**Steps.**

1. **Change the spec from a value to a supplier.** Today
   `RemoteWatchService.watch` (`:111`) and `LocalWatchService.watch` (`:138`)
   take `BoundedWatchSpec? bounded` and capture it lexically, and
   `watchLifecycle` re-invokes the same `arm` closure on every restart
   (`watch_lifecycle.dart:198-240`) — that is the mechanical root of H5.
   Change both signatures to accept a recompute callback (e.g.
   `Future<BoundedWatchSpec> Function()?`) and have `arm` call it each time.
   `repoWatchProvider` (`app_providers.dart:3334-3352`) stops doing the fetch
   itself via `Stream.fromFuture(...).asyncExpand(...)` and passes the closure
   down instead. This also subsumes Phase 5's N1 handling — keep the failure
   fallback there.
2. **Fix the local backend too.** `local_watch_service.dart:145-150` computes
   `roots` once *outside* `watchLifecycle`. Its justifying comment ("the
   layout of a checkout can't change while it's open") is true for the
   linked-worktree case and **false** for the bounded case. Move the bounded
   computation inside `arm` and amend the comment to say which case it covers.
3. **Add a distinct re-arm trigger — do not reuse `scheduleRestart`.** Add a
   `rearm()` hook to `WatchHooks` that calls `start()` **without**
   `scheduleRestart`'s side effects: no `mode = WatchMode.stopped`, no
   spurious grey tick (`:166-172`), no backoff, no restart-budget consumption
   (`:162-165`). Reusing `scheduleRestart` would paint the UI as "watcher
   stopped" every time the user stages a file.
4. **Drive it from an index-touching event, debounced.** Verified achievable:
   `.git/index` already flows through the bounded pipeline —
   `computeBoundedWatchSpec` always watches the git-dir root
   (`bounded_watch.dart:86`), `relativizeBoundedEvent` maps it to `.git/index`
   (`:110-113`), `shouldTriggerWatch('.git/index')` is true
   (`watch_path_filter.dart:22-30`), and
   `RepoWatchEvent.touchesGitState` reports it
   (`watch_event.dart:59-60`) — proven by
   `test/local_watch_bounded_test.dart:125-135`. Hook the trigger **inside the
   service's arm callback**, which sees raw paths before the coalescer and
   before `_withoutIgnoredPaths`; the provider level is not viable (it sits
   behind both and holds no re-arm handle).
5. **Debounce and fail safe.** `listTrackedFiles` is `ExecLane.read`,
   `retries: 1`, `compress: true`, and resolves no `OperationDescriptor`
   (`git_service.dart:1186-1201`, `:6202-6203`) — so repeated calls are
   non-blocking and won't spam the Activity Center, but it is still a full
   index walk. Debounce (suggest ≥2s trailing). It **throws** `GitException`
   on non-zero exit — catch it and **keep the existing spec** rather than
   tearing the watcher down.

**Tests.** `test/watch_lifecycle_test.dart` (`fakeAsync` + captured
`WatchHooks`, the file's existing idiom) for: `rearm()` re-invokes `arm`;
`rearm()` emits no `stopped` tick; `rearm()` does not consume the restart
budget. `test/local_watch_bounded_test.dart` (real git, real FSEvents) for
the end-to-end case: `git add` a file in a **new** directory, then edit that
file, and assert an event arrives — the exact scenario that fails today.

**Negative test.** The integration test above **is** the negative test: run it
against the unmodified tree first and confirm it times out waiting for the
event. Record that output.

**Acceptance.** Tests pass and the integration test fails on the unmodified
tree; analyzer clean; suite green. Commit.

---

### Phase 7 — M1 + M2: GitService cache invalidation and lane correctness

**Objective.** Forge credential-helper selection follows the current branch,
and previewing a commit message never freezes the app.

**Files.** `lib/core/git/git_service.dart`, `test/mutations_test.dart`, one
new test.

**Steps.**

1. **M1.** `_upstreamRemoteByRepo` and `_remoteUrlByRepo`
   (`git_service.dart:1059-1062`) have **no** `.clear()`, `.remove()`, or any
   invalidation anywhere in the file, and are keyed by `repoPath` only.
   Invalidate both for the repo in `checkout` (`:3310`) and
   `checkoutTrackingBranch` (`:3337`). `checkoutTrackingBranch` is the sharper
   case — it *creates* the tracking relationship, so the stale entry is wrong
   by construction. Also sweep for other upstream-changing commands
   (`grep -a -n "set-upstream\|remote rename\|remote set-url"`); any found are
   in scope for the same invalidation.
2. **M1(b).** `:4898` permanently memoizes the `'origin'` fallback, so a repo
   whose HEAD was detached or unborn at first pull answers `origin` forever.
   Do not cache the fallback — only cache a genuine lookup (`:4893`).
3. **M2.** `generateCommitMessage` (`:3292-3297`) passes no `lane:`, taking
   `ExecLane.exclusive` with the 5-minute `commitTimeout`. Change to
   `lane: ExecLane.isolated`. Justification, from the lane's own doc
   (`command_lanes.dart:33-51`): `isolated` is precisely "long-running side
   work" that touches neither index/worktree/refs nor the network resources
   `sync` serializes, and its canonical case is a user-supplied hook. `read`
   would be wrong on the letter of its doc — the script does create and delete
   a `mktemp` file under the git-dir.
   **State the residual risk in the code comment:** a *user-authored*
   `prepare-commit-msg` hook could in principle run git commands that touch
   the index; git's contract for that hook is "edit the message file", but
   nothing enforces it. If the maintainer judges that unacceptable,
   `ExecLane.sync` is the conservative middle — it still avoids holding the
   exclusive barrier for five minutes. **Ask rather than assume** if there is
   any doubt; this is the one lane change in the plan.

**Tests.** M1 has **zero** existing coverage of any kind (`grep` for
`upstreamRemote`/`_forgeAuthArgs` in `test/` returns nothing) — author the
first: check out a branch tracking `upstream`, pull (populating the cache),
check out a branch tracking `origin`, pull again, assert the second command's
argv carries `origin`'s helper. For M2, extend
`test/mutations_test.dart:1591-1610`; the fake executor there must be taught
to record the `lane:` argument.

**Negative test.** Both tests must fail on the unmodified tree — the M1 test
by construction (it is the bug), the M2 test once lane recording exists.

**Acceptance.** Tests pass and fail when reverted; analyzer clean; suite
green. Commit.

---

### Phase 8 — M3: pop-out mutations report to the right Activity Center

**Objective.** A commit or push run in a detached-repo window appears in that
window's Activity Center, not the main window's.

**Files.** `lib/core/exec/operation_activity.dart`,
`lib/core/exec/proxy_command_executor.dart`,
`lib/core/providers/window_manager_bridge.dart`,
`lib/features/window/secondary_window_main.dart`,
`test/window_manager_bridge_test.dart`, `test/secondary_window_app_test.dart`.

**Steps — all three defects, or the pop-out still shows nothing.**

1. **Define an `OperationEvent` wire form.** `OperationDescriptor` already has
   `toWire`/`fromWire` (`operation_activity.dart:84`, `:96`);
   `OperationEvent` (`:130-151`) has none. Add them **on the class**, matching
   where the descriptor's live, so the codec stays channel-free. Mapping:
   `id` → String, `descriptor` → `toWire()`, `phase` → `.name`, `occurredAt` →
   `millisecondsSinceEpoch` (the convention already used at
   `window_manager_bridge.dart:453`), plus `result`, `outputAnchorId`,
   `undoable`, `recoveryAvailable`. **No safe default for `phase`** — an
   unrecognized phase must drop the event.
2. **Route events back to the originating window.** In the hub's execute
   handler (`window_manager_bridge.dart:610-612`), the callback is hard-bound
   to `execContainer`'s notifier. The originating window `id` is in scope at
   `:542`. Push the event to that window using the established per-window
   fire-and-forget idiom (`_hubs[id]?.invokeMethod<void>(…).catchError((_) {})`,
   exactly as `_pushTick` does at `:447-461`).
3. **Handle it in the child.** Add `case 'operationEvent':` to
   `secondary_window_main.dart:565-586`, guarding `args is Map<Object?, Object?>`
   (the file's stated posture: "wire data — never hard-cast"), decoding, and
   calling `ref.read(operationActivityProvider.notifier).report(event)`.
4. **Relay the whole lifecycle, in order.** `OperationActivityStore.apply`
   drops any event whose first phase is not `queued` (`:299`), so `queued`
   must be forwarded, not just the terminal phase. `_isForward` (`:349-359`)
   rejects out-of-order transitions, so wire reordering degrades to dropped,
   not corrupt.
5. **Stop `ProxyCommandExecutor` silently discarding the callback.** It
   accepts `OperationEventCallback? onOperationEvent`
   (`proxy_command_executor.dart:115`) and never uses it. Either honor it or
   remove the parameter — a parameter that is accepted and ignored is how this
   defect stayed invisible.
6. **Correct the false comment** at `secondary_window_main.dart:178` claiming
   the child's `gitServiceProvider` is "identical construction … except undo
   records". It has neither the `ActivityCommandExecutor` wrap nor
   `onOperationEvent`.
7. **Ordering assumption to record:** the terminal event is emitted before
   `encodeExecuteResult` returns (`window_manager_bridge.dart:614`), so the
   push and the reply race on the same hub channel. Both are ordered platform
   messages, so the push arrives first. State this in a comment — the child's
   `ownMutationTracker` marking happens on the reply path
   (`proxy_command_executor.dart:171-173`).

**Tests.** Bridge side: extend `window_manager_bridge_test.dart`, whose
`hubCalls` capture list (`:147-150`) is exactly the seam — assert an
`operationEvent` push occurs, driven by a `_FakeExecutor` that *invokes* the
`onOperationEvent` it already accepts. Child side: extend
`secondary_window_app_test.dart` using its `pushHubEvent` helper (`:200-206`)
and assert `operationActivityProvider` reflects the event. **Note the
limitation:** that file's `pump` builds a bare `ProviderScope` and does not
apply production `runApp` overrides, so a test asserting the *override's*
wiring needs the override list extracted to a testable seam, or the assertion
made at `_onHubCall` level. Choose the latter unless extraction is cheap.

**Negative test.** Drop the child's `case 'operationEvent'` in a scratch copy;
the child-side test must fail.

**Acceptance.** Tests pass and fail when reverted; analyzer clean; suite
green. Commit.

---

### Phase 9 — M4: closed PRs/MRs can be reopened

**Objective.** Closing a PR/MR from Magic Git is no longer a one-way door.

**Files.** `lib/core/github/gh_service.dart`, `lib/core/gitlab/glab_service.dart`,
`lib/features/github/github_panel.dart`, `lib/features/gitlab/gitlab_panel.dart`,
`lib/features/forge/issue_actions.dart` (test only),
`test/forge_context_menu_test.dart`, `test/forge_issue_actions_test.dart`.

**Steps.**

1. **List state is a prerequisite, not optional.** `pullRequests()` hardcodes
   `--state open` (`gh_service.dart:376-377`); `mergeRequests()` passes no
   state flag and gets GitLab's `opened` default (`glab_service.dart:539-579`).
   A closed item is invisible, so a reopen action has nothing to act on.
   Widen both to accept a state. **Models need no change** — `PullRequest`
   (`github/models.dart:85-246`) and `MergeRequest` (`gitlab/models.dart:57-183`)
   already carry `state`.
2. **Surface the state choice as a watched notifier, not a family key.** The
   in-repo precedent is `CiHistoryScope`/`workflowRunsScopeProvider`
   (`app_providers.dart:4884+`, `:5180-5184`), whose doc explicitly explains
   why. A family key would break ~14 widget-test overrides.
3. **Normalize the open-state asymmetry.** GitHub says `open`, GitLab says
   `opened`. `forgeIssueIsOpen` (`issue_actions.dart:25-28`) already exists for
   exactly this — reuse it rather than adding a second predicate.
4. **Wire the action, mirroring close exactly.** `reopenPullRequest`
   (`gh_service.dart:1099-1108`) and `reopenMergeRequest`
   (`glab_service.dart:1631-1638`) already exist and are tested. Add
   `_reopenPr`/`_reopenMr` shaped like `_setPrDraft` (`github_panel.dart:1276-1288`)
   — no confirm needed for a non-destructive action, matching the issue
   precedent — using `_busyPrs`/`_busyMrs` and `_invalidateChangeRequest`
   (`:1039-1051`), **not** the ad-hoc invalidate that `_closePr` uses.
5. **Both surfaces, or neither.** Add to the row context menu *and* the detail
   "More" pulldown (`_prMorePulldown:897-929`, `_mrMorePulldown:943-967`),
   whose own doc states that invariant. Use the issue precedent's
   `if (isOpen) Close else Reopen` branch and icon canon
   (`issue_actions.dart:254-270`).
6. **Structural choice (state it in the commit):** add per-panel
   `_reopenPr`/`_reopenMr` (smallest diff, consistent with each panel's
   existing private-method style) rather than extracting a shared
   `ForgeChangeRequestActions`. Extraction is the tidier long-term shape but
   is a larger refactor of two 1000-line panels and is not required by any
   finding here.
7. **Update the now-wrong copy** that assumes open-only lists:
   `dashboard_sheet.dart:687-688` ("open PRs"/"open MRs" counts),
   `forgeCountLabel` call sites (`github_panel.dart:376`,
   `gitlab_panel.dart:411`), and the hardcoded `'No open pull requests'` /
   `'No open merge requests'` empty text.

**Tests.** Extend `test/forge_context_menu_test.dart` (its fakes are
real-service subclasses, e.g. `_Phase2Gh:75-121` — add a `reopened` list) with
`state: 'closed'` twins of the `_readyPr`/`_readyMr` fixtures. **Also backfill
the precedent:** `forge_issue_actions_test.dart`'s `_issue` fixture is always
`state: 'open'`, so the issue Reopen branch (`issue_actions.dart:264-269`,
`:373-377`) has **zero** coverage today — add it.

**Negative test.** Invert `isOpen` in a scratch copy; the menu test must fail.

**Acceptance.** Tests pass and fail when reverted; analyzer clean; suite
green. Commit.

---

### Phase 10 — H1' + N2 + L5: glab field handling made version-independent

**Objective.** Remove the trap that would turn a refuted finding into a real
one, and fix the merge-message correctness bug next to it.

**Files.** `lib/core/gitlab/glab_service.dart`,
`lib/features/gitlab/gitlab_panel.dart`, `test/mutations_test.dart`,
`test/glab_service_test.dart`.

**Steps.**

1. **N3(a) — fix the trap first.** `glab_service.dart:461` documents `-f` as
   "`--field`". It is `--raw-field`; `--field` is `-F` and *is* the flag that
   does `@filename` substitution. Correct the comment.
2. **Pin it in source, not prose** (the repo's *enforce-in-source-not-docs*
   rule). Add a test asserting `api()` emits `-f` and **never** `-F`. This is
   the durable fix: the comment was the only thing suggesting otherwise, and a
   comment cannot fail a build.
3. **Decide the version-independence question — this needs a maintainer
   decision, so present it rather than choosing unilaterally.** The app drives
   `glab` on hosts whose version it does not control, and glab's own 1.116
   help documents that `--raw-field` handling has changed across versions.
   Options:
   * **(a) Route the two text-bearing fields through `glab mr merge`
     subcommand flags** (`--squash-message`, `-m`), which is the in-repo
     convention for every other text-bearing mutation
     (`glab_service.dart:1064-1076`, `:1667-1670`) and what the GitHub side
     already does (`gh pr merge -t/-b`). **Mandatory if chosen:** pass
     `--auto-merge=false` (glab's `--auto-merge` defaults to **true** —
     merge-when-pipeline-succeeds) and `-y` for non-interactive. **Costs:**
     forfeits the `-i` HTTP-status cross-check that hardens against glab's
     advisory exit codes (the very reason these two methods use REST today,
     documented at `:1544-1547`); inverts two assertions at
     `test/glab_service_test.dart:1397-1411` that currently pin the
     anti-subcommand invariant; those doc comments must be amended.
   * **(b) Keep REST `-f` and rely on the new never-`-F` test.** Zero
     behavior change, keeps the status cross-check, but leaves the unverified
     old-version assumption standing.
   **Recommendation: (b)**, plus the test — because `-f` is verified correct
   on current glab, (a) trades a *proven* hardening (status parsing) for an
   *unproven* risk (a hypothetical old glab), and L5 already records that
   subcommand paths have weaker error detection. Do not execute (a) without
   an explicit decision.
4. **N2 — merge-message correctness.** `gitlab_panel.dart:1276` passes
   `mergeCommitMessage: options.body ?? options.subject`, so **both**
   `merge_commit_message` and `squash_commit_message` are sent on every merge
   regardless of method, and a blank body silently reuses the subject as the
   merge-commit body. Send only the field matching the chosen method, and do
   not substitute the subject for an empty body.
5. **No UI-layer sanitization.** Explicitly rejected: it would blacklist
   legitimate commit-message content (`@mention` is normal GitLab syntax) to
   defend a substitution `-f` does not perform, and `merge_options_sheet.dart`
   is shared with the GitHub path, which already reaches the safe
   `gh pr merge -t/-b` flags.

**Tests.** `test/mutations_test.dart` (exact-argv idiom, `_FakeExecutor` at
`:8`) for the never-`-F` assertion and the N2 field selection.

**Negative test.** Change `-f` to `-F` in `api()` in a scratch copy; the new
test must fail.

**Acceptance.** Tests pass and fail when reverted; analyzer clean; suite
green. Commit.

---

### Phase 11 — M8 + M9: forge JSON off the UI isolate, and honest rate-limit errors

**Objective.** A busy comment thread doesn't jank the UI, and a rate-limited
call says so.

**Files.** `lib/core/gitlab/glab_service.dart`, `lib/core/github/gh_service.dart`,
`lib/core/forge/forge_json.dart`, tests alongside.

**Steps.**

1. **M8.** Route the three remaining raw `jsonDecode` sites through
   `decodeJsonMaybeOffThread` (`forge_json.dart:25-30`), which every other
   decode site already uses: `GlabService.listIssueComments` (`:1426`),
   `GlabService.listMergeRequestNotes` (`:1453`),
   `GhService._parseIssueComments` (`:927`, backing both issue and PR comment
   listing). These are exactly the large-payload case the 32 KiB threshold
   exists for. 0019's plan deliberately left them un-migrated during the
   host-pinning work; this is that flagged residual, not new scope.
2. **M9.** Add rate-limit detection (HTTP 403 with a rate-limit signal, and
   429) so the failure is distinguishable from any other error. Minimum bar:
   a typed/labelled error that surfaces as "rate limited — try again in N"
   rather than an opaque `GhException`/`GlabException`. Retry/backoff is
   **not** in scope for this phase — an automatic retry against a rate limit
   can make things worse, and choosing a policy is a design decision. If
   backoff is wanted, that is a separate MADR.
   Note `branch_forge_status.dart:168` documents that `branchForgeProvider`
   deliberately collapses all failures to `const {}`; that stays — use
   `branchForgeKnowledgeProvider` for anything reasoning about absence.

**Tests.** Assert the decode path is the off-thread helper (or assert
behavior on a >32 KiB payload). Assert a 403/429 response produces the
distinguishable error.

**Negative test.** Revert one decode site; its test must fail.

**Acceptance.** Tests pass and fail when reverted; analyzer clean; suite
green. Commit.

---

### Phase 12 — M10 + L2 + L3 + L4: GitService residuals

**Objective.** Remove the dead-code landmine and the three small correctness
and observability gaps.

**Files.** `lib/core/git/git_cat_file_batch.dart`, `lib/core/git/git_service.dart`,
`lib/core/git/unified_diff.dart`, `test/git_cat_file_batch_test.dart`,
`test/commit_patch_parse_test.dart`, one new test.

**Steps.**

1. **M10.** `git_cat_file_batch.dart:187` re-encodes an already-lossily-decoded
   string (`utf8.encode(result.stdout)`), which is not length-preserving, so a
   single invalid byte desyncs the byte-count framing for **every subsequent
   object** in the batch — and in the non-`requireAll` path returns wrong
   content for the wrong key **silently** (`:190-199`) rather than throwing.
   The fallback at `:211` has the same defect, so
   `git_service.dart:2929-2930`'s claim that binary "falls back to sequential
   (correct, slower)" is false — amend it.
   Fix properly: consume bytes end-to-end rather than round-tripping through
   a String. **This requires an executor path that returns bytes**; if none
   exists for this call shape, that is a **deviation** — stop and ask, and do
   not "fix" it by narrowing the test to ASCII. Given `GitService.showBlobsBatch`
   has **zero callers**, deleting the dead path is also a legitimate
   resolution to put to the maintainer.
2. **L2.** Two changes: (a) read the pending-op script's exit code — it is the
   only snapshot section with no exit-code policy at all, unlike `statusExit`
   (throws), `refsExit` (throws), `remotesExit` (documented degrade); a
   failing script currently reports "no pending operation", the dangerous
   direction, and it gates the session-exit guard. (b) **Second, live bug:**
   the script emits `am` (`git_service.dart:1900`) but the consuming switch
   (`:2147-2153`) has no `'am'` case, so an in-progress `git am` reports as
   none. Check whether `PendingOp` has an `am` variant before choosing between
   adding one and mapping to `rebase`. Also check whether the combined fast
   path (`:1996`) already recovers an exit code the fallback discards.
3. **L3.** Give `undoExecute` (`:5934-5952`) and `redoExecute` (`:5958-5977`)
   an `OperationDescriptor`, mirroring `_run`'s Pattern B (`:6202-6212`) with
   `kind: OperationKind.gitMutation`, `lane: ExecLane.exclusive`, label
   `'Undo …'`/`'Redo …'`. Both use `record.repoPath`, not a parameter.
   **Also:** neither passes `lane:` today, so both rely on `execute`'s default;
   `undoExecute`'s doc claims "on the exclusive lane" but nothing in the body
   says so. Pass it explicitly. If `execute`'s default turns out **not** to be
   exclusive, that is a separate finding — stop and report it.
4. **L4.** Add `copy from `/`copy to ` handling to `_classify`
   (`unified_diff.dart:216-287`). **Choose `renamed`, not a new `copied`
   enum variant**, unless the UI must distinguish them: adding a
   `DiffFileChange` value touches every exhaustive `switch` in the codebase.
   Scoping fact: this repo never passes `-C`/`--find-copies` itself
   (`grep` finds none), so copy headers arrive only from a host
   `diff.renames = copies` config or an imported patch — real, but rare.

**Tests.** M10: build a fixture whose blob body contains an invalid byte
(e.g. `0xFF`), model the executor with `utf8.decode(..., allowMalformed: true)`
— note the current fixture builder at `test/git_cat_file_batch_test.dart:247`
calls `utf8.decode` *without* `allowMalformed` and would throw, so the harness
itself needs changing — and assert the second object's content survives. L4:
add the copy case to `test/commit_patch_parse_test.dart:103-170`, the only
test in the repo exercising `_classify`. L3: a `_RecordingExecutor` unit test
observing the descriptor (the existing undo/redo integration tests use a real
executor that discards it).

**Negative test.** Each of the above fails on the unmodified tree by
construction. Confirm and record.

**Acceptance.** Tests pass and fail when reverted; analyzer clean; suite
green. Commit.

---

### Phase 13 — L1: scoped repos get an editable git-dir

**Objective.** A genuinely moved git-dir is correctable without delete +
re-add.

**Files.** `lib/features/switcher/edit_entry_sheets.dart`, plus the callers
that consume the sheet's return tuple, and tests.

**Steps.** Add a git-dir field to `EditRemoteRepoSheet` (`:273-403`) and
`EditLocalRepoSheet` (`:406-475`), shown only when the repo is scoped. The
remote sheet currently returns `(label, newPath, fsmonitor)` — widening the
tuple touches `_editRepo` (`connection_switcher.dart:896-968`), which must
then carry the edited git-dir instead of unconditionally re-applying
`conn.scopedGitDirFor(repo)` (`:920`, `:943`). Also fix the Path field's hint
("the one containing .git"), which is not scope-aware.

Interaction with Phase 4: an edited git-dir should follow the same
"applies on next connect" contract as fsmonitor, so no live re-register.

**Tests.** Widget test in the existing edit-sheet test file.

**Acceptance.** Analyzer clean; suite green. Commit.

---

### Phase 14 — M11 + N3 + documentation truth

**Objective.** `docs/README.md` can be trusted again, and no stale comment
invites a regression.

**Files.** `docs/0018-MADR-transport-readiness-is-not-an-error.md`,
`docs/0018-PLAN-…md`, `docs/README.md`, this plan, the 0022 MADR.

**Steps.**

1. **0018 status.** Both files say `status: proposed` and `README.md:46`
   repeats it, yet the typed exception, humanizer branch, spinner call sites,
   and readiness gate are all shipped and working. Update to `accepted` /
   `executed`, and add a **dated deviation entry** to the plan recording that
   Phase 1c's specified `ReadinessGatedExecutor` decorator at the provider
   seam was **not** built — an inline gate inside `SSHCommandExecutor` coupled
   to `SSHClientManager` was built instead. Do not delete the original step;
   annotate it. If the maintainer still wants the decorator architecture, that
   is outstanding scope, not a doc fix — ask.
2. Note in 0018 that its coverage gap for secondary windows was closed by this
   plan's Phase 1.
3. **N3 comments** — both already scheduled in their own phases (Phase 10
   step 1 for `glab_service.dart:461`; Phase 3 step 4 for
   `app_providers.dart:2205-2209`). Confirm both landed.
4. Add 0022 to `docs/README.md`'s index with accurate statuses, and set the
   MADR's `verified:` date.

**Acceptance.** No document asserts something the code contradicts. Commit.

---

### Phase 15 — M5: verify the remote watcher teardown claim (maintainer-gated)

**Objective.** Settle whether `fswatch`/`inotifywait` processes actually
outlive their SSH channel — currently a **suspicion, not a reproduced
defect**, and the only finding whose premise cannot be checked from this tree.

**Steps.**

1. On a real target host, arm a watcher, close the window/tab, and check
   server-side whether the process persists (`pgrep -af 'fswatch|inotifywait'`).
2. If it persists: the fix is **not** more signal escalation —
   `SSHSignal.KILL` (`ssh_command_executor.dart:1032-1039`) travels the same
   channel-request path an sshd that ignored TERM will also ignore. Design a
   real teardown (e.g. the remote script traps and kills its own child on
   stdin EOF / pipe close) and bring it back as a **deviation with options**.
3. If it does not persist: record that `session.close()` → SIGPIPE is
   sufficient in practice, note it as an inference now confirmed, and close M5
   as a non-issue with the evidence.

**Note.** This is systemic, not watch-specific — the same
`killAndCloseSession` path backs GitLab CI trace streaming. Line numbers in
the MADR are off by ~2: the real range is
`ssh_command_executor.dart:1013-1043`.

**Acceptance.** M5 is closed with evidence in either direction, or converted
into a scoped follow-up.

---

### Phase 16 — Final verification and handoff

1. `flutter analyze` — clean.
2. `flutter test` — full suite green; record the final pass count against the
   Phase 0 baseline.
3. Confirm every phase's negative test was actually run and its failure
   observed; anything that could not be made to fail is reported as such,
   describing what it *does* establish.
4. Fill in this plan's Execution Record: what each phase did, verbatim
   verification output (not a summary), every deviation with its date and
   decision, and — in the same detail — anything **not** done and why.
5. Set this plan's `status: complete` only when every acceptance criterion is
   met, not when the last commit lands.
6. Report the branch is ahead by N commits and **offer** the push command. Do
   not push.

## Verification

Per phase: `flutter analyze` clean, `flutter test` green, the phase's own new
tests passing, and each new test observed failing against a deliberately
broken scratch copy. Repo-wide at the end: analyzer clean, full suite green,
pass count ≥ the Phase 0 baseline plus the new tests.

Commands:

```sh
flutter pub get
flutter analyze
flutter test
flutter test test/<file>_test.dart              # single file
flutter test --plain-name "substring of name"   # single test
```

Never run `--run-skipped -t live-forge` as part of this plan.

An optional end-to-end check on the two watch phases and the pop-out phases:
`./build_macos.sh --unsigned --install`, then exercise a scoped repo and a
detached-repo window. Not required for acceptance, since neither is
reproducible in CI.

## Rollout and Rollback

**Rollout.** Phases land in order, one commit each, on a branch off `master`.
The ordering is deliberate: Phases 1–4 are self-contained and low-risk;
Phases 5–6 must land together in that order (Phase 6 subsumes Phase 5's N1
handling); Phases 7–13 are independent of each other; Phase 14 is
documentation; Phase 15 needs a live host.

**Rollback.** Each phase is one revertable commit touching a disjoint file
set, except Phases 5–6 (revert as a pair). Highest-risk phases, in order:

* **Phase 6** (watch re-arm) — changes two service signatures and the
  lifecycle engine; a bug here degrades refresh for every repo, not just
  scoped ones. Mitigation: the `rearm` hook is additive and the unbounded path
  is untouched.
* **Phase 8** (activity relay) — touches the window relay, where a malformed
  payload historically caused silent truncation. Mitigation: the child guards
  `args is Map` and drops unknown phases.
* **Phase 9** (list state) — widening PR/MR list state changes counts and
  copy across the Forge tab and Dashboard.
* **Phase 2's controller guard** — makes `finalizeProvisioned` return `false`
  in a new case; both callers already handle `false`, but the user-facing
  message needs the wording fix in step 2.

**No migration.** Nothing here changes persisted schemas. The one persistence
touchpoint, Phase 13's git-dir edit, writes an existing field
(`SavedConnection.scopedGitDirs`) through the existing `withScopedGitDir`
helper.

## Execution Record

Execution began 2026-09-03 on maintainer approval ("scope all findings …
amend the madr and keep going"). The three decisions this plan left open were
resolved by taking the plan's own recommendations, recorded below.

### Decisions taken at approval (2026-09-03)

* **Phase 10 step 3 — glab field handling: option (b).** Keep REST `-f` and
  pin it with a never-`-F` test. Rationale as written in the phase: `-f` is
  verified correct on current glab, and option (a) would trade a proven
  hardening (the `-i` HTTP-status cross-check against glab's advisory exit
  codes) for an unproven risk (a hypothetical older glab). Revisit only if
  evidence of an affected glab version appears.
* **Phase 7 M2 — lane: `ExecLane.isolated`.** The lane's own doc names a
  user-supplied hook as its canonical case, which is exactly what
  `generateCommitMessage` runs. The residual risk (a user hook that touches
  the index despite git's contract) is recorded in a code comment at the call
  site rather than defended against with a more restrictive lane.
* **Phase 12 M10 — resolution chosen when reached**, per the phase text; if no
  byte-returning executor path exists, stop and put deletion of the
  zero-caller dead path to the maintainer rather than narrowing the test.

### DEVIATION 2026-09-03 (a) — the first baseline run was void; my error

**What happened.** The Phase 0 suite run was launched in the background and
then Phase 1's edits were made to `exec_proxy_codec.dart`,
`exec_proxy_codec_test.dart`, and `window_manager_bridge_test.dart` **while it
was still running**. It therefore measured a half-edited tree, and its failure
list is meaningless. It reported `window_manager_bridge_test.dart: serves
execute calls: success and each typed error as envelopes` as failing — which
is simply the test being edited mid-run — alongside ~48 others.

**Why it matters beyond the wasted run.** That output nearly became the
"baseline" the whole plan gates against. A gate derived from a tree in an
unknown state is worse than no gate: every later phase would have compared
itself to noise, and the ~48 `workspace_golden_test.dart` failures would have
been silently accepted as "pre-existing" on no evidence at all.

**Resolution.** Phase 0's method is rewritten above to take the baseline on a
**pristine clone at HEAD**, with an explicit prohibition on editing during the
run, and to record the failing-test *set* rather than a count. The baseline is
being re-taken; until it exists, **no phase may be committed**, including
Phase 1, whose code and negative test are already done.

**Open question this raised — now ANSWERED (2026-09-03).** The ~48
`workspace_golden_test.dart` failures were unattributed, and per Phase 0's
acceptance criterion that blocked the plan. Settled by the pristine-clone run:
all 48 reproduce at HEAD with no local changes whatsoever, all 48 are in that
single file, and each fails inside `LocalFileComparator.compare` — golden
pixel mismatches, not crashes or logic failures. This matches the known
outstanding item "maintainer acceptance of the 48 workspace goldens"
(0007 Phase 7) and is the expected shape of goldens rendered on a machine
other than the one that generated them. Attributed, therefore not blocking;
they form part of the comparison set below.

### DEVIATION 2026-09-03 (b) — Phase 0 baseline is not analyzer-clean

**Evidence.** `flutter analyze` at HEAD `433a9a6` reports **2 issues**, both
`unawaited_return_in_try_block` warnings:
`lib/features/branches/pinned_branches.dart:29:11` and
`lib/features/common/image_diff_view.dart:105:9`.

**Attribution — corrected, and the first attribution was wrong.** This entry
originally recorded the two modified working-tree files
(`analysis_options.yaml`, `pubspec.lock`) as "the maintainer's in-flight
work". That was an assumption, not a finding, and it is **false**. Verified by
experiment on throwaway clones:

* a fresh `git clone --local` of this repo checks out **clean** — `git status`
  empty, no `macos/**` line in `analysis_options.yaml`;
* running **`flutter pub get` alone** in that clean clone reproduces **both**
  modifications byte-for-byte — `analysis_options.yaml` gains `- macos/**`
  under `exclude`, and `pubspec.lock` takes transitive upgrades (e.g. `matcher`
  0.12.19 → 0.12.20).

So both files are **tooling output**, regenerated by `pub get` on any machine
with this SDK, not hand-authored changes. The two analyzer warnings follow
from the same place: the newer lint package that resolution pulls in
introduces `unawaited_return_in_try_block`, which HEAD's code predates. The
warnings reproduce on a pristine clone at HEAD, so they are **pre-existing and
environment-attributable**, not caused by this plan.

**They were still left untouched**, and that does not change: reverting
tooling output in the maintainer's working tree is not mine to do either, and
the two flagged files are not in any phase's file list. No attempt was made to
"fix" the two warnings.

**Why the correction is recorded rather than quietly amended:** the original
framing would have justified treating the files as someone's uncommitted work
to be preserved at all costs, and — worse in the other direction — it
misattributed a reproducible tooling behavior to a person. Either error could
mislead the next session.

**Decision.** Proceed, with the per-phase acceptance criterion restated as
**"no new analyzer issues beyond the 2 pre-existing"** rather than the
literal "analyzer clean". This is the honest bar: blocking all 16 phases on
someone else's uncommitted dependency bump would stall the work without
improving it, and the two warnings cannot mask a regression in this plan's
files because they are attributable by path.

**Consequence of doing nothing about the warnings:** they remain for the
maintainer to resolve alongside the dependency bump. Flagged, not absorbed.

### DEVIATION 2026-09-03 (c) — pre-existing: `dispose()` aborts provisioning through `ref`, which is unsafe once unmounted

**Found by** Phase 2's new sheet test, which is the first test to dispose a
wizard while it holds an adopted provisioning token.

**Evidence.** `dispose()` → `resetProvisioning()` → `ref.read(connectionProvider.notifier)`
throws:

```
Bad state: Using "ref" when a widget is about to or has been unmounted is unsafe.
  WorkspaceProvisioning.resetProvisioning (workspace_provisioning.dart:85)
  _CloneRepositorySheetState.dispose (clone_sheet.dart:203)
```

**Genuinely pre-existing, not caused by the Phase 2 refactor.**
`git show HEAD:lib/features/workspace/clone_sheet.dart` shows the identical
shape before this plan touched it: `dispose()` calling `_resetProvisioning()`,
whose body is `ref.read(connectionProvider.notifier).abortProvisioning(token)`.
Both wizard sheets carry it, and the in-code comment states
`AddExistingRepoSheet` uses "the same fire-and-forget pattern", so
`local_repo_form.dart` is exposed identically.

**User-visible consequence.** Dismissing a wizard by its barrier (or any route
teardown that skips `_requestClose`) after a host has been dialed: `dispose`
throws, the abort never runs, and a live SSH session is stranded at
`phase: connecting` — the buttonless "Connecting…" tab that
`local_repo_form.dart` explicitly guards against elsewhere.

**Decision (maintainer, 2026-09-03): recommended option 1 + 3.**

1. `WorkspaceProvisioning` captures the `ConnectionController` when a dial
   starts and `resetProvisioning` uses that captured reference rather than
   `ref`. Sound because `provisionToken` can only become non-null inside
   `ensureProvisioned`, which captures first — so whenever there is something
   to abort, the reference exists. Mirrors the pattern
   `local_repo_form.dart:305-308` already documents ("the controller outlives
   the sheet").
3. The same fix is applied to `local_repo_form.dart`, which is **not** in
   Phase 2's original file list — scope explicitly widened by the maintainer,
   since it is the identical bug in the very pattern Phase 2 propagates.

Rejected: weakening or deleting the test that found it, and having `dispose`
skip the abort (both leave the stranded session shipped and hidden).

**Files added to Phase 2's scope:** `lib/features/connection/local_repo_form.dart`.

### DEVIATION 2026-09-03 (d) — Phase 7's M1(b) step was wrong as written

**What the plan said.** M1(b): "Do not cache the fallback — only cache a
genuine lookup (`:4893`)."

**Why it is wrong.** Doing that broke four existing tests, one of which pins
the behaviour deliberately: `test/mutations_test.dart:723`, *"pull/push reuse
cached upstream and get-url"*, asserts that two consecutive pushes issue the
upstream probe exactly once. Dropping the fallback cache re-runs
`git config --get branch.<x>.remote` on **every** pull/push for any repo with
no configured upstream — deleting an intentional optimization to fix a much
narrower problem, and requiring four pinned tests to be rewritten to suit the
patch. Rewriting a pinned invariant to make my own change pass is precisely
the move the working-style rules forbid.

**Also established:** the finding is fixed *without* that step. The staleness
that actually bites is across a branch switch, and both checkout paths now
invalidate. Verified: with the fallback cache restored and invalidation kept,
all 121 `mutations_test.dart` tests pass.

**Decision (maintainer, 2026-09-03): option 3.** Keep the fallback cached, keep
the checkout invalidation, **and** close the residual by invalidating on the
upstream-changing commands too — `setUpstream` and `unsetUpstream`. The plan's
original M1(b) wording is struck: *~~do not cache the `'origin'` fallback~~* →
invalidate wherever the upstream can change instead.

**Scope note discovered while doing it:** `GitService` has no
remote-add/rename/set-url methods at all. Those argv are issued directly
through the executor by `create_repo_sheet.dart` (`:562`, `:760`, `:1039`),
bypassing `GitService` and therefore its caches. That is safe today — they run
against a repo being created, whose session is finalized immediately after —
but it means `_remoteUrlByRepo` has one theoretical staleness path this phase
cannot reach from inside `GitService`. Recorded, not silently ignored.

### Phase 0 — Baseline (2026-09-03) — **COMPLETE**

Taken on a pristine `git clone --local` at HEAD `433a9a6`, confirmed clean
(`git status` empty) before running, with no editing during the run.

* **Analyzer: 2 issues**, both `unawaited_return_in_try_block` warnings —
  `lib/features/branches/pinned_branches.dart:29:11` and
  `lib/features/common/image_diff_view.dart:105:9`. Reproduce on the pristine
  clone, so pre-existing at HEAD in this SDK environment. See deviation (b)
  for why (a newer lint arriving via `pub get` resolution).
* **Suite: `+3307 ~2 -48: Some tests failed.`** — 3307 passing, 2 skipped
  (the `live-forge` pair, correctly skipped by default), 48 failing.
* **Failing set: all 48 in `test/workspace_golden_test.dart`**, every one
  failing inside `LocalFileComparator.compare`. Full list saved to the session
  scratchpad (`base_failing.txt`) and used as the per-phase comparison set.
* Working tree at the same commit shows `M analysis_options.yaml` and
  `M pubspec.lock` — tooling output from `flutter pub get`, per deviation (b),
  left untouched.

**The gate for every phase from here:** the failing set must remain exactly
these 48 names, and the analyzer must remain exactly these 2 issues. Compare
sets, not counts.

### Phase 1 verification against that baseline (2026-09-03)

* Suite in the working tree with Phase 1 applied: **`+3308 ~2 -48`**.
* Failing set diffed against baseline: **identical, no new failures**.
* The `+1` is exactly the one new test added (the version-skew `message`
  assertion); the other new assertions live inside two existing tests, so they
  raise no count.

### Phase 1 — H3: `SSHTransportNotReady` survives the pop-out relay (2026-09-03) — **COMPLETE**

Acceptance met: analyzer unchanged at the baseline's 2 issues; suite
`+3308 ~2 -48` with a failing set identical to baseline; negative test seen to
fail. Verification detail is in the Phase 1 block above.

**Done.** `lib/core/exec/exec_proxy_codec.dart`: added the
`SSHTransportNotReady` arm to `encodeExecuteError` (tagged
`'transportNotReady'`, and carrying `'message'` so a version-skewed old
decoder degrades to today's text instead of "unknown proxy error"), added the
matching `case` to `decodeExecuteResponse`, and corrected the two doc comments
that asserted "three" typed exceptions. No change was needed to
`ProxyCommandExecutor`, `display_error.dart`, or `ssh_error_messages.dart` —
confirmed by reading, not assumed: `decodeExecuteResponse` is called outside
the `try` in `proxy_command_executor.dart`, so the typed throw propagates
untouched, and `isTransportNotReady` is an exact `is` test the restored type
satisfies. `uploadBytes` inherits the fix via `encodeUploadBytesError`.

**Tests added.** `test/exec_proxy_codec_test.dart`: a fourth case in "each
typed executor exception survives with its command", plus a new test pinning
the version-skew `message` field. `test/window_manager_bridge_test.dart`: a
not-ready envelope case in "serves execute calls: success and each typed error
as envelopes", exercising the real hub handler end-to-end.

**Negative test — seen to fail.** Run against a scratch `git clone` in the
session scratchpad, never by dirtying the working tree. The decoder `case` was
removed by a script that **asserts its target was present before editing**
(so a no-op edit could not masquerade as a passing check), and the removal was
verified by re-grepping the file. Result, verbatim:

```
Expected: throws <Instance of 'SSHTransportNotReady'> with `command`: 'git status'
  Actual: <Closure: () => CommandResult>
   Which: threw ProxyExecuteException:<SSH transport is not ready yet: git status>
          which is not an instance of 'SSHTransportNotReady'
```

That failure text is the bug itself: the raw developer string that a pop-out
window rendered in its Repository pane instead of the "still connecting"
spinner. Note the version-skew test correctly still passed with the decoder
broken — it exercises only the encoder.

### Phase 2 — H4: mid-dial host switch (2026-09-03) — **COMPLETE**

**Done — controller (the load-bearing half).** `finalizeProvisioned`
(`app_providers.dart`) now rejects a `conn` whose id is not
`_lastConnectionId`, alongside the existing token check, with a comment
explaining why the two are not redundant (the token is a *generation* counter,
not an identity). Its doc comment was amended, as the phase required, because
`false` now has a second meaning that both callers surface as
"cloned/created but could not be opened".

**Done — sheets.** New `lib/features/workspace/workspace_provisioning.dart`
holds the `WorkspaceProvisioning` mixin (`provisionToken`, `provisioning`,
`ensureProvisioned`, `resetProvisioning`, `connectionById`), and both wizard
sheets now use it. The extraction was justified by measurement, not taste: the
four members were byte-for-byte identical between the two sheets apart from
doc comments (verified by diffing the extracted ranges). Both sheets'
Destination dropdowns are now gated on `provisioning` as well as `_submitting`,
matching `local_repo_form.dart:669-671`.

**Deviation (c) fixed in the same phase** — see its entry above: the mixin (and
`local_repo_form.dart`, added to scope by the maintainer) capture the
`ConnectionController` at dial time so `resetProvisioning` never touches `ref`
from `dispose()`.

**Tests added.** `connection_provisioning_test.dart`: a wrong-connection
finalize is refused and persists nothing, **plus a positive control** that the
right connection is still accepted — a guard that rejects everything would
otherwise pass the first test. `clone_sheet_test.dart`: the Destination control
is inert while a host dials and usable again once it resolves, driven by a
gated `beginProvisioning` on the stub.

**A test I rewrote rather than forced.** My first sheet test tried to switch
destination mid-dial and assert the orphaned session was aborted. It could not
work, and the reason is the fix: with the dropdown gated, that switch is
unreachable through the UI. Asserting the gate is the honest test at this
layer; the post-await identity guard is covered at the controller, where it is
reachable. (It also timed out on `pumpAndSettle` — the sheet shows an
indeterminate "Connecting…" spinner, so the test drives `pump()` explicitly.)

**Negative tests — both seen to fail.** In scratch clones, with an assert that
the target text existed before editing:
* dropdown gate reverted → `Expected: null / Actual: <Closure: (String?) =>
  Future<void> from Function '_onDestChanged'>`;
* controller guard removed → `Expected: false / Actual: <true>` — the
  wrong-host finalize succeeding, which is the data-corruption path itself.
Deviation (c) was likewise observed failing before its fix (the `Bad state:
Using "ref" …` stack quoted in that entry).

**Verification.** `flutter analyze` on the touched directories: clean. Full
suite: `+3311 ~2 -48`, failing set **identical** to the Phase 0 baseline. The
`+4` over baseline is exactly the four tests added.

### Phase 3 — H2 + L6 + N3(b): scope-aware forge (2026-09-03) — **COMPLETE**

**Done.**
* `finalizeProvisioned`'s token login now builds an ad-hoc
  `ScopedCommandExecutor` from its own `gitDir`/`repoPath` arguments. As the
  phase predicted, substituting `glabServiceProvider` here would have been a
  silent no-op — those providers resolve their overlay from
  `connectionProvider.scopedGitDirs`, which this method does not publish until
  its final lines.
* `originRemoteUrlProvider`, `forgeProvider`, and `sessionAuthStatusProvider`
  now build on `scopedForgeExecutorProvider`. No cycle resulted, as predicted:
  they are leaves, and the wrapper's dependency set is unchanged.
* `forgeRepoListProvider` (L6) aligned to the scoped wrapper on its remote
  branch; the `local` branch deliberately stays on `localExecutorProvider`.
* N3(b): the stale comment claiming `activeExecutorProvider` watches
  `connectionProvider` is replaced with the true rationale (a host login takes
  an explicit host and needs no git-dir), and notes why the old claim was
  false.

**Deliberately NOT changed:** `forgeAuthProvider`. It shares the same
executor-selection shape and was matched by my first (over-broad) edit — the
script's count assertion caught it and wrote nothing. It probes with
`cwd: '.'` and no repoPath, so the overlay could never apply; scoping it would
have been noise implying a scope-sensitivity it does not have.

**Tests added.** New `test/scoped_forge_providers_test.dart` (4 tests) asserts
the overlay reaches the actual command for all three providers, plus a control
that an ordinary repo stays unscoped — a stray `GIT_DIR` would break every
command it touched. This is precisely what `scoped_forge_executor_test.dart`
could not catch: it unit-tests the wrapper in isolation, so a provider that
never uses the wrapper passes it.

**Negative test — seen to fail.** All three providers reverted to
`activeExecutorProvider` in a scratch clone (with a per-target assertion that
the text existed): all three scoped tests failed with
`Expected: {'GIT_DIR': …} / Actual: <null>` — no overlay reaching the command.
The "ordinary repo" control correctly passed in both states, since it asserts
absence.

**Verification.** Analyzer: 2 issues, the baseline's pre-existing pair. Suite:
`+3315 ~2 -48`, failing set **identical** to baseline (+8 over baseline = the
4 tests from Phase 2 and 4 from Phase 3).

**Still open from H2, by design:** the live check on a real bare/dotfiles repo
with a forge remote. Static tests prove the env reaches the command; only a
live host proves the Forge tab populates. Carried to Phase 15's live pass.

### Phase 4 — M7: live scope-registry lifecycle (2026-09-03) — **COMPLETE**

**Done.** `setRepoPath` gained the missing negative branch
(`unregisterRepoScope` when the path is absent from
`ConnectionState.scopedGitDirs`); `_deleteRepo` and `_editRepo` now drop the
**live** registry entry as well as the persisted map one, both guarded on the
live connection still being that connection. `_deleteRepo`'s unregister
deliberately runs whether or not the deleted repo was the *active* one, since
connect registers every scope a connection carries. `_editRepo` unregisters the
old path only and does not register the new one live — matching the contract
the adjacent fsmonitor branch already states ("across a repoint it applies on
the next connect").

**Known limitation, recorded rather than silently widened** (as the phase
required): `ConnectionState.scopedGitDirs` is written only by `connect`,
`connectLocal`, and `finalizeProvisioned`, so switcher edits do not update the
live session state until the next connect. These unregisters make the registry
consistent with the **live session state**, which can itself lag the saved
connection. Making switcher edits apply live would need a
`copyWith(scopedGitDirs:)` mutator on the controller that does not exist —
out of scope, and a deviation if it ever proves necessary.

**Test added.** In `scoped_forge_providers_test.dart`: with two scopes
registered (as connect would), switching to a repo absent from
`scopedGitDirs` clears its entry while the genuinely scoped repo keeps its
own. Exercises the real `setRepoPath`, not a stub — the stub overrides only
`build()`.

**Negative test — seen to fail.** `else` branch removed in a scratch clone
(with an assert that the block existed): `Expected: false / Actual: <true>` —
the stale scope surviving the switch, which is the leak.

**Verification.** Analyzer: 2 pre-existing. Suite: `+3316 ~2 -48`, failing set
identical to baseline.

### Phases 5 + 6 — M6, N1, H5: bounded watch arming and re-arming (2026-09-03) — **COMPLETE**

Landed as one commit, as the plan's rollout section requires (Phase 6 subsumes
Phase 5's fallback).

**M6 — arming no longer fails silently.** `boundedFswatchArgs` is replaced by
`boundedFswatchScript`, running through `sh -c` so remote fswatch gets the same
existence filter inotifywait already had. The reason differs by tool and is now
written down: inotifywait *aborts* on a missing path, while fswatch merely
*skips* it — and a skipped path is never retried, so a watch armed before the
first `git tag` would never see `refs/tags` appear. The all-missing case now
exits `boundedWatchNoPathsExit` (97) instead of 0; the remote service maps that
to `WatchUnavailable`, which degrades to polling **with** recovery retries,
rather than looking like a watcher that armed and died and burning three
restarts first.

**N1 — a failed `listTrackedFiles` no longer kills the watcher.** The fetch
moved inside the supplier, where a `GitException` or timeout is caught and
degrades to a git-dir-only surface (still enough to see git-state changes)
instead of erroring the provider stream and leaving the repo with no watcher
and no poll.

**H5 — the surface is recomputed on every arm.** Both services now take a
`BoundedWatchSpecSource` supplier instead of a frozen `BoundedWatchSpec`, and
`watchLifecycle` gained a `rearm` hook. `rearm` is deliberately **not**
`scheduleRestart`: a restart marks the mode `stopped`, emits a grey tick,
applies backoff and spends the restart budget — so reusing it would flicker the
watch indicator on every `git add` and drop a repo to polling after three edits
in new directories. The trigger is a `.git/`-prefixed path, debounced 2s
because one `git add` writes index, refs and locks in quick succession.
The local service's `roots` were also frozen outside the lifecycle; ordinary
repos keep that (their layout genuinely cannot change while open) while bounded
repos resolve per arm. The comment that justified freezing was amended rather
than deleted — it was true for linked worktrees and false for bounded mode.

**Tests.** `local_watch_bounded_test.dart` gained a real-git regression: stage
a file into a directory that held nothing tracked at arm time, wait out the
debounce, edit it, and require an event. Its `quietWatcher` helper now
recomputes from the live index, mirroring the provider's supplier.

**Negative test — seen to fail.** In a scratch clone the supplier was resolved
once and cached (`frozenSpec ??= …`), reproducing the pre-fix freeze exactly,
with an assert that the target line existed. Result:
`no matching watch event within 0:00:15.000000` — the new file silently
unwatched, which is the bug verbatim.

**Verification.** Analyzer: 2 pre-existing. Suite: `+3317 ~2 -48`, failing set
identical to baseline.

**Not addressed here (M5):** whether the remote watcher *process* survives
channel teardown is a live-host question, deferred to Phase 15 as planned.

### Phase 7 — M1 + M2: GitService caches and lane (2026-09-03) — **COMPLETE**

**M1.** New `_invalidateRemoteCaches(repoPath)` drops both
`_upstreamRemoteByRepo` and `_remoteUrlByRepo`, called from `checkout`,
`checkoutTrackingBranch` (where the cached value is wrong *by construction* —
it creates the tracking relationship), `setUpstream` and `unsetUpstream`. The
plan's "don't cache the fallback" step was **not** taken; see deviation (d) for
why and what replaced it.

**M2.** `generateCommitMessage` now runs on `ExecLane.isolated`. The comment at
the call site records both the reason (it previews only — a `mktemp` scratch
file under the git-dir, no index/work-tree/refs/network — while carrying the
5-minute commit timeout and running a hook the docstring expects to be slow)
and the residual risk (git does not *enforce* that a `prepare-commit-msg` hook
leaves the index alone).

**Tests added** — M1 had **zero** coverage of any kind before this:
* a checkout invalidates the cached upstream (pull tracking `upstream`, switch,
  pull again → auth must resolve `origin`, and must not still resolve
  `upstream`);
* `setUpstream` invalidates it too — the case a checkout cannot cover;
* `generateCommitMessage` runs on the isolated lane.

**Negative tests — all three seen to fail.** In scratch clones, each with an
assertion that the target text existed first. One of those assertions earned
its keep: reverting the checkout invalidation by its body text matched **two**
sites (both checkout paths), the assert refused, and nothing was written —
without it I would have reverted one, seen the test still fail for the wrong
reason, and drawn a false conclusion. With unique anchors:
`Expected: ExecLane:<isolated> / Actual: <exclusive>`,
`Expected: true / Actual: <false>` (stale `upstream` surviving the checkout),
and the same for `setUpstream`.

**Verification.** Analyzer: 2 pre-existing. Suite: `+3320 ~2 -48`, failing set
identical to baseline.

### Phase 1 negative-test detail (retained)

Run against a scratch `git clone` in the
session scratchpad, never by dirtying the working tree. The decoder `case` was
removed by a script that **asserts its target was present before editing**
(so a no-op edit could not masquerade as a passing check), and the removal was
verified by re-grepping the file. Result, verbatim:

```
Expected: throws <Instance of 'SSHTransportNotReady'> with `command`: 'git status'
  Actual: <Closure: () => CommandResult>
   Which: threw ProxyExecuteException:<SSH transport is not ready yet: git status>
          which is not an instance of 'SSHTransportNotReady'
```

That failure text is the bug itself: the raw developer string that a pop-out
window rendered in its Repository pane instead of the "still connecting"
spinner. Note the version-skew test correctly still passed with the decoder
broken — it exercises only the encoder.
