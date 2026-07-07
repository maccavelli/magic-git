# Memory & performance audit — RAM footprint

Audit of the Magic Git codebase (2026-07-07) focused on RAM: peak memory,
unbounded growth, memory-management bugs, and where the app can trade a little
resident memory for meaningfully better performance. Five parallel passes
(command-exec, viewer engine, provider lifecycle, streams/timers, heavy-view
rendering); every load-bearing finding below was re-verified against source.

## Headline

The codebase is **unusually well-defended against leaks**. Every `Timer`,
`StreamSubscription`, `StreamController`, and UI controller traced has matching
cleanup on the correct path; watcher restarts tear down before re-arming; the
scrollback (2000 lines), CI-trace UI (256 KiB), and watch buffers (1 MiB) are
all capped; `fileContentProvider`/`fileBytesProvider` are correctly `autoDispose`
so file contents free on window close. There is **one** genuine unbounded-growth
leak (Finding A). The rest are (1) transient peak-memory multipliers on large
inputs, (2) main-thread parse jank with a missing isolate guard, and (3) a
size-blind retention cap. Nothing here risks a hard OOM under normal use; the
existing 50 MiB / 16 MiB caps hold — the issue is the *multiplier* on top of them.

---

## Tier 1 — real bugs / clear wins — ✅ DONE (2026-07-07)

All four implemented with tests; 549 tests pass, analyze clean. `BoundedTail`
extracted to `lib/core/utils/bounded_tail.dart` (reusable). Note on testing B:
`Isolate.run` can't be driven inside flutter_test's custom zone (the closure
captures the unsendable test zone — which is why `SplitDiffView`'s own isolate
path was never widget-tested either), so B's off-thread payload is covered by a
`@visibleForTesting` `debugParseHunkDiff` unit test at scale rather than a
spinner widget test. D and E are covered by their existing behavior suites
(`repo_status_view_test`, `blame_sheet_test`) staying green through the refactor.

### A. `traceStream` buffers all CI-job stderr forever — the one true leak *(MED)* — ✅ done
`lib/core/gitlab/glab_service.dart:557,611` — `errBuf` accumulates **every**
stderr chunk for the entire lifetime of a `glab ci trace` process, and is read
exactly once in `finish()` to tell a stdout-less failure apart from a clean
finish. glab writes progress to stderr, so a long-running job left selected grows
`errBuf` monotonically with no ceiling. (Corroborated by two passes.)
**Fix:** only the *tail* is ever used — replace with a bounded ring/tail buffer
(keep the last ~8–16 KiB) or stop appending past a small bound. O(1) memory,
same failure heuristic.

### B. `HunkDiffView` parses the whole diff on the main thread, no isolate guard *(HIGH)* — ✅ done
`lib/features/repository/hunk_diff_view.dart:79,91` — parses + flattens the
entire diff into one `_LineItem` per line **synchronously in `initState`/
`didUpdateWidget`**. This is the default renderer for a selected tracked file
(`repo_status_view.dart:1150`). Its sibling `SplitDiffView` already offloads to an
isolate above 20 000 lines (`split_diff_view.dart:59,112`) with a `_requestId`
staleness guard — `HunkDiffView` has no such threshold. The asymmetry is the bug.
**Scenario:** select a regenerated `package-lock.json` with a 50k-line diff →
split + 50k object allocations on the UI thread in one frame → multi-hundred-ms
hitch, and `_items` stays resident while selected.
**Fix:** mirror `SplitDiffView`'s threshold + `Isolate.run` + `_requestId` path,
spinner while loading. Apply the same to `DiffView` (`diff_view.dart:60`, the
commit/stash/file-history renderer — same class of unguarded main-thread
`LineSplitter().convert`).

### C. Binary/fallback reads hold 3–6 large copies of the file at once *(HIGH transient)* — ✅ done (Tier 2)
`lib/core/git/git_service.dart:909` returns `base64` output *with* GNU's wrapping
newlines; `lib/features/viewer/viewer_providers.dart:82,101` then does
`b64.replaceAll(RegExp(r'\s'), '')`, allocating a **second** full ~1.37× copy via
the regex engine before `base64.decode`. On the UTF-16/Latin-1 fallback paths the
original `raw` String is still pinned across the `await`, so a 12 MB Windows
UTF-16 file transiently holds ~5–6× (`raw` + `b64` + stripped `b64` + bytes +
decoded) ≈ 65–70 MB. (Corroborated by two passes; verified `readFileBase64` uses
`base64 < path` with no `tr`.)
**Fix:** strip newlines remote-side (`base64 < path | tr -d '\n'`, or `base64 -w0`
where available) so the client never makes the second copy and can
`base64.decode(b64)` directly; drop/scope `raw` before the fallback re-decode;
consider decoding off the main isolate.

