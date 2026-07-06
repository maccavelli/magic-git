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
  final VoidCallback onClose;
  final VoidCallback onFocus;

  const FileViewerWindow({
    super.key,
    required this.id,
    required this.repoPath,
    required this.path,
    required this.bounds,
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
            last.width.clamp(_minWidth, widget.bounds.width),
            last.height.clamp(_minHeight, widget.bounds.height),
          )
        : Size(
            (widget.bounds.width * 0.62).clamp(_minWidth, widget.bounds.width),
            (widget.bounds.height * 0.78).clamp(
              _minHeight,
              widget.bounds.height,
            ),
          );
    _position = Offset(
      (widget.bounds.width - _size.width) / 2,
      (widget.bounds.height - _size.height) / 2,
    );
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
        (_size.width + d.delta.dx).clamp(
          _minWidth,
          widget.bounds.width - _position.dx,
        ),
        (_size.height + d.delta.dy).clamp(
          _minHeight,
          widget.bounds.height - _position.dy,
        ),
      );
    });
  }

  void _clamp() {
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
    final size = _maximized
        ? Size(
            widget.bounds.width.clamp(_minWidth, double.infinity),
            widget.bounds.height.clamp(_minHeight, double.infinity),
          )
        : _size;

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
      child: Focus(
        focusNode: _focus,
        autofocus: true,
        child: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.escape): widget.onClose,
          },
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
          if (_mode == _ViewerMode.code)
            _toggle(
              context,
              icon: CupertinoIcons.text_alignleft,
              tooltip: _wrap ? 'Disable word wrap' : 'Word wrap',
              active: _wrap,
              onPressed: () => setState(() => _wrap = !_wrap),
            ),
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
      error: (err, _) => _notice(
        context,
        icon: CupertinoIcons.exclamationmark_triangle,
        title: 'Could not open file',
        detail: '$err',
        color: MacosColors.systemRedColor,
      ),
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
      error: (err, _) => _notice(
        context,
        icon: CupertinoIcons.exclamationmark_triangle,
        title: 'Could not open image',
        detail: '$err',
        color: MacosColors.systemRedColor,
      ),
      data: (bytes) => ImagePreview(bytes: bytes),
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
