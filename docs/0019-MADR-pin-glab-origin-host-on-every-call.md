---
status: accepted
date: 2026-08-26
verified: 2026-08-26
decision-makers: [Maintainer]
consulted: []
informed: [Magic Git contributors]
---

# Pin every glab invocation to the repo origin host, instead of hoping cwd and ambient env pick the self-hosted instance

## Context and Problem Statement

On the `admdevops` SSH bastion, Magic Git's GitLab MR / Forge path fails with an
auth-shaped error (the maintainer's phrasing: *glab not authenticated for that
forge*) even though an interactive `glab auth status` on the same host reports
a working login. The architecture's load-bearing assumption is that `cd` into
the repo is enough: `glab` will inherit the right GitLab instance and token
from remotes + its credential store
([docs/ARCHITECTURE_PLAN.md](ARCHITECTURE_PLAN.md) §4.1 / §4.3). That
assumption is not wired through the call sites that actually list and mutate
MRs, and it collides with how this bastion (and glab 1.109) actually
authenticate.

This record is a findings MADR: what the live host and the code do today, why
those two pictures disagree, and the architectural choice that closes the
gap. No code is changed until a paired plan is approved.

### What was investigated (2026-08-26)

* Read-only pass over `GlabService`, `CommandFormatter`, forge detection,
  auth parsing, and the provider wiring in `app_providers.dart`.
* SSH exec onto `admdevops` (`HostName dpsaur4vadm002.lkq.lkqx.net`, user
  `adm_saxsmith`) as the same account Magic Git would use, including a
  dartssh2-like stripped environment (`env -i HOME USER PATH LANG` plus
  Magic Git's default env prelude).
* Magic Git itself was **not** attached to a live session during this
  investigation. Commands below are the argv + environment the app would
  send, not a captured `.app` trace.

Facts below are tagged **(host)** when observed on `admdevops`, **(code)**
when read from this tree. Assumptions are called out as such.

### Host facts (`admdevops`)

* **(host)** `glab` is 1.109.0 at `/home/adm_saxsmith/.local/bin/glab`. That
  is also where Magic Git's environment probe would resolve it (`$HOME/.local/bin`
  is first on the augmented PATH).
* **(host)** An interactive login has `GITLAB_HOST=gitlab.example.com` and
  `GITLAB_TOKEN` (plus `GITLAB_PERSONAL_ACCESS_TOKEN` and
  `GITLAB_USER_TOKEN`) in the environment. `glab auth status` then reports
  `Logged in to gitlab.example.com as saxsmith (GITLAB_TOKEN)` and a banner
  that the env var **takes precedence over tokens stored in config or
  keyring**.
