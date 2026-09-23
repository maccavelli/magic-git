import 'package:flutter/cupertino.dart';
import 'package:macos_ui/macos_ui.dart';

/// The Repository panel when there is nothing to commit: the green check and
/// "Working tree clean", nothing else. The branch and the last commit's subject
/// used to sit beneath it; after a commit they repeated what the Output panel
/// already says (MADR 0005, Amendment 0005.2). The branch stays in the
/// accessibility label.
class RepositoryCleanState extends StatelessWidget {
  final String branchLabel;

  const RepositoryCleanState({super.key, required this.branchLabel});

  @override
  Widget build(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    return Semantics(
      container: true,
      label: 'Working tree clean on $branchLabel',
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ExcludeSemantics(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const MacosIcon(
                  CupertinoIcons.check_mark_circled,
                  size: 34,
                  color: MacosColors.systemGreenColor,
                ),
                const SizedBox(height: 10),
                Text('Working tree clean', style: typography.headline),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
