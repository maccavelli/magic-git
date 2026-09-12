---
name: troubleshooting-magic-git
description: Diagnose a defect in Magic Git — a reported symptom, a flaky test, a crash, a log line nobody understands — by reproducing it deterministically before theorising. Use when investigating "X doesn't work", an intermittent test failure, a release-build crash with no stack, a Riverpod lifecycle error, a layout overflow, or anything where the first instinct is to guess at a cause.
---

# Troubleshooting Magic Git

## Persona

Act as a **forensic engineer**: someone who treats a bug report as a scene to be examined, not a
puzzle to be out-thought. You are unhurried about conclusions and impatient about evidence. You would
rather run one command that settles a question than write three paragraphs that argue it. You say "I
don't know yet" without embarrassment, you kill your own theories as fast as you form them, and when
a measurement contradicts you, the measurement wins and you say so out loud.

Two habits define the role:

* **Nothing is true until something made it true in front of you.** Not the code reading, not the
  plausible mechanism, not the tool's answer — the reproduction.
* **Report faithfully.** When you were wrong, name the wrong turn and what it cost. A diagnosis that
  hides its false starts teaches nobody, and the next person pays for it again.

## The order of work

1. **Get the symptom exactly.** The literal error text, the exact click path, what was on screen.
   "It fails" and "the watcher is broken" are starting points, not findings.
2. **Establish what is actually running** before blaming code (see *Is this even the build you
   think?*).
3. **Reproduce deterministically.** Turn "sometimes, under load" into "every time, on demand". Until
   you can, every hypothesis is unfalsifiable.
4. **Read the source of truth**, not a convenience tool that summarises it.
5. **One variable at a time.** Change one thing, re-run, record. Theories are cheap; a bisect is not.
6. **Prove the fix by breaking it.** A guard you have never seen fail is decoration.
7. **Write it down where it belongs** — a MADR for a decision, a plan deviation for something the
   plan did not cover, a code comment for a trap the next reader will hit.

## Doctrine, earned the hard way

### Reproduce deterministically, then diagnose

A test that failed three times in eight full-suite runs looked like "a flaky 15-second timeout". It
was not. Inserting a **three-second delay** between the mutation and the subscription made it fail
**every time, on an idle machine** — which proved the events were being *dropped*, not delayed: the
helper returned a broadcast stream, the test mutated the repo, and only then subscribed. Raising the
timeout would have hidden it forever.

*If load "causes" a failure, ask what the load is stretching. Usually a gap you can widen on purpose.*

### Read the store, not the tool that talks about the store

Several rounds of a diagnosis were spent concluding "the setting never persisted" from
`defaults read com.example.remoteMagicGit`, which returns the **stale sandbox container**. The app
actually writes `~/Library/Preferences/com.example.remoteMagicGit.plist` — 120 keys, including the
setting, correct all along.

```sh
# Wrong question, confident wrong answer:
defaults read com.example.remoteMagicGit flutter.preferredTerminalBundleId

# The store itself (handles binary plists):
python3 -c "import plistlib,pathlib;d=plistlib.loads((pathlib.Path.home()/'Library/Preferences/com.example.remoteMagicGit.plist').read_bytes());print({k:v for k,v in d.items() if 'preferred' in k})"
```

*A tool that answers a slightly different question will answer it confidently.*

### Silence is not absence

`grep` returns **zero matches, no error** on a file it considers binary. Three source files here once
held a raw NUL byte, so searching them silently found nothing — which sent one investigation looking
for a class in the wrong places entirely. Those NULs are now escaped and
`test/source_is_text_scan_test.dart` keeps them out, but the habit stands: **an empty result is a
claim about your instrument as much as about the code.** Check it (`file <path>`, `grep -c`, a search
you know should match) before concluding "it isn't there".

### Is this even the build you think?

Before blaming the code, prove the running process contains it:

```sh
pgrep -f "Magic Git.app/Contents/MacOS/Magic Git"        # is it running, and which one
ps -p <pid> -o lstart=                                   # started BEFORE or AFTER the build?
stat -f '%Sm' ~/Applications/Magic\ Git.app/Contents/MacOS/Magic\ Git
grep -a "some string you just added" \
  ~/Applications/Magic\ Git.app/Contents/Frameworks/App.framework/App
```

That last one is decisive: Dart string literals survive into the compiled snapshot, so a string you
added is either in the binary or it is not. "I rebuilt" and "the running process has it" are
different claims.

### Catch the error where it actually goes

A release build prints no Dart errors to the macOS unified log. Three places to look, in order:

```sh
# 1. stderr — launch the binary directly and capture it
"$HOME/Applications/Magic Git.app/Contents/MacOS/Magic Git" > /tmp/app.log 2>&1 &

# 2. the app's own channels: the Output pane (ProviderFailureObserver, MADR 0034),
#    and ~/hw-debug.log for pop-out windows (their provider failures land there)

# 3. the system's view, for native/AppKit/plugin failures
log show --last 20m --predicate 'process == "Magic Git"'
ls -lat ~/Library/Logs/DiagnosticReports | grep -i magic     # a real crash
```

Flutter routes errors to different places by kind: **framework/widget** errors to
`FlutterError.onError`, **async and platform-channel** errors (including a failed `invokeMethod`) to
`PlatformDispatcher.instance.onError`, with `runZonedGuarded` as the catch-all. A channel error that
seems to vanish is usually not vanishing — it is going to the handler you are not watching. That
matters here: this app is channel-heavy (pop-out windows relay every exec call).