* **(host)** `~/.config/glab-cli/config.yml` (symlink into
  `~/dotfiles/glab/…`) has:
  * global `host: gitlab.com` (glab's documented default when unset);
  * `hosts.gitlab.com.token` empty;
  * `hosts.gitlab.example.com.user: saxsmith` and a stored token.
* **(host)** Many work remotes are stored as `git@ssh-gitlab.example.com:…`
  or `git@gitlab.example.com:…`. Global `url.*.insteadof` rewrites both to
  `https://gitlab.example.com/`, so `git remote get-url origin` (what
  Magic Git calls) returns the HTTPS host even when `.git/config` still
  has the SSH alias.
* **(host)** Under a stripped env with **no** `GITLAB_*` vars:
  * `glab api user` talks to **gitlab.com**, returns HTTP 401, **exit 0**.
    glab #911 (advisory exit codes) is still live on 1.109 for this path.
  * `glab api user` with `GITLAB_HOST=gitlab.example.com` returns HTTP 200
    for user `saxsmith` against the self-hosted instance.
  * `glab auth status` prints a `gitlab.com` 401 block **and** a working
    `gitlab.example.com` block, then `X could not authenticate to one or
    more of the configured GitLab instances`. From `$HOME` the combined
    command exited 1; from a matching repo cwd it exited 0 and the
    context host was the self-hosted instance.
  * From a real GitLab repo cwd (`ansible`, `tf-okd-sbx`,
    `systems-workspace`, `terraform`), `glab mr list --output json` and
    `glab api projects/:id/merge_requests -i` succeeded against
    `gitlab.example.com` **without** `GITLAB_HOST`. Cwd auto-resolution
    *can* work when remotes match a configured host.
* **(host)** glab 1.109's own help for `glab api`: *If the current
  directory is a Git directory, this command uses the GitLab authenticated
  host in the current directory. Otherwise, `gitlab.com` is used. To
  override the GitLab hostname, use `--hostname`.* `glab mr list` has no
  `--hostname`; it has `-R/--repo`. `glab auth status` is now
  context-sensitive (git remote / `GITLAB_HOST` / config); `--all` and
  `--hostname` are explicit.

### Code facts (this tree)

* **(code)** `GlabService.hostEnv` (`lib/core/gitlab/glab_service.dart`
  ~407–408) exports `GITLAB_HOST` + legacy `GITLAB_URI` for any host other
  than `gitlab.com`. It is passed on **six** call sites: `_recordCredentialUsername`,
  `listRepos`, `createRepoInExisting`, `_gitProtocol`, and the two API
  lookups inside `resolveOriginUrl`. Those are create / clone / login
  follow-up. They are **not** the Forge tab.
* **(code)** The Forge tab's load-bearing methods do **not** pass
  `hostEnv` and do **not** pass `--hostname`:
  `api`, `graphql`, `projectDashboard`, `mergeRequests`,
  `mergeRequestDetail`, `createMergeRequest`, `listIssues`,
  `traceStream`, pipelines/jobs, and every MR mutation (`approve`,
  `merge`, `rebase`, `close`, …). They rely on cwd + glab's remote
  resolver. `_runJson` *can* take `extraEnv`; `api()` / `graphql()` do
  not expose it.
* **(code)** `CommandFormatter.gitlabTokenVars` is
  `GITLAB_TOKEN`, `GITLAB_ACCESS_TOKEN`, `OAUTH_TOKEN`. When the
  connection stored a GitLab token, every SSH command `unset`s those
  names (`_forgeTokenVarsToNeutralize` in `app_providers.dart` ~1119–1124).
  It does **not** unset `GITLAB_HOST`, `GITLAB_URI`,
  `GITLAB_PERSONAL_ACCESS_TOKEN`, or `GITLAB_USER_TOKEN` — all of which
  are present on this bastion's login environment.
* **(code)** `forgeProvider` classifies by hostname first
  (`classifyForgeHost`). `gitlab.example.com` matches the whole-label
  `gitlab` telltale and becomes `Forge.gitlab` without consulting auth.
  `ssh-gitlab.example.com` does **not** match (`gitlab` is only a
  substring of the `ssh-gitlab` label; see
  `test/forge_detection_test.dart` "telltale only as a substring"). The
  self-hosted fallback then requires `authStatusListsHost` to see that
  **exact** host token in `glab auth status`. Auth status lists
  `gitlab.example.com`, not `ssh-gitlab.example.com`. On this bastion
  `git remote get-url` hides the mismatch via `insteadOf`; a repo (or a
  git that does not apply `insteadOf` to `get-url`) whose origin host is
  the SSH alias classifies as `Forge.unknown` and the Forge tab renders
  `UnsupportedForgeNotice` ("neither CLI reports being authenticated to
  it" — `lib/features/forge/forge_panel.dart` ~88–90).
* **(code)** `parseGlabAuthStatus` reports the **first working host
  block**, not "authenticated to *this repo's* origin". A dashboard
  probe that sees a healthy `gitlab.example.com` block will show signed
  in even if the command that just failed talked to `gitlab.com`.
* **(code)** `projectDashboard` maps GraphQL `{"data":{"project":null}}`
  (HTTP 200, no `errors[]` — GitLab's deliberate hide) to
  `GlabException: GitLab reports no project at "$fullPath" — the path
  may be wrong, or glab may not be logged in with access to it`
  (`glab_service.dart` ~710–722). A GraphQL call that silently hit
  `gitlab.com` for a self-hosted path produces exactly that
  "not logged in" reading. `looksLikeAuthFailure` then matches
  `auth login` / `401` / `not logged in` and the Forge list shows the
  sign-in callout (`ForgeListError`).
* **(code)** Architecture §4.3 still names a **version guard** for glab
  2.0.0+ renaming env vars to `GLAB_*`. It is not implemented. The
  installed binary is already past the documented target (1.103 →
  1.109) and has grown `--hostname` on `glab api` and context-sensitive
  `auth status`.

### Why interactive `glab auth status` looks fine and Magic Git does not

Two different commands, two different contexts:

1. **Interactive SSH** sources the login environment. `GITLAB_TOKEN` +
   `GITLAB_HOST=gitlab.example.com` make `glab auth status` report a
   single healthy self-hosted login. The empty `gitlab.com` host is not
   the story the user sees.
2. **Magic Git** runs a non-interactive exec with its own prelude
   (`GIT_TERMINAL_PROMPT=0`, `GLAB_CHECK_UPDATE=false`, rewritten
   argv[0], optional `unset GITLAB_TOKEN…`). It does **not** pass
   `GITLAB_HOST` on MR/API calls. glab's default host in config is
   `gitlab.com` with no token. Any invocation that fails to bind the
   repo's remotes — not a git dir, GraphQL client without a base repo,
   `api` outside cwd resolution, inherited `GITLAB_HOST=gitlab.com`,
   SSH-alias origin that glab does not map — talks to gitlab.com,
   gets 401 or `project: null`, and the UI reports an auth failure
   against "the forge".

The dashboard probe can still parse a working `gitlab.example.com` block
out of a mixed `auth status` dump (`parseGlabAuthStatus` skips the
stale `gitlab.com` 401; covered by
`test/auth_status_test.dart` "a stale secondary host does not mask a
working login"). That is why the Authentication section can be green
while the MR pane is red.

Cwd auto-resolution **did** succeed on the four sampled GitLab repos
under a stripped env. That does not make the missing pin safe: it is
an accident of `insteadOf` + a matching `hosts:` entry, and it is not
what `api()` / `graphql()` / `mergeRequests()` declare. The first
command that does not resolve remotes the way `glab mr list` does
falls through to gitlab.com.

## Decision Drivers

* **Same host Magic Git classified must be the host glab talks to.**
  Classification from `git remote get-url` and the CLI's API client
  must not be allowed to diverge.
* **Interactive `glab auth status` is not the app's exec environment.**
  Login-shell `GITLAB_TOKEN` / `GITLAB_HOST` are not a contract dartssh2
  exec can rely on, and when they *are* inherited, neutralization is
  only half of the pair (token unset, host left alone).
* **Do not put tokens in argv or the export prelude.** Stdin login +
  the host's credential store stay the secret path
  ([ARCHITECTURE_PLAN.md](ARCHITECTURE_PLAN.md) §4.3). Host *names* are
  not secrets; they belong on the command.
* **Parse machine contracts, treat glab exit codes as advisory.** HTTP
  status (`-i`) already exists on `api`/`graphql`. Host pinning must
  not regress that.
* **Self-hosted is the common case on this app's real hosts**, not
  gitlab.com. A config default of `host: gitlab.com` with an empty
  token is a footgun the app has to neutralize, not a host-side
  workaround we push onto the user.
* **Forge asymmetry is OK.** `gh` infers Enterprise hosts from remotes
  more reliably; the GitLab CLI's default-host behaviour is the
  incident. Pin glab first. Do not wait on a lowest-common-denominator
  with `GhService`.
* **Root cause, not a symptom guard.** Do not special-case
  `gitlab.example.com`, skip the empty `gitlab.com` 401, or rewrite the
  GraphQL null-project error to something vaguer. Pin the host.

## Considered Options

* Pin the origin host on every `GlabService` call (`GITLAB_HOST` /
  `GITLAB_URI` for subcommands, `--hostname` for `glab api` / GraphQL)
* Keep cwd auto-resolution; only document that `glab` must have
  `host:` set to the self-hosted instance
* Inherit the remote login environment's `GITLAB_TOKEN` / `GITLAB_HOST`
  and stop neutralizing them
* Per-connection glab wrapper that rewrites argv[0] to
  `glab --hostname <host> …` at the executor

## Decision Outcome

Chosen option: "Pin the origin host on every `GlabService` call
(`GITLAB_HOST` / `GITLAB_URI` for subcommands, `--hostname` for
`glab api` / GraphQL)", because the Forge tab's methods currently have
no host selector at all, glab 1.109 documents `--hostname` as the
override when cwd is not a matching git dir (and even when it is, as
the way to stop a default `host: gitlab.com` from winning), and host
names are not secrets so they can ride env / argv without violating
the stdin-token rule.

The pin is derived from the same `forgeHostFromRemoteUrl(git remote
get-url origin)` the rest of the app already trusts for classification
and `loginWithToken`. `hostEnv('gitlab.com')` remains `null` so the
public SaaS case does not change. Self-hosted (the incident) always
exports the origin host.

Paired plan: [0019-PLAN-pin-glab-origin-host-on-every-call.md](0019-PLAN-pin-glab-origin-host-on-every-call.md).
Accepted 2026-08-26; execution follows that plan.

### Consequences

* Good, because every MR / pipeline / GraphQL call names the instance
  Magic Git already classified, instead of hoping glab's resolver and
  a `host: gitlab.com` default agree.
* Good, because `--hostname` on `glab api` is the flag the installed
  1.109 binary documents; `GITLAB_HOST` + `GITLAB_URI` remain the
  subcommand path (`glab mr list` has no `--hostname`).
* Good, because a dashboard / auth probe that uses the **origin** host
  (`glab auth status --hostname <origin>`) answers "are we
  authenticated to *this* forge?", which is the question the MR pane
  is asking. Today's "first working block" answer is a different
  question.
* Good, because inherited `GITLAB_HOST=gitlab.example.com` and a
  Magic Git pin of the same value cannot fight; a wrong inherited
  `GITLAB_HOST=gitlab.com` is overwritten by `extraEnv` (SSH merge:
  later export wins; local executor: `extraEnv` is spread last).
* Neutral, because cwd auto-resolution stays as a backstop for a
  caller that has no origin yet (clone/create already pass `hostEnv`).
* Neutral, because `GhService` is not in this decision. `GH_HOST` has
  the same "only on create/clone" shape; file it as a follow-on if a
  GitHub Enterprise host reproduces the same split.
* Bad, because a pin taken from `git remote get-url` (insteadOf-rewritten
  to `gitlab.example.com`) while glab's own remote parser still sees
  `ssh-gitlab.example.com` *and* treats `GITLAB_HOST` as "remotes must
  match this host" can, in principle, produce glab's "none of the git
  remotes … correspond to the GITLAB_HOST environment variable". On
  this bastion that combination was tested (`GITLAB_HOST=gitlab.example.com`
  inside `tf-okd-sbx`, stored remote `git@ssh-gitlab.example.com:…`) and
  `glab mr list` still succeeded — so the risk is real in the abstract
  and not observed here. Confirmation must include an SSH-alias repo
  without `insteadOf`.
* Bad, because loginWithToken still does not pass glab 1.109's
  `--ssh-hostname`. Pinning the HTTPS host does not by itself teach
  glab that `ssh-gitlab.example.com` is the same instance. That is a
  follow-on in the same work, not a reason to keep the Forge tab
  unpinned.
* Bad, because this does not remove the empty `gitlab.com` host from
  the user's config. Auth-status dumps will still contain a 401 block
  until that entry is gone or has a token. The parser already ignores
  it when a later block is logged in; the pin stops *commands* from
  using it as the default.

### Confirmation

* Unit: every `GlabService` method that shells `glab` (not just
  create/clone) records `extraEnv` containing `GITLAB_HOST` /
  `GITLAB_URI` for a non-default origin, and `glab api` / `graphql`
  argv contains `--hostname <host>`. `gitlab.com` origins still pass
  neither. Existing `test/glab_service_test.dart` `hostEnv` tests
  extend to `mergeRequests`, `api`, `graphql`, `createMergeRequest`.
* Unit: `classifyForgeHost('ssh-gitlab.example.com')` and
  `authStatusListsHost` against a real 1.109 dump are pinned so the
  SSH-alias gap cannot regress silently. If the plan maps SSH aliases
  (glab `--ssh-hostname` / `ssh_host:`), that mapping is tested.
* Unit: `parseGlabAuthStatus` / a new origin-scoped probe still treat
  a mixed dump (gitlab.com 401 + self-hosted OK + "could not
  authenticate to one or more") as authenticated **to the origin
  host**, not to gitlab.com, and not as signed out.
* Live, maintainer-driven, on `admdevops` over Magic Git's SSH
  executor (not an interactive shell): open a `gitlab.example.com` repo
  whose stored remote is `git@ssh-gitlab.example.com:…`, and a repo
  whose origin is already HTTPS. Forge tab lists MRs, GraphQL
  dashboard resolves the project, `glab api user -i` HTTP status is
  200 against `gitlab.example.com`. Repeat with the connection's GitLab
  token present (neutralization on) and absent (host env + config
  store). Do not run `live-forge`-tagged tests.
* `flutter analyze` and `flutter test` clean on the changed files
  before staging.

## Pros and Cons of the Options

### Pin the origin host on every `GlabService` call (`GITLAB_HOST` / `GITLAB_URI` for subcommands, `--hostname` for `glab api` / GraphQL)

The Forge-tab methods grow the host selector create/clone already have.
`api()` / `graphql()` take `--hostname` because that is what glab 1.109
documents. Subcommands that have no such flag keep `hostEnv`.

* Good, because it fixes the missing wiring at the service layer, where
  every backend (SSH, local, pop-out proxy) already shares `GlabService`.
* Good, because it does not put tokens in argv or the export prelude.
* Good, because it matches glab's own documented override instead of
  fighting the `host: gitlab.com` default.
* Neutral, because cwd resolution remains if origin cannot be parsed;
  those calls already fail today for other reasons.
* Bad, because every glab call that today is "just argv" grows a host
  lookup (one `git remote get-url` per operation, or a short-lived
  cache on the service / a provider). Cheap next to the HTTP, but it
  is new coupling. A cache keyed by repo path must invalidate on
  remote change.
* Bad, because of the SSH-alias / `GITLAB_HOST` mismatch risk named
  under Consequences. Mitigation: also set glab `ssh_host` /
  `--ssh-hostname` from known aliases, or pin via `--hostname` on
  `api` (host identity for HTTP) while leaving subcommands to cwd
  when remotes already match.

### Keep cwd auto-resolution; only document that `glab` must have `host:` set to the self-hosted instance

Push the empty `gitlab.com` default onto the operator: change
`config.yml` `host:` to `gitlab.example.com`.

* Good, because zero app code.
* Bad, because it is a host-local workaround for an app that claims
  self-hosted GitLab is a first-class case. The next bastion with
  `host: gitlab.com` (glab's own default after `glab auth login` to
  a second instance) reproduces the bug.
* Bad, because it does not help GraphQL / `api` when cwd is not a
  matching git dir (scoped work trees, `GIT_DIR` overlay that glab's
  go-git does not honour, clone/create before origin exists — the
  last of those already pins, inconsistently).
* Bad, because it leaves `hostEnv` as a create/clone-only accident.

### Inherit the remote login environment's `GITLAB_TOKEN` / `GITLAB_HOST` and stop neutralizing them

Interactive-shell parity: if dartssh2/PAM already injects the user's
token and host, use them.

* Good, because on *this* bastion that is how the human already works.
* Bad, because the architecture forbids tokens in the process
  environment Magic Git controls, and neutralization exists
  specifically so a connection-scoped token wins over a stale ambient
  one. Turning neutralization off re-opens the "wrong identity"
  case the stdin login was built for.
* Bad, because dartssh2 exec is not promised to source `bashrc`. On
  this host a full PAM session *does* leak those vars into `ssh -T`
  commands; that is an accident of the bastion, not a contract.
* Bad, because neutralization today unsets the token and leaves
  `GITLAB_HOST`. Completing neutralization (unset host too) without
  a pin would make the default `gitlab.com` *more* likely, not less.

### Per-connection glab wrapper that rewrites argv[0] to `glab --hostname <host> …` at the executor

An executor decorator, analogous to `ScopedCommandExecutor`, injects
`--hostname` in front of every `glab` argv.

* Good, because call sites cannot forget it — the same reason
  `ScopedCommandExecutor` exists for `GIT_DIR`.
* Bad, because `glab mr list` / `glab issue list` / `glab ci trace`
  do not accept `--hostname` (verified against 1.109 `--help`). A
  blanket argv inject would break those subcommands. The injection
  has to be `api`/`graphql`-aware, which is service knowledge, not
  executor knowledge.
* Neutral, because a narrower decorator that only merges `hostEnv`
  for argv whose `argv[0]` is `glab` would work for the env half,
  and is a reasonable *implementation* of the chosen option. It is
  not a different decision.

## More Information

### Missing wiring (inventory)

| Call | Host pin today | What 1.109 accepts |
|---|---|---|
| `listRepos` / `createRepoInExisting` / `resolveOriginUrl` / `_gitProtocol` / `_recordCredentialUsername` | `hostEnv` | env |
| `api` (pipelines, jobs, merge, approve, …) | none | `--hostname`, env |
| `graphql` / `projectDashboard` | none | `--hostname`, env |
| `mergeRequests` / `createMergeRequest` / `mr view` / `mr checkout` / `mr note` / `mr update` | none | env (`GITLAB_HOST`); `-R` is a repo selector, not a host |
| `listIssues` / `issue view` / issue mutations | none | env |
| `traceStream` (`glab ci trace`) | none | env |
| `loginWithToken` | `--hostname` on `auth login` only | also `--ssh-hostname` (unused) |

`GhService.hostEnv` (`GH_HOST`) has the same create/clone-only shape.
Out of scope here unless a GitHub Enterprise host reproduces it.

### Bugs and gaps found, distinct from the pin

1. **Default `host: gitlab.com` + empty token is a silent wrong
   instance.** `glab api user` without a host pin returns HTTP 401 from
   gitlab.com with **exit 0**. Magic Git's `-i` path reports
   `failed with HTTP 401`; `looksLikeAuthFailure` is true. That is the
   auth-shaped Forge error. **(host + code)**
2. **GraphQL `project: null` is labelled as a login problem.** Wrong
   host, wrong path, and missing access are indistinguishable at the
   GitLab API, and Magic Git's message picks "not logged in". After
   pinning, a remaining null is a path/ACL issue and the copy should
   say so. **(code)**
3. **Auth probe is not origin-scoped.** `AuthProbeService` runs
   `glab auth status` with no `--hostname` / `--all`. glab 1.109's
   default is "current context". Combined with
   `parseGlabAuthStatus`'s "first working block", the dashboard can
   show a green self-hosted login while the failed command used
   gitlab.com. **(host + code)**
4. **Token neutralization is incomplete relative to this bastion.**
   Unsets `GITLAB_TOKEN` / `GITLAB_ACCESS_TOKEN` / `OAUTH_TOKEN` when
   the connection stored a GitLab token; does not touch
   `GITLAB_HOST`, `GITLAB_URI`, `GITLAB_PERSONAL_ACCESS_TOKEN`,
   `GITLAB_USER_TOKEN`. A stored Magic Git token that then
   `loginWithToken`s against origin can overwrite
   `hosts.gitlab.example.com.token` in config. If that stored token is
   for a different instance or stale, the config store that the
   stripped-env path depends on is destroyed, and the ambient
   `GITLAB_TOKEN` that made interactive status look fine is gone.
   **(host + code)** — whether the maintainer's connection actually
   stores a GitLab token was not checked (Keychain / connection
   store is local to the Mac).
5. **`ssh-gitlab.example.com` is not a GitLab telltale.**
   `classifyForgeHost` requires `gitlab` as a whole DNS label.
   `authStatusListsHost` requires an exact host token. glab config
   on this bastion has no `ssh_host:` / `--ssh-hostname` mapping.
   `insteadOf` currently papers this over for `git remote get-url`.
   **(host + code)**
6. **glab #911 is still live on 1.109** for `glab api user` (401 +
   exit 0). `auth status` *did* exit 1 from `$HOME` when gitlab.com
   failed, so the #911 fix is partial. Magic Git's `-i` hardening on
   `api`/`graphql` remains necessary; `glab mr list` still has only
   the exit code. **(host)**
7. **Architecture version guard is stale.** Target named as glab
   1.103; host is 1.109; 2.0 `GLAB_*` rename still unhandled.
   `--hostname` on `glab api` and context-sensitive `auth status`
   arrived in that interval and are unused. **(code + host)**
8. **`ScopedCommandExecutor` injects `GIT_DIR` / `GIT_WORK_TREE` for
   forge CLIs, but glab's remote resolver is go-git on cwd.** A
   scoped/dotfiles repo whose work tree has no `.git` directory can
   look to glab like "not a git dir" → default host gitlab.com.
   Not reproduced on `admdevops` (sampled repos are ordinary
   `.git` directories). Related to the pin, not a substitute for it.
   **(code; assumption that go-git ignores `GIT_DIR` — not verified
   against 1.109 source in this pass)**

### What this record does not claim

* It does not claim every MR list on `admdevops` currently fails.
  Four sampled repos listed MRs (or empty `[]`) successfully from a
  stripped env inside the repo cwd. The failure mode is
  **unpinned commands that miss remote resolution**, not "glab is
  unsigned-in".
* It does not claim dartssh2 exec never inherits `GITLAB_*`. `ssh -T`
  on this host *did* inherit them (PAM / systemd user session). Magic
  Git may see the same. The pin must still win over that inheritance,
  because neutralization already drops the token half of the pair.
* It does not change the secret-handling rule. Tokens stay on stdin
  once, then the host store.

### Host binary freeze (2026-08-26)

The maintainer leaves `admdevops` on **glab 1.109.0**. Official 1.110–1.115
notes do not change the documented host model (`GITLAB_HOST` / `--hostname` /
cwd remotes / default `gitlab.com`). 1.111 stores credentials in the OS
keyring by default, which would change `glab auth login --stdin` on a
headless SSH exec. The paired plan therefore targets 1.109 only and does
not upgrade the binary. Flag placement used by the plan (`glab api
--hostname <host> <endpoint>`, `glab auth status --hostname <host>`,
`glab mr list` rejecting `--hostname`) was verified live against that
1.109 binary.

### Related records

* [0002-MADR-forge-change-request-merge-and-models.md](0002-MADR-forge-change-request-merge-and-models.md)
  — Forge MR/PR models; assumes `GlabService` over the executor.
* [ARCHITECTURE_PLAN.md](ARCHITECTURE_PLAN.md) §4 — glab as the GitLab
  layer; cwd auto-resolution and stdin login. This record amends the
  cwd assumption; it does not replace stdin login.
* glab upstream: #911 (exit 0 on 401), #1270 / #8084 (commands falling
  back to gitlab.com), #1073 / #1095 (SSH hostname ≠ API hostname).
)
