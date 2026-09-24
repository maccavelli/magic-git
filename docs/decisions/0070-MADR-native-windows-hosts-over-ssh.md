---
status: "accepted"
date: 2026-09-23
decision-makers: [Maintainer]
consulted: [a read-only inventory of lib/ (scripts, escaping, watchers, path checks), the failed connection to a Windows 11 host on 2026-09-23, Microsoft Learn (OpenSSH for Windows, PowerShell, cmd.exe, .NET), the Win32-OpenSSH project, Git for Windows and git-scm documentation, dartssh2 3.3.0 source]
informed: [Magic Git contributors]
verified: 2026-09-23
---

# Windows hosts over SSH: detect the platform, carry the existing POSIX layer through Git for Windows, and add native Windows services where POSIX has none

## Context and Problem Statement

Magic Git's strongest idea is that it manages repositories **where they live**, over SSH, with no
local clone. Today "where they live" means a POSIX machine. `docs/architecture.md` says so on its
first page ("a remote POSIX machine reached over SSH"), and every remote command is built as POSIX
shell text.

On 2026-09-23 the maintainer added a Windows 11 laptop as a new SSH connection. Authentication
succeeded; the connection failed at the repository check with:

```text
GitException: not a git repository: C:\Users\<user>\gitrepos\<repo> (exit 1)
'export' is not recognized as an internal or external command,
operable program or batch file.
```

The repository was valid. Git never ran. Windows OpenSSH runs every `exec` request through the
account's default shell, which on Windows is `cmd.exe`; `cmd.exe` rejected the first word of the
POSIX prelude the app puts in front of every command. The message the user saw names the wrong
cause, because the environment probe that ran first had already failed and been swallowed.

Windows developer machines, Windows build servers, and Windows VMs are a large share of where
repositories live, and OpenSSH Server is built into every supported Windows release. No other Git
GUI drives Git on a remote machine over SSH at all, let alone a Windows one. This record decides
**how** Magic Git should support Windows hosts over SSH: through Git Bash, through native
PowerShell, through both, or some other way.

## Facts established before deciding

Facts are marked **(code)** when read from this repository, **(doc)** when taken from official
documentation (linked in More Information), and **(observed)** when seen on the Windows host. What
is not yet established is listed separately, as assumptions, with how each will be checked.

### F1 — Every remote command is POSIX shell text (code)

`CommandFormatter.format` (`lib/core/ssh/command_formatter.dart:103-150`) turns argv into
`unset …; export K=V …; cd '<repo>' && exec <args>`, optionally piped through `gzip`. Each argument
is quoted by `ShellEscaper` (POSIX single quotes). `SSHCommandExecutor` sends that string as the
`exec` request (`ssh_command_executor.dart:910-959`, and `:1245-1253` for streams). There is no other
path to the remote host.

### F2 — The POSIX surface is wide (code)

A read-only scan of `lib/` (comment lines excluded) found:

| Assumption | Sites | Files | Examples |
|---|---|---|---|
| `sh -c` scripts | 29 | 7 | commit-message preview, pending-op reader, fsmonitor config, legacy layout probe, `copyIgnoredFiles`, install/sideload, environment probe |
| `ShellEscaper` quoting | 64 | 8 | every interpolated path and argument |
| `export`/`unset`/`exec` prelude | 6 | 3 | the formatter, scoped-repo `GIT_DIR`/`GIT_WORK_TREE`, the forge probe |
| POSIX utilities inside scripts (`mktemp`, `sed`, `find`, `command -v`, `uname`, `printf`, …) | 58 | 12 | |
| Watchers (`fswatch`, `inotifywait`, `stdbuf`) | 35 | 7 | `bounded_watch.dart`, `remote_watch_service.dart`, `watcher_tool_probe.dart` |
| `/dev/null`, `/tmp`, `$TMPDIR`, `$HOME` | 86 | 12 | |
| Absolute-path checks `startsWith('/')` | 14 | 10 | connection form, clone and create sheets, add-worktree, host FS guard |
| `'$repoPath/$path'` joins | 6 | 5 | file view, status view, remote edit |
| POSIX programs as direct argv (`cat`, `pwd`) | 4+ | 3 | `git_service.dart:1512,2894,4741`, `host_fs_service.dart:54` |
| Uploads written as `sh -c 'cat > path'` | 1 | 1 | `ssh_command_executor.dart:505` (SFTP is not used anywhere) |
| Timeout/cancel by SSH `signal` request | 2 | 1 | `ssh_command_executor.dart:1162,1172` |

`git`, `gh` and `glab` are real programs on Windows, so the arguments survive; everything wrapped
around them does not.

### F3 — Failures are swallowed into a misleading message (code)

`EnvironmentProbe.resolve` treats a failed probe as "odd shell" and returns an empty environment
(`environment_probe.dart:111-114`). The connection then proceeds to
`GitService.validateRepoPath` (`git_service.dart:1289-1305`), which reports any failure other than
exit 127 as "not a git repository". On a `cmd.exe` host, both steps fail for the same reason, and the
user is told the wrong one.

### F4 — The SSH library can see the platform before any command runs (code)

