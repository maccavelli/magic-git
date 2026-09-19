---
status: "accepted"
date: 2026-09-08
decision-makers: [Maintainer]
consulted: []
informed: [Magic Git contributors]
verified: 2026-09-08
---

# Let a create choose its destination, and open the result in its own tab

## Context and Problem Statement

The report that prompted this record: creating a repository on a remote SSH
host is not possible — the create sheet is "limited to the local host". The
maintainer's stated requirement, verbatim:

> "remote ssh hosts should have the same functionality as local … we need to
> be able to choose from the users defined connections in addition to their
> local machine filesystem as the 'local' target directory."

And, on review of the first draft of this record:

> "when a user selects a configured remote host as the local dir target, it
> should create the repo and open it in its own, new repo tab. I want this
> functionality for local created repos also. after create success, open the
> newly created repo in a new tab."

**The observable behaviour is real. The diagnosis is narrower than "not
implemented", and the difference decides what gets built.** Every claim below
was established by running the command shown, not by reading; the plan
repeats the table so execution can re-verify it.

### What already works

Creating on an SSH host works today, in exactly two situations.

**You are already connected to that host.** `_recomputeTarget`
(`create_repo_sheet.dart:388-404`) resolves a connected session to
`WorkspaceTarget.sshActive`; the pipeline runs against the session's executor
(`_executor`, `:453`); `registerAndActivateSshActive`
(`workspace_registration.dart:60-105`) persists the path into the saved
connection and switches the tab to it. **Proven** —
`flutter test test/create_repo_sheet_test.dart --plain-name "plain create: git init -b main in the parent, then activates"`
passes against a session with `host: 'h'`, `connectionId: 'c1'` — an SSH
session, not a local one (`create_repo_harness.dart:182-188`) — and asserts
`git init -b main -- new-proj` reaching that host's executor.

**You are on the landing page**, with no session. The wizard shows a
**Destination** step listing *This Mac and every saved connection*
(`WorkspaceDestinationSection`, `workspace_destination.dart:16-67`). Picking a
host dials it on demand (`WorkspaceTarget.sshProvision`), the create runs on
the dialled session, and `finalizeProvisioned` promotes it into the workspace
(`workspace_registration.dart:146-157`).

### What is actually missing

One predicate, present identically in both sheets:

```dart
// create_repo_sheet.dart:188   (clone_sheet.dart:114 is byte-identical)
applicable: () => widget.landing,
```

It is the **only** conditional step in either wizard (`grep -c "applicable:"`
→ 1 in each). The entry points choose the variant purely on whether a session
exists (`app_shell.dart:409-416`; `connection_switcher.dart:1057-1066`):

```dart
final connected = ref.read(connectionProvider).isConnected;
builder: (_) => connected
    ? const CreateRepositorySheet.connected()
    : const CreateRepositorySheet.landing(),
```

So any user with a workspace open gets a wizard with **no destination
control**, targeting whatever that session already is. With a local repo open
— the common case — every create goes to This Mac. That is the reported
experience.

**The choice is not merely ignored when connected; it is unreachable.** The
chain is closed: `_onDestChanged` (`:430`) is referenced only at `:779`,
inside `_destinationSection` (`:776`), which is used only at `:190` as the
`body:` of the step gated at `:188`. And `_recomputeTarget`'s connected
branch derives the target from `conn.isLocal` and never reads
`_destConnectionId`; the field's only read (`:400`) is in the landing `else`.

### Why the choice was gated — the real constraint

Not an oversight. **A tab owns exactly one session, and dialling claims it.**
`ConnectionController.beginProvisioning` (`app_providers.dart:2382-2445`)
runs, before the new host is even reachable:

```
ScopedAccess.instance.release(state.repoPath!)   // local grants gone
_releaseAuxGrants()
_lastRepoPath = null
_hostLogins.clear()
_invalidateRepoState()                            // every repo provider
outputLogProvider.clear()                         // the log the user is reading
executorProvider.resetEnvironment()
binaryEnvironmentProvider.clear()
```

