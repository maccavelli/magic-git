---
status: executed
date: 2026-09-03
executed: 2026-09-03
verified: 2026-09-03
associated-madr: 0021-MADR-create-repo-identity-and-origin.md
owner: [Maintainer]
target-milestone: This work cycle
---

# Implement per-repo git identity on Create, then keep origin + push

Associated MADR:
[0021-MADR-create-repo-identity-and-origin.md](0021-MADR-create-repo-identity-and-origin.md)

This plan is the **single execution vehicle** for that decision. A second
engineer following only this file, against `origin/master` at the moment
the MADR is accepted, must produce the same diff. Do not invent a
different architecture here — amend the MADR first.

**Execution note (2026-09-03).** Maintainer accepted the MADR and
approved this PLAN. Phases 1–3 were already mixed in the working tree
from pre-approval work, so they shipped as one engineering commit
(`69e784d`) rather than four. T5–T7 and T10 were written at execute.
Incidental `analysis_options.yaml` / `pubspec.lock` were reverted and
not committed. Never `git push` unless asked in the same turn. Never
run `live-forge` tests.

Deviation rule (global): if a step is wrong, a listed file is
insufficient, or a pre-existing test fails on an untouched file, **stop
and prompt**. Do not skip assertions, mark tests skipped, or redraw
scope so the failure falls outside the phase. Every option offered on a
deviation must be a real fix, not a workaround.

## Goal

The Create repository wizard collects a git identity (name + email),
writes it into the **new repository's** local git config, and uses it to
author the optional initial commit so that commit can be pushed to the
origin the wizard already wires.

**Acceptance criteria** (end of Phase 3; Phase 4 is docs)

1. Details shows two fields after the README / commit-all toggle:
   placeholder `Your name` and `you@example.com`. They prefill from
   `appSettingsProvider` via `_applyIdentityPrefill` in `initState`
   **and** from a `ref.listen(appSettingsProvider)` in `build` (Settings
   emits empty defaults first, then disk). Only un-edited fields receive
   a non-empty Settings value. They are disposed with the other
   controllers.
2. Continue on Details is disabled when `_addReadme || _commitAll` and
   identity is invalid. Valid means: trimmed name non-empty, trimmed
   email has `@` with at least one character on each side and no spaces.
   Invalid emails include `not-an-email`, `@x`, `x@`. A test must observe
   Continue disabled in those states, then enabled once both fields are
   valid. A Settings-prefilled valid identity must **not** disable
   Continue when README/commit-all is on, and must **not** use the red
   outline. Each invalid required field uses
   `kAppTextFieldErrorDecoration` (name: empty; email: not
   `_looksLikeEmail`); a valid field and optional identity use the stock
   outline.
3. After a successful `git init` (new folder or in-place init), if
   identity is valid, the sheet runs exactly:
   ```
   git config --local user.name <name>
   git config --local user.email <email>
   ```
   against `dest`, `ExecLane.exclusive`, `retries: 0`. Failures append a
   warning and do not abort the create. An **existing** repo (`alreadyRepo`)
   gets this write only when commit-all is on.
4. README commit argv is
   ```
   git add -- README.md
   git -c user.name=<name> -c user.email=<email> commit --no-gpg-sign -m Initial commit
   ```
   Commit-all is the same commit argv after `git add --all`. README
   content is unchanged (`# <name>\n` or `# <name>\n\n<description>\n`).
5. Submit order is frozen:
   init → identity config (when rule 3 applies) → optional commit →
   forge create / custom remote add → `_ensureForgeOrigin` / push when
   `hasCommit` → `git remote get-url origin` verify → register.
   GitHub/GitLab remain API-only (`no --source/--remote/--push`; GitLab
   keeps `--skipGitInit`).
6. `CreateRepositorySheet` never calls
   `appSettingsProvider.notifier.setPreferences` (nor any other Settings
   writer). A spy on `setPreferences` is first shown to increment when
   invoked, then asserted at 0 across a create that filled identity.
   `rg -n setPreferences lib/features/workspace/create_repo_sheet.dart`
   prints nothing.
7. Review shows a `Git identity` row (`name · email`) when either field
   is non-empty. Help Book Create details item is
   `Details — name, initial branch, git identity (name and email), first commit.`
8. `flutter analyze` exit 0 on touched Dart. `dart format --output=none
   --set-exit-if-changed` clean on those files.
   `flutter test test/create_repo_sheet_test.dart test/help_book_json_test.dart`
   green. No `live-forge`.

## Scope

**In scope**

| Phase | Outcome |
|---|---|
| 1 | Details UI, gating, Settings prefill (init + listen), red outline when required-and-invalid, review row, Help Book line; tests T1–T7 |
| 2 | Local `git config`, authored initial commit, `--no-gpg-sign`; submit order |
| 3 | Submit argv tests, T8–T10, live-test `initLocalRepo` argv parity, Settings-write ban |
| 4 | This PLAN + MADR indexed; status updated after acceptance |

