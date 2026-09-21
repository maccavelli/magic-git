---
status: "proposed"
date: 2026-09-21
decision-makers: [Maintainer]
consulted: [docs.flutter.dev/perf/impeller, "What's new in Flutter 3.47" (flutter.dev blog), Flutter 3.47.0 release notes, flutter/flutter engine Impeller README and FAQ, flutter/flutter engine source at tag 3.47.2, flutter/flutter issues and PRs cited below, pub-cache sources of every macOS plugin in pubspec.lock, 0062-REPORT-flutter-sdk-pin-currency.md]
informed: [Magic Git contributors]
verified: 2026-09-21
---

# Adopt Impeller as the macOS renderer by declaration, prove it with an on-device gate, and keep Skia only as a time-boxed rollback

## Context and Problem Statement

Flutter ships two rasterizers for macOS: **Skia**, the long-standing backend, and **Impeller**, a
Metal renderer that precompiles its shaders ahead of time. In July 2026, on Flutter 3.44, Magic Git
assessed Impeller and decided to **stay on Skia**. That assessment lived outside this repository
and is not reproduced here. It rested on three facts: Impeller on macOS was then a **preview** you
had to opt into, upstream had already reverted one attempt to make it the default, and an open P1
macOS Impeller crash matched this app's usage. The maintainer's rule was to adopt Impeller once it
is stable and in a stable release, not before.

That condition has since been met, and the switch has already happened, without anyone deciding
it:

* **Flutter 3.47 made Impeller the macOS default.** 3.47.0 reached stable on 2026-08-12.
  [0062-REPORT](../reports/0062-REPORT-flutter-sdk-pin-currency.md) §4 established this, and
  §"Evidence — official status" below restates it.
* **The pin moved to 3.47.2 without revisiting the renderer.** Commit `5e4984e` moved
  `FLUTTER_VERSION` in `build_macos.sh:45` on 2026-09-04.
* **Nothing in the repository opts out.** `macos/Runner/Info.plist` has 16 keys and none is
  `FLTEnableImpeller`. In the 3.47.2 engine, `FlutterDartProject.mm:77-84` returns `YES` when the
  key is absent. The installed bundle (v1.8.3, built 2026-09-21) has no such key either.

So Magic Git has been rendering with Impeller since 2026-09-04, **by default rather than by
decision**. Three things are missing:

* **The choice is undeclared.** The renderer is whatever the pinned engine defaults to, and no file
  in this tree says which renderer the app uses or why.
* **Nothing checks the renderer.** `flutter test` never runs Impeller: the test harness renders
  with software Skia and substitutes test fonts. So the 48 goldens, and every widget test, are
  blind to the renderer the app actually ships with.
* **The known risks have no confirmation step.** Four risk sites were named in July and never
  checked on Impeller: the vibrancy punch-through, the second FlutterEngine, the frame-clock
  workaround, and a blurred offscreen layer.

**The question:** now that Impeller on macOS is the default in a stable release, should Magic Git
adopt it deliberately? If so, what must be declared, tested and kept in reserve so that the choice
is recorded and verified rather than inherited?

## Decision Drivers

* **The maintainer's precondition, met on the evidence.** Impeller must be officially stable and in
  a stable release, not experimental. The engine README's matrix moves macOS from "🧪 Preview" (3.13
  to 3.44) to "✅ Default" at 3.47: "Impeller is the default option, Skia is available". The docs,
  the 3.47 blog and the 3.47.0 release notes all say "default" and never "preview".
* **Skia on macOS is ending upstream.** The docs, blog and README all say the opt-out "will be
  removed" "in a future release". The umbrella issue "Remove Skia from macOS" (flutter/flutter#183031)
  has 10 of 11 sub-issues closed. iOS already went this way: its opt-out was removed in 3.29.
  Staying on Skia buys time, not a destination.
