---
status: "accepted"
date: 2026-09-08
decision-makers: [Maintainer]
consulted: []
informed: [Magic Git contributors]
verified: 2026-09-08
---

# A debugging pass over the three workspace entry points finds nine defects, and one open path nothing records

## Context and Problem Statement

A targeted sweep across the three ways a repository enters this app — **create**
(`create_repo_sheet.dart`, 1577 lines), **clone** (`clone_sheet.dart`, 1301) and
**open existing** (`local_repo_form.dart`, 1089) — together with the machinery
MADR 0033 and MADR 0036 extracted to be shared between them
(`workspace_provisioning.dart`, `workspace_registration.dart`,
`workspace_open_in_tab.dart`, `workspace_destination.dart`, `workspace_targets.dart`).

These three surfaces were rebuilt twice in quick succession — MADR 0033
decomposed them, MADR 0036 gave them a destination step and per-tab routing,
and MADR 0036 Phase 7 brought the third sheet onto the shared mixin. Two
rewrites over one area is exactly where wiring goes stale: a decision applied to
two of three callers, a helper left behind when its caller changed shape, a
guard that moved but whose copy did not.

The cheap signals say nothing is wrong. `flutter analyze` is clean, the suite is
green at 3,768 tests, and every finding below survives both. They were found by
reading the three flows end to end against each other and asking, at each step,
*"does the third sheet do this too, and does anything still call this?"*

Nine findings follow, ordered by severity. Each names file and line and says how
it was established: **traced by reading** (the control flow is followed and the
conclusion is forced by it), **proven by search** (a claim about what does or
does not call something, verified exhaustively), or **confirmed by execution**.
Nothing below is speculative; where a defect needs a condition to bite, that
condition is stated.

Line numbers are as of `f5ea21d`.

## Findings

### F1 — `finalizeProvisioned` records no per-repo recency, so every remote create, clone and open is invisible to Recents *(highest)*

**Proven by search.** `ConnectionController._recordRecentOpen`
(`app_providers.dart:2225`) is the single writer of the per-repo MRU that drives
the landing page's recent list, and — since MADR 0037 Phase 2 — of namespace
recency too. It has exactly three callers:

* `app_providers.dart:1529` — `connect()`, the SSH connect path;
* `app_providers.dart:2018` — `connectLocal()`, the local connect path;
* `app_providers.dart:2414` — `setRepoPath()`, an in-tab repo switch.

`finalizeProvisioned` (`app_providers.dart:2672-2833`) is a **fourth** way a
repository becomes the live workspace, and it calls neither. It is the path
taken by:

* an SSH **create** (`create_repo_sheet.dart:765`, via `finalizeProvisionedInTab`);
* an SSH **clone** (`clone_sheet.dart:581`);
* an SSH **open existing** (`local_repo_form.dart:511`).

So the three newest, most deliberate workspaces a user can produce on a host are
the three least likely to appear in their recent list. `finalizeProvisioned`
does call `connectionStoreProvider.touch(conn.id)` (`app_providers.dart:2797`),
but that is *per-connection* recency — the exact signal `RecentReposStore`'s own
header calls insufficient, because it "floods the list with a multi-repo
connection's never-opened repos" (`recent_repos_store.dart:62-68`).

**This also contradicts a claim MADR 0037 makes about its own coverage.** That
record states the recording is hung off `_recordRecentOpen` so that "all three
opens are covered by construction". The premise was that there are three; there
are four, and the fourth is the one the create/clone/open sheets use for every
remote target. Consequently a namespace learned by creating a repository on a
host is never recorded either, which is precisely the case MADR 0037 exists to
capture.

**Blast radius.** One call site inside `finalizeProvisioned`, after the state
publish. The MADR 0037 machinery is already in place and best-effort by
contract, so nothing new has to be designed — only called.

### F2 — On an ad-hoc SSH session, create and clone silently target This Mac, and the host you are on cannot be chosen at all

**Traced by reading.** Both sheets seed their destination from the live session
in connected mode (MADR 0036, decision 2A):

