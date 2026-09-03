---
status: accepted
date: 2026-09-03
verified: 2026-09-03
decision-makers: [Maintainer]
consulted: []
informed: [Magic Git contributors]
---

# Collect a per-repo git identity on Create, write it locally, never into Settings

## Context and Problem Statement

Creating a repository from Magic Git can leave a project that exists on
GitHub/GitLab but cannot receive its initial README: the new working tree
has no `user.name` / `user.email`, and the first `git commit` therefore
fails. With no commit, the subsequent `git push -u` is skipped. The
maintainer also reported no `origin` remote on the new repo, so even a
later manual commit could not be pushed without extra setup.

This record is **accepted** (maintainer, 2026-09-03). Execution is
[0021-PLAN-create-repo-identity-and-origin.md](0021-PLAN-create-repo-identity-and-origin.md).
Empty Settings identity must stay empty — writing the wizard's values
back into Settings is rejected.

### What is confirmed (2026-09-03, working tree)

**1. The create wizard already owns origin wiring.**
`CreateRepositorySheet._submit` (`lib/features/workspace/create_repo_sheet.dart`)
is init-first, then optional README/commit-all, then mode-specific origin:

* GitHub / GitLab: API-only `gh`/`glab repo create` (no `--source` /
  `--remote` / `--push`), then `_ensureForgeOrigin` →
  `git remote add origin <url>` from `resolveOriginUrl`, then
  `_pushInitial` when `hasCommit`.
* Custom URL: `git remote add origin <url>`, then push when `hasCommit`.
* None: no remote.

Post-create verification (`git remote get-url origin`) already runs for
every mode that promised a remote. Widget tests in
`test/create_repo_sheet_test.dart` pin that argv. Rebuilding origin
resolution is not the gap.

**2. The initial commit did not carry an identity.**
`_writeReadmeAndCommit` / `_commitAllContents` issued
`['git', 'commit', '-m', 'Initial commit']` with no `-c user.name` /
`-c user.email` and no `--no-gpg-sign`. The failure copy named the cause
explicitly: *"is user.name / user.email configured on the target?"*.
`GitService.commit` (`lib/core/git/git_service.dart`) already injects
those `-c` overrides from Settings and always passes `--no-gpg-sign`.
The create path used the raw executor and so did not.

**3. Nothing wrote local git config on the new repo.**
A host (or this Mac) with no global `user.name` / `user.email` therefore
fails the first commit. Even after a Settings-backed `-c` commit, a
terminal on that repo would still have no identity. The product need is
a self-contained repository, not a one-shot override.

**4. Settings identity is a separate, optional, app-wide override.**
`AppSettings.committerName` / `committerEmail` default to `''`. Empty
means "do not override; use the repository's own git config"
(`lib/core/settings/app_settings.dart`, Settings sheet copy). The
maintainer's rule for this work: **if Settings is empty, it is empty on
purpose**. Prefill-from-Settings is allowed. Write-back from the wizard
is not.

**5. Sequence, not origin lookup, is why the README never lands.**
Submit order is init → (optional commit) → forge create → origin → push.
Forge create does not depend on `hasCommit`. A failed README commit
still publishes an empty forge project, then `_ensureForgeOrigin` still
runs, then `_pushInitial` is skipped because `hasCommit` is false. The
visible wreckage is: forge project exists, local repo exists, README is
uncommitted or absent, push never happened. A separate origin-resolution
failure can also leave `origin` unset; that path already has warnings and
tests. This decision does not replace it.

### What is assumed

* The maintainer's "no remotes" observation is either the skipped-push
  case (origin present, nothing to push) or a live `resolveOriginUrl`
  miss on that host. The widget-tested origin path is kept, not rewritten.
* Users who want an identity in Settings will keep setting it in Settings.
  Create is not a Settings editor.

## Decision Drivers

* The first commit on a new repo must succeed on a host with no global
  git identity.
