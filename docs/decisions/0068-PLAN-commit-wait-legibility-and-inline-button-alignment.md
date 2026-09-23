---
status: "in-progress"
date: 2026-09-22
associated-madr: "0068-MADR-commit-wait-legibility-and-inline-button-alignment.md"
verified: 2026-09-22
---

# Implement: preview cleanup, a legible commit wait, and an inline button that stays where it is put

Associated MADR:
[0068-MADR-commit-wait-legibility-and-inline-button-alignment.md](0068-MADR-commit-wait-legibility-and-inline-button-alignment.md)

## Goal

After this plan: a killed message preview leaves nothing in the git dir; a stalled
`prepare-commit-msg` hook explains itself in the Output view; `InlineActionButton` sizes to its
capsule so the compact back bar's control sits where its parent asks; and the composer spinner's
cost is **measured** and the decision about it recorded — not guessed.

## Scope

**In scope**

* `lib/core/git/git_service.dart` — the preview script (trap + sweep) and stderr capture.
* `lib/core/output/output_log.dart` — no change expected; the append API is used as it is.
* `lib/features/common/inline_action_button.dart` — `Center(widthFactor: 1)`.
* Tests: `test/commit_message_preview_test.dart` (new), `test/inline_button_alignment_test.dart`
  (new), and the existing `test/inline_button_canon_test.dart` and workspace goldens as guards.
* This plan's execution record, the MADR's status, `docs/README.md`.

**Out of scope, deliberately**

* Replacing the spinner (MADR option B2). Phase 4 decides it from a measurement and records the
  outcome as an amendment; no code is written for it under this plan unless that measurement
  says so and the maintainer approves.
* The dropped-first-click observation: it is a **check** here (Phase 5), not a fix. Synthetic
  input cannot evidence it.
* The hook's own latency (provider-side, closed in 0067) and the Minimal preset's collapsing
  (0066, by design).

## Facts measured before writing this plan (2026-09-22)

These are the grounding for the phases below; each was run, not assumed.

| Fact | How it was measured | Result |
|---|---|---|
| The preview leaks its scratch file on the timeout path | A scratch repository with a stub hook that sleeps, running the script exactly as `git_service.dart:3270-3280` composes it, signalled TERM mid-hook | `leftovers=1` — `MAGICGIT_MSG_PREVIEW.WNYTMG` |
| It leaks on SIGKILL too | Same, signalled KILL | `leftovers=1` |
| ~~A `trap 'rm -f "$tmp"' EXIT INT TERM` fixes the timeout path~~ **Wrong — see D1.** | ~~Same repo, proposed script, TERM~~ that probe signalled the whole process group, which the executors never do | ~~`leftovers=0`~~ |
| ~~A trap cannot catch SIGKILL~~ | ~~Same, KILL~~ | ~~`leftovers=1`~~ |
| **With the executors' real kill sequence** (TERM to `sh` only, SIGKILL 400 ms later): the shipped script leaks and orphans the hook; the trap alone still leaks and orphans it; the hook in the background under `wait` with an EXIT trap leaks nothing and stops it | `leak_probe2.py` (scratch), the hook recording its own PID | shipped `1`/running; trap `1`/running; background+wait `0`/stopped |
| The back bar's capsule is centred, and the button is what centres it | Render-tree probe, 640 pt compact layout, scratch clone of `0fb8733` | keyed widget `x=8.0 w=624.0`; `Center` `x=8.0 w=624.0`; capsule `x=256.0 w=127.9` |
| The scratch repo must pin `core.hooksPath` | The first probe run silently exercised this machine's **global** AI hook and exited before it could be signalled | `git config core.hooksPath .git/hooks` in every fixture repo — a probe that calls a provider is not a probe |

The spinner's cost is **not** in this table, because the only figure taken so far (a ~58%
one-minute average, contradicted by an instantaneous 0.0–2.9%) does not support a conclusion.
Phase 4 measures it.

## Implementation Steps

Each phase ends with `flutter analyze`, the phase's tests, and one commit
(`git commit --no-edit`). A step that cannot be done as written is a deviation: stop and prompt.

### Phase 0 — Rehearse the failing tests

0.1. `git clone -q <repo> <scratch>/0068-rehearsal` at `HEAD`; `flutter pub get --enforce-lockfile`.
0.2. Add both new test files (Phases 1 and 3) to the clone only, and run them.
0.3. **Expected:** the preview test fails on the leftover file; the alignment test fails with the
     capsule's left edge near 256 rather than near the bar's padding. Record both messages
     verbatim.