**Out of scope** (do not implement, even if adjacent)

* Writing identity into Settings, Keychain, or `git config --global`.
* Changing default Remote from `None`.
* Requiring identity when no initial commit is requested.
* Overwriting `user.name` / `user.email` on an existing repo unless
  commit-all is on.
* Probing the target's global git config to prefill or to block create.
* Rewriting `GhService.resolveOriginUrl` /
  `GlabService.resolveOriginUrl` / `_ensureForgeOrigin` /
  `_pushInitial` / forge `createRepoInExisting` argv.
* Routing the initial commit through `GitService.commit`.
* Dummy authors, retries around a failed commit, or deleting the repo
  after a failed commit/push (keep-on-failure stays).
* Changing README contents, branch field, or registration.
* Running `test/create_repo_wire_live_test.dart` (tagged `live-forge`,
  mutating). Update its `initLocalRepo` argv only.
* `analysis_options.yaml` (this session added `macos/**` to analyzer
  `exclude` — revert if still dirty; not this work).
* `pubspec.lock` churn from `flutter test` resolving newer packages —
  revert if still dirty; not this work.

## Frozen UI, argv, and helpers

These literals are the spec. A phase that emits different placeholders,
a different flag, or a different helper name is a deviation.

### Controllers and prefill

In `_CreateRepositorySheetState`:

```dart
final _authorName = TextEditingController();
final _authorEmail = TextEditingController();
bool _authorNameEdited = false;
bool _authorEmailEdited = false;
```

`initState`, after `_recomputeTarget()`:

```dart
_applyIdentityPrefill(ref.read(appSettingsProvider));
```

`build` (always, not only when `_onForge`):

```dart
ref.listen(appSettingsProvider, (previous, next) {
  if (_applyIdentityPrefill(next)) setState(() {});
});
```

`_applyIdentityPrefill` copies `settings.committerName` /
`committerEmail` into a field only when all of: the field is un-edited,
the Settings value trims non-empty, and the controller text is not
already that value. Empty Settings values are ignored (must not wipe a
typed or still-empty field). Returns whether a controller changed.

`onChanged` on each identity field sets the matching `*Edited` flag
then `setState`. A cleared or replaced prefill is sticky.

`dispose` must dispose both controllers, next to `_remoteUrl.dispose()`.

Import `../../core/settings/app_settings.dart` for `appSettingsProvider`
(it is declared there, not re-exported from `app_providers.dart`).

~~Original (superseded 2026-09-03):~~ assign `committerName` /
`committerEmail` onto the controllers in `initState` only. That saw the
empty default snapshot and outlined Settings-backed identity as
required. Replaced by `_applyIdentityPrefill` + `ref.listen`.

### Validation

```dart
bool get _needsIdentity => _addReadme || _commitAll;

String get _authorNameText => _authorName.text.trim();
String get _authorEmailText => _authorEmail.text.trim();

bool get _identityValid =>
    _authorNameText.isNotEmpty && _looksLikeEmail(_authorEmailText);

static bool _looksLikeEmail(String email) {
  final at = email.indexOf('@');
  return at > 0 && at < email.length - 1 && !email.contains(' ');
}
```

`_detailsValid` keeps the existing name/branch checks, then:

```
if (_needsIdentity && !_identityValid) return false;
```

### Identity argv

```dart
List<String> get _identityArgs => [
  if (_authorNameText.isNotEmpty) ...['-c', 'user.name=$_authorNameText'],
  if (_authorEmailText.isNotEmpty) ...['-c', 'user.email=$_authorEmailText'],
];
```

Config write (only when `_identityValid && (!alreadyRepo || _commitAll)`),
after init, before the optional commit, `repoPath: dest`:

```
['git', 'config', '--local', 'user.name', _authorNameText]
['git', 'config', '--local', 'user.email', _authorEmailText]
```

README commit:

```
['git', 'add', '--', 'README.md']
['git', ..._identityArgs, 'commit', '--no-gpg-sign', '-m', 'Initial commit']
```

Commit-all: `['git', 'add', '--all']` then the same commit argv.

Config-write failure warning starts with
`Could not write git identity into the new repository`.
Commit-failure warnings must **not** ask whether `user.name / user.email`
are configured on the target (that copy is the bug this plan removes).

### Details layout (order is load-bearing)

Inside `_detailsStep`, after the initial-branch field and hint:

1. README toggle **or** commit-all toggle (existing widgets, unchanged
   labels).
