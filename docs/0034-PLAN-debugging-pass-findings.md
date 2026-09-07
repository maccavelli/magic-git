---
status: "in-progress"
date: 2026-09-07
associated-madr: "0034-MADR-debugging-pass-findings.md"
---

# Fix the debugging pass's findings, severity first

Associated MADR: [0034-MADR-debugging-pass-findings.md](0034-MADR-debugging-pass-findings.md)

## Goal

Work through 0034's nine findings in the three tranches its Decision Outcome
chose. **This plan covers tranche 1 — the silence class: F1, F9, F7** — the
findings whose common property is that something fails and nothing says so.

F2, F3 and F4 (the crash trio) are **already done**, under
[0035](0035-MADR-multi-select-coverage-and-the-two-guards-it-blocks.md) and
commit `44169ac`. Tranche 3 (F5, F6, F8 — the hygiene items) is deliberately
left for a later plan.

## Scope

### In scope

| Finding | What | Files |
| --- | --- | --- |
| **F1** | No `ProviderObserver` anywhere but the pop-out window | new `lib/core/providers/provider_failure_observer.dart`; `lib/main.dart:107`; `lib/features/tabs/tabs_controller.dart:95` |
| **F9** | Forge prefs applied optimistically, persistence failures swallowed | `lib/features/forge/forge_prefs.dart` (4 sites: `:72, :80, :120, :146`) |
| **F7** | `gh api user/orgs` truncates silently at 100 | `lib/core/github/gh_service.dart:390` |

### Out of scope

* **Tranche 2** (F2/F3/F4) — done.
* **Tranche 3** (F5 orphaned CI enum, F6 duplicated legacy watcher filenames,
  F8 the false `--paginate` comment).
* The **49 `.value ?? const []`** sites. 0034 is explicit that the fix is the
  missing observer, not 49 call sites: collapsing a *loading* store to an empty
  list is usually right, and the defect is that nothing notices the *error*
  case. Changing them would be a large UI change with its own design question.
* `glab_service.dart:563` (`groups?min_access_level=30&per_page=100`). Same
  defect class as F7 and recorded in 0032, but it is the input to the namespace
  suggestions that **0032 proposes to replace wholesale**. Fixing pagination in
  code 0032 will rewrite is wasted work; it belongs to whichever plan executes
  0032. **Stated here so it is not mistaken for an oversight.**

### Preconditions

```sh
flutter --version | head -1          # Flutter 3.47.2
flutter pub get --enforce-lockfile   # "Got dependencies!"
git status --short                   # empty
```

### Baselines (captured 2026-09-07 at `440d57e`)

| Metric | Value |
| --- | --- |
| `expect(` across `test/` | **9134** |
| `testWidgets(` across `test/` | **1012** |
| Full suite | **3612** passing, 2 skipped |

## Implementation Steps

Three phases, **one commit each**, in severity order.

---

### Phase 1 — F1: make a failed provider leave a trace

**The finding.** Retry is off by design (`noProviderRetry`, enforced by
`provider_retry_policy_test.dart`); **no observer is wired** to the main scope
(`main.dart:107`) or to any tab container (`tabs_controller.dart:95`); and 49
UI sites collapse error to empty. The pop-out window
(`secondary_window_main.dart:159`) is the *only* place a provider failure leaves
a trace, via `_ProviderFailureLogObserver`.

**1a. `lib/core/providers/provider_failure_observer.dart`.** A
`ProviderObserver` overriding `providerDidFail`, routing to the app's own output
log — the surface the user can already open — rather than a second channel.

`ProviderObserverContext` exposes `container` (riverpod 3.3.2,
`provider_container.dart:1334`), so the log is reachable:

```dart
context.container.read(outputLogProvider.notifier)
    .logError('provider', '<name>(<argument>): <error>');
```

**Two hazards this must handle, and a test each:**

* **Re-entrancy.** `providerDidFail` runs *during* a provider lifecycle event.
  Reading another provider synchronously from inside it risks re-entering the
  container. Defer with `scheduleMicrotask`, and say why in a comment.
* **The observer must never itself throw.** A logger that fails during error
  handling turns one failure into two, and the second has no observer. Wrap the
  body in `try/catch` that discards — **the one place in this plan where
  swallowing is right**, and it needs a comment saying so, since F9 in the same
  commit-series is about *not* doing that.

**1b. Wire it in both places** — `main.dart:107` and
`tabs_controller.dart:95` (`_defaultContainerFactory`). Note `main.dart`'s
scope is `const`; adding `observers:` may cost that, which is fine but should
be deliberate, not accidental.

**Tests** (new file `test/provider_failure_observer_test.dart`):

1. A provider that throws produces a log line naming the provider and the error.
2. The provider's **argument** appears for a family (so `refsProvider('/repo')`
   is distinguishable from `refsProvider('/other')`).
3. An observer whose log sink throws does **not** propagate — the original
   failure still surfaces, nothing else does.
4. `tabs_controller.dart`'s factory attaches the observer (assert a tab
   container's failure is logged, not just the root's).

