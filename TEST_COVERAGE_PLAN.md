# Remaining Test Coverage — Implementation Plan

## Overview

The codebase has ~250 test files but ~48 source files with business logic still lack corresponding tests. This plan covers everything not yet implemented from the original assessment, ordered by return-on-effort (highest first).

---

## Phase 1 — Regression Guards (Bugs #4 & #5)

**Where:** `lib/core/providers/app_providers.dart`
**Why first:** These are the two regression holes from the last fix session. Both involve state that silently breaks the landing-page clone flow if re-broken.

### 1a. `LocalEnvironmentGuard._probe` — token neutralization missing

| Aspect | Detail |
|--------|--------|
| **File to create** | `test/app_providers_test.dart` |
| **What it tests** | After `configureEnvironment` returns, `_probe` calls `executor.setForgeTokenNeutralization()` with forge token vars (`GLAB_TOKEN`, `GH_TOKEN`, `GITHUB_TOKEN`). Without this call, the host's forge tokens leak into SSH command output logged on error. |
| **How to test** | Create a fake executor that records `setForgeTokenNeutralization` calls. Construct a `LocalEnvironmentGuard` with a mock `Reader` that provides a `connectionProvider` whose `_forgeTokenVarsToNeutralize()` returns known vars. Call `_probe` (via `@visibleForTesting` or through the public `environmentProbe` provider) and assert the executor received the right vars. |
| **Existing pattern** | `scoped_forge_executor_test.dart` — fake executor recording method calls |
| **Estimated tests** | 2–3 |

### 1b. `ensureForgeHostLogin` — `forgeAuthProvider` cache stale after login

| Aspect | Detail |
|--------|--------|
| **File** | Same — `test/app_providers_test.dart` |
| **What it tests** | After `ensureForgeHostLogin` completes, the provider `forgeAuthProvider((forge, false))` is invalidated so the next read re-probes instead of returning the stale unauthenticated result. |
| **How to test** | Create a test `ProviderContainer`, read `forgeAuthProvider`, trigger `ensureForgeHostLogin`, assert the provider's state was invalidated (e.g. it reads a different value after). Use `ref.invalidate` tracking. |
| **Constraint** | `ensureForgeHostLogin` is an extension method on `WidgetRef` — test with a `ProviderContainer` and `container.read`/`container.invalidate`. |
| **Estimated tests** | 2 |

### 1c. Infrastructure — mock executor for app_providers

Need a shared `_FakeCommandExecutor` in the test file that records:
- `setForgeTokenNeutralization(Iterable<String> vars)` calls
- `configureEnvironment(...)` calls
- `execute` / `executeStream` calls (for forge auth probe)

Keep it minimal — only record what the tests assert on.

---

## Phase 2 — Small Pure Functions (quick wins, no mocks)

**Effort:** 1–2 hours each
**Risk:** Low — all are deterministic, no IO, no widgets.

### 2a. `auth_probe_service_test.dart`

| File | `lib/core/forge/auth_probe_service.dart` (99 lines) |
|------|-----|
| **What to test** | `AuthProbeService.probeAll()` runs Git, gh, glab probes and returns `TargetAuth`. Edge cases: gh not installed, glab timeout, both missing, git version parse fail. |
| **How to test** | Use a fake executor that returns canned `SSHCommandResult` for each tool. The service takes an executor in its constructor. |
| **Estimated tests** | 5–6 |
| **Key edge cases** | All tools succeed, gh fails (returns `ToolAuth.installed`), glab fails (returns `ToolAuth.installed`), all tools missing (returns `ToolAuth.missing`), timeout on one tool |

### 2b. `saved_local_repo_test.dart`

| File | `lib/core/storage/saved_local_repo.dart` (142 lines) |
|------|-----|
| **What to test** | `SavedLocalRepo.toJson()` / `fromJson()` round-trip. `securityScopedBookmarkData` as base64 in JSON. Missing-field resilience (old versions). |
| **How to test** | Construct a `SavedLocalRepo`, call `toJson()`, parse with `fromJson()`, assert fields match. For missing-field test, create a partial JSON map and assert defaults are used. |
| **Estimated tests** | 4–5 |

### 2c. `ref_chip_test.dart`

| File | `lib/features/history/ref_chip.dart` (filterHistoryRefDecorations function) |
|------|-----|
| **What to test** | `filterHistoryRefDecorations` — deduplicates local/remote tracking pairs, removes `*/HEAD` symrefs, orders HEAD > local branches > tags > remote branches. |
| **How to test** | Call with various `RefDecoration` lists (or the raw input format it expects). Assert ordering, dedup, and noise removal. Pure function — no Flutter dependency. |
| **Note** | May need to extract the function to a non-widget file, or mark it `@visibleForTesting`. |
| **Estimated tests** | 6–8 |