On the landing page there is no session, so claiming the tab costs nothing.
In a connected tab the same call **destroys the workspace the user is standing
in** — mid-edit, with its output log and sandbox grants gone — in order to
create a repository somewhere else. Gating the step was the correct call
given one session per tab. What was missing was a way to reach another host
*without* claiming this tab's session.

### The mechanism that removes the constraint already exists

Every tab is its own `ProviderContainer`, and therefore its own
`ConnectionController` and its own SSH session — `tabs_controller.dart:105-107`:
*"Each tab is a full live session (its own SSH client/socket or local
access)."* `TabsController.openOrFocus` (`:258-300`) runs its `connect`
callback **against the target tab's container** (`connect(tab.container)`,
`:300`), de-duplicates against open tabs, and reuses a blank landing tab. It
is reached from sheets through the static `TabsController.current`
(`tabs_host.dart:126`), which six files already use — the connection
switcher, the command palette, the saved-workspace actions among them.

More than that: **each destination already has a production "open this
repository in its own tab" path**, and none of them is in the create sheet:

| Destination | Existing path, verbatim | Where |
| --- | --- | --- |
| SSH, any saved host | `openOrFocus(connectionId: conn.id, repoPath: repo, savedKind: ssh, connect: (c) => c.read(connectionProvider.notifier).connectToSaved(conn, repoPath: repo))` | `connection_switcher.dart:776-783` |
| This Mac, a saved repo | `resolveSavedLocalRepo` (acquire bookmark → grants) → `openOrFocus(connectionId: repo.id, savedKind: local, connect: connectLocal(…))`, then **release the grants if `connect` never ran** — a leaked grant lasts the app's lifetime | `connection_switcher.dart:1122-1170` |
| A host with no session yet | `ensureProvisioned()` → `runCreateRepo(executor: …)` → `finalizeProvisioned(…)` — the landing flow | `create_repo_sheet.dart:464-510` |

The create pipeline is Riverpod-free and takes its executor as a parameter
(MADR 0033 Phase 4), so running it against another tab's executor is a
call-site change. The provisioning mixin reads `ref` in exactly three places
(`workspace_provisioning.dart:66,87,112`), all of them `read`s that a
`ProviderContainer` can serve.

### What is genuinely absent, then

1. **The destination choice in connected mode.**
2. **Opening the result in a new tab.** Today both registration paths end by
   *switching the current tab*: `setRepoPath(dest)`
   (`workspace_registration.dart:105`) and `connectLocal(dest)` (`:33`).
   The requirement is that the current tab is left alone and the new
   repository gets its own.
3. **End-to-end coverage of the provisioned create.** The only two
   landing-mode tests are `create_repo_sheet_test.dart:1339` ("dials without
   waiting for submit") and `:1376` (MADR 0034 F4's mid-hang-up guard). The
   single `createButton()` tap after line 1300 (`:1318`) belongs to the
   **connected** test at `:1304`. No test has ever driven an `sshProvision`
   create to completion, and no `live-forge` test has created on a real SSH
   host — MADR 0031/0032's live runs used `LocalCommandExecutor`.

## Decision Drivers

* **The user's session is not ours to destroy.** Any design under which a
  wizard can end the workspace someone is working in is disqualified outright.
* **No prerequisite connection.** Picking a host must work whether or not a
  session to it is open anywhere. The dial is part of the create.
* **Reuse over reimplementation.** The destination control, target enum,
  provisioning mixin, registration matrix and tab machinery are all shared and
  in production. MADR 0033 spent five phases removing duplicates between these
  two sheets; a fix that forks any of them re-creates that drift.
* **Parity between clone and create.** The gate is byte-identical in both.
* **Truth in the wizard.** The Destination step's own copy promises "on this
  Mac, or on one of your saved SSH hosts." A connected user is never shown it.
* **Coverage before exposure.** The provisioned path is real but its
  end-to-end behaviour is untested. Adding a second route to it converts a
  hidden capability into a visible, unverified one.
* **Honest limits over silent no-ops.** Wherever the machinery can decline —
  the tab cap, a missing bookmark — the wizard must say so before running,
  not fail quietly after.

## Considered Options

**Decision 1 — how a connected sheet reaches another host.**

* **1A.** Take over the current tab's session (show the step; let
  `beginProvisioning` do what it does).
