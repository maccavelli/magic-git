---
status: "in-progress"
date: 2026-09-21
associated-madr: "0064-MADR-workspace-reachability-feedback-and-log-fidelity.md"
verified: 2026-09-21  # every "proven at planning time" row below was run on this date
---

# Implement: workspace reachability, drop feedback, Output scope, CI log fidelity and suite stability

Associated MADR:
[0064-MADR-workspace-reachability-feedback-and-log-fidelity.md](0064-MADR-workspace-reachability-feedback-and-log-fidelity.md)

## Goal

Land the MADR's six fixes, each as one reviewable commit, in this order:

1. F5, the SSH cipher;
2. F6, the coalescer test;
3. F4, CI log text;
4. F3, the Output view;
5. F1, compact navigation;
6. F2, drag feedback.

Then confirm them on the device and record the results in a GATES record.

**Why the two flake fixes go first.** Every later phase is gated on a full suite that exits 0,
and the two flaky tests failed under load on the untouched tree.

* F5 goes first because its flake is the frequent one. The bulk-transfer test takes 86–99 s of a
  120 s limit on an idle machine, and fails whenever the machine is busy.
* F6's flake is rare: one failure seen across more than ten full-suite runs.

**How this plan is deterministic.** Every file a phase adds, and every change a phase makes, is
embedded verbatim in Appendix A with its SHA-256:

* the test files;
* each reference implementation, as a unified diff (plus one new source file);
* the tools.

Each was built in a scratch clone of `21d32bc` and proven there, alone and then stacked in this
order with the full suite after every phase. An executor applies them and checks the gates. They
do not re-derive or re-type anything.

## Scope

