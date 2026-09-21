---
status: "complete"
date: 2026-09-21
verified: 2026-09-21  # against build_macos.sh, pubspec.lock, macos/Runner, and the installed bundle
---

# Flutter SDK Pin Currency — 3.47.2 vs. Current Stable

**Status:** complete. This is an assessment; it decides nothing. The recommendations in §8 need a
maintainer decision, and the one about the renderer (§4) reopens a decision that was believed
closed.

## 1. Summary

| Question | Answer |
|---|---|
| What is pinned? | Flutter **3.47.2** (Dart 3.13.2), `build_macos.sh:45` |
| What is current stable? | Flutter **3.47.5** (Dart 3.13.4), released 2026-09-18 |
| How far behind? | Three hotfixes on the same minor. No minor or major gap. |
| Is the bump feasible? | Yes. It is a patch-level move with no Dart language change and no breaking changes. |
| Does it add immediate value? | **Little.** One fix (#189284, the Xcode 27 debug hang) applies to this machine. No macOS runtime, rendering or security fix lands after 3.47.2. |
| Security patches after 3.47.2? | **None found.** The security fixes that matter are already in the pin (§5). |
| Performance/stability gains? | None documented for macOS desktop. The 3.47.5 engine roll is not itemised (§3). |
| The finding that matters more than the bump | **The app has been rendering with Impeller, not Skia, since the pin moved to 3.47 on 2026-09-04.** Flutter 3.47 turns Impeller on by default on macOS, and nothing in this repository opts out. A P1 macOS Impeller crash matching this app's usage is still open upstream. See §4. |

## 2. Baseline — what is pinned today

Every item below was checked against the tree on 2026-09-21.

* `build_macos.sh:45` sets `FLUTTER_VERSION="3.47.2"`.
* `flutter --version` on this machine reports `Flutter 3.47.2 • … revision d3b14c8769` and
  `Dart 3.13.2`. `flutter pub get --enforce-lockfile` succeeds.
* `pubspec.yaml` has `environment: sdk: ^3.12.2`. The `pubspec.lock` `sdks:` block says
  `dart: ">=3.12.2 <4.0.0"` and `flutter: ">=3.44.0"`.
* The SDK holds some packages below their latest version. `flutter pub outdated` shows
  `test_api 0.7.12` as the newest **resolvable** version, against 0.7.14 published. The same holds
  for `material_color_utilities 0.13.0`. These packages are why a mismatched SDK rewrites the
  lockfile.
* `MACOSX_DEPLOYMENT_TARGET = 12.0` in `macos/Runner.xcodeproj/project.pbxproj`. That is the new
  3.47 minimum, which the pin already meets.
* There is no `macos/Podfile`. Plugins resolve through Swift Package Manager.
* On this machine, Xcode is 27.0 (27A266a) and macOS is 26.6.2.
* **Previous bumps.** In `8d46a31` (2026-07-15) the move cost `build_macos.sh` and 16 lines of
  `pubspec.lock`. In `5e4984e` (2026-09-04, to 3.47.2) it cost the pin plus 48 regenerated goldens
  in `test/goldens/workspace/`, each off by at most tens of bytes of antialiasing. Before that pin
  landed, a mismatch between the Homebrew SDK and the pin produced a false baseline of "48 failing
  goldens". [0023-PLAN](../decisions/0023-PLAN-commit-and-push-perceived-freeze.md) records the
  correction.

What 3.47.2 itself was: the second hotfix of the 3.47 minor, stable on 2026-08-27.

* **3.47.1** fixed a SwiftPM race in parallel macOS builds (#188446) and added plugin-identifier
  validation that closes a code-injection path into `GeneratedPluginRegistrant` (#189156).
* **3.47.2** fixed SwiftPM build failures (#188265, #190846) and carried a **libpng security
  update** (#190987).

## 3. Stable releases after the pin

Source: `releases_macos.json`, the SDK archive manifest (`current_release.stable` =
`6a19cca564…`). Engine hashes come from `bin/internal/engine.version` at each tag.

| Version | Date (UTC) | Framework | Engine | Dart |
|---|---|---|---|---|
| **3.47.2** (pinned) | 2026-08-27 | d3b14c8769 | a804b26164 | 3.13.2 |
| 3.47.3 | 2026-09-09 | e8113bf456 | 06a2e2a110 | 3.13.3 |
| 3.47.4 | 2026-09-11 | 9584c6713b | 06a2e2a110 | 3.13.3 |
| **3.47.5** (stable) | 2026-09-18 | 6a19cca564 | af7e796e16 | 3.13.4 |
| 3.48.0-0.5.pre (beta) | 2026-09-11 | c9306d5b2e | — | 3.14.0 |

Homebrew's `flutter` cask already offers **3.47.5**, and the cask auto-updates.

### Hotfix contents (flutter/flutter `CHANGELOG.md`)

| Release | Fix | Relevant here? |
|---|---|---|
| 3.47.3 | #191045 `Actions.handler` always returned null | **No.** `lib/` never calls `Actions.handler`. |
| 3.47.3 | #191176 Actionable error instead of a `ProcessException` crash when Xcode is missing or incomplete | Tooling only. Nice to have. |
| 3.47.3 | #181315 Impeller on PowerVR (Android); #191487 Android licences in `flutter doctor` | No, Android only. |
| 3.47.4 | **#189284 Under Xcode 27, a debug launch can show a white screen and hang for minutes** | **Yes.** This machine runs Xcode 27.0, so it affects `flutter run`. It does not affect a release build. |
| 3.47.4 | #191898 flutter_tools `FormatException` on test output | Possibly. `flutter test` is the main gate here. No failure of this kind has been seen. |
| 3.47.4 | #192120, #181560 analytics; #191899 Windows Smart App Control; #191964 iOS native assets; #190465 Wasm dry-run | No. |
| 3.47.5 | #190307 iOS 27 device debug crash; #191242 Widget Previewer crash; #189507 DDS startup `FormatException` (dds 5.4.0) | #189507 affects debug sessions only. The rest do not apply. |

3.47.5 also rolls the engine (to `af7e796e16`) and the Dart revision. The release notes say these
infrastructure rolls are not itemised. **What the engine roll contains is unknown.** It may carry
fixes the changelog does not list, and it is the one part of the bump that can move pixels.

### Dart 3.13.3 and 3.13.4

3.13.3 fixes Windows-to-Linux cross-compilation with build hooks. 3.13.4 fixes a dart2js crash.
Neither touches this app, and neither changes the analyzer or any lints. The strict analyzer
configuration will not produce new findings on a 3.47.x bump. The move to 3.47.2 did produce new
findings (`unawaited_return_in_try_block`), but that was a minor bump.

## 4. Renderer: the app runs on Impeller today

The July 2026 assessment concluded "stay on Skia; do not set `FLTEnableImpeller`". It was made
when Impeller on macOS was **opt-in** (Flutter 3.44). Flutter 3.47 reversed the default, and the
pin moved to 3.47.2 on 2026-09-04 without anyone revisiting the decision.

**Evidence:**

* **The official docs say so.** The Impeller page on docs.flutter.dev (updated 2026-08-21) says
  macOS Impeller is "available and enabled by default as of Flutter 3.47. In a future release, the
  ability to opt out of using Impeller will be removed."
* **The engine source at tag `3.47.2`** is
  `engine/src/flutter/shell/platform/darwin/macos/framework/Source/FlutterDartProject.mm:77-84`:
  ```objc
  - (BOOL)enableImpeller {
    NSNumber* enableImpeller =
        [[NSBundle mainBundle] objectForInfoDictionaryKey:@"FLTEnableImpeller"];
    if (enableImpeller != nil) {
      return enableImpeller.boolValue;
    }
    return YES;
  }
  ```
* **The repository never sets the key.** `grep -rni impeller macos/Runner/` finds nothing.
* **Neither does the shipped app.** The installed bundle is v1.8.3, built 2026-09-21 06:56.
  `PlistBuddy -c 'Print :FLTEnableImpeller'` on its `Info.plist` returns "Does Not Exist".

**What was not observed:** the engine's "Using the Impeller rendering backend" line was not seen.
It does not reach the unified log (a 14-day `log show` search found only `impellerc` build-tool
entries), and the app was not launched for this report. The conclusion rests on the source code
and the bundle, not on a runtime observation.

**Why it matters:**

* **The P1 crash is still open.** flutter/flutter#185394, "[Impeller] Crash on macOS when app is
  foregrounded", carries the labels P1, `c: crash` and `platform-macos`, and was last updated
  2026-09-17. This crash was the main reason for staying on Skia. A related report, "App crashes on
  macOS 27 with Impeller" (#192829), is closed. The fix it points to, PR #192522 "[macOS] Fix back
  buffer cache returning a wrong-size surface", is **still open and not merged**, so no stable
  release carries it.
* **Local evidence so far is clean.** `~/Library/Logs/DiagnosticReports/` holds no Magic Git crash
  reports.
* **The renderer-sensitive code is still there.** The vibrancy punch-through,
  `backgroundBlendMode: BlendMode.clear` (`lib/features/repository/file_view.dart:548`), and the
  second FlutterEngine for pop-out windows (`lib/features/window/secondary_window_main.dart`) have
  been running on Impeller since 2026-09-04. No regression has been reported, but nobody checked
  either one deliberately.
* **The goldens don't cover this.** `flutter test` renders through the headless test harness, not
  the Metal backend, so the 48 goldens say nothing about which renderer the app uses.
* **The opt-out has an end date.** Flutter says it will be removed "in a future release". Skia on
  macOS is a dead end whatever this repository decides. The opt-out flag works on 3.47.2: its fix,
  PR #188132 (merge commit `2d594b0`), is contained in the tag, per the GitHub compare API.

The Impeller decision was believed closed. It changes the facts under that decision, not the
decision itself, so the choice goes back to the maintainer (§8).

## 5. Security

| Source searched | Result after 3.47.2 |
|---|---|
| GitHub security advisories, flutter/flutter | None published (the API returns an empty list) |
| GitHub security advisories, dart-lang/sdk | Nothing since CVE-2026-27704 (pub zip-slip, fixed in Dart 3.11 / Flutter 3.41, 2026-02) |
| Dart `CHANGELOG.md` 3.13.3, 3.13.4 | No security entries |
| Flutter `CHANGELOG.md` 3.47.3–3.47.5 | No security entries |
| Web search for Flutter/Dart CVEs, 2026-09 | Only CVE-2026-27704 |

The security fixes that matter are **already in the pin**: libpng (#190987, in 3.47.2) and
plugin-registrant injection hardening (#189156, in 3.47.1). **Not established:** whether the
unitemised engine and Dart rolls in 3.47.5 carry BoringSSL, zlib or similar third-party updates.
Nothing published says they do. This app's network surface is dartssh2 over `dart:io` sockets, plus
the host's own `git`/`gh`/`glab`, which the SDK does not ship.

## 6. Breaking changes and deprecations

* **3.47.x hotfixes break nothing.** The 3.47 breaking changes (the macOS minimum moving to 12,
  `describeEnum` removed, the semantics heading changes) are already in the pin and the tree
  complies.
* **The big one is coming, not here.** Flutter is moving Material and Cupertino out into the
  standalone `material_ui` / `cupertino_ui` packages. 1.0 of both shipped alongside 3.47 as
  opt-in, and deprecating the in-framework libraries comes later, with `dart fix` as the migration
  path. `macos_ui` and every `package:flutter/material.dart` import in `lib/` will eventually be
  affected. Nothing is required on 3.47.x.
* **Beta 3.48 (Dart 3.14.0)** was not reviewed for new lints. A minor bump brought a new
  strict-analyzer finding last time, so expect the same.

## 7. Feasibility and cost of a bump to 3.47.5

The mechanics are cheap and well understood:

1. Set `FLUTTER_VERSION="3.47.5"` in `build_macos.sh:45`.
2. Run `flutter pub get` on 3.47.5 and commit whatever `pubspec.lock` changes. Expect the
   SDK-pinned entries to move.
3. Run `flutter analyze` and the full `flutter test`. Because the engine rolled, expect
   `test/workspace_golden_test.dart` to need regenerating (`--update-goldens`). Check the diff is
   sub-pixel antialiasing, the same way `5e4984e` was checked.
4. Update the version the prose mentions: `CLAUDE.md`, `README.md`, `docs/architecture.md` and
   `.claude/skills/troubleshooting-magic-git/SKILL.md`. Records that cite 3.47.2 as the SDK in use
   when they were written stay as they are.
5. Run `./build_macos.sh --unsigned` and smoke-test the app.

**Blast radius:** one script line, `pubspec.lock`, up to 48 golden PNGs, and four prose files. No
source changes are expected.

**The risk of *not* bumping is concrete.** The Homebrew cask auto-updates to 3.47.5. The moment it
does, the `flutter` on `PATH` no longer matches the pin. `build_macos.sh` handles that by vendoring
3.47.2, but a bare `flutter test` or `flutter pub get` runs on 3.47.5. That rewrites
`pubspec.lock` and can fail the goldens, which is exactly the false baseline that
[0023-PLAN](../decisions/0023-PLAN-commit-and-push-perceived-freeze.md) and
[0024-PLAN](../decisions/0024-PLAN-ssh-and-remote-repo-engine-debug-audit.md) had to correct. Keeping the pin on the version Homebrew installs removes that trap.

## 8. Recommendations (for maintainer decision)

1. **Decide the renderer first, before any SDK work.** The pin is already on Impeller. The choice
   is between two real positions:
   * **(a) Adopt Impeller deliberately.** Run the QA checklist from the July assessment against the
     current build: foreground/background cycling (#185394), window drag and resize, the
     `file_view.dart` vibrancy punch-through, and pop-out windows on the second engine. Record it
     in a MADR that supersedes the July conclusion. This lines up with where Flutter is going.
   * **(b) Restore Skia on purpose.** Add `FLTEnableImpeller` = `false` to
     `macos/Runner/Info.plist` and pin it with a test, the way `macos_entitlements_canon_test.dart`
     pins the entitlements. Record the expiry: the key goes away "in a future release".

   Recommended: **(a)**. There are no local crash reports after 17 days on Impeller, the opt-out
   is scheduled for removal, and the crash's fix is in review upstream. Either way, the state stops
   being accidental.
2. **Bump to 3.47.5: low value, low cost, worth doing.** It removes the Homebrew/pin drift trap
   and fixes the Xcode 27 debug hang. It is not urgent: no security or runtime fixes are waiting.
   Do it after decision 1, so the golden regeneration and smoke test also cover the chosen
   renderer. Re-check PR #192522 at that point. If a later 3.47.x or 3.48 carries it, that release
   is the better target.
3. **Do not move to 3.48 yet.** It is beta only. Take it once it reaches stable, with its own
   lint review.