* **1B.** Offer only This Mac and the current session.
* **1C.** Run the work in another tab, via `openOrFocus`.
* **1D.** A sheet-scoped second session, owned by the sheet rather than a tab.

**Decision 2 — what the destination list contains.**

* **2A.** This Mac + every saved connection, defaulting to the current session.
* **2B.** As 2A, but hiding hosts already open in another tab.
* **2C.** Current session + This Mac only.

**Decision 3 — where the result opens.**

* **3A.** In the current tab when the destination is the current session;
  elsewhere otherwise.
* **3B.** Always in a new tab.
* **3C.** Ask.

**Decision 4 — clone parity.**

* **4A.** Both sheets, together.
* **4B.** Create only; clone later.

**Decision 5 — a local create with "Save to Local Repositories" turned off.**
(Opening in a new tab needs a security-scoped bookmark for the new folder;
`registerAndActivateLocal` creates one only when `save` is true —
`workspace_registration.dart:36-52`. The toggle defaults on,
`create_repo_sheet.dart:153`, but is visible.)

* **5A.** Force the save whenever the result would open in a new tab.
* **5B.** Respect the toggle: an unsaved create opens in the current tab, as
  today, and the Review step says so.
* **5C.** Remove the toggle.

**Decision 6 — when the new host is dialled.**
(The landing flow dials on destination *selection*; pinned by
`create_repo_sheet_test.dart:1339`.)

* **6A.** On selection, as today — the tab is opened when the host is picked.
* **6B.** On submit — the tab is opened only once the user commits.

**Decision 7 — the tab cap.**
(`openOrFocus` at `maxTabs` returns the active tab and **never runs
`connect`** — `tabs_controller.dart:289-292` — a silent no-op.)

* **7A.** Check `canOpenTab` before running; refuse with a message.
* **7B.** Fall back to the current tab.
* **7C.** Let it no-op.

## Decision Outcome

Chosen options: **1C, 2A, 3B, 4A (sequenced), 5B, 6B, 7A.**

**Together they reduce to one rule:** *a create runs where it can and opens
where it lands, and the tab the wizard was opened from is never touched.*

**1C over 1A** because 1A is the disqualifying case: it is what the machinery
does *today* with the gate removed, and the gate exists precisely to prevent
it. **Over 1B** because 1B answers a different complaint — reaching a host you
are not connected to is exactly the missing case. **Over 1D** because every
consumer of "the session" (`activeExecutorProvider`, the forge services, the
watcher, the output log, `registerAndActivate`) is written against the
container's, and a session with no tab has no owner for its teardown — the
exact shape of the stranded `phase: connecting` session MADR 0022 H4 and
MADR 0034 F4 were both about.

**3B over 3A** — reversed from this record's first draft at the maintainer's
direction — and it **simplifies decision 1 further than 1C alone.** Every tab
is its own session, so under 3B *every* SSH create ends with **one new dial**
for the new tab, whichever session ran the `git init`. The "current session"
case is therefore no cheaper than the "other host" case: one dial each. So
`sshActive` buys nothing for creates, and **every SSH create takes the
provisioning path in its own new tab**. One SSH path instead of two, and no
surgery on `registerAndActivateSshActive` to stop it switching the tab — the
create sheet simply stops calling it. Clone and `AddExistingRepoSheet` keep
using it unchanged.

