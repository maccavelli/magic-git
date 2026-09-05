---
status: "in-progress"
date: 2026-09-04
associated-madr: "0029-MADR-host-scripts-must-be-executed-by-a-test.md"
---

# Enforce the host-script coverage rule, and close the five gaps

Associated MADR: [0029-MADR-host-scripts-must-be-executed-by-a-test.md](0029-MADR-host-scripts-must-be-executed-by-a-test.md)

## Goal

Make it impossible for a host script to ship with only a string assertion behind
it, and close the five builders that are in that state today.

## Scope

**In scope**

* A scan test enumerating every host-script builder in `lib/`, requiring each to
  be either **executed** by a test or **exempt with a recorded reason**.
* Executable tests for the builders that can run on the development machine.
* Named exemptions, with reasons, for those that cannot.

**Out of scope**

* Changing any script's behaviour. This plan adds coverage; if a script turns
  out to be broken — which is the likely outcome for at least one, given the
  sweep — that is a **deviation**, stopped on and prompted, not fixed inline.
* Running anything against a real host. The suite must stay host-independent.
* `live-forge`-tagged work.

## Preconditions

```sh
flutter --version | head -1          # 3.47.2
flutter pub get --enforce-lockfile   # "Got dependencies!"
git status --short                   # empty
flutter analyze                      # No issues found!
flutter test                         # 3490 passing, 2 skipped, 0 failing
```

Any deviation from **3490 / 2 / 0**: stop and prompt.

## Implementation Steps

### Phase 1 — The registry and the scan

**Files.** new `test/host_script_coverage_test.dart`.

Enumerate builders by scanning `lib/` for top-level functions returning a shell
script (`String <name>Script(`), and require each name to appear in exactly one
of two declared sets in the test itself:

```dart
/// Builders proven by a test that RUNS the script and observes its effect.
const executed = <String>{ 'watcherSweepScript', … };

/// Builders that cannot be executed on the development machine.
/// Every entry states why. An entry is a debt, not a dismissal.
const exempt = <String, String>{
  'boundedInotifyScript':
      'needs inotifywait, which does not exist on macOS; …',
};
```

The scan fails when a builder is in neither set, or in both.

**1a. Negative test.** Add a throwaway builder to a fixture and assert the scan
reports it. **Required red:** the scan passes with an unlisted builder before
the check exists.

> The scan must read `lib/` itself, not a hand-maintained list — a hand-list is
> the same class of check as the string assertion this record exists to
> constrain.

**Acceptance.** Scan red then green; suite +1. **Commit.**

### Phase 2 — Execute what can be executed

**Files.** `test/host_script_exec_test.dart` (new), possibly renaming
`test/watcher_sweep_exec_test.dart` into it.

Two candidates run on macOS with no extra dependencies:

* **`catFileBatchScript`** — needs only `git`, `mktemp`, `base64`. Run it in a
  temp git repo against real objects, and assert the framed output decodes to
  the exact blob bytes. This one has never been executed, and it carries the
  0022 M10 binary-safety fix, which is precisely a claim about bytes that a
  string assertion cannot check.
* **`recursiveWatchScript`** and the bounded scripts — the *lease loop* around
  the watcher is pure shell and can be executed with a stand-in inner command
  in place of `inotifywait`, exercising the heartbeat check, the `trap`, and the
  re-arm.

**2a.** Each gets a positive case (it acts) and a negative case (it declines) —
the pairing that catches "does nothing" and "does too much" alike.

**Required red:** proven per script, by breaking its input rather than
asserting from a green run.

**Acceptance.** Tests red then green; every builder moved out of `exempt` that
can be. **Commit.**

### Phase 3 — Record the residue honestly

Whatever remains exempt keeps a written reason in the registry, and the same
list is summarised in the MADR. `rootlessInstallScript` is expected to stay
exempt — it installs binaries, and executing it in a test would mutate the
developer's machine.

**Acceptance.** No exemption without a reason; the MADR's table updated to the
post-plan state.

## Verification

**Per phase:** the phase's own tests, plus

```sh
flutter analyze          # No issues found!
flutter test             # passing rises by exactly the tests added; failing 0
```

**Whole-plan acceptance.**

1. Every negative test observed red, verbatim, in the execution record.
2. The scan was **seen to fail** on an unlisted builder.
3. No script's behaviour changed; any defect found is a recorded deviation.
4. Every exemption carries a reason.
5. The suite remains host-independent — no test requires SSH or a remote.

## Rollout and Rollback

Test-only. Rollback is reverting the commits; no production code changes and
nothing touches a host.

The risk is the plan's own scope: executing scripts that were never executed is
likely to find at least one that does not work, and the temptation will be to
fix it inline. It is a deviation — stop and prompt — because a fix chosen while
mid-way through a coverage sweep gets neither its own red test nor its own
record, which is how the sweep shipped dead in the first place.

## Execution record

*(Empty until approved.)*

| Phase | Status | Commit | Red-test observed | Result |
|---|---|---|---|---|
| 1 | not started | — | — | — |
| 2 | not started | — | — | — |
| 3 | not started | — | — | — |
