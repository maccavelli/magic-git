---
status: "proposed"
date: 2026-09-09
decision-makers: [Maintainer]
consulted: []
informed: [Magic Git contributors]
verified: 2026-09-09
---

# The macOS build edits a tracked, signed input while Xcode is reading it — and has shipped that edit three times

## Context and Problem Statement

A second machine, building the same commit that builds cleanly here, failed
twice in a row. The second failure names the mechanism outright:

```text
error: Entitlements file "Release.entitlements" was modified during the build,
which is not supported. You can disable this error by setting
'CODE_SIGN_ALLOW_ENTITLEMENTS_MODIFICATION' to 'YES', however this may cause the
built product's code signature or provisioning profile to contain incorrect
entitlements. (in target 'Runner' from project 'Runner')
** BUILD FAILED **
```

The first failure, on the same machine and immediately before it, was different
in symptom and adjacent in cause:

```text
Set: Entry, ":CFBundleShortVersionString", Does Not Exist
File Doesn't Exist, Will Create: …/Release/Magic Git.app/Contents/Info.plist
Command PhaseScriptExecution failed with a nonzero exit code
** BUILD FAILED **
```

Neither is caused by the change that prompted the rebuild: everything in that
push is under `lib/`, `test/`, `docs/` and `tool/` — `git diff --name-only`
across the range returns nothing under `macos/`, nothing in `build_macos.sh`,
nothing in `pubspec.*`.

What both have in common is the subject of this record. **`build_macos.sh` and
the Xcode project each reach into build state that the build system does not
know they are touching** — one by editing a signed input in place, the other by
writing into a product bundle without declaring that it depends on it. Both are
machine- and timing-sensitive, which is why one laptop fails and another does
not, and why the same laptop failed two different ways in five minutes.

The entitlements half is not a latent risk. It has already shipped.

## Findings

### F1 — The build edits a tracked file that Xcode is signing from

`macos/Runner.xcodeproj/project.pbxproj:676`, the Runner target's **Release**
configuration:

```text
CODE_SIGN_ENTITLEMENTS = Runner/Release.entitlements;
```

That is a direct input to `ProcessProductPackaging`, which produces the `.xcent`
that `CodeSign` applies. `build_macos.sh:193-206` rewrites that exact file, in
place, on every `--unsigned` build:

```sh
ENT="$SCRIPT_DIR/macos/Runner/Release.entitlements"
cp "$ENT" "$ENT.bak"
trap 'mv -f "$ENT.bak" "$ENT" 2>/dev/null || true' EXIT
/usr/libexec/PlistBuddy -c "Delete :keychain-access-groups" "$ENT" …
/usr/libexec/PlistBuddy -c "Delete :com.apple.security.app-sandbox" "$ENT" …
```

So the file is written twice on the way in and once more on the way out, by a
process Xcode has no relationship with. Xcode's check compares the entitlements
as it recorded them against what it finds when it signs; anything that moves in
between is the reported error.

**Why the stripping exists at all**, because it is not gratuitous and cannot
simply be deleted: `keychain-access-groups` requires a signing certificate, and
removing the sandbox is what puts `$HOME` at the real home directory so the
0600 credentials fallback lands in `~/.config/magic_git/` rather than inside an
app container. The ad-hoc development loop genuinely needs different
entitlements from a signed build. The defect is not *that* they differ — it is
*how* the difference is produced.

### F2 — The stripped entitlements have been committed three times

This is the finding that decides the record. The tracked file's history, by
whether it still contains `com.apple.security.app-sandbox` and
`keychain-access-groups`:

| Commit | Date | Keys | Subject |
| --- | --- | --- | --- |
| `2d8a357` | 2026-07-06 | 2 | Initial Commit |
| `0789fee` | 2026-07-15 | **0** | build(macos): automate version stamping from git tags |
| `8871d49` | 2026-07-15 | 2 | feat(tags): overhaul tag management and remote synchronization |
| `a968b81` | 2026-07-15 | **0** | feat(ui): improve git divergence indicator visibility |
| `b70c800` | 2026-07-15 | 2 | chore(macos): update entitlements for app sandbox and permissions |
| `a008925` | 2026-07-23 | **0** | chore(macos): update entitlements configuration |
| `3964c19` | 2026-07-23 | 2 | build(macos): update entitlements for app sandbox and security |

Three strips, three repairs, twice within one day. Two of the three arrived
inside commits about something else entirely — a UI change and a tag-management
change — which is what "a build died and nobody noticed the working tree was
still stripped" looks like from the outside.

