---
status: "complete"
verified: 2026-09-19
date: 2026-09-19
associated-madr: "0054-MADR-docs-link-checker-and-standard-layout-migration.md"
---

# Implement the documentation link checker and the standard layout migration

Associated MADR:
[0054-MADR-docs-link-checker-and-standard-layout-migration.md](0054-MADR-docs-link-checker-and-standard-layout-migration.md)
(`accepted`, 2026-09-19). Rule IDs R1–R6 are the MADR's. This plan cites them and does not repeat the
rationale.

## Goal

Ship the MADR's option C with C2:

1. **A checker in the gate.** `tool/records.dart` enforces R1–R6. `test/docs_records_test.dart` runs it
   under `flutter test`, against fixtures (each rule seen to fail) and against the real tree (nothing
   reported).
2. **The move.** Every record sits in `docs/decisions/` or `docs/reports/`, the build guide sits in
   `docs/guides/`, and nothing else sits in `docs/` except its index and `architecture.md`. This lands in
   one commit, with every link repaired and checked by target.
3. **A new `architecture.md`** describing the system as it is, with every factual claim checked against
   the code.
4. **`docs/README.md` as the tree's table of contents**, with the "I want to…" matrix, and complete by
   rule.
5. **`AGENTS.md` describes the tree as it is.** The "has not migrated yet" caveat is gone, and numbering
   points at `dart run tool/records.dart next`.

## Scope

### Files this plan may change

**New**

* `tool/records.dart` — the checker library and CLI (`dart:io` only).
* `test/docs_records_test.dart` — fixture tests and repository tests, tagged `integration` (it runs
  `git`).
* `tool/mutations/0054-doc-records.json` — the mutation catalogue.
* `architecture.md` in `docs/` (Phase 3).

**Moved with `git mv`** (content edits limited to link and path-mention repair, plus frontmatter where
stated in Phase 2):

* the 102 flat `NNNN-MADR-*` / `NNNN-PLAN-*` files, into `decisions/`, names unchanged;
* `0005-UX-BASELINE-task-centered-adaptive-repository-workspace.md`, into `reports/` as
  `0005-REPORT-ux-baseline-task-centered-adaptive-repository-workspace.md`;
* the eight unnumbered documents, per the MADR's mapping table (repeated in Phase 2).

**Edited in place**

* `docs/README.md` — link paths (Phase 2); restructure (Phase 4).
* `docs/decisions/0052-*` and `docs/decisions/0053-*` (four files) — link depth only (Phase 2).
* `README.md` — link paths (Phase 2); architecture pointer (Phase 3).
* `AGENTS.md` — Phases 1, 2, 3 and 4 as specified. `CLAUDE.md` and `.goosehints` are symlinks to it and
  are not edited.
* `.claude/skills/troubleshooting-magic-git/SKILL.md:174` — "a MADR under `docs/`" becomes
  "`docs/decisions/`".
* `test/drop_registry_test.dart:122`, `test/helpers/fake_watcher_handle.dart:18` — the path in the
  comment (Phase 2, by the rewriter).
* `lib/core/git/watch_path_filter.dart:34`, `test/ssh_live_transport_test.dart:6` — the document named
  in the comment (Phase 2, by hand).
* This PLAN and its MADR — statuses and execution record.

### Out of scope

* **Adding `verified:` to the 27 PLANs that lack it** (MADR, *More Information*). Deferred by the
  maintainer on 2026-09-19 to a separate statuses audit.
* The dotfiles repository's 0007-PLAN. Marking its Phase 6 done for this repository is the maintainer's
  call, and the handoff offers it.
* The content of any moved record other than link targets, `docs/…` path mentions, and the frontmatter
  specified below. Bare names are not rewritten (MADR, *The move*).
* Any statuses audit of moved records. The index keeps its current statuses.

## Conventions used by every phase

* **Pinned Flutter.** `flutter --version | head -1` must print `Flutter 3.47.2`, and
  `flutter pub get --enforce-lockfile` must print "Got dependencies!". If either disagrees, use
  `./.flutter-sdk/bin/flutter`.
* **Output goes to files.** Long runs are redirected into the session scratchpad (`$S` below), and exit
  status is captured in a variable, never read through a pipe:

  ```sh
  flutter test > "$S/test.log" 2>&1; RC=$?
  ```

* **Before staging:** `flutter analyze` is clean, and `flutter test` passes in full, both run after the
  last edit of the phase. `dart format --output=none --set-exit-if-changed <each changed .dart file>`
  passes.
* **Commit:** `git add <the phase's files>` then `git commit --no-edit`. The repository's hook writes the
  message, and it is read back with `git log -1 --format=%B` and checked against the phase. Never `-m`,
  never `git add -A`. **No push.**
* **Negative tests never dirty the tree.** They run against fixtures in a temporary directory, against a
  scratch clone in `$S`, or through `tool/mutate.py` (its own scratch worktree).
* **Writing convention for R3.** A record that names a file which does not exist yet, or a path that is
  about to move, writes it without the `docs/` prefix or inside a fenced block. This PLAN follows it:
  every command below that names an old path is fenced.
* **Deviations** stop the work and are raised with evidence, real resolutions and the cost of doing
  nothing. Each is recorded here with a date before it is executed (global rules).

## Implementation Steps

### Phase 0 — Baseline (no commit)

1. Check the Flutter pin and the lockfile, as above.
2. `flutter analyze > "$S/p0-analyze.log" 2>&1; RC=$?` — expect `RC=0`.
3. `flutter test > "$S/p0-test.log" 2>&1; RC=$?` — expect `RC=0`. Record the pass count from the log's
   final line, as the suite baseline.
4. Re-run the investigation inventory (scratch scripts `inventory.py`, `deep_check.py`, kept in `$S`) and
   record the numbers against the MADR's: 102/51/51 flat MADR/PLAN; 434 relative links inside `docs/` and
   10 outside; 6 anchored; 169 path mentions in prose and 1 fenced; 0 broken. **A difference is a
   deviation**: someone changed the docs since `9df6338`.
5. `git status --porcelain` must be empty except for this record pair. Anything else is someone else's
   work in flight, and is left alone.

### Phase 1 — The checker, green on the current tree

