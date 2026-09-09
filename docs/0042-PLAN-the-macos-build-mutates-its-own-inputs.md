---
status: "proposed"
date: 2026-09-09
associated-madr: "0042-MADR-the-macos-build-mutates-its-own-inputs.md"
---
# Implement: stop the macOS build editing the file it signs from

Associated MADR:
[0042-MADR-the-macos-build-mutates-its-own-inputs.md](0042-MADR-the-macos-build-mutates-its-own-inputs.md)

## Goal

Make `macos/Runner/Release.entitlements` immutable from the build's point of
view, so that the class of failure the MADR records — a signed input rewritten
mid-build, a backup destroyed by the next run, a stripped tree committed three
times, a guard that cannot tell a live build from a dead one — stops being
reachable rather than being handled.

Four phases, one commit each. Phase 4 is independently revertable and droppable;
phases 1–3 are one decision and land in order.

## Assessment of the MADR before planning on it

The record was written before these checks and one of its findings was wrong.
Recorded here rather than quietly fixed, because the plan is shaped by what the
checks found.

| MADR claim | Checked how | Result |
| --- | --- | --- |
| `#include?` is an optional include Xcode accepts | `xcodebuild -showBuildSettings -xcconfig <file>` naming a file that does not exist | **Holds** — settings resolve, no error |
| `CODE_SIGN_ENTITLEMENTS = $(VAR)` resolves in that setting | same, with `CODE_SIGN_ENTITLEMENTS='$(MG_RELEASE_ENTITLEMENTS)'` | **Holds** — resolves to `Runner/Release.entitlements` |
| an optional include overrides the default, last-wins | two xcconfigs, one including the other | **Holds** — resolves to `Runner/Release-unsigned.entitlements` |
| the rule "lives only in prose" (F3) | looked for a guard | **WRONG** — `test/macos_entitlements_canon_test.dart` exists (`ec18bd8`, 2026-08-20) |

The full probe, which is what phases 1–2 rest on:

```text
A: default only        CODE_SIGN_ENTITLEMENTS = Runner/Release.entitlements
B: optional include    CODE_SIGN_ENTITLEMENTS = Runner/Release-unsigned.entitlements
```

**F3 has been corrected in the record.** The guard exists, it postdates all
three bad commits, and nothing stripped has shipped since. What it cannot do is
prevent the mutation — and, because it asserts on a file a legitimate build
mutates, it *fails during a normal unsigned build*. That reframes step 6 from
"write a test" to "extend the existing one and delete the ambiguity", which is
what this plan does.

Two design defects in the MADR's own proposal, found while planning:

* **(i) A stale override silently mis-signs.** The MADR has `--unsigned` write
  `Local.xcconfig`. If a *signed* build then runs without rewriting it, the
  signed product is built with unsigned entitlements — the exact class of defect
  this record exists to remove. **Both modes must write the file, every run.**
* **(ii) The script still writes a build input.** `Local.xcconfig` is one. It is
  materially different — gitignored, written before the build starts, never
  restored, not a signing input — but the plan states it as a residual rather
  than pretending it is not one.

## Scope

**In scope**

* `macos/Runner.xcodeproj/project.pbxproj` — one build setting, and (phase 4)
  one build phase's `inputPaths`/`outputPaths`.
* `macos/Runner/Configs/AppInfo.xcconfig` — the variable's default and the
  optional include.
* `macos/Runner/Release-unsigned.entitlements` — new, tracked.
* `build_macos.sh` — delete the strip/`cp`/trap; write the override.
* `macos/scripts/stamp_version.sh` — phase 4 only.
* `test/macos_entitlements_canon_test.dart` — extend.
* `.gitignore` — the override file; the `.bak` line becomes a tombstone.

**Explicitly out of scope**

* `DebugProfile.entitlements` and the Debug/Profile configurations. They are not
  mutated by anything and their guard assertion stays as it is.
