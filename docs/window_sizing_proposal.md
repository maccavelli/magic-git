# App-level window sizing — assessment & proposal

Audit of every window/pane/sheet size the app uses, why several are oversized,
and a proposed ergonomic scheme. Numbers marked **✅ implemented** are done (they
were the overflow/crash fix you asked for); everything under **Proposed** is for
review before I touch it.

## 1. Root cause: there is no live minimum window size

`main.dart` set an initial size (1200×800) but **never a minimum**, and the
macOS `MainFlutterWindow.swift` sets none either. So the window could be dragged
to any size — and that single gap is what made three separate bugs *reachable*:

- the file-viewer size clamp crash (`clamp(420, <420)` → `ArgumentError`),
- the diff-pop-out size clamp (same pattern, and worse — it lives in the content
  area = window minus sidebar, so it goes sub-420 even before the window does),
- the viewer title-bar `RenderFlex` overflow at < ~430px.

A minimum window size comfortably above the in-app floating-window minimums
(viewer 420×260, pop-out 420×280) closes all three at once.

### ✅ Implemented (the overflow fix)

| Change | Value | File |
|---|---|---|
| Live minimum window size | **640×480** | `main.dart` (`kMinWindowSize`), enforced via `windowManager.setMinimumSize` + `WindowOptions.minimumSize` |
| Persisted-bounds floor raised to match | 480×360 → **640×480** | `WindowBoundsStore.minWidth/minHeight` |
| Diff pop-out clamp made crash-safe | `_fit` helper (matches the viewer fix) | `diff_popout_window.dart` |

640×480 keeps the sidebar (240–380) plus a usable content pane, and sits above
every floating-window minimum so those never end up larger than their host —
which is what made the title bar overflow and the clamps throw. Trivially tunable
(one constant). Regression tests added for both the viewer and the pop-out at
sub-minimum bounds.

## 2. The default window is oversized for laptops

1200×800 nearly fills a 13"/14" MacBook, which reads as "huge":

| Display (points) | 1200×800 covers | 1080×720 covers |
|---|---|---|
| MacBook Air/Pro 13" — 1440×900 | 83% × 89% | 75% × 80% |
| MacBook Pro 14" — 1512×982 | 79% × 81% | 71% × 73% |
| MacBook Pro 16" — 1728×1117 | 69% × 72% | 63% × 64% |

**Proposed:** default **1080×720** (only on true first launch — a persisted size
still wins). Leaves a comfortable margin on a 13", still roomy for the three-pane
layout. Optional stretch: clamp the first-launch default to `screen × 0.8` so it
also fits unusually small external displays.

## 3. Sheets: one is genuinely unconstrained, the rest are viewport-relative

Full inventory (all 13 `MacosSheet`s + dialogs):

| Sheet | Current size | Verdict |
|---|---|---|
| **Text prompt** (`history_view.dart:194`) | **none** — fills window (~1060px) for one text field | **oversized — fix** |
| Commit-detail (`history_view.dart:767`) | 0.82w (600–**1200**) × 0.86h (400–**950**) | large but content-heavy |
| File history (`file_history_sheet.dart:32`) | 0.78w (640–**1100**) × 0.82h (440–900) | content-heavy |
| Blame (`blame_sheet.dart:23`) | 0.70w (560–**980**) × 0.80h (420–900) | slightly generous |
| Rebase (`rebase_sheet.dart:137`) | 0.60w (520–760) × 0.72h (400–820) | fine |
| New connection (`connection_landing.dart:373`) | 0.60w (460–680) × 0.82h (460–900) | fine |
| Keyboard mappings | 640×560 fixed | fine |
| Connection switcher | 540×500 fixed | fine |
| Settings | 500 wide, intrinsic height | fine |
| Create MR | 520 wide, body maxHeight 460 | fine |
| New local repo / Add repository | 480 wide | fine |
| Commit dialog | intrinsic, clamped 420–680 | exemplary |
| Guardrail / alert dialogs | ~260 wide | fine |

**Proposed:**
1. **Cap the text-prompt sheet** to ~**440** wide (it's a title + one field +
   Cancel/OK). This is the only true "huge for no reason" sheet. *(Clear win — I
   can fold this into the overflow fix if you want.)*
2. Optional modest trims to the upper clamps on the big content viewers, so they
   don't sprawl on a 27" monitor: commit-detail **1200→1120 / 950→880**, file
   history **1100→1040**, blame **980→880**. These only affect large external
   displays; the lower clamps and viewport-relative behavior stay.
3. Leave every fixed/intrinsic sheet as-is — they're already right-sized.

## 4. Status — all applied (2026-07-06)

Everything in this proposal is now implemented and tested (522 tests pass):

| Change | From → To | File |
|---|---|---|
| ✅ Live minimum window size | none → **640×480** | `main.dart` |
| ✅ Persisted-bounds floor | 480×360 → **640×480** | `app_providers.dart` |
| ✅ Diff pop-out clamp crash-safe | `_fit` helper | `diff_popout_window.dart` |
| ✅ Default window size | 1200×800 → **1080×720** | `main.dart` |
| ✅ Text-prompt sheet cap | unconstrained → **440 wide** | `history_view.dart` |
| ✅ Commit-detail clamp | 1200×950 → **1120×880** | `history_view.dart` |
| ✅ File-history clamp | 1100 → **1040** wide | `file_history_sheet.dart` |
| ✅ Blame clamp | 980 → **880** wide | `blame_sheet.dart` |

Regression tests: sub-minimum bounds for the viewer and diff pop-out (no crash),
and the text-prompt sheet width cap. The 640×480 minimum and 1080×720 default are
each a single constant if you want to retune.
