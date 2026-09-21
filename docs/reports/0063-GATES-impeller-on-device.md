---
status: "complete"
date: 2026-09-21
verified: 2026-09-21
---

# Impeller on-device gate (0063)

Plan: [0063-PLAN](../decisions/0063-PLAN-adopt-impeller-renderer-on-macos.md) ·
MADR: [0063-MADR](../decisions/0063-MADR-adopt-impeller-renderer-on-macos.md)

This records the Phase 2–4 results of the plan. The deviation notes are in the plan's execution
record (D1–D3). Paths under the scratch directory are written `$S`. Screenshots and logs stayed
there as executor evidence and are not committed.

| Field | Value |
|---|---|
| Commit under test | `47745ec` (declares `FLTEnableImpeller` = `true`) |
| Flutter | `Flutter 3.47.2 • channel stable • https://github.com/flutter/flutter.git` |
| Hardware / macOS | Apple M1 Pro / 26.6.2 |
| Displays | 3 (`Resolution:` lines in `system_profiler SPDisplaysDataType`) |
| Bundle key (2.3) | `true` |
| Architectures (2.4) | `arm64` |
| Renderer line (2.5) | `[IMPORTANT:flutter/shell/platform/embedder/embedder_surface_metal_impeller.mm(53)] Using the Impeller rendering backend (MetalSDF).` |
| Fixture (3.0) | HEAD `d98ca40df2f6ddbd11df2c54baa613553c083c72`; 3116 commits, 29 merges, 4 worktrees |
| CI job (3.0) | `pick_ci_job.py` exit 0: run 34915619825, job 104212477125 "Dependabot", 2968 lines |

## Gate items

The on-device gate was run by the maintainer (G1–G4, G9) and then by the executor, driving the
app through `cliclick` and Accessibility (G5–G8 retest, Phase 4). Every step of the executor's run
has a screenshot.

| Item | Result | Observation (verbatim or measured) | Evidence |
|---|---|---|---|
| G1 Vibrancy punch-through | PASS | Maintainer: "g1 pass". The executor's captures show the desktop blur through the sidebar and the Files pane, and the sidebar dims while the window is inactive. | `$S/shots/r3a.png`, `p4-state.png` |
| G2a History window | PASS | Maintainer: "g2a pass". The window opened for the restored remote tab, not the fixture; it still exercised the second engine. | `$S/app-stderr.log` |
| G2b Detached windows | PASS | Maintainer: "the windows are open and look fine". Five windows were open at once; `hw-debug.log` shows `revealing window[2..4]`. | `~/hw-debug.log` |
| G3 #185394 repro | PASS | (a), (c) and (d) passed. For (b), the maintainer pressed ⇧⌘F, which did nothing; the plan's ⌃⌘F has no binding in the app (plan defect, D2), and the step passed using the green button. The process stayed alive, and no crash report appeared. | `crash-before.txt` vs `crash-now*.txt` |
| G4 Blurred minimap | PASS | Maintainer: "G4 passed". The executor's captures show a continuous minimap wash. | `$S/shots/r1-cleared.png` |
| G5 Commit graph under zoom | PASS | Zoom 0.6, 1.0, 1.3 and 2.0: lanes continuous, curves smooth, nodes round. ⌘=, ⌘- and ⌘0 work in the wide layout (window 1659 pt). They do nothing in the compact layout (900 pt) on **both** renderers: the pre-existing trap recorded in D3. | `r1-zoom06.png`, `r1-zoomed.png`, `r1-zoom20.png`, `r2-esc.png`, `skia-r2-small.png` |
| G6 Monospace text | PASS | Menlo glyphs are uniform in the diff and code views. "Toggle Output View" flipped "Show Output View" ✓ → unchecked (read through Accessibility); the pane exists only on the Repository page, where the toggle visibly hides and shows it (D3). | `r1-history.png`, `r3a.png`, `r3b.png` |
| G7 Large paragraph | PASS | Run 34915622630, job 104212484924, 1,708 lines. This is a Dependabot run beside the one 3.0 picked; it is equally eligible under the 1,500-line threshold. The "permissions" text is the log's own runner banner (`##[group]GITHUB_TOKEN Permissions`, `Contents: read`), the same text the CLI prints at line 21. Scrolling to the end and ⌘A each completed within the 2 s wait; CPU was 0.1% afterwards. | `r4-job.png`, `r4-selectall.png`, `$S/r4-joblog.txt` |
| G8 Drag ghost | PASS | The drag image is the row snapshot. Dropping on New branch opened "New branch from commit" (cancelled; the fixture still had 33 branches on `main`). The hover tint renders, as the mean RGB of each rail row's right end shows: hovered (58–59, 89–91, 63–66), eligible (49–50, 65–67, 54–57), ineligible (39, 39–40, 46). A left-edge grab covers the hovered row with the drag image, measured at (62, 89, 123): the pre-existing occlusion recorded in D3. | `rail-hover-*.png`, `rail-leftgrab-*.png` |
| G9 Images | PASS | Maintainer: "G9 all passed". | — |
| G10 Memory baseline | Recorded | `Magic Git [63683]: 64-bit    Footprint: 437 MB (16384 bytes per page)`; `phys_footprint: 430 MB`; `phys_footprint_peak: 589 MB`. Taken with the main window, History and three detached windows open. | `$S/footprint.txt` |
| 3.x crash reports | none | `ls ~/Library/Logs/DiagnosticReports/` shows no new `Magic Git*` file at any check (six diffs across Phases 2–4). | `crash-now*.txt` |
| 4.2 vsync probe | PASS | `(child 1) frame timings[1]: 1 frames, vsyncStart=1573996685736µs rasterFinish=1573996694523µs` / `(child 1) frame timings[2]: 57 frames, vsyncStart=0µs rasterFinish=1573996710525µs` / `(child 1) vsync probe: completed value=1.0 mouseConnected=true` | `$S/probe.log` |

## Renderer A/B (D2)

A throwaway Skia build (`FLTEnableImpeller` = `false`, from a scratch clone of `47745ec`, never
committed or installed) logged `FlutterEngine.mm(685)] Using the Skia rendering backend (Metal).`

| Check | Impeller | Skia |
|---|---|---|
| G5 wide: ⌘= zooms, list beside diff | yes | yes |
| G5 compact: list removed, ⌘F and Esc do nothing | yes | yes |
| G8 hovered / eligible / ineligible row RGB | (58–59, 89–91, 63–66) / (49–50, 65–67, 54–57) / (39, 39–40, 46) | (59–60, 90–92, 63–64) / (49–50, 65–68, 54–56) / (39, 39–40, 46–47) |
| G8 left-edge grab, hovered row | (62, 89, 123), the drag image | (55, 83, 119), the drag image |

Every anomaly reported during Phase 3 reproduces identically on Skia, so none of them is caused
by Impeller. They are recorded as D3 and go to a separate decision record.

## Notes

* The second engine's clock still stalls intermittently on Impeller: the second timings batch
  reports `vsyncStart=0µs`. The `SecondaryWindowBinding` self-heal is still load-bearing.
* Every engine start logs Flutter's deprecation warning for split UI/platform threads, which
  comes from the existing `FLTEnableMergedPlatformUIThread` = `false`.
* During the maintainer's session the fixture was fetched and pulled from its `origin`, which
  changed its history and `main`. This did not affect any renderer result.