```dart
_destConnectionId = conn.isLocal ? null : conn.connectionId;
```

— `create_repo_sheet.dart:363`, `clone_sheet.dart:213`.

`ConnectionState.connectionId` is documented as "Active saved-connection id
(**null = ad-hoc**)" (`app_providers.dart:715`). An ad-hoc SSH session is
reachable and supported: `connection_form.dart:47` defaults `_save = true`, but
turning it off leaves `connectionId` null through
`connect(connectionId: null, …)` (`connection_form.dart:179, 275-282`).

For such a session `isLocal` is **false** and `connectionId` is **null**, so the
expression yields `null` — which `_recomputeTarget` then reads as This Mac:

```dart
_target = _destConnectionId == null
    ? WorkspaceTarget.localMac
    : WorkspaceTarget.sshProvision;
```

— `create_repo_sheet.dart:416-418`, `clone_sheet.dart:247-249`.

The user is working on a remote host; the wizard opens pre-set to create or
clone **on their Mac**. The dropdown does show "This Mac", so it is visible
rather than hidden — but it is the wrong default, and it is the opposite of the
decision it was written to implement.

**The second half is worse than the default.** The destination dropdown lists
`This Mac` plus `savedConnectionsProvider` (`workspace_destination.dart:66-79`).
An ad-hoc session has no saved connection, and `WorkspaceTarget.sshActive` is no
longer produced (F6). So on an ad-hoc SSH session there is **no selection at all**
that targets the host the user is on — create and clone can reach their Mac, or
some other saved host, but not the session in front of them. Before MADR 0036,
`sshActive` covered exactly this case.

### F3 — `_openResult`'s local branches use `ref` where the submit deliberately captured `own`

**Traced by reading.** Both sheets capture the container once at submit, with an
explicit reason:

```dart
// Captured ONCE. Sheets live above the root Navigator inside the ACTIVE
// tab's scope (tabs_host.dart), so `ref` follows whichever tab is active —
// the tab opened below, or one the user clicks mid-create, would move it.
final own = ProviderScope.containerOf(context, listen: false);
```

— `create_repo_sheet.dart:502`, and the same at `clone_sheet.dart:352`.

The premise is correct: `TabsHost` wraps the root Navigator in
`UncontrolledProviderScope(container: _controller.active!.container)` and is
"Rebuilt on every tab switch" (`tabs_host.dart:500-505`). A `WidgetRef` in a
sheet therefore re-resolves to whichever tab is active *now*.

`_openResult` then ignores that capture in exactly the branches where it
matters:

* `create_repo_sheet.dart:712` / `clone_sheet.dart:530` —
  `registerAndActivateLocal(ref, …)`, which calls
  `connectLocal` on `ref.read(connectionProvider.notifier)` and reads back
  `ref.read(connectionProvider).isConnected`
  (`workspace_registration.dart:32-35`);
* `create_repo_sheet.dart:719-720` / `clone_sheet.dart:537-538` —
  `saveLocalRepo(ref, …)`.

The `registerAndActivateLocal` case is a genuine session takeover of the wrong
tab: if the user clicks another tab while a local clone runs — seconds, easily —
the finished repository is connected into **that** tab's session, and the
`isConnected` check that decides success reads that tab's state. The same three
lines below use `own` correctly for the no-tab-host fallback
(`create_repo_sheet.dart:727-736`), which is what makes the inconsistency
visible.

`saveLocalRepo` is lower severity: it writes to `localRepoStoreProvider`, a
process-global store that fans out over `StoreBus`, so the misdirected
`ref.invalidate` is redundant rather than wrong. It should still move for
consistency.

**Reachable only for a local target with the "save" toggle in its non-default
state**, because that is what selects these branches — but nothing about the
race is exotic.

### F4 — The add-existing sheet never opens on the destination the user is in

**Proven by search.** `AddExistingRepoSheet`'s state declares
`String? _connectionId;` with no initialiser (`local_repo_form.dart:226`) and
**has no `initState` at all** — the only assignment outside the declaration is
in `_onLocationChanged` (`local_repo_form.dart:328`), i.e. the user's own
selection.

