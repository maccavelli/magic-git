---
status: accepted
date: 2026-08-20
decided: 2026-08-20
decision-makers: [Maintainer]
consulted: []
informed: [Magic Git contributors]
---

# Enforce conventions in source: carry the retry policy on the providers, and close the three tier-5 gaps

## Context and Problem Statement

[0015](./0015-MADR-ssh-engine-and-ui-unit-test-gaps.md) finding **U17**
established that Magic Git's widget tests run Riverpod in a configuration the
app never uses. The app disables automatic provider retry; a test that builds
its own `ProviderScope`/`ProviderContainer` does not, so a provider that fails
in a test does not reach `AsyncError` the way it does in the app, and error-UI
assertions written against those scopes cannot fire.

[0016-PLAN](./0016-PLAN-ssh-engine-and-ui-coverage-tail.md) Phase 9 fixed the
*production* half properly: the policy is now one named value,
`noProviderRetry` (`lib/core/providers/provider_retry_policy.dart`), used by
all three scope sites and pinned by a source scan.

It fixed the *test* half with a mandate: a helper
(`test/helpers/app_scope.dart`) plus a line in `AGENTS.md` telling authors to
use it. That is the weakest link in the chain. A prose instruction is obeyed
only by whoever reads and remembers it, and the failure is silent — a test
written with a bare scope still compiles, still passes, and simply never
exercises the branch it claims to. The maintainer's objection is exactly
right: **the enforcement must live in source, not in a file that agents and
humans alike can skip.**

Today **5** test files use the helper. **166** build a scope some other way,
across **400** sites.

### Two corrections to U17's own wording

Measuring for this record turned up two inaccuracies in how 0015 states the
finding. Both are recorded here and are fixed as part of this decision.

* **"forever" / "indefinitely" is wrong — it is ~38 seconds.**
  `ProviderContainer.defaultRetry` gives up after 10 attempts (exponential
  200 ms doubling, capped at 6.4 s) and *then* emits `AsyncError`. Measured on
  this tree: 12 state transitions, settling at 38 s. Still fatal for a widget
  test — `pumpAndSettle` cannot outlast it and no realistic pump budget
  reaches it — but the claim should say 38 s.
* **`Error` subtypes are never retried.** `defaultRetry` returns null
  immediately when `error is ProviderException || error is Error`. A provider
  throwing `StateError` therefore reaches `AsyncError` even under a bare
  scope. This sharpens rather than softens the finding: the app's own failure
  types — `GitException`, `GhException`, `GlabException` — all
  `implements Exception`, so the errors that actually matter are precisely the
  retried ones. But U17's blanket "every error branch is unreachable" is too
  broad, and some existing error tests pass legitimately because they throw
  an `Error`.

### What was verified for this record (2026-08-20, `3d709c6`)

* Resolution order is `origin.retry ?? container.retry ??
  ProviderContainer.defaultRetry` (`riverpod-3.3.2`,
  `src/core/element.dart` ~764). **A provider's own policy wins over the
  container's.**
* **A provider's `retry` survives `overrideWith`** — including on families.
  Probed directly: an annotated `FutureProvider` overridden to throw, read
  from a *bare* `ProviderContainer`, goes `AsyncLoading → AsyncError` and
  `when()` renders `error`. Same for `FutureProvider.autoDispose.family`.
  This is the load-bearing fact: overriding a provider to fail is how nearly
  every test injects an error, so a policy that did not survive the override
  would be useless here.
* Every async provider form the repo uses accepts `retry:` —
  `FutureProvider` (`future_provider.dart`), `StreamProvider`
  (`stream_provider.dart` ~97), `AsyncNotifierProvider`
  (`async_notifier/orphan.dart` ~60), and their `.family` /
  `.autoDispose` variants. Sync `Provider` accepts it too, where it is
  meaningless.
* **77** async provider declarations exist, in **5** files:
  `app_providers.dart` (68), `pinned_branches.dart` (3),
  `branch_forge_status.dart` (3), `viewer_providers.dart` (2),
  `image_diff_view.dart` (1). None is declared anywhere but at top level.
