import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';
import '../../core/exec/operation_activity.dart';
import '../../core/output/output_log.dart';
import '../../core/theme/app_theme.dart';
import 'tool_icon_button.dart';

/// Owns a window's one Output view (MADR 0064 F3): [child] fills the space
/// above, and the docked log sits below it while `outputLogProvider.visible`
/// is set.
///
/// The Output toggle is a global command — the keymap, the native View menu
/// and the palette all flip the same flag from any page — so the view must
/// live where every page can see it. `AppShell` wraps its page stack in one,
/// and the detached repository window, which has no `AppShell`, wraps its
/// status view in another.
///
/// It also publishes the reveal action ([revealerOf]), so a context bar
/// offers the Activity Center's "Output" link exactly when an Output view is
/// hosted above it, and never as a link that would show nothing.
class OutputViewHost extends ConsumerWidget {
  final Widget child;

  /// Whether this host docks the view below [child]. False while the page in
  /// [child] places the view itself: Repository docks it in its centre column,
  /// beside the full-height File view (MADR Amendment 0064.1). The reveal
  /// action is published either way.
  final bool dock;

  const OutputViewHost({super.key, required this.child, this.dock = true});

  /// Shows the Output view and scrolls it to [OperationId]'s first line, or
  /// null when no [OutputViewHost] is above [context].
  static ValueChanged<OperationId>? revealerOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<_OutputViewHostScope>()
      ?.reveal;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final visible = ref.watch(outputLogProvider.select((s) => s.visible));
    return _OutputViewHostScope(
      reveal: (id) {
        ref.read(outputLogProvider.notifier).setVisible(true);
        ref.read(outputRevealProvider.notifier).request(id);
      },
      child: LayoutBuilder(
        builder: (context, constraints) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Index 0 is always the child, so toggling the log never
            // remounts the pages above it.
            Expanded(child: child),
            if (dock && visible) OutputView(maxHeight: constraints.maxHeight),
          ],
        ),
      ),
    );
  }
}

/// The Output view's user-dragged height, null until the first drag (the view
/// then defaults to 1/6 of its dock). Held here rather than in the view's
/// State because the view docks in two places — the shell, and Repository's
/// centre column — and one drag must hold in both (MADR Amendment 0064.1).
final outputViewHeightProvider = NotifierProvider<OutputViewHeight, double?>(
  OutputViewHeight.new,
);

class OutputViewHeight extends Notifier<double?> {
  @override
  double? build() => null;

  void set(double height) => state = height;
}

class _OutputViewHostScope extends InheritedWidget {
  final ValueChanged<OperationId> reveal;

  const _OutputViewHostScope({required this.reveal, required super.child});

  // The closure only ever reads the same two notifiers, so a new instance
  // on rebuild is not a change dependants need to hear about.
  @override
  bool updateShouldNotify(_OutputViewHostScope oldWidget) => false;
}

/// The user-resizable output view docked across the bottom of a window, below
/// every page (see [OutputViewHost]). Renders the [outputLogProvider] buffer in
/// a horizontally-scrolling, monospace, dark log. Its top edge is a drag handle
/// that grows/shrinks the panel. Shown only when the output view is enabled
/// (View → Show Output View).
class OutputView extends ConsumerStatefulWidget {
  /// Height of the area the view is docked in, used for the default (1/6) and
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
    ref.listen(outputRevealProvider, (_, id) {
      if (id == null) return;
      final index = ref
          .read(outputLogProvider.notifier)
          .firstIndexForOperation(id);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (index != null && _scroll.hasClients) {
          const extent = 12 * 1.3 + 2;
          _stick = false;
          _scroll.jumpTo(
            (index * extent).clamp(0, _scroll.position.maxScrollExtent),
          );
        }
        ref.read(outputRevealProvider.notifier).consume(id);
      });
    });
    // Autoscroll to the tail when new lines arrive and the user hasn't scrolled
    // up to read history. Watches the revision, not the line count: once the
    // scrollback caps out, every append also drops a line, so the count stops
    // changing and this listener would never fire again.
    ref.listen(outputLogProvider.select((s) => s.revision), (_, _) {
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
    final height = (ref.watch(outputViewHeightProvider) ?? widget.maxHeight / 6)
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
        final heights = ref.read(outputViewHeightProvider.notifier);
        final current =
            ref.read(outputViewHeightProvider) ?? widget.maxHeight / 6;
        // Dragging up (negative dy) grows the panel.
        heights.set((current - d.delta.dy).clamp(_floor, _ceil).toDouble());
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
        color: AppTheme.terminalBackground,
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
      color: AppTheme.terminalBackground,
      // SelectionArea + plain Text so a multi-line command transcript can be
      // drag-copied — per-line SelectableText couldn't span lines.
      child: Scrollbar(
        controller: _scroll,
        child: SelectionArea(
          child: ListView.builder(
            controller: _scroll,
            padding: const EdgeInsets.symmetric(vertical: 6),
            // Every row is one non-wrapping mono line (fontSize 12 × height
            // 1.3) plus 1px vertical padding each side — pinning the extent
            // makes stick-to-tail jumps O(1) on a long scrollback.
            itemExtent: 12 * 1.3 + 2,
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
                  child: Text(
                    line.text.isEmpty ? ' ' : line.text,
                    style: _mono.copyWith(color: _colorFor(line.kind)),
                  ),
                ),
              );
            },
          ),
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
