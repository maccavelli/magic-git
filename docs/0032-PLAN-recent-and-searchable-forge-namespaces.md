---
status: "complete"
date: 2026-09-07
associated-madr: "0032-MADR-recent-and-searchable-forge-namespaces.md"
---

# Rank forge namespaces by recent activity, and make them searchable

Associated MADR: [0032-MADR-recent-and-searchable-forge-namespaces.md](0032-MADR-recent-and-searchable-forge-namespaces.md)

## Goal

Replace the create sheet's namespace chips — the account's login plus an
alphabetical head of **7 of 24** creatable groups, leaving 17 unreachable — with
a **recency-ranked** list and a **searchable** field, and fix the two defects
the MADR found in the list that feeds them.

Executes the MADR's chosen options: **1D** (Events API + local history),
**2C** (hybrid local/server search), **3B** (extract the tier function),
**4B** (access-level bucketing), **5B** (the field becomes the search input).

## Scope

### In scope

| Phase | What | Files |
| --- | --- | --- |
| 1 | Extract the palette's match-tier function | `lib/features/common/palette_models.dart`, new `lib/core/utils/match_tier.dart` |
| 2 | Correct + page-walk the creatable-namespace list | `lib/core/gitlab/glab_service.dart:550`, `lib/core/github/gh_service.dart:369` |
| 3 | Recency: forge events → namespaces, plus local history | new `lib/core/forge/namespace_recency.dart`, both services, a prefs store |
| 4 | Compose the providers | `lib/core/providers/app_providers.dart` |
| 5 | The searchable field + dropdown | `lib/features/workspace/create_repo_steps/namespace_suggestions.dart`, `create_repo_sheet.dart`, `lib/core/gitlab/glab_service.dart`, `lib/core/providers/app_providers.dart` (see the 2026-09-07 deviation) |

**0033 Phase 5 already delivered the landing site**: `NamespaceSuggestions` is
its own 79-line `ConsumerWidget` with 5 parameters, not a method at the bottom
of a 2176-line file. Phase 5 here rewrites that widget rather than carving one
out.

### Out of scope

* **GitHub parity beyond degradation.** GitHub namespaces are flat and few (the
  maintainer's account has **0 orgs**), so search is purely client-side there
  and recency has little to rank. Both surfaces must render empty cleanly; they
  do not get bespoke UI.
* Any change to what `resolveOriginUrl` does with the chosen path. MADR 0031
  settled that and live-verified it.
* The `--group` flag. 0031 records why the positional full path is what origin
  resolution understands.

### Preconditions

```sh
flutter --version | head -1          # Flutter 3.47.2
flutter pub get --enforce-lockfile   # "Got dependencies!"
git status --short                   # empty
```

### Baselines (captured 2026-09-07 at `f2bb17e`)

`expect(` **9152**, `testWidgets(` **1012**, suite **3623** passing, 2 skipped.

### Measurements this plan is built on

From the MADR, taken live on 2026-09-06. They decide the design, so they are
repeated here rather than referenced:

| Call | Latency | Result |
| --- | --- | --- |
| `events?after=<7d>&per_page=100` | **0.40–0.81 s** | 100 events (**cap reached**), 11 distinct `project_id` |
| `projects?membership=true&simple=true&per_page=100` | **9.0 s** | disqualifying — never on the critical path |
| `projects/:id` | ~0.5 s | 10 sequential = **3.8 s** → must be concurrent |
| `groups?search=…&min_access_level=30` | **0.67 s** | 37 → **24**; filters compose |
| `gh user/repos?sort=pushed` | 0.43 s | 24 repos |

## Implementation Steps

Five phases, **one commit each**, ordered so each is independently useful:
1–2 fix and sharpen what exists; 3–4 add the data; 5 is the only UI change.

---

### Phase 1 — Extract the match-tier function (3B)

`palette_models.dart:281` `_matchTier` implements exact(0) → prefix(1) →
contains(2) → subsequence(3), which is precisely the "wildcard" semantics the
maintainer described: a typed prefix reaching both a group with that exact name
and a longer one sharing it is a plain prefix case, tier 1. Extract it so
namespaces can rank without becoming palette entries.

**Not option 3A.** Giving namespaces a `PaletteEntryKind` would put a
create-wizard concern into `PaletteQueryScope` and `_scopeAllows`, which every
future palette kind then has to reason about, and namespaces have no palette
actions.

**Steps:** move `_matchTier`'s body and `_subsequence` (`:273`) into
`lib/core/utils/match_tier.dart` as `int? matchTier(Iterable<String> values,
String query)`; `_matchTier` becomes a one-line call passing `entry.searchable`.

**Acceptance:** `palette_models_test.dart` and `workspace_performance_baseline_test.dart`
pass **unedited** — that is the proof the extraction is behaviour-neutral. New
unit tests for `matchTier` land in the same commit, since the function is new
public API.

---

### Phase 2 — A creatable list that is correct and complete (4B)

Two defects in one call, `glab_service.dart:550`:

**2a. `min_access_level=30` is not GitLab's create gate.** The gate is the
group's `project_creation_level` (`noone` / `developer` / `maintainer` /
`administrator`). Measured: **23 of 24** groups are `developer`, **1 is
`maintainer`**. Request `min_access_level` at **30, 40 and 50 concurrently**
(~0.67 s each, in parallel), derive each group's effective access from which
buckets it appears in, and keep a group only when that access meets its
`project_creation_level`. A **null** `project_creation_level` is treated as
permissive — hiding a usable group is worse than a recoverable create failure.

