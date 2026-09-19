# Architecture

How Magic Git is built, as it is now. The *why* behind each part lives in the
[decision records](README.md); this page links them rather than repeating them. For how
the design got here, see
[0056-PLAN-architecture-and-feature-parity.md](decisions/0056-PLAN-architecture-and-feature-parity.md),
the original plan, kept as history.

## What it is

Magic Git (Dart package `remote_magic_git`) is a macOS-only Flutter desktop Git client.
It manages repositories **without a local clone**: it runs `git`, `glab` and `gh` on a
host and renders the results. The host is either a remote POSIX machine reached over SSH
or this Mac. The UI is `macos_ui` over Riverpod 3.

```
lib/
  main.dart        entrypoints: the main window and secondaryWindowMain
  core/            transport, domain and state — no widgets
    ssh/  exec/    the executors, scheduling, output budgets, telemetry
    git/  gitlab/  github/  forge/   services and parsers
    providers/     the Riverpod DI hub (app_providers.dart)
    local/  storage/  settings/  undo/  output/  window/  workspace/  …
  features/<area>/ widgets, one directory per area of the app
macos/Runner/      the native shell: windows, menus, Help, entitlements
test/              flat, roughly one file per unit or widget
tool/              mutate.py (sabotage harness), records.dart (docs checker)
```

## The executor seam

Everything that runs a command goes through `abstract class CommandExecutor`
(`lib/core/ssh/ssh_command_executor.dart`). It has three implementations:

| Executor | Where it runs | Location |
| --- | --- | --- |
| `SSHCommandExecutor` | a remote host, over `dartssh2` | `lib/core/ssh/` |
| `LocalCommandExecutor` | this Mac, `Process.start` with native argv, cwd and env (no shell string to escape) | `lib/core/exec/` |
| `ProxyCommandExecutor` | inside a pop-out window: relays to the main window's executor | `lib/core/exec/` |