* Making the app work sandboxed so the unsigned build needs no difference
  (MADR option G). Separate work, does not retire `keychain-access-groups`.
* `CODE_SIGN_ALLOW_ENTITLEMENTS_MODIFICATION`. Rejected in the record; naming it
  here so nobody adds it while debugging.
* Reproducing the "modified during the build" error. It could not be reproduced
  on this machine (MADR F5) and this plan does not claim to fix a mechanism it
  never saw; it removes the mutation all three candidates depend on.

## Implementation Steps

### Phase 1 — the second entitlements file, and the switch that selects it

Nothing changes behaviour in this phase: with no override file present, every
build resolves exactly as it does today. That is the point — it lands the
mechanism and proves neutrality before anything depends on it.

**1.1** Add `macos/Runner/Release-unsigned.entitlements`, tracked. It is
`Release.entitlements` with exactly two keys removed —
`com.apple.security.app-sandbox` and `keychain-access-groups` — and nothing
else changed. The three remaining grants (`network.client`,
`files.user-selected.read-write`, `files.bookmarks.app-scope`) stay, because the
unsigned build needs them for the same reasons the signed one does.

**1.2** In `macos/Runner/Configs/AppInfo.xcconfig`, add the default and the
optional include, in this order (last assignment wins, so the include must come
after):

```text
// Which entitlements the Release configuration signs with. `build_macos.sh`
// writes Configs/Local.xcconfig (gitignored) to select the unsigned pair; with
// no such file this resolves to the committed, sandboxed entitlements, so a
// plain `flutter build macos` or an Xcode.app build is unchanged.
MG_RELEASE_ENTITLEMENTS = Runner/Release.entitlements
#include? "Local.xcconfig"
```

**1.3** In `project.pbxproj`, the Runner target's **Release** configuration
(`33CC10FD2044A3C60003C045`) only:

```text
-  CODE_SIGN_ENTITLEMENTS = Runner/Release.entitlements;
+  CODE_SIGN_ENTITLEMENTS = "$(MG_RELEASE_ENTITLEMENTS)";
```

Debug and Profile keep `Runner/DebugProfile.entitlements` verbatim.

**1.4** `.gitignore`: add `/macos/Runner/Configs/Local.xcconfig` with a comment
saying what writes it and that it is per-machine build selection.

**1.5 — verification, and it is exact.** `xcodebuild -showBuildSettings` resolves
settings without building, so both states are checkable in seconds:

```sh
# no override present — must equal today's value
xcodebuild -project macos/Runner.xcodeproj -target Runner -configuration Release \
  -showBuildSettings | grep -E '^\s+CODE_SIGN_ENTITLEMENTS'
#   expect: CODE_SIGN_ENTITLEMENTS = Runner/Release.entitlements

# with the override present
printf 'MG_RELEASE_ENTITLEMENTS = Runner/Release-unsigned.entitlements\n' \
  > macos/Runner/Configs/Local.xcconfig
xcodebuild -project macos/Runner.xcodeproj -target Runner -configuration Release \
  -showBuildSettings | grep -E '^\s+CODE_SIGN_ENTITLEMENTS'
#   expect: CODE_SIGN_ENTITLEMENTS = Runner/Release-unsigned.entitlements
rm macos/Runner/Configs/Local.xcconfig
```

Capture the "before" value first, from the current tree, and require the
no-override case to match it byte for byte. That is the neutrality proof for
signed builds, and it does not need a signing identity.

**Acceptance:** both resolutions as above; `flutter analyze` and `flutter test`
unchanged; `git status --short macos/` empty after the check (the override file
removed).

---

### Phase 2 — delete the mutation

**2.1** In `build_macos.sh`, remove the entire `--unsigned` entitlements block
(`:193-206`): the `ENT` assignment, the `cp`, the `trap`, and both
`PlistBuddy -c Delete` calls.