**3B also settles decision 2's open detail.** With one SSH path, the current
session is not routed differently, so it needs no marker; it stays the
**default selection** because the wizard should open on "where you are".
**2A over 2B** because the new repository's path is new by construction —
`_find` (`tabs_controller.dart:424-436`) never matches, and a fresh tab is
always opened whichever hosts are already open. Hiding rows by unrelated tab
state would make the list change for reasons the user did not cause.

**No prerequisite connection, in either direction.** You need not be
connected to the host to create there — the new tab dials it. And being
connected to it elsewhere changes nothing — the new repository still gets its
own tab.

**5B over 5A** because forcing the save would silently override a choice the
user made on the same screen; **over 5C** because removing a working control
to serve a new feature is scope creep. The cost of 5B is that an unsaved local
create behaves as today, which the Review step must say plainly.

**6B over 6A** because a tab opened on selection exists before the user has
committed, and a cancelled wizard would then have to close a tab it opened —
a second lifecycle to unwind. A tab that exists only after submit has exactly
one owner. The cost is the dial latency at submit; the wizard already renders
"Connecting…" for precisely that wait.

**7A over 7B** because for a host with no session there *is* no current-tab
fallback that does not destroy the user's workspace; a fallback that works
only for some destinations is a trap. **Over 7C** because a create that
silently does nothing is the worst outcome on this list. The one exception:
an unsaved local create (5B) opens in the current tab and is not gated by the
cap, since it opens no tab.

**4A, sequenced.** The gate is identical in both sheets, and MADR 0033 exists
because they drift when one is changed alone. But clone is the one place this
is not free: `cloneJobProvider` is a per-container `NotifierProvider` holding
the job's progress (`clone_controller.dart:388`), and the sheet `ref.watch`es
it for its progress bar (`clone_sheet.dart:480`). A clone routed to another
tab runs its job in *that* container, so the sheet must `listen` to the target
container's provider rather than watch its own. Small, but a different shape
from create — so clone is its own phase rather than a parity sweep.

### Consequences

* Good, because the reported limitation disappears: any saved host, connected
  or not, is one selection away, for both sheets.
* Good, because every create now leaves the user where they were and puts the
  new repository where it belongs — consistent with how opening a repository
  on another connection already behaves.
* Good, because the new code is the routing decision and nothing else: the
  destination control, target enum, provisioning mixin, registration matrix,
  three open-in-tab paths and tab machinery are all reused unchanged.
* Good, because one SSH path replaces two; `sshActive` leaves the create flow.
* Neutral, because creating into the session you are in now opens a tab
  rather than switching — a deliberate behaviour change, at the maintainer's
  direction, and the plan's Phase 2 pin for that case is updated with the
  reason in the test.
* Neutral, because an SSH create waits for a dial at submit. The landing page
  pays the same dial; it merely paid it earlier.
* Bad, because the sheet gains a routing branch and a container it does not
  own, and a wizard that hands work to another tab is harder to reason about
  than one that cannot.
* Bad, because an unsaved local create is now the odd one out — it is the only
  case that opens in the current tab. Decision 5 accepts this; the Review step
  carries the explanation.
* Bad, because it makes an **untested end-to-end path reachable by a new
  route**. Coverage is a precondition, not a follow-up.

### Confirmation

1. A connected sheet — local **and** SSH — shows the Destination step listing
   This Mac and every saved connection, defaulting to the current session.
2. **Every** successful create opens the new repository in its own tab, and
   the tab the wizard was opened from is unchanged: still connected, same
   repo, output log intact. Asserted directly against the list of what
   `beginProvisioning` destroys.
3. A host with no open session anywhere is created on and opened, with no
   prior connection.
4. An unsaved local create opens in the current tab, and the Review step says
   so before submit.
5. At the tab cap the wizard refuses with a message and runs nothing.
6. A create that fails after its tab was opened leaves no extra tab and no
   session at `phase: connecting`.
7. The `sshProvision` create is covered end to end, and that coverage lands
   **before** the behaviour change.
