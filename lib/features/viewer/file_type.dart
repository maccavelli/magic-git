/// File-type classification for the built-in file viewer, derived purely from
/// a file's name/extension (no content sniffing). Drives two things: which
/// syntax-highlighting grammar the source view uses, and whether the file
/// offers a rendered *Preview* mode (Markdown/HTML/image/SVG).
library;

/// How a file can be *rendered* in the viewer's Preview mode. Every file is
/// always viewable as source; this only says whether a richer rendered view is
/// additionally available.
enum PreviewKind {
  /// No rich preview — source (code) view only.
  none,

  /// Rendered Markdown (`flutter_markdown_plus`).
  markdown,

  /// Rendered HTML (`flutter_html`).
  html,

  /// A raster image (png/jpg/gif/webp/…), rendered from its bytes.
  image,

  /// A scalable vector image (svg), rendered as vector art. Its source is also
  /// XML-highlightable, so the code view still works.
  svg,
}

/// The viewer's understanding of a file, derived from its path alone.
class ViewerFileType {
  /// highlight.js language id for the source view, or null when the file has
  /// no known grammar (shown as un-highlighted plain text). Note HTML/SVG map
  /// to `xml`, which highlight.js uses for markup.
  final String? languageId;

  /// Whether/how the file supports a rendered Preview mode.
  final PreviewKind preview;

  const ViewerFileType({this.languageId, this.preview = PreviewKind.none});

  /// Plain, un-highlighted text with no preview — the fallback for unknown
  /// types.
  static const plain = ViewerFileType();

  /// Whether a rendered preview is available at all.
  bool get hasPreview => preview != PreviewKind.none;

  /// Whether the file is fundamentally an image (raster or vector) — content
  /// the viewer renders rather than shows as text. Used to route binary
  /// content to an image preview instead of the "binary file" placeholder.
  bool get isImage => preview == PreviewKind.image || preview == PreviewKind.svg;
}

/// Full-basename matches (lower-cased), for files whose *name* — not extension
/// — identifies them. Checked before the extension table.
const Map<String, ViewerFileType> _byFilename = {
  'dockerfile': ViewerFileType(languageId: 'dockerfile'),
  'containerfile': ViewerFileType(languageId: 'dockerfile'),
  'makefile': ViewerFileType(languageId: 'makefile'),
  'gnumakefile': ViewerFileType(languageId: 'makefile'),
  'cmakelists.txt': ViewerFileType(languageId: 'cmake'),
  'rakefile': ViewerFileType(languageId: 'ruby'),
  'gemfile': ViewerFileType(languageId: 'ruby'),
  'podfile': ViewerFileType(languageId: 'ruby'),
  'brewfile': ViewerFileType(languageId: 'ruby'),
  'vagrantfile': ViewerFileType(languageId: 'ruby'),
  // Dotfiles that are essentially shell/config but have no extension.
  '.gitignore': ViewerFileType(),
  '.gitattributes': ViewerFileType(),
  '.dockerignore': ViewerFileType(),
  '.npmignore': ViewerFileType(),
  '.editorconfig': ViewerFileType(languageId: 'ini'),
  '.env': ViewerFileType(languageId: 'bash'),
  '.bashrc': ViewerFileType(languageId: 'bash'),
  '.zshrc': ViewerFileType(languageId: 'bash'),
  '.profile': ViewerFileType(languageId: 'bash'),
};

