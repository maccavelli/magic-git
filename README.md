# Magic Git

Magic Git is a native macOS Git client for repositories that live **on a remote
host** as well as on your Mac. It drives `git`, `gh` and `glab` where the
repository is:

- **Over SSH** on a remote POSIX machine. The repository stays on the host, with
  no local clone, and Magic Git runs every command there.
- **On this Mac**, for repositories in a local folder.

Both give you the same screens: status, history, diffs, branches, stashes,
worktrees, and GitHub/GitLab pull or merge requests, issues and CI.

macOS is the only target platform.

## Features

- **Sessions and tabs.** Several repositories open at once in File tabs, saved
  as named workspaces. There is a Connections Manager for saved SSH hosts and
  local repositories, and support for scoped "dotfiles" repositories (a separate
  `GIT_DIR` and work tree). Dropped SSH sessions reconnect automatically.
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
- **Safety.** ⌘Z undoes the last git operation, and a Recovery view reaches the
  reflog and automatic snapshots taken before every discard.
- **Everywhere.** A command palette (⌘K), remappable shortcuts, drag and drop,
  a file viewer that edits remote files in your editor, a live command Output
  log, a Dashboard, and a Tool Health doctor that installs missing tools on the
  host.

## Requirements

**To run:** macOS 12 or later.

**On the machine where a repository lives** — this Mac, or the SSH host:

| Tool | Needed for | Minimum |
|---|---|---|
| `git` | everything | 2.24 |
| `gh` | GitHub features | 2.0 |
| `glab` | GitLab features | — |
| `fswatch` (macOS hosts) or `inotifywait` (Linux hosts) | live refresh; without one, Magic Git polls | optional |

Sign the forge CLIs in on that machine: `gh auth login`, and `glab auth login`
(add `--hostname <host>` for self-hosted GitLab). You can also put a token on a
saved SSH connection. SSH hosts must offer a POSIX shell.

## Install

Build the app from source on a Mac with Xcode and CocoaPods installed:

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
- Tests tagged `live-forge` create and delete **real** GitHub and GitLab
  projects. They are skipped by default; never run them without meaning to.
- The native Swift tests run through Xcode. See
  [docs/guides/build-macos.md](docs/guides/build-macos.md#running-the-xcode-unit-tests-without-a-certificate).

## Documentation

- [docs/README.md](docs/README.md) — the index of decision records (MADRs),
  plans and reports, with their current status.
- [docs/architecture.md](docs/architecture.md) — how the app is built, as it is now:
  the executors, the SSH transport, scheduling, watching and state.
- [docs/guides/build-macos.md](docs/guides/build-macos.md) — building, signing, installing.
- [AGENTS.md](AGENTS.md) — instructions for coding agents working in this
  repository.
