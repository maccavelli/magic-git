# Magic Git

A Flutter/macOS desktop Git client that manages repositories **without a
working-tree clone**. It drives `git` / `glab` / `gh` on a host — a remote
POSIX machine over SSH, or this Mac via `Process.start` — and renders status,
history, diffs, branches, and GitHub/GitLab forge data (PRs/MRs, pipelines,
live CI traces) in a native macOS UI.

macOS is the only target platform.

## Features

- Remote (SSH) and local backends behind one `CommandExecutor` seam
- Working-tree status (porcelain v2), diffs, commits, branches, stashes, conflicts
- Real-time refresh via remote `fswatch`/`inotifywait` or local `Directory.watch`
- GitHub and GitLab: pull/merge requests, issues, pipelines, live CI traces
- Saved connection profiles (Keychain secrets; unsigned builds fall back to a `0600` dotfile)

## Requirements

- **Build:** macOS with Xcode (see [docs/BUILD_MACOS.md](docs/BUILD_MACOS.md))
- **Remote host:** POSIX shell, `git` 2.x, `glab`/`gh` as needed, optional `fswatch` or `inotifywait`

## Development

```sh
flutter pub get
flutter analyze
flutter test
```

Analyze and unit tests run on any platform. The `.app` is built on a Mac via
[`./build_macos.sh`](build_macos.sh) (use `--unsigned` if no Apple signing
certificate is configured).

## Architecture

See [docs/ARCHITECTURE_PLAN.md](docs/ARCHITECTURE_PLAN.md). Instructions for
coding agents live in [AGENTS.md](AGENTS.md).
