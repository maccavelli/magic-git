/// Classification of a file's raw contents (as read by `GitService.readFile`,
/// which decodes stdout as UTF-8 with malformed bytes replaced) into something
/// the viewer knows how to render: displayable text, un-renderable binary, or
/// content too large to show comfortably.
library;

/// What the viewer should do with a file's bytes.
enum FileContentKind {
  /// Decodable text — shown in the source/preview views.
  text,

  /// Non-text (NUL bytes or a high proportion of undecodable bytes). The
  /// viewer shows a placeholder rather than a wall of mojibake — unless the
  /// file is a known image type, which is fetched and rendered via a separate
  /// bytes path.
  binary,

  /// Text, but past the viewer's render ceiling. Shown as a size notice with an
  /// "open externally" affordance instead of a multi-megabyte text widget.
  tooLarge,
}

/// The result of classifying a file's raw decoded contents.
class FileContent {
  final FileContentKind kind;

  /// The decoded text (empty for [FileContentKind.binary]/[tooLarge]).
  final String text;

  /// Length of the raw content in code units — used for the size notice on
  /// [FileContentKind.tooLarge] and for the source view's footer.
  final int charCount;

  /// Whether [text] warrants offloading syntax highlighting to a background
  /// isolate rather than tokenizing it inline. Highlighting is O(n) synchronous
  /// work, so past this size the [CodeView] runs it via `Isolate.run` (the same
  /// pattern `GitService` uses for large parses) to keep the frame free.
  final bool highlightOffMainThread;

  const FileContent._({
    required this.kind,
    this.text = '',
    this.charCount = 0,
    this.highlightOffMainThread = false,
  });

  /// Soft ceiling on characters the viewer will render as text. Beyond this the
  /// content is reported [FileContentKind.tooLarge] and the viewer offers to
  /// open it externally instead.
  ///
  /// This is *not* a layout limit — the source view virtualizes by line
  /// (`ListView.builder` + `SelectionArea`), so only on-screen lines lay out
  /// and render cost is bounded by the viewport, not the file. The ceiling
  /// instead bounds *memory*: holding the raw string plus a per-line index for
  /// a file this size is comfortable, while a data dump many times larger
  /// belongs in a dedicated tool. Kept under the executor's own 50 MiB read
  /// cap, which would surface as a read error before we ever get here.
  static const int maxRenderChars = 16 * 1024 * 1024;

  /// Above this many characters, highlighting is done on a background isolate
  /// instead of inline. Matches the order of magnitude of `GitService`'s own
  /// isolate threshold for large output.
  static const int isolateHighlightChars = 64 * 1024;

  /// How much of the content to scan for the binary heuristic — the same order
  /// of magnitude as git's own NUL-sniffing window.
  static const int _sniffChars = 8000;

  /// Fraction of the sniff window that may be U+FFFD replacement chars before
  /// the content is judged binary. Genuine UTF-8 text has none; a binary blob
  /// decoded with malformed bytes replaced is saturated with them.
  static const double _binaryReplacementRatio = 0.1;

  /// Classifies [raw] — the decoded file contents — into text / binary /
  /// too-large.
  factory FileContent.classify(String raw) {
    final len = raw.length;
    if (len > maxRenderChars) {
      return FileContent._(kind: FileContentKind.tooLarge, charCount: len);
    }
    // Binary heuristic over a bounded prefix: a NUL anywhere (git's own test),
    // or a high proportion of U+FFFD replacement chars (bytes that failed to
    // decode as UTF-8).
    final window = len < _sniffChars ? len : _sniffChars;
    var replacements = 0;
    for (var i = 0; i < window; i++) {
      final c = raw.codeUnitAt(i);
      if (c == 0) {
        return FileContent._(kind: FileContentKind.binary, charCount: len);
      }
      if (c == 0xFFFD) replacements++;
    }
    if (window > 0 && replacements / window > _binaryReplacementRatio) {
      return FileContent._(kind: FileContentKind.binary, charCount: len);
    }
    return FileContent._(
      kind: FileContentKind.text,
      text: raw,
      charCount: len,
      highlightOffMainThread: len > isolateHighlightChars,
    );
  }

  bool get isText => kind == FileContentKind.text;
}