**2.2** Replace it with selection, written on **every** run in **both** modes —
this is assessment defect (i), and getting it wrong re-creates the bug:

```sh
LOCAL_XCCONFIG="$SCRIPT_DIR/macos/Runner/Configs/Local.xcconfig"
if [[ "$UNSIGNED" == "1" ]]; then
  ENT_REL="Runner/Release-unsigned.entitlements"
else
  ENT_REL="Runner/Release.entitlements"
fi
printf 'MG_RELEASE_ENTITLEMENTS = %s\n' "$ENT_REL" > "$LOCAL_XCCONFIG"
log "Signing entitlements: $ENT_REL"
```

Written before `flutter build macos`, never restored, never removed. There is no
cleanup step, which is the property that matters: nothing can fail to restore.

**2.3** The file is left in place after the build, deliberately. The trade-off,
which the maintainer should confirm rather than inherit:

* **Left in place (recommended).** No cleanup can fail. Cost: a bare
  `flutter build macos --release` run *after* an unsigned script build inherits
  the unsigned selection until the script runs again. Mitigated by 2.2 logging
  the choice on every run, and by the fact that the documented loop is the
  script.
* **Removed on exit.** Restores "bare `flutter build` is always signed" at the
  cost of reintroducing a cleanup step that can be interrupted — the shape this
  record exists to delete. The blast radius is far smaller than the old one (a
  gitignored file, and a stale copy is corrected by the next script run), but it
  is the same shape.

**2.4** Update the header comment block for `--unsigned` (`:28-33`), which
currently promises "The entitlement file is restored after." It no longer is,
because it is no longer modified.

**2.5 — verification.**

```sh
./build_macos.sh --unsigned --install
git status --short macos/          # must be EMPTY, during and after
```

Then the negative control, which is the whole point of the phase: start the
build, and **while it runs**, in another shell:

```sh
git status --short macos/Runner/Release.entitlements   # must print nothing
ls macos/Runner/Release.entitlements.bak               # must not exist
flutter test test/macos_entitlements_canon_test.dart   # must PASS mid-build
```

On today's tree that third command fails twice over (MADR F3). Run it against
the current tree first to see it fail, then against the new one to see it pass —
otherwise the check proves nothing.

**Acceptance:** an unsigned build produces an unsandboxed app with a clean
`git status` throughout; the guard passes at every instant of the build.

---

### Phase 3 — make the guard an invariant instead of a truce

**3.1** In `test/macos_entitlements_canon_test.dart`, add an assertion that the
two files are exactly one edit apart: the set of `<key>` names in
`Release-unsigned.entitlements` equals the set in `Release.entitlements` minus
exactly `com.apple.security.app-sandbox` and `keychain-access-groups`, and every
grant common to both has the same value.

Written as a **set difference**, never as a hardcoded list of expected keys — a
hardcoded list silently ignores a fourth entitlement added later, which is
exactly the drift this assertion exists to catch (MADR Consequences).

No `PlistBuddy`: the suite must run on any platform (`AGENTS.md`), and
`PlistBuddy` is macOS-only. The existing file already parses these plists with
string matching; extend that approach rather than adding an XML dependency.

**3.2** Delete the `no leftover entitlements backup` test and the
`_strippedByUnsignedBuild` message's advice to restore from `.bak`. Both
describe a file that no longer exists. Replace the message with one naming the
real remedy — `git checkout -- macos/Runner/Release.entitlements` — since after
this the only way the file can be wrong is that someone edited it.

**3.3** `.gitignore`: keep `/macos/Runner/Release.entitlements.bak` as a
tombstone with a comment saying nothing writes it any more and it is retained so
a stale copy from an older build cannot become committable. Removing the line
would make that possible again.

**3.4** `AGENTS.md`: the "Critical safety rules" entry describing the transient
strip is now wrong. Rewrite it to say the committed entitlements are never
modified by any build, that the unsigned pair is a second tracked file, and that
the guard covers both.

