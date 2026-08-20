---
status: "proposed"
date: 2026-08-20
associated-madr: "0017-MADR-provider-retry-policy-on-providers.md"
owner: [Maintainer]
target-milestone: Next work cycle (post-review)
---

# Implement: enforce four conventions in source

Associated MADR:
[0017-MADR-provider-retry-policy-on-providers.md](./0017-MADR-provider-retry-policy-on-providers.md)

Declare `retry: noProviderRetry` on all **77** async provider declarations,
enforce it with a scan, correct the two U17 inaccuracies, demote the
`AGENTS.md` mandate from mechanism to signpost — and close the three
mandates that still rest on prose alone: the entitlements keys (G1), shell
escaping of caller values (G2), and NUL-safe relay payloads (G3).

Each uses the mechanism its invariant calls for, not the same one three
times: a committed-artifact read for G1, behavioural tests for G2 and G3, a
source scan only for the syntactic one (the retry annotation).

A second engineer following only this file, against the tree at `3d709c6`,
must produce the same diff.

## Goal

Make a bare `ProviderScope` in a test behave exactly like the app's, so no
test author has to know the rule.

**Acceptance criteria**

1. Every async provider declaration in `lib/` (`FutureProvider`,
   `StreamProvider`, `AsyncNotifierProvider`, and their `.autoDispose` /
   `.family` variants) passes `retry: noProviderRetry`.
2. A widget test using a **bare** `ProviderScope`, with one of those providers
   overridden to throw an `Exception`, renders the `error` branch — asserted
   directly, since it is the decision's entire claim.
3. A source scan fails when an async provider declaration omits `retry:`,
   using a paren-balance extent walk (line-anchored matching does not work —
   see Phase 0).
4. The three production scope sites keep `retry: noProviderRetry` as a
   backstop; `provider_retry_policy_test.dart`'s existing scan still passes.
5. MADR 0015's U17 wording says ~38 s rather than "forever", and records that
   `Error` subtypes are not retried. The same two corrections are made
   wherever they appear in source comments.
6. `AGENTS.md` describes the helper as preferred, not as the thing standing
   between the suite and broken error tests.
7. The committed `Release.entitlements` still carries `app-sandbox` (set
   true) and `keychain-access-groups`, no stripped state and no leftover
   `.bak` can reach a commit unnoticed.
8. A caller-controlled value driven through the covered `GitService` /
   `HostFsService` surfaces reaches the host only as a literal token — as its
   own argv element, or escaped inside a composed script.
9. An encoded relay payload whose text fields carry NULs survives a simulated
   NUL-lossy codec intact, and `stderr`'s wire type is asserted like
   `stdin`'s and `stdout`'s.
10. `flutter analyze` exit 0, `dart format` clean, full `flutter test` green.
    No `live-forge`.

## Scope

**In scope**

| # | Work |
|---|---|
| 1 | Annotate 77 declarations across 5 files |
| 2 | The `lib/` scan for missing `retry:` |
| 3 | The bare-scope proof test |
| 4 | Triage suite fallout from providers that now reach `AsyncError` |
| 5 | Correct the two U17 inaccuracies (docs + source comments) |
| 6 | Demote the `AGENTS.md` mandate |
| 7 | **G1** entitlements canon test |
| 8 | **G2** shell-injection canon test |
| 9 | **G3** NUL-lossy relay guard |

**Out of scope** (do not implement, even if adjacent)

* Removing `test/helpers/app_scope.dart` or migrating tests off it. It stays;
  it is simply no longer load-bearing.
* Migrating the other ~161 test files to the helper. The whole point of this
  decision is that they no longer need it.
* `custom_lint` (MADR option C). Revisit only if drift continues.
* A *source scan* for `ShellEscaper` call sites. The MADR explains why it
  cannot work here (16 escaped vs 125 bare interpolations, nearly all error
  messages); Phase 6 tests the defense instead. Do not add the scan "as well".
* Widening G2's payload table into a general fuzzer, or covering every method
  that takes a string. The table covers the highest-risk surfaces; growing it
  is cheap later and out of scope now.
