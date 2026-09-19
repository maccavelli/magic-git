---
status: "executed"
date: 2026-09-05
associated-madr: "0031-MADR-forge-namespace-on-create.md"
---

# Add a forge namespace to the create-repository flow

Associated MADR: [0031-MADR-forge-namespace-on-create.md](0031-MADR-forge-namespace-on-create.md)

## Goal

Let the create-repository sheet create a project under **any namespace the user
has rights to**, not only their default one — as a picker populated from the
forge, editable as free text, with the chosen value composed into the **full
path** passed as the CLI's positional argument.

## Scope

**In scope**

* A namespace input on the sheet, for the GitHub and GitLab remote modes.
* A service call listing the namespaces the account may create in, host-explicit
  (there is no origin yet at create time).
* Composing `namespace/name` and passing it positionally.
* Splitting the validation that currently makes this impossible.

**Out of scope**

* `newFolder` mode's name rules. There the name is also the directory name and
  must keep rejecting `/` (`create_repo_sheet.dart:445`).
* The clone sheet, and any other flow that does not create a project.
* Changing `resolveOriginUrl`, the origin wiring or the push. They already
  handle `a/b/c` — that is the MADR's central finding and this plan must not
  disturb it.
* Creating a project on a real forge as part of the offline suite.

## Preconditions

```sh
flutter --version | head -1          # must equal FLUTTER_VERSION (3.47.2)
flutter pub get --enforce-lockfile   # "Got dependencies!"
git status --short                   # empty
flutter analyze                      # No issues found!
flutter test                         # 3549 passing, 2 skipped, 0 failing
```

~~Any deviation from **3549 / 2 / 0**: stop and prompt.~~

> **Amended 2026-09-05 (before Phase 1).** The baseline is **3554 / 2 / 0**.
> The plan was written at 3549; the difference is five tests added afterwards
> and fully accounted for, so this is stale bookkeeping rather than a
> discovered problem:
>
> * `+3` — `test/workspace_focus_ring_test.dart`, commit `4147b2e`, landed
>   after the plan commit `e200dd7`;
> * `+2` — `test/no_real_identifiers_scan_test.dart`, the guard added when the
>   internal identifiers were purged from the tree.
>
> Any deviation from **3554 / 2 / 0** from here: stop and prompt.
>
> The tree is also not empty at Phase 1 start: the identifier redaction (19
> files) and its guard are uncommitted, because the maintainer commits each
> cycle himself. Those paths do not intersect this plan's file list.

## Implementation Steps

---

### Phase 1 — List the namespaces a user may create in

**Files.** `lib/core/gitlab/glab_service.dart`, `lib/core/github/gh_service.dart`;
`test/forge_namespaces_test.dart` (new).

```dart
/// Namespaces this account may create a project in, most-usable first:
/// the user's own namespace, then groups by full path.
Future<List<String>> listCreatableNamespaces(
  String repoPath, {
  required String host,
});
```

**GitLab.** `groups?min_access_level=30` via the existing `api()` helper, which
already takes an explicit `host` (`glab_service.dart:479-486`) — necessary here
because there is **no origin to infer the host from** at create time. Read
`full_path`. Prepend the user's own namespace from `glab api user`.

> **`namespaces` is the wrong endpoint and must not be used.** Verified live: it
> returns entries the user can *see*, including other people's personal
> namespaces, not ones they can create in. The MADR records the measurement.

**GitHub.** `gh api user/orgs` for org logins, prepended with the authenticated
login from `gh api user`.

**1a. Negative test.** A fake executor returning recorded JSON; assert the
parsed list, the own-namespace-first ordering, and that a non-JSON or failing
response yields an **empty list rather than throwing** — the sheet must stay
usable when the API does not answer.

**Required red:** `Expected: ['<user>', 'team/subgroup'] / Actual: []` before
the method exists.

**Acceptance.** Tests red then green; suite +N; analyzer clean. **Commit.**

---

### Phase 2 — Split the validation, and compose the path

~~**Files.** `lib/features/workspace/create_repo_sheet.dart`;
`test/create_repo_namespace_test.dart` (new).~~

