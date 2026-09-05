---
status: "accepted"
date: 2026-09-05
decision-makers: [Maintainer]
consulted: []
informed: [Magic Git contributors]
verified: 2026-09-05
---

# Let the create-repository flow choose the forge namespace, not just the default one

## Context and Problem Statement

Creating a repository from an existing folder (Connections manager →
`CreateRepositorySheet`) can only ever create it under **the authenticated
user's default namespace** — `<gitlab-host>/<user>` on a self-hosted GitLab
instance. A user who also has create rights in a nested group (verified below:
this account has 24 of them) has no way to say so, and must create the project
in the web UI and then wire the remote by hand.

Both supported forges accept a namespace at creation time. The app does not
offer one.

## What the code does today

| fact | where |
|---|---|
| One `_name` text field; its value is passed straight through as `name:` | `create_repo_sheet.dart:109`, `:434`, `:661`, `:713` |
| Both services pass `name` as the CLI's **positional** argument | `glab_service.dart:252-268`, `gh_service.dart:163-180` |
| In `existingFolder` mode the local directory is the **picked folder**; `name` is used *only* for the forge | `create_repo_sheet.dart:437-445` |
| In `newFolder` mode `name` is **also** the directory name (`joinPath(parentDir, name)`) | `create_repo_sheet.dart:445` |
| The **only** thing rejecting a namespace is the form validator | `create_repo_sheet.dart:254` → `HostFsService.isValidRepoDirName` |
| …which returns false for any name containing `/` | `core/git/host_fs_service.dart:198-206` |

**The plumbing below the form already anticipates namespaces.** GitLab's origin
resolver documents and implements exactly this:

```dart
///  2. API lookup: bare names resolve under the authenticated user's
///     namespace (`glab api user`); group paths (`a/b/c`) are used
if (name.contains('/')) {
  full = name;          // group path used as-is
} else {
  full = '$username/$name';
}
```

and GitHub's resolves `<name>` against the authenticated account the same way
`create` did. So the gap is **the form**, not the transport: a validator written
for directory names is being used to validate a forge project path.

## Runtime reality, verified 2026-09-05

Checked on this Mac **and** on the host that actually runs the commands, because
the two have disagreed before:

| | this Mac | the remote host |
|---|---|---|
| `glab` | 1.116.0 | **1.116.0** |
| `gh` | 2.99.0 | 2.96.0 |

* **`glab repo create` accepts a namespace two ways.** Its own help:
  `glab repo create [path]`, with examples `glab repo create --group glab-cli`
  and `glab repo create <host>/path/to/repository`, and the flag
  `-g, --group  Namespace or group for the new project. Defaults to the current
  user's namespace.`
* **`gh repo create` takes `[OWNER/]REPO`** — *"If the `OWNER/` portion of the
  `OWNER/REPO` name argument is omitted, it [defaults to the authenticated
  user]."*
* **The forge can tell us where the user may create.** Read-only against the
  live instance: `glab api "groups?min_access_level=30&per_page=100"` returned
  **24 groups** for this account — including the nested group that prompted this
  request. One call, no pagination needed at this size.
* **`/namespaces` is the wrong endpoint** and would be an easy mistake: it
  returned 100 entries including *other users'* personal namespaces — things the
  user can see but cannot create in. `groups?min_access_level=30`, plus the
  user's own namespace from `glab api user`, is the correct pair.

No project was created during this assessment. `AGENTS.md` forbids running the
mutating `live-forge` tests unprompted, and that includes creating a real
project to check a flag.

## Decision Drivers

* **The permission already exists; only the UI withholds it.** This is a missing
  input, not a new capability.
* **The forge knows the answer.** A list the user can pick from beats a path
  they must remember, and it is one round trip.
* **Free text must still work.** A group the API does not return (a fresh grant,
  a paginated tail, an unreachable API) must not become an unusable form.
* **The two forges spell it differently** — GitLab has both a path form and a
  `--group` flag; GitHub has only `OWNER/REPO`. Whatever is chosen must not
  fork the call sites.