**Sabotage:** remove the `observers:` argument from each wiring point in turn;
tests 1–2 must fail for the root, test 4 for the tab container.

**Acceptance:** a forced provider failure produces a log line from the **main**
window; `flutter analyze` clean; full suite green.

---

### Phase 2 — F9: stop swallowing forge-prefs writes

**The finding.** `forge_prefs.dart` discards four persistence failures with bare
`catch (_) {}` (`:72, :80, :120, :146`). `set()` assigns `state = inbox`
**before** the write and drops the write's failure, so the UI shows a setting
that will not survive a restart and nothing says so.

**The fix is to report, not to revert.** Rolling the optimistic state back on
failure would make a pin flicker off under the user's cursor; the honest
behaviour is to keep the state and say it did not persist. Route to the output
log, the same surface Phase 1 uses.

**Steps:** give the notifier a log sink; replace each `catch (_) {}` with a
`catch (e)` that logs `'forge prefs'` and the error. The **load** paths
(`:72, :120`) may legitimately stay quiet on a *missing* key but must not stay
quiet on a *thrown* read — check which each one is before changing it.

**Tests:** a failing `SharedPreferences` produces a log line and leaves the
in-memory state applied. Sabotage: restore the bare `catch`; the test must fail.

**Acceptance:** no bare `catch (_) {}` left in `forge_prefs.dart`; state still
optimistic; failure visible.

---

### Phase 3 — F7: `gh api user/orgs` must not truncate at 100

**The finding.** `gh_service.dart:390` requests `user/orgs` with `per_page=100`
and **no page walk**. An account in more than 100 organisations loses the tail
silently. The codebase already knows this failure mode —
`gh_service.dart:532` carries a comment about "a single `per_page=100` page
silently truncated a matrix run wider than 100", a bug found and fixed in a
different call.

**Fix:** hand-walk pages with `page=N`, stopping on a short page, bounded by a
constant in the same spirit as `GlabService._maxListPages`. **Not**
`--paginate`: 0034's F8 records that `glab api --paginate` returns concatenated
JSON documents, and this plan must not introduce the sibling hazard on the gh
side without verifying `gh api --paginate`'s output shape first.

**Tests:** a fake executor returning a full first page then a short second page
yields the union; a single short page issues exactly one call (no wasted round
trip). Sabotage: drop the walk; the first test must fail.

**Acceptance:** an account with >100 orgs sees them all; call count unchanged
for the common single-page case.

## Verification

At the end of every phase:

```sh
flutter analyze                                  # clean on the first pass
dart format --output=none --set-exit-if-changed <each staged file>
flutter test                                     # full suite
printf 'expect=%s testWidgets=%s\n' \
  "$(grep -rho 'expect(' test/ | wc -l | tr -d ' ')" \
  "$(grep -rho 'testWidgets(' test/ | wc -l | tr -d ' ')"
```

Standing rules that apply: `dart format` in place, never chained with `&&`
before `git commit`, never `dart format lib/ test/` globally; sabotage in a
scratch `git worktree`, never by dirtying the tree; **read the whole failure
list**, not the first line.

### Acceptance criteria for the plan as a whole

1. A provider failure in the **main** window and in a **tab** container each
   produce a log line — the asymmetry with the pop-out window is gone.
2. The observer cannot turn one failure into two: a throwing sink is contained,
   proven by test.
3. `grep -c "catch (_) {}" lib/features/forge/forge_prefs.dart` returns **0**.
4. `user/orgs` walks pages; proven by a fake returning two.
5. Every new test seen to fail against a deliberate break.
6. `flutter analyze` clean and full suite green at every phase.

## Execution record

### Phase 1 — 2026-09-07 — *complete*

**Delivered.** `lib/core/providers/provider_failure_observer.dart` —
`ProviderFailureObserver`, wired at both scopes the finding named:
`main.dart` and `tabs_controller.dart`'s `_defaultContainerFactory`. Failures
go to the app's own output log via `context.container` (riverpod 3.3.2,
`provider_container.dart:1334`), deferred onto a microtask because
`providerDidFail` runs *during* a provider lifecycle event.

**Open question 1 resolved by proceeding.** The plan asked whether the output
log is the right destination or whether this should be a debug-only sink. No
answer was given, so it went to the output log as the plan's stated assumption —
the surface that already exists and the one a user can be asked to read. The
plan noted this is wrong cheaply if wrong: only the observer body changes.

**Five tests, each seen to fail.** The two wiring points, the naming, the
family argument, and the containment:

```
main.dart scope: observer removed   -> every production provider scope attaches a failure observer
tab container: observer removed     -> every production provider scope …
                                       the tab container factory attaches the observer
observer logs nothing               -> a failed provider is logged, naming the provider and the error
                                       a family failure names its argument …
                                       the tab container factory attaches the observer
family argument dropped             -> a family failure names its argument …
containment removed                 -> the observer contains a failure in its own write
```