> **Deviation, 2026-09-05 — the sheet harness is private.**
>
> *Found:* the plan's Phase 2 file list, and its acceptance criterion "no
> existing sheet test changes", assumed a new test file could drive
> `CreateRepositorySheet` on its own. It cannot. The whole harness —
> `_FakeExecutor`, `_StubConnection`, `_FakeStore`, `_PrefillSettings`,
> `_pumpConnected`, `_pumpCreate`, `_nameField`, `_next`, `_createButton` — is
> private to `test/create_repo_sheet_test.dart` (lines 29–263 of 1539), and
> `test/helpers/` holds no create-sheet harness. Pre-existing: that file is
> unmodified in the working tree and the privacy is original to it, not
> introduced by this phase.
>
> *Decision (maintainer, 2026-09-05):* **extract the harness** into
> `test/helpers/create_repo_harness.dart` and have both test files import it,
> rather than appending the new tests to the existing file or duplicating the
> harness. Phase 3 needs the same harness, and a second copy would drift.
>
> *Scope added to this phase:* `test/helpers/create_repo_harness.dart` (new)
> and `test/create_repo_sheet_test.dart` (imports and helper references only).
> The acceptance criterion is amended to: **no existing sheet test's
> assertions change, and all of them stay green.**

**Files.** `lib/features/workspace/create_repo_sheet.dart`;
`test/helpers/create_repo_harness.dart` (new);
`test/create_repo_sheet_test.dart` (harness extraction only);
`test/create_repo_namespace_test.dart` (new).

The block today is one line: `_detailsValid()` calls
`HostFsService.isValidRepoDirName(_name.text.trim())`
(`create_repo_sheet.dart:254`), which rejects any `/`
(`core/git/host_fs_service.dart:198-206`).

* Add `_namespace` (a controller), rendered only when `_onForge`.
* `_name` keeps `isValidRepoDirName` — **in both modes**. The name is a single
  segment; the namespace is the thing that may contain slashes.
* Add a namespace validator: non-empty segments, no leading/trailing `/`, no
  whitespace, no `..`. Empty namespace is legal and means "the default", which
  is today's behaviour.
* Compose at the call sites (`:661`, `:713`):
  `final path = ns.isEmpty ? name : '$ns/$name';` passed as `name:`.

> **Pass the full path, never `--group`.** `glab repo create foo --group
> team/sub` creates `team/sub/foo`, but the app then calls
> `resolveOriginUrl(name: 'foo')`, which — seeing no `/` — looks up
> `<user>/foo`, fails, and reports "origin could not be determined" for a
> project that was created correctly. The positional form is what the resolver
> already understands (`glab_service.dart:341-351`).

**2a. Negative tests.**
* a namespace + name composes `team/subgroup/repo` into the positional argument
  — **required red:** `Actual: 'repo'`;