### D. `repo_status_view` re-derives the full row model on every build/`setState` *(HIGH churn)* — ✅ done
`lib/features/repository/repo_status_view.dart:1509` — `_statusRows(status)` runs
inside `build`, allocating a fresh `_HeaderRow`/`_FileRow` for every changed file
across all sections, with **no memoization** — unlike `HistoryView`, which
memoizes its derived graph on list identity (`history_view.dart:76`). This widget
`setState`s constantly (every selection tap, every `_busy` toggle around each git
op, each diff toggle). **Scenario:** a 10 000-file working tree → every click
re-allocates ~10k row objects (the status listener at `:751` also builds a 10k
`toSet()` per emission), even though `ListView.builder` renders only ~30.
**Fix:** cache `(lastStatus, lastRows)` and rebuild only when
`!identical(status, _lastStatus)` — Riverpod returns the same `GitStatus`
instance until `statusProvider` is invalidated.

### E. `BlameSheet` allocates a full-length bool list every rebuild *(LOW, trivial)* — ✅ done
`lib/features/repository/blame_sheet.dart:99` — `showMeta =
List<bool>.generate(lines.length, …)` runs in `_BlameBody.build`; it's a pure
function of `lines`. **Fix:** compute once (State field / cache on `lines`
identity) instead of per rebuild.

---

## Tier 2 — worthwhile, moderate effort — ✅ F, G, C done (2026-07-07); H deferred

C (base64 double-copy), F (byte-aware LRU), G (byte-based executor cap) implemented
with tests; 560 tests pass, analyze clean. `KeepAliveLru` extracted to
`lib/core/providers/keep_alive_lru.dart` and `OutputByteBudget`/`boundedBytes`
added to the executor, both unit-tested. H (bytes-first fallback read that avoids
holding `raw` + a second read) is the remaining piece — a larger read-path
refactor left for a focused pass; C already removed its worst copy (the client
whitespace-strip).

### F. Diff/blame/blob LRUs are count-capped (24), not byte-capped *(MED)* — ✅ done
`lib/core/providers/app_providers.dart:1479,1497-1503` — seven `_KeepAliveLru`
caches pin the entire fetched string/list for 24 keys each, with **no per-entry
size limit and no total-byte ceiling** (`while (_order.length > capacity)`). Key
space is bounded and cleared on connect/disconnect/repo-switch, so this is **not a
leak** — it's size-blind retention. **Scenario:** reviewing a run of large
generated-file commits pins up to 24 multi-MB `git show` patches in
`_commitDiffLru` alone (× 7 families). (Corroborated by two passes.)
**Fix:** make `_KeepAliveLru` byte-aware — evict to a summed-`.length` budget
(a few MB/family) and/or refuse `keepAlive()` for an entry over a per-entry
threshold (let one huge diff autoDispose; re-fetching it is cheap vs. pinning it).

### G. The 50 MiB executor cap is char-based, per-stream, and doubles on `toString()` *(MED)* — ✅ done (byte-based + shared budget; toString doubling accepted)
`lib/core/ssh/ssh_command_executor.dart:185,346,352` — `collectBounded` counts
UTF-16 code units, not bytes, so a CJK-heavy file (~3 bytes/unit) can be ~150 MB
on disk under a "50 MiB" cap, while non-Latin content forces TwoByteString so
50 M units = ~100 MB RAM; stdout and stderr each get the full independent cap; and
`StringBuffer.toString()` transiently doubles the content. **Fix:** bound on raw
byte length *before* UTF-8 decode, with a single shared byte budget across
stdout+stderr, so the cap maps to real memory/wire size.

### H. Latin-1/UTF-16 fallback should read bytes once and drop `raw` *(MED)* — deferred (see Tier 2 header)
Same site as Finding C — beyond the newline copy, the fallback does a full second
read (`readFileBase64`) for a file it already read as text, holding both. **Fix:**
fetch bytes once and decode locally under the candidate codec; release `raw`
first.

---

## Tier 3 — higher-leverage perf refactors — ✅ DONE (2026-07-07)

Both implemented with tests; 567 tests pass, analyze clean. I: a persistent
shared worker isolate (`lib/features/viewer/highlight_worker.dart`) registers the
grammars once and services every large-file highlight, replacing the per-file
`Isolate.run` that re-registered all 39 grammars each time; small files still
highlight inline. J: the span model is now `HighlightedLines` — per-line backing
String + `Int32List` run-start/scope-id arrays + an interned scope table — so a
viewer retains ~1xN instead of ~9xN, run substrings are cut lazily at paint, and
the compact form is what crosses the isolate boundary.