**Not reproducible on the maintainer's account** (Owner on all 24; 30/40/50 all
return 24), so a **fixture test is the only proof**. Say so in the test.

**2b. `per_page=100` silently truncates.** Hand-walk with `per_page`/`page`,
bounded like `_maxListPages`. **Never `paginate: true`** — 0034 F8, and the
comment at `:511` now says why.

> This is the item 0034's tranche-1 plan explicitly deferred to "whichever plan
> executes 0032", because 0032 rewrites the call. That deferral is now paid.

`gh_service.dart:369`'s `user/orgs` was already page-walked in 0034 Phase 3 and
needs nothing here.

---

### Phase 3 — Where "recently active" comes from (1D)

**The conceptual correction the MADR insists on:** a repository cannot be
created *inside* a project, only inside a **namespace**. "Recent projects" must
be projected to *the namespaces of the projects the user was active in* — 11
distinct projects collapsed to far fewer namespaces, which is what makes the
list short enough to be useful.

**3a. Forge events.** `events?after=<7d>` (0.4–0.8 s), take distinct
`project_id`, resolve each to `namespace.full_path`. Events carry `project_id`
and nothing else identifying, so resolution is a second call — **concurrent**
`projects/:id` (0.5 s each; 10 sequential would be 3.8 s), **not** the 9.0 s
membership call.

**Rank by most-recently-touched, not by frequency.** The 100-event page cap was
reached in one week on the maintainer's account, so a frequency ranking is a
biased sample of a truncated page; recency is unbiased under the same cap.

GitHub: `users/<login>/events` — verified to include **private** events when
authenticated as that user.

**3b. Local history.** Namespaces this app has created into, persisted. Warms
the list before any forge call returns and is the answer when the forge is
unreachable or the account is new. Zero API cost, zero coverage on day one —
which is exactly why it is 1D and not 1C alone.

---

### Phase 4 — Compose the providers

A provider yielding, in order: recent namespaces (local history first, refined
by events), then the remaining creatable ones. Deduplicated, capped by what the
signal actually fills rather than a fixed 10.

**Every async provider declares `retry: noProviderRetry`** — enforced by
`provider_retry_policy_test.dart`. **Read through `.asData?.value`, never
`.when()`**: 0030 Phase 1 found that rendering this `AsyncValue` through
`.when()` puts a spinner over the form, and 0031 made the field work with no
list at all. A slow or dead forge must cost the user nothing.

Failures now reach the output log automatically (0034 F1), so a swallowed
namespace fetch is no longer invisible — but it must still not surface as UI
noise.

---

### Phase 5 — The field becomes the search input (5B)

Rewrite `NamespaceSuggestions`:

* **Hybrid search (2C).** Filter the cached creatable list on every keystroke —
  instant, offline, and the common case. Fire a **debounced** (150 ms, the
  `CommandPalette` interval) `groups?search=…&min_access_level=…` to backfill
  anything past the cached page, merged by `full_path`. Server results pass the
  same creatable predicate as cached ones, so search cannot offer a namespace
  the create would reject.
* **Generation counter** to discard superseded responses —
  `command_palette.dart:740-756` is the working precedent.
* **Keyboard** via `CallbackShortcuts` (arrow/enter from inside a focused text
  field), the idiom `command_palette.dart:875-895` documents.
* **The field stays free text and optional.** 0031's contract: a namespace the
  API never returned — a fresh grant, a paginated tail, an unreachable API —
  must stay typeable. **Option 5C (a required picker) was rejected on this
  ground alone and must not creep back in.**
* Chips remain for the zero-typing case, now carrying recent namespaces.

**Search semantics, measured, so the tests assert the right thing:** `search`
matches substrings of name *and* path; it composes with `min_access_level`
(37 → 24); **full-path search works on `/groups`** — an exact `a/b` and a
truncated `a/b`-prefix each returned exactly 1.

## Verification

At the end of every phase:

```sh
flutter analyze
dart format --output=none --set-exit-if-changed <each staged file>
flutter test
printf 'expect=%s testWidgets=%s\n' \
  "$(grep -rho 'expect(' test/ | wc -l | tr -d ' ')" \
  "$(grep -rho 'testWidgets(' test/ | wc -l | tr -d ' ')"
```

Standing rules: `dart format` in place, never chained with `&&` before
`git commit`, never globally; sabotage in a scratch `git worktree`; **read the
whole failure list**.

### Live verification — maintainer-run, and only when asked

The offline suite cannot prove the API shapes. After Phase 5, one
explicitly-requested run against a real GitLab, reusing 0031's `live-forge`
tagging, should confirm: the events window returns namespaces; `search` +
`min_access_level` compose; and a group requiring Maintainer is excluded for a
Developer-only member (**if such an account exists** — the maintainer's is Owner
everywhere, so this arm may be unprovable live and stays fixture-only).

**Never run `live-forge` tests unprompted** (`AGENTS.md`), and **never
interpolate a real namespace into a test name** — 0031 records that leak.