* Re-testing what `exec_proxy_codec_test.dart` already guards (stdin and
  stdout wire types). Phase 7 adds `stderr` and the structural guard only.
* Adopting a plist parser dependency for G1. Text key-presence is enough and
  cannot itself break.
* Sync `Provider` / `NotifierProvider` declarations. They cannot produce an
  `AsyncError`, so annotating them is noise.
* Changing any provider's actual behaviour. This is behaviour-preserving in
  the app by construction — see the halt condition.

## Prerequisites

* Commands: `flutter pub get`, `flutter analyze`, `flutter test`.
* New Dart analyzer-clean on the first pass; `dart format` before staging.
* `lib/core/providers/app_providers.dart` is classified as **binary** by
  search tools — 68 of the 77 declarations live there. Use `rg -a`, and make
  the edits with a script rather than by hand.
* Do not commit unless the user asks; if they do, one commit per phase with
  `git commit --no-edit`.
* Halt rule: if a Phase 0 fact disagrees with this plan, stop and update the
  plan.

## Phase 0 — Confirm facts (no commit)

Read, do not edit:

* `lib/core/providers/provider_retry_policy.dart` — `noProviderRetry`.
* riverpod 3.3.2 `src/core/element.dart` ~764 —
  `origin.retry ?? container.retry ?? ProviderContainer.defaultRetry`.
* riverpod 3.3.2 `src/core/provider_container.dart` ~940 — `defaultRetry`,
  its `maxRetries: 10` / `minDelay: 200ms` / `maxDelay: 6400ms`, and the
  `error is ProviderException || error is Error` carve-out.
* The 77 declarations. Regenerate the inventory rather than trusting this
  list; the counts as of `3d709c6` are:

  | file | count |
  |---|---|
  | `lib/core/providers/app_providers.dart` | 68 |
  | `lib/features/branches/pinned_branches.dart` | 3 |
  | `lib/core/forge/branch_forge_status.dart` | 3 |
  | `lib/features/viewer/viewer_providers.dart` | 2 |
  | `lib/features/common/image_diff_view.dart` | 1 |

**Extent detection.** A declaration's end cannot be found by matching a
line. 51 of the 68 in `app_providers.dart` end in `});` rather than `);`, and
8 more are line-wrapped so their terminator is indented
(`app_providers.dart` ~4150 `logSearchProvider`, ~4563 `fileLogProvider`;
`image_diff_view.dart` ~88 `imageDiffBlobProvider`). Walk parenthesis depth
from the declaration line until it returns to zero, skipping lines whose
trimmed form starts with `//`. That resolves all 77 — verified.

**Halt if:** the declaration count differs from 77, `retry` is no longer
accepted by one of the provider forms, or the resolution order in
`element.dart` has changed so the container wins over the provider. Update the
MADR first — the decision depends on provider-wins.

---

## Phase 1 — Annotate the 77 declarations (commit)

**Files**

* **Edit** `lib/core/providers/app_providers.dart` (68)
* **Edit** `lib/features/branches/pinned_branches.dart` (3)
* **Edit** `lib/core/forge/branch_forge_status.dart` (3)
* **Edit** `lib/features/viewer/viewer_providers.dart` (2)
* **Edit** `lib/features/common/image_diff_view.dart` (1)

Add `retry: noProviderRetry,` as the last named argument of each async
provider declaration, and the import where missing.

**Do this with a script**, not by hand: find each declaration, walk to its
closing paren, and insert before it. Hand-editing 77 sites in a
grep-hostile file invites a silent miss, and the Phase 2 scan is the check
that it did not happen.

Placement: after the create function and alongside any existing named
arguments (`name:`, `dependencies:`). `dart format` decides the wrapping —
run it and take its output rather than hand-aligning.

**This changes nothing in the app.** All three production containers already
pass `noProviderRetry`, and `origin.retry ?? container.retry` yields the same
function either way. If any behaviour changes, something else is wrong — see
the halt condition.

**Verify:** `flutter analyze`; `dart format`;
`flutter test test/app_providers_test.dart test/provider_retry_policy_test.dart`.
Do not run the full suite yet — Phase 3 owns the fallout.