**1.1 `tool/records.dart`.** A library with a `main`. Public surface:

* `class Finding { String rule; String path; int line; String message; }`, with `toString()` as
  `path:line: rule: message`.
* `List<String> checkedFiles(Directory root)` — runs
  `git ls-files -z --cached --others --exclude-standard` in `root`, drops entries that no longer exist
  on disk, and drops symlinks (`FileSystemEntity.isLinkSync`).
* One function per rule, each `List<Finding> Function(Directory root, List<String> files)`:
  `checkLinks` (R1), `checkAnchors` (R2), `checkPathMentions` (R3), `checkNumbering` (R4),
  `checkFrontmatter` (R5), `checkLayout` (R6).
* `String nextNumber(Directory root, List<String> files)` — max record number over the whole repository,
  plus one, zero-padded to four digits.
* CLI: `dart run tool/records.dart check [--root <dir>] [--rules links,anchors,paths,numbering,frontmatter,layout]`
  prints findings and exits `1` if there are any, else `0`. `dart run tool/records.dart next [--root <dir>]`
  prints the number.

Markdown handling, shared by R1–R3:

* **Fences**: a line starting (after up to three spaces) with at least three backticks or tildes opens
  a fence. The fence closes at a line of the same character, at least as long. Nothing inside a fence is
  parsed.
* **Frontmatter**: `---` on line 1, until the next `---` line. It is excluded from R1–R3 (so a
  `former-path:` value is never checked or rewritten).
* **Inline code spans** (backtick runs, matched by length) are removed before links are extracted.
* **Blockquotes** (`^\s{0,3}>`) are excluded from R3 only. Links inside them are still links, and R1
  and R2 still check them.
* **Inline links and images**: `[text](target)` and `![alt](target)`, with an optional `<…>` wrapper and
  an optional title. **Reference definitions**: `^\s{0,3}\[label\]:\s*<?target>?`.
* **External** targets (a scheme matching `^[A-Za-z][A-Za-z0-9+.-]*:`, or starting `//`) are skipped.
  A target starting `/` resolves from the repository root. Anything else resolves from the file's
  directory, after `Uri.decodeComponent`.

Rule details:

* **R1** — the target path, without its fragment, exists as a file or directory.
* **R2** — when the fragment is non-empty and the target is a `.md` file (or the link is `#x` into its
  own file), the fragment matches one of the target's anchors. Anchors are GitHub's heading slugs:
  inline markup is removed from the heading text (backticks, `*`, and links replaced by their text);
  the text is lowercased; every character that is not a letter, digit, space, `-` or `_` is removed;
  spaces become `-`; a repeated slug gets `-1`, `-2`, and so on. Headings inside fences don't count.
  Explicit `<a id="…">` and `<a name="…">` anchors are added.
* **R3** — in `.md` files outside fences, blockquotes and frontmatter, and in `.dart` files on lines
  whose trimmed text starts with `//`: every match of `(?<![\w/.-])docs/[\w./-]*[\w-]\.md` exists,
  resolved from the repository root. A trailing `#fragment` or `:line` is not part of the match.
* **R4** — record files are the `.md` files whose basename matches `^\d{4}-[A-Z]`. Per number: more than
  one MADR is a finding, unless the number is `0011` or `0012` and the count is exactly two. Every PLAN
  whose number has a MADR sits in the same directory as that MADR.
* **R5** — every record file starts with `---\n`, and its frontmatter has a line matching
  `^status:\s*\S`.
* **R6** — the children of the root `docs/` are a subset of `README.md`, `architecture.md`,
  `decisions`, `reports`, `guides`, and `README.md` and `architecture.md` both exist. Every record file
  matches `^\d{4}-(MADR|PLAN|REPORT|GATES)-[a-z0-9]+(-[a-z0-9]+)*\.md$`. MADR and PLAN files sit in a
  directory named `decisions` whose parent is `docs`; REPORT and GATES files, in `reports` under `docs`.
  No file under a `docs/guides` is numbered. The root `README.md` has a link that resolves to
  `docs/README.md`. `docs/README.md` has a link that resolves to every record under `docs/decisions` and
  `docs/reports`.

**1.2 `test/docs_records_test.dart`**, tagged `@Tags(['integration'])`.

*Group "fixtures".* A helper creates a temporary directory, runs `git init -q` in it, writes a map of
files, and returns the root. It is deleted in `tearDown`. For each case, one defect is planted, and the
test asserts that exactly the expected `(rule, path)` is reported. The cases:

| # | Rule | Case | Expect |
| --- | --- | --- | --- |
| F0 | all | A small, correct tree: both indexes, a MADR/PLAN pair, a report, a guide, an anchored link, a fenced dead link, a blockquoted dead mention | **no findings** |
| F1 | R1 | A relative link to a missing file | 1 finding, the source path and line |
| F2 | R1 | The same dead link inside a fence; then inside an inline code span | none |
| F3 | R1 | A reference definition to a missing file | 1 |
| F4 | R1 | `https:`, `mailto:` and `//host` targets | none |
| F5 | R1 | A link inside a blockquote to a missing file | 1 (blockquotes are exempt from R3 only) |
| F6 | R1 | An ignored `.md` (listed in `.gitignore`) with a dead link; a symlink to a file with a dead link | only the real file is reported, once |
| F7 | R1 | An untracked, not ignored `.md` with a dead link | 1 (so a record is checked before it is staged) |
| F8 | R2 | `file.md#missing` | 1 |
| F9 | R2 | Two identical headings; links to `#h` and `#h-1` | none; and `#h-2` gives 1 |
| F10 | R2 | A heading with backticks, an em dash and `✔`; a link to its GitHub slug | none |
| F11 | R3 | Prose names a missing file by its `docs/` path | 1 |
| F12 | R3 | The same mention in a fence, a blockquote and frontmatter | none |
| F13 | R3 | A `.dart` file whose `//` comment names a missing file by its `docs/` path; the same path in a string literal | 1 (the comment only) |
| F14 | R3 | `magic-git/docs/x.md` and `<tree>/docs/x.md` | none (the lookbehind) |
| F15 | R4 | Two MADRs numbered `0011` | none; a third gives 1 |
| F16 | R4 | Two MADRs numbered `0020` | 1 |
| F17 | R4 | A PLAN in a different directory from its MADR | 1 |
| F18 | R4 | `nextNumber` over records in two separate `docs/` trees, highest `0042` | `0043` |
| F19 | R5 | A record with no frontmatter; a record whose frontmatter has no `status:` | 1 each |
| F20 | R6 | A record directly in `docs/`; a MADR in `reports/`; a numbered file in `guides/`; a stray `notes.md` directly in `docs/`; a missing `architecture.md` | 1 each |
| F21 | R6 | A record not linked from `docs/README.md`; a root `README.md` with no link to it | 1 each |
| F22 | R6 | `0005-UX-BASELINE-x.md` under `decisions/` | 1 (the name form) |