### I. Long-lived syntax-highlight worker isolate *(HIGH leverage, concurrency refactor)* — ✅ done
`lib/features/viewer/code_view.dart:195` spawns a **fresh** `Isolate.run` per file;
in the new isolate `_engine` starts null so `registerLanguages` rebuilds all **39**
grammars every open (`syntax_highlighter.dart:113`), and the source is copied in +
spans copied back (~5×N across both heaps for a large file). It's also
**uncancellable**: `didUpdateWidget` bumps `_highlightToken` to *discard* a
superseded result, but the old isolate runs to completion holding its source copy
(also outlives a closed window). **Fix:** one persistent worker isolate holding the
registered engine for the app's lifetime (grammars paid once), request/response
over a `SendPort` with a monotonic id, newest-wins depth-1 queue, a supersede
message so the worker abandons stale work and releases the source, `Isolate.kill`
when no `CodeView` is open. Tradeoff: a small fixed resident grammar heap vs.
today's per-file rebuild + manual port/crash-recovery lifecycle.
*(Previously logged as deferred in `viewer_engine_findings.md`; this quantifies it.)*

### J. Compact highlighted-span representation *(MED-HIGH, retained-memory)* — ✅ done
`code_view.dart:137` retains `List<List<HlRun>>` for the whole file while the
window is open; each `HlRun` (`syntax_highlighter.dart:55`) is a heap object with
its own substring `String`. Dense source fragments into many short runs (~5
chars), so a 4 MB file can retain 20–30 MB of spans (~8×N object overhead), ×
open viewers. **Fix:** per line, one backing `String` + parallel `Int32List` of
(offset, scopeId) boundaries; intern the small fixed set of scope names to `int`
ids and resolve scopeId→`TextStyle` at paint. Cuts both retained overhead and the
isolate copy-back payload.

---

## Tier 4 — low / accepted residuals

- **`normalizeText` / decode allocations** (`text_decoding.dart:29,84,96`): chained
  `replaceAll` + `substring` copy a CRLF/BOM file once; growable `List<int>` in
  `decode16`/`decode32` and a hintless `StringBuffer` in `decodeLatin1` churn on
  multi-MB fallbacks. Fix: single-pass normalizer (keep the zero-copy clean-LF fast
  path); presize into `Uint16List`/`Uint32List` + `String.fromCharCodes`. Micro.
- **Polling watcher on a hidden tab** (`repo_status_view.dart:717`,
  `*_watch_service.dart` `pollTimer` 5 s): in *polling* mode (no fswatch/
  inotifywait) a full `git status` round-trip fires every 5 s even while another
  tab is visible. Fix: gate the watch-driven invalidation on `widget.isActive`
  (event-driven mode can stay armed). Low; only bites the polling fallback.
- **`repoStructureProvider` re-runs the tree isolate on every pane reopen**
  (`app_providers.dart:1354`): optional single-entry keepAlive for the current
  repo's structure. Recompute-vs-RAM judgment call.
- **`StashView` uses a non-virtualized `ListView(children:[...])`**
  (`stash_view.dart:129`): fine for tens of stashes; switch to `.builder` for
  consistency.
- **`OutputLogNotifier._split`** materializes a full command's lines before
  trimming to 2000 (`output_log.dart:72`): transient only; executor already bounds
  output.
- **`readFile` transports a 16–50 MiB file only to classify it `tooLarge`**
  (`git_service.dart:889` → `file_content.dart:84`): pre-check size or lower this
  read's cap toward `maxRenderChars`.

---

## Verified clean (checked, not assumed — don't re-flag)

Watch services tear down before re-arming and cap their un-delimited buffers at
1 MiB; `traceStream.stop()` kills the remote process on autoDispose; GitLab panel
unmounts the trace subtree when inactive; the 256 KiB CI-trace scrollback and
2000-line output log evict correctly; `SSHClientManager` force-closes in-flight
handshakes and uses a generation token so superseded clients aren't retained;
`_snapshotInFlight`/`_pending`/`OwnMutationTracker` maps all evict or clear;
`autoFetchProvider` timer and every `TextEditingController`/`FocusNode`/
`ScrollController`/overlay is disposed; `logSearchProvider` is autoDispose (a
keepAlive there would leak); the file tree is memoized on identity with lazy
ignored-dir eviction. The streaming executor path is exempt from buffering by
design.

---

## Recommended order

1. **A** (stderr tail buffer) — the only real leak, tiny fix.
2. **B** + **D** + **E** — main-thread jank & per-interaction churn in the hottest
   views; targeted, well-scoped, big felt-perf wins.
3. **C** (+**H**) — kill the redundant base64 copy; cuts the large-file transient.
4. **F** + **G** — byte-aware cap & LRU; correctness of the memory ceilings.
5. **I** / **J** — the isolate/span refactors; highest leverage but largest blast
   radius — do behind tests, one at a time.