**Halt if:** a declaration will not accept `retry:` (a provider form the MADR
did not survey). Leave it, record it, and add it to the Phase 2 allowlist
with a reason. Do not restructure the provider to fit.

---

## Phase 2 — The scan (commit)

**Files**

* **Edit** `test/provider_retry_policy_test.dart`

Add a fourth test beside the existing scope scan, same file, same idiom (the
repo's canon style: regex, path-keyed allowlist with reasons, a failure
message naming the correct API).

`'every async provider declares the retry policy'`

* Walk `lib/**.dart`.
* Start a declaration at
  `^final [A-Za-z0-9_]+Provider = (FutureProvider|StreamProvider|AsyncNotifierProvider)`.
* Determine its extent by parenthesis balance, skipping `//` lines.
* Fail if the extent does not contain `retry:`.
* `const _retryAllowance = <String, int>{}` — empty to start, entries keyed by
  path with a one-line reason, exactly like `_bareTapAllowance`.
* Failure message: name `noProviderRetry` and its file, and say why —
  a provider without it inherits whatever the enclosing scope chose, which is
  not the same thing in a test as in the app.

**Deletion check:** removing `retry:` from any one declaration must fail this
test. Verify on one provider, then restore.

**Verify:** `flutter analyze`;
`flutter test test/provider_retry_policy_test.dart`.

---

## Phase 3 — Prove the claim, then triage the fallout (commit)

**Files**

* **Edit** `test/provider_retry_policy_test.dart` — the proof
* **Edit** whatever the suite turns up

### 3a. The proof

`'a bare scope reaches the error branch for an annotated provider'`

This is the decision's whole claim, so assert it directly rather than
inferring it from Phase 1.

* Build a **bare** `ProviderScope` — deliberately *not* `appProviderScope`,
  with a comment saying so, or the test proves nothing.
* Override a real annotated provider (`statusProvider(_repo)` is a good
  choice — a `FutureProvider.autoDispose.family`, the most common shape) to
  throw a `GitException`, i.e. an `Exception`, which is the retried class.
* Pump a widget that renders `.when(error: …)` and assert the error text
  appears within a couple of pumps.
* A sibling case pinning the mechanism: the same override under a bare scope
  on an **unannotated** local provider still shows `loading`. Keep it
  adjacent so the contrast is legible.

### 3b. Fallout

Run the full suite. Expect failures: tests that today sit in retry-loading
now reach `AsyncError`, and a few will have been asserting the loading state
or passing without exercising anything.

For each failure decide, in this order:

1. The test meant to assert an error branch and now can → fix the assertion,
   it is now doing what it always claimed.
2. The test deliberately asserts a *loading* state → give it a provider that
   is genuinely pending (a `Completer` that never completes), not one that
   fails. A failing provider was never the right way to model loading.
3. The test's provider fails incidentally (an unstubbed dependency) → stub
   it. The error was being swallowed before; that was the bug.

Record each fallout fix in the commit, one line per test.

**Verify:** `flutter analyze`; full `flutter test`.

**Halt if:** more than ~15 tests fail. That is a different-shaped problem than
this plan assumes — stop, report the list, and get direction before
mass-editing tests.

---

## Phase 4 — Corrections and demotion (commit)

**Files**

* **Edit** `docs/0015-MADR-ssh-engine-and-ui-unit-test-gaps.md`
* **Edit** `lib/core/providers/provider_retry_policy.dart`
* **Edit** `test/helpers/app_scope.dart`
* **Edit** `AGENTS.md`

### 4a. The two corrections

Wherever U17's behaviour is described — the MADR's U17 section and its table,
the doc comment on `noProviderRetry`, and the header comment in
`app_scope.dart` — replace "forever" / "indefinitely" with the measured
figure, and add the carve-out:

> Under the default policy a failed provider stays in `AsyncLoading` for
> **~38 s** (10 retries, exponential 200 ms → 6.4 s cap) before it finally
> emits `AsyncError` — far longer than any widget test can pump, so the error
> branch is unreachable in practice. `Error` subtypes and `ProviderException`
> are exempt from retry and surface immediately; the app's own
> `GitException` / `GhException` / `GlabException` all implement `Exception`,
> so the failures that matter are exactly the retried ones.

