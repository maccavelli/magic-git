---
status: "proposed"
date: 2026-09-06
decision-makers: [Maintainer]
consulted: []
informed: [Magic Git contributors]
verified: 2026-09-06
---

# Rank forge namespaces by the user's own recent activity, and make the list searchable instead of truncated

## Context and Problem Statement

[0031-MADR-forge-namespace-on-create.md](0031-MADR-forge-namespace-on-create.md)
gave the create-repository wizard a namespace field and a row of suggestion
chips. The field works: a full path typed into it creates the project there, and
origin resolves to the same path (live-verified 2026-09-05, two levels of
nesting).

The **suggestions** do not work. The maintainer's report is that the chips show
"a seemingly random sample of projects/paths ... available, but not necessarily
ones I want to use." That report is accurate, and the cause is not randomness —
it is that the chip row answers a different question than the one the user is
asking. The user is asking *"where do I usually put things?"*; the chip row
answers *"which groups sort first alphabetically?"*

Two enhancements are requested:

1. A **"Recently active"** list — the namespaces the user has actually been
   working in over the previous week — rather than an alphabetical head.
2. A **wildcard search** attached to the namespace input, so typing `devop`
   offers both `devop`-prefixed groups the account can reach, and the user picks
   the right one from a dropdown. Search must return only namespaces the account
   can actually use.

This record establishes what the forge APIs can and cannot supply, what each
option costs in latency, and which machinery the repository already has.

### Evidence: why the current chips are unhelpful

`GlabService.listCreatableNamespaces` (`lib/core/gitlab/glab_service.dart:535`)
issues one call — `groups?min_access_level=30&per_page=100` — and
`_namespaceSuggestions` (`lib/features/workspace/create_repo_sheet.dart:1455`)
renders `.take(8)` of the result, the first element being the account's own
login. **The user therefore sees their login plus 7 groups.**

Measured against the maintainer's real GitLab account on 2026-09-06 (read-only
`glab api`; all figures are counts, no paths reproduced):

| Measurement | Value |
| --- | --- |
| Groups returned at `min_access_level=30` | **24** |
| — of those, subgroups (path contains `/`) | **22** |
| — path depth 1 / 2 / 3 | **2 / 18 / 4** |
| — distinct top-level ancestors | **2** (23 under one, 1 under the other) |
| Groups shown as chips | **7** of 24 |
| Groups the user can never see in the sheet | **17** of 24 |
| Groups visible without `min_access_level` | **171** (2 pages: 100 + 71) |

The returned order is alphabetical, but by a field the chips never display.
Verified directly: the list **is** sorted by `name` compared case- and
punctuation-insensitively (`true`), and is **not** sorted by `full_path`
(`false`) or by `id` (`false`). `name` is the group's leaf display name;
the chip shows `full_path`. GitLab's documented default for `GET /groups` is
`order_by=name, sort=asc`, which matches.

That mismatch is real but second-order, and the honest measurement says so:
re-sorting the 24 by `full_path` moves entries a **mean of 2.0** positions
(max 11), and **6 of the 7** currently-shown chips would still be in the first 7
of a path sort. So the perceived randomness is not mainly an ordering-key bug.

**The dominant cause is the truncation itself.** Alphabetical order carries no
information about relevance, so taking its first 7 of 24 is, from the user's
point of view, an arbitrary sample — and no amount of re-sorting alphabetically
fixes it. The fix has to change the *ranking signal*, not the sort collation.

### Evidence: the list is also slightly wrong, and silently bounded

Two defects in the current call, neither user-visible on this account:

* **`min_access_level=30` is not GitLab's create gate.** Creating a project in a
  group is governed by the group's `project_creation_level`, whose documented
  values are `noone`, `developer`, `maintainer`, and `administrator`. Of the 24
  groups, **23 are `developer` and 1 is `maintainer`**; across all 171 visible
  groups only those two values appear and **none is null**. A Developer-only
  member of that one group would be offered a namespace the create would reject.
  Not reproducible on this account: `min_access_level` of 30, 40 and 50 all
  return **24**, so the account holds at least Owner everywhere and **0 groups
  are currently mis-offered**. The code path is still wrong.
* **`per_page=100` with no pagination silently truncates.** 24 fits today. An
  account with more than 100 creatable groups would lose the tail with no
  indication. Note the ceiling is on *creatable* groups; this account can already
  *see* 171.

### Evidence: what "recently active" can be sourced from

