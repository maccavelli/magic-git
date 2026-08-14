import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';
import '../../core/git/unified_diff.dart';
import '../../core/providers/app_providers.dart';
import '../common/diff_view.dart';
import '../common/escape_dismissible.dart';
import '../common/split_diff_view.dart';
import '../common/tool_icon_button.dart';
import 'hunk_diff_view.dart';

/// A floating, draggable, resizable diff viewer — the "popped out" form of the
/// Repository panel's inline diff pane, so it can sit alongside the file list
/// instead of splitting the same row with it.
///
/// Carries its own side-by-side / ignore-whitespace toggles, seeded once (in
/// [initState]) from whatever the inline panel was showing at the moment it
/// was popped, then independently controlled from here on — as does its
/// position and size, both clamped to stay within [bounds]. The file it shows
/// ([path]/[staged]/[untracked]) still tracks whichever file is selected in
/// the file list, since popping out relocates *where* the diff is shown, not
/// *which* diff — selecting another file while popped out keeps it popped.
class DiffPopoutWindow extends ConsumerStatefulWidget {
  final String repoPath;
  final String path;
  final bool staged;
  final bool untracked;
  final bool initialSplit;
  final bool initialIgnoreWs;
  final int contextLines;
  final Size bounds;
  final void Function(DiffFile file, DiffHunk hunk, HunkAction action)
  onHunkAction;
  final VoidCallback onClose;

  const DiffPopoutWindow({
    super.key,
    required this.repoPath,
    required this.path,
    required this.staged,
    required this.untracked,
    required this.initialSplit,
    required this.initialIgnoreWs,
    required this.contextLines,
    required this.bounds,
    required this.onHunkAction,
    required this.onClose,
  });

  @override
  ConsumerState<DiffPopoutWindow> createState() => _DiffPopoutWindowState();
}

class _DiffPopoutWindowState extends ConsumerState<DiffPopoutWindow> {
  static const _minWidth = 420.0;
  static const _minHeight = 280.0;

  late bool _split = widget.initialSplit;
  late bool _ignoreWs = widget.initialIgnoreWs;
  late Offset _position;
  late Size _size;

  /// Deregisters this window's Escape-to-close handler.
  VoidCallback? _unregisterEscape;

  @override
  void initState() {
    super.initState();
    _size = Size(
      _fit(widget.bounds.width * 0.6, _minWidth, widget.bounds.width),
      _fit(widget.bounds.height * 0.75, _minHeight, widget.bounds.height),
    );
    _position = Offset(
      (widget.bounds.width - _size.width) / 2,
      (widget.bounds.height - _size.height) / 2,
    );
    // Escape closes the pop-out, same as the file-viewer windows. Routed
    // through the registry (not the focus tree) so it works even while the
    // selectable diff content holds focus, and so a sheet/dialog opened later
    // wins the key first (LIFO).
    _unregisterEscape = EscapeDismissRegistry.register(() {
      widget.onClose();
      return true;
    });
  }

  @override
  void dispose() {
    _unregisterEscape?.call();
    super.dispose();
  }

  /// Clamps [v] into `[lo, hi]`, tolerating a host smaller than the minimum
  /// window size (`hi <= lo`) by returning `hi` rather than letting `num.clamp`
  /// throw on `lower > upper`. The diff pop-out lives in the content area (the
  /// window minus the sidebar), which can be narrower than [_minWidth] even when
  /// the whole window isn't.
  double _fit(double v, double lo, double hi) =>
      hi <= lo ? hi : v.clamp(lo, hi).toDouble();

  void _clampPosition() {
    final maxX = (widget.bounds.width - _size.width).clamp(
      0.0,
      double.infinity,
    );
    final maxY = (widget.bounds.height - _size.height).clamp(
      0.0,
      double.infinity,
    );
    _position = Offset(
      _position.dx.clamp(0.0, maxX),
      _position.dy.clamp(0.0, maxY),
    );
  }

  void _onDrag(DragUpdateDetails details) {
    setState(() {
      _position += details.delta;
      _clampPosition();
    });
  }

  /// Side-by-side needs the room of two columns. Toggling it on grows a
  /// narrow window toward 85% of the host's width (never past it) so both
  /// columns arrive readable — a one-time nudge inside the caller's setState,
  /// not a constraint: the user can still drag it back down to [_minWidth].
  void _growForSplit() {
    final target = widget.bounds.width * 0.85;
    if (_size.width >= target) return;
    _size = Size(_fit(target, _minWidth, widget.bounds.width), _size.height);
    _clampPosition();
  }