2. Caption `Git identity`.
3. Name field, placeholder `Your name`.
4. Email field, placeholder `you@example.com`.
5. When `_needsIdentity` is true, an invalid field uses
   `kAppTextFieldErrorDecoration` /
   `kAppTextFieldErrorFocusedDecoration` (same fill as the stock
   fields, `#FF453A` outline; focused is width 2). Name is invalid when
   empty; email is invalid when `_looksLikeEmail` is false. A valid
   field — including one prefilled from Settings — and both fields when
   identity is optional, keep `kAppTextFieldDecoration` /
   `kAppTextFieldFocusedDecoration`. Required/red is a function of the
   **field text**, never of “Settings has an identity but it has not
   been copied yet”: the listen in Frozen prefill must have copied it
   first.
6. Hint: required copy when `_needsIdentity`, optional copy otherwise;
   both mention prefill from Settings when set. Must not say the values
   are saved to Settings.
7. Existing save-to-local / fsmonitor / label block.

Identity **below** the README toggle so the toggle stays at its previous
vertical position (otherwise widget tests miss the tap; the field itself
is in a `SingleChildScrollView`).

Both identity fields `onChanged` set the matching `*Edited` flag and
`setState`, so Continue and the outline recompute and prefill does not
overwrite the edit.

### Review

After the `Initial branch` row, before `Remote`:

```
if (_authorNameText.isNotEmpty || _authorEmailText.isNotEmpty)
  _reviewRow(typography, 'Git identity',
    [name?, email?].join(' · '));
```

### Help Book

`macos/Runner/help_book.json` topic `clone_create`, Create items, the
Details bullet becomes the string in acceptance criterion 7.
`test/help_book_json_test.dart` `required['clone_create']` gains
`'git identity'`.

### Forbidden

No `_rememberIdentity`. No
`ref.read(appSettingsProvider.notifier).setPreferences(...)`.
Prefill is read-only.

## Tests to write

Every identity behaviour in the Goal has a named test here. A phase
that ships the production change without the matching rows is
incomplete. Exact names are load-bearing (`--plain-name`). Negative
observations (the check is seen to fail) are called out; do not skip
them.

Helpers used by several rows (`_fillIdentity`, `_tapReadme`,
`_queueIdentityConfig`, `_identityCommit`, `_PrefillSettings`,
`_LateSettings`, `_GuardSettings`) are specified in Phase 3a / 1e.
Existing submit tests that do not commit keep their names; Phase 3b
only updates the ones listed there.

### `test/create_repo_sheet_test.dart` — new tests (Phase 1)

| # | Exact name | Asserts | Negative observation |
|---|---|---|---|
| T1 | `Add a README gates Continue until a git identity is filled` | Optional identity: Continue enabled, stock outline. README on, empty: Continue disabled, both fields `kAppTextFieldErrorDecoration`. Name filled: name stock, email still error. `not-an-email`: email still error, Continue disabled. Valid email: Continue enabled, both stock. | Continue is **null** and both fields error after README on with empty identity. Email `not-an-email` keeps Continue null and email error. |
| T2 | `git identity prefills from Settings` | With `_PrefillSettings` (Jane Developer / jane@example.com), Details controllers hold those strings. Read `controller?.text`, not `find.text`. | — |
| T3 | `Settings-prefilled identity is not marked required when README is on` | Same override as T2. Details, valid repo name, tap README. Continue **enabled**. Both fields `kAppTextFieldDecoration`. | — (T4 is the empty-first counterpart) |
| T4 | `identity required outline clears when Settings loads after open` | `_LateSettings` `build()`s empty, then `arrive()` publishes Jane / jane@example.com. After README on, **first** assert name error outline and Continue null; then `arrive()` + `pumpAndSettle`; controllers match, stock outline, Continue enabled. | The first assert is the instrument: required still fires when Settings is still the empty default. |
| T5 | `Commit all gates Continue until a git identity is filled` | Existing-folder Source (`/srv/app`), Remote None, Details. Continue enabled (no commit-all). Turn commit-all on (`ensureVisible` on tooltip starting `Commit all existing contents`). Continue disabled, both identity fields error outline. Fill identity. Continue enabled, stock outline. | Continue is **null** and both fields error after commit-all on with empty identity. `_needsIdentity` is `_addReadme \|\| _commitAll`; T1 only covers README. |
| T6 | `Review lists the git identity` | New folder, fill name `new-proj` and identity, go to Review. `find.text('Git identity')` and `find.text('Ada Lovelace · ada@example.com')`. | — |
| T7 | `typed identity is not overwritten when Settings loads` | `_LateSettings` empty. Details, type `_testAuthorName` / `_testAuthorEmail` (that sets `*Edited`). `arrive(committerName: 'Jane Developer', committerEmail: 'jane@example.com')`. Controllers still hold Ada / ada@example.com, not Jane. | — |

### `test/create_repo_sheet_test.dart` — new tests (Phase 3)