0.4. Nothing is copied back except the test text.

### Phase 1 — The preview cleans up after itself

1.1. **`git_service.dart`, `generateCommitMessage`.** The script becomes, in order:
     * resolve `hp`, `hook`, `dir` exactly as today;
     * **sweep:** `find "$dir" -maxdepth 1 -name 'MAGICGIT_MSG_PREVIEW.*' -mtime +0 -delete
       2>/dev/null;` — older than a day only, so a concurrent preview in another tab is never
       touched, and `2>/dev/null` because a sweep failure must not fail the preview;
     * `tmp=$(mktemp …)`;
     * ~~**`trap 'rm -f "$tmp"' EXIT INT TERM;`** immediately after the `mktemp`;~~ **Replaced (D1):** `pid=; trap '[ -n "$pid" ] && kill "$pid" 2>/dev/null; rm -f "$tmp"' EXIT; trap 'exit 143' TERM; trap 'exit 130' INT;` immediately after the `mktemp`, and the hook runs as `"$hook" "$tmp" … & pid=$!; wait "$pid"; pid=;` — a signal interrupts `wait`, so the trap runs within the 400 ms grace, stops the hook and removes the file;
     * run the hook, `sed` the message out;
     * the trailing `rm -f "$tmp"` is dropped — the trap owns it now.
     The docstring gains ~~one line stating why the cleanup is a trap~~ **(D1)** two lines:
     the timeout TERMs the shell and SIGKILLs it 400 ms later, so a trailing statement never
     runs; and a trap is deferred while a foreground child runs, which is why the hook runs
     in the background under `wait` (both executors: `local_command_executor.dart:493`,
     `ssh_command_executor.dart:1162`).
1.2. **`test/commit_message_preview_test.dart`** (new), tagged `integration` (it runs real `git`
     and `sh` in a temp directory, like `worktrees_view_test.dart`):
     * a helper builds a temp repository, runs `git init -q`, **pins
       `git config core.hooksPath .git/hooks`**, and installs a stub hook;
     * **case 1 — the killed preview leaves nothing:** the hook sleeps 30 s and records its
       own PID; run the script through `Process.start('sh', ['-c', script])`, wait until the
       hook is running, then kill ~~the process group~~ **exactly as the executors do (D1):
       SIGTERM to the `sh` process only, SIGKILL 400 ms later**; assert no
       `MAGICGIT_MSG_PREVIEW.*` remains **and the hook's PID is no longer alive**;
     * **case 2 — the sweep collects an old leftover:** touch a
       `MAGICGIT_MSG_PREVIEW.stale` file with an mtime two days back, run the script with a fast
       hook, assert it is gone and the returned message is the hook's;
     * **case 3 — a concurrent preview is not swept:** a fresh-mtime leftover survives;
     * the script under test is read from the service rather than retyped — expose it as a
       `@visibleForTesting` constant (`kCommitMessagePreviewScript`) so the test cannot drift
       from the shipped text.
1.3. Verify: `flutter analyze`; `flutter test test/commit_message_preview_test.dart
     test/git_service_test.dart`. Commit.

### Phase 2 — The wait explains itself

2.1. **`git_service.dart`, `generateCommitMessage`.** The hook's stderr stops going to
     `/dev/null`: it is captured to `"$tmp.err"` (covered by the same trap), and after the `sed`
     the script emits it on a delimited channel the Dart side can separate — the message first,
     then a line `\u0000MAGICGIT_PREVIEW_STDERR\u0000`, then the captured stderr. The delimiter
     is written in Dart as the escape `\u0000` (a raw NUL in a source file is forbidden — see
     `CLAUDE.md` and `source_is_text_scan_test.dart`).
2.2. The Dart side splits on that marker: the message is what precedes it (unchanged behaviour,
     including the `null` for an empty message). The stderr half is emitted through the
     executor's existing `onOutput` callback (`CommandOutputCallback`, already threaded through
     `git_service.dart:4264` and `:5174`), which is how every other command's output reaches
     `OutputLogNotifier.append(…, OutputLineKind.stderr)`. Using the established sink rather
     than a new one keeps the hook's lines tagged, ordered and revealable like any other
     command's; the call site passes the callback the preview currently omits.