dartssh2 3.3.0 exposes the server's identification string as `SSHClient.remoteVersion`
(`ssh_client.dart:364`), and an SFTP client (`SSHClient.sftp()`, `:643`). Neither is used today.

### F5 — Windows OpenSSH: shell, environment and signals (doc)

* The default shell for `exec` is `cmd.exe`. An administrator changes it with the registry string
  `HKLM\SOFTWARE\OpenSSH\DefaultShell`. The command is run as `<shell> <option> <command>`,
  `DefaultShellCommandOption` defaulting to `-c` (Win32-OpenSSH wiki). `cmd.exe`, PowerShell, bash
  and Cygwin get special argument handling.
* `AcceptEnv` and `PermitUserEnvironment` are **not available** in the Windows build, so
  environment variables cannot be sent as SSH `env` requests.
* Authentication is `password` or `publickey` only. An administrator's keys are read from
  `%programdata%\ssh\administrators_authorized_keys`, not the user's profile.
* Upstream `sshd` has supported the SSH `signal` channel request since OpenSSH 7.9 ("support
  signalling sessions via the SSH protocol"), which is what `session.kill(TERM)` relies on for POSIX
  hosts. Windows has no POSIX signals, and whether the Windows port acts on the request is not
  documented (assumption A9). A Win32-OpenSSH report (issue 1642) describes `sshd` killing **every**
  process a session started when the session ends, as a process tree.

### F6 — `cmd.exe` caps a command line at 8,191 characters (doc)

The limit covers the command line and every environment-variable expansion.

### F7 — PowerShell: encoded commands, stdin scripts, exit codes and bytes (doc)

* `-EncodedCommand` takes Base64 of a UTF-16LE string, "to submit commands … that require complex
  quotation marks". Base64 of UTF-16LE is about 2.7× the script's length, so under F6 an encoded
  command carries roughly 3,000 characters of script.
* `-Command -` and `-File -` read the script from stdin. Statements run one at a time as typed, so
  multi-line constructs need care; with `-Command`, a native program's exit code collapses to 0/1
  unless the script ends with `exit $LASTEXITCODE`.
* **Byte fidelity differs by version.** From PowerShell 7.4, redirecting or piping a native
  command's stdout preserves the bytes. Windows ships Windows PowerShell 5.1, where native output
  captured into the pipeline becomes strings. Git's NUL-delimited machine formats and `cat-file
  --batch` are exactly the output that must not be re-encoded.

### F8 — Git for Windows carries a POSIX shell with it; MinGit carries less (doc)

* Git for Windows runs hooks and aliases with its own bundled `sh`; a hook works the same whichever
  shell `sshd` started.
* The full distribution includes `bash.exe`, the MSYS2 coreutils (`base64`, `mktemp`, `sed`, `find`,
  …) and an `ssh.exe`. When MSYS bash starts a native Windows program, arguments that look like POSIX
  paths are rewritten (`/usr/bin` → `C:\Program Files\Git\usr\bin`); `MSYS_NO_PATHCONV=1` turns
  this off.
* **MinGit**, the minimal distribution third-party tools embed, has `/bin/sh` for hooks but **no
  bash**, and omits "executables that are not called by git.exe".

### F9 — Windows can watch files natively, with limits (doc)

`System.IO.FileSystemWatcher` exists from .NET Framework 1.1, so Windows PowerShell 5.1 has it with
no install. It watches a tree (`IncludeSubdirectories`), but its buffer can overflow in bursts. It
then raises `Error` and "will only provide blanket notification". It may report 8.3 short names.
Git's own `fsmonitor--daemon` runs on Windows and makes `git status` fast, but it talks only to Git
over its own IPC; it offers no event stream to other programs.

### F10 — SFTP on Windows speaks Windows paths (doc)

Win32-OpenSSH's `sftp-server` returns paths like `C:/Users/<user>`, which is not absolute by the
SFTP specification's rule. A client has to accept `C:/…` (and, from some servers, `/C:/…`).

### F11 — What is already portable (code)

* Git's machine formats (`status --porcelain=v2 -z`, `for-each-ref --format`, NUL-delimited log)
  are the same bytes on Windows.
* `gh` and `glab` are native Windows programs and read their tokens from stdin
  (`glab auth login --stdin`), with no shell involved.
* The executor seam (`CommandExecutor`) already hides transport from every service; the local
  backend proves a non-shell executor works (`LocalCommandExecutor`, argv with no shell string).
* Output byte budgets, lanes, telemetry and generation pinning are transport-level and do not
  change.

### Assumptions not yet verified (to be checked on a Windows host before any plan is approved)

| # | Assumption | How it will be checked |
|---|---|---|
| A1 | The identification string of Windows OpenSSH contains `for_Windows` (e.g. `SSH-2.0-OpenSSH_for_Windows_9.5`). | Read `remoteVersion` from a connection to the test host. |
| A2 | Output of a native program run by `cmd.exe` over `exec` reaches the channel byte-for-byte (NULs, no CRLF rewriting). | Run `git status --porcelain=v2 -z` and `git cat-file --batch` through `cmd.exe`; compare with a hash computed on the host. |
| A3 | Windows PowerShell 5.1 passes a native command's stdout straight through when it is the last command and not captured. | Same comparison, run through `powershell.exe -NoProfile`. |
| A4 | Closing the `exec` channel ends the whole process tree it started (F5, issue 1642). | Start `git` under a hook that spawns a child; close the channel; list the processes. |
| A5 | `C:\Program Files\Git\bin\bash.exe -c` works when `cmd.exe` or PowerShell is the default shell, and `cd 'C:/…'` works in it. | Run the bridge prototype (below). |
| A6 | Git for Windows' `base64 -d` is present in every full distribution since 2.x. | `command -v base64` through the bridge. |
| A7 | `FileSystemWatcher` output streamed from `powershell.exe` arrives promptly over `exec` (no block buffering). | Stream from the prototype watcher; touch a file; time the event. |
| A8 | SFTP writes to `C:/…` paths succeed with dartssh2's client. | Upload and read back a file. |
| A9 | Windows `sshd` ignores the SSH `signal` request, so `session.kill(TERM)` does nothing there. | Send TERM to a running `exec`; observe whether the process ends before the channel closes. |

## Decision Drivers

* **Zero-setup where possible.** A user adds a Windows host the way they add a Linux one; asking an
  administrator to change the machine's default shell should be optional, not required.
* **One implementation of Git behaviour.** The 29 scripts and the watcher logic encode years of
  fixes (0068's cleanup, 0065's watch bounds, the redaction scans). Writing them twice doubles every
  future fix.
* **Machine formats stay byte-exact.** NUL-delimited output and `cat-file --batch` must arrive
  unaltered (F7).
* **Honest failure.** When a host cannot be supported, say so precisely (F3).
* **No secrets in argv or command strings** (CLAUDE.md), which rules out passing tokens through
  environment prefixes on Windows as much as on POSIX.
* **Correct cancellation.** Timeouts and cancel must stop the whole remote process tree; on POSIX
  they do not (0069-REPORT), and Windows need not inherit that defect.
* **Testability without Windows CI.** Most confidence must come from tests that run on macOS, with a
  small, explicitly opted-in live suite (the `live-forge` pattern).
* **Incremental delivery.** Read-only browsing first, mutations next, live refresh last, with each
  step useful on its own.

## Considered Options

* **O1** — Refuse honestly: detect a non-POSIX host and fail with a precise message.
* **O2** — Require Git Bash as the host's SSH default shell (documented configuration, no new
  transport).
* **O3** — **Git for Windows bridge**: detect Windows, then run the existing POSIX layer through Git
  for Windows' own `bash`/`sh`, whatever the default shell.
* **O4** — **Native PowerShell dialect**: a second command layer that renders every operation as
  PowerShell.
* **O5** — **Native argv**: send `git`/`gh`/`glab` straight through `cmd.exe` with Windows argument
  quoting, and write the few scripts natively.
* **O6** — **WSL**: run everything inside the host's WSL distribution.
* **O7** — **Remote agent**: upload a small helper binary that speaks a structured protocol.
* **O8** — **Layered host dialect**: O1's detection, O3 as the core, O5's argv for single commands,
  and native Windows services (PowerShell watcher, tree-kill, SFTP) where POSIX has none.

## Decision Outcome

Chosen option: **"O8 — Layered host dialect"**, because it is the only option that:
* works with the host's default shell unchanged;
* keeps one implementation of every Git behaviour;
* keeps Git's bytes away from PowerShell 5.1's string pipeline;
* turns the Windows gaps (no `inotify`, no signals) into native strengths (`FileSystemWatcher`,
  whole-tree termination) instead of reimplementing POSIX tools.

Proposed pending A1–A9: a prototype on a Windows host confirms or amends each before a plan is
approved.

### The shape of the design

**1. Know the platform before sending a command.** At connect, read `remoteVersion` (F4). If it
names Windows, or if it is ambiguous, send a **polyglot probe**: one line that prints something
different under `cmd.exe`, PowerShell and `sh`, for example

```text
echo MGP_SH=%COMSPEC%;$PSVersionTable.PSVersion;$0
```

`cmd.exe` expands `%COMSPEC%` and echoes the rest literally; PowerShell parses `;` as a statement
separator and prints its version; `sh` prints `$0`. (The exact string is fixed by the prototype.)
The result is a `HostProfile`:
* platform (`posix`, `windows`);
* default shell (`sh`, `cmd`, `powershell`, `pwsh`, `bash`);
* the resolved Git for Windows root;
* its POSIX shell (`bash.exe`, or MinGit's `sh.exe`);
* its PowerShell version.

It is cached per connection and re-read on reconnect, like `RemoteEnvironment` today. A host with
no Git is refused with a precise message (O1's behaviour), never "not a git repository".

**2. One seam for dialect: `HostShell`.** `CommandFormatter.format` becomes one implementation of
a `HostShell` interface chosen by the `HostProfile`:

| Implementation | Wraps a command as | Used for |
|---|---|---|
| `PosixShell` (today's formatter) | `unset …; export …; cd '…' && exec …` | Linux, macOS, and a Windows host whose default shell is already bash (O2 users get no bridge overhead) |
| `GitBashBridge` | `"<git-root>\bin\bash.exe" -c "eval \"$(printf %s <b64> \| base64 -d)\""`: the existing POSIX text, Base64-encoded so no `cmd`/PowerShell metacharacter ever appears | every `sh -c` script and prelude on a Windows host |
| `WindowsArgv` | `cd /d "<repo>" && "<git>" <args>` with `CommandLineToArgvW`-correct quoting under `cmd.exe` (or `& '<git>' @args` under PowerShell) | single `git`/`gh`/`glab` invocations with no shell logic: the bulk of reads, where the bridge's process start would be pure overhead |

The escaping rule is decided by the implementation, not by callers. `ShellEscaper` stays the POSIX
implementation, and a `WindowsArgEscaper` is added beside it. The existing
`shell_injection_canon_test.dart` extends to both.

**3. Scripts larger than a command line.** The bridge's Base64 is ~1.33× the script. Scripts that
would exceed F6's 8,191 characters instead:
1. send a short fixed bootstrap that reads a length-prefixed script from stdin;
2. `eval` the script;
3. pass the rest of stdin through to the command.

The same framing serves the few commands that already take stdin, so a script and its data share
one channel.

**4. Scoped environment without `AcceptEnv`.** Environment variables (`GIT_DIR`, `GIT_WORK_TREE`,
`LC_ALL`, the token neutralisation) ride inside the bridge's encoded POSIX text exactly as today. On
the `WindowsArgv` path they are passed as `git -c`/`--git-dir`/`--work-tree` arguments where Git has
them, and otherwise the command is routed through the bridge. Secrets still go only over stdin.

**5. Paths are a type, not a string.** A `HostPath` value carries its style:
* POSIX `/srv/x`;
* Windows `C:/Users/<user>/x` (forward slashes, which Git, `cmd.exe`, PowerShell, MSYS bash and SFTP
  all accept);
* UNC `//server/share/x`.

It also carries case sensitivity (Windows paths compare case-insensitively). The 14 `startsWith('/')`
checks and the 6 `'$repoPath/$path'` joins move to `HostPath.isAbsolute` and `HostPath.join`. The
connection form accepts `C:\…` as typed and stores the normalised form. Git's own output is already
forward-slashed on Windows.

**6. Byte transport.** Git's output reaches the channel through the process that `sshd` started
without passing through a PowerShell pipeline:
* `WindowsArgv` under `cmd.exe` hands the handle straight to `git.exe` (A2);
* the bridge's bash `exec`s git.

Nothing Git prints is ever captured by Windows PowerShell 5.1. PowerShell is used only for
**native services**, whose output the app defines (below), in NUL-delimited UTF-8 that it writes
itself with `[Console]::OpenStandardOutput()`.

**7. Native Windows services, where POSIX has no equivalent.**

* **Live refresh.** A `FileSystemWatcher` script (F9) is streamed from `powershell.exe
  -NoProfile -NonInteractive -EncodedCommand …`. It prints `path\0` per event, and a sentinel on an
  `Error`/overflow event, which the pipeline treats as "rescan everything". That is the same
  contract the current fswatch path uses (`watcher_process.dart:182` splits on NUL for fswatch), so
  the coalescer and bounds from 0065 are reused unchanged. The watch-bounds logic (git dir plus
  tracked directories) maps to one recursive watcher plus the git dir, since `FileSystemWatcher` has
  no per-directory limit comparable to inotify's.
* **Cancellation that actually stops the tree.** Each bridged command first prints its Windows
  process id (MSYS: `/proc/$$/winpid`) on a side channel. Cancel runs `taskkill /PID <pid> /T /F`
  on a separate channel, in addition to closing the original. On Windows this closes the gap that
  0069-REPORT records for POSIX: a hook's children die with it. If A4 holds, closing the channel
  already does this, and `taskkill` becomes the backstop.
* **File I/O over SFTP.** `uploadBytes` and the remote editor's read/write move to SFTP (F4, F10) on
  Windows hosts, removing the `cat > path` script. POSIX hosts can adopt it later on its own merits.
* **Tool discovery.** The environment probe gets a Windows twin that resolves `git`, `gh`, `glab`
  via `where.exe`, plus the Git for Windows root from `git --exec-path`. The install planner learns
  `winget` hints (`Git.Git`, `GitHub.cli`, `GLab.GLab`).

**8. What the user sees.** Windows hosts get a platform badge in the connections manager (the
location glyph family from 0052) and a Windows section in the environment health sheet:
* Git for Windows version and root;
* default shell;
* PowerShell version;
* watcher status;
* `core.longpaths` and `core.autocrlf` values, each with a one-line explanation.

A host with MinGit and no bash runs everything that goes through `WindowsArgv`; features that need
the bridge are listed as unavailable with the reason, never as a generic failure.

### Delivery order (for the plan, not decided here in detail)

1. **Honest detection** (O1 behaviour + `HostProfile`): useful on its own, fixes F3 today.
2. **Read-only Windows sessions**: `WindowsArgv` for status, log, diff, branches, blame; `HostPath`;
   the connection form.
3. **Mutations and scripts** through the bridge: stage, commit (the 0068 preview script unchanged),
   stash, worktrees, fsmonitor config; SFTP file I/O; tree-kill cancellation.
4. **Live refresh**: the `FileSystemWatcher` stream.
5. **Forge**: `gh`/`glab` on Windows, the credential-helper argv (`forge.dart:106-138`) with Windows
   quoting.

### Consequences

* Good, because a Windows host works with its default shell untouched; O2's configuration becomes
  an optimisation, not a prerequisite.
* Good, because every existing script, including the ones hardened in 0068 and 0065, runs unchanged
  on Windows; a fix lands once.
* Good, because Git's bytes never cross Windows PowerShell 5.1's string pipeline.
* Good, because Windows cancellation can end the whole process tree, which POSIX hosts still
  cannot (0069-REPORT).
* Good, because F3's misleading error is fixed for every host, POSIX included.
* Good, because `HostPath` removes 20 stringly-typed path sites that would otherwise each need a
  Windows special case.
* Neutral, because a full Git for Windows install is required for the bridge. It is the standard
  distribution (`winget install Git.Git`) and ships with Visual Studio. MinGit-only hosts get
  `WindowsArgv` features and a clear list of what is unavailable.
* Bad, because each bridged command pays a process start for `bash.exe` (MSYS start-up on Windows
  is slower than `sh` on Linux); `WindowsArgv` exists to keep the hot read paths off it. The cost is
  to be measured in the prototype.
* Bad, because two quoting implementations and two path styles must be kept correct; they are
  pinned by canon tests on macOS, not by a Windows CI runner.
* Bad, because `FileSystemWatcher` can overflow (F9), so Windows refresh degrades to "rescan" under
  bursts rather than failing loudly.

### Confirmation

* **Before a plan is approved:** A1–A9 each recorded as confirmed or amended, from a prototype run
  against a Windows host whose hooks path is pinned (the rule from 0068: a probe that calls an AI
  provider is not a probe).
* **On macOS, every run:** golden tests of each `HostShell` rendering (the exact command string for
  a set of argv and scripts, including metacharacters, `%`, `^`, `!`, quotes, spaces and non-ASCII);
  `shell_injection_canon_test.dart` extended to `WindowsArgEscaper`; `HostPath` property tests; the
  polyglot probe's parser fed the three shells' recorded outputs; the bridge's framing
  round-tripped by a local `bash`.
* **Opt-in live suite** (`live-windows` tag, skipped by default like `live-forge`): the prototype's
  checks, repeatable against a configured host.
* **Each check seen to fail first**, as the repository's rules require.

## Pros and Cons of the Options

### O1 — Refuse honestly

* Good, because it is small (the probe and one message) and fixes the misleading error now.
* Neutral, because it is part of every other option anyway.
* Bad, because it delivers no Windows support.

### O2 — Require Git Bash as the default shell

Set `HKLM\SOFTWARE\OpenSSH\DefaultShell` to `C:\Program Files\Git\bin\bash.exe`.

* Good, because the existing POSIX layer may run nearly unchanged; the cheapest possible start.
* Good, because it remains a valid fast path inside O8 (the `PosixShell` row).
* Bad, because it needs an administrator to change a machine-wide setting that also changes every
  other SSH user's experience of that host, including interactive logins and other tools.
* Bad, because paths still arrive as `C:\…`, MSYS path conversion rewrites POSIX-looking arguments
  to native programs (F8), and live refresh still has no watcher; the gaps O8 fills remain.
* Bad, because a host the user cannot administer (a company laptop, a shared build box) stays
  unsupported.

### O3 — Git for Windows bridge

* Good, because it works with any default shell and reuses every script (driver: one
  implementation).
* Good, because Git for Windows is present wherever Git is, bar MinGit.
* Bad, because every command would pay the bash start-up, including hundreds of simple reads.
* Bad, because on its own it has no watcher, no tree-kill, and no answer for MinGit hosts.

### O4 — Native PowerShell dialect

* Good, because PowerShell is on every Windows host and needs no Git for Windows shell.
* Good, because `-EncodedCommand` removes quoting problems (F7).
* Bad, because every one of the 29 scripts and the watcher logic would be written a second time
  and kept in step forever (driver: one implementation).
* Bad, because Windows PowerShell 5.1 turns captured native output into strings (F7); any script
  that post-processes Git output in PowerShell risks corrupting NUL-delimited formats, and
  PowerShell 7.4+ is not installed by default.
* Bad, because exit codes need explicit `exit $LASTEXITCODE` handling in every script, and `-Command`
  collapses them otherwise.

### O5 — Native argv through `cmd.exe`

* Good, because single commands are the majority, and `cmd.exe` hands Git's stdout straight to the
  channel (A2) with the least start-up cost.
* Bad, because `cmd.exe` quoting (`^`, `%`, `!`, `"`) combined with `CommandLineToArgvW` rules is
  subtle; it needs its own escaper and canon test.
* Bad, because scripts still need a home; alone it covers reads, not the product.

### O6 — WSL

* Good, because inside WSL everything is Linux and works today.
* Bad, because repositories on the Windows filesystem (`/mnt/c`) are slow through WSL's 9P layer, and
  `inotify` does not fire for Windows-side edits there; the repository a Windows user works on is
  usually on the Windows side.
* Bad, because WSL may not be installed, and is per-user.
* Neutral, because a WSL-hosted repository can already be reached today by pointing SSH at the WSL
  instance; O8 does not preclude documenting that.

### O7 — Remote agent

A small cross-platform binary uploaded on first connect (the sideload machinery in
`install_service.dart` is precedent), speaking JSON-RPC over the `exec` channel. It would use
`ReadDirectoryChangesW`, job objects and native process APIs.

* Good, because it gives one precise, typed protocol on every OS, with native watching, tree-kill,
  and no quoting at all.
* Bad, because the app would ship and sign executables for each host architecture, a supply-chain
  and trust surface a Git client should not take on lightly; hosts that block unknown executables
  (AppLocker, Defender) refuse it.
* Bad, because it is the largest build, and it would replace, not reuse, a working POSIX layer.
* Neutral, because it remains a future direction if O8's bridge proves too slow; O8's `HostShell`
  seam is where an agent would plug in.

### O8 — Layered host dialect (chosen)

* Good, because it uses each tool where it is strongest:
  * `cmd`/argv for plain Git calls;
  * Git's own POSIX shell for scripts;
  * PowerShell for Windows services that POSIX lacks.
* Good, because it degrades by capability (MinGit, no PowerShell watcher, O2-configured hosts) with
  an explicit reason each time.
* Bad, because it has the most moving parts of the non-agent options: three `HostShell`
  implementations, a probe, a path type, and a watcher. Each is small and independently testable,
  and delivery is staged so each lands with its own value.

## More Information

### Ideas carried forward (not decided here)

* Offer to set `core.longpaths=true` and to explain `core.autocrlf` from the health sheet; both
  surface as confusing Git errors on Windows otherwise.
* A "Windows host setup" guide that runs, with consent, `Add-WindowsCapability -Online -Name
  OpenSSH.Server~~~~0.0.1.0` and `winget install Git.Git` over the existing connection's PowerShell,
  for hosts where they are missing.
* Detect Microsoft Defender real-time scanning of the repository (a common cause of slow `git
  status` on Windows) and link Microsoft's exclusion guidance.
* Reuse `git fsmonitor--daemon` for speed on Windows (`core.fsmonitor=true`, already a toggle in
  the app), independently of the app's own watcher.
* Adopt SFTP for file I/O on POSIX hosts too, once proven on Windows.

### Evidence

* The failed connection, 2026-09-23, captured from the running app; the host and account names
  are withheld.
* Codebase inventory: a read-only scan of `lib/` by category (counts in F2), kept with the
  investigation's scratch files, not in the repository.
* Microsoft Learn, *OpenSSH Server configuration for Windows* (updated 2025-08-05):
  https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh-server-configuration
* Win32-OpenSSH wiki, *DefaultShell*: https://github.com/PowerShell/Win32-OpenSSH/wiki/DefaultShell
* OpenSSH 7.9 release notes, `sshd` signal support: https://www.openssh.org/txt/release-7.9
* Win32-OpenSSH issue 1642, sessions' child processes killed at session end:
  https://github.com/PowerShell/Win32-OpenSSH/issues/1642
* Microsoft Learn, *Command prompt line string limitation* (8,191 characters):
  https://learn.microsoft.com/en-us/troubleshoot/windows-client/shell-experience/command-line-string-limitation
* Microsoft Learn, *about_PowerShell_exe* (5.1: `-EncodedCommand`, `-Command -`, exit codes):
  https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_powershell_exe
* Microsoft Learn, *about_Redirection* (7.4 native byte-stream preservation):
  https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_redirection
* Microsoft Learn, *FileSystemWatcher class*:
  https://learn.microsoft.com/en-us/dotnet/api/system.io.filesystemwatcher
* git-scm, *git-fsmonitor--daemon*: https://git-scm.com/docs/git-fsmonitor--daemon
* Git for Windows, *MinGit*: https://gitforwindows.org/mingit.html
* Win32-OpenSSH issue 1512 and WinSCP forum, `sftp-server` path format:
  https://github.com/PowerShell/Win32-OpenSSH/issues/1512
* dartssh2 3.3.0 source, `SSHClient.remoteVersion` and `SSHClient.sftp()`.

### Related records

* `docs/architecture.md` — the POSIX statement this record would amend once implemented.
* [0013-MADR-prefer-dartssh2-v3-over-dartssh3.md](0013-MADR-prefer-dartssh2-v3-over-dartssh3.md) —
  the SSH library whose `remoteVersion` and SFTP this design uses.
* [0068-MADR-commit-wait-legibility-and-inline-button-alignment.md](0068-MADR-commit-wait-legibility-and-inline-button-alignment.md)
  — the preview script that must run unchanged through the bridge.
* [0069-REPORT-timed-out-commands-signal-only-the-leader.md](../reports/0069-REPORT-timed-out-commands-signal-only-the-leader.md)
  — the POSIX tree-kill gap that Windows cancellation closes.

## Amendment 0070.1 (2026-09-23): the first slice is Git Bash, detected and offered

**Direction (maintainer, 2026-09-23).** Before the layered dialect, ship detection and a guided
route to option O2. When a Windows host's SSH shell is not Git Bash:
* the app says so;
* if Git Bash is installed, it offers to make it the shell, with an Enable action and the exact
  PowerShell command in a copyable field;
* if Git Bash is not installed, it says so and offers the install command.

Git Bash becomes a listed dependency in Settings, with a custom-path field like `git`, `gh` and
`glab`.

**How this fits the decision.** It does not replace O8. It delivers O8's first step (honest
detection, O1) together with the `PosixShell` fast path that O8 already keeps for hosts whose
default shell is bash. The slice asks the user to change a machine-wide setting, which O2's cons
record; the prompt says so before Enable, and gives the inverse command. The bridge, native argv,
`HostPath` and the native services stay proposed, and O8 remains the direction.

