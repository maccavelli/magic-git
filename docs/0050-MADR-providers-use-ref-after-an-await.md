---
status: "proposed"
date: 2026-09-12
decision-makers: [Maintainer]
consulted: []
informed: [Magic Git contributors]
verified: 2026-09-12
---

# Providers touch `ref` after an `await`: the cost is a misleading log line, and the fix is to register dependencies synchronously

## Context and Problem Statement

Opening a worktree tab and leaving it puts two errors in the Output pane:

```text
FutureProvider<RepositoryWorkspacePrefs>(<worktree path>): Cannot use the Ref of
FutureProvider<RepositoryWorkspacePrefs>#eeb49(<worktree path>) after it has been disposed. …
FutureProvider<RepoNode>(<worktree path>): Cannot use the Ref of
FutureProvider<RepoNode>#b8cd0(<worktree path>) after it has been disposed. …
```

Riverpod's message names the cause generically ("a provider rebuilt, but the previous build was still
pending"). This record establishes which of its two cases actually happens here, what it costs, and
what the correct repair is — because the two cases differ, and only one of them was occurring.

### F1 — The two providers, and the exact lines

Both are `FutureProvider.autoDispose.family`, keyed by repository path, and both use `ref` **after**
their first `await`:

* `repositoryWorkspacePrefsProvider` (`lib/core/providers/app_providers.dart:4671-4684`):
  `await ref.watch(repositoryUiIdentityProvider(repoPath).future)`, then
  `ref.watch(appSettingsProvider.select(…))`.
* `repoStructureProvider` → `RepoNode` (`app_providers.dart:3677-3694`):
  `await ref.watch(statusProvider(repoPath).selectAsync(structureSignature))`, then
  `ref.watch(gitServiceProvider)` and `_retryAfterForgeAuthIfNeeded(ref, …)`.

### F2 — Why a worktree tab triggers it

Both awaits are slow by nature: a UI-identity resolution, and a status round trip that may cross SSH.
Opening the worktree tab starts both builds for that path; leaving the tab disposes the family entries
while those builds are still suspended. When the awaited value finally lands, the continuation runs
with a `Ref` that no longer exists, and the post-`await` `ref.watch` throws.

The path in the message is the family key, not the culprit: any repository would do, given a slow
enough dependency and a quick enough exit.

### F3 — Measured: which case happens, and what it costs

Both cases were driven deterministically in a scratch worktree, against the real `repoStructureProvider`
with its dependencies held open by completers:

| Scenario | What a live listener observed | Failures reported to the observer |
| --- | --- | --- |
| **Rebuilt** while pending (`invalidate`, pane still listening) | `loading → data`, `hasError: false` | **0** |
| **Disposed** while pending (last listener leaves — the reported case) | no listener exists, by construction | **1**, verbatim: `Cannot use the Ref of FutureProvider<RepoNode>#…(/repo) after it has been disposed` |

Two things follow, and they matter for how much this is worth:

* **No pane is damaged.** The rebuild case — the only one where something is still watching — does not
  surface an error at all. Riverpod does not resume the stale build into the provider's state, so pane
  widths do not snap back to defaults and the file tree does not empty. This was an open question in
  the first draft of this analysis; it is now measured, and the answer is no.
* **What it does cost is the log.** MADR 0034 added `ProviderFailureObserver` precisely so that real
  provider failures stop being silent. Every one of these writes a line into that same channel, so the
  defect degrades the instrument built to make genuine failures visible.

### F4 — It is a class, not two sites

A scan of `lib/` finds **28 provider bodies** that touch `ref` (`watch`, `read`, `listen`,
`keepAlive`, `invalidate`) after an `await`. That is the exposure surface, not 28 live defects: only a
provider actually disposed mid-build throws. The two in F1 are simply the two whose awaits are slow
enough, and whose keys are short-lived enough, to lose the race routinely.

### F5 — The repair is not primarily a `mounted` check

Both offending calls are `ref.watch`, and Riverpod asks for dependencies to be registered
**synchronously**: a `watch` issued after an `await` may be skipped on a rebuild, so late registration
is its own latent bug independent of disposal. Neither call needs the awaited value —
`gitServiceProvider` and the `paneWidths` selector can both be read *before* the await. Hoisting them
removes the error and the late-registration hazard together.

`ref.mounted` remains the right tool for a read that genuinely must follow a gap. The codebase already
uses it 55 times in `app_providers.dart`, including in this very neighbourhood:

```dart
await controller.forgeAuthSettled;
if (!ref.mounted) rethrow;          // _retryAfterForgeAuthIfNeeded, app_providers.dart:5539
```

The same helper also has an **unguarded** `ref.read(connectionProvider)` immediately after its first
`await load()` (`app_providers.dart:5532`) — the same shape, on a rarer path (an auth failure).

### F6 — This is enforceable, and the repo already enforces its sibling

`test/provider_retry_policy_test.dart` scans `lib/` and fails when an async provider omits
`retry: noProviderRetry`. A scan of the same shape — `ref.` used after an `await` inside a provider
body — would have caught both of these before they shipped, and would keep the other 26 honest.

## Decision Drivers

