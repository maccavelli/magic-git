# Remote Magic Git

A Flutter/macOS desktop app for managing **remote** Git repositories over SSH — without cloning locally. It drives remote `git` and `glab` on POSIX hosts (Linux/macOS/BSD) and renders working-tree status, history, branches, and GitLab MR/CI data in a native macOS UI.

## Features

- SSH transport with serialized git commands and multiplexed streaming channels
- Working-tree status (porcelain v2), diffs, commits, branches, stashes, conflicts
- Real-time refresh via remote `fswatch`/`inotifywait` (polling fallback)
- GitLab: merge requests, pipelines, live CI traces, project dashboard (GraphQL)
- Saved connection profiles (Keychain secrets + metadata)

## Requirements

- **Build:** macOS with Xcode (see [docs/BUILD_MACOS.md](docs/BUILD_MACOS.md))
- **Remote:** POSIX shell, `git` 2.x, `glab` 1.x, optional `fswatch` or `inotifywait`

## Development (Linux/macOS)

```sh
cd scripts/dart/remote-magic-git
flutter pub get
flutter analyze
flutter test
```

Analyze and unit tests run on Linux; the `.app` must be built on a Mac.

## Architecture

See [docs/ARCHITECTURE_PLAN.md](docs/ARCHITECTURE_PLAN.md) and [docs/ACTION_PLAN.md](docs/ACTION_PLAN.md).