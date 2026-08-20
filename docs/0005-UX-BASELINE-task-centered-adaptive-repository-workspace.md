---
status: "partial"
date: 2026-08-13
verified: 2026-08-20
---

# UX baseline for the task-centered adaptive repository workspace

Associated decision:
[0005-MADR-task-centered-adaptive-repository-workspace.md](0005-MADR-task-centered-adaptive-repository-workspace.md)

Associated implementation plan:
[0005-PLAN-task-centered-adaptive-repository-workspace.md](0005-PLAN-task-centered-adaptive-repository-workspace.md)

- Baseline date: 2026-08-13
- Revision: pre-Phase 1 workspace implementation
- Measurement status: code and automated characterization captured; interactive
  macOS task-study and profile-mode frame measurements unavailable in the
  non-interactive implementation environment
- Integrity rule: `unavailable` means no number was observed. No unavailable
  result is replaced by an estimate.

## Measurement protocol

Each follow-up run must use a release or profile macOS build, begin from a
freshly opened repository tab, and retain screen recording plus a timestamped
observer log. A click is one primary or secondary pointer activation. A
keystroke is one physical key chord, so Command-K counts as one. Backtracking
means revisiting a prior screen, reopening a dismissed surface, or reversing an
accidental selection. Expected remote waiting time is not an error; missing or
ambiguous acknowledgement is.

The repository fixtures are fixed as follows:

| Fixture | Shape |
| --- | --- |
| `mixed-small` | 2 staged, 5 unstaged, 1 untracked, 1 partially staged path, 1 configured remote |
| `branch-forge` | 50 local refs, 50 remote refs, current branch with an open request and one failing check |
| `recovery` | A safely undoable branch delete or reset with a valid snapshot and reflog entry |
| `remote-failure` | SSH repository whose next user-started fetch fails with a deterministic non-secret stderr fixture |
| `worktrees` | Main worktree plus 3 linked worktrees, one locked and one dirty |
| `history-blame` | 500 commits and a selected tracked file with at least 20 revisions |

Window fixtures are 640×480 logical pixels (`compact`), 1080×720
(`standard`), and 1440×900 (`wide`). Run each task once with a local backend
and once over SSH at every width. Keep repository contents identical between
backend runs.

## Interactive task baseline

The six required tasks could not be executed honestly in this environment:
there is no human participant, configured baseline SSH host, or instrumented
profile build. The matrix is retained so the same protocol can be filled in
without changing columns or selectively omitting difficult cases.

