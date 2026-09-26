---
status: "proposed"
date: 2026-09-25
decision-makers: [Maintainer]
consulted: [a read-only survey of lib/ (settings, ConnectionStore, both executors, CommandFormatter, forge services, credential helper), read-only probes of gh 2.98.0 and glab 1.117.0 on a Windows 11 host over key-authenticated SSH, MADR 0019, PLAN 0055 item 2, MADR 0070]
informed: [Magic Git contributors]
verified: 2026-09-25
---

# Magic Git supplies GitHub and GitLab tokens itself, on every call, so the host's credential store no longer decides whether forge work runs

## Context and Problem Statement

On 2026-09-24, the device check for Amendment 0036.1
([0036-PLAN-clone-forge-list-on-a-saved-host.md](0036-PLAN-clone-forge-list-on-a-saved-host.md),
Phase 4) cloned from a Windows 11 host reached over SSH with key authentication. The sheet dialled
the host correctly, and both forge tabs then showed the CLI's own error:

* GitHub: `gh repo list failed — HTTP 401: Requires authentication`.
* GitLab: `failed to read "token" from the operating system keyring … A specified logon session
  does not exist. It may already have been terminated.`

The same failures reproduce outside the app, over plain `ssh <host> "gh auth status & glab auth
status"`. gh reports the stored token as invalid, and glab cannot read its token from the keyring.
Both CLIs were signed in at the machine itself. Both keep their tokens in the Windows credential
store, which a key-authenticated SSH logon session cannot open. Everything the app does with a
forge on that host fails: listing, the host prefill, MR/PR and pipeline views, and HTTPS
fetch/push through the CLI's credential helper.

Today the app does not supply tokens; it relies on the host's CLI:

* Each saved connection can hold a GitHub and a GitLab token. `ConnectionStore` keeps them in the
  Keychain under `conn_ghtoken_<id>` / `conn_gltoken_<id>`, or in the unsigned-build fallback
  `~/.config/magic_git/credentials.json` (`lib/core/storage/connection_store.dart:23-27`).