* The new repo must be usable outside Magic Git (terminal, hooks, other
  tools) — local `user.name` / `user.email` in that repo.
* Empty Settings identity must remain empty. Create must not persist
  name/email into `appSettingsProvider`.
* Origin wiring already exists and is tested; do not rebuild it.
* Initial commits must match `GitService.commit` conventions (`-c`
  identity, `--no-gpg-sign`).
* Root-cause fix only: no retry-around-failed-commit, no dummy author.

## Considered Options

* Collect identity on Details; write `--local` git config; author the
  commit with `-c` + `--no-gpg-sign`; prefill from Settings; never write
  Settings
* Only inject `-c` on the initial commit; do not write git config
* Write the wizard's identity into Settings (and/or global git config)
* Probe the target's `git config --global` and block create if missing;
  no new fields
* Route the initial commit through `GitService.commit` instead of the
  sheet's executor

## Decision Outcome

Chosen option: "Collect identity on Details; write `--local` git config;
author the commit with `-c` + `--no-gpg-sign`; prefill from Settings;
never write Settings", because it makes the new repository self-contained,
makes the README commit succeed without a host-global identity, keeps
Settings as a separate optional override, and leaves the existing origin
pipeline in place so a successful commit is actually pushed.

Identity is **required** only when the wizard will create a commit
(README on a new folder, or commit-all on an existing folder). It is
optional otherwise, but if both fields are valid it is still written
into a brand-new repo (or an in-place init). An existing repo that
already has history is not rewritten unless commit-all is on.

Required is visible two ways, both driven by the field values (not by
whether Settings *has* an identity):

* Continue on Details (and Create on Review) stays disabled until name
  is non-empty and email looks like an address.
* Each *invalid* required field is outlined in red
  (`kAppTextFieldErrorDecoration`). A valid field is not.

Settings is a **read-only prefill**. `AppSettingsNotifier` emits empty
defaults first, then the disk snapshot; Create must copy non-empty
`committerName` / `committerEmail` into un-edited fields on first open
**and** when that snapshot arrives, so a stored identity is already in
the fields before README/commit-all marks them required. A
Settings-populated valid identity must not outline red or disable
Continue. Empty Settings stays empty — Create never writes Settings.
A value the user typed or cleared is sticky and is not overwritten when
Settings finishes loading.

### Amendments (2026-09-03, during review)

* Do not write wizard identity into Settings (maintainer). Empty there
  is intentional.
* Outline invalid required identity fields in red (maintainer).
* Do not fire required/red when the fields are prepopulated from
  Settings, including the async disk-load frame (maintainer).

### Consequences

* Good, because a host with no global git identity can still complete
  Create → README → origin → push.
* Good, because `git config --local` leaves the repo usable from a
  terminal on that host.
* Good, because `-c` on the commit still authors it if the config write
  failed (warning, repo kept — same keep-on-failure rule as origin).
* Good, because `--no-gpg-sign` matches every other Magic Git commit and
  avoids a GPG-agent failure on `commit.gpgsign=true`.
* Good, because Settings stays a read-only prefill here; an empty
  identity in Settings is not overwritten, and a stored identity is
  copied into the fields (including after the async disk load) so
  README/commit-all does not outline them as missing.
* Neutral, because origin resolution, forge CLI argv, and the default
  Remote = None are unchanged.
* Bad, because a user who never fills Settings and never fills the
  wizard, and who does not add a README, still gets a repo with no
  identity — the same as `git init` on that host. They must fill identity
  before the first commit, either here or later.
* Bad, because two sources of identity now exist (Settings `-c` for
  in-app commits, per-repo git config for the repo itself). They can
  diverge. That is accepted: Settings is an override, not a store of
  every repo's author.

### Confirmation