The `.bak` file has been committed too, and the repository says so in its own
`.gitignore:54-57`:

```text
# Transient backup build_macos.sh --unsigned makes while it strips the
# entitlements for the build; its EXIT trap restores and removes it. It only
# exists mid-build (or after a killed build) and must never be committed —
# it once was, swept up alongside a real change (81aa5cf, repaired since).
```

So the hazard is known, documented in two places, and has fired at least four
times.

### F3 — The rule was prose, then became a test — and the test cannot tell a live build from a dead one

**Correction to an earlier draft of this record**, which claimed the rule lived
only in prose. It does not, and the timeline matters:

| | Date | |
| --- | --- | --- |
| `0789fee`, `a968b81` stripped | 2026-07-15 | prose only |
| `a008925` stripped | 2026-07-23 | prose only |
| `ec18bd8` adds `test/macos_entitlements_canon_test.dart` | 2026-08-20 | enforced |
| — | since | nothing stripped has shipped |

So the sequence is the one this repository keeps rediscovering: `AGENTS.md`
carried the rule, the rule was violated three times, and a guard was written in
response. The guard is good — it asserts that `Release.entitlements` *grants*
(not merely mentions) the sandbox key, that `keychain-access-groups` is present,
that three further load-bearing grants survive, that `DebugProfile.entitlements`
keeps the sandbox, and that no `.bak` is left behind.

**What the guard cannot do is the point.** It catches the symptom at commit
time. It does not prevent the mutation (F1), the build failure (F5), the
destroyed backup (F4), or a developer's working tree sitting stripped for the
length of a build.

And it carries a false positive it cannot remove, for the same underlying
reason. Its own comment names the ambiguity:

> Its presence means a build is in flight **or** died; in the second case the
> test above is already failing and this says why.

Because a legitimate build strips the tracked file and creates the `.bak`,
running `flutter test` while `./build_macos.sh --unsigned` is running fails —
two assertions at once — and the suite cannot distinguish that from the
dangerous state. A guard on a file that the build legitimately mutates has to
conflate "this is happening right now" with "this went wrong". That is not a
flaw in the test; it is F1 surfacing a second time, in the test suite instead of
in Xcode.

Under a design where nothing strips the file, both halves of the ambiguity
disappear: the `.bak` never exists, the tracked file is never mid-mutation, and
the guard becomes an invariant that is true at every instant rather than only
between builds.

### F4 — A second failed run destroys the backup the first one made

The recovery path has a hole that turns one interrupted build into permanent
loss of the working tree's good copy:

```sh
cp "$ENT" "$ENT.bak"        # unconditional
```

There is no check for a pre-existing `$ENT.bak`. So:

1. Run 1 strips the file, dies before its `EXIT` trap completes (a `SIGKILL`, a
   crash, a `mv` that fails). `Release.entitlements` is left **stripped**;
   `Release.entitlements.bak` holds the **good** copy.
2. Run 2 starts and immediately does `cp "$ENT" "$ENT.bak"` — copying the
   *stripped* file over the *good* backup. Both copies are now stripped.
3. Run 2's trap dutifully "restores" a stripped file.

From that point the working tree cannot recover itself; only `git checkout` can.
The two `PlistBuddy -c Delete … || true` calls are idempotent, so nothing
downstream notices, and the build proceeds and succeeds — silently producing an
unsandboxed app from what looks like a normal signed build. That is the state
`a968b81` and `a008925` were committed from.

### F5 — Exactly when Xcode sees the modification is not established, and the decision does not depend on it

Being honest about the limit of the evidence: the script edits the file *before*
`flutter build macos --release` is invoked, so a single, clean, uninterrupted run
should not trip the check. The failure was observed on one machine and could not
be reproduced here. Candidate mechanisms, none confirmed:

* **an interrupted or overlapping run** — the `EXIT` trap restores the file the
  moment the script exits, which lands mid-build if a previous build is still
  finishing, or if the user interrupts;
* **incremental build state** — Xcode retains what it recorded for the
  entitlements from the previous build, and the strip → restore → strip cycle
  across runs means the file it finds can disagree with the file it processed;
* **a first build on a machine with different scheduling** — the test machine's
  Xcode version is unknown; this one is Xcode 26.6.

**This ambiguity does not need resolving to decide.** Every candidate is
downstream of one choice: a tracked, signed input is rewritten in place by
something outside the build. Remove that and all three disappear, along with F2
and F4. Keeping the mutation and hardening around it means fixing whichever
mechanism is real and waiting to discover the others.