**3.5 — verification, seen to fail.** Against a **scratch copy**, never the tree:

```sh
cp macos/Runner/Release-unsigned.entitlements "$SCRATCH/keep"
# 1. drift: add a key to one file only  -> the new assertion must fail
# 2. remove a third key from the unsigned file -> must fail
# 3. restore -> must pass
cp "$SCRATCH/keep" macos/Runner/Release-unsigned.entitlements
```

Better still, drive it through `tool/mutate.py` so the mutations run in a
scratch `git worktree` and the tree is never dirtied at all — see the catalogue
below.

**Acceptance:** the extended guard fails on drift in either direction and passes
on the shipped pair; the whole suite is green.

---

### Phase 4 — the version stamp declares what it depends on *(droppable)*

Independent of phases 1–3 and revertable alone. It addresses MADR F6, the
*first* failure on the test machine — which **could not be reproduced here**, so
this phase is honest about which half is verifiable.

**4.1** Give the `Stamp Version From Git` phase
(`5747AB1E57A4C0DE00000001`) an `inputPaths` entry naming
`$(TARGET_BUILD_DIR)/$(INFOPLIST_PATH)`, so the build system orders it after the
task that produces the plist rather than leaving it to scheduling.
`alwaysOutOfDate = 1` stays — the version must be re-stamped whenever HEAD
moves, which no file dependency expresses.

Do **not** declare the same path as an `outputPaths` entry in the same edit: a
file that is both input and output of one task is how dependency cycles are
created. If ordering does not take without it, that is a finding to record, not
a thing to guess at.

**4.2** In `macos/scripts/stamp_version.sh`, check the plist exists before
touching it and fail with a diagnosis:

```sh
PLIST="$TARGET_BUILD_DIR/$INFOPLIST_PATH"
[ -f "$PLIST" ] || {
  echo "error: $INFOPLIST_PATH is not in the product bundle — the app was not
  assembled before this phase ran. Clean build/macos and rebuild; if it recurs,
  the phase is running before Info.plist processing (MADR 0042 F6)." >&2
  exit 1
}
```

It must **exit non-zero**. Skipping the stamp would ship a `0.0.0` version
quietly, and the script's own header explains that the placeholder exists to be
a loud signal.

**4.3 — verification.** 4.2 is provable on demand here; 4.1 is not:

```sh
# 4.2, seen to fail — against a scratch dir, not a real build
TARGET_BUILD_DIR=/nonexistent INFOPLIST_PATH=x/Info.plist SRCROOT=$PWD/macos \
  sh macos/scripts/stamp_version.sh; echo "exit=$?"
#   expect: the diagnosis above, exit=1 (today: PlistBuddy's two lines)
```

**4.1 cannot be confirmed on this machine**, because the failure it addresses
has never occurred here. What can be shown is that a normal build still succeeds
and still stamps: `/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString"`
on the built bundle must print `<tag>.<commits>`, not `0.0.0`. Confirmation that
it fixes anything has to come from the machine that failed.

**Acceptance:** a build stamps a real version; the missing-plist path prints the
diagnosis and exits 1; the phase's position and `alwaysOutOfDate` are unchanged.

---

## Verification

At every phase boundary, not only at the end:

```sh
flutter --version | head -1                # must match FLUTTER_VERSION (3.47.2)
flutter pub get --enforce-lockfile         # "Got dependencies!"
flutter analyze                            # clean
dart format --output=none --set-exit-if-changed lib test
flutter test                               # full suite
tool/mutate.py tool/mutations/0042-entitlements-immutable.json
xcodebuild -project macos/Runner.xcodeproj -target Runner -configuration Release \
  -showBuildSettings | grep -E '^\s+CODE_SIGN_ENTITLEMENTS'
```

Redirect long output to a file and read it back; never put a filter between a
gate and its verdict.