| Task | Backend | Window | Repository fixture | Time | Clicks/chords | Wrong turns | Errors | Observer notes |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Form a partial commit from mixed changes | Local | 640×480 | `mixed-small` | unavailable | unavailable | unavailable | unavailable | Interactive run required |
| Form a partial commit from mixed changes | SSH | 640×480 | `mixed-small` | unavailable | unavailable | unavailable | unavailable | Interactive run required |
| Form a partial commit from mixed changes | Local | 1080×720 | `mixed-small` | unavailable | unavailable | unavailable | unavailable | Interactive run required |
| Form a partial commit from mixed changes | SSH | 1080×720 | `mixed-small` | unavailable | unavailable | unavailable | unavailable | Interactive run required |
| Form a partial commit from mixed changes | Local | 1440×900 | `mixed-small` | unavailable | unavailable | unavailable | unavailable | Interactive run required |
| Form a partial commit from mixed changes | SSH | 1440×900 | `mixed-small` | unavailable | unavailable | unavailable | unavailable | Interactive run required |
| Inspect a branch and its request/checks | Local | 640×480 | `branch-forge` | unavailable | unavailable | unavailable | unavailable | Interactive run required |
| Inspect a branch and its request/checks | SSH | 640×480 | `branch-forge` | unavailable | unavailable | unavailable | unavailable | Interactive run required |
| Inspect a branch and its request/checks | Local | 1080×720 | `branch-forge` | unavailable | unavailable | unavailable | unavailable | Interactive run required |
| Inspect a branch and its request/checks | SSH | 1080×720 | `branch-forge` | unavailable | unavailable | unavailable | unavailable | Interactive run required |
| Inspect a branch and its request/checks | Local | 1440×900 | `branch-forge` | unavailable | unavailable | unavailable | unavailable | Interactive run required |
| Inspect a branch and its request/checks | SSH | 1440×900 | `branch-forge` | unavailable | unavailable | unavailable | unavailable | Interactive run required |
| Recover a destructive action | Local | 640×480 | `recovery` | unavailable | unavailable | unavailable | unavailable | Interactive run required |
| Recover a destructive action | SSH | 640×480 | `recovery` | unavailable | unavailable | unavailable | unavailable | Interactive run required |
| Recover a destructive action | Local | 1080×720 | `recovery` | unavailable | unavailable | unavailable | unavailable | Interactive run required |
| Recover a destructive action | SSH | 1080×720 | `recovery` | unavailable | unavailable | unavailable | unavailable | Interactive run required |
| Recover a destructive action | Local | 1440×900 | `recovery` | unavailable | unavailable | unavailable | unavailable | Interactive run required |
| Recover a destructive action | SSH | 1440×900 | `recovery` | unavailable | unavailable | unavailable | unavailable | Interactive run required |
| Diagnose a failed remote operation | Local | 640×480 | `remote-failure` | unavailable | unavailable | unavailable | unavailable | Local executor failure fixture required |
| Diagnose a failed remote operation | SSH | 640×480 | `remote-failure` | unavailable | unavailable | unavailable | unavailable | Instrumented SSH run required |
| Diagnose a failed remote operation | Local | 1080×720 | `remote-failure` | unavailable | unavailable | unavailable | unavailable | Local executor failure fixture required |
| Diagnose a failed remote operation | SSH | 1080×720 | `remote-failure` | unavailable | unavailable | unavailable | unavailable | Instrumented SSH run required |
| Diagnose a failed remote operation | Local | 1440×900 | `remote-failure` | unavailable | unavailable | unavailable | unavailable | Local executor failure fixture required |
| Diagnose a failed remote operation | SSH | 1440×900 | `remote-failure` | unavailable | unavailable | unavailable | unavailable | Instrumented SSH run required |
| Create or open a worktree | Local | 640×480 | `worktrees` | unavailable | unavailable | unavailable | unavailable | Interactive run required |
| Create or open a worktree | SSH | 640×480 | `worktrees` | unavailable | unavailable | unavailable | unavailable | Interactive run required |
| Create or open a worktree | Local | 1080×720 | `worktrees` | unavailable | unavailable | unavailable | unavailable | Interactive run required |
| Create or open a worktree | SSH | 1080×720 | `worktrees` | unavailable | unavailable | unavailable | unavailable | Interactive run required |
| Create or open a worktree | Local | 1440×900 | `worktrees` | unavailable | unavailable | unavailable | unavailable | Interactive run required |
| Create or open a worktree | SSH | 1440×900 | `worktrees` | unavailable | unavailable | unavailable | unavailable | Interactive run required |
| Find the history and blame of a file | Local | 640×480 | `history-blame` | unavailable | unavailable | unavailable | unavailable | Interactive run required |
| Find the history and blame of a file | SSH | 640×480 | `history-blame` | unavailable | unavailable | unavailable | unavailable | Interactive run required |
| Find the history and blame of a file | Local | 1080×720 | `history-blame` | unavailable | unavailable | unavailable | unavailable | Interactive run required |
| Find the history and blame of a file | SSH | 1080×720 | `history-blame` | unavailable | unavailable | unavailable | unavailable | Interactive run required |
| Find the history and blame of a file | Local | 1440×900 | `history-blame` | unavailable | unavailable | unavailable | unavailable | Interactive run required |
| Find the history and blame of a file | SSH | 1440×900 | `history-blame` | unavailable | unavailable | unavailable | unavailable | Interactive run required |

## Characterization evidence

The pre-workspace behavior is pinned by these tests:

| Contract | Evidence |
| --- | --- |
| Section-scoped Finder-style selection and selection re-homing | `test/repo_status_view_test.dart`, group `multi-select` |
| Partially staged paths remain independently actionable | `test/repo_status_view_test.dart`, `Stage All stays active while a partially-staged file still has...` |
| Diff mode and side-by-side keyboard toggles | `test/keyboard_shortcuts_test.dart`, `test/diff_popout_window_test.dart`, and `test/split_diff_view_test.dart` |
| Generated, manual, loading, failure, Accept, and Accept + Push commit states | `test/commit_dialog_test.dart` |
| Output visibility is isolated to the active repository tab | `test/tabs_host_test.dart`, menu routing group |
| Pane drag, persistence, reset, display clamp, and degenerate-width behavior | `test/resizable_master_detail_test.dart` |
| Palette local-branch and worktree targets | `test/command_palette_test.dart` |
| Visited pages stay mounted while hidden and continue shared refresh behavior | `AppShell._pages`'s lazy `IndexedStack` plus `test/repo_status_watch_refresh_test.dart` |

`test/workspace_performance_baseline_test.dart` adds deterministic 2,000-file
porcelain and 20,000-line diff fixtures. It records parser throughput as a
diagnostic, but intentionally has no wall-clock assertion because shared CI
machine timings are not a stable correctness contract.

## Command and frame baseline

| Scenario | Command count | p95 duration | Frame timing | Status |
| --- | --- | --- | --- | --- |
| Initial Repository paint, local | unavailable | unavailable | unavailable | Requires instrumented profile run |
| Initial Repository paint, SSH | unavailable | unavailable | unavailable | Requires configured SSH fixture |
| Select eight prefetched files, local | unavailable | unavailable | unavailable | Requires instrumented profile run |
| Select eight prefetched files, SSH | unavailable | unavailable | unavailable | Requires configured SSH fixture |
| Open Branches, local | unavailable | unavailable | unavailable | Requires instrumented profile run |
| Open Branches, SSH | unavailable | unavailable | unavailable | Requires configured SSH fixture |
| Open Forge, local | unavailable | unavailable | unavailable | Requires cached forge fixture and profile run |
| Open Forge, SSH | unavailable | unavailable | unavailable | Requires configured SSH/forge fixture |
| Render 2,000-file Repository status | n/a | n/a | unavailable | Deterministic data fixture is checked in; profile frame capture required |
| Render 20,000-line diff | n/a | n/a | unavailable | Deterministic data fixture is checked in; profile frame capture required |

