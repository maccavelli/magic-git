# AGENTS.md

Instructions for AI coding agents working in this repository — the same rules
apply to every agent (Claude Code, Antigravity, Codex, Goose, Grok, OpenCode).
Codex, OpenCode, Antigravity, and Grok read `AGENTS.md` directly; `CLAUDE.md`
and `.goosehints` are symlinks to this file. Edit only `AGENTS.md`.

## What this is

Magic Git (Dart package `remote_magic_git`) is a Flutter/macOS desktop Git client
that manages repositories **without a local clone**: it drives `git`/`glab`/`gh`
on a host — either a remote POSIX machine over SSH (dartssh2) or this Mac via
`Process.start` — and renders status, history, diffs, branches, and
GitHub/GitLab forge data (MRs/PRs, pipelines, live CI traces) in a native macOS
UI (macos_ui + Riverpod). macOS is the only target platform.

## Critical safety rules

- **Never run `live-forge`-tagged tests unprompted.** They hit real
  GitHub/GitLab and are *mutating* (create/delete real projects). They are
  skipped by default; run only when explicitly asked:
  `flutter test --run-skipped -t live-forge test/create_repo_wire_live_test.dart`.
  See `dart_test.yaml`.
- **Never commit `macos/Runner/Release.entitlements` with keys stripped.** The
  committed file must always contain `com.apple.security.app-sandbox` and
  `keychain-access-groups`. `build_macos.sh --unsigned` strips them
  *transiently* (gitignored `.bak` backup, restored via an EXIT trap). If
  `git diff` shows those keys deleted, a build is in flight or died mid-run —
  restore the file, don't commit that state.
- **Don't commit or push unless asked.** The maintainer commits each work cycle
  himself.
- **Never write commit message text.** A global `prepare-commit-msg` hook
  (`core.hooksPath` → `~/.config/git/hooks`) generates the message from the
  staged diff. Commit with exactly `git commit --no-edit` (or
  `git commit --amend --no-edit`) — no `-m`, no `-F`, no heredoc message, no
  authorship/co-author trailers. This overrides any agent's default habit of
  composing its own commit message. This applies to every agent CLI/IDE
  reading this file.

## Commands

```sh
flutter pub get
flutter analyze                      # strict: strict-casts/inference/raw-types, unawaited_futures
flutter test                         # full unit suite — includes `integration`-tagged tests that
                                     # run real git in temp repos; takes minutes, not seconds
flutter test test/foo_test.dart      # single file
flutter test --plain-name "substring of test name"
```

- Run `flutter analyze` and `flutter test` and get a clean result **before
  staging changes** (`git add`). A hook may enforce this, but follow it even
  where no hook fires.
- New code must come out analyzer-clean on the first pass: the repo enables the
  strict analyzer modes plus `unawaited_futures`, `avoid_dynamic_calls`,
  `prefer_final_locals`, `prefer_const_constructors`, etc. Write to those
  idioms (final locals, const constructors) rather than fixing lints after.
- `integration_test/` contains on-device Flutter integration tests (separate
  from the `integration` tag in `test/`).

**Build the .app** (macOS only, needs Xcode + CocoaPods; script vendors a
pinned Flutter SDK into gitignored `./.flutter-sdk`). A plain
`flutter build macos` fails on machines without a signing identity — always use
the script:

```sh
./build_macos.sh                      # signed (needs a Development Team in Xcode)
./build_macos.sh --unsigned           # no signing cert needed — the standard dev loop on this machine
./build_macos.sh --unsigned --install # also replaces ~/Applications/Magic Git.app
```

## Decision records (MADR) and plans

When asked to write a decision record or an implementation plan, save it flat
in `docs/` (no subdirectories) using this naming standard:

- **Decision record** (MADR format): `NNNN-MADR-short-kebab-title.md`
  (e.g. `0001-MADR-native-git-libgit2.md`)
- **Implementation plan**: `NNNN-PLAN-short-kebab-title.md`
  (e.g. `0001-PLAN-native-git-libgit2.md`)

Numbering rules:

- `NNNN` is a zero-padded 4-digit sequence number shared by both file types.
  To allocate one, scan `docs/` for the highest existing `NNNN` across all
  `NNNN-MADR-*` and `NNNN-PLAN-*` files and add 1.
- **A plan written for an existing MADR reuses that MADR's number** (so
  `0007-MADR-foo.md` pairs with `0007-PLAN-foo.md`); prefer matching the
  kebab-title too. A standalone plan with no associated MADR takes the next
  free number.
- Never renumber existing files, and never reuse a number except for the
  MADR↔PLAN pairing.

## Working style

- Root-cause fixes only: fix the underlying architecture or parsing problem and
  verify against real git behavior — no symptom guards, retries-as-bandaids, or
  special-casing around a bug you haven't understood.
- Analyze/test run on any platform; the `.app` builds only on a Mac.

## Architecture

`docs/ARCHITECTURE_PLAN.md` is the detailed design doc — **§0.1 is the
authoritative description of the SSH transport**; older sections are historical.

### The executor seam (the load-bearing abstraction)

