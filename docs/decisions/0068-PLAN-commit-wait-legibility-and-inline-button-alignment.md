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
* **(D4)** `lib/core/exec/local_command_executor.dart` — each process signalled at most once; the drain-failure path escalates. `lib/core/ssh/ssh_command_executor.dart` — one comment that described the local `finally`. `test/local_command_executor_test.dart` — three cases.

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

~~2.1–2.3 as first written~~ — **replaced by D2**; the original text is kept below for the record.

2.1′. **`git_service.dart`.** In `kCommitMessagePreviewScript` the hook's `2>&1` goes: its stdout stays `>/dev/null`, its stderr inherits the script's. `generateCommitMessage` gains `{CommandOutputCallback? onOutput}` and passes it to `execute`.
2.2′. **`commit_composer_controller.dart`.** A top-level `previewCommitMessageWithOutput(git, log, repoPath)` — the provider's `generatePreview` calls it with the log notifier read **before** any `await` — forwards `stderr: true` chunks to an `OutputStreamSession` opened on the first chunk, closes it with exit 0 on success, the `GitException`'s exit code on a failure, or `fail()` on anything else (a timeout), and ignores stdout (the message is shown in the composer).
2.3′. **Tests.** The script half, in `commit_message_preview_test.dart`: a hook writing two stderr lines and a message — `sh`'s stderr carries both lines, its stdout is exactly the message. The wiring half, in `test/commit_preview_output_test.dart` (new): a fake `GitService` that emits stderr and stdout chunks — the stderr lines reach the Output log under a single stream session, stdout does not, the message is returned unchanged; a silent preview adds no line at all; a thrown `GitException` closes the session with its exit code.

~~2.1. **`git_service.dart`, `generateCommitMessage`.** The hook's stderr stops going to
     `/dev/null`: it is captured to `"$tmp.err"` (covered by the same trap), and after the `sed`
     the script emits it on a delimited channel the Dart side can separate — the message first,
     then a line `\u0000MAGICGIT_PREVIEW_STDERR\u0000`, then the captured stderr. The delimiter
     is written in Dart as the escape `\u0000` (a raw NUL in a source file is forbidden — see
     `CLAUDE.md` and `source_is_text_scan_test.dart`).~~