| # | Exact name | Asserts | Negative observation |
|---|---|---|---|
| T8 | `a filled git identity is written into the new repo even without a README` | Fill identity, README off, create. After init: `git config --local user.name Ada Lovelace` then `git config --local user.email ada@example.com`. Sheet pops. No `git commit`, no `git remote add`. Embed T9's spy in this test (or a dedicated sibling with the same submit). | `_GuardSettings.setPreferences` is invoked once **before** create (`preferenceWrites == 1`), then reset to 0; after create it is still 0. A spy that never increments makes the 0-assert meaningless. |
| T9 | Settings-write ban (same test as T8, or dedicated) | See Phase 3d. `preferenceWrites` seen to become 1, then 0 across create. | Same as T8. |
| T10 | `existing repo with history does not rewrite identity unless commit-all is on` | Existing folder `/srv/app` that classifies as its own repo root, identity filled, commit-all **off**, GitHub or None. After create, `exec.calls` joined must **not** contain `git config --local user.name` or `git config --local user.email`. Init is also absent (already a repo). | If this assertion is missing, alreadyRepo would silently pick up Frozen rule 3's exception. |

### `test/create_repo_sheet_test.dart` — existing submit tests to update (Phase 3b)

Do not rename. Fill identity, `_queueIdentityConfig` after init, expect Frozen config + commit argv **and** the existing origin/push argv.

| Exact name | Extra pin after identity commit |
|---|---|
| `the README option commits before the GitHub publish; we push with -u` | README upload `# new-proj\n`; `git remote add origin https://github.com/me/new-proj.git`; gh credential-helper `push -u origin main` |
| `GitLab mode with a README wires origin and pushes the initial commit` | `glab repo create … --skipGitInit`; `git remote add origin https://gitlab.com/me/new-proj.git`; glab credential-helper `push -u origin main` |
| `partial forge create (non-zero exit) still wires origin when the project exists and is discoverable` | origin add + push still run after failed `gh repo create` |
| `existing folder + commit-all + custom URL: contents committed, origin wired, and HEAD pushed with -u` | `git add --all`; Frozen commit; `git remote add origin <url>`; `git push -u origin HEAD` |

Submit tests that do **not** fill identity must **not** expect `git config --local user.name`. Leave their names and origin assertions unchanged.

### `test/help_book_json_test.dart` (Phase 1d)

No new test function. Add `'git identity'` to `required['clone_create']`. The existing `'required facts appear in their topics'` test then fails until the Help Book Details bullet contains that substring — that failure is the instrument.

### `test/create_repo_wire_live_test.dart` (Phase 3e)

No new test function. Change `initLocalRepo` only: after uploading README, Frozen config + commit argv with `Magic Git Live Test` / `livetest@magic-git.invalid`. Do not run the file (`live-forge`).

### Commands

```sh
flutter test test/create_repo_sheet_test.dart test/help_book_json_test.dart
flutter test test/create_repo_sheet_test.dart --plain-name "git identity"
flutter test test/create_repo_sheet_test.dart --plain-name "Add a README gates Continue"
flutter test test/create_repo_sheet_test.dart --plain-name "Commit all gates Continue"
flutter test test/create_repo_sheet_test.dart --plain-name "Settings-prefilled identity"
flutter test test/create_repo_sheet_test.dart --plain-name "Settings loads after open"
flutter test test/create_repo_sheet_test.dart --plain-name "Review lists the git identity"
flutter test test/create_repo_sheet_test.dart --plain-name "typed identity is not overwritten"
flutter test test/create_repo_sheet_test.dart --plain-name "does not rewrite identity"
```

Do not add `flutter test --run-skipped -t live-forge`.

## Prerequisites

* Commands: `flutter analyze`, `flutter test`, `dart format`.
* Do not commit unless asked; if asked, one commit per phase,
  `git commit --no-edit`.
* `lib/core/providers/app_providers.dart` is classified as **binary** by
  search tools. This plan does not edit it. Identity settings live in
  `lib/core/settings/app_settings.dart`.
* **Halt rule:** if origin wiring (`_ensureForgeOrigin`,
  `createRepoInExisting` API-only) has been removed or now passes
  `--source`/`--remote`/`--push`, stop — this plan assumes that pipeline
  still owns remotes.

## Phase 0 — Confirm facts (no commit)

Read, do not edit:

* `lib/features/workspace/create_repo_sheet.dart`
  * `_submit` order: init → optional commit → forge/custom origin →
    verify → register.
  * `_writeReadmeAndCommit` / `_commitAllContents` current argv (on
    `origin/master`: `git commit -m Initial commit`, no `-c`, no
    `--no-gpg-sign`).
  * `_ensureForgeOrigin` / `_pushInitial` / `_verifyOrigin`.
  * Details step body: README toggle currently sits immediately after
    the branch field.
* `lib/core/git/git_service.dart` — `_idArgs`, `commit` (`--no-gpg-sign`).
* `lib/core/settings/app_settings.dart` — `committerName` /
  `committerEmail` default `''`; `appSettingsProvider`;
  `setPreferences`.
