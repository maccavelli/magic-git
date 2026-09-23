# devenv — a read-only developer-environment probe

Answers "do my machines really have the same toolchain?" with evidence instead of memory.
One Python file inventories a machine; a runner collects it from several; an analyzer puts
them side by side.

| File | What it does |
| :--- | :--- |
| `devenv_probe.py` | Inventories one machine and prints a JSON document. Standard library only, Python 3.9 or newer, on Windows, WSL, Linux and macOS. |
| `devenv_snapshot.py` | Fingerprints every shell-init, history and environment file the probe could conceivably disturb, and on Windows the registry environment too. |
| `run_probe.py` | Runs snapshot, probe, snapshot on each target and flags any fingerprint that changed. |
| `analyze.py` | Compares the collected documents and writes `report.txt`. |

## Running it

```sh
python3 scripts/tools/devenv/run_probe.py local ssh:<host-alias> wsl:<distro>
python3 scripts/tools/devenv/analyze.py --reference <label>
```

`ssh:<host-alias>` is a `Host` from your ssh config, and needs `python3` on the far side.
`wsl:<distro>` is a WSL distribution, from Windows. The label for `local` is `local`, for
`ssh:` the alias, and for `wsl:` `wsl-<distro>`.

Output goes to a per-user cache directory: `%LOCALAPPDATA%\devenv-probe` on Windows,
otherwise `$XDG_CACHE_HOME/devenv-probe` or `~/.cache/devenv-probe`. `--out` overrides it
for both scripts. **An output directory inside a git checkout is refused**: the documents
describe a real machine (paths, tool locations, repository names) and must never be
committed.

## What it records

- **Every environment a shell starts with**: login-interactive, login, interactive and the
  probe's own process. On Windows it records the registry's User and Machine values, the
  environment a fresh logon would get (`CreateEnvironmentBlock`), and Git Bash's login
  shell. PATH is listed in order, with missing and duplicate entries marked.
- **Shell init files, with their contents**. Secret-looking values are redacted. `source`
  and `.` lines are followed to the files they load, and symlinks show their targets.
- **Tools**: every copy of about 90 tools on PATH, in PATH order, so a shadowed copy is
  visible. The first copy's version is recorded.
- **Go**: `go env`, installs, toolchains in the module cache, and every binary in `GOBIN`
  and `~/go/bin` with the module version and the Go that built it.
- **mise, JDKs, Flutter (read from files), Android SDK packages**, Homebrew, apt, scoop,
  choco, npm, pipx, uv, cargo, git global config and hooks, agent rule files, and the
  repositories under `~/gitrepos`.

## Why it is safe to run on a machine you care about

- The probe writes no files. Its output goes to stdout. A remote host gets both scripts on
  stdin, so nothing is copied there.
- Shells are started the way a terminal starts them, so your init files run. History is
  disabled before exit (`set +o history; unset HISTFILE`), so no history file is
  rewritten.
- Go runs with `GOTOOLCHAIN=local`, so it cannot download a toolchain. Flutter and Dart
  are never executed, because running them can self-update. Agent CLIs are located but
  never run, because they write state files on start. Homebrew runs with
  `HOMEBREW_NO_AUTO_UPDATE=1`, and git only reads config and refs, with optional locks
  off.
- A tool asked for its version may still refresh its own cache. That is why the runner
  fingerprints the files that matter before and after, and prints `UNCHANGED` or
  `CHANGED: <files>`. It shows the fingerprint can detect a change before trusting it.
