---
status: "proposed"
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
