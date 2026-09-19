---
status: rejected
date: 2026-07-07
verified: 2026-08-20
---
# Do not adopt libgit2/git2dart to replace the git binary

- Status: rejected
- Date: 2026-07-07
- Deciders: Mac Smith
- Tags: architecture, git-engine, performance, dependencies

Technical Story: Evaluate replacing the external `git` binary with libgit2 FFI
bindings (`git2dart` / archived `libgit2dart` / `git2dart_binaries`) to eliminate
dependence on external binaries and move toward a "true enterprise" git client.

## Context and Problem Statement

magic-git shells out to the `git` and `glab` binaries for every operation.
The proposal was to swap the git engine for libgit2 via Dart FFI, on the premise
that native-speed, structured Git operations would be more responsive and stable
than spawning processes, and would remove an external-binary dependency.

The question: is that technically and architecturally feasible for *this* app,
and does it actually move us toward an enterprise-grade client — or does it
optimize the wrong axis and regress features?

## Decision Drivers

- **Remote-first architecture.** The primary transport runs `git` *on a remote
  host* over SSH, against a repo on the remote filesystem
  (`lib/core/ssh/ssh_command_executor.dart:442`,
  `lib/core/ssh/command_formatter.dart:93`). Core product thesis: drive remote
  git over SSH *without cloning locally*.
- **Eliminate external-binary dependency** (the stated goal).
- **Performance / responsiveness** on large repositories.
- **Correctness** — reduce fragile CLI text parsing.
- **Enterprise readiness** — signing, submodules, LFS, hooks, auth.
- **Supply-chain & build risk** — the app currently ships **unsigned** with 0
  code-signing identities; a bundled native `.dylib` has notarization impact.

## Considered Options

1. **Keep the CLI `CommandExecutor` architecture unchanged** (status quo).
2. **Full libgit2 port** — replace the git binary with `git2dart` across the app.
3. **Narrow libgit2 read-acceleration layer** — libgit2 for local-backend
   read-heavy ops (`status`/`log`/`blame`/`diff`/`for-each-ref`) only, behind the
   existing `GitService` seam; CLI retained for mutations, network, hooks, and
   the entire SSH backend.

## Decision Outcome

Chosen option: **Option 1 — keep the CLI `CommandExecutor` architecture.**
Reject Option 2. Do **not** pursue a spike of Option 3 at this time.

libgit2 is an in-process FFI library that operates on a *local* filesystem. It
cannot drive a remote-over-SSH repository, which is the app's core mode. It does
nothing for `glab` (all GitLab access), leaves coreutils/watchers/hooks on the
CLI regardless, and its performance win lands on the *local* backend — the one
whose latency matters least, since SSH round-trips (which libgit2 does not
affect) dominate the felt performance. The best-documented binding
(`libgit2dart`) is archived; the maintained fork (`git2dart`) is a niche `0.x`
package that bundles a native library we would have to sign/notarize.

The one real benefit — deleting a class of fragile CLI-parsing bugs — is
achievable more cheaply by hardening the two brittle parsers in place, and does
not justify maintaining two parallel local read implementations plus a native
dependency.

### Confirmation

This ADR records a "no-build" decision; confirmation is that no libgit2
dependency is added to `pubspec.yaml` and the `CommandExecutor`/`GitService`
architecture is unchanged. Reopen if a concrete, reported *local* large-repo
performance or stash/log mis-parse pain point emerges (see reopen triggers).

### Consequences

- Good — no native binary enters the supply chain; unsigned-build and future
  notarization story stays simple.
- Good — one transport-agnostic execution seam continues to serve local, SSH,
  git, glab, coreutils, and watchers uniformly.
- Good — hooks (`prepare-commit-msg`) and headless interactive rebase keep
  working (libgit2 runs neither).
- Bad — fragile CLI text parsers remain (log field-separator scrubbing, stash
  free-text regex, glab HTTP-status regex); tracked as separate hardening work.
- Bad — local large-repo operations keep per-op process-spawn overhead (small on
  macOS, and already mitigated by round-trip bundling + off-isolate parsing +
  fsmonitor).

## Pros and Cons of the Options

### Option 1 — Keep the CLI CommandExecutor architecture