* **Correctness of the renderer-sensitive code the app actually has.** That means the two vibrancy
  punch-throughs, the multi-engine windows, the frame-clock workaround, the blurred minimap layer,
  and thin-stroke graph painting. See §"Evidence — blast radius".
* **Stability.** An open P1 crash (flutter/flutter#185394) hits exactly the actions a desktop Git
  client performs constantly: foregrounding, full-screen toggles and window drags. Its fix
  (flutter/flutter#192522) is open and unmerged.
* **Verifiability.** The repository's rule is that a convention needs a failing check, not a
  sentence. Today no check can fail on a renderer regression.
* **Reversibility.** Whatever is chosen, rolling back must be a one-key change until upstream
  removes the key.
* **Cost and blast radius.** Prefer a decision whose implementation touches configuration, tests
  and records, not feature code.

## Considered Options

* **A.** Adopt Impeller deliberately: declare `FLTEnableImpeller` = `true`, pin it with a test, gate
  it on an on-device verification pass, and keep `false` as a documented, time-boxed rollback.
* **B.** Keep the implicit default and change nothing.
* **C.** Opt out to Skia with `FLTEnableImpeller` = `false` until upstream removes the opt-out.
* **D.** Opt out to Skia until the #185394 fix reaches a stable release, then adopt Impeller.

## Decision Outcome

Chosen option: **"A. Adopt Impeller deliberately"**. The maintainer's condition for adopting is met
by every official source, and the app has already run on Impeller for 17 days with no crash reports
on the development machine. The remaining risk is concentrated in four identifiable sites and one
open upstream crash, and a gate plus a one-key rollback addresses that far better than returning to
a backend upstream is removing.

Concretely, the decision is:

1. **Declare the renderer.** Add `FLTEnableImpeller` = `<true/>` to `macos/Runner/Info.plist`, with
   an XML comment in the style of the existing `FLTEnableMergedPlatformUIThread` note that names this
   MADR. The key changes no behaviour on 3.47.2, where `YES` is already the default. What it changes
   is that the renderer is now stated in the tree and cannot move silently if a future Flutter
   changes the default again.
2. **Pin the declaration with a test.** Add a scan test, in the pattern of
   `test/macos_entitlements_canon_test.dart`, that fails if the key is removed, set to `false`, or
   duplicated. A rollback to Skia (item 5) is then a deliberate edit to both the plist and the test,
   never a drive-by.
3. **Gate adoption on an on-device verification pass.** `flutter test` cannot exercise Impeller, so
   run the checklist in §"Confirmation" on a built `.app`, record the results in a GATES record, and
   move this MADR to `accepted` only when that pass is green. ~~The existing `integration_test/`
   suite, which runs on the real macOS device and therefore on Impeller, is part of the gate.~~
   *(Struck by Amendment 0063.1: `integration_test/` cannot be run legitimately on a machine with no
   signing identity. See §"Amendment 0063.1".)*
4. **Track the open P1.** Carry flutter/flutter#185394 and its fix PR #192522 as named watch items.
   When a stable release contains #192522, the SDK-pin decision in
   [0062-REPORT](../reports/0062-REPORT-flutter-sdk-pin-currency.md) should target that release.
5. **Keep Skia as a time-boxed rollback, not an alternative.** If the gate fails at a site that
   cannot be fixed in app code, or production shows the #185394 crash signature
   (`EXC_BAD_ACCESS` in `impeller::Canvas::SetupRenderPass`), flip the key to `<false/>` in the same
   commit as the test. File an upstream `[Impeller]` issue, as the 3.47 blog asks. Record the
   rollback as an amendment here. The rollback expires when upstream removes the opt-out, and the
   amendment must say so.

Out of scope, each needing its own record if pursued:

* Moving the SDK pin (0062-REPORT §8, item 2).
* Changing feature code to suit Impeller, unless the gate finds a defect. That would be a plan
  deviation, handled under the global deviation rule.
* Adopting Flutter GPU (`FLTEnableFlutterGPU`) or custom fragment shaders.

### Consequences

* Good, because the renderer becomes a recorded, testable property of the tree instead of an
  engine default. A future Flutter that changed the default, or a stray edit, fails a test.
* Good, because it closes the verification gap. For the first time, the risk sites named in July
  get an explicit pass or fail on the renderer the app actually ships with.
* Good, because it aligns with upstream's one direction of travel. Nothing will need migrating when
  the Skia opt-out is removed.
* Good, because it keeps the Impeller-only gains the app already has: no runtime shader
  compilation (the FAQ credits this with better worst-frame times than Skia); SDF rendering for
  shapes (`enableSDFs` returns `YES`); and the 3.47 fix for inconsistent macOS text stroke weights
  (flutter/flutter#186074).
* Good, because the implementation touches configuration, one test, and records only. No feature
  code changes unless the gate finds a real defect.
* Bad, because the P1 crash #185394 is unfixed in every stable release. Choosing A accepts that
  exposure until #192522 ships. The mitigations are the gate, which tries to reproduce it; the named
  crash signature as a rollback trigger; and the one-key rollback.
* Bad, because wide gamut comes with Impeller and doubles surface memory on this hardware. On Apple
  Silicon with a P3 display, the surface format becomes `MTLPixelFormatBGRA10_XR` (8 bytes per
  pixel, against 4 for BGRA8). One 1600×1000-point window at 2× goes from 25.6 MB to 51.2 MB per
  surface. That multiplies by every open engine, and detached-repo windows are unbounded
  (`window_manager_bridge.dart:169-229`).
* Bad, because a known macOS Impeller performance regression exists for complex opacity
  (flutter/flutter#187390: about 4× on `90th_percentile_frame_rasterizer`). The app's opacity use
  is light, 9 `Opacity` and 2 `AnimatedOpacity` sites, but it has not been measured.
* Neutral, because pixels change without layout changing. Glyph rasterisation, soft-shadow falloff,
  blur edges and thin strokes can differ from Skia by antialiasing. Text **layout** still goes
  through Skia's paragraph engine on both backends ("Flutter also continues to use Skia for text
  layout and its image codecs", Impeller FAQ).
* Neutral, because the goldens are unaffected either way: `flutter test` renders with software
  Skia regardless of this key. The flip side is that they can never serve as the renderer check,
  which is why the gate is on-device.
* Neutral, because the app ships arm64 only (`lipo -archs` on the installed binary reports
  `arm64`). The Intel-only Impeller defects (flutter/flutter#191538 whole-window flicker, #189321
  multi-window artifacts) and upstream's withdrawal of x86_64 testing do not affect what ships.
  Any future universal build must revisit this.

### Confirmation

The decision is confirmed, and this MADR moves from `proposed` to `accepted`, when all of the
following hold. The implementation plan (a PLAN under this number) turns each into exact commands
and acceptance criteria.

1. **The declaration check can be seen to fail.** The new scan test fails against scratch copies of
   the plist with the key removed, set to `false`, and duplicated. It passes on the real file.
   Per the global rules, the negative runs use copies and never the working tree.
2. **The runtime reports the backend.** ~~A `flutter run -d macos` session logs~~ *(Amendment
   0063.1: the release binary, launched directly with stderr captured, logs)* the engine's
   "Using the Impeller rendering backend" line. That is the runtime evidence
   [0062-REPORT](../reports/0062-REPORT-flutter-sdk-pin-currency.md) §4 could not collect. The
   release `.app` honours only the plist key: `engine_switches.cc` reads environment switches only
   under `#ifndef FLUTTER_RELEASE`. So the release pass relies on the declaration plus the visual
   checks below.
3. **The on-device gate passes**, with results recorded in a GATES record:
   * **Vibrancy punch-through, both sites.** The main-window sidebar (`macos_ui` `window.dart:326-331`,
     used via `app_shell.dart:1039`) and the Files pane (`file_view.dart:544-549`) show the native
     blur, not black and not an opaque fill. Check with the window active and inactive, in light and
     dark appearance, and after resizing the Files pane. Pop-out windows must still paint their
     opaque `ColoredBox` (`file_view.dart:520-531`).
   * **Second FlutterEngine.** The History window opens, and its menus, sheets and dialogs animate
     in rather than freezing at their first frame. The "vsync probe" line in `~/hw-debug.log`
     (`WINDOW_DIAGNOSTICS`, `secondary_window_main.dart:545-556`) shows advancing timestamps, as
     `secondary_window_binding.dart:18-20` asks for on every upgrade. Also open three detached-repo
     windows at once.
   * **#185394 reproduction attempt.** Background and foreground the app repeatedly, toggle full
     screen then Cmd-Tab (the #192829 repro), drag windows between displays if more than one is
     attached, and hot-plug a display. Pass means no crash, and no new Magic Git report in
     `~/Library/Logs/DiagnosticReports/`.
   * **Blurred minimap.** The History minimap (`history_minimap.dart:266-303`) renders its blurred
     density wash and scrolls without visible stutter on a large history.
   * **Commit graph under zoom.** Lane lines and nodes (`commit_graph_view.dart:50-110`) stay crisp
     and continuous at minimum, default and maximum History zoom (`history_view.dart:2158, 2228`).
   * **Monospace text.** Diff, code and output views (Menlo, `diff_view.dart:23-43`) show no clipped
     glyphs and no uneven stroke weight.
   * **Large paragraph.** A long CI job log in `run_jobs_view.dart:159` (one `SelectableText`)
     scrolls and selects without a stall.
   * **Drag ghost.** A drag started from History or Branches shows its `toImage` snapshot
     (`drag_item.dart:168`), not the fallback label.
   * **Images.** The image diff (overlay and slider modes, `image_diff_view.dart:291-332`), a
     raster image and an SVG in the viewer (`image_preview.dart:41, 79`) render correctly.
   * **Memory.** With the main window plus History plus two detached windows open, record the
     process footprint (Activity Monitor or `footprint`) as the Impeller baseline, so future changes
     have something to compare against.
4. ~~**`integration_test/` passes on the device** (`flutter test integration_test -d macos`). This is
   the only automated suite that exercises the shipping renderer.~~ *(Struck by Amendment 0063.1.)*
5. **The full `flutter analyze` and `flutter test` suites are green** on the pinned SDK, with
   `docs/README.md` and the records checker updated for this MADR.

If any gate item fails, that is a deviation. Stop, take the evidence and resolution options to the
maintainer, and treat the rollback (Decision Outcome item 5) as a fallback of last resort, not the
first move.

## Pros and Cons of the Options

### A. Adopt Impeller deliberately (declare, pin, gate, time-boxed rollback)

* Good, because it meets the maintainer's stated precondition on the official evidence: "✅
  Default", in a stable release, and described nowhere as preview.
* Good, because it turns an inherited default into a declared, test-pinned choice.
* Good, because the on-device gate is the only way to verify the risk sites. It is necessary
  whichever renderer is chosen, since the app has been on Impeller since 2026-09-04.
* Good, because it follows upstream's roadmap, so it needs no future migration.
* Good, because rollback stays a single key, for as long as upstream honours it.
* Neutral, because the key is redundant with the 3.47 default today. Its value is as a
  declaration, not a behaviour change.
* Bad, because it accepts exposure to the open P1 #185394 until #192522 reaches stable.
* Bad, because it accepts doubled wide-gamut surface memory per engine on P3 hardware.

### B. Keep the implicit default

* Good, because it costs nothing now.
* Neutral, because it renders exactly as A does today.
* Bad, because the renderer stays undeclared, and a future default change or a stray plist edit
  would pass every check.
* Bad, because it leaves the verification gap open: nobody has ever checked the risk sites on the
  renderer that ships.
* Bad, because it gives no rollback procedure or trigger, so a #185394 crash in the field would be
  handled ad hoc.

### C. Opt out to Skia until upstream removes the opt-out

* Good, because it avoids #185394, which does not occur under Skia (the #192829 reporter confirmed
  that `--no-enable-impeller` works around it).
* Good, because it restores the renderer the July assessment and all pre-3.47 development were
  done on.
* Bad, because it contradicts the maintainer's rule now that its condition is met.
* Bad, because it is a dead end with no announced date: upstream will remove the opt-out, and on
  iOS it did.
* Bad, because it forfeits Impeller's gains: precompiled shaders, SDF shape rendering, and the text
  stroke-weight fix.
* Bad, because it still needs an on-device verification pass to confirm Skia on 3.47.2, which has
  received less upstream attention on macOS since the default flipped. That verification cost is
  the same as A's.
* Bad, because it turns off wide gamut too (`enableWideGamut` requires `enableImpeller`).

### D. Opt out now, adopt when the #185394 fix ships in stable

* Good, because it avoids the P1 crash window while leading to Impeller.
* Neutral, because it ends at the same place as A.
* Bad, because it costs two renderer transitions, each needing its own verification pass.
* Bad, because it has an unknowable duration: #192522 is open and not yet approved, and nothing
  commits upstream to a release.
* Bad, because the evidence for the crash risk is upstream reports, not this app. The app has run
  on Impeller for 17 days with no local crash reports, so the precaution buys little in exchange
  for the double migration.

## More Information

### Evidence — official status (verified 2026-09-21)

| Source | What it says |
|---|---|
| docs.flutter.dev/perf/impeller (updated 2026-08-21, footer 3.47.2) | macOS: "Impeller is available and enabled by default as of Flutter 3.47. In a future release, the ability to opt out of using Impeller will be removed." Opt-out: `FLTEnableImpeller` = `false` in Info.plist, or `flutter run --no-enable-impeller`. |
| "What's new in Flutter 3.47", 2026-08-12 | "In Flutter 3.47, Impeller becomes the default renderer for macOS, Windows, and Linux." "Fallback options will be removed in a future release, so file bugs if you must revert to using Skia." "Wide Gamut Color is now active by default on macOS." SDF rendering is now used on desktop. |
| Flutter 3.47.0 release notes | "Turned on impeller by default on macos" (PR #186546, merged 2026-05-28). Tests for disabling macOS Impeller (PR #188132). macOS text stroke-weight fix (PR #186074). macOS minimum raised to 12 (PR #188520). |
| Engine Impeller README, availability matrix | macOS "🧪 Preview" for 3.13–3.44, "✅ Default" for 3.47 and main: "Impeller is the default option, Skia is available." iOS alone is "⭐ Exclusive". |
| Engine source, tag 3.47.2 (`engine/src/flutter/shell/platform/darwin/macos/framework/Source/FlutterDartProject.mm`) | `enableImpeller`: Info.plist `FLTEnableImpeller` if present, else `YES` (lines 77-84). `enableWideGamut` = `enableImpeller && DoesHardwareSupportWideGamut()` (line 87). `enableSDFs` returns `YES`. |
| History | macOS preview began in 3.13 (August 2023). A first default flip (PR #164572, 2025-03-10) was reverted three days later (PR #165091) with no reason recorded. The second flip, #186546, stuck. Issue #183045 promised a runtime warning about the opt-out's deprecation; it is not present at 3.47.2. |

### Evidence — upstream defects

As of 2026-09-21 there are six open issues labelled `e: impeller` + `platform-macos`, none of them
P0.

| Issue | Priority | Relevance to Magic Git |
|---|---|---|
| #185394 Crash on macOS when app is foregrounded | P1, crash | **High.** A raster-thread null dereference in `impeller::Canvas::SetupRenderPass`. Reproduced on 3.47.1 with a stock app. Triggers include foregrounding, full-screen toggling followed by Cmd-Tab, window drag and display hot-plug. Fix PR #192522 ("[macOS] Fix back buffer cache returning a wrong-size surface") is open and unapproved, and a reporter confirmed on 2026-09-17 that it fixes the crash. #192829 was closed as its duplicate. |
| #185920 validation errors and missing output using `drawPaint` with an `ImageFilter` | P1 | **None directly.** Neither `lib/` nor `macos_ui` calls `drawPaint`. |
| #187390 Impeller 4× slower in `90th_percentile_frame_rasterizer` for complex opacity | P2 | Low to medium. Opacity use is light but unmeasured. |
| #190016 Vulkan command-buffer synchronisation | P2 | None. macOS uses Metal. |
| #173650 Flutter GPU tests on macOS; #170213 WebView glitches | P3 | None. No Flutter GPU, no platform views. |

Closed issues worth knowing:

* #191538, whole-window flicker on Intel. Fixed on main only; the app is arm64-only.
* #190150, about 470 MB of IOSurface memory pinned while frames are produced. Auto-closed for no
  response, not fixed; it informs the memory gate item.
* #192097, repeated `toImage()` leaks native memory (P1, cross-platform). The app calls `toImage`
  once per drag, not repeatedly.

### Evidence — blast radius in this codebase

The survey covered `lib/`, `test/`, `macos/` and `integration_test/`, with no truncated searches.
The risk sites, ranked:

| # | Site | Why it is renderer-sensitive | Risk |
|---|---|---|---|
| 1 | Vibrancy punch-throughs: `file_view.dart:544-549` and `macos_ui-2.2.2` `window.dart:326-331` (the main sidebar via `app_shell.dart:1039`), resting on `macos_window_utils-1.9.1` `MacOSWindowUtilsViewController.swift:29-56` (`NSVisualEffectView` root, `flutterViewController.backgroundColor = .clear`) | `BlendMode.clear` must reach the window as real alpha through Impeller's surface, which is BGRA10_XR on P3 hardware. No pixel-level test exists. `test/file_view_test.dart:337-384` checks only that the widget is present. | High |
| 2 | Multiple engines: `SecondaryWindowController.swift:150` (`project: nil`, so the same plist and therefore Impeller), with History as a singleton and detached-repo windows unbounded | Each engine gets its own Impeller Metal context, glyph atlas and wide-gamut surfaces. Moving between displays swaps the surface format (`FlutterEngine.mm:1532-1540`). | High (memory) |
| 3 | Secondary-engine frame clock: `secondary_window_binding.dart:3-55`, with `FLTEnableMergedPlatformUIThread` = `false` (`Info.plist:39-47`, commit `6b10c0f`) | Both were tuned empirically on the pre-3.47 renderer, and both say to re-check on upgrades | Medium |
| 4 | Blurred offscreen layer: `history_minimap.dart:266-303` | A `saveLayer` with `ImageFilter.blur`, containing a few hundred `ui.Gradient.linear` strips, repainted on every scroll tick. Blur edge behaviour and cost differ between backends. | Medium to high |
| 5 | One huge paragraph: `run_jobs_view.dart:159` | A whole CI log in one `SelectableText`, which stresses the glyph atlas | Medium to high |
| 6 | Thin strokes under zoom: `commit_graph_view.dart:50-110`, with `history_view.dart:2158, 2228` | Strokes of 1.4–1.8 px with round caps, drawn per row. Impeller tessellates strokes differently from Skia. | Medium |
| 7 | Drag snapshot: `drag_item.dart:168` (`RenderRepaintBoundary.toImage`) | GPU readback, possibly from a wide-gamut surface. It fails soft into a label fallback (`drag_item.dart:161-185`). | Medium |
| 8 | Images: `image_preview.dart:41` (`Image.memory`, no decoded-dimension guard) and `:79` (`SvgPicture`), plus `image_diff_view.dart:291-332` | The vector_graphics raster path uses `saveLayer`, `BlendMode.dstIn` and `drawVertices`. Known Impeller SVG bugs are iOS/Android only. | Medium |
| 9 | Monospace text: Menlo in `diff_view.dart:23-43` and six other views | Glyph rasterisation differs between backends, while metrics do not. No automated test renders Menlo (the harness forces test fonts). | Medium |
| 10 | 14 `BoxShadow` sites in 10 files | Impeller computes soft shadows analytically, so falloff may differ | Low (cosmetic) |

**Absent from this codebase:**

* No `FragmentProgram`, `.frag` shaders, `ImageShader`, `drawVertices`, `drawAtlas`,
  `PictureRecorder`, `BackdropFilter`, `MaskFilter` or `ColorFiltered` in `lib/`.
* No platform views or `Texture` widgets.
* No custom fonts. The pubspec `fonts:` block is commented out.
* No SkSL warm-up or `--bundle-sksl-path`.
* No renderer flags in `build_macos.sh` or the xcconfigs.

`macos_ui` adds `BackdropFilter` blurs of its own (`title_bar.dart:100`, `toolbar.dart:386`,
`overlay_filter.dart:71`).

### Evidence — dependencies

* **Native code builds the same way on both renderers.** Plugins build through Swift Package
  Manager only: there is no `macos/Podfile`, and `FlutterGeneratedPluginSwiftPackage` lists 10
  plugin packages. `objective_c` 9.4.1 ships as a native-assets framework, pulled in by
  `path_provider_foundation` 2.6.0. None of these touch Metal, OpenGL or `FlutterTexture`, so
  Impeller changes nothing about how they build or link.
* **Rendering-relevant packages**, all at the locked version (latest unless noted):

  | Package | Version | What it does that matters | Risk |
  |---|---|---|---|
  | `macos_window_utils` | 1.9.1 | Vibrancy host view | Medium |
  | `macos_ui` | 2.2.2 | Sidebar `BlendMode.clear` and `BackdropFilter` blurs | Medium |
  | `window_manager` | 0.5.2 | AppKit window transparency and opacity only | Low |
  | `flutter_svg` / `vector_graphics` | 2.3.0 / 1.2.2 (1.2.3 available) | SVG rendering in the viewer | Low to medium |
  | `flutter_html` | 3.0.0 | Widgets and text only | Low |
  | `flutter_markdown_plus` | 1.0.12 | Widgets and text only | Low |
  | `re_highlight` | 0.0.3 | `TextSpan`s only | None |

* **No known Impeller issues in any of them.** Searches of the `macos_ui`, `macos_window_utils` and
  `window_manager` issue trackers for "impeller", "metal", "vibrancy" and "transparent" found none.
  `macos_window_utils` had no commits after 2026-01-05, so a fix, if one were needed, would likely
  have to come from this repository or a fork.
* **Irrelevant to the renderer:** `dartssh2` (pure Dart, no FFI), the secure-storage, file-selector,
  shared-preferences, URL-launcher and drag-and-drop plugins, and `screen_retriever`. None of the
  pending upgrades (`desktop_drop` 0.8.4, `flutter_secure_storage` 11.x, `dartssh2` 4.x) is an
  Impeller fix.

### Evidence — test coverage

* **`flutter test` always renders with software Skia.** At
  `flutter_tools/lib/src/test/flutter_tester_device.dart:113-115` (SDK 3.47.2), the tester gets
  `--enable-impeller` only when asked, and otherwise gets
  `--enable-software-rendering --skia-deterministic-rendering`, plus `--use-test-fonts` and
  `--disable-asset-fonts`. `flutter test --enable-impeller` does not help on macOS: the flag's help
  text says it "will be ignored" on platforms other than iOS and Android.
* **So the goldens cannot see the renderer.** `test/workspace_golden_test.dart` has 48 goldens,
  and every widget test is renderer-blind in the same way. The only automated code that runs on the
  shipping renderer is `integration_test/`: `smoke_test.dart` and `history_search_test.dart`, run on
  the macOS device. Amendment 0063.1 records why neither can serve as the gate on this machine.

### Amendment 0063.1 (2026-09-21, before acceptance)

Writing the plan tested two assumptions in §"Confirmation" against the tree, and both were wrong.

* **`integration_test/` cannot gate this on a machine without a signing identity.**
  `security find-identity -v -p codesigning` reports "0 valid identities found", and
  `project.pbxproj` sets no `DEVELOPMENT_TEAM`. `flutter test integration_test -d macos` builds the
  Debug configuration, which signs with `DebugProfile.entitlements`, including
  `keychain-access-groups`. `integration_test/history_search_test.dart:9-14` records the resulting
  failure, and its documented way around it is to edit that committed file, which `CLAUDE.md`
  forbids. The legitimate override (`MG_DEBUG_ENTITLEMENTS` pointing at
  `DebugProfile-unsigned.entitlements`) keeps the app sandbox, and the same note says the sandbox
  blocks that test's temp-directory repositories. `integration_test/smoke_test.dart:5-6` promises a
  skip when `INTEGRATION_SSH_HOST` is unset, but its code never checks the variable. Neither suite is
  therefore a sound gate item. The on-device gate runs against the release artifact that ships, and
  making `integration_test/` runnable without a certificate is recorded under §"Incidental findings".
* **`flutter run -d macos` is replaced by launching the release binary.** It builds the same
  sandboxed, keychain-entitled Debug configuration. The release binary built by
  `./build_macos.sh --unsigned`, launched directly with stderr redirected, prints the engine line.
  On macOS, `FML_LOG` writes to stderr (`fml/logging.cc`, the non-Android/iOS/Fuchsia branch). The
  SDF variant is on unconditionally (`FlutterDartProject.mm` `enableSDFs` returns `YES`), so the
  exact line is `Using the Impeller rendering backend (MetalSDF).`, from
  `embedder_surface_metal_impeller.mm:53`.

The decision itself is unchanged.

### Incidental findings (out of scope, recorded so they are not lost)

* **A misleading comment.** The comments at `file_view.dart:129-131` and `:573-576` say the
  punch-through flicker was "diagnosed" in `output_view.dart`. `output_view.dart` contains no
  `BlendMode` or `RepaintBoundary` today, and `git log -S 'BlendMode.clear'` shows only the initial
  commit.
* **Stale line references.**
  [0006-PLAN](0006-PLAN-hybrid-native-title-bar-context-bar.md) and
  [0007-PLAN](0007-PLAN-docs-completion-audit.md) cite `file_view.dart:460-471` for the
  punch-through; it is now at 538-551.
* **`integration_test/` needs a path to run without a certificate.** See Amendment 0063.1. It
  needs its own decision: a tracked, unsandboxed debug entitlements variant selected through
  `Local.xcconfig`, and a real skip in `smoke_test.dart`.
* **No decode-size guard in the image preview.** `image_preview.dart:41` decodes images with no
  dimension guard, unlike `image_diff_view.dart:23-24`. That is a memory question on either
  renderer.

### Revisit triggers

* **#192522 lands in a stable release.** Re-point the SDK pin decision at that release (0062-REPORT
  §8), rerun gate items 3 and 4, and drop #185394 from the rollback triggers.
* **Upstream removes the macOS opt-out.** Delete the rollback clause by amendment. The plist key
  becomes inert, so remove it together with its test in the same commit, or keep both as a harmless
  declaration; the amendment decides which.
* **A Flutter upgrade.** Rerun the gate's vibrancy, second-engine and #185394 items, alongside the
  existing "vsync probe" re-check.
* **A universal or x86_64 build.** The Intel-only defects become in scope and need their own
  assessment.