/// Extension (lower-cased, no dot) → type. highlight.js language ids; markup
/// languages (html/svg/xml/vue) share the `xml` grammar.
const Map<String, ViewerFileType> _byExtension = {
  // ---- Markup / preview-capable ----
  'md': ViewerFileType(languageId: 'markdown', preview: PreviewKind.markdown),
  'markdown': ViewerFileType(
    languageId: 'markdown',
    preview: PreviewKind.markdown,
  ),
  'mdown': ViewerFileType(
    languageId: 'markdown',
    preview: PreviewKind.markdown,
  ),
  'mkd': ViewerFileType(languageId: 'markdown', preview: PreviewKind.markdown),
  'html': ViewerFileType(languageId: 'xml', preview: PreviewKind.html),
  'htm': ViewerFileType(languageId: 'xml', preview: PreviewKind.html),
  'xhtml': ViewerFileType(languageId: 'xml', preview: PreviewKind.html),
  'svg': ViewerFileType(languageId: 'xml', preview: PreviewKind.svg),
  // ---- Images (rendered from bytes; no meaningful source) ----
  'png': ViewerFileType(preview: PreviewKind.image),
  'jpg': ViewerFileType(preview: PreviewKind.image),
  'jpeg': ViewerFileType(preview: PreviewKind.image),
  'gif': ViewerFileType(preview: PreviewKind.image),
  'webp': ViewerFileType(preview: PreviewKind.image),
  'bmp': ViewerFileType(preview: PreviewKind.image),
  'ico': ViewerFileType(preview: PreviewKind.image),
  'tif': ViewerFileType(preview: PreviewKind.image),
  'tiff': ViewerFileType(preview: PreviewKind.image),
  // ---- Data / config ----
  'yaml': ViewerFileType(languageId: 'yaml'),
  'yml': ViewerFileType(languageId: 'yaml'),
  'json': ViewerFileType(languageId: 'json'),
  'jsonc': ViewerFileType(languageId: 'json'),
  'xml': ViewerFileType(languageId: 'xml'),
  'plist': ViewerFileType(languageId: 'xml'),
  'toml': ViewerFileType(languageId: 'ini'),
  'ini': ViewerFileType(languageId: 'ini'),
  'cfg': ViewerFileType(languageId: 'ini'),
  'conf': ViewerFileType(languageId: 'ini'),
  'properties': ViewerFileType(languageId: 'properties'),
  'env': ViewerFileType(languageId: 'bash'),
  // ---- Web ----
  'css': ViewerFileType(languageId: 'css'),
  'scss': ViewerFileType(languageId: 'scss'),
  'sass': ViewerFileType(languageId: 'scss'),
  'less': ViewerFileType(languageId: 'less'),
  'js': ViewerFileType(languageId: 'javascript'),
  'mjs': ViewerFileType(languageId: 'javascript'),
  'cjs': ViewerFileType(languageId: 'javascript'),
  'jsx': ViewerFileType(languageId: 'javascript'),
  'ts': ViewerFileType(languageId: 'typescript'),
  'tsx': ViewerFileType(languageId: 'typescript'),
  'vue': ViewerFileType(languageId: 'xml'),
  'graphql': ViewerFileType(languageId: 'graphql'),
  'gql': ViewerFileType(languageId: 'graphql'),
  // ---- Languages ----
  'dart': ViewerFileType(languageId: 'dart'),
  'py': ViewerFileType(languageId: 'python'),
  'pyi': ViewerFileType(languageId: 'python'),
  'rb': ViewerFileType(languageId: 'ruby'),
  'go': ViewerFileType(languageId: 'go'),
  'rs': ViewerFileType(languageId: 'rust'),
  'java': ViewerFileType(languageId: 'java'),
  'kt': ViewerFileType(languageId: 'kotlin'),
  'kts': ViewerFileType(languageId: 'kotlin'),
  'swift': ViewerFileType(languageId: 'swift'),
  'c': ViewerFileType(languageId: 'c'),
  'h': ViewerFileType(languageId: 'c'),
  'cpp': ViewerFileType(languageId: 'cpp'),
  'cc': ViewerFileType(languageId: 'cpp'),
  'cxx': ViewerFileType(languageId: 'cpp'),
  'hpp': ViewerFileType(languageId: 'cpp'),
  'hh': ViewerFileType(languageId: 'cpp'),
  'm': ViewerFileType(languageId: 'objectivec'),
  'mm': ViewerFileType(languageId: 'objectivec'),
  'cs': ViewerFileType(languageId: 'csharp'),
  'php': ViewerFileType(languageId: 'php'),
  'sh': ViewerFileType(languageId: 'bash'),
  'bash': ViewerFileType(languageId: 'bash'),
  'zsh': ViewerFileType(languageId: 'bash'),
  'fish': ViewerFileType(languageId: 'bash'),
  'sql': ViewerFileType(languageId: 'sql'),
  'lua': ViewerFileType(languageId: 'lua'),
  'r': ViewerFileType(languageId: 'r'),
  'pl': ViewerFileType(languageId: 'perl'),
  'pm': ViewerFileType(languageId: 'perl'),
  'scala': ViewerFileType(languageId: 'scala'),
  'groovy': ViewerFileType(languageId: 'groovy'),
  'gradle': ViewerFileType(languageId: 'groovy'),
  'proto': ViewerFileType(languageId: 'protobuf'),
  'cmake': ViewerFileType(languageId: 'cmake'),
  'dockerfile': ViewerFileType(languageId: 'dockerfile'),
  'diff': ViewerFileType(languageId: 'diff'),
  'patch': ViewerFileType(languageId: 'diff'),
  // ---- Plain text (known, but nothing to highlight) ----
  'txt': ViewerFileType(),
  'text': ViewerFileType(),
  'log': ViewerFileType(),
  'csv': ViewerFileType(),
  'tsv': ViewerFileType(),
};

/// Classifies a file by its [path] (repo-relative, `/`-separated). Matches on
/// the basename's full name first (for extension-less files like `Dockerfile`),
/// then its extension, case-insensitively. Unknown files fall back to
/// [ViewerFileType.plain].
ViewerFileType viewerFileTypeFor(String path) {
  final slash = path.lastIndexOf('/');
  final name = (slash < 0 ? path : path.substring(slash + 1)).toLowerCase();

  final byName = _byFilename[name];
  if (byName != null) return byName;

  // Extension = text after the *last* dot, but only when that dot isn't the
  // leading one — so `.gitignore` (handled above) or a bare `.env` has no
  // extension, while `archive.tar.gz` → `gz`.
  final dot = name.lastIndexOf('.');
  if (dot <= 0) return ViewerFileType.plain;
  final ext = name.substring(dot + 1);
  return _byExtension[ext] ?? ViewerFileType.plain;
}
