import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../core/git/unified_diff.dart';
import '../../core/providers/app_providers.dart';
import '../viewer/code_view.dart' show CodeTheme, codeThemeFor;
import '../viewer/file_type.dart';
import 'diff_highlight.dart';
import 'diff_view.dart';
import 'image_diff_view.dart';
import 'inline_action_button.dart';
import 'patch_model.dart';
import 'tappable.dart';

/// A commit's patch with **inline context expanders**: the `⋯` rows between
/// hunks reveal the code git left out (it emits only three context lines, so a
/// hunk routinely ends mid-expression and reads as if the diff were cut off).
///
/// Structurally this is the same shape as [DiffView] — one fixed-height row per
/// line, a single shared horizontal pan so every line's tail is reachable, one
/// [SelectionArea] over the lot. What it adds is a typed row model, so a row can
/// be an interactive expander rather than only text.
///
/// Expansion reads the file as the commit left it ([blobLinesProvider]) and
/// splices those lines in as context — but only after [verifyBlobMatchesHunks]
/// confirms the blob really is the one the hunks were computed against. If it
/// isn't, this shows the patch unexpanded rather than render lines it cannot
/// vouch for.
class CommitPatchView extends ConsumerStatefulWidget {
  final String repoPath;

  /// The commit whose post-image the expanders read from.
  final String hash;

  /// The raw `git show` output.
  final String diff;

  final bool wrap;

  /// The pre-image revision. A single-commit view defaults to the first
  /// parent; a range comparison supplies its explicitly selected older commit.
  final String? beforeRevision;

  const CommitPatchView({
    super.key,
    required this.repoPath,
    required this.hash,
    required this.diff,
    this.wrap = false,
    this.beforeRevision,
  });

  @override
  ConsumerState<CommitPatchView> createState() => _CommitPatchViewState();
}

class _CommitPatchViewState extends ConsumerState<CommitPatchView> {
  /// A commit patch is the biggest thing this app renders — a vendored
  /// dependency bump or a regenerated lockfile runs to tens of thousands of
  /// lines — and it used to be parsed inline, on the UI thread, straight from a
  /// field initializer. [DiffParser] moves exactly those off thread, and leaves
  /// the ordinary commit parsing inline where it belongs.
  final DiffParser<CommitPatch> _parser = DiffParser(parseCommitPatch);

  final ScrollController _vertical = ScrollController();
  final ScrollController _horizontal = ScrollController();

  CommitPatch? _patch;
  bool _loading = false;
  int? _imageFileIndex;

  /// How far each gap has been opened. Keyed by (file, gap) so it survives the
  /// rebuild an expansion itself triggers; cleared when the patch changes.
  Map<ExpandRequest, GapExpansion> _expansions = {};

  /// Files whose blob the user has actually asked for. Fetching every file's
  /// blob up front would be a command per file on every commit selection — so a
  /// file's blob is only fetched once its expander is clicked.
  Set<int> _wanted = {};

  /// Files whose blob was asked for and could not be had — so the expander can
  /// say so instead of sitting there as a control that silently does nothing.
  Set<int> _blobFailed = {};

  /// The rendered rows, and the width of the widest of them.
  ///
  /// Both are O(patch) to derive, and both are a pure function of (patch,
  /// expansions, blobs) — so they are derived when one of those actually moves,
  /// and reused otherwise. They used to be rebuilt on every `build` (which is
  /// every expander click, on a patch that can run to tens of thousands of rows)
  /// and the width was measured inside the `LayoutBuilder`, so it was re-walked
  /// on every layout pass of every frame of a window resize.
  List<PatchRow> _rows = const [];
  double _maxLineWidth = 0;

  /// Syntax runs per row, parallel to [_rows] (null for non-code rows and when
  /// highlighting is skipped). Precomputed with the rows so it's off the render
  /// path — one highlight pass per file, not per visible line per frame.
  List<List<ScopedRun>?> _rowRuns = const [];