* an empty namespace still creates a bare name (today's behaviour, unchanged);
* `newFolder` mode still refuses a `/` **in the name** — required red if the
  validator is loosened for the wrong field;
* the composed path reaches `resolveOriginUrl` **as the same string** that was
  created. This is the regression the `--group` note above describes; assert it
  explicitly rather than trusting the composition.

**Acceptance.** Tests red then green; no existing sheet test's assertions
change and all stay green (amended — see the deviation above). **Commit.**

---

### Phase 3 — Populate the field from the forge

**Files.** `create_repo_sheet.dart`, `lib/core/providers/app_providers.dart`;
`test/create_repo_namespace_test.dart`.

A namespace suggestion list fetched once per (forge, host), offered beneath the
field. **The field stays free text**: a group the API did not return — a fresh
grant, a paginated tail, an unreachable API — must remain typeable.

**Constraints, stated because this sheet has no forge round trip today:**

* **Lazy and non-blocking.** The sheet opens and stays usable while the list
  loads. It must not render an `AsyncValue` through `.when()` and replace the
  form with a spinner — 0030 Phase 1's finding, and `assertion_strength_scan_test`
  will flag a new boundary site that omits `skipLoadingOnReload:`.
* **Failure is silent and non-blocking**: no list, no error banner, field still
  works. A namespace picker is a convenience; typing is the contract.
* The provider is `autoDispose` and keyed by `(forge, host)`, so switching
  remote mode or host re-fetches rather than showing the previous forge's
  groups.

**3a. Negative test.** With the service throwing, the sheet still renders its
namespace field and a create still composes correctly.
**Required red:** the sheet shows an error state or the field disappears.

**Acceptance.** Tests red then green; `assertion_strength_scan_test` and
`refresh_no_flash_test` both still green (they will catch a spinner-over-form
regression). **Commit.**

---

### Phase 4 — Live verification *(requires explicit approval; mutating)*

**No offline code.** Creating a project under a non-default namespace **creates
a real project on a real forge**. `AGENTS.md` forbids running `live-forge`
unprompted; this phase does not run as part of plan execution.

Added to `test/create_repo_wire_live_test.dart` behind the `live-forge` tag:

1. create under a **top-level group** the account may write to;
2. create under a **nested subgroup** (`team/sub/name`, two levels) — **the open
   question the MADR names.** GitLab identifies groups by `full_path` so it
   should work, and glab's own help example is single-level. This is the first
   thing to establish;
3. assert origin resolves to the created project's URL, not to
   `<user>/<name>` — the `--group` trap, verified end to end;
4. delete both projects afterwards.

**Until this runs, the claim "creates under the chosen namespace" is
unverified** and the plan is `complete` only in its offline scope. That is
stated in the execution record rather than implied by a green suite.

---

## Verification

**Per phase:** the phase's own tests, plus

```sh
flutter analyze          # No issues found!
flutter test             # passing rises by exactly the tests added; failing 0
```

**Whole-plan acceptance.**

1. Every negative test observed red, verbatim, in the execution record.
2. `flutter analyze` clean; `flutter test` 0 failing throughout.
3. `newFolder` mode still rejects `/` in the name.
4. Nothing below the sheet changed — `resolveOriginUrl`, origin wiring and push
   are untouched, and their existing tests pass unmodified.
5. The composed path is asserted to reach the resolver as the same string that
   was created.
6. Phase 4 is **not** run without explicit approval, and its absence is recorded
   as an unverified claim rather than omitted.
7. No internal hostname, account or group path appears in any committed file
   (global rules: *Internal identifiers never go into committed content*).

## Rollout and Rollback

Additive: an empty namespace reproduces today's behaviour exactly, so a user who
ignores the field sees no change. Rollback is reverting the phase commits.

**The risk that matters is a silent mis-create** — a project created in one
place while the app wires origin to another. That is precisely what passing
`--group` instead of the full path would cause, and why Phase 2 asserts the
composed path reaches the resolver unchanged rather than assuming it.

A second, smaller risk: the namespace list is a new forge round trip on a sheet
that currently opens with none. If it is not lazy, the first symptom is a
create-repository sheet that hangs on open for a user whose forge is slow or
unreachable — worse than the missing feature.

## Execution record

| Phase | Status | Commit | Red observed | Result |
|---|---|---|---|---|
| 1 | **complete** | *(this commit)* | yes, verbatim below | 3554 → 3562, analyzer clean |
| 2 | **complete** | *(this commit)* | yes, 4 sabotages | 3562 → 3568, analyzer clean |
| 3 | **complete** | *(this commit)* | yes, 3 sabotages | 3568 → 3571, analyzer clean |
| 4 | **complete** | *(this commit)* | n/a — live | 2/2 passed against a real GitLab instance, 30 s |

### Phase 1 — 2026-09-05

`listCreatableNamespaces(repoPath, {required String host})` added to
`GlabService` (`glab_service.dart:535`) and `GhService` (`gh_service.dart:369`);
eight tests in `test/forge_namespaces_test.dart`. Both diffs are **pure
insertion** — 95 added lines, none removed — so nothing below the sheet moved.

* **GitLab** — `glab api user -i` for the own namespace, then
  `groups?min_access_level=30&per_page=100` through the existing `api()` helper,
  reading `full_path`. `api()` already takes an explicit `host`, which is what
  this needs: at create time there is no origin to infer one from.
* **GitHub** — `gh api user` for the login, then `gh api user/orgs`. `gh api`
  has no `--hostname`, so the host rides `GH_HOST` via the existing `hostEnv()`.
* **Failure is not an exception.** A dead account call yields `[]`; a dead
  group/org call still yields the own namespace. The sheet's field is free
  text, so a namespace list that cannot load must not reach it as an error.

**Required red, observed verbatim** against stubs returning `const <String>[]`,
before either implementation existed:

```
Expected: ['testuser', 'team/subgroup', 'platform']
  Actual: []
Expected: ['testuser']
  Actual: []
```

**Two checks were vacuous when first written, and are recorded rather than
quietly fixed:**

1. `expect(exec.envs.every((e) => e?['GH_HOST'] == …), isTrue)` passed against
   the empty stub, because `every` on an empty list is true. Now preceded by
   `expect(exec.envs, hasLength(2))`.
2. The two "non-JSON yields an empty list" tests passed trivially while the
   stub returned `[]`. Proven afterwards by sabotage: all four `catch` blocks
   were rewritten to `rethrow` and the four failure-path tests went red —

   ```
   GlabService … a failing groups call still yields the own namespace [E]
   GlabService … non-JSON answers yield an empty list rather than throwing [E]
   GhService  … a failing orgs call still yields the login [E]
   GhService  … non-JSON answers yield an empty list rather than throwing [E]
   ```

   The sabotage ran against scratchpad copies of both service files and was
   restored by copying them back, verified byte-identical with `cmp`. No git
   command that discards work was used at any point.

**Not yet true.** Nothing calls this method — the sheet is Phase 2/3, and no
project has been created under a non-default namespace on a real forge. The
nested-subgroup question the MADR raises stays open until Phase 4, which is
mutating and unauthorised.

### Phase 2 — 2026-09-05

A `Namespace (optional)` field on the Details step, shown only in forge modes,
composed into `_forgePath` and passed as the CLI's positional argument at all
four forge call sites (`create_repo_sheet.dart:694, 701, 727, 746, 753, 776`).
Six tests in `test/create_repo_namespace_test.dart`.

The split the plan asked for: **`_name` keeps `isValidRepoDirName` in both
modes** — it is the directory name in `newFolder` mode and the project's last
segment on the forge, so it stays one segment either way. `_namespace` is the
only field that may contain `/`, and an empty one means "my default namespace",
which reproduces today's behaviour exactly.

`name` (the local directory) and `forgePath` (what the forge creates and what
origin is resolved against) are now separate locals, computed once at
`create_repo_sheet.dart:472`, so the create and the lookup cannot drift.

**Deviation executed:** the harness extraction described above.
`test/helpers/create_repo_harness.dart` (231 lines) now holds
`FakeCreateExecutor`, `StubConnection`, `FakeConnectionStore`, the settings
notifiers, `pumpConnected`, `pumpCreate` and the field/button finders.
`create_repo_sheet_test.dart` imports it. The extraction was proved
assertion-neutral rather than assumed: reversing the 23 renames on the new
file's `main()` and diffing against `HEAD` yields 61 diff lines, **every one of
them `dart format` rewrapping an expression whose identifier changed length** —
`expect(` count 126 → 126, `testWidgets(` count 28 → 28, all 28 green.

**Red observed.** These tests were written after the implementation, so each
was proved by sabotage rather than by writing it first. Four separate
sabotages, each against a scratchpad copy of `create_repo_sheet.dart` restored
by `cmp`-verified copy, each failing exactly the one test that covers it:

| Sabotage | Test that went red | Failure |
|---|---|---|
| `name:` reverted to the bare name at all four call sites | composes into the positional argument; created-path/resolved-path identity | `Expected: 'team/subgroup/repo'` / `Actual: 'repo'` |
| `isValidRepoDirName` loosened to an emptiness check | a slash in the NAME is still refused | `[E]` |
| the namespace validator line deleted | a malformed namespace blocks Continue | `namespace "/team" should be rejected` |
| the field's `if (_onForge)` guard forced true | the field only exists in forge modes | `[E]` |

The first row is the one that matters: it is the `--group` trap reproduced
directly, and it is why the created path is asserted to reach `gh repo view`
as the same string rather than being trusted from the composition.

**Not yet true.** The field is free text with no suggestions —
`listCreatableNamespaces` from Phase 1 still has no caller. Nothing has created
a project under a non-default namespace on a real forge; the nested-subgroup
question stays open until Phase 4.

### Phase 3 — 2026-09-05

`forgeNamespacesProvider` (`app_providers.dart:5368`), an `autoDispose` family
keyed `(Forge, String host, bool local)` with `retry: noProviderRetry`, calling
Phase 1's `listCreatableNamespaces`. Keyed on the host because the wizard's
host field is editable: switching from `gitlab.com` to a self-hosted instance
must not keep offering the first host's groups. Three tests added, nine in the
file.

Suggestions render as `InlineActionButton` chips beneath the field
(`_namespaceSuggestions`, `create_repo_sheet.dart:1449`) — the repo's enforced
small-button standard. Tapping one fills the field; a `Clear` chip appears once
a namespace is set. **The field stays free text**, so a group the API did not
return is still typeable.

**Read through `asData?.value`, never `.when()`.** The plan named this as the
constraint and it is the whole design: while the fetch is in flight, and
permanently after it fails, the strip renders as empty space. `valueOrNull`
does not exist on this Riverpod version's `AsyncValue`; `asData?.value` is the
idiom already used across `lib/features/`.

**Red observed.** Three sabotages, each against a scratchpad copy of the sheet
restored by `cmp`-verified copy:

| Sabotage | Test that went red |
|---|---|
| the strip returns a `ProgressCircle` while `!hasValue` | *forge that never answers*; *throwing service* — both `[E]` |
| the field's own `if (_onForge)` guard also requires `hasValue`, so the field disappears while pending | *forge that never answers*; *throwing service* — both `[E]` |
| a suggestion chip's `onPressed` no longer writes the field | *offered namespaces fill the field when tapped* — `[E]` |

The first two are exactly the failure the plan predicted — "a create-repository
sheet that hangs on open for a user whose forge is slow or unreachable" — and
they are the reason the two failure tests assert *the field is still there and
the create still composes*, rather than asserting anything about the list.

`assertion_strength_scan_test` and `refresh_no_flash_test` are both green; no
new boundary `.when()` site was introduced, because there is no `.when()`.

## ~~Residual — the plan is complete only in its offline scope~~

> **Resolved 2026-09-05 by the Phase 4 run recorded below.** Kept as written
> so the record shows what was unproven at the time, and for how long.

Phases 1–3 shipped. **Phase 4 has not run and was not authorised**, so the
claim *"creates under the chosen namespace"* is **verified against fakes only**.
Specifically still unestablished:

* that `glab repo create team/sub/name` works for a **nested** subgroup (two
  levels). GitLab identifies groups by `full_path` so it should, and glab's own
  help example is single-level — the MADR names this as the open question;
* that origin resolves to the created project rather than to
  `<login>/<name>` **on a real forge**, end to end;
* that `gh repo create org/name` behaves the same way for a GitHub org.

Running Phase 4 creates and deletes real projects on a real forge. It needs
explicit approval per `AGENTS.md`, and is invoked as
`flutter test --run-skipped -t live-forge test/create_repo_wire_live_test.dart`.
Until then this feature is shipped but unproven against the thing it targets.

### Phase 4 — 2026-09-05 *(live, maintainer-run)*

Run by the maintainer against a real GitLab instance, both cases green:

```
00:00 +0: GitLab live create under a namespace creates in <group> (top-level) …
00:22 +1: GitLab live create under a namespace creates in <group>/<subgroup> (nested, 2 levels) …
00:30 +2: All tests passed!
```

**The MADR's open question is answered: a nested subgroup works.** GitLab
identifies groups by `full_path`, and `glab repo create <group>/<subgroup>/<name>`
creates the project there even though glab's own help example is single-level.
Top-level and two-level namespaces both succeeded.

Each case asserted, in order:

1. the project exists at the requested path — asked of
   `glab api projects/<encoded>` and compared against `path_with_namespace`,
   **not** inferred from the create output, which a `--group` create would print
   identically;
2. `resolveOriginUrl` returns a URL containing that same full path, so the
   created project and the wired origin cannot silently disagree — the
   `--group` trap, checked end to end on a real forge for the first time;
3. `git remote add` + `push -u origin main` succeeds and `ls-remote` shows
   `refs/heads/main` under that namespace.

Both projects were deleted by the `finally` block; the suite finished clean, so
no cleanup warning fired.

**Everything MADR 0031 claimed is now verified against the thing it targets.**
The one part of Phase 4's original scope not exercised is the GitHub org case
(`gh repo create org/name`) — the signed-in GitHub token has no `delete_repo`
scope, which is why this file's GitHub coverage has always been the
non-mutating half. GitHub is unchanged by 0031 and shares the composition path
with GitLab, but that specific create has not been run live.

### Known leak in this test's output

The test name interpolates the namespace (`'creates in $namespace …'`), so a
run prints the real group path to stdout and into any log or CI report kept
from it. The committed file holds no identifier — the value arrives from
`MAGIC_GIT_LIVE_NAMESPACES` — but the *output* does. Not yet fixed.
