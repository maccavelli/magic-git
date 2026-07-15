import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';
import '../../core/git/git_service.dart';
import '../../core/providers/app_providers.dart';
import '../../core/theme/app_theme.dart';
import '../common/diff_view.dart';
import '../common/tool_icon_button.dart';

/// "File history" — the commits that touched a single file (following renames),
/// with the selected commit's patch beside them. Opened from the file tree.
class FileHistorySheet extends ConsumerStatefulWidget {
  final String repoPath;
  final String path;
  const FileHistorySheet({
    super.key,
    required this.repoPath,
    required this.path,
  });

  @override
  ConsumerState<FileHistorySheet> createState() => _FileHistorySheetState();
}

class _FileHistorySheetState extends ConsumerState<FileHistorySheet> {
  String? _selected;

  @override
  Widget build(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    final async = ref.watch(fileLogProvider((widget.repoPath, widget.path)));
    final screen = MediaQuery.sizeOf(context);
    return MacosSheet(
      child: SizedBox(
        width: (screen.width * 0.78).clamp(640.0, 1040.0).toDouble(),
        height: (screen.height * 0.82).clamp(440.0, 900.0).toDouble(),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 10, 8),
              child: Row(
                children: [
                  const MacosIcon(CupertinoIcons.clock, size: 16),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'File history · ${widget.path}',
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
                data: (commits) => _body(context, commits),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _body(BuildContext context, List<GitCommit> commits) {
    if (commits.isEmpty) {
      return Center(
        child: Text(
          'No history for this file.',
          style: MacosTheme.of(
            context,
          ).typography.body.copyWith(color: MacosColors.systemGrayColor),
        ),
      );
    }
    final selected = _selected ?? commits.first.hash;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: 320,
          child: ListView.builder(
            itemCount: commits.length,
            itemBuilder: (context, i) => _commitRow(commits[i], selected),
          ),
        ),
        Container(width: 1, color: MacosColors.separatorColor),
        Expanded(child: _diff(selected)),
      ],
    );
  }

  Widget _commitRow(GitCommit c, String selected) {
    final typography = MacosTheme.of(context).typography;
    final isSel = c.hash == selected;
    return GestureDetector(
      onTap: () => setState(() => _selected = c.hash),
      child: Container(
        color: isSel
            ? AppTheme.rowSelectionTint
            : const Color(0x00000000),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              c.subject,
              style: typography.body,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 2),
            Text(
              '${c.shortHash} · ${c.authorName} · ${c.date.length >= 10 ? c.date.substring(0, 10) : c.date}',
              style: typography.caption1.copyWith(
                color: MacosColors.systemGrayColor,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  Widget _diff(String hash) {
    final async = ref.watch(
      commitFileDiffProvider((widget.repoPath, hash, widget.path)),
    );
    return async.when(
      loading: () => const DiffPending(),
      error: (err, _) => DiffFailure(err),
      data: (patch) => DiffView(diff: patch),
    );
  }
}