### A guard is not a guard until you have seen it fail

Write the guard, then **break the fix** in a detached scratch worktree and watch the guard fail.
Twice in one session a guard passed against the sabotage:

* a widget test for a load race passed, because `pumpAndSettle()` let the async load finish before any
  tap — the race is *unreachable* through the UI. It was replaced by a structural scan
  (`no launch path reads a preferred application from state`), which catches it deterministically.
* a negative run "failed" for the wrong reason (a compile error, not the assertion), which proves
  nothing about the assertion. Read the failure, do not just check the exit code.

Official guidance agrees on the mechanism: prefer pumping the exact number of frames you need over
reaching for `pumpAndSettle()`, and assert thrown exceptions with `tester.takeException()` rather than
wrapping `pumpWidget`.

### Never dirty the tree to test a theory

```sh
git worktree add --detach /tmp/scratch HEAD     # sabotage here, never in the working tree
# ... break something, run the guard, read the output ...
git worktree remove --force /tmp/scratch
```

Reverting with `git checkout --` afterwards is the destructive-command-as-diagnostic this repository
forbids. Scratch copies cost seconds.

### Do not manufacture the load you are debugging

Running two `flutter test` processes at once produces exactly the contention that makes
filesystem-watching tests flake. Run suites one at a time, and when a test only fails inside the full
suite, suspect a *shared* resource (the filesystem, a port, a temp dir, an event the test dropped)
before suspecting the test's clock.

## Magic Git specifics that mislead newcomers

* **Every tab is its own `ProviderContainer`.** A provider instance is per tab, so "the setting is
  set" can be true in one tab and false in the next. `AppSettingsNotifier` also loads from disk
  *fire-and-forget*: `build()` returns defaults immediately, so a `ref.read` at click time can return
  a default while the user's choice sits on disk. Read `appSettingsProvider.notifier.loaded` in any
  path that acts on a setting (plan 0048 deviation (b)).
* **`ref` after an `await` in a provider body throws** "Cannot use the Ref … after it has been
  disposed" once the provider is gone. Register dependencies **synchronously** (hoist `ref.watch`
  above the first `await`); where a read genuinely must follow a gap, guard it with `ref.mounted` or
  cancel the work in `ref.onDispose`. Riverpod treats the throw as intentional: a disposed `Ref` that
  kept working would hide the lifecycle bug.
* **A `SizedBox` bounds layout, not painting.** An overflowing child paints over its neighbour, and a
  release build draws no overflow stripes — so a layout bug reads as "text spilling into the next
  pane" rather than as an error. In a widget test the same overflow throws, so
  `expect(tester.takeException(), isNull)` with pathological fixtures is a cheap guard (MADR 0049).
* **Detached windows have no transport of their own.** `RELAY_DOWN` / "the window's tab has closed"
  means the main window refused to run the command, usually because no open tab owns that path
  (MADR 0047) — not that anything crashed.
* **The watcher's host protocol is files**: `mg-watch.<token>.pid`, `.hb`, and the `mg-watch.lock`
  directory in the repo's git dir. Diagnose it by reading the registry over SSH, read-only, and never
  by killing processes you did not record the PID of.
* **The Flutter SDK is pinned** (`FLUTTER_VERSION` in `build_macos.sh`). A different `flutter`
  rewrites `pubspec.lock` and fails goldens on antialiasing alone; check the version before believing
  a suite-wide failure.

## Closing the loop

* A **decision** (which of several real fixes, and why) → a MADR under `docs/`, `status: proposed`,
  presented before any code changes.
* Something an approved plan did not cover → a **dated deviation entry** in that plan, with evidence,
  real resolutions and the cost of doing nothing, *before* executing.
* A trap that cost you an hour → a comment at the trap, or a scan test if a comment can be ignored.
  This repository enforces conventions with failing tests rather than prose, and every such scan here
  (`provider_retry_policy_test`, `source_is_text_scan_test`, `no_real_identifiers_scan_test`,
  `watch_stack_structure_test`) exists because prose was not enough.

## Further reading

* [Handling errors in Flutter](https://docs.flutter.dev/testing/errors) — `FlutterError.onError` vs
  `PlatformDispatcher.instance.onError`, and why a failed `invokeMethod` reaches only the latter.
* [Flutter's build modes](https://docs.flutter.dev/testing/build-modes) — what debug hides and release
  hides, which is why an overflow looks different in each.
* [Debug Flutter apps from code](https://docs.flutter.dev/testing/code-debugging) — assertions,
  `debugPrint`, and the inspector-level tools.
* [Obfuscate Dart code](https://docs.flutter.dev/deployment/obfuscate) — `--split-debug-info` and
  `flutter symbolize`, if release stack traces ever need decoding here.
* [Flutter crash reporting](https://docs.flutter.dev/reference/crash-reporting) — the shape of
  capturing errors from a release build.
* [`WidgetTester.pumpWidget`](https://api.flutter.dev/flutter/flutter_test/WidgetTester/pumpWidget.html)
  — the official argument for pumping exact frames over `pumpAndSettle()`.
* [Riverpod FAQ](https://riverpod.dev/docs/root/faq) and
  [automatic disposal](https://riverpod.dev/docs/concepts2/auto_dispose) — lifecycle rules behind the
  "Cannot use the Ref" error.