GitLab's Events API is the only endpoint that reports **the user's own**
activity. Measured over `after=<7 days ago>&per_page=100`:

| Source | Latency | Result |
| --- | --- | --- |
| `events?after=<7d>&per_page=100` | **0.40–0.81 s** | 100 events (page cap reached), **11 distinct `project_id`s** |
| `projects?membership=true&simple=true&per_page=100&order_by=last_activity_at` | **9.0 s** | 100 projects; resolves 11/11 of the event project ids |
| `projects/:id` (single) | ~0.5 s | one project |
| `projects/:id` × 10, sequential | **3.8 s** | ten projects |

Event `action_name` distribution over the week: `pushed to` 73, `pushed new` 16,
`transferred` 7, `created` 3, `deleted` 1 — dominated by push activity, which is
the signal wanted.

Three facts constrain the design:

* **Events carry `project_id` and nothing else identifying.** No namespace, no
  path. Turning events into namespaces requires a second lookup.
* **`simple=true` does include what is needed** — the project object carries
  `namespace` (with `full_path`) and `path_with_namespace` — but the membership
  call that returns it costs **9.0 seconds**. That is disqualifying for anything
  on the wizard's critical path, and it is measured from this Mac over HTTPS;
  the SSH backend adds an exec round-trip on top.
* **`per_page=100` on events is a cap that was reached.** A week of this
  account's activity does not fit in one page, so a naive single call sees only
  the most recent 100 events. For a *top-N by frequency* ranking that is a
  biased sample; for *most-recently-touched* it is exactly right.

**A conceptual correction the request needs.** The request asks for "the 10
projects with the most user activity." A repository cannot be created *inside* a
project — only inside a **namespace** (a user or a group). The useful projection
is therefore *the namespaces of the projects the user has been active in*, and it
collapses hard: 11 distinct projects in a week map to far fewer distinct
namespaces. That is a feature, not a loss — it is what makes a short list useful
— but it means the surface should be labelled by namespace, and 10 is more slots
than the signal will usually fill.

On GitHub the same shape holds with different costs. This account has **0
organisations**, so its namespace list is just the login and both features
degrade to nothing. Where orgs do exist: `users/<login>/events?per_page=100`
returned 100 events across **14 distinct repos** and **does include private
events** when authenticated as that user; `user/repos?sort=pushed&per_page=100`
returned 24 repos across 1 owner in **0.43 s**. GitHub namespaces are flat and
few, so client-side handling suffices there.

### Evidence: what server-side search can do

The wildcard search the maintainer described is available server-side today.
Measured, reporting counts only:

| Probe | Result |
| --- | --- |
| `groups?search=<5-char prefix>` | **37** groups |
| same + `min_access_level=30` | **24** groups — the filters compose |
| `groups?search=<same prefix + 1 non-matching char>` | **0** — the endpoint really matches |
| `groups?search=<4-char subgroup leaf path>` | **3**, of which **2** are subgroups |
| `groups?search=<exact full path `a/b`>` | **1** |
| `groups?search=<full path minus its last 3 chars>` | **1** |
| Latency of `search` + `min_access_level` + `order_by=similarity` | **0.67 s** |

Three conclusions:

* The maintainer's exact example works: a shared prefix returns every group
  carrying it, so `devop` reaching both a `devop…` group and a `devop…-…` group
  is a plain prefix match, server-side, in one call.
* **Full-path search works on `GET /groups`.** Both an exact `a/b` and a
  truncated `a/b`-prefix returned the single right group. The documented caveat
  that "only subgroup short paths are searched (not full paths)" is stated for
  the *subgroups* endpoint, not for `/groups`, and `/groups` behaves better than
  a naive reading suggests. This matters: it means a user can narrow by typing
  a parent segment.
* `order_by=similarity` is accepted alongside `search` and is the documented way
  to rank by relevance to the query rather than by name.

### Evidence: the repository already has this machinery

Nothing here needs a new matching algorithm or a new interaction pattern. Both
exist, are pure, and are already unit-tested.

* **Ranking.** `rankPaletteEntries` / `_matchTier`
  (`lib/features/common/palette_models.dart:281,314`) implements a deterministic
  tiered match — exact (0), prefix (1), contains (2), subsequence (3) — then
  focus, then `recency`, then label, then id, with per-kind and total caps.
  Tiers 1 and 2 are precisely the "wildcard" semantics requested, and the
  `recency` field is already a first-class tiebreaker. Covered by
  `test/palette_models_test.dart`.