So the sheet always opens on "This Mac", whatever session the user is in. MADR
0036 decision 2A ("the wizard opens on the destination the user is in") was
implemented in create (`create_repo_sheet.dart:360-364`) and clone
(`clone_sheet.dart:210-214`), and MADR 0036 Phase 7 explicitly brought this
sheet under "this record's decisions" — but this one was not carried across. A
user connected to a host who opens *Add Existing Repository* must re-pick the
host every time.

### F5 — Opening the same folder twice through the add-existing sheet produces two saved repos and two tabs

**Traced by reading, forced by two facts.**

1. `_openLocal` mints a fresh id on every submit:
   `final id = DateTime.now().microsecondsSinceEpoch.toString();`
   (`local_repo_form.dart:550`, with a comment explaining only *why it is minted
   early*, not why it is new).
2. `LocalRepoStore.save` de-duplicates **by id only** —
   `[...existing.where((r) => r.id != repo.id), repo]`
   (`local_repo_store.dart:61-64`). There is no `repoPath` comparison anywhere
   in the store.

A fresh id therefore never collides, and the same folder saved twice becomes two
`SavedLocalRepo` rows with the same `repoPath`. The tab layer cannot collapse
them either: `TabsController._find` matches on `connectionId` **and** `repoPath`
together (`tabs_controller.dart:432-438`), and the connection id is the new
one — so `openLocalRepoInTab` opens a second tab on the same folder rather than
focusing the first.

Downstream, `RecentRepoRef.identity` is `'local $id'`
(`recent_repos_store.dart:39`), so one folder now occupies two of the 30 recents
slots and two rows of the Local Repositories list.

**The SSH form already solves this and says so**: `connection_form.dart:182-194`
searches for a saved profile with the same host+user and updates it in place,
"so re-connecting never piles up duplicates, and its repo list is preserved".
The local form has no equivalent.

### F6 — A whole registration branch is dead: `registerAndActivate`, `registerAndActivateSshActive`, and `WorkspaceTarget.sshActive`

**Proven by search** (`lib/` and `test/`, exhaustive):

* `registerAndActivate` (`workspace_registration.dart:132`) — the "whole
  registration matrix in one place" dispatcher MADR 0033 extracted — has **zero
  callers**, in production or in tests.
* `registerAndActivateSshActive` (`workspace_registration.dart:77`) has **zero
  production callers**; only `workspace_registration_test.dart:287-405` drives
  it.
* `WorkspaceTarget.sshActive` (`workspace_targets.dart`) is never produced.
  Both `_recomputeTarget` implementations yield only `localMac` or
  `sshProvision` (`create_repo_sheet.dart:416-418`, `clone_sheet.dart:247-249`),
  and both run from `initState` (`create_repo_sheet.dart:365`,
  `clone_sheet.dart:215`), so the field initialiser
  (`create_repo_sheet.dart:191`, `clone_sheet.dart:115`) never survives to be
  read. Its only remaining appearances are the unreachable summary rows at
  `create_repo_sheet.dart:1434` and `clone_sheet.dart:1099`.

MADR 0036 chose this deliberately — "`sshActive` is no longer produced here —
every tab is its own session" (`create_repo_sheet.dart:412-415`) — but the
branch it replaced was left standing. The cost is not the dead lines; it is that
`registerAndActivateSshActive` is **the only code that registers a new repo into
the *currently active* saved connection's repo list**, and F2 shows there is now
a session shape (ad-hoc SSH) with no route to any of it. The dead code and the
gap are the same hole seen from two sides.

Two further hazards while it stands: the surviving dispatcher's `sshProvision`
branch (`workspace_registration.dart:158-166`) calls `finalizeProvisioned` on
the sheet's own container and **drops `gitDir`** — the identical defect MADR
0036 Phase 7 fixed in `finalizeProvisionedInTab`, preserved here for the next
caller to find.

### F7 — The provision-tab lifecycle is hand-copied into all three sheets

**Confirmed by execution** (`diff` over the four members, comments stripped):