`GitService`, `GlabService`, `GhService` and `HostFsService` depend only on the **active**
executor (`activeExecutorProvider`, chosen by the connection's backend). So every
capability works unchanged against remote and local repositories. A new git or forge
capability is added at the service layer, never per backend.

## The SSH transport

The remote backend is `dartssh2` 3.3.0, pinned exactly
([0012-MADR](decisions/0012-MADR-adopt-dartssh2-v3.md),
[0013-MADR](decisions/0013-MADR-prefer-dartssh2-v3-over-dartssh3.md)). It supports POSIX
remotes only. `ShellEscaper` is the injection defence on every interpolated value, and
every script sent through `sh -c` must be dash-clean, because Debian-family hosts run
`sh` as dash.

**Up to three clients per connection** (`SSHClientManager`):

* a command client for request/response work;
* a stream client for long-lived streams (watchers, CI traces);
* a sync client for `fetch`/`push`, so pack transfer never shares a TCP connection with
  interactive reads.

The three handshakes run in parallel. Host-key verification is serialized across them
(`serializeHostKeyVerifier`), so one first contact produces one trust-on-first-use prompt
(`KnownHostsStore`). The stream and sync clients fail open onto the command client
rather than failing the connection. They are re-dialled in the background, backing off
15 s, 30 s, 60 s, then 120 s (`SSHClientManager.streamRedialDelay`), and give up for the
session after 5 failures. All three share a generation. A command pins the generation
when it is enqueued, and one that finds a different generation when it runs fails with
`SSHCommandSuperseded`, never retried, so work never lands on a reconnected host it was
not meant for ([0011-MADR](decisions/0011-MADR-ssh-transport-stability-hardening.md),
[0014-MADR](decisions/0014-MADR-ssh-engine-next-wave-hardening.md)).

**Liveness.** `ConnectionHealthMonitor` sends reply-checked keepalive pings on each
client: every 15 s, with a 15 s timeout. Pings pause while that client is busy, so a slow
healthy session is not mistaken for a dead one. Sockets are `NativeSshSocket`. An
unexpected drop records a `TransportDropCause`.

**Reconnect.** `ConnectionController` (`lib/core/providers/app_providers.dart`) watches
the command client. On a drop it moves to `lost` and reconnects on a 1, 2, 4, 8, 15 s
schedule, repeating the last delay. It pauses after 20 attempts
(`_maxAutoReconnectAttempts`), or at once on an error that retrying cannot fix
(`isRetryableReconnectError`: auth, host key, key decode). A user action bumps the
attempt counter and cancels the loop.

**The environment probe.** One connect-time probe builds a `RemoteEnvironment`: the
remote OS, an augmented `PATH` that puts per-user directories ahead of system ones (so a
system shim cannot shadow the user's CLI), and the tool catalogue. Forge-token
environment variables are neutralised per connection, so the app's managed identity
wins over ambient tokens.

**Compression.** `dartssh2` has no transport compression. So large git and forge-CLI
reads are piped through `gzip -c -1` on the host, with an in-band `\x01EXIT=n\x01`
trailer carrying the real exit status (`lib/core/ssh/command_formatter.dart`). A missing
trailer never reads as success. Compressed output over 256 KiB on the wire is gunzipped
off the UI isolate (`gzipOffloadWireBytes`).

## Scheduling, budgets and telemetry

`CommandLaneScheduler` (`lib/core/exec/command_lanes.dart`) runs inside each executor.
The *call site* chooses the lane, because the service layer knows what each invocation
touches:

| `ExecLane` | Runs | For |
| --- | --- | --- |
| `read` | concurrently, up to the read cap | status, log, diff, blame, CLI list calls — always with `GIT_OPTIONAL_LOCKS=0` |
| `sync` | one at a time, overlapping reads | `fetch`, `push`, forge-CLI mutations |
| `exclusive` | alone, as a FIFO barrier | index or work-tree mutations: stage, commit, checkout, rebase |
| `isolated` | beside everything, cap 2 | long-running side work that touches no repository state |

The **read cap** starts at 3 and moves between 1 and 4 (`AdaptiveReadConcurrency`). It is
driven by completed read durations, not by ping latency. Each normalised command has its
own bucket, and comparing a bucket's best recent duration with its smoothed current one
estimates queueing. A channel-open failure drops an error floor at once, because
`MaxSessions` is a cliff, not a gradient
([0024-MADR](decisions/0024-MADR-ssh-and-remote-repo-engine-debug-audit.md),
[0039-MADR](decisions/0039-MADR-process-global-state-and-control-heuristics-audit.md)).
The scheduler clamps any cap to at most 8. A **watchdog** reclaims the slot of a job that
has not settled 30 s past its own deadline, so one lost job cannot wedge a lane.

Streams are not scheduled, since a command that never exits would hold a lane forever.
`SSHCommandExecutor` bounds them with a live counter instead: 8 concurrent streams, or 2
when the stream client is degraded.

Output is bounded: a command's combined stdout and stderr is capped at 50 MiB
(`maxCommandOutputBytes`, `lib/core/exec/command_drain.dart`). On overrun the process is
killed, not just closed. Termination escalates TERM → KILL after a 400 ms grace.
Only transient transport errors are retried, with a 400 ms backoff taken *between* two
separate enqueues, so a retry wait never blocks a lane. A non-zero exit is a result, not
a retry trigger. `CommandTelemetry` records a ring of recent
commands and the connection's counters for the dashboard.

## Services, parsing and forges

* **`GitService`** (`lib/core/git/git_service.dart`) parses machine formats only: `status
  --porcelain=v2 -z`, `for-each-ref --format`, NUL-delimited logs. Large outputs are
  parsed off the UI isolate (`Isolate.run`). Multi-blob reads batch through
  `git cat-file --batch` (`GitCatFileBatch`). A repository with a separate git dir (for
  example a dotfiles bare repository) is scoped with `registerRepoScope`, which adds
  `--git-dir`/`--work-tree` to every call.
* **`GlabService`** and **`GhService`** drive GitLab and GitHub through their CLIs, reading
  `api` JSON. Glab exit codes are advisory, because of known upstream bugs. Every glab
  call pins the origin's host ([0019-MADR](decisions/0019-MADR-pin-glab-origin-host-on-every-call.md)).
  A GitLab token is sent once over stdin to `glab auth login --stdin`, and from then on
  both CLIs use the host's own credential store. **Secrets never appear in argv or a
  command string.**
* **`HostFsService`** does the host file-system work that is not git: the home directory,
  path probes, creating directories, and guarded directory removal.
* Git itself is the engine. There is no libgit2
  ([0001-MADR](decisions/0001-MADR-native-git-libgit2.md)).

## Watching for changes

A repository refreshes on change rather than on a timer. The watch stack gives each
concern one owner ([0045-MADR](decisions/0045-MADR-one-owner-per-watcher-concern.md)):

| Concern | Owner | Location |
| --- | --- | --- |
| identity | `WatchTarget`: a value that keys the `watcherProvider` family; `repoWatchProvider` is a facade over it | `lib/core/git/watch/watch_target.dart` |
| admission | `WatchAdmission`: exclusion within the session first, then the host's budget | `lib/core/git/watch/admission/` |
| sequencing | `WatchEngine`: one event at a time; a result for an attempt that is no longer current is dropped by comparison | `lib/core/git/watch/engine/` |
| the process | `WatchSource`: `RemoteWatchSource` (`fswatch` or `inotifywait` on the host) and `DirectoryWatchSource` (`Directory.watch` locally) | `lib/core/git/watch/source/` |
| timing | `WatchTimings`: every interval in one value, with its couplings asserted | `lib/core/git/watch/watch_timings.dart` |
| observability | `WatcherId` on every transition record | `lib/core/git/watch/watcher_id.dart` |

Change bursts are coalesced (`Coalescer`: a trailing debounce, a max-wait ceiling and a
minimum interval) into ticks the providers refresh on. A watcher that dies backs off
2 s × *n* and restarts, up to 3 times. After that it falls back to polling every 5 s, and
retries event-driven watching every 3 minutes.

On a remote host the client cannot kill the watcher it started: sshd does not
implement the signal request, and closing the channel does not reach a watcher blocked
in `select()`. So the watcher is watched **on the host**. A watchdog reads stdin for EOF,
a lease poll checks the heartbeat the client refreshes, and a trap turns a signal into an
orderly shutdown (`lib/core/git/bounded_watch.dart`). A per-repository lock keyed by the
resolved git dir refuses a second session's watcher
([0041-MADR](decisions/0041-MADR-the-watcher-the-client-cannot-kill.md),
[0043-MADR](decisions/0043-MADR-a-watcher-refused-by-its-own-session.md)). For a very
large work tree, such as a dotfiles repository over a home directory, a bounded watch
covers only the git dir and the directories that hold tracked files. Host scripts like
these are executed by a test, not just string-compared
([0029-MADR](decisions/0029-MADR-host-scripts-must-be-executed-by-a-test.md)).

## State: Riverpod

`lib/core/providers/app_providers.dart` is the DI hub. Feature providers are `family`-keyed
by connection and repository, so several workspaces coexist, and they are invalidated on
disconnect. Two rules are enforced by scan tests:

* **Every async provider declares `retry: noProviderRetry`**
  (`lib/core/providers/provider_retry_policy.dart`). A failure surfaces at once as
  `AsyncError` instead of ~38 s of retries
  ([0017-MADR](decisions/0017-MADR-provider-retry-policy-on-providers.md);
  `test/provider_retry_policy_test.dart`).
* **No provider touches `ref` after an `await` without a `ref.mounted` guard**, and
  dependencies are registered before the first `await`
  ([0050-MADR](decisions/0050-MADR-providers-use-ref-after-an-await.md);
  `test/provider_ref_after_await_scan_test.dart`).

Provider failures are reported to the Output pane by `ProviderFailureObserver`
(`lib/core/providers/provider_failure_observer.dart`), next to the output of the commands
the app runs for the user (`outputLogProvider`, `lib/core/output/`). Git operations
that can be undone are recorded in `UndoJournal`/`RedoJournal` (`lib/core/undo/`).

## Windows, menus and Help

**Pop-out windows** (diff and file viewers) run a second FlutterEngine, whose entrypoint
is `secondaryWindowMain` in `lib/main.dart`. It must stay in the root library. A child
window has no transport of its own. Its `ProxyCommandExecutor` relays each command to
the main window over a per-window channel (`windowHubChannel`,
`lib/core/window/window_channels.dart`). Payloads cross as `Uint8List`, never `String`,
because the native codec truncates strings at NUL (`lib/core/exec/exec_proxy_codec.dart`).
A detached window on a linked worktree routes through the same relay
([0047-MADR](decisions/0047-MADR-a-detached-window-on-a-linked-worktree-runs-no-command.md)).

**The menu bar** is declared in Dart (`kMenuBarMenus`,
`lib/features/common/menu_bar_spec.dart`) and installed natively. Keyboard shortcuts come
from one keymap (`kKeymapActions`, `lib/core/settings/keymap.dart`)
([0008-MADR](decisions/0008-MADR-unified-repository-chrome.md)).

**Help** is a native SwiftUI window (`macos/Runner/HelpView.swift`,
`HelpWindowController.swift`) that renders one bundled book,
`macos/Runner/help_book.json`. `test/help_book_json_test.dart` binds the book's
shortcuts and menu paths to the keymap and menu spec, so they cannot drift
([0010-MADR](decisions/0010-MADR-in-app-help-book-rewrite.md),
[0053-MADR](decisions/0053-MADR-in-app-help-and-readme-currency-refresh.md)).

## Local repositories, sandbox and secrets

The app is sandboxed. Access to a local repository comes from the user's own selection
(a Finder picker or a drop), kept as a security-scoped bookmark
(`SecurityScopedBookmark`, `lib/core/local/`). Secrets go to the macOS Keychain through
`flutter_secure_storage` (`lib/core/storage/connection_store.dart`). An unsigned build,
which has no Keychain access group, falls back to `~/.config/magic_git/credentials.json`
with mode `0600`.

## Building

`build_macos.sh` is the only supported build. It pins the Flutter SDK
(`FLUTTER_VERSION`, currently 3.47.2) and vendors it into `.flutter-sdk/` when the one on
`PATH` differs. A different Flutter rewrites `pubspec.lock` and shifts the golden tests.
`macos/Runner/Release.entitlements` and `DebugProfile.entitlements` are never edited by a
build. An unsigned build selects their tracked twins, `Release-unsigned.entitlements`
and `DebugProfile-unsigned.entitlements`, through xcconfig variables
(`MG_DEBUG_ENTITLEMENTS` in `macos/Runner/Configs/AppInfo.xcconfig`), and
`test/macos_entitlements_canon_test.dart` pins both pairs
([0042-MADR](decisions/0042-MADR-the-macos-build-mutates-its-own-inputs.md)). The steps are
in the [build guide](guides/build-macos.md).

## How it is kept honest

* **`flutter test` is the gate.** It includes `integration`-tagged tests that run real git
  in temporary repositories. `live-forge` tests, which mutate real GitHub/GitLab
  projects, are skipped unless asked for (`dart_test.yaml`).
* **Conventions are scan tests, not prose.** Examples: `source_is_text_scan_test`
  (no raw NUL bytes in source), `no_real_identifiers_scan_test`,
  `shell_injection_canon_test`, `button_cursor_canon_test`, `watch_stack_structure_test`,
  and the two provider scans above.
* **A check is not trusted until it has been seen to fail.** `tool/mutate.py` applies a
  catalogue of deliberate defects (`tool/mutations/*.json`) in a scratch worktree and
  reports any the tests did not notice
  ([0030-MADR](decisions/0030-MADR-test-coverage-gaps-are-shaped-not-sized.md)).
* **Documentation is checked too.** `tool/records.dart`, run by
  `test/docs_records_test.dart`, fails the suite on a broken relative link, anchor or
  `docs/` path mention, on a numbering or frontmatter error, and on any file out of place
  in this tree. `dart run tool/records.dart next` prints the next free record number
  ([0054-MADR](decisions/0054-MADR-docs-link-checker-and-standard-layout-migration.md)).