* **Debounced remote query with out-of-order protection.** `CommandPalette`
  (`lib/features/common/command_palette.dart:740-756`) cancels a pending
  `Timer`, increments a **generation counter**, and fires the fetch after
  **150 ms**, discarding responses from a superseded generation. Other debounces
  in the tree run at 400/500/600 ms.
* **Keyboard-driven list from inside a text field.** The same file (`:875-895`)
  uses `CallbackShortcuts` for arrow-up/down/enter, with a comment explaining
  why that beats `DefaultTextEditingShortcuts` — the exact problem a dropdown
  attached to a search input has to solve.
* `MacosPopupButton` is used at `create_repo_sheet.dart:1347`, but a popup button
  renders a fixed list and cannot filter. The palette pattern is the precedent
  that fits; the popup button is not.

### Evidence: a hazard the implementation must not step into

`GlabService.api` accepts `paginate: true`, and its comment
(`glab_service.dart:511-514`) asserts that "the merged pages then come back as
one clean JSON document." **That is false.** Fetching the 171-group list with
`--paginate` produced **two** JSON documents concatenated with a `][` seam;
`json.load` fails with `Extra data`. `_runJson` hands the body to
`decodeJsonMaybeOffThread`, so any multi-page `paginate: true` call raises
`GlabException: ... returned non-JSON output`.

This is currently harmless — `grep -rn "paginate: true" lib/` finds **no call
sites**, only the comment on `mergeRequests` explaining why it is hand-walked —
but "just fetch all the groups" is exactly the temptation this work creates. Any
page walk must be hand-rolled with `per_page`/`page` against `_maxListPages`, as
`mergeRequests`, `jobs` and `pipelines` already are.

## Decision Drivers

* **The suggestion must answer "where do I put things?"** — relevance, not
  alphabetical position, is the ranking signal. This is the whole request.
* **The wizard must never wait on the forge.** 0031 established that the
  namespace field is free text and works with no list at all; the suggestion
  layer renders through `.asData?.value` precisely so a slow or dead forge costs
  the user nothing (`.when()` would put a spinner over the form — 0030 Phase 1).
  A 9 s call cannot enter the critical path.
* **Only offer what the account can actually use.** Both features must filter to
  creatable namespaces; offering one that the create rejects is worse than
  offering nothing.
* **Typing must remain the contract.** Any namespace — a fresh grant, a
  paginated tail, an unreachable API — must stay typeable. Search augments the
  field; it must not become a required picker.
* **Parity without pretence.** GitHub and GitLab differ in what they can supply.
  Where GitHub cannot match GitLab, the surface should degrade quietly rather
  than fabricate a ranking.
* **Reuse the tested machinery.** A second fuzzy matcher and a second debounce
  idiom in the same codebase are a maintenance cost with no benefit.
* **No identifier leakage.** Group paths are internal identifiers. Nothing in
  the implementation, its tests, or its test *names* may carry a real one — a
  live-run leak of exactly this kind is already recorded against 0031.

## Considered Options

The work decomposes into four decisions. Options are listed per decision;
the recommendation for each is stated in **Decision Outcome**.

**Decision 1 — where "Recently active" comes from.**

* **1A. Events API, projected to namespaces.** `events?after=<7d>` → distinct
  `project_id`s → namespaces, resolved by a bounded batch of `projects/:id`.
* **1B. `projects?membership=true&order_by=last_activity_at`.** One call, no
  events, no id resolution.
* **1C. Local usage history.** Record namespaces the app itself creates or
  clones into; rank by the app's own recency. No API call at all.
* **1D. Events, with local history as the warm-start and fallback (1A + 1C).**

**Decision 2 — how search resolves.**

* **2A. Client-side only**, filtering the already-fetched creatable list.
* **2B. Server-side only**, a debounced `groups?search=…&min_access_level=…`.
* **2C. Hybrid** — filter the cached list on every keystroke for an instant
  result, and fire a debounced server search to backfill entries the cached page
  never held, merging by `full_path`.

**Decision 3 — the ranking implementation.**

* **3A. Reuse `rankPaletteEntries`** by adding a namespace `PaletteEntryKind`
  and a `PaletteQueryScope`.
* **3B. Extract the tier function** (`_matchTier`) into a shared pure helper and
  give namespaces their own small ranker over it.
* **3C. A bespoke matcher** for namespaces.

**Decision 4 — the creatable-namespace filter.**