| Pair | Result |
| --- | --- |
| create vs. add-existing | **byte-identical** |
| create vs. clone | identical but for 3 lines of clone's routed-job teardown |

The duplicated block is `_provisionTab`, `_originTabId`, `_ensureProvisionTab`
and `_abandonProvisionTab` — `create_repo_sheet.dart:661-697`,
`clone_sheet.dart:309-344`, `local_repo_form.dart:283-309`. `_opensNewTab` and
`_refusedAtTabCap` are a third identical pair (`create_repo_sheet.dart:478-489`,
`clone_sheet.dart:302-307`, `local_repo_form.dart:313-320`).

This is the same shape, in the same files, that MADR 0036 Phase 7 was written to
end: `WorkspaceProvisioning` took the **dial**, but the **tab lifecycle around
the dial** stayed hand-rolled three times. The mixin already owns
`provisionTarget`, which is the tab's container — it is one field short of
owning the tab.

### F8 — `_openResult` is ~70 duplicated lines across create and clone

**Traced by reading.** `create_repo_sheet.dart:703-770` and
`clone_sheet.dart:521-588` differ only in which sheet's static `scopedAccess`
they read and which label/fsmonitor fields they pass. Every branch — unsaved
local, saved local with bookmark acquisition, no-tab-host fallback, provisioned
SSH with and without a tab — is otherwise identical, including F3's `ref`/`own`
inconsistency, which is duplicated along with everything else. A fix applied to
one copy will silently miss the other, which is how 0022 H4 came to exist in two
sheets while the third was already fixed.

### F9 — Namespace recording is asymmetric between create and clone, and absent for unsaved local work

**Traced by reading.** Three inconsistencies in one signal:

1. **Ordering.** Create records the namespace *before* opening the result
   (`create_repo_sheet.dart:562`, then `_openResult` at 566). Clone records it
   only *after* a successful open (`clone_sheet.dart:437`, after the
   `!registered` early return at 421-428). A clone that lands on disk but fails
   to open therefore forgets where it came from, while the equivalent create
   remembers. The clone's evidence is no weaker — the repository exists either
   way.
2. **Unsaved local work records nothing at all.**
   `registerAndActivateLocal` passes `id: save ? … : null`
   (`workspace_registration.dart:30-33`), and `connectLocal` guards its whole
   recency block on `if (id != null)` (`app_providers.dart:2013-2019`). So an
   unsaved local create or clone updates neither the recent list nor namespace
   history. Defensible for the MRU (there is no bookmark to reopen from), but
   the namespace is real evidence of where the user works and is lost for no
   reason.
3. **Container.** `_rememberNamespace` reads through `ref`
   (`create_repo_sheet.dart:1043-1051`) rather than the captured `own` — the F3
   pattern again. Harmless today because the stores it reaches are
   process-global, and listed only so a future reader does not have to re-derive
   that.

## What was checked and found clean

Reported because "this class is clean" is a result, and the next person should
not have to re-derive it.

* **Controller disposal.** All three sheets dispose every `TextEditingController`
  they declare — create 12/12 (compared by name, not count), clone 7/7, add-existing 2/2.
* **Security-scoped grant lifecycle on a failed local open.** `_auxGrants.add`
  runs at `app_providers.dart:1887`, *before* the validation that can throw at
  ~1955, and `TabsController.close` awaits `disconnect()` before disposing the
  container (`tabs_controller.dart:350-355`), which releases both the primary
  grant and the aux list (`app_providers.dart:2861-2866`). A folder that turns
  out not to be a repository does not leak its grant.
* **`openLocalRepoInTab`'s release-on-no-session guard**
  (`workspace_open_in_tab.dart:93-97`) is correct for both the tab-cap path and
  the dedupe path, and `ScopedAccess.release` no-ops on a path never acquired
  (`scoped_access.dart:52-62`), so the empty-bookmark case is safe.
* **Tab-cap messaging parity.** All three sheets refuse up front with an
  explanation, both inline and in the review step:
  `create_repo_sheet.dart:513, 1468`, `clone_sheet.dart:357, 1124`,
  `local_repo_form.dart:489, 726`.