**`main.dart`'s scope is enforced by a source scan, not a unit test** — its
`ProviderScope` is inside `runApp` and unreachable from a test. The scan
mirrors `provider_retry_policy_test.dart`'s "every production provider scope
uses the policy", which is this codebase's established way of pinning a scope's
configuration.

**The containment test was vacuous three times before it was real.** Recorded
because each version *passed*, and a passing test that proves nothing is worse
than none:

1. First version disposed the container after `await expectLater(...)`. The
   `await` **drains the observer's microtask while the container is still
   alive**, so the disposed path never ran. It passed against an observer with
   its `catch` deleted.
2. Second version added `runZonedGuarded` to catch the escaping async error —
   but still awaited first, so still never reached the path.
3. Third version disposed before any `await`, but asserted
   `throwsStateError` on the read. `read` rethrows a **wrapped, riverpod-
   internal** type, so the matcher failed inside the zone, the zone swallowed
   the `TestFailure`, and the test **hung for 30 seconds** instead of failing.

The working version disposes before any await and does not pin the throw's type
at all — `ProviderException` is not exported, and the assertion that matters is
that nothing escaped the zone. Verified: deleting the observer's `catch` now
fails exactly this test.

Reading a disposed container **does** throw — measured directly with a
throwaway probe — so the `catch` is load-bearing, not defensive decoration.

**Verification:**

```
flutter analyze (whole project)   No issues found! (ran in 4.2s)
dart format --output=none --set-exit-if-changed   (0 changed)
flutter test (full suite)         03:23 +3617 ~2: All tests passed!
```

**Counts.** `expect(` 9134 -> **9140**; `testWidgets(` **1012** unchanged (these
are plain `test()`s). Suite 3612 -> **3617**.

### Phase 2 — 2026-09-07 — *complete*

**Open question 2 resolved by reading the code: all four sites report; the
phase does not shrink.** The plan wondered whether the two *load* paths swallow
"missing key" (which is normal) or a thrown read (which is not). Both handle the
missing key **explicitly before the catch** — `if (stored != null)` at `:71` and
`if (stored == null || stored.isEmpty) return;` in the marks loader — so every
one of the four `catch` blocks fires only on a genuine failure.

**Reporting, not reverting.** All four now log to the output log and **keep** the
optimistic state. Rolling back on failure would make a pin flicker off under the
user's cursor; the honest behaviour is to keep the change and say it did not
persist. Each message says which it was, e.g. *"pin/snooze will not survive a
restart"*.

`_reportPrefsFailure` wraps its own write in a `try/catch` for the same reason
the observer does — the marks notifier is `autoDispose`, so `ref.read` can throw
after teardown, and a failure to *report* a failure must not be worse than the
original.

**Making it fail was the interesting part.** There is no clean way to force
`SharedPreferences` to throw with a mock installed — so the test installs
**none**. Without `setMockInitialValues`, `getInstance()` throws, which is
exactly the thrown-read/write case these catches exist for. Three tests: the
write path, the pin path, and a read.

**Sabotage — both halves of the claim:**

```
reporting removed entirely       -> all three tests
state reverted instead of kept   -> a failed Inbox/Browse write is reported,
                                    and the choice still applies
```

The second matters: without it the tests would pass for an implementation that
reported the failure *and* silently discarded the user's change.

**Verification:**

```
flutter analyze (whole project)   No issues found! (ran in 4.8s)
dart format --output=none --set-exit-if-changed   (0 changed)
flutter test (full suite)         03:25 +3620 ~2: All tests passed!
grep -c "catch (_) {}" lib/features/forge/forge_prefs.dart   -> 0
```

**Counts.** `expect(` 9140 -> **9145**; suite 3617 -> **3620**. Acceptance
criterion 3 met.

## Rollout and Rollback

**Rollout.** Three commits in severity order. They are independent — F1 touches
provider wiring, F9 a prefs notifier, F7 a forge service — so any can land
alone.

**Rollback.** `git revert <sha>` per phase, no ordering constraint. Phase 2 and
Phase 3 have no dependency on Phase 1; if F9's log routing is built on the same
sink Phase 1 introduces, note that in its commit and revert Phase 2 first.

No data migration and no persisted format change. **F1 and F9 are both
user-visible in one direction only** — more lines in the output log, never
fewer — and F7 changes results only for an account with more than 100 orgs.

## Open questions

1. **Does the observer belong on the output log, or somewhere quieter?** The
   output log is user-facing. A provider failing on a flaky network would now
   write there, which is arguably noise for a user who is not debugging. The
   alternative is a debug-only sink like the pop-out window's. This plan
   assumes the output log because it is the surface that already exists and the
   one a user can be asked to read; **if that is wrong, it is wrong cheaply**
   and only Phase 1a changes.
2. **F9's load paths.** `:72` and `:120` swallow *read* failures. A missing key
   is normal and must stay quiet; a thrown read is not. The plan says to check
   which each is — if both are genuinely "missing key", Phase 2 shrinks to the
   two write sites.