  void _onResize(DragUpdateDetails details) {
    setState(() {
      _size = Size(
        _fit(
          _size.width + details.delta.dx,
          _minWidth,
          widget.bounds.width - _position.dx,
        ),
        _fit(
          _size.height + details.delta.dy,
          _minHeight,
          widget.bounds.height - _position.dy,
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    // Keep the pop-out inside the content area if it shrank (window resized,
    // sidebar/file panel widened) — same as FileViewerWindow. Without this the
    // window (and its only resize handle) can be stranded out of reach.
    _size = Size(
      _fit(_size.width, _minWidth, widget.bounds.width),
      _fit(_size.height, _minHeight, widget.bounds.height),
    );
    _clampPosition();
    final diffAsync = widget.untracked
        ? ref.watch(untrackedDiffProvider((widget.repoPath, widget.path)))
        : ref.watch(
            fileDiffProvider((
              widget.repoPath,
              widget.path,
              widget.staged,
              _ignoreWs,
              widget.contextLines,
            )),
          );
    final defaultColor =
        MacosTheme.of(context).typography.body.color ?? MacosColors.textColor;
    final brightness = MacosTheme.brightnessOf(context);
    final background = brightness.resolve(
      CupertinoColors.systemGrey6.color,
      MacosColors.controlBackgroundColor.darkColor,
    );

    return Positioned(
      left: _position.dx,
      top: _position.dy,
      width: _size.width,
      height: _size.height,
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
          child: Stack(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onPanUpdate: _onDrag,
                    child: Container(
                      color: MacosColors.systemGrayColor.withValues(
                        alpha: 0.10,
                      ),
                      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              widget.path,
                              style: MacosTheme.of(context).typography.caption1,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          _toggle(
                            context,
                            icon: CupertinoIcons.square_split_2x1,
                            tooltip: 'Side-by-side',
                            active: _split,
                            onPressed: () => setState(() {
                              _split = !_split;
                              if (_split) _growForSplit();
                            }),
                          ),
                          _toggle(
                            context,
                            icon: CupertinoIcons.paintbrush,
                            tooltip: 'Ignore whitespace',
                            active: _ignoreWs,
                            onPressed: () =>
                                setState(() => _ignoreWs = !_ignoreWs),
                          ),
                          const SizedBox(width: 4),
                          ToolIconButton(
                            icon: CupertinoIcons.xmark,
                            tooltip: 'Close pop-out',
                            size: 15,
                            color: MacosColors.systemGrayColor,
                            onPressed: widget.onClose,
                          ),
                        ],
                      ),
                    ),
                  ),
                  Container(height: 1, color: MacosColors.separatorColor),
                  Expanded(
                    child: diffAsync.when(
                      loading: () => const DiffPending(),
                      error: (err, _) => DiffFailure(err),
                      data: (diff) {
                        final String? banner = _split
                            ? 'Line actions require Unified view because '
                                  'split rows do not map one-to-one to the '
                                  'patch.'
                            : _ignoreWs
                            ? 'Line actions require whitespace-exact '
                                  'diff mode.'
                            : null;
                        final Widget body;
                        if (_split) {
                          body = SplitDiffView(diff: diff);
                        } else if (widget.untracked || _ignoreWs) {
                          body = DiffView(diff: diff);
                        } else {
                          body = HunkDiffView(
                            diff: diff,
                            staged: widget.staged,
                            onAction: widget.onHunkAction,
                          );
                        }
                        if (banner == null) return body;
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _readOnlyBanner(context, banner),
                            Expanded(child: body),
                          ],
                        );
                      },
                    ),
                  ),
                ],
              ),
              Positioned(
                right: 0,
                bottom: 0,
                child: MouseRegion(
                  cursor: SystemMouseCursors.resizeUpLeftDownRight,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onPanUpdate: _onResize,
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: Icon(
                        CupertinoIcons.arrow_up_left_arrow_down_right,
                        size: 11,
                        color: defaultColor.withValues(alpha: 0.5),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _readOnlyBanner(BuildContext context, String message) {
    return Container(
      width: double.infinity,
      color: MacosColors.systemOrangeColor.withValues(alpha: 0.15),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          const MacosIcon(
            CupertinoIcons.exclamationmark_triangle,
            size: 14,
            color: MacosColors.systemOrangeColor,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: MacosTheme.of(context).typography.caption1,
            ),
          ),
        ],
      ),
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
}
