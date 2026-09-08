---
status: "in-progress"
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
| 5 | The searchable field + dropdown | `lib/features/workspace/create_repo_steps/namespace_suggestions.dart`, `create_repo_sheet.dart` |

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
