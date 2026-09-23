---
status: "complete"
date: 2026-09-22
verified: 2026-09-22
---

# Commit-message preview and composer: three findings

Three things surfaced on 2026-09-22 while investigating a report that the app "spun" on commit
and then presented the manual-edit screen. **The report itself was not an app defect** — the
maintainer's `prepare-commit-msg` hook exhausted its own retries, and switching the model it
calls made commits fast again (Finding 3) — but the investigation left two small defects in this
app. Nothing here is decided: each finding states what was measured, what was not, and what a fix
would have to cover.

Host-specific paths are written `<repo>`; the remote host is `<bastion>`.

## Finding 1 — a cancelled or timed-out preview leaks its scratch file

**What happens.** `GitService.generateCommitMessage`
(`lib/core/git/git_service.dart:3264-3305`) previews the hook's message by running a small shell
script on the host:

```
tmp=$(mktemp "$dir/MAGICGIT_MSG_PREVIEW.XXXXXX") || exit 1
"$hook" "$tmp" </dev/null >/dev/null 2>&1 || true
sed -e /^#/d "$tmp"
rm -f "$tmp"
```

The `rm -f` is the last statement, so it runs only if the script runs to completion. The call
carries the 5-minute commit timeout, and the executor's timeout path kills the channel and its
process (`lib/core/ssh/ssh_command_executor.dart:542`) — the shell never reaches the `rm`.

**Evidence.** After the maintainer's slow-hook attempts, the fixture repository on `<bastion>`
held five `MAGICGIT_MSG_PREVIEW.*` files (timestamps 10:58, 11:00, 11:08…); four remain as this
is written. Each is 0 bytes, owner-only, in the repository's git dir.

**What a fix has to cover.** The cleanup must survive the process being killed, so it belongs in
a `trap` (`trap 'rm -f "$tmp"' EXIT INT TERM`) rather than a trailing statement — the process is
killed, so an EXIT trap fires where a statement does not. A sweep of stale
`MAGICGIT_MSG_PREVIEW.*` files older than some age would also close the window left by a SIGKILL,
which no trap catches. Neither is written here.

**Impact.** Cosmetic litter in `.git/`, not data loss: the files are empty and are never read
back. `git status` ignores them (they are inside the git dir).

## Finding 2 — the composer's spinner runs while a commit waits, and the app's CPU rises

**What was measured.** While the commit composer was waiting on the hook, `ps -o %cpu` for the
app read ~58%. That figure is a **one-minute decaying average**, not an instantaneous one:
sampled with `top -l` after the wait ended, the same process read 0.0–2.9%.

**The mechanism, from the code.** `ProgressCircle` with no `value` is
`CupertinoActivityIndicator` (macos_ui 2.2.2, `progress_indicators.dart:93-96`), whose controller
`repeat()`s — an animation that never settles, so frames are produced for as long as it is on
screen. The composer shows one while a preview loads
(`lib/features/repository/commit_composer.dart:239`) and another while the commit runs (`:269`).
With a 5-minute timeout, "as long as it is on screen" can be five minutes.

**What was NOT established.** Whether that CPU is the spinner's own painting or a larger repaint
it forces was not isolated — no profile build was run against this state, and the number above
cannot separate them. A frame-spin probe of the kind used for
[0064-PLAN](../decisions/0064-PLAN-workspace-reachability-feedback-and-log-fidelity.md)
deviation D5 would settle it in one run. **Do not treat "the spinner costs 58% of a core" as a
measured fact.** What is certain: an indeterminate spinner produces continuous frames, and this
one can be on screen for minutes.

## Finding 3 — the hook itself stalled: provider-side, and now resolved

**The user-visible report.** Commit, the composer spun, it timed out, the manual-edit screen
appeared. Twice.

**What the host showed.** The hook is configured with `timeout_seconds: 90`, `retry_count: 3`,
`retry_delay_seconds: 3`, so a stalled provider call costs ~4.5 minutes before the hook gives up
— which is what the app then reports as a failed preview. One attempt was caught live: the hook
process sat in a Go futex wait (network) for over a minute before finishing. A later attempt from
the same app, same channel, same environment, finished in under 5 seconds.

**What was ruled out.** The app's invocation is the same one git makes (the identical script, the
hook alone, and a 900 KB staged diff all completed in 2–4 s, five for five); the environment the
hook receives is the maintainer's normal one; there is no proxy variable in play (only
`GONOPROXY`); no lock or lingering process was left behind; the app's isolated lane had a free
slot.

**What is left.** The variable never tested is the **actual staged diff** — the reproductions used
synthetic prose, the real attempt was the repository's own documentation changes, and that diff
was committed before it could be captured. To settle it, with the changes still staged:

```sh
cd <repo>
: > /tmp/mg-msg.txt
time ~/.global-git-hooks/prepare-commit-msg /tmp/mg-msg.txt   # stderr shows retries
cat /tmp/mg-msg.txt; rm /tmp/mg-msg.txt
```

90 s or more with a retry line means the provider is stalling on that content and the app is
waiting faithfully; ~3 s means the difference is inside the app's channel after all.

**Resolved (maintainer, 2026-09-22): provider-side.** Changing the default model in the
`prepare-commit-msg` binary's configuration made commits fast again. That fits every measurement
above — the app's invocation, the hook binary, the environment and the staged diff were all
constant across a call that stalled and a call that finished in five seconds, so the only
remaining variable was the model serving the request. **Nothing in this app needs to change for
this finding**, and the capture procedure above is kept only in case it recurs.

**Worth considering either way:** the app discards the hook's stderr (`>/dev/null 2>&1` in the
preview script), so the "generating via …" and retry lines never reach the Output view. Surfacing
them would have made this self-diagnosing.

## Also open, from the 0064 on-device gate

Neither is filed anywhere else, and neither blocks that gate, which passed.

* **A first click on an inactive window looked dropped** during executor-driven runs. Synthetic
  input is not evidence here (0064-PLAN, deviation D4), so this needs a real-mouse check before
  it is called a defect.
* **The compact back bar's capsule is centred**, where the rest of the compact chrome is
  left-aligned. Cosmetic.