**Implementation.** [0070-PLAN-git-bash-detection-and-enablement.md](0070-PLAN-git-bash-detection-and-enablement.md),
`proposed`. The plan's Phase 5 checks A1 on the maintainer's host, and adds A10: `sshd` applies a
changed `DefaultShell` to the next session without a service restart.

## Amendment 0070.2 (2026-09-23): the first slice on a real Windows host

The Git Bash slice (0070-PLAN) was checked on the maintainer's Windows 11 laptop.

* **A1 confirmed.** The host identifies as `SSH-2.0-OpenSSH_for_Windows_9.5`.
* **A10 confirmed, per the maintainer.** Enable, from an administrator account, set
  `DefaultShell`, and the next connection ran through Git Bash with no `sshd` restart.
* **O2's premise holds for reading.** With Git Bash as the shell, the existing POSIX layer works
  unchanged: Status, the file tree, History, and a commit's diff.

**Found at the gate:**
* repository names show the whole `C:\…` path, which is `HostPath`'s job (§5 of the decision);
* live refresh falls back to polling, which the `FileSystemWatcher` service (§7) replaces;
* a watcher sweep fails on a quoted `~` path, which is not specific to Windows.

A2 to A9 remain open for the layered-dialect work.

## Amendment 0070.3 (2026-09-24): reassessed under Git Bash — paths and arguments first

