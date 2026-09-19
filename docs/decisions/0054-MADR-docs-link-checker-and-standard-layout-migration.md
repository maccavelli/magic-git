---
status: "accepted"
date: 2026-09-19
decision-makers: [Maintainer]
consulted: [AGENTS.md, docs/ as of 9df6338, the dotfiles repository's 0007 MADR and PLAN (standard documentation layout), test/source_is_text_scan_test.dart, test/no_real_identifiers_scan_test.dart, tool/mutate.py]
informed: [Magic Git contributors]
verified: 2026-09-19
---

# Enforce documentation links and layout with a test, then move the flat records into the standard tree in one checked commit

## Context and Problem Statement

The global documentation standard (the *MADR & PLAN file standards* in the global agent rules, which
`AGENTS.md` names as the authority) fixes one shape for a documentation tree:

```
README.md            ← links to docs/README.md
docs/
  README.md          ← ToC and the "I want to…" matrix
  architecture.md
  decisions/   NNNN-MADR-*.md  NNNN-PLAN-*.md
  reports/     NNNN-REPORT-*.md  NNNN-GATES-*.md
  guides/      user documentation, unnumbered
```

and says **a record never sits directly in `docs/`**. This repository adopted the standard in its
instructions but not in its files. `AGENTS.md:113-121` says so in as many words:

> **This repository has not migrated yet.** Its ~100 records are still flat in `docs/`, and the
> architecture document is still `docs/ARCHITECTURE_PLAN.md` rather than `docs/architecture.md`. The
> move is the last phase of `0007-PLAN-standard-documentation-layout-and-where-the-standard-lives.md` in
> the dotfiles repository and needs a link checker first, because the records cite one another heavily
> and nothing validates a relative markdown link.

That dotfiles plan (Phase 6, "not approved") scoped the move for this repository and made a link checker
its prerequisite. It also recorded, in its deviation (d), a link that had been dead since it was written
and that nobody noticed until a checker ran. This record decides how this repository does that move.

### What is in `docs/` today (measured at `9df6338`)

| Kind | Count | Where |
| --- | --- | --- |
| `NNNN-MADR-*` / `NNNN-PLAN-*` | 102 (51 + 51) | flat in `docs/` |
| `NNNN-MADR-*` / `NNNN-PLAN-*` | 4 (0052, 0053) | `docs/decisions/` (already migrated) |
| `0005-UX-BASELINE-…` (a report under an older kind name) | 1 | flat |
| Unnumbered documents | 8 | flat |
| `docs/README.md` (the index) | 1 | `docs/` |
| `docs/reports/`, `docs/guides/`, `architecture.md` | absent | — |

The 102 flat records total about 73,000 lines. The eight unnumbered documents, read in full at their
headers and classified by what they are rather than what they are called:

| File | Lines | First added | What it is |
| --- | --- | --- | --- |
| `ACTION_PLAN.md` | 464 | 2026-07-06 | A plan: "Action Plan (post code-review)", ten findings, P0–P3 tiers. [0007-MADR-docs-completion-audit.md](0007-MADR-docs-completion-audit.md) audited it ("46 of ~51 verified") |
| `ARCHITECTURE_PLAN.md` | 703 | 2026-07-06 | A plan: "Architecture & Feature-Parity Plan". Its own banner says "historical plan + living transport notes"; §0.1 is the authoritative SSH transport description (`AGENTS.md:176`) |
| `viewer_engine_findings.md` | 128 | 2026-07-06 | A report: file-view engine assessment backlog |
| `window_sizing_proposal.md` | 98 | 2026-07-06 | A report: window sizing assessment and proposal |
| `memory_audit.md` | 237 | 2026-07-07 | A report: memory and performance audit |
| `DRAG_AND_DROP_ENGINE.md` | 657 | 2026-07-16 | A report: "Feasibility & Design Report"; its status line says A–E shipped |
| `TEST_COVERAGE_PLAN.md` | 213 | 2026-08-15 | A plan: "Remaining Test Coverage — Implementation Plan". Of the 14 test files it names, 12 now exist; `workspace_registration_test.dart` and `local_repo_form_test.dart` do not |
| `BUILD_MACOS.md` | 200 | 2026-07-06 | A guide: how to build the `.app` |

[0004-MADR-ui-ux-deep-debug-audit.md](0004-MADR-ui-ux-deep-debug-audit.md) (lines 412-417, `verified:
2026-08-20`) already records the state of four of these: ACTION_PLAN "mostly done; some deferred", the
viewer findings with residual L7, window sizing "largely implemented", memory "Tier 1–2 fixes done", and
DnD "A–E shipped".

### How heavily the records cite one another

Measured over every tracked, non-symlink Markdown file (the inventory scripts are described in the plan):

* **434 relative inline links** inside `docs/`, plus **10** in `README.md` and `AGENTS.md` that point into
  `docs/`. **0 are broken today.** `docs/README.md` alone has 110, and 102 of the 107 records carry at
  least one.
* **6 links carry a `#fragment`**, and all 6 match a heading in their target.
* **169 path-shaped mentions** of the form `docs/<name>.md` outside link syntax, in prose and inline code
  (for example `docs/decisions/0004-MADR-ui-ux-deep-debug-audit.md:29-31` names four of the unnumbered documents
  this way). One more sits inside a fenced block. None is broken today except
  `AGENTS.md:115`, which names the architecture document at the path this migration creates.
* **Outside Markdown**: two test comments cite a record by path
  (`test/drop_registry_test.dart:122`, `test/helpers/fake_watcher_handle.dart:18`), and two code comments
  cite an unnumbered document by name (`lib/core/git/watch_path_filter.dart:34` "ARCHITECTURE_PLAN
  §watch", `test/ssh_live_transport_test.dart:6` "ACTION_PLAN").
* `.claude/skills/troubleshooting-magic-git/SKILL.md:174` tells a reader a MADR goes "under `docs/`".

Every link that crosses the flat/`decisions/` boundary is written by hand. 0052 and 0053 already reach the
flat records with `../` (for example `0053-MADR-…:21`), and `docs/README.md` reaches 0052 and 0053 with a
`decisions/` prefix. A move changes the depth of 106 files at once.

### What checks exist today

**None for documentation.** There is no CI configuration in the repository. The gate is `flutter test`,
which `AGENTS.md` requires before anything is staged, plus a hook that runs `flutter analyze` before
`git add` (`.agents/pre_add_test_hook.py`). The repository enforces conventions with scan tests rather
than prose — `source_is_text_scan_test`, `provider_retry_policy_test`, `no_real_identifiers_scan_test`,
`watch_stack_structure_test` — and proves guards can fail with the mutation harness `tool/mutate.py`,
which applies catalogued defects in a scratch `git worktree`.

The dotfiles plan points at a `scripts/check_records.py` (with `--next`, `--write-index` and link
detection) on another machine. **It is not on this machine and not in this repository**, so vendoring it
is not an available option; nothing about it can be verified from here.

### Defects the investigation found, and whether this record fixes them

* **27 records have no `verified:` field**, although `AGENTS.md` says every record carries one: the
  PLANs of 0022–0045, 0049, 0052 and 0053. It does not break anything, but a checker that required the
  field would fail on the current tree. **Not fixed here** — see *More Information*.
* **Numbering irregularities that are deliberate and must survive a checker**: 0011 and 0012 each carry
  two unrelated MADRs (documented in `docs/README.md`), 0016 and 0046 are PLANs with no MADR, and 0001 is
  a MADR with no PLAN. A numbering rule that forbade these would fail the tree for reasons already
  accepted.
* **No other dead link, anchor or record-name mention exists.** This is itself a finding: the move is
  starting from a clean baseline, so every failure the checker reports after the move is caused by the
  move.

### The question

How should this repository move its records into the standard tree without breaking any of the ~600
links and mentions, and how does it keep them from rotting afterwards?

## Decision Drivers

* **No broken link may ship.** A link that is silently broken costs a reader later, and a link that
  resolves to the *wrong* file passes a naive checker and still fails the reader.
* **A check is not trusted until it has been seen to fail.** The checker must fail on demand, on planted
  input, and on the real move before its links are rewritten.
* **Enforce in source, not in docs.** This repository keeps a convention in place with a failing test,
  not with a line in `AGENTS.md`. A one-off script does not stop the next record from breaking a link.
* **Every commit stays green.** `flutter test` is the only gate, so an intermediate commit where links are
  broken would fail the suite at that commit and break `git bisect`.
* **History must follow the files.** `git log --follow` on a moved record must still reach its first
  commit. That needs `git mv` and edits small enough to keep rename detection working.
* **Historical records are not rewritten.** Link targets and path pointers change because the files move.
  The findings, decisions and execution logs do not.
* **The deliberate irregularities stay legal**, and no existing file is renumbered (`AGENTS.md`).

## Considered Options

* **A — One-time scripted move, no permanent checker.** Write a throwaway resolver, move, repair, delete
  the resolver.
* **B — Permanent link checker, then the move.** A test that fails on a broken relative link, then the
  move and repair.
* **C — Permanent checker for links, mentions, numbering and layout, proven by fixture tests; then one
  atomic move; then a new `architecture.md`.** The checker covers everything the standard asserts, not
  only links. The move and all link repair land in one commit. The old architecture plan becomes a
  numbered record, and `architecture.md` is written new in `docs/`, from the code.
* **D — Stay flat.** Keep writing new records into `docs/decisions/`, and leave the backlog where it is.

For the architecture document specifically, two sub-options:

* **C1 — Rename `ARCHITECTURE_PLAN.md` to `architecture.md` as it stands.**
* **C2 — Move `ARCHITECTURE_PLAN.md` into the records as a numbered PLAN, and write `architecture.md`
  new, describing the system as it is.**

## Decision Outcome

Chosen option: **"C, with C2"**, because it is the only option that leaves the tree correct *and* keeps it
correct. A catches the move's breakage once and nothing after. B leaves the layout, numbering and
mentions unguarded, and those are what the standard asserts. D keeps the migration growing with every
record. C2 is chosen over C1 because the standard says `architecture.md` "carries no history and no
rationale", and `ARCHITECTURE_PLAN.md` is mostly both: its own banner calls it a "historical plan", and
0007 found stale claims in it (`0007-MADR-…:319`). Renaming it would put the wrong content in the
standard's file. Moving it into the records also keeps every existing citation of it correct, because
each one refers to what it said.

### The checker

A Dart library, `tool/records.dart`, that imports only `dart:io`. It is driven two ways:

* **`test/docs_records_test.dart`**, which runs under `flutter test` — the repository's only gate.
* **The command line**: `dart run tool/records.dart check [--root <dir>]` for a report, and
  `dart run tool/records.dart next` for the next free record number. `AGENTS.md` asks for "tooling that
  is the only source of the next number" where one exists, and this makes one exist.

The files checked are `git ls-files --cached --others --exclude-standard` (tracked plus untracked,
excluding ignored files). Symlinks are skipped, so `CLAUDE.md` and `.goosehints` are not checked twice.
A directory walk was rejected because it would sweep the untracked `.kilo/node_modules` (hundreds of
third-party READMEs). It would also miss the point that a new record should be checked before it is
staged. Content inside fenced code blocks and inline code spans is not parsed for links; it is verbatim
text.

The rules:

| Rule | Asserts | Scope |
| --- | --- | --- |
| **R1 links** | Every relative inline link and reference definition resolves to an existing file or directory | All checked `.md` files |
| **R2 anchors** | A `#fragment` on a link to a Markdown file (or to itself) matches a GitHub-style heading slug in the target | As R1 |
| **R3 path mentions** | Every `docs/…​.md` mention outside fences, blockquotes and YAML frontmatter resolves from the repository root. A record that names a file it will create writes the name without the `docs/` prefix | `.md` files, and `//` comments in `.dart` files |
| **R4 numbering** | At most one MADR per number, except 0011 and 0012 (pinned; a third twin fails); a PLAN whose number has a MADR sits in the MADR's directory; `next` is max + 1 over the whole repository | Record files |
| **R5 frontmatter** | Every record opens with YAML frontmatter containing `status:` | Record files |
| **R6 layout** | `docs/` holds only `README.md`, `architecture.md`, `decisions/`, `reports/`, `guides/`; MADR/PLAN files only in `decisions/`, REPORT/GATES only in `reports/`; record names match `NNNN-(MADR\|PLAN\|REPORT\|GATES)-<kebab>.md`; nothing numbered in `guides/`; root `README.md` links `docs/README.md`; `docs/README.md` links every record | The tree |

The test has two groups. **Fixture tests** build small trees in a temporary directory, each with one
planted defect, and assert that the rule reports it with the path named. **Repository tests** run the
rules against the real tree and assert that nothing is reported. The fixture group is what makes the
checker trustworthy permanently: a mutation that disables a rule is caught by the fixture test, even
though the clean real tree would not notice. The plan proves this with a `tool/mutate.py` catalogue.

R1–R5 run against the real tree from the first phase. R6 is switched on for the real tree only once the
move has happened, because before the move it fails by definition.

### The move

One commit, containing `git mv` for every file plus every link and mention repair. Nothing else goes in
it. The mapping:

* Every `docs/NNNN-MADR-*.md` and `docs/NNNN-PLAN-*.md` → `docs/decisions/`, **name unchanged**.
* `0005-UX-BASELINE-task-centered-adaptive-repository-workspace.md` →
  `reports/0005-REPORT-ux-baseline-task-centered-adaptive-repository-workspace.md`. It keeps its
  number, as `AGENTS.md:149-150` already promises.
* The seven unnumbered records take the next free numbers **after this record's 0054**, in the order they
  were first committed (ties broken by name):

| From | To |
| --- | --- |
| `ACTION_PLAN.md` | `decisions/0055-PLAN-post-review-action-plan.md` |
| `ARCHITECTURE_PLAN.md` | `decisions/0056-PLAN-architecture-and-feature-parity.md` |
| `viewer_engine_findings.md` | `reports/0057-REPORT-file-view-engine-assessment.md` |
| `window_sizing_proposal.md` | `reports/0058-REPORT-window-sizing-assessment.md` |
| `memory_audit.md` | `reports/0059-REPORT-memory-and-performance-audit.md` |
| `DRAG_AND_DROP_ENGINE.md` | `reports/0060-REPORT-drag-and-drop-engine-feasibility.md` |
| `TEST_COVERAGE_PLAN.md` | `decisions/0061-PLAN-remaining-test-coverage.md` |
| `BUILD_MACOS.md` | `guides/build-macos.md` (unnumbered — a guide) |

* **The records that change name get frontmatter**: `status`, `date`, `verified`, and a `former-path:`
  key that records their old path. This makes an old citation (in a commit message, or in another
  repository) traceable. Status comes from the latest audit that checked each one against the code, and
  `verified:` carries that audit's date, never the migration's. Where no audit covers a record, the plan
  checks it during the move and says how far that check went.

Link repair is **computed, not pattern-matched**. For each link, the old target is resolved from the old
source location, mapped through the table, and made relative again from the new source location. Each
repaired link is then checked by target: its new resolution must equal the mapped target, file by file.
A regex rewrite could produce a link that resolves to the *wrong* file, and that would pass R1.

**Path mentions** (`docs/<name>.md` outside link syntax) are rewritten through the same map. They are
pointers, and a pointer to a path that no longer exists is a small broken link. **Bare names are not
rewritten.** A bare name is a mention like `ACTION_PLAN.md` or `0005-UX-BASELINE-…`, with no directory,
and there are headings built from them (`0007-MADR-…`'s "ACTION_PLAN.md: 46 of ~51 verified"). They name
a document as it was called when the record was written. Each still leads to the file, because a search
for the old name finds that file's `former-path:` key. The four code comments that cite a document are
updated by hand, because code comments are not historical records. Three things are left alone:
fenced blocks, blockquotes, and `former-path:` values. All three are verbatim or historical by design. A quotation that is rewritten
no longer quotes anything, and this record's own quotation of `AGENTS.md` is an example. The cost is
that a mention inside a blockquote used as a callout goes unchecked. That is accepted.

### The new `architecture.md`

Written new, describing the system as it is now: the executor seam, the SSH transport (carrying §0.1
forward after checking it against the code), command scheduling and output budgets, the service layer and
forges, the watch pipeline as 0045 left it, state and providers, the multi-window relay, sandbox and
secrets, Help, the build, and the test infrastructure. Each section links the records that govern it.
Every factual claim (a class name, a file path, a limit) is checked against the code before commit, and
the plan records how. `0056-PLAN-…` gets a note at its head pointing to `architecture.md`, and its "§0.1
is authoritative" banner is annotated rather than deleted. `AGENTS.md` points at `architecture.md`
instead.

### `docs/README.md`

It becomes the tree's table of contents. The standard requires an "I want to…" matrix written in the
reader's words, then sections for architecture, guides, decisions and reports. The existing index rows
and their summaries are kept; only their link paths change. Rows are added for 0054–0061 and the 0005
report. R6's index-completeness rule keeps it complete from then on.

### Consequences

* Good, because every relative link, anchor and path mention in the repository is checked on every
  `flutter test`. The dotfiles deviation (d) class of defect — a dead link that sits unnoticed — cannot
  recur here.
* Good, because the layout is enforced, not just described. The "has not migrated yet" caveat in
  `AGENTS.md` is deleted rather than maintained.
* Good, because `dart run tool/records.dart next` replaces a hand scan for numbering. 0011 and 0012 got
  their twins before the numbering rule was enforced, and nothing enforces it now.
* Good, because a record's links are checked before it is staged, since untracked files are included.
* Neutral, because every existing citation keeps its meaning, but 106 files change directory and 8
  change name. Anyone with the old path open in an editor, or a bookmarked GitHub URL, finds it moved.
  `git log --follow` and the `former-path:` keys lead them to the new location.
* Neutral, because the numbers 0055–0061 go to records that are older than 0054. Numbers are assigned
  in order, not by age. The `date:` field and `former-path:` say when each was written.
* Bad, because the checker is new code (an estimated 400–600 lines) in the gate, which has to be maintained. Its
  GitHub slug rules are an approximation of GitHub's renderer. They are proven on the six anchors that
  exist, and the fixture tests pin the cases they cover. An exotic heading could still disagree with
  GitHub.
* Bad, because `git` becomes a dependency of one more test. Other tests already depend on it (the
  `integration` tag), and `mutate.py` runs inside a git worktree, so this adds no new requirement.
* Bad, because the move commit is large: 111 renames with small edits. It is reviewable as
  renames (`git show -M --stat`) plus a link-only diff, and the plan verifies that git detected every
  file as a rename.

### Confirmation

* The checker is seen to fail three ways, and the plan records each: (1) the fixture tests, one per rule,
  each asserting that a planted defect is reported with its path; (2) a `tool/mutate.py` catalogue
  (`tool/mutations/0054-doc-records.json`) that disables each rule's key condition, with every mutation
  killed; (3) **the real move, done first in a scratch clone** — `git mv` only, before repair — must make
  R1 and R3 report a large, recorded number of breaks. The repair must then bring it back to zero.
* After the move: the checker reports zero. Every repaired link resolves to the file the map says it
  should. `git show -M --stat` reports every moved file as a rename. `git log --follow` reaches the
  first commit of a sampled record in each group.
* `flutter analyze` is clean and the full `flutter test` suite passes on the pinned Flutter 3.47.2,
  including the 48 goldens and `no_real_identifiers_scan_test`, which already scans `docs/` recursively
  and so keeps its coverage after the move.

## Pros and Cons of the Options

### A — One-time scripted move, no permanent checker

* Good, because it is the smallest change: no code in the gate.
* Good, because the dotfiles migration proved the procedure on a small tree.
* Bad, because it protects the move and nothing after it. The next record written with a wrong `../`
  ships broken, and so does the one after that. The dotfiles record's own conclusion was that the
  checker should be "a repository artifact rather than a scratch script".
* Bad, because it contradicts the repository's practice of enforcing conventions in source.

### B — Permanent link checker, then the move

* Good, because it closes the dead-link class permanently.
* Good, because it is smaller than C.
* Bad, because the standard's layout rules (no record in `docs/`, pairs in one directory, kinds in their
  directories) stay enforced by prose. That is exactly the kind of enforcement that let this migration
  sit undone.
* Bad, because numbering stays a hand scan. Nothing would stop a third pair of twins like 0011 and
  0012.
* Bad, because a stale path mention (the old `docs/` path of a moved record, written in prose) is not a
  link, so B would not catch it. There are 169 such mentions.

### C — Full checker proven by fixtures, one atomic move, new architecture document

* Good, because it enforces every assertion the standard makes, and does it in the one gate the
  repository has.
* Good, because the fixture tests make the checker's own failure mode (a rule that silently checks
  nothing) detectable, and the mutation catalogue proves it.
* Good, because the one-commit move keeps every commit green and bisectable.
* Neutral, because the scratch-clone run of the move doubles as the checker's most realistic negative
  test at no extra cost.
* Bad, because it is the largest option: a new tool, a new test, a large move commit, and a new
  architecture document that has to be verified claim by claim.

### D — Stay flat

* Good, because it costs nothing now.
* Bad, because it leaves the tree contradicting its own instructions. `AGENTS.md` has to keep a caveat
  explaining the contradiction.
* Bad, because the cost grows: each new record adds links across the flat/`decisions/` boundary, and
  those links are written by hand.
* Bad, because the links stay unchecked.

### C1 — Rename `ARCHITECTURE_PLAN.md` to `architecture.md` as it stands

* Good, because it is one `git mv`, and `git log --follow` on `architecture.md` reaches 2026-07-06.
* Good, because it is the most literal reading of "rename".
* Bad, because the file would describe a July plan, with a roadmap and "Implementation status (as of
  2026-07-17)", under the one name the standard reserves for how the system is *now*. Its own banner
  warns that older sections are wrong ("may still say 'serialized `_tail`' … treat §0.1 as
  authoritative").
* Bad, because it would then have to be edited heavily into an as-is document. That destroys a
  historical record that 19 other records cite for what it *said*.

### C2 — Archive it as a numbered PLAN, write `architecture.md` new

* Good, because both files are then what their names say: a historical plan among the records, and an
  as-is description where the standard puts one.
* Good, because every existing citation of `ARCHITECTURE_PLAN` stays correct: they refer to its content,
  and that content is unchanged at its new path.
* Bad, because `architecture.md` starts with no history of its own. The plan links it to its sources
  instead.
* Bad, because writing it is real work. Every claim has to be checked against the code, and it will need
  the same upkeep any as-is document needs.

## More Information

* **Relationship to other records.** This executes the magic-git part of Phase 6 of the dotfiles
  repository's 0007-PLAN (standard documentation layout). That plan lives in another repository and a
  relative link cannot reach it, so it is cited here by name only. This record does not edit it.
  Whether to mark that phase done there is the maintainer's call, and the plan says so at handoff.
  `0005-UX-BASELINE-…` becoming `0005-REPORT-…` is the rename `AGENTS.md:149-150` already anticipates.
* **Why the `verified:` gap is not closed here.** Requiring `verified:` in R5 would fail the tree on
  the 27 PLANs listed above. Adding the field with an honest date means checking each plan's status
  against the code, which is a statuses audit (the kind 0007 and 0022 did), not a migration. Adding it
  with a made-up date would falsify the one field whose purpose is to say when a claim was checked.
  R5 is written so that requiring `verified:` later is a one-line change, and the plan records the gap
  as an open item. **Maintainer's decision (2026-09-19): deferred** to a separate statuses audit;
  not part of this work.
* **Why there is no rule for bare record names.** An earlier draft had one: every token shaped like a
  record filename must name a record that exists. It was dropped for two reasons. First, it contradicts
  keeping bare names as historical identifiers, as above. Second, it flags every record that names a
  record still to be written — this record's own mapping table, for one. R3 covers the case that
  matters: a path a reader would follow.
* **Things this record does not establish.** The GitHub slug algorithm is reproduced from GitHub's
  documented behaviour and checked against the six anchors that exist. It is not guaranteed for every
  possible heading. Whether GitHub's web view renders every link identically to a filesystem
  resolution (for example a link to a directory) is assumed rather than tested.

## Decision (2026-09-19)

Accepted by the maintainer as proposed, with these answers to the four review points:

1. **The architecture document is a full rewrite to the standard** (C2). `ARCHITECTURE_PLAN.md` becomes
   `0056-PLAN-architecture-and-feature-parity.md`, and `architecture.md` is written new.
2. **The `verified:` backfill for the 27 PLANs is deferred** (see *More Information*).
3. **Bare names, blockquotes and fenced blocks are not rewritten** — accepted.
4. **The R3 writing convention** (a file that does not exist yet is named without the `docs/` prefix)
   — accepted.
