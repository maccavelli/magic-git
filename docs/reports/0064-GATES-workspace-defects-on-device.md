---
status: "complete"
date: 2026-09-22
verified: 2026-09-22
---

# Workspace defects on-device gate (0064)

Plan: [0064-PLAN](../decisions/0064-PLAN-workspace-reachability-feedback-and-log-fidelity.md) ·
MADR: [0064-MADR](../decisions/0064-MADR-workspace-reachability-feedback-and-log-fidelity.md)

This records step 7.3 of the plan — the on-device confirmation of the six fixes (F1–F6) through
the five gate items D1–D5. The deviations found while running it are in the plan's execution
record (D4 the synthetic-input artifact, D5 the CPU spin, D6 the Output pane's placement); this
record states results, not decisions. Paths under the executor's scratch directory are written
`$S`; screenshots and logs stayed there and are not committed.

| Field | Value |
|---|---|
| Fixes under test | F1 compact navigation, F2 drag hover, F3 Output view, F4 CI log sanitizer, F5 SSH cipher, F6 coalescer test |
| Commit that completed the plan's engineering | `718a354` |
| Renderer | Impeller (MetalSDF), confirmed at launch by 0063-PLAN's launcher |
| Flutter | 3.47.2 (the pin in `build_macos.sh`) |
| Build | `./build_macos.sh --unsigned`, exit 0, tree clean, `FLTEnableImpeller` `true` |
| Fixture | the 0063 gate's fixture repository, opened through Recent Repositories |

**Two things the reader needs, stated rather than implied.**

* **The gate ran in two sittings.** D1 compact History was confirmed by the executor on
  2026-09-21 with `cliclick` and Accessibility, every step captured. The rest were confirmed by
  the maintainer on 2026-09-22 ("phase 7 checks pass"), on their installed build of that
  evening. That build carries the plan's engineering plus MADR Amendment 0064.1, 0065, and 0066
  Phases 1–2; the only 0064 code it changes is F3's placement, which is what 0064.1 amended and
  what D3 below exercises.
* **Keyboard sequences are maintainer-run.** The plan's procedure was amended mid-gate (D4):
  synthetic modifier chords leave `HardwareKeyboard` believing ⌘ is held, which made an
  executor-driven Esc fail where a real keyboard succeeds. Anything involving a chord is the
  maintainer's observation, not a driven one.

## Gate items

| Item | Result | Observation | Evidence |
|---|---|---|---|
| **D1 compact History** | PASS | Window 900 pt. A row click shows the diff under a "‹ Commits" bar; Esc, ⌘[ and a click on the bar each return to the list with the previous row still selected. One earlier ⌘[ attempt was discarded as evidence because a stray ⌘← preceded it. | `$S/shots/*` (executor, 2026-09-21) |
| **D1 compact Branches and Worktrees** | PASS | The same sequence with ⌘3 ("‹ Branches") and ⌘6 ("‹ Worktrees"); on Worktrees the list is visible before any click. | Maintainer, 2026-09-22 |
| **D2 drag hover** | PASS | Width 1659 pt. Dragging a commit row grabbed 60 pt from its left edge and holding it over "New branch": the row reads green rather than blue, a green ring is visible, and the drag image collapses to a compact chip below and right of the pointer. | Maintainer, 2026-09-22 |
| **D3 Output everywhere** | PASS | ⇧⌘O shows and hides the Output pane on History and on Branches. Observed in passing by the executor at 900 pt on 2026-09-21, and confirmed by the maintainer on the amended layout (Amendment 0064.1), where Repository docks the pane beside the full-height File view and every other page spans it. | Maintainer, 2026-09-22; `$S/shots/*` |
| **D4 CI log** | PASS | The job log's first screen carries no `^[`, no `UNKNOWN STEP`, and every line begins with its timestamp. | Maintainer, 2026-09-22 |
| **D5 SSH cipher** | PASS (informational) | A remote session loads History without a UI stall. F5's pass/fail check is the negotiated-cipher test, not this observation. | Maintainer, 2026-09-22 |

## Acceptance

AC7 of the plan — "D1–D4 PASS on the device (Impeller), and D5 is recorded" — is met: D1
(all three pages), D2, D3 and D4 PASS, and D5 is recorded above. AC1–AC6 were met during the
engineering phases and are evidenced in the plan's execution record.

## What this gate found, and where it went

Three defects surfaced while running it. None is open.

* **D4 — Esc after a keyboard navigation.** Withdrawn as an app defect: an artifact of synthetic
  input. The maintainer's real keyboard returns to the list every time. The procedure was
  amended instead of the code.
* **D5 — ~115% CPU for as long as the window is visible**, after selecting a branch and then a
  commit. Diagnosed with a probe build to a per-frame navigation-recording loop that predates
  0064, and fixed under
  [0065-MADR](../decisions/0065-MADR-record-workspace-navigation-on-location-change.md); the
  reproduction reads ≤ 0.1% on the fixed build.
* **D6 — the Output pane spanned the File view** on Repository, cutting off the file tree. That
  was a consequence MADR 0064 had accepted; the maintainer rejected it, and Amendment 0064.1
  returns the pane to the centre column with a geometry regression test.