* **4A. Keep `min_access_level=30`.**
* **4B. Bucket by access level and compare against `project_creation_level`** —
  request `min_access_level` at 30/40/50 (concurrently), derive each group's
  effective access, and keep a group only when that access meets what its
  `project_creation_level` demands.

**Decision 5 — the surface.**

* **5A. Keep chips, re-ranked.** Recency-ordered chips; no search.
* **5B. Chips plus a filtering dropdown on the namespace field.** The field
  itself becomes the search input; a dropdown opens beneath it as the user
  types; chips remain for the zero-typing case and carry the recent namespaces.
* **5C. Replace the field with a required picker.**

## Decision Outcome

Chosen options: **1D**, **2C**, **3B**, **4B**, **5B** — because together they
change the ranking signal from alphabetical position to the user's own recent
activity, make everything beyond the top few reachable by typing, and do it with
matching and debounce machinery the repository already has under test, without
putting any forge call on the wizard's critical path.

Specifically:

* **"Recently active" is sourced from the Events API and projected to
  namespaces** (1D). It is the only endpoint that reports *the user's* activity
  rather than *a project's*, it costs **0.4–0.8 s**, and the 9 s membership call
  is avoided entirely. Id-to-namespace resolution uses a bounded batch of
  `projects/:id` (measured 0.5 s each, ~10 needed) issued concurrently on the
  read lane, not the 9 s bulk call. Local usage history warms the list before
  any forge call returns and remains the answer when the forge is unreachable or
  the account is new. The list is labelled **by namespace**, deduplicated, and
  capped at what the signal actually fills rather than a fixed 10.
* **Search is hybrid** (2C). The cached creatable list is filtered locally on
  every keystroke, so the common case is instant and offline; a **150 ms**
  debounced `groups?search=…&min_access_level=…` (0.67 s measured) backfills
  anything past the cached page, merged by `full_path`. Server results are
  filtered through the same creatable predicate as the cached ones, so search
  cannot surface a namespace the create would reject.
* **The tier function is extracted, not the whole ranker** (3B). Namespaces are
  not palette entries: giving them a `PaletteEntryKind` and a `PaletteQueryScope`
  would put a create-wizard concern into the palette's scope enum and its
  `_scopeAllows` switch, which every future palette kind then has to reason
  about. Extracting exact/prefix/contains/subsequence into a shared pure function
  keeps one matcher in the codebase with none of that coupling.
* **The creatable filter is corrected** (4B). This costs two extra concurrent
  calls at ~0.67 s each, off the critical path, and removes a class of offer
  that the create would reject. A group whose `project_creation_level` is absent
  is treated as permissive — hiding a usable group is worse than a recoverable
  create failure. Ceiling behaviour is fixed at the same time: the page walk is
  hand-rolled, **never** `paginate: true`.
* **The namespace field becomes the search input** (5B). It stays free text and
  stays optional, so 0031's contract is intact; the dropdown is an affordance
  over it, driven by the palette's `CallbackShortcuts` idiom. Chips remain for
  the zero-typing case and now carry recent namespaces instead of an
  alphabetical head.

GitHub follows the same structure with its own endpoints — login plus orgs for
the creatable set (flat and small, so search is purely client-side),
`users/<login>/events` for recency. Where an account has no orgs, as the
maintainer's does, both surfaces render empty, which is correct.

### Consequences

* Good, because the first thing the user sees is where they last worked, which
  is the question the chip row was silently failing to answer.
* Good, because all 24 creatable groups become reachable — today 17 of 24 cannot
  be selected from the sheet at all — and the >100 ceiling stops being silent.
