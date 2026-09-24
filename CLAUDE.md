# CLAUDE.md

Instructions for AI coding agents working in this repository — the same rules
apply to every agent (Claude Code, Antigravity, Codex, Goose, Grok, OpenCode).
**`CLAUDE.md` is the canonical file**, and Claude Code reads it directly.
`AGENTS.md` (read by Codex, OpenCode, Antigravity and Grok) and `.goosehints`
are symlinks to it. Edit only `CLAUDE.md`.

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
- **`macos/Runner/Release.entitlements` is never modified by any build.** It
  always contains `com.apple.security.app-sandbox` and
  `keychain-access-groups`, and no script strips or restores it — that pattern
  shipped stripped to git three times and separately broke a build on another
  machine ("Entitlements file … was modified during the build"), and was
  removed in MADR 0042. `build_macos.sh --unsigned` instead selects a second
  tracked file, `Release-unsigned.entitlements` (the same document minus
  exactly those two keys), via an xcconfig variable
  (`Configs/Local.xcconfig`, gitignored, rewritten on every run). If `git diff`
  ever shows `Release.entitlements` with keys missing, that is a direct edit —
  `git checkout -- macos/Runner/Release.entitlements` and look at what changed
  it; `test/macos_entitlements_canon_test.dart` enforces both files and their
  relationship, and should fail before you ever see this in a diff.
  Debug and Profile follow the same pattern (MADR 0053 Amendment 0053.2):
  `DebugProfile.entitlements` is never edited either, and its tracked twin
  `DebugProfile-unsigned.entitlements` (minus only `keychain-access-groups`;
  it stays sandboxed) is selected by `MG_DEBUG_ENTITLEMENTS`, which
  `AppInfo.xcconfig` defaults to the signed file. Pass
  `MG_DEBUG_ENTITLEMENTS=Runner/DebugProfile-unsigned.entitlements` to
  `xcodebuild test` to run the `RunnerTests` Swift tests on a machine with no
  development team (see `docs/guides/build-macos.md`).
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

**The Flutter version is pinned, and it matters.** `build_macos.sh` sets
`FLUTTER_VERSION` (currently **3.47.2**) and that is the SDK the app ships on.
Flutter pins several transitive packages *exactly* — `test_api`, `matcher`,
`meta`, `vector_math` — so running a different `flutter` rewrites
`pubspec.lock` on every command and fails the 48 `workspace_golden_test.dart`
goldens on antialiasing alone. Two commits (`bd93c18`, `21721ef`) are that
churn, and a whole audit baseline was recorded wrong because of it. Check
before you start, and make it agree:

```sh
flutter --version | head -1          # must match FLUTTER_VERSION in build_macos.sh
flutter pub get --enforce-lockfile   # must say "Got dependencies!", not "Unable to satisfy"
```

If they disagree, use the pinned SDK (`./.flutter-sdk/bin/flutter`, which
`build_macos.sh` fetches) rather than whatever is on `$PATH`.

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

**Build the .app** (macOS only, needs Xcode — plugins link through Swift
Package Manager, so no CocoaPods; script vendors a
pinned Flutter SDK into gitignored `./.flutter-sdk`). A plain
`flutter build macos` fails on machines without a signing identity — always use
the script:

```sh
./build_macos.sh                      # signed (needs a Development Team in Xcode)
./build_macos.sh --unsigned           # no signing cert needed — the standard dev loop on this machine
./build_macos.sh --unsigned --install # also replaces ~/Applications/Magic Git.app
```

**Scripts.** `scripts/` holds one-off scripts (`scripts/generate_app_icons.sh`);
`scripts/tools/` holds reusable tooling: `mutate.py` and its `mutations/`
catalogues, `records.dart` (the docs checker), and `devenv/`, a read-only probe of a
developer machine's toolchains and shell environment (its README says how to run
it). Until 2026-09-23 the tooling lived in `tool/`, and older records cite those
paths. At the root, `./devenv.sh` bootstraps a Mac for development (`--check`
changes nothing), and `python3 dependencies.py` checks that the interpreter can
run every Python file in the repository. The development environment targets
Python 3.12 or newer, and the tooling uses only the standard library; the
`devenv/` probe alone keeps working on 3.9, for the machines it inspects.

## Decision records (MADR) and plans

**The layout is the global one** — see *MADR & PLAN file standards* in the
global agent rules, which is the authority. In short: `docs/decisions/` holds
`NNNN-MADR-*` and `NNNN-PLAN-*`, `docs/reports/` holds `NNNN-REPORT-*` and
`NNNN-GATES-*`, `docs/guides/` holds unnumbered user documentation, and
`docs/` itself holds only `README.md` and `architecture.md`. **A record never
sits directly in `docs/`.**

- **Decision record** (MADR format): `NNNN-MADR-short-kebab-title.md`
  (e.g. `0001-MADR-native-git-libgit2.md`)
- **Implementation plan**: `NNNN-PLAN-short-kebab-title.md`
  (e.g. `0001-PLAN-native-git-libgit2.md`)
- **Report** (an audit or investigation that decides nothing):
  `NNNN-REPORT-short-kebab-title.md`