2.3. **Tests** in `test/commit_message_preview_test.dart`:
     * a hook that writes two stderr lines and a message: the message is exactly the message
       file's content, and both stderr lines reach the Output log;
     * a hook that writes stderr and **no** message: the call still returns null (the caller
       falls back to manual entry) and the stderr is still logged;
     * a hook whose stderr contains the marker text itself must not corrupt the split — assert
       the message is intact.
2.4. Verify: `flutter analyze`; the preview tests; `flutter test test/output_view_test.dart
     test/output_log_test.dart test/output_log_stream_test.dart test/git_service_test.dart` —
     all four exist. Commit.

### Phase 3 — The inline button sizes to its capsule

3.1. **`inline_action_button.dart:135`:** `Center(` becomes `Center(widthFactor: 1,`, with a
     one-line comment: the `Center` is there to centre the capsule vertically within
     `minimumTarget`; without `widthFactor` it also fills the width, which centres the capsule in
     any wide slot and overrides the parent's alignment (MADR 0068 §C).
3.2. **`test/inline_button_alignment_test.dart`** (new): the Phase 0 probe as a test — a 640 pt
     compact `AdaptiveWorkspaceLayout` with `compactNavigation`; assert the capsule's left edge
     is within 12 pt of the bar's left padding, and that its width is under half the bar's. A
     second case puts a bare `InlineActionButton` in a 400 pt `Align(centerLeft)` and asserts the
     same, so the rule is pinned at the widget, not only at its one caller.
3.3. Verify: `flutter analyze`; the new test; `flutter test test/inline_button_canon_test.dart
     test/compact_workspace_navigation_test.dart test/workspace_golden_test.dart
     test/workspace_accessibility_test.dart`. **The goldens must pass unchanged.** A golden that
     moves means some caller did rely on the expansion: stop, name the caller, and prompt —
     do not regenerate.
3.4. Commit.

### Phase 4 — Measure the spinner, then decide

4.1. **Build** a probe build as in 0064-PLAN deviation D5: a throwaway clone with
     `lib/diag/frame_spin_probe.dart` installed from `main()` (fps heartbeat, `SIGUSR1` dump,
     release-safe `BuildOwner.onBuildScheduled` hook). The scratch tooling from that work is
     reusable.
4.2. **Measure**, with the machine idle and the maintainer's consent to drive it: open a
     repository with staged changes, open the commit composer so a spinner is on screen (a hook
     that sleeps 20 s makes the window deterministic), and record
     * the probe's `fps=` heartbeat while the spinner is visible, and
     * `top -l 5 -pid <pid>` (instantaneous CPU, **not** `ps %cpu`),
     each against a control: the same surface with the spinner absent.