* **Destination-switch teardown** (0034 F4) is correctly awaited in all three:
  `create_repo_sheet.dart:455`, `clone_sheet.dart:280`,
  `local_repo_form.dart:325`.
* **Remote directory browsing parity.** All three reach the same browser —
  add-existing directly (`local_repo_form.dart:374`), create and clone through
  `workspace_pickers.dart:46`.
* **`finalizeProvisioned`'s identity guard** (`app_providers.dart:2693`) makes
  the 0022 H4 mis-adoption unrepresentable for every caller, including the ones
  that do not guard themselves.

## Decision Drivers

* **A silent gap outranks a visible one.** F1 and F2 both fail without an error:
  the user sees a working repository and simply never sees it again in Recents,
  or sees a wrong default they may not read.
* **Findings that are two views of one hole should be fixed together.** F2 and
  F6 are the ad-hoc/active-session gap seen from the UI and from the dead
  registration branch.
* **Duplication that has already produced a shipped bug is not cosmetic.** F7
  and F8 are the exact shape that put 0022 H4 into two sheets; F8 is currently
  carrying F3 in duplicate.
* **Do not widen scope into a rewrite.** These three sheets have been rebuilt
  twice this quarter. Each fix should be the smallest change that closes the
  hole and leaves a test behind.

## Considered Options

* **A — Fix every finding in one plan, severity-ordered.**
* **B — Fix the silent correctness findings only (F1–F5), and record F6–F9 as
  accepted debt.**
* **C — Fix the correctness findings and consolidate the duplication first, on
  the argument that F7/F8 make every later fix twice as expensive.**
* **D — Record all nine and change nothing now.**

## Decision Outcome

Chosen option: **"C — consolidate first, then fix"**, because two of the nine
findings (F3, F9.1) exist *only* as duplicates, and F8 guarantees that fixing F3
in one sheet leaves it in the other. Consolidating `_openResult` and the
provision-tab lifecycle turns four of the remaining fixes into one edit each,
and the consolidation is mechanical: F7's blocks are byte-identical, and F8's
differ in two named values.

Proposed sequencing, to be detailed in `0038-PLAN-*`:

1. **F1** first and alone — it is a one-call-site fix with the highest user-visible
   payoff, and it needs no consolidation. It also corrects a claim MADR 0037
   makes about its own coverage, which should be amended in the same change.
2. **F7 + F8** — lift the tab lifecycle into `WorkspaceProvisioning` and
   `_openResult` into `workspace_open_in_tab.dart`, with no behaviour change and
   the existing tests as the check.
3. **F3 + F9** on the now-single copy.
4. **F2 + F6** — decide what an ad-hoc SSH session offers as a target. Since
   the 2026-09-08 decision below, F6's *deletion* is no longer gated on this:
   the dead functions' contract is preserved in the ported tests, so they can go
   with step 2. What remains is the F2 choice itself, and it is narrower than
   first stated — the removed behaviour is specified by four of those tests.
5. **F4 + F5** — the add-existing sheet's two independent gaps.

**F2's open question — resolved 2026-09-08 by the maintainer: restore it.** An
ad-hoc SSH session is targetable again. The alternative (refuse, and prompt the
user to save the connection first) was less code and would have made every
target persistable, but it removes a capability that worked before MADR 0036 for
no reason the user asked for. The restored contract is the one the four ported
tests already state: **register nothing, but make the repository live on the
current session** (`workspace_registration_test.dart:381-406`).

### Consequences

* Good, because F1 restores the recency signal for the three most deliberate
  ways a workspace is created, and makes MADR 0037's namespace learning actually
  fire for remote creates.
* Good, because consolidating F7/F8 removes the last hand-rolled copies in these
  three sheets, finishing what MADR 0036 Phase 7 started.
* Good, because each finding names its file and line, so the plan can be
  deterministic and the fixes individually revertible.