* At connect, `ConnectionController` logs the host's CLI in **once**: `gh auth login --hostname
  <h> --with-token` or `glab auth login --hostname <h> --stdin`, with the token on stdin
  (`lib/core/github/gh_service.dart:101-124`, `lib/core/gitlab/glab_service.dart:135-160`). Every
  later call uses whatever the host's CLI then has stored.
* So the stored login lands in the same credential store. A token entered in the app does not
  help on this host, and a connection with no token depends entirely on the host's own sign-in.
* The local backend ("This Mac") carries no token at all, and relies on the Mac's own CLI
  sign-in.

The maintainer asked for tokens to be entered in Magic Git's Settings, next to the gh and glab
binary settings, and for the app to manage gh/glab authentication itself, whatever the host's
operating system or the CLIs' own sign-in state.

**The question:** how does a token held by Magic Git reach `gh` and `glab` on every call, on any
host, without the host's credential store, and without breaking the rule that a secret never
appears in argv or a command string?

## Decision Drivers

* **Works on any host.** It must work on Windows over key-authenticated SSH, Linux, macOS and the
  local backend, whatever the host's credential store can do.
* **Independent of the host CLI's own state.** It must not depend on a stale, expired, keyring-bound
  or absent sign-in, or on the user's CLI config (such as `git_protocol: ssh`).
* **No secret in argv or a command string.** This is a standing rule (`CLAUDE.md`, "SSH transport
  rules"; `docs/architecture.md`). It was restored in
  [0055-PLAN-post-review-action-plan.md](0055-PLAN-post-review-action-plan.md), item 2, after an
  `export GITLAB_TOKEN='…'` prelude leaked the token to `ps`, `/proc/<pid>/cmdline` and shell audit
  logs.
* **Least secret left on the host.** A bastion is often shared.
* **Covers every forge path:** the gh/glab calls, and git's HTTPS fetch/push/clone through the
  per-command credential helper (`lib/core/forge/forge.dart:105-171`).
* **Rotation and removal take effect at once**, with no host-side state to chase.
* **Does not disturb the user's own CLI.** The app must not overwrite the user's own gh/glab
  sign-in or config on the host.

## Considered Options

* A. Settings tokens, supplied on every call over stdin into the CLI's environment, with the CLI
  pointed at a config directory Magic Git owns.
* B. Settings tokens, logged in once per host into CLI config directories Magic Git owns, stored
  as plaintext files there.
* C. Settings tokens, exported in the command string on every call (the pre-0055 design).
* D. Settings tokens, sent as SSH environment requests (`execute(command, environment:)`).
* E. Keep host-managed sign-in, and tell the user how to fix the host (for example
  `--insecure-storage`).

## Decision Outcome

Chosen option: **"A. Settings tokens, supplied on every call over stdin"**. It is the only option
that meets every driver at once:

* it works on the Windows host whose credential store is unreachable (verified below);
* it leaves no secret at rest on any host;
* it keeps every secret out of argv and the command string;
* rotation is immediate.

### What A means

1. **Where tokens are entered.** A new **Forge accounts** section in Settings, beside External
   tools. It holds one token per (forge, host), for example GitHub on `github.com` and GitLab on
   `<gitlab-host>`.
   * Tokens are stored as `ConnectionStore` stores connection secrets: in the Keychain, or in the
     0600 `credentials.json` fallback on unsigned builds, under new global keys. Never in
     SharedPreferences.
   * Settings are global, not per connection, like `binaryOverrides`
     (`lib/core/settings/app_settings.dart:45-50`).
2. **Which token a call uses:**
   * the connection's own token for that forge, when set;
   * otherwise the Settings token for the host the call is pinned to (`GITLAB_HOST`, per
     [0019-MADR-pin-glab-origin-host-on-every-call.md](0019-MADR-pin-glab-origin-host-on-every-call.md);
     `GH_HOST`, `lib/core/github/gh_service.dart:318-319`);
   * otherwise none, and the call behaves exactly as today.

   So existing per-connection tokens keep working, and a setup with no tokens is unchanged.
3. **How a token reaches the CLI, over SSH.**
   * The executor starts the command with a fixed, secret-free prelude, for example
     `IFS= read -r GH_TOKEN; export GH_TOKEN; …`.
   * It writes the token as the first line of the channel's stdin, followed by the command's own
     stdin, if any.
   * The token exists only in the environment of the shell and the CLI for the life of that call.
   * The variables used are `GH_TOKEN`, or `GH_ENTERPRISE_TOKEN` with `GH_HOST` for GitHub
     Enterprise, and `GITLAB_TOKEN` with the pinned `GITLAB_HOST`.
4. **How a token reaches the CLI on This Mac.** It goes in the child's `environment:` in
   `Process.start`. There is no shell or command string, and no stdin prelude is needed.
5. **Config directories Magic Git owns.** While the app supplies a token, glab runs with
   `GLAB_CONFIG_DIR` and gh with `GH_CONFIG_DIR`, each pointed at a directory Magic Git owns on
   that host (for example `~/.config/magic-git/glab`). The directories hold no secret.
   * For glab this is required, not a nicety. With the user's own config, glab reads a keyring
     `job_token` before it considers `GITLAB_TOKEN`, and fails on this host (Evidence 3).
   * For gh it isolates the call from the user's config, for example a `git_protocol: ssh` that
     would make `gh repo clone` use SSH keys instead of the token.
6. **Git over HTTPS.** Git commands that carry the forge credential helper (`forgeGitAuthConfigArgs`)
   get the same prelude and config directories. The helper (`gh auth git-credential` /
   `glab auth git-credential`) inherits them from git, and hands the token to git (Evidence 2 and 4).
7. **Sign-in state comes from the forge's API when the app supplies the token.**
   `forgeAuthProvider` asks the forge's API through the CLI (`gh api user` / `glab api user`),
   under the same token, instead of `auth status`. In glab's clean-config mode, `auth status`
   reports "not authenticated" even when the token works (Evidence 4).
8. **The connect-time login retires.** The app stops running `gh auth login` / `glab auth login`
   on the host, so it no longer writes to the host CLI's credential store. That is a behaviour
   change, covered under Consequences.
9. **Pop-out windows.** The token is applied by the owning session's real executor in the main
   isolate. `ProxyCommandExecutor` never carries it across the window relay.

### Consequences

* Good, because forge work on the Windows host, and on any host whose credential store an SSH
  session cannot open, runs on the token Magic Git holds (Evidence 1 and 2).
* Good, because nothing secret is written to any host. Removing or rotating a token in Settings
  takes effect on the next call, everywhere.
* Good, because the token never appears in argv, the command string, `ps`, `/proc/<pid>/cmdline`
  or a shell history. The command string carries only the fixed prelude.
* Good, because This Mac gains the same behaviour: a Settings token works even when the Mac's own
  gh/glab is signed out.
* Good, because the host's own gh/glab sign-in and config are no longer read or written while the
  app supplies a token. A user's terminal session is unaffected.
* Neutral, because it amends one sentence of MADR 0019: "the architecture forbids tokens in the
  process environment Magic Git controls" (0019, the rejected option "Inherit the remote login
  environment's `GITLAB_TOKEN`").
  * That option was rejected over an *ambient, stale* token overriding the intended one, and that
    concern stands. The neutralization of ambient token variables stays, and an app-supplied
    token replaces them explicitly.
  * What changes is that Magic Git itself now places *its own* token in the environment of the
    processes it starts. That environment is readable only by the same user and by
    administrators (`/proc/<pid>/environ` is mode 0400 on Linux), the same readers as a 0600
    credential file.
* Bad, because a host where the user relied on the app's connect-time `gh auth login` to sign in
  their own terminal CLI no longer gets that side effect. Their terminal gh/glab stays as they
  left it.
* Bad, because every forge-bound call pays the prelude. It is a few bytes, and stdin is already
  open on streamed calls. Every call site that runs gh, glab or git-with-helper also has to pass
  through the executor's forge path, which the plan must enumerate and test.
* Bad, because each host gets two small directories (`~/.config/magic-git/{gh,glab}`) that the app
  creates and owns. They contain no secret.

### Confirmation

* **A scan test**, written and seen to fail before it is trusted: no source string that reaches
  argv or `CommandFormatter.format` may contain a token value. A fixture token must never appear
  in any formatted command or argv across the forge services' tests. Only on stdin's first line
  (SSH) or in `environment:` (local).
* **Executor tests:**
  * the prelude reads exactly one line;
  * the command's own stdin passes through intact after it (Evidence 5);
  * a call with no applicable token gets no prelude.
* **Resolution tests:** the connection token, then the Settings token for the pinned host, then
  none. A GitLab call pinned to host X never receives host Y's token.
* **Mutation catalogue:** entries that remove the prelude, put the token in `extraEnv`, drop the
  config-directory variables, and pick the wrong host's token. Each must be killed by the named
  tests.
* **Device checks:**
  * On the Windows host with its credential store unreachable, and no connection tokens: clone
    lists GitHub and GitLab repositories from Settings tokens, and a fetch over HTTPS
    authenticates.
  * On a Linux host.
  * On This Mac with its own gh signed out.
  * On each, `ps` taken during a long call shows no token.

## Pros and Cons of the Options

### A. Settings tokens, supplied on every call over stdin, with Magic Git's own config directories

* Good, because it was verified on the failing host: gh, with the token read from stdin into
  `GH_TOKEN`, reached GitHub and got `401 Bad credentials` for a deliberately invalid token. So
  the token was used, and the credential store was not in the way (Evidence 2).
* Good, because nothing secret rests on any host, and the command string stays secret-free.
* Good, because rotation and removal are immediate.
* Neutral, because the token sits in the process environment of the CLI during the call. It is
  readable by the same user and administrators, like any 0600 file.
* Bad, because it needs the most plumbing: a forge-aware path in both executors, including
  streamed calls, git-with-helper, and a new Settings section.

### B. Settings tokens, logged in once per host into Magic Git's own config directories as plaintext

`GH_CONFIG_DIR=<dir> gh auth login --with-token --insecure-storage` and the glab equivalent, with
`use_keyring` off for that host. Afterwards every call exports only the directory path.

* Good, because it reuses the existing login-once flow. Both CLIs offer the flag
  (`--insecure-storage`), and glab documents a per-host `use_keyring` setting.
* Good, because per call it only sets a non-secret variable.
* Bad, because the token is written to every host the app touches, in a plaintext file.
  * On a shared bastion that is the state the token-in-argv fix tried to avoid.
  * It survives the app's removal of the token until someone deletes it on the host.
* Bad, because rotation needs a re-login on every host, and a host the app no longer visits keeps
  the old token.

### C. Settings tokens exported in the command string

* Bad, because it is the defect 0055 item 2 removed: the token shows up in `ps`,
  `/proc/<pid>/cmdline` and shell audit logs.

### D. Settings tokens as SSH environment requests

* Good, because the command string would carry nothing.
* Bad, because servers refuse them by default. OpenSSH accepts only the names in `AcceptEnv`,
  usually `LANG LC_*`. The Windows host's `sshd_config` has no `AcceptEnv` at all (Evidence 6).
  dartssh2 raises `SSHChannelRequestError` on a refusal.

### E. Keep host-managed sign-in, and guide the user

* Good, because it needs no code.
* Bad, because it does not meet the request. The app still depends on each host's CLI state, and
  fixing a Windows host means the user logs in there with plaintext storage, which is option B
  done by hand.

## More Information

### Evidence

All probes were read-only on the Windows 11 host (gh 2.98.0, glab 1.117.0, Git Bash 5.3). They
used a deliberately invalid token, and wrote nothing outside a temporary directory, which was
removed. Host, account and GitLab instance names are redacted.

1. **The CLIs' own state over SSH.** `gh auth status`: `The token in default is invalid.`
   `glab auth status`: `could not read the token: failed to read "token" from the operating
   system keyring … A specified logon session does not exist.`
2. **gh with an environment token.**
   * `GH_TOKEN=<invalid> gh auth status` listed `Failed to log in to github.com using token
     (GH_TOKEN)`, and `gh auth token` returned the variable's value.
   * `gh auth git-credential get` for `github.com` returned `username=x-access-token` with that
     token as the password.
   * Read from stdin (`IFS= read -r GH_TOKEN; export GH_TOKEN; exec gh api user`), the call
     reached GitHub and returned `"status": "401"`, `Bad credentials`.
3. **glab with an environment token and the user's config.** `glab auth status` found `Token
   found in environment variable GITLAB_TOKEN` and said it "takes precedence". But `glab api user`
   failed with `Failed to read the job token … from the operating system keyring`. It failed the
   same way with `USE_KEYRING=false`, whether the token came from the environment or from stdin.
4. **glab with a clean `GLAB_CONFIG_DIR`, `GITLAB_HOST` and `GITLAB_TOKEN`.**
   * `glab api user` reached the instance and returned `401 Unauthorized`.
   * `glab auth git-credential get` returned `username=glab` with the token.
   * `glab auth status` reported `has not been authenticated with glab`. That is why decision
     point 7 does not use `auth status`.
   * glab wrote `config.yml`, `aliases.yml` and `config.lock` into the directory on first use.
5. **Stdin after the token line.** `IFS= read -r T; exec cat` printed the second line intact.
6. **The Windows host's `sshd_config`.** It has no `AcceptEnv` line, only the commented
   `#PermitUserEnvironment no`.