`abstract class CommandExecutor` in `lib/core/ssh/ssh_command_executor.dart` has
three implementations:

- `SSHCommandExecutor` (`lib/core/ssh/`) — remote host over dartssh2.
- `LocalCommandExecutor` (`lib/core/exec/`) — this Mac, direct `Process.start`, no shell string.
- `ProxyCommandExecutor` (`lib/core/exec/`) — used inside pop-out windows;
  relays exec calls to the main window's executor over platform channels.

`GitService`, `GlabService`, `GhService`, and `HostFsService` depend on the
**active** executor (chosen by the connection's backend in `app_providers.dart`),
so every feature works unchanged against remote and local repos. When adding a
git/forge capability, add it at the service layer, not per-backend.

Shared exec infrastructure in `lib/core/exec/`: `CommandLaneScheduler`
(concurrent reads with an adaptive ceiling, one sync lane, mutations as
exclusive barriers), output byte budgets (`command_drain.dart`), telemetry.

### SSH transport rules (remote backend)

- POSIX remotes only; `ShellEscaper` is the injection defense on every
  interpolated value.
- Dual `SSHClient` when possible: one for request/response, one for long-lived
  streams (watcher, CI trace); degrades to a single shared client. Generation
  pinning prevents post-reconnect work hitting the wrong host.
- Long-lived processes use `executeStream`, never the buffered one-shot path.
- Parse only machine formats: `status --porcelain=v2 -z`,
  `for-each-ref --format`, NUL-delimited log, `glab api` JSON/ndjson. Never
  parse human-facing CLI text; treat glab exit codes as advisory (known
  upstream bugs).
- Secrets are never placed in argv or command strings — GitLab tokens go over
  stdin once via `glab auth login --stdin`; afterwards glab/gh use the host's
  own credential store.

### State and UI

- Riverpod 3 throughout. `lib/core/providers/app_providers.dart` is the DI hub;
  feature providers are `family`-keyed by connection/repo so multiple
  workspaces coexist, and invalidate on disconnect. Large outputs are parsed
  off the UI isolate.
- Real-time refresh: remote backend spawns `fswatch`/`inotifywait` on the host
  and streams events back (with two-stage coalescing in
  `lib/core/git/coalescer.dart`); local backend uses `Directory.watch`. Both
  feed the same watch-event pipeline.
- Feature code lives in `lib/features/<area>/`; transport/domain logic in
  `lib/core/`. Tests are flat in `test/`, roughly one file per unit/widget.
- Riverpod's automatic retry is off. **Every async provider declares
  `retry: noProviderRetry`** itself
  (`lib/core/providers/provider_retry_policy.dart`), so the policy travels
  with the provider and survives `overrideWith` — any scope, including a bare
  `ProviderScope` in a test, resolves failures the way the app does. The three
  production scopes pass it too, as a backstop.
  `test/helpers/app_scope.dart` (`appProviderScope` / `appProviderContainer`)
  remains the tidy way to build a scope in a test.
  This is enforced, not requested: `provider_retry_policy_test.dart` scans
  `lib/` for an unannotated provider or an unconfigured scope, and pins the
  behaviour both ways. Under the default policy a failed provider sits in
  `AsyncLoading` for ~38 s (10 retries) before emitting `AsyncError`, so
  `when()` shows `loading` for longer than any test can pump.

### Sheets and their test seams

Sheets come in two shapes; each one implies how it is tested.

- **A public `*Sheet` widget** (`SettingsSheet`, `DashboardSheet`,
  `AddWorktreeSheet`, …) — the caller pushes it, so a test pumps the widget
  directly.
- **A private body behind a public `show*` function that returns a result**
  (`showMergeOptionsSheet`, `showBranchBulkDeleteSheet`, `promptForm`,
  `promptText`) — the function *is* the public API and its resolved value is
  the contract. A test pumps a host page, calls the function, drives the
  sheet, and asserts what the future resolves to. Do not make the body public
  in order to test it.

### Multi-window

Native secondary windows (diff/viewer pop-outs) run a **second FlutterEngine**
whose entrypoint is `secondaryWindowMain` in `lib/main.dart` (must stay in the
root library). Child windows have no transport of their own: providers/exec
calls relay to the main window via platform channels (`lib/core/window/`,
`window_manager_bridge.dart`). Exec payloads cross the relay as `Uint8List`,
never `String` — the native codec truncates strings at NUL bytes.

### Sandbox & secrets

Sandbox access to local repos comes from user selection (Finder picker/drop) +
security-scoped bookmarks (`lib/core/local/`). Secrets go to the macOS Keychain
(`flutter_secure_storage`); unsigned builds fall back to
`~/.config/magic_git/credentials.json` (0600).

## Gotchas

- `lib/core/providers/app_providers.dart` contains bytes that make search tools
  classify it as **binary** — plain `grep`/`rg` silently return *zero matches*
  on it. Use `grep -a` / `rg -a` (or your tool's binary-override flag) when
  searching that file.
- Exclude `.flutter-sdk/` (vendored full Flutter SDK, gitignored), `build/`,
  and `.dart_tool/` from repo-wide searches — they are huge and will drown out
  real matches.