~~2.2. The Dart side splits on that marker: the message is what precedes it (unchanged behaviour,
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
       the message is intact.~~
2.4. Verify: `flutter analyze`; the preview tests; `flutter test test/output_view_test.dart
     test/output_log_test.dart test/output_log_stream_test.dart test/git_service_test.dart
     test/commit_preview_output_test.dart` (the last is new, D2). Commit.

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
4.3. **Decide from the numbers**, and record the decision as ~~MADR Amendment 0068.1~~ ~~0068.2~~ ~~0068.3~~ **the MADR's next free amendment number when this phase runs** (D1–D3 each took one; it is no longer pre-numbered) either way:
     * if the spinner's presence costs less than ~5% of a core, the answer is "no change", and
       the report's Finding 2 is closed as measured-and-acceptable;
     * if it costs materially more, option B2 (an elapsed-seconds line in place of the spinner,
       following `_ReconnectingOverlay`'s pattern at `app_shell.dart:107-130`) becomes a
       follow-up phase — **written and approved separately**, not smuggled in here.
4.4. Commit the amendment and this plan's record of the measurement.

### Phase 4a — Signal once; clean up under any signal (D4)

Added by D4 (2026-09-23). The negative rehearsal came first, in the scratch clone at `d8a3b2f`,
and is recorded in the execution record.

4a.1. **`local_command_executor.dart`.**
      * `_killEscalate` stops each process at most once: a file-level
        `Expando<bool>` marks a process when its TERM is sent, and a marked process returns at once.
        The docstring states the contract (TERM, then KILL after the grace, once) and why a second
        TERM is harmful.
      * `_run`'s `catch (_)` calls `_killEscalate(process)`; the `finally { process?.kill(); }` is
        removed, and the comments that described it are rewritten.
4a.2. **`ssh_command_executor.dart`.** The comment in `_run`'s `catch (_)` that cites "the local
      executor's `finally { process?.kill(); }`" is corrected to what the local path now does. No
      code changes.
4a.3. **`git_service.dart`, `kCommitMessagePreviewScript`.** Each of the EXIT, TERM and INT traps
      begins with `trap '' TERM INT;`. The doc comment gains one sentence saying why.
4a.4. **Tests.**
      * `test/local_command_executor_test.dart`:
        - a timed-out command receives exactly one TERM;
        - a command that overflows the output cap and ignores TERM is killed;
        - cancelling a stream twice signals its process once.
      * `test/commit_message_preview_test.dart`: a second TERM during cleanup does not cut the
        cleanup short (`perl` sends TERM, 50 µs, TERM; ten runs).
4a.5. **Verify.** `flutter analyze`; `dart format --set-exit-if-changed` on the touched files; the
      two test files; the full suite; and the hardened script, extracted from the Dart source, under
      `/bin/sh` (bash 3.2) and `/bin/dash` in the scratch harness. Commit.

### Phase 5 — Device gate and records

5.1. `./build_macos.sh --unsigned` (and `--install` only if the maintainer asks). Record the exit
     code.
5.2. **Maintainer checks**, each recorded PASS/FAIL with what was seen:
     | Item | Steps | PASS when |
     |---|---|---|
     | Preview cleanup | Stage a change; start a commit; cancel or let the hook stall past the timeout. Then inspect the repository's git dir. | No `MAGICGIT_MSG_PREVIEW.*` remains. |
     | Wait legibility | Repeat with a hook that prints to stderr. | The Output view carries the hook's lines while the wait is on. |
     | Back bar | At a compact width, open any list's detail. | The "‹ …" control sits at the left edge of its bar, not centred. |
     | The four other buttons that move (D3) — **widened by D5 to every surface Amendment 0068.7 lists** | Look at each: the connection form's button (Connections → add/edit), the Forge create sheet's, a Forge list error's retry, and the switcher's edit-entry sheet's. | Each sits at the left of its row, as its code asks, and looks right there. |
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
| **(D4)** Signal once | `flutter test test/local_command_executor_test.dart` | green; the three new cases seen to fail at `d8a3b2f` |
| **(D4)** Cleanup under a second TERM | `flutter test test/commit_message_preview_test.dart` | green; the new case seen to fail at `d8a3b2f` |

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
* AC8 — The spinner's cost is measured against a control and recorded as ~~Amendment 0068.1~~ ~~0068.2~~ ~~0068.3~~ the MADR's next free amendment, with
  either "no change" or a named follow-up.
* AC9 — Phase 5's ~~four~~ five (D3) device rows are recorded, including the dropped-first-click observation as
  PASS, FAIL-with-new-record, or explicitly not-run.
* AC10 **(D4)** — A timed-out local command receives exactly one TERM, then a KILL; a stream
  cancelled twice is signalled once.
* AC11 **(D4)** — A local command abandoned for any reason — the drain-failure path included — is
  killed even if it ignores TERM.
* AC12 **(D4)** — The preview's cleanup completes when a second TERM arrives during it.
* AC13 **(D4)** — Each of AC10–AC12's tests was seen to fail on the unmodified tree, with its
  message in the execution record.

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
* **Phase 0 (2026-09-22).** Scratch clone of `dbd6d1b`; both new tests copied in; the one change
  the preview test needs to compile — today's script lifted, text unchanged, from
  `generateCommitMessage` into a top-level `kCommitMessagePreviewScript` — made in the clone only.
  * **A rehearsal error, caught and redone.** The first run's lift took the **first**
    `const script =` in `git_service.dart`, which belongs to the commit-template reader, not the
    preview; its "unchanged text" check only looked at the declaration's shape. The test
    therefore ran a script that never invokes a hook, and failed on `HOOK_PID never appeared` —
    a harness failure, not the defect, and not evidence. Traced with `sh -x`, the lift was
    re-anchored on the preview method and now asserts the lifted text contains
    `MAGICGIT_MSG_PREVIEW`; the lifted script was confirmed to return a fast hook's message.
  * **Second run — the real negative:**
    * `a preview killed like a timed-out command leaves no scratch file and no running hook` —
      **fails**: `Actual: ['MAGICGIT_MSG_PREVIEW.4ROqZo']` / "the killed preview must remove its
      scratch file". The test stops at that first expectation, so its orphaned-hook assertion was
      not reached on the unmodified tree; the orphan is evidenced by D1's probe, and by this
      case passing after Phase 1.
    * `a leftover older than a day is swept` — **fails**: `Expected: false` / `Actual: <true>` /
      "what a SIGKILL left behind is collected by the next preview".
    * `a preview that completes …` and `a fresh leftover … is not swept` — **pass**, as they
      must: both describe behaviour the shipped script already has.
    * `the compact back bar keeps its capsule at the left edge` — **fails**: `Expected: a value
      less than or equal to <20>` / `Actual: <256.04999923706055>`.
    * `a bare inline button in a wide left-aligned slot stays left` — **fails**: `Expected: a
      value less than or equal to <1>` / `Actual: <158.25>`.
  * Also measured before Phase 1: step 1.1's `-mtime +0` selects only a 25-hour-old file, never a
    fresh or 23-hour-old one, on **both** macOS `find` and the remote host's GNU `find` — BSD and
    GNU round ages differently, so this was checked rather than assumed. The step stands as
    written.
  * AC1 met. The two test files stay uncommitted until the phase that makes each pass.
* **Phase 1 (2026-09-22).** As corrected by D1: the preview script is now the top-level
  `@visibleForTesting const kCommitMessagePreviewScript` (house style: `package:flutter/foundation.dart
  show visibleForTesting`), with the sweep (`-mtime +0`), `pid=`, an EXIT trap that stops the hook
  and removes the scratch file, `exit 143`/`exit 130` traps for TERM/INT, and the hook run as
  `… & pid=$!; wait "$pid"; pid=;`. The trailing `rm` is gone; the doc comment carries both
  reasons (the kill sequence, and `sh` deferring a trap while a foreground child runs).
  * `flutter test test/commit_message_preview_test.dart test/git_service_test.dart`: `00:02 +53:
    All tests passed!`, 0 `[E]` — the killed-preview case now passes **both** assertions,
    including the orphaned-hook one the unmodified tree never reached. `flutter analyze`: `No
    issues found! (ran in 5.7s)`. `dart format`: the test file reflowed, no content change.
  * **The remote host too, since its `/bin/sh` is bash and `wait` semantics differ by shell.**
    A Python probe sent over `ssh … python3 -` runs the script under that host's `/bin/sh`
    (`/usr/bin/bash`, git 2.48.1), killed the executors' way. The script it sends is extracted from
    the Dart source and **checked byte for byte against the value Dart itself evaluates** (a first
    extraction read apostrophes inside a `//` comment as quotes and sent a corrupted script, so
    the check exists for a reason). Results:
    * shipped (new) script — `killed: leftovers=[] hook_orphaned=False`; `completes: exit=0
      stdout='a generated message' stale_swept=True fresh_kept=True`;
    * **seen to fail:** the pre-0068 script taken from `HEAD` — `killed:
      leftovers=['MAGICGIT_MSG_PREVIEW.YK5weS'] hook_orphaned=True`; `stale_swept=False`.
  * AC2 and AC3 met.
* **D2 (2026-09-22, deviation, before Phase 2): steps 2.1–2.3 would have been silent during a stall.**
  * **Evidence.** `CommandOutputCallback` is `void Function(String chunk, {required bool stderr})`, delivered live by both executors; fetch/push/clone already stream it into an `OutputStreamSession` (`branches_view.dart:1688-1712`, `clone_controller.dart:263`). The plan's route captured the hook's stderr to `"$tmp.err"` and emitted it after the `sed` — so it would appear only once the hook finished, never during a stall, and the Phase 1 trap would delete it when the preview is killed. It also re-created a stream split the transport already provides, with a NUL escape, a parser and a marker-collision case.
  * **Resolutions offered:** (1) use the existing split — the hook's stderr to the script's stderr, `onOutput` on `generateCommitMessage`, a stream session in the composer; (2) keep the plan as written.
  * **Decision (maintainer, 2026-09-22): option 1.** Steps 2.1–2.3 are struck through and replaced by 2.1′–2.3′ above; MADR Amendment 0068.2 records the mechanism; the spinner's amendment becomes 0068.3. Two details decided while reading the code: the session opens on the **first chunk**, so no hook or a quiet hook logs nothing; and the log notifier is read before any `await`, since the composer can close mid-wait and `ref` after an `await` is a known trap here.
  * **Files added to scope:** `lib/features/repository/commit_composer_controller.dart`, `test/commit_preview_output_test.dart`.
* **Phase 2 (2026-09-22), as replaced by D2.**
  * **Script half, seen to fail first.** A new case in `commit_message_preview_test.dart` — a hook
    that writes two stderr lines, one stdout line and a message — failed on the Phase 1 script with
    `Expected: contains 'generating via stub (model-x)...'` / `Actual: ''`: the hook's stderr was
    discarded. After the change (`>/dev/null 2>&1` → `>/dev/null`, so stderr inherits the
    script's), `sh`'s stdout is exactly `a generated message\n`, its stderr carries both lines, and
    the hook's own stdout appears in neither. All five preview cases pass, the killed-preview one
    included — the inherited stderr does not disturb the cleanup.
  * **Wiring half.** `generateCommitMessage(repoPath, {CommandOutputCallback? onOutput})` passes
    the callback to `execute`. `previewCommitMessageWithOutput(git, log, repoPath)` in
    `commit_composer_controller.dart` streams `stderr: true` chunks into an `OutputStreamSession`
    opened on the first chunk (header `$ prepare-commit-msg (message preview)`), closes it with 0 on
    success or the `GitException`'s exit code, `fail()`s it on anything else, and ignores stdout;
    the provider reads the log notifier before calling it. `test/commit_preview_output_test.dart`
    (new, four cases): stderr reaches the log under one header and stdout does not; a silent
    preview adds no line; stdout alone opens no session; a failure closes with `✗ exited with code
    7` and rethrows.
  * **Seen to fail, by mutation** in the scratch clone, one at a time: session opened eagerly →
    caught by "a preview that says nothing adds nothing to the log"; stdout forwarded too → caught
    by "…; stdout does not"; a failure reported as exit 0 → caught by "a failing hook closes the
    session with its exit code and rethrows". 3 of 3; the unmutated baseline passes.
  * **A mechanical consequence:** three test fakes override `generateCommitMessage` —
    `commit_dialog_test.dart` (two) and `keyboard_shortcuts_test.dart` (one) — and took the new
    signature. Bodies unchanged; both files already imported the executor module. **Files added to
    scope:** those two.
  * `flutter analyze`: `No issues found! (ran in 5.1s)`. `dart format --set-exit-if-changed` on the
    six touched files: `0 changed`. `flutter test` on the preview, wiring, output-view,
    output-log, output-log-stream, git-service, commit-dialog and keyboard-shortcut files: `00:04
    +124: All tests passed!`, 0 `[E]`.
  * AC4 met — its "marker text in stderr" clause no longer applies: there is no marker (D2).
* **D3 (2026-09-22, deviation, Phase 3): the button fix moves four more buttons than the
  MADR said.**
  * **Evidence.** A scratch script classified all 61 `InlineActionButton` call sites: 53 are
    list elements (already content-sized, unaffected); 8 sit in single-child slots. Reading each
    one's parent: two receive a tight width (`async_views.dart:105`, `image_diff_view.dart:204`)
    and render as before; one is a `Column` inside a `Center`
    (`repository_workspace_scaffold.dart:116`) and looks the same; the back bar moves left as
    intended; and **four move from centred to left** — `connection_form.dart:370`,
    `forge_create_sheet_widgets.dart:284` and `edit_entry_sheets.dart:203` (each an
    `Align(centerLeft)`) and `forge_widgets.dart:231` (a `Column` with `crossAxisAlignment:
    start`). In every one the parent asks for exactly the new position. None of the 48 goldens
    renders those surfaces, which is why no golden moved and step 3.3's stop condition never
    fired. MADR §C implied the back bar was the only visible change.
  * **Resolutions offered:** (1) accept all four — they now obey their code; (2) make any that
    should stay centred say `center` explicitly.
  * **Decision (maintainer, 2026-09-22): option 1.** MADR Amendment 0068.3 lists all eight
    single-slot callers and their effect; Phase 5's checklist names the four so each is seen.
    The spinner's amendment is no longer pre-numbered — it takes the next free number when
    Phase 4 runs (D1–D3 each consumed one).
* **Phase 3 (2026-09-22).** `inline_action_button.dart`: the `Center` inside the minimum-target
  `ConstrainedBox` gains `widthFactor: 1`, with a comment saying why (it centres vertically only;
  without the factor it filled the width and overrode the parent's alignment).
  * **Seen to fail first** (Phase 0, unmodified tree): the back-bar case at `Actual:
    <256.04999923706055>` against `<= 20`, the bare-button case at `Actual: <158.25>` against
    `<= 1`. Both pass now.
  * Guards: `flutter test` on the inline-button canon, compact navigation, the 48 workspace goldens
    and workspace accessibility — `00:05 +87: All tests passed!`, 0 `[E]`, **0 golden files
    changed**, so step 3.3's stop condition did not fire. The visible changes it could not see are
    D3's.
  * `flutter analyze`: `No issues found! (ran in 4.9s)`. Full suite (AC7): `02:46 +4338 ~3: All
    tests passed!`.
  * AC5, AC6 and AC7 met for this phase. The four surfaces D3 found are Phase 5's to see on the
    device.
* **Phase 4 (2026-09-23).** Release probe build of `9626e67` (the 0064 probe, its automatic dump
  disabled so it cannot add cost), in a scratch clone; the 0063 scratch fixture with its hooks path
  pinned to `.git/hooks` (it had inherited the machine's global AI hook) and a hook that only
  sleeps. Opened with *Save repository* off, so the maintainer's saved connections are unchanged.
  * Results and decision: MADR Amendment 0068.4 — spinner 69.7% at a constant 120 fps against 0.0%
    idle; B2 becomes a separately approved follow-up. A focused message field measured 62.1%
    (macos_ui's animated caret), recorded as a finding for the maintainer to scope.
  * A measurement error, caught: the first spinner reading (69.5%) straddled the preview's
    timeout, so part of it was the focused field; it was retaken inside the timeout (69.7%), and
    the field measured on its own.
  * AC8 met.
* **D4 (2026-09-23, deviation, Phase 4): the Phase 1 cleanup does not hold in the running app.**
  * **Evidence.** MADR Amendment 0068.5: three of four in-app timed-out previews left their
    scratch file (`MAGICGIT_MSG_PREVIEW.*`, created by the new script — the command line in the
    process table is the shipped one), and one left the hook's shell running under launchd; the
    same script, killed the executor's way from a harness, cleaned up in 5 of 5 variants.
    `commit_message_preview_test.dart` starts `sh` itself rather than going through
    `LocalCommandExecutor`, which is why it passes. AC2's device half fails.
  * **Resolutions offered:** (1) diagnose in the app first — a scratch probe build that traces the
    preview shell and the signals it receives — then a root-cause fix and a test through the real
    executor; (2) fold it into 0069's process-group change.
  * **Decision (maintainer, 2026-09-23): option 1.** The fix, once the cause is known, comes back
    as its own proposal before any code changes; this plan stays `in-progress`.
* **D4 resolved (2026-09-23).** Diagnosed as planned: a scratch probe build with the preview
  script traced, run by the app, then reproduced outside it. Cause and design: MADR Amendment
  0068.6 — the local executor sent two TERMs, microseconds apart.
  * **Resolutions offered:** (1) the executor signals once *and* the script's traps ignore further
    signals; (2) the executor only; (3) the script only.
  * **Decision (maintainer, 2026-09-23): option 1**, "hardened, idiomatic and robust". Reading every
    local signal site added two more defects of the same kind to the fix: the drain-failure path
    sent TERM with no KILL, and a second stream `cancel()` signalled again. Phase 4a is added above;
    AC10–AC13 are added.
  * **Files added to scope:** `lib/core/exec/local_command_executor.dart`,
    `lib/core/ssh/ssh_command_executor.dart` (one comment), `test/local_command_executor_test.dart`.
  * **Negative rehearsal** (scratch clone at `d8a3b2f`, tests added, source unchanged):
    * `a timed-out command receives exactly one TERM` — fails, `Actual: ['TERM', 'TERM']`, 3 of 3
      runs;
    * `a command that overflows the output cap and ignores TERM is killed` — fails, "pid … is still
      running", 2 of 2. Its first draft wrote with `yes`, and **passed on the old code**: a writer
      dies of SIGPIPE once the executor stops reading, whatever it is sent. Rewritten to stop
      writing and `exec sleep`;
    * `cancelling a stream twice signals its process once` — fails, `Actual: ['TERM', 'TERM']`, 3
      of 3;
    * `a second TERM during cleanup does not cut the cleanup short` — fails, `Actual:
      ['MAGICGIT_MSG_PREVIEW.…']`, 3 of 3, in the first or second of its ten runs.
    * **Dropped, because they could not be made to fail:** the same preview test run through the
      executor (passed 3 of 3 on the old code; the race does not land in a test run), two TERMs
      sent back to back from Dart (they merge), a hook that signals its parent back when stopped
      (the old cleanup finishes first), and TERM followed by INT (bash takes them in turn).
* **Phase 4a (2026-09-23).** As planned in 4a.1–4a.4:
  * `local_command_executor.dart`: `_killEscalate` stops a process at most once (a file-level
    `Expando<bool>`); the drain-failure path calls it; the signalling `finally` is gone, with a
    comment where it was saying why. The docstring's claim about the delayed KILL was narrowed while
    writing: `dart:io` skips a process whose exit it has observed, which makes the KILL a no-op for
    one that ended on the TERM; it is not a guarantee about reused pids, and the comment no longer
    says it is.
  * `ssh_command_executor.dart`: the one comment corrected. `git_service.dart`: each trap starts
    with `trap "" TERM INT;`, and the doc comment says why.
  * `flutter analyze`: `No issues found! (ran in 6.0s)`. `dart format` reflowed the preview test
    only. The two test files: `00:12 +27: All tests passed!`. The new cases, five more times each:
    0 `[E]`. Full suite: `03:17 +4342 ~3: All tests passed!`, 0 `[E]`.
  * **The script as shipped, in three shells.** The script Dart evaluates was written out by a
    scratch test and run through the harness, a second TERM 50 µs and 100 µs after the first, ten
    trials each, beside the pre-fix script taken from the app's process table:

    | Shell | Pre-fix: file left / hook left running | Shipped: file left / hook left running |
    |---|---|---|
    | `/bin/sh` (bash 3.2) | 12/20 / 2/20 | 0/20 / 0/20 |
    | `/bin/dash` | 11/20 / 0/20 | 0/20 / 0/20 |
    | Homebrew bash 5 | 16/20 / 6/20 | 0/20 / 0/20 |

    With one TERM, all six rows are clean. The remote host was not re-probed.
  * AC10–AC13 met. The device check of preview cleanup stays in Phase 5.
* **Phase 5, first pass (2026-09-25).** `./build_macos.sh --unsigned` exited 0, and the build
  (1.9.4.11, from `73b6257`) was installed at the maintainer's request with the script's printed
  steps, after the running copy was quit and its confirmation accepted. The app was driven with
  `cliclick` and window captures. The fixture was a scratch repository with its hooks path pinned
  to `.git/hooks`, a staged change, and a `prepare-commit-msg` hook that writes two stderr lines
  and then sleeps 600 s. It was opened with *Save repository* off. The commit timeout was set to
  60 s for the gate and put back to 300 s afterwards.

  | Item | Result | Evidence |
  |---|---|---|
  | Preview cleanup | **PASS** | Two previews timed out at 60 s. After each, the git dir held no `MAGICGIT_MSG_PREVIEW.*` file and the hook's shell had stopped. The hook's own `sleep` child was reparented to launchd both times, which is 0069-REPORT's finding and not this plan's. |
  | Wait legibility | **PASS** | While the spinner ran, the Output view showed `$ prepare-commit-msg (message preview)` and both stderr lines. On timeout the composer said "Could not generate a message. Enter one manually." |
  | Back bar | **PASS** | At 640 pt (the window's minimum), History → a commit: "‹ Commits" sits at x ≈ 8–93, at the bar's left. |
  | The buttons that move | not yet run | Widened by D5, below. |
  | Dropped first click | not yet run | The maintainer's check, with a real mouse. |

  **Found at the gate, not fixed here.** Both predate this plan:
  * At the compact width, the sidebar is painted underneath the content and does not take clicks.
    It follows the live selection, so it is not a stale frame, and a screen capture shows the same
    thing as a window capture. It reproduces on a build of `dbd6d1b`, which predates 0068. The
    maintainer chose a new record: diagnose first, then a MADR and plan.
  * A timed-out preview on a **local** repository reports "Timed out waiting for the remote
    command to finish.", and the Output view says "SSH command timed out: …". The text comes from
    `SSHCommandTimeout.toString` (`ssh_command_executor.dart:70`) and `ssh_error_messages.dart:66`,
    and dates from `2d8a357`.
* **D5 (2026-09-25, deviation, Phase 5): D3's inventory missed every button inside a `Wrap`.**
  * **Evidence.** A `Wrap` gives each child a bounded maximum width. Before Phase 3, a button's
    `Center` filled that width, so it took the whole run and its capsule sat in the middle. Now
    the button is content-sized, and the `Wrap` positions it. D3 counted 53 call sites as "list
    elements, whose width was already content-sized", which holds for a `Row` but not for a
    `Wrap`. Seen on the device, the same fixture in a build of `dbd6d1b` and in this build:
    * "Review all visible" (`repo_change_navigator.dart:166`, `WrapAlignment.end`) moved from
      centred (x ≈ 260–380 at 640 pt) to the right (x ≈ 512–630);
    * the branch detail's "Check out" moved from a centred line of its own onto the row beside
      "Advanced", and the tabs below it moved up about 28 pt.

    A scratch scan finds at least 10 call sites directly in a `Wrap`: `branches_view.dart:751-766`
    (4), `activity_center.dart:341-353` (3), `multi_file_review.dart:253` and
    `repo_change_navigator.dart:172-177` (2). A button nested one wrapper deeper was not counted.
    None of the 48 goldens renders them. Amendment 0068.3's claim that 8 single-slot callers are
    the only ones affected is wrong.
  * **Resolutions offered:**
    1. measure the effect per parent kind in a widget test, list every affected call site in a new
       amendment, and put each on Phase 5's checklist, keeping positions that obey their code;
    2. the same, and give an explicit alignment to any surface that looks wrong in its new
       position.
  * **Decision (maintainer, 2026-09-25): option 1.** The test lays out the button in each kind of
    parent, next to a reference that fills its width the way the old `Center` did, and records
    which kinds change position. A scan then classifies every call site by its nearest
    layout-deciding parent. MADR Amendment 0068.7 lists the result, and each listed surface joins
    Phase 5.2's row.
  * **Files added to scope:** none. `test/inline_button_alignment_test.dart` (Phase 3) gains the
    cases, and the MADR gains the amendment.
  * **Executed (2026-09-25).**
    * `inline_button_alignment_test.dart`: "the parents in which the capsule moves are exactly
      these" lays the button out in ten kinds of parent, beside a reference with the old bare
      `Center`, and asserts that exactly `Wrap` (start), `Wrap` (end), `Column(start)` and
      `Align(centerLeft)` move it. `+3: All tests passed!`.
    * **Seen to fail:** with `widthFactor: 1` removed in a scratch worktree, the harness reported
      it KILLED (with both Phase 3 cases). Run on its own there, it failed with `Expected:
      Set:['Wrap (start)', 'Wrap (end)', 'Column (start)', 'Align (centerLeft)']` / `Actual:
      Set:[]`. The reference is faithful to the old shape. The first rerun in the kept worktree
      passed because the harness had already restored the file, so the mutation was re-applied
      with an asserted replacement before the failing run.
    * **The scan:** all 61 call sites classified, with each `Column` and `Wrap` site read back for
      its own alignment argument. 21 sites move, one of them the `_detailButton` helper that 8
      callers use. 40 do not. Amendment 0068.7 lists them, and 0068.3 carries a note that points
      to it.
    * The device check of the listed surfaces is Phase 5.2's widened row, still to run.