### Mutation catalogue

`tool/mutations/0042-entitlements-immutable.json`, run in full at every phase
boundary — MADR 0039 D9's rule, and 0041's execution broke two anchors that way,
so expect it here too.

| Label | Mutation | Killed by |
| --- | --- | --- |
| the unsigned pair drifts by an added key | add a `<key>` to `Release-unsigned.entitlements` | 3.1 |
| the unsigned pair drifts by a removed grant | remove `network.client` from the unsigned file | 3.1 |
| the sandbox key returns to the unsigned file | add `app-sandbox` back | 3.1 |
| the release file is stripped | remove `app-sandbox` from `Release.entitlements` | the existing guard |
| the stamp tolerates a missing plist | `exit 1` → `exit 0` in 4.2 | 4.3 |

The catalogue mutates `macos/` and `test/` rather than `lib/`; confirm
`tool/mutate.py` applies to those paths before relying on it, and if it does
not, that is a deviation to record and resolve rather than a reason to skip the
sabotage round.

### Checks seen to fail

Every new assertion must be watched failing before it is trusted, against a
scratch copy or the mutation worktree — never by dirtying the tree, and never
undone with `git checkout --`.

Two are already available as historical failures rather than synthetic ones: the
existing guard against `0789fee`, `a968b81` and `a008925`, and the current
tree's `macos_entitlements_canon_test.dart` run mid-build, which fails today and
must pass after phase 2.

### Host verification, which is the maintainer's

Two machines are involved and this session can only reach one:

| Check | Where |
| --- | --- |
| `CODE_SIGN_ENTITLEMENTS` resolves both ways | here, no signing identity needed |
| unsigned build, clean `git status` throughout | here |
| guard passes mid-build | here |
| signed build's embedded `.xcent` unchanged | **needs a Development Team** — `codesign -d --entitlements :- "$APP"` before and after, diffed |
| the reported build failures stop | **the test machine only** |

## Rollout and Rollback

* One commit per phase, `git commit --no-edit` only — the hook writes the
  message. Code and docs in separate commits (MADR 0039 D4).
* Nothing is pushed unless asked for in the same turn.
* `git revert` per phase. Ordering: phase 2 must not stand without phase 1 — a
  script selecting `Release-unsigned.entitlements` through a variable no
  `.xcconfig` defines would resolve `CODE_SIGN_ENTITLEMENTS` to empty. If
  phase 1 is ever reverted, revert phase 2 first.
* Phase 4 is independent in both directions.
* `project.pbxproj` merges badly. Both edits are single lines inside a named
  configuration/phase and should be made by hand and read back, not generated.
* **A rebuild is required to see any of this**, on both machines.

## Decisions taken

Recorded 2026-09-09, before execution. Kept as asked so the record shows what
was decided, not only what was done.

1. ~~**Phase 2.3** — leave `Local.xcconfig` in place, or remove it on exit?~~
   **Leave it in place.** No cleanup step exists, so none can be interrupted.
   The accepted cost: a bare `flutter build macos --release` run after an
   unsigned script build inherits the unsigned selection until the script runs
   again, which 2.2's log line makes visible on every run.
2. ~~**Phase 4 in or out?**~~ **In**, both halves. 4.2 lands regardless because
   it converts the next occurrence into a sentence; 4.1 lands as a reasoned fix
   that only the machine which failed can confirm, and the plan says so rather
   than claiming it verified.
3. ~~**`Release-unsigned.entitlements` tracked or generated?**~~ **Tracked.**
   What the ad-hoc loop ships stays reviewable and diffable rather than being
   the output of a generator; 3.1 is what keeps the pair from drifting.

## Deviations

*(None yet — added here, dated, as execution finds them, per the rule that a
deviation is prompted on and recorded before it is executed.)*

## Execution record

*(Added per phase as it lands: what the phase did, the verification output
rather than a summary of it, and what was not done and why.)*