  // The inputs the cached rows were built from. Compared by identity: the patch
  // is replaced only by a re-parse, and [_expansions] is rewritten wholesale on
  // every change rather than mutated, so identity is exactly the right question.
  CommitPatch? _rowsPatch;
  Map<ExpandRequest, GapExpansion>? _rowsExpansions;
  Map<int, List<String>?> _rowsBlobs = const {};

  void _deriveRows(CommitPatch patch, Map<int, List<String>?> blobs) {
    if (identical(_rowsPatch, patch) &&
        identical(_rowsExpansions, _expansions) &&
        _sameBlobs(blobs)) {
      return;
    }
    _rowsPatch = patch;
    _rowsExpansions = _expansions;
    _rowsBlobs = blobs;
    _rows = buildPatchRows(patch, expansions: _expansions, blobs: blobs);
    _maxLineWidth = measureDiffWidth(_rowTexts(_rows));
    _rowRuns = _computeRowRuns(patch, _rows);
  }

  /// Highlights each file's code rows against its language, once per file, and
  /// scatters the runs back to their row positions. Gated by total size — a
  /// vendored-dependency-sized patch renders kind-coloured rather than paying
  /// the highlighter on the UI thread.
  static List<List<ScopedRun>?> _computeRowRuns(
    CommitPatch patch,
    List<PatchRow> rows,
  ) {
    final runs = List<List<ScopedRun>?>.filled(rows.length, null);
    if (rows.length > kDiffIsolateLineThreshold) return runs;
    final byFile = <int, List<int>>{};
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      if (row is CodeRow) (byFile[row.fileIndex] ??= <int>[]).add(i);
    }
    for (final entry in byFile.entries) {
      if (entry.key < 0 || entry.key >= patch.files.length) continue;
      final lang = diffLanguageId(patch.files[entry.key]);
      final indices = entry.value;
      final contents = [
        for (final i in indices) _stripMarker((rows[i] as CodeRow).text),
      ];
      final imageRuns = highlightImageRuns(contents, lang);
      for (var k = 0; k < indices.length; k++) {
        runs[indices[k]] = imageRuns[k];
      }
    }
    return runs;
  }

  static String _stripMarker(String line) =>
      line.isEmpty ? '' : line.substring(1);

  /// Riverpod hands back the *same* list instance for a blob until it is
  /// refetched, so identity per entry answers "did any blob actually change?".
  bool _sameBlobs(Map<int, List<String>?> blobs) {
    if (blobs.length != _rowsBlobs.length) return false;
    for (final entry in blobs.entries) {
      if (!identical(_rowsBlobs[entry.key], entry.value)) return false;
    }
    return true;
  }

  @override
  void initState() {
    super.initState();
    _startParse(widget.diff, initial: true);
  }

  @override
  void didUpdateWidget(CommitPatchView old) {
    super.didUpdateWidget(old);
    if (old.diff != widget.diff || old.hash != widget.hash) {
      // A different patch: its gaps and blobs have nothing to do with the
      // previous one's. Reset on the *diff* changing too, not only the hash —
      // gap indices are positions in a particular hunk layout, and re-parsing
      // gives a different one, so carrying them across would show gaps opened
      // that the user never opened.
      _expansions = {};
      _wanted = {};
      _blobFailed = {};
      _imageFileIndex = null;
      _startParse(widget.diff, initial: false);
    }
  }

  @override
  void dispose() {
    _vertical.dispose();
    _horizontal.dispose();
    super.dispose();
  }

  void _startParse(String diff, {required bool initial}) {
    final inline = _parser.parse(
      diff,
      onDone: (patch) {
        if (!mounted) return;
        setState(() {
          _patch = patch;
          _loading = false;
        });
      },
      // Parse failed, or the isolate never spawned. A commit patch that cannot
      // be parsed still has to render: fall through to the flat [DiffView] (see
      // build) rather than leave the pane spinning on nothing.
      onFailed: () {
        if (!mounted) return;
        setState(() {
          _patch = null;
          _loading = false;
        });
      },
    );

    // Null means it went off-thread and hasn't landed: show the spinner. During
    // initState the imminent first build reads the fields directly.
    if (initial) {
      inline == null ? _loading = true : _patch = inline.result;
      return;
    }
    setState(() {
      _patch = inline?.result;
      _loading = inline == null;
    });
  }

  /// The post-image lines for [fileIndex], or null when they aren't available:
  /// not requested, still loading, failed, or — the case that matters — a blob
  /// that doesn't match the hunks, which must never be spliced.
  List<String>? _blobFor(int fileIndex, CommitPatch patch) {
    if (!_wanted.contains(fileIndex)) return null;
    final file = patch.files[fileIndex];
    final path = file.newPath;
    if (!file.canExpand || path == null) return null;

    final async = ref.watch(
      blobLinesProvider((widget.repoPath, widget.hash, path)),
    );

    // A blob that failed to read (or that the hunks disagree with) leaves the
    // expander as a control that does nothing when clicked, forever, with no
    // explanation. Record it so the row can say what happened instead.
    final failed =
        async.hasError ||
        (async.hasValue && !verifyBlobMatchesHunks(file, async.value!));
    if (failed != _blobFailed.contains(fileIndex)) {
      // Not during build: this is a render-time discovery about async state.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() {
          failed ? _blobFailed.add(fileIndex) : _blobFailed.remove(fileIndex);
        });
      });
    }
    if (failed) return null;

    return async.value;
  }

  void _expand(ExpandRequest request, ExpandDirection direction, int hidden) {
    setState(() {
      _wanted = {..._wanted, request.fileIndex};
      final current = _expansions[request] ?? const GapExpansion();
      _expansions = {..._expansions, request: current.plus(direction, hidden)};
    });
  }

  /// Shuts a gap again. The blob stays in [_wanted] — it's already fetched and
  /// cached, and the user who opened this gap once will likely open it again.
  void _collapse(ExpandRequest request) {
    setState(() {
      _expansions = {..._expansions}..remove(request);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.diff.trim().isEmpty) return const DiffEmpty();
    if (_loading) return const DiffPending();

    final patch = _patch;
    // Unparseable: still show the user their diff, just without the expanders.
    if (patch == null) return DiffView(diff: widget.diff, wrap: widget.wrap);

    // Watching the blobs is what can change the rows out from under us, so this
    // is where the rows are derived — but only when something they depend on has
    // actually moved.
    final blobs = <int, List<String>?>{
      for (var i = 0; i < patch.files.length; i++) i: _blobFor(i, patch),
    };
    _deriveRows(patch, blobs);

    final macosTheme = MacosTheme.of(context);
    final defaultColor =
        macosTheme.typography.body.color ?? MacosColors.textColor;
    final codeTheme = codeThemeFor(macosTheme.brightness);

    final patchBody = widget.wrap
        ? _list(defaultColor, codeTheme, null)
        : DiffPan(
            vertical: _vertical,
            horizontal: _horizontal,
            maxLineWidth: _maxLineWidth,
            builder: (context, _, viewportWidth) =>
                _list(defaultColor, codeTheme, viewportWidth),
          );
    final imageFiles = <int>[
      for (var index = 0; index < patch.files.length; index++)
        if (_isReviewableImage(patch.files[index])) index,
    ];
    if (imageFiles.isEmpty) return patchBody;

    final selected = _imageFileIndex;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _imageReviewBar(context, patch, imageFiles),
        Container(height: 1, color: MacosColors.separatorColor),
        Expanded(
          child: selected == null
              ? patchBody
              : _commitImageDiff(patch.files[selected]),
        ),
      ],
    );
  }

  bool _isReviewableImage(DiffFile file) {
    final path = file.newPath ?? file.oldPath;
    return path != null &&
        file.change == DiffFileChange.binary &&
        viewerFileTypeFor(path).preview == PreviewKind.image;
  }

  Widget _imageReviewBar(
    BuildContext context,
    CommitPatch patch,
    List<int> imageFiles,
  ) {
    return SizedBox(
      height: 38,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        child: Row(
          children: [
            InlineActionButton(
              label: 'Text patch',
              icon: _imageFileIndex == null
                  ? CupertinoIcons.check_mark
                  : CupertinoIcons.doc_text,
              onPressed: () => setState(() => _imageFileIndex = null),
            ),
            for (final index in imageFiles) ...[
              const SizedBox(width: 5),
              InlineActionButton(
                label:
                    'Review ${patch.files[index].newPath ?? patch.files[index].oldPath}',
                icon: _imageFileIndex == index
                    ? CupertinoIcons.check_mark
                    : CupertinoIcons.photo,
                onPressed: () => setState(() => _imageFileIndex = index),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _commitImageDiff(DiffFile file) {
    final added = file.change == DiffFileChange.added;
    final deleted = file.change == DiffFileChange.deleted;
    final displayPath = file.newPath ?? file.oldPath!;
    return ImageDiffView(
      repoPath: widget.repoPath,
      displayPath: displayPath,
      beforePath: added ? null : file.oldPath,
      beforeRevision: widget.beforeRevision ?? '${widget.hash}^',
      afterPath: deleted ? null : file.newPath,
      afterRevision: widget.hash,
    );
  }

  static Iterable<String> _rowTexts(List<PatchRow> rows) sync* {
    for (final row in rows) {
      switch (row) {
        case PreambleRow(:final text):
        case FileHeaderRow(:final text):
        case HunkHeaderRow(:final text):
        case CodeRow(:final text):
          yield text;
        case ExpanderRow():
        case CollapseRow():
          break; // a control, not a line — it never sets the width
      }
    }
  }

  Widget _list(Color defaultColor, CodeTheme codeTheme, double? viewportWidth) {
    return SelectionArea(
      child: ListView.builder(
        controller: _vertical,
        padding: const EdgeInsets.symmetric(vertical: 8),
        // Fixed extent in the unwrapped case only — a wrapped line's height is
        // its own business. Every row (expanders included) is one line tall, so
        // the O(1) scroll math holds. [kDiffStrut] keeps glyph height inside
        // the slot so text never clips against the itemExtent.
        itemExtent: widget.wrap ? null : kDiffLineExtent,
        itemCount: _rows.length,
        itemBuilder: (context, index) => _row(
          _rows[index],
          index < _rowRuns.length ? _rowRuns[index] : null,
          defaultColor,
          codeTheme,
          viewportWidth,
        ),
      ),
    );
  }

  Widget _row(
    PatchRow row,
    List<ScopedRun>? runs,
    Color defaultColor,
    CodeTheme codeTheme,
    double? viewportWidth,
  ) => switch (row) {
    ExpanderRow() => _pin(_expander(row), viewportWidth),
    CollapseRow() => _pin(_collapser(row), viewportWidth),
    PreambleRow(:final text) ||
    FileHeaderRow(:final text) ||
    HunkHeaderRow(:final text) ||
    CodeRow(:final text) => _text(text, runs, defaultColor, codeTheme, row),
  };

  /// Gap rows are controls, so they hold still while the diff pans beneath them
  /// (see [DiffPinnedRow]) — panning right to read a long line must not carry
  /// "Show 16 lines" off the screen. In wrapped mode there is no pan, so there
  /// is nothing to pin against.
  Widget _pin(Widget child, double? viewportWidth) => viewportWidth == null
      ? child
      : DiffPinnedRow(
          horizontal: _horizontal,
          viewportWidth: viewportWidth,
          child: child,
        );

  Widget _text(
    String text,
    List<ScopedRun>? runs,
    Color defaultColor,
    CodeTheme codeTheme,
    PatchRow row,
  ) {
    // An expanded line is unchanged code: colour it as context, and tint its
    // background faintly so it reads as "revealed", not "part of the change".
    // Additions/removals get the same soft band as DiffView/HunkDiffView.
    final expanded = row is CodeRow && row.fromExpansion;
    final bg = expanded ? const Color(0x0DFFFFFF) : diffLineBackground(text);
    // Code rows get syntax colouring (add/remove sense kept via the kind base
    // colour); headers/preamble stay as their single flat colour.
    final Widget child = (row is CodeRow && runs != null)
        ? Text.rich(
            diffLineSpan(
              text,
              DiffLineHighlight(diffLineKind(text), runs),
              kDiffMono,
              defaultColor,
              codeTheme,
            ),
            maxLines: widget.wrap ? null : 1,
            softWrap: widget.wrap,
            strutStyle: widget.wrap ? null : kDiffStrut,
          )
        : Text(
            text,
            maxLines: widget.wrap ? null : 1,
            softWrap: widget.wrap,
            strutStyle: widget.wrap ? null : kDiffStrut,
            style: kDiffMono.copyWith(color: diffLineColor(text, defaultColor)),
          );
    return Container(
      color: bg,
      padding: const EdgeInsets.symmetric(horizontal: kDiffHPad),
      alignment: Alignment.centerLeft,
      child: child,
    );
  }

  /// The row that opens a gap: one chevron, pointing **down** — "reveal what's
  /// hidden here". One click takes the whole gap unless it's enormous, in which
  /// case it walks [kExpandStep] lines at a time and says so.
  ///
  /// If the blob could not be read, it says *that* instead, and stops offering a
  /// click that cannot do anything.
  Widget _expander(ExpanderRow row) {
    if (_blobFailed.contains(row.request.fileIndex)) {
      return _gapRow(
        icon: CupertinoIcons.exclamationmark_triangle,
        label: "Can't show more — this file couldn't be read at this commit",
        color: MacosColors.systemGrayColor,
        onTap: null,
      );
    }
    final hidden = row.hiddenLines;
    final label = switch (hidden) {
      null => 'Show more',
      _ when row.expandsAll => 'Show $hidden ${hidden == 1 ? "line" : "lines"}',
      _ => 'Show $kExpandStep of $hidden lines',
    };
    return _gapRow(
      icon: CupertinoIcons.chevron_down,
      label: label,
      onTap: () => _expand(row.request, row.direction, hidden ?? kExpandStep),
    );
  }

  /// The row that shuts it again: the same chevron, flipped to point up. The
  /// direction *is* the affordance — it says which way the lines are about to
  /// move, so expanding and minimizing can never be mistaken for one another.
  Widget _collapser(CollapseRow row) {
    final n = row.revealedLines;
    return _gapRow(
      icon: CupertinoIcons.chevron_up,
      label: 'Hide $n ${n == 1 ? "line" : "lines"}',
      onTap: () => _collapse(row.request),
    );
  }

  /// One gap control. The whole row is the hit target — an 11px chevron is a
  /// miserable thing to aim at, and a click anywhere on the band should do the
  /// obvious thing.
  ///
  /// [SelectionContainer.disabled] is what makes that legible: inside a
  /// [SelectionArea], a [Text] wraps *itself* in a text-cursor [MouseRegion]
  /// deeper than this one, so the pointer stayed an I-beam over the label and
  /// the row read as dead — clickable only on the icon. Disabling selection here
  /// drops that cursor (and keeps "Show 16 lines" out of copied diff text, which
  /// it had no business being in either).
  Widget _gapRow({
    required IconData icon,
    required String label,
    required VoidCallback? onTap,
    Color color = MacosColors.systemBlueColor,
  }) {
    return SelectionContainer.disabled(
      child: Tappable(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          color: onTap == null
              ? MacosColors.systemGrayColor.withValues(alpha: 0.08)
              : const Color(0x14007AFF),
          padding: const EdgeInsets.symmetric(horizontal: kDiffHPad),
          alignment: Alignment.centerLeft,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              MacosIcon(icon, size: 11, color: color),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: kDiffMono.copyWith(color: color, fontSize: 11),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