* `lib/features/settings/settings_sheet.dart` — Committer identity copy
  ("Leave blank to use the remote repository's own git config").
* `test/create_repo_sheet_test.dart` — `_pumpConnected`, README tests
  that tap the tooltip starting `Add a README`, commit-all tooltip
  starting `Commit all existing contents`.
* `test/create_repo_wire_live_test.dart` — `initLocalRepo`.
* `macos/Runner/help_book.json` — `clone_create` Create items.

**Halt if:** the sheet already writes local `user.name` / `user.email`
and authors the initial commit with `-c` and `--no-gpg-sign`. The work
is done; only the Settings-write ban and tests may remain. **Halt if:**
origin is wired by `gh`/`glab --source/--remote/--push` again — that is
a regression outside this plan.

On the 2026-09-03 working tree, Phase 0's "already done" branch is the
actual state. Treat the remaining phases as the spec that tree must
match, not as a second implementation.

---

## Phase 1 — Details UI, gating, prefill, Help (commit)

**Files**

* **Edit** `lib/features/workspace/create_repo_sheet.dart`
* **Edit** `lib/features/common/field_styles.dart` (error outline
  decorations; see deviation 2026-09-03)
* **Edit** `macos/Runner/help_book.json`
* **Edit** `test/help_book_json_test.dart`
* **Edit** `test/create_repo_sheet_test.dart` (gating + prefill tests
  only; submit argv tests wait for Phase 2–3)

### 1a. Controllers, prefill, dispose, validation

Add `_authorName` / `_authorEmail`, `_authorNameEdited` /
`_authorEmailEdited`, `_applyIdentityPrefill`, the `appSettingsProvider`
listen in `build`, dispose, `_needsIdentity`, `_authorNameText`,
`_authorEmailText`, `_identityValid`, `_looksLikeEmail` exactly as
Frozen. Extend `_detailsValid`. Update the Details step `intro` to
mention git identity. Update the class dartdoc to mention local
identity, `-c`, `--no-gpg-sign`, and that identity is required for an
initial commit.

Do **not** yet change `_submit` or the commit helpers (Phase 2).
Continue on Details with README on and empty identity must already be
null after this phase — even though submit would still fail the commit
until Phase 2.

### 1b. Fields

Insert the Git identity caption + two `MacosTextField`s + `WizardHint`
**after** the README / commit-all block and **before** the
save/fsmonitor block. Placeholders, decorations, and `onChanged` as
Frozen. Hint must not mention writing Settings.

### 1c. Review

Add the `Git identity` review row as Frozen.

### 1d. Help Book

Details bullet and `help_book_json_test.dart` required fact as Frozen.

### 1e. Tests for this phase

In `test/create_repo_sheet_test.dart`:

1. `'Add a README gates Continue until a git identity is filled'`
   * Source → Remote (None) → Details, enter valid repo name.
   * Continue enabled (identity optional).
   * Turn README on. Continue **disabled**. Both identity fields use
     `kAppTextFieldErrorDecoration` (empty → red).
   * Fill name only. Still disabled. Name uses the stock decoration;
     email stays red.
   * Email `not-an-email`. Still disabled. (This is the negative
     observation for the email predicate.)
   * Email `ada@example.com`. Continue enabled.
   * Tap README via `ensureVisible` on the tooltip whose message starts
     with `Add a README` — the toggle can sit under the fold.
2. `'git identity prefills from Settings'`
   * Override `appSettingsProvider` with a notifier whose `build()`
     returns `AppSettings(committerName: 'Jane Developer',
     committerEmail: 'jane@example.com')` and does **not** call
     `super.build()` / SharedPreferences.
   * Source → Remote → Details.
   * Assert the name/email controllers hold those strings
     (`tester.widget<MacosTextField>(...).controller?.text`).
     Do not `find.text` — `MacosTextField` does not always put the
     value in a `Text` widget.
3. `'Settings-prefilled identity is not marked required when README is on'`
   * Same immediate Settings override as (2). Details, valid repo name,
     tap README.
   * Continue **enabled**. Both identity fields use
     `kAppTextFieldDecoration`, not the error outline.
4. `'identity required outline clears when Settings loads after open'`
   * Override with a notifier that `build()`s empty `AppSettings`, then
     later `state =` a stored name+email (the real disk-load sequence).
   * Details, valid repo name, tap README.
   * **First** assert the required state: name uses
     `kAppTextFieldErrorDecoration`, Continue disabled. That is the
     negative observation — required still fires when identity is
     actually missing.
   * Publish the stored identity, `pumpAndSettle`.
   * Controllers hold the stored values, stock outline, Continue
     enabled.