### Acceptance criteria

1. All 24 creatable groups reachable — by scrolling, typing, or recency — not 7.
2. A group whose `project_creation_level` outranks the account's access is
   excluded (fixture test; unprovable on the maintainer's account).
3. The list pages past 100.
4. The field still accepts a namespace the API never returned.
5. No forge call on the wizard's critical path; the form works with the forge
   down, proven by a test with a failing provider.
6. `palette_models_test.dart` unedited through Phase 1.
7. Every new test seen to fail; analyze clean; suite green each phase.

## Execution record

### Phase 1 — 2026-09-07 — *complete*

**Delivered.** `lib/core/utils/match_tier.dart` — `matchTier(Iterable<String>,
String)` and `subsequenceMatch`. `palette_models.dart`'s `_matchTier` is now a
one-line wrapper delegating to it, so the ranking below reads exactly as it did.

**Neutrality proven the way the phase required:** `palette_models_test.dart`,
`command_palette_test.dart` and `workspace_performance_baseline_test.dart` pass
**unedited** — `git diff --stat -- test/` shows no changed files, only the added
`match_tier_test.dart`.

**A small surprise worth noting:** `palette_models.dart` had **zero imports** —
it is a pure model library — so this extraction added its first one. Nothing
wrong with that, but it is the kind of thing a scripted edit assumes away, and
the assumption failed loudly rather than silently.

**Sabotage — four contracts, each seen to fail:**

```
prefix and substring tiers swapped -> ranks exact above prefix above substring…
                                      matches a nested path by any segment
empty query no longer matches      -> an empty query matches everything at tier 0
                                      caps each kind at 50 and the combined list at 100
case sensitivity reintroduced      -> is case-insensitive in both directions
subsequence order not enforced     -> rejects out-of-order characters
```

The second mutation is the interesting one: it breaks a **palette** test as well
as a matcher test, which is the evidence that the extracted function is genuinely
the one the palette runs — not a copy that happens to agree.

**Verification:**

```
flutter analyze (whole project)   No issues found! (ran in 3.6s)
dart format --output=none --set-exit-if-changed   (0 changed)
flutter test (full suite)         03:36 +3634 ~2: All tests passed!
```

**Counts.** `expect(` 9152 -> **9174**; suite 3623 -> **3634**.

### Phase 2 — 2026-09-07 — *complete*

**2a — the create gate is now `project_creation_level`, not
`min_access_level=30`.** `_creatableGroupPaths` fetches the three access floors
(30/40/50) **concurrently** via `Future.wait`, derives each group's effective
access from the highest floor it still appears at, and keeps it only when that
meets what its `project_creation_level` demands. `noone` and `administrator`
are unreachable; a **null** level is permissive, because hiding a usable group
is worse than a create failure the user can retry.

**2b — page-walked**, `per_page`/`page`, stopping on a short page, bounded by
`_maxListPages`. Never `paginate: true` (0034 F8). **This pays the pagination
debt 0034's tranche-1 plan explicitly deferred to "whichever plan executes
0032".**

**One pre-existing test was updated, deliberately.** "asks for groups the
account can actually create in" asserted on `exec.calls.last` — meaningful when
there was one groups call, meaningless now there are three concurrent ones. Its
intent (the `groups` endpoint, not `namespaces`; an explicit host) is preserved
and strengthened: it now asserts **all three floors** are requested and checks
every groups call rather than whichever finished last.

**Two fixture bugs, both mine, both instructive:**

* **A positional queue cannot fixture concurrent calls.** The first version fed
  responses by queue position, but `Future.wait` issues all three floors' page 1
  before any floor's page 2 — so floor 40 received floor 30's second page.
  Symptom: `Expected: <102> Actual: <101>`. Replaced with a **request router**
  on `_FakeExecutor` (`respond`), which answers by argv and is order-independent.
* **`RegExp(r'page=(\d+)')` matches `per_page=100` first.** Every request read
  as page 100, the walk looked finished, and all three filter tests returned
  only the login. The router now uses `(?<![a-z_])page=`, with a comment saying
  why. A production-side version of this mistake would have been a real bug;
  here it only made the fixture lie.

**Sabotage — four contracts, each isolating its own test:**

```
creation level ignored (old behaviour) -> a `noone` group is never offered
                                          excludes a group whose creation level outranks…
null level treated as forbidden        -> a null creation level is treated as permissive
noone treated as ordinary              -> a `noone` group is never offered
page walk removed                      -> walks past the first page of groups
```

**The exclusion arm is fixture-only, and the test says so.** The maintainer's
account holds Owner on all 24 groups, so 30/40/50 return identical lists and
nothing is ever filtered — live verification cannot reach this branch.

**Verification:**

```
flutter analyze (whole project)   No issues found! (ran in 4.2s)
dart format --output=none --set-exit-if-changed   (0 changed)
flutter test (full suite)         03:23 +3639 ~2: All tests passed!
```

**Counts.** `expect(` 9174 -> **9182**; suite 3634 -> **3639**.

### Phase 3a — 2026-09-07 — *complete*

> **Deviation: Phase 3 split into 3a (forge events) and 3b (local history),
> one commit each.** The plan said one commit per phase. 3a is a pair of
> service methods with their own tests; 3b is two persistence stores behind one
> reader/writer. Bundling them would have produced a single diff spanning the
> forge services, `SavedConnection`, a new app-level store and the seam between
> them — reviewable as neither. Each half stands alone.

**`GlabService.recentlyActiveNamespaces`** — `events?after=<date>&per_page=100`,
distinct `project_id` in event order, then **concurrent** `projects/:id` lookups
(capped at `_maxRecentProjects` = 10) to reach `namespace.full_path`. The
one-call alternative, `projects?membership=true`, measured **9.0 s** and is
disqualified for anything the create sheet touches.

**`GhService.recentlyActiveNamespaces`** — one round trip fewer per project: a
GitHub event carries `repo.name` as `owner/repo`, so the namespace is already in
the payload. `users/<login>/events` includes **private** events when
authenticated as that user, verified live in the MADR; a public-only list would
rank the wrong things for anyone whose work is private.

**Ranked by most-recently-touched, not frequency** — asserted by its own test.
The 100-event page cap was *reached in one week* on a real account, so frequency
would be a biased sample of a truncated page.

**Both return empty on any failure**, never throw: the namespace field is free
text and works with no list at all (0031's contract). One unreadable project
does not lose the rest — also its own test.

**Sabotage — four contracts, each isolating its own test:**

```
GitLab: events order not preserved       -> keeps event order — most recently touched first
                                            projects the events onto their owning namespaces
GitLab: unreadable project kills list    -> survives a project it cannot read
GitLab: no window sent                   -> asks only for the window it was given
GitHub: owner not split from repo.name   -> reads the owner straight off the event
```

**Verification:**

```
flutter analyze (whole project)   No issues found! (ran in 3.4s)
dart format --output=none --set-exit-if-changed   (0 changed)
flutter test (full suite)         03:36 +3645 ~2: All tests passed!
```

**Counts.** `expect(` 9182 -> **9191**; suite 3639 -> **3645**.

### Phase 3b — 2026-09-07 — *complete*

**Option B built, with the guardrails the decision came with.**

* **SSH targets** — `SavedConnection.namespaceHistory`, a
  `Map<String, List<String>>` keyed `<forge>@<host>`, following the
  `repoLabels`/`scopedGitDirs` parallel-map idiom exactly: absent means "no
  history", so **existing profiles round-trip with no migration** (its own
  test), and `toJson` omits the key when empty.
* **This Mac** — `core/forge/namespace_history.dart`, SharedPreferences under
  the same key shape.
* **Ad-hoc sessions** — session-only, as decided: there is no record to persist
  into, and inventing one would write under a connection the user chose not to
  save.

**One reader, one writer.** `NamespaceHistory.recent` and `.record` are the
only things that know there are two stores; callers pass the connection (or
null) and never branch. Both stores' doc comments name the other, so neither is
discovered alone — the split MADR 0033 spent five phases undoing is the reason
that mattered.

**Keyed by forge *and* host**, per decision 3, with a test asserting the three
ways that key must not collapse. A GitLab group is not a GitHub org, and two
GitLab instances are two accounts.

**Best-effort by design.** Both paths swallow their own failure: a create that
succeeded must not be reported as failed because *remembering* it did not work.
That is the same judgement as MADR 0034 F9's — except F9 was about a setting the
user chose, so it reports; this is a convenience the user never asked for, so it
does not.

**Sabotage — five contracts, each isolating its own test:**

```
key ignores the forge            -> the key separates forges and hosts
SSH routing removed              -> recording writes it back through the store
history unbounded                -> history is bounded
duplicate not moved to front     -> the most recent use moves to the front …
empty history serialised anyway  -> a profile with no history round-trips unchanged
```

The second needed a second attempt: the first mutation string had been reflowed
by `dart format` and silently failed to apply, so the routing looked pinned when
it was not. Re-run against the formatted text, it fails correctly.

**Verification:**

```
flutter analyze (whole project)   No issues found! (ran in 5.4s)
dart format --output=none --set-exit-if-changed   (0 changed)
flutter test (full suite)         03:37 +3655 ~2: All tests passed!
```

**Counts.** `expect(` 9191 -> **9204**; suite 3645 -> **3655**.

### Phase 4 — 2026-09-07 — *complete*

**`namespaceSuggestionsProvider`** returns a `NamespaceSuggestions` — `recent`
(what the chips show) and `all` (what typing searches) — composed as: local
history first, then the forge's event feed, then everything else creatable.

**A key change the plan did not anticipate.** The key is now
`(Forge, host, local, connectionId?)`, not the three the existing
`forgeNamespacesProvider` uses. The wizard's destination is **editable**, so the
suggestions must follow the chosen connection rather than the active session —
and a namespace is meaningless across accounts. A null `connectionId` is a
This-Mac create, whose history lives in the local store (Phase 3b).

**One composition rule that needed deciding, and is now tested both ways:** a
remembered namespace the account can no longer create in is stale history, not a
suggestion — **but only when the creatable list actually came back**. An empty
`all` means the lookup failed, not that the account may create nowhere, and
dropping every remembered namespace on a failed lookup would be worse than
offering a stale one. Both arms have their own test.

**I rewrote this phase's tests after writing them.** The first version asserted
against `NamespaceSuggestions` the model and called it provider coverage —
`containerWith` was unused by two of the four tests, and the "no-retry policy"
test asserted only `returnsNormally`, which is close to vacuous. The rewrite
drives the real provider with a fake executor answering `events` and
`projects/:id`, so the composition rules are actually exercised. A weak test
that looks like coverage is worse than none.

**Sabotage — three rules, each isolating its own test:**

```
stale history no longer filtered  -> a namespace the account can no longer create in is dropped
failed lookup wipes history too   -> but a FAILED creatable lookup keeps history …
local history no longer consulted -> recent comes from history first, then the forge feed
                                     but a FAILED creatable lookup keeps history …
```

The third needed a second attempt — the mutation string had been reflowed by
`dart format` and silently failed to apply, which reads as "the test does not
catch this" when it means "the sabotage never happened". **Second time this
phase, third this session.**

**Verification:**

```
flutter analyze (whole project)   No issues found! (ran in 4.8s)
dart format --output=none --set-exit-if-changed   (0 changed)
flutter test (full suite)         03:27 +3662 ~2: All tests passed!
```

**Counts.** `expect(` 9204 -> **9215**; suite 3655 -> **3662**.

### Phase 5 — 2026-09-07 — *complete*

> **Deviation 1 (2026-09-07): `NamespaceHistory.record` had no production
> caller.** Phase 3b built the writer and Phase 4 wired the reader, but nothing
> in `lib/` ever called `.record(...)` — `grep -rn "NamespaceHistory" lib/`
> returned only the class itself and the storage fields in
> `saved_connection.dart`. The store `namespaceSuggestionsProvider` reads
> "local history first" from was therefore **permanently empty in production**,
> and the shipped behaviour was decision **1C** (events only), not the chosen
> **1D**. Confirmed pre-existing: the tree was clean at 9 commits ahead and the
> gap arrived with the Phase 3b/4 commits, before Phase 5 opened a file.
>
> **Decision: option A** — wire the recorder at the sheet's success point
> (`create_repo_sheet.dart`, immediately after the `outcome.error` check, where
> the repository is known to exist). Rejected: routing it through
> `CreateRepoDeps` (option B), because `runCreateRepo` has exactly one
> production caller and the indirection buys nothing today; and deferring it to
> a Phase 6 (option C), because the interim commit would ship the rejected 1C.
>
> **Scope added to this phase:** the recording call and its tests in
> `create_repo_sheet.dart`. No new files.
>
> **Deliberately still not done: clone.** MADR option 1C reads "creates *or
> clones* into". Phase 3b narrowed that to creates ("Namespaces this app has
> created into, persisted") and this deviation keeps that narrowing rather than
> widening scope mid-phase. A clone records no namespace today, so a user who
> only ever clones still gets an empty local history.
>
> **No MADR amendment.** The MADR's decision is unchanged and no fact it
> asserts is contradicted — 1D remains the chosen option, and this is what
> makes it true. It never claimed delivery; the PLAN's execution record is the
> only place that did.

> **Deviation 2 (2026-09-07): the scope table under-listed this phase's
> files.** The table named only the widget and the sheet, but the phase body
> specifies a debounced server-side `groups?search=…&min_access_level=…`, which
> needs a service method (`glab_service.dart`) and a provider to reach it
> (`app_providers.dart`). This is a **file-list correction, not a scope
> change** — the work was already approved in the phase body. The table above
> has been corrected in place.

**Delivered.** The namespace field is now the search input (5B).
`create_repo_steps/namespace_suggestions.dart` became
**`namespace_field.dart`**, and the widget `NamespaceSuggestions` became
**`NamespaceField`** — a forced rename, not a preference: the widget must read
`namespaceSuggestionsProvider`, whose value is the Phase 4 *model* class of the
same name. Two `NamespaceSuggestions` in one import graph is the kind of trap
this repository has spent whole MADRs removing.

Three routes to a namespace, in increasing order of effort: **chips** (recency,
zero typing), **the dropdown** (focus the field, every creatable namespace
listed — this is what makes acceptance criterion 1 true), and **typing**
(instant local filtering, plus a debounced server search).

**Hybrid search (2C), both halves.** Local filtering runs on every keystroke
through Phase 1's `matchTier`, over the cached list merged with anything the
server search has since found. `GlabService.searchCreatableNamespaces` is the
server half: `groups?search=…&min_access_level=…` at all three floors
concurrently, **one page each** (a walk on every keystroke would be
indefensible), filtered through the *same* `_creatable` predicate the full list
uses — extracted for exactly that reason, so search can never offer a namespace
the create would reject. GitHub returns nothing by design: its namespaces are
flat and few, so the cached list is already complete.

**Matching on the full path *and* the last segment.** `team/subgroup` is found
by typing `subgroup`. Substring matching alone would also *find* it — the value
of the last-segment arm is **ranking**, which is what its test asserts (see the
survivors below).

**Escape was deliberately not bound.** The first version closed the dropdown on
Escape and the test caught it dismissing the whole sheet instead.
`CommandPalette` documents the rule: dismissal is registry-based and
focus-independent, so a focus-scoped Escape binding fights it and wins only
sometimes. The list closes on choice and on blur; a test now pins that Escape
still reaches the sheet.

**A second deviation, decided during execution and worth reviewing.** A
`CreateRepoOutcome` with no `error` still covers *"the repository was created
locally, but publishing to the forge failed"* — that is a **warning**, because
the local repository is real. Recording there would seed the suggestion list
with a namespace the account never created in. So the recorder fires **only on
a clean run** (no warnings). The cost is the mirror case — a successful forge
create whose origin could not be wired is also a warning, and is not recorded —
which loses a legitimate suggestion but never invents a false one. The precise
alternative is a `forgePath` on `CreateRepoOutcome`, set only where the forge
create succeeds; that touches `create_repo_pipeline.dart` and its 15 tests,
which is why it was not taken unprompted.

**Two fixture defects fixed at the root rather than around.**

* `FakeCreateExecutor` answered **by queue position**, and a create's call order
  shifts with the mode. Three separate attempts to "fail the forge create"
  actually failed `gh auth status`, then `git init`, then nothing at all — each
  reading as a passing test for the wrong reason. It now takes a `respond`
  router, the same fix `forge_namespaces_test.dart` needed in Phase 2 for
  concurrent calls.
* **`SharedPreferences.getInstance()` never settles inside `testWidgets`.** Its
  platform-channel reply needs `runAsync`; in a plain `test()` it throws
  `MissingPluginException` promptly, but under a pumped widget test it simply
  hangs. The history store reads it on the This-Mac path, so the suggestion
  provider sat in `AsyncLoading` forever and **no suggestion rendered at all** —
  which first surfaced as an existing chip test failing. `pumpConnected` now
  seeds `setMockInitialValues({})`. Verified directly, not assumed.

**A production bug the sheet's own tests found.** `_destConnectionId` is null in
connected mode — the destination defaults to *this* session and the picker never
sets an id — so reading it raw sent an SSH create's history to the This-Mac
store, the wrong half of the two-store split. `_effectiveConnectionId` resolves
the active session's id instead. The mutation matrix confirms the test catches
its removal.

**`_search` swallows provider failures.** The service already returns empty on
its own errors, but the provider around it can still fail; the first version let
that escape into the widget. Caught by the test that asserts a failing search
leaves the cached matches standing — which failed, correctly, before the fix.

**Sabotage — eight contracts, run in a scratch `git worktree`, all killed:**

```
last-segment matching removed      -> a last-segment match outranks a mid-word one
debounce removed                   -> a debounced search backfills what the cache lacks
generation check removed           -> a superseded response never replaces a newer one
records even on a warned run       -> a create that fails records nothing
recorder not called at all         -> a successful forge create records it
active connection not resolved     -> a successful forge create records it
search ignores creation level      -> excludes a match whose creation level outranks…
search page-walks every keystroke  -> sends the query at every access floor, one page each
```

**Two of them survived the first round, and both were test defects.**

* *last-segment matching removed* survived because substring matching finds
  `team/subgroup` from `subgroup` anyway — the basename arm only changes
  **rank**. The replacement test asserts the dropdown's **order**, which is the
  contract that arm actually buys.
* *search page-walks every keystroke* survived because the fixture returned an
  **empty** page, which ends any walk after page 1 on its own. The fixture now
  returns a full 100-entry page, so an uncapped walk would ask for page 2.

Both are the same lesson as Phase 4's: a check that has only been seen to pass
is indistinguishable from one that does nothing.

**A redaction caught before commit.** A doc comment in `namespace_field.dart`
named a real group from the maintainer's account as a worked example of the
generation counter — the same identifier this session had already stripped from
this plan. Replaced with a generic one. It never left the working tree, so
there is nothing in history to remedy; recording it because the near-miss is the
point (`AGENTS.md`: an existing redaction is a standing instruction).

**Verification:**

```
flutter analyze (whole project)   No issues found! (ran in 3.5s)
dart format --output=none --set-exit-if-changed   (0 changed, 8 files)
flutter test (full suite)         03:26 +3682 ~2: All tests passed!
```

**Counts.** `expect(` 9215 -> **9254**; `testWidgets(` 1012 -> **1027**;
suite 3662 -> **3682**.

**Acceptance criteria.** 1 met (dropdown lists all, reachable by focus +
scroll or by typing — two tests); 2 met (fixture-only, as the MADR said it
must be); 3 met in Phase 2; 4 met ("a namespace the API never returned stays
typeable"); 5 met (the suggestion providers are stubbed/failed in tests and the
create still composes); 6 met in Phase 1; 7 met — eight mutations, each seen to
fail. **The live verification below remains outstanding and is maintainer-run.**

**Still not done, deliberately:** clone does not record a namespace (see
Deviation 1 above), and GitHub has no server-side search.

### Phase 6 — 2026-09-07 — the recents surface, redesigned

> **Deviation 3 (2026-09-07): Phase 5's presentation was not what was asked
> for.** Shown the shipped sheet, the maintainer said the chips were "not
> exactly my idea" — the recents were meant to be a list of the projects he had
> been most active in, reached from a search bar, not a row of buttons. The
> chips came from MADR 0031 and Phase 5 kept their shape while changing their
> content.
>
> **Two of the three complaints are defects, not taste:** `maxSuggestions = 8`
> silently truncated a service already fetching **10**, and recency was
> surfaced as namespaces (4) where the request said projects (11 → collapsed).
>
> **Decision:** MADR 0032 amended (see its Amendments section); 5B keeps its
> substance and changes its surface. Chosen from three presented options:
> **search-first with a sectioned dropdown**, and **a dedicated search bar**.
> Chips are removed rather than restyled. 1D/2C/3B/4B untouched.
>
> **Deferred and named:** the relative timestamps shown in the option preview.
> The forge feed carries `created_at`, but local history stores none, and
> adding them changes the stored shape Phase 3b designed to need no migration.

### Phase 7 — 2026-09-07 — clone records its namespace too

> **Closes the gap Deviation 1 deliberately left open.** MADR option 1C reads
> "record namespaces the app itself creates **or clones** into". Phase 3b
> narrowed that to creates, and the Phase 5 deviation kept the narrowing rather
> than widening scope mid-phase. Chosen from three assessed options; this is
> **option A**.

**Why A and not the others.** B (clones as a distinct, lower-ranked signal)
buys ranking nuance at the cost of changing `SavedConnection`'s stored shape —
a migration Phase 3b was specifically designed not to need. C (project the
origins of already-registered repos onto namespaces) is retroactive and needs
no write-time hook at all, but origins are cached nowhere: it is one
`git remote get-url origin` per repo in `repoPaths`, so it needs its own cache
before it is affordable. A closes the stated gap with the parts that already
exist.

**Nothing new had to be written.** `ForgeCloneSource` already carries `forge`,
`host` and `slug` fully resolved, so the namespace is `dirname(slug)` with no
parsing at all; `UrlCloneSource` carries a raw URL, and
`forgeHostFromRemoteUrl` / `classifyForgeHost` / `remotePathFromUrl`
(`lib/core/forge/forge.dart:21-56`) already reduce it to the same shape.

**The permission objection, and why it does not block this.** Cloning from a
namespace does not imply *create* permission in it — cloning a well-known
upstream should not offer its owner as a create target. Phase 4's composition
already filters `recent` against `all` whenever the creatable list came back,
so those are dropped without any new code. The only exposure is the deliberate
carve-out: when `all` is empty because the lookup failed, a stale suggestion is
preferred over none. That is a suggestion in a free-text field.

**Clones are where the signal is.** They outnumber creates by a wide margin, so
this is what makes local history non-empty on day one — the exact weakness the
MADR recorded against 1C alone.

**A real bug the tests caught, and the reason its mutation is in the
catalogue.** The obvious way to take "the namespace above the project" is
`dirname(path)` — and it is wrong. `dirname` is filesystem-shaped and answers
`/` for a bare name, so cloning `<host>/my-repo.git` would have recorded a
namespace of **`/`**. It is now an explicit last-slash split with a comment
naming the trap, and `clone: dirname used instead of forge-path split` is in
the mutation catalogue precisely because that is the natural mistake to make
again.

**Phase 6 and 7 verification (one run, both phases):**

```
flutter analyze (whole project)   No issues found! (ran in 4.2s)
dart format --output=none --set-exit-if-changed   (0 changed, 6 files)
flutter test (full suite)         03:42 +3692 ~3: All tests passed!
tool/mutate.py (23 mutations)     23 killed, 0 survived, 0 did not apply
```

**Counts.** `expect(` 9254 -> **9289**; `testWidgets(` 1027 -> **1038**;
suite 3682 -> **3692**. The third skip is the new live-forge file.

**Two intermediate full-suite runs were discarded, not reported.** Both were
started before the edits they would have covered — one mid-redesign, one while
the clone tests were still being written (it showed `-2`, both of them those
tests). A suite run that predates the code it is meant to verify proves
nothing, and reporting it as a pass would be exactly the "check only ever seen
to succeed" failure this plan keeps guarding against.

### Live verification — 2026-09-07 — *run, on request*

Run as `flutter test --run-skipped -t live-forge test/namespace_recency_live_test.dart`.

**The arms had no test.** The plan described them; nothing implemented them.
`create_repo_wire_live_test.dart` covers 0031's namespaced *create*, not 0032's
recency or search. `test/namespace_recency_live_test.dart` is new and is
**read-only** — every call is a GET (`events`, `projects/:id`, `groups`,
`user`), so unlike 0031's live suite it creates, mutates and deletes nothing.
It is still `live-forge` tagged: network-dependent, account-dependent, and its
output describes a real account.

**Results (identifiers deliberately absent — counts carry the argument):**

| Arm | Result |
| --- | --- |
| Events → namespaces | **4 namespaces in 1.9 s** — deduplicated, within the 10-lookup cap |
| Creatable list | **25** entries: the account's own namespace + **24** groups, matching the MADR's measurement |
| `search` composes and narrows | **24 groups → 1** on a leaf-segment needle; every hit was already in the creatable list |
| Creation-level exclusion | **Unprovable, as predicted** — 24 groups at every floor (30/40/50), so nothing can be excluded. Reported as a skip, not a pass |
| GitHub events | **1 namespace**, no `/` in it — the owner is read straight off `repo.name`, no second round trip |

**The 1.9 s confirms the decision.** 1B (`projects?membership=true`) measured
**9.0 s** for the same answer; 1D's two-step is roughly five times faster and is
what makes this affordable on a wizard step.

**One arm was rewritten after its first run, because it proved nothing.** The
needle was initially the *first* path segment of a real group. On an instance
where every group hangs off one root that matches all 24 — the run reported
"narrowed 24 to 24", which satisfies composition but demonstrates no narrowing
whatsoever. Switched to the *last* segment: 24 → 1. The first version would
have been recorded as a passing live verification.

**The exclusion arm stays fixture-only and now says so at runtime**, via
`markTestSkipped` with the reason, rather than asserting something trivially
true on an Owner-everywhere account.

### The sabotage harness, committed — 2026-09-07

`tool/mutate.py` plus `tool/mutations/0032-namespaces.json` (19 mutations).
Previously a scratchpad script; now a repository tool, because it caught two
tests in this plan that only *looked* like coverage.

Re-run against the committed catalogue: **19 killed, 0 survived.** The first
run reported **18 killed, 0 survived, 1 DID NOT APPLY** — the page-walk entry's
`find` string occurs five times in `glab_service.dart`, so it matched twice
after `dart format`. That is the harness reporting a broken *experiment* rather
than a passing *test*, which is the single property it exists for; the entry
was given unique surrounding context and now kills.

**On `mutation_test` (pub.dev).** Evaluated and **not adopted as a
replacement** — see the Considered Options note below. It generates mutations
from operator rules and runs the configured test command per mutation; this
suite is ~3.5 minutes, so a full generated run is measured in hours. The
harness here takes a hand-written catalogue aimed at *named contracts* and runs
only the tests claiming to cover them, which is what makes it usable inside a
single phase. The two are complements: rules find what you did not think to
check, catalogues check what you claimed.

## Rollout and Rollback

**Rollout.** Five commits. Phases 1–2 are independently valuable (a correct,
complete list) even if 3–5 never land. Phase 5 is the only user-visible change.

**Rollback.** `git revert` per phase, reverting 5 → 1. Phase 5 depends on 4,
4 on 3, and 3–5 all use Phase 1's extracted matcher; Phase 2 is independent.

## Decisions — resolved 2026-09-07 by the maintainer

| # | Question | Decision |
| --- | --- | --- |
| 1 | How long is "recently active"? | **7 days** — the window the MADR measured |
| 2 | Where does local history live? | **Per-connection metadata**, not a new prefs key |
| 3 | Is the list keyed by forge + host? | **Yes** — the assumption was right |

**Decision 2's shape.** `SavedConnection` already has the parallel-map idiom for
exactly this — `repoLabels` (`:25`), `scopedGitDirs` (`:34`) and
`fsmonitorPaths` (`:18`), each written through a `withX` helper and persisted by
`connectionStore.updateMetadata`. Namespace history follows it:
`withNamespaceUse(host, namespace)`, keyed by forge + host per decision 3.

**A gap decision 2 leaves, which needs an answer before Phase 3b.** Two of the
three `WorkspaceTarget`s have no `SavedConnection` to hang metadata on:

* **`localMac`** — a This-Mac create has no connection at all, and its forge
  account is the *Mac's own* `gh`/`glab` login. A namespace used from This Mac
  is genuinely not connection-scoped, so per-connection storage does not merely
  lack a home here — it is the wrong shape.
* **`sshProvision` / ad-hoc sessions** — a connection that was never saved has
  no metadata record to update.

`SavedLocalRepo` has no parallel-map analogue either (it carries `label`,
`bookmarkData`, `fsmonitorEnabled`, `gitDir` — no maps).

**Decision 2a (2026-09-07): option B.** Three ways were considered:

* **A.** Persist only for saved SSH connections; This Mac and ad-hoc keep
  session-only history. Simplest, and leaves the most common local case with no
  memory between launches.
* **B.** Add a small app-level store keyed by forge + host for This Mac, with
  `SavedConnection` still owning the SSH case. Correct, but two homes for one
  concept — the kind of split MADR 0033 spent five phases undoing.
* **C.** Key everything by forge + host in one app-level store and skip
  `SavedConnection` entirely — which is a new prefs key, i.e. the option
  decision 2 declined.

**Chosen: B.** The forge account genuinely differs between a This-Mac create
(the Mac's own `gh`/`glab` login) and an SSH host (the connection's), so one
store cannot be keyed correctly for both. Two homes for one concept is a real
cost — the split MADR 0033 spent five phases undoing — so Phase 3b must keep it
honest:

* **One reader.** A single function answers "recent namespaces for this
  (forge, host)" and decides internally which store to consult from the active
  `WorkspaceTarget`. Callers never branch on the target, and there is exactly
  one place to reason about.
* **One writer.** Likewise for recording a use. Nothing outside that pair knows
  there are two stores.
* **The seam is the target, not the caller.** `localMac` reads the app-level
  store; `sshActive`/`sshProvision` read the connection's metadata. A saved
  connection that is later removed takes its history with it, which is correct —
  the namespaces belonged to that account.
* The doc comment on both stores names the other, so neither is discovered
  alone.

Ad-hoc SSH sessions keep session-only history: there is no record to persist
into, and inventing one would mean persisting under a connection the user chose
not to save.