* Good, because it removes a real correctness defect (offering groups whose
  `project_creation_level` outranks the user's access), even though this account
  cannot currently reproduce it.
* Good, because the wizard gains no new way to block: every call stays off the
  critical path and behind `.asData?.value`, so a dead forge still renders a
  working free-text field.
* Good, because one matcher and one debounce idiom serve both the palette and
  the wizard.
* Bad, because the create sheet grows a dropdown, an overlay and keyboard
  navigation — `create_repo_sheet.dart` is already 2176 lines, and this argues
  for extracting the namespace control into its own widget rather than adding to
  it in place.
* Bad, because "recently active" is a heuristic. A user creating a repository in
  a namespace they have never touched gets no help from it, and the week window
  is a guess that will be wrong for some workflows.
* Bad, because the events page cap (100, reached on this account in one week)
  makes *frequency* ranking a biased sample. Ranking by most-recently-touched is
  unbiased under the same cap and is what should be built.
* Neutral, because GitHub gains little: flat namespaces, few orgs, and zero on
  the maintainer's account. The code must be written so that "nothing to show"
  is an ordinary state rather than an error.

### Confirmation

* Unit tests for the extracted tier function pinning the four tiers against
  namespace-shaped inputs, including the requested case — one query matching
  both a bare segment and a longer segment sharing its prefix — and including a
  path containing `/`.
* Provider tests over a fake executor asserting that: events are projected to
  distinct namespaces; a group whose `project_creation_level` outranks the
  account's access is excluded; a non-JSON or failing response yields an empty
  list rather than an error state; and the local history warm-start renders
  before any forge call resolves.
* Widget tests over the existing `test/helpers/create_repo_harness.dart`
  asserting that typing filters the dropdown, that arrow/enter select without
  disturbing the caret, that a selection lands in the namespace field as a full
  path, and that the field remains usable with an empty and with a failing
  suggestion source.
* A test asserting the page walk is bounded and that `paginate: true` is not
  used on the new endpoints.
* **Each new check is to be run against a deliberately broken input and seen to
  fail before it is relied on**, against scratch copies rather than by dirtying
  the tree.
* Live confirmation is a maintainer-run, explicitly-requested step. It must
  reuse 0031's `live-forge` tagging and must not interpolate a real namespace
  into a test name — 0031 already records that leak.

## Pros and Cons of the Options

### 1A. Events API, projected to namespaces

* Good, because it is the only source that reflects **the user's** activity,
  which is what was asked for.
* Good, because it is fast: 0.40–0.81 s measured.
* Good, because `after=` bounds the window server-side.
* Neutral, because it needs a second lookup to reach namespaces; events carry
  only `project_id`.
* Bad, because `per_page=100` was reached in one week on this account, biasing
  any frequency-based ranking.
* Bad, because it is empty for a new or idle account.

### 1B. `projects?membership=true&order_by=last_activity_at`

* Good, because one call returns everything needed — `simple=true` includes
  `namespace.full_path` and `path_with_namespace`.
* Bad, because it measured **9.0 seconds**, an order of magnitude worse than
  every alternative, before the SSH backend's round-trip is added.
* Bad, because `last_activity_at` is *the project's* activity, not the user's: a
  busy project the user has never touched outranks one they pushed to yesterday.
  It answers the wrong question.

### 1C. Local usage history

* Good, because it costs nothing, works offline, and is exactly right when it
  has data.
* Good, because it is the only option that survives an unreachable forge.
* Bad, because it is empty on first run and stays empty for a user who creates
  repositories rarely — which is most users of a create wizard.
* Bad, because it cannot know about work done outside this app.

### 1D. Events plus local history

* Good, because the local list renders instantly and the events list refines it.
* Good, because it degrades to something useful in both failure directions: no
  forge, or no local history.
* Bad, because two sources must be merged and deduplicated, and their orderings
  reconciled.

### 2A. Client-side only

* Good, because it is instant, offline, and adds no API surface.
* Bad, because it cannot find what the cached page never held — precisely the
  >100-group case this record set out to fix.

### 2B. Server-side only

* Good, because it always searches the full set and composes with
  `min_access_level`.
* Good, because `order_by=similarity` gives relevance ranking for free.
* Bad, because every keystroke waits ~0.67 s even when the answer is already in
  memory, and each one is an exec round-trip on the SSH backend.

### 2C. Hybrid

* Good, because the common case is instant and the uncommon case is still
  reachable.
* Good, because it keeps working with the forge down, degrading to 2A.
* Bad, because results arrive in two waves, and the list must not reorder under
  the user's cursor when the second wave lands.
* Bad, because it needs generation-counter discipline to discard superseded
  responses — already solved in `CommandPalette`, but it must be repeated.

### 3A. Reuse `rankPaletteEntries` via a new `PaletteEntryKind`

* Good, because it reuses the ranker whole, including caps and tiebreakers.
* Bad, because it puts a create-wizard concern in `PaletteQueryScope` and
  `_scopeAllows`, which every future palette entry kind must then account for.
* Bad, because namespaces have no palette actions, so `allowedActionIds` and the
  entry's action machinery would be dead weight.

### 3B. Extract the tier function

* Good, because one matching definition serves both callers.
* Good, because the extracted function is pure and directly testable, and the
  existing palette tests keep covering the palette's use of it.
* Neutral, because it touches `palette_models.dart`, so the palette's tests must
  be re-run to prove the extraction is behaviour-neutral.
* Bad, because namespaces need their own small sort (recency, then tier), so a
  little ranking logic is duplicated in spirit if not in code.

### 3C. A bespoke matcher

* Good, because it is unconstrained by the palette's model.
* Bad, because it puts a second fuzzy-matching definition in the codebase, which
  will drift from the first.

### 4A. Keep `min_access_level=30`

* Good, because it is one call and already written.
* Bad, because it does not match GitLab's actual create gate and can offer a
  namespace the create rejects — 1 of this account's 24 groups requires
  Maintainer.

### 4B. Bucket by access level against `project_creation_level`

* Good, because it matches the documented gate and removes the bad-offer class.
* Good, because the extra calls are concurrent, ~0.67 s, and off the critical
  path.
* Neutral, because it cannot be demonstrated on the maintainer's account, which
  holds Owner on all 24 groups — a fixture test is the only way to prove it.
* Bad, because it triples the request count for the creatable list.

### 5A. Chips, re-ranked

* Good, because it is the smallest change and reuses the existing widget.
* Bad, because it does not deliver the search half of the request, and leaves
  everything past the first few chips unreachable.

### 5B. Chips plus a filtering dropdown on the field

* Good, because it delivers both halves and keeps the field free text, so 0031's
  contract is untouched.
* Good, because the interaction pattern is already implemented and commented in
  `CommandPalette`.
* Bad, because it grows an already-large file, and argues for an extraction that
  the phase must budget for.

### 5C. A required picker

* Good, because it removes invalid input by construction.
* Bad, because it breaks 0031's explicit decision that a namespace the API did
  not return must stay typeable — a fresh grant, a paginated tail, or an
  unreachable API would become unusable. Rejected on that ground alone.

## More Information

* [0031-MADR-forge-namespace-on-create.md](0031-MADR-forge-namespace-on-create.md)
  — the namespace field this record builds on, its free-text contract, the
  `--group` trap, and the live verification of nested-subgroup creation.
* [0030-MADR-test-coverage-gaps-are-shaped-not-sized.md](0030-MADR-test-coverage-gaps-are-shaped-not-sized.md)
  — Phase 1's finding that rendering a derived `AsyncValue` through `.when()`
  puts a spinner over the form; the reason suggestions read `.asData?.value`.
* Code: `lib/core/gitlab/glab_service.dart:479` (`api`, and the incorrect
  `--paginate` comment at `:511`), `:535` (`listCreatableNamespaces`);
  `lib/core/github/gh_service.dart:369`;
  `lib/core/providers/app_providers.dart:5378` (`forgeNamespacesProvider`);
  `lib/features/workspace/create_repo_sheet.dart:1455`
  (`_namespaceSuggestions`); `lib/features/common/palette_models.dart:281,314`
  (`_matchTier`, `rankPaletteEntries`);
  `lib/features/common/command_palette.dart:740-756,875-895` (debounce with
  generation counter; `CallbackShortcuts`).
* GitLab API documentation: [Groups](https://docs.gitlab.com/api/groups/)
  (`GET /groups` parameter table, `order_by` default `name`, `search`,
  `min_access_level`, `top_level_only`, `order_by=similarity`,
  `project_creation_level` values),
  [Events](https://docs.gitlab.com/api/events/) (`after`/`before`, `action`,
  `target_type`, event fields incl. `project_id`),
  [Projects](https://docs.gitlab.com/api/projects/) (`membership`,
  `order_by=last_activity_at`, `simple`, `namespace.full_path`).
* GitHub API documentation:
  [Organizations](https://docs.github.com/en/rest/orgs/orgs),
  [Users](https://docs.github.com/en/rest/users/users).
* Prior art: [CircleCI capped its GitLab/GitHub repository pickers at 100
  entries](https://circleci.com/changelog/repository-search-for-gitlab-and-github-app-is-now-limited-to-100-most)
  "in order to prevent timeouts for customers with a large number of
  repositories", ordering GitLab's by most recently updated and GitHub's
  alphabetically, and called it a stopgap until search arrived. The same
  pairing — a short recency-ranked default list, with search for everything
  past it — is what this record proposes, arrived at from the same constraint.
* All measurements in this record were taken on 2026-09-06 from this Mac over
  HTTPS with read-only `glab`/`gh` calls. No mutating call was made. Group and
  project identifiers are deliberately reported as counts only.
