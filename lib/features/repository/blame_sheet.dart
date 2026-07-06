import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show Scrollbar, SelectionArea;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';
import '../../core/git/git_service.dart';
import '../../core/providers/app_providers.dart';
import '../common/diff_view.dart' show kDiffMono;
import '../common/tool_icon_button.dart';

/// Line-by-line authorship for a file (`git blame`), shown in a modal sheet: a
/// left gutter of the commit that last changed each line (short sha · author ·
/// date) beside the source text.
class BlameSheet extends ConsumerWidget {
  final String repoPath;
  final String path;
  const BlameSheet({super.key, required this.repoPath, required this.path});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final typography = MacosTheme.of(context).typography;
    final async = ref.watch(blameProvider((repoPath, path)));
    final screen = MediaQuery.of(context).size;
    return MacosSheet(
      child: SizedBox(
        width: (screen.width * 0.7).clamp(560.0, 980.0).toDouble(),
        height: (screen.height * 0.8).clamp(420.0, 900.0).toDouble(),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 10, 8),
              child: Row(
                children: [
                  const MacosIcon(CupertinoIcons.person_crop_rectangle, size: 16),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Blame · $path',
                      style: typography.title3,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  ToolIconButton(
                    icon: CupertinoIcons.xmark,
                    tooltip: 'Close',
                    size: 16,
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            Container(height: 1, color: MacosColors.separatorColor),
            Expanded(
              child: async.when(
                loading: () => const Center(child: ProgressCircle()),
                error: (err, _) => Center(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      '$err',
                      style: typography.body.copyWith(
                        color: MacosColors.systemRedColor,
                      ),
                    ),
                  ),
                ),
                data: (lines) => _BlameBody(lines: lines),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BlameBody extends StatelessWidget {
  final List<BlameLine> lines;
  const _BlameBody({required this.lines});

  @override
  Widget build(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    final gutter = typography.caption1.copyWith(
      color: MacosColors.systemGrayColor,
      fontFeatures: const [],
    );
    // Group consecutive lines from the same commit so the gutter only prints the
    // commit info at the start of each run (like Fork/Tower). Precomputed once
    // here rather than tracked via a closure-captured "previous hash" mutated
    // inside itemBuilder — a lazy ListView.builder doesn't guarantee its
    // itemBuilder runs in strict forward index order (backward scroll /
    // relayout can revisit indices out of sequence), which would corrupt a
    // visit-order-dependent running value. This is a pure function of [lines]
    // and its own index instead.
    final showMeta = List<bool>.generate(
      lines.length,
      (i) => i == 0 || lines[i].hash != lines[i - 1].hash,
    );
    return Scrollbar(
      child: SelectionArea(
        child: ListView.builder(
          padding: const EdgeInsets.symmetric(vertical: 4),
          itemCount: lines.length,
          itemBuilder: (context, i) {
            final l = lines[i];
            final meta = showMeta[i];
            return Container(
              color: i.isEven
                  ? const Color(0x08FFFFFF)
                  : const Color(0x00000000),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 1),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 66,
                    child: Text(
                      // Guard the abbreviation: an abbreviated/empty hash (< 7
                      // chars) would otherwise throw a RangeError.
                      meta
                          ? (l.hash.length >= 7
                                ? l.hash.substring(0, 7)
                                : l.hash)
                          : '',
                      style: gutter.copyWith(
                        color: MacosColors.systemBlueColor,
                        fontFamily: kDiffMono.fontFamily,
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 120,
                    child: Text(
                      meta ? l.author : '',
                      style: gutter,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  SizedBox(
                    width: 82,
                    child: Text(meta ? l.date : '', style: gutter),
                  ),
                  SizedBox(
                    width: 44,
                    child: Text(
                      '${l.lineNumber}',
                      textAlign: TextAlign.end,
                      style: gutter,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      l.content.isEmpty ? ' ' : l.content,
                      style: kDiffMono,
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