### 2d. `pinned_branches_test.dart`

| File | `lib/features/branches/pinned_branches.dart` |
|------|-----|
| **What to test** | The Riverpod notifier's CRUD operations on the pinned-branch set. Add, remove, toggle, persistence read/write. |
| **How to test** | Use `ProviderContainer` with an overridden `SharedPreferences` store (or mock it). Exercise add/remove/toggle, assert state updates, assert SharedPreferences was written with the expected JSON. |
| **Estimated tests** | 4–5 |

### 2e. `section_collapse_test.dart`

| File | `lib/features/common/section_collapse.dart` |
|------|-----|
| **What to test** | `CollapsedSections` notifier: toggle, reset, persistence round-trip. |
| **How to test** | Same pattern as pinned_branches — ProviderContainer + mock/preloaded SharedPreferences. |
| **Estimated tests** | 3–4 |

### 2f. `actions_test.dart`

| File | `lib/features/common/actions.dart` (191 lines) |
|------|-----|
| **What to test** | `runAction` wrapper: error surfacing, DockProgress integration, confirmation dialog routing. |
| **How to test** | The core logic is the error mapping and Dock progress lifecycle. Test the error-mapping function (extract or `@visibleForTesting`). The widget parts (dialog) need a widget test. |
| **Estimated tests** | 3–4 |

---

## Phase 3 — Service Layer (needs mock executor harness)

**Effort:** 2–4 days each
**Risk:** Medium — big files but the executor seam is clean.

### 3a. Mock executor harness

Before tackling the service files, create a reusable mock executor:

| File to create | `test/helpers/mock_executor.dart` |
|----------------|-----|
| **What it provides** | `MockCommandExecutor` class implementing `CommandExecutor`. Constructor takes canned responses: a `Map<String, List<SSHCommandResult>>` keyed by command prefix or regex, so different git commands return different results. Records every call for later assertion. |
| **Required features** | 1. `execute` returns canned result matching the `gitArgs` pattern. 2. `executeStream` returns a fake `SSHStreamHandle` (pre-built stdout/stderr streams). 3. `configureEnvironment`, `setForgeTokenNeutralization`, `resetEnvironment` are no-ops that record calls. 4. `uploadBytes` records the call. 5. `resolvedBinaryPath` returns canned paths. |
| **Existing reference** | `_FakeExecutor` in `remote_watch_service_test.dart`, `_RecordingExecutor` in `scoped_forge_executor_test.dart`, the executors in `clone_controller_test.dart`. Consolidate patterns into one reusable harness. |

### 3b. `git_service_test.dart`

| File | `lib/core/git/git_service.dart` (5165 lines — the largest file) |
|------|-----|
| **Strategy** | Do NOT test every method. Test one representative method per functional area to lock in the executor-contract pattern, then expand from there. |
| **Priority methods** | 1. `currentBranch()` — simplest read. 2. `branchList()` — parses `git branch` output. 3. `status()` — core porcelain parsing path. 4. `commit()` — mutation with undo capture. 5. `push()` — mutation with undo + remote interaction. |
| **What to test per method** | a) Correct `gitArgs` constructed. b) Correct `repoPath` passed. c) Extra env vars merged. d) Lane selection (read vs exclusive). e) Output parsing handles expected format. |
| **Infra needed** | `MockCommandExecutor` from 3a, plus helper functions to create `SSHCommandResult` with realistic porcelain output. |
| **Estimated tests** | 15–20 initially (grow as-needed) |

### 3c. `glab_service_test.dart`

| File | `lib/core/gitlab/glab_service.dart` (1500 lines) |
|------|-----|
| **Strategy** | Test JSON parsing paths and command construction. Each method: command argv, lane, env vars (like `GITLAB_HOST`), and the JSON/ndjson response format. |
| **Priority methods** | 1. `mrList()` — MR list with JSON parsing. 2. `pipelineList()` — CI pipeline list. 3. `ciTrace()` — streaming CI log tail. 4. `projectId()` — project lookup. 5. `createMr()` — mutation. |
| **Infra needed** | Same `MockCommandExecutor` + `MockSSHStreamHandle` for streaming methods. Need realistic `glab api` JSON responses (use `test/fixtures/` directory for JSON blobs). |
| **Estimated tests** | 12–15 |

### 3d. `gh_service_test.dart`