Numbering rules:

- `NNNN` is a zero-padded 4-digit sequence number shared by every record type.
  **Allocate one with `dart run scripts/tools/records.dart next`**, which scans the
  **whole repository** for `NNNN-MADR-*`, `NNNN-PLAN-*`, `NNNN-REPORT-*` and
  `NNNN-GATES-*` and adds 1 to the highest. Never scan a single directory by
  hand — the sequence is repository-wide and does not restart per directory.
- **A plan or a report written for an existing MADR reuses that MADR's
  number** (so `0007-MADR-foo.md` pairs with `0007-PLAN-foo.md`); a lone plan
  matches the kebab-title too. A MADR may carry several plans where one
  decision is implemented as distinct units of work — they share its number
  and each takes a slug describing its own scope. A standalone plan or report
  with no associated MADR takes the next free number.
- Never renumber existing files, and never reuse a number except for that
  pairing. Two numbers (`0011`, `0012`) already carry unrelated records from
  before this rule was enforced; each notes its twin, and the rule stands —
  **cite records by full filename, never by number alone**, which one number
  naming a decision, its plans and a report about it makes unavoidable.
- `0005` carries a report that was filed under an older kind name,
  `0005-UX-BASELINE-…`. It kept its number when it was renamed to
  `0005-REPORT-ux-baseline-task-centered-adaptive-repository-workspace.md`
  (MADR 0054).

**The tree is checked, not just described.** `test/docs_records_test.dart` runs
`scripts/tools/records.dart` under `flutter test` and fails on: a relative link, anchor or
`docs/…` path mention that does not resolve; a second MADR on a number (0011 and
0012 excepted); a PLAN outside its MADR's directory; a record with no `status:`
or no `verified:`; anything in `docs/` other than the layout above; and a record with no row in
`docs/README.md`. `dart run scripts/tools/records.dart check` prints the same findings.
Fenced blocks, blockquotes and frontmatter are not searched for path mentions,
so a quotation stays verbatim — and a record that names a file which does not
exist *yet* writes it without the `docs/` prefix (MADR 0054).

Every record carries YAML frontmatter with a `status:` and a `verified:` date
(when the status was last checked *against the code*, not when it was
written). The vocabulary is the `madr-and-plan-writing` skill's, which follows
MADR 4.0.0:

- **Decisions (MADR):** `proposed` · `accepted` · `rejected` · `deprecated` ·
  `superseded by NNNN-MADR-…` (a decision is never rewritten; a later record
  supersedes it and says so).
- **Plans:** `proposed` (until the maintainer approves it) · `in-progress`
  (phases landing) · `complete` (**every** acceptance criterion met, including
  maintainer-only checks — not merely the last commit) · `superseded`. Plus
  `partial`: some of the work is real and the rest was deliberately never done;
  the body says which.
- **Reports:** `partial` or `complete`, by the same meanings.

`executed` is a retired value ("engineering phases shipped; the body names any
residual"). Every plan that carried it was mapped on 2026-09-19. Two older plans
still say `complete (amended)`: read it as `complete`. Wherever a status and the
body disagree, the body wins. [`docs/README.md`](docs/README.md) is the index and the one
place to see live state.

## Working style

- Root-cause fixes only: fix the underlying architecture or parsing problem and
  verify against real git behavior — no symptom guards, retries-as-bandaids, or
  special-casing around a bug you haven't understood.
- Analyze/test run on any platform; the `.app` builds only on a Mac.
- **Diagnosing a defect?** Read
  [`.claude/skills/troubleshooting-magic-git/SKILL.md`](.claude/skills/troubleshooting-magic-git/SKILL.md)
  first. It carries the reproduction-before-theory discipline this repository
  works by, the places errors actually surface in a release build, and the
  traps that have already cost real time here — per-tab provider containers,
  `ref` after an `await`, a `SizedBox` that bounds layout but not painting, and
  a `grep` that returns zero matches rather than an error.

## Architecture

[`docs/architecture.md`](docs/architecture.md) describes the system as it is
now and is the authority; this section is the short version agents need most.
`docs/decisions/0056-PLAN-architecture-and-feature-parity.md` (formerly
`ARCHITECTURE_PLAN.md`) is the original plan, kept as history — its §0.1
transport notes were carried into `architecture.md` where the code still
agrees.

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

- **No source file may contain a raw NUL byte**, and none does any more. One
  makes `grep`, `rg`, IDE search and GitHub's code view treat the whole file as
  binary, and they then report *zero matches* — silently, with no error to
  notice. Three files carried one (`app_providers.dart`,
  `git_porcelain_parser.dart`, `recent_repos_store.dart`); each now writes it as
  the escape `\u0000`, which compiles to the identical string at runtime.
  `test/source_is_text_scan_test.dart` enforces this, so searching this
  repository no longer needs `grep -a` — and if a search ever comes back
  suspiciously empty again, that test will already have said why.
- Exclude `.flutter-sdk/` (vendored full Flutter SDK, gitignored), `build/`,
  and `.dart_tool/` from repo-wide searches — they are huge and will drown out
  real matches.