* Bad, because step 2 touches all three sheets at once for no behaviour change,
  which is the highest-risk kind of edit in an area covered mostly by
  widget-level tests. The 48 workspace goldens are **not** exposed —
  `workspace_golden_test.dart:311-334` renders the workspace shell
  (`_WorkspaceGoldenFixture`), and none of the three sheets appears in it — so
  the check is the 73 sheet tests, not pixels. It must be verified against the
  existing suite before anything in steps 3–5 builds on it.
* Neutral, because F6's deletion is only safe once F2 is decided — until then
  the dead branch is the record of a capability that was removed, and removing
  it removes the evidence.

### Confirmation

Each finding gets a test that fails against the current tree before its fix
lands, and the sabotage harness (`tool/mutate.py`,
`tool/mutations/0038-*.json`) gets an entry per behavioural fix. Specifically:

* **F1** — a test that finalizes a provisioned session and asserts the repo
  appears in `recentRepoRefsProvider` and its namespace in `NamespaceHistory`.
  It must be seen to fail first; the whole finding is that nothing observes this
  today.
* **F2** — a connected-mode sheet test with `connectionId: null` and
  `isLocal: false`, asserting the resolved target.
* **F3** — a test that switches the active tab between submit and open, and
  asserts which container ended up connected.
* **F4/F5** — sheet tests over the seeded location and over a repeated open of
  one path.
* **F6/F7/F8** — no behavioural test; the existing suite is the check, and the
  acceptance criterion is that it stays green with the duplication gone.
* **F9** — a clone whose open fails, asserting the namespace was still recorded.

## Assessment — would a canonical shared model resolve these findings?

Added 2026-09-08, at the maintainer's request, before any plan is written.

**Short answer: yes for six of the nine findings, no for the two most severe,
and the useful version of "canonical" is not the obvious one.** The evidence
below is what changes the recommendation from "share more UI" to "put a plain,
testable object under the UI".

### The decisive measurement: half of this area was already canonicalised, and that half is healthy

MADR 0033 split each flow into **the work** and **the lifecycle around the
work**. The work half was extracted into plain, widget-free units, and it is the
best-tested code in the area:

| Unit | Lines | Direct tests |
| --- | --- | --- |
| `create_repo_pipeline.dart` | 841 | `create_repo_pipeline_test.dart` — 15 |
| `clone_controller.dart` | 390 | `clone_controller_test.dart` — 14 |
| `finalizeProvisioned` / `connectLocal` (add-existing has no work step) | — | `connection_provisioning_test.dart` — 10 |

The lifecycle half was extracted too — but as a **mixin over widget state**:

```dart
mixin WorkspaceProvisioning<T extends ConsumerStatefulWidget>
    on ConsumerState<T> {
```

— `workspace_provisioning.dart:19-20`.

That `on ConsumerState<T>` is the whole problem. It cannot be constructed
without a widget, so it cannot be driven from a unit test, so it never got one:

| Shared lifecycle unit | Lines | Direct test callers |
| --- | --- | --- |
| `workspace_provisioning.dart` (`ensureProvisioned`, `resetProvisioning`) | 132 | **0** (`resetProvisioning` appears once, inside `clone_sheet_test.dart`) |
| `workspace_open_in_tab.dart` (`openSshRepoInTab`, `openLocalRepoInTab`, `finalizeProvisionedInTab`) | 125 | **0** |

**Not one of the shared lifecycle units is called directly from any test.** All
257 lines — session takeover, tab routing, the security-scoped grant-release
guard — are exercised only as a side effect of pumping three widget UIs across
73 tests and 2,995 lines. That is why F7 and F8 exist and went unnoticed: there
is no level at which a lifecycle invariant is stated once, so a copy that drifts
is invisible.

The one shared unit that *does* have a dedicated test file
(`workspace_registration_test.dart`, 8 tests) splits evenly, and half of it
covers code F6 shows is **dead**: four tests drive
`registerAndActivateLocal`, which is live (called from
`create_repo_sheet.dart:712` and `clone_sheet.dart:530`), and four drive
`registerAndActivateSshActive`, which has no production caller at all. So the
only direct tests of a shared workspace unit are half-aimed at code nothing
runs, while the 257 lines that every flow *does* run have none. That imbalance
is the finding behind the findings.

