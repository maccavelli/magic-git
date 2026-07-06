import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';
import '../../core/output/output_log.dart';
import '../common/tool_icon_button.dart';

/// The user-resizable output view docked across the bottom of the repository
/// panel. Renders the [outputLogProvider] buffer (push/pull/sync output for
/// now) in a horizontally-scrolling, monospace, dark log. Its top edge is a
/// drag handle that grows/shrinks the panel. Shown only when the output view is
/// enabled (View → Show Output View).
class OutputView extends ConsumerStatefulWidget {
  /// Height of the surrounding repository panel, used for the default (1/6) and
  /// the resize clamp.
  final double maxHeight;

  const OutputView({super.key, required this.maxHeight});

  @override
  ConsumerState<OutputView> createState() => _OutputViewState();
}

class _OutputViewState extends ConsumerState<OutputView> {
  final ScrollController _scroll = ScrollController();
  // Stick to the tail unless the user has scrolled away.
  bool _stick = true;
  // User-set height; null until first drag (defaults to 1/6 of the window).
  double? _height;

  static const _mono = TextStyle(
    fontFamily: 'Menlo',
    fontFamilyFallback: ['SF Mono', 'Consolas', 'monospace'],
    fontSize: 12,
    height: 1.3,
  );

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final p = _scroll.position;
    _stick = p.pixels >= p.maxScrollExtent - 8;
  }

  double get _floor => 90;
  double get _ceil {
    final c = widget.maxHeight * 0.55;
    return c < _floor ? _floor : c;
  }

  @override
  Widget build(BuildContext context) {
    // Autoscroll to the tail when new lines arrive and the user hasn't scrolled
    // up to read history.
    ref.listen(outputLogProvider.select((s) => s.lines.length), (_, _) {
      if (!_stick) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        // The frame can land after this view is disposed (repo/tab switch,
        // disconnect); bail then rather than touching a dead controller.
        if (mounted && _scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
    });

    final lines = ref.watch(outputLogProvider.select((s) => s.lines));
    final log = ref.read(outputLogProvider.notifier);
    final height = (_height ?? widget.maxHeight / 6)
        .clamp(_floor, _ceil)
        .toDouble();

    return SizedBox(
      height: height,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _handle(context, log),
          Expanded(child: _logList(context, lines)),
        ],
      ),
    );
  }

  Widget _handle(BuildContext context, OutputLogNotifier log) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragUpdate: (d) {
        setState(() {
          final current = _height ?? widget.maxHeight / 6;
          // Dragging up (negative dy) grows the panel.
          _height = (current - d.delta.dy).clamp(_floor, _ceil).toDouble();
        });
      },
      child: MouseRegion(
        cursor: SystemMouseCursors.resizeUpDown,
        child: Container(
          decoration: const BoxDecoration(
            color: Color(0xFF252526),
            border: Border(
              top: BorderSide(color: MacosColors.separatorColor),
              bottom: BorderSide(color: MacosColors.separatorColor),
            ),
          ),
          padding: const EdgeInsets.fromLTRB(12, 2, 6, 2),
          child: Row(
            children: [
              const Icon(
                Icons.drag_handle,
                size: 16,
                color: MacosColors.systemGrayColor,
              ),
              const SizedBox(width: 6),
              Text(
                'Output',
                style: MacosTheme.of(
                  context,
                ).typography.caption1.copyWith(fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              ToolIconButton(
                icon: Icons.clear_all,
                tooltip: 'Clear output',
                size: 15,
                onPressed: log.clear,
              ),
              ToolIconButton(
                icon: Icons.close,
                tooltip: 'Hide output view',
                size: 15,
                onPressed: () => log.setVisible(false),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _logList(BuildContext context, List<OutputLine> lines) {
    if (lines.isEmpty) {
      return Container(
        color: const Color(0xFF1E1E1E),
        alignment: Alignment.center,
        child: Text(
          'No output yet.',
          style: MacosTheme.of(
            context,
          ).typography.caption1.copyWith(color: MacosColors.systemGrayColor),
        ),
      );
    }
    return Container(
      color: const Color(0xFF1E1E1E),
      child: Scrollbar(
        controller: _scroll,
        child: ListView.builder(
          controller: _scroll,
          padding: const EdgeInsets.symmetric(vertical: 6),
          itemCount: lines.length,
          itemBuilder: (context, i) {
            final line = lines[i];
            return SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 1,
                ),
                child: SelectableText(
                  line.text.isEmpty ? ' ' : line.text,
                  style: _mono.copyWith(color: _colorFor(line.kind)),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Color _colorFor(OutputLineKind kind) => switch (kind) {
    OutputLineKind.command => MacosColors.systemBlueColor,
    OutputLineKind.stdout => const Color(0xFFD4D4D4),
    OutputLineKind.stderr => MacosColors.systemYellowColor,
    OutputLineKind.success => MacosColors.systemGreenColor,
    OutputLineKind.error => MacosColors.systemRedColor,
    OutputLineKind.info => MacosColors.systemGrayColor,
  };
}