| File | `lib/core/github/gh_service.dart` (1188 lines) |
|------|-----|
| **Strategy** | Mirror of glab_service_test. Test command construction, env vars (`GH_HOST`), JSON parsing, streaming for job logs. |
| **Priority methods** | 1. `prList()` — PR list. 2. `workflowRuns()` — CI runs list. 3. `runJobLog()` — streaming job log. 4. `createPr()` — mutation. 5. `repoList()` — repo listing for clone sheet. |
| **Infra needed** | Same as 3c. |
| **Estimated tests** | 10–14 |

---

## Phase 4 — Provider / Stateful Widget Tests (needs ProviderContainer harness)

**Effort:** 0.5–1 day each

### 4a. `viewer_providers_test.dart`

| File | `lib/features/viewer/viewer_providers.dart` (257 lines) |
|------|-----|
| **What to test** | `_mapReadError` (SSH error → `ViewerReadError` classification), `fileContentProvider` pipeline (read → classify → cache), `fileBytesProvider`. |
| **How to test** | The `_mapReadError` function is a pure mapper — extract it or `@visibleForTesting`. For the providers, use `ProviderContainer` with a mock executor that returns file bytes. |
| **Estimated tests** | 5–7 |

### 4b. `workspace_registration_test.dart`

| File | `lib/features/workspace/workspace_registration.dart` |
|------|-----|
| **What to test** | `registerAndActivateLocal` and `registerAndActivateSshActive` — bookmark creation, SavedLocalRepo persistence, fsmonitor enable, connection activation with fallback. |
| **How to test** | Mock the storage layer (connection store, local repo store, keychain). Test the success path, the "save fails but activation still works" fallback, and idempotency. |
| **Estimated tests** | 4–6 |

### 4c. `connection_form_test.dart` / `local_repo_form_test.dart`

These are 523 and 921-line form files respectively. Testing strategy depends on whether the business logic is extractable from the widget tree. Form-heavy files are best tested via widget tests (filling fields, pressing buttons) rather than unit tests on the state. Recommend widget-level integration tests using `WidgetTester` with mocked providers.

---

## Phase 5 — `app_providers.dart` integration tests

| File | `lib/core/providers/app_providers.dart` (4309 lines) |
|------|-----|
| **Strategy** | Do NOT attempt to test the whole file at once. Add targeted test coverage in small increments tied to bugs or feature work, using the mock executor from Phase 3a. |
| **When to write** | Attach to the next bug fix in this file — write the test first (red), then fix the bug (green). This avoids the up-front cost of understanding all 4309 lines. |

---

## Summary Roadmap

| Phase | Files | Tests | Effort | Depends on |
|-------|-------|-------|--------|------------|
| **1** | `app_providers_test.dart` | 4–5 | half day | — |
| **2a** | `auth_probe_service_test.dart` | 5–6 | 1–2 hrs | — |
| **2b** | `saved_local_repo_test.dart` | 4–5 | 1 hr | — |
| **2c** | `ref_chip_test.dart` | 6–8 | 2 hrs | `@visibleForTesting` in source |
| **2d** | `pinned_branches_test.dart` | 4–5 | 2 hrs | — |
| **2e** | `section_collapse_test.dart` | 3–4 | 1 hr | — |
| **2f** | `actions_test.dart` | 3–4 | 1–2 hrs | `@visibleForTesting` in source |
| **3a** | `test/helpers/mock_executor.dart` | — | half day | — |
| **3b** | `git_service_test.dart` | 15–20 | 2–3 days | Phase 3a |
| **3c–d** | `glab_service_test.dart` + `gh_service_test.dart` | 22–29 | 2–3 days | Phase 3a |
| **4a** | `viewer_providers_test.dart` | 5–7 | half day | Phase 2a harness |
| **4b** | `workspace_registration_test.dart` | 4–6 | half day | — |
| **5** | `app_providers_test.dart` (incremental) | as-needed | ongoing | Phase 3a |

**Total remaining:** ~80–100 test cases across 12–14 files, roughly 1–2 weeks of focused effort.

---

## Recommended Order of Execution

1. **Phase 1** first — regression guards for the two known bugs (half day, concrete value)
2. **Phase 2a–2e** next — quick wins that build confidence (one day)
3. **Phase 3a** — build the mock executor harness (half day, unlocks everything below)
4. **Phase 3b** — start with `git_service.dart`'s read methods (one day)
5. **Phase 3c–3d** — forge services (one day each)
6. **Phase 4** — provider tests (one day total)
7. **Phase 2f** — `actions_test.dart` (anytime, independent of infra)
8. **Phase 5** — ongoing, attach to future bug fixes