* The Output pane's failure log must stay trustworthy; noise there costs more than it looks, because
  its whole purpose is that real failures are noticed.
* Dependencies must be registered synchronously, which is a correctness rule in Riverpod rather than a
  style preference.
* A fix for two sites that leaves 26 of the same shape is a fix with a short shelf life.
* Whatever is decided must be enforced by something that fails on its own, not by reviewer memory.

## Considered Options

* **A — Hoist the two post-`await` `ref.watch` calls** in the reported providers.
* **B — A, plus sweep the other 26 sites.**
* **C — A, plus a scan test that fails on `ref` use after an `await` in a provider body.**
* **D — Guard with `ref.mounted` instead of hoisting.**
* **E — Do nothing, or filter this message out of the log.**

## Decision Outcome

Chosen option: **"C — hoist, and add the scan"**, with the sweep (B) falling out of the scan rather
than being attempted by hand.

A alone silences the two lines the maintainer sees and leaves the class intact. C fixes those two the
right way — synchronous registration — and then lets the scan name every other site, each of which is
then either hoisted, guarded with `ref.mounted` and a stated reason, or allow-listed with that reason
written down. That is the same shape as `watch_stack_structure_test.dart`'s allow-list, which the
project already trusts.

E is rejected outright: filtering a message out of the failure log to make a defect quiet is precisely
the workaround the log exists to prevent — and it would hide genuine disposal bugs, which this one
turns out not to be but the next one may be.

### Consequences

* Good, because the reported noise disappears at the cause, not at the reporter.
* Good, because hoisting also removes late dependency registration, a latent bug that has not yet been
  observed but does not announce itself when it happens.
* Good, because the scan converts a convention into something that fails a run.
* Neutral, because some of the 26 remaining sites are legitimate and will need a written reason rather
  than a change; that reason is worth having.
* Bad, because a scan over provider bodies is a text-level approximation: it will need an allow-list,
  and an allow-list is a thing to maintain. The alternative — reviewer vigilance — has already been
  measured at 28 sites.

### Confirmation

* A regression test built from the probe in F3: with the fix in place, disposing the provider
  mid-build reports **zero** failures to a `ProviderObserver`, where today it reports one. Run against
  the unmodified tree first, where it must fail with the exact message in F3.
* The scan test, seen to fail: it must flag a deliberately reintroduced `ref.watch` after an `await`.
* The full suite, and `flutter analyze`.
* Manually: open a worktree tab on a remote repository, leave it within a second, and the Output pane
  stays clean.

## Pros and Cons of the Options

### A — Hoist the two calls

* Good, because it is small, and it removes the reported symptom at its cause.
* Good, because both hoisted reads are independent of the awaited value, so nothing changes semantically.
* Bad, because 26 sites of the same shape remain, and the next slow dependency puts a new pair of lines
  in the log.

### B — A plus a manual sweep

* Good, because it closes the class today.
* Bad, because "we looked at all 28 once" decays the moment the twenty-ninth is written, and nothing
  reports it.

### C — A plus a scan test *(chosen)*

* Good, because the sweep becomes a list the machine produces and keeps producing.
* Good, because it matches an enforcement pattern already in the repo.
* Neutral, because the scan is textual, so it sees shape rather than meaning.
* Bad, because it needs an allow-list with reasons — which is also the mechanism by which the
  legitimate cases get explained rather than silently tolerated.

### D — `ref.mounted` guards instead of hoisting

* Good, because it is mechanical and uniform.
* Bad, because it treats the symptom: the `watch` still registers a dependency late, which Riverpod
  documents as unsupported, and a guard makes that invisible rather than absent.

### E — Do nothing, or filter the message

* Good, because it costs nothing today — the measurements in F3 show no pane is harmed.
* Bad, because the noise lands in the one channel built to make failures noticeable (MADR 0034), and a
  filter keyed to this message would suppress genuine disposal defects too.

## More Information

* **Code this record reads.** `lib/core/providers/app_providers.dart:3677-3694` (`repoStructureProvider`),
  `:4671-4684` (`repositoryWorkspacePrefsProvider`), `:5524-5542`
  (`_retryAfterForgeAuthIfNeeded`, both the guard at 5539 and the unguarded read at 5532);
  `lib/core/providers/provider_failure_observer.dart` (why these reach the Output pane);
  `test/provider_retry_policy_test.dart` (the enforcement pattern to copy).
* **Evidence.** The maintainer's Output pane (F1); the deterministic two-scenario probe (F3), run in a
  detached scratch worktree and removed afterwards — the working tree was never dirtied.
* **Incidental finding, worth its own fix.** `lib/core/utils/git_porcelain_parser.dart` is a **second**
  file whose bytes make search tools treat it as binary: a plain `grep` for `class GitStatus` returns
  nothing, silently. `AGENTS.md` documents this hazard for `app_providers.dart` only. Anyone
  investigating by search will be misled the same way this analysis briefly was, and the file list in
  `AGENTS.md` should either name both or be replaced by a check that finds them.
* **Not established.** Whether any of the other 26 sites currently throws in practice. The scan in C is
  what would answer that; F4 counts shape, not occurrences.
* **No implementation exists.** This record proposes a decision; a plan follows only on approval.
