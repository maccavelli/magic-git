# Implement the focused commit sheet as the primary commit surface

Associated MADR: [0012-MADR-commit-composer-focused-sheet.md](0012-MADR-commit-composer-focused-sheet.md)

## Goal

Make `CommitDialog` the surface every commit entry point opens, under every
workspace preset, with the polish listed in the MADR's *The redesigned sheet*.
Keep the docked composer working as the secondary surface against the same
`CommitComposerController`.

## Scope

**In scope**

* Routing: the **Commit…** bar, the staged-section action, and
  `repository.focusCommit` (⌘G) open the sheet.
* `CommitDialog` polish: intrinsic clamped height, real branch label, staged
  count in the header, in-sheet error reporting, push wired through the
  controller.
* A user-visible choice of surface, so the dock stays reachable.
* Retiring the `taskDockCollapsed` workaround in `_expandCommitComposer` from
  the primary path.

**Out of scope**

* Any change to `CommitComposerController` semantics — draft, staged signature,
  generation, GPG state, and `submit()` stay as they are.
* The composer's inner body (`commit_composer.dart`) beyond what the sheet
  needs; assistance/co-author/template behaviour is untouched.
* Deleting the docked composer or the task-dock primitive.
* The button-accent rule, which shipped with the MADR's polish pass.

## Implementation Steps

1. **Wire push through the sheet.** `CommitDialog._accept` commits and then
   pops with `push` as the route result, leaving the push to a caller that no
   longer exists. Give it the same shape as
   `RepoStatusView._acceptCommitComposer`: pass `push:` into
   `controller.submit(...)` so the sheet owns the whole outcome, and keep the
   background fetch on the non-push path.

2. **Take the real branch and staged count.** `CommitDialog` hardcodes
   `branchLabel: 'current branch'`. Add a `branchLabel` parameter supplied by
   the caller from `status.branch.head`, and surface `stagedCount` in the sheet
   header ("N staged files on `<branch>`").

3. **Size it intrinsically.** Replace `SizedSheet(width: 760)` wrapping a fixed
   `SizedBox(height: 390)` with an intrinsic height and a clamp, per the sizing
   audit's "exemplary" entry. Verify a one-line subject and a long generated
   body both look deliberate.

4. **Report failures in place.** On a failed commit or push, keep the sheet
   open with the message intact and render the error in the sheet.
   `CommitComposerController` already carries error state; confirm the sheet
   renders it rather than relying on the caller's toast.

5. **Restore the routes.** Reinstate an `_openCommitDialog(...)` equivalent in
   `RepoStatusView` and point all three entry points at it: the **Commit…**
   bar, the staged-section action, and `repository.focusCommit`. It must not
   consult `taskDockCollapsed`.

6. **Keep the dock reachable.** Add a durable preference for the commit surface
   (sheet | dock) — a new field on `RepositoryWorkspacePrefs`, exposed in
   Workspace View Options. Note the schema rule from
   [0011-MADR](0011-MADR-toolbar-slot-schema-migration.md): adding a field means
   deciding what a record written before it decodes to, and a default that is
   duplicated anywhere is a defect waiting to happen. Default to the sheet.

7. **Route by preference.** The commit entry points open whichever surface the
   preference names. When it names the dock, keep today's
   `_expandCommitComposer` behaviour — including its un-collapse — since that
   path genuinely needs it.

8. **Re-point the shortcuts.** `commit.confirm` / `commit.confirmAndPush` must
   work on whichever surface is live. The sheet already binds them; confirm
   0009 G-H8's dock bindings still hold and that the two do not both fire.

## Verification

Commands: `flutter analyze` and `flutter test` clean before staging.

New/updated tests:

* `test/commit_dialog_test.dart` — stops testing dead code. Add: push is
  invoked through the controller on **Accept + Push**; a failed commit leaves
  the sheet open with the message intact; the header names the branch and
  staged count.
* `test/repo_status_view_test.dart` — each of the three entry points opens the
  sheet; parameterise over all four presets to pin the case 0008-PLAN B9
  failed, asserting the sheet appears with `taskDockCollapsed: true`.
* `test/commit_composer_shortcuts_test.dart` — ⌘↩ / ⇧⌘↩ from the sheet,
  including with the message field focused.
* Surface preference: defaults to the sheet; switching to the dock restores the
  docked composer; a pre-existing prefs record decodes to the intended default
  (see 0011's legacy-record group for the pattern).
* `test/commit_composer_test.dart` already pins both accepts accented and
  `Cancel` never accented; extend to the sheet's action row.

Manual check on `wonder`: open a dirty repository over SSH, press ⌘G under each
preset, commit, and commit-and-push.

## Deviations from this plan, as executed

Two things came out differently. Both are recorded here rather than quietly
absorbed.

1. **Steps 5–7 landed as one commit, not three.** Step 5 alone leaves
   `_expandCommitComposer` unreferenced, so the tree cannot come out
   analyzer-clean at that boundary — and AGENTS.md requires clean analyze and
   test before staging. Restoring the routes and routing them by preference is
   one indivisible change.

2. **`CommitComposerController.submit()` was changed**, which §Scope put out of
   bounds. Step 4's goal — "a failed commit *or push* keeps the sheet open with
   the message intact" — was unreachable without it: `submit` caught a throwing
   `push()` in the same block as the commit and returned
   `localCommitted: false`, even though the commit had landed and `clearDraft`
   had already emptied the draft. The caller was told to keep an empty surface
   open on a repository that had in fact changed. The two failures are now
   caught separately: a commit failure returns `localCommitted: false` with the
   draft intact, a push failure returns `localCommitted: true` with
   `pushSucceeded: false`. Nothing else about the controller moved.

A third change was required by step 5 and is worth recording as a finding
rather than a deviation: **`CommitDialog` was calling `updateStaged` from its
own `build`**. That both notified listeners mid-build — which, once the sheet
and the collapsed commit bar were on screen together, threw
`setState() called during build` — and overwrote `RepoStatusView`'s real
content signature with a synthetic `focused:N` one, under which two different
staged sets of the same size hash alike and preview-staleness stops working.
The sheet no longer touches it; `RepoStatusView` is the single owner and
already pushes it post-frame.

## Rollout and Rollback

Rollout is a single change behind a preference that defaults to the sheet, so
the dock is one toggle away if the sheet turns out wrong in daily use. There is
no data migration beyond the new prefs field, and the shared controller means a
user switching surfaces mid-draft keeps the draft.

Rollback is flipping the default back to the dock; the routing code for both
paths remains. Revert the commit only if step 6's schema change proves
problematic, in which case the field and its default go with it.