5. `'Commit all gates Continue until a git identity is filled'`
   * Existing folder `/srv/app`, Remote None, Details.
   * Continue enabled (commit-all off).
   * `ensureVisible` + tap tooltip starting `Commit all existing contents`.
   * Continue **disabled**, both identity fields error outline.
   * `_fillIdentity`. Continue enabled, stock outline.
6. `'Review lists the git identity'`
   * New folder, name `new-proj`, `_fillIdentity`, Review.
   * `find.text('Git identity')` and
     `find.text('Ada Lovelace · ada@example.com')`.
7. `'typed identity is not overwritten when Settings loads'`
   * `_LateSettings` empty. Details, `_fillIdentity` (sets `*Edited`).
   * `arrive(committerName: 'Jane Developer', committerEmail: 'jane@example.com')`.
   * Controllers still Ada / ada@example.com.

### Verification (Phase 1)

```sh
dart format --output=none --set-exit-if-changed \
  lib/features/common/field_styles.dart \
  lib/features/workspace/create_repo_sheet.dart \
  test/create_repo_sheet_test.dart \
  test/help_book_json_test.dart
flutter analyze \
  lib/features/common/field_styles.dart \
  lib/features/workspace/create_repo_sheet.dart \
  test/create_repo_sheet_test.dart \
  test/help_book_json_test.dart
flutter test test/create_repo_sheet_test.dart test/help_book_json_test.dart
```

Expect the existing README **submit** tests to still pass in this phase
(they fill no identity, README tap still works because identity sits
below the toggle, and submit still does the old commit argv until Phase
2). If a README submit test starts failing because Continue is disabled,
that test has README on without identity — stop and add `_fillIdentity`
only in Phase 3, or fill identity in those tests here if they cannot
reach Review otherwise.

**Halt if:** Continue stays enabled with README on and empty identity.
**Halt if:** analyzer reports `Undefined name 'appSettingsProvider'` —
the import must be `app_settings.dart`, not only `app_providers.dart`.

---

## Phase 2 — Local git config + authored commit (commit)

**Files**

* **Edit** `lib/features/workspace/create_repo_sheet.dart` only

### 2a. `_writeIdentityConfig`

Add the helper as Frozen. `ExecLane.exclusive`, `retries: 0`,
`log.logResult` each argv. On first failure: append the Frozen warning
prefix, `return` (do not attempt the second config key). Never throw;
never abort `_submit`.

Call site: immediately after the init block (or the skipped-init
alreadyRepo path), before Step 2 (optional commit):

```
if (_identityValid && (!alreadyRepo || _commitAll)) {
  await _writeIdentityConfig(executor, log, dest, warnings);
  if (!mounted) return;
}
```

`warnings` is already declared just before init.

### 2b. Commit argv

`_writeReadmeAndCommit` and `_commitAllContents`: replace
`['git', 'commit', '-m', 'Initial commit']` with the Frozen commit
argv (`..._identityArgs`, `--no-gpg-sign`). Keep add argv unchanged.

Rewrite the commit-failure warnings so they no longer mention
`user.name / user.email configured on the target`.

### 2c. Confirm origin/push unchanged

Do not edit `_ensureForgeOrigin`, `_pushInitial`, `_verifyOrigin`, or
the `switch (_remote)` body. `hasCommit` still gates push. A successful
Phase-2 commit is what makes `hasCommit == true` on the README path.

### Verification (Phase 2)

```sh
dart format --output=none --set-exit-if-changed \
  lib/features/workspace/create_repo_sheet.dart
flutter analyze lib/features/workspace/create_repo_sheet.dart
```

Existing README widget tests will now **fail** (they queue no
`git config` results and expect `git commit -m Initial commit`). That
failure is required: it is the instrument that Phase 3 updates. If they
still pass, Phase 2 did not change commit argv — stop.

`rg -n "git commit -m Initial commit" lib/features/workspace/create_repo_sheet.dart`
must print nothing.
`rg -n setPreferences lib/features/workspace/create_repo_sheet.dart`
must print nothing.

---

## Phase 3 — Tests (commit)

**Files**

* **Edit** `test/create_repo_sheet_test.dart`
* **Edit** `test/create_repo_wire_live_test.dart` (`initLocalRepo` only)

### 3a. Helpers