*Group "this repository".* Runs `checkedFiles` on `Directory.current` (the package root), then R1–R5,
and expects an empty list. The failure message joins every finding with newlines. The R6 test is added
in Phase 4.

**1.3 The real tree, R1–R5.** ~~One pre-existing finding is expected: R3 on `AGENTS.md:115`, which names
the architecture document by its future `docs/` path. That line is part of the caveat Phase 2 deletes.
In Phase 1 it is reworded to name the file without the prefix (the R3 writing convention); it is not
deleted early.~~ *Struck by deviation D1 (2026-09-19): that line sits in a blockquote, which R3 exempts,
so no finding is expected and nothing is reworded.* **Any finding is a deviation.** The investigation measured the tree clean, so
another finding means the checker disagrees with the investigation, and one of them is wrong.

**1.4 Prove it fails — the catalogue.** Write `tool/mutations/0054-doc-records.json` after the code, with
one mutation per load-bearing condition, each with `tests: ["test/docs_records_test.dart"]`. At minimum:

1. R1's existence check never fails.
2. Fences are not tracked.
3. Inline code spans are not removed.
4. Every scheme is treated as relative (so F4 reports).
5. Reference definitions are not collected.
6. R2 is skipped.
7. The duplicate-heading suffix is dropped.
8. R3's blockquote exemption is removed.
9. R3 skips `.dart` files.
10. The 0011/0012 allowance becomes "two or more".
11. The PLAN-beside-MADR check is skipped.
12. `nextNumber` counts only one tree.
13. The symlink filter is removed.
14. `--exclude-standard` is dropped.
15. R5 accepts a missing `status:`.
16. R6's `docs/` child allow-list accepts anything.
17. R6's index completeness is skipped.

```sh
python3 tool/mutate.py --check tool/mutations/0054-doc-records.json > "$S/p1-check.log" 2>&1; RC=$?
python3 tool/mutate.py tool/mutations/0054-doc-records.json > "$S/p1-mutate.log" 2>&1; RC=$?
```

Accept: `--check` reports every entry applying and compiling; the run reports **every mutation killed,
0 survived, 0 did-not-apply**. The whole log is read, not its tail. A survivor is a question: either the
fixture set is missing a case (add it, re-run) or the mutation is equivalent (record why, and replace
it).

**1.5 Prove it fails — the CLI on a planted clone.** Committed state only:

```sh
git clone -q --local --no-hardlinks . "$S/p1-planted"
# plant: a dead link in docs/0001-MADR-native-git-libgit2.md, a docs/ mention of a missing file in
# AGENTS.md, a stray third 0011 MADR, a record with its status line removed
dart run tool/records.dart check --root "$S/p1-planted" --rules links,anchors,paths,numbering,frontmatter \
  > "$S/p1-planted.txt" 2>&1; RC=$?
```

Accept: `RC=1`, and `$S/p1-planted.txt` names each planted defect's file and line, read in full. Then the
same command on an unplanted fresh clone gives `RC=0`.

**1.6 Commit** `tool/records.dart`, `test/docs_records_test.dart`, `tool/mutations/0054-doc-records.json`,
~~`AGENTS.md` (the 1.3 rewording),~~ *(struck by D1)* and this record pair, with both statuses updated to `accepted` /
`in-progress`.

### Phase 2 — The move (one commit)

**2.1 The map.** Directories are created under `docs/` first (`decisions/` exists already; `reports/`,
`guides/`). The map covers 111 files:

* each of the 102 flat `NNNN-MADR-*` / `NNNN-PLAN-*` → `decisions/`, same name;
* these nine (paths under `docs/`):

| From | To | Frontmatter written |
| --- | --- | --- |
| `0005-UX-BASELINE-task-centered-adaptive-repository-workspace.md` | `reports/0005-REPORT-ux-baseline-task-centered-adaptive-repository-workspace.md` | existing kept; `former-path` added |
| `ACTION_PLAN.md` | `decisions/0055-PLAN-post-review-action-plan.md` | `partial`; `date: 2026-07-06`; `verified: 2026-08-14` (audited by 0007-MADR, "46 of ~51 verified") |
| `ARCHITECTURE_PLAN.md` | `decisions/0056-PLAN-architecture-and-feature-parity.md` | `partial`; `date: 2026-07-06`; `verified: 2026-08-14` (0007-MADR checked its env-token claims, `:319`) |
| `viewer_engine_findings.md` | `reports/0057-REPORT-file-view-engine-assessment.md` | `partial`; `date: 2026-07-06`; `verified: 2026-08-20` (0004-MADR: "viewer residuals (L7)") |
| `window_sizing_proposal.md` | `reports/0058-REPORT-window-sizing-assessment.md` | `partial`; `date: 2026-07-06`; `verified: 2026-08-20` (0004-MADR: "largely implemented") |
| `memory_audit.md` | `reports/0059-REPORT-memory-and-performance-audit.md` | `partial`; `date: 2026-07-07`; `verified: 2026-08-20` (0004-MADR: "Tier 1–2 memory fixes done") |
| `DRAG_AND_DROP_ENGINE.md` | `reports/0060-REPORT-drag-and-drop-engine-feasibility.md` | `executed`; `date: 2026-07-16`; `verified: 2026-08-20` (0004-MADR: "A–E shipped") |
| `TEST_COVERAGE_PLAN.md` | `decisions/0061-PLAN-remaining-test-coverage.md` | `partial`; `date: 2026-08-15`; `verified:` the execution date, by the check in 2.4 |
| `BUILD_MACOS.md` | `guides/build-macos.md` | none (a guide) |