Mark them as corrections with the date, the way 0015's existing corrections
are marked. Do not silently rewrite history.

### 4b. Demote the mandate

`AGENTS.md`'s Riverpod bullet currently reads as *"a test must use the helper
or error branches are unreachable."* That stops being true at Phase 1. Rewrite
to:

* the policy travels with the provider, so any scope behaves like the app;
* `appProviderScope` / `appProviderContainer` remain the tidy default and
  cover anything unannotated;
* the two scans in `provider_retry_policy_test.dart` are what actually
  enforce this — name them, so the reader knows where the teeth are.

Same edit to `app_scope.dart`'s header comment, which makes the same
overstated claim.

**Verify:** `flutter analyze`; `flutter test test/provider_retry_policy_test.dart`;
`ls -l CLAUDE.md .goosehints` still resolve to `AGENTS.md`.

---

## Phase 5 — G1: the entitlements are what we think they are (commit)

**Files**

* **Create** `test/macos_entitlements_canon_test.dart`

`AGENTS.md` calls this a *critical safety rule* and then enforces it with
prose plus a shell trap. A build that dies between `PlistBuddy` and the EXIT
trap leaves a de-sandboxed `Release.entitlements` on disk; the only thing
standing between that and a commit is somebody reading the diff.

**Test** (`Directory.current` is the package root under `flutter test`, so
plain relative paths work; parse as text — key presence does not need a plist
parser, and a dependency-free check cannot itself break)

1. `'Release.entitlements keeps the sandbox and keychain keys'`
   — Read `macos/Runner/Release.entitlements`.
   — Assert it contains `com.apple.security.app-sandbox` immediately followed
     by `<true/>` (a key present but set false is the same bug).
   — Assert it contains `keychain-access-groups`.
   — Assert the other sandbox-dependent grants the app relies on:
     `com.apple.security.network.client`,
     `com.apple.security.files.user-selected.read-write`,
     `com.apple.security.files.bookmarks.app-scope` — the last two are how
     local-repo access works at all (Finder picker + security-scoped
     bookmarks).
   — Reason string: name `build_macos.sh --unsigned`, say the file is
     stripped *transiently* and restored by an EXIT trap, and that seeing
     this fail means a build died mid-run — restore the file, do not commit
     it.
2. `'DebugProfile.entitlements keeps the sandbox'`
   — Same `app-sandbox` + `<true/>` assertion. It is not what ships, but a
     debug build outside the sandbox hides sandbox bugs until release.
3. `'no leftover entitlements backup'`
   — `macos/Runner/Release.entitlements.bak` must not exist. It is gitignored,
     so it never shows in `git status` — its presence means a build is in
     flight or died, and in the second case test 1 is already failing.

**Deletion check:** run `PlistBuddy -c "Delete :com.apple.security.app-sandbox"`
on a **copy**, point the test at the copy, confirm it fails, then discard the
copy. Do not mutate the real file to prove the test works.

**Verify:** `flutter analyze`;
`flutter test test/macos_entitlements_canon_test.dart`;
`git status --short macos/` clean.

---

## Phase 6 — G2: caller values can never become shell syntax (commit)

**Files**

* **Create** `test/shell_injection_canon_test.dart`

**Not a source scan.** See MADR G2: 16 escaped vs 125 bare interpolations
across the 11 script-building files, nearly all of the bare ones error
messages, plus raw-string false positives. A scan here is noise that gets
allowlisted into meaninglessness, and "did someone call `escape()`" is not
the invariant anyway.

**The invariant.** A caller-controlled value reaches the host as a single
literal token, never as syntax. Concretely, for every recorded `execute`
call, the payload must appear **either**:

* as an argv element **equal to** the payload — `CommandFormatter.format`
  escapes whole elements, so this is safe by construction; **or**
* inside a composed element (an `sh -c` script) **only** as
  `ShellEscaper.escape(payload)`.

Anything else — the payload embedded raw in a larger string — fails.

