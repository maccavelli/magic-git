# Decision records and implementation plans

Every architectural decision here is a MADR, and most are paired with an
implementation plan. `AGENTS.md` carries the naming and numbering rules; this
file is the index, and the one place to see what is actually live.

## Status vocabulary

Machine-readable in each file's YAML frontmatter. `verified:` is when the
status was last checked **against the code**, not when the document was
written.

| status | meaning |
|---|---|
| `proposed` | written, not yet decided. No code should exist for it. |
| `accepted` | decided. The decision governs the codebase. |
| `rejected` | decided against. Do not re-propose without new evidence. |
| `executed` | a plan whose engineering phases have shipped. Residuals, if any, are named in the document. |
| `partial` | some of the work is real, some was never done. The document says which. |

`executed` does not mean "nothing left". A plan can be executed and still list
residuals or maintainer-only steps — 0010's Phase 7 is the standing example.

## Index

| # | Record | Status | Plan | Status |
|---|---|---|---|---|
| 0001 | [Do not adopt libgit2/git2dart](0001-MADR-native-git-libgit2.md) | `rejected` | — | |
| 0002 | [Forge change-request models and merge UX](0002-MADR-forge-change-request-merge-and-models.md) | `accepted` | [plan](0002-PLAN-forge-change-request-merge-and-models.md) | `executed` (Phase 6 partial) |
| 0003 | [Base-relative branches workspace](0003-MADR-base-relative-branches-workspace.md) | `accepted` | [plan](0003-PLAN-base-relative-branches-workspace.md) | `executed` |
| 0004 | [UI/UX deep-debug audit backlog](0004-MADR-ui-ux-deep-debug-audit.md) | `accepted` | [plan](0004-PLAN-ui-ux-deep-debug-audit.md) | `executed` |
| 0005 | [Task-centered adaptive workspace](0005-MADR-task-centered-adaptive-repository-workspace.md) | `accepted` | [plan](0005-PLAN-task-centered-adaptive-repository-workspace.md) · [UX baseline](0005-UX-BASELINE-task-centered-adaptive-repository-workspace.md) | `executed` · baseline `partial` |
| 0006 | [Hybrid native title bar](0006-MADR-hybrid-native-title-bar-context-bar.md) | `accepted` | [plan](0006-PLAN-hybrid-native-title-bar-context-bar.md) | `executed` |
| 0007 | [Docs completion audit](0007-MADR-docs-completion-audit.md) | `accepted` | [plan](0007-PLAN-docs-completion-audit.md) | `executed` (Phase 7 maintainer) |
| 0008 | [Unified repository chrome](0008-MADR-unified-repository-chrome.md) | `accepted` | [plan](0008-PLAN-unified-repository-chrome.md) | `executed` |
| 0009 | [UI/UX debug-pass backlog](0009-MADR-ui-ux-debug-pass-backlog.md) | `accepted` | [plan](0009-PLAN-ui-ux-debug-pass-backlog.md) | `executed` |
| 0010 | [In-app Help Book rewrite](0010-MADR-in-app-help-book-rewrite.md) | `accepted` | [plan](0010-PLAN-in-app-help-book-rewrite.md) | `executed` through Phase 6; **Phase 7 open** |
| 0011 | [SSH transport stability hardening](0011-MADR-ssh-transport-stability-hardening.md) | `accepted` | [plan](0011-PLAN-ssh-transport-stability-hardening.md) | `executed` |
| 0011 | [Toolbar slot schema migration](0011-MADR-toolbar-slot-schema-migration.md) ⚠ | `accepted` | — | |
| 0012 | [Adopt dartssh2 3.3.0](0012-MADR-adopt-dartssh2-v3.md) | `accepted` | [plan](0012-PLAN-adopt-dartssh2-v3.md) | `executed` |
| 0012 | [Focused commit composer sheet](0012-MADR-commit-composer-focused-sheet.md) ⚠ | `accepted` | [plan](0012-PLAN-commit-composer-focused-sheet.md) | `executed` |
| 0013 | [Prefer dartssh2 over dartssh3](0013-MADR-prefer-dartssh2-v3-over-dartssh3.md) | `accepted` | [plan](0013-PLAN-prefer-dartssh2-v3-over-dartssh3.md) | `executed` |
| 0014 | [SSH engine next-wave hardening](0014-MADR-ssh-engine-next-wave-hardening.md) | `accepted` | [plan](0014-PLAN-ssh-engine-next-wave-hardening.md) | `executed` |
| 0015 | [SSH engine and UI unit-test gaps](0015-MADR-ssh-engine-and-ui-unit-test-gaps.md) | `accepted` | [plan](0015-PLAN-ssh-engine-and-ui-unit-test-gaps.md) · [tail](0016-PLAN-ssh-engine-and-ui-coverage-tail.md) | both `executed` |
| 0017 | [Enforce conventions in source](0017-MADR-provider-retry-policy-on-providers.md) | `accepted` | [plan](0017-PLAN-provider-retry-policy-on-providers.md) | `executed` |
| 0018 | [Transport readiness is not an error](0018-MADR-transport-readiness-is-not-an-error.md) | `accepted` | [plan](0018-PLAN-transport-readiness-is-not-an-error.md) | `executed` (deviation recorded) |
| 0019 | [Pin glab to the repo origin host](0019-MADR-pin-glab-origin-host-on-every-call.md) | `accepted` | [plan](0019-PLAN-pin-glab-origin-host-on-every-call.md) | `executed` through Phase 7; **Phase 8 open** |
| 0020 | [Fetch/pull/push lag](0020-MADR-fetch-pull-push-lag.md) | `accepted` | [plan](0020-PLAN-fetch-pull-push-lag.md) | `executed` |
| 0021 | [Create-repo identity stays per-repo](0021-MADR-create-repo-identity-and-origin.md) | `accepted` | [plan](0021-PLAN-create-repo-identity-and-origin.md) | `executed` |
| 0022 | [git/gh/glab engine debug audit](0022-MADR-git-gh-glab-engine-debug-audit.md) | `accepted` | [plan](0022-PLAN-git-gh-glab-engine-debug-audit.md) | `executed`; Phase 15 run 2026-09-04 — **M5 CONFIRMED on the real host and reopened** (19 orphaned watchers, oldest 16.9 days; cleared, defect open) |
| 0023 | [Commit-and-push perceived freeze](0023-MADR-commit-and-push-perceived-freeze.md) | `accepted` (amended) | [plan](0023-PLAN-commit-and-push-perceived-freeze.md) | `executed`; live-app measurement done 2026-09-04 — **123 git processes vs the ≈22–40 assumed**; refresh-repetition open |
| 0024 | [SSH / remote-repo engine debug audit](0024-MADR-ssh-and-remote-repo-engine-debug-audit.md) | `accepted` (amended A1.1, A2.1, L2) | [plan](0024-PLAN-ssh-and-remote-repo-engine-debug-audit.md) | `complete`; M2 confirmed and P1 measured live 2026-09-04. **Phase 8 (P2) not executed** |
| 0025 | [Host process economy](0025-MADR-unaccounted-host-side-work.md) | `accepted` | [plan](0025-PLAN-unaccounted-host-side-work.md) | `complete`; **every phase resolved** — 1-5, 7, 9 executed; 6, 8, 11, 12 declined on evidence; 10 already implemented. Measured 123→76 processes per commit+push and **0 while idle**. D1 declined on measurement (amendment D1.1). Findings C4/C5 carried by 0026-0029. Residuals named in the plan: two aggregate ceilings unbuilt (nothing can exceed them), orphan target needs a week of elapsed time |
| 0026 | [Degraded-watch poll diagnosis](0026-MADR-degraded-watch-poll-diagnosis.md) | `accepted` (amended 0026.1) | [plan](0026-PLAN-degraded-watch-poll-diagnosis.md) | `complete`; **H1 CONFIRMED by test** (`Expected: <2> / Actual: <1>`) and fixed by serialising `start()`. Post-fix capture confirms the 5s poll regime is gone (142s idle silence, 2 watchers at the ceiling). H2/H3 open, not refuted; capture raised **0025 C5** |
| 0027 | [Watcher reclamation cannot reclaim](0027-MADR-watcher-reclamation-cannot-reclaim.md) | `accepted` | [plan](0027-PLAN-watcher-reclamation-cannot-reclaim.md) | `complete`; all 5 phases executed. The sweep **could never kill anything** (recorded a shell pid, signalled only `inotifywait`/`fswatch`, via Linux-only `/proc`) — now `ps`-verified identity + per-instance lease/registry files + per-instance staleness + legacy reclamation. Amendment 0027.1: pre-fix orphans are **irrecoverable** (their pid record was overwritten) and need a one-time manual kill — done on the host |
| 0028 | [Ceiling refusal and teardown residue](0028-MADR-ceiling-refusal-and-teardown-residue.md) | `proposed` | [plan](0028-PLAN-ceiling-refusal-and-teardown-residue.md) | `complete`; all 5 phases executed. **H2 confirmed and fixed** — refusals are typed and a ceiling-refused repo takes a freed slot at once instead of polling at 48 processes/min. **H3 resolved by consequence** of 0026+0027 — an abandoned watcher self-terminated at 371s, measured; no remedy needed. Ceiling scope: no defect (amendment 0028.1) |
| 0029 | [Host scripts must be executed by a test](0029-MADR-host-scripts-must-be-executed-by-a-test.md) | `proposed` | [plan](0029-PLAN-host-scripts-must-be-executed-by-a-test.md) | `complete`; a `contains(...)` on script text may pin composition, never behaviour. Went from **1 of 6 host scripts executed by a test to 5 of 6**, with the installer permanently exempt and its reason recorded; a scan reads `lib/` and fails on any unclassified builder. This is the gap that shipped a sweep which could never reclaim anything (0027) |
| 0030 | [Test coverage gaps are shaped, not sized](0030-MADR-test-coverage-gaps-are-shaped-not-sized.md) | `proposed` | — | `proposed`; measured **81.4 % line coverage, zero files uncovered** — and five defects in one session, four of them in covered code. Names four failure *shapes* coverage cannot see (seam, composition-vs-behaviour, parity, in-flight state), measures a lopsided executor seam (`ProxyCommandExecutor` 1 test file vs SSH's 126), and proposes 8 tests by risk. **Recommends against adopting a coverage target** |

⚠ **0011 and 0012 each carry two unrelated records.** `AGENTS.md` forbids
renumbering an existing file, so both keep the number and each carries a note
naming its twin. **Cite records by full filename, never by number alone.**

0016 has a plan but no MADR of its own: it is the second tranche of
[0015-MADR](0015-MADR-ssh-engine-and-ui-unit-test-gaps.md), and took the next
free number because `0015-PLAN-*` was taken.

## What "verified" means here

Statuses were last audited on **2026-09-03** against the tree, in the manner
0007 established: each claim checked against code rather than taken from the
document. Three plans were found asserting the opposite of reality —
0006-PLAN ("ready to execute"), 0008-PLAN and 0009-PLAN ("proposed … no code
written") — while their work was demonstrably shipped. Those lines are
corrected in place and marked, not deleted.

The 2026-09-03 pass (0022) corrected one more: **0018 stood at `proposed`
while its decision was live in the code**, so the index was telling readers a
fixed bug class was still open. Both its files are now `accepted`/`executed`,
and the plan carries a late-recorded deviation — what shipped is an inline
readiness gate, not the `ReadinessGatedExecutor` decorator its Phase 1c
specified.

The 2026-09-04 pass (0024) corrected a second, wider one: `0022-PLAN` and
`0023-PLAN` both record a baseline of **48 failing goldens and 2 analyzer
warnings** as a known pre-existing set. Neither was real — both were artifacts
of running a Flutter that did not match `build_macos.sh`'s pin, which also
explains the `pubspec.lock` churn in `bd93c18`/`21721ef`. The pin is now
`3.47.2`, the suite is fully green, and both plans carry a correction block at
the top rather than a rewrite.

Documents also record their own residuals. Where a status says `executed` and
the body names something outstanding, the body wins — it is more specific.