### F6 — The other failure has the same shape: a build phase that declares no dependencies

The first failure on the same machine came from `macos/scripts/stamp_version.sh`,
which writes the version into the **processed** Info.plist inside the product
bundle:

```sh
PLIST="$TARGET_BUILD_DIR/$INFOPLIST_PATH"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
```

PlistBuddy reported `File Doesn't Exist, Will Create` — the bundle's plist was
not there when the phase ran — then `Set` failed because the plist it had just
created was empty, and `set -eu` turned that into a failed build phase.

The phase is positioned last in the Runner target, which orders it against other
*phases*. But Info.plist processing is not a phase; it is a task ordered by
declared file dependencies, and this phase declares none:

```text
5747AB1E57A4C0DE00000001 /* Stamp Version From Git */ = {
    isa = PBXShellScriptBuildPhase;
    alwaysOutOfDate = 1;
    inputPaths = ( );
    outputPaths = ( );
    …
};
```

`alwaysOutOfDate = 1` guarantees it runs on **every** build; the empty
`inputPaths`/`outputPaths` mean nothing guarantees the plist exists when it does.
Whether the specific trigger was a first build, an incremental one, or a bundle
removed behind Xcode's back, the phase has no right to assume its target file is
there.

Repository-side inputs are correct and identical on both machines, so this is not
a checkout problem: `macos/Runner/Info.plist` is tracked, present, and carries
the `0.0.0` placeholder the stamp overwrites; the Runner target reads it via
`INFOPLIST_FILE = Runner/Info.plist`. (`GENERATE_INFOPLIST_FILE = YES` appears
three times in the project but belongs to **RunnerTests**, not the app.)

**Not reproduced here**, and an earlier explanation of mine — that
`--install` deletes the build-directory bundle and leaves the next build to trip
over it — was withdrawn when the maintainer's own rebuild succeeded from exactly
that state. What stands is the undeclared dependency, which is machine- and
schedule-sensitive in precisely the way the observation was.

### F7 — What the script may touch, enumerated

For completeness, since the decision is about which of these is legitimate:

| Path | Tracked? | Written by | Verdict |
| --- | --- | --- | --- |
| `macos/Runner/Release.entitlements` | **yes** | strip + trap restore | **the defect** |
| `macos/Runner/Release.entitlements.bak` | no (ignored) | `cp` / `mv` | exists only because of the defect |
| `.flutter-sdk/` | no (ignored) | clone / `rm -rf` on version mismatch | legitimate |
| `build/macos/**` | no | Xcode, plus `remove_app_bundles` | legitimate build output |
| `RemoteMagicGit-macos.zip` | no (ignored) | `ditto` | legitimate |
| `~/Applications/*.app` | outside repo | `install_zip` | legitimate |
| `macos/Runner/Configs/AppInfo.xcconfig` | yes | **read only** (`read_product_name`) | fine |
| `pubspec.lock` | yes | `flutter pub get` | fine — the script pins the SDK on `PATH` first |

Exactly one tracked file is written, and it is the one Xcode signs from.

## Decision Drivers

* A signed artifact's entitlements must be **reviewable in git**, not the
  residue of two `PlistBuddy` deletions performed at build time.
* No file the build reads may be mutated while the build reads it.
* An interrupted build must leave the working tree exactly as it found it.
* The difference between a signed and an unsigned build should be visible in a
  diff, because that difference decides whether the shipped app is sandboxed.
* The invariant must hold at **every instant**, not only between builds — the
  existing guard is correct and still cannot be trusted while a build runs (F3).
* The development loop `./build_macos.sh --unsigned --install` must keep working
  unchanged, on a Mac with no signing identity.
* Plain `flutter build macos` and building from Xcode.app must keep working.

## Considered Options

* **A — Keep the mutation; document harder.**
* **B — Keep the mutation; harden the trap and the backup.**
* **C — Set `CODE_SIGN_ALLOW_ENTITLEMENTS_MODIFICATION = YES`.**
* **D — Two tracked entitlements files, selected by a build setting.**
* **E — Generate the unsigned entitlements at build time into an ignored path.**
* **F — A separate Xcode build configuration for unsigned builds.**
* **G — Stop needing different entitlements.**

## Decision Outcome

Chosen option: **D — two tracked entitlements files, selected by a build
setting**, because it is the only option under which no file the build reads is
ever written, the signed/unsigned difference becomes a reviewable diff, and the
`.bak` file and its trap cease to exist rather than being made safer.

Shape of it, stated concretely enough to argue with:

1. **`macos/Runner/Release.entitlements` stays exactly as committed** and becomes
   read-only as far as every build is concerned. Nothing writes it, ever.
2. **`macos/Runner/Release-unsigned.entitlements` is added and tracked** — the
   same document without `com.apple.security.app-sandbox` and
   `keychain-access-groups`. What the ad-hoc loop ships stops being invisible.
3. **The target's setting becomes a variable.** The Runner Release configuration
   changes from `CODE_SIGN_ENTITLEMENTS = Runner/Release.entitlements` to
   `CODE_SIGN_ENTITLEMENTS = $(MG_RELEASE_ENTITLEMENTS)`, with the default
   `MG_RELEASE_ENTITLEMENTS = Runner/Release.entitlements` in `AppInfo.xcconfig`
   — the Runner target's base configuration. A plain `flutter build macos` or an
   Xcode.app build is then byte-for-byte what it is today.
4. **`--unsigned` selects the other file** by writing a gitignored
   `macos/Runner/Configs/Local.xcconfig` containing the one-line override, pulled
   in by an optional `#include? "Local.xcconfig"`. Optional includes are silently
   skipped when absent, so a tree without it behaves as in (3).
5. **The strip, the `cp`, the `.bak` and the `EXIT` trap are deleted.** With
   nothing to restore, there is nothing to fail to restore.
6. **The existing guard is extended, and its ambiguity deleted.**
   `test/macos_entitlements_canon_test.dart` already asserts what
   `Release.entitlements` must grant (F3); it gains an assertion that
   `Release-unsigned.entitlements` is exactly that document minus exactly the
   two keys, so the pair cannot drift. The `.bak` assertion goes with the `.bak`
   itself, and with it the false positive that makes the suite fail during a
   legitimate build.

And, from F6, in the same work but independently revertable:

7. **The stamp phase declares its dependency** — `inputPaths`/`outputPaths`
   naming `$(TARGET_BUILD_DIR)/$(INFOPLIST_PATH)`, so the build system orders it
   after Info.plist processing instead of leaving it to scheduling.
8. **The stamp script fails legibly** when the plist is absent — naming the
   bundle and what to do — rather than emitting PlistBuddy's two lines. This
   earns its place precisely because F6 could not be reproduced: the next
   occurrence diagnoses itself. It must **not** silently skip the stamp; the
   script's own comment explains that a `0.0.0` About panel is the loud signal
   that stamping did not run, and swallowing the error would trade a failed
   build for a wrong version number shipped quietly.

### Why not the others

**A — document harder.** F2 and F3 are the experiment, already run: the rule
existed in `AGENTS.md`, in `.gitignore`'s comment, and in the script's own
comments, and the tree still shipped stripped three times. *Bad, because the
evidence says it does not work.*

**B — harden the trap.** Guard against a pre-existing `.bak`, trap more signals,
verify the restore. This fixes F4 and narrows F2, and leaves F1 and F5 entirely
intact: the file is still rewritten while Xcode signs from it, so "modified
during the build" remains reachable by whichever mechanism is the real one.
*Neutral, because it is a strict improvement that does not address the finding.*

**C — `CODE_SIGN_ALLOW_ENTITLEMENTS_MODIFICATION = YES`.** Apple's own error
message offers this, and the same sentence explains why not: *"this may cause
the built product's code signature or provisioning profile to contain incorrect
entitlements."* It suppresses the detector while leaving the race, so the
observable outcome moves from a failed build to a signed app whose signature may
disagree with its entitlements — for this app, the difference between sandboxed
and not. *Bad, and specifically the kind of fix this project's rules forbid: it
removes the check that noticed the defect.*

**E — generate the unsigned file at build time.** Closer than B: the tracked file
is never written. But what the ad-hoc build actually ships is then the output of
a script rather than a reviewable document, the generator becomes another build
step to keep correct, and the invariant in (6) becomes a test of a generator
instead of a diff of two files. *Neutral — acceptable, strictly worse than D on
reviewability.* Worth revisiting only if keeping two files in sync proves worse
in practice than expected; the test in (6) is what makes D's duplication safe.

**F — a separate Xcode build configuration.** The most Xcode-idiomatic answer: an
`Unsigned` configuration with its own entitlements. It fights the toolchain that
sits above it — `flutter build` maps to the `Debug`/`Profile`/`Release`
configuration names and a fourth is awkward to drive through it. *Bad, because
it buys the same property as D at the cost of the Flutter integration.*