**Status: accepted** (the maintainer, 2026-09-24, including the hook trade-off below), with
its plan,
[0070-PLAN-host-paths-and-argument-fidelity.md](0070-PLAN-host-paths-and-argument-fidelity.md).

The decision above (O8) was made before any Windows host was reached. Since then the maintainer
chose the Git Bash route (Amendment 0070.1), it shipped, and it works for reading (0070.2). This
amendment reassesses what O8 still has to deliver, from facts measured on the maintainer's
Windows 11 host on 2026-09-24. Every measurement was read-only: no file was written on the host,
and every git call pinned `core.hooksPath=/dev/null` and `core.fsmonitor=false`.

### Facts measured (observed)

| # | Fact | How it was seen |
|---|---|---|
| F12 | **Git for Windows prints every absolute path as `C:/…`** (drive letter, forward slashes): `rev-parse --show-toplevel`, `--absolute-git-dir`, `--path-format=absolute`, `worktree list --porcelain`, and `for-each-ref %(worktreepath)`. | `git 2.55.0.windows.5`, run in the maintainer's repository |
| F13 | **The app stores a Windows repository in three forms.** `/c/Users/<user>/…` from the folder browser (it starts at `pwd`, `HostFsService.homeDir`) and from `~` (`$HOME=/c/Users/<user>`); `C:\…` or `C:/…` when typed. Recent Repositories holds `C:\…` and `/c/…` for the same repository. | the live preferences store |
| F14 | **Git canonicalizes case; the shell does not.** After `cd` into an all-caps spelling, `pwd` echoes the caps, and `--show-toplevel` returns the true case in `C:/…` form. `cd` accepts `/c/…`, `C:/…`, `C:\…` and any case. | host |
| F15 | **MSYS rewrites every argument that starts with `/` on its way into a native program**, user text included. Into `git.exe`: `/usr/bin broken` → `C:/Program Files/Git/usr/bin broken`; `/tmp` → `C:/Users/<user>/AppData/Local/Temp`; `--x=/tmp/y` → `--x=C:/Users/<user>/AppData/Local/Temp/y`. `a:/b`, URLs, `refs/heads/x`, `HEAD:/c/file` and `//server/share` pass unchanged. The app passes commit, tag, merge and stash messages and the History `--grep=`/`--author=` filters as arguments (`git_service.dart:2465-2468`, `:3286`, `:4259`, `:4718`, `:5395`, `:5680`), so **such text is corrupted today** on a Git Bash host. | `git rev-parse --sq-quote` echoing its arguments |
| F16 | **`MSYS_NO_PATHCONV=1` stops the rewriting, and is inherited.** Under it all ten test arguments arrive unchanged. A nested `sh` (as a hook's shell would be) inherits it. | host |
| F17 | **With conversion off, git needs Windows-form paths.** Under `MSYS_NO_PATHCONV=1`: `git -C C:/…` and `GIT_DIR=C:/…` work; `git -C /c/…` and `GIT_DIR=/c/…` fail ("cannot change to", "not a git repository"). MSYS programs (`cd`, `ls`, `test`, `cat`) accept `C:/…`. | host |
| F18 | **The byte path is clean under Git Bash.** `status --porcelain=v2 -z --branch` arrives with its NULs and no CR; `log` lines end in `\n`. | `od -c` over SSH |
| F19 | **The host has what the native services need.** Windows PowerShell 5.1 (`powershell.exe`), PowerShell 7 (a user install), `taskkill`/`tasklist`, `/proc/$$/winpid`, and MSYS `stdbuf`, `timeout`, `base64`, `mktemp`, `gzip`, `cygpath`. There is no `fswatch` or `inotifywait`. | `command -v` |
| F20 | **Git defaults on this host:** `core.autocrlf=true` (system config), `core.ignorecase=true`, `core.symlinks=false`, `core.filemode=false`. The MSYS root `/` is the Git install directory; drives are mounted at `/c`, `/d`, … but are not listed in `/`. | host |

### Assumptions, updated

* **A1** confirmed (0070.2). **A10** confirmed (0070.2).
* **A2** answered for the Git Bash route (F18). It stays open only for a `cmd.exe` shell, which the
  app now refuses with the Git Bash prompt.
* **A3** and **A5** do not arise under Git Bash: nothing passes through PowerShell or a bridge.
* **A6** confirmed: `base64` is present (F19).
* **A4, A7, A9** remain open. Each needs a prototype that starts processes on the host, so each is
  a Phase 0 of the plan that needs it, run with the maintainer's consent.
* **A8** does not arise while file writes go through MSYS `cat` (F17).

### Reassessment of O8's parts

| Part | Under Git Bash | Decision |
|---|---|---|
| Honest detection | Shipped (0070-PLAN, first slice) | done |
| `PosixShell` | Is the transport (O2) | done |
| `GitBashBridge`, `WindowsArgv`, byte transport, the polyglot probe | Needed only for a host whose SSH shell cannot be Git Bash (no administrator, or MinGit only) | **deferred** until such a host is a requirement |
| SFTP file I/O | Not needed: MSYS `cat` writes `C:/…` paths (F17) | **deferred** |
| **`HostPath`** | Needed now: F12-F14 break every comparison between a git-printed and a stored path, and F17 makes one canonical form mandatory | **next** |
| **Argument fidelity** (new) | F15 corrupts user text today | **next, with `HostPath`** |
| `FileSystemWatcher` live refresh | Needed: Windows polls (F19: no watcher tool) | after, behind an A7 prototype |
| Tree-kill cancellation | Needed for timeouts (0069-REPORT) | after, behind A4 and A9 prototypes |
| `core.longpaths` / `core.autocrlf` in the health sheet | Useful (F20) | later |

### Decision

1. **Canonical form.** On a Windows host, a host path is canonical as git prints it: `X:/a/b`
   (upper-case drive letter, forward slashes, no trailing slash except `X:/`). `//server/share/…`
   stays UNC. The app canonicalizes when a path enters (the connect, the folder browser, a typed
   field), compares Windows paths case-insensitively, and takes git's case when git reports the
   repository's top level (F14). POSIX paths, on the local backend and on POSIX hosts, stay
   byte-for-byte as today.
2. **Argument fidelity.** On a Windows host the executor exports `MSYS_NO_PATHCONV=1` with every
   command. Every app-supplied path is canonical (decision 1), so nothing still needs MSYS to
   convert it (F17), and user text reaches git unchanged (F16).
3. **Delivery order**, replacing "Delivery order" above for the remaining work: `HostPath` with
   argument fidelity; then live refresh (A7 prototype first); then tree-kill (A4, A9 first); then
   the health-sheet items. The bridge, `WindowsArgv` and SFTP wait for a host that cannot use Git
   Bash.

### Consequences

* Good, because every defect caused by stored versus git-printed forms goes away at the source.
  The plan lists them: worktree "checked out elsewhere", adding a worktree, a new worktree's tab,
  "Create in existing folder", editing saved entries, and duplicates across forms.
* Good, because commit messages and search text starting with `/` stop being rewritten.
* Neutral, because tabs, titles and the Workspaces sheet show `C:/Users/…` paths for Windows
  repositories, which is how git, PowerShell and Explorer's address bar can all use them.
* **Bad, because `MSYS_NO_PATHCONV=1` is inherited by hooks (F16).** A hook script that passes a
  `/c/…` or `/tmp` path to a native Windows program would now pass it unconverted, where the same
  hook run from the user's own Git Bash terminal gets it converted. Hooks that build paths from
  `git rev-parse` (which prints `C:/…`) or use relative paths are unaffected. The alternative
  considered, keeping conversion on and moving user text off the command line, is incomplete:
  `stash push -m`, `--grep` and `--author` have no file or stdin form, so some text would still be
  rewritten. The plan's device gate runs a sample hook to show the difference, and the help book
  documents it.

### Confirmation

On macOS, every run: `HostPath` property tests; formatter tests pinning `MSYS_NO_PATHCONV=1` for a
Windows host and its absence otherwise; a test per defect site. On the host, the plan's device
gate: a message starting with `/` committed and read back unchanged, and a worktree added and
opened, both in a scratch repository with the maintainer's consent.