4.3. **Decide from the numbers**, and record the decision as MADR Amendment ~~0068.1~~ 0068.2 (D1) either way:
     * if the spinner's presence costs less than ~5% of a core, the answer is "no change", and
       the report's Finding 2 is closed as measured-and-acceptable;
     * if it costs materially more, option B2 (an elapsed-seconds line in place of the spinner,
       following `_ReconnectingOverlay`'s pattern at `app_shell.dart:107-130`) becomes a
       follow-up phase — **written and approved separately**, not smuggled in here.
4.4. Commit the amendment and this plan's record of the measurement.

### Phase 5 — Device gate and records

5.1. `./build_macos.sh --unsigned` (and `--install` only if the maintainer asks). Record the exit
     code.
5.2. **Maintainer checks**, each recorded PASS/FAIL with what was seen:
     | Item | Steps | PASS when |
     |---|---|---|
     | Preview cleanup | Stage a change; start a commit; cancel or let the hook stall past the timeout. Then inspect the repository's git dir. | No `MAGICGIT_MSG_PREVIEW.*` remains. |
     | Wait legibility | Repeat with a hook that prints to stderr. | The Output view carries the hook's lines while the wait is on. |
     | Back bar | At a compact width, open any list's detail. | The "‹ …" control sits at the left edge of its bar, not centred. |
     | Dropped first click (open observation, 0064 D4) | With the app **not** frontmost, click once on a control with a real mouse. | The click acts. A FAIL here opens a new record; it is not fixed under this plan. |
5.3. Update this plan's status, the MADR's status, `docs/README.md`, and
     `0067-REPORT`'s Findings 1 and 2 with pointers to what was done.
5.4. `dart run tool/records.dart check` prints `0 finding(s)`; `flutter test
     test/docs_records_test.dart test/no_real_identifiers_scan_test.dart` exits 0. Commit.

## Verification

| Check | Command | Pass condition |
|---|---|---|
| Static analysis | `flutter analyze` | `No issues found!` |
| Preview cleanup + stderr | `flutter test test/commit_message_preview_test.dart` | all cases pass |
| Negative (A) | Phase 0 in the scratch clone | the killed-preview case fails, message recorded |
| Button alignment | `flutter test test/inline_button_alignment_test.dart` | both cases pass |
| Negative (C) | Phase 0 in the scratch clone | fails with the capsule near x=256, message recorded |
| No caller relied on expansion | `flutter test test/workspace_golden_test.dart test/inline_button_canon_test.dart` | green, goldens **not** regenerated |
| Full suite | `flutter test > "$LOG" 2>&1; STATUS=$?` | `STATUS` 0; `grep -c '\[E\]' "$LOG"` prints 0 |
| Spinner cost | Phase 4.2 | both numbers recorded, with their control |
| Device | Phase 5.2 | four rows recorded |
| Records | `dart run tool/records.dart check` | `0 finding(s)` |

## Acceptance Criteria

* AC1 — Both new tests were seen to fail on the unmodified tree (Phase 0), with their messages in
  the execution record.
* AC2 — A preview killed by the timeout leaves no `MAGICGIT_MSG_PREVIEW.*`, proven by a test that
  kills a real `sh` running the shipped script text (not a retyped copy).
* AC3 — A stale leftover is swept; a fresh one (a concurrent preview) is not.
* AC4 — The hook's stderr reaches the Output log, and the returned message is unchanged by it,
  including when the stderr contains the marker text.
* AC5 — The compact back bar's capsule sits at the bar's left padding, and a bare
  `InlineActionButton` in a wide `Align(centerLeft)` does too.
* AC6 — The 48 workspace goldens and `inline_button_canon_test.dart` pass unchanged; no golden is
  regenerated.
* AC7 — Full suite green, 0 `[E]`, after every phase.
* AC8 — The spinner's cost is measured against a control and recorded as Amendment ~~0068.1~~ 0068.2, with
  either "no change" or a named follow-up.
* AC9 — Phase 5's four device rows are recorded, including the dropped-first-click observation as
  PASS, FAIL-with-new-record, or explicitly not-run.

## Rollout and Rollback

Rollout is the next `./build_macos.sh --unsigned --install`. Nothing persists and no data
migrates: the script change affects one command's text, the button change is layout only.

Rollback is `git revert` of the phase commits, newest first. Reverting Phase 1 restores the
leaking script; reverting Phase 3 restores the centred capsule. The sweep deletes only
`MAGICGIT_MSG_PREVIEW.*` files older than a day in the resolved git dir, so a rollback leaves
nothing to undo.

## Execution record

* **D1 (2026-09-22, deviation, before Phase 1): step 1.1's trap does not work under the executors' kill sequence.**
  * **Evidence.** Both executors TERM the `sh` process only and SIGKILL it 400 ms later (`local_command_executor.dart:493`, `ssh_command_executor.dart:1162`, `killGrace` at `:1143`); POSIX `sh` defers a trap until its foreground child exits. Measured in a scratch repository with a stub hook that records its own PID, hooks path pinned: the shipped script leaves `leftovers=1` with the hook still running; the trap alone, `leftovers=1` with the hook still running; the hook backgrounded under `wait` with an EXIT trap, `leftovers=0` and the hook stopped. The earlier probe in this plan's facts table signalled the whole process group, which also killed the hook — so it measured a kill the app never performs. A second defect surfaced: the shipped script **orphans the hook**, so an AI hook keeps calling its provider after the app has given up.
  * **Resolutions offered:** (1) background the hook under `wait` with an EXIT trap, in the preview script; (2) make the executors signal the process group, for every command; (3) do 1 here and file 2 as its own record.
  * **Decision (maintainer, 2026-09-22): option 3.** MADR Amendment 0068.1 records the corrected mechanism and the orphan finding; step 1.1 and the two wrong facts-table rows are struck through and corrected above; the spinner's amendment becomes 0068.2. The executors' behaviour is written up in [0069-REPORT](../reports/0069-REPORT-timed-out-commands-signal-only-the-leader.md), not fixed here. No code had been written when this was found.
  * **Files added to scope:** `docs/reports/0069-REPORT-timed-out-commands-signal-only-the-leader.md`.