**Payload table.** Shell metacharacters in every position that has mattered:
command separation, substitution, quoting, and a newline (which `;`-based
reasoning alone does not cover). Include an apostrophe case, since single
quoting is exactly what the escaper does.

* `'; touch /tmp/pwned; '`
* `$(touch /tmp/pwned)`
* backtick `touch /tmp/pwned` backtick
* `a` + newline + `rm -rf /`
* `--upload-pack=touch /tmp/pwned`
* `it's a branch`

Write them as Dart raw strings where possible; the newline case needs a
normal string.

**Structure.** A recording executor (reuse the `_FakeExecutor` shape from
`mutations_test.dart` — do **not** import across test files; copy the ~20
lines, as the other tests here do), then a table of invocations, each taking
one caller-controlled string:

| surface | method |
|---|---|
| `GitService` | `stage`, `checkoutBranch`, `createBranch`, `deleteBranch`, `commit` (message), `pushTags` (tag name), `deleteRemoteTag`, `fileHistory` (path), `diffRange` (range) |
| `HostFsService` | `makeDirectory`, `removePath`, `listDirectory` |

Drive each with each payload and assert the invariant above. Where a method
takes a *repo path*, exercise that too — it is caller-controlled via the
connection form.

Then one explicit regression case, named for what it protects:

`'a repo path with a quote cannot break out of an sh -c script'`
* `HostFsService.makeDirectory` with `it's` in the path.
* Assert the script contains the escaped form of the path and that the raw
  `it's` never appears unescaped.

**Deletion check:** remove the `ShellEscaper.escape(...)` from
`host_fs_service.dart` ~121 (`mkdir -p --`) and confirm the suite fails, then
restore. If it does not fail, the table does not cover that surface — extend
it before moving on.

**Halt if:** a covered method turns out to interpolate a caller value
**unescaped**. That is a live injection bug, not a test gap: stop, report it
with the exact call site, and get direction before writing any more tests.

**Verify:** `flutter analyze`;
`flutter test test/shell_injection_canon_test.dart test/shell_escaper_test.dart`.

---

## Phase 7 — G3: a NUL-lossy transport cannot behead a payload (commit)

**Files**

* **Edit** `test/exec_proxy_codec_test.dart`

Two of the three text fields are already guarded — the existing
`'NUL-delimited stdin survives...'` and `'NUL-bearing stdout survives...'`
tests assert `isA<Uint8List>()` on the encoded map. Do not duplicate them.
What is missing is `stderr`, and a structural guard covering fields nobody
has written a test for yet.

**Tests**

1. `'NUL-bearing stderr travels as bytes on the wire'`
   — Mirror the stdout test exactly, so the three fields are guarded alike.
     A `git` failure message can carry NUL-delimited paths.
2. `'no payload field carries command text as a NUL-lossy string'`
   — The structural guard. Add a helper that simulates the hostile native
     codec: it walks the encoded map and, for every `String` value, keeps
     only the part before the first NUL (split on '\u0000', take first);
     `Map` and `List` values recurse; everything else — crucially `Uint8List`,
     which is length-prefixed in every codec — passes through untouched.
   — Encode an `ExecuteRequest` whose `stdin` carries NULs, push the encoded
     map through that helper, decode, and assert full equality with the
     original.
   — Same for `encodeExecuteResult` with NULs in `stdout` **and** `stderr`.
   — A future field added as a NUL-bearing `String` fails this without anyone
     remembering to write a test for it — which is the whole point.
3. `'argv and env stay strings by contract'`
   — The library doc says argv/env cannot contain NUL by OS contract and
     deliberately stay strings. Pin that, so the structural test above is not
     later "fixed" by turning everything into bytes: assert `wire['gitArgs']`
     is a list of strings, and that `ShellEscaper.escape` rejects a
     NUL-bearing argument (it already throws `ArgumentError`) — so a NUL can
     never reach argv in the first place.

**Deletion check:** change `_wireBytes` to return the string unchanged for
`stderr` and confirm tests 1 and 2 both fail; restore.

**Verify:** `flutter analyze`;
`flutter test test/exec_proxy_codec_test.dart test/shell_escaper_test.dart`.