**G — stop needing different entitlements.** Make the app work correctly inside
the sandbox container so the unsigned build needs no changes. A real product
question, far larger than this record, and it would not retire the pattern —
`keychain-access-groups` still requires a certificate. *Bad as a solution to
this problem; reasonable as separate work.*

### Consequences

* Good, because after this the answer to "can a failed build leave the
  repository in a state that ships an unsandboxed app" is no, structurally,
  rather than "not if you remember to check `git status`."
* Good, because the entitlements an unsigned build ships become a file someone
  can read, review, and diff — today they are the result of two deletions
  performed on a developer's laptop.
* Good, because the `EXIT` trap, the `.bak` file, its `.gitignore` entry, the
  `AGENTS.md` warning and the guard's own `.bak` assertion all become dead
  weight — and the guard stops being able to fail for a reason that is not a
  defect (F3).
* Good, because F6's fix makes the version stamp obey the build system's own
  ordering rules rather than a phase position that does not mean what it looks
  like it means.
* Bad, because two entitlements files can drift. The test in (6) is what makes
  that safe, and it must be written to compare the two documents rather than to
  assert a hardcoded list of keys — otherwise adding a third entitlement
  silently escapes it.
* Bad, because it edits `project.pbxproj`, which merges badly and is easy to
  corrupt. It is two settings and one phase; it needs care and a real build,
  not a text-editor guess.
* Neutral, because the `--unsigned` and `--install` command lines do not change,
  and a signed build's inputs are byte-for-byte identical to today's.

### Confirmation

Each claim above has a check that can fail:

* **F1/F5, the reported error** — build `--unsigned` twice in a row, and
  interrupt one mid-build. Today's tree can leave `Release.entitlements`
  modified; after the change, `git status --short macos/` must be empty at every
  point during and after both builds, including the interrupted one.
* **F2/F3, the invariant** — the extended assertion from (6) must fail against a
  `Release-unsigned.entitlements` that has drifted from its twin. The existing
  assertions already have three historical commits (`0789fee`, `a968b81`,
  `a008925`) available as a proof-of-failure corpus, and re-running the current
  guard against those trees is how to confirm it does what F3 credits it with.
* **F3, the false positive** — today, `flutter test` run while
  `./build_macos.sh --unsigned` is mid-build fails
  `macos_entitlements_canon_test.dart` twice over. Afterwards it must pass at
  every instant of a build, which is the observable difference between a guard
  on a mutated file and a guard on an immutable one.
* **F4, the backup clobber** — with `Release.entitlements.bak` present and the
  tracked file stripped, today's script destroys the good copy. Afterwards there
  is no `.bak` and no code path that can.
* **F6, the stamp ordering** — the phase must run after Info.plist processing.
  Observable as a successful build on the machine that failed; and the legible
  error from (8) can be provoked on demand by pointing the script at a bundle
  that does not exist.
* **Signed-build neutrality** — the `.xcent` embedded in a signed build must be
  identical before and after the change. `codesign -d --entitlements :-` on both
  products, diffed.

The honest limit: **the reported failure has not been reproduced here.** These
checks establish that the mutation is gone and that the invariant holds; they
cannot prove which of F5's mechanisms was the one that fired on the test
machine. If the failure recurs after this, the cause is somewhere else and this
record's decision is still correct.

## More Information

* `build_macos.sh:193-206` — the strip, the `cp`, the trap.
* `macos/Runner.xcodeproj/project.pbxproj:676` — `CODE_SIGN_ENTITLEMENTS` on the
  Runner Release configuration; `:527`/`:659` for the Debug and Profile
  configurations, which use `DebugProfile.entitlements` and are untouched by
  this record.
* `macos/scripts/stamp_version.sh` and the `Stamp Version From Git` phase —
  F6.
* `.gitignore:54-57` — the repository's own account of the `.bak` incident.
* `AGENTS.md`, "Critical safety rules" — the prose rule F3 is about.
* `test/macos_entitlements_canon_test.dart`, added by `ec18bd8` on 2026-08-20 —
  the existing guard F3 is about, and the file step (6) extends.
* MADR 0029 (host scripts must be executed by a test) and the identifier
  redaction scan are the same precedent: a convention this project relies on
  gets a test, not a paragraph. The entitlements rule already followed it; this
  record is about the half a commit-time guard cannot reach.
* The two failures that prompted this record were reported from a second machine
  on 2026-09-09, against the same commit that builds cleanly on the maintainer's
  own machine. Neither is attributable to the change under test — the push
  contained no file outside `lib/`, `test/`, `docs/` and `tool/`.