Every renamed record also gets `former-path: "docs/<old name>"`. The frontmatter carries a YAML comment
naming the audit behind `verified:` (for example `# 0004-MADR-ui-ux-deep-debug-audit.md, lines 412-417`),
so the date can be traced. Before the numbers are used, `dart run tool/records.dart next` must print
`0055`. If it prints anything else, that is a deviation, and the map is renumbered before anything
moves.

**2.2 The migration script.** `$S/migrate_docs.py` is a one-time tool, kept in the scratchpad and not
committed. It takes `--root <dir>` and `--moves-only`. It parses Markdown with the checker's grammar
(fences, frontmatter, inline code, blockquotes), and:

1. Builds the map and asserts: 111 entries; every source exists; no target exists.
2. Records every relative link in every checked `.md` file: source file, line, raw target, and the
   absolute old target it resolves to.
3. `git mv`s each entry. With `--moves-only`, it stops here.
4. Rewrites each recorded link. The new source is `map(source)`, the new target `map(old target)`, and
   the new link text is the POSIX relative path between them, with the fragment kept. On the new
   source's line, it asserts that the raw `](target` occurs exactly as often as recorded, then replaces
   it.
5. Rewrites every R3 mention (the same scope as R3: `.md` outside fences, blockquotes and frontmatter,
   plus `//` comments in `.dart` files) whose path is a key of the map, replacing it with the value
   under `docs/`. It asserts a per-file count.
6. Writes the frontmatter in 2.1.
7. Verifies by target. Every recorded link is re-resolved from its new source and compared with
   `map(old target)`. The per-file link count is compared with step 2's count. Any mismatch exits
   non-zero, and names the link.

**2.3 Rehearsal in a scratch clone — the checker seen to fail on the real move.**

```sh
git clone -q --local --no-hardlinks . "$S/p2-rehearsal"
python3 "$S/migrate_docs.py" --root "$S/p2-rehearsal" --moves-only > "$S/p2-moves.log" 2>&1; RC=$?
dart run tool/records.dart check --root "$S/p2-rehearsal" --rules links,anchors,paths,numbering,frontmatter \
  > "$S/p2-broken.txt" 2>&1; RC=$?        # expect RC=1: record the count per rule
rm -rf "$S/p2-rehearsal"                   # scratch only
git clone -q --local --no-hardlinks . "$S/p2-rehearsal"
python3 "$S/migrate_docs.py" --root "$S/p2-rehearsal" > "$S/p2-full.log" 2>&1; RC=$?        # expect 0
dart run tool/records.dart check --root "$S/p2-rehearsal" --rules links,anchors,paths,numbering,frontmatter \
  > "$S/p2-clean.txt" 2>&1; RC=$?        # expect RC=0
```