### Which findings a canonical model actually resolves

| # | Resolved by consolidation? | Why |
| --- | --- | --- |
| F1 — no recency on `finalizeProvisioned` | **No** | Lives in `app_providers.dart:2672-2833`, below all three flows. Independent of how the sheets are shaped. |
| F2 — ad-hoc session untargetable | **No** | Needs a product decision about what an unsaved session offers. A shared target model makes it one place to change instead of two, but does not decide it. |
| F3 — `ref` where `own` was captured | **Yes, structurally** | A plain flow object holds its `ProviderContainer` as a field. There is no ambient `ref` to reach for by mistake — the bug becomes unrepresentable rather than merely fixed. |
| F4 — add-existing never seeds its target | **Yes** | Seeding becomes a constructor argument with one implementation. |
| F5 — no path dedupe on saved local repos | **Partly** | The flow object is the natural home for a "reuse the existing saved repo for this path" step, but the store-level dedupe (`local_repo_store.dart:61-64`) is a separate fix. |
| F6 — dead registration branch | **Yes, as a by-product** | The matrix is replaced or deleted by whatever the flow object does instead. |
| F7 — tab lifecycle copied ×3 | **Yes — this is the definition** | |
| F8 — `_openResult` copied ×2 | **Yes** | |
| F9 — namespace recording asymmetry | **Yes for the ordering half** | One place decides when a completed flow records; the unsaved-local gap (F9.2) is still its own decision. |

Six resolved, one partial, two untouched — and **the two untouched are the two
most severe**. Consolidation is therefore not a substitute for F1 and F2 and
must not delay them. The sequencing already chosen (F1 first and alone) is
unaffected by this assessment.

### What "canonical" should and should not mean here

**Not a shared UI.** The three flows are genuinely different shapes and should
stay that way: create is a 5-step wizard (`destination · source · remote ·
details · review`), clone a 4-step one (`destination · source · location ·
review`), and add-existing is a single-page form with no `WizardStep` at all.
Add-existing also carries the scoped/dotfiles git-dir support that neither other
sheet has or wants (36 references in `local_repo_form.dart`, zero in the other
two). Unifying the presentation would mean inventing a step model that fits none
of them well.

**Not more sharing at the widget layer either.** That is what produced the
current state: a mixin that is shared but untestable, beside 200 lines that were
not shared at all.

**A plain flow object, parameterised by the work.** The lifecycle every flow
runs is identical and already visible in all three `_submit` methods:

1. resolve the target (This Mac / a saved host / — per F2 — the active session);
2. ensure a tab and dial it if remote;
3. **do the work** — create pipeline, clone job, or nothing;
4. open the result: register, activate, route to the tab, record recency;
5. clean up — abandon the tab, release grants, abort the session.

Steps 1, 2, 4 and 5 are common; step 3 is the only genuine difference, and it is
*already* a plain injectable unit in two of the three cases. The shape is the
one MADR 0033 already validated on the work half — it simply was not applied to
the lifecycle half.

### Cost, risk, and what it buys

**Cost.** The duplication is small in volume and concentrated in the
highest-risk code: roughly 200 redundant lines out of 3,967 across the three
sheets (~5%). Measured pairs, comments stripped: the four provision-tab members
are byte-identical between create and add-existing and differ by three lines
from clone; `_onDestChanged` is byte-identical between create and clone (17
lines); `_opensNewTab`/`_refusedAtTabCap` are identical in all three;
`_openResult` is ~68 lines duplicated between create and clone. Every one of
F3, F7, F8 and F9.1 lives inside those 200 lines.

**Risk is lower than a refactor of this size usually implies.** The 48 workspace
goldens do not cover these sheets — `workspace_golden_test.dart` renders the
workspace shell — so there is no pixel surface to break. The check is the 73
sheet tests plus the 29 unit tests over the work half, all of which should pass
unchanged, because the target state is a pure move.

