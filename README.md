# Magic Git

Magic Git is a native macOS Git client for repositories that live **on a remote
host** as well as on your Mac. It drives `git`, `gh` and `glab` where the
repository is:

- **Over SSH** on a macOS or Linux host, or a Windows host with Git Bash as its
  SSH shell. The repository stays on the host, with no local clone, and Magic
  Git runs every command there.
- **On this Mac**, for repositories in a local folder.

Both give you the same screens: status, history, diffs, branches, stashes,
worktrees, and GitHub/GitLab pull or merge requests, issues and CI.

The app itself runs on macOS only.

## Features

- **Sessions and tabs.** Several repositories open at once in File tabs, saved
  as named workspaces. The Workspaces panel holds saved SSH hosts and local
  repositories, and supports scoped "dotfiles" repositories (a separate
  `GIT_DIR` and work tree). An SSH repository path may start with `~`. Dropped
  SSH sessions reconnect automatically. Clone a repository, or create one
  together with its GitHub or GitLab project.
- **Repository.** Stage files, hunks or single lines; resolve conflicts; review
  many files at once. Commit from a focused sheet or a docked composer, with
  co-authors, templates and hook-generated messages. A push continues in the
  background.
- **Sync.** Fetch, pull (fast-forward, rebase or merge), push, sync and force
  push, with live progress, guardrails before a rejected or forced push, and
  background auto-fetch.
- **History.** A commit graph with filters, cherry-pick, revert, reset, tags,
  interactive rebase (pick, squash, fixup, drop, reorder), and a pop-out History
  window.
- **Branches.** Browse and Review modes, comparison with a base branch, bulk
  actions, and tags. Guided recovery for out-of-sync branches: Publish,
  Reconcile (merge, rebase or reset) and stale-branch cleanup.
- **Stashes and worktrees.** Stash with untracked files; apply, pop and branch
  from stashes. Add, lock, move, repair and prune worktrees, and open any
  worktree in its own window.
- **Forge.** A GitHub and GitLab inbox, including self-hosted GitLab. Create,
  review, approve and merge pull or merge requests; create and work on issues;
  follow CI runs and pipelines, with live GitLab job logs.
- **Windows hosts.** When you connect, Magic Git checks that Git Bash is the
  OpenSSH default shell, and offers to set it. That needs an administrator
  account, and the setting applies to the whole machine. Status, history and
  diffs are verified on a real Windows host. Paths are shown as git prints them,
  `C:/…`, whichever form you type, tabs name the folder, and text that starts
  with `/` reaches git as typed. Live refresh polls.
- **Safety.** ⌘Z undoes the last git operation and ⇧⌘Z redoes it. A Recovery
  view reaches the reflog and the snapshots taken before destructive operations
  such as discard, reset, revert and stash pop.
- **Everywhere.** A command palette (⌘K), remappable shortcuts, drag and drop,
  a file viewer that edits remote files in your editor, a live command Output
  log, a Dashboard, and a Tool Health check that installs missing tools on macOS
  and Linux hosts (Windows hosts get the commands to run).

## Requirements

**To run:** macOS 12 or later.

**On the machine where a repository lives** — this Mac, or the SSH host:

| Tool | Needed for | Minimum |
|---|---|---|
| `git` | everything | 2.24 |
| `gh` | GitHub features | 2.0 |
| `glab` | GitLab features | — |
| `fswatch` (macOS SSH hosts) or `inotifywait` (Linux SSH hosts) | live refresh over SSH; without one, Magic Git polls. Repositories on this Mac use macOS file events. | optional |
| Git for Windows (Git Bash) | Windows SSH hosts: the OpenSSH default shell | — |

Sign the forge CLIs in on that machine: `gh auth login`, and `glab auth login`
(add `--hostname <host>` for self-hosted GitLab). You can also put a token on a
saved SSH connection. SSH hosts must run commands through a POSIX shell. On
Windows that means OpenSSH Server with Git Bash as its default shell. Magic Git
offers to set it (Help ▸ Support & Help ▸ Windows Hosts).

## Install

Build the app from source on a Mac with Xcode installed:

```sh
./build_macos.sh --unsigned --install
open ~/Applications/Magic\ Git.app
```

`--unsigned` needs no Apple signing certificate. Saved credentials then live in
`~/.config/magic_git/credentials.json` (`0600`) instead of the Keychain. See
[docs/guides/build-macos.md](docs/guides/build-macos.md) for signed builds, notarization, and
troubleshooting.

## Getting help

Inside the app:

- **Help ▸ Support & Help (⌘?)** — the searchable user guide: every panel,
  workflow and menu item, plus a Troubleshooting section.
- **⌘/** — your current keyboard shortcuts, including any remaps.
- **⌘K** — the command palette.

## Development

First-time setup on a Mac:

```sh
./devenv.sh            # checks the toolchain and installs what is missing
./devenv.sh --check    # report only; changes nothing
python3 dependencies.py  # checks the Python the repository's scripts run on
```

`devenv.sh` checks Xcode, git, Flutter at the pinned version and
Python 3.12 or newer. It installs what it can with Homebrew, vendors Flutter
into `./.flutter-sdk` when the one on your `PATH` is not the pin, and fetches the
Dart packages. Steps that need `sudo`, such as accepting the Xcode licence, are
printed for you to run. `--optional` also installs `gh` and `glab`.

The Flutter version is pinned: `FLUTTER_VERSION` in `build_macos.sh`
(currently **3.47.2**). A different SDK rewrites `pubspec.lock` and fails the
golden tests, so check before you start:

```sh
flutter --version | head -1          # must match FLUTTER_VERSION
flutter pub get --enforce-lockfile   # must say "Got dependencies!"
flutter analyze                      # strict analyzer settings
flutter test                         # full suite; takes a few minutes
```

If your `flutter` differs, use `./.flutter-sdk/bin/flutter`, which
`build_macos.sh` fetches.

- Analyze and tests run on any platform; the `.app` builds only on a Mac.
- Tests tagged `live-forge` create and delete **real** GitLab projects, and make
  read-only calls to GitHub. They are skipped by default; never run them
  without meaning to.
- Tooling lives in `scripts/tools/`. `records.dart` checks the docs tree
  (`flutter test` runs it), and `dart run scripts/tools/records.dart next` gives
  a new record its number. `mutate.py` proves a test can fail, and `devenv/`
  inventories a machine's toolchains (see its README). The Python tooling uses
  only the standard library.
- The native Swift tests run through Xcode. See
  [docs/guides/build-macos.md](docs/guides/build-macos.md#running-the-xcode-unit-tests-without-a-certificate).

## Documentation

- [docs/README.md](docs/README.md) — the index of decision records (MADRs),
  plans and reports, with their current status.
- [docs/architecture.md](docs/architecture.md) — how the app is built, as it is now:
  the executors, the SSH transport, scheduling, watching and state.
- [docs/guides/build-macos.md](docs/guides/build-macos.md) — building, signing, installing.
- [CLAUDE.md](CLAUDE.md) — instructions for coding agents working in this
  repository.
