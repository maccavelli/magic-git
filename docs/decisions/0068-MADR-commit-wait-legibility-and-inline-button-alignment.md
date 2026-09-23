---
status: "accepted"
date: 2026-09-22
decision-makers: [Maintainer]
consulted: [0067-REPORT-commit-message-preview-and-composer-findings.md, 0064-PLAN-workspace-reachability-feedback-and-log-fidelity.md (deviation D4), measured render-tree probes of the compact back bar, the hook timings taken on the remote host]
informed: [Magic Git contributors]
verified: 2026-09-22
---

# Leave nothing behind and say what you are waiting for: preview cleanup, a legible commit wait, and an inline button that stays where it is put

## Context and Problem Statement

[0067-REPORT](../reports/0067-REPORT-commit-message-preview-and-composer-findings.md) closed one
question (the slow commits were provider-side, fixed by changing the hook's model) and left two
app defects unfixed. The 0064 on-device gate left a third observation. This record decides all
three. Each is stated with what was measured and what was not; one of them is deliberately
decided as "measure before changing".

### A. A cancelled or timed-out message preview leaks its scratch file

`GitService.generateCommitMessage` (`lib/core/git/git_service.dart:3264-3305`) previews the
`prepare-commit-msg` hook's output by running a script on the host:

```
tmp=$(mktemp "$dir/MAGICGIT_MSG_PREVIEW.XXXXXX") || exit 1
"$hook" "$tmp" </dev/null >/dev/null 2>&1 || true
sed -e /^#/d "$tmp"
rm -f "$tmp"
```

`rm -f` is the last statement, so it runs only when the script completes. The call carries the
five-minute commit timeout, and **both** executors kill the process when it fires — the SSH one
at `ssh_command_executor.dart:542`, the local one through `_killEscalate`
(`lib/core/exec/local_command_executor.dart:256`, `:351`) — so the shell never reaches it.

**Measured.** After the maintainer's slow-hook attempts, the fixture repository on the remote
host held five `MAGICGIT_MSG_PREVIEW.*` files; four remain. Each is 0 bytes and owner-only, in
the repository's git dir, so `git status` never shows them and nothing reads them back.

### B. The commit wait is expensive to draw and says nothing

While a preview or a commit is in flight the composer shows an indeterminate spinner —
`commit_composer.dart:239` for the preview, `:269` while committing. `ProgressCircle` with no
`value` is `CupertinoActivityIndicator` (macos_ui 2.2.2, `progress_indicators.dart:93-96`), whose
controller `repeat()`s: frames are produced for as long as it is on screen, and with the
five-minute timeout that can be five minutes.

**Measured.** During a stalled hook, `ps -o %cpu` for the app read ~58%.

**Not measured, and it matters.** That number is a one-minute decaying average; sampled
instantaneously with `top -l` after the wait, the same process read 0.0–2.9%. Nothing isolated
the spinner's own painting from any repaint it forces, and no profile build was run against this
state. **"The spinner costs 58% of a core" is not a fact this record may assume.**

**What is certain, and is the user-visible half:** the surface says nothing while it waits. The
hook prints `prepare-commit-msg: generating via <provider> (<model>)…` and its retry lines to
stderr, and the preview script throws all of it away (`>/dev/null 2>&1`). When the hook stalled,
the app could not say why, the Output view stayed silent, and the only symptom was a spinner and
eventually a fallback to manual entry. The same investigation needed a terminal to learn what the
app already had in front of it.

### C. An inline action button centres itself when given a wide slot

Reported during the 0064 gate as "the ‹ Branches back-bar capsule is centred, not left-aligned",
and left unfiled because `_CompactBackBar` sets `alignment: Alignment.centerLeft`
(`adaptive_workspace_layout.dart:552-558`), which reads as if it already settles the question.

**Measured** (a render-tree probe in a scratch clone of `0fb8733`, 640 pt window, compact
layout):

```
keyed widget (InlineActionButton)   x=8.0    w=624.0
… ConstrainedBox(minHeight)         x=8.0    w=624.0
… Center                            x=8.0    w=624.0
… AnimatedContainer (the capsule)   x=256.0  w=127.9   <- dead centre of 640
```

The cause is inside the button, not the bar: `InlineActionButton` wraps its capsule in
`Center` to centre it vertically within `minimumTarget`
(`lib/features/common/inline_action_button.dart:133-136`), and `Center` centres horizontally
too. The button therefore fills any loose width it is given and puts its capsule in the middle,
which makes the parent's `centerLeft` moot. Most of its 62 call sites sit in a `Row`, where the
width is already tight to content and nothing is visible; the back bar is the case that hands it
the full width.

## Decision Drivers

* **Leave the host as it was found.** A cancelled operation must not accrete files in someone's
  repository.
* **A wait must be legible.** The app knows what it is waiting for and already has the text; the
  user should not need a terminal to see it.
* **Do not act on an unmeasured number.** Where the evidence is an average that a later
  instantaneous sample contradicts, the decision is to measure, not to optimise.
* **Fix a trap at its source.** A widget that ignores its parent's alignment is a defect in the
  widget, not in each caller that works around it.
* **Small blast radius, and stated where it is not.** B's logging touches a service; C's fix
  touches a widget with 62 call sites and is pinned by tests.

## Considered Options

* **A1** trap the cleanup in the script · **A2** delete from Dart after the call · **A3** sweep
  stale files on connect.
* **B1** surface the hook's stderr and leave the spinner alone until measured · **B2** replace
  the spinner with an elapsed-time line · **B3** optimise the spinner now.
* **C1** shrink-wrap the button (`Center(widthFactor: 1)`) · **C2** left-align inside the button
  · **C3** fix only the back bar.

## Decision Outcome

Chosen: **A1 + A3**, **B1**, **C1**.

### A — the script cleans up after itself, and a sweep catches what a signal cannot

The preview script gains `trap 'rm -f "$tmp"' EXIT INT TERM` immediately after the `mktemp`, so
the file goes when the shell dies — which is what the timeout's TERM produces. A trap cannot
catch SIGKILL, so the leftovers from before this change (and any future kill -9) are collected by
a bounded sweep: the same script removes `MAGICGIT_MSG_PREVIEW.*` entries in the git dir older
than a day before it creates its own. Both halves live in the one script that already knows the
git dir; no new command, no new round trip.

A2 (deleting from Dart afterwards) is rejected because the Dart side is exactly what does *not*
run when the call is killed — the timeout throws, and any cleanup after it is code that the
failure path skips. A3 alone is rejected as the only mechanism: it would leave every cancelled
preview's file lying around until the next preview.

### B — say what is being waited for; measure before optimising

1. **Surface the hook's output.** `generateCommitMessage` stops discarding the hook's stderr.
   The script captures it (`2>"$tmp.err"`), and the Dart side appends each non-empty line to the
   Output log (`OutputLogNotifier.append`, `lib/core/output/output_log.dart:243`) tagged as it
   tags any other command's stderr. A hook that announces `generating via …` and then retries
   becomes visible where every other command's output already is.
2. **The spinner stays for now.** What this record will not do is trade a spinner for an
   elapsed-time line (B2) on the strength of a decaying average, or "optimise" an animation whose
   cost has never been isolated (B3). The plan for this record carries a measurement step — a
   profile or probe build held on the composer's wait state, as in
   [0064-PLAN](0064-PLAN-workspace-reachability-feedback-and-log-fidelity.md) deviation D5 — and
   the result is recorded as an amendment. If the spinner is a real cost, B2 is the obvious
   follow-up and it also improves the surface, since `_ReconnectingOverlay`
   (`app_shell.dart:107-130`) already shows the elapsed-seconds pattern this app uses.

### C — the button sizes to its capsule

`Center` becomes `Center(widthFactor: 1)` in `InlineActionButton`: the vertical centring within
`minimumTarget` is preserved, the horizontal expansion is not, and the button's box becomes its
capsule. Every caller that sits in a `Row` is unaffected (its width was already tight to
content); the back bar's existing `Alignment.centerLeft` starts working, with no change there.

C2 (aligning left inside the button) is rejected: it would silently left-align the capsule in
every wide slot, which is a layout decision belonging to each caller, not to the button. C3
(fixing only the back bar) is rejected because it leaves the trap in place for the next caller
who gives the button a wide slot and is surprised.

### Consequences

* Good, because a cancelled preview leaves nothing behind, on either backend, and the existing
  leftovers are collected without anyone shelling into the host.
* Good, because the next stalled hook explains itself in the Output view instead of presenting a
  silent spinner.
* Good, because the back bar's alignment starts meaning what it says, and the widget stops
  ignoring its parent.
* Neutral, because the spinner is unchanged: this record deliberately closes B's *legibility*
  half and defers B's *cost* half to a measurement rather than guessing.
* Bad, because C touches a widget with 62 call sites. The risk is a caller that wanted the full
  width as a hit target; the plan's confirmation enumerates the call sites that sit outside a
  `Row` and pins the back bar's geometry with the probe above, turned into a test.
* Bad, because A's sweep deletes files by name pattern and age in someone's git dir. It is
  bounded to `MAGICGIT_MSG_PREVIEW.*` in the resolved git dir, files this app alone creates, and
  it runs only in the preview path.

### Confirmation

* **A:** a test that the preview script contains the trap before any hook invocation, and an
  integration test against a real temporary repository whose "hook" sleeps and is killed —
  afterwards no `MAGICGIT_MSG_PREVIEW.*` remains. It must fail on today's script.
* **B:** a test that a hook writing to stderr has those lines in `outputLogProvider` after
  `generateCommitMessage`, and that the returned message is still the message file's content
  only — stderr must not contaminate it.
* **C:** the render-tree probe from §C as a widget test: in a 640 pt compact layout the capsule's
  left edge is within a few points of the bar's padding, not at the centre. It must fail on
  today's widget. Plus the existing `inline_button_canon_test.dart` and the workspace goldens,
  which must stay green — a golden that moves means a caller did rely on the expansion, and that
  caller is named and handled rather than regenerated.
* `flutter analyze` clean and the full suite green after each phase.

## Pros and Cons of the Options

### A1 trap in the script

* Good, because it fires on the signal the timeout actually sends.
* Good, because it needs no second command and no knowledge on the Dart side.
* Bad, because SIGKILL escapes it — which is why A3 accompanies it.

### A2 delete from Dart after the call

* Good, because the deletion is visible in Dart rather than inside a shell string.
* Bad, because the kill path is precisely the path where that code does not run; it fixes the
  case that was never broken.

### A3 sweep stale files

* Good, because it is the only thing that collects what SIGKILL and past versions left.
* Bad, because alone it defers cleanup to the next preview, and it deletes by pattern and age.

### B1 surface stderr, measure before touching the spinner

* Good, because it fixes the half that is certain (the silence) and refuses to act on the half
  that is not.
* Good, because the measurement is cheap and the technique is already written down.
* Bad, because if the spinner is expensive, that cost remains until the follow-up.

### B2 elapsed-time line instead of the spinner

* Good, because it is information rather than motion, and the pattern exists in this app.
* Bad, because adopting it now would be justified by a number this record has shown to be
  unreliable.

### B3 optimise the spinner now

* Bad, because there is nothing to optimise until the cost is attributed; the animation may be
  irrelevant beside a full-surface repaint.

### C1 `Center(widthFactor: 1)`

* Good, because one line fixes every caller and preserves the vertical centring the `Center` was
  there for.
* Bad, because it changes a shared widget's measured size; the goldens are the check.

### C2 left-align inside the button

* Bad, because it substitutes one imposed alignment for another and still ignores the parent.

### C3 fix only the back bar

* Good, because the blast radius is one widget.
* Bad, because the next wide slot reproduces it, and the misleading `centerLeft` stays.

## More Information

* **Out of scope, stated rather than skipped.** The "first click on an inactive window is
  dropped" observation from the 0064 gate stays unfiled: synthetic input is not evidence for it
  (0064-PLAN deviation D4), and it needs a real-mouse check first. The hook's own latency is
  provider-side and closed (0067, Finding 3). The Minimal preset still collapses the navigator by
  design (0066).
* **Evidence.** The render-tree numbers in §C come from a probe run against a scratch clone of
  `0fb8733`; the file counts and hook timings come from the remote host on 2026-09-22 and are
  recorded in 0067.
* **Implementation:** to be written as `0068-PLAN-…` once this record is approved.

## Amendment 0068.1 (2026-09-22): the trap alone does not work, and a killed preview orphans the hook

> **Amended by 0068.5 (2026-09-23):** the table below was measured with `sh` started directly. Run by the app, the shipped script still leaves its scratch file behind on a timeout, and in one run the hook too. See Amendment 0068.5.

§A above says the trap removes the file "when the shell dies — which is what the timeout's TERM
produces". **Measured, that is false.** Both executors signal only the `sh` process —
`process.kill(ProcessSignal.sigterm)` locally (`local_command_executor.dart:493`),
`session.kill(SSHSignal.TERM)` over SSH (`ssh_command_executor.dart:1162`) — and SIGKILL it
`killGrace` (400 ms, `:1143`) later. They never signal the process group. POSIX `sh` defers a
trap until its foreground child exits, so while the hook runs the trap waits, and the SIGKILL
arrives first.

A scratch repository with a stub hook (its hooks path pinned so no provider is called), killed
with exactly that sequence — TERM to `sh`, SIGKILL 400 ms later:

| Script | Leftover file | Hook still running afterwards |
|---|---|---|
| as shipped | 1 | yes |
| + `trap 'rm -f "$tmp"' EXIT INT TERM` (this record's §A as written) | 1 | yes |
| + hook in the background, `wait "$pid"`, an EXIT trap that kills it and removes the file | 0 | no |

The earlier probe that appeared to vindicate the trap signalled the whole process group, which
killed the hook too — not what the app does. The contradiction was found while preparing to
execute, before any code was written (0068-PLAN, deviation D1).

**Two corrections to the decision.**

* **The mechanism.** The hook runs in the background and the shell `wait`s for it. A signal
  interrupts `wait` immediately, the TERM/INT traps `exit`, and the EXIT trap kills the hook and
  removes the scratch file — inside the 400 ms grace. The sweep of day-old leftovers stays, for a
  SIGKILL that arrives with no TERM first.
* **A second defect, now in scope.** Today a timed-out preview leaves the hook **orphaned and
  still running** on the host. For an AI hook that means it keeps calling its provider — up to its
  own ~4.5 minutes of retries in the case that prompted this record — after the app has given up.
  The mechanism above fixes it for the preview.

**Not in scope, filed separately.** Whether *other* commands orphan their children the same way
(git's hooks during a commit, its ssh transport during a fetch) is a question about the executors,
not the preview, and the fix — signalling the process group, which SSH cannot do at the protocol
level — would touch every remote command. It is recorded in
[0069-REPORT](../reports/0069-REPORT-timed-out-commands-signal-only-the-leader.md) rather than
decided here.

The spinner's measurement, which the plan first numbered 0068.1, becomes Amendment 0068.2.

## Amendment 0068.2 (2026-09-22): the hook's output is streamed, not captured

§B.1 above says the script "captures it (`2>"$tmp.err"`), and the Dart side appends each
non-empty line to the Output log". Executed as the plan first wrote it, that would have shown the
hook's output **only after the hook finished** — captured to a file and emitted after the `sed` —
so a stalled hook, the one case this exists for, would have stayed silent for its whole wait, and
a killed preview's trap would have deleted the capture before anyone saw it.

The transport already separates the two streams: `CommandOutputCallback` is
`void Function(String chunk, {required bool stderr})` (`ssh_command_executor.dart`, beside
`CommandExecutor`), delivered live, and fetch/push/clone route it into the Output log through a
stream session (`branches_view.dart:1688-1712`, `clone_controller.dart:263`).

**Amended mechanism.** The hook's stderr flows to the script's stderr (its stdout stays discarded,
so it can never contaminate the message); `generateCommitMessage` takes the same
`CommandOutputCallback? onOutput` fetch and push take; the composer's preview forwards stderr
chunks into an Output stream session **opened on the first chunk**, so a repository with no hook
or a silent one logs nothing. No marker, no NUL escape, no parser. Found before any Phase 2 code
was written (0068-PLAN, deviation D2).

The spinner's measurement becomes Amendment 0068.3.

## Amendment 0068.3 (2026-09-22): four more buttons move, each to where its code asks

§C says every caller in a `Row` is unaffected and the back bar's `centerLeft` "starts working, with
no change there" — implying the back bar is the only visible change. Classifying all 61 call sites
(a scratch script reading each one's slot and enclosing widgets) contradicts that: 53 are list
elements, whose width was already content-sized; 8 sit in single-child slots, and the effect depends
on the width constraint they receive.

| Call site | Parent asks for | Width | Effect |
|---|---|---|---|
| `common/adaptive_workspace_layout.dart:558` (the back bar) | `centerLeft` | loose | moves left — the fix §C intends |
| `common/async_views.dart:105` | `Column(stretch)` | tight | unchanged |
| `common/image_diff_view.dart:204` | `Expanded` in a `Row` | tight | unchanged |
| `common/repository_workspace_scaffold.dart:116` | `Column` in `Center` | loose | unchanged visually |
| `connection/connection_form.dart:370` | `Align(centerLeft)` | loose | **moves left** |
| `forge/forge_create_sheet_widgets.dart:284` | `Align(centerLeft)` | loose | **moves left** |
| `forge/forge_widgets.dart:231` | `Column(crossAxisAlignment: start)` | loose | **moves left** |
| `switcher/edit_entry_sheets.dart:203` | `Align(centerLeft)` | loose | **moves left** |

Under a tight width a `Center` — with or without `widthFactor` — must fill it, so the two tight
callers render as before. The four marked callers each *ask* for left or start alignment that the
button was silently overriding: the same defect as the back bar, on surfaces none of the 48
workspace goldens renders. The maintainer accepted all four as corrected (0068-PLAN, deviation D3);
Phase 5's device checklist names them so each is seen.

## Amendment 0068.4 (2026-09-23): the preview's wait costs about 70% of a core, and so does a focused message field

Phase 4 measured the release build of `9626e67` with the 0064 frame probe on this Mac: `top`
once a second for the app's pid, and the probe's frame counter, in a scratch repository whose hook
only sleeps.

| State | CPU, mean (n) | Frames |
|---|---|---|
| Repository page, idle | 0.0% (30, and 10 on a second launch) | none |
| Composer open, preview running (spinner) | **69.7%** (15) | 120 fps, every second |
| Composer open after the timeout, message field focused | **62.1%** (15) | 120 fps, every second |
| Composer open, field not focused, no spinner | 0.0% (15) | none |

* **The spinner.** Far past the ~5% line §B drew, so by 0068-PLAN step 4.3, option B2 (an
  elapsed-seconds line in place of the spinner) becomes a follow-up phase, **written and approved
  separately** — no code under this plan. The figure is the whole preview state: the toolbar's
  activity indicator animates alongside the spinner, and the probe cannot apportion the frames
  between them.
* **A finding outside §B.** A focused message field costs nearly as much. `MacosTextField` in
  macos_ui 2.2.2 hard-codes `cursorOpacityAnimates: true` (`lib/src/fields/text_field.dart:1491`),
  so a focused field fades its caret every frame. That is likely true of every `MacosTextField` in
  the app; it was measured only in the composer (a second field could not be focused with the
  composer open). Its scope is the maintainer's to set; it is recorded here, not decided.

## Amendment 0068.5 (2026-09-23): in the app, the timed-out preview still leaves its file behind

Amendment 0068.1's table was measured by running `sh` directly, and
`commit_message_preview_test.dart` does the same. Run by the app, the shipped script does not
behave that way. Four previews on this Mac timed out at the configured 60 s (the script taken
verbatim from the app's process table):

| Run | Hook | Scratch file | Hook's shell | Hook's own child |
|---|---|---|---|---|
| 1 | `sleep 600` in the foreground | left | **still running, reparented to launchd** | orphaned |
| 2 | a hook that traps TERM and logs | removed | stopped | — |
| 3 | the test's hook shape (PID file, foreground `sleep`) | left | stopped | orphaned |
| 4 | as 3, polled every 10 ms | left | stopped, in the same 10 ms as the outer `sh` | orphaned |

The same script, started from a Python harness with the executor's TERM and SIGKILL 400 ms later,
cleaned up in all five variants tried (stdout/stderr read or not, stdin a closed pipe or not,
signalled after 1 s or 5 s). `sh` is bash in both cases, and `/bin` is on the app's `PATH` (the
logging hook ran `/bin` tools), so neither explains it. **The cause is not yet established**; the
maintainer chose to diagnose it in the app before choosing a fix (0068-PLAN, deviation D4). Until
then, §A's first consequence — no scratch file after a timeout — does not hold in the running app.
The orphaned child in every run is 0069-REPORT's finding, as expected.