### Relation to other records

* [0019-MADR-pin-glab-origin-host-on-every-call.md](0019-MADR-pin-glab-origin-host-on-every-call.md):
  its host pinning is what selects the token. Its sentence on tokens in the process environment
  is amended as described under Consequences. Its neutralization of ambient token variables
  stays.
* [0055-PLAN-post-review-action-plan.md](0055-PLAN-post-review-action-plan.md) item 2: its rule
  stands unchanged, and this decision relies on it. No secret in argv or the command string, and
  stdin as the channel.
* [0036-MADR-choosing-a-create-destination-while-connected.md](0036-MADR-choosing-a-create-destination-while-connected.md),
  Amendment 0036.1: the clone browse on a saved host. `ensureForgeHostLogin` is a no-op for a
  connection with no token, so Settings tokens are what make that browse work on such a host.
* [0070-MADR-native-windows-hosts-over-ssh.md](0070-MADR-native-windows-hosts-over-ssh.md): the
  host class where this was found. Nothing here is Windows-specific; the same holds on any host
  whose credential store is locked to SSH sessions.

### Open questions for the plan

* The Settings UI: how a host is named, and whether a Test action validates a token through the
  connected host or from the Mac.
* Whether the per-connection token fields stay as overrides, as decided above, or are later
  folded into Forge accounts. This decision keeps them, so no saved connection changes.
* gh's behaviour with a fresh `GH_CONFIG_DIR` and `GH_TOKEN`, including `gh repo clone` under a
  default `git_protocol`, is assumed from gh's documentation and not yet probed. Its first phase
  verifies it on the Windows host before any code relies on it.