8. Clone behaves identically for 1–6, with progress shown for a routed job.
9. The MADR 0022 H4 (mid-dial switch) and MADR 0034 F4 (mid-hang-up dismiss)
   guards hold, exercised through the new path.
10. Every new check is seen to fail against a deliberate defect.

## Pros and Cons of the Options

### 1A. Take over the current tab's session

* Good, because it is the smallest diff — delete one predicate.
* Bad, because it destroys an active workspace to serve a wizard: grants
  released, log cleared, repo state invalidated, none of it reversible.
* Bad, because the failure lands hardest on the user who most wanted the
  feature — deep in one workspace, creating in another.

### 1B. This Mac and the current session only

* Good, because it needs no session work.
* Bad, because it does not address the report.
* Bad, because a list omitting saved hosts contradicts the step's own text.

### 1C. Run the work in another tab

* Good, because it reuses the mechanism already used to open a repository on
  another connection, de-duplication included.
* Good, because the current session is untouched by construction.
* Bad, because the sheet must decide which container runs the work, for every
  combination of session and destination.

### 1D. A sheet-scoped second session

* Good, because conceptually clean.
* Bad, because every consumer of "the session" would need a second path.
* Bad, because a session with no tab has no owner for its teardown.

### 2A / 2B / 2C

* **2A** — one list everywhere; a host open elsewhere simply gets a second tab
  for the new repository, which is the intended result.
* **2B** — the list changes with unrelated tab state.
* **2C** — does not solve the problem.

### 3A / 3B / 3C

* **3A** — preserves today's current-session behaviour; two behaviours
  instead of one; keeps `sshActive` in the create flow.
* **3B** — one behaviour; collapses the SSH paths to one; changes the
  current-session case deliberately.
* **3C** — a prompt for a question the destination choice already answered.

### 5A / 5B / 5C

* **5A** — every create opens in a tab; overrides a visible choice silently.
* **5B** — respects the toggle; one case behaves differently, and says so.
* **5C** — removes a working control to serve a new feature.

### 6A / 6B

* **6A** — the session is ready by submit; a cancelled wizard must close a tab
  it opened.
* **6B** — dial latency at submit; the tab has exactly one owner.

### 7A / 7B / 7C

* **7A** — honest, up front, works for every destination.
* **7B** — works only where a current-tab fallback exists, which is not the
  hard case.
* **7C** — a create that does nothing.

## More Information

**Revision history.** The first draft of this record (2026-09-08, same day)
chose 3A and left three questions open: how to mark the current session's
row, what to do when a destination is already open in another tab, and
whether to reuse a blank tab. The maintainer's direction that *every* create
should open in its own tab reversed decision 3 to 3B, which dissolved the
first two questions (see Decision Outcome) and answered the third by
`openOrFocus`'s existing blank-tab rule. It also surfaced decisions 5–7, none
of which the first draft had seen. The record was consolidated rather than
patched because it had not been accepted; nothing decided was overwritten.

**Coverage is a precondition.** Confirmation item 7 lands before item 1. The
plan's Phase 1 is tests only, with `git diff --stat -- lib/` empty.

**Live coverage is a separate decision.** No `live-forge` test has ever
created on a real SSH host. Adding one is mutating and host-dependent and is
out of scope here.

**Grant hygiene is load-bearing.** The local open path's release-on-decline
guard (`connection_switcher.dart:1160-1170`) exists because a security-scoped
grant acquired for a session that never started leaks for the app's
lifetime, and a linked worktree acquires two. Moving that block into a shared
function is the one place this plan touches sandbox behaviour, and it is
tested with a counting `ScopedAccess` double.

**Related records.** MADR 0033 (why the two sheets share one destination
control, one provisioning mixin and one registration matrix); MADR 0022 H4 and
MADR 0034 F4 (the mid-dial and mid-hang-up hazards the routing must not
reintroduce); MADR 0031/0032 (the forge side of a create — *where the
repository is created on the forge* — which this record does not touch: it
concerns only where the working copy lands and which tab shows it).