```dart
const _testAuthorName = 'Ada Lovelace';
const _testAuthorEmail = 'ada@example.com';

Finder _authorNameField() => find.byWidgetPredicate(
  (w) => w is MacosTextField && w.placeholder == 'Your name',
);
Finder _authorEmailField() => find.byWidgetPredicate(
  (w) => w is MacosTextField && w.placeholder == 'you@example.com',
);

Future<void> _fillIdentity(WidgetTester tester) async {
  await tester.ensureVisible(_authorNameField());
  await tester.pumpAndSettle();
  await tester.enterText(_authorNameField(), _testAuthorName);
  await tester.enterText(_authorEmailField(), _testAuthorEmail);
  await tester.pumpAndSettle();
}

Finder _readmeToggle() => find.byWidgetPredicate(
  (w) => w is MacosTooltip && w.message.startsWith('Add a README'),
);

Future<void> _tapReadme(WidgetTester tester) async {
  await tester.ensureVisible(_readmeToggle());
  await tester.pumpAndSettle();
  await tester.tap(_readmeToggle());
  await tester.pumpAndSettle();
}

void _queueIdentityConfig(_FakeExecutor exec) {
  exec.results.add(_ok('')); // git config --local user.name
  exec.results.add(_ok('')); // git config --local user.email
}

String get _identityCommit =>
    'git -c user.name=$_testAuthorName -c user.email=$_testAuthorEmail '
    'commit --no-gpg-sign -m Initial commit';
```

`_queueIdentityConfig` is library-private (leading underscore) so it
does not take a private type in a public API.

Commit-all toggle: `ensureVisible` on the tooltip starting
`Commit all existing contents` before `tap`.

### 3b. Update every submit path that commits

After `git init` result, `_queueIdentityConfig(exec)` whenever the test
filled identity. Expect `containsAllInOrder` to include, after init:

```
git config --local user.name Ada Lovelace
git config --local user.email ada@example.com
```

and the Frozen commit string instead of `git commit -m Initial commit`.

Tests that must fill identity and queue config (README or commit-all):

* `the README option commits before the GitHub publish; we push with -u`
* `GitLab mode with a README wires origin and pushes the initial commit`
* `partial forge create (non-zero exit) still wires origin when the project exists and is discoverable`
* `existing folder + commit-all + custom URL: contents committed, origin wired, and HEAD pushed with -u`

Those tests must still assert origin add + `git push -u` (GitHub/GitLab
with forge credential helper; custom URL without). That is the
end-to-end pin: identity → commit → origin → push.

Tests that do **not** fill identity must **not** expect `git config`
(plain create, GitHub without README, custom URL without commit, etc.).

### 3c. Identity written without README

`'a filled git identity is written into the new repo even without a README'`

Fill identity, do not turn README on, create. Expect init then the two
`git config --local` calls. Sheet pops. No commit, no origin.

### 3d. Settings-write ban (spy must be seen to fail)

```dart
class _GuardSettings extends AppSettingsNotifier {
  int preferenceWrites = 0;
  @override
  AppSettings build() => const AppSettings();
  @override
  Future<void> setPreferences({
    String? committerName,
    String? committerEmail,
    PullMode? defaultPullMode,
    bool? pushFollowTags,
    int? autoFetchMinutes,
  }) async {
    preferenceWrites++;
  }
}
```

In the test in 3c (or a dedicated test):

1. `await settings.setPreferences(committerName: 'should-count',
   committerEmail: 'x@y');`
2. `expect(settings.preferenceWrites, 1);` — the spy fires.
3. `settings.preferenceWrites = 0;`
4. Pump the sheet with
   `appSettingsProvider.overrideWith(() => settings)`.
5. Create with identity filled.
6. `expect(settings.preferenceWrites, 0)`.

If step 2 is omitted, a 0-write assert is indistinguishable from a spy
that never hooked `setPreferences`.

Extend `_pumpConnected` with `List<Override> extraOverrides = const []`
if that is the cleanest way to inject the spy. Import
`package:riverpod/misc.dart` show `Override`, after the
`remote_magic_git/...` imports (directive order).

### 3e. Live-test argv parity

In `test/create_repo_wire_live_test.dart` `initLocalRepo`, after
uploading README, use the same config + commit argv as the sheet
(`user.name=Magic Git Live Test`,
`user.email=livetest@magic-git.invalid`). Do not run the file.

`dart format` may re-indent the rest of that file. That is allowed;
do not change the GitLab/GitHub live scenarios otherwise.

### 3f. Existing repo does not rewrite identity

`'existing repo with history does not rewrite identity unless commit-all is on'`

Existing folder `/srv/app`, classify as repo root (`git rev-parse
--show-toplevel` → `/srv/app`), identity filled, commit-all off, GitHub
or None (None is enough). Create. Joined argv must not contain
`git config --local user.name` or `git config --local user.email`, and
must not contain `git init` (already a repository).

### Verification (Phase 3)

Negative observation already required: Phase 2 left README tests red.
After 3b they must go green, and they must contain the new argv.

```sh
dart format --output=none --set-exit-if-changed \
  lib/features/workspace/create_repo_sheet.dart \
  test/create_repo_sheet_test.dart \
  test/create_repo_wire_live_test.dart \
  test/help_book_json_test.dart
flutter analyze \
  lib/features/workspace/create_repo_sheet.dart \
  test/create_repo_sheet_test.dart \
  test/create_repo_wire_live_test.dart \
  test/help_book_json_test.dart
flutter test test/create_repo_sheet_test.dart test/help_book_json_test.dart
```

