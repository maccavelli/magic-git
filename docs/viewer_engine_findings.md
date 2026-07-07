# File-view engine & git wiring — assessment backlog

Findings from the 2026-07-06 audit of the file-view engine and git command
wiring, with implementation status. The command-execution layer
(`CommandFormatter`, `ShellEscaper`, both executors) was audited and found sound:
injection is closed on both transports, retries are gated to idempotent reads
only, the output cap fails cleanly (no mid-UTF-8 truncation), and
connection-generation pinning prevents a queued command running against the
wrong host/repo. The issues were concentrated in the viewer's content handling
and window math.

## Phase 1 — done (2026-07-06)

- **[HIGH] CRLF / lone-CR never normalized.** Fixed by `normalizeText` in
  `text_decoding.dart`, applied in `FileContent.classify`.
- **[HIGH] Window sizing crashed when the host was < 420×260.**
  `value.clamp(_minWidth, bounds.width)` threw `ArgumentError`. Fixed with a
  `_fit` helper at every clamp site; `_clamp` also shrinks an over-large window
  to the host, and maximize fills the host exactly.
- **[MED] UTF-8 BOM never stripped** (broke Markdown headings). Stripped in
  `normalizeText`.
- **[MED] UTF-16/UTF-32 text shown as unviewable binary.** `fileContentProvider`
  detects the BOM signature, re-reads bytes, decodes via `decodeUtf16Or32`.
- **[MED] Isolate highlight failure was an uncaught async error.** Added
  `.catchError` in `code_view.dart`.

## Phase 2 — robustness / error surfacing — done (2026-07-06)

- **[MED] Read errors surfaced raw/inconsistently.** `LocalCommandExecutor` now
  maps a `ProcessException` (missing binary / repo dir) to a clean
  `SSHCommandResult(exitCode: 127, …)` — same shape as the SSH path, and no
  longer pointlessly retried. The viewer providers translate the executor
  exception family + `GitException` into a single `ViewerReadException` with a
  user-facing message (no more `"SSH command timed out: cat -- path"`).
- **[MED] Large images failed cryptically.** An output-cap overrun on the bytes
  path now maps to `ViewerReadError.tooLarge`, and the viewer shows the size
  notice + open-externally instead of a raw error.
- **[MED] Open viewers never refetched.** `_refresh` (⌘R) now invalidates the
  `fileContent`/`fileBytes` families, so a manual refresh reflects on-disk edits.

### Deferred from Phase 2

- **[MED] No charset fallback for single-byte non-UTF-8 (Latin-1 / Win-1252).**
  Deferred: unlike the UTF-16 case (a definitive BOM signal), detecting Latin-1
  from a UTF-8-decoded string is fuzzy — it risks a wrong re-decode or an extra
  round-trip for any file with a stray replacement char. Wants a proper charset
  sniff before it's worth doing.

## Phase 3 — rendering fidelity — done (2026-07-06)

- **[MED] Horizontal-scroll width underestimated CJK / tab lines.** The no-wrap
  content width now measures the widest line's true pixel width with a
  `TextPainter` (not `chars × charW`), so the tail is reachable. (Residual: a
  fewer-char but pixel-wider line could still be under-measured — rare.)
- **[MED] Multi-window Escape stalled after the first press.** The front window
  now takes focus when promoted (`isFront` + a post-frame `requestFocus`), and
  `CallbackShortcuts` was reordered to be the *ancestor* of the focus node (a key
  event bubbles up, so the handler must sit above the focused node) — this also
  fixed Escape only working incidentally before.
- **[LOW] Truncation could split a surrogate pair** at the 20000-char boundary.
  `lineToSpan` now backs the cut off a dangling high surrogate.
- **[LOW] Virtualized-list copy dropped off-screen lines.** Added a "Copy file
  contents" title-bar button that copies the full source regardless of scroll.

### Deferred from Phase 3

- **[LOW] Trailing-newline phantom line** (`a\nb\n` shows 3 gutter lines vs an
  editor's 2). Deferred: the split is deliberately lossless (round-trips via
  `join('\n')`) and this behavior is enshrined by tests; changing it for a
  cosmetic one-line difference isn't worth breaking the invariant.
- **[LOW] Fixed `itemExtent` clips tall/emoji glyphs.** Deferred: the only fixes
  either loosen row spacing for every (mostly ASCII) file or drop the
  virtualization win — a poor trade for a rare glyph.
- **[LOW] One overlong line disables highlighting for the whole file.** Deferred:
  the guard exists to keep a 20k+ char line off the tokenizer (a real perf
  cliff); the suggested "highlight normally, plain only that line" still feeds
  the long line to the tokenizer, so it doesn't actually avoid the risk. Tested
  behavior.
- **[LOW] `SelectionArea` over a lazy list** still only selects realized lines.
  The Copy button covers the common need; a true selection-range copy from the
  source string is a larger change.

## Phase 4 — perf / correctness nits — done (2026-07-06)

- **[LOW] Binary sniff missed a binary tail** after a long clean prefix. NUL
  detection now scans the whole (in-memory) string via `contains(the NUL char)`.
- **[LOW] `_charWidth`/`_lineHeight` recomputed every build.** Now cached in
  `late final` fields (metrics depend only on the constant mono font).
- **[INFO] `maxRenderChars` doc** clarified: it's UTF-16 code units, not bytes.

### Deferred from Phase 4 (accepted residuals / higher-risk)

- **[LOW] Title bar overflows (`RenderFlex`) at < ~430px window width.** Deferred:
  a clean fix needs an app-level minimum window size (affects the whole app), not
  a viewer-local change; only reachable in the same extreme small-host case as
  the (fixed) clamp crash.
- **[LOW] Per-file `Isolate.run` re-registers all grammars + double-copies the
  file.** Deferred: a long-lived worker isolate is a real optimization but a
  concurrency/lifecycle refactor that can destabilize; current behavior is
  correct, only large files pay it.
- **[LOW] Retry backoff (400 ms) head-of-line-blocks the serialized queue.**
  Deferred: moving the backoff outside the serialization slot is delicate
  concurrency work in the core executor for a rare (transient-failure-only)
  400 ms stall.
- **[LOW] Snapshot `\x02RMGSNAP\x02` separator collision** for an adversarial
  filename. Deferred: astronomically unlikely, fails safe (throws, no
  corruption), and length-prefixing is a risky rewrite of core snapshot parsing.
- **[INFO] Local env inheritance parity** — `Process.start` inherits the app's
  full environment; the SSH channel gets only the exported prelude. Residual
  parity gap, not an active bug (glab-auth tokens are neutralized on both sides).