---

## Phase 8 — Full gate (no extra commit if clean)

```sh
flutter analyze
dart format --output=none --set-exit-if-changed <every file this plan touched>
flutter test test/provider_retry_policy_test.dart \
  test/app_providers_test.dart \
  test/connection_race_test.dart \
  test/forge_project_sections_test.dart \
  test/run_jobs_view_test.dart \
  test/repo_status_view_test.dart \
  test/file_view_test.dart \
  test/forge_list_error_test.dart \
  test/macos_entitlements_canon_test.dart \
  test/shell_injection_canon_test.dart \
  test/shell_escaper_test.dart \
  test/exec_proxy_codec_test.dart
flutter test
git status --short macos/
```

Never `live-forge`.

## Verification

| # | Check |
|---|---|
| 1 | `flutter analyze` exit 0; `dart format` clean |
| 2 | Full `flutter test` green |
| 3 | All 77 declarations carry `retry:`; the scan fails if one is removed |
| 4 | A bare `ProviderScope` + an overridden annotated provider renders `error` |
| 5 | An unannotated provider under a bare scope still renders `loading` (the contrast case) |
| 6 | The three production scope sites still pass `noProviderRetry` |
| 7 | Fallout tests fixed on their merits, each noted in the commit |
| 8 | 0015's U17 says ~38 s and records the `Error` carve-out, dated as a correction |
| 9 | `AGENTS.md` points at the scans rather than asserting the helper is load-bearing |
| 10 | G1: deleting a sandbox key from a copy fails the test; no `.bak` exists; `macos/` is clean |
| 11 | G2: every payload reaches the host as a literal token; removing an `escape()` call fails the suite |
| 12 | G3: the NUL-lossy round-trip holds; `stderr` asserts `Uint8List`; argv stays strings |

## Rollout and Rollback

**Rollout.** Behaviour-preserving in the app: the containers already supplied
this function. The only observable change is in tests, which is the point. No
schema, no transport, no `.app` build needed.

**Rollback.** Revert in reverse phase order. Phase 2's scan must revert with
Phase 1 or it fails against unannotated providers. Nothing here is depended on
by 0015-PLAN or 0016-PLAN.

**Risks**

* 68 of 77 edits land in a file search tools treat as binary. Script the
  edits; the Phase 2 scan is the proof they all landed.
* Phase 5 will fail for anyone whose working tree holds a half-finished
  unsigned build. That is the feature, but it will look like a broken test
  the first time it happens — the reason string must say so plainly.
* Phase 6's deletion check temporarily removes an escaper call from
  production source. Restore it in the same step; never commit that state.
* Phase 3b's fallout is unbounded until the suite runs. The halt condition
  caps it at ~15.
* A future provider form the scan does not recognise slips through. The
  container backstop covers it, and the scan can be extended when it appears.

## Halt conditions (do not improvise)

1. `origin.retry` no longer wins over `container.retry` → the decision's
   premise is gone. Stop and revise MADR 0017.
2. A provider form rejects `retry:` → allowlist it with a reason; do not
   reshape the provider.
3. Phase 1 changes observable app behaviour → it should not be able to. Stop
   and find out why before continuing; something is reading `container.retry`
   directly, or a provider was already annotated differently.
4. Phase 3b exceeds ~15 failing tests → report the list and get direction.
   Do not mass-edit.
5. A fallout test is "fixed" by reverting its provider's annotation → never.
   Fix the test, or allowlist the provider with a written reason.
6. Phase 5 fails on the real entitlements file → a build died mid-run. Restore
   from `Release.entitlements.bak`, confirm `git diff` is clean, and only then
   continue. Never commit the stripped file, and never "fix" the test by
   relaxing the assertion.
7. Phase 6 finds a caller value interpolated **unescaped** → that is a live
   injection bug. Stop, report the call site, get direction. Do not quietly
   add the `escape()` call and carry on as if it were a test-only change.
8. Phase 7's structural guard fails on a field this plan did not name → good,
   that is it working. Convert the field to bytes via `_wireBytes` /
   `_wireText`; do not exempt it.