* Widget tests in `test/create_repo_sheet_test.dart` pin:
  * Details Continue is disabled when README (or commit-all) is on and
    name/email are missing or the email is not a plausible address.
  * While that gate is active, each invalid identity field uses the
    red error outline (`kAppTextFieldErrorDecoration`); a valid field
    and optional identity use the stock gray outline.
  * Fields prefill from `appSettingsProvider` when set. README on with
    that prefill keeps the stock outline and Continue enabled.
  * Settings arriving after open (empty defaults, then disk) first
    shows the required/red state, then fills the fields and clears it.
    That red frame is the instrument proving required still fires when
    identity is actually missing.
  * `git config --local user.name` / `user.email` run after init when
    identity is filled.
  * Initial commit argv includes `-c user.name=… -c user.email=…` and
    `--no-gpg-sign`.
  * GitHub/GitLab README paths still `git remote add origin` and
    `git push -u` after that commit.
  * `AppSettingsNotifier.setPreferences` is not called during create
    (spy that has been seen to increment, then asserted at 0).
* `test/create_repo_wire_live_test.dart` `initLocalRepo` uses the same
  config + commit argv as the sheet (live-forge still skipped unless
  explicitly asked).
* `rg` over `lib/features/workspace/create_repo_sheet.dart` finds no
  `setPreferences`.
* Help Book Create details line names git identity.

## Pros and Cons of the Options

### Collect identity on Details; write `--local` git config; author the commit with `-c` + `--no-gpg-sign`; prefill from Settings; never write Settings

* Good, because it fixes the commit failure at the source (no author)
  and leaves a durable identity in the repo.
* Good, because it does not turn Create into a Settings editor.
* Good, because origin/push keep their existing ownership; they simply
  run after a commit that now succeeds.
* Neutral, because identity is optional when no commit is requested.
* Bad, because the Details step is taller (scroll). Tests must
  `ensureVisible` before tapping README / commit-all.

### Only inject `-c` on the initial commit; do not write git config

* Good, because the README commit would succeed.
* Bad, because the repo still has no `user.name` / `user.email` for any
  later commit not made through Magic Git — the maintainer's "broken
  repo" complaint would remain.
* Bad, because it treats identity as a one-shot override, which is what
  Settings already is.

### Write the wizard's identity into Settings (and/or global git config)

* Good, because the next Create and all `GitService` commits would
  inherit it.
* Bad, because empty Settings is intentional. A one-off author on a new
  repo would leak into every later commit on every connection.
* Bad, because writing `--global` on an SSH host mutates the user's
  account-wide git config without asking.

### Probe the target's `git config --global` and block create if missing; no new fields

* Good, because no new UI.
* Bad, because it cannot create a repo on a host that has no identity,
  which is the reported environment.
* Bad, because it still would not write local config, so the new repo
  would not be self-contained.

### Route the initial commit through `GitService.commit` instead of the sheet's executor

* Good, because `-c` and `--no-gpg-sign` would come for free when
  Settings is filled.
* Bad, because `GitService` identity is Settings-only; empty Settings
  still fails the commit.
* Bad, because the sheet would still need to write local git config
  itself, and `GitService` is not constructed with a per-create identity.
* Neutral, because the sheet already speaks the executor directly for
  init / remote add / push; mixing one GitService call into that sequence
  is inconsistent without a larger refactor.

## More Information

* Implementation plan:
  [0021-PLAN-create-repo-identity-and-origin.md](0021-PLAN-create-repo-identity-and-origin.md)
* Related: Settings committer identity
  (`lib/features/settings/settings_sheet.dart` "Committer identity");
  `GitService._idArgs` / `commit`; create-repo origin ownership
  (`GhService.createRepoInExisting`, `GlabService.createRepoInExisting`,
  `_ensureForgeOrigin`).
* Related live suite (mutating, skipped by default):
  `test/create_repo_wire_live_test.dart`. Do not run unprompted
  (`AGENTS.md`).
* Maintainer directives (2026-09-03): do not write identities to
  Settings; outline required invalid fields in red; do not treat
  Settings-prepopulated fields as required.
