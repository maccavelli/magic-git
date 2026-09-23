---
status: "complete"
date: 2026-09-22
verified: 2026-09-22
---

# Timed-out commands signal only the leader, and their children outlive the app

This records a finding from executing
[0068-PLAN](../decisions/0068-PLAN-commit-wait-legibility-and-inline-button-alignment.md)
(deviation D1). It decides nothing: 0068 fixes the one command it owns, the commit-message
preview, and this report states what applies to every other command, what was measured, and what
was not.

## What the executors do on a timeout

* **Local.** `LocalCommandExecutor._killEscalate` sends `SIGTERM` to the process, then `SIGKILL`
  after `SSHCommandExecutor.killGrace` — 400 ms (`lib/core/exec/local_command_executor.dart:490-502`,
  `lib/core/ssh/ssh_command_executor.dart:1143`). `Process.kill` signals one PID.
* **SSH.** `SSHCommandExecutor.killAndCloseSession` sends an SSH `signal` request (`TERM`) and
  closes the channel at once, then sends `KILL` and closes again after the same grace
  (`ssh_command_executor.dart:1159-1179`). The command runs as `cd <repo> && exec <argv>`
  (`lib/core/ssh/command_formatter.dart:136`), so the signal is addressed to the command itself.

Neither signals the **process group**. Anything the command started keeps running unless the
command itself stops it.

## Measured (2026-09-22, this Mac, git 2.55.0)

Each case runs in a throwaway repository whose `core.hooksPath` is pinned to its own hooks
directory — this machine's global hook calls an AI provider, and a probe that does that is not a
probe. The stub hook records its own PID and sleeps; the command is killed exactly as the
executors kill it (TERM to the process, SIGKILL 400 ms later); "orphaned" means the hook's PID is
still alive afterwards.

| Command | Child | Orphaned | `index.lock` left |
|---|---|---|---|
| the commit-message preview script (0068's) | `prepare-commit-msg` | **yes** | — |
| `git commit` | `pre-commit` | **yes** | no |
| `git commit` | `prepare-commit-msg` | **yes** | no |

`git` removes its own lockfile when it receives `SIGTERM`, so a timed-out commit does not break the
next one. What it does not do is stop the hook it is waiting on.

## Why it matters here

The maintainer's `prepare-commit-msg` hook calls an AI provider, with a 90-second timeout and three
retries. A commit the app times out therefore leaves that hook running for up to ~4.5 minutes,
still calling the provider, after the user has been told the commit failed — and a second attempt
starts a second one alongside it.

## Not measured

* **The SSH side.** Whether the remote `sshd` acts on an SSH `signal` request at all, and what
  closing the channel does to the command's process group on the remote host, were not tested.
  The local results above do not transfer automatically. A probe on the remote host — the same
  stub hook, driven through the app's own SSH executor rather than a local `Popen` — would settle
  it.
* **Other children.** `git fetch`/`push` start a transport (`ssh`, `git-remote-https`) and may
  start a credential helper; neither was measured.

## What a fix would have to cover

Not decided here. The preview is fixed in 0068 by running the hook in the background under `wait`
with an EXIT trap that stops it — the shell can do that because it owns the script. For arbitrary
commands the executors would have to signal the process group: locally by starting each command
in its own group and signalling the negative PID; over SSH by wrapping each remote command so that
it runs as a group leader and forwards the signal, since the SSH protocol offers no group signal.
That touches every command the app runs, which is why it is filed rather than folded into 0068.
