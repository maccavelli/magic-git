import 'package:flutter/cupertino.dart';
import 'package:macos_ui/macos_ui.dart';

/// The non-fatal "some project data may be incomplete" banner shown when a
/// forge dashboard's GraphQL query came back with partial data alongside an
/// `errors[]` entry (e.g. no permission on one field). One shared widget —
/// it existed byte-identically in both create sheets, while the two project
/// panels showed nothing at all and silently rendered the incomplete data.
///
/// Mirrors repo_status_view's `_warningBanner` styling (orange, full-width,
/// triangle icon) so a non-fatal warning reads the same way everywhere.
class DashboardWarningBanner extends StatelessWidget {
  final String message;

  const DashboardWarningBanner(this.message, {super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Container(
        width: double.infinity,
        color: MacosColors.systemOrangeColor.withValues(alpha: 0.15),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
                'Some project data may be incomplete: $message',
                style: MacosTheme.of(context).typography.caption1,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