Optional extra (not live-forge):

```sh
rg -n setPreferences lib/features/workspace/create_repo_sheet.dart
# expected: no matches
```

**Halt if:** README GitHub test does not include both
`git remote add origin https://github.com/me/new-proj.git` and
`push -u origin main` after the identity commit.
**Halt if:** the Settings spy's `preferenceWrites` is not 0, or was
never shown to become 1.
**Halt if:** T5 (commit-all gate), T6 (Review row), T7 (sticky typed
identity), or T10 (alreadyRepo does not `git config`) are missing.

---

## Phase 4 — Docs (commit)

**Files**

* **Already created this turn:**
  `docs/0021-MADR-create-repo-identity-and-origin.md`
  `docs/0021-PLAN-create-repo-identity-and-origin.md`
* **Edit** `docs/README.md` — add row `0021` to the index.

After the maintainer accepts:

* MADR `status: accepted`, `verified:` today's date. **Done.**
* PLAN `status: executed`, `executed:` / `verified:` today's date,
  and an execution record naming the commits. **Done** (`69e784d`
  engineering; this docs commit).

`docs/ARCHITECTURE_PLAN.md` does not need a new section; create-repo
origin ownership is already described there. Only add a sentence if the
maintainer wants identity called out in §0.1 / the create-repo paragraph.

### Verification (Phase 4)

`docs/README.md` table contains links to both 0021 files. Frontmatter
`associated-madr` on this PLAN equals the MADR filename.

---

## Rollout and Rollback

**Rollout.** macOS desktop only. No migration, no schema, no Settings
key changes. Shipping is: commit Phases 1–4, then the maintainer's
usual `./build_macos.sh --unsigned --install` when they choose.

**Rollback.** Revert the four phase commits. Behaviour returns to: raw
`git commit -m Initial commit`, no local identity, README failing on
hosts without global git config, origin pipeline unchanged.

**Maintainer-only after execute**

* Cold Create on This Mac with Settings identity **empty**, GitHub or
  GitLab remote, README on, name+email filled in Details: forge project
  exists, `git config --local --get user.name` inside the new repo
  prints the wizard name, `git remote -v` shows origin, README is on
  `origin/<branch>`.
* Repeat with Settings identity **empty** and README **off**: repo
  inits, no `git config` if fields left blank, no Settings writes.
* Repeat with Settings identity **set**: fields prefill **before**
  README/commit-all is turned on; they are not outlined red; Continue
  stays enabled; Create does not change Settings even if the user
  edits the fields.
* Do not run `flutter test --run-skipped -t live-forge
  test/create_repo_wire_live_test.dart` unless explicitly asked.

## Execution record

| Date | What |
|---|---|
| 2026-09-03 | Uncommitted working-tree implementation of Phases 1–3 exists, including the Settings-write ban after the maintainer forbade write-back. This PLAN/MADR written for review. `analysis_options.yaml` and `pubspec.lock` are dirty from tooling and are **not** part of the phase diffs. |
| 2026-09-03 | **Deviation (requested):** outline identity fields in red when they are required and invalid. Added `kAppTextFieldErrorDecoration` / `kAppTextFieldErrorFocusedDecoration` in `lib/features/common/field_styles.dart`. Per-field: name red iff `_needsIdentity && name empty`; email red iff `_needsIdentity && !_looksLikeEmail`. Optional identity never uses the error outline. Gating test asserts the decoration swap. Frozen Details layout step 5 is this outline; `field_styles.dart` added to Phase 1's file list. |
| 2026-09-03 | **Deviation (requested):** required/red must not fire when identity is prepopulated from Settings. `AppSettingsNotifier` emits empty defaults first, then disk; initState alone saw the empty snapshot. `_applyIdentityPrefill` copies non-empty Settings name/email into un-edited fields, from initState and from a `ref.listen(appSettingsProvider)` in build. User edits are sticky (`_authorNameEdited` / `_authorEmailEdited`). Tests: prefilled Settings + README keeps stock outline and Continue enabled; empty-then-arrive Settings is first shown red (required), then clears. |
| 2026-09-03 | Maintainer accepted the MADR and approved this PLAN. T5 (`Commit all gates Continue…`), T6 (`Review lists the git identity`), T7 (`typed identity is not overwritten…`), and T10 (`existing repo with history does not rewrite identity…`) written. `flutter analyze` clean on touched Dart; `flutter test test/create_repo_sheet_test.dart test/help_book_json_test.dart` green. Engineering commit `69e784d`. Phases 1–3 not split (pre-approval mixed tree). `analysis_options.yaml` / `pubspec.lock` left uncommitted. |

The two 2026-09-03 deviations are now in Frozen UI / acceptance
criteria 1–2 / Phase 1e tests 3–4. The execution-record rows stay as
the history of how the spec got there.
