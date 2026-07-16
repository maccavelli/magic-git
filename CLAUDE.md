# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Magic Git (Dart package `remote_magic_git`) is a Flutter/macOS desktop Git client that manages repositories **without a local clone**: it drives `git`/`glab`/`gh` on a host — either a remote POSIX machine over SSH (dartssh2) or this Mac via `Process.start` — and renders status, history, diffs, branches, and GitHub/GitLab forge data (MRs/PRs, pipelines, live CI traces) in a native macOS UI (macos_ui + Riverpod). macOS is the only target platform.

## Commands

```sh
flutter pub get
flutter analyze                      # strict: strict-casts/inference/raw-types, unawaited_futures
flutter test                         # full unit suite (includes `integration`-tagged tests that run real git in temp repos)
flutter test test/foo_test.dart      # single file
flutter test --plain-name "substring of test name"
```

- **`live-forge`-tagged tests are skipped by default** — they hit real GitHub/GitLab (mutating: create/delete real projects). Run explicitly only when asked: `flutter test --run-skipped -t live-forge test/create_repo_wire_live_test.dart`. See `dart_test.yaml`.
- `integration_test/` contains on-device Flutter integration tests (separate from the `integration` tag in `test/`).

**Build the .app** (macOS only, needs Xcode + CocoaPods; script vendors a pinned Flutter SDK into gitignored `./.flutter-sdk`):

```sh
./build_macos.sh                      # signed (needs a Development Team in Xcode)
./build_macos.sh --unsigned           # no signing cert needed — the standard dev loop on this machine
./build_macos.sh --unsigned --install # also replaces ~/Applications/Magic Git.app
```

## Architecture

`docs/ARCHITECTURE_PLAN.md` is the detailed design doc — **§0.1 is the authoritative description of the SSH transport**; older sections are historical.

### The executor seam (the load-bearing abstraction)

`abstract class CommandExecutor` in `lib/core/ssh/ssh_command_executor.dart` has three implementations:

- `SSHCommandExecutor` (`lib/core/ssh/`) — remote host over dartssh2.
- `LocalCommandExecutor` (`lib/core/exec/`) — this Mac, direct `Process.start`, no shell string.
- `ProxyCommandExecutor` (`lib/core/exec/`) — used inside pop-out windows; relays exec calls to the main window's executor over platform channels.

`GitService`, `GlabService`, `GhService`, and `HostFsService` depend on the **active** executor (chosen by the connection's backend in `app_providers.dart`), so every feature works unchanged against remote and local repos. When adding a git/forge capability, add it at the service layer, not per-backend.

Shared exec infrastructure in `lib/core/exec/`: `CommandLaneScheduler` (concurrent reads with an adaptive ceiling, one sync lane, mutations as exclusive barriers), output byte budgets (`command_drain.dart`), telemetry.

### SSH transport rules (remote backend)

- POSIX remotes only; `ShellEscaper` is the injection defense on every interpolated value.
- Dual `SSHClient` when possible: one for request/response, one for long-lived streams (watcher, CI trace); degrades to a single shared client. Generation pinning prevents post-reconnect work hitting the wrong host.
- Long-lived processes use `executeStream`, never the buffered one-shot path.
- Parse only machine formats: `status --porcelain=v2 -z`, `for-each-ref --format`, NUL-delimited log, `glab api` JSON/ndjson. Never parse human-facing CLI text; treat glab exit codes as advisory (known upstream bugs).
- Secrets are never placed in argv or command strings — GitLab tokens go over stdin once via `glab auth login --stdin`; afterwards glab/gh use the host's own credential store.

### State and UI

- Riverpod 3 throughout. `lib/core/providers/app_providers.dart` is the DI hub; feature providers are `family`-keyed by connection/repo so multiple workspaces coexist, and invalidate on disconnect. Large outputs are parsed off the UI isolate.
- Real-time refresh: remote backend spawns `fswatch`/`inotifywait` on the host and streams events back (with two-stage coalescing in `lib/core/git/coalescer.dart`); local backend uses `Directory.watch`. Both feed the same watch-event pipeline.
- Feature code lives in `lib/features/<area>/`; transport/domain logic in `lib/core/`. Tests are flat in `test/`, roughly one file per unit/widget.

### Multi-window

Native secondary windows (diff/viewer pop-outs) run a **second FlutterEngine** whose entrypoint is `secondaryWindowMain` in `lib/main.dart` (must stay in the root library). Child windows have no transport of their own: providers/exec calls relay to the main window via platform channels (`lib/core/window/`, `window_manager_bridge.dart`). Exec payloads cross the relay as `Uint8List`, never `String` — the native codec truncates strings at NUL bytes.

### Sandbox & entitlements

The committed `macos/Runner/Release.entitlements` must always contain `com.apple.security.app-sandbox` and `keychain-access-groups`. `build_macos.sh --unsigned` strips them **transiently** (backs up to a gitignored `.bak`, restores via an EXIT trap). If the file ever shows those keys deleted in `git diff`, a build is in flight or died mid-run — never commit that state. Sandbox access to local repos comes from user selection (Finder picker/drop) + security-scoped bookmarks (`lib/core/local/`).

Secrets go to the macOS Keychain (`flutter_secure_storage`); unsigned builds fall back to `~/.config/magic_git/credentials.json` (0600).

## Gotchas

- `lib/core/providers/app_providers.dart` contains bytes that make grep classify it as binary — plain `grep` silently returns nothing on it. Use `grep -a` (Grep tool: pass `-a`).
- A plain `flutter build macos` fails on machines without a signing identity; use `build_macos.sh --unsigned`.