* A paren-balance scan (walk from the declaration line until parenthesis
  depth returns to zero, skipping `//` lines) resolves the extent of **all
  77** correctly. Line-anchored scans do **not**: 51 declarations end in
  `});` rather than `);`, and 8 more terminate at an indentation because the
  declaration is line-wrapped (`app_providers.dart` ~4150, ~4563;
  `image_diff_view.dart` ~88).

## Decision Drivers

* **Enforcement must not depend on adherence.** The rule has to fail a build,
  not a code review. `AGENTS.md` should be an *index of enforcements*, not the
  enforcement.
* **Prefer removing the failure mode to policing it.** A rule that says "do
  not build a bare scope" still lets someone build one. A policy that travels
  with the provider makes the bare scope harmless.
* **Cost of the guard rail matters.** Freezing today's 400 test sites behind
  an allowlist is a 166-entry artifact that every future test brushes against.
* **No behaviour change in the app.** Production containers already pass
  `noProviderRetry`; `origin.retry ?? container.retry` resolves to the same
  function either way.
* **The existing canon idiom is proven here.** `button_cursor_canon_test.dart`
  shows the shape: a scan over `lib/`, an allowlist with reasons, a message
  naming the correct API.
* **Expect fallout, and treat it as the point.** Tests that currently sit in
  retry-loading will start reaching `AsyncError`. Some will fail. Those were
  passing without exercising anything.

## Considered Options

* **A. Ratcheting source scan over `test/`.** Seed an allowlist with today's
  400 sites across 166 files; fail on any new bare scope.
* **B. Declare `retry: noProviderRetry` on all 77 async providers**, keep the
  container policy as a backstop, and scan `lib/` so new providers must
  declare it.
* **C. A `custom_lint` rule** flagging scope construction without the policy.
* **D. Keep the `AGENTS.md` mandate and the helper.** Status quo.

## Decision Outcome

Chosen option: **"B. Declare the policy on the providers themselves"**, and
— per the maintainer's direction — close the three mandates still resting on
prose (G1–G3 below) in the same cycle, each with the mechanism its invariant
actually calls for.

On the retry question specifically,
because it is the only option that removes the failure mode instead of
guarding it. Once a provider carries its own policy, *any* scope — the app's,
a helper's, or a bare `ProviderContainer()` in a test written by someone who
never read `AGENTS.md` — resolves failures identically. There is nothing left
for a test author to remember, so nothing left for them to forget.

The container-level policy stays. It costs one line per scope and covers
anything not annotated: a provider added before the scan runs, and any
provider the repo does not own.

Enforcement is a paren-balance scan over `lib/` requiring every async provider
declaration to carry `retry:`, in the same shape as the button canon —
allowlist keyed by path with a reason, and a failure message naming
`noProviderRetry`.

`test/helpers/app_scope.dart` is kept but **demoted**: it remains the tidy way
to build a scope, and it still applies the policy to anything unannotated, but
it is no longer load-bearing and `AGENTS.md` must stop implying that
forgetting it breaks error tests.

### Confirmation

* Every async provider declaration in `lib/` carries `retry:`; the scan fails
  if one does not.
* G1: deleting either sandbox key from the committed entitlements fails a
  test; a leftover `.bak` fails it too.
* G2: an adversarial payload routed through any covered service reaches the
  host only as a literal token; removing an `escape()` call fails the test.
* G3: encoding a payload whose text fields carry NULs and pushing it through
  a simulated NUL-lossy codec still round-trips; `stderr`'s wire type is
  asserted like `stdin`'s and `stdout`'s.
* A widget test using a **bare** `ProviderScope` with an overridden,
  annotated provider reaches the `error` branch. This is asserted directly,
  because it is the whole claim.
* `flutter analyze` clean, full `flutter test` green, including whatever
  fallout the change surfaces.
* No production behaviour change: the app's containers already supplied the
  same function.

## Pros and Cons of the Options

### A. Ratcheting scan over `test/`

* Good, because it reuses an idiom already in the repo and needs no
  production change.
* Good, because it stops new drift the day it lands.
* Bad, because the seed is 400 sites in 166 files — an allowlist that large
  is a permanent fixture rather than a burn-down list.