**What it buys, concretely:** a lifecycle invariant becomes assertable once, in
a `test()` with no `pumpWidget`. "Every grant acquired is released when no
session starts", "a dialled tab is closed when the flow is abandoned", "the
container captured at submit is the one the result opens in" are today either
untested or asserted three times through three UIs. That is the difference
between the two halves of this area, and it is the whole reason one half has
nine findings and the other has none.

### Effect on the decision

This assessment **confirms the chosen sequencing rather than changing it**:
F1 first and alone; consolidation second, as a pure move with the existing suite
as the check; the behavioural fixes third, on a single copy. It sharpens step 2
in one respect — the target is a plain object owning the lifecycle, with
`WorkspaceProvisioning`'s widget-bound mixin reduced to a thin adapter, not a
larger mixin. A bigger mixin would consolidate the duplication and leave the
untestability that caused it.

**It also raised one question for the maintainer, now answered — see the
decision below.**

## Decision — port all 8 registration tests onto the flow object

Resolved 2026-09-08 by the maintainer: **port, do not delete.**

Examining what the 8 tests actually cover made this cheaper than expected, and
turned up something that changes F2.

**Four of them already cover live behaviour.** `registerAndActivateLocal` is
called from both wizards, so `save:false calls connectLocal without persisting`,
`a failed connect reports false and persists nothing`, `save:true persists
SavedLocalRepo with bookmark data` and `save:true with empty label passes null
to connectLocal` (`workspace_registration_test.dart:176-286`) are current
specifications of the local-open half of step 4. They port across as-is; only
the call shape changes.

**The other four are the specification for F2's fix.** The
`registerAndActivateSshActive` group (`:287-407`) documents the behaviour MADR
0036 removed, including the ad-hoc case F2 reports as unreachable. Its last
test is explicit:

```dart
testWidgets('without connectionId (ad-hoc) skips metadata mutation', …
  expect(store.updated, isNull);
  expect(conn.recordedSetRepoPath, _dest);
```

— `workspace_registration_test.dart:381-406`. An ad-hoc session **skipped
persistence but still made the repository live on the current session**. That is
exactly the capability F2 says no longer has a route, and it means F2 is not the
open-ended product question this record first framed it as: the removed
behaviour is specified, tested, and recoverable. The remaining choice is only
whether to restore it or to require saving the connection first — and the cost
of restoring is now known to be small, because its contract survives in these
four tests.

**Consequence for sequencing.** F6's deletion stops being gated on F2. The dead
*functions* can go whenever the flow object replaces them, because their
*contract* is preserved in the ported tests rather than in the code. The plan
should port all 8 before deleting anything, so the behaviour is pinned on the
new object first and the delete is a no-op against a green suite.

## More Information

* [0033-MADR-decompose-the-create-repository-sheet.md](0033-MADR-decompose-the-create-repository-sheet.md)
  — the extraction that produced `workspace_registration.dart`, including the
  now-dead dispatcher (F6).
* [0036-MADR-choosing-a-create-destination-while-connected.md](0036-MADR-choosing-a-create-destination-while-connected.md)
  — decisions 2A (seed from the session, F2/F4), 3B (open in a tab), 5B (unsaved
  local opens in place), 6B (the sheet owns its tab, F7), 7A (refuse at the cap).
  Its Phase 7 brought the third sheet onto the shared mixin; F7 and F8 are what
  it did not reach.
* [0037-MADR-namespace-recency-from-repositories-you-open.md](0037-MADR-namespace-recency-from-repositories-you-open.md)
  — the coverage claim F1 contradicts.
* [0034-MADR-debugging-pass-findings.md](0034-MADR-debugging-pass-findings.md)
  — the previous sweep over this area; its F4 (`_onDestChanged`) is re-verified
  clean above.
* [0022-MADR-git-gh-glab-engine-debug-audit.md](0022-MADR-git-gh-glab-engine-debug-audit.md)
  — H4, the mid-dial destination switch that existed in two sheets while the
  third was fixed: the precedent for treating F7/F8 as a correctness concern.
