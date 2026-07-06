import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';
import '../../core/git/unified_diff.dart';
import '../../core/providers/app_providers.dart';
import '../common/diff_view.dart';
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

  @override
  void initState() {
    super.initState();
    _size = Size(
      (widget.bounds.width * 0.6).clamp(_minWidth, widget.bounds.width),
      (widget.bounds.height * 0.75).clamp(_minHeight, widget.bounds.height),
    );
    _position = Offset(
      (widget.bounds.width - _size.width) / 2,
      (widget.bounds.height - _size.height) / 2,
    );
  }

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

  void _onResize(DragUpdateDetails details) {
    setState(() {
      _size = Size(
        (_size.width + details.delta.dx).clamp(
          _minWidth,
          widget.bounds.width - _position.dx,
        ),
        (_size.height + details.delta.dy).clamp(
          _minHeight,
          widget.bounds.height - _position.dy,
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
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
                            onPressed: () => setState(() => _split = !_split),
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
                      loading: () => const Center(child: ProgressCircle()),
                      error: (err, _) => Center(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text(
                            '$err',
                            style: MacosTheme.of(context).typography.body
                                .copyWith(color: MacosColors.systemRedColor),
                          ),
                        ),
                      ),
                      data: (diff) {
                        if (_split) return SplitDiffView(diff: diff);
                        if (widget.untracked || _ignoreWs) {
                          return DiffView(diff: diff);
                        }
                        return HunkDiffView(
                          diff: diff,
                          staged: widget.staged,
                          onAction: widget.onHunkAction,
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