* Bad, because it only *polices*. A test author who wants a bare scope can
  still add an allowlist entry, and the diff looks like the other 165.
* Bad, because it leaves the underlying asymmetry in place: the app and the
  suite still configure the framework differently, and the next divergence
  (an observer, an override, a future scope parameter) repeats this exact
  bug.

### B. Policy on the providers (chosen)

* Good, because a bare scope stops being a trap — correctness no longer
  depends on anyone knowing the rule.
* Good, because `retry` survives `overrideWith`, so it holds for the way
  tests actually inject failures.
* Good, because 77 annotated declarations is smaller than a 166-entry
  allowlist, and the scan that guards it is over one well-known declaration
  form in five files.
* Good, because a missing annotation is a *production* smell too, so the scan
  earns its keep beyond the test story.
* Neutral, because it adds a line of boilerplate per provider.
* Bad, because it will surface failing tests that pass today. That is the
  finding working, but it is real work.
* Bad, because a future provider form the scan does not recognise would slip
  through — mitigated by the container backstop.

### C. `custom_lint` rule

* Good, because it fires in `flutter analyze`, which the workflow already
  gates on before staging, and in the IDE — the fastest feedback of any
  option.
* Bad, because it adds `custom_lint` + `analyzer` dev dependencies and an
  in-repo plugin package to a project that today needs none.
* Bad, because it still polices scope construction rather than removing the
  asymmetry; B makes the lint unnecessary.
* Worth revisiting only if drift continues after B.

### D. Status quo

* Good, because it costs nothing.
* Bad, because it is the thing that failed. The mandate was written on
  2026-08-20 and the very next screen tested under a bare scope would have
  reproduced the bug.

## Consequences

* Good, because the suite and the app agree on framework configuration by
  construction, not by convention.
* Good, because it converts a rule people must remember into a rule a machine
  checks — the general principle this record argues for, now applied to four
  mandates rather than one.
* Good, because the highest-consequence prose-only rule in `AGENTS.md` — the
  entitlements keys, whose failure ships a de-sandboxed app — stops depending
  on a human noticing a `git diff`.
* Neutral, because G2's coverage is only as wide as its payload table. It
  proves the defense holds for the services it drives and does not prove the
  absence of an unescaped site elsewhere. That is still far more than a scan
  would have shown, but it is not a proof.
* Good, because U17's remaining risk (113 unmigrated test files) evaporates
  rather than being tracked.
* Neutral, because `AGENTS.md` keeps the guidance; it just stops being the
  mechanism.
* Bad, because the change touches 77 declarations across 5 files, one of
  which (`app_providers.dart`) is classified as binary by search tools and
  must be edited with `rg -a` / scripted edits.
* Bad, because existing tests may flip from a silent loading state to a real
  error and fail. Each one must be fixed on its merits — never by reverting
  the annotation.

## More Information

### The enforcement ladder this record argues from

| Tier | Mechanism | Status in this repo |
|---|---|---|
| 1. Impossible | Types / language | Dart privacy already enforces the sheet-seam rule: `_MergeOptionsBody` cannot be imported. No mechanism needed. |
| 2. Config | `dart_test.yaml`, git hooks | `live-forge` is `skip:` by default; `prepare-commit-msg` generates messages; the precommit gate runs analyze/format. |
| 3. Analyzer | lints | Stock `flutter_lints` plus the strict language modes. No custom rules (option C). |
| 4. Executable canon | source-scan tests | `button_cursor_canon_test`, `inline_button_canon_test`, `menu_bar_spec_test`, `repository_chrome_contract_test`, and the two scans added by 0016. |
| 5. Prose | `AGENTS.md` | Where a rule stops here, it is a wish. |

### Mandates still resting on tier 5 — now in scope

Originally recorded here as "each deserves its own record". The maintainer
directed that all three be closed alongside this decision, so they are in
scope and carried by [0017-PLAN](./0017-PLAN-provider-retry-policy-on-providers.md)
Phases 6–8. Investigating them produced one correction and one change of
mechanism.

