import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';
import '../../core/providers/app_providers.dart';
import '../../core/utils/file_actions.dart';
import '../common/tool_icon_button.dart';
import 'code_view.dart';
import 'file_content.dart';
import 'file_type.dart';
import 'image_preview.dart';
import 'preview_view.dart';
import 'viewer_providers.dart';

enum _ViewerMode { code, preview }

/// A floating, draggable, resizable, maximizable file-viewer window — the
/// built-in "open this file" surface, shown over the whole app by
/// [ViewerHost]. Reads the file's contents via [fileContentProvider] (a plain
/// `cat`, identical local and over SSH) and renders them as syntax-highlighted
/// source ([CodeView]) or, for Markdown/HTML, a rendered preview
/// ([MarkdownPreview]/[HtmlPreview]) toggled from the title bar.
///
/// Position, size and maximize state are local to the window and clamped to
/// [bounds]; the file it shows is fixed for the window's life (reopening the
/// same file focuses this window rather than making a second one — see
/// [OpenFileViewers.open]).
class FileViewerWindow extends ConsumerStatefulWidget {
  final int id;
  final String repoPath;
  final String path;
  final Size bounds;

  /// Whether this is the front-most (top of z-order) window. The front window
  /// holds keyboard focus so shortcuts (Escape) target it.
  final bool isFront;
  final VoidCallback onClose;
  final VoidCallback onFocus;

  const FileViewerWindow({
    super.key,
    required this.id,
    required this.repoPath,
    required this.path,
    required this.bounds,
    required this.isFront,
    required this.onClose,
    required this.onFocus,
  });

  @override
  ConsumerState<FileViewerWindow> createState() => _FileViewerWindowState();
}

class _FileViewerWindowState extends ConsumerState<FileViewerWindow> {
  static const _minWidth = 420.0;
  static const _minHeight = 260.0;

  final _focus = FocusNode();
  late Offset _position;
  late Size _size;
  bool _maximized = false;
  bool _wrap = false;
  late _ViewerMode _mode;

  ViewerFileType get _type => viewerFileTypeFor(widget.path);

  // Text files that also have a rendered form (Markdown/HTML/SVG) get the
  // Code/Preview toggle. Raster images are handled separately (preview-only,
  // no source), so they're not counted here.
  bool get _previewAvailable => switch (_type.preview) {
    PreviewKind.markdown || PreviewKind.html || PreviewKind.svg => true,
    _ => false,
  };

  @override
  void initState() {
    super.initState();
    _mode = _previewAvailable ? _ViewerMode.preview : _ViewerMode.code;
    // Reopen at the last window's size (this session), else a default fraction
    // of the app window — both clamped to fit.
    final last = ref.read(viewerLastSizeProvider);
    _size = last != null
        ? Size(
            _fit(last.width, _minWidth, widget.bounds.width),
            _fit(last.height, _minHeight, widget.bounds.height),
          )
        : Size(
            _fit(widget.bounds.width * 0.62, _minWidth, widget.bounds.width),
            _fit(widget.bounds.height * 0.78, _minHeight, widget.bounds.height),
          );
    _position = Offset(
      (widget.bounds.width - _size.width) / 2,
      (widget.bounds.height - _size.height) / 2,
    );
  }