| Phase | Files changed (from the embedded patch) | Files added |
|---|---|---|
| 1 (F5) | `lib/core/ssh/ssh_client_manager.dart`; an amendment appended to the 0013 MADR (step 1.4) | `test/ssh_cipher_negotiation_live_test.dart` |
| 2 (F6) | `test/coalescer_test.dart` (one test rewritten; see AC3) | — |
| 3 (F4) | `lib/core/github/gh_service.dart` | `lib/core/forge/ci_log_text.dart`, `test/ci_log_text_test.dart`, `test/gh_job_log_sanitize_wiring_test.dart` |
| 4 (F3) | `lib/features/app_shell.dart`, `lib/features/common/repository_context_bar.dart`, `lib/features/repository/repo_status_view.dart`, `lib/features/window/secondary_window_main.dart`, `macos/Runner/help_book.json`, `test/output_view_test.dart` (import path only); **renames** `lib/features/repository/output_view.dart` → `lib/features/common/output_view.dart` | `test/output_view_placement_test.dart` |
| 5 (F1) | `lib/features/branches/branch_navigator.dart`, `lib/features/branches/branches_view.dart`, `lib/features/common/adaptive_workspace_layout.dart`, `lib/features/common/repository_workspace_scaffold.dart`, `lib/features/forge/forge_workspace.dart`, `lib/features/github/github_panel.dart`, `lib/features/gitlab/gitlab_panel.dart`, `lib/features/history/history_view.dart`, `lib/features/stash/stash_view.dart`, `lib/features/worktrees/worktrees_view.dart` | `test/compact_workspace_navigation_test.dart` |
| 6 (F2) | `lib/features/branches/branch_navigator.dart`, `lib/features/dnd/drag_cell.dart`, `lib/features/dnd/drag_item.dart`, `lib/features/dnd/drag_state.dart`, `lib/features/dnd/drop_zone.dart`, `lib/features/dnd/nav_rail.dart`, `lib/features/dnd/staging_drop_banner.dart`, `lib/features/history/history_view.dart` | `lib/features/dnd/drag_hover_scope.dart` (inside the patch), `test/drag_hover_feedback_test.dart`, `test/drag_target_hover_scan_test.dart`, `test/drag_hover_unmount_test.dart` |
| 7 (records) | the MADR, this plan, `docs/README.md` | `reports/0064-GATES-workspace-defects-on-device.md` (under `docs/`; it doesn't exist until Phase 7) |

**Existing test files changed: exactly two.**

* `test/coalescer_test.dart`. One test is rewritten to count timers on simulated time instead of
  timing a loop. It is strictly stronger: see AC3 and P16.
* `test/output_view_test.dart`. One import line changes, because the file it imports moves.

No other existing test file changes. In particular, all of these stay as they are:

* `adaptive_workspace_layout_test.dart`;
* `workspace_golden_test.dart` (no golden changes);
* `repository_chrome_contract_test.dart`;
* `drag_cell_test.dart`, `dnd_hardening_test.dart` and `history_mouse_drag_test.dart`;
* `ssh_live_transport_test.dart`;
* every `branches_*` test.

**Out of scope:** everything in the MADR's §"Out of scope".

## Conventions for executing this plan

1. **Variables.**
   * `REPO` is the repository root.
   * `S` is a scratch directory outside the repository, created in step 0.1 and reused throughout.
   * `APP` is `"$REPO/build/macos/Build/Products/Release/Magic Git.app"`.
2. **Exit status is captured, never piped away.** Every deciding command runs as
   `CMD > "$S/<name>.log" 2>&1; echo "exit=$?"`, and its log is read in full before concluding.
3. **Expected results are exact.** A mismatch is a deviation: stop, record it with its evidence,
   and prompt the maintainer with fixes. The global *Plan deviations* rule applies.
   * **Never edit an embedded test to make it pass.** Each phase checks the test hashes before it
     commits.
   * **The only tolerated failure** is the coalescer test in Phase 1's gate, under the conditions
     step 1.5 states. From Phase 2 on, any failing test is a deviation.
4. **Tools come from Appendix A**, extracted by A.1 and verified by hash (step 0.2).
5. **Every phase starts clean and stages its patch.**
   * `git status --porcelain` is empty at the start of each phase, because the previous phase
     committed.
   * Every patch is applied with `git apply --index`. That flag refuses a file whose index
     differs from the working tree, which the first rehearsal hit (execution record P-2).
6. **Commits.** One commit per phase, made with `git commit --no-edit`; read the message back with
   `git log -1 --format=%B`. Never push.

## Facts proven at planning time (2026-09-21)

All of these runs used scratch clones of `21d32bc`, never this tree.

| # | Assertion | Evidence |
|---|---|---|
| P1 | All 46 `file:line` citations in the MADR's F1–F4 context point at what they claim | A citation checker read each range: `46/46 verified` |
| P2 | **F4 red:** the unit tests fail on every strip case against an identity stub, and the wiring tests fail until `runJobLog` calls the sanitizer | 9 pass, 16 fail with the stub. With the sanitizer but no wiring, the 23 unit tests pass and both wiring tests fail, e.g. `Found 1 widget with text containing ^[` |
| P3 | **F4 green** | `+25`; full suite `+4254 ~3: All tests passed!` |
| P4 | **F3 red:** the placement test fails on the five pages without an Output view, and passes on Repository | exit 1, `+2 -6`, each failure `Found 0 widgets with type "OutputView"` |
| P5 | **F3 green**; goldens unchanged | `+8`; full suite `+4237 ~3`; 0 `[E]` across 48 golden cases |
| P6 | **F1 red:** the compact tests fail for the stated reason, and the 7 controls at 1000 px pass | `+7 -24` (route-scope focus, `navigator must be shown again`, back-bar key not found, `Found 0 widgets with type "PanelShortcuts"`, Worktrees' list absent) |
| P7 | **F1 green**; the chrome-contract invariant intact | `+31`; `repository_chrome_contract_test` `+10`; full suite `+4260 ~3` |
| P8 | **F2 red** (stub): the geometry and border checks fail, and the full-image and Esc checks pass. The scan fails on the missing reports, and the unmount test fails when nothing clears the hover | e.g. `ghost … covers the pointer Offset(120.0, 56.0)`; `no setOverTarget(true)` ×4; `Actual: <226.6…>` |
| P9 | **F2 negative controls** | a fifth target → `Which: larger than expected`; no ownership → `A's disposal must not clear B's live hover` |
| P10 | **F2 green** | `+13`; full suite `+4242 ~3` |
| P11 | **F5 root cause:** dartssh2's default AES-GCM runs pure-Dart GHASH at 1.16 MiB/s, against 29.9 MiB/s for ChaCha20 | Cipher sweep over 16 MiB each; a probe of the 100 MiB test at a flat 1.16 MiB/s with 0 monitor kills; timer gaps of 18.7 s idle and 91 s loaded |
| P12 | **F5 red:** the negotiated-cipher test fails on today's tree | `Actual: ['aes256-gcm@openssh.com' ×6]` (3 clients × 2 directions); the empty-log guard also failed on demand (`Expected ≥ <6>, Actual <0>`) |
| P13 | **F5 green:** bulk transfer in seconds | Negotiated-cipher test passes; bulk test 3.0–5.7 s across 3 isolated runs and 4 full suites, where it took 86–99 s before |
| P14 | **F5 reproduction** on the unmodified tree | At background priority the bulk test exits 1 with a timeout; with the fix, the same priority gives exit 0 in 13 s |
| P15 | **F6 root cause:** the old test times a loop against a 50 ms wall-clock budget | Under 40 busy processes the old test failed 5 of 8 runs (`Actual` 50–291); the new test passed 8 of 8 |
| P16 | **F6 is stricter:** the new test catches what the old one targeted, plus lateness | Guard removed → `Expected: <3> Actual: <20000>`; fire 1 ms late → `Expected: [0:00:00.166002] Actual: [0:00:00.167002]` |
| P17 | ⌘[ is unbound; the `onBack:` ban exists; Flutter calls `onMove` on rejecting targets; an unmounted target gets no `onLeave`; a synchronous clear during dispose throws | `grep` finds no `bracketLeft` in `lib/`; `repository_chrome_contract_test.dart:230-241`; SDK `drag_target.dart`; tested |
| P18 | **All six stacked in this order**, staging between phases, with every phase's red and green steps and a full suite after each | Execution record P-3 |

## Implementation Steps

### Phase 0: preconditions

* **0.1.** Set `REPO="$(git rev-parse --show-toplevel)"` and `S="$(mktemp -d -t mg-0064)"`.
* **0.2.** Save Appendix A.1 as `$S/extract.py`, then run
  `python3 "$S/extract.py" "$REPO/docs/decisions/0064-PLAN-workspace-reachability-feedback-and-log-fidelity.md" "$S/art"`.
  Expected: `exit=0`, and one `ok` line for each Appendix A entry.
* **0.3.** Check the SDK and dependencies:
  * `flutter --version`: the first line is
    `Flutter 3.47.2 • channel stable • https://github.com/flutter/flutter.git`;
  * `flutter pub get --enforce-lockfile`: exit 0.
* **0.4.** The hooks path ends in `/.global-git-hooks`. `git status --porcelain` is empty, with the
  records committed.
* **0.5.** Baseline: `flutter analyze` exits 0. Record the pass count of one `flutter test` run
  as `N0`. If that run fails **only** on one or both of the two known flakes, record them;
  Phases 1 and 2 fix exactly those. Any other failure is a deviation.

### Phase 1: F5, prefer ChaCha20-Poly1305

* **1.1 Red on the real tree.** Copy A.3 → `test/ssh_cipher_negotiation_live_test.dart` and run
  it. Expected: exit 1, with `Actual: ['aes256-gcm@openssh.com', …]` (six entries).
  **Rehearsed:** exit 1, `Actual:` six `'aes256-gcm@openssh.com'` entries.
* **1.2 Implement.** `git apply --index "$S/art/F5.diff"` (A.2).
* **1.3 Green.**
  * The new test: exit 0. **Rehearsed:** exit 0, `+1: All tests passed!`.
  * `flutter test test/ssh_live_transport_test.dart --plain-name "bulk transfer completes with the
    health monitor armed"`: exit 0, in seconds, not minutes. **Rehearsed:** exit 0, `00:03 +1: All tests passed!`.
* **1.4 Annotate 0013.** Append this section to the end of
  `docs/decisions/0013-MADR-prefer-dartssh2-v3-over-dartssh3.md`, with nothing else changed:

  ```markdown
  ## Amendment 0013.1 (2026-09-21): cipher order superseded by 0064

  The row "Leave algorithm defaults alone" is superseded **for the cipher order only** by
  [0064-MADR](0064-MADR-workspace-reachability-feedback-and-log-fidelity.md) §F5: the client now
  prefers `chacha20-poly1305@openssh.com`, because dartssh2's default AES-GCM runs a bit-serial
  pure-Dart GHASH at about 1.2 MiB/s. The rest of that row stands. The decision above is not
  rewritten.
  ```

  Then `dart run tool/records.dart check` exits 0.
* **1.5 Gate.**
  * Format and analyze: exit 0.
  * `flutter test`: exit 0, with the count `N0 + 1`. **Rehearsed:** exit 0, `02:50 +4230 ~3: All tests passed!`; the exception was not needed.
  * **The single tolerated exception.** The run is allowed to fail **only** on
    `test/coalescer_test.dart` "a tight burst does not rebuild the timer per event", whose fix is
    Phase 2, and only if two things hold:
    * that test passes when re-run alone;
    * every other test passed.

    Record the failing line verbatim. Any other failing test, or a coalescer failure that recurs
    when run alone, is a deviation.
* **1.6 Commit** `lib/core/ssh/ssh_client_manager.dart`,
  `test/ssh_cipher_negotiation_live_test.dart`, the 0013 MADR and this plan.

### Phase 2: F6, count timers instead of milliseconds

* **2.1 Implement.** `git apply --index "$S/art/F6.diff"` (A.4). It rewrites the one test body in
  `test/coalescer_test.dart`, and nothing in `lib/` changes.
* **2.2 Seen to fail, by mutation.** Run
  `python3 "$S/art/mutate_coalescer.py" "$REPO" "$S"` (A.5). It works on a scratch copy, removes
  the reschedule guard from `coalescer.dart` (asserting the anchor matched once), and runs the
  test there.

  Expected: exit 0, printing `unmutated: exit=0` and `mutant: exit=1 caught=yes`.
  **Rehearsed:** exit 0, `unmutated: exit=0`, `mutant: exit=1 caught=yes`.
* **2.3 Green.** `flutter test test/coalescer_test.dart`: exit 0. **Rehearsed:** exit 0, `+6: All tests passed!`.
* **2.4 Gate.**
  * Format and analyze: exit 0.
  * `flutter test`: exit 0, with the count `N0 + 1`, and **no** failure of any kind.
    **Rehearsed:** exit 0, `02:48 +4230 ~3: All tests passed!`.
* **2.5 Commit** `test/coalescer_test.dart` and this plan.

### Phase 3: F4, sanitize CI job logs

* **3.1 Red on the real tree.** Copy A.7 → `test/ci_log_text_test.dart` and A.8 →
  `test/gh_job_log_sanitize_wiring_test.dart`, then run both.

  Expected: exit 1, with `Error when reading 'lib/core/forge/ci_log_text.dart': No such file or
  directory` and `Method not found: 'sanitizeGhJobLog'`. **Rehearsed:** exit 1, `test/ci_log_text_test.dart:8:8: Error: Error when reading 'lib/core/forge/ci_log_text.dart': No such file or directory`.
* **3.2 Implement.** Copy A.6 → `lib/core/forge/ci_log_text.dart`, then
  `git apply --index "$S/art/F4.diff"` (A.9).
* **3.3 Green.** Run both files, plus `test/gh_service_test.dart` and
  `test/run_jobs_view_test.dart`. Expected: exit 0, `+112`. **Rehearsed:** exit 0, `+112: All tests passed!`.
* **3.4 Gate.** Format and analyze clean. `flutter test` exits 0 with the count `N0 + 26`.
  **Rehearsed:** exit 0, `02:47 +4255 ~3: All tests passed!`.
* **3.5 Commit** the Phase 3 paths from the Scope table, plus this plan.

### Phase 4: F3, one Output view in the shell

* **4.1 Red on the real tree.** Copy A.10 → `test/output_view_placement_test.dart`. Run a
  temporary copy whose single `features/common/output_view.dart` import is swapped to
  `features/repository/output_view.dart` (assert that exactly one line changed), then delete it.

  Expected: exit 1, `+2 -6`, every failure `Found 0 widgets with type "OutputView"`.
  **Rehearsed:** exit 1, `+2 -6: Some tests failed.`.
* **4.2 Implement.** `git apply --index "$S/art/F3.diff"` (A.11). The patch includes the rename.
* **4.3 Green.** Run the placement test and `test/output_view_test.dart`. Expected: exit 0, `+9`.
  **Rehearsed:** exit 0, `+9: All tests passed!`.
* **4.4 Gate.** Format and analyze clean. `flutter test` exits 0 with the count `N0 + 34`.
  **Rehearsed:** exit 0, `02:47 +4263 ~3: All tests passed!`.
* **4.5 Commit** the Phase 4 paths from the Scope table, plus this plan.

### Phase 5: F1, compact navigation owned by the scaffold

* **5.1 Red on the real tree.** Copy A.12 → `test/compact_workspace_navigation_test.dart` and run
  it. Expected: exit 1, `+7 -24`. The seven `control (1000 px …)` tests must pass; if they don't,
  the instrument is broken, and that is a deviation. **Rehearsed:** exit 1, `+7 -24: Some tests failed.`.
* **5.2 Implement.** `git apply --index "$S/art/F1.diff"` (A.13).
* **5.3 Green.** Run the new file and `test/repository_chrome_contract_test.dart` together.
  Expected: exit 0, `+41`. **Rehearsed:** exit 0, `+41: All tests passed!`.
* **5.4 Gate.**
  * Format and analyze clean.
  * `flutter test` exits 0 with the count `N0 + 65`. **Rehearsed:** exit 0, `02:46 +4294 ~3: All tests passed!`.
  * `grep -rn "onBack:" lib/features/history lib/features/stash lib/features/branches lib/features/worktrees lib/features/forge`
    prints nothing.
* **5.5 Commit** the Phase 5 paths from the Scope table, plus this plan.

### Phase 6: F2, a hover-aware drag image

* **6.1 Red on the real tree.** Copy A.15, A.16 and A.17 into `test/`, then run them.

  Expected: exit 1. The hover and unmount tests fail to compile with `Undefined name
  'kDragChipMaxWidth'` and `'kDragChipPointerOffset'`, and the scan reports `no setOverTarget(true)`
  for each of the four targets. **Rehearsed:** exit 1, `test/drag_hover_feedback_test.dart:234:45: Error: Undefined name 'kDragChipMaxWidth'.`.
* **6.2 Implement.** `git apply --index "$S/art/F2.diff"` (A.14). It adds
  `lib/features/dnd/drag_hover_scope.dart`.
* **6.3 Green.** Run the three new files, plus `test/drag_cell_test.dart`,
  `test/dnd_hardening_test.dart`, `test/history_mouse_drag_test.dart` and
  `test/nav_rail_test.dart`. Expected: exit 0, `+26`. **Rehearsed:** exit 0, `+26: All tests passed!`.
* **6.4 Gate.**
  * Format and analyze clean.
  * `flutter test` exits 0 with the count `N0 + 78`. **Rehearsed:** exit 0, `02:49 +4307 ~3: All tests passed!`.
  * Every test file's hash matches its Appendix A entry.
* **6.5 Commit** the Phase 6 paths from the Scope table, plus this plan.

### Phase 7: on-device confirmation and records

* **7.1 Build.** `pgrep -f 'Magic Git.app/Contents/MacOS/Magic Git'` exits 1; if it doesn't, the
  maintainer quits the app. Then:
  * `./build_macos.sh --unsigned` exits 0;
  * `git status --porcelain` is empty;
  * `PlistBuddy -c 'Print :FLTEnableImpeller'` on the bundle prints `true`.
* **7.2 Launch.** Run 0063-PLAN's launcher (its Appendix A.7) on `$APP/Contents/MacOS/Magic Git`.
  Expected: `PASS … (MetalSDF).` Then activate the app with `open "$APP"`.
* **7.3 Drive and record** with `cliclick` and Accessibility, as in 0063-GATES. Use A.18
  (`shot.py <pid> <name> "$S/shots"`) and A.19 (`png_sample.py`). Open the 0063 fixture through
  Recent Repositories. For each item, record PASS or FAIL with its capture:

  | Item | Steps | PASS when |
  |---|---|---|
  | D1 compact History | Window width 900 pt. ⌘2, click a commit row, capture. Esc, capture. Click a row, ⌘[, capture. Click a row, click "‹ Commits", capture. | The first capture shows the diff with a "‹ Commits" bar. After Esc, ⌘[ and the bar click, the list is visible and the previous row is still highlighted. |
  | D1 compact Branches and Worktrees | The same sequence with ⌘3 ("‹ Branches") and ⌘6 ("‹ Worktrees"). On Worktrees, the list is visible before any click. | As above. |
  | D2 drag hover | Width 1659 pt. On History, drag a commit row grabbed 60 pt from its left edge, and hold it over "New branch" with the pointer on the row's vertical centre. Capture the rail at full resolution and sample the right end of "New branch" and of one other eligible row. | "New branch" measures green, not blue: its green channel is at least the other row's plus 15. A green ring is visible, and a compact chip sits below and right of the pointer. |
  | D3 Output everywhere | ⌘2, then ⇧⌘O twice, capturing after each. Repeat with ⌘3. | The Output pane appears and then disappears on History, and on Branches. |
  | D4 CI log | Forge, the Dependabot Updates run, the Dependabot job. Capture the first screen of the log. | No `^[`, no `UNKNOWN STEP`, and every line begins with the timestamp. |
  | D5 SSH cipher | Only if a remote SSH connection is configured: connect, open History, and let a large log or diff load. | It loads without a UI stall. This is informational; F5's pass/fail check is the negotiated-cipher test. |
* **7.4 Records.**
  * Write `reports/0064-GATES-workspace-defects-on-device.md` under `docs/`, redacted the same way
    as 0063-GATES.
  * If every acceptance criterion holds:
    * MADR `status: "accepted"`;
    * this plan `status: "complete"`;
    * update the index rows.
  * Then run `dart run tool/records.dart check` and `flutter test test/docs_records_test.dart
    test/no_real_identifiers_scan_test.dart`. Both must exit 0.
  * Commit.

## Verification

| AC | Criterion | Evidence |
|---|---|---|
| AC1 | Each phase's new or rewritten test was seen to fail before its fix: red on the real tree for Phases 1 and 3–6, and by mutation for Phase 2 | 1.1, 2.2, 3.1, 4.1, 5.1, 6.1 |
| AC2 | Every embedded test file's hash matches Appendix A | each phase's gate |
| AC3 | Exactly two existing test files change: `coalescer_test.dart`, a strictly stronger rewrite, and `output_view_test.dart`, one import line | `git log -p` of Phases 2 and 4 |
| AC4 | After every phase: analyzer clean, format clean, full suite exit 0 with the stated count. The only tolerated failure is step 1.5's scoped one | 1.5, 2.4, 3.4, 4.4, 5.4, 6.4 |
| AC5 | No workspace golden changed | `git log --stat` shows no `test/goldens/` paths |
| AC6 | 0013-MADR carries Amendment 0013.1, and its decision text is unchanged | 1.4, and `git diff` of 0013 shows only the appended section |
| AC7 | D1–D4 PASS on the device (Impeller), and D5 is recorded | 7.3 and the GATES record |
| AC8 | The records check and the identifier scan pass, and each phase is one `--no-edit` commit; nothing pushed | 7.4 |

## Rollout and Rollback

* **Rollout.** Six independent commits. F5 changes the SSH cipher order, and every connection
  renegotiates on its next connect with no migration. F6 is test-only. F4, F3, F1 and F2 are UI
  and service-layer changes. Installing the build is the maintainer's call.
* **Rollback.** `git revert <phase commit>`, per fix, in reverse order: F2, F1, F3, F4, F6, F5.
  * F1 and F2 both touch `history_view.dart` and `branch_navigator.dart`, in different hunks, so
    revert F2 before F1.
  * Reverting F5 restores AES-GCM-first and its slow path. It also needs Amendment 0013.1
    withdrawn by a further amendment, which is a records change, not a deletion.
  * A revert is a new commit, and the maintainer approves it under the deviation rule.

## Execution record

* **Phase 0 (2026-09-21, execution).**
  * 0.1: `S=/var/folders/…/T/mg-0064.d1byV5Njmi`.
  * The records were not yet committed, so they were committed first as their own `--no-edit`
    commit. That is what 0.4's "records committed" precondition requires.
  * 0.2: extractor `exit=0`, 19 of 19 `ok`.
  * 0.3: `Flutter 3.47.2 • channel stable`; `pub get --enforce-lockfile` `exit=0`.
  * 0.4: hooks path `…/.global-git-hooks`; tree clean.
  * 0.5: `flutter analyze` `No issues found!`. `flutter test` `03:37 +4229 ~3: All tests passed!`,
    so `N0` = 4229 with no flake this run.
* **Phase 1 (2026-09-21, execution).**
  * 1.1: exit 1, `Expected: every element('chacha20-poly1305@openssh.com')` against six
    `'aes256-gcm@openssh.com'` entries.
  * 1.2: apply `exit=0`.
  * 1.3: new test `+1: All tests passed!`; bulk test `00:03 +1: All tests passed!`.
  * 1.4: Amendment 0013.1 appended verbatim (8 insertions, 0 deletions); records check 0 findings.
  * 1.5: format `exit=0`; analyze `No issues found!`; `flutter test` `02:53 +4230 ~3: All tests
    passed!` = `N0 + 1`, so the scoped exception was not needed. The test hash matches A.3
    (`683af364…`).

* **P-1 (2026-09-21, planning).** The first four patches (F4, F3, F1, F2), stacked in a fresh clone
  of `21d32bc`:
  * each `git apply --index` exited 0;
  * phase tests: `+25`, `+9`, `+41` and `+13`;
  * `flutter analyze`: `No issues found!`;
  * full suite: `03:37 +4306 ~3: All tests passed!`, with 0 `[E]`.
* **P-2 (2026-09-21, planning).** A rehearsal of the four-phase draft **without** per-phase
  commits.
  * Phase 4's `git apply --index` exited 1: `lib/features/branches/branch_navigator.dart: does not
    match index` and `lib/features/history/history_view.dart: does not match index`. F1 had been
    applied unstaged.
  * **Fix:** every phase starts clean and applies with `--index`.
  * With the index matching the working tree, F2 applied, and the suite gave
    `03:38 +4306 ~3: All tests passed!`.
* **D-scope (2026-09-21, planning, maintainer).** The maintainer asked for the two flaky tests to
  be investigated and brought into scope. They became F5 (a product defect) and F6 (a test
  defect), and land first. The MADR gained §F5 and §F6.
* **D-order (2026-09-21, planning).** A first six-phase rehearsal ran F6 first. It was stopped
  during Phase 1's full suite, while that suite was on the still-unfixed bulk-transfer test.
  * **The problem:** with F6 first, Phase 1's gate would depend on the *frequent* flake. The order
    is now F5, then F6.
  * **The one flake that can still occur before its fix** is the rare coalescer failure in
    Phase 1's gate. Step 1.5 handles it with a narrow, recorded exception, instead of pretending it
    cannot happen.
* **P-3 (2026-09-21, planning).** The six-phase rehearsal, exactly as written above, in a fresh
  clone, staging between phases: every `git apply --index` exited 0. The red steps failed as stated, and the Phase 2 mutant was caught. The green steps passed. The full suites after Phases 1–6 gave 4230, 4230, 4255, 4263, 4294 and 4307, all exit 0, which is `N0 + 1`, `+1`, `+26`, `+34`, `+65` and `+78` with `N0` = 4229. `flutter analyze` gave `No issues found!`, and `dart format --set-exit-if-changed lib test` reported `787 files (0 changed)`.

## Appendix A: artifacts (extract with A.1; never retype)

| # | File | SHA-256 |
|---|---|---|
| A.1 | `extract.py` | `09dcfccd80419f649e418c87de8ca549ab86fd7971ceaa0f3d3d08182694e0af` |
| A.2 | `F5.diff` | `c402784639df59dc8471af399d6a9370b65ba731b85753ab6fe7cde4ca1632c1` |
| A.3 | `ssh_cipher_negotiation_live_test.dart` | `683af3646cdc80f13c9de76e7a9fa9a9c1d2890c3acb6de82839589de716b23d` |
| A.4 | `F6.diff` | `7a49012494a9b2ebbffd362f94cca6c3b8a83fdb8adf92d0bdee1b36814b2f09` |
| A.5 | `mutate_coalescer.py` | `d7709773b59cae6f6f4374936c8d0b798f64a63b8e2f4dc75a98a041eb90c1d2` |
| A.6 | `ci_log_text.dart` | `17222e9ec045a8cded7d35000fd416340f5f542fb7a9aa413bb9f8d2d3647976` |
| A.7 | `ci_log_text_test.dart` | `1b790c14dd6e4d74a27a55be1984f8df73b820ea57410e087263abf718aa017c` |
| A.8 | `gh_job_log_sanitize_wiring_test.dart` | `4a548f81515e2884882e540ee888c9ea7beb721e7ace4f46db9a4a390eaa89e8` |
| A.9 | `F4.diff` | `51946d0d31da6f7d5848daa04e507d7c7c3e14d65b37c7d7177cc0a05ecb6f87` |
| A.10 | `output_view_placement_test.dart` | `25aabc8533f96285f3c0b51e768c9a1583bf7d711f38110da8bf86e693d55c34` |
| A.11 | `F3.diff` | `fc5caabecc8d6b8de1f7f62433ead5e42d7069f77557f0d3f84da398c372f6bd` |
| A.12 | `compact_workspace_navigation_test.dart` | `91124677fff42929df891080a6068a90c92fe0ed2714a61d22b64d937a4df297` |
| A.13 | `F1.diff` | `f62d50abf58bace51d2969c928f7d9beb793b3b1acb53cd0e873735c6c67b0d5` |
| A.14 | `F2.diff` | `d644fd45176a64357af4d67976c441b43a1a6fcef7a8df8dc9e6c548f7a1c6bf` |
| A.15 | `drag_hover_feedback_test.dart` | `0bc721e991073e7f851d1af191ce1c58346cf6d8e2a1be2fbdca18533e2a8a86` |
| A.16 | `drag_target_hover_scan_test.dart` | `a559af3333de4c425418c27b20720178c811cdc4e38653efad352a6e736186bd` |
| A.17 | `drag_hover_unmount_test.dart` | `bc46a73697a18102e0b980b15a971a16e460e35ac7cf4e0077373377518e7be7` |
| A.18 | `shot.py` | `458042cae202108958a0676dfd1ae2c70a931f3f9c51b27390ac3dedb95c5eee` |
| A.19 | `png_sample.py` | `ab957a14a288e7188f2d769dd52dee17e378f5db2147998c521f5809cc1895f8` |

### A.1 `extract.py`

```python
"""Extract the Appendix A tools from the 0063 PLAN and verify their SHA-256.

Usage: extract.py <plan.md> <dest-dir>

Each tool is a level-3 heading `A.<n> <name>` followed by one fenced block. The
block body plus a trailing newline is written to <dest-dir>/<name>, and its
hash must equal the one in the Appendix A table. Exits 1 on any mismatch.
"""
from __future__ import annotations

import hashlib
import re
import sys
from pathlib import Path

FENCE = "`" * 3  # spelled out so this file can itself sit inside a fenced block
BLOCK = re.compile(
    rf"^### (A\.\d+) `([^`]+)`\n\n{FENCE}\w*\n(.*?)\n{FENCE}$", re.M | re.S
)
ROW = re.compile(r"^\| (A\.\d+) \| `([^`]+)` \| `([0-9a-f]{64})` \|$", re.M)


def main() -> int:
    plan, dest = Path(sys.argv[1]), Path(sys.argv[2])
    text = plan.read_text()
    expected = {name: digest for _, name, digest in ROW.findall(text)}
    blocks = {name: body for _, name, body in BLOCK.findall(text)}
    dest.mkdir(parents=True, exist_ok=True)
    failures = 0
    for name, digest in expected.items():
        if name not in blocks:
            print(f"MISSING {name}")
            failures += 1
            continue
        data = (blocks[name] + "\n").encode()
        (dest / name).write_bytes(data)
        actual = hashlib.sha256(data).hexdigest()
        ok = actual == digest
        print(f"{'ok' if ok else 'MISMATCH'} {name} {actual}")
        failures += not ok
    if set(blocks) - set(expected):
        print(f"UNLISTED {sorted(set(blocks) - set(expected))}")
        failures += 1
    return 1 if failures or not expected else 0


if __name__ == "__main__":
    sys.exit(main())
```

The extractor. Save it by hand as `$S/extract.py` (step 0.2). It re-extracts itself, so its own hash is checked too.

### A.2 `F5.diff`

```diff
diff --git a/lib/core/ssh/ssh_client_manager.dart b/lib/core/ssh/ssh_client_manager.dart
index 6a42ee5..cae55f8 100644
--- a/lib/core/ssh/ssh_client_manager.dart
+++ b/lib/core/ssh/ssh_client_manager.dart
@@ -154,6 +154,31 @@ class SSHClientManager {
   /// client (today's dual-client behaviour).
   static const Duration _syncAuthTimeout = _streamAuthTimeout;
 
+  /// Algorithm preferences for every client this manager opens.
+  ///
+  /// dartssh2's own defaults except for the cipher order, which puts
+  /// `chacha20-poly1305@openssh.com` ahead of AES-GCM. Both are AEAD and both
+  /// are covered by strict kex; the difference is speed in pure Dart. dartssh2
+  /// runs AES-GCM on pointycastle's GCM, whose GHASH is bit-serial, and that
+  /// measured ~1.2 MiB/s against ~30 MiB/s for ChaCha20-Poly1305 on the same
+  /// machine. Decryption happens on the isolate that owns the socket, so the
+  /// slow cipher does not merely cap throughput: it keeps that isolate busy
+  /// for the whole transfer, and dart:io re-reads a socket with bytes still
+  /// available in one microtask chain, so no timer fires until it drains.
+  /// AES-GCM stays in the list for servers that do not offer ChaCha20
+  /// (FIPS-mode hosts); the rest of the order is the library's.
+  static const SSHAlgorithms _algorithms = SSHAlgorithms(
+    cipher: [
+      SSHCipherType.chacha20poly1305,
+      SSHCipherType.aes256gcm,
+      SSHCipherType.aes128gcm,
+      SSHCipherType.aes256ctr,
+      SSHCipherType.aes128ctr,
+      SSHCipherType.aes256cbc,
+      SSHCipherType.aes128cbc,
+    ],
+  );
+
   /// Command / SFTP / health-monitor client (primary).
   SSHClient? _client;
 
@@ -889,6 +914,7 @@ class SSHClientManager {
         // Only when a password exists — see comment above.
         onPasswordRequest: hasPassword ? () => password : null,
         identities: resolvedIdentities,
+        algorithms: _algorithms,
         // Dead-peer detection is owned by [ConnectionHealthMonitor]
         // (which checks whether pings are *answered*). The library's own
         // keepAliveInterval fires-and-forgets without a reply counter, and
```

Phase 1: the SSH cipher order (`git apply --index`).

### A.3 `ssh_cipher_negotiation_live_test.dart`

```dart
@Tags(['integration'])
library;

// Which packet cipher a real connect negotiates — asserted on the wire, from
// the server's own log, not from our configuration.
//
// Why it matters: dartssh2 is pure Dart and decrypts on the isolate that owns
// the socket. Its AES-GCM runs on pointycastle's GCM, whose GHASH is a
// bit-serial loop (128 shift/xor rounds per 16-byte block), and measured about
// 1.2 MiB/s on an idle M1 Pro — against about 30 MiB/s for
// chacha20-poly1305@openssh.com through the same library. dartssh2 3.1.0 made
// AES-GCM its first default, so leaving the defaults alone made every bulk
// read ~25x slower and CPU-bound. A consumer that slow is also slower than
// the socket, and dart:io keeps re-reading a socket that still has bytes
// available in a microtask chain, so for the whole transfer no timer fires —
// the health monitor's, a command timeout's, or a test's own Timeout.
//
// A timing assertion would flake; the negotiated algorithm does not. sshd
// logs it at DEBUG1 ("kex: client->server cipher: …"), so this reads that.
//
// Skips itself (rather than failing) when sshd is unavailable.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';

const _sshdPath = '/usr/sbin/sshd';
const _keygenPath = '/usr/bin/ssh-keygen';

/// A throwaway loopback sshd whose DEBUG1 log lands in [logFile].
class _LoggingSshd {
  _LoggingSshd(this._dir, this.port, this._process, this.privateKeyPem);

  final Directory _dir;
  final int port;
  final Process _process;
  final String privateKeyPem;

  File get logFile => File('${_dir.path}/sshd.log');

  static bool get available =>
      File(_sshdPath).existsSync() && File(_keygenPath).existsSync();

  static Future<_LoggingSshd?> start() async {
    final dir = Directory(
      Directory.systemTemp
          .createTempSync('sshd_cipher_')
          .resolveSymbolicLinksSync(),
    );
    final path = dir.path;
    for (final name in ['hostkey', 'id']) {
      final r = await Process.run(_keygenPath, [
        '-q',
        '-t',
        'ed25519',
        '-f',
        '$path/$name',
        '-N',
        '',
      ]);
      if (r.exitCode != 0) {
        dir.deleteSync(recursive: true);
        return null;
      }
    }
    File(
      '$path/authorized_keys',
    ).writeAsStringSync(File('$path/id.pub').readAsStringSync());
    await Process.run('/bin/chmod', ['600', '$path/authorized_keys']);

    final reserve = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = reserve.port;
    await reserve.close();

    // No Ciphers line: the server offers OpenSSH's full default set, so what
    // gets negotiated is decided by the client's preference order alone.
    File('$path/sshd_config').writeAsStringSync('''
Port $port
ListenAddress 127.0.0.1
HostKey $path/hostkey
PidFile $path/sshd.pid
AuthorizedKeysFile $path/authorized_keys
StrictModes no
UsePAM no
PasswordAuthentication no
PubkeyAuthentication yes
LogLevel DEBUG1
''');

    // -E sends the log to a file rather than stderr, so an unread stderr pipe
    // can never fill and stall sshd under DEBUG1's volume.
    final process = await Process.start(_sshdPath, [
      '-f',
      '$path/sshd_config',
      '-D',
      '-E',
      '$path/sshd.log',
    ]);
    for (var i = 0; i < 50; i++) {
      try {
        final s = await Socket.connect(
          InternetAddress.loopbackIPv4,
          port,
          timeout: const Duration(milliseconds: 200),
        );
        s.destroy();
        return _LoggingSshd(
          dir,
          port,
          process,
          File('$path/id').readAsStringSync(),
        );
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
    process.kill(ProcessSignal.sigkill);
    dir.deleteSync(recursive: true);
    return null;
  }

  SSHConnectionProfile get profile => SSHConnectionProfile(
    host: '127.0.0.1',
    port: port,
    username: Platform.environment['USER'] ?? 'runner',
    privateKey: privateKeyPem,
  );

  /// Every `kex: <direction> cipher: <name>` line sshd has logged so far.
  List<String> negotiatedCiphers() {
    final pattern = RegExp(
      r'kex: (?:client->server|server->client) cipher: (\S+)',
    );
    return [
      for (final m in pattern.allMatches(logFile.readAsStringSync()))
        m.group(1)!,
    ];
  }

  Future<void> stop() async {
    try {
      Process.killPid(_process.pid, ProcessSignal.sigterm);
    } catch (_) {}
    _process.kill(ProcessSignal.sigkill);
    await _process.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () => 0,
    );
    try {
      _dir.deleteSync(recursive: true);
    } catch (_) {}
  }
}

void main() {
  _LoggingSshd? sshd;

  setUpAll(() async {
    if (_LoggingSshd.available) sshd = await _LoggingSshd.start();
  });

  tearDownAll(() async => sshd?.stop());

  test('every client of a real connect negotiates '
      'chacha20-poly1305@openssh.com, not the bit-serial AES-GCM', () async {
    final server = sshd;
    if (server == null) return;
    final manager = SSHClientManager();
    final executor = SSHCommandExecutor(manager);
    addTearDown(manager.disconnect);
    await manager.connect(server.profile, onVerifyHostKey: (_, _) => true);

    // One round trip, so the session is demonstrably usable, not just keyed.
    final echo = await executor.execute(
      repoPath: '/',
      gitArgs: const ['echo', 'ok'],
      lane: ExecLane.read,
    );
    expect(echo.stdout.trim(), 'ok');

    final ciphers = server.negotiatedCiphers();
    // Two lines per connection (one per direction). An empty list means the
    // log did not say, which must fail loudly rather than pass vacuously.
    expect(
      ciphers.length,
      greaterThanOrEqualTo(2 * manager.attachedClientCount),
      reason:
          'sshd logged too few kex lines:\n'
          '${server.logFile.readAsStringSync()}',
    );
    expect(ciphers, everyElement('chacha20-poly1305@openssh.com'));
  }, timeout: const Timeout(Duration(seconds: 60)));
}
```

Phase 1: `test/ssh_cipher_negotiation_live_test.dart`.

### A.4 `F6.diff`

```diff
diff --git a/test/coalescer_test.dart b/test/coalescer_test.dart
index 93b0958..22c6b96 100644
--- a/test/coalescer_test.dart
+++ b/test/coalescer_test.dart
@@ -1,3 +1,5 @@
+import 'dart:async';
+
 import 'package:fake_async/fake_async.dart';
 import 'package:flutter_test/flutter_test.dart';
 import 'package:remote_magic_git/core/git/coalescer.dart';
@@ -103,30 +105,80 @@ void main() {
       // a burst, yet the timer was destroyed and rebuilt on every event:
       // measured 295 ms of the 333 ms a 20,000-event `git checkout` burst cost
       // on the UI isolate, against 9 ms once the reschedule is guarded.
-      var fires = 0;
-      final c = Coalescer(
-        trailing: const Duration(milliseconds: 150),
-        maxWait: const Duration(seconds: 1),
-        minInterval: const Duration(seconds: 1),
-        onFire: () => fires++,
-      );
-      addTearDown(c.cancel);
-
-      const n = 20000;
-      final sw = Stopwatch()..start();
-      for (var i = 0; i < n; i++) {
-        c.signal();
-      }
-      sw.stop();
-
-      // ~30x under the measured churn, ~5x over the guarded cost, so it can
-      // neither flake on a slow machine nor pass on the unguarded version.
-      expect(
-        sw.elapsedMilliseconds,
-        lessThan(50),
-        reason: 'signal() must not cancel and rebuild a Timer per event',
-      );
-      expect(fires, 0, reason: 'nothing should have fired synchronously');
+      //
+      // The property is counted, not timed: every Timer the coalescer builds
+      // goes through the zone's createTimer hook, and the burst runs on fake
+      // time, so the count depends only on the events' timestamps. A
+      // Stopwatch budget here measured the machine's load as much as the
+      // coalescer, and failed under a busy full-suite run.
+      fakeAsync((async) {
+        final base = DateTime(2026);
+        const trailing = Duration(milliseconds: 150);
+        const n = 20000;
+        const step = Duration(microseconds: 1);
+        var timersBuilt = 0;
+        final fireTimes = <Duration>[];
+
+        runZoned(
+          () {
+            final c = Coalescer(
+              trailing: trailing,
+              maxWait: const Duration(seconds: 1),
+              minInterval: const Duration(seconds: 1),
+              onFire: () => fireTimes.add(async.elapsed),
+              now: () => base.add(async.elapsed),
+            );
+            addTearDown(c.cancel);
+
+            // 20,000 events one microsecond apart: a 20 ms burst.
+            for (var i = 0; i < n; i++) {
+              c.signal();
+              if (i < n - 1) async.elapse(step);
+            }
+            final lastEvent = async.elapsed;
+
+            // Each event pushes the trailing target one step later. The timer
+            // is rebuilt only once the target has moved more than the
+            // tolerance past the scheduled one: at the first event, then
+            // every (tolerance + step) of burst.
+            final perRebuild = Coalescer.rescheduleTolerance + step;
+            final expected =
+                lastEvent.inMicroseconds ~/ perRebuild.inMicroseconds + 1;
+            expect(expected, 3, reason: 'sanity: a 20 ms burst, 8 ms guard');
+            expect(
+              timersBuilt,
+              expected,
+              reason: 'signal() must not cancel and rebuild a Timer per event',
+            );
+            expect(fireTimes, isEmpty, reason: 'still inside the debounce');
+
+            // The whole burst collapses to one fire, on the last rebuilt
+            // timer's target: trailing after the last rebuild. That is at
+            // most the tolerance early and never late.
+            async.elapse(trailing);
+            final lastRebuild = perRebuild * (expected - 1);
+            expect(fireTimes, [lastRebuild + trailing]);
+            expect(
+              fireTimes.single,
+              greaterThanOrEqualTo(
+                lastEvent + trailing - Coalescer.rescheduleTolerance,
+              ),
+              reason: 'trailing resolves at most the tolerance early',
+            );
+            expect(
+              fireTimes.single,
+              lessThanOrEqualTo(lastEvent + trailing),
+              reason: 'the guard must never make trailing fire late',
+            );
+          },
+          zoneSpecification: ZoneSpecification(
+            createTimer: (self, parent, zone, duration, callback) {
+              timersBuilt++;
+              return parent.createTimer(zone, duration, callback);
+            },
+          ),
+        );
+      });
     });
 
     test('a guarded reschedule still fires, and never late', () {
```

Phase 2: the coalescer test rewrite (`git apply --index`).

### A.5 `mutate_coalescer.py`

```python
"""Seen-to-fail check for F6: remove Coalescer's reschedule guard in a scratch copy
and confirm the rewritten test catches it.

Usage: mutate_coalescer.py <repo> <scratch-dir>
Exits 0 only when the mutant fails with the expected message and the unmutated
copy passes.
"""
from __future__ import annotations

import shutil
import subprocess
import sys
from pathlib import Path

GUARD = """    if (_timer != null &&
        scheduled != null &&
        !target.isBefore(scheduled) &&
        target.difference(scheduled) <= rescheduleTolerance) {
      return;
    }
"""
TEST = "test/coalescer_test.dart"
NAME = "a tight burst does not rebuild the timer per event"


def run_test(root: Path, log: Path) -> tuple[int, str]:
    with log.open("w") as sink:
        code = subprocess.run(["flutter", "test", TEST, "--plain-name", NAME], cwd=root,
                              stdout=sink, stderr=subprocess.STDOUT, timeout=600).returncode
    return code, log.read_text(errors="replace")


def main() -> int:
    repo, scratch = Path(sys.argv[1]), Path(sys.argv[2])
    copy = scratch / "coalescer-mutant"
    if copy.exists():
        shutil.rmtree(copy)
    shutil.copytree(repo, copy, ignore=shutil.ignore_patterns(".git", "build", ".dart_tool", ".flutter-sdk"))
    subprocess.run(["flutter", "pub", "get", "--offline"], cwd=copy, capture_output=True, timeout=600, check=True)
    code, _ = run_test(copy, scratch / "coalescer-unmutated.log")
    print(f"unmutated: exit={code}")
    src = copy / "lib/core/git/coalescer.dart"
    text = src.read_text()
    assert text.count(GUARD) == 1, "guard anchor not found exactly once"
    src.write_text(text.replace(GUARD, ""))
    assert GUARD not in src.read_text(), "mutation did not land"
    mcode, out = run_test(copy, scratch / "coalescer-mutant.log")
    caught = mcode != 0 and "Expected: <3>" in out and "Actual: <20000>" in out
    print(f"mutant: exit={mcode} caught={'yes' if caught else 'NO'}")
    return 0 if code == 0 and caught else 1


if __name__ == "__main__":
    sys.exit(main())
```

Phase 2: the seen-to-fail check, run by mutation in a scratch copy.

### A.6 `ci_log_text.dart`

```dart
/// Plain-text cleanup for CI job logs fetched through a forge CLI.
library;

/// Real terminal escape sequences, as ECMA-48 defines them: a CSI sequence
/// (`ESC [` parameter bytes, intermediate bytes, one final byte), an OSC
/// string (`ESC ]` up to BEL or ST), or a two-byte Fe escape. CSI and OSC are
/// tried before Fe, whose range includes the `]` that opens an OSC.
final RegExp _realEscape = RegExp(
  r'\x1B\[[\x30-\x3F]*[\x20-\x2F]*[\x40-\x7E]'
  r'|\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)'
  r'|\x1B[\x40-\x5A\x5C-\x5F]',
);

/// gh's caret rendering of an SGR (`m`) or EL (`K`) sequence: `^[[36;1m`.
///
/// Deliberately narrow. A literal `^[` is ordinary log text, and the full
/// ECMA-48 grammar applied to it eats script content: `'^[[:digit:]]+$'`
/// would lose `^[[:d` and become `'igit:]]+$'`.
final RegExp _caretSgr = RegExp(r'\^\[\[[0-9;]*[mK]');

/// gh's `<job>\t<step>\t` column prefix: two tab-free fields, each followed by
/// a tab.
final RegExp _columnPrefix = RegExp(r'^[^\t\n]*\t[^\t\n]*\t');

const String _bom = '\uFEFF';

/// Cleans the output of `gh run view --job <id> --log` for display.
///
/// gh has rendered every control byte in a run log as caret text since
/// v2.92.0 (cli/cli#13272, "Fix log terminal injection"), so an ESC arrives
/// as the two characters `^[` and a colour code reads as `^[[36;1m`. A host
/// with an older gh sends the real ESC bytes instead. The app runs whichever
/// gh the connected host has, so both forms are handled, as is a future gh
/// that strips them itself.
///
/// Four rules, applied in this order:
///
/// 1. remove real ESC sequences (CSI, OSC and two-byte Fe);
/// 2. remove the caret SGR and EL form `^[[<digits and ;>m` or `…K` only, so
///    literal `^[` text such as `'^[[:digit:]]+$'` survives unchanged;
/// 3. remove the `<a>\t<b>\t` prefix only when every non-empty line starts
///    with the identical pair;
/// 4. remove one U+FEFF at the start of each line's content, after rule 3.
///
/// Nothing else changes: line endings are kept and nothing is trimmed.
String sanitizeGhJobLog(String raw) {
  if (raw.isEmpty) return raw;
  final text = raw.replaceAll(_realEscape, '').replaceAll(_caretSgr, '');
  final lines = text.split('\n');
  final prefix = _uniformPrefix(lines);
  return lines.map((line) => _cleanLine(line, prefix)).join('\n');
}

/// The `<a>\t<b>\t` prefix shared by every non-empty line, or null when there
/// is no non-empty line, the first has no such prefix, or any line differs.
String? _uniformPrefix(List<String> lines) {
  String? prefix;
  for (final line in lines) {
    if (line.isEmpty) continue;
    if (prefix == null) {
      final match = _columnPrefix.firstMatch(line);
      if (match == null) return null;
      prefix = match.group(0);
    } else if (!line.startsWith(prefix)) {
      return null;
    }
  }
  return prefix;
}

String _cleanLine(String line, String? prefix) {
  final content = prefix != null && line.isNotEmpty
      ? line.substring(prefix.length)
      : line;
  return content.startsWith(_bom) ? content.substring(_bom.length) : content;
}
```

Phase 3: becomes `lib/core/forge/ci_log_text.dart`.

### A.7 `ci_log_text_test.dart`

```dart
// Unit coverage for sanitizeGhJobLog (MADR 0064, F4-A). The fixtures are
// verbatim lines from two public job logs captured with gh 2.99.0:
// percona/percona-postgresql-operator job 104212484924 and cli/cli job
// 106365973017. The real-ESC line is the same job fetched with
// `gh api --allow-escape-sequences`.

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/forge/ci_log_text.dart';

// Fixtures 1–9: captured lines. Fixture 10: literal `^[` text that must
// survive.
const _f1BomLine =
    "Dependabot\tUNKNOWN STEP\t\uFEFF2026-09-15T01:02:15.6924263Z Current runner version: '2.337.0'";
const _f2GroupLine =
    'Dependabot\tUNKNOWN STEP\t2026-09-15T01:02:15.6967489Z ##[group]GITHUB_TOKEN Permissions';
const _f3ContentsLine =
    'Dependabot\tUNKNOWN STEP\t2026-09-15T01:02:15.6969706Z Contents: read';
const _f4EndgroupLine =
    'Dependabot\tUNKNOWN STEP\t2026-09-15T01:02:15.6971640Z ##[endgroup]';
const _f5RunGroupLine =
    'Dependabot\tUNKNOWN STEP\t2026-09-15T01:02:17.1855744Z ##[group]Run mkdir -p  ./dependabot-job-1576676050-1789434129';
const _f6CaretLine =
    'Dependabot\tUNKNOWN STEP\t2026-09-15T01:02:17.1856861Z ^[[36;1mmkdir -p  ./dependabot-job-1576676050-1789434129^[[0m';
const _f7RealEscLine =
    '2026-09-15T01:02:17.1856861Z \x1B[36;1mmkdir -p  ./dependabot-job-1576676050-1789434129\x1B[0m';
const _f8WarningLine =
    'Dependabot\tUNKNOWN STEP\t2026-09-15T01:02:43.4700318Z updater | rehash: warning: skipping ca-certificates.crt,it does not contain exactly one certificate or CRL';
const _f9CliCaretLine =
    'build (ubuntu-latest)\tUNKNOWN STEP\t2026-09-21T14:06:20.6170077Z ^[[36;1mgo test -race -tags=integration ./...^[[0m';
const _f10Guards = [
  r"grep -E '^[[:digit:]]+$' file",
  r"sed 's/^[[:space:]]*//'",
];

const _mkdirContent =
    '2026-09-15T01:02:17.1856861Z mkdir -p  ./dependabot-job-1576676050-1789434129';

// Lines 1, 21–25 and 33–36 of the Dependabot capture, with gh's trailing
// newline.
const _capturedLog =
    "Dependabot\tUNKNOWN STEP\t\uFEFF2026-09-15T01:02:15.6924263Z Current runner version: '2.337.0'\n"
    'Dependabot\tUNKNOWN STEP\t2026-09-15T01:02:15.6967489Z ##[group]GITHUB_TOKEN Permissions\n'
    'Dependabot\tUNKNOWN STEP\t2026-09-15T01:02:15.6969706Z Contents: read\n'
    'Dependabot\tUNKNOWN STEP\t2026-09-15T01:02:15.6970355Z Metadata: read\n'
    'Dependabot\tUNKNOWN STEP\t2026-09-15T01:02:15.6970925Z Packages: read\n'
    'Dependabot\tUNKNOWN STEP\t2026-09-15T01:02:15.6971640Z ##[endgroup]\n'
    'Dependabot\tUNKNOWN STEP\t2026-09-15T01:02:17.1855744Z ##[group]Run mkdir -p  ./dependabot-job-1576676050-1789434129\n'
    'Dependabot\tUNKNOWN STEP\t2026-09-15T01:02:17.1856861Z ^[[36;1mmkdir -p  ./dependabot-job-1576676050-1789434129^[[0m\n'
    'Dependabot\tUNKNOWN STEP\t2026-09-15T01:02:17.1897711Z shell: /usr/bin/bash -e {0}\n'
    'Dependabot\tUNKNOWN STEP\t2026-09-15T01:02:17.1898643Z ##[endgroup]\n';

const _capturedLogClean =
    "2026-09-15T01:02:15.6924263Z Current runner version: '2.337.0'\n"
    '2026-09-15T01:02:15.6967489Z ##[group]GITHUB_TOKEN Permissions\n'
    '2026-09-15T01:02:15.6969706Z Contents: read\n'
    '2026-09-15T01:02:15.6970355Z Metadata: read\n'
    '2026-09-15T01:02:15.6970925Z Packages: read\n'
    '2026-09-15T01:02:15.6971640Z ##[endgroup]\n'
    '2026-09-15T01:02:17.1855744Z ##[group]Run mkdir -p  ./dependabot-job-1576676050-1789434129\n'
    '2026-09-15T01:02:17.1856861Z mkdir -p  ./dependabot-job-1576676050-1789434129\n'
    '2026-09-15T01:02:17.1897711Z shell: /usr/bin/bash -e {0}\n'
    '2026-09-15T01:02:17.1898643Z ##[endgroup]\n';

void main() {
  group('escape sequences', () {
    test('a caret SGR line comes out clean', () {
      expect(sanitizeGhJobLog(_f6CaretLine), _mkdirContent);
    });

    test('a caret SGR line from a second repository comes out clean', () {
      expect(
        sanitizeGhJobLog(_f9CliCaretLine),
        '2026-09-21T14:06:20.6170077Z go test -race -tags=integration ./...',
      );
    });

    test('a real-ESC line (older gh, or gh api) comes out clean', () {
      expect(sanitizeGhJobLog(_f7RealEscLine), _mkdirContent);
    });

    test('the caret EL form is removed', () {
      expect(sanitizeGhJobLog('progress^[[K done'), 'progress done');
    });

    test('an OSC string is removed with either terminator', () {
      expect(
        sanitizeGhJobLog('a\x1B]0;window title\x07b\x1B]8;;https://x\x1B\\c'),
        'abc',
      );
    });

    test('a two-byte Fe escape is removed', () {
      expect(sanitizeGhJobLog('one\x1BMtwo\x1B7three'), 'onetwo\x1B7three');
    });

    test('CSI with intermediate bytes and a non-SGR final is removed', () {
      expect(sanitizeGhJobLog('x\x1B[2 qy\x1B[?25lz'), 'xyz');
    });

    for (final guard in _f10Guards) {
      test('literal caret text survives unchanged: $guard', () {
        expect(sanitizeGhJobLog(guard), guard);
      });
    }

    test('a caret sequence gh never emits for SGR/EL is left alone', () {
      expect(sanitizeGhJobLog('echo ^[[A pressed'), 'echo ^[[A pressed');
    });
  });

  group('column prefix', () {
    test('a prefix identical on every line is removed', () {
      const log = '$_f2GroupLine\n$_f3ContentsLine\n$_f4EndgroupLine';
      expect(
        sanitizeGhJobLog(log),
        '2026-09-15T01:02:15.6967489Z ##[group]GITHUB_TOKEN Permissions\n'
        '2026-09-15T01:02:15.6969706Z Contents: read\n'
        '2026-09-15T01:02:15.6971640Z ##[endgroup]',
      );
    });

    test('empty lines do not block the prefix and are kept', () {
      const log = '$_f3ContentsLine\n\n$_f8WarningLine\n';
      expect(
        sanitizeGhJobLog(log),
        '2026-09-15T01:02:15.6969706Z Contents: read\n'
        '\n'
        '2026-09-15T01:02:43.4700318Z updater | rehash: warning: skipping '
        'ca-certificates.crt,it does not contain exactly one certificate or '
        'CRL\n',
      );
    });

    test('the prefix is kept when one line names a different step', () {
      const other =
          'Dependabot\tSet up job\t2026-09-15T01:02:15.6969706Z Contents: read';
      const log = '$_f2GroupLine\n$other';
      expect(sanitizeGhJobLog(log), log);
    });

    test('the prefix is kept when one line lacks the tabs', () {
      const log = '$_f5RunGroupLine\n$_f7RealEscLine';
      expect(
        sanitizeGhJobLog(log),
        '$_f5RunGroupLine\n'
        '2026-09-15T01:02:17.1856861Z mkdir -p  '
        './dependabot-job-1576676050-1789434129',
      );
    });

    test('a single-tab line has no prefix to remove', () {
      expect(sanitizeGhJobLog('a\tb'), 'a\tb');
    });
  });

  group('byte-order mark', () {
    test('a BOM at the start of a line\'s content is removed', () {
      expect(
        sanitizeGhJobLog(_f1BomLine),
        "2026-09-15T01:02:15.6924263Z Current runner version: '2.337.0'",
      );
    });

    test('a BOM is removed without a prefix too', () {
      expect(sanitizeGhJobLog('\uFEFFplain'), 'plain');
    });

    test('a BOM in the middle of a line survives', () {
      expect(sanitizeGhJobLog('before\uFEFFafter'), 'before\uFEFFafter');
    });

    test('a BOM before the prefix blocks the prefix but is removed', () {
      const log = '\uFEFF$_f3ContentsLine\n$_f4EndgroupLine';
      expect(sanitizeGhJobLog(log), '$_f3ContentsLine\n$_f4EndgroupLine');
    });
  });

  group('whole log', () {
    test('an empty string stays empty', () {
      expect(sanitizeGhJobLog(''), '');
    });

    test('line endings are preserved and nothing is trimmed', () {
      expect(sanitizeGhJobLog('  a  \r\n\n b\n'), '  a  \r\n\n b\n');
    });

    test('a captured excerpt comes out exactly clean', () {
      expect(sanitizeGhJobLog(_capturedLog), _capturedLogClean);
    });

    test('sanitizing is idempotent on the captured excerpt', () {
      final once = sanitizeGhJobLog(_capturedLog);
      expect(sanitizeGhJobLog(once), once);
    });
  });
}
```

Phase 3: `test/ci_log_text_test.dart`.

### A.8 `gh_job_log_sanitize_wiring_test.dart`

```dart
// Pins where the GitHub job log is cleaned (MADR 0064, F4-A): in
// GhService.runJobLog, so every consumer gets clean text. Both tests feed the
// raw stdout of `gh run view --job <id> --log` through a mock executor and
// never override runJobLogProvider, so they pass only if the service cleans.

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/github/gh_service.dart';
import 'package:remote_magic_git/core/github/models.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/features/github/run_jobs_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/app_scope.dart';
import 'helpers/mock_executor.dart';

const _repo = '/srv/repo';
const _runId = 77;
const _jobId = 104212484924;

// Verbatim from percona/percona-postgresql-operator job 104212484924 (gh
// 2.99.0), with gh's trailing newline.
const _rawStdout =
    'Dependabot\tUNKNOWN STEP\t2026-09-15T01:02:17.1856861Z ^[[36;1mmkdir -p  ./dependabot-job-1576676050-1789434129^[[0m\n';
const _cleanLog =
    '2026-09-15T01:02:17.1856861Z mkdir -p  ./dependabot-job-1576676050-1789434129\n';

GhService _serviceWithRawLog() => GhService(
  MockExecutor(
    onExecute: (call) => call.gitArgs.contains('--log')
        ? const SSHCommandResult(exitCode: 0, stdout: _rawStdout, stderr: '')
        : null,
  ),
);

void main() {
  test('runJobLog returns the cleaned log, not gh\'s raw stdout', () async {
    final log = await _serviceWithRawLog().runJobLog(_repo, _jobId);
    expect(log, _cleanLog);
  });

  testWidgets('the run jobs view shows no caret escape text', (tester) async {
    SharedPreferences.setMockInitialValues(const {});
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      appProviderScope(
        overrides: [
          ghServiceProvider.overrideWithValue(_serviceWithRawLog()),
          runJobsProvider((_repo, _runId)).overrideWith(
            (ref) => Stream.value(const [
              GhJob(
                id: _jobId,
                name: 'Dependabot',
                status: 'completed',
                conclusion: 'success',
              ),
            ]),
          ),
        ],
        child: const MacosApp(
          debugShowCheckedModeBanner: false,
          home: SizedBox.expand(
            child: RunJobsView(repoPath: _repo, runId: _runId),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    await tester.tap(find.text('Dependabot'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.textContaining('mkdir -p  ./dependabot-job'), findsOneWidget);
    expect(find.textContaining('^['), findsNothing);
    expect(find.textContaining('UNKNOWN STEP'), findsNothing);
  });
}
```

Phase 3: `test/gh_job_log_sanitize_wiring_test.dart`.

### A.9 `F4.diff`

```diff
diff --git a/lib/core/github/gh_service.dart b/lib/core/github/gh_service.dart
index 89bbf80..643c286 100644
--- a/lib/core/github/gh_service.dart
+++ b/lib/core/github/gh_service.dart
@@ -1,4 +1,5 @@
 import 'dart:convert';
+import '../forge/ci_log_text.dart';
 import '../forge/forge.dart';
 import '../forge/forge_dashboard.dart';
 import '../forge/forge_json.dart';
@@ -739,7 +740,8 @@ class GhService {
     return true;
   }
 
-  /// A completed job's log via `gh run view --job <id> --log`. GitHub only
+  /// A completed job's log via `gh run view --job <id> --log`, cleaned by
+  /// [sanitizeGhJobLog] so every consumer gets plain text. GitHub only
   /// serves logs once the job finishes; for an in-progress job `gh` exits
   /// non-zero and this throws [GhException] (the view shows a "logs available
   /// when the job completes" placeholder rather than calling this).
@@ -753,7 +755,7 @@ class GhService {
     if (!result.isSuccess) {
       throw GhException('gh run view --log failed', result);
     }
-    return result.stdout;
+    return sanitizeGhJobLog(result.stdout);
   }
 
   // ---- Mutations (outward-facing) ------------------------------------------
```

Phase 3: the `gh_service.dart` wiring (`git apply --index`).

### A.10 `output_view_placement_test.dart`

```dart
// MADR 0064 F3: the Output view belongs to the shell, not to one page.
//
// ⇧⌘O ("Toggle Output View") is a global command — the keymap, the native
// View menu and the palette all flip `outputLogProvider.visible` from any
// page. The view itself used to be mounted only inside the Repository page,
// so from History, Branches, Stashes, Forge or Worktrees the command flipped
// the menu checkmark and nothing appeared. These tests drive a connected
// AppShell with real key events only — ⌘1…⌘6 to change page, ⇧⌘O to toggle —
// and assert on the rendered widget, not the provider, which is what every
// earlier test checked and why the defect shipped green.

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/git/watch_event.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/features/app_shell.dart';
import 'package:remote_magic_git/features/branches/branches_view.dart';
import 'package:remote_magic_git/features/common/output_view.dart';
import 'package:remote_magic_git/features/forge/forge_panel.dart';
import 'package:remote_magic_git/features/history/history_view.dart';
import 'package:remote_magic_git/features/repository/repo_status_view.dart';
import 'package:remote_magic_git/features/stash/stash_view.dart';
import 'package:remote_magic_git/features/worktrees/worktrees_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A ConnectionController pinned to a connected state, so the shell renders
/// its pages without running a real connect.
class _StubConnection extends ConnectionController {
  _StubConnection(this._state);
  final ConnectionState _state;

  @override
  ConnectionState build() => _state;
}

const _pageNames = [
  'Repository',
  'History',
  'Branches',
  'Stashes',
  'Forge',
  'Worktrees',
];

/// The widget each page mounts, so a test can prove the ⌘N switch landed.
const _pageTypes = [
  RepoStatusView,
  HistoryView,
  BranchesView,
  StashView,
  ForgePanel,
  WorktreesView,
];

const _pageKeys = [
  LogicalKeyboardKey.digit1,
  LogicalKeyboardKey.digit2,
  LogicalKeyboardKey.digit3,
  LogicalKeyboardKey.digit4,
  LogicalKeyboardKey.digit5,
  LogicalKeyboardKey.digit6,
];

Future<void> _pumpConnectedShell(WidgetTester tester, Size size) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        connectionProvider.overrideWith(
          () => _StubConnection(
            const ConnectionState(
              phase: ConnectionPhase.connected,
              backend: ConnectionBackend.ssh,
              host: 'build01.example.com',
              repoPath: '/srv/repo',
              repoPaths: ['/srv/repo'],
            ),
          ),
        ),
        repoWatchProvider(
          '/srv/repo',
        ).overrideWith((ref) => const Stream<RepoWatchEvent>.empty()),
        savedConnectionsProvider.overrideWith((ref) async => const []),
        savedLocalReposProvider.overrideWith((ref) async => const []),
      ],
      child: const MacosApp(
        debugShowCheckedModeBanner: false,
        home: SizedBox.expand(child: AppShell()),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

/// Presses [key] with the given modifiers held, as real key events.
Future<void> _chord(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  bool shift = false,
}) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
  if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyEvent(key);
  if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 2));
}

/// Switches to [page] with its ⌘N shortcut, then checks ⇧⌘O toggles the
/// visible Output view one → none → one (it is visible by default).
Future<void> _expectToggleOnPage(WidgetTester tester, int page) async {
  await _chord(tester, _pageKeys[page]);
  expect(
    find.byType(_pageTypes[page]),
    findsOneWidget,
    reason: '⌘${page + 1} shows the ${_pageNames[page]} page',
  );
  expect(
    find.byType(OutputView),
    findsOneWidget,
    reason: 'the Output view is visible by default on ${_pageNames[page]}',
  );

  await _chord(tester, LogicalKeyboardKey.keyO, shift: true);
  expect(
    find.byType(OutputView),
    findsNothing,
    reason: '⇧⌘O hides the Output view on ${_pageNames[page]}',
  );

  await _chord(tester, LogicalKeyboardKey.keyO, shift: true);
  expect(
    find.byType(OutputView),
    findsOneWidget,
    reason: '⇧⌘O shows the Output view again on ${_pageNames[page]}',
  );
}

void main() {
  for (var page = 0; page < _pageNames.length; page++) {
    testWidgets('⇧⌘O toggles the Output view on ${_pageNames[page]} '
        '(1400x900)', (tester) async {
      await _pumpConnectedShell(tester, const Size(1400, 900));
      await _expectToggleOnPage(tester, page);
      await _unmount(tester);
    });
  }

  // The supported minimum window. The sidebar is hidden at this width, so
  // the page is changed by its keyboard shortcut, which is also the only
  // route a real user has without reopening the sidebar.
  for (final page in const [1, 0]) {
    testWidgets('⇧⌘O toggles the Output view on ${_pageNames[page]} '
        '(640x480)', (tester) async {
      await _pumpConnectedShell(tester, const Size(640, 480));
      await _expectToggleOnPage(tester, page);
      await _unmount(tester);
    });
  }
}
```

Phase 4: `test/output_view_placement_test.dart`.

### A.11 `F3.diff`

```diff
diff --git a/lib/features/app_shell.dart b/lib/features/app_shell.dart
index 7c2237b..a7a8111 100644
--- a/lib/features/app_shell.dart
+++ b/lib/features/app_shell.dart
@@ -23,6 +23,7 @@ import 'common/command_palette.dart';
 import 'common/diff_view.dart' show kDiffMono;
 import 'common/escape_dismissible.dart';
 import 'common/menu_bar_bridge.dart';
+import 'common/output_view.dart';
 import 'common/palette_intents.dart';
 import 'common/palette_models.dart';
 import 'common/panel_actions.dart';
@@ -1132,11 +1133,17 @@ class _AppShellState extends ConsumerState<AppShell> {
           // trigger their panel's provider fetches — until first opened.
           // A missing-tool banner sits above every page (zero-height when the
           // host is healthy) so a gap in the environment is visible wherever
-          // the user is, not just in Settings.
+          // the user is, not just in Settings. The Output view sits below
+          // every page for the same reason (MADR 0064 F3): its toggle is
+          // global, so the view it toggles must be too.
           return Column(
             children: [
               const ToolHealthBanner(),
-              Expanded(child: _pages(repoPath, pageIndex, visitedPages)),
+              Expanded(
+                child: OutputViewHost(
+                  child: _pages(repoPath, pageIndex, visitedPages),
+                ),
+              ),
             ],
           );
         },
diff --git a/lib/features/repository/output_view.dart b/lib/features/common/output_view.dart
similarity index 71%
rename from lib/features/repository/output_view.dart
rename to lib/features/common/output_view.dart
index 0736aff..edf54f0 100644
--- a/lib/features/repository/output_view.dart
+++ b/lib/features/common/output_view.dart
@@ -1,17 +1,76 @@
 import 'package:flutter/material.dart';
 import 'package:flutter_riverpod/flutter_riverpod.dart';
 import 'package:macos_ui/macos_ui.dart';
+import '../../core/exec/operation_activity.dart';
 import '../../core/output/output_log.dart';
 import '../../core/theme/app_theme.dart';
-import '../common/tool_icon_button.dart';
+import 'tool_icon_button.dart';
 
-/// The user-resizable output view docked across the bottom of the repository
-/// panel. Renders the [outputLogProvider] buffer (push/pull/sync output for
-/// now) in a horizontally-scrolling, monospace, dark log. Its top edge is a
-/// drag handle that grows/shrinks the panel. Shown only when the output view is
-/// enabled (View → Show Output View).
+/// Owns a window's one Output view (MADR 0064 F3): [child] fills the space
+/// above, and the docked log sits below it while `outputLogProvider.visible`
+/// is set.
+///
+/// The Output toggle is a global command — the keymap, the native View menu
+/// and the palette all flip the same flag from any page — so the view must
+/// live where every page can see it. `AppShell` wraps its page stack in one,
+/// and the detached repository window, which has no `AppShell`, wraps its
+/// status view in another.
+///
+/// It also publishes the reveal action ([revealerOf]), so a context bar
+/// offers the Activity Center's "Output" link exactly when an Output view is
+/// hosted above it, and never as a link that would show nothing.
+class OutputViewHost extends ConsumerWidget {
+  final Widget child;
+
+  const OutputViewHost({super.key, required this.child});
+
+  /// Shows the Output view and scrolls it to [OperationId]'s first line, or
+  /// null when no [OutputViewHost] is above [context].
+  static ValueChanged<OperationId>? revealerOf(BuildContext context) => context
+      .dependOnInheritedWidgetOfExactType<_OutputViewHostScope>()
+      ?.reveal;
+
+  @override
+  Widget build(BuildContext context, WidgetRef ref) {
+    final visible = ref.watch(outputLogProvider.select((s) => s.visible));
+    return _OutputViewHostScope(
+      reveal: (id) {
+        ref.read(outputLogProvider.notifier).setVisible(true);
+        ref.read(outputRevealProvider.notifier).request(id);
+      },
+      child: LayoutBuilder(
+        builder: (context, constraints) => Column(
+          crossAxisAlignment: CrossAxisAlignment.stretch,
+          children: [
+            // Index 0 is always the child, so toggling the log never
+            // remounts the pages above it.
+            Expanded(child: child),
+            if (visible) OutputView(maxHeight: constraints.maxHeight),
+          ],
+        ),
+      ),
+    );
+  }
+}
+
+class _OutputViewHostScope extends InheritedWidget {
+  final ValueChanged<OperationId> reveal;
+
+  const _OutputViewHostScope({required this.reveal, required super.child});
+
+  // The closure only ever reads the same two notifiers, so a new instance
+  // on rebuild is not a change dependants need to hear about.
+  @override
+  bool updateShouldNotify(_OutputViewHostScope oldWidget) => false;
+}
+
+/// The user-resizable output view docked across the bottom of a window, below
+/// every page (see [OutputViewHost]). Renders the [outputLogProvider] buffer in
+/// a horizontally-scrolling, monospace, dark log. Its top edge is a drag handle
+/// that grows/shrinks the panel. Shown only when the output view is enabled
+/// (View → Show Output View).
 class OutputView extends ConsumerStatefulWidget {
-  /// Height of the surrounding repository panel, used for the default (1/6) and
+  /// Height of the area the view is docked in, used for the default (1/6) and
   /// the resize clamp.
   final double maxHeight;
 
diff --git a/lib/features/common/repository_context_bar.dart b/lib/features/common/repository_context_bar.dart
index 917ba1d..2483976 100644
--- a/lib/features/common/repository_context_bar.dart
+++ b/lib/features/common/repository_context_bar.dart
@@ -9,6 +9,7 @@ import '../../core/settings/repository_workspace_prefs.dart';
 import 'activity_center.dart';
 import 'buttons.dart';
 import 'link_status_chip.dart';
+import 'output_view.dart';
 import 'repository_context.dart';
 import 'repository_workspace_models.dart';
 import 'repository_workspace_scaffold.dart';
@@ -46,6 +47,11 @@ class RepositoryContextBar extends StatelessWidget {
   /// toolbar band — so it moves here rather than disappearing.
   final bool showLinkStatus;
   final VoidCallback? onToggleSidebar;
+
+  /// Reveals an operation's lines in the Output view. Defaults to the
+  /// enclosing [OutputViewHost]'s reveal, so every page's Activity Center
+  /// offers the "Output" link wherever an Output view is actually hosted —
+  /// and nowhere it would show nothing.
   final ValueChanged<OperationId>? onRevealOutput;
 
   const RepositoryContextBar({
@@ -63,6 +69,7 @@ class RepositoryContextBar extends StatelessWidget {
 
   @override
   Widget build(BuildContext context) {
+    final revealOutput = onRevealOutput ?? OutputViewHost.revealerOf(context);
     return LayoutBuilder(
       builder: (context, constraints) {
         final appearance = WorkspaceAppearanceScope.maybeOf(context);
@@ -177,7 +184,7 @@ class RepositoryContextBar extends StatelessWidget {
                       // the second copy the Repository toolbar used to render:
                       // the reveal-in-Output affordance lived only on that
                       // copy.
-                      onRevealOutput: onRevealOutput,
+                      onRevealOutput: revealOutput,
                     ),
                   ),
                   const SizedBox(width: 6),
diff --git a/lib/features/repository/repo_status_view.dart b/lib/features/repository/repo_status_view.dart
index f7f0223..9adacb7 100644
--- a/lib/features/repository/repo_status_view.dart
+++ b/lib/features/repository/repo_status_view.dart
@@ -55,7 +55,6 @@ import 'diff_view_controls.dart';
 import 'file_view.dart';
 import 'hunk_diff_view.dart';
 import 'multi_file_review.dart';
-import 'output_view.dart';
 import 'repo_change_filter.dart';
 import 'repo_change_model.dart';
 import 'repo_change_navigator.dart';
@@ -1575,7 +1574,6 @@ class _RepoStatusViewState extends ConsumerState<RepoStatusView>
     final sessionWarning = ref.watch(
       connectionProvider.select((c) => c.warning),
     );
-    final outputVisible = ref.watch(outputLogProvider.select((s) => s.visible));
     final fileVisible = ref.watch(fileViewVisibleProvider);
 
     final status = statusAsync.value;
@@ -1872,10 +1870,12 @@ class _RepoStatusViewState extends ConsumerState<RepoStatusView>
             ),
           );
           // Pane priority: a right pane (the file view) is the full-height "3rd
-          // panel" and takes precedence over any horizontal pane. Horizontal
-          // panes — including the output view — live inside the center "main"
-          // column, so they're clamped to its width and never extend under (or
-          // clip) the right pane.
+          // panel" of this page and takes precedence over this page's
+          // horizontal panes, which live inside the center "main" column, so
+          // they're clamped to its width and never extend under (or clip) the
+          // right pane. The Output view is not one of them: it belongs to the
+          // shell, below every page (MADR 0064 F3), so it spans the full width
+          // beneath this whole page, File view included.
           final centerColumn = Column(
             crossAxisAlignment: CrossAxisAlignment.stretch,
             children: [
@@ -1895,7 +1895,6 @@ class _RepoStatusViewState extends ConsumerState<RepoStatusView>
                   composerController,
                   policyAdvisory: commitPolicyAdvisory,
                 ),
-              if (outputVisible) OutputView(maxHeight: constraints.maxHeight),
             ],
           );
           final canvas = LayoutBuilder(
@@ -1949,10 +1948,6 @@ class _RepoStatusViewState extends ConsumerState<RepoStatusView>
               showLinkStatus: !connection.isLocal,
               onToggleSidebar: () =>
                   MacosWindowScope.maybeOf(context)?.toggleSidebar(),
-              onRevealOutput: (id) {
-                ref.read(outputLogProvider.notifier).setVisible(true);
-                ref.read(outputRevealProvider.notifier).request(id);
-              },
               onPrimaryAction: (kind) => _invokePrimaryRepositoryAction(
                 kind,
                 status: status,
diff --git a/lib/features/window/secondary_window_main.dart b/lib/features/window/secondary_window_main.dart
index dd77105..4127734 100644
--- a/lib/features/window/secondary_window_main.dart
+++ b/lib/features/window/secondary_window_main.dart
@@ -46,6 +46,7 @@ import '../../core/window/window_channels.dart';
 import '../../core/window/window_kind.dart';
 import '../common/actions.dart';
 import '../common/escape_dismissible.dart';
+import '../common/output_view.dart';
 import '../common/undo_toast.dart';
 import '../history/history_view.dart';
 import '../recovery/recovery_sheet.dart';
@@ -1098,10 +1099,14 @@ class _SecondaryWindowShellState extends ConsumerState<SecondaryWindowShell>
       repoPath: repoPath,
       isActive: true,
     ),
-    WindowKind.detachedRepo => RepoStatusView(
-      key: ValueKey(repoPath),
-      repoPath: repoPath,
-      isActive: true,
+    // This window has no AppShell, so it hosts its own Output view — the
+    // status view no longer mounts one (MADR 0064 F3).
+    WindowKind.detachedRepo => OutputViewHost(
+      child: RepoStatusView(
+        key: ValueKey(repoPath),
+        repoPath: repoPath,
+        isActive: true,
+      ),
     ),
   };
 }
diff --git a/macos/Runner/help_book.json b/macos/Runner/help_book.json
index ea1485c..e338dc7 100644
--- a/macos/Runner/help_book.json
+++ b/macos/Runner/help_book.json
@@ -482,7 +482,7 @@
             },
             {
               "type": "paragraph",
-              "text": "Output (View ▸ Show Output View, ⇧⌘O) is a docked command log under the Repository canvas, visible by default. It shows git and SSH invocations, stdout, stderr, and exit codes, including doctor install output."
+              "text": "Output (View ▸ Show Output View, ⇧⌘O) is a docked command log below every page, visible by default. It shows git and SSH invocations, stdout, stderr, and exit codes, including doctor install output."
             },
             {
               "type": "items",
diff --git a/test/output_view_test.dart b/test/output_view_test.dart
index be42faf..72bbf43 100644
--- a/test/output_view_test.dart
+++ b/test/output_view_test.dart
@@ -9,7 +9,7 @@ import 'package:macos_ui/macos_ui.dart';
 
 import 'package:remote_magic_git/core/output/output_log.dart';
 import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
-import 'package:remote_magic_git/features/repository/output_view.dart';
+import 'package:remote_magic_git/features/common/output_view.dart';
 
 void main() {
   testWidgets('OutputView renders lines appended to the notifier', (
```

Phase 4: the shell-level Output view, including the rename (`git apply --index`).

### A.12 `compact_workspace_navigation_test.dart`

```dart
// MADR 0064 F1: at the compact size class (< 720 px of panel width) a
// repository workspace shows one pane at a time. Selecting a row must open the
// canvas WITHOUT trapping the user there: Esc, ⌘[ and the back bar return to
// the list, focus lands where the panel's shortcuts can see it, and the
// selection survives the round trip.
//
// Real input only — taps and key events. Bindings are never invoked directly
// (that bypasses focus routing, which is exactly what failed here), and no
// provider is mutated to fake a state change.
//
// The 1000 px group is the control: standard width shows both panes, so the
// same steps pass on the unmodified tree and prove the instrument works.

import 'package:flutter/cupertino.dart' hide ConnectionState;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/forge/branch_forge_status.dart';
import 'package:remote_magic_git/core/forge/forge_dashboard.dart';
import 'package:remote_magic_git/core/forge/merge_plan.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/gitlab/glab_service.dart';
import 'package:remote_magic_git/core/gitlab/models.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/settings/app_settings.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/core/utils/git_porcelain_parser.dart';
import 'package:remote_magic_git/features/branches/branches_view.dart';
import 'package:remote_magic_git/features/common/panel_shortcuts.dart';
import 'package:remote_magic_git/features/common/repository_workspace_models.dart';
import 'package:remote_magic_git/features/common/workspace_focus_order.dart';
import 'package:remote_magic_git/features/forge/forge_prefs.dart';
import 'package:remote_magic_git/features/gitlab/gitlab_panel.dart';
import 'package:remote_magic_git/features/history/history_view.dart';
import 'package:remote_magic_git/features/stash/stash_view.dart';
import 'package:remote_magic_git/features/worktrees/worktrees_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/fake_snapshot.dart';

const _repo = '/srv/repo';
const _compact = 600.0;
const _standard = 1000.0;
const _backKey = Key('workspace-compact-back');

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

class _FakeGit extends GitService with FakeRefsSnapshot {
  _FakeGit({this.commits = const []})
    : super(SSHCommandExecutor(SSHClientManager()));

  final List<GitCommit> commits;
  final List<String> stashApplies = [];
  String? merged;

  @override
  Future<List<GitCommit>> log(
    String repoPath, {
    String revision = 'HEAD',
    int maxCount = 200,
    int skip = 0,
    String? grep,
    String? author,
    String? since,
    String? until,
    String? path,
    String? pathQuery,
    String? sha,
    bool all = false,
    bool follow = false,
    bool noMerges = false,
    bool fullHistory = false,
  }) async => commits;

  @override
  Future<List<GitRef>> refs(String repoPath) async => const [];

  @override
  Future<String> showCommit(
    String repoPath,
    String hash, {
    String? path,
    int? context,
  }) async => 'diff --git a/x b/x\n@@ -1 +1 @@\n-a\n+b';

  @override
  Future<SSHCommandResult> stashApply(
    String repoPath,
    String oid, {
    bool restoreIndex = false,
  }) async {
    stashApplies.add(oid);
    return const SSHCommandResult(exitCode: 0, stdout: '', stderr: '');
  }

  @override
  Future<SSHCommandResult> merge(
    String repoPath,
    String branch, {
    MergeMode mode = MergeMode.normal,
    bool allowUnrelatedHistories = false,
  }) async {
    merged = branch;
    return const SSHCommandResult(exitCode: 0, stdout: '', stderr: '');
  }
}

class _QuietGlab extends GlabService {
  _QuietGlab() : super(SSHCommandExecutor(SSHClientManager()));
  int approveCalls = 0;

  @override
  Future<void> approveMergeRequest(String repoPath, int iid) async {
    approveCalls++;
  }
}

class _BrowseMode extends ForgeInboxMode {
  @override
  bool build() => false;
}

class _Connected extends ConnectionController {
  @override
  ConnectionState build() => const ConnectionState(
    phase: ConnectionPhase.connected,
    repoPath: _repo,
    sessionEpoch: 7,
  );
}

GitCommit _commit(String hash, String subject) => GitCommit(
  hash: hash,
  shortHash: hash.substring(0, 7),
  authorName: 'Dev',
  authorEmail: 'd@e',
  date: '2026-07-04T10:00',
  parents: const [],
  subject: subject,
);

final _head = _commit('aaaaaaa1111111', 'head commit');
final _older = _commit('bbbbbbb2222222', 'old commit');

const _oidA = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _oidB = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _stashes = [
  GitStash(
    index: 0,
    oid: _oidA,
    branch: 'main',
    message: 'WIP on main: abc1234 first',
    relativeDate: '2 hours ago',
  ),
  GitStash(
    index: 1,
    oid: _oidB,
    branch: 'feature',
    message: 'On feature: second',
    relativeDate: '3 days ago',
  ),
];

const _mr = MergeRequest(
  iid: 7,
  title: 'Add the parser',
  state: 'opened',
  authorUsername: 'alice',
  sourceBranch: 'feat',
  targetBranch: 'main',
  webUrl: '',
  draft: false,
  sha: 'abcdef0123456789abcdef0123456789abcdef01',
  detailedMergeStatus: 'mergeable',
  hasConflicts: false,
);

const _worktreeRepo = '/srv/app';
const _worktrees = [
  GitWorktree(
    path: _worktreeRepo,
    headOid: 'a',
    branch: 'refs/heads/main',
    isMain: true,
  ),
  GitWorktree(
    path: '/srv/app-feature',
    headOid: 'b',
    branch: 'refs/heads/feature',
  ),
];

// ---------------------------------------------------------------------------
// Observation helpers
// ---------------------------------------------------------------------------

Finder _region(WorkspacePaneRole role) =>
    find.byWidgetPredicate((w) => w is WorkspaceFocusRegion && w.role == role);

final _navigator = _region(WorkspacePaneRole.navigator);
final _canvas = _region(WorkspacePaneRole.canvas);

BuildContext? get _focusContext => FocusManager.instance.primaryFocus?.context;

String get _focusLabel {
  final node = FocusManager.instance.primaryFocus;
  return '${node?.debugLabel ?? node.runtimeType}';
}

bool get _focusUnderPanelShortcuts =>
    _focusContext?.findAncestorWidgetOfExactType<PanelShortcuts>() != null;

bool get _focusInNavigator =>
    _focusContext
        ?.findAncestorWidgetOfExactType<WorkspaceFocusRegion>()
        ?.role ==
    WorkspacePaneRole.navigator;

void _expectCanvasOnly() {
  expect(_canvas, findsOneWidget, reason: 'canvas must be shown');
  expect(
    _navigator,
    findsNothing,
    reason: 'compact shows one pane: the navigator must be gone',
  );
}

void _expectBothPanes() {
  expect(_navigator, findsOneWidget, reason: 'standard width: navigator');
  expect(_canvas, findsOneWidget, reason: 'standard width: canvas');
}

void _expectFocusUnderPanel() {
  expect(
    _focusUnderPanelShortcuts,
    isTrue,
    reason:
        'primary focus must sit inside the page PanelShortcuts so panel '
        'shortcuts can see key events (focus: $_focusLabel)',
  );
}

void _expectNavigatorFocused(String listLabel) {
  expect(_navigator, findsOneWidget, reason: 'navigator must be shown again');
  expect(
    FocusManager.instance.primaryFocus?.debugLabel,
    listLabel,
    reason: 'focus must return to the list node "$listLabel"',
  );
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.tap(finder);
  // Rows with a double-tap handler resolve a single tap only after the
  // double-tap window closes.
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pumpAndSettle();
}

Future<void> _press(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  bool meta = false,
  bool alt = false,
  bool shift = false,
}) async {
  if (meta) await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
  if (alt) await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
  if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyDownEvent(key);
  await tester.sendKeyUpEvent(key);
  if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  if (alt) await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
  if (meta) await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
  await tester.pumpAndSettle();
}

void _setSize(WidgetTester tester, double width, double height) {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<void> _host(
  WidgetTester tester,
  ProviderContainer container,
  double width,
  double height,
  Widget page,
) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MacosApp(
        debugShowCheckedModeBanner: false,
        home: SizedBox(width: width, height: height, child: page),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Captures what ⌘C puts on the clipboard.
class _Clipboard {
  String? text;

  void install(WidgetTester tester) {
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        text = (call.arguments as Map)['text'] as String?;
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
  }
}

// ---------------------------------------------------------------------------
// Page harnesses
// ---------------------------------------------------------------------------

Future<ProviderContainer> _pumpHistory(
  WidgetTester tester,
  double width,
) async {
  _setSize(tester, width, 700);
  final container = ProviderContainer(
    overrides: [
      gitServiceProvider.overrideWithValue(_FakeGit(commits: [_head, _older])),
      repoWatchProvider.overrideWith((ref, repoPath) => const Stream.empty()),
    ],
  );
  addTearDown(container.dispose);
  await _host(
    tester,
    container,
    width,
    700,
    const HistoryView(repoPath: _repo, isActive: true),
  );
  return container;
}

Finder get _headRow => find.text('head commit').first;

Future<_FakeGit> _pumpStash(WidgetTester tester, double width) async {
  _setSize(tester, width, 700);
  final git = _FakeGit();
  final container = ProviderContainer(
    overrides: [
      gitServiceProvider.overrideWithValue(git),
      stashesProvider(_repo).overrideWith((ref) async => _stashes),
      stashDiffProvider((_repo, _oidA)).overrideWith((ref) async => 'PATCH-A'),
      stashDiffProvider((_repo, _oidB)).overrideWith((ref) async => 'PATCH-B'),
    ],
  );
  addTearDown(container.dispose);
  await _host(tester, container, width, 700, const StashView(repoPath: _repo));
  return git;
}

Finder get _firstStash => find.text('first').first;

Future<_FakeGit> _pumpBranches(WidgetTester tester, double width) async {
  _setSize(tester, width, 900);
  final git = _FakeGit();
  final container = ProviderContainer(
    overrides: [
      gitServiceProvider.overrideWithValue(git),
      refsProvider(_repo).overrideWith(
        (ref) async => const [
          GitRef(name: 'refs/heads/main', oid: 'a', isHead: true, subject: 's'),
          GitRef(
            name: 'refs/heads/feature',
            oid: 'b',
            isHead: false,
            subject: 's',
          ),
        ],
      ),
      remotesProvider(_repo).overrideWith((ref) async => const ['origin']),
      remoteTagsProvider(_repo).overrideWith((ref) async => null),
      branchForgeProvider(_repo).overrideWith((ref) async => const {}),
      mergedBranchesProvider(
        _repo,
      ).overrideWith((ref) async => const <String>{}),
    ],
  );
  addTearDown(container.dispose);
  await _host(
    tester,
    container,
    width,
    900,
    const BranchesView(repoPath: _repo),
  );
  return git;
}

Finder get _featureBranch => find.text('feature').first;

Future<_QuietGlab> _pumpGitLab(WidgetTester tester, double width) async {
  _setSize(tester, width, 800);
  final glab = _QuietGlab();
  final container = ProviderContainer(
    overrides: [
      connectionProvider.overrideWith(_Connected.new),
      forgeInboxModeProvider.overrideWith(_BrowseMode.new),
      glabServiceProvider.overrideWithValue(glab),
      refsProvider(_repo).overrideWith(
        (ref) async => const [
          GitRef(
            name: 'refs/remotes/origin/main',
            oid: 'deadbeef',
            isHead: false,
            subject: '',
          ),
        ],
      ),
      remotesProvider(_repo).overrideWith((ref) async => const ['origin']),
      statusProvider(_repo).overrideWith(
        (ref) async => GitStatus(
          branch: const GitBranchInfo(head: 'main'),
          files: const [],
        ),
      ),
      mergeRequestsProvider(_repo).overrideWith((ref) async => const [_mr]),
      mergeRequestDetailProvider((_repo, 7)).overrideWith((ref) async => _mr),
      repoMergePolicyProvider(
        _repo,
      ).overrideWith((ref) async => const GlRepoMergePolicy()),
      pipelinesProvider(_repo).overrideWith((ref) async => const <Pipeline>[]),
      projectIssuesProvider(_repo).overrideWith((ref) async => const []),
      projectMilestonesProvider(_repo).overrideWith((ref) async => const []),
      projectDashboardProvider(
        _repo,
      ).overrideWith((ref) async => const ForgeProjectDashboard()),
      originRemoteUrlProvider(_repo).overrideWith((ref) async => null),
      changeRequestCommentsProvider((
        _repo,
        7,
      )).overrideWith((ref) async => const []),
    ],
  );
  addTearDown(container.dispose);
  await _host(
    tester,
    container,
    width,
    720,
    const GitLabPanel(repoPath: _repo),
  );
  return glab;
}

Finder get _mrRow => find.text('Add the parser').first;

Future<void> _pumpWorktrees(WidgetTester tester, double width) async {
  _setSize(tester, width, 700);
  final container = ProviderContainer(
    overrides: [
      gitWorktreesProvider(
        _worktreeRepo,
      ).overrideWith((ref) async => _worktrees),
    ],
  );
  addTearDown(container.dispose);
  await _host(
    tester,
    container,
    width,
    700,
    const WorktreesView(repoPath: _worktreeRepo),
  );
}

Finder get _featureWorktreeRow => find.text('app-feature');

/// The selected overview row is tinted (worktrees_view.dart `_row`).
bool get _featureWorktreeTinted => find
    .ancestor(
      of: _featureWorktreeRow,
      matching: find.byWidgetPredicate(
        (w) =>
            w is Container &&
            w.color == MacosColors.systemBlueColor.withValues(alpha: 0.08),
      ),
    )
    .evaluate()
    .isNotEmpty;

void _expectBackBar(String label) {
  expect(find.byKey(_backKey), findsOneWidget, reason: 'back bar button');
  expect(
    find.descendant(of: find.byKey(_backKey), matching: find.text('‹ $label')),
    findsOneWidget,
    reason: 'back bar reads "‹ $label"',
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('compact (600 px)', () {
    group('History', () {
      testWidgets('1. tapping a row shows the canvas with focus in the panel', (
        tester,
      ) async {
        await _pumpHistory(tester, _compact);
        expect(_navigator, findsOneWidget);
        await _tap(tester, _headRow);
        _expectCanvasOnly();
        _expectFocusUnderPanel();
        _expectBackBar('Commits');
      });

      testWidgets('2. Esc returns to the list, focused, selection kept', (
        tester,
      ) async {
        final clipboard = _Clipboard()..install(tester);
        await _pumpHistory(tester, _compact);
        await _tap(tester, _headRow);
        _expectCanvasOnly();
        await _press(tester, LogicalKeyboardKey.escape);
        _expectNavigatorFocused('commit-list');
        // The selection survived Back: ⌘C copies the commit that was open.
        await _press(tester, LogicalKeyboardKey.keyC, meta: true);
        expect(clipboard.text, _head.hash, reason: 'selection kept');
        await _tap(tester, _headRow);
        _expectCanvasOnly();
      });

      testWidgets('3. ⌘[ returns to the list', (tester) async {
        await _pumpHistory(tester, _compact);
        await _tap(tester, _headRow);
        _expectCanvasOnly();
        await _press(tester, LogicalKeyboardKey.bracketLeft, meta: true);
        _expectNavigatorFocused('commit-list');
      });

      testWidgets('4. the back bar returns to the list', (tester) async {
        await _pumpHistory(tester, _compact);
        await _tap(tester, _headRow);
        _expectCanvasOnly();
        await _tap(tester, find.byKey(_backKey));
        _expectNavigatorFocused('commit-list');
        await _tap(tester, _headRow);
        _expectCanvasOnly();
      });

      testWidgets('5. ⌘= zooms the commit list from the canvas', (
        tester,
      ) async {
        final container = await _pumpHistory(tester, _compact);
        await _tap(tester, _headRow);
        _expectCanvasOnly();
        final before = container.read(appSettingsProvider).historyZoom;
        await _press(tester, LogicalKeyboardKey.equal, meta: true);
        expect(
          container.read(appSettingsProvider).historyZoom,
          greaterThan(before),
          reason: '⌘= must reach History PanelShortcuts (focus: $_focusLabel)',
        );
      });

      testWidgets(
        '8. ↓ in the list moves the selection and stays in the list',
        (tester) async {
          final clipboard = _Clipboard()..install(tester);
          await _pumpHistory(tester, _compact);
          await _tap(tester, _headRow);
          await _press(tester, LogicalKeyboardKey.escape);
          _expectNavigatorFocused('commit-list');
          await _press(tester, LogicalKeyboardKey.arrowDown);
          expect(
            _navigator,
            findsOneWidget,
            reason: 'arrow keys change selection without switching panes',
          );
          await _press(tester, LogicalKeyboardKey.keyC, meta: true);
          expect(
            clipboard.text,
            _older.hash,
            reason: '↓ selected the next row',
          );
        },
      );
    });

    group('Stashes', () {
      testWidgets('1. tapping a row shows the canvas with focus in the panel', (
        tester,
      ) async {
        await _pumpStash(tester, _compact);
        expect(_navigator, findsOneWidget);
        await _tap(tester, _firstStash);
        _expectCanvasOnly();
        expect(find.text('PATCH-A'), findsOneWidget);
        _expectFocusUnderPanel();
        _expectBackBar('Stashes');
      });

      testWidgets('2. Esc returns to the list, focused, selection kept', (
        tester,
      ) async {
        final git = await _pumpStash(tester, _compact);
        await _tap(tester, _firstStash);
        _expectCanvasOnly();
        await _press(tester, LogicalKeyboardKey.escape);
        _expectNavigatorFocused('stash-list');
        // ⌥⌘A applies the selected stash — by the OID that was open.
        await _press(tester, LogicalKeyboardKey.keyA, meta: true, alt: true);
        expect(git.stashApplies, [_oidA], reason: 'selection kept');
        await _tap(tester, _firstStash);
        _expectCanvasOnly();
      });

      testWidgets('3. ⌘[ returns to the list', (tester) async {
        await _pumpStash(tester, _compact);
        await _tap(tester, _firstStash);
        _expectCanvasOnly();
        await _press(tester, LogicalKeyboardKey.bracketLeft, meta: true);
        _expectNavigatorFocused('stash-list');
      });

      testWidgets('4. the back bar returns to the list', (tester) async {
        await _pumpStash(tester, _compact);
        await _tap(tester, _firstStash);
        _expectCanvasOnly();
        await _tap(tester, find.byKey(_backKey));
        _expectNavigatorFocused('stash-list');
        await _tap(tester, _firstStash);
        _expectCanvasOnly();
      });
    });

    group('Branches', () {
      testWidgets('1. tapping a row shows the canvas with focus in the panel', (
        tester,
      ) async {
        await _pumpBranches(tester, _compact);
        expect(_navigator, findsOneWidget);
        await _tap(tester, _featureBranch);
        _expectCanvasOnly();
        _expectFocusUnderPanel();
        _expectBackBar('Branches');
      });

      testWidgets('2. Esc returns to the list, focused, selection kept', (
        tester,
      ) async {
        final git = await _pumpBranches(tester, _compact);
        await _tap(tester, _featureBranch);
        _expectCanvasOnly();
        await _press(tester, LogicalKeyboardKey.escape);
        _expectNavigatorFocused('branch-list');
        // ⌘⇧M merges the selected branch — the one that was open.
        await _press(tester, LogicalKeyboardKey.keyM, meta: true, shift: true);
        await _tap(tester, find.text('Merge'));
        expect(git.merged, 'feature', reason: 'selection kept');
      });

      testWidgets('3. ⌘[ returns to the list', (tester) async {
        await _pumpBranches(tester, _compact);
        await _tap(tester, _featureBranch);
        _expectCanvasOnly();
        await _press(tester, LogicalKeyboardKey.bracketLeft, meta: true);
        _expectNavigatorFocused('branch-list');
      });

      testWidgets('4. the back bar returns to the list', (tester) async {
        await _pumpBranches(tester, _compact);
        await _tap(tester, _featureBranch);
        _expectCanvasOnly();
        await _tap(tester, find.byKey(_backKey));
        _expectNavigatorFocused('branch-list');
        await _tap(tester, _featureBranch);
        _expectCanvasOnly();
      });

      testWidgets(
        '6. the panel keeps exactly one PanelShortcuts in the canvas',
        (tester) async {
          await _pumpBranches(tester, _compact);
          await _tap(tester, _featureBranch);
          _expectCanvasOnly();
          expect(find.byType(PanelShortcuts), findsOneWidget);
        },
      );
    });

    // GitLab rather than GitHub: its harness is already proven by
    // gitlab_panel_test.dart, and approve (⌥⌘A) opens a confirm naming the
    // selected MR's iid, which observes the selection without any mutation.
    group('Forge (GitLab)', () {
      testWidgets('1. tapping a row shows the canvas with focus in the panel', (
        tester,
      ) async {
        await _pumpGitLab(tester, _compact);
        expect(_navigator, findsOneWidget);
        await _tap(tester, _mrRow);
        _expectCanvasOnly();
        _expectFocusUnderPanel();
        _expectBackBar('Items');
      });

      testWidgets('2. Esc returns to the list, focused, selection kept', (
        tester,
      ) async {
        final glab = await _pumpGitLab(tester, _compact);
        await _tap(tester, _mrRow);
        _expectCanvasOnly();
        await _press(tester, LogicalKeyboardKey.escape);
        expect(_navigator, findsOneWidget, reason: 'navigator shown again');
        // Forge has no list node today; the contract is focus inside the
        // navigator and inside the panel's PanelShortcuts.
        expect(_focusInNavigator, isTrue, reason: 'focus: $_focusLabel');
        _expectFocusUnderPanel();
        await _press(tester, LogicalKeyboardKey.keyA, meta: true, alt: true);
        expect(
          find.text('Approve !7 on the remote GitLab project?'),
          findsOneWidget,
          reason: 'selection kept: approve targets the MR that was open',
        );
        await _tap(tester, find.text('Cancel'));
        expect(glab.approveCalls, 0);
        await _tap(tester, _mrRow);
        _expectCanvasOnly();
      });

      testWidgets('3. ⌘[ returns to the list', (tester) async {
        await _pumpGitLab(tester, _compact);
        await _tap(tester, _mrRow);
        _expectCanvasOnly();
        await _press(tester, LogicalKeyboardKey.bracketLeft, meta: true);
        expect(_navigator, findsOneWidget, reason: 'navigator shown again');
        expect(_focusInNavigator, isTrue, reason: 'focus: $_focusLabel');
      });

      testWidgets('4. the back bar returns to the list', (tester) async {
        await _pumpGitLab(tester, _compact);
        await _tap(tester, _mrRow);
        _expectCanvasOnly();
        await _tap(tester, find.byKey(_backKey));
        expect(_navigator, findsOneWidget, reason: 'navigator shown again');
        expect(_focusInNavigator, isTrue, reason: 'focus: $_focusLabel');
        await _tap(tester, _mrRow);
        _expectCanvasOnly();
      });
    });

    group('Worktrees', () {
      testWidgets('7. with no selection the list rows are visible', (
        tester,
      ) async {
        await _pumpWorktrees(tester, _compact);
        expect(_navigator, findsOneWidget, reason: 'the list must be shown');
        expect(_featureWorktreeRow, findsOneWidget);
      });

      testWidgets('1. tapping a row shows the canvas with focus in the panel', (
        tester,
      ) async {
        await _pumpWorktrees(tester, _compact);
        expect(
          _featureWorktreeRow,
          findsOneWidget,
          reason: 'the list must be reachable before a row can be tapped',
        );
        await _tap(tester, _featureWorktreeRow);
        _expectCanvasOnly();
        expect(find.text('Worktree: app-feature'), findsOneWidget);
        _expectFocusUnderPanel();
        _expectBackBar('Worktrees');
      });

      testWidgets('2. Esc returns to the list, focused, selection kept', (
        tester,
      ) async {
        await _pumpWorktrees(tester, _compact);
        expect(_featureWorktreeRow, findsOneWidget, reason: 'list reachable');
        await _tap(tester, _featureWorktreeRow);
        _expectCanvasOnly();
        await _press(tester, LogicalKeyboardKey.escape);
        _expectNavigatorFocused('worktree-overview');
        expect(_featureWorktreeTinted, isTrue, reason: 'selection kept');
        await _tap(tester, _featureWorktreeRow);
        _expectCanvasOnly();
      });

      testWidgets('3. ⌘[ returns to the list', (tester) async {
        await _pumpWorktrees(tester, _compact);
        expect(_featureWorktreeRow, findsOneWidget, reason: 'list reachable');
        await _tap(tester, _featureWorktreeRow);
        _expectCanvasOnly();
        await _press(tester, LogicalKeyboardKey.bracketLeft, meta: true);
        _expectNavigatorFocused('worktree-overview');
      });

      testWidgets('4. the back bar returns to the list', (tester) async {
        await _pumpWorktrees(tester, _compact);
        expect(_featureWorktreeRow, findsOneWidget, reason: 'list reachable');
        await _tap(tester, _featureWorktreeRow);
        _expectCanvasOnly();
        await _tap(tester, find.byKey(_backKey));
        _expectNavigatorFocused('worktree-overview');
        await _tap(tester, _featureWorktreeRow);
        _expectCanvasOnly();
      });
    });
  });

  group('control (1000 px, standard)', () {
    testWidgets('History 1. tap keeps both panes, focus in the panel', (
      tester,
    ) async {
      await _pumpHistory(tester, _standard);
      await _tap(tester, _headRow);
      _expectBothPanes();
      _expectFocusUnderPanel();
      expect(find.byKey(_backKey), findsNothing, reason: 'no back bar');
    });

    testWidgets('History 5. ⌘= zooms the commit list', (tester) async {
      final container = await _pumpHistory(tester, _standard);
      await _tap(tester, _headRow);
      final before = container.read(appSettingsProvider).historyZoom;
      await _press(tester, LogicalKeyboardKey.equal, meta: true);
      expect(
        container.read(appSettingsProvider).historyZoom,
        greaterThan(before),
      );
    });

    testWidgets('Stashes 1. tap keeps both panes, focus in the panel', (
      tester,
    ) async {
      await _pumpStash(tester, _standard);
      await _tap(tester, _firstStash);
      _expectBothPanes();
      expect(find.text('PATCH-A'), findsOneWidget);
      _expectFocusUnderPanel();
    });

    testWidgets('Branches 1. tap keeps both panes, focus in the panel', (
      tester,
    ) async {
      await _pumpBranches(tester, _standard);
      await _tap(tester, _featureBranch);
      _expectBothPanes();
      _expectFocusUnderPanel();
    });

    testWidgets('Branches 6. exactly one PanelShortcuts', (tester) async {
      await _pumpBranches(tester, _standard);
      await _tap(tester, _featureBranch);
      expect(find.byType(PanelShortcuts), findsOneWidget);
    });

    // Panes only: after a mouse click Forge focus stays outside the panel at
    // every width (MADR 0064 "Forge shortcuts after a mouse click", out of
    // F1's scope), so a focus assertion here would not be a passing control.
    testWidgets('Forge 1. tap keeps both panes', (tester) async {
      await _pumpGitLab(tester, _standard);
      await _tap(tester, _mrRow);
      _expectBothPanes();
    });

    testWidgets('Worktrees 1. tap keeps both panes, focus in the panel', (
      tester,
    ) async {
      await _pumpWorktrees(tester, _standard);
      expect(_featureWorktreeRow, findsOneWidget);
      await _tap(tester, _featureWorktreeRow);
      _expectBothPanes();
      expect(find.text('Worktree: app-feature'), findsOneWidget);
      _expectFocusUnderPanel();
    });
  });
}
```

Phase 5: `test/compact_workspace_navigation_test.dart`.

### A.13 `F1.diff`

```diff
diff --git a/lib/features/branches/branch_navigator.dart b/lib/features/branches/branch_navigator.dart
index 702065a..ce86b36 100644
--- a/lib/features/branches/branch_navigator.dart
+++ b/lib/features/branches/branch_navigator.dart
@@ -14,7 +14,6 @@ import '../../core/git/branch_review_query.dart';
 import '../../core/git/branch_sync_state.dart';
 import '../../core/git/git_service.dart';
 import '../../core/providers/app_providers.dart';
-import '../../core/settings/keymap.dart';
 import '../../core/theme/app_theme.dart';
 import '../common/chip_strip.dart';
 import '../common/context_menu.dart';
@@ -49,6 +48,76 @@ String remoteLocalName(String remoteShortName) => remoteShortName.contains('/')
 /// The three-way outcome of deleting a tag that also exists on the remote.
 enum TagDeleteScope { local, both, cancel }
 
+/// The Branches panel's action-id → handler map: one map for the keyboard
+/// shortcuts, the command palette's dispatched intents and the menu bar (see
+/// `PanelShortcuts.handlers`).
+///
+/// Built by `BranchesView`, above the workspace scaffold, so it survives the
+/// navigator being unmounted at the compact size class (MADR 0064 F1-A). It
+/// used to live inside [BranchNavigator], and went dead with it.
+///
+/// [selectedRef] is the view's selected ref name, which the navigator's
+/// keyboard cursor always mirrors. Preconditions mirror branch_detail's
+/// primary/secondary gates, so a remapped key never does something the UI
+/// would leave disabled; merge/delete need a non-current LOCAL branch (merging
+/// or deleting the branch you're on is nonsensical / rejected by git).
+Map<String, VoidCallback?> branchPanelHandlers({
+  required GitService git,
+  required BranchViewModel vm,
+  required String? selectedRef,
+  required List<String> remotes,
+  required bool busy,
+  required void Function(GitService) onCreateBranch,
+  required void Function() onOpenCreateTagSheet,
+  required void Function(GitService, GitRef, MergeMode) onMerge,
+  required void Function(GitService, String) onDeleteBranch,
+  void Function(GitService, GitRef)? onPublish,
+  void Function(GitRef)? onCreateRequest,
+  void Function(String?)? onOpenUrl,
+  VoidCallback? onCompare,
+}) {
+  final local = selectedRef == null
+      ? null
+      : vm.localsOnScreen.where((b) => b.name == selectedRef).firstOrNull;
+  final canActOnSelection = local != null && !local.isHead;
+  final unpublished = local != null && local.upstream == null;
+  final bf = local == null ? null : vm.forge[local.shortName];
+  final hasRequest = bf != null && bf.hasRequest;
+  final canPublish =
+      local != null &&
+      unpublished &&
+      remotes.isNotEmpty &&
+      onPublish != null &&
+      !busy;
+  final canCreateRequest =
+      local != null &&
+      !unpublished &&
+      !hasRequest &&
+      onCreateRequest != null &&
+      !busy;
+  final ciUrl = bf?.ciUrl;
+  return <String, VoidCallback?>{
+    'branches.newBranch': () => onCreateBranch(git),
+    'branches.createTag': onOpenCreateTagSheet,
+    // Only bound with a non-current branch selected — otherwise they fall
+    // through, matching the rest of the app's precondition gates.
+    'branches.merge': canActOnSelection
+        ? () => onMerge(git, local, MergeMode.normal)
+        : null,
+    'branches.delete': canActOnSelection
+        ? () => onDeleteBranch(git, local.shortName)
+        : null,
+    'branches.publish': canPublish ? () => onPublish(git, local) : null,
+    'branches.createRequest': canCreateRequest
+        ? () => onCreateRequest(local)
+        : null,
+    'branches.openCi': ciUrl != null && onOpenUrl != null
+        ? () => onOpenUrl(ciUrl)
+        : null,
+    'branches.compare': local != null && onCompare != null ? onCompare : null,
+  };
+}
+
 /// The choice offered when a branch is dropped onto the current branch's row.
 enum DropOp { merge, rebase, cancel }
 
@@ -298,12 +367,9 @@ class BranchNavigator extends ConsumerStatefulWidget {
   })
   onDropCommitOnBranch;
 
-  /// Publish / create-request / open CI / compare — same actions as the detail
-  /// pane, so keymap + palette handlers stay in lockstep with the buttons.
-  final void Function(GitService, GitRef)? onPublish;
-  final void Function(GitRef)? onCreateRequest;
-  final void Function(String?)? onOpenUrl;
-  final VoidCallback? onCompare;
+  /// A row was clicked (not merely selected by ↑/↓): at the compact size
+  /// class this opens the detail pane (MADR 0064 F1-A).
+  final VoidCallback? onOpen;
 
   /// Called when the filter text changes so the coordinator can rebuild the
   /// view model with the new filter.
@@ -374,10 +440,7 @@ class BranchNavigator extends ConsumerStatefulWidget {
     required this.onPushAllLocalOnly,
     required this.onDropOnCurrent,
     required this.onDropCommitOnBranch,
-    this.onPublish,
-    this.onCreateRequest,
-    this.onOpenUrl,
-    this.onCompare,
+    this.onOpen,
     required this.onFilterChanged,
     required this.onModeChanged,
     required this.onBaseChanged,
@@ -440,13 +503,6 @@ class _BranchNavigatorState extends ConsumerState<BranchNavigator> {
     return null;
   }
 
-  // A non-current LOCAL branch is selected — merge/delete apply (merging or
-  // deleting the branch you're on is nonsensical / rejected by git).
-  bool get _canActOnSelection {
-    final sel = _selectedLocal;
-    return sel != null && !sel.isHead;
-  }
-
   void _select(GitRef refEntry, {bool command = false, bool shift = false}) {
     _selectionCursor = refEntry.name;
     widget.focusNode.requestFocus();
@@ -685,6 +741,7 @@ class _BranchNavigatorState extends ConsumerState<BranchNavigator> {
         HardwareKeyboard.instance.isControlPressed;
     final shift = HardwareKeyboard.instance.isShiftPressed;
     _select(branch, command: command, shift: shift);
+    widget.onOpen?.call();
     if (isDouble &&
         !branch.isHead &&
         branch.elsewhereWorktreePath == null &&
@@ -764,88 +821,34 @@ class _BranchNavigatorState extends ConsumerState<BranchNavigator> {
   @override
   Widget build(BuildContext context) {
     final git = ref.read(gitServiceProvider);
-    final keymap = ref.watch(keymapProvider);
-
-    // One handler map for both consumers: the keyboard shortcuts and the
-    // command palette's dispatched intents (see PanelShortcuts.handlers).
-    // Preconditions mirror branch_detail primary/secondary gates so a
-    // remapped key never does something the UI would leave disabled.
-    final local = _selectedLocal;
-    final remotes =
-        ref.watch(remotesProvider(widget.repoPath)).value ?? const <String>[];
-    final unpublished = local != null && local.upstream == null;
-    final bf = local == null ? null : widget.vm.forge[local.shortName];
-    final hasRequest = bf != null && bf.hasRequest;
-    final canPublish =
-        local != null &&
-        unpublished &&
-        remotes.isNotEmpty &&
-        widget.onPublish != null &&
-        !widget.busy;
-    final canCreateRequest =
-        local != null &&
-        !unpublished &&
-        !hasRequest &&
-        widget.onCreateRequest != null &&
-        !widget.busy;
-    final ciUrl = bf?.ciUrl;
-    final handlers = <String, VoidCallback?>{
-      'branches.newBranch': () => widget.onCreateBranch(git),
-      'branches.createTag': widget.onOpenCreateTagSheet,
-      // Only bound with a non-current branch selected — otherwise they
-      // fall through, matching the rest of the app's precondition gates.
-      'branches.merge': _canActOnSelection
-          ? () => widget.onMerge(git, _selectedLocal!, MergeMode.normal)
-          : null,
-      'branches.delete': _canActOnSelection
-          ? () => widget.onDeleteBranch(git, _selectedLocal!.shortName)
-          : null,
-      'branches.publish': canPublish
-          ? () => widget.onPublish!(git, local)
-          : null,
-      'branches.createRequest': canCreateRequest
-          ? () => widget.onCreateRequest!(local)
-          : null,
-      'branches.openCi': ciUrl != null && widget.onOpenUrl != null
-          ? () => widget.onOpenUrl!(ciUrl)
-          : null,
-      'branches.compare': local != null && widget.onCompare != null
-          ? widget.onCompare
-          : null,
-    };
-
     final rows = _buildRows(widget.vm);
 
-    return PanelShortcuts(
-      bindings: widget.isActive
-          ? resolveShortcuts(keymap, handlers)
-          : const <ShortcutActivator, VoidCallback>{},
-      handlers: widget.isActive ? handlers : const {},
-      child: Focus(
-        focusNode: widget.focusNode,
-        onKeyEvent: _onBranchKey,
-        child: Column(
-          children: [
-            _toolbar(git),
-            Expanded(
-              child: DeselectOnEmptyClick(
-                onDeselect: () => widget.onSelect(null),
-                child: ListView.builder(
-                  controller: widget.scrollController,
-                  itemCount: rows.length,
-                  itemBuilder: (context, i) => _buildRow(
-                    context,
-                    git,
-                    rows[i],
-                    remoteTags: widget.vm.remoteTags,
-                    tagRemote: widget.vm.tagRemote,
-                    localOnly: widget.vm.localOnlyTags,
-                  ),
+    // The panel's shortcut/palette handlers and their PanelShortcuts live in
+    // BranchesView, above the scaffold (branchPanelHandlers, MADR 0064 F1-A).
+    return Focus(
+      focusNode: widget.focusNode,
+      onKeyEvent: _onBranchKey,
+      child: Column(
+        children: [
+          _toolbar(git),
+          Expanded(
+            child: DeselectOnEmptyClick(
+              onDeselect: () => widget.onSelect(null),
+              child: ListView.builder(
+                controller: widget.scrollController,
+                itemCount: rows.length,
+                itemBuilder: (context, i) => _buildRow(
+                  context,
+                  git,
+                  rows[i],
+                  remoteTags: widget.vm.remoteTags,
+                  tagRemote: widget.vm.tagRemote,
+                  localOnly: widget.vm.localOnlyTags,
                 ),
               ),
             ),
-          ],
-        ),
+          ),
+        ],
       ),
     );
   }
@@ -1912,7 +1915,10 @@ class _BranchNavigatorState extends ConsumerState<BranchNavigator> {
         key: _rowKeyFor(branch.name),
         child: Tappable(
           behavior: HitTestBehavior.opaque,
-          onTap: () => _select(branch),
+          onTap: () {
+            _select(branch);
+            widget.onOpen?.call();
+          },
           onSecondaryTapUp: (d) => _menu.show(
             context,
             d.globalPosition,
@@ -1963,7 +1969,10 @@ class _BranchNavigatorState extends ConsumerState<BranchNavigator> {
       key: _rowKeyFor(tag.name),
       child: Tappable(
         behavior: HitTestBehavior.opaque,
-        onTap: () => _select(tag),
+        onTap: () {
+          _select(tag);
+          widget.onOpen?.call();
+        },
         onSecondaryTapUp: (d) => _menu.show(
           context,
           d.globalPosition,
diff --git a/lib/features/branches/branches_view.dart b/lib/features/branches/branches_view.dart
index acb3c75..f9f7c50 100644
--- a/lib/features/branches/branches_view.dart
+++ b/lib/features/branches/branches_view.dart
@@ -15,6 +15,7 @@ import '../../core/git/git_service.dart';
 import '../../core/output/output_log.dart';
 import '../../core/providers/app_providers.dart';
 import '../../core/settings/app_settings.dart';
+import '../../core/settings/keymap.dart';
 import '../../core/settings/repository_workspace_prefs.dart';
 import '../../core/ssh/ssh_command_executor.dart';
 import '../../core/utils/display_error.dart';
@@ -23,6 +24,7 @@ import '../common/adaptive_workspace_layout.dart';
 import '../common/branch_switch.dart';
 import '../common/busy_action.dart';
 import '../common/inline_action_button.dart';
+import '../common/panel_shortcuts.dart';
 import '../common/pending_op_banner.dart';
 import '../common/prompt_form_sheet.dart';
 import '../common/prompt_text_sheet.dart';
@@ -43,7 +45,12 @@ import '../worktrees/worktree_tabs.dart';
 import 'branch_bulk_delete_sheet.dart';
 import 'branch_detail.dart' show BranchDetail, TagRemoteStatus;
 import 'branch_navigator.dart'
-    show BranchNavigator, DropOp, TagDeleteScope, remoteLocalName;
+    show
+        BranchNavigator,
+        DropOp,
+        TagDeleteScope,
+        branchPanelHandlers,
+        remoteLocalName;
 import 'branch_view_model.dart';
 import 'branch_workspace_prefs.dart';
 import 'create_tag_sheet.dart';
@@ -129,6 +136,12 @@ class _BranchesViewState extends ConsumerState<BranchesView>
 
   final _filterCtl = TextEditingController();
   final FocusNode _branchFocus = FocusNode(debugLabel: 'branch-list');
+
+  // Compact width shows the list OR the detail (MADR 0064 F1-A): a row click
+  // opens the detail, Back closes it and keeps the selection, and ↑/↓ move
+  // the selection without flipping panes. (Enter keeps checking out the
+  // selected branch, as it always has.)
+  bool _compactShowCanvas = false;
   final ScrollController _branchScroll = ScrollController();
 
   String get repoPath => widget.repoPath;
@@ -291,7 +304,10 @@ class _BranchesViewState extends ConsumerState<BranchesView>
           markWorkspaceLocationUnavailable(ref, location);
           return;
         }
-        setState(() => _selectedRef = match.name);
+        setState(() {
+          _selectedRef = match.name;
+          _compactShowCanvas = true;
+        });
       });
     }
 
@@ -447,6 +463,15 @@ class _BranchesViewState extends ConsumerState<BranchesView>
       });
     }
 
+    // A cleared selection closes the compact detail with it.
+    if (selectedRef == null) _compactShowCanvas = false;
+    void onCompare() {
+      // Surface the base-relative comparison: Review mode + keep selection.
+      if (mode != BranchWorkspaceMode.review) {
+        _setMode(BranchWorkspaceMode.review);
+      }
+    }
+
     final navigator = BranchNavigator(
       repoPath: repoPath,
       vm: vm,
@@ -528,15 +553,7 @@ class _BranchesViewState extends ConsumerState<BranchesView>
       onPushAllLocalOnly: _pushAllLocalOnly,
       onDropOnCurrent: _dropOnCurrent,
       onDropCommitOnBranch: _dropCommitOnBranch,
-      onPublish: _publishBranch,
-      onCreateRequest: _createRequest,
-      onOpenUrl: _open,
-      onCompare: () {
-        // Surface the base-relative comparison: Review mode + keep selection.
-        if (mode != BranchWorkspaceMode.review) {
-          _setMode(BranchWorkspaceMode.review);
-        }
-      },
+      onOpen: () => setState(() => _compactShowCanvas = true),
       onFilterChanged: (_) => setState(() {}),
       onModeChanged: _setMode,
       onBaseChanged: _setBase,
@@ -629,28 +646,58 @@ class _BranchesViewState extends ConsumerState<BranchesView>
       ),
       navigator: navigator,
       canvas: detail,
-      activePage: selectedRef == null
-          ? CompactWorkspacePage.navigator
-          : CompactWorkspacePage.canvas,
+      compactNavigation: CompactWorkspaceNavigation(
+        navigatorLabel: 'Branches',
+        hasSelection: selectedRef != null,
+        showCanvas: _compactShowCanvas,
+        onShowNavigator: () => setState(() => _compactShowCanvas = false),
+        navigatorFocusNode: _branchFocus,
+      ),
       preferences: workspace.preferences,
       onPreferencesChanged: workspace.onChanged,
       workspaceOptionsEnabled: true,
     );
+    // The panel's handlers live here, above the scaffold, where the other
+    // panels keep theirs: inside the navigator they unmounted with the list
+    // at the compact size class, taking every Branch shortcut and menu item
+    // with them (MADR 0064 F1-A).
+    final handlers = branchPanelHandlers(
+      git: git,
+      vm: vm,
+      selectedRef: _selectedRef,
+      remotes: remotesList ?? const <String>[],
+      busy: busy,
+      onCreateBranch: _createBranchPrompt,
+      onOpenCreateTagSheet: _openCreateTagSheet,
+      onMerge: (g, b, mode) => _mergeBranch(g, b.shortName, mode),
+      onDeleteBranch: (g, branch) => _deleteBranch(vm, g, branch),
+      onPublish: _publishBranch,
+      onCreateRequest: _createRequest,
+      onOpenUrl: _open,
+      onCompare: onCompare,
+    );
     // Repo-wide, not per row: mid-rebase HEAD is detached and no branch row
     // is current. Above the scaffold rather than in its context slot, which
     // a worktree tab (where a rebase is as likely) does not render.
     final pending = ref.watch(pendingOpProvider(repoPath)).value;
-    if (pending == null || pending == PendingOp.none) return scaffold;
-    return Column(
-      crossAxisAlignment: CrossAxisAlignment.stretch,
-      children: [
-        PendingOpBanner(
-          op: pending,
-          onContinue: () => _continuePending(pending),
-          onAbort: () => _abortPending(pending),
-        ),
-        Expanded(child: scaffold),
-      ],
+    return PanelShortcuts(
+      bindings: widget.isActive
+          ? resolveShortcuts(ref.watch(keymapProvider), handlers)
+          : const <ShortcutActivator, VoidCallback>{},
+      handlers: widget.isActive ? handlers : const {},
+      child: pending == null || pending == PendingOp.none
+          ? scaffold
+          : Column(
+              crossAxisAlignment: CrossAxisAlignment.stretch,
+              children: [
+                PendingOpBanner(
+                  op: pending,
+                  onContinue: () => _continuePending(pending),
+                  onAbort: () => _abortPending(pending),
+                ),
+                Expanded(child: scaffold),
+              ],
+            ),
     );
   }
 
diff --git a/lib/features/common/adaptive_workspace_layout.dart b/lib/features/common/adaptive_workspace_layout.dart
index 0b19d27..430ebff 100644
--- a/lib/features/common/adaptive_workspace_layout.dart
+++ b/lib/features/common/adaptive_workspace_layout.dart
@@ -1,12 +1,55 @@
-import 'package:flutter/widgets.dart';
+import 'package:flutter/cupertino.dart';
+import 'package:flutter/services.dart';
+import 'package:macos_ui/macos_ui.dart';
 
 import '../../core/settings/repository_workspace_prefs.dart';
+import 'inline_action_button.dart';
 import 'repository_workspace_models.dart';
 import 'resizable_master_detail.dart';
 import 'workspace_focus_order.dart';
 
 enum CompactWorkspacePage { navigator, canvas }
 
+/// A page's side of compact navigation (MADR 0064 F1-A).
+///
+/// At the compact size class the layout shows one pane at a time. The page
+/// owns [showCanvas] — a row tap sets it, as does plain Enter where the list
+/// has no other use for Enter (Branches keeps Enter = check out); Back (the
+/// back bar, Esc or ⌘[) clears it through [onShowNavigator] — and the
+/// selection itself survives Back, as a collapsed split view does. The canvas
+/// is shown only when [hasSelection] && [showCanvas]; arrow keys that move the
+/// selection inside the list must leave [showCanvas] alone, so browsing the
+/// list never flips the pane.
+@immutable
+class CompactWorkspaceNavigation {
+  /// Names the list on the back bar: "‹ [navigatorLabel]".
+  final String navigatorLabel;
+  final bool hasSelection;
+  final bool showCanvas;
+
+  /// Back: clears the page's [showCanvas] so the list shows again. Named
+  /// apart from the context bar's Back/Forward, which navigate the session's
+  /// history and stay owned by the bar. The selection must be kept.
+  final VoidCallback onShowNavigator;
+
+  /// The list's own focus node, which receives focus on Back. When null the
+  /// layout focuses a non-text node of its own inside the navigator region.
+  final FocusNode? navigatorFocusNode;
+
+  const CompactWorkspaceNavigation({
+    required this.navigatorLabel,
+    required this.hasSelection,
+    required this.showCanvas,
+    required this.onShowNavigator,
+    this.navigatorFocusNode,
+  });
+
+  bool get wantsCanvas => hasSelection && showCanvas;
+}
+
+/// The back bar's button, for tests and for the pane-reachability contract.
+const Key kWorkspaceCompactBackKey = Key('workspace-compact-back');
+
 enum WorkspaceTaskDockPresentation { hidden, compact, full }
 
 @immutable
@@ -76,6 +119,10 @@ class AdaptiveWorkspaceLayout extends StatefulWidget {
   final Widget? inspector;
   final Widget? taskDock;
   final CompactWorkspacePage compactPage;
+
+  /// When set, compact navigation is scaffold-owned (F1-A) and [compactPage]
+  /// is ignored. Callers without it keep the legacy [compactPage] behaviour.
+  final CompactWorkspaceNavigation? compactNavigation;
   final bool inspectorVisible;
   final bool taskDockFocused;
   final RepositoryWorkspacePrefs preferences;
@@ -88,6 +135,7 @@ class AdaptiveWorkspaceLayout extends StatefulWidget {
     this.inspector,
     this.taskDock,
     this.compactPage = CompactWorkspacePage.canvas,
+    this.compactNavigation,
     this.inspectorVisible = false,
     this.taskDockFocused = false,
     this.preferences = const RepositoryWorkspacePrefs(),
@@ -104,6 +152,34 @@ class _AdaptiveWorkspaceLayoutState extends State<AdaptiveWorkspaceLayout> {
   late double _inspectorWidth = widget.preferences.inspectorWidth;
   late double _taskDockHeight = widget.preferences.taskDockHeight;
 
+  /// Holds focus for the canvas at the compact size class. It sits below the
+  /// page's PanelShortcuts, so panel shortcuts keep working once the list —
+  /// and the list's own focus node — has been unmounted.
+  final FocusNode _compactCanvasFocus = FocusNode(
+    debugLabel: 'workspace-compact-canvas',
+    skipTraversal: true,
+  );
+
+  /// Receives focus on Back when the page supplies no list focus node.
+  final FocusNode _compactNavigatorFocus = FocusNode(
+    debugLabel: 'workspace-compact-navigator',
+    skipTraversal: true,
+  );
+
+  /// The compact pane shown by the previous build; null outside compact.
+  CompactWorkspacePage? _lastCompactPage;
+
+  /// With the navigator collapsed (the Minimal preset) compact opens on the
+  /// canvas; the back bar still reaches the list, and this remembers it did.
+  bool _collapsedNavigatorRevealed = false;
+
+  @override
+  void dispose() {
+    _compactCanvasFocus.dispose();
+    _compactNavigatorFocus.dispose();
+    super.dispose();
+  }
+
   @override
   void didUpdateWidget(AdaptiveWorkspaceLayout oldWidget) {
     super.didUpdateWidget(oldWidget);
@@ -125,6 +201,75 @@ class _AdaptiveWorkspaceLayoutState extends State<AdaptiveWorkspaceLayout> {
     widget.onPreferencesChanged?.call(next.normalized);
   }
 
+  CompactWorkspacePage _compactPageFor(CompactWorkspaceNavigation? nav) {
+    if (nav == null) {
+      return widget.preferences.navigatorCollapsed
+          ? CompactWorkspacePage.canvas
+          : widget.compactPage;
+    }
+    if (nav.wantsCanvas) return CompactWorkspacePage.canvas;
+    if (widget.preferences.navigatorCollapsed && !_collapsedNavigatorRevealed) {
+      return CompactWorkspacePage.canvas;
+    }
+    return CompactWorkspacePage.navigator;
+  }
+
+  /// Moves focus onto the canvas once it replaces the list — only on that
+  /// transition, only for the visible page (IndexedStack disables TickerMode
+  /// for hidden ones), and never away from something inside the canvas.
+  void _noteCompactPage(CompactWorkspacePage? page) {
+    final previous = _lastCompactPage;
+    _lastCompactPage = page;
+    if (previous != CompactWorkspacePage.navigator ||
+        page != CompactWorkspacePage.canvas) {
+      return;
+    }
+    WidgetsBinding.instance.addPostFrameCallback((_) {
+      if (!mounted || !TickerMode.valuesOf(context).enabled) return;
+      if (_compactCanvasFocus.context == null || _compactCanvasFocus.hasFocus) {
+        return;
+      }
+      _compactCanvasFocus.requestFocus();
+    });
+  }
+
+  void _compactBack() {
+    final nav = widget.compactNavigation;
+    if (nav == null) return;
+    setState(() => _collapsedNavigatorRevealed = true);
+    nav.onShowNavigator();
+    WidgetsBinding.instance.addPostFrameCallback((_) {
+      if (!mounted) return;
+      final node =
+          widget.compactNavigation?.navigatorFocusNode ??
+          _compactNavigatorFocus;
+      if (node.context != null && node.canRequestFocus) node.requestFocus();
+    });
+  }
+
+  /// Esc and ⌘[ go Back — reached only when no descendant handled the key
+  /// first, so an open popover, a live drag or a field keeps its own Esc.
+  KeyEventResult _onCompactCanvasKey(FocusNode node, KeyEvent event) {
+    if (event is! KeyDownEvent) return KeyEventResult.ignored;
+    final keyboard = HardwareKeyboard.instance;
+    final back = switch (event.logicalKey) {
+      LogicalKeyboardKey.escape =>
+        !keyboard.isMetaPressed &&
+            !keyboard.isAltPressed &&
+            !keyboard.isControlPressed &&
+            !keyboard.isShiftPressed,
+      LogicalKeyboardKey.bracketLeft =>
+        keyboard.isMetaPressed &&
+            !keyboard.isAltPressed &&
+            !keyboard.isControlPressed &&
+            !keyboard.isShiftPressed,
+      _ => false,
+    };
+    if (!back) return KeyEventResult.ignored;
+    _compactBack();
+    return KeyEventResult.handled;
+  }
+
   @override
   Widget build(BuildContext context) {
     return LayoutBuilder(
@@ -136,6 +281,14 @@ class _AdaptiveWorkspaceLayoutState extends State<AdaptiveWorkspaceLayout> {
           inspectorVisible: widget.inspectorVisible,
           taskDockFocused: widget.taskDockFocused,
         );
+        final nav = widget.compactNavigation;
+        _noteCompactPage(
+          nav != null &&
+                  widget.navigator != null &&
+                  !arrangement.navigatorAndCanvas
+              ? _compactPageFor(nav)
+              : null,
+        );
         Widget main = _mainFor(arrangement);
         final dock = widget.taskDock;
         if (dock != null &&
@@ -210,10 +363,38 @@ class _AdaptiveWorkspaceLayoutState extends State<AdaptiveWorkspaceLayout> {
       child: navigator,
     );
     if (!arrangement.navigatorAndCanvas) {
-      if (widget.preferences.navigatorCollapsed) return canvas;
-      return widget.compactPage == CompactWorkspacePage.navigator
-          ? navigatorRegion
-          : canvas;
+      final nav = widget.compactNavigation;
+      if (nav == null) {
+        if (widget.preferences.navigatorCollapsed) return canvas;
+        return widget.compactPage == CompactWorkspacePage.navigator
+            ? navigatorRegion
+            : canvas;
+      }
+      if (_compactPageFor(nav) == CompactWorkspacePage.navigator) {
+        return WorkspaceFocusRegion(
+          role: WorkspacePaneRole.navigator,
+          child: nav.navigatorFocusNode == null
+              ? Focus(focusNode: _compactNavigatorFocus, child: navigator)
+              : navigator,
+        );
+      }
+      return WorkspaceFocusRegion(
+        role: WorkspacePaneRole.canvas,
+        child: Focus(
+          focusNode: _compactCanvasFocus,
+          onKeyEvent: _onCompactCanvasKey,
+          child: Column(
+            crossAxisAlignment: CrossAxisAlignment.stretch,
+            children: [
+              _CompactBackBar(
+                label: nav.navigatorLabel,
+                onPressed: _compactBack,
+              ),
+              Expanded(child: widget.canvas),
+            ],
+          ),
+        ),
+      );
     }
 
     Widget body = ResizablePanePair(
@@ -263,3 +444,29 @@ class _AdaptiveWorkspaceLayoutState extends State<AdaptiveWorkspaceLayout> {
     return body;
   }
 }
+
+/// "‹ Commits": the one way back to the list that needs no keyboard.
+class _CompactBackBar extends StatelessWidget {
+  final String label;
+  final VoidCallback onPressed;
+
+  const _CompactBackBar({required this.label, required this.onPressed});
+
+  @override
+  Widget build(BuildContext context) {
+    return Container(
+      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
+      decoration: const BoxDecoration(
+        border: Border(bottom: BorderSide(color: MacosColors.separatorColor)),
+      ),
+      alignment: Alignment.centerLeft,
+      child: InlineActionButton(
+        key: kWorkspaceCompactBackKey,
+        label: '‹ $label',
+        icon: CupertinoIcons.list_bullet,
+        tooltip: 'Back to $label (Esc or ⌘[)',
+        onPressed: onPressed,
+      ),
+    );
+  }
+}
diff --git a/lib/features/common/repository_workspace_scaffold.dart b/lib/features/common/repository_workspace_scaffold.dart
index 98dce09..1611117 100644
--- a/lib/features/common/repository_workspace_scaffold.dart
+++ b/lib/features/common/repository_workspace_scaffold.dart
@@ -61,6 +61,11 @@ class RepositoryWorkspaceScaffold extends StatelessWidget {
   final Object? error;
   final VoidCallback? onRetry;
   final CompactWorkspacePage activePage;
+
+  /// Scaffold-owned compact navigation (MADR 0064 F1-A). When set it decides
+  /// the compact pane, adds the back bar and Esc/⌘[, and hands focus between
+  /// the panes; [activePage] then applies only to callers without it.
+  final CompactWorkspaceNavigation? compactNavigation;
   final bool inspectorVisible;
   final bool taskDockFocused;
   final RepositoryWorkspacePrefs preferences;
@@ -78,6 +83,7 @@ class RepositoryWorkspaceScaffold extends StatelessWidget {
     this.error,
     this.onRetry,
     this.activePage = CompactWorkspacePage.canvas,
+    this.compactNavigation,
     this.inspectorVisible = false,
     this.taskDockFocused = false,
     this.preferences = const RepositoryWorkspacePrefs(),
@@ -119,6 +125,7 @@ class RepositoryWorkspaceScaffold extends StatelessWidget {
         inspector: inspector,
         taskDock: taskDock,
         compactPage: activePage,
+        compactNavigation: compactNavigation,
         inspectorVisible: inspectorVisible,
         taskDockFocused: taskDockFocused,
         preferences: preferences,
diff --git a/lib/features/forge/forge_workspace.dart b/lib/features/forge/forge_workspace.dart
index f2a2b50..c7e0ed6 100644
--- a/lib/features/forge/forge_workspace.dart
+++ b/lib/features/forge/forge_workspace.dart
@@ -30,6 +30,12 @@ class ForgeRepositoryWorkspace extends ConsumerWidget {
   final Object? error;
   final VoidCallback? onRetry;
 
+  /// Compact navigation (MADR 0064 F1-A): whether the page asked for the
+  /// detail, and how it closes it again. Without [onCompactShowNavigator] the
+  /// compact pane still follows [selection] alone.
+  final bool showCanvas;
+  final VoidCallback? onCompactShowNavigator;
+
   const ForgeRepositoryWorkspace({
     super.key,
     required this.repoPath,
@@ -42,6 +48,8 @@ class ForgeRepositoryWorkspace extends ConsumerWidget {
     this.loading = false,
     this.error,
     this.onRetry,
+    this.showCanvas = false,
+    this.onCompactShowNavigator,
   });
 
   @override
@@ -120,6 +128,14 @@ class ForgeRepositoryWorkspace extends ConsumerWidget {
       activePage: selection is ForgeNothingSel
           ? CompactWorkspacePage.navigator
           : CompactWorkspacePage.canvas,
+      compactNavigation: onCompactShowNavigator == null
+          ? null
+          : CompactWorkspaceNavigation(
+              navigatorLabel: 'Items',
+              hasSelection: selection is! ForgeNothingSel,
+              showCanvas: showCanvas,
+              onShowNavigator: onCompactShowNavigator!,
+            ),
       preferences: workspace.preferences,
       onPreferencesChanged: workspace.onChanged,
       workspaceOptionsEnabled: true,
diff --git a/lib/features/github/github_panel.dart b/lib/features/github/github_panel.dart
index f63cfa6..fd8eeb2 100644
--- a/lib/features/github/github_panel.dart
+++ b/lib/features/github/github_panel.dart
@@ -69,6 +69,10 @@ class _GitHubPanelState extends ConsumerState<GitHubPanel> {
 
   ForgeSel _sel = const ForgeNothingSel();
 
+  // Compact width shows the list OR the detail (MADR 0064 F1-A): selecting
+  // an item opens the detail, Back closes it and keeps the selection.
+  bool _compactShowCanvas = false;
+
   /// Whether an inline create form holds unsaved content (reported via
   /// onDirtyChanged). Guards row clicks and tab-away from silently
   /// destroying a draft.
@@ -191,6 +195,7 @@ class _GitHubPanelState extends ConsumerState<GitHubPanel> {
     setState(() {
       _sel = next;
       _draftDirty = false;
+      _compactShowCanvas = true;
     });
     publishLandedForgeSelection(
       ref,
@@ -293,6 +298,9 @@ class _GitHubPanelState extends ConsumerState<GitHubPanel> {
         navigator: _leftPane(prs, runs, runByBranch),
         canvas: _mainPane(prs, runs, runByBranch),
         selection: _sel,
+        showCanvas: _sel is! ForgeNothingSel && _compactShowCanvas,
+        onCompactShowNavigator: () =>
+            setState(() => _compactShowCanvas = false),
         primaryActionLabel: 'New Pull Request',
         onPrimaryAction: _createPr,
       ),
diff --git a/lib/features/gitlab/gitlab_panel.dart b/lib/features/gitlab/gitlab_panel.dart
index 8f0aa4c..91cd87b 100644
--- a/lib/features/gitlab/gitlab_panel.dart
+++ b/lib/features/gitlab/gitlab_panel.dart
@@ -88,6 +88,10 @@ class _GitLabPanelState extends ConsumerState<GitLabPanel> {
 
   ForgeSel _sel = const ForgeNothingSel();
 
+  // Compact width shows the list OR the detail (MADR 0064 F1-A): selecting
+  // an item opens the detail, Back closes it and keeps the selection.
+  bool _compactShowCanvas = false;
+
   /// Whether an inline create form holds unsaved content (reported via
   /// onDirtyChanged). Guards row clicks and tab-away from silently
   /// destroying a draft.
@@ -224,6 +228,7 @@ class _GitLabPanelState extends ConsumerState<GitLabPanel> {
     setState(() {
       _sel = next;
       _draftDirty = false;
+      _compactShowCanvas = true;
     });
     publishLandedForgeSelection(
       ref,
@@ -331,6 +336,9 @@ class _GitLabPanelState extends ConsumerState<GitLabPanel> {
         navigator: _leftPane(mrs, pipelines, pipeByRef),
         canvas: _mainPane(mrs, pipelines, pipeByRef),
         selection: _sel,
+        showCanvas: _sel is! ForgeNothingSel && _compactShowCanvas,
+        onCompactShowNavigator: () =>
+            setState(() => _compactShowCanvas = false),
         primaryActionLabel: 'New Merge Request',
         onPrimaryAction: _createMr,
       ),
diff --git a/lib/features/history/history_view.dart b/lib/features/history/history_view.dart
index fa8486a..62232bd 100644
--- a/lib/features/history/history_view.dart
+++ b/lib/features/history/history_view.dart
@@ -114,6 +114,11 @@ class _HistoryViewState extends ConsumerState<HistoryView>
   // then ↑/↓ walk the selection through the commits (⇧↑/⇧↓ extend a range),
   // scrolling each into view.
   final FocusNode _commitFocus = FocusNode(debugLabel: 'commit-list');
+
+  // Compact width shows the list OR the detail (MADR 0064 F1-A). A row tap or
+  // Enter opens the detail; Back closes it and keeps the selection; ↑/↓ move
+  // the selection without flipping panes.
+  bool _compactShowCanvas = false;
   final ScrollController _commitScroll = ScrollController();
   final Map<String, GlobalKey> _commitRowKeys = {};
 
@@ -330,6 +335,7 @@ class _HistoryViewState extends ConsumerState<HistoryView>
     final commits = _lastCommits ?? const <GitCommit>[];
     final keys = HardwareKeyboard.instance;
     setState(() {
+      _compactShowCanvas = true;
       if (keys.isMetaPressed) {
         if (_selectedHashes.contains(hash)) {
           // ⌘-click on a selected row removes it. The removed hash must NOT
@@ -435,6 +441,20 @@ class _HistoryViewState extends ConsumerState<HistoryView>
           hasSelection: _selectedHashes.isNotEmpty,
           clear: () => setState(_clearSelection),
         );
+      case LogicalKeyboardKey.enter:
+      case LogicalKeyboardKey.numpadEnter:
+        // Plain Enter opens the selected commit (the compact canvas). Any
+        // modifier belongs to a panel binding such as ⌘⇧↩ Amend.
+        final keys = HardwareKeyboard.instance;
+        if (_soleSelectedHash == null ||
+            keys.isMetaPressed ||
+            keys.isShiftPressed ||
+            keys.isAltPressed ||
+            keys.isControlPressed) {
+          return KeyEventResult.ignored;
+        }
+        setState(() => _compactShowCanvas = true);
+        return KeyEventResult.handled;
     }
     return KeyEventResult.ignored;
   }
@@ -1446,6 +1466,7 @@ class _HistoryViewState extends ConsumerState<HistoryView>
               second,
           };
           _selectionAnchor = location.identity;
+          _compactShowCanvas = true;
         });
       });
     }
@@ -1489,6 +1510,9 @@ class _HistoryViewState extends ConsumerState<HistoryView>
 
     final keymap = ref.watch(keymapProvider);
     final selectedHash = _soleSelectedHash;
+    // A cleared selection closes the compact detail with it, so a later ↑/↓
+    // selects in the list rather than reopening the detail.
+    if (selectedHash == null) _compactShowCanvas = false;
     final selectedCommit = _selectedCommitIn(commits);
     final hasCommits = commits?.isNotEmpty ?? false;
     final connection = ref.watch(connectionProvider);
@@ -1665,9 +1689,13 @@ class _HistoryViewState extends ConsumerState<HistoryView>
           ],
         ),
         canvas: _rightPane(context, commits),
-        activePage: selectedHash == null
-            ? CompactWorkspacePage.navigator
-            : CompactWorkspacePage.canvas,
+        compactNavigation: CompactWorkspaceNavigation(
+          navigatorLabel: 'Commits',
+          hasSelection: selectedHash != null,
+          showCanvas: _compactShowCanvas,
+          onShowNavigator: () => setState(() => _compactShowCanvas = false),
+          navigatorFocusNode: _commitFocus,
+        ),
         preferences: workspace.preferences,
         onPreferencesChanged: workspace.onChanged,
         workspaceOptionsEnabled: true,
diff --git a/lib/features/stash/stash_view.dart b/lib/features/stash/stash_view.dart
index ea9f82f..60077b6 100644
--- a/lib/features/stash/stash_view.dart
+++ b/lib/features/stash/stash_view.dart
@@ -67,6 +67,10 @@ class _StashViewState extends ConsumerState<StashView> with BusyActionState {
   // Keyboard navigation of the stash list: the list takes focus on a card tap,
   // then ↑/↓ walk _selected through the stashes (⌥⌘A/⌥⌘P/⌘⌫ then act on it).
   final FocusNode _stashFocus = FocusNode(debugLabel: 'stash-list');
+
+  // Compact width shows the list OR the preview (MADR 0064 F1-A): a tap or
+  // Enter opens the preview, Back closes it and keeps the selection.
+  bool _compactShowCanvas = false;
   final ScrollController _stashScroll = ScrollController();
   final TextEditingController _filterController = TextEditingController();
   final Map<String, GlobalKey> _stashRowKeys = {};
@@ -146,6 +150,19 @@ class _StashViewState extends ConsumerState<StashView> with BusyActionState {
           hasSelection: _selected != null,
           clear: () => setState(() => _selected = null),
         );
+      case LogicalKeyboardKey.enter:
+      case LogicalKeyboardKey.numpadEnter:
+        // Plain Enter opens the selected stash's preview (compact canvas).
+        final keys = HardwareKeyboard.instance;
+        if (_selected == null ||
+            keys.isMetaPressed ||
+            keys.isShiftPressed ||
+            keys.isAltPressed ||
+            keys.isControlPressed) {
+          return KeyEventResult.ignored;
+        }
+        setState(() => _compactShowCanvas = true);
+        return KeyEventResult.handled;
     }
     return KeyEventResult.ignored;
   }
@@ -262,7 +279,10 @@ class _StashViewState extends ConsumerState<StashView> with BusyActionState {
           markWorkspaceLocationUnavailable(ref, location);
           return;
         }
-        setState(() => _selected = location.identity);
+        setState(() {
+          _selected = location.identity;
+          _compactShowCanvas = true;
+        });
       });
     }
     final git = ref.read(gitServiceProvider);
@@ -420,6 +440,8 @@ class _StashViewState extends ConsumerState<StashView> with BusyActionState {
           final selected = stashes.any((stash) => stash.oid == _selected)
               ? _selected
               : null;
+          // A cleared selection closes the compact preview with it.
+          if (selected == null) _compactShowCanvas = false;
           return RepositoryWorkspaceScaffold(
             repositoryContext: _contextBar(snapshot, git),
             navigator: Column(
@@ -456,9 +478,13 @@ class _StashViewState extends ConsumerState<StashView> with BusyActionState {
             canvas: stashes.isEmpty
                 ? _empty(context)
                 : _preview(context, selected),
-            activePage: selected == null
-                ? CompactWorkspacePage.navigator
-                : CompactWorkspacePage.canvas,
+            compactNavigation: CompactWorkspaceNavigation(
+              navigatorLabel: 'Stashes',
+              hasSelection: selected != null,
+              showCanvas: _compactShowCanvas,
+              onShowNavigator: () => setState(() => _compactShowCanvas = false),
+              navigatorFocusNode: _stashFocus,
+            ),
             preferences: workspace.preferences,
             onPreferencesChanged: workspace.onChanged,
             workspaceOptionsEnabled: true,
@@ -681,7 +707,10 @@ class _StashViewState extends ConsumerState<StashView> with BusyActionState {
         key: _stashRowKeyFor(stash.oid),
         onTap: () {
           _stashFocus.requestFocus();
-          setState(() => _selected = stash.oid);
+          setState(() {
+            _selected = stash.oid;
+            _compactShowCanvas = true;
+          });
         },
         onSecondaryTapUp: (d) =>
             _showCardMenu(context, git, stash, d.globalPosition),
diff --git a/lib/features/worktrees/worktrees_view.dart b/lib/features/worktrees/worktrees_view.dart
index 734eef9..0f06b64 100644
--- a/lib/features/worktrees/worktrees_view.dart
+++ b/lib/features/worktrees/worktrees_view.dart
@@ -14,6 +14,7 @@ import '../../core/utils/display_error.dart';
 import '../../core/utils/file_actions.dart';
 import '../branches/branches_view.dart';
 import '../common/actions.dart';
+import '../common/adaptive_workspace_layout.dart';
 import '../common/async_views.dart';
 import '../common/busy_action.dart';
 import '../common/buttons.dart';
@@ -112,6 +113,10 @@ class _WorktreesViewState extends ConsumerState<WorktreesView>
   final Map<String, GlobalKey> _overviewRowKeys = {};
   String? _selectedOverviewPath;
 
+  // Compact width shows the overview list OR the selected worktree (MADR 0064
+  // F1-A): a tap or Enter opens it, Back closes it and keeps the selection.
+  bool _compactShowCanvas = false;
+
   String get repoPath => widget.repoPath;
 
   GlobalKey _overviewRowKeyFor(String path) =>
@@ -155,6 +160,19 @@ class _WorktreesViewState extends ConsumerState<WorktreesView>
           hasSelection: _selectedOverviewPath != null,
           clear: () => setState(() => _selectedOverviewPath = null),
         );
+      case LogicalKeyboardKey.enter:
+      case LogicalKeyboardKey.numpadEnter:
+        // Plain Enter opens the selected worktree (the compact canvas).
+        final keys = HardwareKeyboard.instance;
+        if (_selectedOverviewPath == null ||
+            keys.isMetaPressed ||
+            keys.isShiftPressed ||
+            keys.isAltPressed ||
+            keys.isControlPressed) {
+          return KeyEventResult.ignored;
+        }
+        setState(() => _compactShowCanvas = true);
+        return KeyEventResult.handled;
     }
     return KeyEventResult.ignored;
   }
@@ -685,7 +703,10 @@ class _WorktreesViewState extends ConsumerState<WorktreesView>
           ref.read(worktreeTabsProvider.notifier).select(match.path);
         } else {
           ref.read(worktreeTabsProvider.notifier).select(null);
-          setState(() => _selectedOverviewPath = match.path);
+          setState(() {
+            _selectedOverviewPath = match.path;
+            _compactShowCanvas = true;
+          });
         }
       });
     }
@@ -787,6 +808,8 @@ class _WorktreesViewState extends ConsumerState<WorktreesView>
     final selectedWorktree = worktrees
         .where((item) => item.path == _selectedOverviewPath)
         .firstOrNull;
+    // A cleared selection closes the compact detail with it.
+    if (selectedWorktree == null) _compactShowCanvas = false;
     final snapshot = RepositoryContextSnapshot(
       repositoryPath: repoPath,
       repositoryName:
@@ -840,6 +863,13 @@ class _WorktreesViewState extends ConsumerState<WorktreesView>
         canvas: selectedWorktree == null
             ? _overviewPlaceholder(context, worktrees)
             : _worktreeDetail(context, selectedWorktree),
+        compactNavigation: CompactWorkspaceNavigation(
+          navigatorLabel: 'Worktrees',
+          hasSelection: selectedWorktree != null,
+          showCanvas: _compactShowCanvas,
+          onShowNavigator: () => setState(() => _compactShowCanvas = false),
+          navigatorFocusNode: _overviewFocus,
+        ),
         preferences: workspace.preferences,
         onPreferencesChanged: workspace.onChanged,
         workspaceOptionsEnabled: true,
@@ -1041,7 +1071,10 @@ class _WorktreesViewState extends ConsumerState<WorktreesView>
       key: _overviewRowKeyFor(wt.path),
       onTap: () {
         _overviewFocus.requestFocus();
-        setState(() => _selectedOverviewPath = wt.path);
+        setState(() {
+          _selectedOverviewPath = wt.path;
+          _compactShowCanvas = true;
+        });
       },
       onDoubleTap: () => _openWorktree(wt),
       // Selecting first mirrors the tap path (and Stash's card menu): the menu
```

Phase 5: compact navigation owned by the scaffold (`git apply --index`).

### A.14 `F2.diff`

```diff
diff --git a/lib/features/branches/branch_navigator.dart b/lib/features/branches/branch_navigator.dart
index 702065a..819568a 100644
--- a/lib/features/branches/branch_navigator.dart
+++ b/lib/features/branches/branch_navigator.dart
@@ -28,6 +28,7 @@ import '../common/show_more_row.dart';
 import '../common/tappable.dart';
 import '../common/tool_icon_button.dart';
 import '../dnd/deselect.dart';
+import '../dnd/drag_hover_scope.dart';
 import '../dnd/drag_item.dart';
 import '../dnd/drag_state.dart';
 import '../forge/forge_widgets.dart' show CiDot;
@@ -1481,49 +1482,69 @@ class _BranchNavigatorState extends ConsumerState<BranchNavigator> {
       // Local branches accept a dragged commit (E2 cherry-pick onto that
       // branch). HEAD also still accepts another local branch for
       // merge-into / rebase-onto (see [_dropOnCurrent]).
-      child: DragTarget<DragItem>(
-        onWillAcceptWithDetails: (d) {
-          if (d.data is DragCommit) {
-            return branch.isLocalBranch && !branch.isCheckedOutElsewhere;
-          }
-          return branch.isHead &&
-              d.data is DragRef &&
-              (d.data as DragRef).ref.name != branch.name;
-        },
-        onAcceptWithDetails: (d) {
-          // ESC-cancelled drags release as a no-op (see DragStateNotifier).
-          if (ref.read(dragStateProvider) == null) return;
-          final data = d.data;
-          if (data is DragCommit) {
-            widget.onDropCommitOnBranch(
-              git,
-              commit: data.commit,
-              branch: branch,
-            );
-            return;
-          }
-          if (data is DragRef) {
-            widget.onDropOnCurrent(git, source: data.ref, current: branch);
-          }
-        },
-        builder: (context, candidate, rejected) {
-          final hovering = candidate.isNotEmpty;
-          final row = _localRowBody(context, git, branch, depth, label);
-          if (!hovering) return row;
-          return DecoratedBox(
-            decoration: BoxDecoration(
-              color: _accentTint,
-              border: const Border(
-                left: BorderSide(color: MacosColors.systemBlueColor, width: 2),
+      // Per-row hover owner: a row rebuilt away mid-drag gives the hover
+      // back (MADR 0064 F2).
+      child: DragHoverScope(
+        builder: (_, hover) => DragTarget<DragItem>(
+          onWillAcceptWithDetails: (d) => _acceptsDrop(branch, d.data),
+          // Hover report for the drag image (MADR 0064 F2), guarded by the
+          // same acceptance test: Flutter calls onMove on rejecting targets.
+          onMove: (d) {
+            if (_acceptsDrop(branch, d.data)) {
+              hover.setOverTarget(true);
+            }
+          },
+          onLeave: (_) => hover.setOverTarget(false),
+          onAcceptWithDetails: (d) {
+            hover.setOverTarget(false);
+            // ESC-cancelled drags release as a no-op (see DragStateNotifier).
+            if (ref.read(dragStateProvider) == null) return;
+            final data = d.data;
+            if (data is DragCommit) {
+              widget.onDropCommitOnBranch(
+                git,
+                commit: data.commit,
+                branch: branch,
+              );
+              return;
+            }
+            if (data is DragRef) {
+              widget.onDropOnCurrent(git, source: data.ref, current: branch);
+            }
+          },
+          builder: (context, candidate, rejected) {
+            final hovering = candidate.isNotEmpty;
+            final row = _localRowBody(context, git, branch, depth, label);
+            if (!hovering) return row;
+            return DecoratedBox(
+              decoration: BoxDecoration(
+                color: _accentTint,
+                border: const Border(
+                  left: BorderSide(
+                    color: MacosColors.systemBlueColor,
+                    width: 2,
+                  ),
+                ),
               ),
-            ),
-            child: row,
-          );
-        },
+              child: row,
+            );
+          },
+        ),
       ),
     );
   }
 
+  /// Whether [branch]'s row takes [data]: a dragged commit onto a local
+  /// branch not checked out elsewhere (E2 cherry-pick), or another local
+  /// branch onto HEAD (merge-into / rebase-onto). One predicate for both
+  /// the accept decision and the hover report.
+  static bool _acceptsDrop(GitRef branch, DragItem data) {
+    if (data is DragCommit) {
+      return branch.isLocalBranch && !branch.isCheckedOutElsewhere;
+    }
+    return branch.isHead && data is DragRef && data.ref.name != branch.name;
+  }
+
   static final Color _accentTint = MacosColors.systemBlueColor.withValues(
     alpha: 0.12,
   );
diff --git a/lib/features/dnd/drag_cell.dart b/lib/features/dnd/drag_cell.dart
index f681b2e..3afcf50 100644
--- a/lib/features/dnd/drag_cell.dart
+++ b/lib/features/dnd/drag_cell.dart
@@ -18,6 +18,16 @@ import 'package:macos_ui/macos_ui.dart';
 /// where the identity lives: icon, hash, name).
 const double kDragCellMaxWidth = 420;
 
+/// Max width of the compact chip the drag image becomes while it is over a
+/// drop target that accepts it (MADR 0064 F2).
+const double kDragChipMaxWidth = 220;
+
+/// Where the compact chip's top-left sits relative to the pointer. Right of
+/// and below it, so the pointer is never covered, and far enough down (more
+/// than half a 32 px nav row) that the hovered row stays clear whenever the
+/// pointer is at or above its vertical centre.
+const Offset kDragChipPointerOffset = Offset(12, 18);
+
 /// Corner radius of the cell (press chrome and lifted ghost must match, so the
 /// press visually *becomes* the lifted cell).
 const double kDragCellRadius = 9;
@@ -36,8 +46,10 @@ class DragCellChrome extends StatelessWidget {
     return DecoratedBox(
       decoration: BoxDecoration(
         // Elevated surface a step above the panel background (dark theme —
-        // the app pins ThemeMode.dark). Slight translucency keeps drop
-        // targets readable through the cell as it passes over them.
+        // the app pins ThemeMode.dark). Together with the lifted cell's
+        // 0.94 opacity this is ~89% opaque: it does NOT keep what is under
+        // it readable. That is why the cell collapses to a compact chip
+        // beside the pointer while it is over a drop target (MADR 0064 F2).
         color: const Color(0xF2323236),
         borderRadius: BorderRadius.circular(kDragCellRadius),
         border: Border.all(
@@ -82,17 +94,22 @@ class DragCellBody extends StatelessWidget {
   final Size sourceSize;
   final String fallbackLabel;
 
+  /// The widest the cell may be: [kDragCellMaxWidth] for the lifted cell,
+  /// [kDragChipMaxWidth] for the compact chip.
+  final double maxWidth;
+
   const DragCellBody({
     super.key,
     required this.image,
     required this.pixelRatio,
     required this.sourceSize,
     required this.fallbackLabel,
+    this.maxWidth = kDragCellMaxWidth,
   });
 
   @override
   Widget build(BuildContext context) {
-    final width = sourceSize.width.clamp(0.0, kDragCellMaxWidth).toDouble();
+    final width = sourceSize.width.clamp(0.0, maxWidth).toDouble();
     final img = image;
 
     final content = img != null
@@ -110,7 +127,7 @@ class DragCellBody extends StatelessWidget {
             ),
           )
         : ConstrainedBox(
-            constraints: const BoxConstraints(maxWidth: kDragCellMaxWidth),
+            constraints: BoxConstraints(maxWidth: maxWidth),
             child: Padding(
               padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
               child: Text(
@@ -128,8 +145,14 @@ class DragCellBody extends StatelessWidget {
 
 /// The lifted ghost that rides under the pointer, springing from the pressed
 /// scale (0.98) up to a floating one (1.03) as it detaches from the list —
-/// ~140ms ease-out per the microinteraction guidance; slight transparency so
-/// drop targets stay readable underneath.
+/// ~140ms ease-out per the microinteraction guidance. At 0.94 opacity over a
+/// 0xF2 fill it is ~89% opaque, so it hides what it covers.
+///
+/// [compact] is the mode the drag image takes while it is over a drop target
+/// that accepts it (MADR 0064 F2): the item's label in the same chrome, at
+/// most [kDragChipMaxWidth] wide, count badge kept. The caller places it
+/// beside the pointer. It is this same widget in another mode, never a
+/// second one, so exactly one [DragCellChrome] is ever on screen.
 class LiftedDragCell extends StatelessWidget {
   final ui.Image? image;
   final double pixelRatio;
@@ -141,6 +164,9 @@ class LiftedDragCell extends StatelessWidget {
   /// is what says the whole selection is in hand.
   final int? badgeCount;
 
+  /// Render as the compact over-a-target chip instead of the full snapshot.
+  final bool compact;
+
   const LiftedDragCell({
     super.key,
     required this.image,
@@ -148,15 +174,18 @@ class LiftedDragCell extends StatelessWidget {
     required this.sourceSize,
     required this.fallbackLabel,
     this.badgeCount,
+    this.compact = false,
   });
 
   @override
   Widget build(BuildContext context) {
+    // Compact: no snapshot, so the body renders the label fallback.
     Widget cell = DragCellBody(
-      image: image,
+      image: compact ? null : image,
       pixelRatio: pixelRatio,
       sourceSize: sourceSize,
       fallbackLabel: fallbackLabel,
+      maxWidth: compact ? kDragChipMaxWidth : kDragCellMaxWidth,
     );
     final count = badgeCount;
     if (count != null) {
@@ -172,8 +201,13 @@ class LiftedDragCell extends StatelessWidget {
       tween: Tween(begin: 0.98, end: 1.03),
       duration: const Duration(milliseconds: 140),
       curve: Curves.easeOutCubic,
-      builder: (context, scale, child) =>
-          Transform.scale(scale: scale, child: child),
+      // The compact chip scales about its top-left, so that corner stays
+      // exactly where the caller put it (pointer + kDragChipPointerOffset).
+      builder: (context, scale, child) => Transform.scale(
+        scale: scale,
+        alignment: compact ? Alignment.topLeft : Alignment.center,
+        child: child,
+      ),
       child: Opacity(opacity: 0.94, child: cell),
     );
   }
diff --git a/lib/features/dnd/drag_hover_scope.dart b/lib/features/dnd/drag_hover_scope.dart
new file mode 100644
index 0000000..375f254
--- /dev/null
+++ b/lib/features/dnd/drag_hover_scope.dart
@@ -0,0 +1,48 @@
+import 'package:flutter/widgets.dart';
+import 'package:flutter_riverpod/flutter_riverpod.dart';
+
+import 'drag_state.dart';
+
+/// Gives one drop target its own [DragHoverReport] and releases it when the
+/// target leaves the tree (MADR 0064 F2).
+///
+/// Flutter never calls `onLeave` on a drop target that is unmounted mid-drag
+/// (a list refresh rebuilding History rows, a page unmounting), so a target
+/// that held the hover would otherwise leave the drag image as a compact chip
+/// over empty space until the release. The report is owned by this element:
+/// its disposal clears the hover only if this target still holds it, so
+/// removing one target never takes the hover from another.
+///
+/// Wrap each drop target in one, and report through the handle the builder
+/// receives: `hover.setOverTarget(true)` from `onMove` (guarded by the
+/// target's acceptance test), `hover.setOverTarget(false)` from `onLeave` and
+/// on accept.
+class DragHoverScope extends ConsumerStatefulWidget {
+  final Widget Function(BuildContext context, DragHoverReport hover) builder;
+
+  const DragHoverScope({super.key, required this.builder});
+
+  @override
+  ConsumerState<DragHoverScope> createState() => _DragHoverScopeState();
+}
+
+class _DragHoverScopeState extends ConsumerState<DragHoverScope> {
+  late final DragHoverReport _hover;
+
+  @override
+  void initState() {
+    super.initState();
+    // Bound to the notifier, not `ref`: the notifier stays valid for the
+    // tab's lifetime, and dispose must not touch `ref`.
+    _hover = DragHoverReport(ref.read(dragStateProvider.notifier));
+  }
+
+  @override
+  void dispose() {
+    _hover.dispose();
+    super.dispose();
+  }
+
+  @override
+  Widget build(BuildContext context) => widget.builder(context, _hover);
+}
diff --git a/lib/features/dnd/drag_item.dart b/lib/features/dnd/drag_item.dart
index a48594e..d8f027f 100644
--- a/lib/features/dnd/drag_item.dart
+++ b/lib/features/dnd/drag_item.dart
@@ -139,6 +139,11 @@ class _DragItemDraggableState extends ConsumerState<DragItemDraggable> {
   double _snapshotPixelRatio = 1;
   Size _sourceSize = Size.zero;
 
+  /// Where the row was grabbed, in its own coordinates ([_anchor]'s result):
+  /// the drag image's origin sits this far up-left of the pointer. The
+  /// compact chip is translated by it to land beside the pointer.
+  Offset _grabAnchor = Offset.zero;
+
   /// Pressed-button state: pointer is down on the row, drag not yet started.
   bool _pressed = false;
 
@@ -194,7 +199,7 @@ class _DragItemDraggableState extends ConsumerState<DragItemDraggable> {
     final local = box.globalToLocal(position);
     final cellWidth = box.size.width.clamp(0.0, kDragCellMaxWidth);
     final inset = cellWidth >= 32 ? 16.0 : cellWidth / 2;
-    return Offset(
+    return _grabAnchor = Offset(
       local.dx.clamp(inset, cellWidth - inset),
       local.dy.clamp(0.0, box.size.height),
     );
@@ -323,20 +328,35 @@ class _DragItemDraggableState extends ConsumerState<DragItemDraggable> {
     // cell swaps to the selected-state pixels mid-flight, seamlessly. A
     // multi-file drag carries the whole selection but snapshots only the
     // grabbed row — the Finder-style count badge says what's really in hand.
+    //
+    // It also subscribes to the drag state's over-a-target flag (MADR 0064
+    // F2): over an accepting target the cell turns compact and moves beside
+    // the pointer, so it no longer covers the target it is over. The
+    // translate is always in the tree (zero when off target) so the cell
+    // keeps its element — and its lift animation — across the switch.
+    // Hit-testing is unaffected (Flutter tests at the pointer), and so is
+    // the snap-back origin (`details.offset`, the uncompacted top-left).
     final item = widget.item;
     final badgeCount = item is DragFiles && item.paths.length > 1
         ? item.paths.length
         : null;
-    final ghost = ValueListenableBuilder<ui.Image?>(
-      valueListenable: _snapshot,
-      builder: (context, image, _) => LiftedDragCell(
-        image: image,
-        pixelRatio: _snapshotPixelRatio,
-        sourceSize: _sourceSize == Size.zero
-            ? const Size(kDragCellMaxWidth / 2, 28)
-            : _sourceSize,
-        fallbackLabel: widget.item.shortLabel,
-        badgeCount: badgeCount,
+    final ghost = ValueListenableBuilder<bool>(
+      valueListenable: drag.overTarget,
+      builder: (context, over, _) => ValueListenableBuilder<ui.Image?>(
+        valueListenable: _snapshot,
+        builder: (context, image, _) => Transform.translate(
+          offset: over ? _grabAnchor + kDragChipPointerOffset : Offset.zero,
+          child: LiftedDragCell(
+            image: image,
+            pixelRatio: _snapshotPixelRatio,
+            sourceSize: _sourceSize == Size.zero
+                ? const Size(kDragCellMaxWidth / 2, 28)
+                : _sourceSize,
+            fallbackLabel: widget.item.shortLabel,
+            badgeCount: badgeCount,
+            compact: over,
+          ),
+        ),
       ),
     );
 
diff --git a/lib/features/dnd/drag_state.dart b/lib/features/dnd/drag_state.dart
index 301a30e..c361bed 100644
--- a/lib/features/dnd/drag_state.dart
+++ b/lib/features/dnd/drag_state.dart
@@ -1,3 +1,5 @@
+import 'package:flutter/foundation.dart';
+import 'package:flutter/scheduler.dart';
 import 'package:flutter/services.dart';
 import 'package:flutter_riverpod/flutter_riverpod.dart';
 
@@ -13,6 +15,11 @@ import 'drag_item.dart';
 /// ghost follows the pointer until release), but every drop target treats a
 /// null drag state as "cancelled" and ignores the drop, and the nav rail
 /// un-lights immediately — so ESC makes releasing anywhere a guaranteed no-op.
+///
+/// **Over a target** ([overTarget], MADR 0064 F2): every drop target reports
+/// whether the pointer is over it *and it accepts the payload*, so the drag
+/// image can collapse to its compact chip beside the pointer instead of
+/// covering the very target it is over.
 class DragStateNotifier extends Notifier<DragItem?> {
   bool _escHandlerInstalled = false;
 
@@ -37,10 +44,61 @@ class DragStateNotifier extends Notifier<DragItem?> {
   /// from a cancelled one that happened to be released over a target.
   bool get isActive => state != null;
 
+  /// Whether the pointer is over a drop target that accepts the live payload.
+  /// A [ValueNotifier] rather than provider state: the drag image is built
+  /// once as the Draggable's feedback, and only a listenable can update it.
+  /// Synchronous, so the image switches in the same frame the target lights.
+  final ValueNotifier<bool> overTarget = ValueNotifier(false);
+
+  /// The target that last reported hover (its [DragHoverReport]), so only
+  /// that target can take the hover back.
+  Object? _overTargetOwner;
+
+  /// Called by every drop target for a drag item, through its own
+  /// [DragHoverReport]: `true` from `onMove` — guarded by the target's own
+  /// acceptance test, because Flutter calls `onMove` on rejecting targets
+  /// too — and `false` from `onLeave` and on accept.
+  ///
+  /// `true` makes [owner] the holder. `false` from an [owner] that no
+  /// longer holds the hover is ignored; a `false` with no owner clears it
+  /// unconditionally. A `true` while no drag is live (ESC already
+  /// cancelled it) is ignored, so moving after ESC cannot bring the chip
+  /// back.
+  void setOverTarget(bool value, {Object? owner}) {
+    if (value) {
+      if (state == null) return;
+      _overTargetOwner = owner;
+      overTarget.value = true;
+      return;
+    }
+    if (owner != null && !identical(owner, _overTargetOwner)) return;
+    _clearOverTarget();
+  }
+
+  /// A drop target is leaving the tree. Flutter never calls `onLeave` on an
+  /// unmounted target, so this is the only way the hover it holds comes
+  /// back. Deferred to the end of the frame: a target is disposed while
+  /// the widget tree is locked, when the drag image cannot be marked for
+  /// rebuild. No-op unless [owner] still holds the hover then.
+  void releaseOverTarget(Object owner) {
+    if (!identical(owner, _overTargetOwner)) return;
+    SchedulerBinding.instance
+      ..addPostFrameCallback((_) {
+        if (identical(owner, _overTargetOwner)) _clearOverTarget();
+      })
+      ..ensureVisualUpdate();
+  }
+
+  void _clearOverTarget() {
+    _overTargetOwner = null;
+    overTarget.value = false;
+  }
+
   /// Called on every drag end (drop or cancel). Idempotent — an ESC-cancelled
   /// drag still ends with a pointer release, which calls this again.
   void end() {
     state = null;
+    _clearOverTarget();
     _removeEscHandler();
   }
 
@@ -49,6 +107,7 @@ class DragStateNotifier extends Notifier<DragItem?> {
         event.logicalKey == LogicalKeyboardKey.escape &&
         state != null) {
       state = null; // drop targets now ignore the release; the rail un-lights
+      _clearOverTarget(); // the full drag image returns at once
       return true; // swallow it — this ESC must not also dismiss a sheet
     }
     return false;
@@ -62,6 +121,21 @@ class DragStateNotifier extends Notifier<DragItem?> {
   }
 }
 
+/// One drop target's hover report: the handle a [DragHoverScope] gives the
+/// target it wraps. Reporting through it makes that target the owner, so
+/// its [dispose] clears the hover only while it still holds it.
+class DragHoverReport {
+  final DragStateNotifier _drag;
+
+  DragHoverReport(this._drag);
+
+  /// See [DragStateNotifier.setOverTarget].
+  void setOverTarget(bool value) => _drag.setOverTarget(value, owner: this);
+
+  /// The target is leaving the tree: give back the hover if it holds it.
+  void dispose() => _drag.releaseOverTarget(this);
+}
+
 final dragStateProvider = NotifierProvider<DragStateNotifier, DragItem?>(
   DragStateNotifier.new,
 );
diff --git a/lib/features/dnd/drop_zone.dart b/lib/features/dnd/drop_zone.dart
index e649759..8248a49 100644
--- a/lib/features/dnd/drop_zone.dart
+++ b/lib/features/dnd/drop_zone.dart
@@ -3,6 +3,7 @@ import 'package:flutter_riverpod/flutter_riverpod.dart';
 
 import '../../core/providers/app_providers.dart';
 import '../common/context_menu.dart';
+import 'drag_hover_scope.dart';
 import 'drag_item.dart';
 import 'drag_state.dart';
 import 'drop_registry.dart';
@@ -44,30 +45,39 @@ class _DropZoneState extends ConsumerState<DropZone> {
 
   @override
   Widget build(BuildContext context) {
-    return DragTarget<DragItem>(
-      onWillAcceptWithDetails: (details) => canDrop(details.data, widget.id),
-      onAcceptWithDetails: (details) {
-        // ESC cancelled this drag (the gesture itself can't be aborted, only
-        // its release) — a cancelled drop is a no-op everywhere.
-        if (ref.read(dragStateProvider) == null) return;
-        final repoPath = ref.read(connectionProvider).repoPath;
-        if (repoPath == null) return;
-        runDrop(
-          details.data,
-          widget.id,
-          DropContext(
-            ref: ref,
-            context: context,
-            repoPath: repoPath,
-            selectPage: widget.selectPage,
-            refresh: widget.refresh,
-            menu: _menu,
-          ),
-          details.offset,
-        );
-      },
-      builder: (context, candidate, rejected) =>
-          widget.builder(context, candidate.isNotEmpty),
+    return DragHoverScope(
+      builder: (_, hover) => DragTarget<DragItem>(
+        onWillAcceptWithDetails: (details) => canDrop(details.data, widget.id),
+        // Hover report for the drag image (MADR 0064 F2), guarded by the same
+        // acceptance test: Flutter calls onMove on rejecting targets too.
+        onMove: (details) {
+          if (canDrop(details.data, widget.id)) hover.setOverTarget(true);
+        },
+        onLeave: (_) => hover.setOverTarget(false),
+        onAcceptWithDetails: (details) {
+          hover.setOverTarget(false);
+          // ESC cancelled this drag (the gesture itself can't be aborted, only
+          // its release) — a cancelled drop is a no-op everywhere.
+          if (ref.read(dragStateProvider) == null) return;
+          final repoPath = ref.read(connectionProvider).repoPath;
+          if (repoPath == null) return;
+          runDrop(
+            details.data,
+            widget.id,
+            DropContext(
+              ref: ref,
+              context: context,
+              repoPath: repoPath,
+              selectPage: widget.selectPage,
+              refresh: widget.refresh,
+              menu: _menu,
+            ),
+            details.offset,
+          );
+        },
+        builder: (context, candidate, rejected) =>
+            widget.builder(context, candidate.isNotEmpty),
+      ),
     );
   }
 }
diff --git a/lib/features/dnd/nav_rail.dart b/lib/features/dnd/nav_rail.dart
index 3b5eadc..688f57f 100644
--- a/lib/features/dnd/nav_rail.dart
+++ b/lib/features/dnd/nav_rail.dart
@@ -131,6 +131,9 @@ class _NavRowVisual extends StatefulWidget {
   State<_NavRowVisual> createState() => _NavRowVisualState();
 }
 
+/// Width of the hovered drop row's ring.
+const double _dropRingWidth = 2;
+
 class _NavRowVisualState extends State<_NavRowVisual> {
   bool _hover = false;
 
@@ -168,10 +171,25 @@ class _NavRowVisualState extends State<_NavRowVisual> {
       behavior: HitTestBehavior.opaque,
       child: Container(
         margin: const EdgeInsets.symmetric(vertical: 1),
-        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
+        // The hovered drop row carries a 2 px ring (MADR 0064 F2), so the
+        // cue does not rest on a 16-point alpha difference alone. The ring
+        // takes exactly its width out of the padding: the row never changes
+        // size, so the rows below never shift under the pointer mid-drag.
+        padding: widget.activeDrop
+            ? const EdgeInsets.symmetric(
+                horizontal: 10 - _dropRingWidth,
+                vertical: 7 - _dropRingWidth,
+              )
+            : const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
         decoration: BoxDecoration(
           color: bg,
           borderRadius: BorderRadius.circular(6),
+          border: widget.activeDrop
+              ? Border.all(
+                  color: MacosColors.systemGreenColor,
+                  width: _dropRingWidth,
+                )
+              : null,
         ),
         child: Row(
           children: [
diff --git a/lib/features/dnd/staging_drop_banner.dart b/lib/features/dnd/staging_drop_banner.dart
index 00c61c9..f9440db 100644
--- a/lib/features/dnd/staging_drop_banner.dart
+++ b/lib/features/dnd/staging_drop_banner.dart
@@ -2,6 +2,7 @@ import 'package:flutter/cupertino.dart';
 import 'package:flutter_riverpod/flutter_riverpod.dart';
 import 'package:macos_ui/macos_ui.dart' show MacosColors, MacosIcon, MacosTheme;
 
+import 'drag_hover_scope.dart';
 import 'drag_item.dart';
 import 'drag_state.dart';
 
@@ -51,53 +52,62 @@ class StagingDropBanner extends ConsumerWidget {
         ? CupertinoIcons.plus_circle
         : CupertinoIcons.minus_circle;
 
-    return DragTarget<DragItem>(
-      onWillAcceptWithDetails: (details) => details.data is DragFiles,
-      onAcceptWithDetails: (details) {
-        // ESC does unmount this banner (the build watches the drag state), but
-        // the rebuild lands a frame later — a release inside that frame would
-        // still hit the old target. Same runtime guard as every DropZone.
-        if (ref.read(dragStateProvider) is! DragFiles) return;
-        final paths = (details.data as DragFiles).paths;
-        if (toStage) {
-          onStage(paths);
-        } else {
-          onUnstage(paths);
-        }
-      },
-      builder: (context, candidate, rejected) {
-        final hovering = candidate.isNotEmpty;
-        return Container(
-          margin: const EdgeInsets.all(8),
-          height: 40,
-          decoration: BoxDecoration(
-            color: color.withValues(alpha: hovering ? 0.28 : 0.14),
-            borderRadius: BorderRadius.circular(8),
-            border: Border.all(
-              color: color.withValues(alpha: hovering ? 0.95 : 0.5),
-              width: hovering ? 2 : 1,
+    return DragHoverScope(
+      builder: (_, hover) => DragTarget<DragItem>(
+        onWillAcceptWithDetails: (details) => details.data is DragFiles,
+        // Hover report for the drag image (MADR 0064 F2), guarded by the same
+        // acceptance test: Flutter calls onMove on rejecting targets too.
+        onMove: (details) {
+          if (details.data is DragFiles) hover.setOverTarget(true);
+        },
+        onLeave: (_) => hover.setOverTarget(false),
+        onAcceptWithDetails: (details) {
+          hover.setOverTarget(false);
+          // ESC does unmount this banner (the build watches the drag state), but
+          // the rebuild lands a frame later — a release inside that frame would
+          // still hit the old target. Same runtime guard as every DropZone.
+          if (ref.read(dragStateProvider) is! DragFiles) return;
+          final paths = (details.data as DragFiles).paths;
+          if (toStage) {
+            onStage(paths);
+          } else {
+            onUnstage(paths);
+          }
+        },
+        builder: (context, candidate, rejected) {
+          final hovering = candidate.isNotEmpty;
+          return Container(
+            margin: const EdgeInsets.all(8),
+            height: 40,
+            decoration: BoxDecoration(
+              color: color.withValues(alpha: hovering ? 0.28 : 0.14),
+              borderRadius: BorderRadius.circular(8),
+              border: Border.all(
+                color: color.withValues(alpha: hovering ? 0.95 : 0.5),
+                width: hovering ? 2 : 1,
+              ),
             ),
-          ),
-          child: Row(
-            mainAxisAlignment: MainAxisAlignment.center,
-            children: [
-              MacosIcon(icon, size: 16, color: color),
-              const SizedBox(width: 8),
-              Flexible(
-                child: Text(
-                  label,
-                  maxLines: 1,
-                  overflow: TextOverflow.ellipsis,
-                  style: MacosTheme.of(context).typography.body.copyWith(
-                    color: color,
-                    fontWeight: FontWeight.w600,
+            child: Row(
+              mainAxisAlignment: MainAxisAlignment.center,
+              children: [
+                MacosIcon(icon, size: 16, color: color),
+                const SizedBox(width: 8),
+                Flexible(
+                  child: Text(
+                    label,
+                    maxLines: 1,
+                    overflow: TextOverflow.ellipsis,
+                    style: MacosTheme.of(context).typography.body.copyWith(
+                      color: color,
+                      fontWeight: FontWeight.w600,
+                    ),
                   ),
                 ),
-              ),
-            ],
-          ),
-        );
-      },
+              ],
+            ),
+          );
+        },
+      ),
     );
   }
 }
diff --git a/lib/features/history/history_view.dart b/lib/features/history/history_view.dart
index fa8486a..ed4d884 100644
--- a/lib/features/history/history_view.dart
+++ b/lib/features/history/history_view.dart
@@ -42,6 +42,7 @@ import '../common/workspace_focus.dart';
 import '../common/workspace_navigation.dart';
 import '../common/workspace_preferences_binding.dart';
 import '../dnd/deselect.dart';
+import '../dnd/drag_hover_scope.dart';
 import '../dnd/drag_item.dart';
 import '../dnd/drag_state.dart';
 import '../forge/forge_prefs.dart';
@@ -2168,126 +2169,139 @@ class _HistoryViewState extends ConsumerState<HistoryView>
                 final row = graph.rows[index];
                 final commit = row.commit;
                 final selected = _selectedHashes.contains(commit.hash);
-                return DragTarget<DragItem>(
-                  // A branch chip dropped anywhere on a commit row opens the integrate
-                  // menu; the row it lands on is just the drop affordance. Only a
-                  // dragged branch (DragRef) is meaningful here — a dragged commit
-                  // is bound for the nav rail, not another commit.
-                  onWillAcceptWithDetails: (details) {
-                    final data = details.data;
-                    return data is DragRef && _canDropBranch(data.ref);
-                  },
-                  onAcceptWithDetails: (details) {
-                    // ESC-cancelled drags release as a no-op (see DragStateNotifier).
-                    if (ref.read(dragStateProvider) == null) return;
-                    final data = details.data;
-                    if (data is DragRef) {
-                      _onBranchDropped(data.ref, commit, details.offset);
-                    }
-                  },
-                  builder: (context, candidate, rejected) {
-                    final dropHover = candidate.isNotEmpty;
-                    // The row is itself draggable (immediate: mouse-first — see
-                    // DragItemDraggable) — drop a commit on the Branches tab to
-                    // fork a branch, on Worktrees for a worktree, etc.
-                    return DragItemDraggable(
-                      item: DragCommit(commit),
-                      immediate: true,
-                      // Picking a row up selects it — the canonical engine
-                      // contract, so the drag operand is never ambiguous.
-                      onDragSelect: () => _selectForDrag(commit.hash),
-                      child: GestureDetector(
-                        key: _commitRowKeyFor(commit.hash),
-                        onTap: () => _handleRowTap(commit.hash),
-                        onSecondaryTapUp: (d) =>
-                            _handleRowSecondaryTap(commit, d.globalPosition),
-                        child: Container(
-                          color: dropHover
-                              ? MacosColors.systemGreenColor.withValues(
-                                  alpha: 0.20,
-                                )
-                              : selected
-                              ? MacosColors.systemBlueColor.withValues(
-                                  alpha: 0.32,
-                                )
-                              : const Color(0x00000000),
-                          height: rowHeight,
-                          child: Row(
-                            children: [
-                              // Clip to the fixed band so rounding in the compressed-lane
-                              // math can never paint a hair over the ref chips, subject, or
-                              // author text to the right — every lane itself is still drawn
-                              // (compressed via `laneWidth` above once the count exceeds
-                              // the cap), never dropped.
-                              ClipRect(
-                                child: CustomPaint(
-                                  size: Size(graphWidth, rowHeight),
-                                  painter: CommitRowPainter(
-                                    row,
-                                    laneWidth: laneWidth,
-                                    scale: zoom,
+                // Per-row hover owner: a row recycled away mid-drag gives
+                // the hover back (MADR 0064 F2).
+                return DragHoverScope(
+                  builder: (_, hover) => DragTarget<DragItem>(
+                    // A branch chip dropped anywhere on a commit row opens the integrate
+                    // menu; the row it lands on is just the drop affordance. Only a
+                    // dragged branch (DragRef) is meaningful here — a dragged commit
+                    // is bound for the nav rail, not another commit.
+                    onWillAcceptWithDetails: (details) =>
+                        _acceptsBranchDrop(details.data),
+                    // Hover report for the drag image (MADR 0064 F2), guarded
+                    // by the same acceptance test: Flutter calls onMove on
+                    // rejecting targets too (a dragged commit crosses rows).
+                    onMove: (details) {
+                      if (_acceptsBranchDrop(details.data)) {
+                        hover.setOverTarget(true);
+                      }
+                    },
+                    onLeave: (_) => hover.setOverTarget(false),
+                    onAcceptWithDetails: (details) {
+                      hover.setOverTarget(false);
+                      // ESC-cancelled drags release as a no-op (see DragStateNotifier).
+                      if (ref.read(dragStateProvider) == null) return;
+                      final data = details.data;
+                      if (data is DragRef) {
+                        _onBranchDropped(data.ref, commit, details.offset);
+                      }
+                    },
+                    builder: (context, candidate, rejected) {
+                      final dropHover = candidate.isNotEmpty;
+                      // The row is itself draggable (immediate: mouse-first — see
+                      // DragItemDraggable) — drop a commit on the Branches tab to
+                      // fork a branch, on Worktrees for a worktree, etc.
+                      return DragItemDraggable(
+                        item: DragCommit(commit),
+                        immediate: true,
+                        // Picking a row up selects it — the canonical engine
+                        // contract, so the drag operand is never ambiguous.
+                        onDragSelect: () => _selectForDrag(commit.hash),
+                        child: GestureDetector(
+                          key: _commitRowKeyFor(commit.hash),
+                          onTap: () => _handleRowTap(commit.hash),
+                          onSecondaryTapUp: (d) =>
+                              _handleRowSecondaryTap(commit, d.globalPosition),
+                          child: Container(
+                            color: dropHover
+                                ? MacosColors.systemGreenColor.withValues(
+                                    alpha: 0.20,
+                                  )
+                                : selected
+                                ? MacosColors.systemBlueColor.withValues(
+                                    alpha: 0.32,
+                                  )
+                                : const Color(0x00000000),
+                            height: rowHeight,
+                            child: Row(
+                              children: [
+                                // Clip to the fixed band so rounding in the compressed-lane
+                                // math can never paint a hair over the ref chips, subject, or
+                                // author text to the right — every lane itself is still drawn
+                                // (compressed via `laneWidth` above once the count exceeds
+                                // the cap), never dropped.
+                                ClipRect(
+                                  child: CustomPaint(
+                                    size: Size(graphWidth, rowHeight),
+                                    painter: CommitRowPainter(
+                                      row,
+                                      laneWidth: laneWidth,
+                                      scale: zoom,
+                                    ),
                                   ),
                                 ),
-                              ),
-                              const SizedBox(width: 8),
-                              Expanded(
-                                child: Column(
-                                  mainAxisAlignment: MainAxisAlignment.center,
-                                  crossAxisAlignment: CrossAxisAlignment.start,
-                                  children: [
-                                    Row(
-                                      children: [
-                                        if (commit.isMerge) ...[
-                                          MacosIcon(
-                                            CupertinoIcons.arrow_merge,
-                                            size: 13 * zoom,
+                                const SizedBox(width: 8),
+                                Expanded(
+                                  child: Column(
+                                    mainAxisAlignment: MainAxisAlignment.center,
+                                    crossAxisAlignment:
+                                        CrossAxisAlignment.start,
+                                    children: [
+                                      Row(
+                                        children: [
+                                          if (commit.isMerge) ...[
+                                            MacosIcon(
+                                              CupertinoIcons.arrow_merge,
+                                              size: 13 * zoom,
+                                            ),
+                                            const SizedBox(width: 4),
+                                          ],
+                                          // Subject first (Tower / Fork / GitHub Desktop): the
+                                          // message is primary. Chips are intrinsically sized
+                                          // (capped per chip + maxVisible) so they never compete
+                                          // with the subject for flex space and collapse to
+                                          // zero width — the pop-out bug that hid every badge.
+                                          Expanded(
+                                            child: Text(
+                                              commit.subject,
+                                              style: typography.body,
+                                              maxLines: 1,
+                                              overflow: TextOverflow.ellipsis,
+                                            ),
                                           ),
-                                          const SizedBox(width: 4),
+                                          if ((decorations[commit.hash] ??
+                                                  const <GitRef>[])
+                                              .isNotEmpty) ...[
+                                            const SizedBox(width: 6),
+                                            RefChipStrip(
+                                              refs: decorations[commit.hash]!,
+                                              enableDrag: true,
+                                            ),
+                                          ],
                                         ],
-                                        // Subject first (Tower / Fork / GitHub Desktop): the
-                                        // message is primary. Chips are intrinsically sized
-                                        // (capped per chip + maxVisible) so they never compete
-                                        // with the subject for flex space and collapse to
-                                        // zero width — the pop-out bug that hid every badge.
-                                        Expanded(
-                                          child: Text(
-                                            commit.subject,
-                                            style: typography.body,
-                                            maxLines: 1,
-                                            overflow: TextOverflow.ellipsis,
-                                          ),
+                                      ),
+                                      const SizedBox(height: 2),
+                                      Text(
+                                        '${commit.shortHash}  ·  ${commit.authorName}  ·  '
+                                        '${_shortDate(commit.date)}',
+                                        style: typography.caption1.copyWith(
+                                          color: MacosColors.systemGrayColor,
                                         ),
-                                        if ((decorations[commit.hash] ??
-                                                const <GitRef>[])
-                                            .isNotEmpty) ...[
-                                          const SizedBox(width: 6),
-                                          RefChipStrip(
-                                            refs: decorations[commit.hash]!,
-                                            enableDrag: true,
-                                          ),
-                                        ],
-                                      ],
-                                    ),
-                                    const SizedBox(height: 2),
-                                    Text(
-                                      '${commit.shortHash}  ·  ${commit.authorName}  ·  '
-                                      '${_shortDate(commit.date)}',
-                                      style: typography.caption1.copyWith(
-                                        color: MacosColors.systemGrayColor,
+                                        maxLines: 1,
+                                        overflow: TextOverflow.ellipsis,
                                       ),
-                                      maxLines: 1,
-                                      overflow: TextOverflow.ellipsis,
-                                    ),
-                                  ],
+                                    ],
+                                  ),
                                 ),
-                              ),
-                              const SizedBox(width: 8),
-                            ],
+                                const SizedBox(width: 8),
+                              ],
+                            ),
                           ),
                         ),
-                      ),
-                    );
-                  },
+                      );
+                    },
+                  ),
                 );
               },
             ),
@@ -2308,6 +2322,12 @@ class _HistoryViewState extends ConsumerState<HistoryView>
     return null;
   }
 
+  /// Whether a commit row takes this drag: only a dragged branch it can
+  /// integrate. One predicate for both the accept decision and the hover
+  /// report, so the two can never disagree.
+  bool _acceptsBranchDrop(DragItem data) =>
+      data is DragRef && _canDropBranch(data.ref);
+
   /// A drop is meaningful only when a branch is dragged and there's a current
   /// branch that differs from it (a branch can't be merged/rebased with itself).
   bool _canDropBranch(GitRef dragged) {
```

Phase 6: the hover-aware drag image, adding `lib/features/dnd/drag_hover_scope.dart` (`git apply --index`).

### A.15 `drag_hover_feedback_test.dart`

```dart
// MADR 0064 F2 (Confirmation 2): the drag image must never hide the drop
// target under the pointer.
//
// Over an accepting target the lifted snapshot collapses to a compact chip
// whose top-left sits at pointer + kDragChipPointerOffset, so neither the
// pointer nor the hovered row is covered; off any target (or once Esc cancels
// the drag) the full lifted snapshot returns and a cancelled release still
// flies home. The hovered nav-rail row also carries a border, so the cue does
// not rest on a 16-point alpha difference alone.
//
// Real gestures only (tester.startGesture / moveTo): the snapshot is captured
// under fake async, so the ghost geometry measured here is the real one.

import 'package:flutter/cupertino.dart' hide ConnectionState;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/features/dnd/drag_cell.dart';
import 'package:remote_magic_git/features/dnd/drag_item.dart';
import 'package:remote_magic_git/features/dnd/drop_registry.dart';
import 'package:remote_magic_git/features/dnd/nav_rail.dart';

/// Minimal connection state so a DropZone sees an active repoPath.
class _FakeConnection extends ConnectionController {
  @override
  ConnectionState build() =>
      const ConnectionState(phase: ConnectionPhase.connected, repoPath: '/r');
}

const _commit = DragCommit(
  GitCommit(
    hash: 'a1b2c3d4e5f6',
    shortHash: 'a1b2c3d',
    authorName: 'Dev',
    authorEmail: 'd@e',
    date: '2026-07-16T10:00',
    parents: [],
    subject: 'a change',
  ),
);

const _items = [
  NavRailItem(
    icon: CupertinoIcons.folder,
    label: 'Repository',
    zone: DropZoneId.repository,
  ),
  NavRailItem(
    icon: CupertinoIcons.arrow_branch,
    label: 'Branches',
    zone: DropZoneId.branches,
  ),
  NavRailItem(
    icon: CupertinoIcons.tray_2,
    label: 'Stashes',
    zone: DropZoneId.stashes,
  ),
  NavRailItem(
    icon: CupertinoIcons.tree,
    label: 'Worktrees',
    zone: DropZoneId.worktrees,
  ),
];

const _sourceKey = ValueKey('source-row');

/// A point well clear of the rail and the source row: no drop target here.
const _neutral = Offset(1000, 400);

/// Long enough for any lift/collapse animation to settle while the pointer
/// is held.
const _settle = Duration(milliseconds: 300);

/// The rail (240 px, as the shell's minimum sidebar) beside a 900 x 52 source
/// row standing in for a History commit row at zoom 1.0.
Future<void> _pump(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1400, 700);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [connectionProvider.overrideWith(_FakeConnection.new)],
      child: MacosApp(
        debugShowCheckedModeBanner: false,
        home: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 240,
              height: 600,
              child: NavRail(
                currentIndex: 0,
                onChanged: (_) {},
                items: _items,
                selectPage: (_) {},
                refresh: () {},
              ),
            ),
            const DragItemDraggable(
              item: _commit,
              immediate: true,
              child: SizedBox(
                key: _sourceKey,
                width: 900,
                height: 52,
                child: ColoredBox(
                  color: Color(0xFF3E597B),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text('SOURCE commit row'),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Presses the source row [grabDx] px in from its left edge and lifts it.
Future<TestGesture> _lift(WidgetTester tester, {required double grabDx}) async {
  final source = tester.getRect(find.byKey(_sourceKey));
  final gesture = await tester.startGesture(
    Offset(source.left + grabDx, source.center.dy),
  );
  await tester.pump(const Duration(milliseconds: 100));
  await gesture.moveBy(const Offset(0, -20)); // past the drag slop
  await tester.pump(_settle);
  return gesture;
}

/// Holds the drag over the centre of the "New branch" rail row and returns the
/// pointer position.
Future<Offset> _hoverNewBranch(WidgetTester tester, TestGesture gesture) async {
  final pointer = tester.getCenter(_navRowOf('New branch'));
  await gesture.moveTo(pointer);
  await tester.pump(_settle);
  return pointer;
}

/// The nav-rail row's decorated container (the one carrying its background).
Finder _navRowOf(String label) =>
    find.ancestor(of: find.text(label), matching: find.byType(Container)).first;

BoxDecoration _decorationOf(WidgetTester tester, String label) =>
    tester.widget<Container>(_navRowOf(label)).decoration! as BoxDecoration;

/// The drag image. Exactly one cell chrome may be on screen at a time.
Rect _ghost(WidgetTester tester) {
  expect(find.byType(DragCellChrome), findsOneWidget);
  return tester.getRect(find.byType(DragCellChrome));
}

Future<void> _release(WidgetTester tester, TestGesture gesture) async {
  await gesture.moveTo(_neutral);
  await tester.pump(_settle);
  await gesture.up();
  await tester.pumpAndSettle();
}

void main() {
  group('grab at x = 300, held over "New branch"', () {
    testWidgets('(a) the drag image does not contain the pointer', (
      tester,
    ) async {
      await _pump(tester);
      final gesture = await _lift(tester, grabDx: 300);
      final pointer = await _hoverNewBranch(tester, gesture);

      final ghost = _ghost(tester);
      expect(
        ghost.contains(pointer),
        isFalse,
        reason: 'ghost $ghost covers the pointer $pointer',
      );

      await _release(tester, gesture);
    });

    testWidgets('(b) the drag image does not overlap the hovered row', (
      tester,
    ) async {
      await _pump(tester);
      final gesture = await _lift(tester, grabDx: 300);
      await _hoverNewBranch(tester, gesture);

      final ghost = _ghost(tester);
      final row = tester.getRect(_navRowOf('New branch'));
      final overlap = ghost.intersect(row);
      expect(
        overlap.width <= 0 || overlap.height <= 0,
        isTrue,
        reason: 'ghost $ghost overlaps the hovered row $row by $overlap',
      );

      await _release(tester, gesture);
    });

    testWidgets('(c) only the hovered row carries a border', (tester) async {
      await _pump(tester);
      final gesture = await _lift(tester, grabDx: 300);
      await _hoverNewBranch(tester, gesture);

      expect(
        _decorationOf(tester, 'New branch').border,
        isNotNull,
        reason: 'the hovered (activeDrop) row must carry a border',
      );
      expect(
        _decorationOf(tester, 'New worktree').border,
        isNull,
        reason: 'an eligible row that is not hovered must not',
      );

      await _release(tester, gesture);
    });

    testWidgets('(f) the chip is capped and sits at the pointer offset', (
      tester,
    ) async {
      await _pump(tester);
      final gesture = await _lift(tester, grabDx: 300);
      final pointer = await _hoverNewBranch(tester, gesture);

      final ghost = _ghost(tester);
      // The lift's 1.03 scale is allowed for in both checks.
      expect(ghost.width, lessThanOrEqualTo(kDragChipMaxWidth * 1.03 + 1));
      final expected = pointer + kDragChipPointerOffset;
      expect(ghost.left, closeTo(expected.dx, 5));
      expect(ghost.top, closeTo(expected.dy, 5));

      await _release(tester, gesture);
    });

    testWidgets('(d) moving off the target restores the full lifted image', (
      tester,
    ) async {
      await _pump(tester);
      final gesture = await _lift(tester, grabDx: 300);
      await _hoverNewBranch(tester, gesture);

      await gesture.moveTo(_neutral);
      await tester.pump(_settle);
      expect(_ghost(tester).width, greaterThanOrEqualTo(400));

      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets('(e) Esc while hovering restores the full image and the '
        'release still flies home', (tester) async {
      await _pump(tester);
      final gesture = await _lift(tester, grabDx: 300);
      await _hoverNewBranch(tester, gesture);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump(_settle);
      expect(_ghost(tester).width, greaterThanOrEqualTo(400));

      await gesture.up();
      await tester.pump();
      expect(find.byType(SnapBackFlight), findsOneWidget);

      await tester.pumpAndSettle();
      expect(find.byType(SnapBackFlight), findsNothing);
    });
  });

  group('left-edge grab (x = 40), held over "New branch"', () {
    testWidgets('(a) the drag image does not contain the pointer', (
      tester,
    ) async {
      await _pump(tester);
      final gesture = await _lift(tester, grabDx: 40);
      final pointer = await _hoverNewBranch(tester, gesture);

      final ghost = _ghost(tester);
      expect(
        ghost.contains(pointer),
        isFalse,
        reason: 'ghost $ghost covers the pointer $pointer',
      );

      await _release(tester, gesture);
    });

    testWidgets('(b) the drag image does not overlap the hovered row', (
      tester,
    ) async {
      await _pump(tester);
      final gesture = await _lift(tester, grabDx: 40);
      await _hoverNewBranch(tester, gesture);

      final ghost = _ghost(tester);
      final row = tester.getRect(_navRowOf('New branch'));
      final overlap = ghost.intersect(row);
      expect(
        overlap.width <= 0 || overlap.height <= 0,
        isTrue,
        reason: 'ghost $ghost overlaps the hovered row $row by $overlap',
      );

      await _release(tester, gesture);
    });
  });
}
```

Phase 6: `test/drag_hover_feedback_test.dart`.

### A.16 `drag_target_hover_scan_test.dart`

```dart
// MADR 0064 F2 (Confirmation 2): every drop target for the app's drag payload
// reports hover, so the drag image can collapse to its compact chip and stop
// hiding the target under the pointer.
//
// A `DragTarget<DragItem>` that never calls `setOverTarget` would bring the
// occlusion back for that one target, silently. This scan finds every such
// target in lib/ and requires both halves of the report; it also pins the set
// of files, so adding a target is a conscious decision, not an accident.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _marker = 'DragTarget<DragItem>';

/// The drop targets known when F2 landed. A new one must be added here, and
/// must report hover like these do.
const _knownTargets = {
  'lib/features/dnd/drop_zone.dart',
  'lib/features/branches/branch_navigator.dart',
  'lib/features/history/history_view.dart',
  'lib/features/dnd/staging_drop_banner.dart',
};

/// Every .dart file under lib/, as a POSIX path relative to the package root.
List<File> _libDartFiles() {
  final lib = Directory('lib');
  if (!lib.existsSync()) {
    throw StateError('lib/ not found: run from the package root');
  }
  return [
    for (final entity in lib.listSync(recursive: true))
      if (entity is File && entity.path.endsWith('.dart')) entity,
  ];
}

String _posix(File file) => file.path.replaceAll(r'\', '/');

void main() {
  late List<File> files;
  late Set<String> targets;

  setUpAll(() {
    files = _libDartFiles();
    targets = {
      for (final file in files)
        if (file.readAsStringSync().contains(_marker)) _posix(file),
    };
  });

  test('the scan actually read lib/', () {
    // A scan that found nothing to read would pass every check below.
    expect(files.length, greaterThan(100));
    expect(targets, isNotEmpty);
  });

  test('the DragTarget<DragItem> sites are exactly the known four', () {
    expect(
      targets,
      equals(_knownTargets),
      reason:
          'A drop target was added or removed. Make it report hover '
          '(setOverTarget(true) in onMove, setOverTarget(false) in onLeave '
          'and on accept), then update _knownTargets.',
    );
  });

  test('every DragTarget<DragItem> reports hover both ways', () {
    final missing = <String>[];
    for (final path in targets.toList()..sort()) {
      final source = File(path).readAsStringSync();
      for (final call in const [
        'setOverTarget(true)',
        'setOverTarget(false)',
      ]) {
        if (!source.contains(call)) missing.add('$path: no $call');
      }
    }
    expect(missing, isEmpty);
  });
}
```

Phase 6: `test/drag_target_hover_scan_test.dart`.

### A.17 `drag_hover_unmount_test.dart`

```dart
// MADR 0064 F2: a drop target that is removed from the tree while it holds
// the drag's hover must give the hover back.
//
// Flutter never calls onLeave on an unmounted target, so without an owner
// that releases on dispose the drag image would stay a compact chip over
// empty space until the release. Ownership also means removing a target that
// no longer holds the hover must not take it from the target that does.
//
// The release lands in the frame after the removal: the target is disposed
// while the widget tree is locked, where the drag image cannot be marked for
// rebuild, so the clear is deferred to the end of that frame.

import 'package:flutter/cupertino.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/features/dnd/drag_cell.dart';
import 'package:remote_magic_git/features/dnd/drag_item.dart';
import 'package:remote_magic_git/features/dnd/drop_registry.dart';
import 'package:remote_magic_git/features/dnd/drop_zone.dart';

/// Minimal connection state so a DropZone sees an active repoPath.
class _FakeConnection extends ConnectionController {
  @override
  ConnectionState build() =>
      const ConnectionState(phase: ConnectionPhase.connected, repoPath: '/r');
}

const _commit = DragCommit(
  GitCommit(
    hash: 'a1b2c3d4e5f6',
    shortHash: 'a1b2c3d',
    authorName: 'Dev',
    authorEmail: 'd@e',
    date: '2026-07-16T10:00',
    parents: [],
    subject: 'a change',
  ),
);

const _sourceKey = ValueKey('source-row');

/// A point well clear of the targets and the source row.
const _neutral = Offset(1000, 500);

/// Long enough for the lift animation to settle while the pointer is held.
const _settle = Duration(milliseconds: 300);

/// The compact chip's widest on-screen size (the lift's 1.03 scale allowed).
const _chipMaxOnScreen = kDragChipMaxWidth * 1.03 + 1;

/// Two Branches drop zones (both accept a dragged commit) above a 900 x 52
/// source row. [visible] names the targets currently in the tree, so a test
/// can remove one mid-drag while the pointer is still held.
Future<void> _pump(
  WidgetTester tester,
  ValueNotifier<Set<String>> visible,
) async {
  tester.view.physicalSize = const Size(1400, 700);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [connectionProvider.overrideWith(_FakeConnection.new)],
      child: MacosApp(
        debugShowCheckedModeBanner: false,
        home: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              height: 60,
              child: ValueListenableBuilder<Set<String>>(
                valueListenable: visible,
                builder: (context, names, _) => Row(
                  children: [
                    for (final name in const ['A', 'B'])
                      if (names.contains(name))
                        SizedBox(
                          width: 200,
                          height: 40,
                          child: DropZone(
                            key: ValueKey('zone-$name'),
                            id: DropZoneId.branches,
                            selectPage: (_) {},
                            refresh: () {},
                            builder: (context, hovering) =>
                                Center(child: Text('TARGET $name')),
                          ),
                        )
                      else
                        const SizedBox(width: 200, height: 40),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 100),
            const DragItemDraggable(
              item: _commit,
              immediate: true,
              child: SizedBox(
                key: _sourceKey,
                width: 900,
                height: 52,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('SOURCE commit row'),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Presses the source row 300 px in from its left edge and lifts it.
Future<TestGesture> _lift(WidgetTester tester) async {
  final source = tester.getRect(find.byKey(_sourceKey));
  final gesture = await tester.startGesture(
    Offset(source.left + 300, source.center.dy),
  );
  await tester.pump(const Duration(milliseconds: 100));
  await gesture.moveBy(const Offset(0, -20)); // past the drag slop
  await tester.pump(_settle);
  return gesture;
}

/// The drag image's on-screen width. Exactly one cell chrome at a time.
double _ghostWidth(WidgetTester tester) {
  expect(find.byType(DragCellChrome), findsOneWidget);
  return tester.getRect(find.byType(DragCellChrome)).width;
}

Future<void> _release(WidgetTester tester, TestGesture gesture) async {
  await gesture.moveTo(_neutral);
  await tester.pump(_settle);
  await gesture.up();
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('removing the hovered target mid-drag restores the full image', (
    tester,
  ) async {
    final visible = ValueNotifier<Set<String>>({'A', 'B'});
    addTearDown(visible.dispose);
    await _pump(tester, visible);
    final gesture = await _lift(tester);

    await gesture.moveTo(tester.getCenter(find.text('TARGET A')));
    await tester.pump(_settle);
    expect(
      _ghostWidth(tester),
      lessThanOrEqualTo(_chipMaxOnScreen),
      reason: 'precondition: over an accepting target the image is a chip',
    );

    // Remove A with the pointer still held over where it was. Flutter will
    // never call A's onLeave: only its disposal can give the hover back.
    visible.value = {'B'};
    await tester.pump(); // the frame that disposes A
    await tester.pump(); // the frame after it: the deferred release lands
    expect(find.text('TARGET A'), findsNothing);
    expect(
      _ghostWidth(tester),
      greaterThanOrEqualTo(400),
      reason: 'the removed target held the hover; the full image must return',
    );

    await _release(tester, gesture);
  });

  testWidgets('removing a target that no longer holds the hover leaves the '
      'hovered target in charge', (tester) async {
    final visible = ValueNotifier<Set<String>>({'A', 'B'});
    addTearDown(visible.dispose);
    await _pump(tester, visible);
    final gesture = await _lift(tester);

    await gesture.moveTo(tester.getCenter(find.text('TARGET A')));
    await tester.pump(_settle);
    await gesture.moveTo(tester.getCenter(find.text('TARGET B')));
    await tester.pump(_settle);
    expect(
      _ghostWidth(tester),
      lessThanOrEqualTo(_chipMaxOnScreen),
      reason: 'precondition: B now holds the hover',
    );

    visible.value = {'B'}; // dispose A, which left before B was entered
    await tester.pump();
    await tester.pump();
    expect(find.text('TARGET A'), findsNothing);
    expect(
      _ghostWidth(tester),
      lessThanOrEqualTo(_chipMaxOnScreen),
      reason: "A's disposal must not clear B's live hover",
    );

    await _release(tester, gesture);
  });
}
```

Phase 6: `test/drag_hover_unmount_test.dart`.

### A.18 `shot.py`

```python
"""Capture a process's front window into <out-dir>/<name>.png, downscaled to 1400 px.

Usage: shot.py <pid> <name> <out-dir>
"""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path


def bounds(pid: int) -> tuple[int, int, int, int]:
    script = (f'tell application "System Events" to tell (first process whose unix id is {pid}) '
              'to get {position, size} of window 1')
    out = subprocess.run(["osascript", "-e", script], capture_output=True, text=True,
                         timeout=10, check=True).stdout
    x, y, w, h = (int(v) for v in out.replace(" ", "").strip().split(","))
    return x, y, w, h


def main() -> None:
    pid, name, out_dir = int(sys.argv[1]), sys.argv[2], Path(sys.argv[3])
    out_dir.mkdir(parents=True, exist_ok=True)
    x, y, w, h = bounds(pid)
    path = out_dir / f"{name}.png"
    subprocess.run(["screencapture", "-x", f"-R{x},{y},{w},{h}", str(path)], check=True, timeout=10)
    subprocess.run(["sips", "-Z", "1400", str(path)], capture_output=True, check=True, timeout=10)
    print(f"{path} window={x},{y},{w},{h}")


if __name__ == "__main__":
    main()
```

Phase 7: window capture.

### A.19 `png_sample.py`

```python
"""Average RGB of rectangles in an 8-bit non-interlaced PNG (stdlib only).

Usage: png_sample.py <png> <label>=x0,y0,x1,y1 [...]   (pixel coordinates)
"""
from __future__ import annotations

import struct
import sys
import zlib
from pathlib import Path


def decode(path: Path) -> tuple[int, int, int, list[bytearray]]:
    data = path.read_bytes()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG"
    pos, idat, width = 8, bytearray(), 0
    while pos < len(data):
        length, kind = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + length]
        if kind == b"IHDR":
            width, height, depth, ctype, _, _, interlace = struct.unpack(">IIBBBBB", body)
            assert depth == 8 and interlace == 0 and ctype in (2, 6), (depth, ctype, interlace)
            bpp = 4 if ctype == 6 else 3
        elif kind == b"IDAT":
            idat += body
        pos += 12 + length
    raw, stride, rows, prev = zlib.decompress(idat), width * bpp, [], bytearray(width * bpp)
    for y in range(height):
        f, line = raw[y * (stride + 1)], bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for i in range(stride):
            a = line[i - bpp] if i >= bpp else 0
            b, c = prev[i], (prev[i - bpp] if i >= bpp else 0)
            if f == 1: line[i] = (line[i] + a) & 255
            elif f == 2: line[i] = (line[i] + b) & 255
            elif f == 3: line[i] = (line[i] + (a + b) // 2) & 255
            elif f == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[i] = (line[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        rows.append(line)
        prev = line
    return width, height, bpp, rows


def main() -> None:
    width, height, bpp, rows = decode(Path(sys.argv[1]))
    print(f"{width}x{height} bpp={bpp}")
    for spec in sys.argv[2:]:
        label, box = spec.split("=")
        x0, y0, x1, y1 = (int(v) for v in box.split(","))
        acc, n = [0, 0, 0], 0
        for y in range(y0, y1):
            for x in range(x0, x1):
                px = rows[y][x * bpp:x * bpp + 3]
                acc = [s + v for s, v in zip(acc, px)]
                n += 1
        print(f"{label:>14}: rgb=({acc[0]//n:3d},{acc[1]//n:3d},{acc[2]//n:3d})")


if __name__ == "__main__":
    main()
```

Phase 7: mean RGB of rectangles in a PNG (stdlib only).