- Good — the only design that supports remote-over-SSH without cloning.
- Good — one seam handles both backends and `git`/`glab`/coreutils/watchers.
- Good — hooks, interactive rebase, signing-adjacent behavior all reachable.
- Good — zero supply-chain / signing / notarization change.
- Bad — retains fragile text parsing.
- Bad — retains per-op spawn cost on the local backend.

### Option 2 — Full libgit2 port

- Good — native, structured, no-spawn local reads; kills a class of parser bugs.
- Bad — **architecturally impossible for the SSH backend**: libgit2 is local; the
  app runs git on the remote host. Would require cloning locally (defeats the
  thesis), mounting the remote FS (slow, lock-fragile), or shipping a bespoke
  on-host agent (worse than the `git` dependency it replaces).
- Bad — **does not eliminate external binaries**: all of `glab` (MRs, pipelines,
  issues, approvals, CI trace) plus `cat`/`rm`/`ls`/`base64`, `.gitignore`
  editing, and `fswatch`/`inotifywait` watchers remain.
- Bad — **feature regressions**: libgit2 does not run hooks; has no *interactive*
  rebase (todo-list orchestration would be reimplemented by hand).
- Bad — best binding `libgit2dart` **archived since Feb 2023**; `git2dart` is
  niche (~13 likes, ~1.2k weekly downloads), `0.x` API.
- Bad — bundles a native `.dylib`; unclear prebuilt SSH/libssh2 and Apple-Silicon
  support; collides with the unsigned-build / notarization constraint.
- Bad — signing support is limited vs. the CLI; the app would move *away* from
  enterprise signing, not toward it.

### Option 3 — Narrow local-only read-acceleration layer

- Good — captures the genuine wins (native local reads, structured objects) where
  they help, without touching the SSH backend, mutations, network, or hooks.
- Good — feature-flaggable per operation, default off, easily reverted.
- Bad — **additive complexity, not eliminated dependencies**: two local read
  implementations to keep in sync; every CLI parser still maintained for SSH.
- Bad — still bundles a native library to sign/notarize; still a `0.x` niche dep.
- Bad — payoff only materializes if *local* large-repo lag or stash/log
  mis-parsing is a real, reported pain point — currently unverified.
- Neutral — decision is to **not spike this now**; revisit on a concrete trigger.

## Reopen triggers

Revisit this decision if any of these become concrete and reported:

- Users experience material lag on **local** large-repo `status`/`log`/`blame`.
- Stash-list or log parsing produces user-visible corruption in practice.
- A first-party, stable (≥1.0) libgit2 binding with confirmed macOS arm64 +
  bundled SSH support emerges.

## More Information

Enterprise-readiness is better advanced CLI-side than via a git-engine swap:
commit **signing + verification** (currently disabled via `--no-gpg-sign`),
**submodule** support, **Git LFS** awareness, in-place hardening of the two
brittle parsers, and richer **auth/credential** integration. libgit2 would make
signing, hooks, and LFS harder, not easier.

Evidence base (read-only codebase audit, 2026-07-07):

- Remote exec: `lib/core/ssh/ssh_command_executor.dart:442`,
  `lib/core/ssh/command_formatter.dart:70-94`.
- Executor selection: `lib/core/providers/app_providers.dart:124-133`.
- Git operations (~27 subcommands): `lib/core/git/git_service.dart`.
- GitLab via `glab`: `lib/core/gitlab/glab_service.dart`.
- Fragile parsers: `git_log_parser.dart:145` (`_stripSeps`),
  `git_service.dart:1730` (stash regex), `glab_service.dart:162` (HTTP status).
- Hooks / headless rebase: `git_service.dart:1081-1139`, `:1481`.

Package research:

- git2dart — https://pub.dev/packages/git2dart (v0.5.3; ~13 likes; ~1.2k
  weekly downloads)
- libgit2dart — https://github.com/SkinnyMind/libgit2dart (archived Feb 2023)
- git2dart_binaries — https://pub.dev/packages/git2dart_binaries
- libgit2 + libssh2 SSH transport — https://github.com/libgit2/libgit2/issues/2665
- https://libgit2.org/