The automated test prints `WORKSPACE_BASELINE status_parse_2000_us=...` and
`WORKSPACE_BASELINE diff_parse_20000_us=...` for local diagnostic comparison.
These values describe parser throughput, not UI frame timing, and must not be
used as a substitute for the missing profile-mode measurements.

The first clean run on the implementation host measured 4,996 µs for the
2,000-file parser fixture and 22,020 µs for the 20,000-line diff parser
fixture. These single-run diagnostics are saved only as a regression clue;
they are neither p95 values nor cross-machine performance gates.

## Follow-up acceptance worksheet

After Phase 11, duplicate the task matrix with observed values and report:

1. Median interaction-step change for partial stage-review-commit.
2. Error-rate and backtracking change for every task.
3. Time to first visible acknowledgement for each remote mutation.
4. Keyboard-only completion and VoiceOver announcements.
5. Overflow, clipping, and primary-action reachability at all three widths.
6. Command count, p95 command duration, build/raster p50 and p95, and worst
   frame for both the 2,000-file and 20,000-line fixtures.

## Phase 9 automated follow-up — 2026-08-13

The deterministic portion of the Phase 9 gate is now implemented and green.
Human timing, VoiceOver listening, and a configured SSH task-study remain
explicitly `unavailable`; the baseline integrity rule above still applies.

| Gate | Follow-up result | Evidence |
| --- | --- | --- |
| Explicit pane focus | Context 1, navigator 2, canvas 4, inspector 5, task dock 6, activity 7; direct actions are remappable and unbound by default | `test/workspace_accessibility_test.dart` |
| Semantic regions | All workspace roles have stable names; loading, stale, partial-error, and error states carry non-color/live-region descriptions | `test/workspace_accessibility_test.dart`, `test/workspace_async_views_test.dart` |
| Target and motion | Inline targets enforce the 28 px compact token; list navigation, inline actions, and focus treatment use zero duration when animations are disabled | `test/workspace_accessibility_test.dart` |
| Width and text scale | 640×480, 1080×720, and 1600×1000 pass at 1.0×, 1.3×, and 1.6× with the primary action reachable and no overflow | `test/workspace_responsive_test.dart` |
| Visual matrix | 48 checked-in DPR-1 fixtures cover 16 required states/screens at all three sizes | `test/workspace_golden_test.dart`, `test/goldens/workspace/` |
| 2,000-file filter | 2,690 µs median on the implementation host; 55,000 µs hard budget (recorded 50,000 µs baseline + 10%) | `test/workspace_performance_baseline_test.dart` |
| 20,000-line diff | 20,831 µs diagnostic parse/flatten; the production `DiffParser` selects its guarded background-isolate path | `test/workspace_performance_baseline_test.dart` |
| Passive chrome/palette | Rendering pure workspace chrome and ranking an empty palette query record zero executor commands | `test/workspace_performance_baseline_test.dart` |
| Hidden/provider budget | 500-ref Branches remains bounded; Forge and other visited pages stop polling/streaming when inactive; Forge chrome consumes only landed cache values | `test/branches_phase7_command_budget_test.dart`, `test/github_panel_test.dart`, `test/gitlab_panel_test.dart` |

The same host's Phase 0 clues were 4,996 µs for status parsing and 22,020 µs
for diff parsing. The Phase 9 diagnostic run measured 4,588 µs and 20,831 µs
respectively. These are improvements of approximately 8% and 5%; they remain
single-host clues, not portable wall-clock contracts. The deterministic filter
budget and off-isolate branch are the enforced regression contracts.

The expanded dock fixture also exposed a recursive closure capture in the
adaptive pane composition. Phase 9 fixed it by capturing the pre-dock canvas
before constructing the vertical pane pair and now exercises the combination
in accessibility and golden tests.

### Interactive follow-up status

No configured SSH fixture, profile-mode interactive harness, human participant,
or VoiceOver observer is available in this implementation session. Therefore:

| Required observation | Result |
| --- | --- |
| Local task-study repetitions | unavailable |
| SSH task-study repetitions | unavailable |
| Median stage-review-commit interaction reduction | unavailable |
| Human-observed error/backtracking rate | unavailable |
| Profile build/raster p50 and p95 | unavailable |
| VoiceOver announcement quality | unavailable |
| Maintainer visual acceptance of the 48 golden fixtures | pending review |

Automated coverage confirms standard committing remains inline, mutation
activity is acknowledged immediately, keyboard routes exist, and ordinary
tests introduce no error-rate regression. The human/SSH numbers must be filled
from the protocol above before claiming the observational portion of the core
release gate; they are not inferred from automated tests.
