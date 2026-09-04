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
| 0022 | [git/gh/glab engine debug audit](0022-MADR-git-gh-glab-engine-debug-audit.md) | `accepted` | [plan](0022-PLAN-git-gh-glab-engine-debug-audit.md) | `executed` through Phase 14; **Phase 15 open (live host)** |

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

Documents also record their own residuals. Where a status says `executed` and
the body names something outstanding, the body wins — it is more specific.