Accept: the moves-only run reports a large number of R1 and R3 findings, and R5 findings for the
legacy files with no frontmatter. The counts are recorded here as the checker's real-world negative
test. The full run then reports none. `git -C "$S/p2-rehearsal" diff --cached -M --stat` shows 111
renames and no additions or deletions. (Everything inside `$S`: `rm -rf` of a scratch clone this plan
created is not a destructive command on anyone's work.)

**2.4 `TEST_COVERAGE_PLAN` check.** Re-run the existence check for the 14 test files named in its phase
headings, and write its `verified:` date and a one-line body note: "verified by test-file existence
only; 12 of 14 exist". The note sits under the frontmatter as a dated annotation. The document's text is
not rewritten.

**2.5 Hand edits in the same commit.**

* `AGENTS.md`: delete the "This repository has not migrated yet" blockquote (`AGENTS.md:113-121`). Update
  the `0005` note (`:149-150`) to say the rename has happened, naming
  `0005-REPORT-ux-baseline-task-centered-adaptive-repository-workspace.md`. The architecture line
  (`:176`) points at `0056-PLAN-architecture-and-feature-parity.md` §0.1 until Phase 3.
* `.claude/skills/troubleshooting-magic-git/SKILL.md:174`: `docs/` → `docs/decisions/`.
* `lib/core/git/watch_path_filter.dart:34`: "ARCHITECTURE_PLAN §watch" → the new filename and the section
  it means. The section is confirmed by reading the old §5 before editing.
* `test/ssh_live_transport_test.dart:6`: "ACTION_PLAN" → the new filename.

**2.6 Execute in the real tree:** `python3 "$S/migrate_docs.py" --root .`, then the 2.5 edits.

**2.7 Verify, then commit:**

```sh
dart run tool/records.dart check --rules links,anchors,paths,numbering,frontmatter > "$S/p2-real.txt" 2>&1; RC=$?   # 0
git diff --cached -M --stat > "$S/p2-stat.txt"   # 111 renames (R0xx), plus the in-place edits listed in Scope
git log --follow --format=%h -- docs/decisions/0001-MADR-native-git-libgit2.md | tail -1         # reaches its first commit
git log --follow --format=%h -- docs/reports/0059-REPORT-memory-and-performance-audit.md | tail -1  # reaches afda1e4
```

For a moved file, `git log --follow` must reach the same first commit as before the move. Check one
record from each group: a flat MADR, the UX-BASELINE report, an unnumbered report, and the guide. Then
run `flutter analyze` and the full `flutter test`, with the suite count equal to Phase 1's. **The commit
contains the moves, the repairs, the frontmatter and the 2.5 edits, and nothing else.**

### Phase 3 — `architecture.md`

**3.1 Write it** in `docs/`: purpose and shape; the executor seam (`CommandExecutor` and its three
implementations); the SSH transport (§0.1 of `0056-PLAN-…`, carried forward only where the code still
agrees); command scheduling, output budgets and telemetry (`lib/core/exec/`); services and forges (`git`,
`glab`, `gh`, host filesystem); the watch pipeline as 0045 left it (`WatchTarget`, `WatchAdmission`,
`WatchEngine`, `WatchSource`, `WatchTimings`); state and providers (the Riverpod DI hub, family keys, the
retry policy); multi-window relay; sandbox and secrets; Help; build and entitlements; test
infrastructure (scan tests, `tool/mutate.py`, this checker). Each section links the records that govern
it. It is present tense throughout, with no history ("we chose", "we used to" belong to records).

**3.2 Check every claim.** Every class, file, limit or behaviour named is checked against the code. The
execution record gets a table: claim → `file:line` evidence. A claim with no evidence is removed, not
softened. §0.1 statements that the code now contradicts are listed separately, because they are
findings about `0056-PLAN-…`.

**3.3 Point readers at it.**

* `AGENTS.md:176` names `architecture.md` (in `docs/`) as the as-is description, and `0056-PLAN-…` as
  historical.
* `README.md`'s architecture link targets it.
* `0056-PLAN-…` gets a dated note directly under its title: "Historical. The system as it is now is
  described in `[architecture.md](../architecture.md)`." (the link, written as Markdown). Its "§0.1 … authoritative" line is annotated,
  not deleted: "authoritative until 2026-09-NN; superseded by architecture.md".

**3.4 Verify:** the checker (R1–R5) reports 0. `no_real_identifiers_scan_test` passes (it scans `docs/`,
so it now covers the new file). Then analyze and the full test suite. **Commit.**

### Phase 4 — Layout enforced, index rebuilt

**4.1 `docs/README.md`** becomes the table of contents:

1. Title "Documentation", and a one-paragraph orientation.
2. **I want to…**, written by hand in the reader's words. At least these rows:
   * understand how the app fits together → `architecture.md`
   * build, install or sign the app → the build guide
   * run the Xcode unit tests without a certificate → the guide's anchor
   * write a new decision record → `AGENTS.md` and `dart run tool/records.dart next`
   * know why there is no libgit2 → 0001-MADR
   * know why the SSH transport works as it does → 0011, 0012, 0014, 0024
   * understand the watcher → 0045-MADR
   * know why the entitlements files are never edited → 0042-MADR, 0053-MADR
   * know why every provider declares `retry:` → 0017-MADR
   * test that a guard can fail → 0029 and 0030, `tool/mutate.py`
3. **Architecture** and **Guides** sections.
4. **Status vocabulary** — kept as it is.
5. **Decisions** — the existing index table, rows unchanged except their link paths (which Phase 2 already
   rewrote), plus rows for 0054, 0055, 0056 and 0061.
6. **Reports** — a new table: 0005, 0057, 0058, 0059, 0060.
7. The existing notes (twins, 0016, "What 'verified' means here") kept.

**4.2 R6 on.** Add the "this repository" R6 test. Run it. Expect 0 findings.

**4.3 `AGENTS.md`**, the *Decision records* section:

* The next number comes from `dart run tool/records.dart next`. The rule about scanning the whole
  repository stays, as what the tool does.
* Delete "with records currently in two places".
* One paragraph on the checker: what `test/docs_records_test.dart` enforces, and the R3 writing
  convention.

**4.4 Verify:** `dart run tool/records.dart check > "$S/p4.txt" 2>&1; RC=$?` with all rules, expecting
`RC=0`. Then analyze and the full test suite. **Commit.**

### Phase 5 — Close

1. Re-run the full catalogue: every mutation killed. ~~R6's mutations can only be killed now, because
   before this phase the real-tree R6 test did not exist.~~ *Corrected by D1: fixtures F20–F22 kill the
   R6 mutations, and did in Phase 1.* The fixture tests do not depend on the real-tree R6 test, so a
   change in the result here is a finding.
2. `docs/README.md`'s 0054 row: `accepted`, plan `complete`, with a one-paragraph summary in the style of
   the neighbouring rows.
3. The MADR: `status: "accepted"`, `verified:` today. The PLAN: `status: "complete"`.
4. Full `flutter test` and `flutter analyze` one last time. **Commit.**
5. Handoff: the branch is ahead by N commits, the push command is offered, and the dotfiles 0007-PLAN
   Phase 6 item is offered for the maintainer to mark.

## Verification

| Phase | Command | Expected |
| --- | --- | --- |
| 0 | `flutter test > "$S/p0-test.log" 2>&1; RC=$?` | `RC=0`; count recorded |
| 1 | `flutter test test/docs_records_test.dart` | all fixture cases and the R1–R5 repository test pass |
| 1 | `python3 tool/mutate.py tool/mutations/0054-doc-records.json` | every mutation killed; 0 survived; 0 did-not-apply |
| 1 | `dart run tool/records.dart check --root "$S/p1-planted" …` | `RC=1`, each planted defect named |
| 2 | the rehearsal, moves only | `RC=1`, counts recorded per rule |
| 2 | the rehearsal, full | `RC=0`; 111 renames in `--stat` |
| 2 | `dart run tool/records.dart check --rules …` in the real tree | `RC=0` |
| 2 | `git log --follow` on four sampled moved files | same first commit as before the move |
| 3 | claim table in the execution record | every claim has `file:line` evidence |
| 4 | `dart run tool/records.dart check` (all rules) | `RC=0` |
| every | `flutter analyze`; `flutter test` | clean; full pass, count ≥ baseline |

**Acceptance criteria**

1. No record, report or unnumbered document sits directly in `docs/`. `docs/` holds exactly
   `README.md`, `architecture.md`, `decisions/`, `reports/` and `guides/`.
2. Every relative link, anchor and `docs/` path mention in the repository resolves, and
   `flutter test` fails if one stops resolving. This has been seen three ways: fixtures, mutations, and
   the rehearsal.
3. Every moved file is a git rename, and its history follows it.
4. `architecture.md` exists, is present tense, and every claim in it has recorded evidence.
5. `docs/README.md` has the "I want to…" matrix and links every record. A new record without an index
   row fails the suite.
6. `dart run tool/records.dart next` prints the next free number.
7. `AGENTS.md` describes the tree as it is: no migration caveat, and no `docs/…` path that does not
   resolve.

## Rollout and Rollback

Each phase is its own commit, and each commit is green. Rollback is `git revert` of the phase commits
in reverse order:

* Reverting Phase 4 turns R6 off again and restores the old index.
* Reverting Phase 3 removes `architecture.md` and the pointers.
* Reverting Phase 2 is a revert of renames plus link edits, and restores the flat tree exactly. R1–R5
  still pass on it, which Phase 1 proved.
* Reverting Phase 1 removes the checker.

Nothing is pushed by this plan.

## Execution record

Approved for execution by the maintainer on 2026-09-19, with the MADR accepted as proposed (see the
MADR's *Decision* section): the architecture document is a full rewrite, and the `verified:` backfill is
deferred.

### Phase 0 — executed 2026-09-19

* `Flutter 3.47.2`; `flutter pub get --enforce-lockfile` → "Got dependencies!".
* `flutter analyze` → `RC=0`, "No issues found!".
* `flutter test` → `RC=0`, **`+4196 ~3: All tests passed!`** (the suite baseline; 3 skipped are the
  `live-forge` tests).
* The inventory, re-run with the 0054 pair excluded, matched the MADR exactly: 434 links inside `docs/`,
  10 outside, 6 anchored, 169 prose mentions, 1 fenced, 0 broken. With the pair included, the counts
  were 436 / 179 / 2, and the whole difference came from the pair. The only dead mention was at
  `AGENTS.md:115`, not `:114` as first written; both records were corrected.
* `git status --porcelain`: only the 0054 pair. The MADR had already been committed as `cb5b9fa`, not
  by this work; it matched the working file at the time.

### Phase 1 — executed 2026-09-19

* **`tool/records.dart`** (R1–R6, `check`/`next` CLI, `dart:io` only) and
  **`test/docs_records_test.dart`**: 23 fixture tests (F0–F22) and 3 repository tests. The third
  repository test is not in the plan. It asserts that the checker sees more than 100 records, including
  this MADR, because a file listing that silently came back empty would make every other rule pass.
* **Real tree, R1–R5: 0 findings.** `dart run tool/records.dart next` → `0055`.
* **The fixtures, first run:** 6 of 26 failed. All six were an off-by-one in the test's own line
  constant: the MADR fixture is 17 lines, and the constant said 19. The checker's line numbers were
  right. After correcting the constant, 26 of 26 passed.
* **Mutations (`tool/mutations/0054-doc-records.json`, 18 entries):** `--check` → 18 sound. First run →
  **17 killed, 1 survived**: "slugs keep backticks". The survivor was an equivalent mutation, because
  the slug's punctuation filter already drops `` ` `` and `*`, so removing them separately was dead
  code. The resolution was to delete the redundant `replaceAll`s and replace the mutation with one that
  is not equivalent: "heading links are not reduced to their text". F10 gained a heading with a link to
  pin it. Second run: **18 killed, 0 survived, 0 did not apply, 0 did not compile.**
* **CLI on a planted scratch clone** (clones in the session scratchpad, never the working tree). Four
  defects were planted: a dead link appended to 0001-MADR, a dead `docs/` mention appended to
  `AGENTS.md`, a third 0011 MADR, and the `status:` line removed from 0020-PLAN. Result: `RC=1`, 6
  findings. They were the link at `0001-MADR…:170`, the path at `AGENTS.md:285`, all three 0011 MADRs,
  and the frontmatter finding at `0020-PLAN…:1`. The unplanted clone: `RC=0`, 0 findings.
* `flutter analyze` clean; `dart format --set-exit-if-changed` clean on both Dart files; full
  `flutter test` → **`+4222 ~3: All tests passed!`** (+26, the new tests).

### Deviation D1 (2026-09-19): step 1.3 expected a finding that R3 exempts

* **Found:** step 1.3 expected one R3 finding on the real tree, at `AGENTS.md:115`, and prescribed
  rewording that line. The line is inside the "has not migrated yet" blockquote, and blockquotes are
  exempt from R3 (MADR, *The move*; accepted as review point 3). The real tree gives 0 findings. This
  was confirmed on an unmodified scratch clone, with `AGENTS.md` untouched.
* **Also found:** Phase 5 step 1 claimed the R6 mutations could only be killed after Phase 4. Fixtures
  F20–F22 kill them, and did in Phase 1.
* **Decision (maintainer, 2026-09-19):** strike the rewording, and leave `AGENTS.md` out of the Phase 1
  commit. The blockquote is deleted in Phase 2 as planned. Correct the Phase 5 text. No files were added
  to any phase's scope, and the MADR is unaffected: it asserted the exemption, and the plan step
  contradicted it.

### Phase 1 — committed as `7083d7a`

### Phase 2 — executed 2026-09-19, committed as `fea3dcf`

* `dart run tool/records.dart next` → `0055` before anything moved, matching the map.
* **The rehearsal, moves only** (scratch clone): the script recorded 440 relative links and
  moved 111 files. The checker then reported **`RC=1`, 269 findings: 145 `links`, 117
  `paths`, 7 `frontmatter`**. This is the checker's real-world negative test. (440 is
  lower than the investigation's 434 + 10 + the pair's links, because the script, like
  R1, does not record `#fragment`-only links.)
* **The rehearsal, full** (fresh clone): 194 link occurrences rewritten, and 117 path
  mentions in 37 files. **All 440 links verified by target: 0 files mismatched.** Checker
  `RC=0`. `git diff --cached -M` showed **111 renames (`R`) and 5 in-place edits**; the
  lowest rename similarity was 94%.
* **The real tree:** the same output as the full rehearsal: 440 recorded, 111 moved, 194
  links, 117 mentions in 37 files, 0 mismatched. Then the 2.5 hand edits:
  * `AGENTS.md`: the blockquote deleted, the `0005` note updated, and the architecture
    line pointed at 0056;
  * the skill's `docs/decisions/`;
  * the `watch_path_filter.dart` comment ("§watch" is §5, *Layer 4 — Real-time remote
    state*, whose `.git/` watch/ignore list is at its line 417);
  * the `ssh_live_transport_test.dart` comment, reflowed.
* Checker (R1–R5) → 0 findings. `flutter analyze` clean. `flutter test` →
  **`+4222 ~3: All tests passed!`** (unchanged from Phase 1).
* **The commit:** 123 files, **111 `R` + 12 `M`**, and nothing else. The PLAN's own
  execution entry was deliberately held to the next commit.
* **History follows** (`git log --follow`, the first commit before the move vs after):
  | File | Before | After |
  | --- | --- | --- |
  | 0001-MADR (flat record) | `ef3415e` | `ef3415e` |
  | 0005-REPORT (was UX-BASELINE) | `60adb02` | `60adb02` |
  | 0059-REPORT (was `memory_audit.md`) | `afda1e4` | `afda1e4` |
  | the build guide | `2d8a357` | `2d8a357` |
  | 0056-PLAN (was `ARCHITECTURE_PLAN.md`) | `2d8a357` | `2d8a357` |
* `TEST_COVERAGE_PLAN` (2.4): 12 of 14 named test files exist; the note in 0061 says the
  check was existence only.

### Phase 3 — executed 2026-09-19

`architecture.md` is written in `docs/`. Every claim was checked against the code. The
evidence behind each one:

| Claim | Evidence |
| --- | --- |
| three executors behind `CommandExecutor` | `lib/core/ssh/ssh_command_executor.dart:223`, `:307`; `lib/core/exec/local_command_executor.dart:20`; `lib/core/exec/proxy_command_executor.dart:25` |
| services depend on the active executor | `activeExecutorProvider`, `lib/core/providers/app_providers.dart:256` |
| dartssh2 3.3.0 exact | `pubspec.yaml` (`dartssh2: 3.3.0`) |
| triple client, serialized host-key verification | `SSHClientManager`, `ssh_client_manager.dart:139`; `serializeHostKeyVerifier`, `:799` |
| redial 15→30→60→120 s, 5 failures | `streamRedialDelay`, `ssh_client_manager.dart:273`; `_maxRedialFailures = 5`, `:226` |
| generation supersession | `SSHCommandSuperseded`, `ssh_command_executor.dart:78` |
| keepalive 15 s / 15 s, busy pause | `ConnectionHealthMonitor`, `ssh_client_manager.dart:51`, `:56-57`, `isBusy` `:107` |
| `NativeSshSocket`, `TransportDropCause` | `native_ssh_socket.dart:14`; `command_telemetry.dart:41` |
| reconnect 1/2/4/8/15 s, pause after 20 | `_reconnectDelays`, `app_providers.dart:2222`; `_maxAutoReconnectAttempts = 20`, `:2239`; `isRetryableReconnectError`, `ssh_error_messages.dart:30` |
| `RemoteEnvironment`; token neutralising | `environment_probe.dart:11`; `command_formatter.dart:43` (`GITLAB_TOKEN`) |
| gzip + EXIT trailer; 256 KiB offload | `command_formatter.dart:95`, `:146`; `gzipOffloadWireBytes`, `ssh_command_executor.dart:330` |
| four lanes; `GIT_OPTIONAL_LOCKS=0` | `ExecLane`, `command_lanes.dart:14`; `command_formatter.dart:22` |
| read cap 3 → 1..4 by duration buckets; error floor | `adaptive_read_concurrency.dart:1-47`, `:52-53`, `:185`; `onReadSample` fed by `ssh_command_executor.dart:434` |
| scheduler clamp 8; watchdog +30 s; isolated cap 2 | `command_lanes.dart:158`, `:154`, `:134` |
| streams 8 / 2 degraded | `maxConcurrentStreams`, `ssh_command_executor.dart:385` |
| 50 MiB budget; 400 ms kill grace; retry between enqueues | `command_drain.dart:25`; `killGrace`, `ssh_command_executor.dart:1143`; `_retryBackoff` and its doc, `:630-649` |
| porcelain v2; `Isolate.run`; `GitCatFileBatch`; `registerRepoScope` | `git_service.dart:1938`, `:517`; `git_cat_file_batch.dart:158`; `git_service.dart:1175` |
| glab token over stdin | `glab_service.dart:93` |
| `HostFsService` operations | `host_fs_service.dart:51`, `:98`, `:119`, `:143` |
| watch owners | `watch_target.dart:55`; `watch_admission.dart:11`; `watch_engine.dart:41`; `watch_source.dart:10`, `remote_watch_source.dart:21`, `directory_watch_source.dart:48`; `watch_timings.dart:14`; `watcher_id.dart:7`; `watcherProvider`/`repoWatchProvider`, `app_providers.dart:3887`, `:3903` |
| restart 2 s·n ×3, poll 5 s, recover 3 min | `watch_timings.dart:73`, `:76`, `:67`, `:70`; `watch_engine.dart:312` |
| `Coalescer` guards | `coalescer.dart:1-28` |
| host-side watchdog (stdin EOF, lease poll, trap) | `bounded_watch.dart:270-300`; `WatchLease`, `watch_lease.dart:25` |
| `noProviderRetry`; failures to the Output pane | `provider_retry_policy.dart:28`; `ProviderFailureObserver`, `provider_failure_observer.dart:23`, writing `outputLogProvider` |
| undo/redo journals | `undo_journal.dart:16`, `:57` |
| secondary entrypoint; hub channel; `Uint8List` codec | `lib/main.dart:18`; `window_channels.dart:36`; `exec_proxy_codec.dart:10` |
| menu spec; keymap | `menu_bar_spec.dart:111`; `keymap.dart:155` |
| Help files and test | `macos/Runner/HelpView.swift`, `HelpWindowController.swift`, `help_book.json`; `test/help_book_json_test.dart` |
| bookmarks; Keychain; `credentials.json` 0600 | `security_scoped_bookmark.dart:12`; `connection_store.dart:3`, `:15-16`, `:82` |
| Flutter pin; SDK vendoring; debug entitlements variable | `build_macos.sh:45`, `:144-168`; `AppInfo.xcconfig:36` |
| scan tests named | each exists in `test/` (listed at execution) |

**Two claims in the first draft failed the check and were corrected before commit:**
* "`HostFsService` does reads, writes, directory listings" — the class provides
  `homeDir`, `probePath`, `makeDirs` and `removeDirGuarded` only.
* "every command is recorded in the Output pane" — unverified, so it was replaced with
  what the code shows (`ProviderFailureObserver` writes provider failures to
  `outputLogProvider`).

**Findings about 0056's §0.1** (annotated in place, not rewritten). Three statements the
code contradicts:
1. watcher restarts run in `WatchEngine`, not `watchLifecycle`;
2. the read cap follows per-command read durations, not keepalive RTT bands;
3. the stream client carries 8 concurrent streams, not "1 watcher + 1 CI".

0056's `verified:` moves to 2026-09-19 on the strength of that check.

**Pointers:** `AGENTS.md` *Architecture* names `architecture.md` as the authority, and
0056 as history. `README.md` links `architecture.md`. 0056 carries a dated "Historical"
note under its title and an annotation under §0.1.

### Phase 3 — committed as `be24056`

### Phase 4 — executed 2026-09-19

* **R6 seen to fail on the real tree first.** Before the index was touched,
  `dart run tool/records.dart check --rules layout` reported **9 findings**, all
  "not linked from docs/README.md", for exactly the records with no row yet: 0054 MADR and
  PLAN, 0055, 0056, 0061, and 0057–0060. This is the same `check(root, rules: ['layout'])`
  call the new repository test makes.
* **`docs/README.md`** is now the table of contents. It has a title and orientation,
  an **I want to…** matrix (11 rows, in the reader's words, including an anchor into
  `AGENTS.md` and one into `architecture.md`, both resolved by R2), and *Architecture*
  and *Guides* sections. The status vocabulary is kept. *Index* is renamed *Decisions*,
  with rows added for 0054, 0055, 0056 and 0061. A note explains the older-than-their-numbers
  records. There is a new *Reports* table (0005, 0057–0060). The existing rows and notes
  are unchanged apart from the link paths Phase 2 rewrote.
* **The R6 repository test** is added ("the documentation tree has the standard layout,
  fully indexed").
* **`AGENTS.md`:** numbering now points at `dart run tool/records.dart next`, and "with
  records currently in two places" is gone. A new paragraph says what the checker
  enforces, including the fence/blockquote/frontmatter exemptions and the R3 writing
  convention.
* `dart run tool/records.dart check` (all six rules) → `RC=0`, 0 findings.
  `flutter analyze` clean. `flutter test` → **`+4223 ~3: All tests passed!`** (+1, the R6
  test).

### Phase 4 — committed as `f99b6a1`

### Phase 5 — executed 2026-09-19

* The 0054 catalogue on the final tree: `--check` 18 sound; run → **18 killed, 0 survived,
  0 did not apply, 0 did not compile**. The R6 mutations were killed exactly as in Phase 1,
  as D1 predicted: the fixtures kill them, and the real-tree R6 test does not change that.
* **Other catalogues.** Phase 2 edited comments in four files
  (`lib/core/git/watch_path_filter.dart`, `test/ssh_live_transport_test.dart`,
  `test/drop_registry_test.dart`, `test/helpers/fake_watcher_handle.dart`), and a
  catalogue anchor containing that text would stop applying. A full
  `tool/mutate.py --check` over every catalogue was started, and then stopped at the
  maintainer's request because it was slow. The same question was answered directly
  instead: a scan of all **302 entries** in `tool/mutations/*.json` found **none that even
  targets** one of the four files, so none can be anchored on the changed text. The
  stopped run's scratch worktree was removed with `git worktree remove --force`, as the
  harness does itself.
* The index row for 0054 is `accepted` / `complete`. The MADR is `accepted`,
  `verified: 2026-09-19`. This PLAN is `complete`.

**Residuals.**
* The `verified:` backfill for the 27 PLANs that lack it, deferred by the maintainer.
* Whether to mark the dotfiles repository's 0007-PLAN Phase 6 done for this repository.
  That is outside this repository, and the maintainer's call.

### Follow-up — executed 2026-09-19 (maintainer's request after the push)

**1. The `verified:` backfill** (MADR amendment 0054.1).
* **How it was checked.** Four read-only agents each took a quarter of the 27 PLANs.
  For every plan they read its status and execution record, and located the 3–6 most
  load-bearing shipped deliverables at `file:line` in the tree at `d67953c`. A
  deliverable later replaced was traced to the record that replaced it.
* **Result: 27 confirmed, 0 contradicted.** 16 were confirmed as they stand; 11 via
  supersession (mostly MADR 0045's rewrite of the watcher stack).
* **Stamped.** Each carries `verified: 2026-09-19`, with a YAML comment naming the
  basis. This PLAN, which also lacked the field, is stamped too.
* **Findings reported, not changed** (the status values were out of scope):
  * 26 PLANs use `complete` or `complete (amended)`. `CLAUDE.md`'s plan vocabulary is
    `executed` · `partial`, and the `madr-and-plan-writing` skill uses `complete`.
  * 0049 says `complete` while its body says the maintainer's manual check (criterion
    12) is still owed.
  * 0030's body records its Phase 7 as partial.
  * 0040's body does not mention that 0041 re-landed its Phase 2 goal.
  * 0024 still has an "Empty until the plan is approved" placeholder under its
    execution-record heading.

**2. R5 requires `verified:`.**
* `tool/records.dart` checks both keys through one table.
* Fixture F19 gained the missing-`verified:` case, and the clean fixture's records
  carry the key (the line constants moved by one).
* The catalogue's R5 entry was retargeted, and a new one added ("R5 requires only
  status:"). **19 killed, 0 survived.**
* Seen to fail on real input: against a clone of the pushed `HEAD` (before the
  backfill), `check --rules frontmatter` → `RC=1`, **28 findings**, all "no verified:".

**3. `CLAUDE.md` is the canonical instructions file.**
* `git mv AGENTS.md CLAUDE.md`, with `AGENTS.md` and `.goosehints` recreated as
  symlinks to it. Both old symlinks were committed and unchanged before they were
  replaced.
* The header now says to edit only `CLAUDE.md`.
* The live references were updated: `README.md`, the `docs/README.md` matrix and twin
  note, `tool/records.dart`'s comments, `.agents/pre_add_test_hook.py`, and 9 test
  comments. Historical records keep their `AGENTS.md` citations.
* The checker skips symlinks, so it now checks `CLAUDE.md` and skips `AGENTS.md`.

**4. The dotfiles 0007-PLAN.** Its Phase 6b (this repository's migration) is recorded
done there, with the ways it differed from that plan as written. It stays `in-progress`
for its own Phase 5 and remaining flat records, by the maintainer's choice.