* **`newFolder` mode must keep rejecting slashes**, because there the name is
  also a directory name.

## Considered Options

* **A — Relax the validator in `existingFolder` mode** and let the user type
  `team/subgroup/name` into the existing field.
* **B — A separate free-text "Namespace / group" field.**
* **C — A namespace picker populated from the forge, editable as free text.**
* **D — A full-URL field the app parses.**

## Decision Outcome

Chosen option: **"C — a namespace picker populated from the forge, editable as
free text"**, because the forge can enumerate exactly the namespaces the user
may create in (verified: 24, including the one this request names), and because
falling back to free text costs nothing and keeps the form usable when the API
does not answer.

**The value passed to the CLI is the full path**, not a `--group` flag. This is
the load-bearing detail:

> `glab repo create <name> --group team/subgroup` would create
> `team/subgroup/<name>`, but the app would then call
> `resolveOriginUrl(name: '<name>')`, which — seeing no `/` — looks the project
> up as `<user>/<name>` and fails to find it. The wiring would report "origin
> could not be determined" for a project that was created correctly.
>
> Passing `team/subgroup/<name>` as the positional argument is the form
> both CLIs already accept **and** the form the existing resolver already
> handles. One code path, no fork between forges, and no change below the sheet.

**A** is rejected: it overloads one field with two meanings and leaves the user
to know the path by heart, and it relaxes a validator whose other caller is a
directory name. **B** is C without the part that makes it usable. **D** invites
a parser for something the forge will simply list.

`newFolder` mode keeps the current validation — there the name *is* a directory
name.

### Consequences

* Good, because a permission the user already holds becomes reachable, and the
  common case (their own namespace) stays a default they never touch.
* Good, because nothing below the sheet changes: the resolver, the origin
  wiring and the push already handle `a/b/c`.
* Good, because the picker is one read-only API call whose failure degrades to
  the field the user would otherwise have had.
* Bad, because it adds a forge round trip to a sheet that currently opens with
  none. It must be lazy and non-blocking — the sheet has to remain usable while
  the list loads, and must not become another provider that shows a spinner over
  a form (0030 Phase 1's finding, in a new place).
* Bad, because a namespace the user lacks rights to still fails at `create`
  time, with the CLI's own error. The sheet already surfaces create failures;
  this makes a new class of them reachable.
* Neutral on GitHub: `OWNER/REPO` is the same shape, but the org list comes from
  a different endpoint and personal-vs-org creation has different token scopes.
  The picker for GitHub is a smaller win and may reasonably ship second.

### Confirmation

Offline: the sheet accepts a namespace, composes `namespace/name`, and passes it
as the positional argument for both forges; `newFolder` mode still rejects a
slash. Each assertion landable red-then-green against the existing sheet tests.

Live: creating a real project under a non-default namespace **mutates a real
forge**, so it belongs in `test/create_repo_wire_live_test.dart` behind the
`live-forge` tag and must not run unprompted. Until that is run once with the
maintainer's agreement, the claim "creates under the chosen group" is
**unverified** — the flag's existence is documented, not exercised.

One thing is deliberately not assumed: that `glab repo create` accepts a
**nested subgroup** path (`team/subgroup/x`, two levels) as readily as a
top-level group. GitLab identifies groups by `full_path`, and the help's example
is single-level. That is the first thing the live check must establish.

## More Information

* `lib/features/workspace/create_repo_sheet.dart` — the sheet, its validator at `:254`, and both create call sites.
* `lib/core/gitlab/glab_service.dart:262` / `lib/core/github/gh_service.dart:174` — the create calls; `:306` / `:191` the resolvers that already handle group paths.
* `lib/core/git/host_fs_service.dart:198` — `isValidRepoDirName`, the validator being asked to do a second job.
* `test/create_repo_wire_live_test.dart` — the mutating live suite where the end-to-end check belongs.
* `AGENTS.md` — the `live-forge` rule, and the record that `glab -h` means `--help`, not `--host`.