**G1. `Release.entitlements` must keep its sandbox keys.** Filed under
"Critical safety rules" in `AGENTS.md`, guarded only by the build script's
EXIT trap (`build_macos.sh` ~199) and by prose. **No test asserts the
committed file still has them.** The committed file carries
`com.apple.security.app-sandbox`, `network.client`,
`files.user-selected.read-write`, `files.bookmarks.app-scope` and
`keychain-access-groups`; `--unsigned` transiently deletes the first and last
via `PlistBuddy`, restoring from a gitignored `.bak` on exit. A build that
dies mid-run leaves the stripped file on disk *and* a leftover
`Release.entitlements.bak` — which is precisely the state a test should catch
before it reaches a commit. Cheapest and highest-consequence gap on the list.

**G2. `ShellEscaper` on every interpolated value — mechanism corrected.**
A source scan does **not** work here, and specifying one would have been a
mistake. Measured on this tree: the 11 files that build shell text contain
**16** escaped interpolations and **125** bare ones — but nearly every bare
one is an error message (`${result.exitCode}`, `${result.stderr}`), and raw
strings produce false positives on shell syntax (`${TMPDIR:-/tmp}`). A scan
would be ~90% noise, and noise gets allowlisted until it means nothing.
Worse, the syntactic question ("did someone call the escaper?") is not the
invariant anyone cares about.

The invariant is **behavioural**: a caller-controlled value must reach the
host as a single literal token, never as syntax. That is directly testable —
drive the services with adversarial payloads through a recording executor and
assert each payload appears either as its own argv element (which
`CommandFormatter` escapes wholesale) or, inside a composed `sh -c` script,
only in its `ShellEscaper.escape`d form. That tests the defense rather than
the coding habit, and it does not go stale when someone escapes correctly by
a different route.

**G3. Relay payloads as `Uint8List` — partly covered already.** The claim
that "nothing stops a new `String` payload" was half right, and the "the
codec round-trip is tested" half understated what exists.
`exec_proxy_codec_test.dart` already asserts the **wire type** for two of the
three text fields: `'NUL-delimited stdin survives, and travels as bytes on
the wire'` and `'NUL-bearing stdout survives…'` both assert
`isA<Uint8List>()` on the encoded map. What is genuinely missing is narrower
than stated: `stderr`'s wire type is never asserted, and there is no
structural guard — nothing catches a *future* field added as a NUL-bearing
`String`.

The mechanism for that is again behavioural, not syntactic: simulate the
hostile native codec (truncate every `String` value at its first NUL), apply
it to an encoded payload whose every text field carries a NUL, and assert the
decode still round-trips. Any new field that carries command text as a string
fails it automatically, including fields nobody thought to write a test for.

### Mechanism follows the invariant, not the tier

The ladder above says *how strongly* a rule is enforced. It does not say
*which technique* to use, and conflating the two is how a good rule becomes a
noisy scan nobody trusts:

* **Syntactic invariants** — "this widget wraps that one", "this declaration
  carries that argument", "this scope passes that policy" — are what source
  scans are for. They are decidable by looking at one declaration.
* **Behavioural invariants** — "a caller value can never become shell
  syntax", "command text survives a NUL-lossy transport" — need a test that
  exercises the behaviour. A scan can only ask whether a particular *spelling*
  was used, which is neither necessary nor sufficient.

G1 is a third kind: a **committed-artifact** invariant, checked by reading the
file the build ships.

### References

* [0015-MADR](./0015-MADR-ssh-engine-and-ui-unit-test-gaps.md) U17, and the
  two corrections above.
* [0016-PLAN](./0016-PLAN-ssh-engine-and-ui-coverage-tail.md) Phase 9, which
  introduced `noProviderRetry` and the `lib/` scope scan.
* `lib/core/providers/provider_retry_policy.dart`,
  `test/provider_retry_policy_test.dart`, `test/helpers/app_scope.dart`.
* riverpod 3.3.2: `src/core/element.dart` ~764 (resolution order),
  `src/core/provider_container.dart` ~940 (`defaultRetry`, its 10-attempt cap
  and its `Error` carve-out).