  @override
  void didUpdateWidget(FileViewerWindow old) {
    super.didUpdateWidget(old);
    // Promoted to front-most (the previous front closed, or another window was
    // raised over this one and then dismissed): take keyboard focus so Escape
    // and other shortcuts target this window rather than being swallowed.
    // Deferred to after the frame so the focus node is fully attached (the
    // promotion happens during the sibling's removal rebuild).
    if (!old.isFront && widget.isFront) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focus.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _onDrag(DragUpdateDetails d) {
    setState(() {
      _position += d.delta;
      _clamp();
    });
  }

  void _onResize(DragUpdateDetails d) {
    setState(() {
      _size = Size(
        _fit(_size.width + d.delta.dx, _minWidth, widget.bounds.width - _position.dx),
        _fit(
          _size.height + d.delta.dy,
          _minHeight,
          widget.bounds.height - _position.dy,
        ),
      );
    });
  }

  /// Clamps [v] into `[lo, hi]`, but tolerates a host smaller than the minimum
  /// window size: when `hi <= lo` (the app window is narrower/shorter than
  /// `_minWidth`/`_minHeight`) it returns `hi`, filling the available space,
  /// rather than letting `num.clamp` throw on `lower > upper`.
  double _fit(double v, double lo, double hi) =>
      hi <= lo ? hi : v.clamp(lo, hi).toDouble();

  void _clamp() {
    // Shrink an over-large window down to the host first (e.g. the app window
    // shrank while this one was open), so it can't be stranded off-screen with
    // its resize handle out of reach.
    _size = Size(
      _fit(_size.width, _minWidth, widget.bounds.width),
      _fit(_size.height, _minHeight, widget.bounds.height),
    );
    final maxX = (widget.bounds.width - _size.width).clamp(0.0, double.infinity);
    final maxY = (widget.bounds.height - _size.height).clamp(
      0.0,
      double.infinity,
    );
    _position = Offset(
      _position.dx.clamp(0.0, maxX),
      _position.dy.clamp(0.0, maxY),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Keep a floating window inside the app if the whole window shrank.
    if (!_maximized) _clamp();
    final pos = _maximized ? Offset.zero : _position;
    // Maximized fills the host exactly — no min clamp, which would otherwise
    // overflow the viewport when the app window is smaller than the minimum.
    final size = _maximized ? widget.bounds : _size;

    final brightness = MacosTheme.brightnessOf(context);
    final background = brightness.resolve(
      CupertinoColors.systemGrey6.color,
      MacosColors.controlBackgroundColor.darkColor,
    );

    return Positioned(
      left: pos.dx,
      top: pos.dy,
      width: size.width,
      height: size.height,
      // CallbackShortcuts must be the *ancestor* of the focus node: a key event
      // dispatches to the focused node and bubbles up its ancestors, so the
      // Escape handler only sees it from above [_focus], not below.
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): widget.onClose,
        },
        child: Focus(
          focusNode: _focus,
          autofocus: true,
          child: Listener(
            // Any interaction raises this window to the front.
            onPointerDown: (_) {
              _focus.requestFocus();
              widget.onFocus();
            },
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: background,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: MacosColors.separatorColor),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x40000000),
                    blurRadius: 24,
                    offset: Offset(0, 10),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _titleBar(context),
                    Container(height: 1, color: MacosColors.separatorColor),
                    Expanded(
                      child: Stack(
                        children: [
                          Positioned.fill(child: _body(context)),
                          if (!_maximized)
                            Positioned(
                              right: 0,
                              bottom: 0,
                              child: _resizeHandle(context),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _titleBar(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    final slash = widget.path.lastIndexOf('/');
    final name = slash < 0 ? widget.path : widget.path.substring(slash + 1);
    final dir = slash < 0 ? '' : widget.path.substring(0, slash);

    return Container(
      color: MacosColors.systemGrayColor.withValues(alpha: 0.10),
      padding: const EdgeInsets.fromLTRB(12, 7, 8, 7),
      child: Row(
        children: [
          // Only the icon + filename is the drag/double-tap surface, so the
          // action buttons to its right aren't competing with the drag and
          // double-tap recognizers in the gesture arena (which would otherwise
          // swallow their taps).
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanUpdate: _maximized ? null : _onDrag,
              // Double-click the title bar to toggle maximize, like a native
              // window.
              onDoubleTap: () => setState(() => _maximized = !_maximized),
              child: Row(
                children: [
                  const MacosIcon(CupertinoIcons.doc_text, size: 15),
                  const SizedBox(width: 6),
                  Expanded(
                    child: MacosTooltip(
                      message: widget.path,
                      child: RichText(
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        text: TextSpan(
                          style: typography.caption1,
                          children: [
                            TextSpan(
                              text: name,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            if (dir.isNotEmpty)
                              TextSpan(
                                text: '  $dir',
                                style: const TextStyle(
                                  color: MacosColors.systemGrayColor,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          if (_previewAvailable) ...[
            _modeToggle(context),
            const SizedBox(width: 8),
          ],
          if (_mode == _ViewerMode.code) ...[
            // A reliable "copy the whole file" — the source view virtualizes by
            // line, so a drag-selection + copy only captures the lines that were
            // realized on screen; this copies the full text regardless of scroll.
            _toggle(
              context,
              icon: CupertinoIcons.doc_on_clipboard,
              tooltip: 'Copy file contents',
              active: false,
              onPressed: _copyContents,
            ),
            _toggle(
              context,
              icon: CupertinoIcons.text_alignleft,
              tooltip: _wrap ? 'Disable word wrap' : 'Word wrap',
              active: _wrap,
              onPressed: () => setState(() => _wrap = !_wrap),
            ),
          ],
          _toggle(
            context,
            icon: _maximized
                ? CupertinoIcons.arrow_down_right_arrow_up_left
                : CupertinoIcons.arrow_up_left_arrow_down_right,
            tooltip: _maximized ? 'Restore' : 'Maximize',
            active: false,
            onPressed: () => setState(() => _maximized = !_maximized),
          ),
          const SizedBox(width: 2),
          ToolIconButton(
            icon: CupertinoIcons.xmark,
            tooltip: 'Close',
            size: 15,
            color: MacosColors.systemGrayColor,
            onPressed: widget.onClose,
          ),
        ],
      ),
    );
  }

  // A two-segment Code / Preview switch.
  Widget _modeToggle(BuildContext context) {
    return Row(
      children: [
        _toggle(
          context,
          icon: CupertinoIcons.chevron_left_slash_chevron_right,
          tooltip: 'Source',
          active: _mode == _ViewerMode.code,
          onPressed: () => setState(() => _mode = _ViewerMode.code),
        ),
        _toggle(
          context,
          icon: CupertinoIcons.eye,
          tooltip: 'Preview',
          active: _mode == _ViewerMode.preview,
          onPressed: () => setState(() => _mode = _ViewerMode.preview),
        ),
      ],
    );
  }

  Widget _toggle(
    BuildContext context, {
    required IconData icon,
    required String tooltip,
    required bool active,
    required VoidCallback onPressed,
  }) => ToolIconButton(
    icon: icon,
    tooltip: tooltip,
    size: 15,
    color: active
        ? MacosTheme.of(context).iconTheme.color
        : MacosColors.systemGrayColor,
    onPressed: onPressed,
  );

  Widget _resizeHandle(BuildContext context) {
    final defaultColor =
        MacosTheme.of(context).typography.body.color ?? MacosColors.textColor;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeUpLeftDownRight,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanUpdate: _onResize,
        // Remember this size so the next window opens matching it.
        onPanEnd: (_) => ref.read(viewerLastSizeProvider.notifier).set(_size),
        child: SizedBox(
          width: 18,
          height: 18,
          child: Icon(
            CupertinoIcons.arrow_up_left_arrow_down_right,
            size: 11,
            color: defaultColor.withValues(alpha: 0.5),
          ),
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    // A raster image has no source form — read and render its bytes directly,
    // bypassing the text-classification path entirely.
    if (_type.preview == PreviewKind.image) return _imageBody(context);

    final async = ref.watch(
      fileContentProvider((widget.repoPath, widget.path)),
    );
    return async.when(
      loading: () => const Center(child: ProgressCircle()),
      error: (err, _) => _readErrorNotice(context, err, 'Could not open file'),
      data: (content) => switch (content.kind) {
        FileContentKind.tooLarge => _notice(
          context,
          icon: CupertinoIcons.doc_text_search,
          title: 'File too large to display',
          detail: '${_mib(content.charCount)} MB — open it in an external '
              'editor to view the whole thing.',
        ),
        FileContentKind.binary => _notice(
          context,
          icon: CupertinoIcons.doc_plaintext,
          title: 'Binary file',
          detail: "This file isn't text, so there's nothing to display here.",
        ),
        FileContentKind.text =>
          _mode == _ViewerMode.preview && _previewAvailable
              ? _preview(content)
              : CodeView(
                  content: content,
                  languageId: _type.languageId,
                  wrap: _wrap,
                ),
      },
    );
  }

  Widget _imageBody(BuildContext context) {
    final async = ref.watch(
      fileBytesProvider((widget.repoPath, widget.path)),
    );
    return async.when(
      loading: () => const Center(child: ProgressCircle()),
      error: (err, _) => _readErrorNotice(context, err, 'Could not open image'),
      data: (bytes) => ImagePreview(bytes: bytes),
    );
  }

  /// Renders a read failure: a `tooLarge` error gets the size notice + the
  /// (local-only) open-externally button, everything else a plain message —
  /// both drawn from the clean [ViewerReadException] text, never a raw
  /// transport error string.
  Widget _readErrorNotice(BuildContext context, Object err, String title) {
    if (err is ViewerReadException &&
        err.kind == ViewerReadError.tooLarge) {
      return _notice(
        context,
        icon: CupertinoIcons.doc_text_search,
        title: 'File too large to display',
        detail: '$err',
      );
    }
    return _notice(
      context,
      icon: CupertinoIcons.exclamationmark_triangle,
      title: title,
      detail: '$err',
      color: MacosColors.systemRedColor,
    );
  }

  Widget _preview(FileContent content) => switch (_type.preview) {
    PreviewKind.markdown => MarkdownPreview(source: content.text),
    PreviewKind.html => HtmlPreview(source: content.text),
    PreviewKind.svg => SvgPreview(source: content.text),
    // _previewAvailable gates this branch to md/html/svg only.
    _ => CodeView(
      content: content,
      languageId: _type.languageId,
      wrap: _wrap,
    ),
  };

  String _mib(int chars) => (chars / (1024 * 1024)).toStringAsFixed(1);

  /// Copies the whole file's text to the clipboard (no-op for a binary/too-large
  /// file or one still loading). Reads the already-cached provider value rather
  /// than re-fetching.
  void _copyContents() {
    final content = ref
        .read(fileContentProvider((widget.repoPath, widget.path)))
        .value;
    if (content != null && content.kind == FileContentKind.text) {
      Clipboard.setData(ClipboardData(text: content.text));
    }
  }

  /// A "reveal/open on this machine" button, shown on the fallback notices —
  /// but only for a local repo, since an SSH repo's files live on the remote
  /// host, not here (same gating as the status list's Reveal/Open actions).
  Widget? _openExternallyButton() {
    final isLocal = ref.watch(connectionProvider.select((c) => c.isLocal));
    if (!isLocal) return null;
    return PushButton(
      controlSize: ControlSize.large,
      secondary: true,
      onPressed: () => openFiles(['${widget.repoPath}/${widget.path}']),
      child: const Text('Open in Default App'),
    );
  }

  Widget _notice(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String detail,
    Color? color,
  }) {
    final typography = MacosTheme.of(context).typography;
    final openButton = _openExternallyButton();
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            MacosIcon(
              icon,
              size: 40,
              color: color ?? MacosColors.systemGrayColor,
            ),
            const SizedBox(height: 12),
            Text(title, style: typography.title3),
            const SizedBox(height: 6),
            Text(
              detail,
              textAlign: TextAlign.center,
              style: typography.body.copyWith(
                color: MacosColors.systemGrayColor,
              ),
            ),
            if (openButton != null) ...[
              const SizedBox(height: 16),
              openButton,
            ],
          ],
        ),
      ),
    );
  }
}
